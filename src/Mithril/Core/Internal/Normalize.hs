{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Core v0 normalizer: the one pass that turns the explicit
-- resolved model of a /well-typed/ document
-- ("Mithril.Core.Internal.Resolved", under the @Typed@ stage index)
-- into the explicit typed normalized representation
-- ("Mithril.Core.Internal.Normalized").  It consumes only the
-- resolved model — never raw JSON — and it restates no judgment of
-- the earlier stages: every reference it follows is an
-- already-resolved identifier, every static type it stamps onto a
-- normalized term comes from the typechecker's own shared type-query
-- facility ('inferValue' and 'inferPolicy' of
-- "Mithril.Core.Internal.Typecheck"), and every ordered reading it
-- stores comes from the same facility's 'orderedVerdict' — so the
-- Core v0 typing judgment, the declared-type projections, and the
-- ordered classification each have exactly one statement in this
-- package.
--
-- == The normalization, construct by construct
--
-- Declarations are carried over with their identifiers, names, and
-- source paths unchanged; a declared enum order additionally becomes
-- a materialized complete ranking.  Terms are rebuilt node for node
-- in authored structure and authored operand order, each node stamped
-- with its determined static type; a @LessOrEqual@ additionally
-- records its ordered operand reading, and lookups and relation
-- effects bind each endpoint term to the declared endpoint it fills.
-- A @CreateEntity@ effect's initializers are put into the target
-- entity's attribute declaration order — the one ordering
-- normalization changes (the resolved model lists the name-keyed
-- initializers in ascending key order).  Guarantee case terms are
-- normalized in their action's environment; a @TenantIsolation@
-- guarantee's resolved access relation and endpoint identities are
-- carried over unchanged (never re-resolved or re-judged), and an
-- escalation case's scope term is bound to the authority's scope
-- endpoint.
--
-- Nothing is simplified, folded, sorted, evaluated, or optimized:
-- normalization is deterministic structural canonicalization of one
-- authored document, and it neither evaluates policies nor
-- establishes guarantees.
--
-- == Failure classification
--
-- A well-typed document has no user-error class here: after the
-- typechecker minted the @Typed@ stage over this very model, every
-- inconsistency the normalizer could observe — a failing re-checked
-- typing judgment, a reference outside the model, an initializer set
-- that is not one-to-one with the target's attributes, an endpoint
-- arity the relation does not declare, an order that is not a
-- complete permutation, a scope term without a scope endpoint — is
-- impossible, and is therefore classified as a
-- 'NormalizerInvariantViolation' (frontend drift or a
-- typechecker\/normalizer bug; exit status 2 at the tool boundary),
-- never as a problem with the user's document.  The pass first
-- re-runs the complete checking pass ('checkModel') as a consistency
-- gate — reclassifying anything it reports — and is total: it walks
-- the whole model, aggregates every problem it finds, and never
-- throws.
module Mithril.Core.Internal.Normalize
  ( -- * Violations
    NormalizerInvariantViolation (..)

    -- * The normalization pass
  , normalizeModel
  ) where

import Data.Foldable (traverse_)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.Report
  ( Collect
  , andThen
  , quoted
  , refuse
  , reporting
  , runCollect
  , suppressed
  )
import qualified Mithril.Core.Internal.Resolved as Resolved
import Mithril.Core.Internal.SourcePath
  ( SourcePath
  , Sourced (..)
  , sourcePathSegments
  )
import Mithril.Core.Internal.Syntax (OneOrTwo (..))
import Mithril.Core.Internal.Typecheck
  ( Check
  , Env (..)
  , OrderedVerdict (..)
  , Signature
  , TypeViolation (..)
  , TypecheckerInvariantViolation (..)
  , TypingProblem (..)
  , buildSignature
  , caseEnv
  , checkModel
  , entitySig
  , inferPolicy
  , inferValue
  , orderedVerdict
  , policyTermPath
  , relationSig
  , valueTermPath
  )

--------------------------------------------------------------------
-- Violations
--------------------------------------------------------------------

-- | One normalizer-invariant violation: an inconsistency of the
-- well-typed model the normalizer cannot interpret even though the
-- static typechecker accepted it.  This is evidence of frontend
-- drift or a typechecker\/normalizer bug — an internal error of the
-- @mithril@ tool, never a problem with the user's document, which by
-- construction has no user-error class at this stage.
data NormalizerInvariantViolation = NormalizerInvariantViolation
  { normalizerInvariantPath :: [Text]
    -- ^ Instance path of the inconsistent site, as raw (unescaped)
    -- segments; render with
    -- 'Mithril.Core.Validation.renderJsonPointer'.
  , normalizerInvariantMessage :: Text
    -- ^ Description of the expectation that failed.
  }
  deriving (Eq, Ord, Show)

--------------------------------------------------------------------
-- Normalization computations
--------------------------------------------------------------------

-- | A normalization step: aggregates invariant violations while
-- building the normalized model.  There is deliberately no user
-- problem class.
type Norm a = Collect NormalizerInvariantViolation a

-- | Fail with one invariant violation at a source path.
refuseAt :: SourcePath -> Text -> Norm a
refuseAt path message =
  refuse (NormalizerInvariantViolation (sourcePathSegments path) message)

-- | Run a typechecker computation as a trusted query over the typed
-- model.  On a well-typed document the query reports nothing; any
-- problem it does report — a resurfacing user-class typing violation
-- as much as a typechecker-internal one — is impossible after the
-- @Typed@ stage was minted and is reclassified as a normalizer
-- invariant.
trusted :: Check a -> Norm a
trusted query =
  case runCollect query of
    (problems, value) ->
      reporting (map reclassify problems) *> maybe suppressed pure value
  where
    reclassify problem =
      case problem of
        UserTypingProblem violation ->
          NormalizerInvariantViolation
            (typeViolationPath violation)
            ( "the typed document fails a static-typing judgment: "
                <> typeViolationMessage violation
            )
        InternalTypingProblem violation ->
          NormalizerInvariantViolation
            (typecheckerInvariantPath violation)
            (typecheckerInvariantMessage violation)

--------------------------------------------------------------------
-- The model
--------------------------------------------------------------------

-- | Normalize a complete well-typed resolved model.  The pass first
-- re-runs the whole checking judgment as a consistency gate, then
-- rebuilds every declaration, action, and guarantee into the
-- normalized representation.  Pure and deterministic: the same model
-- always produces the same normalized model or the same violations.
normalizeModel
  :: Resolved.Model -> Collect NormalizerInvariantViolation Normalized.Model
normalizeModel model =
  trusted (checkModel model)
    *> ( Normalized.Model (Resolved.modelName model)
           <$> pure (map normalizeEntity (Resolved.modelEntities model))
           <*> traverse normalizeEnum (Resolved.modelEnums model)
           <*> pure (map normalizeRelation (Resolved.modelRelations model))
           <*> traverse (normalizeAction sig) (Resolved.modelActions model)
           <*> traverse (normalizeGuarantee sig) (Resolved.modelGuarantees model)
       )
  where
    sig = buildSignature model

--------------------------------------------------------------------
-- Schema declarations
--------------------------------------------------------------------

normalizeEntity :: Resolved.Entity -> Normalized.Entity
normalizeEntity entity =
  Normalized.Entity
    (Resolved.entityId entity)
    (Resolved.entityPath entity)
    (Resolved.entityName entity)
    (map normalizeAttribute (Resolved.entityAttributes entity))

-- Declared attribute, parameter, and payload type families are
-- shared between the resolved and normalized representations, so
-- their nodes are carried over as-is: this pass converts nothing and
-- projects nothing (the one projection into the static type
-- vocabulary lives in "Mithril.Core.Internal.StaticType").
normalizeAttribute :: Resolved.Attribute -> Normalized.Attribute
normalizeAttribute attribute =
  Normalized.Attribute
    (Resolved.attributeId attribute)
    (Resolved.attributePath attribute)
    (Resolved.attributeName attribute)
    (Resolved.attributeType attribute)

-- | Normalize one enum declaration, materializing a declared order
-- into the explicit complete ranking.  The typechecker established
-- that the order is a complete permutation of the enum's values; a
-- model where it is not is refused as an invariant violation.
normalizeEnum :: Resolved.EnumDefinition -> Norm Normalized.EnumDefinition
normalizeEnum definition =
  Normalized.EnumDefinition
    (Resolved.enumDefinitionId definition)
    (Resolved.enumDefinitionPath definition)
    (Resolved.enumDefinitionName definition)
    (fmap normalizeMember (Resolved.enumDefinitionValues definition))
    <$> normalizedOrder
  where
    normalizeMember member =
      Normalized.EnumMember
        (Resolved.enumMemberId member)
        (Resolved.enumMemberName member)
    memberIds =
      map
        Resolved.enumMemberId
        (NonEmpty.toList (Resolved.enumDefinitionValues definition))
    normalizedOrder =
      case Resolved.enumDefinitionOrder definition of
        Nothing -> pure Nothing
        Just orderRefs
          | sort (map Resolved.refTarget (NonEmpty.toList orderRefs))
              == sort memberIds ->
              pure
                ( Just
                    ( Normalized.EnumOrder
                        ( NonEmpty.zipWith
                            Normalized.RankedValue
                            (0 :| [1 ..])
                            orderRefs
                        )
                    )
                )
          | otherwise ->
              refuseAt
                (Resolved.enumDefinitionPath definition)
                "the declared order of this enum is not a complete permutation of its values"

normalizeRelation :: Resolved.Relation -> Normalized.Relation
normalizeRelation relation =
  Normalized.Relation
    (Resolved.relationId relation)
    (Resolved.relationPath relation)
    (Resolved.relationName relation)
    (fmap normalizeEndpoint (Resolved.relationEndpoints relation))
    (Resolved.relationPayload relation)

normalizeEndpoint :: Resolved.Endpoint -> Normalized.Endpoint
normalizeEndpoint endpoint =
  Normalized.Endpoint
    (Resolved.endpointId endpoint)
    (Resolved.endpointPath endpoint)
    (Resolved.endpointName endpoint)
    (Resolved.endpointEntity endpoint)

--------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------

normalizeAction :: Signature -> Resolved.Action -> Norm Normalized.Action
normalizeAction sig action =
  Normalized.Action
    (Resolved.actionId action)
    (Resolved.actionPath action)
    (Resolved.actionName action)
    (map normalizeParameter (Resolved.actionParameters action))
    <$> normalizeBody (Resolved.actionBody action)
  where
    env = Env sig (Resolved.actionId action)
    normalizeBody body =
      case body of
        Resolved.AuthenticatedOnlyBody allow shape ->
          Normalized.AuthenticatedOnlyBody
            <$> normalizePolicy env allow
            <*> normalizeShape env shape
        Resolved.AnyPrincipalBody allow shape ->
          Normalized.AnyPrincipalBody
            <$> ( Normalized.AnyPrincipalAllow
                    <$> normalizePolicy env (Resolved.anyPrincipalAnonymous allow)
                    <*> normalizePolicy
                      env
                      (Resolved.anyPrincipalAuthenticated allow)
                )
            <*> normalizeShape env shape

normalizeParameter :: Resolved.Parameter -> Normalized.Parameter
normalizeParameter parameter =
  Normalized.Parameter
    (Resolved.parameterId parameter)
    (Resolved.parameterPath parameter)
    (Resolved.parameterName parameter)
    (Resolved.parameterType parameter)

normalizeShape
  :: Env
  -> Resolved.ActionShape availability
  -> Norm (Normalized.ActionShape availability)
normalizeShape env shape =
  case shape of
    Resolved.ReadShape effectPath resultPath observed ->
      Normalized.ReadShape effectPath resultPath
        <$> normalizeValue env observed
    Resolved.CreateShape effect resultPath ->
      Normalized.CreateShape
        <$> normalizeCreateEntityEffect env effect
        <*> pure resultPath
    Resolved.MutationShape effect resultPath ->
      Normalized.MutationShape
        <$> normalizeDoneEffect env effect
        <*> pure resultPath

-- | Normalize a @CreateEntity@ effect: exactly one initializer per
-- target attribute, reordered into the target entity's attribute
-- declaration order.  The typechecker established completeness and
-- key resolution established target-owned unique keys, so a missing,
-- duplicated, or foreign initializer is an invariant violation.
normalizeCreateEntityEffect
  :: Env
  -> Resolved.CreateEntityEffect availability
  -> Norm (Normalized.CreateEntityEffect availability)
normalizeCreateEntityEffect env effect =
  trusted (entitySig (envSignature env) entityRef) `andThen` \entity ->
    let attributes = Resolved.entityAttributes entity
        attributeIds = map Resolved.attributeId attributes
        checkKnownKey initializer =
          let keyRef = Resolved.initializerKey initializer
           in if Resolved.refTarget keyRef `elem` attributeIds
                then pure ()
                else
                  refuseAt
                    (Resolved.refPath keyRef)
                    "a \"CreateEntity\" initializer key does not name an attribute of the target entity"
        initializerFor attribute =
          case
            [ initializer
            | initializer <- initializers
            , Resolved.refTarget (Resolved.initializerKey initializer)
                == Resolved.attributeId attribute
            ]
          of
            [initializer] ->
              Normalized.Initializer (Resolved.initializerKey initializer)
                <$> normalizeValue env (Resolved.initializerValue initializer)
            [] ->
              refuseAt
                sitePath
                ( "attribute "
                    <> quoted (sourcedValue (Resolved.attributeName attribute))
                    <> " of the target entity has no initializer"
                )
            _ ->
              refuseAt
                sitePath
                ( "attribute "
                    <> quoted (sourcedValue (Resolved.attributeName attribute))
                    <> " of the target entity has more than one initializer"
                )
     in Normalized.CreateEntityEffect sitePath entityRef
          <$> (traverse_ checkKnownKey initializers
                 *> traverse initializerFor attributes)
  where
    sitePath = Resolved.createEntityEffectPath effect
    entityRef = Resolved.createEntityEffectEntity effect
    initializers = Resolved.createEntityEffectInitializers effect

normalizeDoneEffect
  :: Env
  -> Resolved.DoneEffect availability
  -> Norm (Normalized.DoneEffect availability)
normalizeDoneEffect env effect =
  case effect of
    Resolved.NoChangeEffect path -> pure (Normalized.NoChangeEffect path)
    Resolved.DeleteEntityEffect path target ->
      Normalized.DeleteEntityEffect path <$> normalizeValue env target
    Resolved.SetRelationEffect path relationRef endpointTerms payload ->
      Normalized.SetRelationEffect path relationRef
        <$> bindEndpointTerms env path relationRef endpointTerms
        <*> normalizeValue env payload
    Resolved.RemoveRelationEffect path relationRef endpointTerms ->
      Normalized.RemoveRelationEffect path relationRef
        <$> bindEndpointTerms env path relationRef endpointTerms

-- | Bind the endpoint terms of a lookup or relation effect to the
-- declared endpoints of its relation, position by position.  The
-- typechecker established the exact arity, so a mismatch is an
-- invariant violation.
bindEndpointTerms
  :: Env
  -> SourcePath
  -> Resolved.Ref Resolved.RelationId
  -> OneOrTwo (Resolved.ValueTerm availability)
  -> Norm (OneOrTwo (Normalized.EndpointBinding availability))
bindEndpointTerms env sitePath relationRef endpointTerms =
  trusted (relationSig (envSignature env) relationRef) `andThen` \relation ->
    case (Resolved.relationEndpoints relation, endpointTerms) of
      (One endpoint, One term) -> One <$> bindOne endpoint term
      (Two firstEndpoint secondEndpoint, Two firstTerm secondTerm) ->
        Two
          <$> bindOne firstEndpoint firstTerm
          <*> bindOne secondEndpoint secondTerm
      _ ->
        refuseAt
          sitePath
          "the endpoint terms of this site do not match the relation's declared endpoint arity"
  where
    bindOne endpoint term =
      Normalized.EndpointBinding (Resolved.endpointId endpoint)
        <$> normalizeValue env term

--------------------------------------------------------------------
-- Terms
--------------------------------------------------------------------

-- | Normalize a value term: the node is rebuilt in authored
-- structure, and the term's static type is obtained from the
-- typechecker's own inference — never restated here.
normalizeValue
  :: Env
  -> Resolved.ValueTerm availability
  -> Norm (Normalized.ValueTerm availability)
normalizeValue env term =
  trusted (inferValue env term) `andThen` \termType ->
    Normalized.ValueTerm (valueTermPath term) termType
      <$> normalizeValueNode env term

normalizeValueNode
  :: Env
  -> Resolved.ValueTerm availability
  -> Norm (Normalized.ValueNode availability)
normalizeValueNode env term =
  case term of
    Resolved.BoolTerm _ flag -> pure (Normalized.BoolNode flag)
    Resolved.UnitTerm _ -> pure Normalized.UnitNode
    Resolved.EnumTerm _ enumRef valueRef ->
      pure (Normalized.EnumNode enumRef valueRef)
    Resolved.ArgumentTerm _ parameterRef ->
      pure (Normalized.ArgumentNode parameterRef)
    Resolved.ActorTerm _ userEntity -> pure (Normalized.ActorNode userEntity)
    Resolved.AttributeTerm _ source attributeRef ->
      (\normalizedSource -> Normalized.AttributeNode normalizedSource attributeRef)
        <$> normalizeValue env source

-- | Normalize a policy term; see 'normalizeValue'.
normalizePolicy
  :: Env
  -> Resolved.PolicyTerm availability
  -> Norm (Normalized.PolicyTerm availability)
normalizePolicy env term =
  trusted (inferPolicy env term) `andThen` \termType ->
    Normalized.PolicyTerm (policyTermPath term) termType
      <$> normalizePolicyNode env term

normalizePolicyNode
  :: Env
  -> Resolved.PolicyTerm availability
  -> Norm (Normalized.PolicyNode availability)
normalizePolicyNode env term =
  case term of
    Resolved.ValuePolicyTerm valueTerm ->
      Normalized.ValuePolicyNode <$> normalizeValue env valueTerm
    Resolved.LookupTerm path relationRef endpointTerms ->
      Normalized.LookupNode relationRef
        <$> bindEndpointTerms env path relationRef endpointTerms
    Resolved.NoneTerm _ payload ->
      pure (Normalized.NoneNode payload)
    Resolved.SomeTerm _ valueTerm ->
      Normalized.SomeNode <$> normalizeValue env valueTerm
    Resolved.IsSomeTerm _ operand ->
      Normalized.IsSomeNode <$> normalizePolicy env operand
    Resolved.EqualTerm _ left right ->
      Normalized.EqualNode
        <$> normalizePolicy env left
        <*> normalizePolicy env right
    Resolved.LessOrEqualTerm path left right ->
      Normalized.LessOrEqualNode
        <$> orderedOperandType env path left
        <*> normalizePolicy env left
        <*> normalizePolicy env right
    Resolved.AndTerm _ left right ->
      Normalized.AndNode
        <$> normalizePolicy env left
        <*> normalizePolicy env right
    Resolved.OrTerm _ left right ->
      Normalized.OrNode
        <$> normalizePolicy env left
        <*> normalizePolicy env right
    Resolved.NotTerm _ operand ->
      Normalized.NotNode <$> normalizePolicy env operand

-- | The explicit ordered reading of a @LessOrEqual@, from the
-- operands' determined type.  The classification is not restated
-- here: the typechecker's own shared 'orderedVerdict' answers it, and
-- this pass stores its 'OrderedAt' evidence — the ranking enum and
-- whether the comparison happens at the optional level.  The
-- typechecker established orderedness when it minted the stage, so
-- any other verdict is an invariant violation.
orderedOperandType
  :: Env
  -> SourcePath
  -> Resolved.PolicyTerm availability
  -> Norm Normalized.OrderedType
orderedOperandType env sitePath operand =
  trusted (inferPolicy env operand) `andThen` \operandType ->
    trusted (orderedVerdict (envSignature env) sitePath operandType)
      `andThen` \verdict ->
        case verdict of
          OrderedAt orderedType -> pure orderedType
          UnrankedEnum _ ->
            refuseAt
              sitePath
              "the operand enum of a \"LessOrEqual\" declares no order"
          NotOrdered ->
            refuseAt
              sitePath
              "the operands of a \"LessOrEqual\" do not have an ordered type"

--------------------------------------------------------------------
-- Guarantees
--------------------------------------------------------------------

normalizeGuarantee :: Signature -> Resolved.Guarantee -> Norm Normalized.Guarantee
normalizeGuarantee sig guarantee =
  case guarantee of
    Resolved.AuthenticatedMutationGuarantee path ->
      pure (Normalized.AuthenticatedMutationGuarantee path)
    Resolved.TenantIsolationGuarantee path access cases ->
      Normalized.TenantIsolationGuarantee
        path
        (normalizeTenantAccess access)
        <$> traverse (normalizeTenantIsolationCase sig) cases
    Resolved.NoSelfPrivilegeEscalationGuarantee path authority cases ->
      Normalized.NoSelfPrivilegeEscalationGuarantee
        path
        (normalizeAuthority authority)
        <$> traverse
          (normalizeEscalationCase sig (Resolved.authorityScopeEndpoint authority))
          cases

normalizeAuthority :: Resolved.Authority -> Normalized.Authority
normalizeAuthority authority =
  Normalized.Authority
    (Resolved.authorityPath authority)
    (Resolved.authorityRelation authority)
    (Resolved.authoritySubjectEndpoint authority)
    (Resolved.authorityScopeEndpoint authority)
    (Resolved.authorityAbsenceLevel authority)
    (Resolved.authorityPayloadOrder authority)

-- | Carry the resolved @TenantIsolation@ access relation and
-- endpoint identities into the normalized model unchanged.  Nothing
-- is re-resolved or re-judged here: the typechecker established (in
-- the consistency gate above) that the relation is binary, the
-- endpoints distinct and relation-owned, and the subject endpoint of
-- the distinguished @User@ entity's type.
normalizeTenantAccess
  :: Resolved.TenantIsolationAccess -> Normalized.TenantIsolationAccess
normalizeTenantAccess access =
  Normalized.TenantIsolationAccess
    (Resolved.tenantIsolationAccessPath access)
    (Resolved.tenantIsolationAccessRelation access)
    (Resolved.tenantIsolationAccessSubjectEndpoint access)
    (Resolved.tenantIsolationAccessTenantEndpoint access)

normalizeTenantIsolationCase
  :: Signature -> Resolved.TenantIsolationCase -> Norm Normalized.TenantIsolationCase
normalizeTenantIsolationCase sig tenantCase =
  trusted (caseEnv sig (Resolved.tenantIsolationCaseAction tenantCase))
    `andThen` \env ->
      Normalized.TenantIsolationCase
        (Resolved.tenantIsolationCasePath tenantCase)
        (Resolved.tenantIsolationCaseAction tenantCase)
        <$> normalizeValue env (Resolved.tenantIsolationCaseTenant tenantCase)
        <*> normalizePolicy env (Resolved.tenantIsolationCaseProtected tenantCase)

-- | Normalize one escalation case, binding its zero-or-one scope
-- term to the authority's scope endpoint.  The typechecker
-- established the one-to-one correspondence, so a mismatch in either
-- direction is an invariant violation.
normalizeEscalationCase
  :: Signature
  -> Maybe (Resolved.Ref Resolved.EndpointId)
  -> Resolved.EscalationCase
  -> Norm Normalized.EscalationCase
normalizeEscalationCase sig scopeEndpoint escalationCase =
  trusted (caseEnv sig (Resolved.escalationCaseAction escalationCase))
    `andThen` \env ->
      Normalized.EscalationCase
        (Resolved.escalationCasePath escalationCase)
        (Resolved.escalationCaseAction escalationCase)
        <$> scopeBinding env
  where
    scopeBinding env =
      case (scopeEndpoint, Resolved.escalationCaseScope escalationCase) of
        (Nothing, Nothing) -> pure Nothing
        (Just endpointRef, Just scopeTerm) ->
          Just
            . Normalized.ScopeBinding (Resolved.refTarget endpointRef)
            <$> normalizeValue env scopeTerm
        (Nothing, Just scopeTerm) ->
          refuseAt
            (valueTermPath scopeTerm)
            "this case names a scope term, but the authority declares no scope endpoint"
        (Just _, Nothing) ->
          refuseAt
            (Resolved.escalationCasePath escalationCase)
            "this case names no scope term, but the authority declares a scope endpoint"
