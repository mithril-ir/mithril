{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | __Internal module — never expose.__
--
-- The Core v0 verifier slice: the deterministic generator of the one
-- supported Agda obligation module and the checker-independent
-- verification orchestration over the shared NoSelfPrivilegeEscalation
-- support plan.  The support gate itself — the single statement of
-- the supported-shape classification, its canonical identity
-- preflight, and the resolved plan it extracts — lives in
-- "Mithril.Core.Internal.NspeSupportPlan" and is consumed unchanged
-- by this module and by the Wasp emitter ("Mithril.Core.Internal.Wasp");
-- this module restates no part of it.  It is pure except for the one
-- injected 'CheckerRunner' call; the production runner — which embeds
-- the trusted Agda kernel and invokes the real Agda 2.8.0 executable
-- across a process boundary — lives in the public library
-- (@Mithril.Core.Internal.AgdaChecker@), and the public boundary is
-- exactly "Mithril.Core.Verification".
--
-- Soundness of the transcription: the generated module transcribes
-- exactly the supported shape into the trusted fixed-schema kernel
-- and re-proves, with the kernel's checked frame lemmas, that policy
-- success forces the authenticated actor's index apart from the
-- subject parameter's, so the authorized @SetRelation@ write cannot
-- touch the actor's own authority tuple in the selected scope — the
-- actor's tuple is exactly unchanged, hence never raised.  Agda
-- checks the generated module from scratch; the plan proves nothing.
--
-- == Failure classification
--
-- Shapes outside the support rule are 'UnsupportedReason's and
-- forged normalized evidence is a 'VerifierInvariantViolation' (both
-- decided by the shared gate before any generation).  Checker
-- problems (missing or wrong-version Agda, launch or workspace
-- failure, a nonzero check after the gate accepted, a structured
-- generated-artifact inventory missing a required theorem block) are
-- 'VerificationFailure's — tool failures, never semantic verdicts.
-- Nothing here can ever report a violation: @VIOLATED@ is reserved
-- for a future independently checked concrete witness and has no
-- representation in this vocabulary.
module Mithril.Core.Internal.Verify
  ( -- * Public result vocabulary (re-exported by Mithril.Core.Verification)
    VerificationResult (..)
  , VerifiedObligation (..)
  , UnsupportedReason (..)
  , VerificationFailure (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations

    -- * The shared support gate (re-exported from the plan facility)
  , NspeSupportPlan (..)
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

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import qualified Data.Text as Text

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.NspeSupportPlan
  ( NspeSupportPlan (..)
  , PlanRankedMember (..)
  , PlanRefusal (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations
  , quotedName
  , supportPlan
  )
import Mithril.Core.Internal.Resolved
  ( ActionId (..)
  , EndpointId (..)
  , EntityId (..)
  , EnumId (..)
  , EnumValueId (..)
  , ParameterId (..)
  , RelationId (..)
  )
import Mithril.Core.Internal.SourcePath (Sourced (..))
import Mithril.Core.Internal.Syntax (AbsenceLevel (..))

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

-- | The obligation summary of a plan, as reported on success.
planObligation :: NspeSupportPlan -> VerifiedObligation
planObligation plan =
  VerifiedObligation
    { verifiedGuarantee = "NoSelfPrivilegeEscalation"
    , verifiedCaseAction = sourcedValue (planActionName plan)
    , verifiedTheorems = requiredTheoremNames
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
generatedObligationArtifact :: NspeSupportPlan -> GeneratedArtifact
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
renderObligationModule :: NspeSupportPlan -> Text
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

evidenceLines :: NspeSupportPlan -> [Text]
evidenceLines plan =
  [ "--"
  , "-- Consumed normalized evidence:"
  , "--"
  , "-- model: " <> quotedName (sourcedValue (planModelName plan))
  , "-- guarantee: NoSelfPrivilegeEscalation"
  , "-- authority relation: "
      <> quotedName (sourcedValue (planRelationName plan))
      <> " (relation "
      <> relationIndex (planRelationId plan)
      <> ")"
  , "-- authority subject endpoint: "
      <> endpointEvidence
        (sourcedValue (planSubjectEndpointName plan))
        (planSubjectEndpointId plan)
        (sourcedValue (planSubjectEntityName plan))
        (planSubjectEntityId plan)
  , "-- authority scope endpoint: "
      <> endpointEvidence
        (sourcedValue (planScopeEndpointName plan))
        (planScopeEndpointId plan)
        (sourcedValue (planScopeEntityName plan))
        (planScopeEntityId plan)
  , "-- authority absence level: " <> absenceText (planAbsenceLevel plan)
  , "-- authority payload order: enum "
      <> quotedName (sourcedValue (planEnumName plan))
      <> " (enum "
      <> enumIndex (planEnumId plan)
      <> ")"
  , "-- materialized authority ranking: rank 0 = "
      <> valueEvidence (planRankedName (planRankBottom plan)) (planRankedId (planRankBottom plan))
      <> ", rank 1 = "
      <> valueEvidence (planRankedName (planRankTop plan)) (planRankedId (planRankTop plan))
  , "-- case action: "
      <> quotedName (sourcedValue (planActionName plan))
      <> " (action "
      <> actionIndex (planActionId plan)
      <> ")"
  , "-- case scope binding: endpoint "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument "
      <> quotedName (sourcedValue (planScopeParameterName plan))
      <> " (parameter "
      <> parameterIndex (planScopeParameterId plan)
      <> ")"
  , "-- principal mode: AuthenticatedOnly"
  , "-- parameter 0: "
      <> quotedName (sourcedValue (planSubjectParameterName plan))
      <> " : EntityRef "
      <> quotedName (sourcedValue (planSubjectEntityName plan))
  , "-- parameter 1: "
      <> quotedName (sourcedValue (planScopeParameterName plan))
      <> " : EntityRef "
      <> quotedName (sourcedValue (planScopeEntityName plan))
  , "-- parameter 2: "
      <> quotedName (sourcedValue (planPayloadParameterName plan))
      <> " : Enum "
      <> quotedName (sourcedValue (planEnumName plan))
  , "-- allow policy: And(LessOrEqual[order optional "
      <> quotedName (sourcedValue (planEnumName plan))
      <> ", absence as bottom](Some(Enum["
      <> quotedName (sourcedValue (planEnumName plan))
      <> "."
      <> quotedName (planRankedName (planRankTop plan))
      <> "]), Lookup["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Actor, "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (planScopeParameterName plan))
      <> "])), And(Not(Equal(Actor, Argument["
      <> quotedName (sourcedValue (planSubjectParameterName plan))
      <> "])), IsSome(Lookup["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (planSubjectParameterName plan))
      <> "], "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (planScopeParameterName plan))
      <> "]))))"
  , "-- effect: SetRelation["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (planSubjectParameterName plan))
      <> "], "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (planScopeParameterName plan))
      <> "]) payload Argument["
      <> quotedName (sourcedValue (planPayloadParameterName plan))
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

countText :: Int -> Text
countText = Text.pack . show

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

contextLines :: NspeSupportPlan -> [Text]
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
      <> quotedName (sourcedValue (planSubjectParameterName plan))
  , "subjectParam : Var obligationCtx (entity UserK)"
  , "subjectParam = " <> deBruijn (planSubjectParameterId plan)
  , ""
  , "-- parameter " <> parameterIndex (planScopeParameterId plan) <> " "
      <> quotedName (sourcedValue (planScopeParameterName plan))
  , "scopeParam : Var obligationCtx (entity OrgK)"
  , "scopeParam = " <> deBruijn (planScopeParameterId plan)
  , ""
  , "-- parameter " <> parameterIndex (planPayloadParameterId plan) <> " "
      <> quotedName (sourcedValue (planPayloadParameterName plan))
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

rankingLines :: NspeSupportPlan -> [Text]
rankingLines plan =
  [ ""
  , "-- The materialized authority ranking: rank 0 ("
      <> quotedName (planRankedName (planRankBottom plan))
      <> ") is the"
  , "-- kernel's bottom ranked value, rank 1 ("
      <> quotedName (planRankedName (planRankTop plan))
      <> ") the top."
  , ""
  , "rankBottom : Role"
  , "rankBottom = memberR"
  , ""
  , "rankTop : Role"
  , "rankTop = adminR"
  ]

policyLines :: NspeSupportPlan -> [Text]
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

actionLines :: NspeSupportPlan -> [Text]
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

projectionLines :: NspeSupportPlan -> [Text]
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

scopeLines :: NspeSupportPlan -> [Text]
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
