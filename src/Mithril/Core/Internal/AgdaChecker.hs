{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | __Internal module — never expose.__
--
-- The production checker runner behind "Mithril.Core.Verification":
-- the one place the verifier crosses the file\/process boundary to
-- the Agda toolchain.  No Agda compiler internals are imported; the
-- checker is an external executable.
--
-- For every invocation the runner
--
-- * asks the @agda@ executable on the search path for its version and
--   refuses anything whose first reported line is not exactly
--   @Agda version 2.8.0@;
-- * materializes the compile-time-embedded trusted kernel modules
--   ("Mithril.Core.Internal.AgdaKernel") and the generated obligation
--   module into a fresh, uniquely named temporary workspace — never
--   the current repository, the working directory, or any
--   environment-selected source location, and never a location a
--   previous run could have populated, so no stale interface file can
--   participate (@--ignore-interfaces@ additionally refuses any);
-- * invokes exactly @agda --safe --no-libraries --ignore-interfaces@
--   on the generated entry module inside that workspace; and
-- * removes the whole workspace afterwards, on success and on every
--   failure path.
--
-- Every problem is a classified tool failure
-- ('Mithril.Core.Internal.Verify.VerificationFailure'): a missing or
-- unlaunchable checker, a wrong version, a workspace failure, a
-- nonzero exit, or termination by a signal.  A nonzero Agda exit
-- after the support gate accepted the document is never a semantic
-- verdict — the runner cannot produce @VIOLATED@, which does not
-- exist in the vocabulary.
--
-- No diagnostic constructed here contains an absolute path: workspace
-- and launch problems are reported as a stable operation label plus
-- the classified I\/O error kind ('ioeGetErrorType', never the raw
-- host-dependent 'show' of the exception, which embeds the failing
-- path), and captured checker output is reported only after every
-- occurrence of the workspace root is replaced by a fixed
-- placeholder — so no temporary base, workspace root, or
-- environment-supplied @TMPDIR@ value leaks into a diagnostic.
module Mithril.Core.Internal.AgdaChecker
  ( agdaCheckerRunner
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openTempFile)
import System.IO.Error (ioeGetErrorType)
import System.Process (readProcessWithExitCode)

import Mithril.Core.Internal.AgdaKernel (kernelModules)
import Mithril.Core.Internal.Verify
  ( CheckerRunner
  , VerificationFailure (..)
  , generatedModuleFile
  )

-- | The checker executable, resolved through the process search path.
agdaProgram :: FilePath
agdaProgram = "agda"

-- | The exact version line the checker must report first.
requiredVersionLine :: String
requiredVersionLine = "Agda version 2.8.0"

-- | The fixed safe-mode arguments of every check.
checkArguments :: FilePath -> [String]
checkArguments root =
  [ "--safe"
  , "--no-libraries"
  , "--ignore-interfaces"
  , "-i"
  , root
  , root </> generatedModuleFile
  ]

-- | The production runner; see the module header.
agdaCheckerRunner :: CheckerRunner
agdaCheckerRunner generatedModule = do
  versionOutcome <- checkVersion
  case versionOutcome of
    Left failure -> pure (Left failure)
    Right () -> runInWorkspace generatedModule

-- | 'try' specialized to the one exception class this boundary
-- classifies.
tryIO :: IO a -> IO (Either IOException a)
tryIO = try

-- | The classified kind of an I\/O error — a stable, path-free
-- description such as @does not exist@ or @permission denied@.  The
-- raw 'show' of an 'IOException' embeds the failing absolute path and
-- is never rendered.
describeIOError :: IOException -> Text
describeIOError = Text.pack . show . ioeGetErrorType

-- | A workspace failure with a stable operation label and the
-- classified error kind; no path appears.
workspaceFailure :: Text -> IOException -> VerificationFailure
workspaceFailure operation problem =
  CheckerWorkspaceFailure (operation <> " failed: " <> describeIOError problem)

-- | A launch failure with the classified error kind; no path appears.
launchFailure :: IOException -> VerificationFailure
launchFailure problem =
  CheckerUnavailable
    ("the checker executable could not be launched: " <> describeIOError problem)

-- | Refuse every checker that is not exactly Agda 2.8.0.
checkVersion :: IO (Either VerificationFailure ())
checkVersion = do
  outcome <- tryIO (readProcessWithExitCode agdaProgram ["--version"] "")
  pure $ case outcome of
    Left problem -> Left (launchFailure problem)
    Right (ExitFailure status, out, err) ->
      Left
        ( CheckerUnavailable
            ( "the checker's --version invocation exited with status "
                <> Text.pack (show status)
                <> ": "
                <> Text.pack (out <> err)
            )
        )
    Right (ExitSuccess, out, _err) ->
      let reported = takeWhile (/= '\n') out
       in if reported == requiredVersionLine
            then Right ()
            else Left (CheckerVersionMismatch (Text.pack reported))

-- | Materialize kernel and generated module into a fresh workspace,
-- run the check, classify, and clean up on every path.  Each phase
-- carries its own stable operation label: anchor creation, workspace
-- directory creation, checking-tree materialization, and workspace
-- removal each classify separately, and a check-phase failure is
-- reported in preference to a subsequent cleanup failure.
runInWorkspace :: Text -> IO (Either VerificationFailure ())
runInWorkspace generatedModule = do
  anchorOutcome <- tryIO (acquireAnchor =<< getTemporaryDirectory)
  case anchorOutcome of
    Left problem ->
      pure (Left (workspaceFailure "creating the workspace anchor" problem))
    Right anchorPath -> do
      let root = anchorPath ++ ".d"
      createOutcome <- tryIO (createDirectory root)
      bodyOutcome <-
        case createOutcome of
          Left problem ->
            pure
              (Left (workspaceFailure "creating the workspace directory" problem))
          Right () -> do
            inside <- tryIO (checkInside generatedModule root)
            pure $ case inside of
              Left problem ->
                Left (workspaceFailure "materializing the checking tree" problem)
              Right result -> result
      cleanupOutcome <-
        cleanupWorkspace (either (const False) (const True) createOutcome)
          root
          anchorPath
      pure $ case (bodyOutcome, cleanupOutcome) of
        (Left failure, _) -> Left failure
        (Right (), Left failure) -> Left failure
        (Right (), Right ()) -> Right ()
  where
    -- A fresh, uniquely named anchor under the system temporary
    -- directory; the workspace directory is the anchor's name plus
    -- @.d@, and 'createDirectory' fails loudly instead of adopting a
    -- foreign directory.
    acquireAnchor temporaryBase = do
      (anchorPath, handle) <- openTempFile temporaryBase "mithril-verify-workspace.txt"
      hClose handle
      pure anchorPath

-- | Remove the workspace directory (when it was created) and the
-- anchor file — always both attempted, classifying the first problem.
cleanupWorkspace
  :: Bool -> FilePath -> FilePath -> IO (Either VerificationFailure ())
cleanupWorkspace directoryCreated root anchorPath = do
  rootOutcome <-
    if directoryCreated
      then tryIO (removeDirectoryRecursive root)
      else pure (Right ())
  anchorOutcome <- tryIO (removeFile anchorPath)
  pure $ case (rootOutcome, anchorOutcome) of
    (Left problem, _) -> Left (workspaceFailure "removing the workspace" problem)
    (_, Left problem) -> Left (workspaceFailure "removing the workspace" problem)
    _ -> Right ()

-- | Write the embedded kernel and the generated module, invoke the
-- checker, and classify its exit.
checkInside :: Text -> FilePath -> IO (Either VerificationFailure ())
checkInside generatedModule root = do
  mapM_ materialize kernelModules
  materialize (generatedModuleFile, Encoding.encodeUtf8 generatedModule)
  invocation <-
    tryIO (readProcessWithExitCode agdaProgram (checkArguments root) "")
  pure $ case invocation of
    Left problem -> Left (launchFailure problem)
    Right (ExitSuccess, _out, _err) -> Right ()
    Right (ExitFailure status, out, err)
      | status < 0 -> Left (CheckerTerminatedBySignal (negate status))
      | otherwise ->
          Left (CheckerRejected (scrub (Text.pack (out <> err))))
  where
    materialize (relativePath, bytes) = do
      let destination = root </> relativePath
      createDirectoryIfMissing True (takeDirectory destination)
      ByteString.writeFile destination bytes
    -- Keep the temporary workspace path out of every diagnostic.
    scrub = Text.replace (Text.pack root) "<workspace>"
