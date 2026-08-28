{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | White-box checks over the real typed normalized model.
--
-- These checks run the production pipeline through its public stage
-- functions — parse, structural validation against the compiled-in
-- schema, name resolution, static typing, and normalization, the
-- same calls any consumer makes — over the well-typed full-coverage
-- fixture, then unwrap the @'CoreDocument' 'Normalized'@ through the
-- package-private @core-internal@ sublibrary and inspect the
-- normalized model it actually carries.
--
-- The expected values are an independent oracle in the discipline of
-- "Mithril.CoreModelTests": every declaration of the fixture has a
-- literal expectation row — exact identifier, authored name,
-- declaration and name-field locations as literal segment lists —
-- and the normalization-specific content is pinned on top of it:
-- the static type stamped on every inspected term, the materialized
-- enum ranks (including a rank order that differs from declaration
-- order), the explicit ordered reading of every @LessOrEqual@, the
-- endpoint bindings of lookups and relation effects, the
-- @CreateEntity@ initializers in target-attribute declaration order
-- (differing from the resolved model's ascending key order), the
-- explicit principal-mode branches, and the guarantee structure with
-- its scope binding.  Actual locations are read back only through
-- 'sourcePathSegments' and compared against literal segment lists;
-- the production path constructors are deliberately not imported.
--
-- The as-authored no-transformation pins live here too: an
-- @And(true, true)@ allow, an @Or(..., false)@ operand, and the
-- authored operand order of an @Equal@ must all survive
-- normalization verbatim — normalization performs no boolean
-- simplification, constant folding, or operand reordering.
--
-- A final section walks every term of the normalized model and pins
-- that all annotations and ordered readings agree with the one
-- shared statement of the declared-type projections and the ordered
-- classification — the consumption checks described at
-- 'sharedProjectionChecks'.
--
-- Determinism is checked for real: two independent full pipeline
-- runs (separate file reads, parses, validations, resolutions,
-- typechecks, and normalizations) must produce structurally equal
-- normalized models under the representation's 'Eq'.
module Mithril.NormalizedModelTests
  ( tests
  ) where

import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Core.Internal.Document (CoreDocument (..))
import Mithril.Core.Internal.Normalized
import Mithril.Core.Internal.Resolved
  ( ActionId (..)
  , AttributeId (..)
  , EndpointId (..)
  , EntityId (..)
  , EnumId (..)
  , EnumValueId (..)
  , ParameterId (..)
  , Ref (..)
  , RelationId (..)
  )
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , sourcePathSegments
  )
import Mithril.Core.Internal.StaticType
  ( PolicyType (..)
  , ValueType (..)
  , orderedPolicyType
  , orderedTypeEnum
  )
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel (..)
  , OneOrTwo (..)
  )
import Mithril.Core.Normalization (Normalized, normalizeCoreDocument)
import Mithril.Core.Resolution (resolveCoreDocument)
import Mithril.Core.Typing (typecheckCoreDocument)
import Mithril.Core.Validation
  ( bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Test (Check, check)

-- | The well-typed full-coverage fixture, normalized from the
-- package root (which is where @cabal test@ runs the suite).
welltypedPath :: FilePath
welltypedPath = "test/fixtures/welltyped.mir.json"

-- | All white-box normalized-model checks.
tests :: IO [Check]
tests = do
  firstOutcome <- normalizeWelltypedFile
  secondOutcome <- normalizeWelltypedFile
  pure $ case (firstOutcome, secondOutcome) of
    (Just (CoreDocument firstModel), Just (CoreDocument secondModel)) ->
      check
        "two independent full pipeline runs produce equal normalized models"
        (firstModel == secondModel)
        : modelChecks firstModel
    _ ->
      [ check
          "the well-typed fixture normalizes twice through the public pipeline (prerequisite)"
          False
      ]

-- | Every stored @Actor@ entity of an action's allow policies and
-- effect terms, in authored order.
actionActors :: Action -> [EntityId]
actionActors action =
  case actionBody action of
    AuthenticatedOnlyBody allow shape -> policyActors allow <> shapeActors shape
    AnyPrincipalBody _ shape -> shapeActors shape
  where
    shapeActors :: ActionShape availability -> [EntityId]
    shapeActors shape =
      case shape of
        MutationShape (SetRelationEffect _ _ bindings payload) _ ->
          concatMap (valueActors . endpointBindingTerm) (endpointList bindings) <> valueActors payload
        MutationShape (RemoveRelationEffect _ _ bindings) _ ->
          concatMap (valueActors . endpointBindingTerm) (endpointList bindings)
        _ -> []
    endpointList :: OneOrTwo a -> [a]
    endpointList (One a) = [a]
    endpointList (Two a b) = [a, b]
    valueActors :: ValueTerm availability -> [EntityId]
    valueActors term =
      case valueTermNode term of
        ActorNode e -> [e]
        AttributeNode source _ -> valueActors source
        _ -> []
    policyActors :: PolicyTerm availability -> [EntityId]
    policyActors term =
      case policyTermNode term of
        ValuePolicyNode v -> valueActors v
        LookupNode _ bindings -> concatMap (valueActors . endpointBindingTerm) (endpointList bindings)
        NoneNode _ -> []
        SomeNode v -> valueActors v
        IsSomeNode p -> policyActors p
        EqualNode l r -> policyActors l <> policyActors r
        LessOrEqualNode _ l r -> policyActors l <> policyActors r
        AndNode l r -> policyActors l <> policyActors r
        OrNode l r -> policyActors l <> policyActors r
        NotNode p -> policyActors p

-- | One complete production run: a fresh file read pushed through
-- the public parse, structural validation, resolution, typechecking,
-- and normalization functions.  Each call performs its own read and
-- stages, so two calls are two independent pipeline runs.
normalizeWelltypedFile :: IO (Maybe (CoreDocument Normalized))
normalizeWelltypedFile = do
  bytes <- ByteString.readFile welltypedPath
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
                    Right typedDocument ->
                      either
                        (const Nothing)
                        Just
                        (normalizeCoreDocument typedDocument)

--------------------------------------------------------------------
-- The path oracle
--------------------------------------------------------------------

-- | The one path comparison of this module; expected paths are never
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

-- | A normalized value term carries the expected static type at the
-- expected literal segments, with a node matching the predicate.
isValue
  :: [Text]
  -> ValueType
  -> (ValueNode availability -> Bool)
  -> ValueTerm availability
  -> Bool
isValue expectedSegments expectedType nodeMatches term =
  hasSegments expectedSegments (valueTermPath term)
    && valueTermType term == expectedType
    && nodeMatches (valueTermNode term)

-- | A normalized policy term carries the expected static type at the
-- expected literal segments, with a node matching the predicate.
isPolicy
  :: [Text]
  -> PolicyType
  -> (PolicyNode availability -> Bool)
  -> PolicyTerm availability
  -> Bool
isPolicy expectedSegments expectedType nodeMatches term =
  hasSegments expectedSegments (policyTermPath term)
    && policyTermType term == expectedType
    && nodeMatches (policyTermNode term)

-- | The endpoint binding pairs the expected declared endpoint with a
-- matching term.
isBinding
  :: EndpointId
  -> (ValueTerm availability -> Bool)
  -> EndpointBinding availability
  -> Bool
isBinding expectedEndpoint termMatches binding =
  endpointBindingEndpoint binding == expectedEndpoint
    && termMatches (endpointBindingTerm binding)

--------------------------------------------------------------------
-- Declaration expectation tables
--------------------------------------------------------------------

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
    , "Ticket"
    , ["schema", "entities", "2"]
    , ["schema", "entities", "2", "name"]
    )
  ]

-- | The expected declared attribute type: the literal segments of the
-- type node, for the referencing constructors the segments and
-- target of the reference, and the static type the shared projection
-- must produce.
data ExpectedAttributeType
  = ExpectedBoolAttribute [Text]
  | ExpectedEnumAttribute [Text] [Text] EnumId
  | ExpectedEntityRefAttribute [Text] [Text] EntityId

matchesAttributeType :: ExpectedAttributeType -> AttributeType -> Bool
matchesAttributeType expected actual = case (expected, actual) of
  (ExpectedBoolAttribute typeSegments, BoolAttributeType path) ->
    hasSegments typeSegments path
      && attributeStaticType actual == BoolType
  (ExpectedEnumAttribute typeSegments refSegments target, EnumAttributeType path ref) ->
    hasSegments typeSegments path
      && matchesRef refSegments target ref
      && attributeStaticType actual == EnumType target
  (ExpectedEntityRefAttribute typeSegments refSegments target, EntityRefAttributeType path ref) ->
    hasSegments typeSegments path
      && matchesRef refSegments target ref
      && attributeStaticType actual == EntityRefType target
  _ -> False

attributeTable :: [(AttributeId, Text, [Text], [Text], ExpectedAttributeType)]
attributeTable =
  [ ( AttributeId (EntityId 0) 0
    , "role"
    , ["schema", "entities", "0", "attributes", "0"]
    , ["schema", "entities", "0", "attributes", "0", "name"]
    , ExpectedEnumAttribute
        ["schema", "entities", "0", "attributes", "0", "type"]
        ["schema", "entities", "0", "attributes", "0", "type", "enum"]
        (EnumId 0)
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
    , "owner"
    , ["schema", "entities", "2", "attributes", "0"]
    , ["schema", "entities", "2", "attributes", "0", "name"]
    , ExpectedEntityRefAttribute
        ["schema", "entities", "2", "attributes", "0", "type"]
        ["schema", "entities", "2", "attributes", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( AttributeId (EntityId 2) 1
    , "urgent"
    , ["schema", "entities", "2", "attributes", "1"]
    , ["schema", "entities", "2", "attributes", "1", "name"]
    , ExpectedBoolAttribute
        ["schema", "entities", "2", "attributes", "1", "type"]
    )
  , ( AttributeId (EntityId 2) 2
    , "organization"
    , ["schema", "entities", "2", "attributes", "2"]
    , ["schema", "entities", "2", "attributes", "2", "name"]
    , ExpectedEntityRefAttribute
        ["schema", "entities", "2", "attributes", "2", "type"]
        ["schema", "entities", "2", "attributes", "2", "type", "entity"]
        (EntityId 1)
    )
  ]

enumTable :: [(EnumId, Text, [Text], [Text])]
enumTable =
  [ ( EnumId 0
    , "Rank"
    , ["schema", "enums", "0"]
    , ["schema", "enums", "0", "name"]
    )
  , ( EnumId 1
    , "Phase"
    , ["schema", "enums", "1"]
    , ["schema", "enums", "1", "name"]
    )
  , ( EnumId 2
    , "Badge"
    , ["schema", "enums", "2"]
    , ["schema", "enums", "2", "name"]
    )
  ]

enumValueTable :: [(EnumValueId, Text, [Text])]
enumValueTable =
  [ (EnumValueId (EnumId 0) 0, "Bronze", ["schema", "enums", "0", "values", "0"])
  , (EnumValueId (EnumId 0) 1, "Silver", ["schema", "enums", "0", "values", "1"])
  , (EnumValueId (EnumId 0) 2, "Gold", ["schema", "enums", "0", "values", "2"])
  , (EnumValueId (EnumId 1) 0, "Draft", ["schema", "enums", "1", "values", "0"])
  , (EnumValueId (EnumId 1) 1, "Final", ["schema", "enums", "1", "values", "1"])
  , (EnumValueId (EnumId 2) 0, "Star", ["schema", "enums", "2", "values", "0"])
  ]

-- | The expected relation payload, including the static type the
-- shared projection must produce.
data ExpectedPayloadType
  = ExpectedUnitPayload [Text]
  | ExpectedEnumPayload [Text] [Text] EnumId

matchesPayloadType :: ExpectedPayloadType -> PayloadType -> Bool
matchesPayloadType expected actual = case (expected, actual) of
  (ExpectedUnitPayload payloadSegments, UnitPayloadType path) ->
    hasSegments payloadSegments path
      && payloadStaticType actual == UnitType
  (ExpectedEnumPayload payloadSegments refSegments target, EnumPayloadType path ref) ->
    hasSegments payloadSegments path
      && matchesRef refSegments target ref
      && payloadStaticType actual == EnumType target
  _ -> False

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
    , "Marked"
    , ["schema", "relations", "1"]
    , ["schema", "relations", "1", "name"]
    , ExpectedUnitPayload
        ["schema", "relations", "1", "payload"]
    )
  , ( RelationId 2
    , "Clearance"
    , ["schema", "relations", "2"]
    , ["schema", "relations", "2", "name"]
    , ExpectedEnumPayload
        ["schema", "relations", "2", "payload"]
        ["schema", "relations", "2", "payload", "enum"]
        (EnumId 0)
    )
  ]

endpointTable :: [(EndpointId, Text, [Text], [Text], [Text], EntityId)]
endpointTable =
  [ ( EndpointId (RelationId 0) 0
    , "member"
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
  , ( EndpointId (RelationId 2) 0
    , "holder"
    , ["schema", "relations", "2", "endpoints", "0"]
    , ["schema", "relations", "2", "endpoints", "0", "name"]
    , ["schema", "relations", "2", "endpoints", "0", "entity"]
    , EntityId 0
    )
  ]

actionTable :: [(ActionId, Text, [Text], [Text])]
actionTable =
  [ (ActionId 0, "Ticket.read", ["actions", "0"], ["actions", "0", "name"])
  , (ActionId 1, "Ticket.file", ["actions", "1"], ["actions", "1", "name"])
  , (ActionId 2, "User.inspect", ["actions", "2"], ["actions", "2", "name"])
  , (ActionId 3, "Ticket.purge", ["actions", "3"], ["actions", "3", "name"])
  , (ActionId 4, "Membership.assign", ["actions", "4"], ["actions", "4", "name"])
  , (ActionId 5, "Marked.strip", ["actions", "5"], ["actions", "5", "name"])
  , (ActionId 6, "Status.check", ["actions", "6"], ["actions", "6", "name"])
  , (ActionId 7, "Marked.tag", ["actions", "7"], ["actions", "7", "name"])
  , (ActionId 8, "Organization.found", ["actions", "8"], ["actions", "8", "name"])
  , (ActionId 9, "Session.refresh", ["actions", "9"], ["actions", "9", "name"])
  ]

-- | The expected declared parameter type; see
-- 'ExpectedAttributeType'.
data ExpectedParameterType
  = ExpectedBoolParameter [Text]
  | ExpectedUnitParameter [Text]
  | ExpectedEnumParameter [Text] [Text] EnumId
  | ExpectedEntityRefParameter [Text] [Text] EntityId

matchesParameterType :: ExpectedParameterType -> ParameterType -> Bool
matchesParameterType expected actual = case (expected, actual) of
  (ExpectedBoolParameter typeSegments, BoolParameterType path) ->
    hasSegments typeSegments path
      && parameterStaticType actual == BoolType
  (ExpectedUnitParameter typeSegments, UnitParameterType path) ->
    hasSegments typeSegments path
      && parameterStaticType actual == UnitType
  (ExpectedEnumParameter typeSegments refSegments target, EnumParameterType path ref) ->
    hasSegments typeSegments path
      && matchesRef refSegments target ref
      && parameterStaticType actual == EnumType target
  (ExpectedEntityRefParameter typeSegments refSegments target, EntityRefParameterType path ref) ->
    hasSegments typeSegments path
      && matchesRef refSegments target ref
      && parameterStaticType actual == EntityRefType target
  _ -> False

parameterTable :: [(ParameterId, Text, [Text], [Text], ExpectedParameterType)]
parameterTable =
  [ ( ParameterId (ActionId 0) 0
    , "ticket"
    , ["actions", "0", "parameters", "0"]
    , ["actions", "0", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "0", "parameters", "0", "type"]
        ["actions", "0", "parameters", "0", "type", "entity"]
        (EntityId 2)
    )
  , ( ParameterId (ActionId 1) 0
    , "organization"
    , ["actions", "1", "parameters", "0"]
    , ["actions", "1", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "1", "parameters", "0", "type"]
        ["actions", "1", "parameters", "0", "type", "entity"]
        (EntityId 1)
    )
  , ( ParameterId (ActionId 1) 1
    , "urgent"
    , ["actions", "1", "parameters", "1"]
    , ["actions", "1", "parameters", "1", "name"]
    , ExpectedBoolParameter ["actions", "1", "parameters", "1", "type"]
    )
  , ( ParameterId (ActionId 2) 0
    , "target"
    , ["actions", "2", "parameters", "0"]
    , ["actions", "2", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "2", "parameters", "0", "type"]
        ["actions", "2", "parameters", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( ParameterId (ActionId 2) 1
    , "level"
    , ["actions", "2", "parameters", "1"]
    , ["actions", "2", "parameters", "1", "name"]
    , ExpectedEnumParameter
        ["actions", "2", "parameters", "1", "type"]
        ["actions", "2", "parameters", "1", "type", "enum"]
        (EnumId 0)
    )
  , ( ParameterId (ActionId 3) 0
    , "ticket"
    , ["actions", "3", "parameters", "0"]
    , ["actions", "3", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "3", "parameters", "0", "type"]
        ["actions", "3", "parameters", "0", "type", "entity"]
        (EntityId 2)
    )
  , ( ParameterId (ActionId 4) 0
    , "target"
    , ["actions", "4", "parameters", "0"]
    , ["actions", "4", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "4", "parameters", "0", "type"]
        ["actions", "4", "parameters", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( ParameterId (ActionId 4) 1
    , "organization"
    , ["actions", "4", "parameters", "1"]
    , ["actions", "4", "parameters", "1", "name"]
    , ExpectedEntityRefParameter
        ["actions", "4", "parameters", "1", "type"]
        ["actions", "4", "parameters", "1", "type", "entity"]
        (EntityId 1)
    )
  , ( ParameterId (ActionId 4) 2
    , "level"
    , ["actions", "4", "parameters", "2"]
    , ["actions", "4", "parameters", "2", "name"]
    , ExpectedEnumParameter
        ["actions", "4", "parameters", "2", "type"]
        ["actions", "4", "parameters", "2", "type", "enum"]
        (EnumId 0)
    )
  , ( ParameterId (ActionId 5) 0
    , "subject"
    , ["actions", "5", "parameters", "0"]
    , ["actions", "5", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "5", "parameters", "0", "type"]
        ["actions", "5", "parameters", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( ParameterId (ActionId 6) 0
    , "peer"
    , ["actions", "6", "parameters", "0"]
    , ["actions", "6", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "6", "parameters", "0", "type"]
        ["actions", "6", "parameters", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( ParameterId (ActionId 6) 1
    , "phase"
    , ["actions", "6", "parameters", "1"]
    , ["actions", "6", "parameters", "1", "name"]
    , ExpectedEnumParameter
        ["actions", "6", "parameters", "1", "type"]
        ["actions", "6", "parameters", "1", "type", "enum"]
        (EnumId 1)
    )
  , ( ParameterId (ActionId 7) 0
    , "subject"
    , ["actions", "7", "parameters", "0"]
    , ["actions", "7", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "7", "parameters", "0", "type"]
        ["actions", "7", "parameters", "0", "type", "entity"]
        (EntityId 0)
    )
  , ( ParameterId (ActionId 8) 0
    , "founder"
    , ["actions", "8", "parameters", "0"]
    , ["actions", "8", "parameters", "0", "name"]
    , ExpectedEntityRefParameter
        ["actions", "8", "parameters", "0", "type"]
        ["actions", "8", "parameters", "0", "type", "entity"]
        (EntityId 0)
    )
  ]

--------------------------------------------------------------------
-- Checks
--------------------------------------------------------------------

modelChecks :: Model -> [Check]
modelChecks model =
  concat
    [ [ check
          "the document name keeps its text and its source path"
          (matchesSourced ["name"] "Welltyped" (modelName model))
      , check
          "the distinguished-User anchor is the canonical identity of the one entity declared as User (entity 0), independently of any term"
          ( modelUserEntity model == EntityId 0
              && [name | (identity, name, _, _) <- entityTable, identity == modelUserEntity model] == ["User"]
              && and
                [ (sourcedValue (entityName entity) == "User") == (entityId entity == modelUserEntity model)
                | entity <- modelEntities model
                ]
          )
      , check
          "every Actor term of the model denotes exactly the carried distinguished-User anchor"
          ( let actors = concatMap actionActors (modelActions model)
             in not (null actors) && all (== modelUserEntity model) actors
          )
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
        (concatMap (oneOrTwoList . relationEndpoints) (modelRelations model))
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
        (\(expectedId, name, _, _, _) ->
          Text.unpack name <> " (" <> show expectedId <> ")")
        (\(expectedId, name, declSegments, nameSegments, expectedType) actual ->
          parameterId actual == expectedId
            && hasSegments declSegments (parameterPath actual)
            && matchesSourced nameSegments name (parameterName actual)
            && matchesParameterType expectedType (parameterType actual))
    , enumRankChecks model
    , actionChecks model
    , guaranteeChecks model
    , sharedProjectionChecks model
    ]

oneOrTwoList :: OneOrTwo a -> [a]
oneOrTwoList shape =
  case shape of
    One only -> [only]
    Two firstItem secondItem -> [firstItem, secondItem]

-- | One count check plus one check per oracle row for a declaration
-- category; see "Mithril.CoreModelTests".
declarationChecks ::
  String ->
  [row] ->
  [actual] ->
  (row -> String) ->
  (row -> actual -> Bool) ->
  [Check]
declarationChecks category table actuals describe matches =
  check
    ("the normalized model carries exactly the " <> show (length table)
       <> " " <> category <> " declarations of the oracle")
    (length actuals == length table)
    : [ check
          ("normalized " <> category <> " " <> describe row <> " matches its oracle row")
          (matches row actual)
      | (row, actual) <- zip table actuals
      ]

--------------------------------------------------------------------
-- Materialized enum ranks
--------------------------------------------------------------------

enumRankChecks :: Model -> [Check]
enumRankChecks model =
  [ check
      "Rank materializes ranks 0..2 in its authored (declaration-agreeing) order"
      ( withEnum 0 $ \rankEnum ->
          case enumDefinitionOrder rankEnum of
            Just order ->
              case NonEmpty.toList (enumOrderRanking order) of
                [bronze, silver, gold] ->
                  rankedValueRank bronze == 0
                    && matchesRef
                      ["schema", "enums", "0", "order", "0"]
                      (EnumValueId (EnumId 0) 0)
                      (rankedValueMember bronze)
                    && rankedValueRank silver == 1
                    && matchesRef
                      ["schema", "enums", "0", "order", "1"]
                      (EnumValueId (EnumId 0) 1)
                      (rankedValueMember silver)
                    && rankedValueRank gold == 2
                    && matchesRef
                      ["schema", "enums", "0", "order", "2"]
                      (EnumValueId (EnumId 0) 2)
                      (rankedValueMember gold)
                _ -> False
            Nothing -> False
      )
  , check
      "Phase materializes authored ranks that differ from declaration order (Final below Draft)"
      ( withEnum 1 $ \phaseEnum ->
          case enumDefinitionOrder phaseEnum of
            Just order ->
              case NonEmpty.toList (enumOrderRanking order) of
                [bottom, top] ->
                  rankedValueRank bottom == 0
                    && matchesRef
                      ["schema", "enums", "1", "order", "0"]
                      (EnumValueId (EnumId 1) 1)
                      (rankedValueMember bottom)
                    && rankedValueRank top == 1
                    && matchesRef
                      ["schema", "enums", "1", "order", "1"]
                      (EnumValueId (EnumId 1) 0)
                      (rankedValueMember top)
                _ -> False
            Nothing -> False
      )
  , check
      "the unordered Badge enum materializes no ranking"
      ( withEnum 2 $ \badgeEnum ->
          case enumDefinitionOrder badgeEnum of
            Nothing -> True
            Just _ -> False
      )
  , check
      "enumOrderRank answers ranks for the ranked enum and nothing for foreign values"
      ( withEnum 1 $ \phaseEnum ->
          case enumDefinitionOrder phaseEnum of
            Just order ->
              enumOrderRank order (EnumValueId (EnumId 1) 0) == Just 1
                && enumOrderRank order (EnumValueId (EnumId 1) 1) == Just 0
                && enumOrderRank order (EnumValueId (EnumId 0) 0) == Nothing
            Nothing -> False
      )
  ]
  where
    withEnum index continue =
      case drop index (modelEnums model) of
        definition : _ -> continue definition
        [] -> False

--------------------------------------------------------------------
-- Actions: typed terms, bindings, ordering, explicit branches
--------------------------------------------------------------------

actionChecks :: Model -> [Check]
actionChecks model =
  [ check
      "Ticket.read stamps its full allow tree with types, ordered reading, and endpoint bindings"
      ( withAction 0 $ \ticketRead ->
          case actionBody ticketRead of
            AuthenticatedOnlyBody allow (ReadShape effectPath resultPath observed) ->
              hasSegments ["actions", "0", "effect"] effectPath
                && hasSegments ["actions", "0", "result"] resultPath
                && isValue
                  ["actions", "0", "result", "entity"]
                  (EntityRefType (EntityId 2))
                  (\node -> case node of
                     ArgumentNode ref ->
                       matchesRef
                         ["actions", "0", "result", "entity", "name"]
                         (ParameterId (ActionId 0) 0)
                         ref
                     _ -> False)
                  observed
                && isPolicy
                  ["actions", "0", "allow"]
                  (ValuePolicyType BoolType)
                  (\node -> case node of
                     LessOrEqualNode ordered left right ->
                       ordered == OptionalEnumOrderedType (EnumId 0)
                         && isPolicy
                           ["actions", "0", "allow", "left"]
                           (OptionalPolicyType (EnumType (EnumId 0)))
                           (\leftNode -> case leftNode of
                              SomeNode inner ->
                                isValue
                                  ["actions", "0", "allow", "left", "value"]
                                  (EnumType (EnumId 0))
                                  (\innerNode -> case innerNode of
                                     EnumNode enumRef valueRef ->
                                       matchesRef
                                         ["actions", "0", "allow", "left", "value", "enum"]
                                         (EnumId 0)
                                         enumRef
                                         && matchesRef
                                           ["actions", "0", "allow", "left", "value", "value"]
                                           (EnumValueId (EnumId 0) 1)
                                           valueRef
                                     _ -> False)
                                  inner
                              _ -> False)
                           left
                         && isPolicy
                           ["actions", "0", "allow", "right"]
                           (OptionalPolicyType (EnumType (EnumId 0)))
                           (\rightNode -> case rightNode of
                              LookupNode relationRef bindings ->
                                matchesRef
                                  ["actions", "0", "allow", "right", "relation"]
                                  (RelationId 0)
                                  relationRef
                                  && case bindings of
                                       Two actorBinding tenantBinding ->
                                         isBinding
                                           (EndpointId (RelationId 0) 0)
                                           ( isValue
                                               ["actions", "0", "allow", "right", "endpoints", "0"]
                                               (EntityRefType (EntityId 0))
                                               (\bNode -> case bNode of
                                                  ActorNode userEntity ->
                                                    userEntity == EntityId 0
                                                  _ -> False)
                                           )
                                           actorBinding
                                           && isBinding
                                             (EndpointId (RelationId 0) 1)
                                             ( isValue
                                                 ["actions", "0", "allow", "right", "endpoints", "1"]
                                                 (EntityRefType (EntityId 1))
                                                 (\bNode -> case bNode of
                                                    AttributeNode source attributeRef ->
                                                      matchesRef
                                                        ["actions", "0", "allow", "right", "endpoints", "1", "attribute"]
                                                        (AttributeId (EntityId 2) 2)
                                                        attributeRef
                                                        && isValue
                                                          ["actions", "0", "allow", "right", "endpoints", "1", "source"]
                                                          (EntityRefType (EntityId 2))
                                                          (\sourceNode -> case sourceNode of
                                                             ArgumentNode ref ->
                                                               matchesRef
                                                                 ["actions", "0", "allow", "right", "endpoints", "1", "source", "name"]
                                                                 (ParameterId (ActionId 0) 0)
                                                                 ref
                                                             _ -> False)
                                                          source
                                                    _ -> False)
                                             )
                                             tenantBinding
                                       One _ -> False
                              _ -> False)
                           right
                     _ -> False)
                  allow
            _ -> False
      )
  , check
      "Ticket.file reorders its initializers into attribute declaration order (owner, urgent, organization)"
      ( withAction 1 $ \ticketFile ->
          case actionBody ticketFile of
            AuthenticatedOnlyBody allow (CreateShape effect resultPath) ->
              isPolicy
                ["actions", "1", "allow"]
                (ValuePolicyType BoolType)
                (\node -> case node of
                   IsSomeNode operand ->
                     policyTermType operand
                       == OptionalPolicyType (EnumType (EnumId 0))
                   _ -> False)
                allow
                && hasSegments
                  ["actions", "1", "effect"]
                  (createEntityEffectPath effect)
                && matchesRef
                  ["actions", "1", "effect", "entity"]
                  (EntityId 2)
                  (createEntityEffectEntity effect)
                && case createEntityEffectInitializers effect of
                     [ownerInit, urgentInit, organizationInit] ->
                       matchesRef
                         ["actions", "1", "effect", "attributes", "owner"]
                         (AttributeId (EntityId 2) 0)
                         (initializerKey ownerInit)
                         && isValue
                           ["actions", "1", "effect", "attributes", "owner"]
                           (EntityRefType (EntityId 0))
                           (\node -> case node of
                              ActorNode userEntity -> userEntity == EntityId 0
                              _ -> False)
                           (initializerValue ownerInit)
                         && matchesRef
                           ["actions", "1", "effect", "attributes", "urgent"]
                           (AttributeId (EntityId 2) 1)
                           (initializerKey urgentInit)
                         && isValue
                           ["actions", "1", "effect", "attributes", "urgent"]
                           BoolType
                           (\node -> case node of
                              ArgumentNode ref ->
                                matchesRef
                                  ["actions", "1", "effect", "attributes", "urgent", "name"]
                                  (ParameterId (ActionId 1) 1)
                                  ref
                              _ -> False)
                           (initializerValue urgentInit)
                         && matchesRef
                           ["actions", "1", "effect", "attributes", "organization"]
                           (AttributeId (EntityId 2) 2)
                           (initializerKey organizationInit)
                         && isValue
                           ["actions", "1", "effect", "attributes", "organization"]
                           (EntityRefType (EntityId 1))
                           (\node -> case node of
                              ArgumentNode ref ->
                                matchesRef
                                  ["actions", "1", "effect", "attributes", "organization", "name"]
                                  (ParameterId (ActionId 1) 0)
                                  ref
                              _ -> False)
                           (initializerValue organizationInit)
                     _ -> False
                && hasSegments ["actions", "1", "result"] resultPath
            _ -> False
      )
  , check
      "User.inspect compares at the plain enum level and projects the Actor's attribute"
      ( withAction 2 $ \userInspect ->
          case actionBody userInspect of
            AuthenticatedOnlyBody allow (ReadShape _ _ observed) ->
              isPolicy
                ["actions", "2", "allow"]
                (ValuePolicyType BoolType)
                (\node -> case node of
                   AndNode left right ->
                     isPolicy
                       ["actions", "2", "allow", "left"]
                       (ValuePolicyType BoolType)
                       (\leftNode -> case leftNode of
                          LessOrEqualNode ordered comparisonLeft comparisonRight ->
                            ordered == EnumOrderedType (EnumId 0)
                              && policyTermType comparisonLeft
                                == ValuePolicyType (EnumType (EnumId 0))
                              && policyTermType comparisonRight
                                == ValuePolicyType (EnumType (EnumId 0))
                          _ -> False)
                       left
                       && isPolicy
                         ["actions", "2", "allow", "right"]
                         (ValuePolicyType BoolType)
                         (\rightNode -> case rightNode of
                            EqualNode equalLeft _ ->
                              isPolicy
                                ["actions", "2", "allow", "right", "left"]
                                (ValuePolicyType (EnumType (EnumId 0)))
                                (\projected -> case projected of
                                   ValuePolicyNode inner ->
                                     isValue
                                       ["actions", "2", "allow", "right", "left"]
                                       (EnumType (EnumId 0))
                                       (\innerNode -> case innerNode of
                                          AttributeNode source attributeRef ->
                                            matchesRef
                                              ["actions", "2", "allow", "right", "left", "attribute"]
                                              (AttributeId (EntityId 0) 0)
                                              attributeRef
                                              && isValue
                                                ["actions", "2", "allow", "right", "left", "source"]
                                                (EntityRefType (EntityId 0))
                                                (\sourceNode -> case sourceNode of
                                                   ActorNode userEntity ->
                                                     userEntity == EntityId 0
                                                   _ -> False)
                                                source
                                          _ -> False)
                                       inner
                                   _ -> False)
                                equalLeft
                            _ -> False)
                         right
                   _ -> False)
                allow
                && valueTermType observed == EntityRefType (EntityId 0)
            _ -> False
      )
  , check
      "Ticket.purge types both Equal operands at EntityRef User and its DeleteEntity target"
      ( withAction 3 $ \ticketPurge ->
          case actionBody ticketPurge of
            AuthenticatedOnlyBody allow (MutationShape (DeleteEntityEffect effectPath target) resultPath) ->
              isPolicy
                ["actions", "3", "allow"]
                (ValuePolicyType BoolType)
                (\node -> case node of
                   EqualNode left right ->
                     policyTermType left
                       == ValuePolicyType (EntityRefType (EntityId 0))
                       && policyTermType right
                         == ValuePolicyType (EntityRefType (EntityId 0))
                   _ -> False)
                allow
                && hasSegments ["actions", "3", "effect"] effectPath
                && isValue
                  ["actions", "3", "effect", "target"]
                  (EntityRefType (EntityId 2))
                  (\node -> case node of
                     ArgumentNode ref ->
                       matchesRef
                         ["actions", "3", "effect", "target", "name"]
                         (ParameterId (ActionId 3) 0)
                         ref
                     _ -> False)
                  target
                && hasSegments ["actions", "3", "result"] resultPath
            _ -> False
      )
  , check
      "Membership.assign keeps its authored operand order and redundant Or branch unsimplified"
      ( withAction 4 $ \membershipAssign ->
          case actionBody membershipAssign of
            AuthenticatedOnlyBody allow (MutationShape (SetRelationEffect effectPath relationRef bindings payload) resultPath) ->
              isPolicy
                ["actions", "4", "allow"]
                (ValuePolicyType BoolType)
                (\node -> case node of
                   AndNode notSide orSide ->
                     isPolicy
                       ["actions", "4", "allow", "left"]
                       (ValuePolicyType BoolType)
                       (\notNode -> case notNode of
                          NotNode equalTerm ->
                            isPolicy
                              ["actions", "4", "allow", "left", "value"]
                              (ValuePolicyType BoolType)
                              (\equalNode -> case equalNode of
                                 -- Authored operand order preserved:
                                 -- Actor on the left, the argument on
                                 -- the right.
                                 EqualNode equalLeft equalRight ->
                                   isPolicy
                                     ["actions", "4", "allow", "left", "value", "left"]
                                     (ValuePolicyType (EntityRefType (EntityId 0)))
                                     (\actorSide -> case actorSide of
                                        ValuePolicyNode inner ->
                                          case valueTermNode inner of
                                            ActorNode userEntity ->
                                              userEntity == EntityId 0
                                            _ -> False
                                        _ -> False)
                                     equalLeft
                                     && isPolicy
                                       ["actions", "4", "allow", "left", "value", "right"]
                                       (ValuePolicyType (EntityRefType (EntityId 0)))
                                       (\argumentSide -> case argumentSide of
                                          ValuePolicyNode inner ->
                                            case valueTermNode inner of
                                              ArgumentNode ref ->
                                                refTarget ref
                                                  == ParameterId (ActionId 4) 0
                                              _ -> False
                                          _ -> False)
                                       equalRight
                                 _ -> False)
                              equalTerm
                          _ -> False)
                       notSide
                       && isPolicy
                         ["actions", "4", "allow", "right"]
                         (ValuePolicyType BoolType)
                         (\orNode -> case orNode of
                            OrNode lookupEqual redundantFalse ->
                              isPolicy
                                ["actions", "4", "allow", "right", "left"]
                                (ValuePolicyType BoolType)
                                (\equalNode -> case equalNode of
                                   EqualNode lookupSide noneSide ->
                                     policyTermType lookupSide
                                       == OptionalPolicyType (EnumType (EnumId 0))
                                       && isPolicy
                                         ["actions", "4", "allow", "right", "left", "right"]
                                         (OptionalPolicyType (EnumType (EnumId 0)))
                                         (\noneNode -> case noneNode of
                                            NoneNode written ->
                                              case written of
                                                EnumPayloadType payloadPath payloadRef ->
                                                  hasSegments
                                                    ["actions", "4", "allow", "right", "left", "right", "payloadType"]
                                                    payloadPath
                                                    && matchesRef
                                                      ["actions", "4", "allow", "right", "left", "right", "payloadType", "enum"]
                                                      (EnumId 0)
                                                      payloadRef
                                                _ -> False
                                            _ -> False)
                                         noneSide
                                   _ -> False)
                                lookupEqual
                                -- The authored, foldable "or false" is
                                -- preserved verbatim.
                                && isPolicy
                                  ["actions", "4", "allow", "right", "right"]
                                  (ValuePolicyType BoolType)
                                  (\falseNode -> case falseNode of
                                     ValuePolicyNode inner ->
                                       case valueTermNode inner of
                                         BoolNode False -> True
                                         _ -> False
                                     _ -> False)
                                  redundantFalse
                            _ -> False)
                         orSide
                   _ -> False)
                allow
                && hasSegments ["actions", "4", "effect"] effectPath
                && matchesRef
                  ["actions", "4", "effect", "relation"]
                  (RelationId 0)
                  relationRef
                && case bindings of
                     Two targetBinding organizationBinding ->
                       isBinding
                         (EndpointId (RelationId 0) 0)
                         ( isValue
                             ["actions", "4", "effect", "endpoints", "0"]
                             (EntityRefType (EntityId 0))
                             (\node -> case node of
                                ArgumentNode ref ->
                                  refTarget ref == ParameterId (ActionId 4) 0
                                _ -> False)
                         )
                         targetBinding
                         && isBinding
                           (EndpointId (RelationId 0) 1)
                           ( isValue
                               ["actions", "4", "effect", "endpoints", "1"]
                               (EntityRefType (EntityId 1))
                               (\node -> case node of
                                  ArgumentNode ref ->
                                    refTarget ref == ParameterId (ActionId 4) 1
                                  _ -> False)
                           )
                           organizationBinding
                     One _ -> False
                && isValue
                  ["actions", "4", "effect", "payload"]
                  (EnumType (EnumId 0))
                  (\node -> case node of
                     ArgumentNode ref ->
                       matchesRef
                         ["actions", "4", "effect", "payload", "name"]
                         (ParameterId (ActionId 4) 2)
                         ref
                     _ -> False)
                  payload
                && hasSegments ["actions", "4", "result"] resultPath
            _ -> False
      )
  , check
      "Marked.strip keeps explicit AnyPrincipal branches and binds its arity-one removal"
      ( withAction 5 $ \markedStrip ->
          case actionBody markedStrip of
            AnyPrincipalBody allow (MutationShape (RemoveRelationEffect effectPath relationRef bindings) resultPath) ->
              isPolicy
                ["actions", "5", "allow", "anonymous"]
                (ValuePolicyType BoolType)
                (\node -> case node of
                   EqualNode lookupSide noneSide ->
                     isPolicy
                       ["actions", "5", "allow", "anonymous", "left"]
                       (OptionalPolicyType UnitType)
                       (\lookupNode -> case lookupNode of
                          LookupNode innerRelation innerBindings ->
                            matchesRef
                              ["actions", "5", "allow", "anonymous", "left", "relation"]
                              (RelationId 1)
                              innerRelation
                              && case innerBindings of
                                   One subjectBinding ->
                                     isBinding
                                       (EndpointId (RelationId 1) 0)
                                       ( isValue
                                           ["actions", "5", "allow", "anonymous", "left", "endpoints", "0"]
                                           (EntityRefType (EntityId 0))
                                           (\bNode -> case bNode of
                                              ArgumentNode ref ->
                                                refTarget ref
                                                  == ParameterId (ActionId 5) 0
                                              _ -> False)
                                       )
                                       subjectBinding
                                   Two _ _ -> False
                          _ -> False)
                       lookupSide
                       && isPolicy
                         ["actions", "5", "allow", "anonymous", "right"]
                         (OptionalPolicyType UnitType)
                         (\noneNode -> case noneNode of
                            NoneNode written ->
                              case written of
                                UnitPayloadType payloadPath ->
                                  hasSegments
                                    ["actions", "5", "allow", "anonymous", "right", "payloadType"]
                                    payloadPath
                                _ -> False
                            _ -> False)
                         noneSide
                   _ -> False)
                (anyPrincipalAnonymous allow)
                && isPolicy
                  ["actions", "5", "allow", "authenticated"]
                  (ValuePolicyType BoolType)
                  (\node -> case node of
                     ValuePolicyNode inner ->
                       case valueTermNode inner of
                         BoolNode True -> True
                         _ -> False
                     _ -> False)
                  (anyPrincipalAuthenticated allow)
                && hasSegments ["actions", "5", "effect"] effectPath
                && matchesRef
                  ["actions", "5", "effect", "relation"]
                  (RelationId 1)
                  relationRef
                && case bindings of
                     One subjectBinding ->
                       isBinding
                         (EndpointId (RelationId 1) 0)
                         ( isValue
                             ["actions", "5", "effect", "endpoints", "0"]
                             (EntityRefType (EntityId 0))
                             (\node -> case node of
                                ArgumentNode ref ->
                                  refTarget ref == ParameterId (ActionId 5) 0
                                _ -> False)
                         )
                         subjectBinding
                     Two _ _ -> False
                && hasSegments ["actions", "5", "result"] resultPath
            _ -> False
      )
  , check
      "Status.check orders its anonymous comparison by the reversed-rank Phase enum"
      ( withAction 6 $ \statusCheck ->
          case actionBody statusCheck of
            AnyPrincipalBody allow (ReadShape _ _ observed) ->
              isPolicy
                ["actions", "6", "allow", "anonymous"]
                (ValuePolicyType BoolType)
                (\node -> case node of
                   LessOrEqualNode ordered left right ->
                     ordered == EnumOrderedType (EnumId 1)
                       && policyTermType left
                         == ValuePolicyType (EnumType (EnumId 1))
                       && isPolicy
                         ["actions", "6", "allow", "anonymous", "right"]
                         (ValuePolicyType (EnumType (EnumId 1)))
                         (\rightNode -> case rightNode of
                            ValuePolicyNode inner ->
                              case valueTermNode inner of
                                EnumNode enumRef valueRef ->
                                  refTarget enumRef == EnumId 1
                                    && refTarget valueRef
                                      == EnumValueId (EnumId 1) 0
                                _ -> False
                            _ -> False)
                         right
                   _ -> False)
                (anyPrincipalAnonymous allow)
                && isPolicy
                  ["actions", "6", "allow", "authenticated"]
                  (ValuePolicyType BoolType)
                  (\node -> case node of
                     IsSomeNode operand ->
                       isPolicy
                         ["actions", "6", "allow", "authenticated", "value"]
                         (OptionalPolicyType UnitType)
                         (\lookupNode -> case lookupNode of
                            LookupNode innerRelation innerBindings ->
                              refTarget innerRelation == RelationId 1
                                && case innerBindings of
                                     One actorBinding ->
                                       isBinding
                                         (EndpointId (RelationId 1) 0)
                                         ( isValue
                                             ["actions", "6", "allow", "authenticated", "value", "endpoints", "0"]
                                             (EntityRefType (EntityId 0))
                                             (\bNode -> case bNode of
                                                ActorNode userEntity ->
                                                  userEntity == EntityId 0
                                                _ -> False)
                                         )
                                         actorBinding
                                     Two _ _ -> False
                            _ -> False)
                         operand
                     _ -> False)
                  (anyPrincipalAuthenticated allow)
                && isValue
                  ["actions", "6", "result", "entity"]
                  (EntityRefType (EntityId 0))
                  (\node -> case node of
                     ArgumentNode ref ->
                       refTarget ref == ParameterId (ActionId 6) 0
                     _ -> False)
                  observed
            _ -> False
      )
  , check
      "Marked.tag types its Unit payload term at Unit"
      ( withAction 7 $ \markedTag ->
          case actionBody markedTag of
            AnyPrincipalBody _ (MutationShape (SetRelationEffect _ relationRef bindings payload) _) ->
              refTarget relationRef == RelationId 1
                && case bindings of
                     One subjectBinding ->
                       isBinding
                         (EndpointId (RelationId 1) 0)
                         (\term ->
                            valueTermType term == EntityRefType (EntityId 0))
                         subjectBinding
                     Two _ _ -> False
                && isValue
                  ["actions", "7", "effect", "payload"]
                  UnitType
                  (\node -> case node of
                     UnitNode -> True
                     _ -> False)
                  payload
            _ -> False
      )
  , check
      "Organization.found normalizes its actor-free initializer completely"
      ( withAction 8 $ \organizationFound ->
          case actionBody organizationFound of
            AnyPrincipalBody _ (CreateShape effect resultPath) ->
              matchesRef
                ["actions", "8", "effect", "entity"]
                (EntityId 1)
                (createEntityEffectEntity effect)
                && case createEntityEffectInitializers effect of
                     [ownerInit] ->
                       matchesRef
                         ["actions", "8", "effect", "attributes", "owner"]
                         (AttributeId (EntityId 1) 0)
                         (initializerKey ownerInit)
                         && isValue
                           ["actions", "8", "effect", "attributes", "owner"]
                           (EntityRefType (EntityId 0))
                           (\node -> case node of
                              ArgumentNode ref ->
                                matchesRef
                                  ["actions", "8", "effect", "attributes", "owner", "name"]
                                  (ParameterId (ActionId 8) 0)
                                  ref
                              _ -> False)
                           (initializerValue ownerInit)
                     _ -> False
                && hasSegments ["actions", "8", "result"] resultPath
            _ -> False
      )
  , check
      "Session.refresh keeps its foldable And(true, true) allow unfolded"
      ( withAction 9 $ \sessionRefresh ->
          null (actionParameters sessionRefresh)
            && case actionBody sessionRefresh of
                 AuthenticatedOnlyBody allow (MutationShape (NoChangeEffect effectPath) resultPath) ->
                   isPolicy
                     ["actions", "9", "allow"]
                     (ValuePolicyType BoolType)
                     (\node -> case node of
                        AndNode left right ->
                          isPolicy
                            ["actions", "9", "allow", "left"]
                            (ValuePolicyType BoolType)
                            (\leftNode -> case leftNode of
                               ValuePolicyNode inner ->
                                 case valueTermNode inner of
                                   BoolNode True -> True
                                   _ -> False
                               _ -> False)
                            left
                            && isPolicy
                              ["actions", "9", "allow", "right"]
                              (ValuePolicyType BoolType)
                              (\rightNode -> case rightNode of
                                 ValuePolicyNode inner ->
                                   case valueTermNode inner of
                                     BoolNode True -> True
                                     _ -> False
                                 _ -> False)
                              right
                        _ -> False)
                     allow
                     && hasSegments ["actions", "9", "effect"] effectPath
                     && hasSegments ["actions", "9", "result"] resultPath
                 _ -> False
      )
  ]
  where
    withAction index continue =
      case drop index (modelActions model) of
        action : _ -> continue action
        [] -> False

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

guaranteeChecks :: Model -> [Check]
guaranteeChecks model =
  [ check
      "the AuthenticatedMutation guarantee keeps its declaration path"
      ( withGuarantee 0 $ \guarantee ->
          case guarantee of
            AuthenticatedMutationGuarantee path ->
              hasSegments ["guarantees", "0"] path
            _ -> False
      )
  , check
      "the TenantIsolation guarantee stores its resolved access identities and types its case terms in Ticket.read's environment"
      ( withGuarantee 1 $ \guarantee ->
          case guarantee of
            TenantIsolationGuarantee path access (tenantCase :| []) ->
              hasSegments ["guarantees", "1"] path
                && hasSegments
                  ["guarantees", "1", "access"]
                  (tenantIsolationAccessPath access)
                && matchesRef
                  ["guarantees", "1", "access", "relation"]
                  (RelationId 0)
                  (tenantIsolationAccessRelation access)
                && matchesRef
                  ["guarantees", "1", "access", "subjectEndpoint"]
                  (EndpointId (RelationId 0) 0)
                  (tenantIsolationAccessSubjectEndpoint access)
                && matchesRef
                  ["guarantees", "1", "access", "tenantEndpoint"]
                  (EndpointId (RelationId 0) 1)
                  (tenantIsolationAccessTenantEndpoint access)
                && hasSegments
                  ["guarantees", "1", "cases", "0"]
                  (tenantIsolationCasePath tenantCase)
                && matchesRef
                  ["guarantees", "1", "cases", "0", "action"]
                  (ActionId 0)
                  (tenantIsolationCaseAction tenantCase)
                && isValue
                  ["guarantees", "1", "cases", "0", "tenant"]
                  (EntityRefType (EntityId 1))
                  (\node -> case node of
                     AttributeNode source attributeRef ->
                       matchesRef
                         ["guarantees", "1", "cases", "0", "tenant", "attribute"]
                         (AttributeId (EntityId 2) 2)
                         attributeRef
                         && isValue
                           ["guarantees", "1", "cases", "0", "tenant", "source"]
                           (EntityRefType (EntityId 2))
                           (\sourceNode -> case sourceNode of
                              ArgumentNode ref ->
                                matchesRef
                                  ["guarantees", "1", "cases", "0", "tenant", "source", "name"]
                                  (ParameterId (ActionId 0) 0)
                                  ref
                              _ -> False)
                           source
                     _ -> False)
                  (tenantIsolationCaseTenant tenantCase)
                && isPolicy
                  ["guarantees", "1", "cases", "0", "protected"]
                  (ValuePolicyType BoolType)
                  (\node -> case node of
                     ValuePolicyNode inner ->
                       case valueTermNode inner of
                         BoolNode True -> True
                         _ -> False
                     _ -> False)
                  (tenantIsolationCaseProtected tenantCase)
            _ -> False
      )
  , -- The normalized access identities must equal the shared resolved
    -- projections: the endpoints the identifiers select in the
    -- normalized schema are the subject (User-typed) and tenant
    -- endpoints the typechecker judged, and the stored tenant-term
    -- annotation names exactly the tenant endpoint's entity.
    check
      "the stored access identities agree with the relation's declared endpoints and the tenant term's stored type"
      ( withGuarantee 1 $ \guarantee ->
          case guarantee of
            TenantIsolationGuarantee _ access (tenantCase :| []) ->
              case modelRelations model of
                membership : _ ->
                  case relationEndpoints membership of
                    Two memberEndpoint organizationEndpoint ->
                      endpointId memberEndpoint
                        == refTarget (tenantIsolationAccessSubjectEndpoint access)
                        && endpointId organizationEndpoint
                          == refTarget (tenantIsolationAccessTenantEndpoint access)
                        && refTarget (endpointEntity memberEndpoint) == EntityId 0
                        && valueTermType (tenantIsolationCaseTenant tenantCase)
                          == EntityRefType
                            (refTarget (endpointEntity organizationEndpoint))
                    One _ -> False
                [] -> False
            _ -> False
      )
  , check
      "the scoped authority binds its case scope term to the scope endpoint"
      ( withGuarantee 2 $ \guarantee ->
          case guarantee of
            NoSelfPrivilegeEscalationGuarantee guaranteePath authority (assignCase :| []) ->
              hasSegments ["guarantees", "2"] guaranteePath
                && hasSegments
                  ["guarantees", "2", "authority"]
                  (authorityPath authority)
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
                && hasSegments
                  ["guarantees", "2", "cases", "0"]
                  (escalationCasePath assignCase)
                && matchesRef
                  ["guarantees", "2", "cases", "0", "action"]
                  (ActionId 4)
                  (escalationCaseAction assignCase)
                && ( case escalationCaseScope assignCase of
                       Just binding ->
                         scopeBindingEndpoint binding
                           == EndpointId (RelationId 0) 1
                           && isValue
                             ["guarantees", "2", "cases", "0", "scope", "0"]
                             (EntityRefType (EntityId 1))
                             (\node -> case node of
                                ArgumentNode ref ->
                                  matchesRef
                                    ["guarantees", "2", "cases", "0", "scope", "0", "name"]
                                    (ParameterId (ActionId 4) 1)
                                    ref
                                _ -> False)
                             (scopeBindingTerm binding)
                       Nothing -> False
                   )
            _ -> False
      )
  , check
      "the unscoped authority carries no scope endpoint and its case no scope binding"
      ( withGuarantee 3 $ \guarantee ->
          case guarantee of
            NoSelfPrivilegeEscalationGuarantee guaranteePath authority (refreshCase :| []) ->
              hasSegments ["guarantees", "3"] guaranteePath
                && matchesRef
                  ["guarantees", "3", "authority", "relation"]
                  (RelationId 2)
                  (authorityRelation authority)
                && matchesRef
                  ["guarantees", "3", "authority", "subjectEndpoint"]
                  (EndpointId (RelationId 2) 0)
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
                  (EnumId 0)
                  (authorityPayloadOrder authority)
                && matchesRef
                  ["guarantees", "3", "cases", "0", "action"]
                  (ActionId 9)
                  (escalationCaseAction refreshCase)
                && ( case escalationCaseScope refreshCase of
                       Nothing -> True
                       Just _ -> False
                   )
            _ -> False
      )
  ]
  where
    withGuarantee index continue =
      case drop index (modelGuarantees model) of
        guarantee : _ -> continue guarantee
        [] -> False

--------------------------------------------------------------------
-- Shared projections and ordered evidence (consumption checks)
--------------------------------------------------------------------

-- | These checks pin that the typechecker and the normalizer consume
-- the one shared statement of each declared-type projection and of
-- the ordered classification, rather than maintaining parallel case
-- analyses.  Every term annotation in the normalized model was
-- computed by the typechecker's own inference (through the
-- normalizer), while the oracle side below calls the shared
-- projections ('attributeStaticType', 'parameterStaticType',
-- 'payloadStaticType') and the shared shape classifier
-- ('orderedPolicyType') — it deliberately restates no case of them —
-- so the quantified agreement over every relevant site of the
-- full-coverage fixture fails as soon as either consumer diverges
-- from the shared definitions.  Each rule also pins the exact number
-- of sites the fixture exercises, so an incomplete walk cannot pass
-- vacuously.
sharedProjectionChecks :: Model -> [Check]
sharedProjectionChecks model =
  [ check
      "all 4 CreateEntity initializer annotations equal the shared attribute projection of their declared types"
      ( length initializerRows == 4
          && all
            (\(target, annotated) ->
               fmap
                 (attributeStaticType . attributeType)
                 (attributeById target)
                 == Just annotated)
            initializerRows
      )
  , check
      "all 4 attribute-projection annotations equal the shared attribute projection of the projected declarations"
      ( length projectionRows == 4
          && all
            (\(target, annotated) ->
               fmap
                 (attributeStaticType . attributeType)
                 (attributeById target)
                 == Just annotated)
            projectionRows
      )
  , check
      "all 24 Argument annotations equal the shared parameter projection of their declared types"
      ( length argumentRows == 24
          && all
            (\(target, annotated) ->
               fmap
                 (parameterStaticType . parameterType)
                 (parameterById target)
                 == Just annotated)
            argumentRows
      )
  , check
      "all 5 Lookup annotations are Optional of the shared payload projection of their relations"
      ( length lookupRows == 5
          && all
            (\(target, annotated) ->
               fmap
                 (OptionalPolicyType . payloadStaticType . relationPayload)
                 (relationById target)
                 == Just annotated)
            lookupRows
      )
  , check
      "both None annotations are Optional of the shared payload projection of their written payload types"
      ( length noneRows == 2
          && all
            (\(written, annotated) ->
               OptionalPolicyType (payloadStaticType written) == annotated)
            noneRows
      )
  , check
      "both SetRelation payload annotations equal the shared payload projection of their relations"
      ( length setPayloadRows == 2
          && all
            (\(target, annotated) ->
               fmap
                 (payloadStaticType . relationPayload)
                 (relationById target)
                 == Just annotated)
            setPayloadRows
      )
  , check
      "all 3 stored ordered readings are the shared classification of both operand annotations"
      ( length orderedRows == 3
          && all
            (\(evidence, leftType, rightType) ->
               orderedPolicyType leftType == Just evidence
                 && orderedPolicyType rightType == Just evidence)
            orderedRows
      )
  , check
      "every stored ordered reading names an enum whose normalized declaration materializes a ranking"
      ( all
          (\(evidence, _, _) ->
             case enumById (orderedTypeEnum evidence) of
               Just definition ->
                 case enumDefinitionOrder definition of
                   Just _ -> True
                   Nothing -> False
               Nothing -> False)
          orderedRows
      )
  ]
  where
    facts = modelFacts model
    initializerRows = [(target, annotated) | InitializerFact target annotated <- facts]
    projectionRows = [(target, annotated) | ProjectionFact target annotated <- facts]
    argumentRows = [(target, annotated) | ArgumentFact target annotated <- facts]
    lookupRows = [(target, annotated) | LookupFact target annotated <- facts]
    noneRows = [(written, annotated) | NoneFact written annotated <- facts]
    setPayloadRows = [(target, annotated) | SetPayloadFact target annotated <- facts]
    orderedRows =
      [ (evidence, leftType, rightType)
      | OrderedFact evidence leftType rightType <- facts
      ]
    attributeById target =
      case
        [ attribute
        | entity <- modelEntities model
        , attribute <- entityAttributes entity
        , attributeId attribute == target
        ]
      of
        attribute : _ -> Just attribute
        [] -> Nothing
    parameterById target =
      case
        [ parameter
        | action <- modelActions model
        , parameter <- actionParameters action
        , parameterId parameter == target
        ]
      of
        parameter : _ -> Just parameter
        [] -> Nothing
    relationById target =
      case [relation | relation <- modelRelations model, relationId relation == target] of
        relation : _ -> Just relation
        [] -> Nothing
    enumById target =
      case
        [ definition
        | definition <- modelEnums model
        , enumDefinitionId definition == target
        ]
      of
        definition : _ -> Just definition
        [] -> Nothing

-- | One fact per site at which the normalized model relates a term
-- annotation to a declared type, or stores ordered evidence.
data ProjectionFact
  = -- | An initializer's target attribute and its term's annotation.
    InitializerFact AttributeId ValueType
  | -- | An attribute projection's attribute and the projection
    -- term's annotation.
    ProjectionFact AttributeId ValueType
  | -- | An @Argument@ term's parameter and its annotation.
    ArgumentFact ParameterId ValueType
  | -- | A @Lookup@ term's relation and its annotation.
    LookupFact RelationId PolicyType
  | -- | A @None@ term's written payload type and its annotation.
    NoneFact PayloadType PolicyType
  | -- | A @SetRelation@ payload term's relation and the payload
    -- term's annotation.
    SetPayloadFact RelationId ValueType
  | -- | A @LessOrEqual@'s stored evidence and both operand
    -- annotations.
    OrderedFact OrderedType PolicyType PolicyType

-- | Every projection fact of the model: all terms of all actions and
-- guarantee cases, walked completely.
modelFacts :: Model -> [ProjectionFact]
modelFacts model =
  concatMap (bodyFacts . actionBody) (modelActions model)
    <> concatMap guaranteeFacts (modelGuarantees model)

bodyFacts :: ActionBody -> [ProjectionFact]
bodyFacts body =
  case body of
    AuthenticatedOnlyBody allow shape ->
      policyTermFacts allow <> shapeFacts shape
    AnyPrincipalBody allow shape ->
      policyTermFacts (anyPrincipalAnonymous allow)
        <> policyTermFacts (anyPrincipalAuthenticated allow)
        <> shapeFacts shape

shapeFacts :: ActionShape availability -> [ProjectionFact]
shapeFacts shape =
  case shape of
    ReadShape _ _ observed -> valueTermFacts observed
    CreateShape effect _ ->
      concatMap initializerFacts (createEntityEffectInitializers effect)
    MutationShape effect _ -> doneEffectFacts effect

initializerFacts :: Initializer availability -> [ProjectionFact]
initializerFacts initializer =
  InitializerFact
    (refTarget (initializerKey initializer))
    (valueTermType (initializerValue initializer))
    : valueTermFacts (initializerValue initializer)

doneEffectFacts :: DoneEffect availability -> [ProjectionFact]
doneEffectFacts effect =
  case effect of
    NoChangeEffect _ -> []
    DeleteEntityEffect _ target -> valueTermFacts target
    SetRelationEffect _ relationRef bindings payload ->
      SetPayloadFact (refTarget relationRef) (valueTermType payload)
        : concatMap bindingFacts (oneOrTwoList bindings)
          <> valueTermFacts payload
    RemoveRelationEffect _ _ bindings ->
      concatMap bindingFacts (oneOrTwoList bindings)

guaranteeFacts :: Guarantee -> [ProjectionFact]
guaranteeFacts guarantee =
  case guarantee of
    AuthenticatedMutationGuarantee _ -> []
    TenantIsolationGuarantee _ _ cases ->
      concatMap tenantCaseFacts (NonEmpty.toList cases)
    NoSelfPrivilegeEscalationGuarantee _ _ cases ->
      concatMap escalationCaseFacts (NonEmpty.toList cases)

tenantCaseFacts :: TenantIsolationCase -> [ProjectionFact]
tenantCaseFacts tenantCase =
  valueTermFacts (tenantIsolationCaseTenant tenantCase)
    <> policyTermFacts (tenantIsolationCaseProtected tenantCase)

escalationCaseFacts :: EscalationCase -> [ProjectionFact]
escalationCaseFacts escalationCase =
  case escalationCaseScope escalationCase of
    Nothing -> []
    Just binding -> valueTermFacts (scopeBindingTerm binding)

bindingFacts :: EndpointBinding availability -> [ProjectionFact]
bindingFacts binding = valueTermFacts (endpointBindingTerm binding)

valueTermFacts :: ValueTerm availability -> [ProjectionFact]
valueTermFacts term =
  case valueTermNode term of
    BoolNode _ -> []
    UnitNode -> []
    EnumNode _ _ -> []
    ArgumentNode ref -> [ArgumentFact (refTarget ref) (valueTermType term)]
    ActorNode _ -> []
    AttributeNode source ref ->
      ProjectionFact (refTarget ref) (valueTermType term)
        : valueTermFacts source

policyTermFacts :: PolicyTerm availability -> [ProjectionFact]
policyTermFacts term =
  case policyTermNode term of
    ValuePolicyNode inner -> valueTermFacts inner
    LookupNode relationRef bindings ->
      LookupFact (refTarget relationRef) (policyTermType term)
        : concatMap bindingFacts (oneOrTwoList bindings)
    NoneNode written -> [NoneFact written (policyTermType term)]
    SomeNode inner -> valueTermFacts inner
    IsSomeNode operand -> policyTermFacts operand
    EqualNode left right -> policyTermFacts left <> policyTermFacts right
    LessOrEqualNode evidence left right ->
      OrderedFact evidence (policyTermType left) (policyTermType right)
        : policyTermFacts left
          <> policyTermFacts right
    AndNode left right -> policyTermFacts left <> policyTermFacts right
    OrNode left right -> policyTermFacts left <> policyTermFacts right
    NotNode operand -> policyTermFacts operand
