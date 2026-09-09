-- | The Mithril Core v0 verifier boundary: one deliberately narrow
-- proof slice over typed normalized Core.
--
-- > normalized opaque document
-- >   -> pure deterministic support gate
-- >   -> deterministic generated Agda obligation module
-- >   -> Agda 2.8.0 safe check across a process boundary
-- >   -> VERIFIED or UNSUPPORTED
--
-- 'verifyCoreDocument' accepts exactly a
-- @'Mithril.Core.Validation.CoreDocument' 'Normalized'@ — the stage
-- indexes make a merely typed (or earlier) document unacceptable —
-- and decides, first and purely, whether the document lies inside
-- the supported slice: exactly one selected
-- @NoSelfPrivilegeEscalation@ guarantee whose non-empty case
-- collection consists entirely of cases each matching exactly one of
-- the two supported proof rules, rule 1 (/change-other/) or rule 2
-- (/bounded self-update/).  The shared support gate
-- ("Mithril.Core.Internal.NspeSupportPlan") states the exact rules;
-- see @docs\/current-scope.md@ for the supported slice, result
-- meanings, trusted components, and explicit non-claims.  Every
-- authored case is classified independently in authored order and
-- tagged with its rule; one case outside both rules makes the whole
-- obligation unsupported.  The gate inspects stored identities and
-- evidence structurally: it never compares raw JSON bytes,
-- recognizes file names, hashes the model, repeats parsing,
-- resolution, or type inference, or evaluates policy, and it
-- deliberately rejects semantically equivalent but differently
-- authored shapes as unsupported.
--
-- For a supported document the boundary deterministically generates
-- one Agda obligation module from the normalized evidence — one
-- complete proof group per case, qualified by the case's zero-based
-- authored position — checks that the generator's structured
-- artifact inventory carries every required theorem of every case,
-- materializes the module together with the compile-time-embedded
-- trusted kernel modules into a fresh isolated workspace, and has
-- exactly Agda 2.8.0 check it with @--safe --no-libraries
-- --ignore-interfaces@.  The generated module carries a checked
-- theorem manifest per case, so the checker's acceptance itself
-- proves that every required theorem of every case exists at exactly
-- its required type; no source text is ever searched for theorem
-- names.
--
-- == Result semantics
--
-- * 'VerificationVerified': every selected case of the document's
--   one selected obligation is supported, the deterministic artifact
--   was generated, and every required named theorem of every case
--   was accepted by the configured checker; the result records every
--   case with its position, rule, action, and checked theorem
--   inventory ('VerifiedCase').
-- * 'VerificationUnsupported': the normalized document lies outside
--   the supported slice.  Decided by the pure gate before any checker
--   runs, with non-empty, deterministic, sorted, deduplicated
--   reasons.  A document selecting no guarantees is unsupported,
--   never vacuously verified.
-- * No @VIOLATED@ outcome exists: it has no representation in this
--   vocabulary.  In particular, an Agda refusal after the gate
--   accepted the document is a tool failure, never a semantic
--   verdict.
-- * 'VerificationFailure' (the 'Left' side) means the verification
--   mechanism itself could not be trusted to complete: a forged or
--   drifted normalized model, a structured generated artifact missing
--   a required theorem block, a missing or unlaunchable checker, a
--   checker version other than exactly 2.8.0, a workspace failure, a
--   nonzero checker exit after gate acceptance, or checker
--   termination by a signal.  These exit with status 2 at the tool
--   boundary.
--
-- A successful verification establishes exactly that the selected
-- cases of the one selected obligation of the checked document were
-- checked against the trusted Agda kernel semantics.  Nothing else
-- about the document is verified, and the Haskell frontend and
-- generator, the embedded kernel modules, the Agda toolchain, and
-- the support rules themselves remain trusted components.
module Mithril.Core.Verification
  ( -- * Pipeline stage
    Normalized

    -- * Results
  , VerificationResult (..)
  , VerifiedObligation (..)
  , VerifiedCase (..)
  , NspeRule (..)
  , nspeRuleLabel
  , UnsupportedReason (..)

    -- * Failures
  , VerificationFailure (..)
  , VerifierInvariantViolation (..)

    -- * Verification
  , verifyCoreDocument

    -- * Reason and violation normalization
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations
  ) where

import Mithril.Core.Internal.AgdaChecker (agdaCheckerRunner)
import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Normalized
  )
import Mithril.Core.Internal.Verify
  ( NspeRule (..)
  , UnsupportedReason (..)
  , VerificationFailure (..)
  , VerificationResult (..)
  , VerifiedCase (..)
  , VerifiedObligation (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations
  , nspeRuleLabel
  , verifyModelWith
  )

-- | Verify a normalized document against the supported slice (the
-- module header states the pipeline and the exact result semantics;
-- "Mithril.Core.Internal.NspeSupportPlan" states the rules).
--
-- Only a @'CoreDocument' 'Normalized'@ is accepted; the typed
-- normalized model is consumed as trusted normalized information, so
-- no decoding, name resolution, type inference, endpoint binding, or
-- policy evaluation is repeated here.  The support decision and the
-- generated artifact are pure and deterministic; the 'IO' exists
-- exclusively to invoke the external Agda 2.8.0 checker across a
-- process boundary in a fresh isolated workspace, cleaned on every
-- path.
verifyCoreDocument
  :: CoreDocument Normalized
  -> IO (Either VerificationFailure VerificationResult)
verifyCoreDocument (CoreDocument model) =
  verifyModelWith agdaCheckerRunner model
