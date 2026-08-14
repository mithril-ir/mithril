-- | Test-suite runner: names the check groups and hands them to the
-- shared harness in "Mithril.Test".  The checks themselves live in
-- "Mithril.CLITests" (pure CLI boundary) and
-- "Mithril.CoreValidationTests" (structural validation boundary).
module Main
  ( main
  ) where

import qualified Mithril.CLITests
import qualified Mithril.CoreValidationTests
import Mithril.Test (runGroups)

main :: IO ()
main =
  runGroups
    [ ("CLI", Mithril.CLITests.tests)
    , ("Core validation", Mithril.CoreValidationTests.tests)
    ]
