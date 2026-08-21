{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | __Internal module — never expose.__
--
-- The explicit typed normalized Core v0 representation: the payload
-- of a @'Mithril.Core.Validation.CoreDocument' 'Normalized'@, produced
-- only by the normalizer ("Mithril.Core.Internal.Normalize", behind
-- "Mithril.Core.Normalization") from a well-typed document, and the
-- one intended input of the contract renderer (its first implemented
-- consumer, "Mithril.Core.Internal.Contract" behind
-- "Mithril.Core.Contract"), the future Agda backend, and the future
-- target emitters.  It is a distinct model from the resolved
-- representation ("Mithril.Core.Internal.Resolved") — not the resolved
-- 'Mithril.Core.Internal.Resolved.Model' under another stage tag —
-- although it deliberately shares the resolved leaf vocabulary:
-- namespace-specific identifiers, 'Ref' reference sites, source
-- paths, the declared attribute, parameter, and payload type
-- families, and the actor-availability index.
--
-- == What normalization adds to the resolved model
--
-- * /Types on every term./  Every 'ValueTerm' and 'PolicyTerm' node
--   carries the static type the typechecker determined for it
--   ("Mithril.Core.Internal.StaticType"), so no later backend ever
--   reruns type inference.  The declared attribute, parameter, and
--   payload type families are the resolved declaration nodes
--   themselves (re-exported here), and 'attributeStaticType',
--   'parameterStaticType', and 'payloadStaticType' — the one
--   statement of each projection into the type vocabulary, defined in
--   "Mithril.Core.Internal.StaticType" and consumed by the
--   typechecker's judgment as well — are re-exported alongside them,
--   so backends never reinterpret a declared family.
-- * /Materialized enum ranks./  A declared enum order — typechecked
--   to be a complete permutation of the enum's values — becomes an
--   explicit 'EnumOrder': every value with its 0-based rank, in
--   ascending rank order exactly as authored.  Ordered comparisons
--   name their ranking through 'OrderedType', so a backend reads
--   ranks instead of re-deriving orderedness.
-- * /Explicit endpoint bindings./  The endpoint terms of lookups and
--   relation effects are paired one-to-one with the declared
--   endpoints they bind ('EndpointBinding'), so the typechecked
--   arity and per-position entity compatibility is present in the
--   structure instead of being an implicit positional convention.
-- * /Initializers in declaration order./  A @CreateEntity@ effect
--   lists exactly one typed initializer per attribute of its target
--   entity, in the target entity's attribute declaration order (the
--   resolved model lists the name-keyed initializers in ascending
--   key order; see the decoder note there).
-- * /Explicit guarantee structure./  Guarantee case terms are typed
--   in their action's environment, and a @NoSelfPrivilegeEscalation@
--   case's zero-or-one scope term is paired with the authority's
--   scope endpoint ('ScopeBinding').
--
-- Declaration names and every source path survive as
-- diagnostic/rendering metadata only: resolved linkage and equality
-- go through the identifiers, exactly as in the resolved model, and
-- no reference field holds a name for later stages to look up again.
-- Identifiers, declaration order, and term structure are preserved
-- unchanged from the resolved model (the initializer reordering above
-- is the one ordering change).
--
-- == What normalization is not
--
-- Normalization is deterministic /structural/ canonicalization of one
-- authored document.  It performs no boolean simplification, no
-- constant folding, no operand sorting, no policy evaluation, no
-- proof checking, and no semantic optimization: an authored
-- @And(true, true)@ normalizes to an @And@ over two @Bool@ literals,
-- and the operands of every binary constructor keep their authored
-- order.  Consequently two differently authored documents are /not/
-- claimed to normalize to equal models even when they are
-- semantically or alpha-equivalent — equality of normalized models is
-- only guaranteed to be reflexive across repeated runs over one
-- authored document.  A value of this model attests nothing beyond
-- what the pipeline stages established: it is well-typed normalized
-- structure, still unverified — no policy is evaluated, no guarantee
-- is established, and no security property holds because of it.
module Mithril.Core.Internal.Normalized
  ( -- * The normalized model
    Model (..)
  , Entity (..)
  , Attribute (..)
  , AttributeType (..)
  , attributeStaticType
  , EnumDefinition (..)
  , EnumMember (..)
  , EnumOrder (..)
  , RankedValue (..)
  , enumOrderRank
  , Relation (..)
  , Endpoint (..)
  , PayloadType (..)
  , payloadStaticType

    -- * Actions
  , Action (..)
  , Parameter (..)
  , ParameterType (..)
  , parameterStaticType
  , ActionBody (..)
  , AnyPrincipalAllow (..)
  , ActionShape (..)
  , CreateEntityEffect (..)
  , Initializer (..)
  , DoneEffect (..)

    -- * Terms
  , ValueTerm (..)
  , ValueNode (..)
  , PolicyTerm (..)
  , PolicyNode (..)
  , OrderedType (..)
  , EndpointBinding (..)

    -- * Guarantees
  , Guarantee (..)
  , TenantIsolationCase (..)
  , Authority (..)
  , EscalationCase (..)
  , ScopeBinding (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)

import Mithril.Core.Internal.Resolved
  ( ActionId
  , AttributeId
  , AttributeType (..)
  , EndpointId
  , EntityId
  , EnumId
  , EnumValueId
  , ParameterId
  , ParameterType (..)
  , PayloadType (..)
  , Ref (..)
  , RelationId
  )
import Mithril.Core.Internal.SourcePath (SourcePath, Sourced)
import Mithril.Core.Internal.StaticType
  ( OrderedType (..)
  , PolicyType
  , ValueType
  , attributeStaticType
  , parameterStaticType
  , payloadStaticType
  )
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel
  , ActorAvailability (..)
  , OneOrTwo
  )

--------------------------------------------------------------------
-- The normalized model
--------------------------------------------------------------------

-- | A typed normalized Core v0 model.  Declaration lists preserve
-- authored order, and list positions agree with the corresponding
-- identifiers exactly as in the resolved model: the entity with
-- @'EntityId' i@ is at position @i@ of 'modelEntities', and likewise
-- for enums, relations, actions, and each owner-local list.
--
-- Every model type has structural equality ('Eq') over exactly this
-- content — identifiers, types, ranks, paths, and name metadata —
-- which is what the package's white-box determinism test compares
-- across independent pipeline runs.
data Model = Model
  { modelName :: Sourced Text
  , modelEntities :: [Entity]
  , modelEnums :: [EnumDefinition]
  , modelRelations :: [Relation]
  , modelActions :: [Action]
  , modelGuarantees :: [Guarantee]
  }
  deriving (Eq)

-- | A normalized entity declaration.
data Entity = Entity
  { entityId :: EntityId
  , entityPath :: SourcePath
  , entityName :: Sourced Text
  , entityAttributes :: [Attribute]
  }
  deriving (Eq)

-- | A normalized attribute declaration.
data Attribute = Attribute
  { attributeId :: AttributeId
  , attributePath :: SourcePath
  , attributeName :: Sourced Text
  , attributeType :: AttributeType
  }
  deriving (Eq)

-- The declared attribute type family — exactly @Bool@, @Enum@, or
-- @EntityRef@ (no @Unit@), with the authored type-node and reference
-- locations retained — is the resolved declaration node itself,
-- re-exported from "Mithril.Core.Internal.Resolved", and
-- 'attributeStaticType' is the one shared projection into the
-- term-type vocabulary, re-exported from
-- "Mithril.Core.Internal.StaticType" — the same definition the
-- typechecker's judgment consumes, so backends never reinterpret the
-- declared family themselves.

-- | A normalized enum declaration.  When the enum declares an order,
-- it is carried as a materialized complete ranking ('EnumOrder');
-- an enum without one has no ranks and cannot appear in an
-- 'OrderedType'.
data EnumDefinition = EnumDefinition
  { enumDefinitionId :: EnumId
  , enumDefinitionPath :: SourcePath
  , enumDefinitionName :: Sourced Text
  , enumDefinitionValues :: NonEmpty EnumMember
  , enumDefinitionOrder :: Maybe EnumOrder
  }
  deriving (Eq)

-- | One declared enum value, in declaration order.
data EnumMember = EnumMember
  { enumMemberId :: EnumValueId
  , enumMemberName :: Sourced Text
  }
  deriving (Eq)

-- | A materialized declared enum order: every value of the enum with
-- its rank, in ascending rank order exactly as authored (rank 0 is
-- the bottom-most authored member).  The normalizer only constructs
-- complete permutations — every value of the enum appears exactly
-- once — so ordered comparisons can rank any value of the enum
-- directly.  Absence of a relation payload ranks below rank 0 at the
-- optional level; it is never a member of this ranking.
newtype EnumOrder = EnumOrder
  { enumOrderRanking :: NonEmpty RankedValue
  }
  deriving (Eq)

-- | One ranked enum value: its 0-based rank — always its position in
-- 'enumOrderRanking', materialized so backends consume it directly —
-- and the resolved value reference with the authored order-member
-- location.
data RankedValue = RankedValue
  { rankedValueRank :: Int
  , rankedValueMember :: Ref EnumValueId
  }
  deriving (Eq)

-- | The rank of an enum value inside a materialized order, when the
-- value belongs to the ranked enum.  'Nothing' means the value is not
-- part of this ranking (a foreign enum's value); every value of the
-- ranked enum itself is present by construction.
enumOrderRank :: EnumOrder -> EnumValueId -> Maybe Int
enumOrderRank order valueId =
  case
    [ rankedValueRank ranked
    | ranked <- NonEmpty.toList (enumOrderRanking order)
    , refTarget (rankedValueMember ranked) == valueId
    ]
  of
    rank : _ -> Just rank
    [] -> Nothing

-- | A normalized relation declaration.
data Relation = Relation
  { relationId :: RelationId
  , relationPath :: SourcePath
  , relationName :: Sourced Text
  , relationEndpoints :: OneOrTwo Endpoint
  , relationPayload :: PayloadType
  }
  deriving (Eq)

-- | A normalized endpoint declaration.
data Endpoint = Endpoint
  { endpointId :: EndpointId
  , endpointPath :: SourcePath
  , endpointName :: Sourced Text
  , endpointEntity :: Ref EntityId
  }
  deriving (Eq)

-- The declared relation payload type family — exactly @Unit@ or
-- @Enum@ — and its 'payloadStaticType' projection are likewise
-- re-exported shared definitions; see the attribute family above.

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

-- | A normalized action declaration.  Its parameter list is the
-- typed environment every term of the action (and of guarantee cases
-- naming the action) was checked in; each 'ArgumentNode' inside
-- carries its parameter's determined type on the term itself, so the
-- environment's typing cannot be forgotten at a use site.
data Action = Action
  { actionId :: ActionId
  , actionPath :: SourcePath
  , actionName :: Sourced Text
  , actionParameters :: [Parameter]
  , actionBody :: ActionBody
  }
  deriving (Eq)

-- | A normalized parameter declaration.
data Parameter = Parameter
  { parameterId :: ParameterId
  , parameterPath :: SourcePath
  , parameterName :: Sourced Text
  , parameterType :: ParameterType
  }
  deriving (Eq)

-- The declared parameter type family — exactly @Bool@, @Unit@,
-- @Enum@, or @EntityRef@ — and its 'parameterStaticType' projection
-- are likewise re-exported shared definitions; see the attribute
-- family above.

-- | The two principal modes with their explicit branches.
-- @AuthenticatedOnly@: one @Bool@-typed allow policy with the actor
-- available throughout.  @AnyPrincipal@: the explicit
-- anonymous\/authenticated allow pair, with the effect and result
-- constrained to the actor-free families by the type index — an
-- @AnyPrincipal@ action whose effect could mention the actor is
-- unrepresentable, exactly as in the resolved model.
data ActionBody
  = AuthenticatedOnlyBody
      (PolicyTerm 'ActorAvailable)
      (ActionShape 'ActorAvailable)
  | AnyPrincipalBody AnyPrincipalAllow (ActionShape 'ActorFree)
  deriving (Eq)

-- | The explicit @AnyPrincipal@ allow branches.  Both are typed at
-- @Bool@.
data AnyPrincipalAllow = AnyPrincipalAllow
  { anyPrincipalAnonymous :: PolicyTerm 'ActorFree
  , anyPrincipalAuthenticated :: PolicyTerm 'ActorAvailable
  }
  deriving (Eq)

-- | The structurally permitted classification\/effect\/result
-- combinations, one constructor each — the action's classification is
-- encoded by the shape, never a separate field that could disagree.
data ActionShape (availability :: ActorAvailability)
  = -- | Classification @Read@: a @NoChange@ effect (first path) and
    -- an @Observe@ result (second path) observing the given
    -- entity-reference-typed term.
    ReadShape SourcePath SourcePath (ValueTerm availability)
  | -- | Classification @Mutation@ with a @CreateEntity@ effect and a
    -- @Created@ result (the path).
    CreateShape (CreateEntityEffect availability) SourcePath
  | -- | Classification @Mutation@ with one of the four @Done@-result
    -- effects and a @Done@ result (the path).
    MutationShape (DoneEffect availability) SourcePath

deriving instance Eq (ActionShape availability)

-- | A normalized @CreateEntity@ effect: exactly one typed
-- initializer per attribute of the target entity, in the target
-- entity's attribute declaration order.  Completeness was
-- typechecked; the normalizer refuses (as an internal error) any
-- model where the one-to-one correspondence does not hold.
data CreateEntityEffect (availability :: ActorAvailability) =
  CreateEntityEffect
    { createEntityEffectPath :: SourcePath
    , createEntityEffectEntity :: Ref EntityId
    , createEntityEffectInitializers :: [Initializer availability]
    }

deriving instance Eq (CreateEntityEffect availability)

-- | One normalized initializer: the attribute it initializes (the
-- reference keeps the authored key location) and the initializing
-- term, typed at the attribute's declared type.
data Initializer (availability :: ActorAvailability) = Initializer
  { initializerKey :: Ref AttributeId
  , initializerValue :: ValueTerm availability
  }

deriving instance Eq (Initializer availability)

-- | The four effects whose actions have a @Done@ result.  Relation
-- effects bind their endpoint terms explicitly; a @DeleteEntity@
-- target is typed at an entity reference; a @SetRelation@ payload is
-- typed at the relation's payload type.
data DoneEffect (availability :: ActorAvailability)
  = NoChangeEffect SourcePath
  | DeleteEntityEffect SourcePath (ValueTerm availability)
  | SetRelationEffect
      SourcePath
      (Ref RelationId)
      (OneOrTwo (EndpointBinding availability))
      (ValueTerm availability)
  | RemoveRelationEffect
      SourcePath
      (Ref RelationId)
      (OneOrTwo (EndpointBinding availability))

deriving instance Eq (DoneEffect availability)

--------------------------------------------------------------------
-- Terms
--------------------------------------------------------------------

-- | A normalized value term: its authored location, the static value
-- type the typechecker determined for it, and the constructor node.
-- The type is carried on every node — including nodes whose type is
-- syntactically evident — so a backend reads one field instead of
-- re-implementing any inference rule.
data ValueTerm (availability :: ActorAvailability) = ValueTerm
  { valueTermPath :: SourcePath
  , valueTermType :: ValueType
  , valueTermNode :: ValueNode availability
  }

deriving instance Eq (ValueTerm availability)

-- | Normalized value-term constructors.  'ActorNode' inhabits only
-- @'ActorAvailable'@ trees and carries the identifier of the
-- distinguished @User@ entity it denotes.
data ValueNode (availability :: ActorAvailability) where
  BoolNode :: Bool -> ValueNode availability
  UnitNode :: ValueNode availability
  -- | An enum value: the resolved enum reference and the resolved
  -- value reference (whose identifier also encodes the owning enum).
  EnumNode :: Ref EnumId -> Ref EnumValueId -> ValueNode availability
  -- | A reference to a parameter of the environment's action; the
  -- surrounding term's type is the parameter's declared type.
  ArgumentNode :: Ref ParameterId -> ValueNode availability
  -- | The implicit authenticated principal, resolved to the
  -- distinguished @User@ entity.
  ActorNode :: EntityId -> ValueNode 'ActorAvailable
  -- | An attribute projection: the typed source term and the
  -- projected attribute; the surrounding term's type is the
  -- attribute's declared type.
  AttributeNode ::
    ValueTerm availability ->
    Ref AttributeId ->
    ValueNode availability

deriving instance Eq (ValueNode availability)

-- | A normalized policy term: authored location, determined policy
-- type, constructor node.  See 'ValueTerm'.
data PolicyTerm (availability :: ActorAvailability) = PolicyTerm
  { policyTermPath :: SourcePath
  , policyTermType :: PolicyType
  , policyTermNode :: PolicyNode availability
  }

deriving instance Eq (PolicyTerm availability)

-- | Normalized policy-term constructors.  Comparison and boolean
-- constructors have type @Bool@; their operands carry their own
-- (typechecked-compatible) types, and a @LessOrEqual@ additionally
-- names its ordered reading explicitly ('OrderedType').
data PolicyNode (availability :: ActorAvailability)
  = ValuePolicyNode (ValueTerm availability)
  | -- | A relation lookup, its endpoint terms bound to the declared
    -- endpoints; the term's type is @Optional P@ for the relation's
    -- payload type @P@.
    LookupNode (Ref RelationId) (OneOrTwo (EndpointBinding availability))
  | -- | Absence of a relation payload, keeping the authored payload
    -- type node; the term's type is the corresponding optional type.
    NoneNode PayloadType
  | SomeNode (ValueTerm availability)
  | IsSomeNode (PolicyTerm availability)
  | EqualNode (PolicyTerm availability) (PolicyTerm availability)
  | LessOrEqualNode
      OrderedType
      (PolicyTerm availability)
      (PolicyTerm availability)
  | AndNode (PolicyTerm availability) (PolicyTerm availability)
  | OrNode (PolicyTerm availability) (PolicyTerm availability)
  | NotNode (PolicyTerm availability)

deriving instance Eq (PolicyNode availability)

-- The ordered reading itself ('OrderedType') is the shared
-- definition re-exported from "Mithril.Core.Internal.StaticType": the
-- typechecker's @LessOrEqual@ judgment classifies operands into it,
-- and the normalizer stores exactly that classification here.  The
-- named enum always carries an 'EnumOrder' in the normalized schema,
-- so the ordering a backend must apply is explicit and cannot be
-- re-derived incorrectly.

-- | One endpoint term bound to the declared endpoint it fills.  The
-- binding makes the typechecked correspondence explicit: the term's
-- type is the entity reference type of exactly this endpoint, and a
-- lookup or relation effect carries as many bindings as its relation
-- declares endpoints.
data EndpointBinding (availability :: ActorAvailability) =
  EndpointBinding
    { endpointBindingEndpoint :: EndpointId
    , endpointBindingTerm :: ValueTerm availability
    }

deriving instance Eq (EndpointBinding availability)

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

-- | A normalized guarantee selection — still only a selected proof
-- obligation; normalization establishes nothing about its truth.
data Guarantee
  = AuthenticatedMutationGuarantee SourcePath
  | TenantIsolationGuarantee SourcePath (NonEmpty TenantIsolationCase)
  | NoSelfPrivilegeEscalationGuarantee
      SourcePath
      Authority
      (NonEmpty EscalationCase)
  deriving (Eq)

-- | One normalized @TenantIsolation@ case: its terms are typed in
-- the referenced action's parameter environment — the tenant term at
-- an entity reference (its type names the tenant entity directly),
-- @protected@ and @tenantAccess@ at @Bool@.
data TenantIsolationCase = TenantIsolationCase
  { tenantIsolationCasePath :: SourcePath
  , tenantIsolationCaseAction :: Ref ActionId
  , tenantIsolationCaseTenant :: ValueTerm 'ActorAvailable
  , tenantIsolationCaseProtected :: PolicyTerm 'ActorAvailable
  , tenantIsolationCaseTenantAccess :: PolicyTerm 'ActorAvailable
  }
  deriving (Eq)

-- | The normalized @NoSelfPrivilegeEscalation@ authority.  The
-- typechecked facts a backend consumes: the subject endpoint
-- references the distinguished @User@ entity, subject and scope
-- endpoints are distinct and together cover the relation's
-- endpoints, and 'authorityPayloadOrder' is exactly the relation's
-- payload enum, whose materialized 'EnumOrder' in the normalized
-- schema ranks authority payloads (with an absent tuple at the
-- 'authorityAbsenceLevel' bottom).
data Authority = Authority
  { authorityPath :: SourcePath
  , authorityRelation :: Ref RelationId
  , authoritySubjectEndpoint :: Ref EndpointId
  , authorityScopeEndpoint :: Maybe (Ref EndpointId)
  , authorityAbsenceLevel :: Sourced AbsenceLevel
  , authorityPayloadOrder :: Ref EnumId
  }
  deriving (Eq)

-- | One normalized @NoSelfPrivilegeEscalation@ case.  Its scope
-- corresponds one-to-one with the authority's scope endpoint: absent
-- exactly when the authority names no scope endpoint, and otherwise
-- a 'ScopeBinding' pairing the scope term with that endpoint.
data EscalationCase = EscalationCase
  { escalationCasePath :: SourcePath
  , escalationCaseAction :: Ref ActionId
  , escalationCaseScope :: Maybe ScopeBinding
  }
  deriving (Eq)

-- | A case's scope term bound to the authority's scope endpoint, the
-- term typed (in the case action's environment) at the scope
-- endpoint's entity reference type.
data ScopeBinding = ScopeBinding
  { scopeBindingEndpoint :: EndpointId
  , scopeBindingTerm :: ValueTerm 'ActorAvailable
  }
  deriving (Eq)
