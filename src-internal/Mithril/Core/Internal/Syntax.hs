{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The decoded Core v0 surface syntax: an explicit Haskell reading of
-- a structurally valid document, with every construct of
-- @core\/schema.json@ as a constructor, a 'SourcePath' on every node,
-- and /symbolic/ references — the authored names, as 'Sourced'
-- 'Text', not yet resolved to declarations.
--
-- This tree is produced only by "Mithril.Core.Internal.Decode" (the
-- one place that interprets JSON constructor tags and member layout)
-- and consumed only by "Mithril.Core.Resolution" (which builds
-- namespaces over it and resolves every symbolic reference into the
-- identifier-based model of "Mithril.Core.Internal.Resolved").  The
-- decoder, this syntax, and the resolved model must be audited
-- together with every @core\/schema.json@ change: they are the single
-- frontend interpretation of the external grammar, and no second
-- JSON walk may reinterpret it.
--
-- Structurally established facts are encoded in the types rather than
-- rechecked downstream:
--
-- * The 'ActorAvailability' index threads through terms, effects, and
--   results, and the 'ActorTerm' constructor inhabits only
--   @'ActorAvailable'@ trees — an anonymous @AnyPrincipal@ branch,
--   effect, or result containing an @Actor@ is unrepresentable.
-- * 'ActionBody' fixes the two principal modes and their distinct
--   allow shapes; 'ActionShape' fixes the three structurally
--   permitted classification\/effect\/result combinations.
-- * The attribute, parameter, and relation-payload type families are
--   separate types, each with exactly its structurally permitted
--   constructors.
-- * Arrays the schema bounds are precise shapes: 'OneOrTwo' for
--   relation and lookup endpoints, 'Data.List.NonEmpty.NonEmpty' for
--   enum values and guarantee cases, 'Maybe' for the zero-or-one
--   scope endpoint and scope term.
--
-- Nothing here is typed or normalized: the syntax records what was
-- authored, resolution establishes names, and every deeper judgment
-- belongs to the later stages — static typing to
-- "Mithril.Core.Internal.Typecheck" and normalization to
-- "Mithril.Core.Internal.Normalize" (both over the resolved model,
-- never over this symbolic syntax), everything beyond the frontend
-- to stages that do not exist yet.
module Mithril.Core.Internal.Syntax
  ( -- * Actor availability
    ActorAvailability (..)
  , ActorContext (..)

    -- * The distinguished entity
  , distinguishedUserEntity

    -- * Bounded shapes
  , OneOrTwo (..)

    -- * Documents and schema declarations
  , Document (..)
  , EntityDeclaration (..)
  , AttributeDeclaration (..)
  , AttributeType (..)
  , EnumDeclaration (..)
  , RelationDeclaration (..)
  , EndpointDeclaration (..)
  , PayloadType (..)

    -- * Actions
  , ActionDeclaration (..)
  , ParameterDeclaration (..)
  , ParameterType (..)
  , ActionBody (..)
  , AnyPrincipalAllow (..)
  , ActionShape (..)
  , CreateEntityEffect (..)
  , DoneEffect (..)

    -- * Terms
  , ValueTerm (..)
  , PolicyTerm (..)

    -- * Guarantees
  , Guarantee (..)
  , TenantIsolationAccess (..)
  , TenantIsolationCase (..)
  , Authority (..)
  , AbsenceLevel (..)
  , EscalationCase (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

import Mithril.Core.Internal.SourcePath (SourcePath, Sourced)

--------------------------------------------------------------------
-- Actor availability
--------------------------------------------------------------------

-- | Whether the implicit authenticated principal is in scope for a
-- family of terms.  Promoted to a kind and used as the index of
-- 'ValueTerm', 'PolicyTerm', 'ActionShape', and the effect types, so
-- the schema's two structurally distinct term families — the general
-- one and the Actor-free one — are two instantiations of one tree
-- rather than two independently maintained trees.
data ActorAvailability
  = -- | Terms may use the 'ActorTerm' constructor: authenticated-only
    -- actions, the authenticated branch of an @AnyPrincipal@ allow,
    -- and escalation-case scope terms.
    ActorAvailable
  | -- | Terms must not contain an @Actor@ at any depth: the anonymous
    -- branch of an @AnyPrincipal@ allow, every @AnyPrincipal@ effect
    -- and result, and the tenant and protected terms of a
    -- @TenantIsolation@ case (the obligation quantifies over the
    -- principal, so no case term may mention it).  The 'ActorTerm'
    -- constructor does not inhabit this index, so the exclusion is
    -- checked by the type checker, not by a traversal.
    ActorFree

-- | Run-time witness of an 'ActorAvailability' index, used by the
-- decoder to decide whether an @Actor@ constructor tag is admissible
-- in the tree it is building.
data ActorContext (availability :: ActorAvailability) where
  WithActor :: ActorContext 'ActorAvailable
  WithoutActor :: ActorContext 'ActorFree

-- | The name of the distinguished entity the @Actor@ term denotes.
-- Its presence is structurally required by the schema's @contains@
-- clause; the decoder treats its absence as drift, and the resolver
-- resolves every @Actor@ term to it.
distinguishedUserEntity :: Text
distinguishedUserEntity = "User"

--------------------------------------------------------------------
-- Bounded shapes
--------------------------------------------------------------------

-- | Exactly one or two items: the schema's @minItems 1, maxItems 2@
-- bound on relation endpoints and on the endpoint terms of lookup and
-- relation effects.
data OneOrTwo a
  = One a
  | Two a a
  deriving (Eq, Functor, Foldable, Traversable)

--------------------------------------------------------------------
-- Documents and schema declarations
--------------------------------------------------------------------

-- | A decoded Core v0 document.  The @format@ and @formatVersion@
-- members are structural constants of the external grammar and carry
-- no model content, so they are not represented.  Declaration lists
-- preserve authored order.
data Document = Document
  { documentName :: Sourced Text
  , documentEntities :: [EntityDeclaration]
  , documentEnums :: [EnumDeclaration]
  , documentRelations :: [RelationDeclaration]
  , documentActions :: [ActionDeclaration]
  , documentGuarantees :: [Guarantee]
  }

-- | An entity declaration.
data EntityDeclaration = EntityDeclaration
  { entityDeclarationPath :: SourcePath
  , entityDeclarationName :: Sourced Text
  , entityDeclarationAttributes :: [AttributeDeclaration]
  }

-- | An attribute declaration within an entity.
data AttributeDeclaration = AttributeDeclaration
  { attributeDeclarationPath :: SourcePath
  , attributeDeclarationName :: Sourced Text
  , attributeDeclarationType :: AttributeType
  }

-- | Entity attribute types: exactly @Bool@, @Enum@, or @EntityRef@
-- (no @Unit@), as the schema's @attributeType@ family fixes.
data AttributeType
  = BoolAttributeType SourcePath
  | EnumAttributeType SourcePath (Sourced Text)
  | EntityRefAttributeType SourcePath (Sourced Text)

-- | An enum declaration.  The value list is structurally non-empty
-- and its members structurally unique; the optional order is
-- structurally non-empty when present.  Whether an order is a
-- complete permutation of the values is a fact for the typechecker
-- (over the resolved model), not encoded here.
data EnumDeclaration = EnumDeclaration
  { enumDeclarationPath :: SourcePath
  , enumDeclarationName :: Sourced Text
  , enumDeclarationValues :: NonEmpty (Sourced Text)
  , enumDeclarationOrder :: Maybe (NonEmpty (Sourced Text))
  }

-- | A relation declaration.
data RelationDeclaration = RelationDeclaration
  { relationDeclarationPath :: SourcePath
  , relationDeclarationName :: Sourced Text
  , relationDeclarationEndpoints :: OneOrTwo EndpointDeclaration
  , relationDeclarationPayload :: PayloadType
  }

-- | An endpoint declaration within a relation.
data EndpointDeclaration = EndpointDeclaration
  { endpointDeclarationPath :: SourcePath
  , endpointDeclarationName :: Sourced Text
  , endpointDeclarationEntity :: Sourced Text
  }

-- | Relation payload types: exactly @Unit@ or @Enum@.
data PayloadType
  = UnitPayloadType SourcePath
  | EnumPayloadType SourcePath (Sourced Text)

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

-- | An action declaration.
data ActionDeclaration = ActionDeclaration
  { actionDeclarationPath :: SourcePath
  , actionDeclarationName :: Sourced Text
  , actionDeclarationParameters :: [ParameterDeclaration]
  , actionDeclarationBody :: ActionBody
  }

-- | A parameter declaration within an action.
data ParameterDeclaration = ParameterDeclaration
  { parameterDeclarationPath :: SourcePath
  , parameterDeclarationName :: Sourced Text
  , parameterDeclarationType :: ParameterType
  }

-- | Action parameter types: exactly @Bool@, @Unit@, @Enum@, or
-- @EntityRef@.
data ParameterType
  = BoolParameterType SourcePath
  | UnitParameterType SourcePath
  | EnumParameterType SourcePath (Sourced Text)
  | EntityRefParameterType SourcePath (Sourced Text)

-- | The two principal modes with their structurally distinct allow
-- shapes.  @AuthenticatedOnly@: one policy term with the actor
-- available everywhere.  @AnyPrincipal@: an anonymous\/authenticated
-- allow pair whose anonymous branch is actor-free, with the effect
-- and result also constrained to the actor-free families.
data ActionBody
  = AuthenticatedOnlyBody
      (PolicyTerm 'ActorAvailable)
      (ActionShape 'ActorAvailable)
  | AnyPrincipalBody AnyPrincipalAllow (ActionShape 'ActorFree)

-- | The @AnyPrincipal@ allow surface: the anonymous branch is
-- actor-free by type, the authenticated branch may use the actor.
data AnyPrincipalAllow = AnyPrincipalAllow
  { anyPrincipalAnonymous :: PolicyTerm 'ActorFree
  , anyPrincipalAuthenticated :: PolicyTerm 'ActorAvailable
  }

-- | The structurally permitted classification\/effect\/result
-- combinations, one constructor each; every other combination is
-- already rejected by structural validation and is unrepresentable
-- here.  Result descriptors carry no payload beyond the @Observe@
-- term, so the result is represented by its source path (and the
-- observed term for reads).
data ActionShape (availability :: ActorAvailability)
  = -- | Classification @Read@: a @NoChange@ effect (first path) and
    -- an @Observe@ result (second path) observing the given term.
    ReadShape SourcePath SourcePath (ValueTerm availability)
  | -- | Classification @Mutation@ with a @CreateEntity@ effect and a
    -- @Created@ result (the path).
    CreateShape (CreateEntityEffect availability) SourcePath
  | -- | Classification @Mutation@ with one of the four @Done@-result
    -- effects and a @Done@ result (the path).
    MutationShape (DoneEffect availability) SourcePath

-- | A @CreateEntity@ effect: the target entity reference and the
-- name-keyed attribute initializers.  JSON object member order is not
-- semantically meaningful and is not preserved by the JSON parser, so
-- the decoder lists initializers in ascending key order — the one
-- deterministic order available.
data CreateEntityEffect (availability :: ActorAvailability) =
  CreateEntityEffect
    { createEntityEffectPath :: SourcePath
    , createEntityEffectEntity :: Sourced Text
    , createEntityEffectInitializers ::
        [(Sourced Text, ValueTerm availability)]
    }

-- | The four effects whose actions have a @Done@ result.
data DoneEffect (availability :: ActorAvailability)
  = NoChangeEffect SourcePath
  | DeleteEntityEffect SourcePath (ValueTerm availability)
  | SetRelationEffect
      SourcePath
      (Sourced Text)
      (OneOrTwo (ValueTerm availability))
      (ValueTerm availability)
  | RemoveRelationEffect
      SourcePath
      (Sourced Text)
      (OneOrTwo (ValueTerm availability))

--------------------------------------------------------------------
-- Terms
--------------------------------------------------------------------

-- | Value terms — the family allowed as an @Attribute@ source and in
-- every value position.  'ActorTerm' inhabits only
-- @'ActorAvailable'@ trees; everything else is available in both.
data ValueTerm (availability :: ActorAvailability) where
  BoolTerm :: SourcePath -> Bool -> ValueTerm availability
  UnitTerm :: SourcePath -> ValueTerm availability
  -- | An enum value: the enum reference and the value reference.
  EnumTerm ::
    SourcePath -> Sourced Text -> Sourced Text -> ValueTerm availability
  -- | A reference to a parameter of the enclosing action.
  ArgumentTerm :: SourcePath -> Sourced Text -> ValueTerm availability
  -- | The implicit authenticated principal.
  ActorTerm :: SourcePath -> ValueTerm 'ActorAvailable
  -- | An attribute projection: source term and attribute reference.
  AttributeTerm ::
    SourcePath ->
    ValueTerm availability ->
    Sourced Text ->
    ValueTerm availability

-- | Policy terms: every value term plus the lookup, option,
-- comparison, and boolean constructors.
data PolicyTerm (availability :: ActorAvailability)
  = ValuePolicyTerm (ValueTerm availability)
  | LookupTerm
      SourcePath
      (Sourced Text)
      (OneOrTwo (ValueTerm availability))
  | -- | Absence of a relation payload; carries a payload type, never
    -- a term, so it is shared by both term families.
    NoneTerm SourcePath PayloadType
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

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

-- | A selected guarantee — a proof obligation, established by
-- nothing in this stage.  Guarantee case terms are resolved in the
-- referenced action's parameter environment, in the actor
-- availability the schema's term families fix: escalation-case scope
-- terms with the actor available, @TenantIsolation@ case terms
-- actor-free.
data Guarantee
  = -- | @AuthenticatedMutation@ selects every mutation action through
    -- a structurally constant target; it carries no reference beyond
    -- that selector.
    AuthenticatedMutationGuarantee SourcePath
  | TenantIsolationGuarantee
      SourcePath
      TenantIsolationAccess
      (NonEmpty TenantIsolationCase)
  | NoSelfPrivilegeEscalationGuarantee
      SourcePath
      Authority
      (NonEmpty EscalationCase)

-- | The @TenantIsolation@ structural access relation: the relation
-- reference and its two designated endpoints — the subject endpoint
-- (the acting principal's side) and the tenant endpoint (the tenant's
-- side), both member names resolved within that relation by the
-- resolver.  Whether the relation is binary, the endpoints distinct,
-- and the subject endpoint of entity type @User@ are typechecker
-- questions.
data TenantIsolationAccess = TenantIsolationAccess
  { tenantIsolationAccessPath :: SourcePath
  , tenantIsolationAccessRelation :: Sourced Text
  , tenantIsolationAccessSubjectEndpoint :: Sourced Text
  , tenantIsolationAccessTenantEndpoint :: Sourced Text
  }

-- | One @TenantIsolation@ case.  Its tenant and protected terms are
-- structurally actor-free — the schema's actor-free families fix
-- this, and the type index makes an @Actor@ inside them
-- unrepresentable.
data TenantIsolationCase = TenantIsolationCase
  { tenantIsolationCasePath :: SourcePath
  , tenantIsolationCaseAction :: Sourced Text
  , tenantIsolationCaseTenant :: ValueTerm 'ActorFree
  , tenantIsolationCaseProtected :: PolicyTerm 'ActorFree
  }

-- | The @NoSelfPrivilegeEscalation@ authority description: the
-- authority relation, its subject endpoint, the zero-or-one scope
-- endpoint, the absence level, and the enum whose declared order
-- ranks authority payloads.
data Authority = Authority
  { authorityPath :: SourcePath
  , authorityRelation :: Sourced Text
  , authoritySubjectEndpoint :: Sourced Text
  , authorityScopeEndpoint :: Maybe (Sourced Text)
  , authorityAbsenceLevel :: Sourced AbsenceLevel
    -- ^ 'Sourced' like every decoded leaf: the constant keeps the
    -- path of the authored @absenceLevel@ member.
  , authorityPayloadOrder :: Sourced Text
  }

-- | The rank of an absent authority tuple.  Structurally the constant
-- @Bottom@; it is never serialized as an enum value and never becomes
-- an enum reference.
data AbsenceLevel = AbsenceBottom
  deriving (Eq)

-- | One @NoSelfPrivilegeEscalation@ case: the target action and its
-- zero-or-one scope term.
data EscalationCase = EscalationCase
  { escalationCasePath :: SourcePath
  , escalationCaseAction :: Sourced Text
  , escalationCaseScope :: Maybe (ValueTerm 'ActorAvailable)
  }
