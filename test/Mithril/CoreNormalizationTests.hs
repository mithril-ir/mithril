{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Checks over the normalization boundary: "Mithril.Core.Normalization"
-- and its integration in "Mithril.Command.Validate".
--
-- The positive side goes through the production API: the Acme example
-- and the well-typed coverage fixture flow through the complete
-- public pipeline — parse, structural validation against the
-- compiled-in schema, resolution, typechecking, and normalization —
-- and reach a @'CoreDocument' 'Normalized'@ witness, while the
-- deliberately ill-typed coverage fixture is still rejected at static
-- typing and never reaches the normalizer.  The normalized model's
-- content is inspected by "Mithril.NormalizedModelTests"; this module
-- pins the boundary itself: the failure vocabulary, its rendering and
-- exit-2 classification, and — via the package-private sublibrary,
-- the same white-box seam the typing invariant checks use — the
-- fail-closed internal classification of every inconsistency class
-- the normalizer can observe.
--
-- The forged-document checks are the deliberate exception to the
-- public-pipeline rule, and they pin this milestone's central
-- classification requirement: normalization has /no user-error
-- class/.  The public pipeline cannot produce a typed document whose
-- model breaks the normalizer's invariants (the typechecker would
-- have refused it), so these checks construct broken models directly
-- and stamp them @Typed@ through the sublibrary constructor — and
-- every resulting problem, including a resurfacing user-shaped typing
-- violation, must come back as 'NormalizerInvariantViolations' (the
-- exit-2 internal class), never as anything user-addressed.
module Mithril.CoreNormalizationTests
  ( tests
  ) where

import qualified Data.ByteString as ByteString
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
import qualified Mithril.Core.Internal.Resolved as Internal
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , memberPath
  , rootPath
  )
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel (..)
  , ActorAvailability (..)
  , OneOrTwo (..)
  )
import Mithril.Core.Normalization
  ( NormalizationFailure (..)
  , Normalized
  , NormalizerInvariantViolation (..)
  , normalizeCoreDocument
  , normalizeNormalizerInvariantViolations
  )
import Mithril.Core.Resolution (resolveCoreDocument)
import Mithril.Core.Typing (Typed, typecheckCoreDocument)
import Mithril.Core.Validation
  ( bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Test (Check, check)

-- | The handwritten well-typed example.
acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

-- | The well-typed full-coverage fixture.
welltypedPath :: FilePath
welltypedPath = "test/fixtures/welltyped.mir.json"

-- | The deliberately ill-typed (but resolvable) coverage fixture.
coveragePath :: FilePath
coveragePath = "test/fixtures/coverage.mir.json"

-- | All normalization-boundary checks.  The file reads assume the
-- test process runs from the package root, which is how @cabal test@
-- runs it.
tests :: IO [Check]
tests = do
  acmeFileOutcome <- validateCoreFile acmePath
  welltypedFileOutcome <- validateCoreFile welltypedPath
  coverageFileOutcome <- validateCoreFile coveragePath
  acmeInMemory <- normalizeThroughPipeline acmePath
  pure $
    concat
      [ boundaryChecks
          acmeFileOutcome
          welltypedFileOutcome
          coverageFileOutcome
          acmeInMemory
      , normalizationHelperChecks
      , renderingChecks
      , invariantChecks
      ]

-- | One complete in-memory production run through every public stage
-- function, ending at the normalizer.
normalizeThroughPipeline
  :: FilePath -> IO (Maybe (CoreDocument Normalized))
normalizeThroughPipeline file = do
  bytes <- ByteString.readFile file
  pure $ case bundledCoreSchema of
    Left _ -> Nothing
    Right schema ->
      case parseCoreDocument bytes of
        Left _ -> Nothing
        Right document ->
          case validateCoreDocument schema document of
            Left _ -> Nothing
            Right validDocument ->
              case resolveCoreDocument validDocument of
                Left _ -> Nothing
                Right resolvedDocument ->
                  case typecheckCoreDocument resolvedDocument of
                    Left _ -> Nothing
                    Right typedOutcome ->
                      either
                        (const Nothing)
                        Just
                        (normalizeCoreDocument typedOutcome)

--------------------------------------------------------------------
-- The boundary through the public pipeline
--------------------------------------------------------------------

boundaryChecks
  :: Either ValidateFileError (CoreDocument Normalized)
  -> Either ValidateFileError (CoreDocument Normalized)
  -> Either ValidateFileError (CoreDocument Normalized)
  -> Maybe (CoreDocument Normalized)
  -> [Check]
boundaryChecks acmeFileOutcome welltypedFileOutcome coverageFileOutcome acmeInMemory =
  [ check
      "the public stage functions carry Acme to a CoreDocument Normalized witness"
      (maybe False hasNormalizedStage acmeInMemory)
  , check
      "validateCoreFile normalizes the Acme example"
      (either (const False) hasNormalizedStage acmeFileOutcome)
  , check
      "validateCoreFile normalizes the well-typed coverage fixture"
      (either (const False) hasNormalizedStage welltypedFileOutcome)
  , check
      "the ill-typed coverage fixture is still rejected at static typing, before normalization"
      ( case coverageFileOutcome of
          Left (FileTypeViolations _ _) -> True
          _ -> False
      )
  ]

-- | Compile-time witness that a value sits at the 'Normalized'
-- stage; using it on a merely typed document does not typecheck.
hasNormalizedStage :: CoreDocument Normalized -> Bool
hasNormalizedStage _ = True

--------------------------------------------------------------------
-- Violation normalization
--------------------------------------------------------------------

normalizationHelperChecks :: [Check]
normalizationHelperChecks =
  [ check
      "normalizing no violations yields no violations"
      (normalizeNormalizerInvariantViolations [] == [])
  , check
      "violations sort by path, then message"
      ( normalizeNormalizerInvariantViolations [atB, atA2, atA1]
          == [atA1, atA2, atB]
      )
  , check
      "duplicate violations are removed"
      (normalizeNormalizerInvariantViolations [atB, atA1, atB] == [atA1, atB])
  ]
  where
    atA1 = NormalizerInvariantViolation ["a"] "first message"
    atA2 = NormalizerInvariantViolation ["a"] "second message"
    atB = NormalizerInvariantViolation ["b"] "first message"

--------------------------------------------------------------------
-- Rendering and exit codes
--------------------------------------------------------------------

renderingChecks :: [Check]
renderingChecks =
  [ check
      "the internal normalizer failure block renders exactly as specified"
      ( renderValidateFailure
          ( InternalNormalizerError
              ( NormalizerInvariantViolation ["a~b"] "first detail"
                  :| [NormalizerInvariantViolation ["c/d", "0"] "second detail"]
              )
          )
          == Text.intercalate
            "\n"
            [ "mithril: internal Core normalizer error: the well-typed document\
              \ does not match the normalizer's Core v0 interpretation"
            , "  /a~0b: first detail"
            , "  /c~1d/0: second detail"
            ]
      )
  , check
      "internal normalizer errors exit with status 2"
      ( failureExitCode
          ( InternalNormalizerError
              (NormalizerInvariantViolation [] "detail" :| [])
          )
          == ExitFailure 2
      )
  , check
      "internal normalizer errors render with the required prefix"
      ( "mithril: internal Core normalizer error: "
          `Text.isPrefixOf` renderValidateFailure
            ( InternalNormalizerError
                (NormalizerInvariantViolation [] "detail" :| [])
            )
      )
  ]

--------------------------------------------------------------------
-- Internal invariants (white-box, through core-internal)
--------------------------------------------------------------------

-- | The fail-closed classification of every inconsistency class the
-- normalizer can observe on a forged typed document.  Each check
-- pins the exact sorted, deduplicated violation list — where the
-- re-checking gate and the structural build both notice a problem,
-- both reports appear, and a user-shaped typing judgment resurfaces
-- only under the reclassification prefix, never as a user error.
invariantChecks :: [Check]
invariantChecks =
  [ check
      "a forged well-formed typed model normalizes to a Normalized witness"
      ( case normalizeCoreDocument (typedDocument baseModel) of
          Right normalizedDocument -> hasNormalizedStage normalizedDocument
          Left _ -> False
      )
  , check
      "a resurfacing user-shaped typing violation is an internal invariant, not a user error"
      ( invariantOutcome (typedDocument (withAllow illBoolAllow))
          == Just
            [ NormalizerInvariantViolation
                ["unitOperand"]
                "the typed document fails a static-typing judgment:\
                \ an operand of \"And\" must have type Bool, but this term has type Unit"
            ]
      )
  , check
      "a dangling relation reference is an internal invariant"
      ( invariantOutcome (typedDocument (withAllow danglingLookupAllow))
          == Just
            [ NormalizerInvariantViolation
                ["lookupRelation"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "an incomplete enum order is refused by both the gate and the rank materializer"
      ( invariantOutcome (typedDocument incompleteOrderModel)
          == Just
            [ NormalizerInvariantViolation
                ["shadeEnum"]
                "the declared order of this enum is not a complete permutation of its values"
            , NormalizerInvariantViolation
                ["shadeEnum"]
                "the typed document fails a static-typing judgment:\
                \ the order of enum \"Shade\" does not include value \"Dark\""
            ]
      )
  , check
      "an endpoint-arity mismatch is refused by both the gate and the binding step"
      ( invariantOutcome (typedDocument arityMismatchModel)
          == Just
            [ NormalizerInvariantViolation
                ["lookup"]
                "the endpoint terms of this site do not match the relation's declared endpoint arity"
            , NormalizerInvariantViolation
                ["lookup"]
                "the typed document fails a static-typing judgment:\
                \ relation \"Marked\" declares 1 endpoint, but 2 endpoint terms are given"
            ]
      )
  , check
      "a missing CreateEntity initializer is refused by both the gate and the reordering step"
      ( invariantOutcome (typedDocument missingInitializerModel)
          == Just
            [ NormalizerInvariantViolation
                ["effect"]
                "attribute \"flag\" of the target entity has no initializer"
            , NormalizerInvariantViolation
                ["effect"]
                "the typed document fails a static-typing judgment:\
                \ attribute \"flag\" of entity \"User\" is not initialized"
            ]
      )
  , check
      "an unknown CreateEntity initializer key is refused by both the gate and the key check"
      ( invariantOutcome (typedDocument unknownInitializerModel)
          == Just
            [ NormalizerInvariantViolation
                ["extraKey"]
                "a \"CreateEntity\" initializer key does not belong to the target entity"
            , NormalizerInvariantViolation
                ["extraKey"]
                "a \"CreateEntity\" initializer key does not name an attribute of the target entity"
            ]
      )
  , check
      "a duplicated CreateEntity initializer is refused by the reordering step alone (the gate is silent)"
      ( invariantOutcome (typedDocument duplicateInitializerModel)
          == Just
            [ NormalizerInvariantViolation
                ["effect"]
                "attribute \"flag\" of the target entity has more than one initializer"
            ]
      )
  , check
      "an unordered LessOrEqual is refused by both the gate and the ordered-reading step"
      ( invariantOutcome (typedDocument (withAllow unorderedComparisonAllow))
          == Just
            [ NormalizerInvariantViolation
                ["allow"]
                "the operands of a \"LessOrEqual\" do not have an ordered type"
            , NormalizerInvariantViolation
                ["allow"]
                "the typed document fails a static-typing judgment:\
                \ the operands of \"LessOrEqual\" have type Bool, which has no order"
            ]
      )
  , check
      "a LessOrEqual over an enum without a declared order is refused by both the gate and the ordered-reading step"
      ( invariantOutcome (typedDocument unrankedEnumModel)
          == Just
            [ NormalizerInvariantViolation
                ["allow"]
                "the operand enum of a \"LessOrEqual\" declares no order"
            , NormalizerInvariantViolation
                ["allow"]
                "the typed document fails a static-typing judgment:\
                \ the operands of \"LessOrEqual\" have type Enum \"Shade\",\
                \ but enum \"Shade\" declares no order"
            ]
      )
  , check
      "a scope term without a scope endpoint is refused by both the gate and the binding step"
      ( invariantOutcome (typedDocument strayScopeModel)
          == Just
            [ NormalizerInvariantViolation
                ["scopeTerm"]
                "the typed document fails a static-typing judgment:\
                \ this case names a scope term, but the authority declares no scope endpoint"
            , NormalizerInvariantViolation
                ["scopeTerm"]
                "this case names a scope term, but the authority declares no scope endpoint"
            ]
      )
  , check
      "a missing scope term under a declared scope endpoint is refused by both the gate and the binding step"
      ( invariantOutcome (typedDocument missingScopeModel)
          == Just
            [ NormalizerInvariantViolation
                ["case"]
                "the typed document fails a static-typing judgment:\
                \ this case names no scope term,\
                \ but the authority declares the scope endpoint \"scope\""
            , NormalizerInvariantViolation
                ["case"]
                "this case names no scope term, but the authority declares a scope endpoint"
            ]
      )
  , check
      "a forged well-formed TenantIsolation guarantee normalizes to a Normalized witness (control)"
      ( case normalizeCoreDocument (typedDocument (tenantModel id)) of
          Right normalizedDocument -> hasNormalizedStage normalizedDocument
          Left _ -> False
      )
  , check
      "a dangling access relation is refused by the consistency gate"
      ( invariantOutcome
          ( typedDocument
              ( tenantModel
                  ( \access ->
                      access
                        { Internal.tenantIsolationAccessRelation =
                            Internal.Ref
                              (synthetic "tenantAccessRelation")
                              (Internal.RelationId 7)
                        }
                  )
              )
          )
          == Just
            [ NormalizerInvariantViolation
                ["tenantAccessRelation"]
                "a resolved relation reference does not name a relation of the model"
            ]
      )
  , check
      "a dangling access subject endpoint is refused by the consistency gate"
      ( invariantOutcome
          ( typedDocument
              ( tenantModel
                  ( \access ->
                      access
                        { Internal.tenantIsolationAccessSubjectEndpoint =
                            Internal.Ref
                              (synthetic "tenantAccessSubject")
                              (Internal.EndpointId (Internal.RelationId 0) 9)
                        }
                  )
              )
          )
          == Just
            [ NormalizerInvariantViolation
                ["tenantAccessSubject"]
                "a resolved endpoint reference does not name a endpoint of the model"
            ]
      )
  , check
      "a dangling access tenant endpoint is refused by the consistency gate"
      ( invariantOutcome
          ( typedDocument
              ( tenantModel
                  ( \access ->
                      access
                        { Internal.tenantIsolationAccessTenantEndpoint =
                            Internal.Ref
                              (synthetic "tenantAccessTenant")
                              (Internal.EndpointId (Internal.RelationId 0) 9)
                        }
                  )
              )
          )
          == Just
            [ NormalizerInvariantViolation
                ["tenantAccessTenant"]
                "a resolved endpoint reference does not name a endpoint of the model"
            ]
      )
  , check
      "an access endpoint owned by a foreign relation is refused by the consistency gate"
      ( invariantOutcome
          ( typedDocument
              ( tenantModel
                  ( \access ->
                      access
                        { Internal.tenantIsolationAccessTenantEndpoint =
                            Internal.Ref
                              (synthetic "tenantAccessTenant")
                              (Internal.EndpointId (Internal.RelationId 1) 0)
                        }
                  )
              )
          )
          == Just
            [ NormalizerInvariantViolation
                ["tenantAccessTenant"]
                "an access endpoint does not belong to the access relation"
            ]
      )
  , check
      "one endpoint used twice resurfaces only under the reclassification prefix"
      ( invariantOutcome (typedDocument duplicateAccessEndpointModel)
          == Just
            [ NormalizerInvariantViolation
                ["tenantAccessTenant"]
                "the typed document fails a static-typing judgment:\
                \ the tenant endpoint duplicates the subject endpoint \"member\""
            ]
      )
  , check
      "a non-User subject entity resurfaces only under the reclassification prefix"
      ( invariantOutcome (typedDocument wrongSubjectEntityModel)
          == Just
            [ NormalizerInvariantViolation
                ["tenantAccessSubject"]
                "the typed document fails a static-typing judgment:\
                \ the subject endpoint \"member\" of relation \"Grid\" must reference\
                \ the distinguished \"User\" entity, but it references entity \"Org\""
            ]
      )
  , check
      "a tenant term inconsistent with the tenant endpoint resurfaces only under the reclassification prefix"
      ( invariantOutcome (typedDocument mismatchedTenantModel)
          == Just
            [ NormalizerInvariantViolation
                ["tenantTerm"]
                "the typed document fails a static-typing judgment:\
                \ the \"tenant\" term must have type EntityRef \"Org\" (the entity of\
                \ the access tenant endpoint \"container\"), but this term has type\
                \ EntityRef \"User\""
            ]
      )
  , check
      "a non-Bool protected term resurfaces only under the reclassification prefix"
      ( invariantOutcome (typedDocument unitProtectedModel)
          == Just
            [ NormalizerInvariantViolation
                ["protectedTerm"]
                "the typed document fails a static-typing judgment:\
                \ the \"protected\" term must have type Bool, but this term has type Unit"
            ]
      )
  , check
      "invariant classification and rendering are deterministic across repeated runs"
      ( renderForged (typedDocument arityMismatchModel)
          == renderForged (typedDocument arityMismatchModel)
      )
  ]
  where
    invariantOutcome document =
      case normalizeCoreDocument document of
        Left (NormalizerInvariantViolations problems) ->
          Just (NonEmpty.toList problems)
        Right _ -> Nothing
    renderForged document =
      case normalizeCoreDocument document of
        Left (NormalizerInvariantViolations problems) ->
          renderValidateFailure (InternalNormalizerError problems)
        Right _ -> "NOT-REFUSED"

--------------------------------------------------------------------
-- Forged typed documents (the white-box seam)
--------------------------------------------------------------------

-- | Stamp a hand-built model as 'Typed' through the sublibrary
-- constructor — the forgery no public caller can perform, used here
-- to reach the normalizer with models the typechecker would refuse.
typedDocument :: Internal.Model -> CoreDocument Typed
typedDocument = CoreDocument

synthetic :: Text -> SourcePath
synthetic segment = memberPath rootPath segment

-- | A minimal well-typed model: one @User@ entity with one @Bool@
-- attribute, one ordered two-value enum, one arity-one relation, and
-- one parameterless mutation action with a trivially true allow.
baseModel :: Internal.Model
baseModel =
  Internal.Model
    { Internal.modelName = Sourced (synthetic "name") "Tiny"
    , Internal.modelEntities = [userEntity]
    , Internal.modelEnums = [shadeEnum completeOrder]
    , Internal.modelRelations = [markedRelation]
    , Internal.modelActions = [touchAction trueAllow noChangeShape]
    , Internal.modelGuarantees = []
    }

-- | 'baseModel' with a different allow policy on its one action.
withAllow :: Internal.PolicyTerm 'ActorAvailable -> Internal.Model
withAllow allow =
  baseModel
    { Internal.modelActions = [touchAction allow noChangeShape]
    }

userEntity :: Internal.Entity
userEntity =
  Internal.Entity
    { Internal.entityId = Internal.EntityId 0
    , Internal.entityPath = synthetic "userEntity"
    , Internal.entityName = Sourced (synthetic "userEntityName") "User"
    , Internal.entityAttributes =
        [ Internal.Attribute
            { Internal.attributeId = Internal.AttributeId (Internal.EntityId 0) 0
            , Internal.attributePath = synthetic "flagAttribute"
            , Internal.attributeName = Sourced (synthetic "flagName") "flag"
            , Internal.attributeType =
                Internal.BoolAttributeType (synthetic "flagType")
            }
        ]
    }

-- | The two-value @Shade@ enum with the given declared order.
shadeEnum
  :: Maybe (NonEmpty (Internal.Ref Internal.EnumValueId))
  -> Internal.EnumDefinition
shadeEnum order =
  Internal.EnumDefinition
    { Internal.enumDefinitionId = Internal.EnumId 0
    , Internal.enumDefinitionPath = synthetic "shadeEnum"
    , Internal.enumDefinitionName = Sourced (synthetic "shadeName") "Shade"
    , Internal.enumDefinitionValues =
        Internal.EnumMember
          (Internal.EnumValueId (Internal.EnumId 0) 0)
          (Sourced (synthetic "lightValue") "Light")
          :| [ Internal.EnumMember
                 (Internal.EnumValueId (Internal.EnumId 0) 1)
                 (Sourced (synthetic "darkValue") "Dark")
             ]
    , Internal.enumDefinitionOrder = order
    }

completeOrder :: Maybe (NonEmpty (Internal.Ref Internal.EnumValueId))
completeOrder =
  Just
    ( Internal.Ref (synthetic "orderLight") (Internal.EnumValueId (Internal.EnumId 0) 0)
        :| [ Internal.Ref
               (synthetic "orderDark")
               (Internal.EnumValueId (Internal.EnumId 0) 1)
           ]
    )

-- | The arity-one @Marked@ relation over @User@, with a Unit payload.
markedRelation :: Internal.Relation
markedRelation = markedRelationWith (Internal.UnitPayloadType (synthetic "markedPayload"))

-- | The @Marked@ relation with the given payload (the stray-scope
-- model needs the ordered @Shade@ payload so its authority is
-- otherwise well-typed).
markedRelationWith :: Internal.PayloadType -> Internal.Relation
markedRelationWith payload =
  Internal.Relation
    { Internal.relationId = Internal.RelationId 0
    , Internal.relationPath = synthetic "markedRelation"
    , Internal.relationName = Sourced (synthetic "markedName") "Marked"
    , Internal.relationEndpoints =
        One
          ( Internal.Endpoint
              { Internal.endpointId =
                  Internal.EndpointId (Internal.RelationId 0) 0
              , Internal.endpointPath = synthetic "subjectEndpoint"
              , Internal.endpointName = Sourced (synthetic "subjectName") "subject"
              , Internal.endpointEntity =
                  Internal.Ref (synthetic "subjectEntity") (Internal.EntityId 0)
              }
          )
    , Internal.relationPayload = payload
    }

touchAction
  :: Internal.PolicyTerm 'ActorAvailable
  -> Internal.ActionShape 'ActorAvailable
  -> Internal.Action
touchAction allow shape =
  Internal.Action
    { Internal.actionId = Internal.ActionId 0
    , Internal.actionPath = synthetic "action"
    , Internal.actionName = Sourced (synthetic "actionName") "Tiny.touch"
    , Internal.actionParameters = []
    , Internal.actionBody = Internal.AuthenticatedOnlyBody allow shape
    }

noChangeShape :: Internal.ActionShape 'ActorAvailable
noChangeShape =
  Internal.MutationShape
    (Internal.NoChangeEffect (synthetic "effect"))
    (synthetic "result")

trueAllow :: Internal.PolicyTerm 'ActorAvailable
trueAllow =
  Internal.ValuePolicyTerm (Internal.BoolTerm (synthetic "allow") True)

-- | A user-shaped typing violation: a Unit operand of @And@.
illBoolAllow :: Internal.PolicyTerm 'ActorAvailable
illBoolAllow =
  Internal.AndTerm
    (synthetic "allow")
    (Internal.ValuePolicyTerm (Internal.UnitTerm (synthetic "unitOperand")))
    trueAllow

-- | A lookup whose relation identifier is outside the model.
danglingLookupAllow :: Internal.PolicyTerm 'ActorAvailable
danglingLookupAllow =
  Internal.IsSomeTerm
    (synthetic "isSome")
    ( Internal.LookupTerm
        (synthetic "lookup")
        (Internal.Ref (synthetic "lookupRelation") (Internal.RelationId 7))
        (One (Internal.BoolTerm (synthetic "lookupEndpoint") True))
    )

-- | A @LessOrEqual@ whose operands have the unordered type @Bool@.
unorderedComparisonAllow :: Internal.PolicyTerm 'ActorAvailable
unorderedComparisonAllow =
  Internal.LessOrEqualTerm
    (synthetic "allow")
    (Internal.ValuePolicyTerm (Internal.BoolTerm (synthetic "leftBool") True))
    (Internal.ValuePolicyTerm (Internal.BoolTerm (synthetic "rightBool") False))

-- | The @Shade@ order listing only one of the two values.
incompleteOrderModel :: Internal.Model
incompleteOrderModel =
  baseModel
    { Internal.modelEnums =
        [ shadeEnum
            ( Just
                ( Internal.Ref
                    (synthetic "orderLight")
                    (Internal.EnumValueId (Internal.EnumId 0) 0)
                    :| []
                )
            )
        ]
    }

-- | Two endpoint terms against the arity-one @Marked@ relation.
arityMismatchModel :: Internal.Model
arityMismatchModel =
  withAllow
    ( Internal.IsSomeTerm
        (synthetic "isSome")
        ( Internal.LookupTerm
            (synthetic "lookup")
            (Internal.Ref (synthetic "lookupRelation") (Internal.RelationId 0))
            ( Two
                (Internal.BoolTerm (synthetic "firstEndpoint") True)
                (Internal.BoolTerm (synthetic "secondEndpoint") False)
            )
        )
    )

-- | A @CreateEntity@ effect that initializes none of the target's
-- attributes.
missingInitializerModel :: Internal.Model
missingInitializerModel =
  baseModel
    { Internal.modelActions =
        [ touchAction
            trueAllow
            ( Internal.CreateShape
                ( Internal.CreateEntityEffect
                    { Internal.createEntityEffectPath = synthetic "effect"
                    , Internal.createEntityEffectEntity =
                        Internal.Ref (synthetic "effectEntity") (Internal.EntityId 0)
                    , Internal.createEntityEffectInitializers = []
                    }
                )
                (synthetic "result")
            )
        ]
    }

-- | A well-typed initializer for the @flag@ attribute of the target
-- @User@ entity.
flagInitializer :: Internal.Initializer 'ActorAvailable
flagInitializer =
  Internal.Initializer
    { Internal.initializerKey =
        Internal.Ref
          (synthetic "flagKey")
          (Internal.AttributeId (Internal.EntityId 0) 0)
    , Internal.initializerValue =
        Internal.BoolTerm (synthetic "flagInitializerValue") True
    }

-- | A @CreateEntity@ shape over @User@ with the given initializers.
createShapeWith
  :: [Internal.Initializer 'ActorAvailable]
  -> Internal.ActionShape 'ActorAvailable
createShapeWith initializers =
  Internal.CreateShape
    ( Internal.CreateEntityEffect
        { Internal.createEntityEffectPath = synthetic "effect"
        , Internal.createEntityEffectEntity =
            Internal.Ref (synthetic "effectEntity") (Internal.EntityId 0)
        , Internal.createEntityEffectInitializers = initializers
        }
    )
    (synthetic "result")

-- | A complete initializer set plus one whose key identifies an
-- attribute of an entity outside the model, so the unknown-key
-- refusal is the only structural inconsistency (completeness holds).
unknownInitializerModel :: Internal.Model
unknownInitializerModel =
  baseModel
    { Internal.modelActions =
        [ touchAction
            trueAllow
            ( createShapeWith
                [ flagInitializer
                , Internal.Initializer
                    { Internal.initializerKey =
                        Internal.Ref
                          (synthetic "extraKey")
                          (Internal.AttributeId (Internal.EntityId 1) 0)
                    , Internal.initializerValue =
                        Internal.BoolTerm (synthetic "extraValue") True
                    }
                ]
            )
        ]
    }

-- | The one @flag@ attribute initialized twice, each initializer
-- well-typed on its own — the checking gate accepts this shape
-- (initializer keys are unique by construction on the real pipeline),
-- so only the normalizer's one-to-one reordering step can refuse it.
duplicateInitializerModel :: Internal.Model
duplicateInitializerModel =
  baseModel
    { Internal.modelActions =
        [ touchAction
            trueAllow
            ( createShapeWith
                [ flagInitializer
                , Internal.Initializer
                    { Internal.initializerKey =
                        Internal.Ref
                          (synthetic "duplicateKey")
                          (Internal.AttributeId (Internal.EntityId 0) 0)
                    , Internal.initializerValue =
                        Internal.BoolTerm (synthetic "duplicateValue") False
                    }
                ]
            )
        ]
    }

-- | A @LessOrEqual@ over two values of the @Shade@ enum: well-shaped
-- for ordering, so it reaches the enum-declares-no-order refusal (not
-- the no-ordered-shape one) when the enum's order is removed.
shadeComparisonAllow :: Internal.PolicyTerm 'ActorAvailable
shadeComparisonAllow =
  Internal.LessOrEqualTerm
    (synthetic "allow")
    ( Internal.ValuePolicyTerm
        ( Internal.EnumTerm
            (synthetic "leftShade")
            (Internal.Ref (synthetic "leftShadeEnum") (Internal.EnumId 0))
            ( Internal.Ref
                (synthetic "leftShadeValue")
                (Internal.EnumValueId (Internal.EnumId 0) 0)
            )
        )
    )
    ( Internal.ValuePolicyTerm
        ( Internal.EnumTerm
            (synthetic "rightShade")
            (Internal.Ref (synthetic "rightShadeEnum") (Internal.EnumId 0))
            ( Internal.Ref
                (synthetic "rightShadeValue")
                (Internal.EnumValueId (Internal.EnumId 0) 1)
            )
        )
    )

-- | The @Shade@ comparison against a @Shade@ enum that declares no
-- order at all.
unrankedEnumModel :: Internal.Model
unrankedEnumModel =
  (withAllow shadeComparisonAllow)
    { Internal.modelEnums = [shadeEnum Nothing]
    }

-- | An escalation case naming a scope term although its authority
-- declares no scope endpoint.  The authority is otherwise well-typed
-- (the relation carries the ordered @Shade@ payload), so the scope
-- mismatch is the only inconsistency.
strayScopeModel :: Internal.Model
strayScopeModel =
  baseModel
    { Internal.modelRelations =
        [ markedRelationWith
            ( Internal.EnumPayloadType
                (synthetic "markedPayload")
                (Internal.Ref (synthetic "markedPayloadEnum") (Internal.EnumId 0))
            )
        ]
    , Internal.modelGuarantees =
        [ Internal.NoSelfPrivilegeEscalationGuarantee
            (synthetic "guarantee")
            Internal.Authority
              { Internal.authorityPath = synthetic "authority"
              , Internal.authorityRelation =
                  Internal.Ref (synthetic "authorityRelation") (Internal.RelationId 0)
              , Internal.authoritySubjectEndpoint =
                  Internal.Ref
                    (synthetic "authoritySubject")
                    (Internal.EndpointId (Internal.RelationId 0) 0)
              , Internal.authorityScopeEndpoint = Nothing
              , Internal.authorityAbsenceLevel =
                  Sourced (synthetic "absenceLevel") AbsenceBottom
              , Internal.authorityPayloadOrder =
                  Internal.Ref (synthetic "payloadOrder") (Internal.EnumId 0)
              }
            ( Internal.EscalationCase
                { Internal.escalationCasePath = synthetic "case"
                , Internal.escalationCaseAction =
                    Internal.Ref (synthetic "caseAction") (Internal.ActionId 0)
                , Internal.escalationCaseScope =
                    Just (Internal.BoolTerm (synthetic "scopeTerm") True)
                }
                :| []
            )
        ]
    }

-- | The relation with two endpoints — @subject@ and @scope@, both
-- over @User@ — and the ordered @Shade@ payload, so an authority
-- naming both endpoints is otherwise well-typed.
scopedRelation :: Internal.Relation
scopedRelation =
  Internal.Relation
    { Internal.relationId = Internal.RelationId 0
    , Internal.relationPath = synthetic "markedRelation"
    , Internal.relationName = Sourced (synthetic "markedName") "Marked"
    , Internal.relationEndpoints =
        Two
          ( Internal.Endpoint
              { Internal.endpointId =
                  Internal.EndpointId (Internal.RelationId 0) 0
              , Internal.endpointPath = synthetic "subjectEndpoint"
              , Internal.endpointName = Sourced (synthetic "subjectName") "subject"
              , Internal.endpointEntity =
                  Internal.Ref (synthetic "subjectEntity") (Internal.EntityId 0)
              }
          )
          ( Internal.Endpoint
              { Internal.endpointId =
                  Internal.EndpointId (Internal.RelationId 0) 1
              , Internal.endpointPath = synthetic "scopeEndpoint"
              , Internal.endpointName = Sourced (synthetic "scopeName") "scope"
              , Internal.endpointEntity =
                  Internal.Ref (synthetic "scopeEntity") (Internal.EntityId 0)
              }
          )
    , Internal.relationPayload =
        Internal.EnumPayloadType
          (synthetic "markedPayload")
          (Internal.Ref (synthetic "markedPayloadEnum") (Internal.EnumId 0))
    }

--------------------------------------------------------------------
-- The forged TenantIsolation family (access relation and case terms)
--------------------------------------------------------------------

-- | The binary @Grid@ relation (member : User, container : Org, Unit
-- payload) whose member endpoint references the given entity — @User@
-- for the well-formed variants, @Org@ for the wrong-subject one.
gridRelation :: Internal.EntityId -> Internal.Relation
gridRelation memberEntity =
  Internal.Relation
    { Internal.relationId = Internal.RelationId 0
    , Internal.relationPath = synthetic "gridRelation"
    , Internal.relationName = Sourced (synthetic "gridName") "Grid"
    , Internal.relationEndpoints =
        Two
          ( Internal.Endpoint
              { Internal.endpointId = Internal.EndpointId (Internal.RelationId 0) 0
              , Internal.endpointPath = synthetic "memberEndpoint"
              , Internal.endpointName = Sourced (synthetic "memberName") "member"
              , Internal.endpointEntity =
                  Internal.Ref (synthetic "memberEntity") memberEntity
              }
          )
          ( Internal.Endpoint
              { Internal.endpointId = Internal.EndpointId (Internal.RelationId 0) 1
              , Internal.endpointPath = synthetic "containerEndpoint"
              , Internal.endpointName = Sourced (synthetic "containerName") "container"
              , Internal.endpointEntity =
                  Internal.Ref (synthetic "containerEntity") (Internal.EntityId 1)
              }
          )
    , Internal.relationPayload = Internal.UnitPayloadType (synthetic "gridPayload")
    }

-- | The unary @Other@ relation beside @Grid@, so a foreign-owner
-- access endpoint names a real endpoint of a real other relation.
otherRelation :: Internal.Relation
otherRelation =
  Internal.Relation
    { Internal.relationId = Internal.RelationId 1
    , Internal.relationPath = synthetic "otherRelation"
    , Internal.relationName = Sourced (synthetic "otherName") "Other"
    , Internal.relationEndpoints =
        One
          ( Internal.Endpoint
              { Internal.endpointId = Internal.EndpointId (Internal.RelationId 1) 0
              , Internal.endpointPath = synthetic "holderEndpoint"
              , Internal.endpointName = Sourced (synthetic "holderName") "holder"
              , Internal.endpointEntity =
                  Internal.Ref (synthetic "holderEntity") (Internal.EntityId 0)
              }
          )
    , Internal.relationPayload = Internal.UnitPayloadType (synthetic "otherPayload")
    }

-- | The well-formed forged access: relation @Grid@, subject @member@,
-- tenant @container@.
wellFormedAccess :: Internal.TenantIsolationAccess
wellFormedAccess =
  Internal.TenantIsolationAccess
    { Internal.tenantIsolationAccessPath = synthetic "tenantAccess"
    , Internal.tenantIsolationAccessRelation =
        Internal.Ref (synthetic "tenantAccessRelation") (Internal.RelationId 0)
    , Internal.tenantIsolationAccessSubjectEndpoint =
        Internal.Ref
          (synthetic "tenantAccessSubject")
          (Internal.EndpointId (Internal.RelationId 0) 0)
    , Internal.tenantIsolationAccessTenantEndpoint =
        Internal.Ref
          (synthetic "tenantAccessTenant")
          (Internal.EndpointId (Internal.RelationId 0) 1)
    }

-- | An actor-free tenant term referencing the view action's parameter
-- at the given position (0: @container : Org@, 1: @target : User@).
tenantArgumentTerm :: Int -> Internal.ValueTerm 'ActorFree
tenantArgumentTerm position =
  Internal.ArgumentTerm
    (synthetic "tenantTerm")
    ( Internal.Ref
        (synthetic "tenantTermName")
        (Internal.ParameterId (Internal.ActionId 0) position)
    )

boolProtectedTerm :: Internal.PolicyTerm 'ActorFree
boolProtectedTerm =
  Internal.ValuePolicyTerm (Internal.BoolTerm (synthetic "protectedTerm") True)

unitProtectedTerm :: Internal.PolicyTerm 'ActorFree
unitProtectedTerm =
  Internal.ValuePolicyTerm (Internal.UnitTerm (synthetic "protectedTerm"))

-- | The complete forged TenantIsolation model: @User@ and @Org@
-- entities, the @Grid@ and @Other@ relations, one action with the
-- parameters @container : Org@ and @target : User@, and one guarantee
-- whose access the check adjusts.  The variants below change one
-- coordinated fact each, so every check pins exactly its intended
-- refusal branch.
tenantModel
  :: (Internal.TenantIsolationAccess -> Internal.TenantIsolationAccess)
  -> Internal.Model
tenantModel adjustAccess =
  tenantModelWith
    (Internal.EntityId 0)
    (adjustAccess wellFormedAccess)
    (tenantArgumentTerm 0)
    boolProtectedTerm

tenantModelWith
  :: Internal.EntityId
  -> Internal.TenantIsolationAccess
  -> Internal.ValueTerm 'ActorFree
  -> Internal.PolicyTerm 'ActorFree
  -> Internal.Model
tenantModelWith memberEntity access tenantTerm protectedTerm =
  Internal.Model
    { Internal.modelName = Sourced (synthetic "name") "Tiny"
    , Internal.modelEntities =
        [ Internal.Entity
            { Internal.entityId = Internal.EntityId 0
            , Internal.entityPath = synthetic "userEntity"
            , Internal.entityName = Sourced (synthetic "userEntityName") "User"
            , Internal.entityAttributes = []
            }
        , Internal.Entity
            { Internal.entityId = Internal.EntityId 1
            , Internal.entityPath = synthetic "orgEntity"
            , Internal.entityName = Sourced (synthetic "orgEntityName") "Org"
            , Internal.entityAttributes = []
            }
        ]
    , Internal.modelEnums = []
    , Internal.modelRelations = [gridRelation memberEntity, otherRelation]
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
                          ( Internal.Ref
                              (synthetic "containerParameterEntity")
                              (Internal.EntityId 1)
                          )
                    }
                , Internal.Parameter
                    { Internal.parameterId =
                        Internal.ParameterId (Internal.ActionId 0) 1
                    , Internal.parameterPath = synthetic "targetParameter"
                    , Internal.parameterName =
                        Sourced (synthetic "targetParameterName") "target"
                    , Internal.parameterType =
                        Internal.EntityRefParameterType
                          (synthetic "targetParameterType")
                          ( Internal.Ref
                              (synthetic "targetParameterEntity")
                              (Internal.EntityId 0)
                          )
                    }
                ]
            , Internal.actionBody =
                Internal.AuthenticatedOnlyBody trueAllow noChangeShape
            }
        ]
    , Internal.modelGuarantees =
        [ Internal.TenantIsolationGuarantee
            (synthetic "guarantee")
            access
            ( Internal.TenantIsolationCase
                { Internal.tenantIsolationCasePath = synthetic "case"
                , Internal.tenantIsolationCaseAction =
                    Internal.Ref (synthetic "caseAction") (Internal.ActionId 0)
                , Internal.tenantIsolationCaseTenant = tenantTerm
                , Internal.tenantIsolationCaseProtected = protectedTerm
                }
                :| []
            )
        ]
    }

-- | The tenant endpoint duplicating the subject endpoint, with the
-- case tenant term retargeted at the @User@-typed parameter so the
-- duplication is the only reported fact.
duplicateAccessEndpointModel :: Internal.Model
duplicateAccessEndpointModel =
  tenantModelWith
    (Internal.EntityId 0)
    wellFormedAccess
      { Internal.tenantIsolationAccessTenantEndpoint =
          Internal.Ref
            (synthetic "tenantAccessTenant")
            (Internal.EndpointId (Internal.RelationId 0) 0)
      }
    (tenantArgumentTerm 1)
    boolProtectedTerm

-- | The subject (member) endpoint referencing @Org@ instead of the
-- distinguished @User@ entity; everything else stays consistent.
wrongSubjectEntityModel :: Internal.Model
wrongSubjectEntityModel =
  tenantModelWith
    (Internal.EntityId 1)
    wellFormedAccess
    (tenantArgumentTerm 0)
    boolProtectedTerm

-- | A tenant term of @EntityRef User@ against the @Org@-typed tenant
-- endpoint.
mismatchedTenantModel :: Internal.Model
mismatchedTenantModel =
  tenantModelWith
    (Internal.EntityId 0)
    wellFormedAccess
    (tenantArgumentTerm 1)
    boolProtectedTerm

-- | A @Unit@-typed protected term.
unitProtectedModel :: Internal.Model
unitProtectedModel =
  tenantModelWith
    (Internal.EntityId 0)
    wellFormedAccess
    (tenantArgumentTerm 0)
    unitProtectedTerm

-- | An escalation case naming no scope term although its authority
-- declares a scope endpoint — the converse of 'strayScopeModel'.
-- The authority itself is well-typed against 'scopedRelation', so
-- the missing scope term is the only inconsistency.
missingScopeModel :: Internal.Model
missingScopeModel =
  baseModel
    { Internal.modelRelations = [scopedRelation]
    , Internal.modelGuarantees =
        [ Internal.NoSelfPrivilegeEscalationGuarantee
            (synthetic "guarantee")
            Internal.Authority
              { Internal.authorityPath = synthetic "authority"
              , Internal.authorityRelation =
                  Internal.Ref (synthetic "authorityRelation") (Internal.RelationId 0)
              , Internal.authoritySubjectEndpoint =
                  Internal.Ref
                    (synthetic "authoritySubject")
                    (Internal.EndpointId (Internal.RelationId 0) 0)
              , Internal.authorityScopeEndpoint =
                  Just
                    ( Internal.Ref
                        (synthetic "authorityScope")
                        (Internal.EndpointId (Internal.RelationId 0) 1)
                    )
              , Internal.authorityAbsenceLevel =
                  Sourced (synthetic "absenceLevel") AbsenceBottom
              , Internal.authorityPayloadOrder =
                  Internal.Ref (synthetic "payloadOrder") (Internal.EnumId 0)
              }
            ( Internal.EscalationCase
                { Internal.escalationCasePath = synthetic "case"
                , Internal.escalationCaseAction =
                    Internal.Ref (synthetic "caseAction") (Internal.ActionId 0)
                , Internal.escalationCaseScope = Nothing
                }
                :| []
            )
        ]
    }
