{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Core v0 verifier slice: the deterministic support gate over the
-- typed normalized representation, the deterministic generator of the
-- one supported Agda obligation module, and the checker-independent
-- verification orchestration.  This module is pure except for the one
-- injected 'CheckerRunner' call; the production runner — which embeds
-- the trusted Agda kernel and invokes the real Agda 2.8.0 executable
-- across a process boundary — lives in the public library
-- (@Mithril.Core.Internal.AgdaChecker@), and the public boundary is
-- exactly "Mithril.Core.Verification".
--
-- == The support rule
--
-- Exactly one obligation shape is supported: a document that selects
-- exactly one guarantee, a @NoSelfPrivilegeEscalation@ guarantee with
-- exactly one case, whose normalized evidence corresponds
-- structurally to the already-mechanized sound proof rule of the Agda
-- spike's @Mithril.Acme@ slice (the safe @Membership.changeRole@
-- shape):
--
-- * the authority relation is binary, with the subject endpoint at
--   the distinguished @User@ entity and one scope endpoint at a
--   different entity;
-- * the authority payload order is a two-value enum with a declared
--   (materialized) complete ranking, absence interpreted as bottom;
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
-- The gate inspects stored identities and evidence structurally — it
-- never compares raw JSON bytes, recognizes filenames, hashes the
-- model, reparses, re-resolves, re-infers types, or evaluates policy
-- — and it deliberately rejects semantically equivalent but
-- differently authored shapes as unsupported.
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
-- still halts as an invariant violation before generation.
--
-- Soundness of the rule: the generated module transcribes exactly
-- this shape into the trusted fixed-schema kernel and re-proves, with
-- the kernel's checked frame lemmas, that policy success forces the
-- authenticated actor's index apart from the subject parameter's, so
-- the authorized @SetRelation@ write cannot touch the actor's own
-- authority tuple in the selected scope — the actor's tuple is
-- exactly unchanged, hence never raised.  The middle guard conjunct
-- @Not(Equal(Actor, subject parameter))@ is the proof-relevant fact;
-- every other pinned piece keeps the transcription exact.  Agda
-- checks the generated module from scratch; the gate itself proves
-- nothing.
--
-- == Failure classification
--
-- Shapes a well-typed author can write but the rule does not cover
-- are 'UnsupportedReason's — deterministic, sorted, deduplicated,
-- decided before any checker runs.  Inconsistencies of the normalized
-- model that no pipeline-produced document can exhibit (dangling or
-- foreign identities, evidence drift) are
-- 'VerifierInvariantViolation's — internal tool errors.  Checker
-- problems (missing or wrong-version Agda, launch or workspace
-- failure, a nonzero check after the gate accepted, a structured
-- generated-artifact inventory missing a required theorem block) are
-- 'VerificationFailure's — tool failures,
-- never semantic verdicts.  Nothing here can ever report a
-- violation: @VIOLATED@ is reserved for a future independently
-- checked concrete witness and has no representation in this
-- vocabulary.
module Mithril.Core.Internal.Verify
  ( -- * Public result vocabulary (re-exported by Mithril.Core.Verification)
    VerificationResult (..)
  , VerifiedObligation (..)
  , UnsupportedReason (..)
  , VerificationFailure (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations

    -- * The support gate
  , SupportPlan (..)
  , PlanRefusal (..)
  , supportPlan

    -- * Deterministic generation
  , TheoremSpec (..)
  , requiredTheoremSpecs
  , requiredTheoremNames
  , GeneratedArtifact (..)
  , generatedObligationArtifact
  , renderObligationModule
  , renderedTheoremBlock
  , renderedManifestBlock
  , generatedModuleFile
  , missingRequiredTheorems
  , planObligation
  , quotedName

    -- * Checker-independent orchestration
  , CheckerRunner
  , verifyModelWith
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
-- Public result vocabulary
--------------------------------------------------------------------

-- | The two semantic outcomes of the verifier boundary.  There is
-- deliberately no violation outcome: @VIOLATED@ is reserved for a
-- future independently checked concrete witness, and this milestone
-- can never emit it — an Agda refusal after the gate accepted is a
-- tool failure ('CheckerRejected'), not a security verdict.
data VerificationResult
  = -- | Every selected obligation of the document is supported, the
    -- deterministic artifact was generated, and every required named
    -- theorem was accepted by the configured Agda 2.8.0 safe check.
    VerificationVerified VerifiedObligation
  | -- | The normalized document lies outside the implemented support
    -- rule.  Decided by the pure deterministic gate before any
    -- checker runs; the reasons are sorted and deduplicated.
    VerificationUnsupported (NonEmpty UnsupportedReason)
  deriving (Eq, Show)

-- | What a successful verification checked: the guarantee family, the
-- case action's declared name, and the exact required theorem names
-- the checker accepted.  No internal identifiers, no paths, no
-- checker output.
data VerifiedObligation = VerifiedObligation
  { verifiedGuarantee :: Text
  , verifiedCaseAction :: Text
  , verifiedTheorems :: [Text]
  }
  deriving (Eq, Ord, Show)

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

-- | Why verification could not be trusted to complete.  Every
-- constructor is a tool\/internal failure (exit status 2 at the tool
-- boundary): none is an unsupported classification and none is a
-- security verdict.
data VerificationFailure
  = -- | The normalized model is inconsistent (forged or drifted);
    -- sorted and deduplicated.
    VerifierInvariantViolations (NonEmpty VerifierInvariantViolation)
  | -- | The structured generated-artifact inventory does not carry a
    -- rendered theorem block for every required 'TheoremSpec' — a
    -- generator bug, detected before any checker runs.  (Whether each
    -- rendered theorem really exists at exactly its required type is
    -- proved by Agda through the generated module's checked manifest,
    -- never by inspecting source text; a manifest the checker cannot
    -- satisfy is a 'CheckerRejected' tool failure.)
    GeneratedTheoremsMissing (NonEmpty Text)
  | -- | The Agda checker could not be invoked at all (missing
    -- executable, process launch failure).
    CheckerUnavailable Text
  | -- | The checker launched but is not exactly Agda 2.8.0; the
    -- payload is the version line it reported.
    CheckerVersionMismatch Text
  | -- | The isolated checking workspace could not be materialized or
    -- cleaned.
    CheckerWorkspaceFailure Text
  | -- | The checker exited nonzero after the support gate accepted
    -- the document.  A compilation failure alone is never a security
    -- witness: this is a tool failure, not @VIOLATED@.  The payload
    -- is the checker's captured output.
    CheckerRejected Text
  | -- | The checker was terminated by the given signal.
    CheckerTerminatedBySignal Int
  deriving (Eq, Show)

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
-- The support plan
--------------------------------------------------------------------

-- | Everything the generator consumes, extracted structurally from
-- the normalized evidence by the support gate: resolved identities
-- plus declared-name metadata for every proof-relevant declaration of
-- the one supported obligation.  Constructing a plan attests support
-- only; nothing is verified by it.
data SupportPlan = SupportPlan
  { planModelName :: Text
  , planRelationId :: RelationId
  , planRelationName :: Text
  , planSubjectEndpointId :: EndpointId
  , planSubjectEndpointName :: Text
  , planSubjectEntityId :: EntityId
  , planSubjectEntityName :: Text
  , planScopeEndpointId :: EndpointId
  , planScopeEndpointName :: Text
  , planScopeEntityId :: EntityId
  , planScopeEntityName :: Text
  , planAbsenceLevel :: AbsenceLevel
  , planEnumId :: EnumId
  , planEnumName :: Text
  , planRankBottomId :: EnumValueId
  , planRankBottomName :: Text
  , planRankTopId :: EnumValueId
  , planRankTopName :: Text
  , planActionId :: ActionId
  , planActionName :: Text
  , planSubjectParameterId :: ParameterId
  , planSubjectParameterName :: Text
  , planScopeParameterId :: ParameterId
  , planScopeParameterName :: Text
  , planPayloadParameterId :: ParameterId
  , planPayloadParameterName :: Text
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

-- | The obligation summary of a plan, as reported on success.
planObligation :: SupportPlan -> VerifiedObligation
planObligation plan =
  VerifiedObligation
    { verifiedGuarantee = "NoSelfPrivilegeEscalation"
    , verifiedCaseAction = planActionName plan
    , verifiedTheorems = requiredTheoremNames
    }

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
-- generation plan if so.  The module header states the rule and its
-- soundness; the gate consumes stored identities and evidence only.
supportPlan :: Normalized.Model -> Either PlanRefusal SupportPlan
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
-- NoSelfPrivilegeEscalation family, with exactly one case.
selectObligation
  :: Normalized.Model
  -> Gate (SourcePath, Normalized.Authority, Normalized.EscalationCase)
selectObligation model =
  case Normalized.modelGuarantees model of
    [] ->
      gateReasons
        [ UnsupportedReason
            ["guarantees"]
            "the document selects no guarantee obligation, and an empty selection is never vacuously verified"
        ]
    [Normalized.NoSelfPrivilegeEscalationGuarantee path authority cases] ->
      case cases of
        onlyCase :| [] -> gateValue (path, authority, onlyCase)
        _ ->
          gateReasons
            [ reasonAt path
                ( "the guarantee selects "
                    <> countText (NonEmpty.length cases)
                    <> " escalation cases, but only exactly one case is supported"
                )
            ]
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

-- | Phase 2: the authority, the case, and the case action.
obligationPlan
  :: Normalized.Model
  -> SourcePath
  -> Normalized.Authority
  -> Normalized.EscalationCase
  -> Gate SupportPlan
obligationPlan model _guaranteePath authority onlyCase =
  authorityFacts model authority
    `gateThen` \facts ->
      lookupAction model (Normalized.escalationCaseAction onlyCase)
        `gateThen` \action ->
          declaredParameterChecks action
            `gateThen` \() ->
              actionFacts model facts onlyCase action
                `gateThen` \params ->
                  gateValue (assemblePlan model facts action params)

-- | The authority-side facts the deep checks depend on.
data AuthorityFacts = AuthorityFacts
  { factRelation :: Normalized.Relation
  , factSubjectEndpoint :: Normalized.Endpoint
  , factSubjectEntity :: Normalized.Entity
  , factScopeEndpoint :: Normalized.Endpoint
  , factScopeEntity :: Normalized.Entity
  , factAbsenceLevel :: AbsenceLevel
  , factEnum :: Normalized.EnumDefinition
  , factRankBottom :: Ref EnumValueId
  , factRankBottomName :: Text
  , factRankTop :: Ref EnumValueId
  , factRankTopName :: Text
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
                            `gateThen` \((rankBottom, rankBottomName), (rankTop, rankTopName)) ->
                              gateValue
                                AuthorityFacts
                                  { factRelation = relation
                                  , factSubjectEndpoint = subjectEndpoint
                                  , factSubjectEntity = subjectEntity
                                  , factScopeEndpoint = scopeEndpoint
                                  , factScopeEntity = scopeEntity
                                  , factAbsenceLevel =
                                      sourcedValue (Normalized.authorityAbsenceLevel authority)
                                  , factEnum = enumDefinition
                                  , factRankBottom = rankBottom
                                  , factRankBottomName = rankBottomName
                                  , factRankTop = rankTop
                                  , factRankTopName = rankTopName
                                  }
  where
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
                    [bottom, top] ->
                      gateBoth
                        (rankedMemberName enumDefinition (Normalized.rankedValueMember bottom))
                        (rankedMemberName enumDefinition (Normalized.rankedValueMember top))
                        `gateThen` \(bottomName, topName) ->
                          gateValue
                            ( (Normalized.rankedValueMember bottom, bottomName)
                            , (Normalized.rankedValueMember top, topName)
                            )
                    _ ->
                      gateReasons
                        [ reasonAt
                            (refPath (Normalized.authorityPayloadOrder auth))
                            ( "the authority enum declares "
                                <> countText (length ranking)
                                <> " ranked values, but only a two-value ordered enum is supported"
                            )
                        ]

-- | Phase 3: the case action's principal mode, parameters, effect,
-- allow policy, and the case scope binding.  Returns the three
-- supported parameters.
actionFacts
  :: Normalized.Model
  -> AuthorityFacts
  -> Normalized.EscalationCase
  -> Normalized.Action
  -> Gate
       ( Normalized.Parameter
       , Normalized.Parameter
       , Normalized.Parameter
       )
actionFacts _model facts onlyCase action =
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
          supportedParameters facts action
            `gateThen` \params@(subjectParam, scopeParam, payloadParam) ->
              effectBindingChecks facts params bindings payloadTerm
                `gateThen` \() ->
                  policyChecks facts params allow
                    `gateThen` \() ->
                      caseScopeCheck facts subjectParam scopeParam payloadParam onlyCase
                        `gateThen` \() ->
                          gateValue params

-- | The effect must be a @SetRelation@ on the authority relation.
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

-- | Exactly three parameters: subject, scope, payload, in order and
-- at the authority's types.
supportedParameters
  :: AuthorityFacts
  -> Normalized.Action
  -> Gate
       ( Normalized.Parameter
       , Normalized.Parameter
       , Normalized.Parameter
       )
supportedParameters facts action =
  case Normalized.actionParameters action of
    [subjectParam, scopeParam, payloadParam] ->
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
    parameters ->
      gateReasons
        [ reasonAt
            (Normalized.actionPath action)
            ( "the case action declares "
                <> countText (length parameters)
                <> " parameters, but the supported proof rule requires exactly"
                <> " three: subject, scope, and payload, in that order"
            )
        ]

-- | The effect must bind subject ↦ subject parameter, scope ↦ scope
-- parameter, payload ↦ payload parameter.
effectBindingChecks
  :: AuthorityFacts
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> OneOrTwo (Normalized.EndpointBinding 'ActorAvailable)
  -> Normalized.ValueTerm 'ActorAvailable
  -> Gate ()
effectBindingChecks facts (subjectParam, scopeParam, payloadParam) bindings payloadTerm =
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

-- | The allow policy must be exactly the supported conjunction; see
-- the module header.
policyChecks
  :: AuthorityFacts
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> Normalized.PolicyTerm 'ActorAvailable
  -> Gate ()
policyChecks facts (subjectParam, scopeParam, _payloadParam) allow =
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
              if ordered /= OptionalEnumOrderedType enumIdentity
                then
                  gateInvariant
                    ( invariantAt
                        (refPath enumRef)
                        "the stored ordered-comparison evidence has drifted from the absence-as-bottom optional ordering of the authority enum"
                    )
                else
                  gateUnit
                    [ reasonAt
                        (refPath valueRef)
                        "the compared privilege floor is not the top-ranked value of the authority enum, which the supported proof rule requires"
                    | refTarget valueRef /= refTarget (factRankTop facts)
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

-- | The term must be exactly the implicit authenticated principal,
-- denoting the authority's subject entity.
actorTermCheck
  :: AuthorityFacts
  -> Normalized.ValueTerm 'ActorAvailable
  -> Text
  -> Gate ()
actorTermCheck facts term message =
  case Normalized.valueTermNode term of
    Normalized.ActorNode actorEntity ->
      if actorEntity /= Normalized.entityId (factSubjectEntity facts)
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

-- | The case scope binding must bind the authority's scope endpoint
-- to exactly the scope parameter.
caseScopeCheck
  :: AuthorityFacts
  -> Normalized.Parameter
  -> Normalized.Parameter
  -> Normalized.Parameter
  -> Normalized.EscalationCase
  -> Gate ()
caseScopeCheck facts _subjectParam scopeParam _payloadParam onlyCase =
  case Normalized.escalationCaseScope onlyCase of
    Nothing ->
      gateInvariant
        ( invariantAt
            (Normalized.escalationCasePath onlyCase)
            "the case names no scope binding although the authority declares a scope endpoint"
        )
    Just binding ->
      if Normalized.scopeBindingEndpoint binding
        /= Normalized.endpointId (factScopeEndpoint facts)
        then
          gateInvariant
            ( invariantAt
                (Normalized.escalationCasePath onlyCase)
                "the case scope binding names an endpoint other than the authority's scope endpoint"
            )
        else
          argumentTermCheck
            facts
            (Normalized.scopeBindingTerm binding)
            scopeParam
            (EntityRefType (Normalized.entityId (factScopeEntity facts)))
            "the case scope term must be exactly the scope parameter of the case action"

-- | Assemble the generation plan from the checked facts.
assemblePlan
  :: Normalized.Model
  -> AuthorityFacts
  -> Normalized.Action
  -> ( Normalized.Parameter
     , Normalized.Parameter
     , Normalized.Parameter
     )
  -> SupportPlan
assemblePlan model facts action (subjectParam, scopeParam, payloadParam) =
  SupportPlan
    { planModelName = sourcedValue (Normalized.modelName model)
    , planRelationId = Normalized.relationId (factRelation facts)
    , planRelationName = sourcedValue (Normalized.relationName (factRelation facts))
    , planSubjectEndpointId = Normalized.endpointId (factSubjectEndpoint facts)
    , planSubjectEndpointName =
        sourcedValue (Normalized.endpointName (factSubjectEndpoint facts))
    , planSubjectEntityId = Normalized.entityId (factSubjectEntity facts)
    , planSubjectEntityName =
        sourcedValue (Normalized.entityName (factSubjectEntity facts))
    , planScopeEndpointId = Normalized.endpointId (factScopeEndpoint facts)
    , planScopeEndpointName =
        sourcedValue (Normalized.endpointName (factScopeEndpoint facts))
    , planScopeEntityId = Normalized.entityId (factScopeEntity facts)
    , planScopeEntityName =
        sourcedValue (Normalized.entityName (factScopeEntity facts))
    , planAbsenceLevel = factAbsenceLevel facts
    , planEnumId = Normalized.enumDefinitionId (factEnum facts)
    , planEnumName = sourcedValue (Normalized.enumDefinitionName (factEnum facts))
    , planRankBottomId = refTarget (factRankBottom facts)
    , planRankBottomName = factRankBottomName facts
    , planRankTopId = refTarget (factRankTop facts)
    , planRankTopName = factRankTopName facts
    , planActionId = Normalized.actionId action
    , planActionName = sourcedValue (Normalized.actionName action)
    , planSubjectParameterId = Normalized.parameterId subjectParam
    , planSubjectParameterName = sourcedValue (Normalized.parameterName subjectParam)
    , planScopeParameterId = Normalized.parameterId scopeParam
    , planScopeParameterName = sourcedValue (Normalized.parameterName scopeParam)
    , planPayloadParameterId = Normalized.parameterId payloadParam
    , planPayloadParameterName = sourcedValue (Normalized.parameterName payloadParam)
    }

--------------------------------------------------------------------
-- Deterministic generation
--------------------------------------------------------------------

-- | The path of the generated entry module inside the checking tree,
-- relative to the Agda include root.  Fixed — never derived from the
-- document, so no authored name can influence the module name.
generatedModuleFile :: FilePath
generatedModuleFile = "Mithril/Generated.agda"

-- | One required generated theorem, as a structured specification:
-- its name, the comment lines introducing it, the exact lines of its
-- type, and the lines of its proof.  'requiredTheoremSpecs' is the
-- single authority for the required theorems: the rendered theorem
-- declarations, the rendered checked manifest entries, and the
-- user-facing verified-theorem inventory are all derived from exactly
-- these specifications, so no theorem name or type has a second
-- statement anywhere in the tool.
data TheoremSpec = TheoremSpec
  { theoremSpecName :: Text
  , theoremSpecCommentLines :: [Text]
  , theoremSpecTypeLines :: [Text]
    -- ^ The theorem's type, one line per rendered line, without
    -- indentation — the renderers indent it for the declaration and
    -- for the manifest entry, so both state byte-identically the
    -- same type.
  , theoremSpecProofLines :: [Text]
  }
  deriving (Eq, Show)

-- | The required generated theorems, in rendering order.
requiredTheoremSpecs :: [TheoremSpec]
requiredTheoremSpecs =
  [ TheoremSpec
      { theoremSpecName = theoremCaseScopeName
      , theoremSpecCommentLines = []
      , theoremSpecTypeLines =
          [ "∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)"
          , "→ eval s (mkAuthed a) γ caseScopeTerm ≡ scopeOf γ"
          ]
      , theoremSpecProofLines =
          [ theoremCaseScopeName <> " s a γ = refl"
          ]
      }
  , TheoremSpec
      { theoremSpecName = theoremActorDistinctName
      , theoremSpecCommentLines =
          [ "-- Policy success separates the actor from the subject parameter: the"
          , "-- guard conjunct evaluates to notB (eqNat (ix actor) (ix subject)),"
          , "-- so an equal index would collapse the policy value to"
          , "-- allowFirst && false, refuted by &&-false-absurd."
          ]
      , theoremSpecTypeLines =
          [ "∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)"
          , "→ checkPolicy s γ (authC a) (policyOf obligationAction) ≡ true"
          , "→ ¬ (ix a ≡ ix (subjectOf γ))"
          ]
      , theoremSpecProofLines =
          [ theoremActorDistinctName <> " s a γ pol p ="
          , "  &&-false-absurd (eval s (mkAuthed a) γ allowFirst)"
          , "    (subst (λ b → (eval s (mkAuthed a) γ allowFirst"
          , "                   && (notB b && eval s (mkAuthed a) γ allowThird))"
          , "                  ≡ true)"
          , "           (trans (sym (cong (eqNat (ix a)) p)) (eqNat-refl (ix a)))"
          , "           pol)"
          ]
      }
  , TheoremSpec
      { theoremSpecName = theoremAuthorityUnchangedName
      , theoremSpecCommentLines =
          [ "-- Strong form: every authorized execution of the case action leaves"
          , "-- the authenticated actor's own authority tuple in the selected scope"
          , "-- exactly unchanged (the SetRelation frame lemma, fed by the policy's"
          , "-- actor/subject disequality)."
          ]
      , theoremSpecTypeLines =
          [ "∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}"
          , "  (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)"
          , "→ authorityOf (postState (execute cap al)) a (scopeOf γ)"
          , "≡ authorityOf s a (scopeOf γ)"
          ]
      , theoremSpecProofLines =
          [ theoremAuthorityUnchangedName <> " {s} {a} {γ} cap al ="
          , "  execute-setRel-frame cap al a (scopeOf γ) noHit"
          , "  where"
          , "  noHit : ¬ ((ix (subjectOf γ) ≡ ix a)"
          , "           × (ix (scopeOf γ) ≡ ix (scopeOf γ)))"
          , "  noHit (tEq , _) ="
          , "    " <> theoremActorDistinctName <> " s a γ (policy-ok cap) (sym tEq)"
          ]
      }
  , TheoremSpec
      { theoremSpecName = theoremNoEscalationName
      , theoremSpecCommentLines =
          [ "-- The selected obligation: no authorized execution of the case action"
          , "-- raises the authenticated actor's own authority in the selected"
          , "-- scope, with absence ranked as bottom."
          ]
      , theoremSpecTypeLines =
          [ "∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}"
          , "  (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)"
          , "→ NoSelfPrivilegeEscalation s (postState (execute cap al))"
          , "                            a (scopeOf γ)"
          ]
      , theoremSpecProofLines =
          [ theoremNoEscalationName <> " {s} {a} {γ} cap al ="
          , "  authority-unchanged→no-escalation"
          , "    s (postState (execute cap al)) a (scopeOf γ)"
          , "    (" <> theoremAuthorityUnchangedName <> " cap al)"
          ]
      }
  ]

-- | The exact required theorem names, projected from
-- 'requiredTheoremSpecs' — the same structured authority everything
-- else about the required theorems is derived from.
requiredTheoremNames :: [Text]
requiredTheoremNames = map theoremSpecName requiredTheoremSpecs

theoremCaseScopeName :: Text
theoremCaseScopeName = "case-scope-is-scope-argument"

theoremActorDistinctName :: Text
theoremActorDistinctName = "policy-actor-distinct"

theoremAuthorityUnchangedName :: Text
theoremAuthorityUnchangedName = "actor-authority-unchanged"

theoremNoEscalationName :: Text
theoremNoEscalationName = "no-self-escalation"

-- | The deterministic generated artifact: the exact module text
-- together with the structured inventory of the rendered theorem
-- blocks the text was assembled from.  The text is built by
-- concatenating exactly the inventoried blocks (plus the fixed
-- surrounding sections and the checked manifest), so the inventory is
-- the generator's own structured record of what it emitted — no
-- source text is ever re-lexed or searched to reconstruct it.
data GeneratedArtifact = GeneratedArtifact
  { artifactTheoremBlocks :: [(Text, [Text])]
    -- ^ Each rendered theorem's name with its rendered inner-module
    -- block lines, in rendering order.
  , artifactModuleText :: Text
  }
  deriving (Eq, Show)

-- | Every required theorem name for which the structured generated
-- artifact carries no rendered theorem block.  This is an inventory
-- check of the generator's own structured output: a missing entry is
-- a generator bug — an internal generated-artifact failure, detected
-- before any checker runs, never an unsupported classification and
-- never a verdict.  Whether each inventoried theorem actually exists
-- in the checked module at exactly its required type is deliberately
-- not decided here, and not by any inspection of source text: the
-- generated module's checked manifest makes Agda itself prove it
-- when the checker accepts the module (see 'renderedManifestBlock').
missingRequiredTheorems :: GeneratedArtifact -> [Text]
missingRequiredTheorems artifact =
  [ theoremSpecName spec
  | spec <- requiredTheoremSpecs
  , theoremSpecName spec `notElem` map fst (artifactTheoremBlocks artifact)
  ]

-- | Generate the one supported obligation artifact deterministically
-- from the plan's normalized evidence.  The module text depends only
-- on the plan — never on file paths, time, or environment — uses
-- Unix line endings with no carriage returns and no tabs, and ends
-- with exactly one final newline.  Every proof-relevant supported
-- field of the evidence appears: the identities and declared names in
-- the evidence comment block (names escaped through 'quotedName', so
-- no authored text can introduce a physical line break or any Agda
-- syntax), the parameter order and types, ranking, bindings, and
-- policy structure in both the comment block and the transcribed
-- definitions.  The required theorems are rendered from
-- 'requiredTheoremSpecs' into the named inner theorem module,
-- followed by the checked manifest that makes Agda itself prove each
-- one exists at exactly its required type; the artifact records the
-- rendered theorem blocks as its structured inventory.
generatedObligationArtifact :: SupportPlan -> GeneratedArtifact
generatedObligationArtifact plan =
  GeneratedArtifact
    { artifactTheoremBlocks = blocks
    , artifactModuleText =
        Text.unlines
          ( pragmaLines
              <> evidenceLines plan
              <> moduleLines
              <> contextLines plan
              <> rankingLines plan
              <> policyLines plan
              <> actionLines plan
              <> projectionLines plan
              <> scopeLines plan
              <> theoremModuleHeaderLines
              <> concatMap snd blocks
              <> manifestIntroLines
              <> concatMap renderedManifestBlock requiredTheoremSpecs
          )
    }
  where
    blocks =
      [ (theoremSpecName spec, renderedTheoremBlock spec)
      | spec <- requiredTheoremSpecs
      ]

-- | The exact module text of the generated artifact.
renderObligationModule :: SupportPlan -> Text
renderObligationModule = artifactModuleText . generatedObligationArtifact

pragmaLines :: [Text]
pragmaLines =
  [ "{-# OPTIONS --safe #-}"
  , ""
  , "-- Generated Mithril Core v0 verification artifact.  DO NOT EDIT."
  , "--"
  , "-- This module was derived deterministically by the mithril verifier"
  , "-- from the normalized evidence of one authored Mithril Core v0"
  , "-- document; correcting it means correcting the authored document or"
  , "-- the generator, never editing this file.  It instantiates the"
  , "-- trusted fixed-schema Agda kernel (Mithril.Base, Mithril.Core,"
  , "-- Mithril.Policy, Mithril.Effect, Mithril.Guarantee) for exactly one"
  , "-- selected NoSelfPrivilegeEscalation obligation."
  ]

evidenceLines :: SupportPlan -> [Text]
evidenceLines plan =
  [ "--"
  , "-- Consumed normalized evidence:"
  , "--"
  , "-- model: " <> quotedName (planModelName plan)
  , "-- guarantee: NoSelfPrivilegeEscalation"
  , "-- authority relation: "
      <> quotedName (planRelationName plan)
      <> " (relation "
      <> relationIndex (planRelationId plan)
      <> ")"
  , "-- authority subject endpoint: "
      <> endpointEvidence
        (planSubjectEndpointName plan)
        (planSubjectEndpointId plan)
        (planSubjectEntityName plan)
        (planSubjectEntityId plan)
  , "-- authority scope endpoint: "
      <> endpointEvidence
        (planScopeEndpointName plan)
        (planScopeEndpointId plan)
        (planScopeEntityName plan)
        (planScopeEntityId plan)
  , "-- authority absence level: " <> absenceText (planAbsenceLevel plan)
  , "-- authority payload order: enum "
      <> quotedName (planEnumName plan)
      <> " (enum "
      <> enumIndex (planEnumId plan)
      <> ")"
  , "-- materialized authority ranking: rank 0 = "
      <> valueEvidence (planRankBottomName plan) (planRankBottomId plan)
      <> ", rank 1 = "
      <> valueEvidence (planRankTopName plan) (planRankTopId plan)
  , "-- case action: "
      <> quotedName (planActionName plan)
      <> " (action "
      <> actionIndex (planActionId plan)
      <> ")"
  , "-- case scope binding: endpoint "
      <> quotedName (planScopeEndpointName plan)
      <> " = Argument "
      <> quotedName (planScopeParameterName plan)
      <> " (parameter "
      <> parameterIndex (planScopeParameterId plan)
      <> ")"
  , "-- principal mode: AuthenticatedOnly"
  , "-- parameter 0: "
      <> quotedName (planSubjectParameterName plan)
      <> " : EntityRef "
      <> quotedName (planSubjectEntityName plan)
  , "-- parameter 1: "
      <> quotedName (planScopeParameterName plan)
      <> " : EntityRef "
      <> quotedName (planScopeEntityName plan)
  , "-- parameter 2: "
      <> quotedName (planPayloadParameterName plan)
      <> " : Enum "
      <> quotedName (planEnumName plan)
  , "-- allow policy: And(LessOrEqual[order optional "
      <> quotedName (planEnumName plan)
      <> ", absence as bottom](Some(Enum["
      <> quotedName (planEnumName plan)
      <> "."
      <> quotedName (planRankTopName plan)
      <> "]), Lookup["
      <> quotedName (planRelationName plan)
      <> "]("
      <> quotedName (planSubjectEndpointName plan)
      <> " = Actor, "
      <> quotedName (planScopeEndpointName plan)
      <> " = Argument["
      <> quotedName (planScopeParameterName plan)
      <> "])), And(Not(Equal(Actor, Argument["
      <> quotedName (planSubjectParameterName plan)
      <> "])), IsSome(Lookup["
      <> quotedName (planRelationName plan)
      <> "]("
      <> quotedName (planSubjectEndpointName plan)
      <> " = Argument["
      <> quotedName (planSubjectParameterName plan)
      <> "], "
      <> quotedName (planScopeEndpointName plan)
      <> " = Argument["
      <> quotedName (planScopeParameterName plan)
      <> "]))))"
  , "-- effect: SetRelation["
      <> quotedName (planRelationName plan)
      <> "]("
      <> quotedName (planSubjectEndpointName plan)
      <> " = Argument["
      <> quotedName (planSubjectParameterName plan)
      <> "], "
      <> quotedName (planScopeEndpointName plan)
      <> " = Argument["
      <> quotedName (planScopeParameterName plan)
      <> "]) payload Argument["
      <> quotedName (planPayloadParameterName plan)
      <> "]"
  , "-- result: Done"
  ]
  where
    endpointEvidence endpointName (EndpointId _ position) entityName (EntityId entityPosition) =
      quotedName endpointName
        <> " (endpoint "
        <> countText position
        <> " of relation "
        <> relationIndex (planRelationId plan)
        <> "), entity "
        <> quotedName entityName
        <> " (entity "
        <> countText entityPosition
        <> ")"
    valueEvidence valueName (EnumValueId _ position) =
      quotedName valueName
        <> " (value "
        <> countText position
        <> " of enum "
        <> enumIndex (planEnumId plan)
        <> ")"
    absenceText AbsenceBottom = "Bottom"

relationIndex :: RelationId -> Text
relationIndex (RelationId index) = countText index

enumIndex :: EnumId -> Text
enumIndex (EnumId index) = countText index

actionIndex :: ActionId -> Text
actionIndex (ActionId index) = countText index

parameterIndex :: ParameterId -> Text
parameterIndex (ParameterId _ index) = countText index

moduleLines :: [Text]
moduleLines =
  [ ""
  , "module Mithril.Generated where"
  , ""
  , "open import Mithril.Base"
  , "open import Mithril.Core"
  , "open import Mithril.Policy"
  , "open import Mithril.Effect"
  , "open import Mithril.Guarantee"
  ]

contextLines :: SupportPlan -> [Text]
contextLines plan =
  [ ""
  , "-- The action's parameter context, in declaration order (parameter 0"
  , "-- outermost); the kernel renders the subject entity as UserK, the"
  , "-- scope entity as OrgK, and the two-value authority enum as Role."
  , ""
  , "obligationCtx : Ctx"
  , "obligationCtx = ∅ ▸ entity UserK ▸ entity OrgK ▸ role"
  , ""
  , "-- parameter " <> parameterIndex (planSubjectParameterId plan) <> " "
      <> quotedName (planSubjectParameterName plan)
  , "subjectParam : Var obligationCtx (entity UserK)"
  , "subjectParam = " <> deBruijn (planSubjectParameterId plan)
  , ""
  , "-- parameter " <> parameterIndex (planScopeParameterId plan) <> " "
      <> quotedName (planScopeParameterName plan)
  , "scopeParam : Var obligationCtx (entity OrgK)"
  , "scopeParam = " <> deBruijn (planScopeParameterId plan)
  , ""
  , "-- parameter " <> parameterIndex (planPayloadParameterId plan) <> " "
      <> quotedName (planPayloadParameterName plan)
  , "payloadParam : Var obligationCtx role"
  , "payloadParam = " <> deBruijn (planPayloadParameterId plan)
  ]
  where
    -- The de Bruijn spine of a parameter in the three-parameter
    -- context: parameter 0 is outermost ("there (there here)"),
    -- parameter 2 innermost ("here").
    deBruijn (ParameterId _ position) = spine (2 - position)
    spine :: Int -> Text
    spine depth
      | depth <= 0 = "here"
      | depth == 1 = "there here"
      | otherwise = "there (" <> spine (depth - 1) <> ")"

rankingLines :: SupportPlan -> [Text]
rankingLines plan =
  [ ""
  , "-- The materialized authority ranking: rank 0 ("
      <> quotedName (planRankBottomName plan)
      <> ") is the"
  , "-- kernel's bottom ranked value, rank 1 ("
      <> quotedName (planRankTopName plan)
      <> ") the top."
  , ""
  , "rankBottom : Role"
  , "rankBottom = memberR"
  , ""
  , "rankTop : Role"
  , "rankTop = adminR"
  ]

policyLines :: SupportPlan -> [Text]
policyLines _plan =
  [ ""
  , "-- The three authored allow-policy conjuncts, transcribed constructor"
  , "-- by constructor with the authored nesting And(first, And(guard, third))."
  , ""
  , "allowFirst : Term authed obligationCtx bool"
  , "allowFirst = leqT (maybe-ord role-ord)"
  , "                  (justT (roleL rankTop))"
  , "                  (memT actorT (arg scopeParam))"
  , ""
  , "allowGuard : Term authed obligationCtx bool"
  , "allowGuard = notT (eqT actorT (arg subjectParam))"
  , ""
  , "allowThird : Term authed obligationCtx bool"
  , "allowThird = hasMemT (arg subjectParam) (arg scopeParam)"
  , ""
  , "allowPolicy : Term authed obligationCtx bool"
  , "allowPolicy = andT allowFirst (andT allowGuard allowThird)"
  ]

actionLines :: SupportPlan -> [Text]
actionLines _plan =
  [ ""
  , "-- The complete case action: AuthenticatedOnly principal mode, the"
  , "-- transcribed allow policy, and the SetRelation effect writing the"
  , "-- authority relation at (subject parameter, scope parameter) with the"
  , "-- payload parameter; the effect descriptor forces the Done result."
  , ""
  , "obligationAction : Action authenticatedOnly obligationCtx doneD"
  , "obligationAction ="
  , "  mutA (authP allowPolicy)"
  , "       (setRelE (arg subjectParam) (arg scopeParam) (arg payloadParam))"
  ]

projectionLines :: SupportPlan -> [Text]
projectionLines _plan =
  [ ""
  , "-- Request projections."
  , ""
  , "subjectOf : Args obligationCtx → EntityRef UserK"
  , "subjectOf γ = lookupArg γ subjectParam"
  , ""
  , "scopeOf : Args obligationCtx → EntityRef OrgK"
  , "scopeOf γ = lookupArg γ scopeParam"
  ]

scopeLines :: SupportPlan -> [Text]
scopeLines _plan =
  [ ""
  , "-- The case scope binding: the guarantee's selected scope term is the"
  , "-- scope parameter, so it evaluates to exactly the scope argument the"
  , "-- theorems below quantify over."
  , ""
  , "caseScopeTerm : Term authed obligationCtx (entity OrgK)"
  , "caseScopeTerm = arg scopeParam"
  ]

-- | The fixed name of the inner module the required theorems are
-- declared in.  The checked manifest references every theorem
-- qualified through this module name, so only a real declaration of
-- this module can satisfy a manifest entry — never an imported or
-- otherwise coincidental outer name, and never any non-declaration
-- text.
generatedTheoremModuleName :: Text
generatedTheoremModuleName = "GeneratedTheorems"

theoremModuleHeaderLines :: [Text]
theoremModuleHeaderLines =
  [ ""
  , "-- The required theorems, declared in a named inner module so the"
  , "-- checked manifest below can reference each one by a qualified name."
  , ""
  , "module " <> generatedTheoremModuleName <> " where"
  ]

-- | The rendered inner-module block of one required theorem: its
-- comment lines, its declaration at exactly the spec's type, and its
-- proof, indented into the inner theorem module.
renderedTheoremBlock :: TheoremSpec -> [Text]
renderedTheoremBlock spec =
  [""]
    <> map indentLine (theoremSpecCommentLines spec)
    <> ["" | not (null (theoremSpecCommentLines spec))]
    <> map
      indentLine
      ( (theoremSpecName spec <> " :")
          : map ("  " <>) (theoremSpecTypeLines spec)
          <> theoremSpecProofLines spec
      )
  where
    indentLine line
      | Text.null line = line
      | otherwise = "  " <> line

manifestIntroLines :: [Text]
manifestIntroLines =
  [ ""
  , "-- Checked theorem manifest.  Each entry restates one required"
  , "-- theorem's exact type and is defined by the qualified name of the"
  , "-- generated theorem itself, so Agda's acceptance of this module"
  , "-- proves that every required theorem above exists at exactly its"
  , "-- required type: a name occurring only in a comment, a string, a"
  , "-- hole, or a longer identifier declares nothing, and a qualified"
  , "-- reference into the inner theorem module can never resolve to an"
  , "-- imported or otherwise coincidental outer name."
  ]

-- | The rendered checked-manifest entry of one required theorem: a
-- fresh top-level declaration restating the theorem's exact type from
-- the same 'TheoremSpec', defined by the qualified name of the
-- generated theorem.  Agda accepts the entry only if the inner
-- theorem module really declares the theorem and its type is exactly
-- the required one.
renderedManifestBlock :: TheoremSpec -> [Text]
renderedManifestBlock spec =
  [ ""
  , entryName <> " :"
  ]
    <> map ("  " <>) (theoremSpecTypeLines spec)
    <> [ entryName
           <> " = "
           <> generatedTheoremModuleName
           <> "."
           <> theoremSpecName spec
       ]
  where
    entryName = "manifest-" <> theoremSpecName spec

--------------------------------------------------------------------
-- Checker-independent orchestration
--------------------------------------------------------------------

-- | How a generated obligation module reaches a checker: the runner
-- receives the exact generated module text and answers either
-- acceptance or a classified tool failure.  The production runner
-- ("Mithril.Core.Internal.AgdaChecker") materializes the embedded
-- kernel and the module into a fresh isolated workspace and invokes
-- exactly Agda 2.8.0 with @--safe --no-libraries
-- --ignore-interfaces@; test runners stay inside this package.
type CheckerRunner = Text -> IO (Either VerificationFailure ())

-- | Verify one normalized model with the given checker runner:
-- support gate first (pure — an unsupported model never reaches any
-- checker), then deterministic generation, then the
-- required-theorem completeness check, then the checker.
verifyModelWith
  :: CheckerRunner
  -> Normalized.Model
  -> IO (Either VerificationFailure VerificationResult)
verifyModelWith runner model =
  case supportPlan model of
    Left (PlanInvariant violations) ->
      pure (Left (VerifierInvariantViolations violations))
    Left (PlanUnsupported reasons) ->
      pure (Right (VerificationUnsupported reasons))
    Right plan ->
      let artifact = generatedObligationArtifact plan
       in case missingRequiredTheorems artifact of
            missing : more ->
              pure (Left (GeneratedTheoremsMissing (missing :| more)))
            [] -> do
              checkOutcome <- runner (artifactModuleText artifact)
              pure $ case checkOutcome of
                Left failure -> Left failure
                Right () ->
                  Right (VerificationVerified (planObligation plan))
