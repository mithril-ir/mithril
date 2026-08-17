{-# LANGUAGE OverloadedStrings #-}

-- | The effectful file boundary of @mithril validate FILE@.
--
-- This module owns reading the user's file, obtaining the compiled-in
-- Core v0 schema, and classifying every failure of the boundary;
-- expected failures are returned as values, never thrown.  It also renders the
-- outcomes and classifies exit codes so that the executable's @Main@
-- stays a thin dispatcher.
--
-- The command establishes structural Core v0 validity plus complete
-- Core v0 name resolution plus complete Core v0 static typing —
-- nothing more (see "Mithril.Core.Validation",
-- "Mithril.Core.Resolution", and "Mithril.Core.Typing" for the exact
-- non-claims).
module Mithril.Command.Validate
  ( ValidateFileError (..)
  , validateCoreFile
  , renderValidateSuccess
  , renderValidateFailure
  , failureExitCode
  , displayPath
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as ByteString
import Data.Char (isPrint, showLitChar)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))
import System.IO.Error (ioeGetErrorString)

import Mithril.Core.Resolution
  ( ResolutionFailure (..)
  , ResolutionViolation (..)
  , ResolverInvariantViolation (..)
  , resolveCoreDocument
  )
import Mithril.Core.Typing
  ( TypeViolation (..)
  , TypecheckerInvariantViolation (..)
  , Typed
  , TypingFailure (..)
  , typecheckCoreDocument
  )
import Mithril.Core.Validation
  ( CoreDocument
  , ParseError (..)
  , SchemaLoadError (..)
  , StructuralViolation (..)
  , bundledCoreSchema
  , parseCoreDocument
  , renderJsonPointer
  , validateCoreDocument
  )

-- | Every expected failure of @mithril validate FILE@, classified.
data ValidateFileError
  = -- | The user's file could not be read; the 'Text' is the reason.
    FileReadError FilePath Text
  | -- | The user's file is not valid JSON.
    FileParseError FilePath ParseError
  | -- | The user's file is valid JSON but violates the Core v0
    -- schema; violations are sorted and deduplicated.
    FileStructuralViolations FilePath (NonEmpty StructuralViolation)
  | -- | The user's file is structurally valid but has Core v0 name
    -- problems; violations are sorted and deduplicated.
    FileResolutionViolations FilePath (NonEmpty ResolutionViolation)
  | -- | The user's file resolves but has Core v0 static-typing
    -- problems; violations are sorted and deduplicated.
    FileTypeViolations FilePath (NonEmpty TypeViolation)
  | -- | The schema compiled into the tool failed to parse or fell
    -- outside the supported profile — possible only when the
    -- @core/schema.json@ embedded at build time was itself broken.
    -- This is an internal error of the tool.
    InternalSchemaError SchemaLoadError
  | -- | The resolver could not interpret the structurally validated
    -- document (schema\/resolver drift or a resolver bug).  This is
    -- an internal error of the tool, never a user-document problem.
    InternalResolverError (NonEmpty ResolverInvariantViolation)
  | -- | The typechecker could not interpret the resolved
    -- representation (frontend drift or a resolver\/typechecker
    -- bug).  This is an internal error of the tool, never a
    -- user-document problem.
    InternalTypecheckerError (NonEmpty TypecheckerInvariantViolation)
  deriving (Eq, Show)

-- | Read FILE, parse it as JSON, validate it structurally against the
-- compiled-in canonical Core v0 schema, resolve every Core v0 name,
-- and typecheck the resolved document.
--
-- Expected failures — an unreadable file, malformed JSON, structural
-- violations, name-resolution violations, static-typing violations,
-- a broken compiled-in schema, or a resolver- or
-- typechecker-invariant failure — are returned in 'Left';
-- 'IOException's from reading the user file are caught and
-- classified.  The schema itself involves no run-time I\/O
-- ('bundledCoreSchema' is pure), so no environment override can
-- substitute it.
validateCoreFile
  :: FilePath
  -> IO (Either ValidateFileError (CoreDocument Typed))
validateCoreFile file =
  case bundledCoreSchema of
    Left schemaError -> pure (Left (InternalSchemaError schemaError))
    Right schema -> do
      readOutcome <- try (ByteString.readFile file)
      pure $ case readOutcome of
        Left readFailure ->
          Left
            ( FileReadError
                file
                (Text.pack (ioeGetErrorString (readFailure :: IOException)))
            )
        Right bytes ->
          case parseCoreDocument bytes of
            Left parseFailure -> Left (FileParseError file parseFailure)
            Right document ->
              case validateCoreDocument schema document of
                Left violations ->
                  Left (FileStructuralViolations file violations)
                Right validDocument ->
                  case resolveCoreDocument validDocument of
                    Left (ResolutionViolations violations) ->
                      Left (FileResolutionViolations file violations)
                    Left (ResolverInvariantViolations problems) ->
                      Left (InternalResolverError problems)
                    Right resolvedDocument ->
                      case typecheckCoreDocument resolvedDocument of
                        Left (TypeViolations violations) ->
                          Left (FileTypeViolations file violations)
                        Left (TypecheckerInvariantViolations problems) ->
                          Left (InternalTypecheckerError problems)
                        Right typedDocument -> Right typedDocument

-- | The single success line, for stdout.
renderValidateSuccess :: FilePath -> Text
renderValidateSuccess file =
  displayPath file <> ": valid Mithril Core v0 through static typing"

-- | Render a failure for stderr.  The result has no trailing newline;
-- print it with a newline-appending writer.  Rendering is pure and
-- deterministic: the same failure always renders to the same bytes.
renderValidateFailure :: ValidateFileError -> Text
renderValidateFailure failure =
  case failure of
    FileReadError file reason ->
      displayPath file <> ": cannot read file\n  " <> escapeControlChars reason
    FileParseError file (ParseError message) ->
      displayPath file <> ": invalid JSON\n  " <> escapeControlChars message
    FileStructuralViolations file violations ->
      Text.intercalate
        "\n"
        ( (displayPath file <> ": invalid Mithril Core v0 structure")
            : [ "  "
                  <> renderJsonPointer (violationPath violation)
                  <> ": "
                  <> escapeControlChars (violationMessage violation)
              | violation <- NonEmpty.toList violations
              ]
        )
    FileResolutionViolations file violations ->
      Text.intercalate
        "\n"
        ( (displayPath file <> ": invalid Mithril Core v0 name resolution")
            : [ "  "
                  <> renderJsonPointer (resolutionViolationPath violation)
                  <> ": "
                  <> escapeControlChars (resolutionViolationMessage violation)
              | violation <- NonEmpty.toList violations
              ]
        )
    FileTypeViolations file violations ->
      Text.intercalate
        "\n"
        ( (displayPath file <> ": invalid Mithril Core v0 static typing")
            : [ "  "
                  <> renderJsonPointer (typeViolationPath violation)
                  <> ": "
                  <> escapeControlChars (typeViolationMessage violation)
              | violation <- NonEmpty.toList violations
              ]
        )
    InternalSchemaError schemaError ->
      case schemaError of
        SchemaParseError reason ->
          internalSchemaPrefix
            <> "the compiled-in schema is not valid JSON\n  "
            <> escapeControlChars reason
        SchemaProfileError problems ->
          Text.intercalate
            "\n"
            ( (internalSchemaPrefix <> "the compiled-in schema is outside the supported profile")
                : [ "  " <> escapeControlChars problem
                  | problem <- NonEmpty.toList problems
                  ]
            )
    InternalResolverError problems ->
      Text.intercalate
        "\n"
        ( ( internalResolverPrefix
              <> "the structurally validated document does not match the"
              <> " resolver's Core v0 interpretation"
          )
            : [ "  "
                  <> renderJsonPointer (resolverInvariantPath problem)
                  <> ": "
                  <> escapeControlChars (resolverInvariantMessage problem)
              | problem <- NonEmpty.toList problems
              ]
        )
    InternalTypecheckerError problems ->
      Text.intercalate
        "\n"
        ( ( internalTypecheckerPrefix
              <> "the name-resolved document does not match the"
              <> " typechecker's Core v0 interpretation"
          )
            : [ "  "
                  <> renderJsonPointer (typecheckerInvariantPath problem)
                  <> ": "
                  <> escapeControlChars (typecheckerInvariantMessage problem)
              | problem <- NonEmpty.toList problems
              ]
        )
  where
    internalSchemaPrefix = "mithril: internal Core schema error: "
    internalResolverPrefix = "mithril: internal Core resolver error: "
    internalTypecheckerPrefix = "mithril: internal Core typechecker error: "

-- | Exit classification: user-input failures exit @1@; internal
-- compiled-in-schema, resolver, and typechecker failures exit @2@.
-- (Success exits @0@ and is not a 'ValidateFileError'.)
failureExitCode :: ValidateFileError -> ExitCode
failureExitCode failure =
  case failure of
    InternalSchemaError _ -> ExitFailure 2
    InternalResolverError _ -> ExitFailure 2
    InternalTypecheckerError _ -> ExitFailure 2
    FileReadError _ _ -> ExitFailure 1
    FileParseError _ _ -> ExitFailure 1
    FileStructuralViolations _ _ -> ExitFailure 1
    FileResolutionViolations _ _ -> ExitFailure 1
    FileTypeViolations _ _ -> ExitFailure 1

-- | Deterministic rendering of a file path inside diagnostics.
--
-- A non-empty path made of printable characters is rendered verbatim;
-- anything else (control characters, an empty path) is rendered as a
-- Haskell string literal via 'show', so unusual paths cannot smuggle
-- line breaks or invisible characters into diagnostics.
displayPath :: FilePath -> Text
displayPath path
  | not (null path) && all isPrint path = Text.pack path
  | otherwise = Text.pack (show path)

-- | Escape control characters in diagnostic text ('showLitChar'
-- form), keeping every diagnostic on its intended line.
escapeControlChars :: Text -> Text
escapeControlChars = Text.concatMap escapeChar
  where
    escapeChar c
      | isPrint c = Text.singleton c
      | otherwise = Text.pack (showLitChar c "")
