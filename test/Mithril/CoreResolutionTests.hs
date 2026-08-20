{-# LANGUAGE OverloadedStrings #-}

-- | Checks over the name-resolution boundary: "Mithril.Core.Resolution"
-- and its integration in "Mithril.Command.Validate".
--
-- Everything goes through the production API — documents enter via
-- 'parseCoreDocument', the only obtainable schema is the compiled-in
-- canonical one ('bundledCoreSchema'), structural validation gates
-- every mutant, and resolution runs through 'resolveCoreDocument'; no
-- resolver logic is duplicated here.  Mutants are built in memory
-- from the pristine Acme example and re-encoded, and the normative
-- schema and example are never modified.  Every mutant used for a
-- resolution expectation must first pass structural validation, so
-- these checks cannot silently degrade into structural rejections.
--
-- The resolver's internal fail-closed classification
-- ('ResolverInvariantViolations', exit 2) is unit-tested in
-- 'renderingChecks' through its pure seam.  It is deliberately no
-- longer demonstrated through the public pipeline: the schema is a
-- compile-time constant, so no runtime substitution can push a
-- structurally invalid document into the resolver — that closure is
-- pinned by the schema-provenance regressions in
-- "Mithril.CoreValidationTests" and by the process-level CLI tests.
module Mithril.CoreResolutionTests
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
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))

import Mithril.Command.Validate
  ( ValidateFileError (..)
  , failureExitCode
  , renderValidateFailure
  , renderValidateSuccess
  , validateCoreFile
  )
import Mithril.Core.Resolution
  ( ResolutionFailure (..)
  , ResolutionViolation (..)
  , Resolved
  , ResolverInvariantViolation (..)
  , normalizeResolutionViolations
  , resolveCoreDocument
  )
import Mithril.Core.Normalization (Normalized)
import Mithril.Core.Validation
  ( CoreDocument
  , CoreSchema
  , SchemaLoadError
  , bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Test (Check, check)

-- | The handwritten example every mutant starts from.
acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

-- | All resolution checks.  The file reads assume the test process
-- runs from the package root, which is how @cabal test@ runs it.
tests :: IO [Check]
tests = do
  let schemaOutcome = bundledCoreSchema
  acmeBytes <- ByteString.readFile acmePath
  acmeFileOutcome <- validateCoreFile acmePath
  pure $
    concat
      [ normalizationChecks
      , withSchema schemaOutcome $ \schema ->
          withAcme acmeBytes $ \acme ->
            concat
              [ acmeResolutionChecks schema acmeBytes acmeFileOutcome
              , reuseChecks schema acme
              , coverageChecks schema acme
              , duplicateChecks schema acme
              , unknownReferenceChecks schema acme
              , noCascadeChecks schema acme
              , separationChecks schema acme
              , renderingChecks schema acme
              ]
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
  case eitherDecodeStrict' bytes of
    Left problem ->
      [check ("Acme example decodes (prerequisite): " ++ problem) False]
    Right value -> buildChecks value

--------------------------------------------------------------------
-- Violation normalization
--------------------------------------------------------------------

normalizationChecks :: [Check]
normalizationChecks =
  [ check
      "normalizing no violations yields no violations"
      (normalizeResolutionViolations [] == [])
  , check
      "violations sort by path, then by message"
      (normalizeResolutionViolations [atB, atA2, atA1] == [atA1, atA2, atB])
  , check
      "duplicate violations are removed"
      (normalizeResolutionViolations [atB, atA1, atB] == [atA1, atB])
  ]
  where
    atA1 = ResolutionViolation ["a"] "first message"
    atA2 = ResolutionViolation ["a"] "second message"
    atB = ResolutionViolation ["b"] "first message"

--------------------------------------------------------------------
-- The pristine Acme example through the full pipeline
--------------------------------------------------------------------

acmeResolutionChecks
  :: CoreSchema
  -> ByteString
  -> Either ValidateFileError (CoreDocument Normalized)
  -> [Check]
acmeResolutionChecks schema acmeBytes acmeFileOutcome =
  [ check
      "the public pipeline reaches a CoreDocument Resolved witness on Acme"
      ( case parseCoreDocument acmeBytes of
          Left _ -> False
          Right document ->
            case validateCoreDocument schema document of
              Left _ -> False
              Right validDocument ->
                either
                  (const False)
                  hasResolvedStage
                  (resolveCoreDocument validDocument)
      )
  , check
      "validateCoreFile resolves (and then typechecks and normalizes) the Acme example"
      (either (const False) hasNormalizedStage acmeFileOutcome)
  , check
      "the success line is exactly as specified"
      ( renderValidateSuccess acmePath
          == "examples/acme/acme.mir.json: valid Mithril Core v0 through normalization"
      )
  ]

-- | Compile-time witness that a value sits at the 'Resolved' stage;
-- using it on a merely structurally valid document does not
-- typecheck.
hasResolvedStage :: CoreDocument Resolved -> Bool
hasResolvedStage _ = True

-- | Compile-time witness that the file boundary now ends at the
-- 'Normalized' stage; using it on a merely resolved or typed
-- document does not typecheck.
hasNormalizedStage :: CoreDocument Normalized -> Bool
hasNormalizedStage _ = True

--------------------------------------------------------------------
-- Name reuse that must be accepted
--------------------------------------------------------------------

reuseChecks :: CoreSchema -> Value -> [Check]
reuseChecks schema acme =
  [ check
      "the unmutated Acme document resolves (control)"
      (resolves schema acme)
  , check
      "one text may name declarations in different global namespaces"
      ( resolves
          schema
          ( appendEnum (enumDecl "Project" ["Solo"])
              (appendRelation projectRelation acme)
          )
      )
  , check
      "local names may be reused under different entities, relations, and actions"
      ( resolves
          schema
          ( onEntity 1 (setKey "attributes" (toJSON [attributeDecl "organization" boolType]))
              ( appendRelation taggingRelation
                  (appendAction (readProbeAction "Status.ping" [parameterDecl "project" boolType]) acme)
              )
          )
      )
  ]
  where
    projectRelation =
      relationDecl "Project" [endpointDecl "user" "User"] unitType
    taggingRelation =
      relationDecl
        "Tagging"
        [endpointDecl "user" "User", endpointDecl "organization" "Organization"]
        unitType

--------------------------------------------------------------------
-- Constructor coverage
--------------------------------------------------------------------

coverageChecks :: CoreSchema -> Value -> [Check]
coverageChecks schema acme =
  [ check
      "an AnyPrincipal action with Or, Unit, IsSome, Lookup, and Not resolves (control)"
      (resolves schema (appendAction (anyPrincipalProbe goodAnonymous goodAuthenticated) acme))
  , check
      "the anonymous AnyPrincipal branch is inspected"
      ( rejectsExactly
          schema
          (appendAction (anyPrincipalProbe badAnonymous goodAuthenticated) acme)
          [
            ( ["actions", "5", "allow", "anonymous", "left", "name"]
            , "unknown parameter \"ghost\" in action \"Status.ping\""
            )
          ]
      )
  , check
      "the authenticated AnyPrincipal branch is inspected"
      ( rejectsExactly
          schema
          (appendAction (anyPrincipalProbe goodAnonymous badAuthenticated) acme)
          [
            ( ["actions", "5", "allow", "authenticated", "value", "name"]
            , "unknown parameter \"ghost\" in action \"Status.ping\""
            )
          ]
      )
  , check
      "a RemoveRelation effect resolves (control)"
      ( resolves
          schema
          ( onAction 3
              (setKey "effect" (removeRelationEffect "Membership"))
              acme
          )
      )
  , check
      "a nested attribute chain resolves through declared EntityRef attributes"
      ( resolves
          schema
          ( onEntity 1
              (setKey "attributes" (toJSON [attributeDecl "owner" (entityRefType "User")]))
              (onAction 0 (setProjectLookupTarget ownerChain) acme)
          )
      )
  ]
  where
    goodAnonymous = orTerm (argumentTerm "flag") boolFalseTerm
    badAnonymous = orTerm (argumentTerm "ghost") boolFalseTerm
    goodAuthenticated =
      andTerm
        (isSomeTerm (lookupTerm "Membership" [actorTerm]))
        (notTerm boolFalseTerm)
    badAuthenticated = isSomeTerm (argumentTerm "ghost")
    ownerChain =
      attributeTerm
        (attributeTerm (argumentTerm "project") "organization")
        "owner"

--------------------------------------------------------------------
-- Duplicate declarations
--------------------------------------------------------------------

duplicateChecks :: CoreSchema -> Value -> [Check]
duplicateChecks schema acme =
  [ check
      "a duplicate entity name is reported at the later occurrence"
      ( rejectsExactly
          schema
          (appendEntity (entityDecl "Project" []) acme)
          [
            ( ["schema", "entities", "3", "name"]
            , "duplicate entity name \"Project\" (first declared at /schema/entities/2/name)"
            )
          ]
      )
  , check
      "a duplicate enum name is reported without value-error cascades"
      ( rejectsExactly
          schema
          (appendEnum (enumDecl "MembershipRole" ["Zeta"]) acme)
          [
            ( ["schema", "enums", "1", "name"]
            , "duplicate enum name \"MembershipRole\" (first declared at /schema/enums/0/name)"
            )
          ]
      )
  , check
      "a duplicate relation name is reported without dependent errors"
      ( rejectsExactly
          schema
          ( appendRelation
              (relationDecl "Membership" [endpointDecl "peer" "User"] unitType)
              acme
          )
          [
            ( ["schema", "relations", "1", "name"]
            , "duplicate relation name \"Membership\" (first declared at /schema/relations/0/name)"
            )
          ]
      )
  , check
      "a duplicate action name is reported at the later occurrence"
      ( rejectsExactly
          schema
          (appendAction (readProbeAction "Project.read" []) acme)
          [
            ( ["actions", "5", "name"]
            , "duplicate action name \"Project.read\" (first declared at /actions/0/name)"
            )
          ]
      )
  , check
      "a duplicate attribute within one entity is reported"
      ( rejectsExactly
          schema
          ( onEntity 2
              (onKey "attributes" (appendItem (attributeDecl "organization" boolType)))
              acme
          )
          [
            ( ["schema", "entities", "2", "attributes", "1", "name"]
            , "duplicate attribute name \"organization\" in entity \"Project\"\
              \ (first declared at /schema/entities/2/attributes/0/name)"
            )
          ]
      )
  , check
      "a duplicate endpoint within one relation is reported"
      ( rejectsExactly
          schema
          ( appendRelation
              ( relationDecl
                  "Tagging"
                  [endpointDecl "user" "User", endpointDecl "user" "User"]
                  unitType
              )
              acme
          )
          [
            ( ["schema", "relations", "1", "endpoints", "1", "name"]
            , "duplicate endpoint name \"user\" in relation \"Tagging\"\
              \ (first declared at /schema/relations/1/endpoints/0/name)"
            )
          ]
      )
  , check
      "a duplicate parameter within one action is reported without body cascades"
      ( rejectsExactly
          schema
          ( onAction 0
              (onKey "parameters" (appendItem (parameterDecl "project" boolType)))
              acme
          )
          [
            ( ["actions", "0", "parameters", "1", "name"]
            , "duplicate parameter name \"project\" in action \"Project.read\"\
              \ (first declared at /actions/0/parameters/0/name)"
            )
          ]
      )
  ]

--------------------------------------------------------------------
-- Unknown references, per category and scope
--------------------------------------------------------------------

unknownReferenceChecks :: CoreSchema -> Value -> [Check]
unknownReferenceChecks schema acme =
  [ referenceCheck
      "an attribute type's enum reference"
      (onEntity 2 (onKey "attributes" (appendItem (attributeDecl "level" (enumType "Missing")))))
      ["schema", "entities", "2", "attributes", "1", "type", "enum"]
      "unknown enum \"Missing\""
  , referenceCheck
      "an attribute type's entity reference"
      (onEntity 2 (onKey "attributes" (appendItem (attributeDecl "peer" (entityRefType "Ghost")))))
      ["schema", "entities", "2", "attributes", "1", "type", "entity"]
      "unknown entity \"Ghost\""
  , referenceCheck
      "a relation endpoint's entity reference"
      (onRelation 0 (onKey "endpoints" (onIndex 1 (setKey "entity" (String "Ghost")))))
      ["schema", "relations", "0", "endpoints", "1", "entity"]
      "unknown entity \"Ghost\""
  , referenceCheck
      "a relation payload's enum reference"
      (onRelation 0 (setKey "payload" (enumType "Ghost")))
      ["schema", "relations", "0", "payload", "enum"]
      "unknown enum \"Ghost\""
  , referenceCheck
      "an enum order member"
      (onEnum 0 (setKey "order" (toJSON [String "Member", String "Boss"])))
      ["schema", "enums", "0", "order", "1"]
      "unknown value \"Boss\" in enum \"MembershipRole\""
  , referenceCheck
      "an action parameter type's enum reference"
      (onAction 0 (onKey "parameters" (appendItem (parameterDecl "extra" (enumType "Ghost")))))
      ["actions", "0", "parameters", "1", "type", "enum"]
      "unknown enum \"Ghost\""
  , referenceCheck
      "an action parameter type's entity reference"
      (onAction 0 (onKey "parameters" (appendItem (parameterDecl "extra" (entityRefType "Ghost")))))
      ["actions", "0", "parameters", "1", "type", "entity"]
      "unknown entity \"Ghost\""
  , referenceCheck
      "an Enum term's value against its enum"
      (onAction 0 (onKey "allow" (onKey "left" (onKey "value" (setKey "value" (String "Boss"))))))
      ["actions", "0", "allow", "left", "value", "value"]
      "unknown value \"Boss\" in enum \"MembershipRole\""
  , referenceCheck
      "an Argument reference in an allow policy"
      ( onAction 0
          (onKey "allow" (onKey "right" (onKey "endpoints" (onIndex 1 (onKey "source" (setKey "name" (String "ghost")))))))
      )
      ["actions", "0", "allow", "right", "endpoints", "1", "source", "name"]
      "unknown parameter \"ghost\" in action \"Project.read\""
  , referenceCheck
      "an Argument reference in an effect"
      ( onAction 1
          (onKey "effect" (onKey "attributes" (onKey "organization" (setKey "name" (String "ghost")))))
      )
      ["actions", "1", "effect", "attributes", "organization", "name"]
      "unknown parameter \"ghost\" in action \"Project.create\""
  , referenceCheck
      "an Argument reference in a result"
      (onAction 0 (onKey "result" (onKey "entity" (setKey "name" (String "ghost")))))
      ["actions", "0", "result", "entity", "name"]
      "unknown parameter \"ghost\" in action \"Project.read\""
  , referenceCheck
      "a Lookup term's relation reference"
      (onAction 0 (onKey "allow" (onKey "right" (setKey "relation" (String "Ghost")))))
      ["actions", "0", "allow", "right", "relation"]
      "unknown relation \"Ghost\""
  , referenceCheck
      "a SetRelation effect's relation reference"
      (onAction 3 (onKey "effect" (setKey "relation" (String "Ghost"))))
      ["actions", "3", "effect", "relation"]
      "unknown relation \"Ghost\""
  , referenceCheck
      "a RemoveRelation effect's relation reference"
      (onAction 3 (setKey "effect" (removeRelationEffect "Ghost")))
      ["actions", "3", "effect", "relation"]
      "unknown relation \"Ghost\""
  , referenceCheck
      "a None term's payload enum reference"
      ( onAction 3
          (onKey "allow" (onKey "right" (onKey "right" (onKey "payloadType" (setKey "enum" (String "Ghost"))))))
      )
      ["actions", "3", "allow", "right", "right", "payloadType", "enum"]
      "unknown enum \"Ghost\""
  , referenceCheck
      "a CreateEntity effect's target entity"
      (onAction 1 (onKey "effect" (setKey "entity" (String "Ghost"))))
      ["actions", "1", "effect", "entity"]
      "unknown entity \"Ghost\""
  , referenceCheck
      "a CreateEntity initializer key against the target entity"
      (onAction 1 (onKey "effect" (onKey "attributes" (renameKey "organization" "ghost"))))
      ["actions", "1", "effect", "attributes", "ghost"]
      "unknown attribute \"ghost\" in entity \"Project\""
  , referenceCheck
      "an Attribute projection member"
      (onAction 0 (onKey "allow" (onKey "right" (onKey "endpoints" (onIndex 1 (setKey "attribute" (String "ghost")))))))
      ["actions", "0", "allow", "right", "endpoints", "1", "attribute"]
      "unknown attribute \"ghost\" in entity \"Project\""
  , referenceCheck
      "a nested Attribute projection member on the projected entity"
      (onAction 0 (setProjectLookupTarget bogusOuterChain))
      ["actions", "0", "allow", "right", "endpoints", "1", "attribute"]
      "unknown attribute \"bogus\" in entity \"Organization\""
  , referenceCheck
      "an Attribute projection whose source is a known non-entity"
      ( onAction 0
          (onKey "allow" (onKey "right" (onKey "endpoints" (onIndex 1 (setKey "source" boolTrueTerm)))))
      )
      ["actions", "0", "allow", "right", "endpoints", "1", "attribute"]
      "cannot select an attribute namespace for \"organization\":\
      \ the source term does not denote an entity reference"
  , referenceCheck
      "a TenantIsolation case term in the referenced action's environment"
      ( onGuarantee 1
          (onKey "cases" (onIndex 0 (onKey "tenant" (onKey "source" (setKey "name" (String "ghost"))))))
      )
      ["guarantees", "1", "cases", "0", "tenant", "source", "name"]
      "unknown parameter \"ghost\" in action \"Project.read\""
  , referenceCheck
      "a NoSelfPrivilegeEscalation subject endpoint"
      (onGuarantee 2 (onKey "authority" (setKey "subjectEndpoint" (String "ghost"))))
      ["guarantees", "2", "authority", "subjectEndpoint"]
      "unknown endpoint \"ghost\" in relation \"Membership\""
  , referenceCheck
      "a NoSelfPrivilegeEscalation scope endpoint"
      (onGuarantee 2 (onKey "authority" (setKey "scopeEndpoints" (toJSON [String "ghost"]))))
      ["guarantees", "2", "authority", "scopeEndpoints", "0"]
      "unknown endpoint \"ghost\" in relation \"Membership\""
  , referenceCheck
      "a NoSelfPrivilegeEscalation payload order enum"
      (onGuarantee 2 (onKey "authority" (setKey "payloadOrder" (String "Ghost"))))
      ["guarantees", "2", "authority", "payloadOrder"]
      "unknown enum \"Ghost\""
  , referenceCheck
      "a NoSelfPrivilegeEscalation case scope term"
      ( onGuarantee 2
          (onKey "cases" (onIndex 0 (onKey "scope" (onIndex 0 (setKey "name" (String "ghost"))))))
      )
      ["guarantees", "2", "cases", "0", "scope", "0", "name"]
      "unknown parameter \"ghost\" in action \"Membership.changeRole\""
  , check
      "independent problems aggregate, sorted by path"
      ( rejectsExactly
          schema
          ( appendEntity
              (entityDecl "Project" [])
              ( onAction 0
                  (onKey "allow" (onKey "left" (onKey "value" (setKey "enum" (String "Ghost")))))
                  (onGuarantee 2 (onKey "authority" (setKey "payloadOrder" (String "Ghost2"))) acme)
              )
          )
          [ (["actions", "0", "allow", "left", "value", "enum"], "unknown enum \"Ghost\"")
          , (["guarantees", "2", "authority", "payloadOrder"], "unknown enum \"Ghost2\"")
          ,
            ( ["schema", "entities", "3", "name"]
            , "duplicate entity name \"Project\" (first declared at /schema/entities/2/name)"
            )
          ]
      )
  ]
  where
    referenceCheck description mutate expectedPath expectedMessage =
      check
        ("unknown reference: " ++ description)
        (rejectsExactly schema (mutate acme) [(expectedPath, expectedMessage)])
    bogusOuterChain =
      attributeTerm
        (attributeTerm (argumentTerm "project") "organization")
        "bogus"

--------------------------------------------------------------------
-- Root problems must not cascade
--------------------------------------------------------------------

noCascadeChecks :: CoreSchema -> Value -> [Check]
noCascadeChecks schema acme =
  [ check
      "an unknown enum suppresses the dependent enum-value check"
      ( rejectsExactly
          schema
          (onAction 0 (onKey "allow" (onKey "left" (onKey "value" (setKey "enum" (String "Ghost"))))) acme)
          [(["actions", "0", "allow", "left", "value", "enum"], "unknown enum \"Ghost\"")]
      )
  , check
      "an unknown authority relation suppresses dependent endpoint checks"
      ( rejectsExactly
          schema
          (onGuarantee 2 (onKey "authority" (setKey "relation" (String "Ghost"))) acme)
          [(["guarantees", "2", "authority", "relation"], "unknown relation \"Ghost\"")]
      )
  , check
      "an unknown guarantee action suppresses dependent parameter checks"
      ( rejectsExactly
          schema
          (onGuarantee 1 (onKey "cases" (onIndex 0 (setKey "action" (String "Ghost.read")))) acme)
          [(["guarantees", "1", "cases", "0", "action"], "unknown action \"Ghost.read\"")]
      )
  , check
      "a duplicated guarantee action suppresses dependent parameter checks"
      ( rejectsExactly
          schema
          (appendAction (readProbeAction "Membership.changeRole" []) acme)
          [
            ( ["actions", "5", "name"]
            , "duplicate action name \"Membership.changeRole\" (first declared at /actions/4/name)"
            )
          ]
      )
  , check
      "a failed inner attribute suppresses the dependent outer member check"
      ( rejectsExactly
          schema
          (onAction 0 (setProjectLookupTarget bogusInnerChain) acme)
          [
            ( ["actions", "0", "allow", "right", "endpoints", "1", "source", "attribute"]
            , "unknown attribute \"bogus\" in entity \"Project\""
            )
          ]
      )
  ]
  where
    bogusInnerChain =
      attributeTerm (attributeTerm (argumentTerm "project") "bogus") "owner"

--------------------------------------------------------------------
-- Resolution/typechecking separation
--------------------------------------------------------------------

-- | Structurally valid documents with no missing or ambiguous names
-- that are intentionally ill-typed: resolution must accept every one
-- of them, because the checks they violate belong to the static
-- typechecker — a separate later stage.  The paired regressions in
-- "Mithril.CoreTypingTests" pin that the typechecker then rejects
-- each of these same mutants, with exact paths and messages.
separationChecks :: CoreSchema -> Value -> [Check]
separationChecks schema acme =
  [ separationCheck
      "a Lookup with wrong endpoint arity for its relation"
      (onAction 0 (onKey "allow" (onKey "right" (setKey "endpoints" (toJSON [actorTerm])))))
  , separationCheck
      "an Equal over incompatible operands (Bool and Unit)"
      (onAction 0 (setKey "allow" (equalTerm boolTrueTerm unitTerm)))
  , separationCheck
      "a LessOrEqual over incompatible operands (Bool and an enum value)"
      (onAction 0 (setKey "allow" (lessOrEqualTerm boolTrueTerm (enumValueTerm "MembershipRole" "Member"))))
  , separationCheck
      "an enum order of existing members that is not the full permutation"
      (onEnum 0 (setKey "order" (toJSON [String "Member"])))
  , separationCheck
      "a payloadOrder enum incompatible with the authority relation"
      ( appendEnum (enumDeclOrdered "Priority" ["Low", "High"] ["Low", "High"])
          . onGuarantee 2 (onKey "authority" (setKey "payloadOrder" (String "Priority")))
      )
  , separationCheck
      "a CreateEntity initializer that is incomplete for its entity"
      (onAction 1 (onKey "effect" (setKey "attributes" (object []))))
  , separationCheck
      "a SetRelation payload of the wrong type for its relation"
      (onAction 3 (onKey "effect" (setKey "payload" boolTrueTerm)))
  ]
  where
    separationCheck description mutate =
      check
        ("resolves although ill-typed: " ++ description)
        (resolves schema (mutate acme))

--------------------------------------------------------------------
-- Rendering, exit codes, and determinism
--------------------------------------------------------------------

renderingChecks :: CoreSchema -> Value -> [Check]
renderingChecks schema acme =
  [ check
      "the resolution failure block renders exactly as specified"
      ( renderValidateFailure
          ( FileResolutionViolations
              "doc.mir.json"
              ( ResolutionViolation ["a~b"] "first message"
                  :| [ResolutionViolation ["c/d", "0"] "second message"]
              )
          )
          == Text.intercalate
            "\n"
            [ "doc.mir.json: invalid Mithril Core v0 name resolution"
            , "  /a~0b: first message"
            , "  /c~1d/0: second message"
            ]
      )
  , check
      "resolution violations exit with status 1"
      ( failureExitCode
          ( FileResolutionViolations
              "doc.mir.json"
              (ResolutionViolation [] "message" :| [])
          )
          == ExitFailure 1
      )
  , check
      "internal resolver errors exit with status 2"
      ( failureExitCode
          (InternalResolverError (ResolverInvariantViolation [] "detail" :| []))
          == ExitFailure 2
      )
  , check
      "internal resolver errors render with the required prefix"
      ( "mithril: internal Core resolver error: "
          `Text.isPrefixOf` renderValidateFailure
            (InternalResolverError (ResolverInvariantViolation [] "detail" :| []))
      )
  , check
      "returned violations are already sorted and deduplicated"
      ( case violationsOf schema doublyMutated of
          Just violationList ->
            violationList == normalizeResolutionViolations violationList
              && length violationList == 2
          Nothing -> False
      )
  , check
      "repeated resolution renders byte-identical diagnostics"
      (renderResolutionMutant doublyMutated == renderResolutionMutant doublyMutatedReordered)
  ]
  where
    -- The same two independent edits, applied in both orders: the
    -- rendered diagnostics must not depend on construction order.
    unknownEnumEdit =
      onAction 0 (onKey "allow" (onKey "left" (onKey "value" (setKey "enum" (String "Ghost")))))
    duplicateEntityEdit = appendEntity (entityDecl "Project" [])
    doublyMutated = unknownEnumEdit (duplicateEntityEdit acme)
    doublyMutatedReordered = duplicateEntityEdit (unknownEnumEdit acme)
    renderResolutionMutant mutant =
      case violationsOf schema mutant of
        Just violationList ->
          case NonEmpty.nonEmpty violationList of
            Just someViolations ->
              renderValidateFailure
                (FileResolutionViolations "doc.mir.json" someViolations)
            Nothing -> "EMPTY"
        Nothing -> "NOT-REJECTED"

--------------------------------------------------------------------
-- Pipeline helpers
--------------------------------------------------------------------

-- | Push an in-memory document through the real public pipeline:
-- re-encode, parse, structurally validate, then resolve.  'Nothing'
-- means the mutant never reached resolution (it failed parsing or
-- structural validation), which distinguishes a broken test mutant
-- from a resolution verdict.
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
    Just (Right resolvedDocument) -> hasResolvedStage resolvedDocument
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
-- expected violations, in the expected (sorted) order — pinning
-- paths, messages, and the absence of cascading extras at once.
rejectsExactly :: CoreSchema -> Value -> [([Text], Text)] -> Bool
rejectsExactly schema value expected =
  violationsOf schema value
    == Just [ResolutionViolation path message | (path, message) <- expected]

--------------------------------------------------------------------
-- Term, declaration, and action builders
--------------------------------------------------------------------

boolTrueTerm :: Value
boolTrueTerm = object ["kind" .= ("Bool" :: Text), "value" .= True]

boolFalseTerm :: Value
boolFalseTerm = object ["kind" .= ("Bool" :: Text), "value" .= False]

unitTerm :: Value
unitTerm = object ["kind" .= ("Unit" :: Text)]

actorTerm :: Value
actorTerm = object ["kind" .= ("Actor" :: Text)]

argumentTerm :: Text -> Value
argumentTerm name =
  object ["kind" .= ("Argument" :: Text), "name" .= name]

attributeTerm :: Value -> Text -> Value
attributeTerm source attribute =
  object
    [ "kind" .= ("Attribute" :: Text)
    , "source" .= source
    , "attribute" .= attribute
    ]

enumValueTerm :: Text -> Text -> Value
enumValueTerm enumName valueName =
  object
    [ "kind" .= ("Enum" :: Text)
    , "enum" .= enumName
    , "value" .= valueName
    ]

lookupTerm :: Text -> [Value] -> Value
lookupTerm relation endpoints =
  object
    [ "kind" .= ("Lookup" :: Text)
    , "relation" .= relation
    , "endpoints" .= endpoints
    ]

isSomeTerm :: Value -> Value
isSomeTerm value = object ["kind" .= ("IsSome" :: Text), "value" .= value]

notTerm :: Value -> Value
notTerm value = object ["kind" .= ("Not" :: Text), "value" .= value]

equalTerm :: Value -> Value -> Value
equalTerm left right =
  object ["kind" .= ("Equal" :: Text), "left" .= left, "right" .= right]

lessOrEqualTerm :: Value -> Value -> Value
lessOrEqualTerm left right =
  object ["kind" .= ("LessOrEqual" :: Text), "left" .= left, "right" .= right]

andTerm :: Value -> Value -> Value
andTerm left right =
  object ["kind" .= ("And" :: Text), "left" .= left, "right" .= right]

orTerm :: Value -> Value -> Value
orTerm left right =
  object ["kind" .= ("Or" :: Text), "left" .= left, "right" .= right]

removeRelationEffect :: Text -> Value
removeRelationEffect relation =
  object
    [ "kind" .= ("RemoveRelation" :: Text)
    , "relation" .= relation
    , "endpoints" .= [argumentTerm "target", argumentTerm "organization"]
    ]

boolType :: Value
boolType = object ["kind" .= ("Bool" :: Text)]

unitType :: Value
unitType = object ["kind" .= ("Unit" :: Text)]

enumType :: Text -> Value
enumType name = object ["kind" .= ("Enum" :: Text), "enum" .= name]

entityRefType :: Text -> Value
entityRefType name = object ["kind" .= ("EntityRef" :: Text), "entity" .= name]

attributeDecl :: Text -> Value -> Value
attributeDecl name declaredType =
  object ["name" .= name, "type" .= declaredType]

parameterDecl :: Text -> Value -> Value
parameterDecl name declaredType =
  object ["name" .= name, "type" .= declaredType]

entityDecl :: Text -> [Value] -> Value
entityDecl name attributes =
  object ["name" .= name, "attributes" .= attributes]

enumDecl :: Text -> [Text] -> Value
enumDecl name values = object ["name" .= name, "values" .= values]

enumDeclOrdered :: Text -> [Text] -> [Text] -> Value
enumDeclOrdered name values order =
  object ["name" .= name, "values" .= values, "order" .= order]

endpointDecl :: Text -> Text -> Value
endpointDecl name entity = object ["name" .= name, "entity" .= entity]

relationDecl :: Text -> [Value] -> Value -> Value
relationDecl name endpoints payload =
  object ["name" .= name, "endpoints" .= endpoints, "payload" .= payload]

-- | A minimal AuthenticatedOnly Read action used as a duplicate or
-- reuse probe; structurally valid on its own.
readProbeAction :: Text -> [Value] -> Value
readProbeAction name parameters =
  object
    [ "name" .= name
    , "parameters" .= parameters
    , "principalMode" .= ("AuthenticatedOnly" :: Text)
    , "classification" .= ("Read" :: Text)
    , "allow" .= boolTrueTerm
    , "effect" .= object ["kind" .= ("NoChange" :: Text)]
    , "result" .= object ["kind" .= ("Observe" :: Text), "entity" .= boolTrueTerm]
    ]

-- | A structurally valid AnyPrincipal action around the given
-- anonymous and authenticated allow branches.
anyPrincipalProbe :: Value -> Value -> Value
anyPrincipalProbe anonymousAllow authenticatedAllow =
  object
    [ "name" .= ("Status.ping" :: Text)
    , "parameters" .= [parameterDecl "flag" boolType]
    , "principalMode" .= ("AnyPrincipal" :: Text)
    , "classification" .= ("Read" :: Text)
    , "allow"
        .= object
          [ "anonymous" .= anonymousAllow
          , "authenticated" .= authenticatedAllow
          ]
    , "effect" .= object ["kind" .= ("NoChange" :: Text)]
    , "result" .= object ["kind" .= ("Observe" :: Text), "entity" .= unitTerm]
    ]

--------------------------------------------------------------------
-- In-memory JSON edits (mirroring Mithril.CoreValidationTests)
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

-- | Append one array element.
appendItem :: Value -> Value -> Value
appendItem item = overList (<> [item])

-- Acme-shaped shorthands.

onAction :: Int -> (Value -> Value) -> Value -> Value
onAction index adjust = onKey "actions" (onIndex index adjust)

onEntity :: Int -> (Value -> Value) -> Value -> Value
onEntity index adjust = onKey "schema" (onKey "entities" (onIndex index adjust))

onEnum :: Int -> (Value -> Value) -> Value -> Value
onEnum index adjust = onKey "schema" (onKey "enums" (onIndex index adjust))

onRelation :: Int -> (Value -> Value) -> Value -> Value
onRelation index adjust =
  onKey "schema" (onKey "relations" (onIndex index adjust))

onGuarantee :: Int -> (Value -> Value) -> Value -> Value
onGuarantee index adjust = onKey "guarantees" (onIndex index adjust)

appendEntity :: Value -> Value -> Value
appendEntity item = onKey "schema" (onKey "entities" (appendItem item))

appendEnum :: Value -> Value -> Value
appendEnum item = onKey "schema" (onKey "enums" (appendItem item))

appendRelation :: Value -> Value -> Value
appendRelation item = onKey "schema" (onKey "relations" (appendItem item))

appendAction :: Value -> Value -> Value
appendAction item = onKey "actions" (appendItem item)

-- | Replace the second Lookup endpoint of Project.read's allow policy
-- — the Attribute projection in the pristine example — with the given
-- term.
setProjectLookupTarget :: Value -> Value -> Value
setProjectLookupTarget replacement =
  onKey "allow" (onKey "right" (onKey "endpoints" (onIndex 1 (const replacement))))
