{-# LANGUAGE OverloadedStrings #-}

-- | The effectful file boundary of @mithril contract FILE@.
--
-- The command runs the complete existing validation\/normalization
-- pipeline over FILE — exactly
-- 'Mithril.Command.Validate.validateCoreFile', so every input failure
-- keeps the validate boundary's diagnostic bytes and exit
-- classification — and, on success, renders the normalized document
-- as the deterministic human-readable security contract
-- ('Mithril.Core.Contract.renderCoreContract').  On success the
-- caller prints only the contract text to stdout (it carries its own
-- final newline; the validate success line is deliberately not
-- printed); every failure renders on stderr.
--
-- The contract is a review artifact only: rendering evaluates no
-- policy, proves nothing, verifies no guarantee, compares no two
-- documents, and generates nothing executable — see
-- "Mithril.Core.Contract" for the exact non-claims.
module Mithril.Command.Contract
  ( ContractFileError (..)
  , contractCoreFile
  , renderContractFailure
  , contractFailureExitCode
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))

import Mithril.Command.Internal.Diagnostic (escapeControlChars)
import Mithril.Command.Validate
  ( ValidateFileError (..)
  , failureExitCode
  , renderValidateFailure
  , validateCoreFile
  )
import Mithril.Core.Contract
  ( ContractRendererInvariantViolation (..)
  , ContractRenderingFailure (..)
  , renderCoreContract
  )
import Mithril.Core.Validation (renderJsonPointer)

-- | Every expected failure of @mithril contract FILE@, classified.
data ContractFileError
  = -- | The input failed the validation\/normalization pipeline.  The
    -- classification, rendering, and exit status are exactly those of
    -- @mithril validate FILE@ — the pipeline is reused, not restated.
    ContractInputError ValidateFileError
  | -- | The contract renderer hit referential inconsistencies of the
    -- normalized document (frontend drift or a normalizer\/renderer
    -- bug).  Contract rendering has no user-error class — a
    -- pipeline-produced normalized document renders — so this is
    -- always an internal error of the tool, never a user-document
    -- problem.
    InternalContractRendererError (NonEmpty ContractRendererInvariantViolation)
  deriving (Eq, Show)

-- | Read FILE, run the complete validation\/normalization pipeline on
-- it, and render the normalized document's security contract.
--
-- Expected failures are returned in 'Left': every input failure of
-- 'validateCoreFile' (classified unchanged), plus the internal
-- contract-renderer invariant class, which no public invocation can
-- construct.
contractCoreFile :: FilePath -> IO (Either ContractFileError Text)
contractCoreFile file = do
  outcome <- validateCoreFile file
  pure $ case outcome of
    Left inputFailure -> Left (ContractInputError inputFailure)
    Right normalizedDocument ->
      case renderCoreContract normalizedDocument of
        Left (ContractRendererInvariantViolations problems) ->
          Left (InternalContractRendererError problems)
        Right contractText -> Right contractText

-- | Render a failure for stderr.  Input failures render byte-for-byte
-- as @mithril validate FILE@ renders them; the internal
-- contract-renderer class renders in the internal-error block form of
-- the other stages.  The result has no trailing newline; print it
-- with a newline-appending writer.  Rendering is pure and
-- deterministic.
renderContractFailure :: ContractFileError -> Text
renderContractFailure failure =
  case failure of
    ContractInputError inputFailure -> renderValidateFailure inputFailure
    InternalContractRendererError problems ->
      Text.intercalate
        "\n"
        ( ( "mithril: internal Core contract renderer error: "
              <> "the normalized document does not match the"
              <> " contract renderer's Core v0 interpretation"
          )
            : [ "  "
                  <> renderJsonPointer (contractRendererInvariantPath problem)
                  <> ": "
                  <> escapeControlChars (contractRendererInvariantMessage problem)
              | problem <- NonEmpty.toList problems
              ]
        )

-- | Exit classification: input failures keep the validate boundary's
-- exit status; internal contract-renderer failures exit @2@ like every
-- other internal class.  (Success exits @0@ and is not a
-- 'ContractFileError'.)
contractFailureExitCode :: ContractFileError -> ExitCode
contractFailureExitCode failure =
  case failure of
    ContractInputError inputFailure -> failureExitCode inputFailure
    InternalContractRendererError _ -> ExitFailure 2
