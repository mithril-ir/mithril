{-# LANGUAGE OverloadedStrings #-}

-- | The CLI boundary of @mithril wasp generate CORE_FILE WASP_ROOT@
-- and @mithril wasp check CORE_FILE WASP_ROOT@.
--
-- Both commands run the complete existing validation\/normalization
-- pipeline over CORE_FILE — exactly
-- 'Mithril.Command.Validate.validateCoreFile', so every input failure
-- keeps the validate boundary's diagnostic bytes and exit
-- classification — then require the production verifier
-- ('Mithril.Core.Verification.verifyCoreDocument') to report the
-- document VERIFIED, and then render the closed Wasp bundle
-- ('Mithril.Core.Wasp.renderWaspBundle') of the same normalized
-- document.  Rendering itself attests only that the shared support
-- gate accepted the document; the VERIFIED provenance a successful
-- report states is established here, by the verifier having
-- returned VERIFIED before anything was rendered — a document the
-- verifier reports unsupported, or a verifier tool failure, never
-- writes or replaces a Wasp root.
--
-- * @generate@ renders the complete bundle before touching the
--   filesystem, validates WASP_ROOT lexically (no empty, dot, or
--   trailing-separator component; never normalized) and its
--   ancestors with no-follow metadata, refuses an unusable root and
--   an existing entry of any kind at the backup sibling path
--   (@WASP_ROOT.mithril-wasp-backup@, never touched), and installs
--   the bundle as a complete directory: an absent or empty
--   destination is initialized; a nonempty destination is replaced
--   as a whole only when it carries the byte-exact Mithril ownership
--   marker and nothing outside the fixed inventory (altered or
--   missing managed files are recovered by the replacement); an
--   unmarked nonempty root or any unmanaged path refuses the command
--   without mutation.  The new bundle is written to a sibling staging
--   directory created private (permission bits @0700@ regardless of
--   the umask, so the installed root is private too), checked there,
--   and swapped into place by whole-directory renames with rollback
--   ("Mithril.Core.Internal.WaspFilesystem" states the exact
--   sequence, including the second backup-absence check right before
--   the rename); the command finishes with exactly the confinement
--   check of @check@.
-- * @check@ performs no writes: it walks the complete source root
--   without following symbolic links, rejects hard links, compares
--   every managed file byte-for-byte with the regenerated bundle,
--   and rejects missing, altered, and unexpected inputs with
--   deterministic sorted deduplicated diagnostics.
--
-- Outcome contract at the tool boundary:
--
-- * a generated or confined root exits 0 with the deterministic
--   report on stdout — which states the completed verification gate
--   — and nothing on stderr;
-- * a document outside the support rule exits 3 with the
--   deterministic unsupported report on stdout;
-- * a root that is not the closed profile (@check@), or that
--   @generate@ may not replace (unmarked, or holding an unmanaged
--   path), exits 4 with the deterministic violation report on stdout,
--   and @generate@ mutates nothing in that case;
-- * invalid authored Core keeps the validate boundary's exact
--   diagnostic bytes and exit classification;
-- * an unusable root — an empty argument, a dot, empty, or
--   trailing-separator path component, the filesystem root, an
--   ancestor or the root itself being a symbolic link or not a
--   directory, a missing parent, a missing root for @check@, or (for
--   @generate@) an existing entry at the backup sibling path — exits
--   1 with a diagnostic on stderr;
-- * every internal\/tool failure — a verifier tool failure, a forged
--   normalized model, or a staging\/swap\/rollback\/cleanup failure —
--   exits 2 with a diagnostic on stderr and no false success.
--
-- Reports contain no timestamps or internal numeric identifiers;
-- stderr diagnostics render document- and system-supplied text
-- through the shared control-character escaping convention, and
-- filesystem failures are reported as a stable operation label plus
-- the classified I\/O error kind — never the raw exception — naming
-- only a backup or staging directory the command had to leave
-- behind, since the user must know where the previous root is.
module Mithril.Command.Wasp
  ( WaspFileError (..)
  , WaspFileSuccess (..)
  , WaspReport (..)
  , generateWaspApp
  , checkWaspApp
  , renderWaspSuccess
  , renderWaspFailure
  , waspSuccessExitCode
  , waspFailureExitCode
  ) where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (..))

import Mithril.Command.Internal.Diagnostic (escapeControlChars)
import Mithril.Command.Validate
  ( ValidateFileError
  , displayPath
  , failureExitCode
  , renderValidateFailure
  , validateCoreFile
  )
import Mithril.Command.Verify
  ( VerifyFileError (..)
  , renderVerifyFailure
  )
import Mithril.Core.Internal.WaspFilesystem
  ( InstallFailure (..)
  , RootState (..)
  , inspectRoot
  , installBundle
  , noInstallHooks
  , resolveRootPath
  )
import Mithril.Core.Validation (renderJsonPointer)
import Mithril.Core.Verification
  ( VerificationFailure
  , VerificationResult (..)
  , verifyCoreDocument
  )
import Mithril.Core.Wasp
  ( ConfinementMode (..)
  , ConfinementViolation (..)
  , UnsupportedReason (..)
  , VerifierInvariantViolation (..)
  , WaspBundle
  , WaspBundleSummary (..)
  , WaspRenderingFailure (..)
  , checkWaspConfinement
  , renderWaspBundle
  , waspBundleSummary
  , waspTargetVersion
  )

-- | Every expected failure of the two commands, classified.
data WaspFileError
  = -- | The input failed the validation\/normalization pipeline; the
    -- classification, rendering, and exit status are exactly those
    -- of @mithril validate FILE@.
    WaspInputError ValidateFileError
  | -- | The verification mechanism could not be trusted to complete
    -- (a tool failure of the verify boundary, rendered byte-identically
    -- to @mithril verify@; exit status 2).  Nothing is written.
    WaspVerifierError VerificationFailure
  | -- | The Wasp emitter hit inconsistencies of the normalized
    -- document that no pipeline-produced document can exhibit
    -- (frontend drift or a tool bug; exit status 2).
    WaspRenderInvariantError (NonEmpty VerifierInvariantViolation)
  | -- | WASP_ROOT cannot be used (module header; exit status 1):
    -- the path, an ancestor, the root itself, or — for @generate@ —
    -- an occupied backup sibling path.  The 'Text' is the reason.
    WaspRootError FilePath Text
  | -- | Staging, swapping, restoring, or cleaning up failed (exit
    -- status 2).  The 'Text' names the operations, the classified
    -- I\/O error kinds, and any directory left behind.
    WaspWorkspaceError Text
  deriving (Eq, Show)

-- | The deterministic outcomes of a completed command.
data WaspFileSuccess
  = -- | Exit 3: the document lies outside the support rule; the
    -- reasons are non-empty, sorted, and deduplicated.
    WaspUnsupported (NonEmpty UnsupportedReason)
  | -- | Exit 4: WASP_ROOT is not the closed profile (@check@), or is
    -- a nonempty root @generate@ may not replace (unmarked, or
    -- holding an unmanaged path; nothing was mutated).
    WaspNotConfined FilePath (NonEmpty ConfinementViolation)
  | -- | Exit 0: the bundle was installed and the root is confined.
    WaspGenerated WaspReport
  | -- | Exit 0: the root is exactly the closed profile.
    WaspConfined WaspReport
  deriving (Eq, Show)

-- | What a successful command reports: the Core file, the root, and
-- the bundle summary (no bytes, no temporary paths).
data WaspReport = WaspReport
  { reportCore :: FilePath
  , reportRoot :: FilePath
  , reportSummary :: WaspBundleSummary
  }
  deriving (Eq, Show)

--------------------------------------------------------------------
-- The commands
--------------------------------------------------------------------

-- | Validate, verify (VERIFIED required), and render the bundle.
prepareBundle
  :: FilePath
  -> IO (Either WaspFileError (Either (NonEmpty UnsupportedReason) WaspBundle))
prepareBundle coreFile = do
  outcome <- validateCoreFile coreFile
  case outcome of
    Left inputFailure -> pure (Left (WaspInputError inputFailure))
    Right document -> do
      verdict <- verifyCoreDocument document
      pure $ case verdict of
        Left failure -> Left (WaspVerifierError failure)
        Right (VerificationUnsupported reasons) -> Right (Left reasons)
        Right (VerificationVerified _) ->
          case renderWaspBundle document of
            Left (WaspRenderingUnsupported reasons) -> Right (Left reasons)
            Left (WaspRenderingInvariants problems) ->
              Left (WaspRenderInvariantError problems)
            Right bundle -> Right (Right bundle)

-- | @mithril wasp check CORE_FILE WASP_ROOT@ (module header).
checkWaspApp :: FilePath -> FilePath -> IO (Either WaspFileError WaspFileSuccess)
checkWaspApp coreFile root = do
  prepared <- prepareBundle coreFile
  case prepared of
    Left failure -> pure (Left failure)
    Right (Left reasons) -> pure (Right (WaspUnsupported reasons))
    Right (Right bundle) -> do
      resolved <- resolveRootPath root
      case resolved of
        Left reason -> pure (Left (WaspRootError root reason))
        Right absolute -> do
          state <- inspectRoot absolute
          pure $ case state of
            Left reason -> Left (WaspRootError root reason)
            Right RootAbsent -> Left (WaspRootError root "does not exist")
            Right (RootDirectory entries) ->
              case NonEmpty.nonEmpty (checkWaspConfinement FullCheck bundle entries) of
                Just violations -> Right (WaspNotConfined root violations)
                Nothing -> Right (WaspConfined (report coreFile root bundle))

-- | @mithril wasp generate CORE_FILE WASP_ROOT@ (module header).
generateWaspApp :: FilePath -> FilePath -> IO (Either WaspFileError WaspFileSuccess)
generateWaspApp coreFile root = do
  prepared <- prepareBundle coreFile
  case prepared of
    Left failure -> pure (Left failure)
    Right (Left reasons) -> pure (Right (WaspUnsupported reasons))
    Right (Right bundle) -> do
      resolved <- resolveRootPath root
      case resolved of
        Left reason -> pure (Left (WaspRootError root reason))
        Right absolute -> do
          installed <- installBundle noInstallHooks bundle absolute
          pure $ case installed of
            Left (InstallUnusableRoot reason) -> Left (WaspRootError root reason)
            Left (InstallNotOwned violations) -> Right (WaspNotConfined root violations)
            Left (InstallWorkspaceFailure reason) -> Left (WaspWorkspaceError reason)
            Left (InstallNotConfined violations) -> Right (WaspNotConfined root violations)
            Right () -> Right (WaspGenerated (report coreFile root bundle))

report :: FilePath -> FilePath -> WaspBundle -> WaspReport
report coreFile root bundle =
  WaspReport
    { reportCore = coreFile
    , reportRoot = root
    , reportSummary = waspBundleSummary bundle
    }

--------------------------------------------------------------------
-- Rendering and exit classification
--------------------------------------------------------------------

profileLabel :: Text
profileLabel = "Wasp Confinement Profile v0"

-- | Render a completed outcome for stdout (no trailing newline).
renderWaspSuccess :: FilePath -> WaspFileSuccess -> Text
renderWaspSuccess coreFile success =
  case success of
    WaspUnsupported reasons ->
      Text.intercalate
        "\n"
        ( (displayPath coreFile <> ": UNSUPPORTED by the implemented Wasp support rule")
            : [ "  "
                  <> renderJsonPointer (unsupportedReasonPath reason)
                  <> ": "
                  <> escapeControlChars (unsupportedReasonMessage reason)
              | reason <- NonEmpty.toList reasons
              ]
        )
    WaspNotConfined root violations ->
      Text.intercalate
        "\n"
        ( (displayPath root <> ": NOT CONFINED (" <> profileLabel <> ")")
            : [ "  "
                  <> escapeControlChars (confinementPath violation)
                  <> ": "
                  <> escapeControlChars (confinementMessage violation)
              | violation <- NonEmpty.toList violations
              ]
        )
    WaspGenerated generated ->
      Text.intercalate "\n" (reportLines "GENERATED" generated <> ["  confinement: CONFINED"])
    WaspConfined confined ->
      Text.intercalate "\n" (reportLines "CONFINED" confined)
  where
    reportLines verdict completed =
      let summary = reportSummary completed
       in [ displayPath (reportRoot completed) <> ": " <> verdict <> " (" <> profileLabel <> ")"
          , "  core: " <> displayPath (reportCore completed)
          , "  verification: VERIFIED by the production verifier before the bundle was rendered"
          , "  guarantee: " <> escapeControlChars (summaryGuarantee summary)
          , "  case action: " <> escapeControlChars (Text.pack (show (summaryCaseAction summary)))
          , "  operation: "
              <> escapeControlChars (summaryOperation summary)
              <> " (POST "
              <> escapeControlChars (summaryRoute summary)
              <> ")"
          , "  target: Wasp " <> waspTargetVersion <> ", PostgreSQL, Prisma runtime supplied by Wasp"
          , "  managed files: " <> Text.pack (show (length (summaryManagedPaths summary)))
          ]
            <> [ "    " <> escapeControlChars (Text.pack path)
               | path <- summaryManagedPaths summary
               ]

-- | Render a failure for stderr (no trailing newline).
renderWaspFailure :: WaspFileError -> Text
renderWaspFailure failure =
  case failure of
    WaspInputError inputFailure -> renderValidateFailure inputFailure
    WaspVerifierError verifierFailure ->
      renderVerifyFailure (InternalVerifierError verifierFailure)
    WaspRenderInvariantError problems ->
      Text.intercalate
        "\n"
        ( ( internalPrefix
              <> "the normalized document does not match the"
              <> " Wasp emitter's Core v0 interpretation"
          )
            : [ "  "
                  <> renderJsonPointer (verifierInvariantPath problem)
                  <> ": "
                  <> escapeControlChars (verifierInvariantMessage problem)
              | problem <- NonEmpty.toList problems
              ]
        )
    WaspRootError root reason ->
      displayPath root <> ": unusable Wasp root\n  " <> escapeControlChars reason
    WaspWorkspaceError reason ->
      internalPrefix
        <> "the generated bundle could not be installed\n  "
        <> escapeControlChars reason
  where
    internalPrefix = "mithril: internal Core Wasp emitter error: "

-- | Exit classification of completed outcomes: 0 generated or
-- confined, 3 unsupported, 4 not confined.
waspSuccessExitCode :: WaspFileSuccess -> ExitCode
waspSuccessExitCode success =
  case success of
    WaspGenerated _ -> ExitSuccess
    WaspConfined _ -> ExitSuccess
    WaspUnsupported _ -> ExitFailure 3
    WaspNotConfined _ _ -> ExitFailure 4

-- | Exit classification of failures: input failures keep the
-- validate boundary's status, an unusable root exits 1, and every
-- internal or tool failure exits 2.
waspFailureExitCode :: WaspFileError -> ExitCode
waspFailureExitCode failure =
  case failure of
    WaspInputError inputFailure -> failureExitCode inputFailure
    WaspVerifierError _ -> ExitFailure 2
    WaspRenderInvariantError _ -> ExitFailure 2
    WaspRootError _ _ -> ExitFailure 1
    WaspWorkspaceError _ -> ExitFailure 2
