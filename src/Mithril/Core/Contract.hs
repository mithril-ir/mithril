{-# LANGUAGE OverloadedStrings #-}

-- | The deterministic Core v0 security-contract renderer over typed
-- normalized Core.
--
-- > normalized opaque document
-- >   -> deterministic contract rendering      ('renderCoreContract')
-- >   -> human-readable security contract text
--
-- 'renderCoreContract' accepts exactly a
-- @'Mithril.Core.Validation.CoreDocument' 'Normalized'@ — the stage
-- indexes make a merely typed (or earlier) document unacceptable — and
-- renders the explicit typed normalized Core representation it
-- carries as a deterministic, line-oriented, human-readable security
-- contract: the fixed Mithril Core v0 header and model name, the
-- declared entities, enums (with their materialized value rankings),
-- relations, and actions (parameters, principal mode, classification,
-- allow policies, effect, and result), the selected guarantees —
-- explicitly labelled unverified proof obligations — and a fixed
-- limitations section.  Terms render in an unambiguous, fully
-- parenthesized, constructor-preserving syntax with their stored
-- static types; references render through their resolved identifiers
-- and declaration metadata; declaration order is preserved.  The same
-- normalized document always renders to the same bytes, the output
-- depends only on the document's content (never on its filesystem
-- path), and successful output ends with exactly one final newline.
--
-- The contract is a review artifact and nothing more.  Rendering
-- evaluates no policy, simplifies nothing, proves and checks nothing,
-- verifies no guarantee, compares no two documents (it is not a
-- semantic diff), and generates no executable artifact; the rendered
-- guarantees remain unverified proof obligations, exactly as selected.
--
-- == Failure classification
--
-- A normalized document produced by the public pipeline always
-- renders: this boundary deliberately has no user-error class.  The
-- only refusal is 'ContractRendererInvariantViolations' — referential
-- inconsistencies of the normalized model that are impossible after
-- 'Mithril.Core.Normalization' minted the @Normalized@ stage (they
-- indicate frontend drift or a normalizer\/renderer bug, never a
-- problem with the user's document, and exit with status 2 at the
-- tool boundary).  The violations are deterministic: aggregated
-- across the whole model, sorted, and deduplicated, and the renderer
-- never throws and never emits a placeholder.
module Mithril.Core.Contract
  ( -- * Pipeline stage
    Normalized

    -- * Failures and violations
  , ContractRenderingFailure (..)
  , ContractRendererInvariantViolation (..)

    -- * Contract rendering
  , renderCoreContract

    -- * Violation normalization
  , normalizeContractRendererInvariantViolations
  ) where

import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)

import Mithril.Core.Internal.Contract
  ( ContractRendererInvariantViolation (..)
  , renderModelContract
  )
import Mithril.Core.Internal.Document
  ( CoreDocument (..)
  , Normalized
  )
import Mithril.Core.Internal.Report (runCollect)

-- | Why 'renderCoreContract' refused to render.  There is exactly one
-- class: the renderer hit referential inconsistencies of the
-- normalized model that no pipeline-produced document can exhibit.
-- This is an internal error of the tool, never a user-document
-- problem — a normalized document has no user-error class at this
-- boundary.  The violations are sorted and deduplicated
-- ('normalizeContractRendererInvariantViolations').
newtype ContractRenderingFailure
  = ContractRendererInvariantViolations
      (NonEmpty ContractRendererInvariantViolation)
  deriving (Eq, Show)

-- | Render a normalized document as the deterministic human-readable
-- security contract (the module header states the format and exactly
-- what rendering does and does not establish).
--
-- Pure and deterministic: the same normalized document always renders
-- to the same bytes.  Only a @'CoreDocument' 'Normalized'@ is
-- accepted — the typed normalized model is consumed as trusted
-- normalized information, so no decoding, name resolution, type
-- inference, endpoint binding, rank materialization, or policy
-- evaluation is repeated here.
renderCoreContract
  :: CoreDocument Normalized
  -> Either ContractRenderingFailure Text
renderCoreContract (CoreDocument model) =
  case runCollect (renderModelContract model) of
    (problems, outcome) ->
      case NonEmpty.nonEmpty (normalizeContractRendererInvariantViolations problems) of
        Just someViolations ->
          Left (ContractRendererInvariantViolations someViolations)
        Nothing ->
          case outcome of
            Nothing -> Left internalCompletenessFailure
            Just contractText -> Right contractText

-- | The totality net: a rendering pass that produced neither a result
-- nor a diagnostic is an implementation bug, classified as an
-- internal invariant failure rather than swallowed or thrown.
-- Unreachable while the renderer upholds its contract that every
-- missing result traces to a reported problem.
internalCompletenessFailure :: ContractRenderingFailure
internalCompletenessFailure =
  ContractRendererInvariantViolations
    ( ContractRendererInvariantViolation
        []
        "the contract renderer produced neither a result nor a diagnostic"
        :| []
    )

-- | Deterministically sort contract-renderer invariant violations (by
-- path, then message) and remove duplicates.  This is the exact
-- normalization applied by 'renderCoreContract' before violations are
-- returned.
normalizeContractRendererInvariantViolations
  :: [ContractRendererInvariantViolation]
  -> [ContractRendererInvariantViolation]
normalizeContractRendererInvariantViolations =
  map NonEmpty.head . NonEmpty.group . sort
