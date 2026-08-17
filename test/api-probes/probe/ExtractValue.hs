-- Attack: recover a raw Aeson Value from a resolved document with
-- Data.Coerce.  Must fail twice over: a CoreDocument Resolved carries
-- the internal resolved representation, not a JSON value — no
-- conversion back to JSON exists — and the newtype constructor that
-- could unwrap the payload never leaves the hidden internal module.
module Main
  ( main
  ) where

import Data.Aeson (Value)
import Data.Coerce (coerce)
import Mithril.Core.Resolution (Resolved)
import Mithril.Core.Validation (CoreDocument)

extract :: CoreDocument Resolved -> Value
extract = coerce

main :: IO ()
main = extract `seq` pure ()
