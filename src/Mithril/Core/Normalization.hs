{-# LANGUAGE OverloadedStrings #-}

-- | The fourth deterministic frontend boundary for Mithril Core v0:
-- normalization of a well-typed document into the explicit typed
-- normalized Core representation.
--
-- > typed opaque document
-- >   -> deterministic normalization        ('normalizeCoreDocument')
-- >   -> normalized opaque document
--
-- 'normalizeCoreDocument' consumes exactly the typed document
-- produced by "Mithril.Core.Typing" — the stage index makes a merely
-- resolved (or earlier) document unacceptable — and constructs the
-- typed normalized Core: the explicit internal representation the
-- contract renderer ("Mithril.Core.Contract", its first implemented
-- consumer), the future Agda backend, and the future target emitters
-- are required to share.  Relative to the typed document's resolved
-- model, normalization
--
-- * stamps every term with the static type the typechecker
--   determined for it, so no later backend reruns type inference;
-- * preserves every resolved namespace-specific identifier, and
--   keeps declaration names and JSON source locations as
--   diagnostic\/rendering metadata that never determines semantic
--   linkage;
-- * materializes each declared enum order into an explicit complete
--   ranking, and records at every ordered comparison which enum's
--   ranking applies and whether absence-as-bottom optionality is in
--   play;
-- * pairs the endpoint terms of lookups and relation effects with
--   the declared endpoints they bind, and puts @CreateEntity@
--   initializers into the target entity's attribute declaration
--   order;
-- * keeps the two principal modes and their allow branches explicit,
--   with the actor-free families still unrepresentable outside their
--   branches; and
-- * normalizes guarantee cases and access\/authority metadata into
--   explicit structures — case terms typed in their action's
--   environment, the @TenantIsolation@ access relation and endpoint
--   identities carried over from resolution unchanged, escalation
--   scope terms bound to the authority's scope endpoint.
--
-- Normalization is /structural/ canonicalization of one authored
-- document and nothing more.  It performs no boolean simplification,
-- no constant folding, no operand reordering, no policy evaluation,
-- no guarantee verification, no proof generation or checking, and no
-- code generation; it does not claim alpha-equivalence or canonical
-- equality between differently authored documents — determinism
-- means only that one authored document always normalizes to the
-- same result.  A @'Mithril.Core.Validation.CoreDocument'
-- 'Normalized'@ therefore attests exactly deterministic structural
-- normalization of a well-typed document: no semantic or security
-- property is established, and a normalized document's guarantees
-- remain unverified proof obligations.
--
-- == Failure classification
--
-- An ordinary well-typed document normalizes without any user-error
-- class: this boundary deliberately has no equivalent of structural,
-- name, or typing violations.  The only refusal is
-- 'NormalizerInvariantViolations' — inconsistencies of the typed
-- model that are impossible after 'Mithril.Core.Typing' minted the
-- @Typed@ stage (they indicate frontend drift or a
-- typechecker\/normalizer bug, never a problem with the user's
-- document, and exit with status 2 at the tool boundary).  The
-- violations are deterministic: aggregated across the whole model,
-- sorted, and deduplicated, and the normalizer never throws.
module Mithril.Core.Normalization
  ( -- * Pipeline stage
    Normalized

    -- * Failures and violations
  , NormalizationFailure (..)
  , NormalizerInvariantViolation (..)

    -- * Normalization
  , normalizeCoreDocument

    -- * Violation normalization
  , normalizeNormalizerInvariantViolations
  ) where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty

import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Normalized
  , Typed
  )
import Mithril.Core.Internal.Normalize
  ( NormalizerInvariantViolation (..)
  , normalizeModel
  )
import Mithril.Core.Internal.Report (runCollect)

-- | Why 'normalizeCoreDocument' refused the stage transition.  There
-- is exactly one class: the normalizer hit inconsistencies of the
-- typed model that no well-typed document can exhibit.  This is an
-- internal error of the tool, never a user-document problem — a
-- well-typed document has no user-error class at this boundary.  The
-- violations are sorted and deduplicated
-- ('normalizeNormalizerInvariantViolations').
newtype NormalizationFailure
  = NormalizerInvariantViolations (NonEmpty NormalizerInvariantViolation)
  deriving (Eq, Show)

-- | Normalize a well-typed document into typed normalized Core (the
-- module header states exactly what that adds and what it does not
-- claim).
--
-- Pure and deterministic: the same document always produces the same
-- normalized representation.  This function is the only direct
-- public producer of the @'Typed'@ → @'Normalized'@ stage
-- transition, and only a @'CoreDocument' 'Typed'@ is accepted — the
-- typed document's model is consumed as trusted typed information,
-- and every static type in the result comes from the typechecker's
-- own judgment.  ('Mithril.Command.Validate.validateCoreFile' also
-- publicly returns a @'CoreDocument' 'Normalized'@, but only by
-- orchestrating the complete staged pipeline through this function;
-- it mints nothing independently.)
normalizeCoreDocument
  :: CoreDocument Typed
  -> Either NormalizationFailure (CoreDocument Normalized)
normalizeCoreDocument (CoreDocument model) =
  case runCollect (normalizeModel model) of
    (problems, outcome) ->
      case NonEmpty.nonEmpty (normalizeNormalizerInvariantViolations problems) of
        Just someViolations ->
          Left (NormalizerInvariantViolations someViolations)
        Nothing ->
          case outcome of
            Nothing -> Left internalCompletenessFailure
            Just normalizedModel -> Right (CoreDocument normalizedModel)

-- | The totality net: a normalization pass that produced neither a
-- result nor a diagnostic is an implementation bug, classified as an
-- internal invariant failure rather than swallowed or thrown.
-- Unreachable while the normalizer upholds its contract that every
-- missing result traces to a reported problem.
internalCompletenessFailure :: NormalizationFailure
internalCompletenessFailure =
  NormalizerInvariantViolations
    ( NormalizerInvariantViolation
        []
        "the normalizer produced neither a result nor a diagnostic"
        :| []
    )

-- | Deterministically sort normalizer-invariant violations (by path,
-- then message) and remove duplicates.  This is the exact
-- normalization applied by 'normalizeCoreDocument' before violations
-- are returned.
normalizeNormalizerInvariantViolations
  :: [NormalizerInvariantViolation] -> [NormalizerInvariantViolation]
normalizeNormalizerInvariantViolations =
  map NonEmpty.head . NonEmpty.group . sort
