{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Core v0 schema decoder: the only place in the frontend that
-- interprets the JSON layout of a structurally valid document —
-- constructor tags, member names, array shapes — and turns it into
-- the explicit surface syntax of "Mithril.Core.Internal.Syntax",
-- recording a 'SourcePath' on every node and reference.  The
-- resolver ("Mithril.Core.Resolution") consumes only that syntax; it
-- never re-reads the JSON, so decoder and resolver together form one
-- frontend interpretation of @core\/schema.json@ rather than two
-- independently maintained walks.
--
-- Every failure here is a 'ResolverInvariantViolation': the input
-- already passed structural validation against the compiled-in
-- canonical schema, so a shape this decoder cannot interpret is
-- schema\/frontend drift or an implementation bug — an internal error
-- of the tool (exit status 2), never a problem with the user's
-- document.  The decoder is total: it walks the whole document,
-- aggregates every invariant violation it finds, and never throws.
--
-- Auditing note: any change to @core\/schema.json@ that touches
-- declaration namespaces, reference-bearing fields, constructor sets,
-- or structural bounds must audit this decoder and the two
-- representation modules together with "Mithril.Core.Resolution" —
-- see the schema-and-resolver evolution rule in
-- @docs\/compiler-architecture.md@.
module Mithril.Core.Internal.Decode
  ( decodeCoreValue
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text

import Mithril.Core.Internal.Report
  ( Collect
  , ResolverInvariantViolation
  , andThen
  , invariantAt
  , quoted
  , refuse
  )
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , indexPath
  , memberPath
  , rootPath
  )
import Mithril.Core.Internal.Syntax
  ( ActorContext (..)
  , OneOrTwo (..)
  , distinguishedUserEntity
  )
import qualified Mithril.Core.Internal.Syntax as Syntax

-- | A decoding step: aggregates invariant violations while building a
-- syntax node.
type Decode a = Collect ResolverInvariantViolation a

-- | Decode a structurally valid document value into the explicit
-- surface syntax.  Runs over the whole document and aggregates every
-- invariant violation; the caller normalizes and classifies them.
decodeCoreValue :: Value -> Decode Syntax.Document
decodeCoreValue = decodeDocument

--------------------------------------------------------------------
-- Shape helpers
--------------------------------------------------------------------

-- | Fail with one invariant violation.
invariant :: SourcePath -> Text -> Decode a
invariant path message = refuse (invariantAt path message)

-- | The JSON type of a value, for invariant messages.
jsonTypeName :: Value -> Text
jsonTypeName value =
  case value of
    Object _ -> "an object"
    Array _ -> "an array"
    String _ -> "a string"
    Number _ -> "a number"
    Bool _ -> "a boolean"
    Null -> "null"

asObject :: SourcePath -> Value -> Decode (KeyMap.KeyMap Value)
asObject path value =
  case value of
    Object members -> pure members
    _ -> invariant path ("expected a JSON object, found " <> jsonTypeName value)

asArray :: SourcePath -> Value -> Decode [(SourcePath, Value)]
asArray path value =
  case value of
    Array items ->
      pure
        [ (indexPath path index, item)
        | (index, item) <- zip [0 ..] (foldr (:) [] items)
        ]
    _ -> invariant path ("expected a JSON array, found " <> jsonTypeName value)

asText :: SourcePath -> Value -> Decode Text
asText path value =
  case value of
    String text -> pure text
    _ -> invariant path ("expected a JSON string, found " <> jsonTypeName value)

asBool :: SourcePath -> Value -> Decode Bool
asBool path value =
  case value of
    Bool flag -> pure flag
    _ -> invariant path ("expected a JSON boolean, found " <> jsonTypeName value)

-- | A required object member; the violation for a missing member
-- lands at the member's own path.
requiredMember :: SourcePath -> KeyMap.KeyMap Value -> Text -> Decode Value
requiredMember path members name =
  case KeyMap.lookup (Key.fromText name) members of
    Just value -> pure value
    Nothing ->
      invariant
        (memberPath path name)
        ("required member " <> quoted name <> " is missing")

-- | A required string member, located at its own path.
textMember :: SourcePath -> KeyMap.KeyMap Value -> Text -> Decode (Sourced Text)
textMember path members name =
  requiredMember path members name
    `andThen` \value ->
      Sourced valuePath <$> asText valuePath value
  where
    valuePath = memberPath path name

-- | A required boolean member.
boolMember :: SourcePath -> KeyMap.KeyMap Value -> Text -> Decode Bool
boolMember path members name =
  requiredMember path members name
    `andThen` asBool (memberPath path name)

-- | A required array member: its own path plus its located items.
arrayMember
  :: SourcePath
  -> KeyMap.KeyMap Value
  -> Text
  -> Decode (SourcePath, [(SourcePath, Value)])
arrayMember path members name =
  requiredMember path members name
    `andThen` \value -> (,) arrayPath <$> asArray arrayPath value
  where
    arrayPath = memberPath path name

-- | The constructor tag of a term, effect, result, or guarantee node.
kindOf :: SourcePath -> KeyMap.KeyMap Value -> Decode (Sourced Text)
kindOf path members = textMember path members "kind"

-- | Exactly one or two items, per the schema's endpoint bounds.
oneOrTwoOf :: SourcePath -> [a] -> Decode (OneOrTwo a)
oneOrTwoOf path items =
  case items of
    [only] -> pure (One only)
    [first', second'] -> pure (Two first' second')
    _ ->
      invariant
        path
        ("expected one or two array items, found " <> countOf items)

-- | At least one item, per the schema's @minItems 1@ bounds.
nonEmptyOf :: SourcePath -> [a] -> Decode (NonEmpty a)
nonEmptyOf path items =
  case NonEmpty.nonEmpty items of
    Just some -> pure some
    Nothing -> invariant path "expected a non-empty array, found no items"

-- | At most one item, per the schema's @maxItems 1@ bounds.
atMostOneOf :: SourcePath -> [a] -> Decode (Maybe a)
atMostOneOf path items =
  case items of
    [] -> pure Nothing
    [only] -> pure (Just only)
    _ ->
      invariant
        path
        ("expected at most one array item, found " <> countOf items)

countOf :: [a] -> Text
countOf = Text.pack . show . length

--------------------------------------------------------------------
-- The document
--------------------------------------------------------------------

decodeDocument :: Value -> Decode Syntax.Document
decodeDocument value =
  asObject rootPath value `andThen` \members ->
    assemble
      <$> textMember rootPath members "name"
      <*> ( requiredMember rootPath members "schema"
              `andThen` decodeSchema (memberPath rootPath "schema")
          )
      <*> ( arrayMember rootPath members "actions"
              `andThen` \(_, items) -> traverse (uncurry decodeAction) items
          )
      <*> ( arrayMember rootPath members "guarantees"
              `andThen` \(_, items) -> traverse (uncurry decodeGuarantee) items
          )
  where
    assemble name (entities, enums, relations) actions guarantees =
      Syntax.Document
        { Syntax.documentName = name
        , Syntax.documentEntities = entities
        , Syntax.documentEnums = enums
        , Syntax.documentRelations = relations
        , Syntax.documentActions = actions
        , Syntax.documentGuarantees = guarantees
        }

decodeSchema
  :: SourcePath
  -> Value
  -> Decode
      ( [Syntax.EntityDeclaration]
      , [Syntax.EnumDeclaration]
      , [Syntax.RelationDeclaration]
      )
decodeSchema path value =
  asObject path value `andThen` \members ->
    (,,)
      <$> ( arrayMember path members "entities"
              `andThen` \(entitiesPath, items) ->
                traverse (uncurry decodeEntity) items
                  `andThen` requireUserEntity entitiesPath
          )
      <*> ( arrayMember path members "enums"
              `andThen` \(_, items) -> traverse (uncurry decodeEnum) items
          )
      <*> ( arrayMember path members "relations"
              `andThen` \(_, items) -> traverse (uncurry decodeRelation) items
          )

-- | The schema structurally requires an entity named @User@
-- (@contains@); its absence after successful structural validation is
-- drift, because @Actor@ terms silently denote it.
requireUserEntity
  :: SourcePath
  -> [Syntax.EntityDeclaration]
  -> Decode [Syntax.EntityDeclaration]
requireUserEntity path entities
  | any declaresUser entities = pure entities
  | otherwise =
      invariant
        path
        ( "no entity named "
            <> quoted distinguishedUserEntity
            <> " is declared after structural validation"
        )
  where
    declaresUser declaration =
      sourcedValue (Syntax.entityDeclarationName declaration)
        == distinguishedUserEntity

--------------------------------------------------------------------
-- Schema declarations
--------------------------------------------------------------------

decodeEntity :: SourcePath -> Value -> Decode Syntax.EntityDeclaration
decodeEntity path value =
  asObject path value `andThen` \members ->
    Syntax.EntityDeclaration path
      <$> textMember path members "name"
      <*> ( arrayMember path members "attributes"
              `andThen` \(_, items) -> traverse (uncurry decodeAttribute) items
          )

decodeAttribute :: SourcePath -> Value -> Decode Syntax.AttributeDeclaration
decodeAttribute path value =
  asObject path value `andThen` \members ->
    Syntax.AttributeDeclaration path
      <$> textMember path members "name"
      <*> ( requiredMember path members "type"
              `andThen` decodeAttributeType (memberPath path "type")
          )

decodeAttributeType :: SourcePath -> Value -> Decode Syntax.AttributeType
decodeAttributeType path value =
  asObject path value `andThen` \members ->
    kindOf path members `andThen` \(Sourced kindPath kind) ->
      case kind of
        "Bool" -> pure (Syntax.BoolAttributeType path)
        "Enum" ->
          Syntax.EnumAttributeType path <$> textMember path members "enum"
        "EntityRef" ->
          Syntax.EntityRefAttributeType path
            <$> textMember path members "entity"
        _ ->
          invariant
            kindPath
            ("unexpected attribute type constructor " <> quoted kind)

decodeEnum :: SourcePath -> Value -> Decode Syntax.EnumDeclaration
decodeEnum path value =
  asObject path value `andThen` \members ->
    Syntax.EnumDeclaration path
      <$> textMember path members "name"
      <*> ( arrayMember path members "values"
              `andThen` \(valuesPath, items) ->
                traverse locatedText items `andThen` nonEmptyOf valuesPath
          )
      <*> decodeOrder members
  where
    decodeOrder members =
      case KeyMap.lookup "order" members of
        Nothing -> pure Nothing
        Just orderValue ->
          Just
            <$> ( asArray orderPath orderValue
                    `andThen` \items ->
                      traverse locatedText items `andThen` nonEmptyOf orderPath
                )
      where
        orderPath = memberPath path "order"
    locatedText (itemPath, item) = Sourced itemPath <$> asText itemPath item

decodeRelation :: SourcePath -> Value -> Decode Syntax.RelationDeclaration
decodeRelation path value =
  asObject path value `andThen` \members ->
    Syntax.RelationDeclaration path
      <$> textMember path members "name"
      <*> ( arrayMember path members "endpoints"
              `andThen` \(endpointsPath, items) ->
                oneOrTwoOf endpointsPath items
                  `andThen` traverse (uncurry decodeEndpoint)
          )
      <*> ( requiredMember path members "payload"
              `andThen` decodePayloadType (memberPath path "payload")
          )

decodeEndpoint :: SourcePath -> Value -> Decode Syntax.EndpointDeclaration
decodeEndpoint path value =
  asObject path value `andThen` \members ->
    Syntax.EndpointDeclaration path
      <$> textMember path members "name"
      <*> textMember path members "entity"

decodePayloadType :: SourcePath -> Value -> Decode Syntax.PayloadType
decodePayloadType path value =
  asObject path value `andThen` \members ->
    kindOf path members `andThen` \(Sourced kindPath kind) ->
      case kind of
        "Unit" -> pure (Syntax.UnitPayloadType path)
        "Enum" ->
          Syntax.EnumPayloadType path <$> textMember path members "enum"
        _ ->
          invariant
            kindPath
            ("unexpected relation-payload type constructor " <> quoted kind)

decodeParameterType :: SourcePath -> Value -> Decode Syntax.ParameterType
decodeParameterType path value =
  asObject path value `andThen` \members ->
    kindOf path members `andThen` \(Sourced kindPath kind) ->
      case kind of
        "Bool" -> pure (Syntax.BoolParameterType path)
        "Unit" -> pure (Syntax.UnitParameterType path)
        "Enum" ->
          Syntax.EnumParameterType path <$> textMember path members "enum"
        "EntityRef" ->
          Syntax.EntityRefParameterType path
            <$> textMember path members "entity"
        _ ->
          invariant
            kindPath
            ("unexpected parameter type constructor " <> quoted kind)

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

decodeAction :: SourcePath -> Value -> Decode Syntax.ActionDeclaration
decodeAction path value =
  asObject path value `andThen` \members ->
    Syntax.ActionDeclaration path
      <$> textMember path members "name"
      <*> ( arrayMember path members "parameters"
              `andThen` \(_, items) -> traverse (uncurry decodeParameter) items
          )
      <*> decodeBody members
  where
    decodeBody members =
      textMember path members "principalMode"
        `andThen` \(Sourced modePath mode) ->
          case mode of
            "AuthenticatedOnly" ->
              Syntax.AuthenticatedOnlyBody
                <$> ( requiredMember path members "allow"
                        `andThen` decodePolicyTerm
                          WithActor
                          (memberPath path "allow")
                    )
                <*> decodeShape WithActor path members
            "AnyPrincipal" ->
              Syntax.AnyPrincipalBody
                <$> ( requiredMember path members "allow"
                        `andThen` decodeAnyPrincipalAllow
                          (memberPath path "allow")
                    )
                <*> decodeShape WithoutActor path members
            _ -> invariant modePath ("unexpected principal mode " <> quoted mode)

decodeParameter :: SourcePath -> Value -> Decode Syntax.ParameterDeclaration
decodeParameter path value =
  asObject path value `andThen` \members ->
    Syntax.ParameterDeclaration path
      <$> textMember path members "name"
      <*> ( requiredMember path members "type"
              `andThen` decodeParameterType (memberPath path "type")
          )

decodeAnyPrincipalAllow :: SourcePath -> Value -> Decode Syntax.AnyPrincipalAllow
decodeAnyPrincipalAllow path value =
  asObject path value `andThen` \members ->
    Syntax.AnyPrincipalAllow
      <$> ( requiredMember path members "anonymous"
              `andThen` decodePolicyTerm
                WithoutActor
                (memberPath path "anonymous")
          )
      <*> ( requiredMember path members "authenticated"
              `andThen` decodePolicyTerm
                WithActor
                (memberPath path "authenticated")
          )

-- | Decode the classification\/effect\/result triple into the one
-- structurally permitted 'Syntax.ActionShape'.  A combination outside
-- the schema's compatibility table is drift.
decodeShape
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Decode (Syntax.ActionShape availability)
decodeShape context path members =
  textMember path members "classification"
    `andThen` \(Sourced classificationPath classification) ->
      requiredMember path members "effect" `andThen` \effectValue ->
        requiredMember path members "result" `andThen` \resultValue ->
          asObject effectPath effectValue `andThen` \effectMembers ->
            kindOf effectPath effectMembers
              `andThen` \(Sourced effectKindPath effectKind) ->
                asObject resultPath resultValue `andThen` \resultMembers ->
                  kindOf resultPath resultMembers
                    `andThen` \(Sourced resultKindPath resultKind) ->
                      decodeCombination
                        Combination
                          { combinationClassificationPath = classificationPath
                          , combinationClassification = classification
                          , combinationEffectMembers = effectMembers
                          , combinationEffectKindPath = effectKindPath
                          , combinationEffectKind = effectKind
                          , combinationResultMembers = resultMembers
                          , combinationResultKindPath = resultKindPath
                          , combinationResultKind = resultKind
                          }
  where
    effectPath = memberPath path "effect"
    resultPath = memberPath path "result"

    decodeCombination combination =
      case combinationClassification combination of
        "Read" ->
          requireEffectKind combination "NoChange" "a \"Read\" action" $
            requireResultKind combination "Observe" "a \"Read\" action" $
              Syntax.ReadShape effectPath resultPath
                <$> ( requiredMember
                        resultPath
                        (combinationResultMembers combination)
                        "entity"
                        `andThen` decodeValueTerm
                          context
                          (memberPath resultPath "entity")
                    )
        "Mutation" ->
          case combinationEffectKind combination of
            "CreateEntity" ->
              requireResultKind combination "Created" "a \"CreateEntity\" mutation" $
                Syntax.CreateShape
                  <$> decodeCreateEntityEffect
                    context
                    effectPath
                    (combinationEffectMembers combination)
                  <*> pure resultPath
            other
              | other `elem` doneEffectKinds ->
                  requireResultKind combination "Done" "this mutation effect" $
                    Syntax.MutationShape
                      <$> decodeDoneEffect
                        context
                        effectPath
                        (combinationEffectMembers combination)
                        other
                      <*> pure resultPath
              | otherwise ->
                  invariant
                    (combinationEffectKindPath combination)
                    ("unexpected effect constructor " <> quoted other)
        other ->
          invariant
            (combinationClassificationPath combination)
            ("unexpected classification " <> quoted other)

    requireEffectKind combination expected description continue
      | combinationEffectKind combination == expected = continue
      | combinationEffectKind combination `notElem` allEffectKinds =
          invariant
            (combinationEffectKindPath combination)
            ( "unexpected effect constructor "
                <> quoted (combinationEffectKind combination)
            )
      | otherwise =
          invariant
            (combinationEffectKindPath combination)
            ( "effect constructor "
                <> quoted (combinationEffectKind combination)
                <> " is structurally incompatible with "
                <> description
            )

    requireResultKind combination expected description continue
      | combinationResultKind combination == expected = continue
      | combinationResultKind combination `notElem` allResultKinds =
          invariant
            (combinationResultKindPath combination)
            ( "unexpected result constructor "
                <> quoted (combinationResultKind combination)
            )
      | otherwise =
          invariant
            (combinationResultKindPath combination)
            ( "result constructor "
                <> quoted (combinationResultKind combination)
                <> " is structurally incompatible with "
                <> description
            )

-- | The decoded classification\/effect\/result surface of one action,
-- gathered before the compatibility table is applied.
data Combination = Combination
  { combinationClassificationPath :: SourcePath
  , combinationClassification :: Text
  , combinationEffectMembers :: KeyMap.KeyMap Value
  , combinationEffectKindPath :: SourcePath
  , combinationEffectKind :: Text
  , combinationResultMembers :: KeyMap.KeyMap Value
  , combinationResultKindPath :: SourcePath
  , combinationResultKind :: Text
  }

doneEffectKinds :: [Text]
doneEffectKinds = ["NoChange", "DeleteEntity", "SetRelation", "RemoveRelation"]

allEffectKinds :: [Text]
allEffectKinds = "CreateEntity" : doneEffectKinds

allResultKinds :: [Text]
allResultKinds = ["Observe", "Created", "Done"]

decodeCreateEntityEffect
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Decode (Syntax.CreateEntityEffect availability)
decodeCreateEntityEffect context path members =
  Syntax.CreateEntityEffect path
    <$> textMember path members "entity"
    <*> ( requiredMember path members "attributes"
            `andThen` \attributesValue ->
              asObject attributesPath attributesValue
                `andThen` \attributeMembers ->
                  traverse
                    decodeInitializer
                    (KeyMap.toAscList attributeMembers)
        )
  where
    attributesPath = memberPath path "attributes"
    -- The initializer map is the syntax's one open-keyed object; the
    -- parser does not preserve authored member order, so ascending
    -- key order is the deterministic order used.
    decodeInitializer (key, termValue) =
      (,) (Sourced keyPath keyName)
        <$> decodeValueTerm context keyPath termValue
      where
        keyName = Key.toText key
        keyPath = memberPath attributesPath keyName

decodeDoneEffect
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Text
  -> Decode (Syntax.DoneEffect availability)
decodeDoneEffect context path members kind =
  case kind of
    "NoChange" -> pure (Syntax.NoChangeEffect path)
    "DeleteEntity" ->
      Syntax.DeleteEntityEffect path
        <$> valueTermMember context path members "target"
    "SetRelation" ->
      Syntax.SetRelationEffect path
        <$> textMember path members "relation"
        <*> endpointTerms context path members
        <*> valueTermMember context path members "payload"
    "RemoveRelation" ->
      Syntax.RemoveRelationEffect path
        <$> textMember path members "relation"
        <*> endpointTerms context path members
    _ -> invariant (memberPath path "kind") ("unexpected effect constructor " <> quoted kind)

--------------------------------------------------------------------
-- Terms
--------------------------------------------------------------------

-- | The value-term constructor tags (the family allowed as an
-- @Attribute@ source and in every value position).
valueTermKinds :: [Text]
valueTermKinds = ["Bool", "Unit", "Enum", "Argument", "Actor", "Attribute"]

decodeValueTerm
  :: ActorContext availability
  -> SourcePath
  -> Value
  -> Decode (Syntax.ValueTerm availability)
decodeValueTerm context path value =
  asObject path value `andThen` \members ->
    kindOf path members `andThen` \(Sourced kindPath kind) ->
      if kind `elem` valueTermKinds
        then decodeValueTermKind context path members kind
        else
          invariant
            kindPath
            ("unexpected value-term constructor " <> quoted kind)

-- | Decode a value term whose members and (value-family) constructor
-- tag are known.
decodeValueTermKind
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Text
  -> Decode (Syntax.ValueTerm availability)
decodeValueTermKind context path members kind =
  case kind of
    "Bool" -> Syntax.BoolTerm path <$> boolMember path members "value"
    "Unit" -> pure (Syntax.UnitTerm path)
    "Enum" ->
      Syntax.EnumTerm path
        <$> textMember path members "enum"
        <*> textMember path members "value"
    "Argument" -> Syntax.ArgumentTerm path <$> textMember path members "name"
    "Actor" ->
      case context of
        WithActor -> pure (Syntax.ActorTerm path)
        WithoutActor ->
          invariant
            (memberPath path "kind")
            "an Actor term appears in an actor-free context after structural validation"
    "Attribute" ->
      Syntax.AttributeTerm path
        <$> valueTermMember context path members "source"
        <*> textMember path members "attribute"
    _ ->
      invariant
        (memberPath path "kind")
        ("unexpected value-term constructor " <> quoted kind)

-- | A required member decoded as a value term.
valueTermMember
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Text
  -> Decode (Syntax.ValueTerm availability)
valueTermMember context path members name =
  requiredMember path members name
    `andThen` decodeValueTerm context (memberPath path name)

-- | A required member decoded as a policy term.
policyTermMember
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Text
  -> Decode (Syntax.PolicyTerm availability)
policyTermMember context path members name =
  requiredMember path members name
    `andThen` decodePolicyTerm context (memberPath path name)

-- | The one-or-two endpoint terms of a lookup or relation effect.
endpointTerms
  :: ActorContext availability
  -> SourcePath
  -> KeyMap.KeyMap Value
  -> Decode (OneOrTwo (Syntax.ValueTerm availability))
endpointTerms context path members =
  arrayMember path members "endpoints"
    `andThen` \(endpointsPath, items) ->
      oneOrTwoOf endpointsPath items
        `andThen` traverse (uncurry (decodeValueTerm context))

decodePolicyTerm
  :: ActorContext availability
  -> SourcePath
  -> Value
  -> Decode (Syntax.PolicyTerm availability)
decodePolicyTerm context path value =
  asObject path value `andThen` \members ->
    kindOf path members `andThen` \(Sourced kindPath kind) ->
      if kind `elem` valueTermKinds
        then
          Syntax.ValuePolicyTerm
            <$> decodeValueTermKind context path members kind
        else case kind of
          "Lookup" ->
            Syntax.LookupTerm path
              <$> textMember path members "relation"
              <*> endpointTerms context path members
          "None" ->
            Syntax.NoneTerm path
              <$> ( requiredMember path members "payloadType"
                      `andThen` decodePayloadType
                        (memberPath path "payloadType")
                  )
          "Some" ->
            Syntax.SomeTerm path <$> valueTermMember context path members "value"
          "IsSome" ->
            Syntax.IsSomeTerm path
              <$> policyTermMember context path members "value"
          "Equal" ->
            Syntax.EqualTerm path
              <$> policyTermMember context path members "left"
              <*> policyTermMember context path members "right"
          "LessOrEqual" ->
            Syntax.LessOrEqualTerm path
              <$> policyTermMember context path members "left"
              <*> policyTermMember context path members "right"
          "And" ->
            Syntax.AndTerm path
              <$> policyTermMember context path members "left"
              <*> policyTermMember context path members "right"
          "Or" ->
            Syntax.OrTerm path
              <$> policyTermMember context path members "left"
              <*> policyTermMember context path members "right"
          "Not" ->
            Syntax.NotTerm path
              <$> policyTermMember context path members "value"
          _ ->
            invariant
              kindPath
              ("unexpected policy-term constructor " <> quoted kind)

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

decodeGuarantee :: SourcePath -> Value -> Decode Syntax.Guarantee
decodeGuarantee path value =
  asObject path value `andThen` \members ->
    kindOf path members `andThen` \(Sourced kindPath kind) ->
      case kind of
        "AuthenticatedMutation" ->
          -- The target selector is structurally the constant
          -- classification "Mutation"; it carries no reference and no
          -- model content beyond the selection itself.
          pure (Syntax.AuthenticatedMutationGuarantee path)
        "TenantIsolation" ->
          Syntax.TenantIsolationGuarantee path
            <$> ( requiredMember path members "access"
                    `andThen` decodeTenantIsolationAccess
                      (memberPath path "access")
                )
            <*> decodeCases members decodeTenantIsolationCase
        "NoSelfPrivilegeEscalation" ->
          Syntax.NoSelfPrivilegeEscalationGuarantee path
            <$> ( requiredMember path members "authority"
                    `andThen` decodeAuthority (memberPath path "authority")
                )
            <*> decodeCases members decodeEscalationCase
        _ ->
          invariant
            kindPath
            ("unexpected guarantee constructor " <> quoted kind)
  where
    decodeCases
      :: KeyMap.KeyMap Value
      -> (SourcePath -> Value -> Decode a)
      -> Decode (NonEmpty a)
    decodeCases members decodeCase =
      arrayMember path members "cases"
        `andThen` \(casesPath, items) ->
          traverse (uncurry decodeCase) items `andThen` nonEmptyOf casesPath

-- | The structural @TenantIsolation@ access relation: three symbolic
-- references, resolved later (the endpoints within the relation).
decodeTenantIsolationAccess
  :: SourcePath -> Value -> Decode Syntax.TenantIsolationAccess
decodeTenantIsolationAccess path value =
  asObject path value `andThen` \members ->
    Syntax.TenantIsolationAccess path
      <$> textMember path members "relation"
      <*> textMember path members "subjectEndpoint"
      <*> textMember path members "tenantEndpoint"

-- | A @TenantIsolation@ case: the tenant and protected terms are
-- structurally actor-free, so they decode in the actor-free context
-- (an @Actor@ inside them after structural validation is drift).
decodeTenantIsolationCase
  :: SourcePath -> Value -> Decode Syntax.TenantIsolationCase
decodeTenantIsolationCase path value =
  asObject path value `andThen` \members ->
    Syntax.TenantIsolationCase path
      <$> textMember path members "action"
      <*> valueTermMember WithoutActor path members "tenant"
      <*> policyTermMember WithoutActor path members "protected"

decodeEscalationCase :: SourcePath -> Value -> Decode Syntax.EscalationCase
decodeEscalationCase path value =
  asObject path value `andThen` \members ->
    Syntax.EscalationCase path
      <$> textMember path members "action"
      <*> ( arrayMember path members "scope"
              `andThen` \(scopePath, items) ->
                atMostOneOf scopePath items
                  `andThen` traverse (uncurry (decodeValueTerm WithActor))
          )

decodeAuthority :: SourcePath -> Value -> Decode Syntax.Authority
decodeAuthority path value =
  asObject path value `andThen` \members ->
    Syntax.Authority path
      <$> textMember path members "relation"
      <*> textMember path members "subjectEndpoint"
      <*> ( arrayMember path members "scopeEndpoints"
              `andThen` \(scopePath, items) ->
                traverse locatedText items `andThen` atMostOneOf scopePath
          )
      <*> ( textMember path members "absenceLevel"
              `andThen` \(Sourced levelPath level) ->
                case level of
                  -- The fixed Core v0 constant, kept with the path of
                  -- the authored member like every decoded leaf.
                  "Bottom" -> pure (Sourced levelPath Syntax.AbsenceBottom)
                  _ ->
                    invariant
                      levelPath
                      ("unexpected absence level " <> quoted level)
          )
      <*> textMember path members "payloadOrder"
  where
    locatedText (itemPath, item) = Sourced itemPath <$> asText itemPath item
