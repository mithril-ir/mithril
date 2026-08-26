-- | Effectful entry point for the @mithril@ executable.
--
-- All argument interpretation and rendering is pure and lives in
-- "Mithril.CLI"; the validate boundary lives in
-- "Mithril.Command.Validate", the contract boundary in
-- "Mithril.Command.Contract", the verify boundary in
-- "Mithril.Command.Verify", and the wasp boundary in
-- "Mithril.Command.Wasp".  This module only wires together the
-- process arguments, stdout, stderr, the package version, and the
-- exit status.
module Main
  ( main
  ) where

import Data.Version (showVersion)
import qualified Data.Text.IO as TextIO
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

import Mithril.CLI (Command (..), parseCommand, renderHelp, renderVersion)
import Mithril.Command.Contract
  ( contractCoreFile
  , contractFailureExitCode
  , renderContractFailure
  )
import Mithril.Command.Validate
  ( failureExitCode
  , renderValidateFailure
  , renderValidateSuccess
  , validateCoreFile
  )
import Mithril.Command.Verify
  ( renderVerifyFailure
  , renderVerifySuccess
  , verifyCoreFile
  , verifyFailureExitCode
  , verifySuccessExitCode
  )
import Mithril.Command.Wasp
  ( checkWaspApp
  , generateWaspApp
  , renderWaspFailure
  , renderWaspSuccess
  , waspFailureExitCode
  , waspSuccessExitCode
  )
import Paths_mithril_ir (version)

main :: IO ()
main = do
  arguments <- getArgs
  case parseCommand arguments of
    Right ShowHelp -> putStr renderHelp
    Right ShowVersion -> putStrLn (renderVersion (showVersion version))
    Right (Validate file) -> do
      outcome <- validateCoreFile file
      case outcome of
        Right _validDocument ->
          TextIO.putStrLn (renderValidateSuccess file)
        Left failure -> do
          TextIO.hPutStrLn stderr (renderValidateFailure failure)
          exitWith (failureExitCode failure)
    Right (Contract file) -> do
      outcome <- contractCoreFile file
      case outcome of
        -- The contract carries its own final newline and is the
        -- complete stdout of a successful invocation: no validate
        -- success line is printed.
        Right contractText -> TextIO.putStr contractText
        Left failure -> do
          TextIO.hPutStrLn stderr (renderContractFailure failure)
          exitWith (contractFailureExitCode failure)
    Right (Verify file) -> do
      outcome <- verifyCoreFile file
      case outcome of
        -- Both semantic outcomes print their deterministic report to
        -- stdout with nothing on stderr; only the exit status —
        -- 0 verified, 3 unsupported — distinguishes them for tools.
        Right success -> do
          TextIO.putStrLn (renderVerifySuccess file success)
          exitWith (verifySuccessExitCode success)
        Left failure -> do
          TextIO.hPutStrLn stderr (renderVerifyFailure failure)
          exitWith (verifyFailureExitCode failure)
    Right (WaspGenerate coreFile root) ->
      waspOutcome coreFile (generateWaspApp coreFile root)
    Right (WaspCheck coreFile root) ->
      waspOutcome coreFile (checkWaspApp coreFile root)
    Left problem -> do
      hPutStrLn stderr problem
      exitFailure
  where
    -- Both wasp commands share one outcome contract: every completed
    -- outcome (generated, confined, unsupported, not confined) prints
    -- its deterministic report to stdout with nothing on stderr and
    -- exits 0, 3, or 4; every failure prints to stderr.
    waspOutcome coreFile run = do
      outcome <- run
      case outcome of
        Right success -> do
          TextIO.putStrLn (renderWaspSuccess coreFile success)
          exitWith (waspSuccessExitCode success)
        Left failure -> do
          TextIO.hPutStrLn stderr (renderWaspFailure failure)
          exitWith (waspFailureExitCode failure)
