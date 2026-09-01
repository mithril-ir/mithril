{-# LANGUAGE OverloadedStrings #-}

-- | The first target adapter consuming normalized Core: pure,
-- deterministic rendering of exactly two NoSelfPrivilegeEscalation
-- plan shapes — the singleton rule-1 (change-other) plan, lowered as
-- the /Wasp Confinement Profile v0/, and the exact ordered rule-1,
-- rule-2 (bounded self-update) case pair, lowered as the /Wasp
-- Confinement Profile v1/ — as a closed Wasp 0.25.0 application
-- bundle, and the pure confinement check of a source-root snapshot
-- against a regenerated bundle.  The profiles' filenames, manifests,
-- and this public boundary are frozen for these slices; general or
-- additional adapter formats remain open.
--
-- Four scope statements, kept separate:
--
-- * The shared verifier ("Mithril.Core.Verification") supports one
--   selected NoSelfPrivilegeEscalation guarantee whose non-empty
--   case collection is independently classified, case by case, as
--   exact rule-1 (change-other) and\/or exact rule-2 (bounded
--   self-update) cases — the existing exact rule-1\/rule-2 case
--   family.
-- * Wasp Profile v0 lowers only exactly one rule-1 case: one Action,
--   its bytes, marker, manifest, and inventory exactly what they were
--   before Profile v1 existed.
-- * Wasp Profile v1 lowers only the exact ordered @[rule 1, rule 2]@
--   pair — the change-other case at position 0 and the bounded
--   self-update case at position 1, in authored order — as two
--   Actions exported by the one generated operation file, over the
--   same fourteen managed paths.  Arbitrary multi-case lowering is
--   not implemented: a singleton rule-2 case, two rule-1 cases, the
--   reversed pair, two rule-2 cases, and three or more cases select
--   no profile.
-- * Therefore a document the shared verifier reports VERIFIED may
--   still be 'WaspRenderingUnsupported' here, because it lies outside
--   both profiles — refused by the profile dispatcher over the plan's
--   ordered rule tags before any lowering.  VERIFIED-but-Wasp-
--   UNSUPPORTED remains a valid outcome.
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
-- deterministic reasons, a verified plan outside both profiles is
-- refused by the dispatcher over the plan's ordered rule tags (never
-- by re-deriving a rule or inspecting the normalized model), and the
-- emitter restates no part of the supported-shape classification and
-- no ranking logic of its own.  The bundle depends only on the
-- document's content, never on its filesystem path, time, or
-- environment; the same normalized document always renders to the
-- same bytes.  The selected profile is an explicit identity
-- ('WaspProfile') carried by the bundle and its summary — never
-- inferred from an operation count — and the summary lists the
-- complete ordered operation list, one operation per lowered case.
--
-- == The frozen adapter boundary and its compatibility views
--
-- This boundary was frozen before Profile v1 existed, and source
-- written against it keeps compiling: the summary's complete trusted
-- representation is the constructor 'WaspProfileSummary' (the
-- explicit 'summaryProfile' and the complete ordered
-- 'summaryOperations'), while the record surface of that time —
-- @WaspBundleSummary { summaryModelName, summaryGuarantee,
-- summaryCaseAction, summaryOperation, summaryRoute,
-- summaryManagedPaths }@ — remains available as the bidirectional
-- pattern synonym 'WaspBundleSummary', a /first-operation
-- compatibility view/: matching it projects operation 0 (for Profile
-- v0 exactly the former singleton summary; for Profile v1 the rule-1
-- operation, with 'summaryOperations' the authoritative complete
-- list), and constructing through it builds the Profile-v0 singleton
-- summary of that one operation.  The three selectors
-- 'summaryCaseAction', 'summaryOperation', and 'summaryRoute' are
-- exactly that view's projections.  Likewise the CLI boundary
-- ("Mithril.Command.Wasp") keeps its two-argument
-- @WaspNotConfined root violations@ construction and matching next
-- to the profile-aware outcome it now reports.
--
-- What rendering establishes: supported-shape lowering only.  A
-- rendered bundle attests that the shared support gate accepted the
-- document; no rendered byte claims the document was verified.
-- VERIFIED provenance belongs to the CLI generation path
-- ("Mithril.Command.Wasp"), which requires the production verifier
-- to report VERIFIED before rendering and states so in its report.
--
-- What the bundle is: a normal Wasp 0.25.0 application on PostgreSQL
-- whose complete server-capable and security-sensitive input surface
-- is owned by the generator — @main.wasp.ts@, @schema.prisma@, the
-- Wasp Action declaration(s), the generated TypeScript Action
-- implementation(s) in the one file @src\/mithrilCaseAction.ts@
-- (Wasp authentication required, @context.user.id@ as the only
-- identity, argument validation, authorization reads and the
-- @SetRelation@ write in one Prisma interactive transaction at
-- @Serializable@ isolation with a bounded deterministic @P2034@
-- retry, no raw SQL — the rule-1 Action @mithrilCaseAction@ at
-- @\/operations\/mithril-case-action@ and, in Profile v1 only, the
-- rule-2 Action @mithrilSelfUpdateAction@ at
-- @\/operations\/mithril-self-update-action@, which writes the
-- actor's own tuple to a payload bounded by the actor's pre-state
-- authority and accepts no subject argument), the dependency,
-- TypeScript, and Vite configuration, the Wasp root marker, the
-- profile's fixed-bytes Mithril ownership marker, the ignore files, a
-- minimal static client shell, and a deterministic generation
-- manifest (format version 0 for Profile v0, 1 for Profile v1, with
-- the complete ordered case-to-operation mapping).  Every identifier,
-- filename, and route of the bundle is a fixed target name derived
-- from the role a declaration plays in the supported shape (or, for
-- enum values, from the canonical declaration position of the
-- value's identity), never an authored name — so no authored name can
-- collide with a Prisma scalar type, a Wasp auth model, a TypeScript
-- keyword, or another target name, and the closed path inventory is
-- the same for every supported document and for both profiles.
-- Authored names survive only as escaped metadata (comments, string
-- literals, and the manifest's explicit authored-to-target mapping).
-- The finite role ranking is the materialized enum ranking of the
-- normalized Core as validated by the shared plan; no independent
-- ordering authority exists.
--
-- What confinement means ('checkWaspConfinement'): the authority is
-- the regenerated closed path inventory plus exact bytes — every
-- managed file present as a private regular file (link count one)
-- and byte-identical, nothing else present except the directories
-- the managed paths require; a symbolic link or a hard link anywhere
-- is a violation; installation, build, migration, and environment
-- outputs are never part of the source root.  The snapshot itself is
-- validated first: non-canonical, absolute, aliased, or duplicate
-- entries are rejected before any lookup.  A denylist scan labels
-- /why/ an already-rejected file is dangerous (a second Prisma
-- import, a raw-query API, a database driver, dynamic code, an
-- additional operation or server path, dependency or provider
-- drift) but is never the authority.  The 'OwnershipCheck' mode is
-- the replacement rule a regeneration applies to an existing root:
-- it recognizes exactly the two literal ownership markers (Profile v0
-- and Profile v1) over the common inventory, so an owned root of
-- either profile is replaced as a whole by a regeneration of either
-- profile (v0 → v1 and v1 → v0 transitions), while 'FullCheck'
-- requires the exact marker, inventory, and bytes of the requested
-- profile.
--
-- What the confinement claim covers, and what it excludes: the
-- checker establishes that the source root it walked was, at the
-- time of checking or generation, exactly the clean regenerated
-- profile (repository-authored alternate server paths are rejected).
-- It does not cover malicious concurrent same-user mutation after the
-- final check, privileged users or malicious same-user processes in
-- general (the generated root is created private, mode 0700, which
-- keeps other unprivileged users out and nothing more), malicious
-- changes to the checker or the CI that runs it, compromise of Wasp,
-- Node, Prisma, or PostgreSQL dependencies, external processes
-- holding database credentials, or tampering after the Wasp build.
--
-- What this is not: not a general Wasp backend, not a whole-product
-- generator, not a complete verifier, not a policy evaluator, and
-- not a runtime sandbox.  No semantic-preservation theorem between
-- the Core semantics and the generated TypeScript exists — a rendered
-- bundle is trusted correspondence evidence, documented per the
-- adapter table, never a proof; Wasp, Node, Prisma, PostgreSQL, the
-- templates, and the lowering are trusted components.
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
-- compatibility view of the frozen boundary (module header).
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
-- module header states the pipeline, the profile, what rendering
-- establishes, and the exact non-claims).
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
