{-# LANGUAGE OverloadedStrings #-}

-- | The first deterministic frontend boundary for Mithril Core v0:
--
-- > raw bytes
-- >   -> JSON parsing                      ('parseCoreDocument')
-- >   -> Core v0 structural validation     ('validateCoreDocument')
-- >   -> structurally-valid opaque document
--
-- This boundary establishes syntactic JSON well-formedness and
-- structural conformance to the supported profile of the canonical
-- @core/schema.json@ (JSON Schema draft 2020-12), compiled into this
-- library at build time — nothing more.  It
-- performs no name resolution, no Mithril typechecking, no
-- normalization, no semantic well-formedness checks, no guarantee
-- verification, no proof generation or checking, and no code
-- generation.  A @'CoreDocument' 'StructurallyValid'@ is /not/ typed
-- normalized Core.  The next frontend stage, complete Core v0 name
-- resolution, lives in "Mithril.Core.Resolution" and consumes the
-- structurally valid document this module produces.
--
-- == Known limitations (deliberate, unresolved)
--
-- * JSON parsing uses Aeson's object-member semantics: duplicate
--   object members are accepted under the currently resolved Aeson
--   version, not rejected.  Which occurrence wins is not part of the
--   Mithril language contract, and callers must not rely on any
--   winner behavior; strict duplicate-member rejection remains
--   unresolved and is expected to need a stricter parse step later.
-- * Mithril enforces no independent input-size, nesting, memory, or
--   execution-resource limits on documents or on the compiled-in schema.
--   Excessive nesting or reference recursion is expected to fail
--   closed inside the validation backend, but no dedicated depth
--   diagnostic is guaranteed: the backend's error aggregation may
--   surface only an outer structural violation.
-- * The validation backend (@jsonschema-0.3.0.1@, MPL-2.0) is
--   provisional and trusted only for the explicitly gated schema
--   profile (see 'checkCoreSchemaProfile'): local @#@ references
--   only, no external references or anchors, no @unevaluated*@ or
--   dynamic references, and @pattern@ semantics inherited from the
--   backend's POSIX (TDFA) regex engine — no claim of ECMA-262
--   equivalence; the gate compiles every @pattern@ with that same
--   engine, so a pattern the backend cannot compile is a schema-load
--   failure, not a validation-time exception.  This module does not
--   claim a complete Draft 2020-12 implementation.
module Mithril.Core.Validation
  ( -- * Pipeline stages
    Parsed
  , StructurallyValid

    -- * Opaque documents and schemas
  , CoreDocument
  , CoreSchema

    -- * Errors and violations
  , ParseError (..)
  , SchemaLoadError (..)
  , StructuralViolation (..)

    -- * JSON parsing
  , parseCoreDocument

    -- * The compiled-in schema and the profile gate
  , checkCoreSchemaProfile
  , bundledCoreSchema
  , draft202012SchemaUri
  , supportedSchemaKeywords
  , usedSchemaKeywords

    -- * Structural validation
  , validateCoreDocument
  , normalizeViolations

    -- * Diagnostic rendering
  , renderJsonPointer
  ) where

import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import Data.JSON.JSONSchema (ValidationError (..), validateWithErrors)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import Text.Regex.TDFA (defaultCompOpt, defaultExecOpt)
import qualified Text.Regex.TDFA.Text as Regex

import Mithril.Core.Internal.BundledSchema (bundledCoreSchemaBytes)
import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Parsed
  , StructurallyValid
  )

-- 'CoreDocument', its stage indexes, and its nominal role annotation
-- live in the hidden "Mithril.Core.Internal.Document" module and are
-- re-exported abstractly here: the constructor is not exported and no
-- accessor is exported, so later compiler stages cannot consume a
-- merely 'Parsed' value while bypassing structural validation.  The
-- only way to obtain a @'CoreDocument' 'StructurallyValid'@ is
-- 'validateCoreDocument' — and since 'bundledCoreSchema' is the
-- only public producer of 'CoreSchema', that stage always attests
-- validity against the compiled-in canonical Core v0 schema, not
-- against some caller-supplied or runtime-substituted schema.

-- | A gated Core v0 schema.  Opaque: the constructor is not exported,
-- and 'bundledCoreSchema' is the only public producer — no public
-- function accepts arbitrary schema bytes and returns a 'CoreSchema',
-- so holding one means holding /the canonical compiled-in schema/.
-- 'checkCoreSchemaProfile' exposes the same gate for tests and
-- tooling without producing a schema value.
newtype CoreSchema = CoreSchema Value

-- | A JSON syntax failure from 'parseCoreDocument'.
newtype ParseError = ParseError
  { parseErrorMessage :: Text
  }
  deriving (Eq, Show)

-- | A failure to obtain a usable Core schema.  For the compiled-in
-- schema every one of these is an internal error of the @mithril@
-- tool — possible only when the @core/schema.json@ embedded at build
-- time was itself broken — never a problem with the user's document.
data SchemaLoadError
  = -- | The schema bytes are not valid JSON.
    SchemaParseError Text
  | -- | The schema parsed but is outside the supported Core v0
    -- profile.  Each entry is a rendered @pointer: message@ line;
    -- the list is sorted and deduplicated.
    SchemaProfileError (NonEmpty Text)
  deriving (Eq, Show)

-- | One structural violation of the Core v0 schema by a document.
data StructuralViolation = StructuralViolation
  { violationPath :: [Text]
    -- ^ Instance path of the failing value, as raw (unescaped)
    -- segments; render with 'renderJsonPointer'.
  , violationMessage :: Text
    -- ^ Description of the violation, produced by the validation
    -- backend.
  }
  deriving (Eq, Ord, Show)

-- | Parse raw bytes as a single JSON value.
--
-- Malformed input is rejected, as is any trailing non-whitespace
-- garbage after the value.  Duplicate object members are currently
-- accepted rather than rejected, and no occurrence is contractually
-- the winner (see the module header).
parseCoreDocument :: ByteString -> Either ParseError (CoreDocument Parsed)
parseCoreDocument bytes =
  case eitherDecodeStrict' bytes :: Either String Value of
    Left message -> Left (ParseError (Text.pack message))
    Right value -> Right (CoreDocument value)

-- | Validate a parsed document against a gated Core schema.
--
-- Pure and deterministic: the same schema and document always produce
-- the same result.  On failure the violations are sorted and
-- deduplicated ('normalizeViolations').
validateCoreDocument
  :: CoreSchema
  -> CoreDocument Parsed
  -> Either (NonEmpty StructuralViolation) (CoreDocument StructurallyValid)
validateCoreDocument (CoreSchema schemaValue) (CoreDocument documentValue) =
  case NonEmpty.nonEmpty (normalizeViolations violations) of
    Nothing -> Right (CoreDocument documentValue)
    Just someViolations -> Left someViolations
  where
    violations =
      [ StructuralViolation
          { violationPath = error_path backendError
          , violationMessage = error_message backendError
          }
      | backendError <- validateWithErrors schemaValue documentValue
      ]

-- | Deterministically sort violations (by path, then message) and
-- remove duplicates.  This is the exact normalization applied by
-- 'validateCoreDocument' before violations are returned.
normalizeViolations :: [StructuralViolation] -> [StructuralViolation]
normalizeViolations = map NonEmpty.head . NonEmpty.group . sort

-- | Render an instance path as an RFC 6901-style JSON pointer:
-- @~@ escapes to @~0@ and @/@ escapes to @~1@ (in that order, so no
-- double escaping occurs).  By project convention the root path
-- renders as @\/@ rather than RFC 6901's empty string, so that every
-- diagnostic line carries a visible location.
renderJsonPointer :: [Text] -> Text
renderJsonPointer [] = "/"
renderJsonPointer segments =
  Text.concat ["/" <> escapeSegment segment | segment <- segments]
  where
    escapeSegment = Text.replace "/" "~1" . Text.replace "~" "~0"

-- | The only accepted @$schema@ value.
draft202012SchemaUri :: Text
draft202012SchemaUri = "https://json-schema.org/draft/2020-12/schema"

-- | The exact, closed inventory of keywords accepted in schema
-- positions, sorted.  This is the current Core v0 schema profile: a
-- schema using any other keyword fails to load, because the selected
-- validation backend would silently ignore keywords it does not
-- implement.  Extending this list requires reviewing backend support
-- and the tests that pin the inventory.
supportedSchemaKeywords :: [Text]
supportedSchemaKeywords =
  sort
    [ "$schema"
    , "title"
    , "description"
    , "$comment"
    , "$defs"
    , "$ref"
    , "type"
    , "properties"
    , "required"
    , "additionalProperties"
    , "items"
    , "contains"
    , "propertyNames"
    , "oneOf"
    , "allOf"
    , "not"
    , "const"
    , "enum"
    , "pattern"
    , "minItems"
    , "maxItems"
    , "uniqueItems"
    ]

-- | The distinct member keys appearing in schema positions of a
-- loaded schema, sorted.  Keys under @properties@ and @$defs@ are
-- property or definition names, not schema keywords, and are not
-- included.  Tests use this to pin 'supportedSchemaKeywords' to what
-- the compiled-in schema actually uses.
usedSchemaKeywords :: CoreSchema -> [Text]
usedSchemaKeywords (CoreSchema value) =
  map NonEmpty.head (NonEmpty.group (sort (walkKeywords (walkSchema [] value))))

-- | Check schema bytes against the supported Core v0 profile,
-- returning only evidence of the outcome.
--
-- This is the exact gate that 'bundledCoreSchema' applies to the
-- compiled-in schema bytes, exposed so tests and tooling can probe it
-- with arbitrary bytes.  The gate fails closed: before the backend
-- validator is trusted with a schema, it verifies that
--
-- 1. the bytes parse as JSON;
-- 2. the root is a JSON object;
-- 3. the root declares @$schema@, and every occurrence of @$schema@
--    is exactly 'draft202012SchemaUri';
-- 4. every @$ref@ is a local @#@ JSON-pointer reference (no external
--    URIs, no anchors) that resolves to a schema position of this
--    document, using unescaped pointer tokens only;
-- 5. members beside @$ref@ are annotation-only (@$comment@, @title@,
--    @description@) — the backend ignores @$ref@ siblings, so
--    assertion siblings are rejected rather than silently dropped;
-- 6. every keyword in a schema position is in
--    'supportedSchemaKeywords' and has the expected shape, with keys
--    under @properties@ and @$defs@ correctly treated as names rather
--    than keywords;
-- 7. every @pattern@ value compiles under the validation backend's
--    own POSIX (TDFA) regex engine, with the backend's own defaults,
--    so document validation can never reach the backend's partial
--    regex construction.
--
-- This is a profile gate, not a meta-schema validator: it checks
-- exactly what is needed so that no unsupported keyword or reference
-- behavior can be silently ignored (or thrown) by the backend.
--
-- Success is @()@ by design, never a schema value: 'CoreSchema' can
-- only be produced by 'bundledCoreSchema', which keeps
-- @'CoreDocument' 'StructurallyValid'@ meaning validity against the
-- canonical compiled-in Core v0 schema.
checkCoreSchemaProfile :: ByteString -> Either SchemaLoadError ()
checkCoreSchemaProfile bytes = () <$ gateSchemaBytes bytes

-- | Parse schema bytes and apply the supported-profile gate described
-- at 'checkCoreSchemaProfile'.
--
-- This is the only constructor of 'CoreSchema', and it is deliberately
-- private: exporting a bytes-to-schema function would let callers mint
-- @'CoreDocument' 'StructurallyValid'@ values against arbitrary
-- schemas inside the keyword profile (for example @{\"type\":
-- \"object\"}@), destroying what the stage attests.
gateSchemaBytes :: ByteString -> Either SchemaLoadError CoreSchema
gateSchemaBytes bytes =
  case eitherDecodeStrict' bytes :: Either String Value of
    Left message -> Left (SchemaParseError (Text.pack message))
    Right value ->
      case NonEmpty.nonEmpty (renderProfileProblems (schemaProfileProblems value)) of
        Nothing -> Right (CoreSchema value)
        Just problems -> Left (SchemaProfileError problems)

-- | The canonical Core v0 schema, gated: the only public producer of
-- 'CoreSchema'.
--
-- The schema bytes are compiled into this library from
-- @core/schema.json@ at build time (see
-- "Mithril.Core.Internal.BundledSchema"), then pass through the same
-- gate as 'checkCoreSchemaProfile'.  This value is pure by
-- construction: no file is read at run time, so neither the process
-- working directory nor any environment override — in particular the
-- Cabal data-directory variable @mithril_ir_datadir@ — can influence
-- which grammar confers the 'StructurallyValid' stage.  A 'Left' here
-- means the schema embedded at build time was itself unparseable or
-- outside the supported profile; the tool reports it deterministically
-- as an internal error.
bundledCoreSchema :: Either SchemaLoadError CoreSchema
bundledCoreSchema = gateSchemaBytes bundledCoreSchemaBytes

--------------------------------------------------------------------
-- Internal: the schema-profile walk
--------------------------------------------------------------------

-- | Accumulated facts from one traversal of all schema positions.
data SchemaWalk = SchemaWalk
  { walkProblems :: [([Text], Text)]
    -- ^ Profile violations: schema path and message.
  , walkPositions :: [[Text]]
    -- ^ Paths of all schema positions (objects and boolean schemas);
    -- @$ref@ targets must land on one of these.
  , walkKeywords :: [Text]
    -- ^ Member keys seen in schema-position objects.
  , walkReferences :: [([Text], Text)]
    -- ^ Locally well-formed @$ref@s: path of the @$ref@ keyword and
    -- its target, resolved against 'walkPositions' afterwards.
  }

instance Semigroup SchemaWalk where
  SchemaWalk a b c d <> SchemaWalk a' b' c' d' =
    SchemaWalk (a <> a') (b <> b') (c <> c') (d <> d')

instance Monoid SchemaWalk where
  mempty = SchemaWalk [] [] [] []

-- | All profile problems of a candidate schema document.
schemaProfileProblems :: Value -> [([Text], Text)]
schemaProfileProblems value =
  case value of
    Object members ->
      let walk = walkSchema [] value
          rootSchemaProblems =
            [ ( []
              , "the schema root must declare \"$schema\" as exactly \""
                  <> draft202012SchemaUri
                  <> "\""
              )
            | not (KeyMap.member "$schema" members)
            ]
          unresolvedProblems =
            [ ( refPath
              , "\"$ref\" target \""
                  <> target
                  <> "\" does not resolve to a schema position in this document"
              )
            | (refPath, target) <- walkReferences walk
            , pointerTokens target `notElem` walkPositions walk
            ]
       in walkProblems walk <> rootSchemaProblems <> unresolvedProblems
    _ -> [([], "the schema root must be a JSON object")]

-- | Sort, deduplicate, and render profile problems as
-- @pointer: message@ lines.
renderProfileProblems :: [([Text], Text)] -> [Text]
renderProfileProblems problems =
  [ renderJsonPointer path <> ": " <> message
  | (path, message) <- map NonEmpty.head (NonEmpty.group (sort problems))
  ]

-- | Tokens of an already-vetted local pointer: @#@ is the root, and
-- @#\/a\/b@ addresses member @b@ of member @a@.  Escapes are rejected
-- before this point, so tokens are literal.
pointerTokens :: Text -> [Text]
pointerTokens target =
  case Text.stripPrefix "#/" target of
    Just pointer -> Text.splitOn "/" pointer
    Nothing -> []

-- | Walk one schema position, then every schema position below it.
walkSchema :: [Text] -> Value -> SchemaWalk
walkSchema path value =
  case value of
    Bool _ -> mempty {walkPositions = [path]}
    Object members ->
      mempty {walkPositions = [path], walkKeywords = memberKeys members}
        <> walkMembers path members
    _ ->
      mempty
        { walkProblems =
            [(path, "a schema position must be a JSON object or boolean")]
        }

-- | The member keys of a schema-position object.
memberKeys :: KeyMap.KeyMap Value -> [Text]
memberKeys members = [Key.toText key | (key, _) <- KeyMap.toList members]

-- | Check the members of a schema-position object.  A node carrying
-- @$ref@ follows the reference rules; any other node is checked
-- keyword by keyword.
walkMembers :: [Text] -> KeyMap.KeyMap Value -> SchemaWalk
walkMembers path members
  | KeyMap.member "$ref" members = walkReferenceNode path members
  | otherwise =
      mconcat
        [ checkKeyword path (Key.toText key) memberValue
        | (key, memberValue) <- KeyMap.toList members
        ]

-- | Annotation keywords accepted beside @$ref@.  The backend ignores
-- all @$ref@ siblings, so only keywords without assertion semantics
-- may appear here.
refAnnotationKeywords :: [Text]
refAnnotationKeywords = ["$comment", "title", "description"]

-- | Check a schema-position object that carries @$ref@.
walkReferenceNode :: [Text] -> KeyMap.KeyMap Value -> SchemaWalk
walkReferenceNode path members =
  referenceCheck <> siblingChecks
  where
    referenceCheck =
      case KeyMap.lookup "$ref" members of
        Just (String target)
          | not (isLocalPointer target) ->
              problemAt
                (path <> ["$ref"])
                ( "\"$ref\" target \""
                    <> target
                    <> "\" is not a local \"#\" JSON-pointer reference"
                )
          | Text.any (\c -> c == '%' || c == '~') target ->
              problemAt
                (path <> ["$ref"])
                ( "\"$ref\" target \""
                    <> target
                    <> "\" uses \"%\" or \"~\" escapes, which are outside"
                    <> " the supported profile"
                )
          | otherwise -> mempty {walkReferences = [(path <> ["$ref"], target)]}
        _ ->
          problemAt
            (path <> ["$ref"])
            "\"$ref\" must be a string containing a local \"#\" JSON-pointer reference"
    isLocalPointer target =
      target == "#" || "#/" `Text.isPrefixOf` target
    siblingChecks =
      mconcat
        [ checkSibling (Key.toText key) memberValue
        | (key, memberValue) <- KeyMap.toList members
        , key /= "$ref"
        ]
    checkSibling keyword memberValue
      | keyword `elem` refAnnotationKeywords =
          case memberValue of
            String _ -> mempty
            _ ->
              problemAt
                (path <> [keyword])
                ("\"" <> keyword <> "\" must be a string")
      | otherwise =
          problemAt
            (path <> [keyword])
            ( "keyword \""
                <> keyword
                <> "\" is not permitted beside \"$ref\" (the validator"
                <> " ignores \"$ref\" siblings; only the annotations"
                <> " \"$comment\", \"title\" and \"description\" are"
                <> " accepted)"
            )

-- | Check one keyword of an ordinary (non-@$ref@) schema node and
-- walk into any subschemas it holds.  Keys under @properties@ and
-- @$defs@ are property or definition names, never keywords.
checkKeyword :: [Text] -> Text -> Value -> SchemaWalk
checkKeyword path keyword memberValue =
  case keyword of
    "$schema" ->
      case memberValue of
        String uri | uri == draft202012SchemaUri -> mempty
        _ ->
          problemAt
            keywordPath
            ("\"$schema\" must be exactly \"" <> draft202012SchemaUri <> "\"")
    "title" -> stringShaped
    "description" -> stringShaped
    "$comment" -> stringShaped
    "$defs" -> schemaMap "\"$defs\" must be a JSON object of schemas"
    "properties" -> schemaMap "\"properties\" must be a JSON object of schemas"
    "type" ->
      case memberValue of
        String typeName
          | typeName `elem` jsonTypeNames -> mempty
        _ ->
          problemAt
            keywordPath
            "\"type\" must be a single JSON type name string"
    "required" ->
      case memberValue of
        Array items | all isString items -> mempty
        _ -> problemAt keywordPath "\"required\" must be an array of strings"
    "additionalProperties" -> subschema
    "items" -> subschema
    "contains" -> subschema
    "propertyNames" -> subschema
    "not" -> subschema
    "oneOf" -> schemaList
    "allOf" -> schemaList
    "const" -> mempty
    "enum" ->
      case memberValue of
        Array items | not (null items) -> mempty
        _ -> problemAt keywordPath "\"enum\" must be a non-empty array"
    "pattern" ->
      case memberValue of
        String patternText ->
          case compileBackendPattern patternText of
            Right _ -> mempty
            Left compileError ->
              problemAt
                keywordPath
                ( "\"pattern\" value "
                    <> Text.pack (show patternText)
                    <> " does not compile under the validation backend's"
                    <> " POSIX (TDFA) regex engine: "
                    <> collapseWhitespace (Text.pack compileError)
                )
        _ -> problemAt keywordPath "\"pattern\" must be a string"
    "minItems" -> nonNegativeInteger
    "maxItems" -> nonNegativeInteger
    "uniqueItems" ->
      case memberValue of
        Bool _ -> mempty
        _ -> problemAt keywordPath "\"uniqueItems\" must be a boolean"
    _ ->
      problemAt
        keywordPath
        ( "schema keyword \""
            <> keyword
            <> "\" is outside the supported Core v0 profile"
        )
  where
    keywordPath = path <> [keyword]
    stringShaped =
      case memberValue of
        String _ -> mempty
        _ -> problemAt keywordPath ("\"" <> keyword <> "\" must be a string")
    subschema = walkSchema keywordPath memberValue
    schemaMap message =
      case memberValue of
        Object names ->
          mconcat
            [ walkSchema (keywordPath <> [Key.toText name]) named
            | (name, named) <- KeyMap.toList names
            ]
        _ -> problemAt keywordPath message
    schemaList =
      case memberValue of
        Array items
          | not (null items) ->
              mconcat
                [ walkSchema (keywordPath <> [Text.pack (show index)]) item
                | (index, item) <- zip [0 :: Int ..] (foldr (:) [] items)
                ]
        _ ->
          problemAt
            keywordPath
            ("\"" <> keyword <> "\" must be a non-empty array of schemas")
    nonNegativeInteger =
      case fromJSON memberValue :: Result Int of
        Success n | n >= 0 -> mempty
        _ ->
          problemAt
            keywordPath
            ("\"" <> keyword <> "\" must be a non-negative integer")
    isString v =
      case v of
        String _ -> True
        _ -> False

-- | The JSON type names accepted for the @type@ keyword.
jsonTypeNames :: [Text]
jsonTypeNames =
  ["array", "boolean", "integer", "null", "number", "object", "string"]

-- | Compile a @pattern@ exactly as the validation backend will: the
-- same engine (@regex-tdfa@) with the same default options its @=~@
-- operator uses, but through the total 'Regex.compile' API.  An
-- uncompilable pattern therefore becomes a deterministic profile
-- problem here instead of a runtime exception inside document
-- validation.  Only compilability is checked; the compiled value is
-- discarded.
compileBackendPattern :: Text -> Either String Regex.Regex
compileBackendPattern = Regex.compile defaultCompOpt defaultExecOpt

-- | Collapse every whitespace run (including newlines) to a single
-- space, keeping each profile problem on one line; the regex
-- compiler's parse errors span multiple lines.
collapseWhitespace :: Text -> Text
collapseWhitespace = Text.unwords . Text.words

-- | A single profile problem as a 'SchemaWalk'.
problemAt :: [Text] -> Text -> SchemaWalk
problemAt path message = mempty {walkProblems = [(path, message)]}
