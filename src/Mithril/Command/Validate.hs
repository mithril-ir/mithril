{-# LANGUAGE OverloadedStrings #-}

-- | The effectful file boundary of @mithril validate FILE@.
--
-- This module owns reading the user's file, loading the bundled
-- schema, and classifying every failure of the boundary; expected
-- failures are returned as values, never thrown.  It also renders the
-- outcomes and classifies exit codes so that the executable's @Main@
-- stays a thin dispatcher.
--
-- The command establishes structural Core v0 validity only (see
-- "Mithril.Core.Validation" for the exact non-claims).
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

import Mithril.Core.Validation
  ( CoreDocument
  , ParseError (..)
  , SchemaLoadError (..)
  , StructurallyValid
  , StructuralViolation (..)
  , loadBundledCoreSchema
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
  | -- | The bundled schema failed to load, parse, or pass the
    -- profile gate.  This is an internal error of the tool.
    InternalSchemaError SchemaLoadError
  deriving (Eq, Show)

-- | Read FILE, parse it as JSON, and validate it structurally against
-- the bundled Core v0 schema.
--
-- Expected failures — an unreadable file, malformed JSON, structural
-- violations, or a broken bundled schema — are returned in 'Left';
-- 'IOException's from both the user file and the bundled schema are
-- caught and classified.
validateCoreFile
  :: FilePath
  -> IO (Either ValidateFileError (CoreDocument StructurallyValid))
validateCoreFile file = do
  schemaOutcome <- loadBundledCoreSchema
  case schemaOutcome of
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
                Right validDocument -> Right validDocument

-- | The single success line, for stdout.
renderValidateSuccess :: FilePath -> Text
renderValidateSuccess file =
  displayPath file <> ": structurally valid Mithril Core v0"

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
    InternalSchemaError schemaError ->
      case schemaError of
        SchemaReadError reason ->
          internalPrefix
            <> "cannot read the bundled schema\n  "
            <> escapeControlChars reason
        SchemaParseError reason ->
          internalPrefix
            <> "the bundled schema is not valid JSON\n  "
            <> escapeControlChars reason
        SchemaProfileError problems ->
          Text.intercalate
            "\n"
            ( (internalPrefix <> "the bundled schema is outside the supported profile")
                : [ "  " <> escapeControlChars problem
                  | problem <- NonEmpty.toList problems
                  ]
            )
  where
    internalPrefix = "mithril: internal Core schema error: "

-- | Exit classification: user-input failures exit @1@; internal
-- bundled-schema failures exit @2@.  (Success exits @0@ and is not a
-- 'ValidateFileError'.)
failureExitCode :: ValidateFileError -> ExitCode
failureExitCode failure =
  case failure of
    InternalSchemaError _ -> ExitFailure 2
    FileReadError _ _ -> ExitFailure 1
    FileParseError _ _ -> ExitFailure 1
    FileStructuralViolations _ _ -> ExitFailure 1

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
