{-# LANGUAGE OverloadedStrings #-}

-- | The first target adapter consuming normalized Core: pure,
-- deterministic rendering of exactly the singleton rule-1
-- (change-other) NoSelfPrivilegeEscalation plan — the one shape the
-- /Wasp Confinement Profile v0/ covers — as a closed Wasp 0.25.0
-- application bundle, and the pure confinement check of a source-root
-- snapshot against a regenerated bundle.  The profile's filenames,
-- manifest, and this public boundary are frozen for this slice;
-- general or additional adapter formats remain open.
--
-- Three scope statements, kept separate:
--
-- * The shared verifier ("Mithril.Core.Verification") supports one
--   selected NoSelfPrivilegeEscalation guarantee whose non-empty
--   case collection is independently classified, case by case, as
--   exact rule-1 (change-other) and\/or exact rule-2 (bounded
--   self-update) cases.
-- * Wasp Profile v0 lowers only exactly one rule-1 case: no rule-2
--   lowering, no multi-operation lowering, and no second route or
--   runtime scenario exist.
-- * Therefore a document the shared verifier reports VERIFIED may
--   still be 'WaspRenderingUnsupported' here, because it lies outside
--   Profile v0 (a rule-2 case, or several cases) — refused by the
--   profile's capability gate before any lowering.
--
-- > normalized opaque document
-- >   -> shared NoSelfPrivilegeEscalation support gate
-- >   -> fixed role-derived target names
-- >   -> deterministic closed Wasp bundle        ('renderWaspBundle')
--
-- 'renderWaspBundle' accepts exactly a
-- @'Mithril.Core.Validation.CoreDocument' 'Normalized'@ — the stage
-- indexes make a merely typed (or earlier) document unacceptable,
-- pinned by downstream compile-fail probes — and consumes the same
-- shared support plan the verifier consumes: a document the verifier
-- reports unsupported is unsupported here for exactly the same
-- deterministic reasons, a verified plan outside Profile v0 is
-- refused by the capability gate over the plan's rule tags (never by
-- re-deriving a rule), and the emitter restates no part of the
-- supported-shape classification and no ranking logic of its own.
-- The bundle depends only on the document's content, never on its
-- filesystem path, time, or environment; the same normalized
-- document always renders to the same bytes.
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
-- Wasp Action declaration, the generated TypeScript Action
-- implementation (Wasp authentication required, @context.user.id@ as
-- the only identity, argument validation, authorization reads and
-- the @SetRelation@ write in one Prisma interactive transaction at
-- @Serializable@ isolation with a bounded deterministic @P2034@
-- retry, no raw SQL), the dependency, TypeScript, and Vite
-- configuration, the Wasp root marker, the Mithril ownership marker,
-- the ignore files, a minimal static client shell, and a
-- deterministic generation manifest.  Every identifier, filename,
-- and route of the bundle is a fixed target name derived from the
-- role a declaration plays in the supported shape (or, for enum
-- values, from the canonical declaration position of the value's
-- identity), never an authored name — so no authored name can
-- collide with a Prisma scalar type, a Wasp auth model, a TypeScript
-- keyword, or another target name, and the closed path inventory is
-- the same for every supported document.  Authored names survive
-- only as escaped metadata (comments, string literals, and the
-- manifest's explicit authored-to-target mapping).  The finite role
-- ranking is the materialized enum ranking of the normalized Core as
-- validated by the shared plan; no independent ordering authority
-- exists.
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
-- the replacement rule a regeneration applies to an existing root.
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
-- the Core semantics and the generated TypeScript exists; Wasp,
-- Node, Prisma, PostgreSQL, the templates, and the lowering are
-- trusted components.
--
-- == Failure classification
--
-- 'WaspRenderingUnsupported': the document lies outside the shared
-- support rule (authored shapes, sorted and deduplicated reasons), or
-- inside it — possibly VERIFIED by the shared verifier — but outside
-- the Profile-v0 capability: a singleton rule-2 case (one reason at
-- the case path) or several cases (one reason at the guarantee path).
-- 'WaspRenderingInvariants': the normalized model is inconsistent —
-- forged or drifted evidence no pipeline-produced document can
-- exhibit, decided by the shared gate before anything is lowered; an
-- internal error of the tool (exit status 2 at the tool boundary).
module Mithril.Core.Wasp
  ( -- * Pipeline stage
    Normalized

    -- * Bundles
  , WaspBundle
  , waspBundleFiles
  , waspBundleSummary
  , WaspManagedFile (..)
  , WaspBundleSummary (..)
  , waspProfileName
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
  ( UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  )
import Mithril.Core.Internal.Wasp
  ( WaspBundle
  , WaspBundleSummary (..)
  , WaspManagedFile (..)
  , WaspRenderingRefusal (..)
  , bundleFiles
  , bundleSummary
  , profileName
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
  = -- | Outside the shared support rule, or outside Wasp Profile v0
    -- although the shared gate accepted the document (a verified
    -- rule-2 case or several verified cases): deterministic,
    -- sorted, deduplicated, source-anchored reasons.
    WaspRenderingUnsupported (NonEmpty UnsupportedReason)
  | -- | Forged or drifted normalized evidence, decided by the shared
    -- gate before any lowering: a tool error, never a document
    -- problem and never a verdict.
    WaspRenderingInvariants (NonEmpty VerifierInvariantViolation)
  deriving (Eq, Show)

-- | The managed files of a bundle, sorted by root-relative path and
-- pairwise distinct — the closed path inventory, the same for every
-- supported document.
waspBundleFiles :: WaspBundle -> [WaspManagedFile]
waspBundleFiles = bundleFiles

-- | The report-facing summary of a bundle.
waspBundleSummary :: WaspBundle -> WaspBundleSummary
waspBundleSummary = bundleSummary

-- | The name of the profile every bundle instantiates.
waspProfileName :: Text
waspProfileName = profileName

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
