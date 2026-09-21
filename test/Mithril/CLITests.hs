-- | Checks over the pure CLI boundary in "Mithril.CLI".
--
-- Every check calls the public surface directly; no CLI logic is
-- duplicated here.  The bootstrap behaviors (no
-- arguments, help, short help, version, unknown arguments, extra
-- arguments) are pinned alongside the @validate FILE@,
-- @contract FILE@, @verify FILE@, @wasp --help@ / @wasp -h@,
-- @wasp generate CORE_FILE WASP_ROOT@, and
-- @wasp check CORE_FILE WASP_ROOT@ grammars; the help-content checks
-- pin that both help texts stay short, conventional, and precise
-- about result meanings; and the argument-escaping checks pin that no
-- user-supplied argument can add physical lines or terminal controls
-- to a diagnostic.
module Mithril.CLITests
  ( tests
  ) where

import Data.List (isInfixOf, isPrefixOf, isSuffixOf)

import Mithril.CLI
  ( Command (..)
  , displayArgument
  , parseCommand
  , renderHelp
  , renderVersion
  , renderWaspHelp
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
      "a help flag after a FILE-taking command is its FILE, never a help request"
      ( parseCommand ["validate", "--help"] == Right (Validate "--help")
          && parseCommand ["contract", "-h"] == Right (Contract "-h")
      )
  , check
      "wasp generate CORE_FILE WASP_ROOT parses"
      ( parseCommand ["wasp", "generate", "doc.mir.json", "app"]
          == Right (WaspGenerate "doc.mir.json" "app")
      )
  , check
      "wasp check CORE_FILE WASP_ROOT parses"
      ( parseCommand ["wasp", "check", "doc.mir.json", "app"]
          == Right (WaspCheck "doc.mir.json" "app")
      )
  , check
      "wasp --help selects the Wasp-specific help"
      (parseCommand ["wasp", "--help"] == Right ShowWaspHelp)
  , check
      "wasp -h selects the Wasp-specific help"
      (parseCommand ["wasp", "-h"] == Right ShowWaspHelp)
  , check
      "extra arguments after wasp --help are rejected naming the extras and the wasp help"
      ( parseCommand ["wasp", "--help", "extra"]
          == Left
            "mithril: unexpected extra arguments after 'wasp --help': 'extra'\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "extra arguments after wasp -h are rejected naming the extras and the wasp help"
      ( parseCommand ["wasp", "-h", "generate"]
          == Left
            "mithril: unexpected extra arguments after 'wasp -h': 'generate'\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "wasp --version is an unknown wasp subcommand, never the version"
      ( parseCommand ["wasp", "--version"]
          == Left
            "mithril: unknown wasp subcommand '--version'\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "a help flag after a wasp subcommand is its CORE_FILE, never a help request"
      ( parseCommand ["wasp", "generate", "--help"]
          == Left
            "mithril: 'wasp generate' requires exactly two arguments: CORE_FILE WASP_ROOT\n\
            \Run 'mithril wasp --help' for usage."
          && parseCommand ["wasp", "check", "-h", "app"] == Right (WaspCheck "-h" "app")
      )
  , check
      "wasp without a subcommand is rejected naming both subcommands and the wasp help"
      ( parseCommand ["wasp"]
          == Left
            "mithril: 'wasp' requires a subcommand: generate or check\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "an unknown wasp subcommand is rejected naming it and the wasp help"
      ( parseCommand ["wasp", "frobnicate", "a", "b"]
          == Left
            "mithril: unknown wasp subcommand 'frobnicate'\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "wasp generate with one argument is rejected naming both arguments and the wasp help"
      ( parseCommand ["wasp", "generate", "doc.mir.json"]
          == Left
            "mithril: 'wasp generate' requires exactly two arguments: CORE_FILE WASP_ROOT\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "wasp check without arguments is rejected naming both arguments and the wasp help"
      ( parseCommand ["wasp", "check"]
          == Left
            "mithril: 'wasp check' requires exactly two arguments: CORE_FILE WASP_ROOT\n\
            \Run 'mithril wasp --help' for usage."
      )
  , check
      "wasp check with extra arguments is rejected naming the extras and the wasp help"
      ( parseCommand ["wasp", "check", "doc.mir.json", "app", "surplus"]
          == Left
            "mithril: unexpected extra arguments after 'wasp check CORE_FILE WASP_ROOT': \
            \'surplus'\nRun 'mithril wasp --help' for usage."
      )
  , check
      "dash-prefixed wasp arguments stay paths, never options"
      ( parseCommand ["wasp", "generate", "--core", "--root"]
          == Right (WaspGenerate "--core" "--root")
      )
  , check
      "a hostile wasp subcommand renders escaped on two lines"
      (rejectsOnTwoLines ["wasp", "bad\narg"] "\\n")
  , check
      "a hostile extra argument after wasp --help renders escaped on two lines"
      (rejectsOnTwoLines ["wasp", "--help", "x\ny"] "\\n")
  , check
      "version rendering produces the exact version line"
      (renderVersion "0.1.0.0" == "mithril 0.1.0.0")
  ]
    ++ helpChecks
    ++ waspHelpChecks
    ++ argumentEscapingChecks

-- | The root help is a conventional short command summary: a one-line
-- description, a usage section, the five commands with their
-- arguments plus the Wasp-specific help, the essential result
-- meanings with their exit codes (UNSUPPORTED being neither a safety
-- nor a violation verdict), and pointers to README.md and
-- docs/current-scope.md for the exact scope.  It stays short and
-- terminal-friendly instead of restating the scope ledger.
helpChecks :: [Check]
helpChecks =
  [ check
      "help begins with a one-line description of the tool"
      ( "mithril - " `isPrefixOf` renderHelp
          && all ((<= 80) . length) (take 1 (lines renderHelp))
      )
  , check
      "help contains a Usage: section"
      ("\nUsage:\n" `isInfixOf` renderHelp)
  , check
      "help contains a Commands: section"
      ("\nCommands:\n" `isInfixOf` renderHelp)
  , check
      "help lists the self-describing invocations"
      ( ("mithril --help | -h" `isInfixOf` renderHelp)
          && ("mithril --version" `isInfixOf` renderHelp)
      )
  , check
      "help lists every command with its arguments"
      ( all
          (`isInfixOf` renderHelp)
          [ "\n  validate FILE "
          , "\n  contract FILE "
          , "\n  verify FILE "
          , "\n  wasp generate CORE_FILE WASP_ROOT\n"
          , "\n  wasp check CORE_FILE WASP_ROOT\n"
          ]
      )
  , check
      "help points at the Wasp-specific help"
      ("\n  wasp --help " `isInfixOf` renderHelp)
  , check
      "help states the verify gate for wasp generate and the byte-exact meaning of wasp check"
      ( ("(VERIFIED required)" `isInfixOf` renderHelp)
          && ("exactly the regenerated closed Wasp source root" `isInfixOf` flattened renderHelp)
      )
  , check
      "help states the essential results with their exit codes"
      ( all
          (`isInfixOf` renderHelp)
          [ "\nResults:\n"
          , "\n  VERIFIED (exit 0) "
          , "\n  UNSUPPORTED (exit 3) "
          , "\n  CONFINED (exit 0) "
          , "NOT CONFINED (exit 4)"
          ]
      )
  , check
      "help states that UNSUPPORTED is neither a safety nor a violation verdict and that no VIOLATED result exists"
      ( "The document lies outside the implemented proof rules. This is neither a safety nor a violation verdict; no VIOLATED result exists."
          `isInfixOf` flattened renderHelp
      )
  , check
      "help states that invalid input exits 1 and that a tool failure is never a verdict"
      ("Invalid input exits 1. A tool failure exits 2 and is never a verdict." `isInfixOf` renderHelp)
  , check
      "help points at README.md and docs/current-scope.md for the exact scope"
      ( "See README.md for the quickstart and docs/current-scope.md for the exact supported scope, trusted components, and non-claims."
          `isInfixOf` flattened renderHelp
      )
  , check
      "help never calls a result unsafe, dangerous, or a proof"
      (not (any (`isInfixOf` renderHelp) ["unsafe", "dangerous", "vulnerab", "proves"]))
  , check
      "help does not restate the scope ledger"
      ( not
          ( any
              (`isInfixOf` renderHelp)
              [ "--safe --no-libraries --ignore-interfaces"
              , "mode 0700"
              , "semantic-preservation"
              , "TenantIsolation"
              , "No other compiler stage is implemented"
              ]
          )
      )
  , check
      "help is short: at most 40 lines"
      (length (lines renderHelp) <= 40)
  , check
      "help is terminal-friendly: every line fits in 80 columns"
      (all ((<= 80) . length) (lines renderHelp))
  , check
      "help ends with exactly one newline"
      (endsWithOneNewline renderHelp)
  ]

-- | The Wasp-specific help (@mithril wasp --help@ and @-h@): both
-- usage lines, what @generate@ and @check@ require and do, the exact
-- two profiles, the result meanings with their exit codes, the
-- closed-source-artifact warning that sends ordinary Wasp tooling to a
-- disposable copy (where NOT CONFINED is expected), and the separation
-- of mithril's own prerequisites from the runtime toolchain.
waspHelpChecks :: [Check]
waspHelpChecks =
  [ check
      "wasp help begins with its one-line description"
      ("mithril wasp - " `isPrefixOf` renderWaspHelp)
  , check
      "wasp help shows both usage lines and the help spelling"
      ( all
          (`isInfixOf` renderWaspHelp)
          [ "\nUsage:\n"
          , "\n  mithril wasp generate CORE_FILE WASP_ROOT\n"
          , "\n  mithril wasp check CORE_FILE WASP_ROOT\n"
          , "\n  mithril wasp --help | -h\n"
          ]
      )
  , check
      "wasp help states that generate requires the verification gate and a supported profile"
      ( ("\n  generate " `isInfixOf` renderWaspHelp)
          && ("Run the verification gate on CORE_FILE (VERIFIED required), lower its verified cases through a supported Wasp profile, install the generated source root at WASP_ROOT, and finish with the check below."
                `isInfixOf` flattened renderWaspHelp)
      )
  , check
      "wasp help states what generate initializes, replaces, and refuses"
      ( "An absent or empty WASP_ROOT is initialized; a root mithril generated earlier that still holds nothing else is replaced as a whole; any other nonempty directory is refused unchanged."
          `isInfixOf` flattened renderWaspHelp
      )
  , check
      "wasp help states that check regenerates the expected bundle in memory and writes nothing"
      ( ("\n  check " `isInfixOf` renderWaspHelp)
          && ("Regenerate the expected source bundle in memory and check that WASP_ROOT is exactly that bundle: every managed file byte-identical, nothing missing, nothing else present. Nothing is written."
                `isInfixOf` flattened renderWaspHelp)
      )
  , check
      "wasp help states the two profiles exactly and that every other verified document is unsupported"
      ( "Exactly one change-other case selects Profile v0; that case followed by exactly one bounded self-update case selects Profile v1. Every other verified document is UNSUPPORTED here: VERIFIED, but not lowered."
          `isInfixOf` flattened renderWaspHelp
      )
  , check
      "wasp help states the result meanings with their exit codes"
      ( all
          (`isInfixOf` renderWaspHelp)
          [ "\nResults:\n"
          , "\n  GENERATED, CONFINED (exit 0) "
          , "\n  NOT CONFINED (exit 4) "
          , "\n  UNSUPPORTED (exit 3) "
          ]
          && ("CORE_FILE is outside the implemented proof rules or the two Wasp profiles. Neither a safety nor a violation verdict."
                `isInfixOf` flattened renderWaspHelp)
          && ("Invalid CORE_FILE or an unusable WASP_ROOT path exits 1. A tool failure exits 2 and is never a verdict."
                `isInfixOf` flattened renderWaspHelp)
      )
  , check
      "wasp help calls the generated root a closed source artifact and sends Wasp tooling to a disposable copy"
      ( "The generated root is a closed source artifact, not a general Wasp application to edit by hand. Run Wasp tooling only in a disposable copy of it: wasp install, wasp start, and migrations add node_modules, .wasp, package-lock.json, migrations, and environment files, so that copy becomes NOT CONFINED as expected while the clean generated root stays CONFINED. Regenerate the clean root and refresh the copy whenever CORE_FILE changes."
          `isInfixOf` flattened renderWaspHelp
      )
  , check
      "wasp help separates mithril's own prerequisites from the runtime toolchain"
      ( "mithril itself needs Agda 2.8.0 for the verification gate but no Wasp, Node, or PostgreSQL installation; running the copy needs the Wasp 0.25.0 CLI, Node.js 24, and a PostgreSQL database."
          `isInfixOf` flattened renderWaspHelp
      )
  , check
      "wasp help points at README.md for the quickstart"
      ("See README.md for the quickstart." `isInfixOf` renderWaspHelp)
  , check
      "wasp help never calls a result unsafe, dangerous, or a proof"
      (not (any (`isInfixOf` renderWaspHelp) ["unsafe", "dangerous", "vulnerab", "proves", "proof of"]))
  , check
      "wasp help is short: at most 50 lines"
      (length (lines renderWaspHelp) <= 50)
  , check
      "wasp help is terminal-friendly: every line fits in 80 columns"
      (all ((<= 80) . length) (lines renderWaspHelp))
  , check
      "wasp help ends with exactly one newline"
      (endsWithOneNewline renderWaspHelp)
  , check
      "the two help texts are distinct"
      (renderHelp /= renderWaspHelp)
  ]

-- | Argument-escaping regressions: user-controlled arguments inside usage
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
      "no hostile wasp subcommand adds a physical diagnostic line"
      ( all
          (\argument -> countsTwoLines (parseCommand ["wasp", argument]))
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

-- | The text with every run of whitespace (including the line breaks
-- and the indentation of wrapped help columns) collapsed to one
-- space, so a sentence can be pinned regardless of where it wraps.
flattened :: String -> String
flattened = unwords . words

-- | The text ends with a newline and not with a blank line.
endsWithOneNewline :: String -> Bool
endsWithOneNewline text = "\n" `isSuffixOf` text && not ("\n\n" `isSuffixOf` text)
