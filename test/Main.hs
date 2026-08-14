-- | Test-suite runner: names the check groups and hands them to the
-- shared harness in "Mithril.Test".  The checks themselves live in
-- "Mithril.CLITests" (pure CLI boundary),
-- "Mithril.CoreValidationTests" (structural validation boundary),
-- "Mithril.CoreResolutionTests" (name-resolution boundary), and
-- "Mithril.CLIProcessTests" (the real executable as a process).
module Main
  ( main
  ) where

import qualified Mithril.CLIProcessTests
import qualified Mithril.CLITests
import qualified Mithril.CoreResolutionTests
import qualified Mithril.CoreValidationTests
import Mithril.Test (runGroups)

main :: IO ()
main =
  runGroups
    [ ("CLI", Mithril.CLITests.tests)
    , ("Core validation", Mithril.CoreValidationTests.tests)
    , ("Core resolution", Mithril.CoreResolutionTests.tests)
    , ("CLI process", Mithril.CLIProcessTests.tests)
    ]
