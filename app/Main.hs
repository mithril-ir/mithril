-- | Effectful entry point for the @mithril@ executable.
--
-- All argument interpretation and rendering is pure and lives in
-- "Mithril.CLI"; the validate boundary lives in
-- "Mithril.Command.Validate".  This module only wires together the
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
import Mithril.Command.Validate
  ( failureExitCode
  , renderValidateFailure
  , renderValidateSuccess
  , validateCoreFile
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
    Left problem -> do
      hPutStrLn stderr problem
      exitFailure
