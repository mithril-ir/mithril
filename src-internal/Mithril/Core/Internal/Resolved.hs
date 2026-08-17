{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | __Internal module — never expose.__
--
-- The explicit resolved Core v0 representation: the payload of a
-- @'Mithril.Core.Validation.CoreDocument' 'Resolved'@, the input of
-- the static typechecker ("Mithril.Core.Internal.Typecheck"), and —
-- unchanged, under the @Typed@ stage index — the payload the
-- typechecker's judgment is about.  It mirrors the decoded surface syntax
-- of "Mithril.Core.Internal.Syntax" construct for construct, with one
-- systematic difference: every semantically meaningful name reference
-- is a 'Ref' to a namespace-specific opaque identifier instead of
-- text.  Generic JSON ends before this module: no node holds an
-- Aeson @Value@, a @KeyMap@, a constructor tag, or a textual
-- reference, and no conversion back to JSON exists.
--
-- == Identifiers
--
-- Each namespace has its own identifier type, so mixing them up is a
-- type error, and the owner-local identifiers embed their owner —
-- an attribute of one entity can never be confused with an attribute
-- of another:
--
-- * global: 'EntityId', 'EnumId', 'RelationId', 'ActionId' — the
--   declaration's position in its authored declaration list;
-- * owner-local: 'AttributeId' (entity-owned), 'EnumValueId'
--   (enum-owned), 'EndpointId' (relation-owned), 'ParameterId'
--   (action-owned) — the owner's identifier plus the position in the
--   owner's declaration list.
--
-- Every identifier — the global ones included — is a distinct @data@
-- type, never a @newtype@ over a shared representation: GHC provides
-- no @Coercible@ instance between two identifier namespaces, so even
-- code inside this package that imports these constructors cannot
-- @coerce@ one namespace into another (the in-package non-coercion
-- probes pin exactly that).
--
-- Identifiers are assigned deterministically from authored
-- declaration order, which this model preserves unchanged: nothing is
-- normalized or sorted here (the one exception is the name-keyed
-- @CreateEntity@ initializer map, whose authored member order the
-- JSON parser does not preserve; the decoder lists it in ascending
-- key order).  Declaration names remain in the model as 'Sourced'
-- metadata for future diagnostics and human-readable output, but
-- resolved linkage and equality go through the identifiers; no
-- resolved reference field holds a name for later stages to look up
-- again.
--
-- Every node and reference retains the 'SourcePath' it was decoded
-- from, so the typechecker (and every later stage) can report a
-- problem at the originating JSON location without rereading the raw
-- JSON.
--
-- Every model type has structural equality ('Eq') over exactly this
-- content — identifiers, paths, and name metadata — which is what the
-- package's white-box determinism test compares across independent
-- pipeline runs.
--
-- A value of this model attests names only: declarations unique in
-- their namespaces, every reference resolved in its correct
-- namespace, and the narrow declared-type lookup behind @Attribute@
-- members.  Whether it also satisfies the Core v0 typing judgment is
-- carried by the document's stage index, never by the model value —
-- the typechecker's verdict mints @Typed@ around this same model.
-- Under either index it is unnormalized and unverified, is not typed
-- normalized Core, and supports no security claim.
module Mithril.Core.Internal.Resolved
  ( -- * Identifiers
    EntityId (..)
  , EnumId (..)
  , RelationId (..)
  , ActionId (..)
  , AttributeId (..)
  , EnumValueId (..)
  , EndpointId (..)
  , ParameterId (..)

    -- * Resolved references
  , Ref (..)

    -- * The resolved model
  , Model (..)
  , Entity (..)
  , Attribute (..)
  , AttributeType (..)
  , EnumDefinition (..)
  , EnumMember (..)
  , Relation (..)
  , Endpoint (..)
  , PayloadType (..)

    -- * Actions
  , Action (..)
  , Parameter (..)
  , ParameterType (..)
  , ActionBody (..)
  , AnyPrincipalAllow (..)
  , ActionShape (..)
  , CreateEntityEffect (..)
  , Initializer (..)
  , DoneEffect (..)

    -- * Terms
  , ValueTerm (..)
  , PolicyTerm (..)

    -- * Guarantees
  , Guarantee (..)
  , TenantIsolationCase (..)
  , Authority (..)
  , EscalationCase (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

import Mithril.Core.Internal.SourcePath (SourcePath, Sourced)
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel
  , ActorAvailability (..)
  , OneOrTwo
  )

--------------------------------------------------------------------
-- Identifiers
--------------------------------------------------------------------

-- | A resolved entity: its position in the authored entity list.
-- Deliberately @data@, not @newtype@ (like every identifier here), so
-- no @Coercible@ path exists between identifier namespaces.
data EntityId = EntityId Int
  deriving (Eq, Ord, Show)

-- | A resolved enum: its position in the authored enum list.
data EnumId = EnumId Int
  deriving (Eq, Ord, Show)

-- | A resolved relation: its position in the authored relation list.
data RelationId = RelationId Int
  deriving (Eq, Ord, Show)

-- | A resolved action: its position in the authored action list.
data ActionId = ActionId Int
  deriving (Eq, Ord, Show)

-- | A resolved attribute, owned by its entity.
data AttributeId = AttributeId EntityId Int
  deriving (Eq, Ord, Show)

-- | A resolved enum value, owned by its enum.
data EnumValueId = EnumValueId EnumId Int
  deriving (Eq, Ord, Show)

-- | A resolved endpoint, owned by its relation.
data EndpointId = EndpointId RelationId Int
  deriving (Eq, Ord, Show)

-- | A resolved parameter, owned by its action.
data ParameterId = ParameterId ActionId Int
  deriving (Eq, Ord, Show)

--------------------------------------------------------------------
-- Resolved references
--------------------------------------------------------------------

-- | One resolved reference site: the identifier it resolved to plus
-- the source location of the reference itself, so later stages can
-- diagnose problems at the authored site.
data Ref target = Ref
  { refPath :: SourcePath
  , refTarget :: target
  }
  deriving (Eq, Ord, Show)

--------------------------------------------------------------------
-- The resolved model
--------------------------------------------------------------------

-- | A completely name-resolved Core v0 model, in authored order.
-- List positions agree with the corresponding identifiers: the entity
-- with @'EntityId' i@ is at position @i@ of 'modelEntities', and
-- likewise for enums, relations, actions, and each owner-local list.
data Model = Model
  { modelName :: Sourced Text
  , modelEntities :: [Entity]
  , modelEnums :: [EnumDefinition]
  , modelRelations :: [Relation]
  , modelActions :: [Action]
  , modelGuarantees :: [Guarantee]
  }
  deriving (Eq)

-- | A resolved entity declaration.
data Entity = Entity
  { entityId :: EntityId
  , entityPath :: SourcePath
  , entityName :: Sourced Text
  , entityAttributes :: [Attribute]
  }
  deriving (Eq)

-- | A resolved attribute declaration.
data Attribute = Attribute
  { attributeId :: AttributeId
  , attributePath :: SourcePath
  , attributeName :: Sourced Text
  , attributeType :: AttributeType
  }
  deriving (Eq)

-- | Entity attribute types: exactly @Bool@, @Enum@, or @EntityRef@.
data AttributeType
  = BoolAttributeType SourcePath
  | EnumAttributeType SourcePath (Ref EnumId)
  | EntityRefAttributeType SourcePath (Ref EntityId)
  deriving (Eq)

-- | A resolved enum declaration.  The optional order references the
-- enum's own values by identifier; whether it is a complete
-- permutation is the typechecker's question, not resolution's.
data EnumDefinition = EnumDefinition
  { enumDefinitionId :: EnumId
  , enumDefinitionPath :: SourcePath
  , enumDefinitionName :: Sourced Text
  , enumDefinitionValues :: NonEmpty EnumMember
  , enumDefinitionOrder :: Maybe (NonEmpty (Ref EnumValueId))
  }
  deriving (Eq)

-- | One declared enum value.
data EnumMember = EnumMember
  { enumMemberId :: EnumValueId
  , enumMemberName :: Sourced Text
  }
  deriving (Eq)

-- | A resolved relation declaration.
data Relation = Relation
  { relationId :: RelationId
  , relationPath :: SourcePath
  , relationName :: Sourced Text
  , relationEndpoints :: OneOrTwo Endpoint
  , relationPayload :: PayloadType
  }
  deriving (Eq)

-- | A resolved endpoint declaration.
data Endpoint = Endpoint
  { endpointId :: EndpointId
  , endpointPath :: SourcePath
  , endpointName :: Sourced Text
  , endpointEntity :: Ref EntityId
  }
  deriving (Eq)

-- | Relation payload types: exactly @Unit@ or @Enum@.
data PayloadType
  = UnitPayloadType SourcePath
  | EnumPayloadType SourcePath (Ref EnumId)
  deriving (Eq)

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

-- | A resolved action declaration.
data Action = Action
  { actionId :: ActionId
  , actionPath :: SourcePath
  , actionName :: Sourced Text
  , actionParameters :: [Parameter]
  , actionBody :: ActionBody
  }
  deriving (Eq)

-- | A resolved parameter declaration.
data Parameter = Parameter
  { parameterId :: ParameterId
  , parameterPath :: SourcePath
  , parameterName :: Sourced Text
  , parameterType :: ParameterType
  }
  deriving (Eq)

-- | Action parameter types: exactly @Bool@, @Unit@, @Enum@, or
-- @EntityRef@.
data ParameterType
  = BoolParameterType SourcePath
  | UnitParameterType SourcePath
  | EnumParameterType SourcePath (Ref EnumId)
  | EntityRefParameterType SourcePath (Ref EntityId)
  deriving (Eq)

-- | The two principal modes with their distinct allow shapes; see
-- 'Mithril.Core.Internal.Syntax.ActionBody'.
data ActionBody
  = AuthenticatedOnlyBody
      (PolicyTerm 'ActorAvailable)
      (ActionShape 'ActorAvailable)
  | AnyPrincipalBody AnyPrincipalAllow (ActionShape 'ActorFree)
  deriving (Eq)

-- | The resolved @AnyPrincipal@ allow pair.
data AnyPrincipalAllow = AnyPrincipalAllow
  { anyPrincipalAnonymous :: PolicyTerm 'ActorFree
  , anyPrincipalAuthenticated :: PolicyTerm 'ActorAvailable
  }
  deriving (Eq)

-- | The structurally permitted classification\/effect\/result
-- combinations; see 'Mithril.Core.Internal.Syntax.ActionShape'.
data ActionShape (availability :: ActorAvailability)
  = ReadShape SourcePath SourcePath (ValueTerm availability)
  | CreateShape (CreateEntityEffect availability) SourcePath
  | MutationShape (DoneEffect availability) SourcePath

deriving instance Eq (ActionShape availability)

-- | A resolved @CreateEntity@ effect: the target entity and the
-- initializers with their keys resolved against that entity's
-- attribute namespace (in ascending key order; see the module
-- header).  Initializer completeness and value typing are the
-- typechecker's questions, not resolution's.
data CreateEntityEffect (availability :: ActorAvailability) =
  CreateEntityEffect
    { createEntityEffectPath :: SourcePath
    , createEntityEffectEntity :: Ref EntityId
    , createEntityEffectInitializers :: [Initializer availability]
    }

deriving instance Eq (CreateEntityEffect availability)

-- | One resolved initializer: the attribute it initializes and the
-- initializing term.
data Initializer (availability :: ActorAvailability) = Initializer
  { initializerKey :: Ref AttributeId
  , initializerValue :: ValueTerm availability
  }

deriving instance Eq (Initializer availability)

-- | The four effects whose actions have a @Done@ result.
data DoneEffect (availability :: ActorAvailability)
  = NoChangeEffect SourcePath
  | DeleteEntityEffect SourcePath (ValueTerm availability)
  | SetRelationEffect
      SourcePath
      (Ref RelationId)
      (OneOrTwo (ValueTerm availability))
      (ValueTerm availability)
  | RemoveRelationEffect
      SourcePath
      (Ref RelationId)
      (OneOrTwo (ValueTerm availability))

deriving instance Eq (DoneEffect availability)

--------------------------------------------------------------------
-- Terms
--------------------------------------------------------------------

-- | Resolved value terms.  'ActorTerm' inhabits only
-- @'ActorAvailable'@ trees and carries the identifier of the
-- distinguished @User@ entity it denotes.
data ValueTerm (availability :: ActorAvailability) where
  BoolTerm :: SourcePath -> Bool -> ValueTerm availability
  UnitTerm :: SourcePath -> ValueTerm availability
  -- | An enum value: the resolved enum reference and the resolved
  -- value reference (whose identifier also encodes the owning enum).
  EnumTerm ::
    SourcePath -> Ref EnumId -> Ref EnumValueId -> ValueTerm availability
  ArgumentTerm :: SourcePath -> Ref ParameterId -> ValueTerm availability
  -- | The implicit authenticated principal, resolved to the
  -- distinguished @User@ entity.
  ActorTerm :: SourcePath -> EntityId -> ValueTerm 'ActorAvailable
  AttributeTerm ::
    SourcePath ->
    ValueTerm availability ->
    Ref AttributeId ->
    ValueTerm availability

deriving instance Eq (ValueTerm availability)

-- | Resolved policy terms.
data PolicyTerm (availability :: ActorAvailability)
  = ValuePolicyTerm (ValueTerm availability)
  | LookupTerm
      SourcePath
      (Ref RelationId)
      (OneOrTwo (ValueTerm availability))
  | NoneTerm SourcePath PayloadType
  | SomeTerm SourcePath (ValueTerm availability)
  | IsSomeTerm SourcePath (PolicyTerm availability)
  | EqualTerm
      SourcePath
      (PolicyTerm availability)
      (PolicyTerm availability)
  | LessOrEqualTerm
      SourcePath
      (PolicyTerm availability)
      (PolicyTerm availability)
  | AndTerm
      SourcePath
      (PolicyTerm availability)
      (PolicyTerm availability)
  | OrTerm
      SourcePath
      (PolicyTerm availability)
      (PolicyTerm availability)
  | NotTerm SourcePath (PolicyTerm availability)

deriving instance Eq (PolicyTerm availability)

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

-- | A resolved guarantee selection — still only a selected proof
-- obligation; nothing about it is verified.
data Guarantee
  = AuthenticatedMutationGuarantee SourcePath
  | TenantIsolationGuarantee SourcePath (NonEmpty TenantIsolationCase)
  | NoSelfPrivilegeEscalationGuarantee
      SourcePath
      Authority
      (NonEmpty EscalationCase)
  deriving (Eq)

-- | One resolved @TenantIsolation@ case.  Its terms are resolved in
-- the referenced action's parameter environment.
data TenantIsolationCase = TenantIsolationCase
  { tenantIsolationCasePath :: SourcePath
  , tenantIsolationCaseAction :: Ref ActionId
  , tenantIsolationCaseTenant :: ValueTerm 'ActorAvailable
  , tenantIsolationCaseProtected :: PolicyTerm 'ActorAvailable
  , tenantIsolationCaseTenantAccess :: PolicyTerm 'ActorAvailable
  }
  deriving (Eq)

-- | The resolved @NoSelfPrivilegeEscalation@ authority: relation,
-- subject endpoint, zero-or-one scope endpoint, absence level, and
-- payload-order enum, all by identifier.  The absence level is the
-- fixed Core v0 constant, kept 'Sourced' so the path of the authored
-- @absenceLevel@ member survives like every other decoded location.
data Authority = Authority
  { authorityPath :: SourcePath
  , authorityRelation :: Ref RelationId
  , authoritySubjectEndpoint :: Ref EndpointId
  , authorityScopeEndpoint :: Maybe (Ref EndpointId)
  , authorityAbsenceLevel :: Sourced AbsenceLevel
  , authorityPayloadOrder :: Ref EnumId
  }
  deriving (Eq)

-- | One resolved @NoSelfPrivilegeEscalation@ case.  Its zero-or-one
-- scope term is resolved in the referenced action's parameter
-- environment.
data EscalationCase = EscalationCase
  { escalationCasePath :: SourcePath
  , escalationCaseAction :: Ref ActionId
  , escalationCaseScope :: Maybe (ValueTerm 'ActorAvailable)
  }
  deriving (Eq)
