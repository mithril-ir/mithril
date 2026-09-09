{-# LANGUAGE OverloadedStrings #-}

-- | The public boundary of the Wasp target adapter: pure,
-- deterministic rendering of a supported NoSelfPrivilegeEscalation
-- plan as a closed Wasp 0.25.0 application bundle — the /Wasp
-- Confinement Profile v0/ for a singleton rule-1 (change-other) plan,
-- the /Wasp Confinement Profile v1/ for the exact ordered rule-1,
-- rule-2 (bounded self-update) case pair — and the pure confinement
-- check of a source-root snapshot against a regenerated bundle.  See
-- @docs\/current-scope.md@ for the supported slice, result meanings,
-- trusted components, and explicit non-claims.
--
-- > normalized opaque document
-- >   -> shared NoSelfPrivilegeEscalation support gate
-- >   -> profile dispatcher over the ordered rule tags
-- >   -> fixed role-derived target names
-- >   -> deterministic closed Wasp bundle        ('renderWaspBundle')
--
-- 'renderWaspBundle' accepts exactly a
-- @'Mithril.Core.Validation.CoreDocument' 'Normalized'@ — the stage
-- indexes make a merely typed (or earlier) document unacceptable,
-- pinned by downstream compile-fail probes — and consumes the same
-- shared support plan the verifier consumes: a document the verifier
-- reports unsupported is unsupported here for exactly the same
-- deterministic reasons.  The profile dispatch is fail-closed and
-- decided over the plan's ordered rule tags alone, never by
-- re-deriving a rule or inspecting the normalized model: exactly
-- @[rule 1]@ selects Profile v0, exactly @[rule 1, rule 2]@ in
-- authored order selects Profile v1, and every other plan is
-- refused.  Wasp profile support is narrower than verifier support,
-- so a document the verifier reports VERIFIED can still be
-- UNSUPPORTED here.  The emitter restates no part of the
-- supported-shape classification and no ranking logic of its own.
-- The bundle depends only on the document's content, never on its
-- filesystem path, time, or environment; the same normalized
-- document always renders to the same bytes.  The selected profile
-- is an explicit identity ('WaspProfile') carried by the bundle and
-- its summary — never inferred from an operation count — and the
-- summary lists the complete ordered operation list, one operation
-- per lowered case.
--
-- == Provenance
--
-- Rendering establishes supported-shape lowering only: a rendered
-- bundle attests that the shared support gate accepted the document,
-- and no rendered byte claims the document was verified.  VERIFIED
-- provenance belongs to the CLI generation path
-- ("Mithril.Command.Wasp"), which requires the production verifier
-- to report VERIFIED before rendering and states so in its report.
--
-- == The bundle
--
-- A closed Wasp application whose complete server-capable and
-- security-sensitive input surface is owned by the generator.  Every
-- identifier, filename, and route is a fixed target name derived
-- from the role a declaration plays in the supported shape, never an
-- authored name, so no authored name can collide with a target name
-- and the closed path inventory is the same for every supported
-- document and for both profiles ("Mithril.Core.Internal.Wasp"
-- states the generated files and the naming rule).  The finite role
-- ranking is the materialized enum ranking of the normalized Core as
-- validated by the shared plan; no independent ordering authority
-- exists.
--
-- == The summary's compatibility view
--
-- The summary's complete trusted representation is the constructor
-- 'WaspProfileSummary' (the explicit 'summaryProfile' and the
-- complete ordered 'summaryOperations').  The record form
-- @WaspBundleSummary { summaryModelName, summaryGuarantee,
-- summaryCaseAction, summaryOperation, summaryRoute,
-- summaryManagedPaths }@ is the bidirectional pattern synonym
-- 'WaspBundleSummary', a /first-operation compatibility view/:
-- matching it projects operation 0 (for Profile v0 the one
-- operation; for Profile v1 the rule-1 operation, with
-- 'summaryOperations' the authoritative complete list), and
-- constructing through it builds the Profile-v0 singleton summary of
-- that one operation.  The three selectors 'summaryCaseAction',
-- 'summaryOperation', and 'summaryRoute' are exactly that view's
-- projections.  Likewise the CLI boundary ("Mithril.Command.Wasp")
-- offers the two-argument @WaspNotConfined root violations@ view of
-- its profile-aware outcome.
--
-- == Confinement
--
-- 'checkWaspConfinement' takes the regenerated closed path inventory
-- plus exact bytes as the authority: every managed file present as a
-- private regular file (link count one) and byte-identical, nothing
-- else present except the directories the managed paths require; a
-- symbolic link or a hard link anywhere is a violation, and
-- installation, build, migration, and environment outputs are never
-- part of the source root.  The snapshot itself is validated first
-- (non-canonical, absolute, aliased, or duplicate entries are
-- rejected before any lookup).  A denylist scan labels /why/ an
-- already-rejected file is dangerous but is never the authority.
-- 'OwnershipCheck' is the replacement rule a regeneration applies to
-- an existing root: it recognizes exactly the two literal ownership
-- markers over the common inventory, so an owned root of either
-- profile is replaced as a whole by a regeneration of either profile;
-- 'FullCheck' requires the exact marker, inventory, and bytes of the
-- requested profile.  The confinement claim is a statement about the
-- source root as walked at the time of checking or generation;
-- @docs\/current-scope.md@ states what lies outside it.
--
-- == Failure classification
--
-- 'WaspRenderingUnsupported': the document lies outside the shared
-- support rule (authored shapes, sorted and deduplicated reasons), or
-- inside it — possibly VERIFIED by the shared verifier — but outside
-- both profiles: a singleton rule-2 case (one reason at the case
-- path), a two-case plan whose ordered tags are not @[rule 1, rule
-- 2]@ (one reason at every case whose tag is not the one Profile v1
-- requires at its position), or three or more cases (one reason at
-- the guarantee path).
-- 'WaspRenderingInvariants': the normalized model is inconsistent —
-- forged or drifted evidence no pipeline-produced document can
-- exhibit, decided by the shared gate before anything is lowered; an
-- internal error of the tool (exit status 2 at the tool boundary).
module Mithril.Core.Wasp
  ( -- * Pipeline stage
    Normalized

    -- * Bundles
  , WaspBundle
  , waspBundleProfile
  , waspBundleFiles
  , waspBundleSummary
  , WaspManagedFile (..)
  , WaspBundleSummary (..)
  , WaspOperationSummary (..)
  , NspeRule (..)
  , nspeRuleLabel

    -- * Profiles
  , WaspProfile (..)
  , waspProfileName
  , waspProfileLabel
  , waspTargetVersion

    -- * Failures
  , WaspRenderingFailure (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation (..)

    -- * Rendering
  , renderWaspBundle

    -- * Confinement
  , RootEntry (..)
  , EntryKind (..)
  , ConfinementMode (..)
  , ConfinementViolation (..)
  , checkWaspConfinement
  , normalizeConfinementViolations
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Normalized
  )
import Mithril.Core.Internal.NspeSupportPlan
  ( NspeRule (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  , nspeRuleLabel
  )
import Mithril.Core.Internal.Wasp
  ( WaspBundle
  , WaspBundleSummary (..)
  , WaspManagedFile (..)
  , WaspOperationSummary (..)
  , WaspProfile (..)
  , WaspRenderingRefusal (..)
  , bundleFiles
  , bundleProfile
  , bundleSummary
  , profileLabel
  , profileNameOf
  , renderBundleFromModel
  , waspVersion
  )
import Mithril.Core.Internal.WaspConfinement
  ( ConfinementMode (..)
  , ConfinementViolation (..)
  , EntryKind (..)
  , RootEntry (..)
  , checkConfinement
  , normalizeConfinementViolations
  )

-- | Why 'renderWaspBundle' refused (module header).
data WaspRenderingFailure
  = -- | Outside the shared support rule, or outside both Wasp
    -- profiles although the shared gate accepted the document (a
    -- verified singleton rule-2 case, a verified pair in any order
    -- other than rule 1 then rule 2, or three or more verified
    -- cases): deterministic, sorted, deduplicated, source-anchored
    -- reasons.
    WaspRenderingUnsupported (NonEmpty UnsupportedReason)
  | -- | Forged or drifted normalized evidence, decided by the shared
    -- gate before any lowering: a tool error, never a document
    -- problem and never a verdict.
    WaspRenderingInvariants (NonEmpty VerifierInvariantViolation)
  deriving (Eq, Show)

-- | The explicit profile a bundle instantiates.
waspBundleProfile :: WaspBundle -> WaspProfile
waspBundleProfile = bundleProfile

-- | The managed files of a bundle, sorted by root-relative path and
-- pairwise distinct — the closed path inventory, the same for every
-- supported document and for both profiles.
waspBundleFiles :: WaspBundle -> [WaspManagedFile]
waspBundleFiles = bundleFiles

-- | The report-facing summary of a bundle: the explicit profile and
-- the complete ordered operation list among its fields (the
-- constructor 'WaspProfileSummary'); the pattern synonym
-- 'WaspBundleSummary' and the selectors 'summaryCaseAction',
-- 'summaryOperation', and 'summaryRoute' are the first-operation
-- compatibility view of the summary (module header).
waspBundleSummary :: WaspBundle -> WaspBundleSummary
waspBundleSummary = bundleSummary

-- | The name of a profile (its manifest @profile@ field).
waspProfileName :: WaspProfile -> Text
waspProfileName = profileNameOf

-- | The human-readable label of a profile, as the reports state it.
waspProfileLabel :: WaspProfile -> Text
waspProfileLabel = profileLabel

-- | The exact Wasp version every bundle pins.
waspTargetVersion :: Text
waspTargetVersion = waspVersion

-- | Render the closed Wasp bundle of a normalized document (the
-- module header states the pipeline, the profiles, and what
-- rendering establishes).
--
-- Pure and deterministic.  Only a @'CoreDocument' 'Normalized'@ is
-- accepted; the typed normalized model is consumed as trusted
-- normalized information through the shared support plan, so no
-- decoding, name resolution, type inference, endpoint binding, rank
-- re-derivation, or policy evaluation is repeated here.
renderWaspBundle
  :: CoreDocument Normalized -> Either WaspRenderingFailure WaspBundle
renderWaspBundle (CoreDocument model) =
  case renderBundleFromModel model of
    Left (RenderUnsupported reasons) -> Left (WaspRenderingUnsupported reasons)
    Left (RenderInvariant violations) -> Left (WaspRenderingInvariants violations)
    Right bundle -> Right bundle

-- | Check a snapshot of a Wasp source root against a regenerated
-- bundle (module header): the sorted, deduplicated violations, empty
-- exactly when the root is the closed profile ('FullCheck') or may be
-- initialized or replaced by a regeneration ('OwnershipCheck').
checkWaspConfinement
  :: ConfinementMode -> WaspBundle -> [RootEntry] -> [ConfinementViolation]
checkWaspConfinement = checkConfinement
