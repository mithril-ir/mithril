{-# LANGUAGE OverloadedStrings #-}

-- | Checks over the structural validation boundary:
-- "Mithril.Core.Validation" and "Mithril.Command.Validate".
--
-- Everything goes through the production API — documents enter via
-- 'parseCoreDocument', the only obtainable schema is the compiled-in
-- canonical one ('bundledCoreSchema'), and the profile gate is probed
-- with arbitrary bytes through 'checkCoreSchemaProfile'; no
-- validation logic is duplicated here.  Mutated documents are built
-- in memory from the pristine Acme example and re-encoded; the only
-- invalid documents stored as files are the deliberate fixtures under
-- @test\/fixtures\/@ (shared with the process-level CLI tests), and
-- the normative schema and example are never modified.
-- 'validateCoreFile' continues through name resolution and static
-- typing, so its successful outcomes here carry the 'Typed' stage;
-- the resolution boundary itself is covered by
-- "Mithril.CoreResolutionTests" and the typing boundary by
-- "Mithril.CoreTypingTests".
--
-- The schema-provenance regressions at the end pin the review's
-- substitution attack shut: pointing the Cabal data-directory
-- override at a nonexistent or malicious location must not change
-- which grammar validation uses, because the schema is a compile-time
-- constant of the library, not a runtime lookup.
module Mithril.CoreValidationTests
  ( tests
  ) where

import Data.Aeson
  ( Result (..)
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , fromJSON
  , object
  , toJSON
  , (.=)
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Either (isLeft, isRight)
import Data.List (isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))

import Mithril.Command.Validate
  ( ValidateFileError (..)
  , displayPath
  , failureExitCode
  , renderValidateFailure
  , renderValidateSuccess
  , validateCoreFile
  )
import Mithril.Core.Typing (Typed)
import Mithril.Core.Validation
  ( CoreDocument
  , CoreSchema
  , ParseError (..)
  , SchemaLoadError (..)
  , StructurallyValid
  , StructuralViolation (..)
  , bundledCoreSchema
  , checkCoreSchemaProfile
  , draft202012SchemaUri
  , normalizeViolations
  , parseCoreDocument
  , renderJsonPointer
  , supportedSchemaKeywords
  , usedSchemaKeywords
  , validateCoreDocument
  )
import Mithril.Test (Check, check)
import Mithril.TestEnv
  ( datadirVariable
  , permissiveSchemaBytes
  , withEnvVarSet
  , withPermissiveDatadir
  )

-- | The handwritten example validated by the full checkpoint checks.
acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

-- | The independent review's near-Core document: a checked-in fixture
-- whose root carries plausible @schema@\/@actions@\/@guarantees@
-- members but none of the canonical root requirements.
nearCorePath :: FilePath
nearCorePath = "test/fixtures/near-core.mir.json"

-- | All validation checks.  The file reads assume the test process
-- runs from the package root, which is how @cabal test@ runs it.
tests :: IO [Check]
tests = do
  let schemaOutcome = bundledCoreSchema
  acmeBytes <- ByteString.readFile acmePath
  acmeFileOutcome <- validateCoreFile acmePath
  missingFileOutcome <- validateCoreFile "test/does-not-exist.mir.json"
  readmeOutcome <- validateCoreFile "README.md"
  nearCoreBytes <- ByteString.readFile nearCorePath
  nearCoreOutcome <- validateCoreFile nearCorePath
  -- Last, because they temporarily override the data-directory
  -- environment variable (restoring it exactly).
  overrideChecks <- schemaOverrideChecks
  pure $
    concat
      [ pointerChecks
      , normalizationChecks
      , parseChecks
      , schemaProfileChecks schemaOutcome
      , withSchema schemaOutcome $ \schema ->
          withAcme acmeBytes $ \acme ->
            concat
              [ acmeChecks schema acmeBytes acmeFileOutcome
              , mutationChecks schema acme
              , diagnosticsChecks schema acme
              , nearCoreChecks schema nearCoreBytes nearCoreOutcome
              ]
      , commandChecks missingFileOutcome readmeOutcome
      , overrideChecks
      ]

-- | Run checks that need the compiled-in schema, or fail one check.
withSchema
  :: Either SchemaLoadError CoreSchema -> (CoreSchema -> [Check]) -> [Check]
withSchema (Left failure) _ =
  [check ("compiled-in schema gates (prerequisite): " ++ show failure) False]
withSchema (Right schema) buildChecks = buildChecks schema

-- | Run checks that need the decoded Acme document, or fail one check.
withAcme :: ByteString -> (Value -> [Check]) -> [Check]
withAcme bytes buildChecks =
  case decodeValue bytes of
    Left problem ->
      [check ("Acme example decodes (prerequisite): " ++ problem) False]
    Right value -> buildChecks value

--------------------------------------------------------------------
-- JSON pointer rendering
--------------------------------------------------------------------

pointerChecks :: [Check]
pointerChecks =
  [ check
      "the root path renders as /"
      (renderJsonPointer [] == "/")
  , check
      "a plain path renders slash-separated"
      (renderJsonPointer ["actions", "0", "name"] == "/actions/0/name")
  , check
      "~ escapes to ~0"
      (renderJsonPointer ["a~b"] == "/a~0b")
  , check
      "/ escapes to ~1"
      (renderJsonPointer ["c/d"] == "/c~1d")
  , check
      "~ and / escape together"
      (renderJsonPointer ["~/"] == "/~0~1")
  , check
      "~ is escaped before /, so no double escaping occurs"
      (renderJsonPointer ["x~1y"] == "/x~01y")
  ]

--------------------------------------------------------------------
-- Violation normalization
--------------------------------------------------------------------

normalizationChecks :: [Check]
normalizationChecks =
  [ check
      "normalizing no violations yields no violations"
      (normalizeViolations [] == [])
  , check
      "violations sort by path, then by message"
      ( normalizeViolations [atB, atA2, atA1] == [atA1, atA2, atB]
      )
  , check
      "duplicate violations are removed"
      (normalizeViolations [atB, atA1, atB] == [atA1, atB])
  ]
  where
    atA1 = StructuralViolation ["a"] "first message"
    atA2 = StructuralViolation ["a"] "second message"
    atB = StructuralViolation ["b"] "first message"

--------------------------------------------------------------------
-- JSON parsing
--------------------------------------------------------------------

parseChecks :: [Check]
parseChecks =
  [ check
      "a JSON object parses"
      (isRight (parseCoreDocument "{\"a\": 1}"))
  , check
      "any syntactically valid JSON value parses (validation comes later)"
      (all (isRight . parseCoreDocument) ["null", "true", "[1, 2]", "\"s\""])
  , check
      "trailing whitespace is accepted"
      (isRight (parseCoreDocument "{}  \n"))
  , check
      "malformed JSON is rejected"
      (all (isLeft . parseCoreDocument) ["", "{", "{\"a\":}", "nul"])
  , check
      "trailing non-whitespace garbage is rejected"
      (all (isLeft . parseCoreDocument) ["{} x", "null null", "1//comment"])
  , check
      "parse failures carry a message"
      ( case parseCoreDocument "{" of
          Left failure -> not (Text.null (parseErrorMessage failure))
          Right _ -> False
      )
  , -- Provisional Aeson member semantics, documented in
    -- Mithril.Core.Validation: duplicate members are not yet
    -- rejected.  This check pins acceptance only, so a future
    -- stricter parse step must revisit it consciously; which
    -- occurrence wins is deliberately not asserted, because no winner
    -- is part of the Mithril language contract.
    check
      "duplicate object members are currently accepted (provisional)"
      (isRight (parseCoreDocument "{\"a\": 1, \"a\": 2}"))
  ]

--------------------------------------------------------------------
-- Schema profile gate
--------------------------------------------------------------------

schemaProfileChecks :: Either SchemaLoadError CoreSchema -> [Check]
schemaProfileChecks schemaOutcome =
  [ check
      "the compiled-in schema passes the profile gate"
      (isRight schemaOutcome)
  , check
      "a minimal draft 2020-12 schema passes the profile check"
      (checkSchemaValue minimalSchema == Right ())
  , -- The independent review's permissive schema: inside the keyword
    -- profile, so the profile check accepts it — but acceptance
    -- yields only (), never a CoreSchema, so it cannot be used to
    -- mint a StructurallyValid document.  bundledCoreSchema is the
    -- sole CoreSchema producer, and it is a compile-time constant.
    check
      "an in-profile permissive schema yields only () from the profile check"
      ( checkSchemaValue
          (withDraftUri ["type" .= ("object" :: Text)])
          == Right ()
      )
  , check
      "a draft-07 $schema URI is rejected"
      ( profileRejects
          (object ["$schema" .= ("http://json-schema.org/draft-07/schema#" :: Text)])
          (mentions "$schema")
      )
  , check
      "a missing root $schema is rejected"
      ( profileRejects
          (object ["type" .= ("object" :: Text)])
          (mentions "must declare \"$schema\"")
      )
  , check
      "a non-object schema root is rejected"
      (profileRejects (toJSON True) (mentions "root must be a JSON object"))
  , check
      "an unknown schema keyword is rejected"
      ( profileRejects
          (withDraftUri ["minLength" .= (3 :: Int)])
          (mentions "minLength")
      )
  , check
      "an unknown keyword nested in a properties subschema is rejected"
      ( profileRejects
          ( withDraftUri
              ["properties" .= object ["a" .= object ["frobnicate" .= (1 :: Int)]]]
          )
          (mentions "frobnicate")
      )
  , check
      "an external $ref is rejected"
      ( profileRejects
          (withDraftUri ["$ref" .= ("https://example.com/x.json" :: Text)])
          (mentions "not a local")
      )
  , check
      "an anchor $ref is rejected"
      ( profileRejects
          (withDraftUri ["$ref" .= ("#anchor" :: Text)])
          (mentions "not a local")
      )
  , check
      "an escaped $ref pointer token is rejected"
      ( profileRejects
          (withDraftUri ["$ref" .= ("#/$defs/a~0b" :: Text)])
          (mentions "escapes")
      )
  , check
      "an unresolved local $ref is rejected"
      ( profileRejects
          (withDraftUri ["$ref" .= ("#/$defs/missing" :: Text)])
          (mentions "does not resolve")
      )
  , check
      "a $ref into a non-schema position is rejected"
      ( profileRejects
          ( withDraftUri
              [ "type" .= ("object" :: Text)
              , "properties" .= object ["a" .= object ["type" .= ("string" :: Text)]]
              , "$defs" .= object ["bad" .= object ["$ref" .= ("#/properties" :: Text)]]
              ]
          )
          (mentions "does not resolve")
      )
  , check
      "an assertion sibling beside $ref is rejected"
      ( profileRejects
          ( withDraftUri
              [ "$defs"
                  .= object
                    [ "a" .= object ["type" .= ("string" :: Text)]
                    , "b"
                        .= object
                          [ "$ref" .= ("#/$defs/a" :: Text)
                          , "type" .= ("string" :: Text)
                          ]
                    ]
              ]
          )
          (mentions "beside \"$ref\"")
      )
  , check
      "a $comment sibling beside $ref is accepted"
      ( isRight
          ( checkSchemaValue
              ( withDraftUri
                  [ "$defs"
                      .= object
                        [ "a" .= object ["type" .= ("string" :: Text)]
                        , "b"
                            .= object
                              [ "$ref" .= ("#/$defs/a" :: Text)
                              , "$comment" .= ("why" :: Text)
                              ]
                        ]
                  ]
              )
          )
      )
  , check
      "properties keys that look like keywords are names, not keywords"
      ( isRight
          ( checkSchemaValue
              ( withDraftUri
                  [ "type" .= ("object" :: Text)
                  , "properties"
                      .= object
                        [ "oneOf" .= object ["type" .= ("string" :: Text)]
                        , "$ref" .= object ["type" .= ("integer" :: Text)]
                        ]
                  ]
              )
          )
      )
  , check
      "$defs keys that look like keywords are names, not keywords"
      ( isRight
          ( checkSchemaValue
              ( withDraftUri
                  [ "type" .= ("object" :: Text)
                  , "$defs" .= object ["items" .= object ["type" .= ("string" :: Text)]]
                  , "properties"
                      .= object ["x" .= object ["$ref" .= ("#/$defs/items" :: Text)]]
                  ]
              )
          )
      )
  , -- The four patterns below are copies of the four "pattern" values
    -- in core/schema.json.  They must compile through the gate's
    -- regex check; the real file is covered by the compiled-in-schema
    -- check above, which compiles every pattern it contains.
    check
      "the canonical Core v0 patterns compile through the profile gate"
      ( checkSchemaValue
          ( withDraftUri
              [ "allOf"
                  .= [object ["pattern" .= bundledPattern] | bundledPattern <- bundledPatterns]
              ]
          )
          == Right ()
      )
  , check
      "an invalid regex pattern is rejected by the profile check"
      ( profileRejects
          (withDraftUri ["pattern" .= ("[" :: Text)])
          (mentions "does not compile")
      )
  , check
      "an invalid regex nested in a subschema is rejected"
      ( profileRejects
          ( withDraftUri
              ["properties" .= object ["a" .= object ["pattern" .= ("(" :: Text)]]]
          )
          (mentions "does not compile")
      )
  , check
      "a non-string pattern is rejected"
      ( profileRejects
          (withDraftUri ["pattern" .= (1 :: Int)])
          (mentions "must be a string")
      )
  , check
      "the supported keyword inventory is pinned exactly"
      (supportedSchemaKeywords == expectedKeywordInventory)
  , -- Also pins position-awareness of the keyword walk: the
    -- compiled-in schema's property and $defs names (name, actions,
    -- ...) must not surface as keywords here.
    check
      "the compiled-in schema uses exactly the supported keyword inventory"
      (fmap usedSchemaKeywords schemaOutcome == Right supportedSchemaKeywords)
  ]
  where
    minimalSchema = object ["$schema" .= draft202012SchemaUri]
    withDraftUri members = object (("$schema" .= draft202012SchemaUri) : members)
    bundledPatterns :: [Text]
    bundledPatterns =
      [ "^[A-Z][A-Za-z0-9]*$"
      , "^[a-z][A-Za-z0-9]*$"
      , "^[a-z][A-Za-z0-9]*$"
      , "^[A-Z][A-Za-z0-9]*\\.[a-z][A-Za-z0-9]*$"
      ]
    mentions needle line = needle `Text.isInfixOf` line
    expectedKeywordInventory =
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

--------------------------------------------------------------------
-- Full checkpoint behavior on the Acme example
--------------------------------------------------------------------

acmeChecks
  :: CoreSchema
  -> ByteString
  -> Either ValidateFileError (CoreDocument Typed)
  -> [Check]
acmeChecks schema acmeBytes acmeFileOutcome =
  [ check
      "the Acme example parses"
      (isRight (parseCoreDocument acmeBytes))
  , check
      "the Acme example is structurally valid"
      ( case parseCoreDocument acmeBytes of
          Left _ -> False
          Right document -> isRight (validateCoreDocument schema document)
      )
  , check
      "validation yields the StructurallyValid stage"
      ( case parseCoreDocument acmeBytes of
          Left _ -> False
          Right document ->
            either
              (const False)
              hasStructurallyValidStage
              (validateCoreDocument schema document)
      )
  , check
      "validateCoreFile accepts the Acme example"
      (either (const False) hasTypedStage acmeFileOutcome)
  ]

-- | Compile-time witness that a value sits at the
-- 'StructurallyValid' stage; using it on a merely parsed document
-- does not typecheck.
hasStructurallyValidStage :: CoreDocument StructurallyValid -> Bool
hasStructurallyValidStage _ = True

-- | Compile-time witness that a 'validateCoreFile' success now sits
-- at the 'Typed' stage.
hasTypedStage :: CoreDocument Typed -> Bool
hasTypedStage _ = True

--------------------------------------------------------------------
-- Targeted invalid mutations (built in memory from pristine Acme)
--------------------------------------------------------------------

mutationChecks :: CoreSchema -> Value -> [Check]
mutationChecks schema acme =
  [ check
      "the unmutated Acme document is accepted (control)"
      (accepts schema acme)
  , check
      "a well-formed AnyPrincipal action is accepted (control)"
      (accepts schema (withExtraAction (anyPrincipalAction boolTrueTerm)))
  , check
      "a well-formed extra CreateEntity attribute key is accepted (control)"
      (accepts schema (withExtraAttribute "extra"))
  , -- Resource-limit gap, documented in Mithril.Core.Validation: the
    -- backend is expected to fail closed on pathological nesting, but
    -- no dedicated depth diagnostic is guaranteed — its error
    -- aggregation may surface only an outer structural violation — so
    -- this check asserts rejection only, never a message or path.
    check
      "a pathologically deep policy term does not validate (fail closed)"
      ( isLeft
          ( validateMutant
              schema
              (onKey "actions" (onIndex 0 (setKey "allow" (deeplyNestedNot 400))) acme)
          )
      )
  ]
    ++ [ check
          ("mutation rejects: " ++ name)
          (rejectsWithPrefix schema expectedPrefix (mutate acme))
       | (name, expectedPrefix, mutate) <- mutations
       ]
  where
    withExtraAction newAction = onKey "actions" (appendItem newAction) acme
    withExtraAttribute attributeName =
      onKey
        "actions"
        (onIndex 1 (onKey "effect" (onKey "attributes" (setKey attributeName unitTerm))))
        acme
    mutations :: [(String, [Text], Value -> Value)]
    mutations =
      [ ( "missing required root field 'name' [required]"
        , []
        , dropKey "name"
        )
      , ( "non-object document root [type]"
        , []
        , const (String "not a Core document")
        )
      , ( "object where the 'actions' array belongs [type]"
        , ["actions"]
        , setKey "actions" (object [])
        )
      , ( "wrong 'format' constant [const]"
        , ["format"]
        , setKey "format" (String "mithril-core-v1")
        )
      , ( "numeric 'formatVersion' instead of the string \"0\" [const]"
        , ["formatVersion"]
        , setKey "formatVersion" (toJSON (0 :: Int))
        )
      , ( "extra forbidden root property [additionalProperties]"
        , []
        , setKey "unexpected" (toJSON True)
        )
      , ( "lowercase declaration name [pattern via local $ref]"
        , ["name"]
        , setKey "name" (String "acme")
        )
      , ( "action name without the dot [pattern]"
        , ["actions", "0", "name"]
        , onKey "actions" (onIndex 0 (setKey "name" (String "ProjectRead")))
        )
      , ( "unknown principalMode value [enum]"
        , ["actions", "0", "principalMode"]
        , onKey "actions" (onIndex 0 (setKey "principalMode" (String "Anonymous")))
        )
      , ( "empty TenantIsolation.cases [minItems]"
        , ["guarantees", "1"]
        , onKey "guarantees" (onIndex 1 (setKey "cases" (toJSON ([] :: [Value]))))
        )
      , ( "empty NoSelfPrivilegeEscalation.cases [minItems]"
        , ["guarantees", "2"]
        , onKey "guarantees" (onIndex 2 (setKey "cases" (toJSON ([] :: [Value]))))
        )
      , ( "three relation endpoints [maxItems]"
        , ["schema", "relations", "0", "endpoints"]
        , onKey
            "schema"
            (onKey "relations" (onIndex 0 (onKey "endpoints" (appendItem thirdEndpoint))))
        )
      , ( "duplicate enum values [uniqueItems]"
        , ["schema", "enums", "0", "values"]
        , onKey
            "schema"
            ( onKey
                "enums"
                (onIndex 0 (setKey "values" (toJSON [String "Member", String "Member"])))
            )
        )
      , ( "unknown term constructor tag [oneOf]"
        , ["actions", "0"]
        , onKey "actions" (onIndex 0 (setKey "allow" (object ["kind" .= ("Xor" :: Text)])))
        )
      , ( "Read action with a Done result [allOf compatibility]"
        , ["actions", "0"]
        , onKey "actions" (onIndex 0 (setKey "result" (object ["kind" .= ("Done" :: Text)])))
        )
      , ( "parameter named 'actor' [not]"
        , ["actions", "0", "parameters", "0", "name"]
        , onKey
            "actions"
            (onIndex 0 (onKey "parameters" (onIndex 0 (setKey "name" (String "actor")))))
        )
      , ( "no entity named User [contains]"
        , ["schema", "entities"]
        , onKey "schema" (onKey "entities" (onIndex 0 (setKey "name" (String "Person"))))
        )
      , ( "capitalized CreateEntity attribute key [propertyNames]"
        , ["actions", "1", "effect"]
        , onKey
            "actions"
            (onIndex 1 (onKey "effect" (onKey "attributes" (setKey "BadKey" unitTerm))))
        )
      , ( "two NoSelfPrivilegeEscalation scope terms [maxItems]"
        , ["guarantees", "2"]
        , onKey
            "guarantees"
            ( onIndex
                2
                (onKey "cases" (onIndex 0 (setKey "scope" (toJSON [argumentOrganization, argumentOrganization]))))
            )
        )
      , ( "Actor inside an anonymous AnyPrincipal policy [Actor-free oneOf families]"
        , ["actions", "5"]
        , onKey "actions" (appendItem (anyPrincipalAction actorTerm))
        )
      ]

-- | A structurally valid AnyPrincipal action around the given
-- anonymous-branch policy term.  With a Bool term it must be
-- accepted; with an Actor term it must be rejected.
anyPrincipalAction :: Value -> Value
anyPrincipalAction anonymousAllow =
  object
    [ "name" .= ("Status.ping" :: Text)
    , "parameters" .= ([] :: [Value])
    , "principalMode" .= ("AnyPrincipal" :: Text)
    , "classification" .= ("Read" :: Text)
    , "allow"
        .= object
          [ "anonymous" .= anonymousAllow
          , "authenticated" .= boolTrueTerm
          ]
    , "effect" .= object ["kind" .= ("NoChange" :: Text)]
    , "result"
        .= object
          [ "kind" .= ("Observe" :: Text)
          , "entity" .= boolTrueTerm
          ]
    ]

boolTrueTerm :: Value
boolTrueTerm = object ["kind" .= ("Bool" :: Text), "value" .= True]

-- | @Not (Not (... (Bool true)))@ to the given depth: shape-correct
-- at every level, so only the backend's internal recursion bound can
-- reject it.
deeplyNestedNot :: Int -> Value
deeplyNestedNot depth = iterate wrap boolTrueTerm !! depth
  where
    wrap inner = object ["kind" .= ("Not" :: Text), "value" .= inner]

actorTerm :: Value
actorTerm = object ["kind" .= ("Actor" :: Text)]

unitTerm :: Value
unitTerm = object ["kind" .= ("Unit" :: Text)]

argumentOrganization :: Value
argumentOrganization =
  object ["kind" .= ("Argument" :: Text), "name" .= ("organization" :: Text)]

thirdEndpoint :: Value
thirdEndpoint =
  object ["name" .= ("witness" :: Text), "entity" .= ("User" :: Text)]

--------------------------------------------------------------------
-- Diagnostics: ordering, deduplication, deterministic rendering
--------------------------------------------------------------------

diagnosticsChecks :: CoreSchema -> Value -> [Check]
diagnosticsChecks schema acme =
  [ check
      "a doubly mutated document reports both violation sites"
      ( case validateMutant schema doublyMutated of
          Left violations ->
            let paths = map violationPath (NonEmpty.toList violations)
             in any (== []) paths
                  && any (\p -> ["actions", "0"] `isPrefixOf` p) paths
          Right _ -> False
      )
  , check
      "returned violations are already sorted and deduplicated"
      ( case validateMutant schema doublyMutated of
          Left violations ->
            let violationList = NonEmpty.toList violations
             in violationList == normalizeViolations violationList
          Right _ -> False
      )
  , check
      "repeated validation renders byte-identical diagnostics"
      (renderMutant doublyMutated == renderMutant doublyMutatedReordered)
  , check
      "the structural failure block renders exactly as specified"
      ( renderValidateFailure
          ( FileStructuralViolations
              "doc.mir.json"
              ( StructuralViolation ["a~b"] "first message"
                  :| [StructuralViolation ["c/d", "0"] "second message"]
              )
          )
          == Text.intercalate
            "\n"
            [ "doc.mir.json: invalid Mithril Core v0 structure"
            , "  /a~0b: first message"
            , "  /c~1d/0: second message"
            ]
      )
  ]
  where
    -- The same two independent edits, applied in both orders: the
    -- rendered diagnostics must not depend on construction order.
    doublyMutated =
      setKey "unexpected" (toJSON True) (badPrincipalMode acme)
    doublyMutatedReordered =
      badPrincipalMode (setKey "unexpected" (toJSON True) acme)
    badPrincipalMode =
      onKey "actions" (onIndex 0 (setKey "principalMode" (String "Anonymous")))
    renderMutant mutant =
      case validateMutant schema mutant of
        Left violations ->
          renderValidateFailure (FileStructuralViolations "doc.mir.json" violations)
        Right _ -> "ACCEPTED"

--------------------------------------------------------------------
-- Effectful command boundary and rendering
--------------------------------------------------------------------

commandChecks
  :: Either ValidateFileError (CoreDocument Typed)
  -> Either ValidateFileError (CoreDocument Typed)
  -> [Check]
commandChecks missingFileOutcome readmeOutcome =
  [ check
      "the success line is exactly as specified"
      ( renderValidateSuccess acmePath
          == "examples/acme/acme.mir.json: valid Mithril Core v0 through static typing"
      )
  , check
      "a missing file is classified as a read error"
      ( case missingFileOutcome of
          Left (FileReadError path _) -> path == "test/does-not-exist.mir.json"
          _ -> False
      )
  , check
      "a missing file exits with status 1"
      ( either failureExitCode (const ExitSuccess) missingFileOutcome
          == ExitFailure 1
      )
  , check
      "a missing file renders a cannot-read diagnostic"
      ( case missingFileOutcome of
          Left failure ->
            ("cannot read file" `Text.isInfixOf` renderValidateFailure failure)
          _ -> False
      )
  , check
      "an existing non-JSON file is classified as invalid JSON"
      ( case readmeOutcome of
          Left (FileParseError path _) -> path == "README.md"
          _ -> False
      )
  , check
      "invalid JSON renders the required label and exits with status 1"
      ( case readmeOutcome of
          Left failure ->
            "README.md: invalid JSON\n"
              `Text.isPrefixOf` renderValidateFailure failure
              && failureExitCode failure == ExitFailure 1
          _ -> False
      )
  , check
      "structural violations exit with status 1"
      ( failureExitCode
          ( FileStructuralViolations
              "doc.mir.json"
              (StructuralViolation [] "message" :| [])
          )
          == ExitFailure 1
      )
  , -- Internal-error classification is exercised through this pure
    -- seam: with the schema compiled in and gated at build time, the
    -- canonical public pipeline cannot construct these states, so the
    -- renderer and exit classification are pinned directly.
    check
      "internal schema errors exit with status 2"
      ( all
          (\failure -> failureExitCode (InternalSchemaError failure) == ExitFailure 2)
          [ SchemaParseError "detail"
          , SchemaProfileError ("/x: problem" :| [])
          ]
      )
  , check
      "internal schema errors render with the required prefix"
      ( all
          ( \failure ->
              "mithril: internal Core schema error: "
                `Text.isPrefixOf` renderValidateFailure (InternalSchemaError failure)
          )
          [ SchemaParseError "detail"
          , SchemaProfileError ("/x: problem" :| [])
          ]
      )
  , check
      "plain paths render verbatim"
      (displayPath "examples/acme/acme.mir.json" == "examples/acme/acme.mir.json")
  , check
      "paths with control characters render escaped"
      (displayPath "bad\npath.json" == Text.pack (show ("bad\npath.json" :: String)))
  , check
      "the empty path renders escaped"
      (displayPath "" == "\"\"")
  , check
      "diagnostics never carry raw control characters from paths"
      ( not
          ( "\n\n"
              `Text.isInfixOf` renderValidateFailure
                (FileReadError "two\nlines.json" "does not exist")
          )
      )
  ]

--------------------------------------------------------------------
-- The review's near-Core document against the canonical schema
--------------------------------------------------------------------

-- | The near-Core fixture must be rejected structurally — for the
-- missing canonical root requirements @format@, @formatVersion@, and
-- @name@ — and can therefore never reach the resolver or the
-- typechecker, let alone a @'CoreDocument' 'Typed'@, through the
-- public pipeline.
nearCoreChecks
  :: CoreSchema
  -> ByteString
  -> Either ValidateFileError (CoreDocument Typed)
  -> [Check]
nearCoreChecks schema nearCoreBytes nearCoreOutcome =
  [ check
      "the near-Core document parses as JSON (control)"
      (isRight (parseCoreDocument nearCoreBytes))
  , check
      "the near-Core document is rejected structurally, never validated"
      ( case parseCoreDocument nearCoreBytes of
          Left _ -> False
          Right document -> isLeft (validateCoreDocument schema document)
      )
  , check
      "the near-Core rejection names every missing root requirement"
      ( case parseCoreDocument nearCoreBytes of
          Left _ -> False
          Right document ->
            case validateCoreDocument schema document of
              Right _ -> False
              Left violations ->
                let rootMessages =
                      [ violationMessage violation
                      | violation <- NonEmpty.toList violations
                      , null (violationPath violation)
                      ]
                    mentioned needle =
                      any (needle `Text.isInfixOf`) rootMessages
                 in all mentioned ["format", "formatVersion", "name"]
      )
  , check
      "validateCoreFile classifies the near-Core fixture as a structural failure with exit 1"
      ( case nearCoreOutcome of
          Left failure@(FileStructuralViolations path _) ->
            path == nearCorePath && failureExitCode failure == ExitFailure 1
          _ -> False
      )
  ]

--------------------------------------------------------------------
-- Schema provenance under data-directory overrides
--------------------------------------------------------------------

-- | The review's substitution attack, pinned shut end to end: no
-- @mithril_ir_datadir@ value — nonexistent or pointing at a real
-- directory containing an in-profile permissive schema — may alter
-- the grammar validation uses, because 'bundledCoreSchema' is a
-- compile-time constant.  Under the pre-fix runtime lookup the
-- malicious half of this test minted a structurally \"valid\"
-- non-Core document; now the same setup must change nothing.
schemaOverrideChecks :: IO [Check]
schemaOverrideChecks = do
  variableBefore <- lookupEnv datadirVariable
  nonexistentOutcomes <-
    withEnvVarSet datadirVariable "test/no-such-datadir" $ do
      acmeOutcome <- validateCoreFile acmePath
      nearCoreOutcome <- validateCoreFile nearCorePath
      pure (acmeOutcome, nearCoreOutcome)
  maliciousOutcomes <-
    withPermissiveDatadir $ \datadir ->
      withEnvVarSet datadirVariable datadir $ do
        acmeOutcome <- validateCoreFile acmePath
        nearCoreFirst <- validateCoreFile nearCorePath
        nearCoreSecond <- validateCoreFile nearCorePath
        pure (acmeOutcome, nearCoreFirst, nearCoreSecond)
  restoredOutcome <- validateCoreFile acmePath
  variableAfter <- lookupEnv datadirVariable
  let (nonexistentAcme, nonexistentNearCore) = nonexistentOutcomes
      (maliciousAcme, maliciousNearCoreFirst, maliciousNearCoreSecond) =
        maliciousOutcomes
      isStructuralRejection outcome =
        case outcome of
          Left (FileStructuralViolations path _) -> path == nearCorePath
          _ -> False
      -- CoreDocument is opaque (no Eq), so determinism is compared on
      -- the rejections, which both runs must be.
      sameRejection first second =
        case (first, second) of
          (Left firstFailure, Left secondFailure) -> firstFailure == secondFailure
          _ -> False
  pure
    [ -- Control: the planted schema really is the dangerous one — it
      -- passes the profile gate (yielding only ()), so only compile-time
      -- provenance, not the gate, keeps it out of the pipeline.
      check
        "the planted permissive schema passes the profile gate (control)"
        (checkCoreSchemaProfile permissiveSchemaBytes == Right ())
    , check
        "a nonexistent datadir override does not break validation: Acme still resolves"
        (isRight nonexistentAcme)
    , check
        "a nonexistent datadir override does not weaken validation: near-Core still rejected"
        (isStructuralRejection nonexistentNearCore)
    , check
        "a malicious permissive datadir cannot alter the schema: Acme resolves against the canonical grammar"
        (isRight maliciousAcme)
    , check
        "a malicious permissive datadir cannot mint validity for the near-Core document"
        (isStructuralRejection maliciousNearCoreFirst)
    , check
        "rejection under the malicious override is deterministic"
        (sameRejection maliciousNearCoreFirst maliciousNearCoreSecond)
    , check
        "validation still succeeds after the overrides are restored"
        (isRight restoredOutcome)
    , check
        "the override helper restores the environment variable exactly"
        (variableBefore == variableAfter)
    ]

--------------------------------------------------------------------
-- Helpers: decoding, re-encoding, and in-memory JSON edits
--------------------------------------------------------------------

-- | Decode bytes to a raw 'Value' for building mutants.  Documents
-- re-enter the pipeline only through 'parseCoreDocument'.
decodeValue :: ByteString -> Either String Value
decodeValue = eitherDecodeStrict'

-- | Validate an in-memory document through the public API: the value
-- is re-encoded to bytes, parsed with 'parseCoreDocument', and
-- validated with 'validateCoreDocument'.
validateMutant
  :: CoreSchema
  -> Value
  -> Either (NonEmpty StructuralViolation) (CoreDocument StructurallyValid)
validateMutant schema value =
  case parseCoreDocument (LazyByteString.toStrict (encode value)) of
    Left failure ->
      Left
        ( StructuralViolation
            []
            ("re-encoded mutant failed to parse: " <> parseErrorMessage failure)
            :| []
        )
    Right document -> validateCoreDocument schema document

-- | Run an in-memory schema through the public profile check.  On
-- success this yields only (): arbitrary schemas can be probed but
-- never turned into a 'CoreSchema'.
checkSchemaValue :: Value -> Either SchemaLoadError ()
checkSchemaValue = checkCoreSchemaProfile . LazyByteString.toStrict . encode

-- | The document is accepted by the schema.
accepts :: CoreSchema -> Value -> Bool
accepts schema value = isRight (validateMutant schema value)

-- | The document is rejected, with at least one violation under the
-- expected path prefix (attribution of the mutation).
rejectsWithPrefix :: CoreSchema -> [Text] -> Value -> Bool
rejectsWithPrefix schema expectedPrefix value =
  case validateMutant schema value of
    Left violations ->
      any
        (\violation -> expectedPrefix `isPrefixOf` violationPath violation)
        (NonEmpty.toList violations)
    Right _ -> False

-- | A schema profile rejection with at least one problem line
-- satisfying the predicate.
profileRejects :: Value -> (Text -> Bool) -> Bool
profileRejects candidate holds =
  case checkSchemaValue candidate of
    Left (SchemaProfileError problems) -> any holds (NonEmpty.toList problems)
    _ -> False

-- | Apply a function to the value of an object member, if present.
onKey :: Text -> (Value -> Value) -> Value -> Value
onKey name adjust value =
  case value of
    Object members ->
      case KeyMap.lookup (Key.fromText name) members of
        Just inner ->
          Object (KeyMap.insert (Key.fromText name) (adjust inner) members)
        Nothing -> value
    _ -> value

-- | Insert or replace an object member.
setKey :: Text -> Value -> Value -> Value
setKey name new value =
  case value of
    Object members -> Object (KeyMap.insert (Key.fromText name) new members)
    _ -> value

-- | Delete an object member.
dropKey :: Text -> Value -> Value
dropKey name value =
  case value of
    Object members -> Object (KeyMap.delete (Key.fromText name) members)
    _ -> value

-- | Apply a list transformation to an array value.
overList :: ([Value] -> [Value]) -> Value -> Value
overList adjust value =
  case value of
    Array _ ->
      case fromJSON value of
        Success items -> toJSON (adjust (items :: [Value]))
        Error _ -> value
    _ -> value

-- | Apply a function to one array element.
onIndex :: Int -> (Value -> Value) -> Value -> Value
onIndex index adjust = overList (zipWith apply [0 ..])
  where
    apply position item = if position == index then adjust item else item

-- | Append one array element.
appendItem :: Value -> Value -> Value
appendItem item = overList (<> [item])
