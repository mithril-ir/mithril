{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The one shared NoSelfPrivilegeEscalation support-plan facility: the
-- deterministic support gate over the typed normalized representation
-- and the resolved plan it extracts.  It is the single statement of
-- the supported-shape classification, consumed by both implemented
-- backends of typed normalized Core — the Agda verifier slice
-- ("Mithril.Core.Internal.Verify", behind "Mithril.Core.Verification")
-- and the Wasp emitter ("Mithril.Core.Internal.Wasp", behind
-- "Mithril.Core.Wasp").  Neither consumer restates any part of the
-- classification: the verifier transcribes the plan into the trusted
-- Agda kernel, the emitter lowers exactly the one case shape its
-- profile covers from the same tagged plan, and a document outside the
-- rule is unsupported to both for exactly the same deterministic
-- reasons.
--
-- == The support rule
--
-- Exactly one obligation family is supported: a document that selects
-- exactly one guarantee, a @NoSelfPrivilegeEscalation@ guarantee whose
-- non-empty case collection consists entirely of cases each matching
-- exactly one of the two supported proof rules below.  The shared
-- authority evidence is validated once for the whole guarantee:
--
-- * the authority relation is binary, with the subject endpoint at
--   the distinguished @User@ entity — anchored to the identity the
--   normalized model carries independently for it
--   ('Normalized.modelUserEntity': the resolver's own designation,
--   validated by the typechecker and propagated by the normalizer),
--   never re-derived from an authored name, a declaration position,
--   the subject endpoint itself, or an @Actor@ term of a case — and
--   one scope endpoint at a different entity;
-- * the authority payload order is a two-value enum with a declared
--   (materialized) complete ranking, absence interpreted as bottom.
--
-- Every authored case is then classified independently, in authored
-- order — never only the first case, never with a case silently
-- dropped, reordered, or deduplicated — and tagged with the rule it
-- matched ('NspeCasePlan', 'NspeCaseMatch'):
--
-- /Rule 1, change-other/ (the already-mechanized sound proof rule of
-- the Agda spike's @Mithril.Acme@ slice, the safe
-- @Membership.changeRole@ shape):
--
-- * the case action is @AuthenticatedOnly@ and declares exactly three
--   parameters in order: subject (@EntityRef@ of the subject
--   entity), scope (@EntityRef@ of the scope entity), payload (the
--   authority enum);
-- * the effect is @SetRelation@ on the authority relation, binding
--   the subject endpoint to exactly the subject parameter, the scope
--   endpoint to exactly the scope parameter, and the payload to
--   exactly the payload parameter;
-- * the case scope term is exactly the scope parameter; and
-- * the allow policy is exactly the conjunction
--   @And(LessOrEqual(Some(top authority value), Lookup(authority,
--   [Actor, scope parameter])), And(Not(Equal(Actor, subject
--   parameter)), IsSome(Lookup(authority, [subject parameter, scope
--   parameter]))))@ at the absence-as-bottom optional ordering of the
--   authority enum.
--
-- /Rule 2, bounded self-update/:
--
-- * the case action is @AuthenticatedOnly@ and declares exactly two
--   parameters in order: scope (@EntityRef@ of the scope entity),
--   payload (the authority enum);
-- * the effect is @SetRelation@ on the authority relation, binding
--   the subject endpoint to exactly @Actor@, the scope endpoint to
--   exactly the scope parameter, and the payload to exactly the
--   payload parameter;
-- * the case scope term is exactly the scope parameter; and
-- * the allow policy is exactly @LessOrEqual(Some(payload parameter),
--   Lookup(authority, [Actor, scope parameter]))@ at the
--   absence-as-bottom optional ordering of the authority enum — with
--   no further conjunct: an explicit @IsSome@ is redundant under
--   absence as bottom (a lifted value is never below an absent tuple)
--   and is deliberately not accepted.
--
-- The two rules are disjoint by declared arity — three parameters
-- against two — so the declared parameter count selects the one
-- candidate rule of a case deterministically, no case can match both
-- rules, and a case matching neither rule (any other arity, or a
-- mismatch against its candidate rule) makes the complete obligation
-- unsupported with reasons anchored at the offending case, action,
-- parameter, policy, effect, or case-scope site.  The gate inspects
-- stored identities and evidence structurally — it never compares raw
-- JSON bytes, recognizes filenames, hashes the model, reparses,
-- re-resolves, re-infers types, or evaluates policy — and it
-- deliberately rejects semantically equivalent but differently
-- authored shapes as unsupported.
--
-- Every stored identity the gate consumes first passes the one
-- canonical identity preflight ('canonicalDeclaration',
-- 'canonicalChildren'): a reference resolves through its canonical
-- declaration-list position, the recovered declaration's stored
-- self-identity must equal exactly the canonical identity the
-- reference names, and every owner-local child declaration (relation
-- endpoint, enum member, action parameter) must store exactly the
-- canonical identity derived from its already-validated owner
-- identity and its own declaration position.  Identity is validated
-- before types, ranking, bindings, policy shape, or names, and no
-- unvalidated stored self-identity is ever carried into
-- 'AuthorityFacts', support matching, name lookup, generated
-- evidence, or plan construction — so a stored identity drifted
-- coordinately with every stored reference later compared against it
-- still halts as an invariant violation before either consumer can
-- generate anything or launch any checker.  The subject entity is
-- additionally anchored semantically, not only canonically: the
-- entity the (validated) subject endpoint references must be exactly
-- the distinguished @User@ identity the normalized model carries, and
-- every @Actor@ term the rules inspect is then compared against that
-- same anchored identity ('AuthorityFacts' stores it as
-- 'factUserEntity').  Without the anchor, a subject endpoint, its
-- parameter types, and every @Actor@ term redirected coherently to
-- some other entity would agree with one another and pass every
-- self-consistency check, while the generated module would still
-- transcribe the subject as the kernel's fixed @UserK@; with it, such
-- evidence halts as an invariant violation at the authority's subject
-- endpoint reference — never as an unsupported shape and never as a
-- verified document.
--
-- Soundness of the rules (the verifier's concern, stated once here so
-- the emitter inherits exactly the same premise): the generated Agda
-- module transcribes exactly these shapes into the trusted
-- fixed-schema kernel.  For rule 1 it re-proves, with the kernel's
-- checked frame lemma, that policy success forces the authenticated
-- actor's index apart from the subject parameter's, so the authorized
-- @SetRelation@ write cannot touch the actor's own authority tuple in
-- the selected scope; the middle guard conjunct @Not(Equal(Actor,
-- subject parameter))@ is the proof-relevant fact.  For rule 2 it
-- re-proves, with the kernel's checked point lemma, that the write
-- installs exactly the requested payload at the actor's own tuple
-- while policy success is exactly the bound of that payload by the
-- actor's pre-state authority.  Every other pinned piece keeps the
-- transcription exact.  The gate itself proves nothing, and a plan
-- attests support only.
--
-- == The one ranking authority
--
-- The materialized ranking of the authority enum is validated here
-- and nowhere else: 'materializedRanking' requires the stored ranking
-- to be a consistently materialized complete permutation of the
-- enum's canonical member identities (every stored rank equal to its
-- position), classifies any other stored ranking evidence as an
-- invariant violation, identifies the bottom (rank 0) and the top —
-- the privilege floor the rule-1 allow policy names — and resolves
-- their numeric ranks, and derives the rank an absent tuple takes.
-- Both consumers read 'planRanking', 'planRankBottom', 'planRankTop',
-- and 'planAbsentRank' as validated values; neither scans the ranking
-- again, supplies a fallback rank, or classifies ranking evidence of
-- its own.
--
-- == Failure classification
--
-- Shapes a well-typed author can write but the rule does not cover
-- are 'UnsupportedReason's — deterministic, sorted, deduplicated,
-- decided before any generation.  Inconsistencies of the normalized
-- model that no pipeline-produced document can exhibit (dangling or
-- foreign identities, evidence drift) are
-- 'VerifierInvariantViolation's — internal tool errors shared by both
-- consumers, never authored-document problems and never semantic
-- verdicts.
module Mithril.Core.Internal.NspeSupportPlan
  ( -- * Shared support vocabulary
    UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations

    -- * The two supported proof rules
  , NspeRule (..)
  , nspeRuleLabel

    -- * The support plan
  , NspeSupportPlan (..)
  , NspeCasePlan (..)
  , NspeCaseMatch (..)
  , ChangeOtherFacts (..)
  , BoundedSelfUpdateFacts (..)
  , caseRule
  , PlanEnumMember (..)
  , PlanRankedMember (..)
  , PlanBinding (..)
  , PlanRefusal (..)
  , supportPlan

    -- * Name quoting shared by the consumers' diagnostics and comments
  , quotedName
  ) where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.Resolved
  ( ActionId (..)
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
  ( OrderedType (..)
  , PolicyType (..)
  , ValueType (..)
  , parameterStaticType
  )
import Mithril.Core.Internal.Syntax
  ( AbsenceLevel (..)
  , ActorAvailability (..)
  , OneOrTwo (..)
  )

--------------------------------------------------------------------
-- Shared support vocabulary
--------------------------------------------------------------------

-- | One deterministic reason the normalized document is outside the
-- support rule.  Authored, well-typed shapes land here — never
-- internal errors and never semantic verdicts.
data UnsupportedReason = UnsupportedReason
  { unsupportedReasonPath :: [Text]
    -- ^ Instance path of the unsupported site, as raw (unescaped)
    -- segments; render with
    -- 'Mithril.Core.Validation.renderJsonPointer'.
  , unsupportedReasonMessage :: Text
    -- ^ Description of the supported shape the site does not match.
  }
  deriving (Eq, Ord, Show)

-- | One verifier-invariant violation: an inconsistency of the
-- normalized model that no pipeline-produced document can exhibit
-- (a dangling or foreign identity, binding or ownership
-- inconsistency, or stored type\/order evidence drift).  This is an
-- internal error of the tool, never a user-document problem and never
-- a semantic verdict.
data VerifierInvariantViolation = VerifierInvariantViolation
  { verifierInvariantPath :: [Text]
    -- ^ Instance path of the inconsistent site, as raw segments;
    -- render with 'Mithril.Core.Validation.renderJsonPointer'.
  , verifierInvariantMessage :: Text
    -- ^ Description of the expectation that failed.
  }
  deriving (Eq, Ord, Show)

-- | Deterministically sort unsupported reasons (by path, then
-- message) and remove duplicates — the exact normalization applied
-- before reasons are returned.
normalizeUnsupportedReasons :: [UnsupportedReason] -> [UnsupportedReason]
normalizeUnsupportedReasons = map NonEmpty.head . NonEmpty.group . sort

-- | Deterministically sort verifier-invariant violations (by path,
-- then message) and remove duplicates.
normalizeVerifierInvariantViolations
  :: [VerifierInvariantViolation] -> [VerifierInvariantViolation]
normalizeVerifierInvariantViolations = map NonEmpty.head . NonEmpty.group . sort

--------------------------------------------------------------------
-- The two supported proof rules
--------------------------------------------------------------------

-- | The two supported proof rules a case can match (module header).
-- The tag is decided once, here, and carried in the plan; downstream
-- consumers dispatch on it and never re-derive it.
data NspeRule
  = -- | Rule 1: an authenticated principal changes /another/
    -- subject's authority (the safe @Membership.changeRole@ shape).
    ChangeOtherRule
  | -- | Rule 2: an authenticated principal updates its /own/
    -- authority to a payload bounded by its pre-state authority.
    BoundedSelfUpdateRule
  deriving (Eq, Ord, Show)

-- | The deterministic human-readable identity of a rule, shared by
-- the generated Agda evidence and the verification report.
nspeRuleLabel :: NspeRule -> Text
nspeRuleLabel rule =
  case rule of
    ChangeOtherRule -> "rule 1 (change-other)"
    BoundedSelfUpdateRule -> "rule 2 (bounded-self-update)"

--------------------------------------------------------------------
-- The support plan
--------------------------------------------------------------------

-- | Everything both consumers derive from, extracted structurally
-- from the normalized evidence by the support gate: the resolved
-- identities of every proof- and execution-relevant declaration of
-- the one supported obligation, each declared name together with its
-- authored location (diagnostic and rendering metadata, never
-- semantic linkage), the enum's declared members, its materialized
-- ranking, and — per authored case, in authored order — the explicit
-- endpoint and scope bindings the gate verified together with the
-- rule the case matched.  Constructing a plan attests support only;
-- nothing is verified by it, and nothing is generated from
-- unvalidated evidence.
data NspeSupportPlan = NspeSupportPlan
  { planModelName :: Sourced Text
  , planGuaranteePath :: SourcePath
    -- ^ The authored location of the one selected guarantee (for
    -- diagnostics anchored at the guarantee, such as a consumer
    -- profile that covers fewer cases than the guarantee selects).
  , planRelationId :: RelationId
  , planRelationName :: Sourced Text
  , planSubjectEndpointId :: EndpointId
  , planSubjectEndpointName :: Sourced Text
  , planSubjectEntityId :: EntityId
  , planSubjectEntityName :: Sourced Text
  , planScopeEndpointId :: EndpointId
  , planScopeEndpointName :: Sourced Text
  , planScopeEntityId :: EntityId
  , planScopeEntityName :: Sourced Text
  , planAbsenceLevel :: AbsenceLevel
  , planEnumId :: EnumId
  , planEnumName :: Sourced Text
  , planEnumMembers :: [PlanEnumMember]
    -- ^ The authority enum's declared members, in declaration order
    -- (the canonical member identities, validated by the preflight).
  , planRanking :: [PlanRankedMember]
    -- ^ The materialized complete ranking of the authority enum, in
    -- ascending rank order (rank 0 first); absence ranks below rank 0
    -- at 'planAbsenceLevel'.
  , planRankBottom :: PlanRankedMember
    -- ^ The bottom of the materialized ranking: the member ranked 0,
    -- resolved once here from the validated ranking.
  , planRankTop :: PlanRankedMember
    -- ^ The top of the materialized ranking — the privilege floor the
    -- rule-1 allow policy compares the actor's authority against —
    -- with its validated numeric rank, resolved once here from the
    -- validated ranking.  Neither consumer scans the ranking for it.
  , planAbsentRank :: Int
    -- ^ The rank an absent authority tuple takes under
    -- 'planAbsenceLevel' (absence as bottom: below rank 0, so -1),
    -- derived once here.
  , planCases :: NonEmpty NspeCasePlan
    -- ^ Every authored case of the guarantee, in authored order, each
    -- tagged with the rule it matched.  Complete by construction: the
    -- gate refuses the whole guarantee unless every case matched.
  }
  deriving (Eq)

-- | One supported escalation case: the facts every rule shares —
-- its zero-based authored position and location, the case action,
-- the scope and payload parameters, and the verified case scope
-- binding — plus the rule-specific match.
data NspeCasePlan = NspeCasePlan
  { casePosition :: Int
    -- ^ The zero-based authored position of the case in the
    -- guarantee's case list; the generated theorem groups and the
    -- verification report are qualified by it.
  , casePath :: SourcePath
  , caseActionId :: ActionId
  , caseActionName :: Sourced Text
  , caseScopeParameterId :: ParameterId
  , caseScopeParameterName :: Sourced Text
  , casePayloadParameterId :: ParameterId
  , casePayloadParameterName :: Sourced Text
  , caseScopeBinding :: PlanBinding
    -- ^ The case scope binding the gate verified: the authority's
    -- scope endpoint bound to the scope parameter.
  , caseMatch :: NspeCaseMatch
    -- ^ The rule the case matched, with the rule-specific facts.
  }
  deriving (Eq)

-- | The rule a case matched, explicitly tagged, with the facts only
-- that rule establishes.
data NspeCaseMatch
  = ChangeOtherMatch ChangeOtherFacts
  | BoundedSelfUpdateMatch BoundedSelfUpdateFacts
  deriving (Eq)

-- | The rule-1 facts: the subject parameter the effect and policy
-- name, and the effect's verified endpoint bindings.
data ChangeOtherFacts = ChangeOtherFacts
  { changeOtherSubjectParameterId :: ParameterId
  , changeOtherSubjectParameterName :: Sourced Text
  , changeOtherEffectBindings :: [PlanBinding]
    -- ^ The @SetRelation@ effect's endpoint bindings the gate
    -- verified, in the authority relation's endpoint order: the
    -- subject endpoint bound to the subject parameter, then the scope
    -- endpoint bound to the scope parameter.
  }
  deriving (Eq)

-- | The rule-2 facts: the effect writes the authority relation at
-- (@Actor@, scope parameter) — the subject endpoint is bound to the
-- implicit authenticated principal by the rule itself, so only the
-- scope endpoint's verified parameter binding is recorded.
newtype BoundedSelfUpdateFacts = BoundedSelfUpdateFacts
  { selfUpdateEffectScopeBinding :: PlanBinding
  }
  deriving (Eq)

-- | The rule tag of a case plan.
caseRule :: NspeCasePlan -> NspeRule
caseRule casePlan =
  case caseMatch casePlan of
    ChangeOtherMatch _ -> ChangeOtherRule
    BoundedSelfUpdateMatch _ -> BoundedSelfUpdateRule

-- | One declared member of the authority enum.
data PlanEnumMember = PlanEnumMember
  { planMemberId :: EnumValueId
  , planMemberName :: Sourced Text
  }
  deriving (Eq)

-- | One materialized rank of the authority enum: the 0-based rank,
-- the canonical member identity it ranks, and that member's declared
-- name.
data PlanRankedMember = PlanRankedMember
  { planRankedRank :: Int
  , planRankedId :: EnumValueId
  , planRankedName :: Text
  }
  deriving (Eq)

-- | One verified binding of a declared endpoint of the authority
-- relation to a parameter of the case action.
data PlanBinding = PlanBinding
  { planBindingEndpointId :: EndpointId
  , planBindingEndpointName :: Text
  , planBindingParameterId :: ParameterId
  , planBindingParameterName :: Text
  }
  deriving (Eq)

-- | Why no plan was produced: the document is outside the support
-- rule (authored shapes), or the normalized model is internally
-- inconsistent (forged or drifted — a tool error).  Invariant
-- violations dominate unsupported reasons.
data PlanRefusal
  = PlanUnsupported (NonEmpty UnsupportedReason)
  | PlanInvariant (NonEmpty VerifierInvariantViolation)
  deriving (Eq, Show)

--------------------------------------------------------------------
-- Gate helpers
--------------------------------------------------------------------

reasonAt :: SourcePath -> Text -> UnsupportedReason
reasonAt path = UnsupportedReason (sourcePathSegments path)

invariantAt :: SourcePath -> Text -> VerifierInvariantViolation
invariantAt path = VerifierInvariantViolation (sourcePathSegments path)

-- | Quote a document-supplied name for a diagnostic or generated
-- comment.  'show' on 'Text' renders a double-quoted string literal
-- with every control and non-ASCII character escaped, so no name can
-- smuggle a physical line break — and therefore no Agda syntax —
-- into a diagnostic or a generated line comment.
quotedName :: Text -> Text
quotedName = Text.pack . show

-- | Accumulated gate findings alongside an optional continuation
-- value.
data Gate a = Gate [UnsupportedReason] [VerifierInvariantViolation] (Maybe a)

gateValue :: a -> Gate a
gateValue = Gate [] []  . Just

gateReasons :: [UnsupportedReason] -> Gate a
gateReasons reasons = Gate reasons [] Nothing

gateInvariant :: VerifierInvariantViolation -> Gate a
gateInvariant violation = Gate [] [violation] Nothing

-- | Sequence a dependent gate step: the continuation runs only when a
-- value exists; findings of both steps are kept.
gateThen :: Gate a -> (a -> Gate b) -> Gate b
gateThen (Gate reasons violations value) continue =
  case value of
    Nothing -> Gate reasons violations Nothing
    Just x ->
      case continue x of
        Gate moreReasons moreViolations result ->
          Gate (reasons <> moreReasons) (violations <> moreViolations) result

-- | Combine independent gate checks, keeping the pair of values only
-- when both exist.
gateBoth :: Gate a -> Gate b -> Gate (a, b)
gateBoth (Gate r1 v1 a) (Gate r2 v2 b) =
  Gate (r1 <> r2) (v1 <> v2) ((,) <$> a <*> b)

-- | Map over the value of a gate, keeping its findings.
gateMap :: (a -> b) -> Gate a -> Gate b
gateMap f (Gate reasons violations value) = Gate reasons violations (fmap f value)

-- | Combine independent gate checks over a list: every check runs and
-- every finding is kept; the list of values exists only when every
-- check produced one.  This is the per-case traversal — no case is
-- skipped because an earlier one failed.
gateAll :: [Gate a] -> Gate [a]
gateAll = foldr (\next rest -> gateMap (uncurry (:)) (gateBoth next rest)) (gateValue [])

-- | A check with findings but no interesting value.
gateUnit :: [UnsupportedReason] -> [VerifierInvariantViolation] -> Gate ()
gateUnit reasons violations = Gate reasons violations (Just ())

--------------------------------------------------------------------
-- Canonical identity preflight (model lookups)
--------------------------------------------------------------------

-- | The one canonical lookup for top-level declarations: the
-- reference's target names a canonical declaration-list position, the
-- declaration at that position is recovered, and the recovered
-- declaration's stored self-identity must be exactly the canonical
-- identity the reference names.  Indexing alone is deliberately not
-- sufficient — a recovered declaration whose stored self-identity has
-- drifted is forged evidence, and a stored self-identity changed
-- coordinately with every stored reference the gate later compares
-- against it would otherwise pass every downstream comparison.  Only
-- a declaration that passed this validation may be consumed, so every
-- stored self-identity later read from it (for 'AuthorityFacts',
-- support matching, name lookup, generated evidence, or plan
-- construction) is known to equal its canonical identity.
canonicalDeclaration
  :: Eq identity
  => SourcePath
  -- ^ The reference site, for diagnostics.
  -> Text
  -- ^ Missing-declaration diagnostic.
  -> Text
  -- ^ Identity-drift diagnostic.
  -> Int
  -- ^ The canonical declaration position the reference names.
  -> [declaration]
  -- ^ The model's declaration list.
  -> (declaration -> identity)
  -- ^ The stored self-identity of a declaration.
  -> identity
  -- ^ The canonical identity (the reference's target).
  -> Gate declaration
canonicalDeclaration path missingMessage driftMessage position declarations storedIdentity canonical
  | position >= 0
  , declaration : _ <- drop position declarations =
      if storedIdentity declaration == canonical
        then gateValue declaration
        else gateInvariant (invariantAt path driftMessage)
  | otherwise = gateInvariant (invariantAt path missingMessage)

-- | The one canonical preflight for owner-local declaration lists:
-- the child at each declaration position must store exactly the
-- canonical identity derived from the already-validated owner
-- identity and that position.  The caller must have validated the
-- owner's own stored self-identity first ('canonicalDeclaration'), so
-- no child canonical identity is ever derived from an unvalidated
-- stored parent identity.  One exact statement rules out duplicate,
-- missing-position, foreign-owner, and out-of-range stored child
-- identities, and it makes the canonical identity list pairwise
-- distinct by construction.  Corrupt children halt the gate (every
-- violation reported, no continuation), so nothing downstream can
-- consume the forged metadata.
canonicalChildren
  :: Eq identity
  => Text
  -- ^ Identity-drift diagnostic.
  -> (Int -> identity)
  -- ^ The canonical identity of a declaration position, derived from
  -- the validated owner identity.
  -> (child -> identity)
  -- ^ The stored self-identity of a child.
  -> (child -> SourcePath)
  -- ^ The child's declaration site, for diagnostics.
  -> [child]
  -> Gate ()
canonicalChildren driftMessage canonicalAt storedIdentity childPath children =
  case violations of
    [] -> gateValue ()
    _ -> Gate [] violations Nothing
  where
    violations =
      [ invariantAt (childPath child) driftMessage
      | (position, child) <- zip [0 ..] children
      , storedIdentity child /= canonicalAt position
      ]

lookupRelation
  :: Normalized.Model -> Ref RelationId -> Gate Normalized.Relation
lookupRelation model ref =
  case refTarget ref of
    canonical@(RelationId position) ->
      canonicalDeclaration
        (refPath ref)
        "this reference names a relation the model does not declare"
        "this referenced relation's stored identity is not the canonical identity of its declaration position"
        position
        (Normalized.modelRelations model)
        Normalized.relationId
        canonical

lookupEntity :: Normalized.Model -> Ref EntityId -> Gate Normalized.Entity
lookupEntity model ref =
  case refTarget ref of
    canonical@(EntityId position) ->
      canonicalDeclaration
        (refPath ref)
        "this reference names an entity the model does not declare"
        "this referenced entity's stored identity is not the canonical identity of its declaration position"
        position
        (Normalized.modelEntities model)
        Normalized.entityId
        canonical

lookupEnum :: Normalized.Model -> Ref EnumId -> Gate Normalized.EnumDefinition
lookupEnum model ref =
  case refTarget ref of
    canonical@(EnumId position) ->
      canonicalDeclaration
        (refPath ref)
        "this reference names an enum the model does not declare"
        "this referenced enum's stored identity is not the canonical identity of its declaration position"
        position
        (Normalized.modelEnums model)
        Normalized.enumDefinitionId
        canonical

lookupAction :: Normalized.Model -> Ref ActionId -> Gate Normalized.Action
lookupAction model ref =
  case refTarget ref of
    canonical@(ActionId position) ->
      canonicalDeclaration
        (refPath ref)
        "this reference names an action the model does not declare"
        "this referenced action's stored identity is not the canonical identity of its declaration position"
        position
        (Normalized.modelActions model)
        Normalized.actionId
        canonical

-- | Canonical child preflight of an already identity-validated
-- relation: every declared endpoint must store exactly the canonical
-- endpoint identity of its declaration position, owned by exactly
-- this relation.  Runs immediately after 'lookupRelation', before any
-- endpoint lookup, binding pairing, or evidence extraction can
-- consume a forged endpoint identity.
declaredEndpointChecks :: Normalized.Relation -> Gate ()
declaredEndpointChecks relation =
  canonicalChildren
    "this declared endpoint's stored identity is not the canonical identity of its declaration position"
    (EndpointId (Normalized.relationId relation))
    Normalized.endpointId
    Normalized.endpointPath
    (endpointList (Normalized.relationEndpoints relation))

-- | Canonical child preflight of an already identity-validated enum:
-- every declared member must store exactly the canonical value
-- identity of its declaration position, owned by exactly this enum.
-- Runs before any ranking or member-name lookup can consume a forged
-- member identity, and it makes the canonical identity list the
-- ranking bijection compares against pairwise distinct by
-- construction.
declaredMemberChecks :: Normalized.EnumDefinition -> Gate ()
declaredMemberChecks enumDefinition =
  canonicalChildren
    "this declared enum member's stored identity is not the canonical identity of its declaration position"
    (EnumValueId (Normalized.enumDefinitionId enumDefinition))
    Normalized.enumMemberId
    (sourcedPath . Normalized.enumMemberName)
    (NonEmpty.toList (Normalized.enumDefinitionValues enumDefinition))

-- | Canonical child preflight of an already identity-validated
-- action: every declared parameter must store exactly the canonical
-- parameter identity of its declaration position, owned by exactly
-- this action.  Runs immediately after 'lookupAction', before any
-- parameter typing, argument-reference, or generation-relevant
-- (de Bruijn) consumption of a forged parameter identity.
declaredParameterChecks :: Normalized.Action -> Gate ()
declaredParameterChecks action =
  canonicalChildren
    "this declared parameter's stored identity is not the canonical identity of its declaration position"
    (ParameterId (Normalized.actionId action))
    Normalized.parameterId
    Normalized.parameterPath
    (Normalized.actionParameters action)

-- | The endpoint declaration named by a relation-owned endpoint
-- identifier, resolved through its canonical position inside an
-- already-preflighted relation — refusing (as an invariant violation)
-- an endpoint of a different relation, an endpoint outside the
-- relation's arity, or (defensively; unreachable after
-- 'declaredEndpointChecks') a recovered declaration whose stored
-- identity is not the one the identifier names.
lookupEndpoint
  :: Normalized.Relation
  -> SourcePath
  -> EndpointId
  -> Gate Normalized.Endpoint
lookupEndpoint relation path endpoint@(EndpointId owner position) =
  if owner /= Normalized.relationId relation
    then
      gateInvariant
        ( invariantAt
            path
            "this endpoint belongs to a different relation than the one it is used with"
        )
    else
      case drop position (endpointList (Normalized.relationEndpoints relation)) of
        declared : _
          | position >= 0 ->
              if Normalized.endpointId declared == endpoint
                then gateValue declared
                else
                  gateInvariant
                    ( invariantAt
                        path
                        "this declared endpoint's stored identity is not the canonical identity of its declaration position"
                    )
        _ ->
          gateInvariant
            ( invariantAt
                path
                "this endpoint is outside its relation's declared arity"
            )

endpointList :: OneOrTwo a -> [a]
endpointList (One a) = [a]
endpointList (Two a b) = [a, b]

--------------------------------------------------------------------
-- The support gate
--------------------------------------------------------------------

-- | Decide, purely and deterministically, whether the normalized
-- model is exactly the supported obligation shape, and extract the
-- generation plan if so.  The module header states the rules and
-- their soundness; the gate consumes stored identities and evidence
-- only.
supportPlan :: Normalized.Model -> Either PlanRefusal NspeSupportPlan
supportPlan model =
  case selectObligation model `gateThen` uncurry3 (obligationPlan model) of
    Gate reasons violations plan ->
      case NonEmpty.nonEmpty (normalizeVerifierInvariantViolations violations) of
        Just someViolations -> Left (PlanInvariant someViolations)
        Nothing ->
          case NonEmpty.nonEmpty (normalizeUnsupportedReasons reasons) of
            Just someReasons -> Left (PlanUnsupported someReasons)
            Nothing ->
              case plan of
                Just builtPlan -> Right builtPlan
                Nothing ->
                  Left
                    ( PlanInvariant
                        ( VerifierInvariantViolation
                            []
                            "the support gate produced neither a plan nor a finding"
                            :| []
                        )
                    )
  where
    uncurry3 f (a, b, c) = f a b c

-- | Phase 1: the guarantee selection.  Exactly one guarantee, of the
-- NoSelfPrivilegeEscalation family; its non-empty case collection is
-- handed on complete and in authored order.
selectObligation
  :: Normalized.Model
  -> Gate (SourcePath, Normalized.Authority, NonEmpty Normalized.EscalationCase)
selectObligation model =
  case Normalized.modelGuarantees model of
    [] ->
      gateReasons
        [ UnsupportedReason
            ["guarantees"]
            "the document selects no guarantee obligation, and an empty selection is never vacuously verified"
        ]
    [Normalized.NoSelfPrivilegeEscalationGuarantee path authority cases] ->
      gateValue (path, authority, cases)
    guarantees ->
      gateReasons
        ( concatMap familyReason guarantees
            <> [ UnsupportedReason
                   ["guarantees"]
                   ( "the document selects "
                       <> countText (length guarantees)
                       <> " guarantee obligations, but only a document selecting"
                       <> " exactly one NoSelfPrivilegeEscalation obligation is supported"
                   )
               | length guarantees > 1
               ]
        )
  where
    familyReason guarantee =
      case guarantee of
        Normalized.AuthenticatedMutationGuarantee path ->
          [ reasonAt path
              "the AuthenticatedMutation guarantee family is not supported by the verifier"
          ]
        Normalized.TenantIsolationGuarantee path _ _ ->
          [ reasonAt path
              "the TenantIsolation guarantee family is not supported by the verifier"
          ]
        Normalized.NoSelfPrivilegeEscalationGuarantee {} -> []

countText :: Int -> Text
countText = Text.pack . show

-- | Phase 2: the shared authority facts, then every case independently
-- (in authored order, all of them), then the plan.
obligationPlan
  :: Normalized.Model
  -> SourcePath
  -> Normalized.Authority
  -> NonEmpty Normalized.EscalationCase
  -> Gate NspeSupportPlan
obligationPlan model guaranteePath authority cases =
  authorityFacts model authority
    `gateThen` \facts ->
      casePlans model facts cases
        `gateThen` \plans ->
          gateValue (assemblePlan model guaranteePath facts plans)

-- | Every authored case, classified independently and kept in
-- authored order: the case at position 0 first, and every finding of
-- every case reported — no head-only selection, no dropping, no
-- reordering, no deduplication.
casePlans
  :: Normalized.Model
  -> AuthorityFacts
  -> NonEmpty Normalized.EscalationCase
  -> Gate (NonEmpty NspeCasePlan)
casePlans model facts (firstCase :| moreCases) =
  gateMap
    (uncurry (:|))
    ( gateBoth
        (classifyCase model facts 0 firstCase)
        (gateAll [classifyCase model facts position c | (position, c) <- zip [1 ..] moreCases])
    )

-- | The authority-side facts the deep checks depend on.
data AuthorityFacts = AuthorityFacts
  { factRelation :: Normalized.Relation
  , factSubjectEndpoint :: Normalized.Endpoint
  , factSubjectEntity :: Normalized.Entity
  , factUserEntity :: EntityId
    -- ^ The distinguished @User@ identity the normalized model
    -- carries, validated (before these facts exist) to be exactly the
    -- subject entity's canonical identity; every @Actor@ term is
    -- compared against this anchor.
  , factScopeEndpoint :: Normalized.Endpoint
  , factScopeEntity :: Normalized.Entity
  , factAbsenceLevel :: AbsenceLevel
  , factEnum :: Normalized.EnumDefinition
  , factRankBottom :: PlanRankedMember
  , factRankTop :: PlanRankedMember
  , factRanking :: [PlanRankedMember]
  }

authorityFacts :: Normalized.Model -> Normalized.Authority -> Gate AuthorityFacts
authorityFacts model authority =
  lookupRelation model (Normalized.authorityRelation authority)
    `gateThen` \relation ->
      declaredEndpointChecks relation `gateThen` \() ->
      case Normalized.authorityScopeEndpoint authority of
        Nothing ->
          gateReasons
            [ reasonAt
                (Normalized.authorityPath authority)
                "the authority names no scope endpoint, but the supported proof rule requires exactly one"
            ]
        Just scopeRef ->
          gateBoth
            ( lookupEndpoint relation (refPath (Normalized.authoritySubjectEndpoint authority))
                (refTarget (Normalized.authoritySubjectEndpoint authority))
                `gateThen` \subjectEndpoint ->
                  lookupEntity model (Normalized.endpointEntity subjectEndpoint)
                    `gateThen` \subjectEntity ->
                      distinguishedUserCheck subjectEntity
                        `gateThen` \() ->
                          gateValue (subjectEndpoint, subjectEntity)
            )
            ( lookupEndpoint relation (refPath scopeRef) (refTarget scopeRef)
                `gateThen` \scopeEndpoint ->
                  lookupEntity model (Normalized.endpointEntity scopeEndpoint)
                    `gateThen` \scopeEntity ->
                      gateValue (scopeEndpoint, scopeEntity)
            )
            `gateThen` \((subjectEndpoint, subjectEntity), (scopeEndpoint, scopeEntity)) ->
              distinctnessCheck subjectEndpoint scopeEndpoint
                `gateThen` \() ->
                  scopeEntityCheck scopeRef subjectEntity scopeEntity
                    `gateThen` \() ->
                      payloadEnum relation authority
                        `gateThen` \enumDefinition ->
                          materializedRanking authority enumDefinition
                            `gateThen` \(rankBottom, rankTop, ranking) ->
                              gateValue
                                AuthorityFacts
                                  { factRelation = relation
                                  , factSubjectEndpoint = subjectEndpoint
                                  , factSubjectEntity = subjectEntity
                                  , factUserEntity = Normalized.modelUserEntity model
                                  , factScopeEndpoint = scopeEndpoint
                                  , factScopeEntity = scopeEntity
                                  , factAbsenceLevel =
                                      sourcedValue (Normalized.authorityAbsenceLevel authority)
                                  , factEnum = enumDefinition
                                  , factRankBottom = rankBottom
                                  , factRankTop = rankTop
                                  , factRanking = ranking
                                  }
  where
    -- The semantic anchor (module header): the canonically validated
    -- subject entity must be exactly the distinguished @User@ identity
    -- the normalized model carries.  Anything else is forged or
    -- drifted evidence — an invariant violation anchored where the
    -- typechecker states the same judgment, the authority's subject
    -- endpoint reference — and no facts are constructed from it.
    distinguishedUserCheck subjectEntity =
      if Normalized.entityId subjectEntity == Normalized.modelUserEntity model
        then gateValue ()
        else
          gateInvariant
            ( invariantAt
                (refPath (Normalized.authoritySubjectEndpoint authority))
                "the authority's subject entity is not the distinguished User entity the normalized model carries"
            )

    distinctnessCheck subjectEndpoint scopeEndpoint =
      if Normalized.endpointId subjectEndpoint == Normalized.endpointId scopeEndpoint
        then
          gateInvariant
            ( invariantAt
                (Normalized.authorityPath authority)
                "the authority's subject and scope endpoints are not distinct"
            )
        else gateUnit [] []

    scopeEntityCheck scopeRef subjectEntity scopeEntity =
      gateUnit
        [ reasonAt
            (refPath scopeRef)
            "the scope endpoint references the same entity as the subject endpoint, which the supported proof rule does not cover"
        | Normalized.entityId scopeEntity == Normalized.entityId subjectEntity
        ]
        []

    payloadEnum relation auth =
      case Normalized.relationPayload relation of
        Normalized.EnumPayloadType _ payloadRef
          | refTarget payloadRef == refTarget (Normalized.authorityPayloadOrder auth) ->
              lookupEnum model (Normalized.authorityPayloadOrder auth)
        _ ->
          gateInvariant
            ( invariantAt
                (refPath (Normalized.authorityPayloadOrder auth))
                "the authority payload order does not name the authority relation's enum payload"
            )

    -- The declared name of a ranked member, resolved through the
    -- already-canonicalized declaration list — with an explicit
    -- invariant failure, never a fail-open default: a ranked identity
    -- that resolves to no declared member is forged evidence, and no
    -- plan is constructed and nothing is generated from it.
    rankedMemberName enumDefinition ref =
      case
        [ sourcedValue (Normalized.enumMemberName member)
        | member <- NonEmpty.toList (Normalized.enumDefinitionValues enumDefinition)
        , Normalized.enumMemberId member == refTarget ref
        ]
      of
        name : _ -> gateValue name
        [] ->
          gateInvariant
            ( invariantAt
                (refPath ref)
                "this ranked value references a member the authority enum does not declare"
            )

    materializedRanking auth enumDefinition =
      declaredMemberChecks enumDefinition `gateThen` \() ->
        case Normalized.enumDefinitionOrder enumDefinition of
          Nothing ->
            gateInvariant
              ( invariantAt
                  (refPath (Normalized.authorityPayloadOrder auth))
                  "the authority enum carries no materialized ranking"
              )
          Just order ->
            let ranking = NonEmpty.toList (Normalized.enumOrderRanking order)
                values = NonEmpty.toList (Normalized.enumDefinitionValues enumDefinition)
                rankedTargets =
                  map (refTarget . Normalized.rankedValueMember) ranking
                -- The canonical declaration identities, as established
                -- by 'declaredMemberChecks' — pairwise distinct by
                -- construction, so they are a trusted comparison
                -- basis independent of any stored member field.
                canonicalIds =
                  [ EnumValueId (Normalized.enumDefinitionId enumDefinition) position
                  | position <- [0 .. length values - 1]
                  ]
                -- The materialized ranking must be exactly equal, as
                -- an unordered identity collection, to the canonical
                -- declaration identities: equal cardinality, and each
                -- canonical identity ranked exactly once — which,
                -- with the canonical list distinct and the lengths
                -- equal, leaves no slot for a duplicate, missing,
                -- foreign, nonexistent, or additional ranking
                -- identity — and every stored rank must equal its
                -- position.  Ranking order may still legitimately
                -- differ from declaration order: the ranking is the
                -- separately authored enum order.
                consistent =
                  and
                    [ Normalized.rankedValueRank ranked == position
                    | (position, ranked) <- zip [0 ..] ranking
                    ]
                    && length rankedTargets == length canonicalIds
                    && all
                      ( \canonical ->
                          length (filter (== canonical) rankedTargets) == 1
                      )
                      canonicalIds
             in if not consistent
                  then
                    gateInvariant
                      ( invariantAt
                          (refPath (Normalized.authorityPayloadOrder auth))
                          "the authority enum's ranking is not a consistently materialized complete permutation"
                      )
                  else case ranking of
                    -- The two-value case the rule supports: the
                    -- bottom is rank 0 and the top — the privilege
                    -- floor — is rank 1, each carrying its validated
                    -- rank, canonical identity, and declared name.
                    -- This is the one place the floor member and its
                    -- numeric rank are identified.
                    [bottom, top] ->
                      gateBoth
                        (rankedMemberName enumDefinition (Normalized.rankedValueMember bottom))
                        (rankedMemberName enumDefinition (Normalized.rankedValueMember top))
                        `gateThen` \(bottomName, topName) ->
                          let bottomMember =
                                PlanRankedMember
                                  { planRankedRank = Normalized.rankedValueRank bottom
                                  , planRankedId = refTarget (Normalized.rankedValueMember bottom)
                                  , planRankedName = bottomName
                                  }
                              topMember =
                                PlanRankedMember
                                  { planRankedRank = Normalized.rankedValueRank top
                                  , planRankedId = refTarget (Normalized.rankedValueMember top)
                                  , planRankedName = topName
                                  }
                           in gateValue (bottomMember, topMember, [bottomMember, topMember])
                    _ ->
                      gateReasons
                        [ reasonAt
                            (refPath (Normalized.authorityPayloadOrder auth))
                            ( "the authority enum declares "
                                <> countText (length ranking)
                                <> " ranked values, but only a two-value ordered enum is supported"
                            )
                        ]

--------------------------------------------------------------------
-- Per-case classification
--------------------------------------------------------------------

-- | Phase 3, per case: resolve and preflight the case action, check
-- the rule-independent prerequisites (principal mode, the effect
-- family), select the one candidate rule by declared arity, and run
-- that rule's exact matcher.
classifyCase
  :: Normalized.Model
  -> AuthorityFacts
  -> Int
  -> Normalized.EscalationCase
  -> Gate NspeCasePlan
classifyCase model facts position escalationCase =
  lookupAction model (Normalized.escalationCaseAction escalationCase)
    `gateThen` \action ->
      declaredParameterChecks action
        `gateThen` \() ->
          caseFacts facts position escalationCase action

-- | The case action's principal mode and effect family are required
-- identically by both rules and are checked first; the declared
-- parameter count then selects the candidate rule (three parameters:
-- rule 1; two parameters: rule 2; anything else matches neither).
caseFacts
  :: AuthorityFacts
  -> Int
  -> Normalized.EscalationCase
  -> Normalized.Action
  -> Gate NspeCasePlan
caseFacts facts position escalationCase action =
  case Normalized.actionBody action of
    Normalized.AnyPrincipalBody _ _ ->
      gateReasons
        [ reasonAt
            (Normalized.actionPath action)
            "the case action's principal mode is not AuthenticatedOnly, which the supported proof rule requires"
        ]
    Normalized.AuthenticatedOnlyBody allow shape ->
      supportedEffect facts action shape
        `gateThen` \(bindings, payloadTerm) ->
          case Normalized.actionParameters action of
            [subjectParam, scopeParam, payloadParam] ->
              changeOtherCase
                facts
                position
                escalationCase
                action
                allow
                bindings
                payloadTerm
                (subjectParam, scopeParam, payloadParam)
            [scopeParam, payloadParam] ->
              boundedSelfUpdateCase
                facts
                position
                escalationCase
                action
                allow
                bindings
                payloadTerm
                (scopeParam, payloadParam)
            parameters ->
              gateReasons
                [ reasonAt
                    (Normalized.actionPath action)
                    ( "the case action declares "
                        <> countText (length parameters)
                        <> (if length parameters == 1 then " parameter" else " parameters")
                        <> ", but the supported proof rules require exactly"
                        <> " three (subject, scope, and payload; the change-other rule)"
                        <> " or exactly two (scope and payload; the bounded self-update"
                        <> " rule), in that order"
                    )
                ]

-- | The effect must be a @SetRelation@ on the authority relation
-- (required identically by both rules).
supportedEffect
  :: AuthorityFacts
  -> Normalized.Action
  -> Normalized.ActionShape 'ActorAvailable
  -> Gate
       ( OneOrTwo (Normalized.EndpointBinding 'ActorAvailable)
       , Normalized.ValueTerm 'ActorAvailable
       )
supportedEffect facts action shape =
  case shape of
    Normalized.MutationShape
      (Normalized.SetRelationEffect _ relationRef bindings payloadTerm)
      _resultPath ->
        if refTarget relationRef == Normalized.relationId (factRelation facts)
          then gateValue (bindings, payloadTerm)
          else
            gateReasons
              [ reasonAt
                  (refPath relationRef)
                  "the SetRelation effect writes a relation other than the authority relation"
              ]
    _ ->
      gateReasons
        [ reasonAt
            (Normalized.actionPath action)
            "the case action's effect is not a SetRelation on the authority relation, which the supported proof rule requires"
        ]

--------------------------------------------------------------------
-- Rule 1: change-other
--------------------------------------------------------------------

-- | The exact rule-1 matcher over a three-parameter case action:
-- parameter types, effect bindings, the allow conjunction, and the
-- case scope binding, in that order.
changeOtherCase
  :: AuthorityFacts
  -> Int
  -> Normalized.EscalationCase
  -> Normalized.Action
  -> Normalized.PolicyTerm 'ActorAvailable
  -> OneOrTwo (Normalized.EndpointBinding 'ActorAvailable)
  -> Normalized.ValueTerm 'ActorAvailable
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> Gate NspeCasePlan
changeOtherCase facts position escalationCase action allow bindings payloadTerm params =
  changeOtherParameters facts params
    `gateThen` \(subjectParam, scopeParam, payloadParam) ->
      changeOtherBindingChecks facts params bindings payloadTerm
        `gateThen` \() ->
          changeOtherPolicyChecks facts params allow
            `gateThen` \() ->
              caseScopeCheck facts scopeParam escalationCase
                `gateThen` \() ->
                  gateValue
                    NspeCasePlan
                      { casePosition = position
                      , casePath = Normalized.escalationCasePath escalationCase
                      , caseActionId = Normalized.actionId action
                      , caseActionName = Normalized.actionName action
                      , caseScopeParameterId = Normalized.parameterId scopeParam
                      , caseScopeParameterName = Normalized.parameterName scopeParam
                      , casePayloadParameterId = Normalized.parameterId payloadParam
                      , casePayloadParameterName = Normalized.parameterName payloadParam
                      , caseScopeBinding = bindingOf (factScopeEndpoint facts) scopeParam
                      , caseMatch =
                          ChangeOtherMatch
                            ChangeOtherFacts
                              { changeOtherSubjectParameterId = Normalized.parameterId subjectParam
                              , changeOtherSubjectParameterName = Normalized.parameterName subjectParam
                              , changeOtherEffectBindings =
                                  [ bindingOf (factSubjectEndpoint facts) subjectParam
                                  , bindingOf (factScopeEndpoint facts) scopeParam
                                  ]
                              }
                      }

-- | Rule 1: the three parameters — subject, scope, payload, in order
-- — at the authority's types.
changeOtherParameters
  :: AuthorityFacts
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> Gate
       ( Normalized.Parameter
       , Normalized.Parameter
       , Normalized.Parameter
       )
changeOtherParameters facts (subjectParam, scopeParam, payloadParam) =
  let typeReasons =
        [ reasonAt
            (Normalized.parameterPath subjectParam)
            "the first parameter must have the entity-reference type of the authority's subject endpoint"
        | parameterStaticType (Normalized.parameterType subjectParam)
            /= EntityRefType (Normalized.entityId (factSubjectEntity facts))
        ]
          <> [ reasonAt
                 (Normalized.parameterPath scopeParam)
                 "the second parameter must have the entity-reference type of the authority's scope endpoint"
             | parameterStaticType (Normalized.parameterType scopeParam)
                 /= EntityRefType (Normalized.entityId (factScopeEntity facts))
             ]
          <> [ reasonAt
                 (Normalized.parameterPath payloadParam)
                 "the third parameter must have the authority enum's type"
             | parameterStaticType (Normalized.parameterType payloadParam)
                 /= EnumType (Normalized.enumDefinitionId (factEnum facts))
             ]
   in -- A wrongly typed parameter list suppresses every
      -- parameter-dependent check rather than cascading.
      if null typeReasons
        then gateValue (subjectParam, scopeParam, payloadParam)
        else gateReasons typeReasons

-- | Rule 1: the effect must bind subject ↦ subject parameter, scope ↦
-- scope parameter, payload ↦ payload parameter.
changeOtherBindingChecks
  :: AuthorityFacts
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> OneOrTwo (Normalized.EndpointBinding 'ActorAvailable)
  -> Normalized.ValueTerm 'ActorAvailable
  -> Gate ()
changeOtherBindingChecks facts (subjectParam, scopeParam, payloadParam) bindings payloadTerm =
  bindingPair facts bindings
    `gateThen` \(subjectBinding, scopeBinding) ->
      argumentTermCheck
        facts
        (Normalized.endpointBindingTerm subjectBinding)
        subjectParam
        (EntityRefType (Normalized.entityId (factSubjectEntity facts)))
        "the SetRelation effect must bind the authority's subject endpoint to exactly the subject parameter"
        `gateThen` \() ->
          argumentTermCheck
            facts
            (Normalized.endpointBindingTerm scopeBinding)
            scopeParam
            (EntityRefType (Normalized.entityId (factScopeEntity facts)))
            "the SetRelation effect must bind the authority's scope endpoint to exactly the scope parameter"
            `gateThen` \() ->
              payloadTermCheck facts payloadTerm payloadParam

-- | Both rules: the @SetRelation@ payload must be exactly the payload
-- parameter.
payloadTermCheck
  :: AuthorityFacts
  -> Normalized.ValueTerm 'ActorAvailable
  -> Normalized.Parameter
  -> Gate ()
payloadTermCheck facts payloadTerm payloadParam =
  argumentTermCheck
    facts
    payloadTerm
    payloadParam
    (EnumType (Normalized.enumDefinitionId (factEnum facts)))
    "the SetRelation payload must be exactly the payload parameter"

-- | Split a two-endpoint binding list into (subject, scope) by
-- stored endpoint identity; any other constellation is a forged
-- binding-set inconsistency.
bindingPair
  :: AuthorityFacts
  -> OneOrTwo (Normalized.EndpointBinding availability)
  -> Gate
       ( Normalized.EndpointBinding availability
       , Normalized.EndpointBinding availability
       )
bindingPair facts bindings =
  case bindings of
    Two first second
      | Normalized.endpointBindingEndpoint first == subjectId
      , Normalized.endpointBindingEndpoint second == scopeId ->
          gateValue (first, second)
      | Normalized.endpointBindingEndpoint first == scopeId
      , Normalized.endpointBindingEndpoint second == subjectId ->
          gateValue (second, first)
    _ ->
      gateInvariant
        ( invariantAt
            (Normalized.relationPath (factRelation facts))
            "an endpoint-binding list of the authority relation does not bind exactly its subject and scope endpoints"
        )
  where
    subjectId = Normalized.endpointId (factSubjectEndpoint facts)
    scopeId = Normalized.endpointId (factScopeEndpoint facts)

-- | The term must be exactly a reference to the given parameter; the
-- stored type must agree with the parameter's declared type (drift is
-- a forged-evidence invariant, never an authored shape).
argumentTermCheck
  :: AuthorityFacts
  -> Normalized.ValueTerm 'ActorAvailable
  -> Normalized.Parameter
  -> ValueType
  -> Text
  -> Gate ()
argumentTermCheck _facts term parameter expectedType message =
  case Normalized.valueTermNode term of
    Normalized.ArgumentNode parameterRef
      | refTarget parameterRef == Normalized.parameterId parameter ->
          if Normalized.valueTermType term /= expectedType
            then
              gateInvariant
                ( invariantAt
                    (Normalized.valueTermPath term)
                    "the stored static type of this parameter reference has drifted from the parameter's declared type"
                )
            else gateUnit [] []
      | parameterOwner (refTarget parameterRef)
          /= parameterOwner (Normalized.parameterId parameter) ->
          gateInvariant
            ( invariantAt
                (Normalized.valueTermPath term)
                "this parameter reference belongs to a different action than the case action, which the typechecker cannot have accepted"
            )
    _ -> gateUnit [reasonAt (Normalized.valueTermPath term) message] []
  where
    parameterOwner (ParameterId owner _) = owner

-- | Every proof-relevant stored policy-type annotation the supported
-- shape visits must be exactly the type that shape assigns to its
-- position; any other stored annotation is forged or drifted
-- evidence, which the typechecker cannot have produced.  Validated
-- against the already-resolved declarations and the exact supported
-- shape — no type is inferred and no second typechecker exists.
policyTypeCheck
  :: PolicyType -> Normalized.PolicyTerm 'ActorAvailable -> Gate ()
policyTypeCheck expected term =
  gateUnit
    []
    [ invariantAt
        (Normalized.policyTermPath term)
        "the stored static type of this policy term has drifted from the type the supported proof shape requires"
    | Normalized.policyTermType term /= expected
    ]

-- | The value-term counterpart of 'policyTypeCheck'.  (Parameter
-- references are covered by 'argumentTermCheck' against their
-- parameter's declared type; this check covers the remaining
-- proof-relevant value terms of the supported shape.)
valueTypeCheck
  :: ValueType -> Normalized.ValueTerm 'ActorAvailable -> Gate ()
valueTypeCheck expected term =
  gateUnit
    []
    [ invariantAt
        (Normalized.valueTermPath term)
        "the stored static type of this value term has drifted from the type the supported proof shape requires"
    | Normalized.valueTermType term /= expected
    ]

-- | The stored ordered-comparison evidence of a rule's @LessOrEqual@
-- must be exactly the absence-as-bottom optional ordering of the
-- authority enum; anything else is drifted evidence the typechecker
-- cannot have produced.
orderedEvidenceCheck :: AuthorityFacts -> SourcePath -> OrderedType -> Gate ()
orderedEvidenceCheck facts path ordered =
  if ordered /= OptionalEnumOrderedType (Normalized.enumDefinitionId (factEnum facts))
    then
      gateInvariant
        ( invariantAt
            path
            "the stored ordered-comparison evidence has drifted from the absence-as-bottom optional ordering of the authority enum"
        )
    else gateValue ()

-- | Rule 1: the allow policy must be exactly the supported
-- conjunction; see the module header.
changeOtherPolicyChecks
  :: AuthorityFacts
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> Normalized.PolicyTerm 'ActorAvailable
  -> Gate ()
changeOtherPolicyChecks facts (subjectParam, scopeParam, _payloadParam) allow =
  case Normalized.policyTermNode allow of
    Normalized.AndNode firstConjunct rest ->
      case Normalized.policyTermNode rest of
        Normalized.AndNode guardConjunct thirdConjunct ->
          boolPolicyCheck allow
            `gateThen` \() ->
              boolPolicyCheck rest
                `gateThen` \() ->
                  floorCheck firstConjunct
                    `gateThen` \() ->
                      guardCheck guardConjunct
                        `gateThen` \() ->
                          membershipCheck thirdConjunct
        _ ->
          gateReasons
            [ reasonAt
                (Normalized.policyTermPath rest)
                "the second operand of the allow policy must itself be the conjunction And(actor/subject guard, subject membership)"
            ]
    _ ->
      gateReasons
        [ reasonAt
            (Normalized.policyTermPath allow)
            "the allow policy is not the supported conjunction And(privilege floor, And(actor/subject guard, subject membership))"
        ]
  where
    -- The exact stored types the supported shape assigns: every
    -- connective and comparison is Bool, both lookups and the lifted
    -- floor value are optional at the authority enum, and both guard
    -- equality operands are references to the subject entity.
    boolPolicyCheck = policyTypeCheck (ValuePolicyType BoolType)

    optionalAuthorityEnumType =
      OptionalPolicyType
        (EnumType (Normalized.enumDefinitionId (factEnum facts)))

    subjectReferencePolicyType =
      ValuePolicyType
        (EntityRefType (Normalized.entityId (factSubjectEntity facts)))

    floorMessage =
      "the first conjunct must be LessOrEqual(Some(top authority value),\
      \ Lookup(authority relation, [Actor, scope parameter])) at the\
      \ absence-as-bottom optional ordering of the authority enum"

    floorCheck conjunct =
      case Normalized.policyTermNode conjunct of
        Normalized.LessOrEqualNode ordered left right
          | Normalized.SomeNode someValue <- Normalized.policyTermNode left
          , Normalized.EnumNode enumRef valueRef <-
              Normalized.valueTermNode someValue
          , Normalized.LookupNode lookupRelationRef lookupBindings <-
              Normalized.policyTermNode right
          , refTarget lookupRelationRef
              == Normalized.relationId (factRelation facts) ->
              boolPolicyCheck conjunct
                `gateThen` \() ->
                  policyTypeCheck optionalAuthorityEnumType left
                    `gateThen` \() ->
                      valueTypeCheck
                        (EnumType (Normalized.enumDefinitionId (factEnum facts)))
                        someValue
                        `gateThen` \() ->
                          policyTypeCheck optionalAuthorityEnumType right
                            `gateThen` \() ->
                              bindingPair facts lookupBindings
                                `gateThen` \(subjectBinding, scopeBinding) ->
                                  actorTermCheck facts (Normalized.endpointBindingTerm subjectBinding) floorMessage
                                    `gateThen` \() ->
                                      argumentTermCheck
                                        facts
                                        (Normalized.endpointBindingTerm scopeBinding)
                                        scopeParam
                                        (EntityRefType (Normalized.entityId (factScopeEntity facts)))
                                        floorMessage
                                        `gateThen` \() ->
                                          enumEvidenceCheck enumRef valueRef ordered
        _ ->
          gateReasons [reasonAt (Normalized.policyTermPath conjunct) floorMessage]

    enumEvidenceCheck enumRef valueRef ordered =
      let enumIdentity = Normalized.enumDefinitionId (factEnum facts)
       in if refTarget enumRef /= enumIdentity
            then
              gateInvariant
                ( invariantAt
                    (refPath enumRef)
                    "the compared privilege-floor value belongs to an enum other than the authority enum, which the typechecker cannot have accepted"
                )
            else
              orderedEvidenceCheck facts (refPath enumRef) ordered
                `gateThen` \() ->
                  gateUnit
                    [ reasonAt
                        (refPath valueRef)
                        "the compared privilege floor is not the top-ranked value of the authority enum, which the supported proof rule requires"
                    | refTarget valueRef /= planRankedId (factRankTop facts)
                    ]
                    []

    guardCheck conjunct =
      let guardMessage =
            "the guard conjunct must be exactly Not(Equal(Actor, subject\
            \ parameter)); the mechanized proof rule rests on this\
            \ actor/subject disequality"
       in case Normalized.policyTermNode conjunct of
            Normalized.NotNode negated
              | Normalized.EqualNode equalLeft equalRight <-
                  Normalized.policyTermNode negated
              , Normalized.ValuePolicyNode actorSide <-
                  Normalized.policyTermNode equalLeft
              , Normalized.ValuePolicyNode subjectSide <-
                  Normalized.policyTermNode equalRight ->
                  boolPolicyCheck conjunct
                    `gateThen` \() ->
                      boolPolicyCheck negated
                        `gateThen` \() ->
                          policyTypeCheck subjectReferencePolicyType equalLeft
                            `gateThen` \() ->
                              policyTypeCheck subjectReferencePolicyType equalRight
                                `gateThen` \() ->
                                  actorTermCheck facts actorSide guardMessage
                                    `gateThen` \() ->
                                      argumentTermCheck
                                        facts
                                        subjectSide
                                        subjectParam
                                        (EntityRefType (Normalized.entityId (factSubjectEntity facts)))
                                        guardMessage
            _ ->
              gateReasons [reasonAt (Normalized.policyTermPath conjunct) guardMessage]

    membershipCheck conjunct =
      let membershipMessage =
            "the final conjunct must be IsSome(Lookup(authority relation,\
            \ [subject parameter, scope parameter]))"
       in case Normalized.policyTermNode conjunct of
            Normalized.IsSomeNode inner
              | Normalized.LookupNode lookupRelationRef lookupBindings <-
                  Normalized.policyTermNode inner
              , refTarget lookupRelationRef
                  == Normalized.relationId (factRelation facts) ->
                  boolPolicyCheck conjunct
                    `gateThen` \() ->
                      policyTypeCheck optionalAuthorityEnumType inner
                        `gateThen` \() ->
                          bindingPair facts lookupBindings
                            `gateThen` \(subjectBinding, scopeBinding) ->
                              argumentTermCheck
                                facts
                                (Normalized.endpointBindingTerm subjectBinding)
                                subjectParam
                                (EntityRefType (Normalized.entityId (factSubjectEntity facts)))
                                membershipMessage
                                `gateThen` \() ->
                                  argumentTermCheck
                                    facts
                                    (Normalized.endpointBindingTerm scopeBinding)
                                    scopeParam
                                    (EntityRefType (Normalized.entityId (factScopeEntity facts)))
                                    membershipMessage
            _ ->
              gateReasons
                [reasonAt (Normalized.policyTermPath conjunct) membershipMessage]

--------------------------------------------------------------------
-- Rule 2: bounded self-update
--------------------------------------------------------------------

-- | The exact rule-2 matcher over a two-parameter case action:
-- parameter types, effect bindings, the single allow comparison, and
-- the case scope binding, in that order.
boundedSelfUpdateCase
  :: AuthorityFacts
  -> Int
  -> Normalized.EscalationCase
  -> Normalized.Action
  -> Normalized.PolicyTerm 'ActorAvailable
  -> OneOrTwo (Normalized.EndpointBinding 'ActorAvailable)
  -> Normalized.ValueTerm 'ActorAvailable
  -> (Normalized.Parameter, Normalized.Parameter)
  -> Gate NspeCasePlan
boundedSelfUpdateCase facts position escalationCase action allow bindings payloadTerm params =
  boundedSelfUpdateParameters facts params
    `gateThen` \(scopeParam, payloadParam) ->
      boundedSelfUpdateBindingChecks facts params bindings payloadTerm
        `gateThen` \() ->
          boundedSelfUpdatePolicyChecks facts params allow
            `gateThen` \() ->
              caseScopeCheck facts scopeParam escalationCase
                `gateThen` \() ->
                  gateValue
                    NspeCasePlan
                      { casePosition = position
                      , casePath = Normalized.escalationCasePath escalationCase
                      , caseActionId = Normalized.actionId action
                      , caseActionName = Normalized.actionName action
                      , caseScopeParameterId = Normalized.parameterId scopeParam
                      , caseScopeParameterName = Normalized.parameterName scopeParam
                      , casePayloadParameterId = Normalized.parameterId payloadParam
                      , casePayloadParameterName = Normalized.parameterName payloadParam
                      , caseScopeBinding = bindingOf (factScopeEndpoint facts) scopeParam
                      , caseMatch =
                          BoundedSelfUpdateMatch
                            BoundedSelfUpdateFacts
                              { selfUpdateEffectScopeBinding =
                                  bindingOf (factScopeEndpoint facts) scopeParam
                              }
                      }

-- | Rule 2: the two parameters — scope, payload, in order — at the
-- authority's types.
boundedSelfUpdateParameters
  :: AuthorityFacts
  -> (Normalized.Parameter, Normalized.Parameter)
  -> Gate (Normalized.Parameter, Normalized.Parameter)
boundedSelfUpdateParameters facts (scopeParam, payloadParam) =
  let typeReasons =
        [ reasonAt
            (Normalized.parameterPath scopeParam)
            "the first parameter of a bounded self-update case action must have the entity-reference type of the authority's scope endpoint"
        | parameterStaticType (Normalized.parameterType scopeParam)
            /= EntityRefType (Normalized.entityId (factScopeEntity facts))
        ]
          <> [ reasonAt
                 (Normalized.parameterPath payloadParam)
                 "the second parameter of a bounded self-update case action must have the authority enum's type"
             | parameterStaticType (Normalized.parameterType payloadParam)
                 /= EnumType (Normalized.enumDefinitionId (factEnum facts))
             ]
   in if null typeReasons
        then gateValue (scopeParam, payloadParam)
        else gateReasons typeReasons

-- | Rule 2: the effect must bind subject ↦ @Actor@, scope ↦ scope
-- parameter, payload ↦ payload parameter.
boundedSelfUpdateBindingChecks
  :: AuthorityFacts
  -> (Normalized.Parameter, Normalized.Parameter)
  -> OneOrTwo (Normalized.EndpointBinding 'ActorAvailable)
  -> Normalized.ValueTerm 'ActorAvailable
  -> Gate ()
boundedSelfUpdateBindingChecks facts (scopeParam, payloadParam) bindings payloadTerm =
  bindingPair facts bindings
    `gateThen` \(subjectBinding, scopeBinding) ->
      actorTermCheck
        facts
        (Normalized.endpointBindingTerm subjectBinding)
        "the SetRelation effect of a bounded self-update case action must bind the authority's subject endpoint to exactly Actor"
        `gateThen` \() ->
          argumentTermCheck
            facts
            (Normalized.endpointBindingTerm scopeBinding)
            scopeParam
            (EntityRefType (Normalized.entityId (factScopeEntity facts)))
            "the SetRelation effect of a bounded self-update case action must bind the authority's scope endpoint to exactly the scope parameter"
            `gateThen` \() ->
              payloadTermCheck facts payloadTerm payloadParam

-- | Rule 2: the allow policy must be exactly the single comparison
-- @LessOrEqual(Some(payload parameter), Lookup(authority, [Actor,
-- scope parameter]))@ at the absence-as-bottom optional ordering of
-- the authority enum — no conjunction around it, no explicit
-- @IsSome@, no other operand.
boundedSelfUpdatePolicyChecks
  :: AuthorityFacts
  -> (Normalized.Parameter, Normalized.Parameter)
  -> Normalized.PolicyTerm 'ActorAvailable
  -> Gate ()
boundedSelfUpdatePolicyChecks facts (scopeParam, payloadParam) allow =
  case Normalized.policyTermNode allow of
    Normalized.LessOrEqualNode ordered left right
      | Normalized.SomeNode someValue <- Normalized.policyTermNode left
      , Normalized.LookupNode lookupRelationRef lookupBindings <-
          Normalized.policyTermNode right
      , refTarget lookupRelationRef
          == Normalized.relationId (factRelation facts) ->
          policyTypeCheck (ValuePolicyType BoolType) allow
            `gateThen` \() ->
              policyTypeCheck optionalAuthorityEnumType left
                `gateThen` \() ->
                  argumentTermCheck
                    facts
                    someValue
                    payloadParam
                    (EnumType (Normalized.enumDefinitionId (factEnum facts)))
                    boundMessage
                    `gateThen` \() ->
                      policyTypeCheck optionalAuthorityEnumType right
                        `gateThen` \() ->
                          bindingPair facts lookupBindings
                            `gateThen` \(subjectBinding, scopeBinding) ->
                              actorTermCheck facts (Normalized.endpointBindingTerm subjectBinding) boundMessage
                                `gateThen` \() ->
                                  argumentTermCheck
                                    facts
                                    (Normalized.endpointBindingTerm scopeBinding)
                                    scopeParam
                                    (EntityRefType (Normalized.entityId (factScopeEntity facts)))
                                    boundMessage
                                    `gateThen` \() ->
                                      orderedEvidenceCheck facts (Normalized.policyTermPath allow) ordered
    _ ->
      gateReasons [reasonAt (Normalized.policyTermPath allow) boundMessage]
  where
    optionalAuthorityEnumType =
      OptionalPolicyType
        (EnumType (Normalized.enumDefinitionId (factEnum facts)))

    boundMessage =
      "the allow policy of a bounded self-update case action must be exactly\
      \ LessOrEqual(Some(payload parameter), Lookup(authority relation,\
      \ [Actor, scope parameter])) at the absence-as-bottom optional\
      \ ordering of the authority enum, with no further conjunct"

--------------------------------------------------------------------
-- Shared checks and plan assembly
--------------------------------------------------------------------

-- | The term must be exactly the implicit authenticated principal,
-- denoting the distinguished @User@ entity — compared against the
-- independently anchored identity ('factUserEntity', validated equal
-- to the authority's subject entity before the facts existed), never
-- against another term of the same case.
actorTermCheck
  :: AuthorityFacts
  -> Normalized.ValueTerm 'ActorAvailable
  -> Text
  -> Gate ()
actorTermCheck facts term message =
  case Normalized.valueTermNode term of
    Normalized.ActorNode actorEntity ->
      if actorEntity /= factUserEntity facts
        then
          gateInvariant
            ( invariantAt
                (Normalized.valueTermPath term)
                "the stored Actor entity has drifted from the authority's subject entity"
            )
        else
          valueTypeCheck
            (EntityRefType (Normalized.entityId (factSubjectEntity facts)))
            term
    _ -> gateUnit [reasonAt (Normalized.valueTermPath term) message] []

-- | Both rules: the case scope binding must bind the authority's
-- scope endpoint to exactly the scope parameter.
caseScopeCheck
  :: AuthorityFacts
  -> Normalized.Parameter
  -> Normalized.EscalationCase
  -> Gate ()
caseScopeCheck facts scopeParam escalationCase =
  case Normalized.escalationCaseScope escalationCase of
    Nothing ->
      gateInvariant
        ( invariantAt
            (Normalized.escalationCasePath escalationCase)
            "the case names no scope binding although the authority declares a scope endpoint"
        )
    Just binding ->
      if Normalized.scopeBindingEndpoint binding
        /= Normalized.endpointId (factScopeEndpoint facts)
        then
          gateInvariant
            ( invariantAt
                (Normalized.escalationCasePath escalationCase)
                "the case scope binding names an endpoint other than the authority's scope endpoint"
            )
        else
          argumentTermCheck
            facts
            (Normalized.scopeBindingTerm binding)
            scopeParam
            (EntityRefType (Normalized.entityId (factScopeEntity facts)))
            "the case scope term must be exactly the scope parameter of the case action"

-- | One verified binding of a declared endpoint to a parameter.
bindingOf :: Normalized.Endpoint -> Normalized.Parameter -> PlanBinding
bindingOf endpoint parameter =
  PlanBinding
    { planBindingEndpointId = Normalized.endpointId endpoint
    , planBindingEndpointName = sourcedValue (Normalized.endpointName endpoint)
    , planBindingParameterId = Normalized.parameterId parameter
    , planBindingParameterName = sourcedValue (Normalized.parameterName parameter)
    }

-- | Assemble the plan from the checked facts.  Every stored identity
-- and name below was validated by the preflight and the deep checks
-- above; nothing is looked up again with a fail-open default.
assemblePlan
  :: Normalized.Model
  -> SourcePath
  -> AuthorityFacts
  -> NonEmpty NspeCasePlan
  -> NspeSupportPlan
assemblePlan model guaranteePath facts cases =
  NspeSupportPlan
    { planModelName = Normalized.modelName model
    , planGuaranteePath = guaranteePath
    , planRelationId = Normalized.relationId (factRelation facts)
    , planRelationName = Normalized.relationName (factRelation facts)
    , planSubjectEndpointId = Normalized.endpointId (factSubjectEndpoint facts)
    , planSubjectEndpointName = Normalized.endpointName (factSubjectEndpoint facts)
    , planSubjectEntityId = Normalized.entityId (factSubjectEntity facts)
    , planSubjectEntityName = Normalized.entityName (factSubjectEntity facts)
    , planScopeEndpointId = Normalized.endpointId (factScopeEndpoint facts)
    , planScopeEndpointName = Normalized.endpointName (factScopeEndpoint facts)
    , planScopeEntityId = Normalized.entityId (factScopeEntity facts)
    , planScopeEntityName = Normalized.entityName (factScopeEntity facts)
    , planAbsenceLevel = factAbsenceLevel facts
    , planEnumId = Normalized.enumDefinitionId (factEnum facts)
    , planEnumName = Normalized.enumDefinitionName (factEnum facts)
    , planEnumMembers =
        [ PlanEnumMember
            { planMemberId = Normalized.enumMemberId member
            , planMemberName = Normalized.enumMemberName member
            }
        | member <- NonEmpty.toList (Normalized.enumDefinitionValues (factEnum facts))
        ]
    , planRanking = factRanking facts
    , planRankBottom = factRankBottom facts
    , planRankTop = factRankTop facts
    , planAbsentRank = absentRankOf (factAbsenceLevel facts)
    , planCases = cases
    }
  where
    -- Absence as bottom ranks strictly below every member: one below
    -- rank 0.
    absentRankOf AbsenceBottom = -1
