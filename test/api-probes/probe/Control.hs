-- Control (must compile): the legitimate public pipeline, written
-- exactly as a downstream consumer would write it.  If this probe
-- ever stops compiling, the probe environment itself is broken and
-- the attack probes' failures prove nothing — the driver therefore
-- builds this one first and requires success.
module Main
  ( main
  ) where

import qualified Data.ByteString.Char8 as Char8

import Mithril.Core.Resolution (resolveCoreDocument)
import Mithril.Core.Validation
  ( bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )

main :: IO ()
main =
  case bundledCoreSchema of
    Left _ -> putStrLn "internal schema error"
    Right schema ->
      case parseCoreDocument (Char8.pack "{}") of
        Left _ -> putStrLn "parse error"
        Right document ->
          case validateCoreDocument schema document of
            Left _ -> putStrLn "structurally invalid"
            Right validDocument ->
              case resolveCoreDocument validDocument of
                Left _ -> putStrLn "unresolved"
                Right _ -> putStrLn "resolved"
