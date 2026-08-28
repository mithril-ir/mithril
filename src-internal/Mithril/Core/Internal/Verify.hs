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
-- preflight, the per-case rule tags, and the resolved plan it extracts
-- — lives in "Mithril.Core.Internal.NspeSupportPlan" and is consumed
-- unchanged by this module and by the Wasp emitter
-- ("Mithril.Core.Internal.Wasp"); this module restates no part of it.
-- It is pure except for the one injected 'CheckerRunner' call; the
-- production runner — which embeds the trusted Agda kernel and invokes
-- the real Agda 2.8.0 executable across a process boundary — lives in
-- the public library (@Mithril.Core.Internal.AgdaChecker@), and the
-- public boundary is exactly "Mithril.Core.Verification".
--
-- == Generation
--
-- Every supported case of the plan gets its own complete proof group
-- — the theorems of the rule it matched ('ruleTheoremSpecs') — and
-- its own checked-manifest entries; the required theorem inventory is
-- derived from the complete plan ('missingRequiredTheorems'), never
-- from one global list.  Two layouts exist:
--
-- * the /compatibility layout/ for exactly a singleton rule-1 plan:
--   the original flat module, byte-for-byte unchanged, with the
--   theorems in the inner module @GeneratedTheorems@ and the manifest
--   entries at top level;
-- * the /general layout/ for every other plan (a singleton rule-2
--   plan, or several cases): the shared ranking at top level, then
--   one inner module @Case\<i\>@ per case in authored order — @i@ the
--   zero-based authored case position — holding that case's context,
--   policy, action, projections, scope term, and its inner
--   @GeneratedTheorems@ module, followed by one manifest module
--   @ManifestCase\<i\>@ per case that opens @Case\<i\>@ and restates
--   every required theorem's exact type, defined by the qualified
--   generated theorem.  Position qualification makes every module and
--   theorem name collision-free, and authored order is preserved.
--
-- Soundness of the transcription: the generated module transcribes
-- exactly the supported shapes into the trusted fixed-schema kernel.
-- A rule-1 group re-proves, with the kernel's checked frame lemma,
-- that policy success forces the authenticated actor's index apart
-- from the subject parameter's, so the authorized @SetRelation@ write
-- cannot touch the actor's own authority tuple in the selected scope
-- — the actor's tuple is exactly unchanged, hence never raised.  A
-- rule-2 group re-proves, with the kernel's checked point lemma, that
-- the write installs exactly the requested payload at the actor's own
-- tuple and that policy success is exactly the bound of that payload
-- by the actor's pre-state authority — so the post-state authority is
-- bounded by the pre-state authority, hence never raised.  Agda checks
-- the generated module from scratch; the plan proves nothing.
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
  , VerifiedCase (..)
  , NspeRule (..)
  , nspeRuleLabel
  , UnsupportedReason (..)
  , VerificationFailure (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations

    -- * The shared support gate (re-exported from the plan facility)
  , NspeSupportPlan (..)
  , NspeCasePlan (..)
  , NspeCaseMatch (..)
  , PlanRefusal (..)
  , supportPlan

    -- * Deterministic generation
  , TheoremSpec (..)
  , ruleTheoremSpecs
  , ruleTheoremNames
  , GeneratedArtifact (..)
  , GeneratedCase (..)
  , generatedObligationArtifact
  , renderObligationModule
  , renderedTheoremBlock
  , renderedManifestBlock
  , indentLines
  , generatedCaseModuleName
  , generatedManifestModuleName
  , generatedModuleFile
  , missingRequiredTheorems
  , planObligation
  , quotedName

    -- * Checker-independent orchestration
  , CheckerRunner
  , verifyModelWith
  ) where

import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text

import qualified Mithril.Core.Internal.Normalized as Normalized
import Mithril.Core.Internal.NspeSupportPlan
  ( BoundedSelfUpdateFacts (..)
  , ChangeOtherFacts (..)
  , NspeCaseMatch (..)
  , NspeCasePlan (..)
  , NspeRule (..)
  , NspeSupportPlan (..)
  , PlanBinding (..)
  , PlanRankedMember (..)
  , PlanRefusal (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  , caseRule
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations
  , nspeRuleLabel
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
  = -- | Every selected case of the document's one selected obligation
    -- is supported, the deterministic artifact was generated, and
    -- every required named theorem of every case was accepted by the
    -- configured Agda 2.8.0 safe check.
    VerificationVerified VerifiedObligation
  | -- | The normalized document lies outside the implemented support
    -- rule.  Decided by the pure deterministic gate before any
    -- checker runs; the reasons are sorted and deduplicated.
    VerificationUnsupported (NonEmpty UnsupportedReason)
  deriving (Eq, Show)

-- | What a successful verification checked: the guarantee family and
-- every verified case in authored order — each with its zero-based
-- authored position, the rule it matched, its case action's declared
-- name, and the exact required theorem names the checker accepted.
-- No internal identifiers, no paths, no checker output.
data VerifiedObligation = VerifiedObligation
  { verifiedGuarantee :: Text
  , verifiedCases :: NonEmpty VerifiedCase
  }
  deriving (Eq, Ord, Show)

-- | One verified case of the obligation.
data VerifiedCase = VerifiedCase
  { verifiedCasePosition :: Int
  , verifiedCaseRule :: NspeRule
  , verifiedCaseAction :: Text
  , verifiedCaseTheorems :: [Text]
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
    -- rendered theorem block for every required theorem of every
    -- case of the plan — a generator bug, detected before any checker
    -- runs.  (Whether each rendered theorem really exists at exactly
    -- its required type is proved by Agda through the generated
    -- module's checked manifests, never by inspecting source text; a
    -- manifest the checker cannot satisfy is a 'CheckerRejected' tool
    -- failure.)
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

-- | The obligation summary of a plan, as reported on success: every
-- case in authored order with its rule and its required theorem
-- inventory.
planObligation :: NspeSupportPlan -> VerifiedObligation
planObligation plan =
  VerifiedObligation
    { verifiedGuarantee = "NoSelfPrivilegeEscalation"
    , verifiedCases = fmap caseObligation (planCases plan)
    }
  where
    caseObligation casePlan =
      VerifiedCase
        { verifiedCasePosition = casePosition casePlan
        , verifiedCaseRule = caseRule casePlan
        , verifiedCaseAction = sourcedValue (caseActionName casePlan)
        , verifiedCaseTheorems = ruleTheoremNames (caseRule casePlan)
        }

--------------------------------------------------------------------
-- Deterministic generation: the theorem specifications
--------------------------------------------------------------------

-- | The path of the generated entry module inside the checking tree,
-- relative to the Agda include root.  Fixed — never derived from the
-- document, so no authored name can influence the module name.
generatedModuleFile :: FilePath
generatedModuleFile = "Mithril/Generated.agda"

-- | One required generated theorem, as a structured specification:
-- its name, the comment lines introducing it, the exact lines of its
-- type, and the lines of its proof.  'ruleTheoremSpecs' is the single
-- authority for the required theorems of a rule: the rendered theorem
-- declarations, the rendered checked manifest entries, and the
-- user-facing verified-theorem inventory are all derived from exactly
-- these specifications, so no theorem name or type has a second
-- statement anywhere in the tool.  The type and proof lines name the
-- case-local definitions unqualified; inside a case's inner module
-- and inside the manifest module that opens it, they denote exactly
-- that case's definitions.
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

-- | The required generated theorems of a rule, in rendering order.
ruleTheoremSpecs :: NspeRule -> [TheoremSpec]
ruleTheoremSpecs rule =
  case rule of
    ChangeOtherRule -> changeOtherTheoremSpecs
    BoundedSelfUpdateRule -> boundedSelfUpdateTheoremSpecs

-- | The exact required theorem names of a rule, projected from
-- 'ruleTheoremSpecs' — the same structured authority everything else
-- about the required theorems is derived from.
ruleTheoremNames :: NspeRule -> [Text]
ruleTheoremNames = map theoremSpecName . ruleTheoremSpecs

-- | The rule-1 (change-other) proof group: the case scope equals the
-- scope argument, policy success separates the actor from the
-- subject, execution leaves the actor's own tuple unchanged, and the
-- obligation follows.
changeOtherTheoremSpecs :: [TheoremSpec]
changeOtherTheoremSpecs =
  [ caseScopeTheoremSpec
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
      , theoremSpecTypeLines = noEscalationTypeLines
      , theoremSpecProofLines =
          [ theoremNoEscalationName <> " {s} {a} {γ} cap al ="
          , "  authority-unchanged→no-escalation"
          , "    s (postState (execute cap al)) a (scopeOf γ)"
          , "    (" <> theoremAuthorityUnchangedName <> " cap al)"
          ]
      }
  ]

-- | The rule-2 (bounded self-update) proof group: the case scope
-- equals the scope argument, policy success bounds the requested
-- payload by the actor's pre-state authority, execution writes the
-- actor's own tuple to the requested payload, and the obligation
-- follows by composing the two.
boundedSelfUpdateTheoremSpecs :: [TheoremSpec]
boundedSelfUpdateTheoremSpecs =
  [ caseScopeTheoremSpec
  , TheoremSpec
      { theoremSpecName = theoremPolicyBoundsPayloadName
      , theoremSpecCommentLines =
          [ "-- Policy success bounds the requested payload by the actor's own"
          , "-- pre-state authority in the selected scope: the single authored"
          , "-- comparison evaluates to exactly that bound, with absence ranked as"
          , "-- bottom, so the policy equation is the bound itself."
          ]
      , theoremSpecTypeLines =
          [ "∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)"
          , "→ checkPolicy s γ (authC a) (policyOf obligationAction) ≡ true"
          , "→ authLeq (just (payloadOf γ)) (authorityOf s a (scopeOf γ)) ≡ true"
          ]
      , theoremSpecProofLines =
          [ theoremPolicyBoundsPayloadName <> " s a γ pol = pol"
          ]
      }
  , TheoremSpec
      { theoremSpecName = theoremAuthorityWrittenName
      , theoremSpecCommentLines =
          [ "-- Every authorized execution of the case action writes exactly the"
          , "-- requested payload to the authenticated actor's own authority tuple"
          , "-- in the selected scope (the SetRelation point lemma)."
          ]
      , theoremSpecTypeLines =
          [ "∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}"
          , "  (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)"
          , "→ authorityOf (postState (execute cap al)) a (scopeOf γ)"
          , "≡ just (payloadOf γ)"
          ]
      , theoremSpecProofLines =
          [ theoremAuthorityWrittenName <> " cap al = execute-setRel-point cap al"
          ]
      }
  , TheoremSpec
      { theoremSpecName = theoremNoEscalationName
      , theoremSpecCommentLines =
          [ "-- The selected obligation: the written payload is bounded by the"
          , "-- actor's pre-state authority, so no authorized execution of the case"
          , "-- action raises the actor's own authority in the selected scope, with"
          , "-- absence ranked as bottom."
          ]
      , theoremSpecTypeLines = noEscalationTypeLines
      , theoremSpecProofLines =
          [ theoremNoEscalationName <> " {s} {a} {γ} cap al ="
          , "  trans"
          , "    (cong (λ level → authLeq level (authorityOf s a (scopeOf γ)))"
          , "          (" <> theoremAuthorityWrittenName <> " cap al))"
          , "    (" <> theoremPolicyBoundsPayloadName <> " s a γ (policy-ok cap))"
          ]
      }
  ]

-- | The theorem both rules share: the guarantee's case scope term
-- evaluates to exactly the scope argument.
caseScopeTheoremSpec :: TheoremSpec
caseScopeTheoremSpec =
  TheoremSpec
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

-- | The obligation's statement, identical for both rules.
noEscalationTypeLines :: [Text]
noEscalationTypeLines =
  [ "∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}"
  , "  (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)"
  , "→ NoSelfPrivilegeEscalation s (postState (execute cap al))"
  , "                            a (scopeOf γ)"
  ]

theoremCaseScopeName :: Text
theoremCaseScopeName = "case-scope-is-scope-argument"

theoremActorDistinctName :: Text
theoremActorDistinctName = "policy-actor-distinct"

theoremAuthorityUnchangedName :: Text
theoremAuthorityUnchangedName = "actor-authority-unchanged"

theoremPolicyBoundsPayloadName :: Text
theoremPolicyBoundsPayloadName = "policy-bounds-payload"

theoremAuthorityWrittenName :: Text
theoremAuthorityWrittenName = "actor-authority-written"

theoremNoEscalationName :: Text
theoremNoEscalationName = "no-self-escalation"

--------------------------------------------------------------------
-- Deterministic generation: the artifact
--------------------------------------------------------------------

-- | The deterministic generated artifact: the exact module text
-- together with the structured inventory of the rendered theorem
-- blocks the text was assembled from, per case.  The text is built
-- by concatenating exactly the inventoried blocks (plus the fixed
-- surrounding sections and the checked manifests), so the inventory
-- is the generator's own structured record of what it emitted — no
-- source text is ever re-lexed or searched to reconstruct it.
data GeneratedArtifact = GeneratedArtifact
  { artifactCases :: [GeneratedCase]
    -- ^ One entry per case, in authored order.
  , artifactModuleText :: Text
  }
  deriving (Eq, Show)

-- | The rendered theorem blocks of one case: the case's zero-based
-- authored position, the rule its group was rendered for, and each
-- rendered theorem's name with its rendered block lines, in rendering
-- order.
data GeneratedCase = GeneratedCase
  { generatedCasePosition :: Int
  , generatedCaseRule :: NspeRule
  , generatedCaseTheoremBlocks :: [(Text, [Text])]
  }
  deriving (Eq, Show)

-- | Every required theorem of every case of the plan for which the
-- structured generated artifact carries no rendered theorem block in
-- that case's group (or whose group is missing, or was rendered for
-- another rule), each named as @case \<position\>: \<theorem\>@.
-- The requirement is derived from the complete plan — every case,
-- the rule each matched — never from one global list.  This is an
-- inventory check of the generator's own structured output: a
-- missing entry is a generator bug — an internal generated-artifact
-- failure, detected before any checker runs, never an unsupported
-- classification and never a verdict.  Whether each inventoried
-- theorem actually exists in the checked module at exactly its
-- required type is deliberately not decided here, and not by any
-- inspection of source text: the generated module's checked
-- manifests make Agda itself prove it when the checker accepts the
-- module (see 'renderedManifestBlock').
missingRequiredTheorems :: NspeSupportPlan -> GeneratedArtifact -> [Text]
missingRequiredTheorems plan artifact =
  [ "case " <> countText (casePosition casePlan) <> ": " <> theoremSpecName spec
  | casePlan <- NonEmpty.toList (planCases plan)
  , spec <- ruleTheoremSpecs (caseRule casePlan)
  , not (any (carries casePlan spec) (artifactCases artifact))
  ]
  where
    carries casePlan spec generated =
      generatedCasePosition generated == casePosition casePlan
        && generatedCaseRule generated == caseRule casePlan
        && theoremSpecName spec `elem` map fst (generatedCaseTheoremBlocks generated)

-- | Generate the one supported obligation artifact deterministically
-- from the plan's normalized evidence.  The module text depends only
-- on the plan — never on file paths, time, or environment — uses
-- Unix line endings with no carriage returns and no tabs, and ends
-- with exactly one final newline.  Every proof-relevant supported
-- field of the evidence appears: the identities and declared names in
-- the evidence comment block (names escaped through 'quotedName', so
-- no authored text can introduce a physical line break or any Agda
-- syntax), each case's parameter order and types, the ranking,
-- bindings, and policy structure in both the comment block and the
-- transcribed definitions.  The required theorems of every case are
-- rendered from 'ruleTheoremSpecs' into the case's inner theorem
-- module, followed by the checked manifest that makes Agda itself
-- prove each one exists at exactly its required type; the artifact
-- records the rendered theorem blocks per case as its structured
-- inventory.  A singleton rule-1 plan renders in the compatibility
-- layout, every other plan in the general layout (module header).
generatedObligationArtifact :: NspeSupportPlan -> GeneratedArtifact
generatedObligationArtifact plan =
  case planCases plan of
    onlyCase :| []
      | ChangeOtherMatch facts <- caseMatch onlyCase ->
          compatibilityArtifact plan onlyCase facts
    cases -> generalArtifact plan cases

-- | The exact module text of the generated artifact.
renderObligationModule :: NspeSupportPlan -> Text
renderObligationModule = artifactModuleText . generatedObligationArtifact

--------------------------------------------------------------------
-- The compatibility layout: exactly a singleton rule-1 plan
--------------------------------------------------------------------

-- | The original flat module of the singleton change-other
-- obligation, byte-for-byte as before the multi-case milestone: the
-- theorems in the inner module @GeneratedTheorems@, the manifest
-- entries at top level.
compatibilityArtifact
  :: NspeSupportPlan -> NspeCasePlan -> ChangeOtherFacts -> GeneratedArtifact
compatibilityArtifact plan onlyCase facts =
  GeneratedArtifact
    { artifactCases =
        [ GeneratedCase
            { generatedCasePosition = casePosition onlyCase
            , generatedCaseRule = ChangeOtherRule
            , generatedCaseTheoremBlocks = blocks
            }
        ]
    , artifactModuleText =
        Text.unlines
          ( compatibilityPragmaLines
              <> evidenceHeaderLines
              <> sharedEvidenceLines plan
              <> changeOtherEvidenceLines plan onlyCase facts
              <> moduleLines
              <> changeOtherContextLines onlyCase facts
              <> rankingLines plan
              <> changeOtherPolicyLines
              <> changeOtherActionLines
              <> changeOtherProjectionLines
              <> scopeLines
              <> theoremModuleHeaderLines
              <> concatMap snd blocks
              <> compatibilityManifestIntroLines
              <> concatMap renderedManifestBlock changeOtherTheoremSpecs
          )
    }
  where
    blocks =
      [ (theoremSpecName spec, renderedTheoremBlock spec)
      | spec <- changeOtherTheoremSpecs
      ]

compatibilityPragmaLines :: [Text]
compatibilityPragmaLines =
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

compatibilityManifestIntroLines :: [Text]
compatibilityManifestIntroLines =
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

--------------------------------------------------------------------
-- The general layout: position-qualified inner modules per case
--------------------------------------------------------------------

-- | The fixed name of the inner module holding one case's
-- definitions and theorem group, qualified by the case's zero-based
-- authored position.
generatedCaseModuleName :: Int -> Text
generatedCaseModuleName position = "Case" <> countText position

-- | The fixed name of the manifest module of one case.
generatedManifestModuleName :: Int -> Text
generatedManifestModuleName position = "ManifestCase" <> countText position

generalArtifact :: NspeSupportPlan -> NonEmpty NspeCasePlan -> GeneratedArtifact
generalArtifact plan cases =
  GeneratedArtifact
    { artifactCases = map fst rendered
    , artifactModuleText =
        Text.unlines
          ( generalPragmaLines (NonEmpty.length cases)
              <> evidenceHeaderLines
              <> sharedEvidenceLines plan
              <> ["-- selected cases: " <> countText (NonEmpty.length cases)]
              <> concatMap (caseEvidenceLines plan) (NonEmpty.toList cases)
              <> moduleLines
              <> rankingLines plan
              <> concatMap snd rendered
              <> generalManifestIntroLines
              <> concatMap (caseManifestLines . fst) rendered
          )
    }
  where
    rendered = map renderCase (NonEmpty.toList cases)

generalPragmaLines :: Int -> [Text]
generalPragmaLines caseCount =
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
  , "-- selected NoSelfPrivilegeEscalation obligation with "
      <> countText caseCount
      <> " escalation"
  , "-- " <> (if caseCount == 1 then "case" else "cases")
      <> ", each proved in its own inner module qualified by its"
  , "-- zero-based authored case position."
  ]

generalManifestIntroLines :: [Text]
generalManifestIntroLines =
  [ ""
  , "-- Checked theorem manifests.  Each case's manifest module opens that"
  , "-- case's inner module and restates every required theorem's exact"
  , "-- type, defined by the qualified name of the generated theorem itself,"
  , "-- so Agda's acceptance of this module proves that every required"
  , "-- theorem of every case exists at exactly its required type: a name"
  , "-- occurring only in a comment, a string, a hole, or a longer"
  , "-- identifier declares nothing, and a qualified reference into a case's"
  , "-- inner theorem module can never resolve to an imported or otherwise"
  , "-- coincidental outer name."
  ]

-- | One case's section of the general layout: the header comment,
-- the inner module with the case's definitions, and its theorem
-- group — plus the structured inventory of the rendered blocks.
renderCase :: NspeCasePlan -> (GeneratedCase, [Text])
renderCase casePlan =
  ( GeneratedCase
      { generatedCasePosition = position
      , generatedCaseRule = rule
      , generatedCaseTheoremBlocks = blocks
      }
  , [ ""
    , "-- Case " <> countText position <> ": " <> nspeRuleLabel rule <> ", case action "
        <> quotedName (sourcedValue (caseActionName casePlan))
        <> " (action " <> actionIndex (caseActionId casePlan) <> ")."
    , "-- Every definition and theorem of this case lives in the inner module"
    , "-- " <> generatedCaseModuleName position <> ", qualified by the zero-based authored case position."
    , ""
    , "module " <> generatedCaseModuleName position <> " where"
    ]
      <> indentLines 2 (definitionLines <> theoremModuleHeaderLines)
      <> concatMap snd blocks
  )
  where
    position = casePosition casePlan
    rule = caseRule casePlan
    definitionLines =
      case caseMatch casePlan of
        ChangeOtherMatch facts ->
          changeOtherContextLines casePlan facts
            <> changeOtherPolicyLines
            <> changeOtherActionLines
            <> changeOtherProjectionLines
            <> scopeLines
        BoundedSelfUpdateMatch _ ->
          boundedSelfUpdateContextLines casePlan
            <> boundedSelfUpdatePolicyLines
            <> boundedSelfUpdateActionLines
            <> boundedSelfUpdateProjectionLines
            <> scopeLines
    -- The blocks are rendered once, at the depth of the case module's
    -- inner theorem module (two levels below top level), and the very
    -- same lines are concatenated into the text: the inventory is the
    -- emitted text.
    blocks =
      [ (theoremSpecName spec, indentLines 2 (renderedTheoremBlock spec))
      | spec <- ruleTheoremSpecs rule
      ]

-- | One case's manifest module of the general layout.
caseManifestLines :: GeneratedCase -> [Text]
caseManifestLines generated =
  [ ""
  , "module " <> generatedManifestModuleName position <> " where"
  , ""
  , "  open " <> generatedCaseModuleName position
  ]
    <> concatMap (indentLines 2 . renderedManifestBlock) (ruleTheoremSpecs (generatedCaseRule generated))
  where
    position = generatedCasePosition generated

-- | Indent every non-empty line by the given number of spaces (blank
-- lines stay blank, so a nested block never carries trailing spaces).
indentLines :: Int -> [Text] -> [Text]
indentLines width =
  map (\line -> if Text.null line then line else Text.replicate width " " <> line)

--------------------------------------------------------------------
-- Evidence comment blocks
--------------------------------------------------------------------

evidenceHeaderLines :: [Text]
evidenceHeaderLines =
  [ "--"
  , "-- Consumed normalized evidence:"
  , "--"
  ]

-- | The authority-side evidence shared by every case.
sharedEvidenceLines :: NspeSupportPlan -> [Text]
sharedEvidenceLines plan =
  [ "-- model: " <> quotedName (sourcedValue (planModelName plan))
  , "-- guarantee: NoSelfPrivilegeEscalation"
  , "-- authority relation: "
      <> quotedName (sourcedValue (planRelationName plan))
      <> " (relation "
      <> relationIndex (planRelationId plan)
      <> ")"
  , "-- authority subject endpoint: "
      <> endpointEvidence
        plan
        (sourcedValue (planSubjectEndpointName plan))
        (planSubjectEndpointId plan)
        (sourcedValue (planSubjectEntityName plan))
        (planSubjectEntityId plan)
  , "-- authority scope endpoint: "
      <> endpointEvidence
        plan
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
      <> valueEvidence plan (planRankedName (planRankBottom plan)) (planRankedId (planRankBottom plan))
      <> ", rank 1 = "
      <> valueEvidence plan (planRankedName (planRankTop plan)) (planRankedId (planRankTop plan))
  ]

endpointEvidence :: NspeSupportPlan -> Text -> EndpointId -> Text -> EntityId -> Text
endpointEvidence plan endpointName (EndpointId _ position) entityName (EntityId entityPosition) =
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

valueEvidence :: NspeSupportPlan -> Text -> EnumValueId -> Text
valueEvidence plan valueName (EnumValueId _ position) =
  quotedName valueName
    <> " (value "
    <> countText position
    <> " of enum "
    <> enumIndex (planEnumId plan)
    <> ")"

absenceText :: AbsenceLevel -> Text
absenceText AbsenceBottom = "Bottom"

-- | One case's evidence block of the general layout: its position and
-- rule, then the rule's case evidence.
caseEvidenceLines :: NspeSupportPlan -> NspeCasePlan -> [Text]
caseEvidenceLines plan casePlan =
  [ "--"
  , "-- case " <> countText (casePosition casePlan) <> ": " <> nspeRuleLabel (caseRule casePlan)
  ]
    <> case caseMatch casePlan of
      ChangeOtherMatch facts -> changeOtherEvidenceLines plan casePlan facts
      BoundedSelfUpdateMatch facts -> boundedSelfUpdateEvidenceLines plan casePlan facts

-- | The case evidence of a rule-1 case.
changeOtherEvidenceLines :: NspeSupportPlan -> NspeCasePlan -> ChangeOtherFacts -> [Text]
changeOtherEvidenceLines plan casePlan facts =
  [ "-- case action: "
      <> quotedName (sourcedValue (caseActionName casePlan))
      <> " (action "
      <> actionIndex (caseActionId casePlan)
      <> ")"
  , "-- case scope binding: endpoint "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument "
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> " (parameter "
      <> parameterIndex (caseScopeParameterId casePlan)
      <> ")"
  , "-- principal mode: AuthenticatedOnly"
  , "-- parameter 0: "
      <> quotedName (sourcedValue (changeOtherSubjectParameterName facts))
      <> " : EntityRef "
      <> quotedName (sourcedValue (planSubjectEntityName plan))
  , "-- parameter 1: "
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> " : EntityRef "
      <> quotedName (sourcedValue (planScopeEntityName plan))
  , "-- parameter 2: "
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
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
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> "])), And(Not(Equal(Actor, Argument["
      <> quotedName (sourcedValue (changeOtherSubjectParameterName facts))
      <> "])), IsSome(Lookup["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (changeOtherSubjectParameterName facts))
      <> "], "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> "]))))"
  , "-- effect: SetRelation["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (changeOtherSubjectParameterName facts))
      <> "], "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> "]) payload Argument["
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
      <> "]"
  , "-- result: Done"
  ]

-- | The case evidence of a rule-2 case.
boundedSelfUpdateEvidenceLines
  :: NspeSupportPlan -> NspeCasePlan -> BoundedSelfUpdateFacts -> [Text]
boundedSelfUpdateEvidenceLines plan casePlan facts =
  [ "-- case action: "
      <> quotedName (sourcedValue (caseActionName casePlan))
      <> " (action "
      <> actionIndex (caseActionId casePlan)
      <> ")"
  , "-- case scope binding: endpoint "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument "
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> " (parameter "
      <> parameterIndex (caseScopeParameterId casePlan)
      <> ")"
  , "-- principal mode: AuthenticatedOnly"
  , "-- parameter 0: "
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> " : EntityRef "
      <> quotedName (sourcedValue (planScopeEntityName plan))
  , "-- parameter 1: "
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
      <> " : Enum "
      <> quotedName (sourcedValue (planEnumName plan))
  , "-- allow policy: LessOrEqual[order optional "
      <> quotedName (sourcedValue (planEnumName plan))
      <> ", absence as bottom](Some(Argument["
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
      <> "]), Lookup["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Actor, "
      <> quotedName (sourcedValue (planScopeEndpointName plan))
      <> " = Argument["
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
      <> "]))"
  , -- The effect's scope binding is the rule-2 fact the gate verified
    -- (the subject endpoint is bound to Actor by the rule itself).
    "-- effect: SetRelation["
      <> quotedName (sourcedValue (planRelationName plan))
      <> "]("
      <> quotedName (sourcedValue (planSubjectEndpointName plan))
      <> " = Actor, "
      <> quotedName (planBindingEndpointName (selfUpdateEffectScopeBinding facts))
      <> " = Argument["
      <> quotedName (planBindingParameterName (selfUpdateEffectScopeBinding facts))
      <> "]) payload Argument["
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
      <> "]"
  , "-- result: Done"
  ]

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

--------------------------------------------------------------------
-- Transcribed definitions
--------------------------------------------------------------------

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

-- | The de Bruijn spine of a parameter in a context of the given
-- arity: parameter 0 is outermost (@there (… here)@), the last
-- parameter innermost (@here@).
deBruijn :: Int -> ParameterId -> Text
deBruijn arity (ParameterId _ position) = spine (arity - 1 - position)
  where
    spine :: Int -> Text
    spine depth
      | depth <= 0 = "here"
      | depth == 1 = "there here"
      | otherwise = "there (" <> spine (depth - 1) <> ")"

-- | The rule-1 three-parameter context.
changeOtherContextLines :: NspeCasePlan -> ChangeOtherFacts -> [Text]
changeOtherContextLines casePlan facts =
  [ ""
  , "-- The action's parameter context, in declaration order (parameter 0"
  , "-- outermost); the kernel renders the subject entity as UserK, the"
  , "-- scope entity as OrgK, and the two-value authority enum as Role."
  , ""
  , "obligationCtx : Ctx"
  , "obligationCtx = ∅ ▸ entity UserK ▸ entity OrgK ▸ role"
  , ""
  , "-- parameter " <> parameterIndex (changeOtherSubjectParameterId facts) <> " "
      <> quotedName (sourcedValue (changeOtherSubjectParameterName facts))
  , "subjectParam : Var obligationCtx (entity UserK)"
  , "subjectParam = " <> deBruijn 3 (changeOtherSubjectParameterId facts)
  , ""
  , "-- parameter " <> parameterIndex (caseScopeParameterId casePlan) <> " "
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
  , "scopeParam : Var obligationCtx (entity OrgK)"
  , "scopeParam = " <> deBruijn 3 (caseScopeParameterId casePlan)
  , ""
  , "-- parameter " <> parameterIndex (casePayloadParameterId casePlan) <> " "
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
  , "payloadParam : Var obligationCtx role"
  , "payloadParam = " <> deBruijn 3 (casePayloadParameterId casePlan)
  ]

-- | The shared materialized ranking, rendered once per module.
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

changeOtherPolicyLines :: [Text]
changeOtherPolicyLines =
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

changeOtherActionLines :: [Text]
changeOtherActionLines =
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

changeOtherProjectionLines :: [Text]
changeOtherProjectionLines =
  [ ""
  , "-- Request projections."
  , ""
  , "subjectOf : Args obligationCtx → EntityRef UserK"
  , "subjectOf γ = lookupArg γ subjectParam"
  , ""
  , "scopeOf : Args obligationCtx → EntityRef OrgK"
  , "scopeOf γ = lookupArg γ scopeParam"
  ]

-- | The rule-2 two-parameter context.
boundedSelfUpdateContextLines :: NspeCasePlan -> [Text]
boundedSelfUpdateContextLines casePlan =
  [ ""
  , "-- The action's parameter context, in declaration order (parameter 0"
  , "-- outermost); the kernel renders the scope entity as OrgK and the"
  , "-- two-value authority enum as Role, and the authenticated actor is a"
  , "-- reference of the subject entity, rendered as UserK."
  , ""
  , "obligationCtx : Ctx"
  , "obligationCtx = ∅ ▸ entity OrgK ▸ role"
  , ""
  , "-- parameter " <> parameterIndex (caseScopeParameterId casePlan) <> " "
      <> quotedName (sourcedValue (caseScopeParameterName casePlan))
  , "scopeParam : Var obligationCtx (entity OrgK)"
  , "scopeParam = " <> deBruijn 2 (caseScopeParameterId casePlan)
  , ""
  , "-- parameter " <> parameterIndex (casePayloadParameterId casePlan) <> " "
      <> quotedName (sourcedValue (casePayloadParameterName casePlan))
  , "payloadParam : Var obligationCtx role"
  , "payloadParam = " <> deBruijn 2 (casePayloadParameterId casePlan)
  ]

boundedSelfUpdatePolicyLines :: [Text]
boundedSelfUpdatePolicyLines =
  [ ""
  , "-- The single authored allow-policy comparison, transcribed constructor"
  , "-- by constructor: the requested payload, lifted, is bounded by the"
  , "-- actor's own authority in the scope parameter (absence as bottom)."
  , ""
  , "allowPolicy : Term authed obligationCtx bool"
  , "allowPolicy = leqT (maybe-ord role-ord)"
  , "                   (justT (arg payloadParam))"
  , "                   (memT actorT (arg scopeParam))"
  ]

boundedSelfUpdateActionLines :: [Text]
boundedSelfUpdateActionLines =
  [ ""
  , "-- The complete case action: AuthenticatedOnly principal mode, the"
  , "-- transcribed allow policy, and the SetRelation effect writing the"
  , "-- authority relation at (Actor, scope parameter) with the payload"
  , "-- parameter; the effect descriptor forces the Done result."
  , ""
  , "obligationAction : Action authenticatedOnly obligationCtx doneD"
  , "obligationAction ="
  , "  mutA (authP allowPolicy)"
  , "       (setRelE actorT (arg scopeParam) (arg payloadParam))"
  ]

boundedSelfUpdateProjectionLines :: [Text]
boundedSelfUpdateProjectionLines =
  [ ""
  , "-- Request projections."
  , ""
  , "scopeOf : Args obligationCtx → EntityRef OrgK"
  , "scopeOf γ = lookupArg γ scopeParam"
  , ""
  , "payloadOf : Args obligationCtx → Role"
  , "payloadOf γ = lookupArg γ payloadParam"
  ]

scopeLines :: [Text]
scopeLines =
  [ ""
  , "-- The case scope binding: the guarantee's selected scope term is the"
  , "-- scope parameter, so it evaluates to exactly the scope argument the"
  , "-- theorems below quantify over."
  , ""
  , "caseScopeTerm : Term authed obligationCtx (entity OrgK)"
  , "caseScopeTerm = arg scopeParam"
  ]

-- | The fixed name of the inner module the required theorems of a
-- case are declared in.  The checked manifest references every
-- theorem qualified through this module name, so only a real
-- declaration of this module can satisfy a manifest entry — never an
-- imported or otherwise coincidental outer name, and never any
-- non-declaration text.
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

-- | The rendered checked-manifest entry of one required theorem: a
-- fresh declaration restating the theorem's exact type from the same
-- 'TheoremSpec', defined by the qualified name of the generated
-- theorem.  Agda accepts the entry only if the inner theorem module
-- (of the case whose manifest module it lives in) really declares the
-- theorem and its type is exactly the required one.
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
-- plan-derived required-theorem completeness check, then the checker.
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
       in case missingRequiredTheorems plan artifact of
            missing : more ->
              pure (Left (GeneratedTheoremsMissing (missing :| more)))
            [] -> do
              checkOutcome <- runner (artifactModuleText artifact)
              pure $ case checkOutcome of
                Left failure -> Left failure
                Right () ->
                  Right (VerificationVerified (planObligation plan))
