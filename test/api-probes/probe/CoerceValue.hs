-- Attack: mint a CoreDocument Resolved directly from a raw Aeson
-- Value with Data.Coerce, bypassing the entire pipeline.  Must fail:
-- unwrapping or wrapping the newtype requires its constructor, which
-- never leaves the hidden internal module.
module Main
  ( main
  ) where

import Data.Aeson (Value)
import Data.Coerce (coerce)
import Mithril.Core.Resolution (Resolved)
import Mithril.Core.Validation (CoreDocument)

mint :: Value -> CoreDocument Resolved
mint = coerce

main :: IO ()
main = mint `seq` pure ()
