-- | Base-only test harness for the pure CLI boundary.
--
-- Every check calls the public "Mithril.CLI" surface directly; no CLI
-- logic is duplicated here.  Each failing check is reported by name on
-- stderr and makes the harness exit nonzero.
module Main
  ( main
  ) where

import Data.List (isInfixOf)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Mithril.CLI (Command (..), parseCommand, renderHelp, renderVersion)

-- | Named checks over the pure CLI surface.
checks :: [(String, Bool)]
checks =
  [ ( "no arguments select help"
    , parseCommand [] == Right ShowHelp
    )
  , ( "--help selects help"
    , parseCommand ["--help"] == Right ShowHelp
    )
  , ( "-h selects help"
    , parseCommand ["-h"] == Right ShowHelp
    )
  , ( "--version selects version"
    , parseCommand ["--version"] == Right ShowVersion
    )
  , ( "an unknown argument is rejected with a message naming it"
    , isRejectionMentioning "frobnicate" (parseCommand ["frobnicate"])
    )
  , ( "extra arguments after --help are rejected"
    , isRejection (parseCommand ["--help", "--version"])
    )
  , ( "extra arguments after --version are rejected"
    , isRejection (parseCommand ["--version", "extra"])
    )
  , ( "help contains a Usage: section"
    , "Usage:" `isInfixOf` renderHelp
    )
  , ( "help states that compiler commands are not implemented"
    , "Compiler commands are not implemented yet." `isInfixOf` renderHelp
    )
  , ( "version rendering produces the exact version line"
    , renderVersion "0.1.0.0" == "mithril 0.1.0.0"
    )
  ]

-- | A rejection is a 'Left' carrying a non-empty message.
isRejection :: Either String Command -> Bool
isRejection (Left message) = not (null message)
isRejection (Right _) = False

-- | Like 'isRejection', but the message must also name the argument.
isRejectionMentioning :: String -> Either String Command -> Bool
isRejectionMentioning argument result =
  case result of
    Left message -> argument `isInfixOf` message
    Right _ -> False

main :: IO ()
main =
  case [name | (name, passed) <- checks, not passed] of
    [] -> putStrLn ("All " ++ show (length checks) ++ " checks passed.")
    failures -> do
      mapM_ (\name -> hPutStrLn stderr ("FAIL: " ++ name)) failures
      hPutStrLn stderr
        ( show (length failures)
            ++ " of "
            ++ show (length checks)
            ++ " checks failed."
        )
      exitFailure
