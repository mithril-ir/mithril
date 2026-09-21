-- | Pure command-line boundary for the @mithril@ executable.
--
-- Argument interpretation and output rendering live here so they can be
-- tested without I/O.  All effects — reading arguments, writing to
-- handles, choosing the exit status — belong to the executable's
-- @Main@ module.
--
-- The tool understands the self-describing invocations (the root help,
-- the Wasp-specific help, and the version) plus the five commands of
-- 'Command': @validate FILE@, @contract FILE@, @verify FILE@,
-- @wasp generate CORE_FILE WASP_ROOT@, and
-- @wasp check CORE_FILE WASP_ROOT@.  What each command establishes is
-- stated by its command module; see @docs\/current-scope.md@ for the
-- supported slice, result meanings, trusted components, and explicit
-- non-claims.  The help texts are deliberately short command summaries
-- and point there instead of restating that ledger.
module Mithril.CLI
  ( Command (..)
  , parseCommand
  , displayArgument
  , renderHelp
  , renderWaspHelp
  , renderVersion
  ) where

import Data.Char (isPrint)

-- | A fully interpreted command-line invocation.
data Command
  = -- | Print the help text and exit successfully.
    ShowHelp
  | -- | Print the Wasp-specific help text and exit successfully.
    ShowWaspHelp
  | -- | Print the package version and exit successfully.
    ShowVersion
  | -- | Parse FILE, validate it structurally against the compiled-in
    -- Core v0 schema, resolve every Core v0 name, typecheck the
    -- resolved document, and normalize the typed document.
    Validate FilePath
  | -- | Run the complete @validate@ pipeline on FILE and print the
    -- deterministic security contract of the normalized document.
    Contract FilePath
  | -- | Run the complete @validate@ pipeline on FILE and verify the
    -- normalized document against the one implemented support rule,
    -- checking the generated obligation with Agda 2.8.0.
    Verify FilePath
  | -- | Run the complete @validate@ pipeline and the verify gate on
    -- CORE_FILE, then write the closed Wasp bundle of the verified
    -- slice into WASP_ROOT and check its confinement.
    WaspGenerate FilePath FilePath
  | -- | Run the same pipeline and gate on CORE_FILE, regenerate the
    -- bundle without writing, and check that WASP_ROOT is exactly
    -- the closed profile.
    WaspCheck FilePath FilePath
  deriving (Eq, Show)

-- | Interpret raw command-line arguments.
--
-- Exactly these invocations are accepted: no arguments (help),
-- @--help@, @-h@, @--version@, @validate FILE@, @contract FILE@,
-- @verify FILE@, @wasp --help@, @wasp -h@, @wasp generate CORE_FILE
-- WASP_ROOT@, and @wasp check CORE_FILE WASP_ROOT@.
-- Anything else — an unknown argument, a missing FILE, or extra
-- arguments after a complete invocation — yields a deterministic
-- error message intended for stderr.  Every user-supplied argument
-- embedded in such a message is rendered through 'displayArgument',
-- so no argument can add physical lines or terminal controls to a
-- diagnostic.
parseCommand :: [String] -> Either String Command
parseCommand [] = Right ShowHelp
parseCommand ("validate" : rest) = fileCommand "validate" Validate rest
parseCommand ("contract" : rest) = fileCommand "contract" Contract rest
parseCommand ("verify" : rest) = fileCommand "verify" Verify rest
parseCommand ("wasp" : rest) = waspCommand rest
parseCommand (argument : rest) =
  case recognize argument of
    Nothing -> Left (unknownArgumentError argument)
    Just command
      | null rest -> Right command
      | otherwise -> Left (extraArgumentsError usageHint argument rest)

-- | Interpret the argument list after a FILE-taking command name.
-- The next argument is always FILE — a leading dash does not make it
-- an option — and anything after it is rejected.
fileCommand
  :: String -> (FilePath -> Command) -> [String] -> Either String Command
fileCommand commandName construct rest =
  case rest of
    [file] -> Right (construct file)
    [] -> Left (missingFileError commandName)
    (_file : extras) ->
      Left (extraArgumentsError usageHint (commandName ++ " FILE") extras)

-- | Interpret the argument list after the @wasp@ command name: the
-- Wasp-specific help (@--help@ or @-h@, alone), or a subcommand,
-- @generate@ or @check@, followed by exactly CORE_FILE and WASP_ROOT.
-- The help flags are recognized only in the subcommand position: after
-- a subcommand, neither argument is ever an option, and anything after
-- the two is rejected.  Every diagnostic of this grammar points at the
-- Wasp-specific help.
waspCommand :: [String] -> Either String Command
waspCommand rest =
  case rest of
    [] -> Left missingWaspSubcommandError
    ("generate" : more) -> twoArguments "wasp generate" WaspGenerate more
    ("check" : more) -> twoArguments "wasp check" WaspCheck more
    (flag : more)
      | isHelpFlag flag ->
          if null more
            then Right ShowWaspHelp
            else Left (extraArgumentsError waspUsageHint ("wasp " ++ flag) more)
    (subcommand : _) -> Left (unknownWaspSubcommandError subcommand)

twoArguments
  :: String -> (FilePath -> FilePath -> Command) -> [String] -> Either String Command
twoArguments commandName construct arguments =
  case arguments of
    [coreFile, root] -> Right (construct coreFile root)
    (_coreFile : _root : extras) ->
      Left (extraArgumentsError waspUsageHint (commandName ++ " CORE_FILE WASP_ROOT") extras)
    _ -> Left (missingWaspArgumentsError commandName)

-- | Map a single recognized option to its command.
recognize :: String -> Maybe Command
recognize "--version" = Just ShowVersion
recognize argument
  | isHelpFlag argument = Just ShowHelp
  | otherwise = Nothing

-- | The two spellings of a help request, shared by the root and the
-- @wasp@ grammar.
isHelpFlag :: String -> Bool
isHelpFlag argument = argument == "--help" || argument == "-h"

-- | Render a user-supplied command-line argument for inclusion in a
-- diagnostic.  This is the single rendering point for every
-- user-controlled argument that parse errors embed.
--
-- An ordinary argument — non-empty, printable, and free of quote and
-- backslash characters — keeps the existing readable @'...'@ form.
-- Anything else is rendered as a Haskell string literal via 'show':
-- control characters (newline, carriage return, escape, delete, ...)
-- become visible escape sequences instead of physical output
-- controls, and quotes and backslashes cannot break the quoting
-- convention.  Rendering is pure, deterministic, and never introduces
-- a line break.
displayArgument :: String -> String
displayArgument argument
  | not (null argument) && all ordinary argument = "'" ++ argument ++ "'"
  | otherwise = show argument
  where
    ordinary c = isPrint c && c /= '\'' && c /= '"' && c /= '\\'

-- | Deterministic error for an unrecognized argument.
unknownArgumentError :: String -> String
unknownArgumentError argument =
  "mithril: unknown argument " ++ displayArgument argument ++ "\n" ++ usageHint

-- | Deterministic error for arguments after a complete invocation,
-- closed by the given usage hint.
extraArgumentsError :: String -> String -> [String] -> String
extraArgumentsError hint argument extras =
  "mithril: unexpected extra arguments after "
    ++ displayArgument argument
    ++ ": "
    ++ unwords (map displayArgument extras)
    ++ "\n"
    ++ hint

-- | Deterministic error for a FILE-taking command without its FILE
-- argument.
missingFileError :: String -> String
missingFileError commandName =
  "mithril: '"
    ++ commandName
    ++ "' requires exactly one FILE argument\n"
    ++ usageHint

-- | Deterministic error for @wasp@ without its subcommand.
missingWaspSubcommandError :: String
missingWaspSubcommandError =
  "mithril: 'wasp' requires a subcommand: generate or check\n" ++ waspUsageHint

-- | Deterministic error for an unrecognized @wasp@ subcommand.
unknownWaspSubcommandError :: String -> String
unknownWaspSubcommandError subcommand =
  "mithril: unknown wasp subcommand " ++ displayArgument subcommand ++ "\n" ++ waspUsageHint

-- | Deterministic error for a @wasp@ subcommand without exactly its
-- two arguments.
missingWaspArgumentsError :: String -> String
missingWaspArgumentsError commandName =
  "mithril: '"
    ++ commandName
    ++ "' requires exactly two arguments: CORE_FILE WASP_ROOT\n"
    ++ waspUsageHint

usageHint :: String
usageHint = "Run 'mithril --help' for usage."

waspUsageHint :: String
waspUsageHint = "Run 'mithril wasp --help' for usage."

-- | Help text.  Ends with a newline; print with 'putStr'.
--
-- A short command summary in the conventional shape (one-line
-- description, usage, commands, result meanings, pointers), never a
-- restatement of the scope ledger: every line fits in 80 columns, and
-- the exact supported scope, trusted components, and non-claims are
-- delegated to the documents the last paragraph names.
renderHelp :: String
renderHelp =
  unlines
    [ "mithril - check Mithril Core permission rules and generate a Wasp demonstrator"
    , ""
    , "Usage:"
    , "  mithril <command> [arguments]"
    , "  mithril --help | -h     Print this help text."
    , "  mithril --version       Print the package version."
    , ""
    , "Commands:"
    , "  validate FILE           Check that FILE is a valid Mithril Core v0 document."
    , "  contract FILE           Print the review contract of FILE. It is a review"
    , "                          aid, not a proof."
    , "  verify FILE             Verify the one selected guarantee of FILE with"
    , "                          Agda 2.8.0: VERIFIED or UNSUPPORTED."
    , "  wasp generate CORE_FILE WASP_ROOT"
    , "                          Verify CORE_FILE (VERIFIED required), install its"
    , "                          closed Wasp source root at WASP_ROOT, and check it."
    , "  wasp check CORE_FILE WASP_ROOT"
    , "                          Check that WASP_ROOT is exactly the regenerated"
    , "                          closed Wasp source root of CORE_FILE."
    , "  wasp --help             Print the Wasp-specific help text."
    , ""
    , "Results:"
    , "  VERIFIED (exit 0)       Agda accepted every required proof of every selected"
    , "                          case of the document's one selected guarantee."
    , "  UNSUPPORTED (exit 3)    The document lies outside the implemented proof"
    , "                          rules. This is neither a safety nor a violation"
    , "                          verdict; no VIOLATED result exists."
    , "  CONFINED (exit 0)       The Wasp source root is byte-identical to the"
    , "                          regenerated closed bundle. NOT CONFINED (exit 4)"
    , "                          otherwise."
    , ""
    , "Invalid input exits 1. A tool failure exits 2 and is never a verdict."
    , ""
    , "See README.md for the quickstart and docs/current-scope.md for the exact"
    , "supported scope, trusted components, and non-claims."
    ]

-- | Wasp-specific help text (@mithril wasp --help@).  Ends with a
-- newline; print with 'putStr'.
--
-- Beyond the two subcommands and their results, it states the one fact
-- a first-time user needs and the reports alone do not convey: the
-- generated root is a closed source artifact, so ordinary Wasp tooling
-- belongs in a disposable copy, where NOT CONFINED is the expected
-- outcome.  Every line fits in 80 columns.
renderWaspHelp :: String
renderWaspHelp =
  unlines
    [ "mithril wasp - generate and check the closed Wasp demonstrator"
    , ""
    , "Usage:"
    , "  mithril wasp generate CORE_FILE WASP_ROOT"
    , "  mithril wasp check CORE_FILE WASP_ROOT"
    , "  mithril wasp --help | -h"
    , ""
    , "Commands:"
    , "  generate    Run the verification gate on CORE_FILE (VERIFIED required),"
    , "              lower its verified cases through a supported Wasp profile,"
    , "              install the generated source root at WASP_ROOT, and finish"
    , "              with the check below. An absent or empty WASP_ROOT is"
    , "              initialized; a root mithril generated earlier that still holds"
    , "              nothing else is replaced as a whole; any other nonempty"
    , "              directory is refused unchanged."
    , "  check       Regenerate the expected source bundle in memory and check that"
    , "              WASP_ROOT is exactly that bundle: every managed file"
    , "              byte-identical, nothing missing, nothing else present. Nothing"
    , "              is written."
    , ""
    , "Profiles:"
    , "  Exactly one change-other case selects Profile v0; that case followed by"
    , "  exactly one bounded self-update case selects Profile v1. Every other"
    , "  verified document is UNSUPPORTED here: VERIFIED, but not lowered."
    , ""
    , "Results:"
    , "  GENERATED, CONFINED (exit 0)  WASP_ROOT is exactly the generated source root."
    , "  NOT CONFINED (exit 4)         WASP_ROOT differs from the regenerated bundle,"
    , "                                or generate may not replace it; nothing was"
    , "                                written."
    , "  UNSUPPORTED (exit 3)          CORE_FILE is outside the implemented proof"
    , "                                rules or the two Wasp profiles. Neither a"
    , "                                safety nor a violation verdict."
    , ""
    , "Invalid CORE_FILE or an unusable WASP_ROOT path exits 1. A tool failure"
    , "exits 2 and is never a verdict."
    , ""
    , "The generated root is a closed source artifact, not a general Wasp"
    , "application to edit by hand. Run Wasp tooling only in a disposable copy of"
    , "it: wasp install, wasp start, and migrations add node_modules, .wasp,"
    , "package-lock.json, migrations, and environment files, so that copy becomes"
    , "NOT CONFINED as expected while the clean generated root stays CONFINED."
    , "Regenerate the clean root and refresh the copy whenever CORE_FILE changes."
    , "mithril itself needs Agda 2.8.0 for the verification gate but no Wasp,"
    , "Node, or PostgreSQL installation; running the copy needs the Wasp 0.25.0"
    , "CLI, Node.js 24, and a PostgreSQL database. See README.md for the quickstart."
    ]

-- | Version line for the given package version string.
renderVersion :: String -> String
renderVersion versionString = "mithril " ++ versionString
