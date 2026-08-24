{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Checks over the static-typing boundary: "Mithril.Core.Typing"
-- and its integration in "Mithril.Command.Validate".
--
-- Everything user-visible goes through the production API — mutants
-- are built in memory from the pristine Acme example (or read from
-- the coverage fixture), re-encoded, and pushed through
-- 'parseCoreDocument', structural validation against the compiled-in
-- schema, 'resolveCoreDocument', and 'typecheckCoreDocument'; no
-- typechecker logic is duplicated here.  Every mutant used for a
-- typing expectation must first parse, validate, and resolve, so
-- these checks cannot silently degrade into structural or
-- name-resolution rejections.  The internal-invariant checks at the
-- end are the deliberate exception: the public pipeline cannot
-- construct a resolved document that breaks the typechecker's
-- invariants, so they build broken models directly through the
-- package-private @core-internal@ sublibrary — the same white-box
-- seam "Mithril.CoreModelTests" uses — and pin the fail-closed
-- internal classification (exit 2) through the pure seam.
--
-- == Core v0 typing-rule audit
--
-- One row per construct of the resolved representation
-- ("Mithril.Core.Internal.Resolved"), stating its typing judgment
-- and where this module exercises it (beyond the whole-document
-- positive controls):
--
-- * @Model@ name, @Entity@, @Attribute@, @Relation@, @Endpoint@,
--   @Parameter@, and their declared types (@AttributeType@,
--   @ParameterType@, @PayloadType@) — no judgment of their own
--   (established at name resolution); they supply the expected types
--   at use sites, exercised throughout.
-- * @EnumDefinition@\/@EnumMember@ order — declared order must be a
--   complete permutation: negative (missing value; single report, no
--   per-use cascade) and positive (reversed but complete order);
--   orderedness at comparison sites: the no-order mutants.
-- * @Action@\/@ActionBody@\/@AnyPrincipalAllow@ — every allow policy
--   (@AuthenticatedOnly@, and both @AnyPrincipal@ branches) must be
--   @Bool@: one negative per position, plus @AnyPrincipal@
--   positives.
-- * @ActionShape@: @ReadShape@ — the @Observe@ term must be an
--   entity reference (negative + Acme positive); @CreateShape@ —
--   initializer completeness (one and two missing), initializer
--   value typing (negative), keys pinned target-owned as an internal
--   invariant; @MutationShape@ — see the effects below.
-- * @DoneEffect@: @NoChange@ — nothing to check (positive controls);
--   @DeleteEntity@ — entity-reference target (negative);
--   @SetRelation@ — endpoint arity, per-position endpoint entity
--   types, and payload type for enum and Unit payloads (negatives +
--   positives); @RemoveRelation@ — endpoint arity and types
--   (two-position aggregation negative + positive).
-- * @ValueTerm@: @BoolTerm@\/@UnitTerm@\/@EnumTerm@ — literal types
--   (exercised as operands everywhere; an ill-owned @EnumTerm@ value
--   is impossible after resolution and pinned as an internal
--   invariant); @ArgumentTerm@ — the parameter's declared type
--   (exercised at every expected-type site; a foreign parameter is
--   an internal invariant); @ActorTerm@ — @EntityRef User@
--   (positives; a non-@User@ payload is an internal invariant);
--   @AttributeTerm@ — the attribute's declared type (positives and
--   endpoint negatives; a non-entity source is unrepresentable after
--   resolution).
-- * @PolicyTerm@: @ValuePolicyTerm@ — lifting (everywhere);
--   @LookupTerm@ — arity (negative, with per-endpoint checks
--   suppressed) and endpoint types (negatives per position);
--   @NoneTerm@\/@SomeTerm@ — optional types (Equal positives and
--   mismatch negatives; @Some@ deliberately admits every value type,
--   pinned by a positive); @IsSomeTerm@ — optional operand (negative
--   + positives); @EqualTerm@ — same-type operands, equality total
--   at every type (positives at @Bool@, @Unit@, @EntityRef@, and
--   optional types; mismatch negatives across value\/optional
--   combinations); @LessOrEqualTerm@ — same-type ordered operands
--   (positives for @Enum@ and @Optional Enum@ with a declared order;
--   negatives for mismatched, unordered-kind, order-less enum, and
--   @Optional Unit@ operands); @AndTerm@\/@OrTerm@\/@NotTerm@ —
--   @Bool@ operands (one negative each).
-- * @Guarantee@: @AuthenticatedMutation@ — carries no terms; typing
--   accepts it (Acme positive); its truth stays a verification
--   question.  @TenantIsolationAccess@ — the access relation must be
--   binary (negative, isolated on a User-endpoint unary relation),
--   its subject and tenant endpoints distinct (negative; distinctness
--   is judged only for a binary relation, so the unary mutant reports
--   the arity alone), and its subject endpoint of the distinguished
--   @User@ entity's type (negative); positives cover an enum-payload
--   access relation (Acme) and a Unit-payload one, and forged
--   dangling\/foreign access references are internal invariants.
--   @TenantIsolationCase@ — an entity-reference @tenant@ of exactly
--   the tenant endpoint's entity (a non-entity negative and an
--   entity-mismatch negative — a non-entity tenant reports only that
--   fact, never a mismatch cascade) and a @Bool@ @protected@
--   (negative), both actor-free by construction, in the case
--   action's environment (nested actor-free positives; a case naming
--   an @AnyPrincipal@ action stays well-typed — the anonymous branch
--   is a verifier question).  @Authority@\/@EscalationCase@ —
--   subject endpoint must reference the distinguished @User@ entity
--   (negative), scope endpoint distinct from the subject (negative,
--   with the coverage count suppressed), endpoint coverage
--   (negative), payload\/@payloadOrder@ agreement and orderedness
--   (negatives incl. both-at-once; Unit payload via the coverage
--   fixture), case scope arity in both directions and the scope
--   term's entity type (negatives), plus an arity-one positive.
--   @AbsenceLevel@ — the structural constant @Bottom@; nothing to
--   check.
--
-- The resolution\/typing separation mutants of
-- "Mithril.CoreResolutionTests" (documents that resolve although
-- ill-typed) are paired here: every one of them is rejected by the
-- typechecker with an exact path and message.
module Mithril.CoreTypingTests
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
  , validateCoreFile
  )
import Mithril.Core.Internal.Document (CoreDocument (..))
import Mithril.Core.Normalization (Normalized)
import qualified Mithril.Core.Internal.Resolved as Internal
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , memberPath
  , rootPath
  )
import Mithril.Core.Internal.Syntax
  ( ActorAvailability (..)
  , OneOrTwo (..)
  )
import Mithril.Core.Resolution (Resolved, resolveCoreDocument)
import Mithril.Core.Typing
  ( TypeViolation (..)
  , TypecheckerInvariantViolation (..)
  , Typed
  , TypingFailure (..)
  , normalizeTypeViolations
  , typecheckCoreDocument
  )
import Mithril.Core.Validation
  ( CoreSchema
  , SchemaLoadError
  , bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Test (Check, check)

-- | The handwritten example every mutant starts from.
acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

-- | The deliberately ill-typed (but resolvable) coverage fixture.
coveragePath :: FilePath
coveragePath = "test/fixtures/coverage.mir.json"

-- | All static-typing checks.  The file reads assume the test
-- process runs from the package root, which is how @cabal test@ runs
-- it.
tests :: IO [Check]
tests = do
  let schemaOutcome = bundledCoreSchema
  acmeBytes <- ByteString.readFile acmePath
  acmeFileOutcome <- validateCoreFile acmePath
  coverageFileOutcome <- validateCoreFile coveragePath
  pure $
    concat
      [ normalizationChecks
      , withSchema schemaOutcome $ \schema ->
          withAcme acmeBytes $ \acme ->
            concat
              [ acmeChecks schema acme acmeFileOutcome
              , coverageChecks coverageFileOutcome
              , positiveChecks schema acme
              , operandChecks schema acme
              , relationChecks schema acme
              , effectAndResultChecks schema acme
              , enumOrderChecks schema acme
              , guaranteeChecks schema acme
              , aggregationChecks schema acme
              , renderingChecks
              ]
      , invariantChecks
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
      (normalizeTypeViolations [] == [])
  , check
      "violations sort by path, then by message"
      (normalizeTypeViolations [atB, atA2, atA1] == [atA1, atA2, atB])
  , check
      "duplicate violations are removed"
      (normalizeTypeViolations [atB, atA1, atB] == [atA1, atB])
  ]
  where
    atA1 = TypeViolation ["a"] "first message"
    atA2 = TypeViolation ["a"] "second message"
    atB = TypeViolation ["b"] "first message"

--------------------------------------------------------------------
-- The pristine documents through the full pipeline
--------------------------------------------------------------------

acmeChecks
  :: CoreSchema
  -> Value
  -> Either ValidateFileError (CoreDocument Normalized)
  -> [Check]
acmeChecks schema acme acmeFileOutcome =
  [ check
      "the public pipeline reaches a CoreDocument Typed witness on Acme"
      (welltyped schema acme)
  , check
      "validateCoreFile typechecks the Acme example (and continues into normalization)"
      (either (const False) hasNormalizedFileStage acmeFileOutcome)
  ]

-- | The deliberately ill-typed coverage fixture through the file
-- boundary: rejected at static typing with exactly its independent
-- violations — the same list the process-level test pins as bytes.
coverageChecks :: Either ValidateFileError (CoreDocument Normalized) -> [Check]
coverageChecks coverageFileOutcome =
  [ check
      "validateCoreFile rejects the coverage fixture with exactly its type violations"
      ( case coverageFileOutcome of
          Left (FileTypeViolations file violations) ->
            file == coveragePath
              && NonEmpty.toList violations == expectedCoverageViolations
          _ -> False
      )
  ]

-- | Every deliberately ill-typed construct of the coverage fixture,
-- sorted by path then message: an operand mismatch in each
-- principal-mode family, the arity mismatch on the arity-one
-- @Flagged@ relation (no cascaded per-endpoint errors), the
-- non-entity @Observe@ term, the missing guarantee scope term, and
-- the doubly incompatible payload-order enum.
expectedCoverageViolations :: [TypeViolation]
expectedCoverageViolations =
  [ TypeViolation
      ["actions", "0", "allow", "right", "right"]
      "the operands of \"Equal\" have incompatible types: Optional Unit and Bool"
  , TypeViolation
      ["actions", "6", "allow", "anonymous", "left", "right", "value", "value"]
      "relation \"Flagged\" declares 1 endpoint, but 2 endpoint terms are given"
  , TypeViolation
      ["actions", "6", "allow", "anonymous", "right"]
      "the operands of \"Equal\" have incompatible types: Optional (Enum \"Level\") and Optional Unit"
  , TypeViolation
      ["actions", "6", "result", "entity"]
      "an \"Observe\" result must observe an entity reference, but this term has type Bool"
  , TypeViolation
      ["guarantees", "2", "cases", "1"]
      "this case names no scope term, but the authority declares the scope endpoint \"organization\""
  , TypeViolation
      ["guarantees", "3", "authority", "payloadOrder"]
      "enum \"Badge\" declares no order, so it cannot rank authority levels"
  , TypeViolation
      ["guarantees", "3", "authority", "payloadOrder"]
      "relation \"Flagged\" has a Unit payload, so enum \"Badge\" cannot rank its authority levels"
  ]

--------------------------------------------------------------------
-- Constructs that must typecheck
--------------------------------------------------------------------

positiveChecks :: CoreSchema -> Value -> [Check]
positiveChecks schema acme =
  [ positive
      "a LessOrEqual over a declared-order enum (not optional)"
      ( onAction 0
          ( setKey
              "allow"
              ( lessOrEqualTerm
                  (enumValueTerm "MembershipRole" "Member")
                  (enumValueTerm "MembershipRole" "Admin")
              )
          )
      )
  , positive
      "an Equal at Unit type (equality is total at every type)"
      (withUnitParameter (setActionAllow (equalTerm unitTerm (argumentTerm "token"))))
  , positive
      "an Equal between Some over a Unit term and a Unit-payload lookup"
      ( appendRelation taggingRelation
          . setActionAllow (equalTerm (lookupTerm "Tagging" [actorTerm]) (someTerm unitTerm))
      )
  , positive
      "a Some over an entity reference (Optional admits every value type)"
      (setActionAllow (isSomeTerm (someTerm actorTerm)))
  , positive
      "an enum order that is a permutation in a different order"
      (onEnum 0 (setKey "order" (toJSON [String "Admin", String "Member"])))
  , positive
      "an enum without a declared order is fine while nothing compares it"
      (appendEnum (enumDecl "Color" ["Red"]))
  , positive
      "a RemoveRelation with matching endpoint types"
      (onAction 3 (setKey "effect" (removeRelationEffect "Membership" [argumentTerm "target", argumentTerm "organization"])))
  , positive
      "a SetRelation on a Unit-payload relation with a Unit payload term"
      ( appendRelation taggingRelation
          . appendAction
            ( mutationProbeAction
                "Tagging.set"
                []
                (setRelationEffect "Tagging" [actorTerm] unitTerm)
            )
      )
  , positive
      "an AnyPrincipal action with Bool branches and an entity-typed observation"
      (appendAction (anyPrincipalProbe boolTrueTerm boolTrueTerm))
  , positive
      "an actor-free AnyPrincipal mutation deleting an argument entity"
      (appendAction anyPrincipalDeleteProbe)
  , positive
      "a NoSelfPrivilegeEscalation authority over an arity-one enum-payload relation"
      ( appendRelation flaggedEnumRelation
          . appendGuarantee
            ( nspeGuarantee
                "Flagged"
                "subject"
                []
                "MembershipRole"
                [("Project.read", [])]
            )
      )
  , positive
      "a TenantIsolation access over a binary Unit-payload relation"
      ( appendRelation assignmentRelation
          . onGuarantee 1 (onKey "access" (setKey "relation" (String "Assignment")))
      )
  , positive
      "a nested actor-free TenantIsolation protected policy"
      ( onGuarantee 1
          ( onKey "cases"
              ( onIndex 0
                  ( setKey
                      "protected"
                      (equalTerm (argumentTerm "project") (argumentTerm "project"))
                  )
              )
          )
      )
  , positive
      "a TenantIsolation case over an AnyPrincipal action stays structurally and type valid"
      ( appendAction anyPrincipalOrgAction
          . onGuarantee 1
            ( onKey "cases"
                ( appendItem
                    (tenantCaseValue "Status.ping" (argumentTerm "organization") boolTrueTerm)
                )
            )
      )
  ]
  where
    positive description mutate =
      check
        ("typechecks: " ++ description)
        (welltyped schema (mutate acme))
    taggingRelation =
      relationDecl "Tagging" [endpointDecl "user" "User"] unitType
    flaggedEnumRelation =
      relationDecl
        "Flagged"
        [endpointDecl "subject" "User"]
        (enumType "MembershipRole")
    assignmentRelation =
      relationDecl
        "Assignment"
        [endpointDecl "user" "User", endpointDecl "organization" "Organization"]
        unitType
    anyPrincipalOrgAction =
      object
        [ "name" .= ("Status.ping" :: Text)
        , "parameters" .= [parameterDecl "organization" (entityRefType "Organization")]
        , "principalMode" .= ("AnyPrincipal" :: Text)
        , "classification" .= ("Read" :: Text)
        , "allow"
            .= object
              [ "anonymous" .= boolTrueTerm
              , "authenticated" .= boolTrueTerm
              ]
        , "effect" .= object ["kind" .= ("NoChange" :: Text)]
        , "result"
            .= object
              ["kind" .= ("Observe" :: Text), "entity" .= argumentTerm "organization"]
        ]
    withUnitParameter =
      \mutate ->
        onAction 0 (onKey "parameters" (appendItem (parameterDecl "token" unitType)))
          . mutate

--------------------------------------------------------------------
-- Operand compatibility
--------------------------------------------------------------------

operandChecks :: CoreSchema -> Value -> [Check]
operandChecks schema acme =
  [ negative
      "an And over a Unit operand"
      (setActionAllow (andTerm unitTerm boolTrueTerm))
      ["actions", "0", "allow", "left"]
      "an operand of \"And\" must have type Bool, but this term has type Unit"
  , negative
      "an Or over an enum operand"
      (setActionAllow (orTerm boolTrueTerm (enumValueTerm "MembershipRole" "Member")))
      ["actions", "0", "allow", "right"]
      "an operand of \"Or\" must have type Bool, but this term has type Enum \"MembershipRole\""
  , negative
      "a Not over an optional operand"
      (setActionAllow (notTerm (someTerm unitTerm)))
      ["actions", "0", "allow", "value"]
      "the operand of \"Not\" must have type Bool, but this term has type Optional Unit"
  , negative
      "an IsSome over a non-optional operand"
      (setActionAllow (isSomeTerm boolTrueTerm))
      ["actions", "0", "allow", "value"]
      "the operand of \"IsSome\" must have an Optional type, but this term has type Bool"
  , negative
      "an Equal over Bool and Unit (the separation mutant)"
      (setActionAllow (equalTerm boolTrueTerm unitTerm))
      ["actions", "0", "allow"]
      "the operands of \"Equal\" have incompatible types: Bool and Unit"
  , negative
      "an Equal over references to different entities"
      (setActionAllow (notTerm (equalTerm actorTerm (argumentTerm "project"))))
      ["actions", "0", "allow", "value"]
      "the operands of \"Equal\" have incompatible types: EntityRef \"User\" and EntityRef \"Project\""
  , negative
      "an Equal over an optional and its unwrapped value type"
      ( setActionAllow
          ( equalTerm
              (lookupTerm "Membership" [actorTerm, projectOrganization])
              (enumValueTerm "MembershipRole" "Member")
          )
      )
      ["actions", "0", "allow"]
      "the operands of \"Equal\" have incompatible types: Optional (Enum \"MembershipRole\") and Enum \"MembershipRole\""
  , negative
      "an Equal over a None and a Unit term"
      (setActionAllow (equalTerm (noneTerm (enumType "MembershipRole")) unitTerm))
      ["actions", "0", "allow"]
      "the operands of \"Equal\" have incompatible types: Optional (Enum \"MembershipRole\") and Unit"
  , negative
      "an Equal over two differently typed Some terms"
      ( setActionAllow
          ( equalTerm
              (someTerm actorTerm)
              (lookupTerm "Membership" [actorTerm, projectOrganization])
          )
      )
      ["actions", "0", "allow"]
      "the operands of \"Equal\" have incompatible types: Optional (EntityRef \"User\") and Optional (Enum \"MembershipRole\")"
  , negative
      "a LessOrEqual over incompatible operands (the separation mutant)"
      (setActionAllow (lessOrEqualTerm boolTrueTerm (enumValueTerm "MembershipRole" "Member")))
      ["actions", "0", "allow"]
      "the operands of \"LessOrEqual\" have incompatible types: Bool and Enum \"MembershipRole\""
  , negative
      "a LessOrEqual over Bool operands"
      (setActionAllow (lessOrEqualTerm boolTrueTerm boolFalseTerm))
      ["actions", "0", "allow"]
      "the operands of \"LessOrEqual\" have type Bool, which has no order"
  , negative
      "a LessOrEqual over an order-less enum"
      ( appendEnum (enumDecl "Badge" ["Star"])
          . setActionAllow
            ( lessOrEqualTerm
                (enumValueTerm "Badge" "Star")
                (enumValueTerm "Badge" "Star")
            )
      )
      ["actions", "0", "allow"]
      "the operands of \"LessOrEqual\" have type Enum \"Badge\", but enum \"Badge\" declares no order"
  , negative
      "a LessOrEqual over Optional Unit operands"
      ( appendRelation (relationDecl "Tagging" [endpointDecl "user" "User"] unitType)
          . setActionAllow
            (lessOrEqualTerm (lookupTerm "Tagging" [actorTerm]) (someTerm unitTerm))
      )
      ["actions", "0", "allow"]
      "the operands of \"LessOrEqual\" have type Optional Unit, which has no order"
  , negative
      "an AuthenticatedOnly allow policy that is not Bool"
      (setActionAllow unitTerm)
      ["actions", "0", "allow"]
      "an allow policy must have type Bool, but this term has type Unit"
  , negative
      "an anonymous AnyPrincipal allow branch that is not Bool"
      (appendAction (anyPrincipalProbe unitTerm boolTrueTerm))
      ["actions", "5", "allow", "anonymous"]
      "an allow policy must have type Bool, but this term has type Unit"
  , negative
      "an authenticated AnyPrincipal allow branch that is not Bool"
      (appendAction (anyPrincipalProbe boolTrueTerm (someTerm unitTerm)))
      ["actions", "5", "allow", "authenticated"]
      "an allow policy must have type Bool, but this term has type Optional Unit"
  ]
  where
    negative description mutate expectedPath expectedMessage =
      check
        ("ill-typed: " ++ description)
        (rejectsExactly schema (mutate acme) [(expectedPath, expectedMessage)])

--------------------------------------------------------------------
-- Relation endpoint, lookup, and payload compatibility
--------------------------------------------------------------------

relationChecks :: CoreSchema -> Value -> [Check]
relationChecks schema acme =
  [ negative
      "a Lookup with too few endpoint terms (the separation mutant), without endpoint cascades"
      (onAction 0 (onKey "allow" (onKey "right" (setKey "endpoints" (toJSON [actorTerm])))))
      [
        ( ["actions", "0", "allow", "right"]
        , "relation \"Membership\" declares 2 endpoints, but 1 endpoint term is given"
        )
      ]
  , negative
      "a Lookup endpoint term of the wrong entity type"
      ( onAction 0
          (onKey "allow" (onKey "right" (setKey "endpoints" (toJSON [actorTerm, argumentTerm "project"]))))
      )
      [
        ( ["actions", "0", "allow", "right", "endpoints", "1"]
        , "endpoint \"organization\" of relation \"Membership\" requires type\
          \ EntityRef \"Organization\", but this term has type EntityRef \"Project\""
        )
      ]
  , negative
      "a Lookup first-endpoint term of the wrong entity type"
      ( onAction 0
          ( onKey "allow"
              (onKey "right" (setKey "endpoints" (toJSON [argumentTerm "project", projectOrganization])))
          )
      )
      [
        ( ["actions", "0", "allow", "right", "endpoints", "0"]
        , "endpoint \"user\" of relation \"Membership\" requires type\
          \ EntityRef \"User\", but this term has type EntityRef \"Project\""
        )
      ]
  , negative
      "a SetRelation with too few endpoint terms"
      (onAction 3 (onKey "effect" (setKey "endpoints" (toJSON [argumentTerm "target"]))))
      [
        ( ["actions", "3", "effect"]
        , "relation \"Membership\" declares 2 endpoints, but 1 endpoint term is given"
        )
      ]
  , negative
      "a SetRelation endpoint term of the wrong entity type"
      ( onAction 3
          ( onKey "effect"
              (setKey "endpoints" (toJSON [argumentTerm "organization", argumentTerm "organization"]))
          )
      )
      [
        ( ["actions", "3", "effect", "endpoints", "0"]
        , "endpoint \"user\" of relation \"Membership\" requires type\
          \ EntityRef \"User\", but this term has type EntityRef \"Organization\""
        )
      ]
  , negative
      "a SetRelation payload of the wrong type (the separation mutant)"
      (onAction 3 (onKey "effect" (setKey "payload" boolTrueTerm)))
      [
        ( ["actions", "3", "effect", "payload"]
        , "the payload of relation \"Membership\" must have type\
          \ Enum \"MembershipRole\", but this term has type Bool"
        )
      ]
  , negative
      "a Unit-payload SetRelation with a non-Unit payload term"
      ( appendRelation (relationDecl "Tagging" [endpointDecl "user" "User"] unitType)
          . appendAction
            ( mutationProbeAction
                "Tagging.set"
                []
                (setRelationEffect "Tagging" [actorTerm] boolTrueTerm)
            )
      )
      [
        ( ["actions", "5", "effect", "payload"]
        , "the payload of relation \"Tagging\" must have type Unit, but this term has type Bool"
        )
      ]
  , negative
      "a RemoveRelation with both endpoint terms swapped reports both positions"
      ( onAction 3
          ( setKey
              "effect"
              (removeRelationEffect "Membership" [argumentTerm "organization", argumentTerm "target"])
          )
      )
      [
        ( ["actions", "3", "effect", "endpoints", "0"]
        , "endpoint \"user\" of relation \"Membership\" requires type\
          \ EntityRef \"User\", but this term has type EntityRef \"Organization\""
        )
      ,
        ( ["actions", "3", "effect", "endpoints", "1"]
        , "endpoint \"organization\" of relation \"Membership\" requires type\
          \ EntityRef \"Organization\", but this term has type EntityRef \"User\""
        )
      ]
  ]
  where
    negative description mutate expected =
      check
        ("ill-typed: " ++ description)
        (rejectsExactly schema (mutate acme) expected)

--------------------------------------------------------------------
-- Effect targets, results, and CreateEntity initializers
--------------------------------------------------------------------

effectAndResultChecks :: CoreSchema -> Value -> [Check]
effectAndResultChecks schema acme =
  [ negative
      "a DeleteEntity target that is not an entity reference"
      (onAction 2 (onKey "effect" (setKey "target" boolTrueTerm)))
      [
        ( ["actions", "2", "effect", "target"]
        , "the target of \"DeleteEntity\" must be an entity reference, but this term has type Bool"
        )
      ]
  , negative
      "an Observe result that does not observe an entity reference"
      (onAction 0 (onKey "result" (setKey "entity" (enumValueTerm "MembershipRole" "Member"))))
      [
        ( ["actions", "0", "result", "entity"]
        , "an \"Observe\" result must observe an entity reference,\
          \ but this term has type Enum \"MembershipRole\""
        )
      ]
  , negative
      "a CreateEntity initializer that is incomplete (the separation mutant)"
      (onAction 1 (onKey "effect" (setKey "attributes" (object []))))
      [
        ( ["actions", "1", "effect"]
        , "attribute \"organization\" of entity \"Project\" is not initialized"
        )
      ]
  , negative
      "a CreateEntity missing two initializers reports each attribute"
      ( onEntity 2
          ( setKey
              "attributes"
              ( toJSON
                  [ attributeDecl "organization" (entityRefType "Organization")
                  , attributeDecl "active" boolType
                  ]
              )
          )
          . onAction 1 (onKey "effect" (setKey "attributes" (object [])))
      )
      [
        ( ["actions", "1", "effect"]
        , "attribute \"active\" of entity \"Project\" is not initialized"
        )
      ,
        ( ["actions", "1", "effect"]
        , "attribute \"organization\" of entity \"Project\" is not initialized"
        )
      ]
  , negative
      "a CreateEntity initializer term of the wrong type"
      (onAction 1 (onKey "effect" (onKey "attributes" (setKey "organization" boolTrueTerm))))
      [
        ( ["actions", "1", "effect", "attributes", "organization"]
        , "attribute \"organization\" of entity \"Project\" has type\
          \ EntityRef \"Organization\", but this initializer has type Bool"
        )
      ]
  ]
  where
    negative description mutate expected =
      check
        ("ill-typed: " ++ description)
        (rejectsExactly schema (mutate acme) expected)

--------------------------------------------------------------------
-- Enum-order permutation validity and orderedness
--------------------------------------------------------------------

enumOrderChecks :: CoreSchema -> Value -> [Check]
enumOrderChecks schema acme =
  [ check
      "ill-typed: an incomplete enum order is reported once, with no per-use cascade (the separation mutant)"
      ( rejectsExactly
          schema
          (onEnum 0 (setKey "order" (toJSON [String "Member"])) acme)
          [
            ( ["schema", "enums", "0"]
            , "the order of enum \"MembershipRole\" does not include value \"Admin\""
            )
          ]
      )
  , check
      "ill-typed: removing the declared order is reported at every comparison that needs it"
      ( rejectsExactly
          schema
          ( onEnum 0 (removeKey "order") acme
          )
          ( [ (path, orderlessMessage)
            | path <-
                [ ["actions", "0", "allow"]
                , ["actions", "1", "allow"]
                , ["actions", "2", "allow"]
                , ["actions", "3", "allow", "left"]
                , ["actions", "4", "allow", "left"]
                ]
            ]
              ++ [
                   ( ["guarantees", "2", "authority", "payloadOrder"]
                   , "enum \"MembershipRole\" declares no order, so it cannot rank authority levels"
                   )
                 ]
          )
      )
  ]
  where
    orderlessMessage =
      "the operands of \"LessOrEqual\" have type Optional (Enum \"MembershipRole\"),\
      \ but enum \"MembershipRole\" declares no order"

--------------------------------------------------------------------
-- Guarantee well-typedness
--------------------------------------------------------------------

guaranteeChecks :: CoreSchema -> Value -> [Check]
guaranteeChecks schema acme =
  [ negative
      "a TenantIsolation tenant term that is not an entity reference"
      (onGuarantee 1 (onKey "cases" (onIndex 0 (setKey "tenant" boolTrueTerm))))
      [
        ( ["guarantees", "1", "cases", "0", "tenant"]
        , "the \"tenant\" term must be an entity reference, but this term has type Bool"
        )
      ]
  , negative
      "a TenantIsolation protected term that is not Bool"
      (onGuarantee 1 (onKey "cases" (onIndex 0 (setKey "protected" unitTerm))))
      [
        ( ["guarantees", "1", "cases", "0", "protected"]
        , "the \"protected\" term must have type Bool, but this term has type Unit"
        )
      ]
  , negative
      "a TenantIsolation tenant term of a different entity than the tenant endpoint (the separation mutant)"
      ( onGuarantee 1
          (onKey "cases" (onIndex 0 (setKey "tenant" (argumentTerm "project"))))
      )
      [
        ( ["guarantees", "1", "cases", "0", "tenant"]
        , "the \"tenant\" term must have type EntityRef \"Organization\" (the entity\
          \ of the access tenant endpoint \"organization\"), but this term has type\
          \ EntityRef \"Project\""
        )
      ]
  , negative
      "a non-entity tenant term reports only that fact, never an entity-mismatch cascade"
      ( onGuarantee 1
          ( onKey "cases"
              (onIndex 0 (setKey "tenant" (enumValueTerm "MembershipRole" "Member")))
          )
      )
      [
        ( ["guarantees", "1", "cases", "0", "tenant"]
        , "the \"tenant\" term must be an entity reference, but this term has type\
          \ Enum \"MembershipRole\""
        )
      ]
  , negative
      "a TenantIsolation access over an arity-one relation (the separation mutant)"
      ( appendRelation soloRelation
          . onGuarantee 1 (const (tenantIsolationValue soloAccess [userTenantCase]))
      )
      [
        ( ["guarantees", "1", "access", "relation"]
        , "relation \"Solo\" declares 1 endpoint, but the TenantIsolation access\
          \ requires a binary relation"
        )
      ]
  , negative
      "a TenantIsolation access naming one endpoint twice (the separation mutant)"
      ( onGuarantee 1
          ( const
              ( tenantIsolationValue
                  (accessValue "Membership" "user" "user")
                  [userTenantCase]
              )
          )
      )
      [
        ( ["guarantees", "1", "access", "tenantEndpoint"]
        , "the tenant endpoint duplicates the subject endpoint \"user\""
        )
      ]
  , negative
      "a TenantIsolation access with a non-User subject endpoint (the separation mutant)"
      ( onGuarantee 1
          ( const
              ( tenantIsolationValue
                  (accessValue "Membership" "organization" "user")
                  [userTenantCase]
              )
          )
      )
      [
        ( ["guarantees", "1", "access", "subjectEndpoint"]
        , "the subject endpoint \"organization\" of relation \"Membership\" must reference\
          \ the distinguished \"User\" entity, but it references entity \"Organization\""
        )
      ]
  , negative
      "an authority subject endpoint that does not reference the User entity"
      ( onGuarantee 2
          ( onKey "authority"
              ( setKey "subjectEndpoint" (String "organization")
                  . setKey "scopeEndpoints" (toJSON [String "user"])
              )
          )
          . onGuarantee 2
            (onKey "cases" (onIndex 0 (setKey "scope" (toJSON [argumentTerm "target"]))))
      )
      [
        ( ["guarantees", "2", "authority", "subjectEndpoint"]
        , "the subject endpoint \"organization\" of relation \"Membership\" must reference\
          \ the distinguished \"User\" entity, but it references entity \"Organization\""
        )
      ]
  , negative
      "an authority scope endpoint that duplicates the subject endpoint, without a coverage cascade"
      ( onGuarantee 2 (onKey "authority" (setKey "scopeEndpoints" (toJSON [String "user"])))
          . onGuarantee 2
            (onKey "cases" (onIndex 0 (setKey "scope" (toJSON [argumentTerm "target"]))))
      )
      [
        ( ["guarantees", "2", "authority", "scopeEndpoints", "0"]
        , "the scope endpoint duplicates the subject endpoint \"user\""
        )
      ]
  , negative
      "an authority that does not cover an arity-two relation, and the then-surplus case scope"
      (onGuarantee 2 (onKey "authority" (setKey "scopeEndpoints" (toJSON ([] :: [Text])))))
      [
        ( ["guarantees", "2", "authority"]
        , "relation \"Membership\" declares 2 endpoints, but the authority names\
          \ only the subject endpoint"
        )
      ,
        ( ["guarantees", "2", "cases", "0", "scope", "0"]
        , "this case names a scope term, but the authority declares no scope endpoint"
        )
      ]
  , negative
      "a case without the scope term its authority requires"
      (onGuarantee 2 (onKey "cases" (onIndex 0 (setKey "scope" (toJSON ([] :: [Value]))))))
      [
        ( ["guarantees", "2", "cases", "0"]
        , "this case names no scope term, but the authority declares the scope endpoint \"organization\""
        )
      ]
  , negative
      "a case scope term of the wrong entity type"
      (onGuarantee 2 (onKey "cases" (onIndex 0 (setKey "scope" (toJSON [argumentTerm "target"])))))
      [
        ( ["guarantees", "2", "cases", "0", "scope", "0"]
        , "the scope term must have type EntityRef \"Organization\" (the entity of\
          \ scope endpoint \"organization\"), but this term has type EntityRef \"User\""
        )
      ]
  , negative
      "a payloadOrder enum that is not the relation's payload enum (the separation mutant)"
      ( appendEnum (enumDeclOrdered "Priority" ["Low", "High"] ["Low", "High"])
          . onGuarantee 2 (onKey "authority" (setKey "payloadOrder" (String "Priority")))
      )
      [
        ( ["guarantees", "2", "authority", "payloadOrder"]
        , "relation \"Membership\" has an Enum \"MembershipRole\" payload,\
          \ so enum \"Priority\" cannot rank its authority levels"
        )
      ]
  , negative
      "a payloadOrder enum that is both foreign and order-less"
      ( appendEnum (enumDecl "Badge" ["Star"])
          . onGuarantee 2 (onKey "authority" (setKey "payloadOrder" (String "Badge")))
      )
      [
        ( ["guarantees", "2", "authority", "payloadOrder"]
        , "enum \"Badge\" declares no order, so it cannot rank authority levels"
        )
      ,
        ( ["guarantees", "2", "authority", "payloadOrder"]
        , "relation \"Membership\" has an Enum \"MembershipRole\" payload,\
          \ so enum \"Badge\" cannot rank its authority levels"
        )
      ]
  ]
  where
    negative description mutate expected =
      check
        ("ill-typed: " ++ description)
        (rejectsExactly schema (mutate acme) expected)
    soloRelation =
      relationDecl "Solo" [endpointDecl "holder" "User"] unitType
    soloAccess = accessValue "Solo" "holder" "holder"
    -- A case whose tenant is EntityRef User, so the access mutants
    -- above isolate their access violation: with a User tenant
    -- endpoint the tenant term matches and only the mutated access
    -- fact is reported.
    userTenantCase =
      tenantCaseValue "Membership.addMember" (argumentTerm "target") boolTrueTerm

--------------------------------------------------------------------
-- Aggregation, determinism, and no-cascade behavior
--------------------------------------------------------------------

aggregationChecks :: CoreSchema -> Value -> [Check]
aggregationChecks schema acme =
  [ check
      "independent violations across actions and guarantees aggregate, sorted by path"
      ( rejectsExactly
          schema
          triplyMutated
          [ (["actions", "0", "allow"], equalMismatchMessage)
          ,
            ( ["actions", "2", "effect", "target"]
            , "the target of \"DeleteEntity\" must be an entity reference, but this term has type Bool"
            )
          ,
            ( ["guarantees", "1", "cases", "0", "protected"]
            , "the \"protected\" term must have type Bool, but this term has type Unit"
            )
          ]
      )
  , check
      "returned violations are already sorted and deduplicated"
      ( case typeViolationsOf schema triplyMutated of
          Just violationList ->
            violationList == normalizeTypeViolations violationList
              && length violationList == 3
          Nothing -> False
      )
  , check
      "repeated typechecking renders byte-identical diagnostics"
      (renderTypingMutant doublyMutated == renderTypingMutant doublyMutatedReordered)
  ]
  where
    equalMismatchMessage =
      "the operands of \"Equal\" have incompatible types: Bool and Unit"
    allowEdit = setActionAllow (equalTerm boolTrueTerm unitTerm)
    deleteEdit = onAction 2 (onKey "effect" (setKey "target" boolTrueTerm))
    protectedEdit =
      onGuarantee 1 (onKey "cases" (onIndex 0 (setKey "protected" unitTerm)))
    triplyMutated = allowEdit (deleteEdit (protectedEdit acme))
    doublyMutated = allowEdit (deleteEdit acme)
    doublyMutatedReordered = deleteEdit (allowEdit acme)
    renderTypingMutant mutant =
      case typeViolationsOf schema mutant of
        Just violationList ->
          case NonEmpty.nonEmpty violationList of
            Just someViolations ->
              renderValidateFailure
                (FileTypeViolations "doc.mir.json" someViolations)
            Nothing -> "EMPTY"
        Nothing -> "NOT-REJECTED"

--------------------------------------------------------------------
-- Rendering and exit codes
--------------------------------------------------------------------

renderingChecks :: [Check]
renderingChecks =
  [ check
      "the static-typing failure block renders exactly as specified"
      ( renderValidateFailure
          ( FileTypeViolations
              "doc.mir.json"
              ( TypeViolation ["a~b"] "first message"
                  :| [TypeViolation ["c/d", "0"] "second message"]
              )
          )
          == Text.intercalate
            "\n"
            [ "doc.mir.json: invalid Mithril Core v0 static typing"
            , "  /a~0b: first message"
            , "  /c~1d/0: second message"
            ]
      )
  , check
      "type violations exit with status 1"
      ( failureExitCode
          (FileTypeViolations "doc.mir.json" (TypeViolation [] "message" :| []))
          == ExitFailure 1
      )
  , check
      "internal typechecker errors exit with status 2"
      ( failureExitCode
          ( InternalTypecheckerError
              (TypecheckerInvariantViolation [] "detail" :| [])
          )
          == ExitFailure 2
      )
  , check
      "internal typechecker errors render with the required prefix"
      ( "mithril: internal Core typechecker error: "
          `Text.isPrefixOf` renderValidateFailure
            ( InternalTypecheckerError
                (TypecheckerInvariantViolation [] "detail" :| [])
            )
      )
  ]

--------------------------------------------------------------------
-- Internal invariants (white-box, through core-internal)
--------------------------------------------------------------------

-- | The public pipeline cannot construct a resolved document that
-- breaks the typechecker's invariants, so these checks build broken
-- models directly through the package-private sublibrary and pin the
-- fail-closed internal classification: never a user type error,
-- always 'TypecheckerInvariantViolations' — the exit-2 class.
invariantChecks :: [Check]
invariantChecks =
  [ check
      "a hand-built well-formed model typechecks to a Typed witness"
      ( case typecheckCoreDocument (resolvedDocumentWith wellTypedAllow) of
          Right typedDocument -> hasTypedStage typedDocument
          Left _ -> False
      )
  , check
      "a dangling relation reference is an internal invariant, not a user error"
      ( invariantOutcome (resolvedDocumentWith danglingLookupAllow)
          == Just
            [ TypecheckerInvariantViolation
                ["lookupRelation"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "a foreign parameter reference is an internal invariant"
      ( invariantOutcome (resolvedDocumentWith foreignArgumentAllow)
          == Just
            [ TypecheckerInvariantViolation
                ["foreignParameter"]
                "an argument reference escapes its action's parameter environment"
            ]
      )
  , check
      "an Actor term with a non-User entity is an internal invariant"
      ( invariantOutcome (resolvedDocumentWith strayActorAllow)
          == Just
            [ TypecheckerInvariantViolation
                ["strayActor"]
                "an Actor term does not reference the distinguished \"User\" entity"
            ]
      )
  , check
      "internal invariants dominate user type violations"
      ( invariantOutcome (resolvedDocumentWith dominanceAllow)
          == Just
            [ TypecheckerInvariantViolation
                ["lookupRelation"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "a forged well-formed TenantIsolation access typechecks to a Typed witness (control)"
      ( case typecheckCoreDocument (tenantAccessDocumentWith gridRef memberRef containerRef) of
          Right typedDocument -> hasTypedStage typedDocument
          Left _ -> False
      )
  , check
      "a dangling access relation reference is an internal invariant"
      ( invariantOutcome
          ( tenantAccessDocumentWith
              (Internal.Ref (synthetic "accessRelation") (Internal.RelationId 7))
              memberRef
              containerRef
          )
          == Just
            [ TypecheckerInvariantViolation
                ["accessRelation"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "a dangling access endpoint reference is an internal invariant"
      ( invariantOutcome
          ( tenantAccessDocumentWith
              gridRef
              memberRef
              ( Internal.Ref
                  (synthetic "accessTenant")
                  (Internal.EndpointId (Internal.RelationId 0) 9)
              )
          )
          == Just
            [ TypecheckerInvariantViolation
                ["accessTenant"]
                "a resolved endpoint reference does not name a endpoint of the model"
            ]
      )
  , check
      "an access endpoint owned by a foreign relation is an internal invariant"
      ( invariantOutcome
          ( tenantAccessDocumentWith
              gridRef
              ( Internal.Ref
                  (synthetic "accessSubject")
                  (Internal.EndpointId (Internal.RelationId 1) 0)
              )
              containerRef
          )
          == Just
            [ TypecheckerInvariantViolation
                ["accessSubject"]
                "an access endpoint does not belong to the access relation"
            ]
      )
  ]
  where
    invariantOutcome document =
      case typecheckCoreDocument document of
        Left (TypecheckerInvariantViolations problems) ->
          Just (NonEmpty.toList problems)
        _ -> Nothing
    gridRef = Internal.Ref (synthetic "accessRelation") (Internal.RelationId 0)
    memberRef =
      Internal.Ref
        (synthetic "accessSubject")
        (Internal.EndpointId (Internal.RelationId 0) 0)
    containerRef =
      Internal.Ref
        (synthetic "accessTenant")
        (Internal.EndpointId (Internal.RelationId 0) 1)

-- | A minimal hand-built resolved model — one @User@ entity and one
-- parameterless mutation action — whose allow policy is supplied by
-- each check.
resolvedDocumentWith
  :: Internal.PolicyTerm 'ActorAvailable
  -> CoreDocument Resolved
resolvedDocumentWith allow = CoreDocument model
  where
    model =
      Internal.Model
        { Internal.modelName = Sourced (synthetic "name") "Tiny"
        , Internal.modelEntities =
            [ Internal.Entity
                { Internal.entityId = Internal.EntityId 0
                , Internal.entityPath = synthetic "userEntity"
                , Internal.entityName = Sourced (synthetic "userEntityName") "User"
                , Internal.entityAttributes = []
                }
            ]
        , Internal.modelEnums = []
        , Internal.modelRelations = []
        , Internal.modelActions =
            [ Internal.Action
                { Internal.actionId = Internal.ActionId 0
                , Internal.actionPath = synthetic "action"
                , Internal.actionName = Sourced (synthetic "actionName") "Tiny.touch"
                , Internal.actionParameters = []
                , Internal.actionBody =
                    Internal.AuthenticatedOnlyBody
                      allow
                      ( Internal.MutationShape
                          (Internal.NoChangeEffect (synthetic "effect"))
                          (synthetic "result")
                      )
                }
            ]
        , Internal.modelGuarantees = []
        }

synthetic :: Text -> SourcePath
synthetic segment = memberPath rootPath segment

-- | A forged resolved model carrying a @TenantIsolation@ guarantee
-- over the binary @Grid@ relation (member : User, container : Org)
-- beside the unary @Other@ relation (holder : User), with the access
-- references supplied by each check: with the well-formed references
-- it typechecks, and dangling or foreign references pin the internal
-- invariant classification.
tenantAccessDocumentWith
  :: Internal.Ref Internal.RelationId
  -> Internal.Ref Internal.EndpointId
  -> Internal.Ref Internal.EndpointId
  -> CoreDocument Resolved
tenantAccessDocumentWith relationRef subjectRef tenantRef =
  CoreDocument model
  where
    entityOf position name pathSegment =
      Internal.Entity
        { Internal.entityId = Internal.EntityId position
        , Internal.entityPath = synthetic pathSegment
        , Internal.entityName = Sourced (synthetic (pathSegment <> "Name")) name
        , Internal.entityAttributes = []
        }
    endpointOf relation position name entity =
      Internal.Endpoint
        { Internal.endpointId = Internal.EndpointId relation position
        , Internal.endpointPath = synthetic (name <> "Endpoint")
        , Internal.endpointName = Sourced (synthetic (name <> "EndpointName")) name
        , Internal.endpointEntity = Internal.Ref (synthetic (name <> "Entity")) entity
        }
    model =
      Internal.Model
        { Internal.modelName = Sourced (synthetic "name") "Tiny"
        , Internal.modelEntities =
            [entityOf 0 "User" "userEntity", entityOf 1 "Org" "orgEntity"]
        , Internal.modelEnums = []
        , Internal.modelRelations =
            [ Internal.Relation
                { Internal.relationId = Internal.RelationId 0
                , Internal.relationPath = synthetic "gridRelation"
                , Internal.relationName = Sourced (synthetic "gridName") "Grid"
                , Internal.relationEndpoints =
                    Two
                      (endpointOf (Internal.RelationId 0) 0 "member" (Internal.EntityId 0))
                      (endpointOf (Internal.RelationId 0) 1 "container" (Internal.EntityId 1))
                , Internal.relationPayload =
                    Internal.UnitPayloadType (synthetic "gridPayload")
                }
            , Internal.Relation
                { Internal.relationId = Internal.RelationId 1
                , Internal.relationPath = synthetic "otherRelation"
                , Internal.relationName = Sourced (synthetic "otherName") "Other"
                , Internal.relationEndpoints =
                    One (endpointOf (Internal.RelationId 1) 0 "holder" (Internal.EntityId 0))
                , Internal.relationPayload =
                    Internal.UnitPayloadType (synthetic "otherPayload")
                }
            ]
        , Internal.modelActions =
            [ Internal.Action
                { Internal.actionId = Internal.ActionId 0
                , Internal.actionPath = synthetic "action"
                , Internal.actionName = Sourced (synthetic "actionName") "Tiny.view"
                , Internal.actionParameters =
                    [ Internal.Parameter
                        { Internal.parameterId =
                            Internal.ParameterId (Internal.ActionId 0) 0
                        , Internal.parameterPath = synthetic "containerParameter"
                        , Internal.parameterName =
                            Sourced (synthetic "containerParameterName") "container"
                        , Internal.parameterType =
                            Internal.EntityRefParameterType
                              (synthetic "containerParameterType")
                              (Internal.Ref (synthetic "containerParameterEntity") (Internal.EntityId 1))
                        }
                    ]
                , Internal.actionBody =
                    Internal.AuthenticatedOnlyBody
                      wellTypedAllow
                      ( Internal.MutationShape
                          (Internal.NoChangeEffect (synthetic "effect"))
                          (synthetic "result")
                      )
                }
            ]
        , Internal.modelGuarantees =
            [ Internal.TenantIsolationGuarantee
                (synthetic "guarantee")
                Internal.TenantIsolationAccess
                  { Internal.tenantIsolationAccessPath = synthetic "access"
                  , Internal.tenantIsolationAccessRelation = relationRef
                  , Internal.tenantIsolationAccessSubjectEndpoint = subjectRef
                  , Internal.tenantIsolationAccessTenantEndpoint = tenantRef
                  }
                ( Internal.TenantIsolationCase
                    { Internal.tenantIsolationCasePath = synthetic "case"
                    , Internal.tenantIsolationCaseAction =
                        Internal.Ref (synthetic "caseAction") (Internal.ActionId 0)
                    , Internal.tenantIsolationCaseTenant =
                        Internal.ArgumentTerm
                          (synthetic "tenantTerm")
                          ( Internal.Ref
                              (synthetic "tenantTermName")
                              (Internal.ParameterId (Internal.ActionId 0) 0)
                          )
                    , Internal.tenantIsolationCaseProtected =
                        Internal.ValuePolicyTerm
                          (Internal.BoolTerm (synthetic "protectedTerm") True)
                    }
                    :| []
                )
            ]
        }

wellTypedAllow :: Internal.PolicyTerm 'ActorAvailable
wellTypedAllow =
  Internal.ValuePolicyTerm (Internal.BoolTerm (synthetic "allow") True)

danglingLookup :: Internal.PolicyTerm 'ActorAvailable
danglingLookup =
  Internal.LookupTerm
    (synthetic "lookup")
    (Internal.Ref (synthetic "lookupRelation") (Internal.RelationId 7))
    (One (Internal.BoolTerm (synthetic "lookupEndpoint") True))

danglingLookupAllow :: Internal.PolicyTerm 'ActorAvailable
danglingLookupAllow = Internal.IsSomeTerm (synthetic "isSome") danglingLookup

foreignArgumentAllow :: Internal.PolicyTerm 'ActorAvailable
foreignArgumentAllow =
  Internal.ValuePolicyTerm
    ( Internal.ArgumentTerm
        (synthetic "argument")
        ( Internal.Ref
            (synthetic "foreignParameter")
            (Internal.ParameterId (Internal.ActionId 9) 0)
        )
    )

strayActorAllow :: Internal.PolicyTerm 'ActorAvailable
strayActorAllow =
  Internal.ValuePolicyTerm
    (Internal.ActorTerm (synthetic "strayActor") (Internal.EntityId 5))

-- | Both a user violation (a Unit operand of And) and an internal
-- invariant (the dangling lookup): classification must be internal.
dominanceAllow :: Internal.PolicyTerm 'ActorAvailable
dominanceAllow =
  Internal.AndTerm
    (synthetic "and")
    (Internal.ValuePolicyTerm (Internal.UnitTerm (synthetic "unitOperand")))
    (Internal.IsSomeTerm (synthetic "isSome") danglingLookup)

--------------------------------------------------------------------
-- Pipeline helpers
--------------------------------------------------------------------

-- | Push an in-memory document through the real public pipeline:
-- re-encode, parse, structurally validate, resolve, then typecheck.
-- 'Nothing' means the mutant never reached the typechecker (it
-- failed parsing, structural validation, or name resolution), which
-- distinguishes a broken test mutant from a typing verdict.
typecheckMutant
  :: CoreSchema
  -> Value
  -> Maybe (Either TypingFailure (CoreDocument Typed))
typecheckMutant schema value =
  case parseCoreDocument (LazyByteString.toStrict (encode value)) of
    Left _ -> Nothing
    Right document ->
      case validateCoreDocument schema document of
        Left _ -> Nothing
        Right validDocument ->
          case resolveCoreDocument validDocument of
            Left _ -> Nothing
            Right resolvedDocument ->
              Just (typecheckCoreDocument resolvedDocument)

-- | The mutant is structurally valid, resolves, and typechecks.
welltyped :: CoreSchema -> Value -> Bool
welltyped schema value =
  case typecheckMutant schema value of
    Just (Right typedDocument) -> hasTypedStage typedDocument
    _ -> False

-- | Compile-time witness that a value sits at the 'Typed' stage;
-- using it on a merely resolved document does not typecheck.
hasTypedStage :: CoreDocument Typed -> Bool
hasTypedStage _ = True

-- | Compile-time witness that the file boundary now carries its
-- success to the 'Normalized' stage (the well-typed document
-- continued through the normalizer).
hasNormalizedFileStage :: CoreDocument Normalized -> Bool
hasNormalizedFileStage _ = True

-- | The mutant's type violations, if it reached the typechecker and
-- was rejected with user violations (never internal ones).
typeViolationsOf :: CoreSchema -> Value -> Maybe [TypeViolation]
typeViolationsOf schema value =
  case typecheckMutant schema value of
    Just (Left (TypeViolations violations)) ->
      Just (NonEmpty.toList violations)
    _ -> Nothing

-- | The mutant resolves and is rejected by the typechecker with
-- exactly the expected violations, in the expected (sorted) order —
-- pinning paths, messages, and the absence of cascading extras at
-- once.
rejectsExactly :: CoreSchema -> Value -> [([Text], Text)] -> Bool
rejectsExactly schema value expected =
  typeViolationsOf schema value
    == Just [TypeViolation path message | (path, message) <- expected]

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

-- | The Acme @Project.read@ action's tenant expression: the
-- organization of the @project@ argument.
projectOrganization :: Value
projectOrganization = attributeTerm (argumentTerm "project") "organization"

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

someTerm :: Value -> Value
someTerm value = object ["kind" .= ("Some" :: Text), "value" .= value]

noneTerm :: Value -> Value
noneTerm payloadType =
  object ["kind" .= ("None" :: Text), "payloadType" .= payloadType]

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

setRelationEffect :: Text -> [Value] -> Value -> Value
setRelationEffect relation endpoints payload =
  object
    [ "kind" .= ("SetRelation" :: Text)
    , "relation" .= relation
    , "endpoints" .= endpoints
    , "payload" .= payload
    ]

removeRelationEffect :: Text -> [Value] -> Value
removeRelationEffect relation endpoints =
  object
    [ "kind" .= ("RemoveRelation" :: Text)
    , "relation" .= relation
    , "endpoints" .= endpoints
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

-- | A minimal AuthenticatedOnly mutation action with a Done result
-- around the given effect; structurally valid and trivially allowed.
mutationProbeAction :: Text -> [Value] -> Value -> Value
mutationProbeAction name parameters effect =
  object
    [ "name" .= name
    , "parameters" .= parameters
    , "principalMode" .= ("AuthenticatedOnly" :: Text)
    , "classification" .= ("Mutation" :: Text)
    , "allow" .= boolTrueTerm
    , "effect" .= effect
    , "result" .= object ["kind" .= ("Done" :: Text)]
    ]

-- | A well-typed AnyPrincipal read probe around the given allow
-- branches: an entity-typed parameter observed by the result, so
-- only the branches decide typing.
anyPrincipalProbe :: Value -> Value -> Value
anyPrincipalProbe anonymousAllow authenticatedAllow =
  object
    [ "name" .= ("Status.ping" :: Text)
    , "parameters" .= [parameterDecl "peer" (entityRefType "User")]
    , "principalMode" .= ("AnyPrincipal" :: Text)
    , "classification" .= ("Read" :: Text)
    , "allow"
        .= object
          [ "anonymous" .= anonymousAllow
          , "authenticated" .= authenticatedAllow
          ]
    , "effect" .= object ["kind" .= ("NoChange" :: Text)]
    , "result"
        .= object ["kind" .= ("Observe" :: Text), "entity" .= argumentTerm "peer"]
    ]

-- | A well-typed actor-free AnyPrincipal mutation: deletes an
-- argument entity.
anyPrincipalDeleteProbe :: Value
anyPrincipalDeleteProbe =
  object
    [ "name" .= ("User.expel" :: Text)
    , "parameters" .= [parameterDecl "target" (entityRefType "User")]
    , "principalMode" .= ("AnyPrincipal" :: Text)
    , "classification" .= ("Mutation" :: Text)
    , "allow"
        .= object
          [ "anonymous" .= boolTrueTerm
          , "authenticated" .= boolTrueTerm
          ]
    , "effect"
        .= object
          [ "kind" .= ("DeleteEntity" :: Text)
          , "target" .= argumentTerm "target"
          ]
    , "result" .= object ["kind" .= ("Done" :: Text)]
    ]

-- | A TenantIsolation access object.
accessValue :: Text -> Text -> Text -> Value
accessValue relation subjectEndpoint tenantEndpoint =
  object
    [ "relation" .= relation
    , "subjectEndpoint" .= subjectEndpoint
    , "tenantEndpoint" .= tenantEndpoint
    ]

-- | A TenantIsolation case object.
tenantCaseValue :: Text -> Value -> Value -> Value
tenantCaseValue actionName tenant protectedTerm =
  object
    [ "action" .= actionName
    , "tenant" .= tenant
    , "protected" .= protectedTerm
    ]

-- | A complete TenantIsolation guarantee value.
tenantIsolationValue :: Value -> [Value] -> Value
tenantIsolationValue access cases =
  object
    [ "kind" .= ("TenantIsolation" :: Text)
    , "access" .= access
    , "cases" .= cases
    ]

-- | A NoSelfPrivilegeEscalation guarantee value.
nspeGuarantee :: Text -> Text -> [Text] -> Text -> [(Text, [Value])] -> Value
nspeGuarantee relation subject scopeEndpoints payloadOrder cases =
  object
    [ "kind" .= ("NoSelfPrivilegeEscalation" :: Text)
    , "authority"
        .= object
          [ "relation" .= relation
          , "subjectEndpoint" .= subject
          , "scopeEndpoints" .= scopeEndpoints
          , "absenceLevel" .= ("Bottom" :: Text)
          , "payloadOrder" .= payloadOrder
          ]
    , "cases"
        .= [ object ["action" .= actionName, "scope" .= scope]
           | (actionName, scope) <- cases
           ]
    ]

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

-- | Delete an object member.
removeKey :: Text -> Value -> Value
removeKey name value =
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

-- Acme-shaped shorthands.

onAction :: Int -> (Value -> Value) -> Value -> Value
onAction index adjust = onKey "actions" (onIndex index adjust)

onEntity :: Int -> (Value -> Value) -> Value -> Value
onEntity index adjust = onKey "schema" (onKey "entities" (onIndex index adjust))

onEnum :: Int -> (Value -> Value) -> Value -> Value
onEnum index adjust = onKey "schema" (onKey "enums" (onIndex index adjust))

onGuarantee :: Int -> (Value -> Value) -> Value -> Value
onGuarantee index adjust = onKey "guarantees" (onIndex index adjust)

appendEnum :: Value -> Value -> Value
appendEnum item = onKey "schema" (onKey "enums" (appendItem item))

appendRelation :: Value -> Value -> Value
appendRelation item = onKey "schema" (onKey "relations" (appendItem item))

appendAction :: Value -> Value -> Value
appendAction item = onKey "actions" (appendItem item)

appendGuarantee :: Value -> Value -> Value
appendGuarantee item = onKey "guarantees" (appendItem item)

-- | Replace the allow policy of the first Acme action.
setActionAllow :: Value -> Value -> Value
setActionAllow allow = onAction 0 (setKey "allow" allow)
