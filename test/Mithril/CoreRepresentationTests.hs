{-# LANGUAGE OverloadedStrings #-}

-- | Black-box checks over the explicit resolved-representation
-- milestone, exercised exclusively through the public library API: a
-- successfully resolved document is carried as the internal decoded
-- and name-resolved Core model, constructed by the real
-- @parse -> validate -> resolve@ pipeline.
--
-- This module deliberately stays on the public side of the package
-- boundary — the view any downstream consumer has, where the
-- representation modules cannot be imported (pinned by the downstream
-- compile-fail probes).  What it can observe from there is pipeline
-- behavior: the full-coverage fixture
-- (@test\/fixtures\/coverage.mir.json@) pushes every Core v0
-- constructor family — the actor-available families
-- (@AuthenticatedOnly@ bodies, authenticated branches, guarantee
-- terms) and the actor-free families (@AnyPrincipal@ anonymous
-- branches, effects, and results) — through parsing, structural
-- validation, and name resolution successfully, and reference sites
-- that only this fixture exercises (an arity-one authority relation,
-- actor-free initializer keys, actor-free effect terms) get targeted
-- unknown-name regressions with exact paths and messages.  The
-- successful model's /content/ — identifiers, owners, retained
-- source paths, and cross-run determinism — is inspected by
-- "Mithril.CoreModelTests", which reaches the real internal model
-- through the package-private @core-internal@ sublibrary instead of
-- weakening this public boundary.
--
-- The fixture also bakes in deliberately ill-typed but well-named
-- constructs (a lookup passing two endpoint terms — the second a
-- @Bool@ literal — to the arity-one relation @Flagged@, an unordered
-- @payloadOrder@ enum, incompatible comparison operands), so its
-- acceptance by resolution is a regression that constructing the
-- representation adds no typechecking — while the file-level
-- pipeline, which now continues into static typing, must reject it
-- with type violations, never name-resolution ones (the exact
-- violation list is pinned in "Mithril.CoreTypingTests" and at the
-- process level).
module Mithril.CoreRepresentationTests
  ( tests
  ) where

import Data.Aeson
  ( Result (..)
  , Value (..)
  , eitherDecodeStrict'
  , encode
  , fromJSON
  , toJSON
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)

import Mithril.Command.Validate
  ( ValidateFileError (..)
  , validateCoreFile
  )
import Mithril.Core.Normalization (Normalized)
import Mithril.Core.Resolution
  ( ResolutionFailure (..)
  , ResolutionViolation (..)
  , Resolved
  , resolveCoreDocument
  )
import Mithril.Core.Validation
  ( CoreDocument
  , CoreSchema
  , SchemaLoadError
  , bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Test (Check, check)

-- | The full-coverage fixture: structurally valid, resolvable, and
-- exercising every Core v0 constructor family.
coveragePath :: FilePath
coveragePath = "test/fixtures/coverage.mir.json"

-- | All representation checks.  The file reads assume the test
-- process runs from the package root, which is how @cabal test@ runs
-- it.
tests :: IO [Check]
tests = do
  let schemaOutcome = bundledCoreSchema
  coverageBytes <- ByteString.readFile coveragePath
  fileOutcome <- validateCoreFile coveragePath
  pure $
    concat
      [ fileChecks fileOutcome
      , withSchema schemaOutcome $ \schema ->
          withCoverage coverageBytes $ \coverage ->
            concat
              [ coverageChecks schema coverageBytes coverage
              , referenceChecks schema coverage
              ]
      ]

-- | Run checks that need the compiled-in schema, or fail one check.
withSchema
  :: Either SchemaLoadError CoreSchema -> (CoreSchema -> [Check]) -> [Check]
withSchema (Left failure) _ =
  [check ("compiled-in schema gates (prerequisite): " ++ show failure) False]
withSchema (Right schema) buildChecks = buildChecks schema

-- | Run checks that need the decoded coverage document, or fail one
-- check.
withCoverage :: ByteString -> (Value -> [Check]) -> [Check]
withCoverage bytes buildChecks =
  case eitherDecodeStrict' bytes of
    Left problem ->
      [check ("coverage fixture decodes (prerequisite): " ++ problem) False]
    Right value -> buildChecks value

--------------------------------------------------------------------
-- The complete public pipeline over the coverage fixture
--------------------------------------------------------------------

fileChecks :: Either ValidateFileError (CoreDocument Normalized) -> [Check]
fileChecks fileOutcome =
  [ check
      "the coverage fixture reaches static typing through the file pipeline and is rejected there"
      ( case fileOutcome of
          Left (FileTypeViolations _ _) -> True
          _ -> False
      )
  ]

coverageChecks :: CoreSchema -> ByteString -> Value -> [Check]
coverageChecks schema coverageBytes coverage =
  [ check
      "the coverage fixture resolves through the in-memory pipeline (control)"
      (resolves schema coverage)
  , check
      "the coverage fixture resolves stepwise through parse, validate, and resolve"
      ( case parseCoreDocument coverageBytes of
          Left _ -> False
          Right document ->
            case validateCoreDocument schema document of
              Left _ -> False
              Right validDocument ->
                either
                  (const False)
                  (const True)
                  (resolveCoreDocument validDocument)
      )
  , -- The fixture deliberately contains ill-typed but well-named
    -- constructs: a Lookup passing two endpoint terms (an Argument of
    -- Bool parameter type, then a Bool literal) to the arity-one
    -- relation "Flagged", an unordered payloadOrder enum ("Badge"),
    -- and Equal/None operand mismatches.  Accepting it pins that
    -- resolution performs no typechecking; the white-box model checks
    -- confirm the two endpoint terms really reach the resolved model
    -- against that one-endpoint relation.
    check
      "resolves although ill-typed: coverage's arity, operand, and order mismatches"
      (resolves schema coverage)
  ]

--------------------------------------------------------------------
-- Reference categories only the coverage fixture exercises
--------------------------------------------------------------------

referenceChecks :: CoreSchema -> Value -> [Check]
referenceChecks schema coverage =
  [ referenceCheck
      "a subject endpoint on an arity-one authority relation"
      (onGuarantee 3 (onKey "authority" (setKey "subjectEndpoint" (String "ghost"))))
      ["guarantees", "3", "authority", "subjectEndpoint"]
      "unknown endpoint \"ghost\" in relation \"Flagged\""
  , referenceCheck
      "an actor-free CreateEntity initializer key"
      (onAction 7 (onKey "effect" (onKey "attributes" (renameKey "owner" "ghost"))))
      ["actions", "7", "effect", "attributes", "ghost"]
      "unknown attribute \"ghost\" in entity \"Organization\""
  , referenceCheck
      "an actor-free RemoveRelation endpoint argument"
      ( onAction 10
          (onKey "effect" (onKey "endpoints" (onIndex 0 (setKey "name" (String "ghost")))))
      )
      ["actions", "10", "effect", "endpoints", "0", "name"]
      "unknown parameter \"ghost\" in action \"User.unmark\""
  , referenceCheck
      "an actor-free SetRelation enum payload value"
      (onAction 8 (onKey "effect" (onKey "payload" (setKey "value" (String "Boss")))))
      ["actions", "8", "effect", "payload", "value"]
      "unknown value \"Boss\" in enum \"Level\""
  , referenceCheck
      "an enum-order member of the coverage Level enum"
      (onEnum 0 (setKey "order" (toJSON [String "Low", String "Boss"])))
      ["schema", "enums", "0", "order", "1"]
      "unknown value \"Boss\" in enum \"Level\""
  , referenceCheck
      "an argument nested in the actor-free anonymous branch"
      ( onAction 6
          ( onKey "allow"
              ( onKey "anonymous"
                  ( onKey "left"
                      ( onKey "right"
                          ( onKey "value"
                              ( onKey "value"
                                  (onKey "endpoints" (onIndex 0 (setKey "name" (String "ghost"))))
                              )
                          )
                      )
                  )
              )
          )
      )
      ["actions", "6", "allow", "anonymous", "left", "right", "value", "value", "endpoints", "0", "name"]
      "unknown parameter \"ghost\" in action \"Status.ping\""
  ]
  where
    referenceCheck description mutate expectedPath expectedMessage =
      check
        ("unknown reference (coverage): " ++ description)
        (rejectsExactly schema (mutate coverage) [(expectedPath, expectedMessage)])

--------------------------------------------------------------------
-- Pipeline helpers (mirroring Mithril.CoreResolutionTests)
--------------------------------------------------------------------

-- | Push an in-memory document through the real public pipeline:
-- re-encode, parse, structurally validate, then resolve.  'Nothing'
-- means the mutant never reached resolution.
resolveMutant
  :: CoreSchema
  -> Value
  -> Maybe (Either ResolutionFailure (CoreDocument Resolved))
resolveMutant schema value =
  case parseCoreDocument (LazyByteString.toStrict (encode value)) of
    Left _ -> Nothing
    Right document ->
      case validateCoreDocument schema document of
        Left _ -> Nothing
        Right validDocument -> Just (resolveCoreDocument validDocument)

-- | The mutant is structurally valid and resolves.
resolves :: CoreSchema -> Value -> Bool
resolves schema value =
  case resolveMutant schema value of
    Just (Right _) -> True
    _ -> False

-- | The mutant's semantic resolution violations, if it was
-- structurally valid and semantically rejected.
violationsOf :: CoreSchema -> Value -> Maybe [ResolutionViolation]
violationsOf schema value =
  case resolveMutant schema value of
    Just (Left (ResolutionViolations violations)) ->
      Just (NonEmpty.toList violations)
    _ -> Nothing

-- | The mutant is structurally valid and rejected with exactly the
-- expected violations, in the expected (sorted) order.
rejectsExactly :: CoreSchema -> Value -> [([Text], Text)] -> Bool
rejectsExactly schema value expected =
  violationsOf schema value
    == Just [ResolutionViolation path message | (path, message) <- expected]

--------------------------------------------------------------------
-- In-memory JSON edits (mirroring Mithril.CoreResolutionTests)
--------------------------------------------------------------------

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

-- | Move a member to a new key, keeping its value.
renameKey :: Text -> Text -> Value -> Value
renameKey from to value =
  case value of
    Object members ->
      case KeyMap.lookup (Key.fromText from) members of
        Just inner ->
          Object
            ( KeyMap.insert
                (Key.fromText to)
                inner
                (KeyMap.delete (Key.fromText from) members)
            )
        Nothing -> value
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

-- Coverage-shaped shorthands.

onAction :: Int -> (Value -> Value) -> Value -> Value
onAction index adjust = onKey "actions" (onIndex index adjust)

onEnum :: Int -> (Value -> Value) -> Value -> Value
onEnum index adjust = onKey "schema" (onKey "enums" (onIndex index adjust))

onGuarantee :: Int -> (Value -> Value) -> Value -> Value
onGuarantee index adjust = onKey "guarantees" (onIndex index adjust)
