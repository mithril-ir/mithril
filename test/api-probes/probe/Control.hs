-- Control (must compile): the legitimate public pipeline, written
-- exactly as a downstream consumer would write it — through
-- normalization and on into the public contract and verifier APIs,
-- so each boundary's one accepted input (a normalized document
-- obtained through the public pipeline) is demonstrably reachable
-- from outside.  The verifier action is referenced but deliberately
-- not executed, so compiling (or even running) this probe never
-- invokes Agda.  If this probe ever stops compiling, the probe
-- environment itself is broken and the attack probes' failures prove
-- nothing — the driver therefore builds this one first and requires
-- success.
module Main
  ( main
  ) where

import qualified Data.ByteString.Char8 as Char8

import Mithril.Core.Contract (renderCoreContract)
import Mithril.Core.Normalization (normalizeCoreDocument)
import Mithril.Core.Resolution (resolveCoreDocument)
import Mithril.Core.Typing (typecheckCoreDocument)
import Mithril.Core.Validation
  ( bundledCoreSchema
  , parseCoreDocument
  , validateCoreDocument
  )
import Mithril.Core.Verification (verifyCoreDocument)

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
                Right resolvedDocument ->
                  case typecheckCoreDocument resolvedDocument of
                    Left _ -> putStrLn "ill-typed"
                    Right typedDocument ->
                      case normalizeCoreDocument typedDocument of
                        Left _ -> putStrLn "internal normalizer error"
                        Right normalizedDocument ->
                          case renderCoreContract normalizedDocument of
                            Left _ -> putStrLn "internal contract renderer error"
                            Right _contract ->
                              -- The verifier boundary accepts the same
                              -- normalized document; forcing the IO
                              -- action's closure proves reachability
                              -- without ever running the checker.
                              verifyCoreDocument normalizedDocument
                                `seq` putStrLn "contract rendered, verifier reachable"
