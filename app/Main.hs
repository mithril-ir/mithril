-- | Effectful entry point for the @mithril@ executable.
--
-- All argument interpretation and rendering is pure and lives in
-- "Mithril.CLI".  This module only wires together the process
-- arguments, stdout, stderr, the package version, and the exit status.
module Main
  ( main
  ) where

import Data.Version (showVersion)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Mithril.CLI (Command (..), parseCommand, renderHelp, renderVersion)
import Paths_mithril_ir (version)

main :: IO ()
main = do
  arguments <- getArgs
  case parseCommand arguments of
    Right ShowHelp -> putStr renderHelp
    Right ShowVersion -> putStrLn (renderVersion (showVersion version))
    Left problem -> do
      hPutStrLn stderr problem
      exitFailure
