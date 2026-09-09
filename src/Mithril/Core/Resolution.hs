{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The name-resolution boundary of the Mithril Core v0 frontend:
-- complete name resolution, producing the explicit internal resolved
-- representation.
--
-- > structurally-valid opaque document
-- >   -> complete name resolution          ('resolveCoreDocument')
-- >   -> resolved opaque document
--
-- 'resolveCoreDocument' consumes the structurally valid document
-- produced by "Mithril.Core.Validation" and checks every Core v0 name
-- site.  It establishes exactly two kinds of fact:
--
-- 1. /Declaration-name uniqueness/, independently per namespace: the
--    four global namespaces (entities, enums, relations, actions) and
--    the owner-local namespaces (attributes within one entity,
--    endpoints within one relation, parameters within one action).
--    The same text may name declarations in different namespaces or
--    under different owners.
--
-- 2. /Reference resolution/: every name reference resolves to an
--    existing declaration in its correct namespace — enum and entity
--    references in declared types, relation endpoint entities,
--    relation payload enums, enum-order members against the enum's
--    own values, every term constructor (@Enum@, @Argument@,
--    @Attribute@, @Lookup@, @None@ payload enums, and all nested
--    terms), effect targets and @CreateEntity@ initializer keys,
--    result terms, and every guarantee reference (case actions and
--    their action-scoped terms, the @TenantIsolation@ access relation
--    with its subject and tenant endpoints — endpoints are
--    relation-owned members, resolved within the resolved access
--    relation, never global names — and the
--    @NoSelfPrivilegeEscalation@ authority relation, endpoints, and
--    payload-order enum).
--
-- On success the resolved model additionally records the resolver's
-- own designation of the distinguished @User@ entity
-- ('Resolved.modelUserEntity'): the unique entity declaration
-- carrying the schema-designated name, taken from the same
-- entity-namespace lookup that resolves every @Actor@ term.  This is
-- the one place in the pipeline that selects that identity by name;
-- the typechecker validates and the normalizer propagates the stored
-- identity, and neither searches names again.
--
-- Internally the stage is one frontend interpretation in two passes:
-- "Mithril.Core.Internal.Decode" decodes the structurally valid JSON
-- into the explicit surface syntax (source paths and symbolic
-- references; the only place that reads JSON), and this module builds
-- the namespaces over that syntax and resolves every symbolic
-- reference, producing the identifier-based resolved model of
-- "Mithril.Core.Internal.Resolved".  On success the raw JSON value is
-- discarded: a @'CoreDocument' 'Resolved'@ carries the resolved model,
-- not an Aeson @Value@, so no later compiler stage can reinterpret
-- raw JSON or rebuild name resolution.
--
-- The only typing-like work in this stage is the narrow declared-type
-- lookup needed to select the entity-local namespace of an
-- @Attribute@ projection: @Actor@ denotes the distinguished @User@
-- entity, an @Argument@ denotes an entity when its declared parameter
-- type is @EntityRef@, and a nested @Attribute@ denotes an entity
-- when its resolved attribute declaration has @EntityRef@ type.  A
-- source that is known /not/ to denote an entity reference is a
-- resolution failure; nothing else about types is checked.
--
-- Everything else about types — general term typing, operand
-- compatibility, enum-order validity, relation and effect
-- compatibility, result typing, and guarantee well-typedness —
-- belongs to the static typechecker ("Mithril.Core.Typing"), with
-- normalization ("Mithril.Core.Normalization") after it.  A
-- structurally valid document can therefore resolve successfully and
-- still fail the typechecker.  A @'CoreDocument' 'Resolved'@ is an
-- attestation about names only — /not/ typed normalized Core, and no
-- semantic or security property.
--
-- == Failure classification
--
-- Name problems in the user's document are 'ResolutionViolation's,
-- reported with raw path segments (render with
-- 'Mithril.Core.Validation.renderJsonPointer'), aggregated across
-- independent sites, deduplicated, and deterministically ordered.  A
-- dependent site whose prerequisite name is unknown or ambiguous is
-- suppressed rather than reported, so one root problem does not
-- cascade.
--
-- Shapes that structural validation cannot produce indicate
-- schema\/frontend drift or a decoder\/resolver bug, never a user
-- error.  They are 'ResolverInvariantViolation's, kept separate from
-- semantic violations, and they dominate: if the decoder cannot
-- interpret the document, the frontend no longer trusts its reading
-- and reports 'ResolverInvariantViolations' without attempting name
-- resolution.  Neither pass ever throws.
module Mithril.Core.Resolution
  ( -- * Pipeline stage
    Resolved

    -- * Failures and violations
  , ResolutionFailure (..)
  , ResolutionViolation (..)
  , ResolverInvariantViolation (..)

    -- * Name resolution
  , resolveCoreDocument

    -- * Violation normalization
  , normalizeResolutionViolations
  ) where

import Data.Foldable (toList)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)

import Mithril.Core.Internal.Decode (decodeCoreValue)
import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Resolved
  , StructurallyValid
  )
import Mithril.Core.Internal.Report
  ( Collect
  , ResolutionViolation (..)
  , ResolverInvariantViolation (..)
  , quoted
  , refuse
  , reporting
  , runCollect
  , suppressed
  , violationAt
  )
import qualified Mithril.Core.Internal.Resolved as Resolved
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , sourcePathSegments
  )
import Mithril.Core.Internal.Syntax
  ( OneOrTwo (..)
  , distinguishedUserEntity
  )
import qualified Mithril.Core.Internal.Syntax as Syntax
import Mithril.Core.Validation (renderJsonPointer)

-- | Why 'resolveCoreDocument' refused the stage transition.
data ResolutionFailure
  = -- | The document has name problems.  The violations are sorted
    -- and deduplicated ('normalizeResolutionViolations').
    ResolutionViolations (NonEmpty ResolutionViolation)
  | -- | The frontend hit shapes it cannot interpret.  This
    -- classification dominates: when the decoder cannot trust its
    -- interpretation of the document, no ordinary name verdict is
    -- reported.  The violations are sorted and deduplicated.
    ResolverInvariantViolations (NonEmpty ResolverInvariantViolation)
  deriving (Eq, Show)

-- | Resolve every Core v0 name site of a structurally valid document
-- and construct the explicit resolved representation.
--
-- Pure and deterministic: the same document always produces the same
-- result, with violations aggregated across independent sites,
-- sorted, and deduplicated.  On success the document is carried as
-- the internal decoded and name-resolved Core model — the raw JSON
-- value is discarded at this boundary — and this function is the only
-- public producer of a @'CoreDocument' 'Resolved'@.
resolveCoreDocument
  :: CoreDocument StructurallyValid
  -> Either ResolutionFailure (CoreDocument Resolved)
resolveCoreDocument (CoreDocument documentValue) =
  case runCollect (decodeCoreValue documentValue) of
    (invariantProblems, decodedDocument) ->
      case NonEmpty.nonEmpty (normalizeInvariantViolations invariantProblems) of
        Just someInvariants -> Left (ResolverInvariantViolations someInvariants)
        Nothing ->
          case decodedDocument of
            Nothing -> Left (internalCompletenessFailure "schema decoder")
            Just document ->
              case runCollect (resolveDocument document) of
                (violations, resolvedModel) ->
                  case NonEmpty.nonEmpty (normalizeResolutionViolations violations) of
                    Just someViolations ->
                      Left (ResolutionViolations someViolations)
                    Nothing ->
                      case resolvedModel of
                        Nothing -> Left (internalCompletenessFailure "name resolver")
                        Just model -> Right (CoreDocument model)

-- | The totality net: a pass that produced neither a result nor a
-- diagnostic is an implementation bug, classified as an internal
-- invariant failure rather than swallowed or thrown.  Unreachable
-- when decoder and resolver uphold their contract that every missing
-- result traces to a reported problem.
internalCompletenessFailure :: Text -> ResolutionFailure
internalCompletenessFailure passName =
  ResolverInvariantViolations
    ( ResolverInvariantViolation
        []
        ("the " <> passName <> " produced neither a result nor a diagnostic")
        :| []
    )

-- | Deterministically sort resolution violations (by path, then
-- message) and remove duplicates.  This is the exact normalization
-- applied by 'resolveCoreDocument' before violations are returned.
normalizeResolutionViolations :: [ResolutionViolation] -> [ResolutionViolation]
normalizeResolutionViolations = map NonEmpty.head . NonEmpty.group . sort

-- | The same normalization for invariant violations.
normalizeInvariantViolations
  :: [ResolverInvariantViolation] -> [ResolverInvariantViolation]
normalizeInvariantViolations = map NonEmpty.head . NonEmpty.group . sort

--------------------------------------------------------------------
-- Internal: resolution computations
--------------------------------------------------------------------

-- | A resolution step: aggregates name violations while building a
-- resolved node.  'suppressed' marks a dependent site whose root
-- problem is already reported elsewhere.
type Resolve a = Collect ResolutionViolation a

-- | Fail with one violation at a source path.
refuseAt :: SourcePath -> Text -> Resolve a
refuseAt path message = refuse (violationAt path message)

-- | Render a source path as a JSON pointer for duplicate messages.
renderPointer :: SourcePath -> Text
renderPointer = renderJsonPointer . sourcePathSegments

--------------------------------------------------------------------
-- Internal: namespaces
--------------------------------------------------------------------

-- | One deterministic namespace: the first declaration per name plus
-- the set of names declared more than once.
data Namespace a = Namespace
  { namespaceEntries :: Map Text a
  , namespaceAmbiguous :: Set Text
  }

emptyNamespace :: Namespace a
emptyNamespace = Namespace Map.empty Set.empty

-- | The three possible outcomes of a name lookup.  'NameAmbiguous'
-- means the name is declared more than once: the duplicate is already
-- reported at its declaration site, so dependent checks are
-- suppressed rather than resolved against an arbitrary pick.
data NameLookup a = NameMissing | NameAmbiguous | NameFound a

lookupName :: Namespace a -> Text -> NameLookup a
lookupName namespace name
  | Set.member name (namespaceAmbiguous namespace) = NameAmbiguous
  | otherwise =
      maybe NameMissing NameFound (Map.lookup name (namespaceEntries namespace))

-- | Build a namespace from declarations in document order.  The first
-- declaration of a name wins deterministically; every later
-- declaration of the same name is reported at its own name field,
-- with a message identifying the first declaration.
buildNamespace
  :: (Text -> Text -> Text)
  -- ^ Duplicate message: the name and the rendered pointer of the
  -- first declaration's name field.
  -> [(Sourced Text, a)]
  -- ^ (located name, payload) in declaration order.
  -> ([ResolutionViolation], Namespace a)
buildNamespace duplicateMessage = go [] Map.empty emptyNamespace
  where
    go reports firsts namespace entries =
      case entries of
        [] -> (reports, namespace)
        (Sourced namePath name, payload) : rest ->
          case Map.lookup name firsts of
            Nothing ->
              go
                reports
                (Map.insert name namePath firsts)
                namespace
                  { namespaceEntries =
                      Map.insert name payload (namespaceEntries namespace)
                  }
                rest
            Just firstPath ->
              go
                ( reports
                    <> [ violationAt
                          namePath
                          (duplicateMessage name (renderPointer firstPath))
                       ]
                )
                firsts
                namespace
                  { namespaceAmbiguous =
                      Set.insert name (namespaceAmbiguous namespace)
                  }
                rest

-- | The duplicate message of a global namespace.
globalDuplicateMessage :: Text -> Text -> Text -> Text
globalDuplicateMessage namespaceLabel name firstPointer =
  "duplicate "
    <> namespaceLabel
    <> " name "
    <> quoted name
    <> " (first declared at "
    <> firstPointer
    <> ")"

-- | The duplicate message of an owner-local namespace.
ownedDuplicateMessage :: Text -> Text -> Text -> Text -> Text -> Text
ownedDuplicateMessage memberLabel ownerLabel ownerName name firstPointer =
  "duplicate "
    <> memberLabel
    <> " name "
    <> quoted name
    <> " in "
    <> ownerLabel
    <> " "
    <> quoted ownerName
    <> " (first declared at "
    <> firstPointer
    <> ")"

--------------------------------------------------------------------
-- Internal: declaration indexes
--------------------------------------------------------------------

-- | An attribute entry: its identifier and its declared type, which
-- drives the narrow entity-denotation lookup.
data AttributeEntry = AttributeEntry Resolved.AttributeId Syntax.AttributeType

-- | An entity entry: its identifier, its name (for diagnostics), and
-- its attribute namespace.
data EntityEntry = EntityEntry
  { entityEntryId :: Resolved.EntityId
  , entityEntryName :: Text
  , entityEntryAttributes :: Namespace AttributeEntry
  }

-- | An enum entry: the enum's identifier, its members — the one
-- place its 'Resolved.EnumValueId's are assigned — and the one
-- name-keyed lookup table over exactly those members.  Enum terms
-- (via the enum namespace) and the enum's own order resolution (via
-- the positional entry) share this table; no equivalent map is
-- rebuilt elsewhere.  Value uniqueness is already structural
-- (@uniqueItems@), so no duplicate tracking is needed here.
data EnumEntry = EnumEntry
  { enumEntryId :: Resolved.EnumId
  , enumEntryMembers :: NonEmpty Resolved.EnumMember
  , enumEntryValues :: Map Text Resolved.EnumValueId
  }

-- | A relation entry: its identifier and its endpoint namespace.
data RelationEntry = RelationEntry Resolved.RelationId (Namespace Resolved.EndpointId)

-- | A parameter entry: its identifier and its declared type.
data ParameterEntry = ParameterEntry Resolved.ParameterId Syntax.ParameterType

-- | An action entry: its identifier, its name (for diagnostics), and
-- its parameter namespace.
data ActionEntry = ActionEntry
  { actionEntryId :: Resolved.ActionId
  , actionEntryName :: Text
  , actionEntryParameters :: Namespace ParameterEntry
  }

-- | The four global namespaces of a Core v0 document, plus the
-- resolver's one designation of the distinguished @User@ entity: the
-- entity namespace's lookup of the schema-designated name, made once
-- here and consumed both by every @Actor@ term ('resolveActorTerm')
-- and by the resolved model's own record of the identity
-- ('resolveDistinguishedUser').
data Indexes = Indexes
  { entityIndex :: Namespace EntityEntry
  , enumIndex :: Namespace EnumEntry
  , relationIndex :: Namespace RelationEntry
  , actionIndex :: Namespace ActionEntry
  , userDesignation :: NameLookup EntityEntry
  }

-- | Build every namespace, reporting all duplicate declarations, and
-- return the positional enum and action entries so each enum's order
-- is resolved against its own value table and each action's body is
-- resolved in its own parameter environment even when its name is
-- duplicated.
buildIndexes
  :: Syntax.Document
  -> ([ResolutionViolation], Indexes, [EnumEntry], [ActionEntry])
buildIndexes document =
  ( concat (map entityMemberReports entityPreparations)
      <> entityReports
      <> enumReports
      <> concat (map relationMemberReports relationPreparations)
      <> relationReports
      <> concat (map actionMemberReports actionPreparations)
      <> actionReports
  , Indexes
      { entityIndex = entityNamespace
      , enumIndex = enumNamespace
      , relationIndex = relationNamespace
      , actionIndex = actionNamespace
      , userDesignation = lookupName entityNamespace distinguishedUserEntity
      }
  , map snd enumPreparations
  , map preparedActionEntry actionPreparations
  )
  where
    entityPreparations =
      [ (declaration, EntityEntry owner name attributeNamespace, attributeReports)
      | (position, declaration) <-
          withPositions (Syntax.documentEntities document)
      , let owner = Resolved.EntityId position
            name = sourcedValue (Syntax.entityDeclarationName declaration)
            (attributeReports, attributeNamespace) =
              buildNamespace
                (ownedDuplicateMessage "attribute" "entity" name)
                [ ( Syntax.attributeDeclarationName attribute
                  , AttributeEntry
                      (Resolved.AttributeId owner attributePosition)
                      (Syntax.attributeDeclarationType attribute)
                  )
                | (attributePosition, attribute) <-
                    withPositions (Syntax.entityDeclarationAttributes declaration)
                ]
      ]
    entityMemberReports (_, _, reports) = reports
    (entityReports, entityNamespace) =
      buildNamespace
        (globalDuplicateMessage "entity")
        [ (Syntax.entityDeclarationName declaration, entry)
        | (declaration, entry, _) <- entityPreparations
        ]

    -- One preparation per declaration, in authored order: the single
    -- assignment of each enum's member identifiers and its single
    -- lookup table.  The name-keyed namespace below indexes these same
    -- entries (first declaration wins); nothing rebuilds them.
    enumPreparations =
      [ (declaration, EnumEntry enumId members (memberLookup members))
      | (position, declaration) <-
          withPositions (Syntax.documentEnums document)
      , let enumId = Resolved.EnumId position
            members =
              NonEmpty.zipWith
                ( \valuePosition member ->
                    Resolved.EnumMember
                      (Resolved.EnumValueId enumId valuePosition)
                      member
                )
                (0 :| [1 ..])
                (Syntax.enumDeclarationValues declaration)
      ]
    (enumReports, enumNamespace) =
      buildNamespace
        (globalDuplicateMessage "enum")
        [ (Syntax.enumDeclarationName declaration, entry)
        | (declaration, entry) <- enumPreparations
        ]

    relationPreparations =
      [ (declaration, RelationEntry owner endpointNamespace, endpointReports)
      | (position, declaration) <-
          withPositions (Syntax.documentRelations document)
      , let owner = Resolved.RelationId position
            name = sourcedValue (Syntax.relationDeclarationName declaration)
            (endpointReports, endpointNamespace) =
              buildNamespace
                (ownedDuplicateMessage "endpoint" "relation" name)
                [ ( Syntax.endpointDeclarationName endpoint
                  , Resolved.EndpointId owner endpointPosition
                  )
                | (endpointPosition, endpoint) <-
                    withPositions
                      (toList (Syntax.relationDeclarationEndpoints declaration))
                ]
      ]
    relationMemberReports (_, _, reports) = reports
    (relationReports, relationNamespace) =
      buildNamespace
        (globalDuplicateMessage "relation")
        [ (Syntax.relationDeclarationName declaration, entry)
        | (declaration, entry, _) <- relationPreparations
        ]

    actionPreparations =
      [ (declaration, ActionEntry actionId name parameterNamespace, parameterReports)
      | (position, declaration) <-
          withPositions (Syntax.documentActions document)
      , let actionId = Resolved.ActionId position
            name = sourcedValue (Syntax.actionDeclarationName declaration)
            (parameterReports, parameterNamespace) =
              buildNamespace
                (ownedDuplicateMessage "parameter" "action" name)
                [ ( Syntax.parameterDeclarationName parameter
                  , ParameterEntry
                      (Resolved.ParameterId actionId parameterPosition)
                      (Syntax.parameterDeclarationType parameter)
                  )
                | (parameterPosition, parameter) <-
                    withPositions (Syntax.actionDeclarationParameters declaration)
                ]
      ]
    actionMemberReports (_, _, reports) = reports
    preparedActionEntry (_, entry, _) = entry
    (actionReports, actionNamespace) =
      buildNamespace
        (globalDuplicateMessage "action")
        [ (Syntax.actionDeclarationName declaration, entry)
        | (declaration, entry, _) <- actionPreparations
        ]

-- | The name-keyed lookup table over an enum's members, derived once
-- from the member list that assigned their identifiers.
memberLookup :: NonEmpty Resolved.EnumMember -> Map Text Resolved.EnumValueId
memberLookup members =
  Map.fromList
    [ ( sourcedValue (Resolved.enumMemberName member)
      , Resolved.enumMemberId member
      )
    | member <- NonEmpty.toList members
    ]

withPositions :: [a] -> [(Int, a)]
withPositions = zip [0 ..]

withPositionsOneOrTwo :: OneOrTwo a -> OneOrTwo (Int, a)
withPositionsOneOrTwo shape =
  case shape of
    One only -> One (0, only)
    Two first' second' -> Two (0, first') (1, second')

--------------------------------------------------------------------
-- Internal: reference resolution
--------------------------------------------------------------------

-- | Resolve an enum reference.  An ambiguous (duplicated) name is
-- already reported at its declaration sites and is suppressed here.
resolveEnumReference
  :: Indexes -> Sourced Text -> Resolve (Resolved.Ref Resolved.EnumId)
resolveEnumReference indexes (Sourced path name) =
  case lookupName (enumIndex indexes) name of
    NameMissing -> refuseAt path ("unknown enum " <> quoted name)
    NameAmbiguous -> suppressed
    NameFound entry -> pure (Resolved.Ref path (enumEntryId entry))

-- | Resolve an entity reference; see 'resolveEnumReference'.
resolveEntityReference
  :: Indexes -> Sourced Text -> Resolve (Resolved.Ref Resolved.EntityId)
resolveEntityReference indexes (Sourced path name) =
  case lookupName (entityIndex indexes) name of
    NameMissing -> refuseAt path ("unknown entity " <> quoted name)
    NameAmbiguous -> suppressed
    NameFound entry -> pure (Resolved.Ref path (entityEntryId entry))

-- | Resolve a relation reference; see 'resolveEnumReference'.
resolveRelationReference
  :: Indexes -> Sourced Text -> Resolve (Resolved.Ref Resolved.RelationId)
resolveRelationReference indexes (Sourced path name) =
  case lookupName (relationIndex indexes) name of
    NameMissing -> refuseAt path ("unknown relation " <> quoted name)
    NameAmbiguous -> suppressed
    NameFound (RelationEntry relationId _) -> pure (Resolved.Ref path relationId)

--------------------------------------------------------------------
-- Internal: declared types
--------------------------------------------------------------------

resolveAttributeType
  :: Indexes -> Syntax.AttributeType -> Resolve Resolved.AttributeType
resolveAttributeType indexes attributeType =
  case attributeType of
    Syntax.BoolAttributeType path -> pure (Resolved.BoolAttributeType path)
    Syntax.EnumAttributeType path reference ->
      Resolved.EnumAttributeType path <$> resolveEnumReference indexes reference
    Syntax.EntityRefAttributeType path reference ->
      Resolved.EntityRefAttributeType path
        <$> resolveEntityReference indexes reference

resolveParameterType
  :: Indexes -> Syntax.ParameterType -> Resolve Resolved.ParameterType
resolveParameterType indexes parameterType =
  case parameterType of
    Syntax.BoolParameterType path -> pure (Resolved.BoolParameterType path)
    Syntax.UnitParameterType path -> pure (Resolved.UnitParameterType path)
    Syntax.EnumParameterType path reference ->
      Resolved.EnumParameterType path <$> resolveEnumReference indexes reference
    Syntax.EntityRefParameterType path reference ->
      Resolved.EntityRefParameterType path
        <$> resolveEntityReference indexes reference

resolvePayloadType
  :: Indexes -> Syntax.PayloadType -> Resolve Resolved.PayloadType
resolvePayloadType indexes payloadType =
  case payloadType of
    Syntax.UnitPayloadType path -> pure (Resolved.UnitPayloadType path)
    Syntax.EnumPayloadType path reference ->
      Resolved.EnumPayloadType path <$> resolveEnumReference indexes reference

--------------------------------------------------------------------
-- Internal: terms
--------------------------------------------------------------------

-- | The context a term is resolved in: the global indexes plus the
-- action-local parameter environment.  A 'Nothing' environment means
-- it could not be determined (the enclosing guarantee case names an
-- unknown or duplicated action): @Argument@ checks are suppressed
-- rather than guessed, while every environment-independent check
-- still runs.
data TermScope = TermScope
  { scopeIndexes :: Indexes
  , scopeParameters :: Maybe ActionEntry
  }

-- | What a value term denotes, as far as attribute-namespace
-- selection needs to know.  This is deliberately the only
-- typing-shaped judgment in this stage.
data Denotation
  = -- | The term denotes a reference to this entity.
    DenotesEntity EntityEntry
  | -- | The term is known not to denote an entity reference.
    DenotesNonEntity
  | -- | The denotation could not be determined because a prerequisite
    -- name is unknown or ambiguous; dependent checks are suppressed.
    DenotesUnknown

-- | The entity denotation of a declared-type entity name.  The
-- reference itself is checked (and any problem reported) where the
-- declared type is resolved; an unknown or ambiguous name here only
-- suppresses dependent member checks.
entityDenotation :: Indexes -> Text -> Denotation
entityDenotation indexes entityName =
  case lookupName (entityIndex indexes) entityName of
    NameFound entry -> DenotesEntity entry
    NameMissing -> DenotesUnknown
    NameAmbiguous -> DenotesUnknown

parameterTypeDenotation :: Indexes -> Syntax.ParameterType -> Denotation
parameterTypeDenotation indexes parameterType =
  case parameterType of
    Syntax.EntityRefParameterType _ (Sourced _ entityName) ->
      entityDenotation indexes entityName
    Syntax.BoolParameterType _ -> DenotesNonEntity
    Syntax.UnitParameterType _ -> DenotesNonEntity
    Syntax.EnumParameterType _ _ -> DenotesNonEntity

attributeTypeDenotation :: Indexes -> Syntax.AttributeType -> Denotation
attributeTypeDenotation indexes attributeType =
  case attributeType of
    Syntax.EntityRefAttributeType _ (Sourced _ entityName) ->
      entityDenotation indexes entityName
    Syntax.BoolAttributeType _ -> DenotesNonEntity
    Syntax.EnumAttributeType _ _ -> DenotesNonEntity

-- | Resolve a value term, returning its resolved node and its
-- denotation.  The two are independent: a term whose references
-- resolve may still have an unknown denotation (and vice versa the
-- denotation of @Bool@\/@Unit@\/@Enum@ terms is known even when a
-- reference inside them is not).
resolveValueTerm
  :: TermScope
  -> Syntax.ValueTerm availability
  -> (Resolve (Resolved.ValueTerm availability), Denotation)
resolveValueTerm scope term =
  case term of
    Syntax.BoolTerm path flag ->
      (pure (Resolved.BoolTerm path flag), DenotesNonEntity)
    Syntax.UnitTerm path -> (pure (Resolved.UnitTerm path), DenotesNonEntity)
    Syntax.EnumTerm path enumReference valueReference ->
      ( resolveEnumTerm (scopeIndexes scope) path enumReference valueReference
      , DenotesNonEntity
      )
    Syntax.ArgumentTerm path nameReference ->
      resolveArgumentTerm scope path nameReference
    Syntax.ActorTerm path -> resolveActorTerm (scopeIndexes scope) path
    Syntax.AttributeTerm path source memberReference ->
      resolveAttributeTerm scope path source memberReference

-- | Resolve a value term when only the node is needed.
valueOnly
  :: TermScope
  -> Syntax.ValueTerm availability
  -> Resolve (Resolved.ValueTerm availability)
valueOnly scope term = fst (resolveValueTerm scope term)

-- | The @Enum@ term: the enum reference, then — only when the enum is
-- unique and known — its value against that enum's own values.
resolveEnumTerm
  :: Indexes
  -> SourcePath
  -> Sourced Text
  -> Sourced Text
  -> Resolve (Resolved.ValueTerm availability)
resolveEnumTerm indexes path (Sourced enumPath enumName) (Sourced valuePath valueName) =
  case lookupName (enumIndex indexes) enumName of
    NameMissing -> refuseAt enumPath ("unknown enum " <> quoted enumName)
    NameAmbiguous -> suppressed
    NameFound entry ->
      case Map.lookup valueName (enumEntryValues entry) of
        Nothing ->
          refuseAt
            valuePath
            ( "unknown value "
                <> quoted valueName
                <> " in enum "
                <> quoted enumName
            )
        Just valueId ->
          pure
            ( Resolved.EnumTerm
                path
                (Resolved.Ref enumPath (enumEntryId entry))
                (Resolved.Ref valuePath valueId)
            )

resolveArgumentTerm
  :: TermScope
  -> SourcePath
  -> Sourced Text
  -> (Resolve (Resolved.ValueTerm availability), Denotation)
resolveArgumentTerm scope path (Sourced namePath parameterName) =
  case scopeParameters scope of
    Nothing -> (suppressed, DenotesUnknown)
    Just entry ->
      case lookupName (actionEntryParameters entry) parameterName of
        NameMissing ->
          ( refuseAt
              namePath
              ( "unknown parameter "
                  <> quoted parameterName
                  <> " in action "
                  <> quoted (actionEntryName entry)
              )
          , DenotesUnknown
          )
        NameAmbiguous -> (suppressed, DenotesUnknown)
        NameFound (ParameterEntry parameterId parameterType) ->
          ( pure (Resolved.ArgumentTerm path (Resolved.Ref namePath parameterId))
          , parameterTypeDenotation (scopeIndexes scope) parameterType
          )

-- | The @Actor@ term denotes the distinguished @User@ entity — the
-- resolver's one designation ('userDesignation'), the very identity
-- the resolved model records ('resolveDistinguishedUser').  A
-- duplicated @User@ suppresses dependent uses (the duplicate is
-- reported at its declaration); a missing @User@ is impossible after
-- the decoder's check, and suppression keeps the resolver total —
-- the completeness net in 'resolveCoreDocument' classifies such an
-- outcome as internal.
resolveActorTerm
  :: Indexes -> SourcePath -> (Resolve (Resolved.ValueTerm 'Syntax.ActorAvailable), Denotation)
resolveActorTerm indexes path =
  case userDesignation indexes of
    NameFound entry ->
      (pure (Resolved.ActorTerm path (entityEntryId entry)), DenotesEntity entry)
    NameAmbiguous -> (suppressed, DenotesUnknown)
    NameMissing -> (suppressed, DenotesUnknown)

-- | The resolved model's record of the resolver's designation of the
-- distinguished @User@ entity ('Resolved.modelUserEntity'): the
-- identity every @Actor@ term denotes, read from the same
-- 'userDesignation' as 'resolveActorTerm'.  A duplicated @User@ is
-- reported at its declaration sites and suppressed here; a missing
-- one is impossible after the decoder's check, and suppression keeps
-- the resolver total.
resolveDistinguishedUser :: Indexes -> Resolve Resolved.EntityId
resolveDistinguishedUser indexes =
  case userDesignation indexes of
    NameFound entry -> pure (entityEntryId entry)
    NameAmbiguous -> suppressed
    NameMissing -> suppressed

-- | Resolve an @Attribute@ projection: its source, then its member
-- against the namespace selected by the source's denotation.
resolveAttributeTerm
  :: TermScope
  -> SourcePath
  -> Syntax.ValueTerm availability
  -> Sourced Text
  -> (Resolve (Resolved.ValueTerm availability), Denotation)
resolveAttributeTerm scope path source (Sourced attributeSitePath attributeName) =
  case sourceDenotation of
    DenotesUnknown -> (sourceResolve *> suppressed, DenotesUnknown)
    DenotesNonEntity ->
      ( sourceResolve
          *> refuseAt
            attributeSitePath
            ( "cannot select an attribute namespace for "
                <> quoted attributeName
                <> ": the source term does not denote an entity reference"
            )
      , DenotesUnknown
      )
    DenotesEntity entry ->
      case lookupName (entityEntryAttributes entry) attributeName of
        NameMissing ->
          ( sourceResolve
              *> refuseAt
                attributeSitePath
                ( "unknown attribute "
                    <> quoted attributeName
                    <> " in entity "
                    <> quoted (entityEntryName entry)
                )
          , DenotesUnknown
          )
        NameAmbiguous -> (sourceResolve *> suppressed, DenotesUnknown)
        NameFound (AttributeEntry attributeId attributeType) ->
          ( ( \resolvedSource ->
                Resolved.AttributeTerm
                  path
                  resolvedSource
                  (Resolved.Ref attributeSitePath attributeId)
            )
              <$> sourceResolve
          , attributeTypeDenotation (scopeIndexes scope) attributeType
          )
  where
    (sourceResolve, sourceDenotation) = resolveValueTerm scope source

-- | Resolve a policy term: every value-term constructor plus the
-- lookup, option, comparison, and boolean constructors.  Actor
-- availability is carried by the type index; this walk adds no second
-- interpretation of that distinction.
resolvePolicyTerm
  :: TermScope
  -> Syntax.PolicyTerm availability
  -> Resolve (Resolved.PolicyTerm availability)
resolvePolicyTerm scope term =
  case term of
    Syntax.ValuePolicyTerm valueTerm ->
      Resolved.ValuePolicyTerm <$> valueOnly scope valueTerm
    Syntax.LookupTerm path relationReference endpoints ->
      Resolved.LookupTerm path
        <$> resolveRelationReference (scopeIndexes scope) relationReference
        <*> traverse (valueOnly scope) endpoints
    Syntax.NoneTerm path payloadType ->
      Resolved.NoneTerm path
        <$> resolvePayloadType (scopeIndexes scope) payloadType
    Syntax.SomeTerm path value -> Resolved.SomeTerm path <$> valueOnly scope value
    Syntax.IsSomeTerm path value ->
      Resolved.IsSomeTerm path <$> resolvePolicyTerm scope value
    Syntax.EqualTerm path left right ->
      Resolved.EqualTerm path
        <$> resolvePolicyTerm scope left
        <*> resolvePolicyTerm scope right
    Syntax.LessOrEqualTerm path left right ->
      Resolved.LessOrEqualTerm path
        <$> resolvePolicyTerm scope left
        <*> resolvePolicyTerm scope right
    Syntax.AndTerm path left right ->
      Resolved.AndTerm path
        <$> resolvePolicyTerm scope left
        <*> resolvePolicyTerm scope right
    Syntax.OrTerm path left right ->
      Resolved.OrTerm path
        <$> resolvePolicyTerm scope left
        <*> resolvePolicyTerm scope right
    Syntax.NotTerm path value ->
      Resolved.NotTerm path <$> resolvePolicyTerm scope value

--------------------------------------------------------------------
-- Internal: schema declarations
--------------------------------------------------------------------

resolveEntity
  :: Indexes -> Int -> Syntax.EntityDeclaration -> Resolve Resolved.Entity
resolveEntity indexes position declaration =
  Resolved.Entity
    owner
    (Syntax.entityDeclarationPath declaration)
    (Syntax.entityDeclarationName declaration)
    <$> traverse
      resolveAttribute
      (withPositions (Syntax.entityDeclarationAttributes declaration))
  where
    owner = Resolved.EntityId position
    resolveAttribute (attributePosition, attribute) =
      Resolved.Attribute
        (Resolved.AttributeId owner attributePosition)
        (Syntax.attributeDeclarationPath attribute)
        (Syntax.attributeDeclarationName attribute)
        <$> resolveAttributeType indexes (Syntax.attributeDeclarationType attribute)

-- | Resolve one enum from its own positional entry: the members (and
-- their identifiers) come from the entry unchanged, and the optional
-- order resolves against the same value table enum terms use — even
-- when the enum's name is duplicated, each declaration keeps its own
-- entry.
resolveEnum
  :: EnumEntry -> Syntax.EnumDeclaration -> Resolve Resolved.EnumDefinition
resolveEnum entry declaration =
  Resolved.EnumDefinition
    (enumEntryId entry)
    (Syntax.enumDeclarationPath declaration)
    (Syntax.enumDeclarationName declaration)
    (enumEntryMembers entry)
    <$> resolvedOrder
  where
    enumName = sourcedValue (Syntax.enumDeclarationName declaration)
    -- Only member existence is checked: whether an order is a
    -- complete permutation of the values remains a static-typing
    -- check.
    resolvedOrder =
      case Syntax.enumDeclarationOrder declaration of
        Nothing -> pure Nothing
        Just orderMembers -> Just <$> traverse resolveOrderMember orderMembers
    resolveOrderMember (Sourced orderMemberPath memberName) =
      case Map.lookup memberName (enumEntryValues entry) of
        Just valueId -> pure (Resolved.Ref orderMemberPath valueId)
        Nothing ->
          refuseAt
            orderMemberPath
            ( "unknown value "
                <> quoted memberName
                <> " in enum "
                <> quoted enumName
            )

resolveRelation
  :: Indexes -> Int -> Syntax.RelationDeclaration -> Resolve Resolved.Relation
resolveRelation indexes position declaration =
  Resolved.Relation
    owner
    (Syntax.relationDeclarationPath declaration)
    (Syntax.relationDeclarationName declaration)
    <$> traverse
      resolveEndpoint
      (withPositionsOneOrTwo (Syntax.relationDeclarationEndpoints declaration))
    <*> resolvePayloadType indexes (Syntax.relationDeclarationPayload declaration)
  where
    owner = Resolved.RelationId position
    resolveEndpoint (endpointPosition, endpoint) =
      Resolved.Endpoint
        (Resolved.EndpointId owner endpointPosition)
        (Syntax.endpointDeclarationPath endpoint)
        (Syntax.endpointDeclarationName endpoint)
        <$> resolveEntityReference indexes (Syntax.endpointDeclarationEntity endpoint)

--------------------------------------------------------------------
-- Internal: actions
--------------------------------------------------------------------

-- | Resolve one action in its own positional parameter environment,
-- so every occurrence of a duplicated action name is checked against
-- its own body.
resolveAction
  :: Indexes -> ActionEntry -> Syntax.ActionDeclaration -> Resolve Resolved.Action
resolveAction indexes entry declaration =
  Resolved.Action
    (actionEntryId entry)
    (Syntax.actionDeclarationPath declaration)
    (Syntax.actionDeclarationName declaration)
    <$> traverse
      resolveParameter
      (withPositions (Syntax.actionDeclarationParameters declaration))
    <*> resolveBody (Syntax.actionDeclarationBody declaration)
  where
    scope = TermScope indexes (Just entry)
    resolveParameter (parameterPosition, parameter) =
      Resolved.Parameter
        (Resolved.ParameterId (actionEntryId entry) parameterPosition)
        (Syntax.parameterDeclarationPath parameter)
        (Syntax.parameterDeclarationName parameter)
        <$> resolveParameterType indexes (Syntax.parameterDeclarationType parameter)
    resolveBody body =
      case body of
        Syntax.AuthenticatedOnlyBody allow shape ->
          Resolved.AuthenticatedOnlyBody
            <$> resolvePolicyTerm scope allow
            <*> resolveShape scope shape
        Syntax.AnyPrincipalBody allow shape ->
          Resolved.AnyPrincipalBody
            <$> ( Resolved.AnyPrincipalAllow
                    <$> resolvePolicyTerm scope (Syntax.anyPrincipalAnonymous allow)
                    <*> resolvePolicyTerm
                      scope
                      (Syntax.anyPrincipalAuthenticated allow)
                )
            <*> resolveShape scope shape

resolveShape
  :: TermScope
  -> Syntax.ActionShape availability
  -> Resolve (Resolved.ActionShape availability)
resolveShape scope shape =
  case shape of
    Syntax.ReadShape effectPath resultPath observed ->
      Resolved.ReadShape effectPath resultPath <$> valueOnly scope observed
    Syntax.CreateShape effect resultPath ->
      Resolved.CreateShape
        <$> resolveCreateEntityEffect scope effect
        <*> pure resultPath
    Syntax.MutationShape effect resultPath ->
      Resolved.MutationShape
        <$> resolveDoneEffect scope effect
        <*> pure resultPath

-- | Resolve a @CreateEntity@ effect.  Only names are resolved:
-- initializer completeness and value typing remain for later stages.
resolveCreateEntityEffect
  :: TermScope
  -> Syntax.CreateEntityEffect availability
  -> Resolve (Resolved.CreateEntityEffect availability)
resolveCreateEntityEffect scope (Syntax.CreateEntityEffect path entityReference initializers) =
  Resolved.CreateEntityEffect path
    <$> entityResolve
    <*> traverse resolveInitializer initializers
  where
    Sourced entitySitePath entityName = entityReference
    entityLookup = lookupName (entityIndex (scopeIndexes scope)) entityName
    entityResolve =
      case entityLookup of
        NameMissing -> refuseAt entitySitePath ("unknown entity " <> quoted entityName)
        NameAmbiguous -> suppressed
        NameFound entry -> pure (Resolved.Ref entitySitePath (entityEntryId entry))
    -- Unknown or duplicated target entity: the root problem is
    -- reported once, and the initializer keys — which cannot be
    -- resolved without a unique target — are suppressed.  The
    -- initializer value terms are still resolved.
    targetEntity =
      case entityLookup of
        NameFound entry -> Just entry
        NameMissing -> Nothing
        NameAmbiguous -> Nothing
    resolveInitializer (Sourced keyPath keyName, valueTerm) =
      Resolved.Initializer <$> keyResolve <*> valueOnly scope valueTerm
      where
        keyResolve =
          case targetEntity of
            Nothing -> suppressed
            Just entry ->
              case lookupName (entityEntryAttributes entry) keyName of
                NameMissing ->
                  refuseAt
                    keyPath
                    ( "unknown attribute "
                        <> quoted keyName
                        <> " in entity "
                        <> quoted (entityEntryName entry)
                    )
                NameAmbiguous -> suppressed
                NameFound (AttributeEntry attributeId _) ->
                  pure (Resolved.Ref keyPath attributeId)

resolveDoneEffect
  :: TermScope
  -> Syntax.DoneEffect availability
  -> Resolve (Resolved.DoneEffect availability)
resolveDoneEffect scope effect =
  case effect of
    Syntax.NoChangeEffect path -> pure (Resolved.NoChangeEffect path)
    Syntax.DeleteEntityEffect path target ->
      Resolved.DeleteEntityEffect path <$> valueOnly scope target
    Syntax.SetRelationEffect path relationReference endpoints payload ->
      Resolved.SetRelationEffect path
        <$> resolveRelationReference (scopeIndexes scope) relationReference
        <*> traverse (valueOnly scope) endpoints
        <*> valueOnly scope payload
    Syntax.RemoveRelationEffect path relationReference endpoints ->
      Resolved.RemoveRelationEffect path
        <$> resolveRelationReference (scopeIndexes scope) relationReference
        <*> traverse (valueOnly scope) endpoints

--------------------------------------------------------------------
-- Internal: guarantees
--------------------------------------------------------------------

resolveGuarantee :: Indexes -> Syntax.Guarantee -> Resolve Resolved.Guarantee
resolveGuarantee indexes guarantee =
  case guarantee of
    Syntax.AuthenticatedMutationGuarantee path ->
      -- No declaration-name reference beyond the structural target
      -- selector.
      pure (Resolved.AuthenticatedMutationGuarantee path)
    Syntax.TenantIsolationGuarantee path access cases ->
      Resolved.TenantIsolationGuarantee path
        <$> resolveTenantIsolationAccess indexes access
        <*> traverse (resolveTenantIsolationCase indexes) cases
    Syntax.NoSelfPrivilegeEscalationGuarantee path authority cases ->
      Resolved.NoSelfPrivilegeEscalationGuarantee path
        <$> resolveAuthority indexes authority
        <*> traverse (resolveEscalationCase indexes) cases

-- | Resolve the @TenantIsolation@ structural access relation.  An
-- unknown or duplicated access relation is reported once (or at its
-- declaration sites); its endpoint names cannot be resolved without a
-- unique relation and are suppressed.  Once the relation resolves,
-- each endpoint name resolves in that relation's own endpoint
-- namespace — endpoints are relation-owned members, never global
-- names — with unknown and ambiguous names diagnosed exactly like
-- the authority endpoints below.
resolveTenantIsolationAccess
  :: Indexes
  -> Syntax.TenantIsolationAccess
  -> Resolve Resolved.TenantIsolationAccess
resolveTenantIsolationAccess indexes access =
  Resolved.TenantIsolationAccess
    (Syntax.tenantIsolationAccessPath access)
    <$> relationResolve
    <*> resolveEndpoint (Syntax.tenantIsolationAccessSubjectEndpoint access)
    <*> resolveEndpoint (Syntax.tenantIsolationAccessTenantEndpoint access)
  where
    Sourced relationSitePath relationName =
      Syntax.tenantIsolationAccessRelation access
    relationLookup = lookupName (relationIndex indexes) relationName
    relationResolve =
      case relationLookup of
        NameMissing ->
          refuseAt relationSitePath ("unknown relation " <> quoted relationName)
        NameAmbiguous -> suppressed
        NameFound (RelationEntry relationId _) ->
          pure (Resolved.Ref relationSitePath relationId)
    endpointNamespace =
      case relationLookup of
        NameFound (RelationEntry _ endpoints) -> Just endpoints
        NameMissing -> Nothing
        NameAmbiguous -> Nothing
    resolveEndpoint (Sourced endpointSitePath endpointName) =
      case endpointNamespace of
        Nothing -> suppressed
        Just endpoints ->
          case lookupName endpoints endpointName of
            NameMissing ->
              refuseAt
                endpointSitePath
                ( "unknown endpoint "
                    <> quoted endpointName
                    <> " in relation "
                    <> quoted relationName
                )
            NameAmbiguous -> suppressed
            NameFound endpointId ->
              pure (Resolved.Ref endpointSitePath endpointId)

resolveTenantIsolationCase
  :: Indexes -> Syntax.TenantIsolationCase -> Resolve Resolved.TenantIsolationCase
resolveTenantIsolationCase indexes tenantCase =
  Resolved.TenantIsolationCase
    (Syntax.tenantIsolationCasePath tenantCase)
    <$> actionResolve
    <*> valueOnly scope (Syntax.tenantIsolationCaseTenant tenantCase)
    <*> resolvePolicyTerm scope (Syntax.tenantIsolationCaseProtected tenantCase)
  where
    (actionResolve, scope) =
      caseActionScope indexes (Syntax.tenantIsolationCaseAction tenantCase)

resolveEscalationCase
  :: Indexes -> Syntax.EscalationCase -> Resolve Resolved.EscalationCase
resolveEscalationCase indexes escalationCase =
  Resolved.EscalationCase
    (Syntax.escalationCasePath escalationCase)
    <$> actionResolve
    <*> traverse (valueOnly scope) (Syntax.escalationCaseScope escalationCase)
  where
    (actionResolve, scope) =
      caseActionScope indexes (Syntax.escalationCaseAction escalationCase)

-- | Resolve a guarantee case's @action@ reference and produce the
-- term scope its terms are resolved in.  An unknown action is
-- reported once at the reference; an unknown or duplicated action
-- yields a suppressed parameter environment, so the case's terms
-- produce no dependent parameter errors.
caseActionScope
  :: Indexes -> Sourced Text -> (Resolve (Resolved.Ref Resolved.ActionId), TermScope)
caseActionScope indexes (Sourced path name) =
  case lookupName (actionIndex indexes) name of
    NameMissing ->
      ( refuseAt path ("unknown action " <> quoted name)
      , TermScope indexes Nothing
      )
    NameAmbiguous -> (suppressed, TermScope indexes Nothing)
    NameFound entry ->
      ( pure (Resolved.Ref path (actionEntryId entry))
      , TermScope indexes (Just entry)
      )

-- | Resolve the @NoSelfPrivilegeEscalation@ authority.  An unknown or
-- duplicated authority relation is reported once (or at its
-- declaration sites); its endpoint names cannot be resolved and are
-- suppressed.  The payload-order enum is independent.
resolveAuthority :: Indexes -> Syntax.Authority -> Resolve Resolved.Authority
resolveAuthority indexes authority =
  Resolved.Authority
    (Syntax.authorityPath authority)
    <$> relationResolve
    <*> resolveEndpoint (Syntax.authoritySubjectEndpoint authority)
    <*> traverse resolveEndpoint (Syntax.authorityScopeEndpoint authority)
    <*> pure (Syntax.authorityAbsenceLevel authority)
    <*> resolveEnumReference indexes (Syntax.authorityPayloadOrder authority)
  where
    Sourced relationSitePath relationName = Syntax.authorityRelation authority
    relationLookup = lookupName (relationIndex indexes) relationName
    relationResolve =
      case relationLookup of
        NameMissing ->
          refuseAt relationSitePath ("unknown relation " <> quoted relationName)
        NameAmbiguous -> suppressed
        NameFound (RelationEntry relationId _) ->
          pure (Resolved.Ref relationSitePath relationId)
    endpointNamespace =
      case relationLookup of
        NameFound (RelationEntry _ endpoints) -> Just endpoints
        NameMissing -> Nothing
        NameAmbiguous -> Nothing
    resolveEndpoint (Sourced endpointSitePath endpointName) =
      case endpointNamespace of
        Nothing -> suppressed
        Just endpoints ->
          case lookupName endpoints endpointName of
            NameMissing ->
              refuseAt
                endpointSitePath
                ( "unknown endpoint "
                    <> quoted endpointName
                    <> " in relation "
                    <> quoted relationName
                )
            NameAmbiguous -> suppressed
            NameFound endpointId ->
              pure (Resolved.Ref endpointSitePath endpointId)

--------------------------------------------------------------------
-- Internal: the document
--------------------------------------------------------------------

-- | Resolve a decoded document: build every namespace (reporting all
-- duplicates), record the distinguished @User@ designation, then
-- resolve every declaration, action, and guarantee into the
-- identifier-based model.  Violations aggregate across the whole
-- document; the model exists only when every part resolved.
resolveDocument :: Syntax.Document -> Resolve Resolved.Model
resolveDocument document =
  reporting duplicateReports
    *> ( Resolved.Model (Syntax.documentName document)
           <$> resolveDistinguishedUser indexes
           <*> traverse
             (uncurry (resolveEntity indexes))
             (withPositions (Syntax.documentEntities document))
           <*> traverse
             (uncurry resolveEnum)
             (zip positionalEnums (Syntax.documentEnums document))
           <*> traverse
             (uncurry (resolveRelation indexes))
             (withPositions (Syntax.documentRelations document))
           <*> traverse
             (uncurry (resolveAction indexes))
             (zip positionalActions (Syntax.documentActions document))
           <*> traverse
             (resolveGuarantee indexes)
             (Syntax.documentGuarantees document)
       )
  where
    (duplicateReports, indexes, positionalEnums, positionalActions) =
      buildIndexes document
