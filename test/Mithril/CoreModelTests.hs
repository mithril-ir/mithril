{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | White-box checks over the real resolved model.
--
-- These checks run the complete production pipeline — the same
-- @validateCoreFile@ any consumer calls — over the full-coverage
-- fixture, then unwrap the @'CoreDocument' 'Resolved'@ through the
-- package-private @core-internal@ sublibrary and inspect the model it
-- actually carries.
--
-- The expected values are an independent oracle.  Every declaration
-- represented by the coverage fixture — every entity, enum, relation,
-- and action, and every attribute, enum value, endpoint, and
-- parameter they own — has a literal expectation row below: its exact
-- identifier, its exact authored name or value, and its declaration
-- and name-field locations written out as literal segment lists.
-- Actual locations are read back only through 'sourcePathSegments'
-- and compared against those literal lists ('hasSegments' is the one
-- path comparison of this module); the production path constructors
-- ('memberPath' and friends) are deliberately not imported, and no
-- expected 'SourcePath' value is ever constructed, so a defect in
-- production path construction cannot be reproduced by this oracle —
-- it fails these comparisons instead.
--
-- The sublibrary is the deliberate white-box seam: it is private to
-- the package (@visibility: private@), so nothing here is public API,
-- no observer is added to the library, and the downstream
-- compile-fail probes still prove external code cannot import these
-- modules.  The types inspected here are the very types the public
-- pipeline produced — no copied definitions, no second
-- representation.
--
-- Determinism is checked for real: two independent full pipeline runs
-- (separate file reads, parses, validations, and resolutions) must
-- produce structurally equal models under the representation's 'Eq',
-- which compares every identifier, path, and name.
module Mithril.CoreModelTests
  ( tests
  ) where

import Data.Foldable (toList)
import qualified Data.List.NonEmpty as NonEmpty
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Command.Validate (validateCoreFile)
import Mithril.Core.Internal.Document (CoreDocument (..))
import Mithril.Core.Internal.Resolved
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , sourcePathSegments
  )
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel (..)
  , OneOrTwo (..)
  )
import Mithril.Test (Check, check)

-- | The full-coverage fixture, resolved from the package root (which
-- is where @cabal test@ runs the suite).
coveragePath :: FilePath
coveragePath = "test/fixtures/coverage.mir.json"

-- | All white-box model checks.
tests :: IO [Check]
tests = do
  firstOutcome <- validateCoreFile coveragePath
  secondOutcome <- validateCoreFile coveragePath
  pure $ case (firstOutcome, secondOutcome) of
    (Right (CoreDocument firstModel), Right (CoreDocument secondModel)) ->
      check
        "two independent full pipeline runs produce equal resolved models"
        (firstModel == secondModel)
        : modelChecks firstModel
    _ ->
      [ check
          "the coverage fixture resolves twice through the public pipeline (prerequisite)"
          False
      ]

--------------------------------------------------------------------
-- The path oracle
--------------------------------------------------------------------

-- | The one path comparison of this module: the actual location's raw
-- segments, read through 'sourcePathSegments', must equal a literal
-- segment list written in the oracle below.  Expected paths are never
-- built with the production path constructors.
hasSegments :: [Text] -> SourcePath -> Bool
hasSegments expected actual = sourcePathSegments actual == expected

-- | A located value carries the expected value at the expected
-- literal segments.
matchesSourced :: Eq a => [Text] -> a -> Sourced a -> Bool
matchesSourced expectedSegments expected actual =
  hasSegments expectedSegments (sourcedPath actual)
    && sourcedValue actual == expected

-- | A resolved reference resolved to the expected identifier, at the
-- expected literal segments.
matchesRef :: Eq target => [Text] -> target -> Ref target -> Bool
matchesRef expectedSegments expected actual =
  hasSegments expectedSegments (refPath actual)
    && refTarget actual == expected

--------------------------------------------------------------------
-- Declaration expectation tables
--------------------------------------------------------------------

-- | One oracle row per entity declaration: exact identifier, exact
-- authored name, literal declaration-path segments, literal
-- name-field-path segments.
entityTable :: [(EntityId, Text, [Text], [Text])]
entityTable =
  [ ( EntityId 0
    , "User"
    , ["schema", "entities", "0"]
    , ["schema", "entities", "0", "name"]
    )
  , ( EntityId 1
    , "Organization"
    , ["schema", "entities", "1"]
    , ["schema", "entities", "1", "name"]
    )
  , ( EntityId 2
    , "Project"
    , ["schema", "entities", "2"]
    , ["schema", "entities", "2", "name"]
    )
  ]

-- | The expected declared type of an attribute: the literal segments
-- of the type node and, for the referencing types, the literal
-- segments and target of the resolved reference.
data ExpectedAttributeType
  = ExpectedBoolAttribute [Text]
  | ExpectedEnumAttribute [Text] [Text] EnumId
  | ExpectedEntityRefAttribute [Text] [Text] EntityId

matchesAttributeType :: ExpectedAttributeType -> AttributeType -> Bool
matchesAttributeType expected actual = case (expected, actual) of
  (ExpectedBoolAttribute typeSegments, BoolAttributeType path) ->
    hasSegments typeSegments path
  (ExpectedEnumAttribute typeSegments refSegments target, EnumAttributeType path ref) ->
    hasSegments typeSegments path && matchesRef refSegments target ref
  (ExpectedEntityRefAttribute typeSegments refSegments target, EntityRefAttributeType path ref) ->
    hasSegments typeSegments path && matchesRef refSegments target ref
  _ -> False

-- | One oracle row per attribute of every entity: exact owner-encoded
-- identifier, exact authored name, literal declaration-path segments,
-- literal name-field-path segments, and the expected declared type.
attributeTable :: [(AttributeId, Text, [Text], [Text], ExpectedAttributeType)]
attributeTable =
  [ ( AttributeId (EntityId 0) 0
    , "active"
    , ["schema", "entities", "0", "attributes", "0"]
    , ["schema", "entities", "0", "attributes", "0", "name"]
    , ExpectedBoolAttribute
        ["schema", "entities", "0", "attributes", "0", "type"]
    )
  , ( AttributeId (EntityId 0) 1
    , "level"
    , ["schema", "entities", "0", "attributes", "1"]
    , ["schema", "entities", "0", "attributes", "1", "name"]
    , ExpectedEnumAttribute
        ["schema", "entities", "0", "attributes", "1", "type"]
        ["schema", "entities", "0", "attributes", "1", "type", "enum"]
        (EnumId 0)
    )
  , ( AttributeId (EntityId 0) 2
    , "sponsor"
    , ["schema", "entities", "0", "attributes", "2"]
    , ["schema", "entities", "0", "attributes", "2", "name"]
    , ExpectedEntityRefAttribute
        ["schema", "entities", "0", "attributes", "2", "type"]
        ["schema", "entities", "0", "attributes", "2", "type", "entity"]
        (EntityId 0)
    )
  , ( AttributeId (EntityId 1) 0
    , "owner"
    , ["schema", "entities", "1", "attributes", "0"]
    , ["schema", "entities", "1", "attributes", "0", "name"]
    , ExpectedEntityRefAttribute
        ["schema", "entities", "1", "attributes", "0", "type"]
        ["schema", "entities", "1", "attributes", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( AttributeId (EntityId 2) 0
    , "organization"
    , ["schema", "entities", "2", "attributes", "0"]
    , ["schema", "entities", "2", "attributes", "0", "name"]
    , ExpectedEntityRefAttribute
        ["schema", "entities", "2", "attributes", "0", "type"]
        ["schema", "entities", "2", "attributes", "0", "type", "entity"]
        (EntityId 1)
    )
  ]

-- | One oracle row per enum declaration.
enumTable :: [(EnumId, Text, [Text], [Text])]
enumTable =
  [ ( EnumId 0
    , "Level"
    , ["schema", "enums", "0"]
    , ["schema", "enums", "0", "name"]
    )
  , ( EnumId 1
    , "Badge"
    , ["schema", "enums", "1"]
    , ["schema", "enums", "1", "name"]
    )
  ]

-- | One oracle row per enum value of every enum: exact enum-owned
-- identifier, exact authored value text, and the literal segments of
-- the value.  An enum value is authored as a bare string, so its
-- declaration path and its value-field path are the same location.
enumValueTable :: [(EnumValueId, Text, [Text])]
enumValueTable =
  [ ( EnumValueId (EnumId 0) 0
    , "Low"
    , ["schema", "enums", "0", "values", "0"]
    )
  , ( EnumValueId (EnumId 0) 1
    , "High"
    , ["schema", "enums", "0", "values", "1"]
    )
  , ( EnumValueId (EnumId 1) 0
    , "Star"
    , ["schema", "enums", "1", "values", "0"]
    )
  ]

-- | The expected relation payload: the literal segments of the
-- payload node and, for an enum payload, of its resolved reference.
data ExpectedPayloadType
  = ExpectedUnitPayload [Text]
  | ExpectedEnumPayload [Text] [Text] EnumId

matchesPayloadType :: ExpectedPayloadType -> PayloadType -> Bool
matchesPayloadType expected actual = case (expected, actual) of
  (ExpectedUnitPayload payloadSegments, UnitPayloadType path) ->
    hasSegments payloadSegments path
  (ExpectedEnumPayload payloadSegments refSegments target, EnumPayloadType path ref) ->
    hasSegments payloadSegments path && matchesRef refSegments target ref
  _ -> False

-- | One oracle row per relation declaration, with its expected
-- payload.
relationTable :: [(RelationId, Text, [Text], [Text], ExpectedPayloadType)]
relationTable =
  [ ( RelationId 0
    , "Membership"
    , ["schema", "relations", "0"]
    , ["schema", "relations", "0", "name"]
    , ExpectedEnumPayload
        ["schema", "relations", "0", "payload"]
        ["schema", "relations", "0", "payload", "enum"]
        (EnumId 0)
    )
  , ( RelationId 1
    , "Flagged"
    , ["schema", "relations", "1"]
    , ["schema", "relations", "1", "name"]
    , ExpectedUnitPayload
        ["schema", "relations", "1", "payload"]
    )
  ]

-- | One oracle row per endpoint of every relation: exact
-- relation-owned identifier, exact authored name, literal
-- declaration-path segments, literal name-field-path segments, and
-- the literal segments and target of the resolved entity reference.
endpointTable :: [(EndpointId, Text, [Text], [Text], [Text], EntityId)]
endpointTable =
  [ ( EndpointId (RelationId 0) 0
    , "user"
    , ["schema", "relations", "0", "endpoints", "0"]
    , ["schema", "relations", "0", "endpoints", "0", "name"]
    , ["schema", "relations", "0", "endpoints", "0", "entity"]
    , EntityId 0
    )
  , ( EndpointId (RelationId 0) 1
    , "organization"
    , ["schema", "relations", "0", "endpoints", "1"]
    , ["schema", "relations", "0", "endpoints", "1", "name"]
    , ["schema", "relations", "0", "endpoints", "1", "entity"]
    , EntityId 1
    )
  , ( EndpointId (RelationId 1) 0
    , "subject"
    , ["schema", "relations", "1", "endpoints", "0"]
    , ["schema", "relations", "1", "endpoints", "0", "name"]
    , ["schema", "relations", "1", "endpoints", "0", "entity"]
    , EntityId 0
    )
  ]

-- | One oracle row per action declaration.
actionTable :: [(ActionId, Text, [Text], [Text])]
actionTable =
  [ ( ActionId 0
    , "Project.read"
    , ["actions", "0"]
    , ["actions", "0", "name"]
    )
  , ( ActionId 1
    , "User.invite"
    , ["actions", "1"]
    , ["actions", "1", "name"]
    )
  , ( ActionId 2
    , "User.purge"
    , ["actions", "2"]
    , ["actions", "2", "name"]
    )
  , ( ActionId 3
    , "Membership.set"
    , ["actions", "3"]
    , ["actions", "3", "name"]
    )
  , ( ActionId 4
    , "User.unflag"
    , ["actions", "4"]
    , ["actions", "4", "name"]
    )
  , ( ActionId 5
    , "User.touch"
    , ["actions", "5"]
    , ["actions", "5", "name"]
    )
  , ( ActionId 6
    , "Status.ping"
    , ["actions", "6"]
    , ["actions", "6", "name"]
    )
  , ( ActionId 7
    , "Organization.register"
    , ["actions", "7"]
    , ["actions", "7", "name"]
    )
  , ( ActionId 8
    , "Membership.expire"
    , ["actions", "8"]
    , ["actions", "8", "name"]
    )
  , ( ActionId 9
    , "User.forget"
    , ["actions", "9"]
    , ["actions", "9", "name"]
    )
  , ( ActionId 10
    , "User.unmark"
    , ["actions", "10"]
    , ["actions", "10", "name"]
    )
  , ( ActionId 11
    , "Status.noop"
    , ["actions", "11"]
    , ["actions", "11", "name"]
    )
  ]

-- | One oracle row per parameter of every action: exact action-owned
-- identifier, exact authored name, literal declaration-path segments,
-- literal name-field-path segments.  Actions 5 (@User.touch@) and 11
-- (@Status.noop@) declare no parameters, so no row carries their
-- identifiers.
parameterTable :: [(ParameterId, Text, [Text], [Text])]
parameterTable =
  [ ( ParameterId (ActionId 0) 0
    , "project"
    , ["actions", "0", "parameters", "0"]
    , ["actions", "0", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 0) 1
    , "flag"
    , ["actions", "0", "parameters", "1"]
    , ["actions", "0", "parameters", "1", "name"]
    )
  , ( ParameterId (ActionId 0) 2
    , "token"
    , ["actions", "0", "parameters", "2"]
    , ["actions", "0", "parameters", "2", "name"]
    )
  , ( ParameterId (ActionId 0) 3
    , "level"
    , ["actions", "0", "parameters", "3"]
    , ["actions", "0", "parameters", "3", "name"]
    )
  , ( ParameterId (ActionId 1) 0
    , "level"
    , ["actions", "1", "parameters", "0"]
    , ["actions", "1", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 2) 0
    , "target"
    , ["actions", "2", "parameters", "0"]
    , ["actions", "2", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 3) 0
    , "target"
    , ["actions", "3", "parameters", "0"]
    , ["actions", "3", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 3) 1
    , "organization"
    , ["actions", "3", "parameters", "1"]
    , ["actions", "3", "parameters", "1", "name"]
    )
  , ( ParameterId (ActionId 3) 2
    , "level"
    , ["actions", "3", "parameters", "2"]
    , ["actions", "3", "parameters", "2", "name"]
    )
  , ( ParameterId (ActionId 4) 0
    , "target"
    , ["actions", "4", "parameters", "0"]
    , ["actions", "4", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 6) 0
    , "flag"
    , ["actions", "6", "parameters", "0"]
    , ["actions", "6", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 7) 0
    , "founder"
    , ["actions", "7", "parameters", "0"]
    , ["actions", "7", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 8) 0
    , "target"
    , ["actions", "8", "parameters", "0"]
    , ["actions", "8", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 8) 1
    , "organization"
    , ["actions", "8", "parameters", "1"]
    , ["actions", "8", "parameters", "1", "name"]
    )
  , ( ParameterId (ActionId 9) 0
    , "target"
    , ["actions", "9", "parameters", "0"]
    , ["actions", "9", "parameters", "0", "name"]
    )
  , ( ParameterId (ActionId 10) 0
    , "target"
    , ["actions", "10", "parameters", "0"]
    , ["actions", "10", "parameters", "0", "name"]
    )
  ]

--------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------

-- | Facts about the successfully resolved coverage model, asserted
-- against the literal oracle above.
modelChecks :: Model -> [Check]
modelChecks model =
  concat
    [ [ check
          "the document name keeps its text and its source path"
          (matchesSourced ["name"] "Coverage" (modelName model))
      ]
    , declarationChecks
        "entity"
        entityTable
        (modelEntities model)
        (\(_, name, _, _) -> Text.unpack name)
        (\(expectedId, name, declSegments, nameSegments) actual ->
          entityId actual == expectedId
            && hasSegments declSegments (entityPath actual)
            && matchesSourced nameSegments name (entityName actual))
    , declarationChecks
        "attribute"
        attributeTable
        (concatMap entityAttributes (modelEntities model))
        (\(expectedId, name, _, _, _) ->
          Text.unpack name <> " (" <> show expectedId <> ")")
        (\(expectedId, name, declSegments, nameSegments, expectedType) actual ->
          attributeId actual == expectedId
            && hasSegments declSegments (attributePath actual)
            && matchesSourced nameSegments name (attributeName actual)
            && matchesAttributeType expectedType (attributeType actual))
    , declarationChecks
        "enum"
        enumTable
        (modelEnums model)
        (\(_, name, _, _) -> Text.unpack name)
        (\(expectedId, name, declSegments, nameSegments) actual ->
          enumDefinitionId actual == expectedId
            && hasSegments declSegments (enumDefinitionPath actual)
            && matchesSourced nameSegments name (enumDefinitionName actual))
    , declarationChecks
        "enum value"
        enumValueTable
        (concatMap (NonEmpty.toList . enumDefinitionValues) (modelEnums model))
        (\(expectedId, value, _) ->
          Text.unpack value <> " (" <> show expectedId <> ")")
        (\(expectedId, value, valueSegments) actual ->
          enumMemberId actual == expectedId
            && matchesSourced valueSegments value (enumMemberName actual))
    , declarationChecks
        "relation"
        relationTable
        (modelRelations model)
        (\(_, name, _, _, _) -> Text.unpack name)
        (\(expectedId, name, declSegments, nameSegments, expectedPayload) actual ->
          relationId actual == expectedId
            && hasSegments declSegments (relationPath actual)
            && matchesSourced nameSegments name (relationName actual)
            && matchesPayloadType expectedPayload (relationPayload actual))
    , declarationChecks
        "endpoint"
        endpointTable
        (concatMap (toList . relationEndpoints) (modelRelations model))
        (\(expectedId, name, _, _, _, _) ->
          Text.unpack name <> " (" <> show expectedId <> ")")
        (\(expectedId, name, declSegments, nameSegments, entitySegments, entity) actual ->
          endpointId actual == expectedId
            && hasSegments declSegments (endpointPath actual)
            && matchesSourced nameSegments name (endpointName actual)
            && matchesRef entitySegments entity (endpointEntity actual))
    , declarationChecks
        "action"
        actionTable
        (modelActions model)
        (\(_, name, _, _) -> Text.unpack name)
        (\(expectedId, name, declSegments, nameSegments) actual ->
          actionId actual == expectedId
            && hasSegments declSegments (actionPath actual)
            && matchesSourced nameSegments name (actionName actual))
    , declarationChecks
        "parameter"
        parameterTable
        (concatMap actionParameters (modelActions model))
        (\(expectedId, name, _, _) ->
          Text.unpack name <> " (" <> show expectedId <> ")")
        (\(expectedId, name, declSegments, nameSegments) actual ->
          parameterId actual == expectedId
            && hasSegments declSegments (parameterPath actual)
            && matchesSourced nameSegments name (parameterName actual))
    , enumOrderChecks model
    , referenceChecks model
    ]

-- | One count check plus one check per oracle row for a declaration
-- category.  The count check makes the coverage exhaustive (no
-- declaration of the fixture may be omitted by the model, and none
-- may appear that the oracle does not list); the per-row identifier
-- comparisons pin the pairing, since every owner-local identifier
-- embeds its owner.
declarationChecks ::
  String ->
  [row] ->
  [actual] ->
  (row -> String) ->
  (row -> actual -> Bool) ->
  [Check]
declarationChecks category table actuals describe matches =
  check
    ("the model carries exactly the " <> show (length table)
       <> " " <> category <> " declarations of the oracle")
    (length actuals == length table)
    : [ check
          (category <> " " <> describe row <> " matches its oracle row")
          (matches row actual)
      | (row, actual) <- zip table actuals
      ]

-- | Level orders its own two values (asserted by identifier at the
-- authored order locations); Badge declares no order.  Whether an
-- order is a permutation remains a typechecker question.
enumOrderChecks :: Model -> [Check]
enumOrderChecks model =
  [ check
      "Level's order references its own values in authored order"
      ( case modelEnums model of
          levelEnum : _ ->
            case enumDefinitionOrder levelEnum of
              Just (lowRef :| [highRef]) ->
                matchesRef
                  ["schema", "enums", "0", "order", "0"]
                  (EnumValueId (EnumId 0) 0)
                  lowRef
                  && matchesRef
                    ["schema", "enums", "0", "order", "1"]
                    (EnumValueId (EnumId 0) 1)
                    highRef
              _ -> False
          [] -> False
      )
  , check
      "Badge declares no order"
      ( case drop 1 (modelEnums model) of
          badge : _ ->
            case enumDefinitionOrder badge of
              Nothing -> True
              Just _ -> False
          [] -> False
      )
  ]

-- | The retained reference, term, guarantee, Bottom, and
-- endpoint-arity assertions, with every expected location a literal
-- segment list.
referenceChecks :: Model -> [Check]
referenceChecks model =
  [ check
      "a nested attribute projection resolves through Project to Organization's owner"
      ( withAction 0 $ \projectRead ->
          case actionBody projectRead of
            AuthenticatedOnlyBody _ (ReadShape effectPath resultPath observed) ->
              hasSegments ["actions", "0", "effect"] effectPath
                && hasSegments ["actions", "0", "result"] resultPath
                && case observed of
                     AttributeTerm
                       outerPath
                       (AttributeTerm
                          innerPath
                          (ArgumentTerm argumentPath argumentRef)
                          innerRef)
                       outerRef ->
                         hasSegments
                           ["actions", "0", "result", "entity"]
                           outerPath
                           && hasSegments
                             ["actions", "0", "result", "entity", "source"]
                             innerPath
                           && hasSegments
                             ["actions", "0", "result", "entity", "source", "source"]
                             argumentPath
                           && matchesRef
                             ["actions", "0", "result", "entity", "source", "source", "name"]
                             (ParameterId (ActionId 0) 0)
                             argumentRef
                           && matchesRef
                             ["actions", "0", "result", "entity", "source", "attribute"]
                             (AttributeId (EntityId 2) 0)
                             innerRef
                           && matchesRef
                             ["actions", "0", "result", "entity", "attribute"]
                             (AttributeId (EntityId 1) 0)
                             outerRef
                     _ -> False
            _ -> False
      )
  , check
      "Actor resolves to the User entity identifier inside a CreateEntity initializer"
      ( withAction 1 $ \userInvite ->
          case actionBody userInvite of
            AuthenticatedOnlyBody _ (CreateShape effect resultPath) ->
              hasSegments ["actions", "1", "effect"] (createEntityEffectPath effect)
                && matchesRef
                  ["actions", "1", "effect", "entity"]
                  (EntityId 0)
                  (createEntityEffectEntity effect)
                -- Ascending initializer key order, entity-owned key
                -- identifiers, an argument resolved in this action's
                -- environment, and Actor resolved to EntityId 0.
                && case createEntityEffectInitializers effect of
                     [activeInit, levelInit, sponsorInit] ->
                       matchesRef
                         ["actions", "1", "effect", "attributes", "active"]
                         (AttributeId (EntityId 0) 0)
                         (initializerKey activeInit)
                         && ( case initializerValue activeInit of
                                BoolTerm path True ->
                                  hasSegments
                                    ["actions", "1", "effect", "attributes", "active"]
                                    path
                                _ -> False
                            )
                         && matchesRef
                           ["actions", "1", "effect", "attributes", "level"]
                           (AttributeId (EntityId 0) 1)
                           (initializerKey levelInit)
                         && ( case initializerValue levelInit of
                                ArgumentTerm path ref ->
                                  hasSegments
                                    ["actions", "1", "effect", "attributes", "level"]
                                    path
                                    && matchesRef
                                      ["actions", "1", "effect", "attributes", "level", "name"]
                                      (ParameterId (ActionId 1) 0)
                                      ref
                                _ -> False
                            )
                         && matchesRef
                           ["actions", "1", "effect", "attributes", "sponsor"]
                           (AttributeId (EntityId 0) 2)
                           (initializerKey sponsorInit)
                         && ( case initializerValue sponsorInit of
                                ActorTerm path userEntity ->
                                  hasSegments
                                    ["actions", "1", "effect", "attributes", "sponsor"]
                                    path
                                    && userEntity == EntityId 0
                                _ -> False
                            )
                     _ -> False
                && hasSegments ["actions", "1", "result"] resultPath
            _ -> False
      )
  , check
      "an enum payload resolves to enum-owned identifiers in an actor-free SetRelation"
      ( withAction 8 $ \membershipExpire ->
          case actionBody membershipExpire of
            AnyPrincipalBody _ (MutationShape (SetRelationEffect effectPath relation endpoints payload) resultPath) ->
              hasSegments ["actions", "8", "effect"] effectPath
                && matchesRef
                  ["actions", "8", "effect", "relation"]
                  (RelationId 0)
                  relation
                && case endpoints of
                     Two targetTerm organizationTerm ->
                       ( case targetTerm of
                           ArgumentTerm path ref ->
                             hasSegments
                               ["actions", "8", "effect", "endpoints", "0"]
                               path
                               && matchesRef
                                 ["actions", "8", "effect", "endpoints", "0", "name"]
                                 (ParameterId (ActionId 8) 0)
                                 ref
                           _ -> False
                       )
                         && ( case organizationTerm of
                                ArgumentTerm path ref ->
                                  hasSegments
                                    ["actions", "8", "effect", "endpoints", "1"]
                                    path
                                    && matchesRef
                                      ["actions", "8", "effect", "endpoints", "1", "name"]
                                      (ParameterId (ActionId 8) 1)
                                      ref
                                _ -> False
                            )
                     One _ -> False
                && case payload of
                     EnumTerm path enumRef valueRef ->
                       hasSegments ["actions", "8", "effect", "payload"] path
                         && matchesRef
                           ["actions", "8", "effect", "payload", "enum"]
                           (EnumId 0)
                           enumRef
                         && matchesRef
                           ["actions", "8", "effect", "payload", "value"]
                           (EnumValueId (EnumId 0) 0)
                           valueRef
                     _ -> False
                && hasSegments ["actions", "8", "result"] resultPath
            _ -> False
      )
  , -- The deliberate ill-typed construct of the fixture, witnessed
    -- inside the model: the anonymous-branch lookup carries two
    -- resolved endpoint terms while the Flagged relation it references
    -- declares exactly one endpoint.  Both sides sit in the same
    -- model, so this is also the regression that resolution performs
    -- no arity checking.
    check
      "the ill-typed lookup keeps two endpoint terms against the one-endpoint Flagged relation"
      ( flaggedDeclaresOneEndpoint
          && withAction 6 (\statusPing ->
                case actionBody statusPing of
                  AnyPrincipalBody allow _ ->
                    case anyPrincipalAnonymous allow of
                      OrTerm _ (AndTerm _ _ (NotTerm _ (IsSomeTerm _ flaggedLookup))) _ ->
                        case flaggedLookup of
                          LookupTerm lookupPath relationRef (Two flagTerm literalTerm) ->
                            hasSegments
                              ["actions", "6", "allow", "anonymous", "left", "right", "value", "value"]
                              lookupPath
                              && matchesRef
                                ["actions", "6", "allow", "anonymous", "left", "right", "value", "value", "relation"]
                                (RelationId 1)
                                relationRef
                              && ( case flagTerm of
                                     ArgumentTerm path ref ->
                                       hasSegments
                                         ["actions", "6", "allow", "anonymous", "left", "right", "value", "value", "endpoints", "0"]
                                         path
                                         && matchesRef
                                           ["actions", "6", "allow", "anonymous", "left", "right", "value", "value", "endpoints", "0", "name"]
                                           (ParameterId (ActionId 6) 0)
                                           ref
                                     _ -> False
                                 )
                              && ( case literalTerm of
                                     BoolTerm path False ->
                                       hasSegments
                                         ["actions", "6", "allow", "anonymous", "left", "right", "value", "value", "endpoints", "1"]
                                         path
                                     _ -> False
                                 )
                          _ -> False
                      _ -> False
                  _ -> False)
      )
  , check
      "an actor-free CreateEntity resolves its target entity and initializer key"
      ( withAction 7 $ \organizationRegister ->
          case actionBody organizationRegister of
            AnyPrincipalBody _ (CreateShape effect resultPath) ->
              matchesRef
                ["actions", "7", "effect", "entity"]
                (EntityId 1)
                (createEntityEffectEntity effect)
                && case createEntityEffectInitializers effect of
                     [ownerInit] ->
                       matchesRef
                         ["actions", "7", "effect", "attributes", "owner"]
                         (AttributeId (EntityId 1) 0)
                         (initializerKey ownerInit)
                         && ( case initializerValue ownerInit of
                                ArgumentTerm path ref ->
                                  hasSegments
                                    ["actions", "7", "effect", "attributes", "owner"]
                                    path
                                    && matchesRef
                                      ["actions", "7", "effect", "attributes", "owner", "name"]
                                      (ParameterId (ActionId 7) 0)
                                      ref
                                _ -> False
                            )
                     _ -> False
                && hasSegments ["actions", "7", "result"] resultPath
            _ -> False
      )
  , check
      "the AuthenticatedMutation guarantee keeps its declaration path"
      ( withGuarantee 0 $ \guarantee ->
          case guarantee of
            AuthenticatedMutationGuarantee path ->
              hasSegments ["guarantees", "0"] path
            _ -> False
      )
  , check
      "a TenantIsolation case resolves its action and its terms in that action's environment"
      ( withGuarantee 1 $ \guarantee ->
          case guarantee of
            TenantIsolationGuarantee path (tenantCase :| []) ->
              hasSegments ["guarantees", "1"] path
                && matchesRef
                  ["guarantees", "1", "cases", "0", "action"]
                  (ActionId 0)
                  (tenantIsolationCaseAction tenantCase)
                && case tenantIsolationCaseTenant tenantCase of
                     AttributeTerm
                       tenantPath
                       (ArgumentTerm sourcePath sourceRef)
                       attributeRef ->
                         hasSegments
                           ["guarantees", "1", "cases", "0", "tenant"]
                           tenantPath
                           && hasSegments
                             ["guarantees", "1", "cases", "0", "tenant", "source"]
                             sourcePath
                           && matchesRef
                             ["guarantees", "1", "cases", "0", "tenant", "source", "name"]
                             (ParameterId (ActionId 0) 0)
                             sourceRef
                           && matchesRef
                             ["guarantees", "1", "cases", "0", "tenant", "attribute"]
                             (AttributeId (EntityId 2) 0)
                             attributeRef
                     _ -> False
            _ -> False
      )
  , check
      "the NoSelfPrivilegeEscalation authority resolves relation, endpoints, Bottom path, and payload order"
      ( withGuarantee 2 $ \guarantee ->
          case guarantee of
            NoSelfPrivilegeEscalationGuarantee guaranteePath authority (setCase :| [touchCase]) ->
              hasSegments ["guarantees", "2"] guaranteePath
                && matchesRef
                  ["guarantees", "2", "authority", "relation"]
                  (RelationId 0)
                  (authorityRelation authority)
                && matchesRef
                  ["guarantees", "2", "authority", "subjectEndpoint"]
                  (EndpointId (RelationId 0) 0)
                  (authoritySubjectEndpoint authority)
                && ( case authorityScopeEndpoint authority of
                       Just scopeRef ->
                         matchesRef
                           ["guarantees", "2", "authority", "scopeEndpoints", "0"]
                           (EndpointId (RelationId 0) 1)
                           scopeRef
                       Nothing -> False
                   )
                && matchesSourced
                  ["guarantees", "2", "authority", "absenceLevel"]
                  AbsenceBottom
                  (authorityAbsenceLevel authority)
                && matchesRef
                  ["guarantees", "2", "authority", "payloadOrder"]
                  (EnumId 0)
                  (authorityPayloadOrder authority)
                && matchesRef
                  ["guarantees", "2", "cases", "0", "action"]
                  (ActionId 3)
                  (escalationCaseAction setCase)
                && ( case escalationCaseScope setCase of
                       Just (ArgumentTerm scopePath scopeRef) ->
                         hasSegments
                           ["guarantees", "2", "cases", "0", "scope", "0"]
                           scopePath
                           && matchesRef
                             ["guarantees", "2", "cases", "0", "scope", "0", "name"]
                             (ParameterId (ActionId 3) 1)
                             scopeRef
                       _ -> False
                   )
                && matchesRef
                  ["guarantees", "2", "cases", "1", "action"]
                  (ActionId 5)
                  (escalationCaseAction touchCase)
                && ( case escalationCaseScope touchCase of
                       Nothing -> True
                       Just _ -> False
                   )
            _ -> False
      )
  , check
      "the arity-one authority keeps no scope endpoint and the unordered payload-order enum"
      ( withGuarantee 3 $ \guarantee ->
          case guarantee of
            NoSelfPrivilegeEscalationGuarantee guaranteePath authority (unflagCase :| []) ->
              hasSegments ["guarantees", "3"] guaranteePath
                && matchesRef
                  ["guarantees", "3", "authority", "relation"]
                  (RelationId 1)
                  (authorityRelation authority)
                && matchesRef
                  ["guarantees", "3", "authority", "subjectEndpoint"]
                  (EndpointId (RelationId 1) 0)
                  (authoritySubjectEndpoint authority)
                && ( case authorityScopeEndpoint authority of
                       Nothing -> True
                       Just _ -> False
                   )
                && matchesSourced
                  ["guarantees", "3", "authority", "absenceLevel"]
                  AbsenceBottom
                  (authorityAbsenceLevel authority)
                && matchesRef
                  ["guarantees", "3", "authority", "payloadOrder"]
                  (EnumId 1)
                  (authorityPayloadOrder authority)
                && matchesRef
                  ["guarantees", "3", "cases", "0", "action"]
                  (ActionId 4)
                  (escalationCaseAction unflagCase)
                && ( case escalationCaseScope unflagCase of
                       Nothing -> True
                       Just _ -> False
                   )
            _ -> False
      )
  ]
  where
    withAction index continue =
      case drop index (modelActions model) of
        action : _ -> continue action
        [] -> False
    withGuarantee index continue =
      case drop index (modelGuarantees model) of
        guarantee : _ -> continue guarantee
        [] -> False
    flaggedDeclaresOneEndpoint =
      case drop 1 (modelRelations model) of
        flagged : _ ->
          case relationEndpoints flagged of
            One _ -> True
            Two _ _ -> False
        [] -> False
