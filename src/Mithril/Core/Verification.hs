-- | The first Mithril Core v0 verifier boundary: one connected,
-- deliberately narrow proof slice over typed normalized Core.
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
-- and decides, first and purely, whether the document lies inside the
-- one implemented support rule: a document selecting exactly one
-- guarantee, a @NoSelfPrivilegeEscalation@ guarantee with exactly one
-- case, whose authority, payload ordering, case action, parameters,
-- @SetRelation@ effect bindings and payload, case scope, and allow
-- policy correspond structurally to the already-mechanized sound
-- proof rule of the Agda spike's safe @Membership.changeRole@ slice
-- (the internal support gate states the exact rule).  The gate
-- inspects stored identities and evidence structurally: it never
-- compares raw JSON bytes, recognizes file names, hashes the model,
-- repeats parsing, resolution, or type inference, or evaluates
-- policy, and it deliberately rejects semantically equivalent but
-- differently authored shapes as unsupported.
--
-- For a supported document the boundary deterministically generates
-- one Agda obligation module from the normalized evidence, checks
-- that the generator's structured artifact inventory carries every
-- required theorem, materializes the module together with the
-- compile-time-embedded trusted kernel modules into a fresh isolated
-- workspace, and has exactly Agda 2.8.0 check it with @--safe
-- --no-libraries --ignore-interfaces@ — the generated module ends in
-- a checked theorem manifest, so the checker's acceptance itself
-- proves that every required theorem exists at exactly its required
-- type (no source text is ever searched for theorem names).
--
-- == Result semantics
--
-- * 'VerificationVerified': every selected obligation of the
--   document — there is exactly one in a supported document — is
--   supported, the deterministic artifact was generated, and every
--   required named theorem was accepted by the configured checker.
-- * 'VerificationUnsupported': the normalized document lies outside
--   the implemented support rule.  Decided by the pure gate before
--   any checker runs, with non-empty, deterministic, sorted,
--   deduplicated reasons.  A document selecting no guarantees is
--   unsupported, never vacuously verified.
-- * @VIOLATED@ is reserved for a future independently checked
--   concrete witness and cannot be produced by this boundary: it has
--   no representation in the vocabulary.  In particular, an Agda
--   refusal after the gate accepted the document is a tool failure,
--   never a semantic verdict.
-- * 'VerificationFailure' (the 'Left' side) means the verification
--   mechanism itself could not be trusted to complete: a forged or
--   drifted normalized model, a structured generated artifact missing
--   a required theorem block, a missing or unlaunchable checker, a checker version
--   other than exactly 2.8.0, a workspace failure, a nonzero checker
--   exit after gate acceptance, or checker termination by a signal.
--   These exit with status 2 at the tool boundary.
--
-- What a successful verification does and does not establish: it
-- checks exactly the one selected obligation of the checked document
-- against the trusted Agda kernel semantics.  The Haskell frontend
-- and generator, the embedded kernel modules, the Agda toolchain,
-- and the support rule itself remain trusted components; no other
-- action, guarantee family, document, or semantic-preservation
-- property is verified, and the canonical Acme example — which
-- selects three guarantees — remains unsupported and unverified.
module Mithril.Core.Verification
  ( -- * Pipeline stage
    Normalized

    -- * Results
  , VerificationResult (..)
  , VerifiedObligation (..)
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
  ( UnsupportedReason (..)
  , VerificationFailure (..)
  , VerificationResult (..)
  , VerifiedObligation (..)
  , VerifierInvariantViolation (..)
  , normalizeUnsupportedReasons
  , normalizeVerifierInvariantViolations
  , verifyModelWith
  )

-- | Verify a normalized document against the one implemented support
-- rule (the module header states the pipeline, the rule, and the
-- exact result semantics).
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
