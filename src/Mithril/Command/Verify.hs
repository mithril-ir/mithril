{-# LANGUAGE OverloadedStrings #-}

-- | The effectful file boundary of @mithril verify FILE@.
--
-- The command runs the complete existing validation\/normalization
-- pipeline over FILE — exactly
-- 'Mithril.Command.Validate.validateCoreFile', so every input failure
-- keeps the validate boundary's diagnostic bytes and exit
-- classification — and, on success, hands the normalized document to
-- the verifier boundary ('Mithril.Core.Verification.verifyCoreDocument').
--
-- Outcome contract at the tool boundary:
--
-- * a supported, checked document exits 0 with the deterministic
--   verification report on stdout and nothing on stderr;
-- * an unsupported document exits 3 with the deterministic
--   unsupported report — sorted, deduplicated reasons — on stdout
--   and nothing on stderr;
-- * invalid authored Core keeps the validate boundary's exact
--   diagnostic bytes and exit classification;
-- * every internal\/tool failure — a forged normalized model, an
--   incomplete generated module, a missing, unlaunchable,
--   wrong-version, refusing, or signal-terminated checker, or a
--   workspace failure — exits 2 with a precise escaped diagnostic on
--   stderr and no false semantic verdict.  A checker refusal after
--   the support gate accepted the document is a tool failure, never
--   @VIOLATED@, which this milestone can never emit.
--
-- Reports contain no timestamps, temporary paths, working-directory
-- details, internal numeric identifiers, or uncontrolled checker
-- output; stderr diagnostics render document- and checker-supplied
-- text through the shared control-character escaping convention.
module Mithril.Command.Verify
  ( VerifyFileError (..)
  , VerifyFileSuccess (..)
  , verifyCoreFile
  , renderVerifySuccess
  , renderVerifyFailure
  , verifySuccessExitCode
  , verifyFailureExitCode
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))

import Mithril.Command.Internal.Diagnostic (escapeControlChars)
import Mithril.Command.Validate
  ( ValidateFileError (..)
  , displayPath
  , failureExitCode
  , renderValidateFailure
  , validateCoreFile
  )
import Mithril.Core.Validation (renderJsonPointer)
import Mithril.Core.Verification
  ( UnsupportedReason (..)
  , VerificationFailure (..)
  , VerificationResult (..)
  , VerifiedObligation (..)
  , VerifierInvariantViolation (..)
  , verifyCoreDocument
  )

-- | Every expected failure of @mithril verify FILE@, classified.
data VerifyFileError
  = -- | The input failed the validation\/normalization pipeline.  The
    -- classification, rendering, and exit status are exactly those of
    -- @mithril validate FILE@ — the pipeline is reused, not restated.
    VerifyInputError ValidateFileError
  | -- | The verification mechanism itself could not be trusted to
    -- complete ("Mithril.Core.Verification" states the classes).
    -- Always an internal\/tool failure with exit status 2 — never an
    -- unsupported classification and never a semantic verdict.
    InternalVerifierError VerificationFailure
  deriving (Eq, Show)

-- | The two semantic outcomes of a successfully mechanized decision.
data VerifyFileSuccess
  = -- | Exit 0: the one selected obligation was checked.
    VerifyVerified VerifiedObligation
  | -- | Exit 3: the document lies outside the implemented support
    -- rule; the reasons are non-empty, sorted, and deduplicated.
    VerifyUnsupported (NonEmpty UnsupportedReason)
  deriving (Eq, Show)

-- | Read FILE, run the complete validation\/normalization pipeline on
-- it, and verify the normalized document.  Expected failures are
-- returned in 'Left'; the unsupported outcome is a 'Right', because
-- the verifier decided it deterministically.
verifyCoreFile :: FilePath -> IO (Either VerifyFileError VerifyFileSuccess)
verifyCoreFile file = do
  outcome <- validateCoreFile file
  case outcome of
    Left inputFailure -> pure (Left (VerifyInputError inputFailure))
    Right normalizedDocument -> do
      verdict <- verifyCoreDocument normalizedDocument
      pure $ case verdict of
        Left failure -> Left (InternalVerifierError failure)
        Right (VerificationVerified obligation) ->
          Right (VerifyVerified obligation)
        Right (VerificationUnsupported reasons) ->
          Right (VerifyUnsupported reasons)

-- | Render a semantic outcome for stdout.  The result has no trailing
-- newline; print it with a newline-appending writer.  Deterministic:
-- no timestamps, no temporary paths, no internal numeric identifiers,
-- and no checker output.
renderVerifySuccess :: FilePath -> VerifyFileSuccess -> Text
renderVerifySuccess file success =
  case success of
    VerifyVerified obligation ->
      Text.intercalate
        "\n"
        [ displayPath file <> ": VERIFIED"
        , "  guarantee: " <> escapeControlChars (verifiedGuarantee obligation)
        , "  case action: "
            <> escapeControlChars (Text.pack (show (verifiedCaseAction obligation)))
        , "  checker: Agda 2.8.0 with --safe --no-libraries --ignore-interfaces"
        , "  theorems: "
            <> Text.intercalate ", " (map escapeControlChars (verifiedTheorems obligation))
        , "  scope: exactly the one selected obligation of this document is"
            <> " verified; nothing else is"
        ]
    VerifyUnsupported reasons ->
      Text.intercalate
        "\n"
        ( (displayPath file <> ": UNSUPPORTED by the implemented verifier support rule")
            : [ "  "
                  <> renderJsonPointer (unsupportedReasonPath reason)
                  <> ": "
                  <> escapeControlChars (unsupportedReasonMessage reason)
              | reason <- NonEmpty.toList reasons
              ]
        )

-- | Render an expected failure for stderr.  Input failures render
-- byte-for-byte as @mithril validate FILE@ renders them; internal
-- verifier failures render in the internal-error block form of the
-- other stages, with every document- or checker-supplied fragment
-- escaped.  No trailing newline.
renderVerifyFailure :: VerifyFileError -> Text
renderVerifyFailure failure =
  case failure of
    VerifyInputError inputFailure -> renderValidateFailure inputFailure
    InternalVerifierError verifierFailure ->
      case verifierFailure of
        VerifierInvariantViolations problems ->
          Text.intercalate
            "\n"
            ( ( internalPrefix
                  <> "the normalized document does not match the"
                  <> " verifier's Core v0 interpretation"
              )
                : [ "  "
                      <> renderJsonPointer (verifierInvariantPath problem)
                      <> ": "
                      <> escapeControlChars (verifierInvariantMessage problem)
                  | problem <- NonEmpty.toList problems
                  ]
            )
        GeneratedTheoremsMissing names ->
          Text.intercalate
            "\n"
            ( (internalPrefix <> "the generated Agda module lacks a required theorem")
                : [ "  " <> escapeControlChars name
                  | name <- NonEmpty.toList names
                  ]
            )
        CheckerUnavailable reason ->
          internalPrefix
            <> "the Agda checker could not be invoked\n  "
            <> escapeControlChars reason
        CheckerVersionMismatch reported ->
          internalPrefix
            <> "the checker is not exactly Agda 2.8.0\n  reported: "
            <> escapeControlChars reported
        CheckerWorkspaceFailure reason ->
          internalPrefix
            <> "the isolated checking workspace could not be prepared or cleaned\n  "
            <> escapeControlChars reason
        CheckerRejected output ->
          internalPrefix
            <> "the Agda checker rejected the generated obligation after the"
            <> " support gate accepted the document (a tool failure, not a"
            <> " semantic verdict)\n  "
            <> escapeControlChars output
        CheckerTerminatedBySignal signal ->
          internalPrefix
            <> "the Agda checker was terminated by signal "
            <> Text.pack (show signal)
  where
    internalPrefix = "mithril: internal Core verifier error: "

-- | Exit classification of the semantic outcomes: a verified document
-- exits 0, an unsupported one exits 3.
verifySuccessExitCode :: VerifyFileSuccess -> ExitCode
verifySuccessExitCode success =
  case success of
    VerifyVerified _ -> ExitSuccess
    VerifyUnsupported _ -> ExitFailure 3

-- | Exit classification of the failures: input failures keep the
-- validate boundary's exit status; every internal verifier failure
-- exits 2.
verifyFailureExitCode :: VerifyFileError -> ExitCode
verifyFailureExitCode failure =
  case failure of
    VerifyInputError inputFailure -> failureExitCode inputFailure
    InternalVerifierError _ -> ExitFailure 2
