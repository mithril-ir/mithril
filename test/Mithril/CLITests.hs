-- | Checks over the pure CLI boundary in "Mithril.CLI".
--
-- Every check calls the public surface directly; no CLI logic is
-- duplicated here.  The pre-existing bootstrap behaviors (no
-- arguments, help, short help, version, unknown arguments, extra
-- arguments) are pinned alongside the @validate FILE@,
-- @contract FILE@, and @verify FILE@ grammars, and the
-- argument-escaping checks pin that no user-supplied argument can
-- add physical lines or terminal controls to a diagnostic.
module Mithril.CLITests
  ( tests
  ) where

import Data.List (isInfixOf)

import Mithril.CLI
  ( Command (..)
  , displayArgument
  , parseCommand
  , renderHelp
  , renderVersion
  )
import Mithril.Test (Check, check)

-- | All CLI checks (pure; 'IO' only to fit the harness).
tests :: IO [Check]
tests = pure checks

checks :: [Check]
checks =
  [ check
      "no arguments select help"
      (parseCommand [] == Right ShowHelp)
  , check
      "--help selects help"
      (parseCommand ["--help"] == Right ShowHelp)
  , check
      "-h selects help"
      (parseCommand ["-h"] == Right ShowHelp)
  , check
      "--version selects version"
      (parseCommand ["--version"] == Right ShowVersion)
  , check
      "an unknown argument is rejected with a message naming it"
      (isRejectionMentioning "frobnicate" (parseCommand ["frobnicate"]))
  , check
      "an unknown option is rejected"
      (isRejection (parseCommand ["--validate"]))
  , check
      "extra arguments after --help are rejected"
      (isRejection (parseCommand ["--help", "--version"]))
  , check
      "extra arguments after --version are rejected"
      (isRejection (parseCommand ["--version", "extra"]))
  , check
      "validate FILE parses"
      (parseCommand ["validate", "doc.mir.json"] == Right (Validate "doc.mir.json"))
  , check
      "validate without FILE is rejected mentioning FILE"
      (isRejectionMentioning "FILE" (parseCommand ["validate"]))
  , check
      "validate with extra arguments is rejected naming the extras"
      (isRejectionMentioning "surplus" (parseCommand ["validate", "doc.mir.json", "surplus"]))
  , check
      "contract FILE parses"
      (parseCommand ["contract", "doc.mir.json"] == Right (Contract "doc.mir.json"))
  , check
      "contract without FILE is rejected mentioning FILE"
      (isRejectionMentioning "FILE" (parseCommand ["contract"]))
  , check
      "contract with extra arguments is rejected naming the extras"
      (isRejectionMentioning "surplus" (parseCommand ["contract", "doc.mir.json", "surplus"]))
  , check
      "verify FILE parses"
      (parseCommand ["verify", "doc.mir.json"] == Right (Verify "doc.mir.json"))
  , check
      "verify without FILE is rejected mentioning FILE"
      (isRejectionMentioning "FILE" (parseCommand ["verify"]))
  , check
      "verify with extra arguments is rejected naming the extras"
      (isRejectionMentioning "surplus" (parseCommand ["verify", "doc.mir.json", "surplus"]))
  , check
      "a dash-prefixed verify FILE stays a file, never an option"
      (parseCommand ["verify", "--frobnicate"] == Right (Verify "--frobnicate"))
  , check
      "help contains a Usage: section"
      ("Usage:" `isInfixOf` renderHelp)
  , check
      "help lists the validate command"
      ("validate FILE" `isInfixOf` renderHelp)
  , check
      "help lists the contract command"
      ("contract FILE" `isInfixOf` renderHelp)
  , check
      "help scopes validate to structural validation plus name resolution plus static typing plus normalization"
      ( ("structural Core v0 validation" `isInfixOf` renderHelp)
          && ("name resolution" `isInfixOf` renderHelp)
          && ("static typing" `isInfixOf` renderHelp)
          && ("deterministic normalization" `isInfixOf` renderHelp)
      )
  , check
      "help disclaims semantic verification and proof checking"
      ("not semantic verification and not proof checking" `isInfixOf` renderHelp)
  , check
      "help scopes normalization to structural work without simplification or evaluation"
      ( ("no boolean simplification, constant folding," `isInfixOf` renderHelp)
          && ("or policy evaluation" `isInfixOf` renderHelp)
      )
  , check
      "help scopes contract to deterministic review rendering with unverified obligations"
      ( ("security contract for human review" `isInfixOf` renderHelp)
          && ("remain unverified proof obligations" `isInfixOf` renderHelp)
      )
  , check
      "help disclaims policy evaluation, generation, and semantic diffing for contract"
      ( ("evaluates no policy, proves and verifies nothing," `isInfixOf` renderHelp)
          && ("is not a semantic diff" `isInfixOf` renderHelp)
      )
  , check
      "help lists the verify command"
      ("verify FILE" `isInfixOf` renderHelp)
  , check
      "help scopes verify to the one supported obligation under Agda 2.8.0"
      ( ("exactly one proof slice" `isInfixOf` renderHelp)
          && ("Agda 2.8.0" `isInfixOf` renderHelp)
          && ("--safe --no-libraries --ignore-interfaces" `isInfixOf` renderHelp)
      )
  , check
      "help states that canonical Acme and the other families remain unverified"
      ( ("including the canonical" `isInfixOf` renderHelp)
          && ("TenantIsolation and AuthenticatedMutation" `isInfixOf` renderHelp)
          && ("remain unverified" `isInfixOf` renderHelp)
      )
  , check
      "help states that verify never reports a violation"
      ( ("verify never reports a violation" `isInfixOf` renderHelp)
          && ("unsupported, not a proved violation" `isInfixOf` renderHelp)
          && ("never a semantic verdict" `isInfixOf` renderHelp)
      )
  , check
      "help names the verifier's trusted components"
      ( "the embedded Agda kernel, the Agda toolchain, and the support"
          `isInfixOf` renderHelp
      )
  , check
      "help states that no compiler stage beyond the three commands is implemented"
      ( "No other compiler stage is implemented yet: no complete verifier,\n\
        \no semantic diff, and no target code generation.\n"
          `isInfixOf` renderHelp
      )
  , check
      "version rendering produces the exact version line"
      (renderVersion "0.1.0.0" == "mithril 0.1.0.0")
  ]
    ++ argumentEscapingChecks

-- | Finding-5 regressions: user-controlled arguments inside usage
-- errors are rendered through 'displayArgument', so control
-- characters render visibly, quotes and backslashes cannot break the
-- quoting convention, and every usage error keeps exactly two
-- physical lines (the diagnostic and the usage hint).
argumentEscapingChecks :: [Check]
argumentEscapingChecks =
  [ check
      "ordinary arguments render in the existing quoted form"
      (displayArgument "frobnicate" == "'frobnicate'")
  , check
      "arguments with controls, quotes, or backslashes render as string literals"
      ( displayArgument "bad\narg" == "\"bad\\narg\""
          && displayArgument "it's" == "\"it's\""
          && displayArgument "back\\slash" == "\"back\\\\slash\""
          && displayArgument "quo\"te" == "\"quo\\\"te\""
          && displayArgument "" == "\"\""
      )
  , check
      "the ordinary unknown-argument message is byte-stable"
      ( parseCommand ["frobnicate"]
          == Left
            "mithril: unknown argument 'frobnicate'\nRun 'mithril --help' for usage."
      )
  , check
      "the ordinary extra-arguments message is byte-stable"
      ( parseCommand ["validate", "doc.mir.json", "surplus"]
          == Left
            "mithril: unexpected extra arguments after 'validate FILE': \
            \'surplus'\nRun 'mithril --help' for usage."
      )
  , check
      "the contract missing-FILE message is byte-stable"
      ( parseCommand ["contract"]
          == Left
            "mithril: 'contract' requires exactly one FILE argument\n\
            \Run 'mithril --help' for usage."
      )
  , check
      "the contract extra-arguments message is byte-stable"
      ( parseCommand ["contract", "doc.mir.json", "surplus"]
          == Left
            "mithril: unexpected extra arguments after 'contract FILE': \
            \'surplus'\nRun 'mithril --help' for usage."
      )
  , check
      "an unknown argument containing a newline renders it visibly"
      ( parseCommand ["bad\narg"]
          == Left
            "mithril: unknown argument \"bad\\narg\"\nRun 'mithril --help' for usage."
      )
  , check
      "an unknown argument containing a carriage return stays on one line"
      (rejectsOnTwoLines ["bad\rarg"] "\\r")
  , check
      "an unknown argument containing ESC cannot emit a terminal control"
      (rejectsOnTwoLines ["bad\ESCarg"] "\\ESC")
  , check
      "an unknown argument containing an apostrophe keeps the quoting intact"
      (rejectsOnTwoLines ["it's"] "\"it's\"")
  , check
      "an unknown argument containing a backslash keeps the quoting intact"
      (rejectsOnTwoLines ["back\\slash"] "\\\\")
  , check
      "a newline in an extra argument after --help stays on one line"
      (rejectsOnTwoLines ["--help", "x\ny"] "\\n")
  , check
      "a control character in an extra argument after validate FILE stays on one line"
      (rejectsOnTwoLines ["validate", "doc.mir.json", "x\ty"] "\\t")
  , check
      "no hostile argument adds a physical diagnostic line"
      ( all
          (\argument -> countsTwoLines (parseCommand [argument]))
          ["a\nb", "a\r\nb", "a\rb", "a\ESCb", "a\DELb", "a\tb", "it's", "a\\b", "q\"q", ""]
      )
  , check
      "hostile-argument rendering is byte-identical across repetitions"
      (parseCommand ["bad\narg"] == parseCommand ["bad\narg"])
  ]

-- | A rejection is a 'Left' carrying a non-empty message.
isRejection :: Either String Command -> Bool
isRejection (Left message) = not (null message)
isRejection (Right _) = False

-- | Like 'isRejection', but the message must also mention the text.
isRejectionMentioning :: String -> Either String Command -> Bool
isRejectionMentioning text result =
  case result of
    Left message -> text `isInfixOf` message
    Right _ -> False

-- | The invocation is rejected, the message is exactly two physical
-- lines, and the expected visible escape appears in it.
rejectsOnTwoLines :: [String] -> String -> Bool
rejectsOnTwoLines arguments visible =
  case parseCommand arguments of
    Left message -> length (lines message) == 2 && visible `isInfixOf` message
    Right _ -> False

-- | The invocation is rejected with exactly two physical lines.
countsTwoLines :: Either String Command -> Bool
countsTwoLines result =
  case result of
    Left message -> length (lines message) == 2
    Right _ -> False
