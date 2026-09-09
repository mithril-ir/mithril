-- | Pure command-line boundary for the @mithril@ executable.
--
-- Argument interpretation and output rendering live here so they can be
-- tested without I/O.  All effects — reading arguments, writing to
-- handles, choosing the exit status — belong to the executable's
-- @Main@ module.
--
-- The tool understands the self-describing invocations plus the five
-- commands of 'Command': @validate FILE@, @contract FILE@,
-- @verify FILE@, @wasp generate CORE_FILE WASP_ROOT@, and
-- @wasp check CORE_FILE WASP_ROOT@.  What each command establishes is
-- stated by its command module; see @docs\/current-scope.md@ for the
-- supported slice, result meanings, trusted components, and explicit
-- non-claims.
module Mithril.CLI
  ( Command (..)
  , parseCommand
  , displayArgument
  , renderHelp
  , renderVersion
  ) where

import Data.Char (isPrint)

-- | A fully interpreted command-line invocation.
data Command
  = -- | Print the help text and exit successfully.
    ShowHelp
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
-- @verify FILE@, @wasp generate CORE_FILE WASP_ROOT@, and @wasp check
-- CORE_FILE WASP_ROOT@.
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
      | otherwise -> Left (extraArgumentsError argument rest)

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
      Left (extraArgumentsError (commandName ++ " FILE") extras)

-- | Interpret the argument list after the @wasp@ command name: a
-- subcommand, @generate@ or @check@, followed by exactly CORE_FILE
-- and WASP_ROOT.  Neither argument is ever an option, and anything
-- after the two is rejected.
waspCommand :: [String] -> Either String Command
waspCommand rest =
  case rest of
    [] -> Left missingWaspSubcommandError
    ("generate" : more) -> twoArguments "wasp generate" WaspGenerate more
    ("check" : more) -> twoArguments "wasp check" WaspCheck more
    (subcommand : _) -> Left (unknownWaspSubcommandError subcommand)

twoArguments
  :: String -> (FilePath -> FilePath -> Command) -> [String] -> Either String Command
twoArguments commandName construct arguments =
  case arguments of
    [coreFile, root] -> Right (construct coreFile root)
    (_coreFile : _root : extras) ->
      Left (extraArgumentsError (commandName ++ " CORE_FILE WASP_ROOT") extras)
    _ -> Left (missingWaspArgumentsError commandName)

-- | Map a single recognized option to its command.
recognize :: String -> Maybe Command
recognize "--help" = Just ShowHelp
recognize "-h" = Just ShowHelp
recognize "--version" = Just ShowVersion
recognize _ = Nothing

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

-- | Deterministic error for arguments after a complete invocation.
extraArgumentsError :: String -> [String] -> String
extraArgumentsError argument extras =
  "mithril: unexpected extra arguments after "
    ++ displayArgument argument
    ++ ": "
    ++ unwords (map displayArgument extras)
    ++ "\n"
    ++ usageHint

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
  "mithril: 'wasp' requires a subcommand: generate or check\n" ++ usageHint

-- | Deterministic error for an unrecognized @wasp@ subcommand.
unknownWaspSubcommandError :: String -> String
unknownWaspSubcommandError subcommand =
  "mithril: unknown wasp subcommand " ++ displayArgument subcommand ++ "\n" ++ usageHint

-- | Deterministic error for a @wasp@ subcommand without exactly its
-- two arguments.
missingWaspArgumentsError :: String -> String
missingWaspArgumentsError commandName =
  "mithril: '"
    ++ commandName
    ++ "' requires exactly two arguments: CORE_FILE WASP_ROOT\n"
    ++ usageHint

usageHint :: String
usageHint = "Run 'mithril --help' for usage."

-- | Help text.  Ends with a newline; print with 'putStr'.
renderHelp :: String
renderHelp =
  unlines
    [ "mithril - host tool for the Mithril Core IR"
    , ""
    , "Usage:"
    , "  mithril                Print this help text."
    , "  mithril --help         Print this help text."
    , "  mithril -h             Print this help text."
    , "  mithril --version      Print the package version."
    , "  mithril validate FILE  Parse FILE as JSON, check it against the"
    , "                         compiled-in Mithril Core v0 schema,"
    , "                         resolve every Core v0 name, typecheck the"
    , "                         resolved document, and normalize the"
    , "                         typed document."
    , "  mithril contract FILE  Run the complete validate pipeline on"
    , "                         FILE, then print the deterministic"
    , "                         human-readable security contract of the"
    , "                         normalized document to stdout."
    , "  mithril verify FILE    Run the complete validate pipeline on"
    , "                         FILE, then verify the normalized document"
    , "                         against the one implemented support rule:"
    , "                         a single selected NoSelfPrivilegeEscalation"
    , "                         obligation whose every case matches one of"
    , "                         the two exact structural proof rules"
    , "                         (change-other, bounded self-update),"
    , "                         checked by Agda 2.8.0."
    , "  mithril wasp generate CORE_FILE WASP_ROOT"
    , "                         Run the complete validate pipeline and the"
    , "                         verify gate on CORE_FILE (VERIFIED required),"
    , "                         then install the closed Wasp 0.25.0 application"
    , "                         of that document as a complete root at WASP_ROOT"
    , "                         (initialized when absent or empty, replaced as a"
    , "                         whole when owned) and check its confinement."
    , "  mithril wasp check CORE_FILE WASP_ROOT"
    , "                         Regenerate the same bundle without writing and"
    , "                         check that WASP_ROOT is exactly the closed"
    , "                         profile: every managed file byte-identical,"
    , "                         nothing else present."
    , ""
    , "validate performs JSON parsing, structural Core v0 validation"
    , "against the supported profile of core/schema.json (compiled into"
    , "the tool at build time), complete Core v0 name resolution:"
    , "declaration-name uniqueness in every namespace and resolution"
    , "of every name reference in its namespace, complete Core v0"
    , "static typing of the resolved document: term, policy, effect and"
    , "result types, operand and relation-endpoint compatibility,"
    , "enum-order permutation validity, initializer completeness, and"
    , "guarantee well-typedness, and deterministic normalization of the"
    , "well-typed document into the internal typed normalized Core. It is"
    , "not semantic verification and not proof checking; normalization"
    , "is structural only (no boolean simplification, constant folding,"
    , "or policy evaluation), and validate does not verify guarantees"
    , "or generate anything."
    , "contract renders the typed normalized Core of a document that"
    , "passes that complete pipeline as a deterministic, line-oriented"
    , "security contract for human review: the declared schema, every"
    , "action's policies, effects and results, and the selected"
    , "guarantees, which remain unverified proof obligations. It"
    , "evaluates no policy, proves and verifies nothing, generates"
    , "nothing executable, and is not a semantic diff."
    , "verify implements exactly one proof slice: a document selecting"
    , "exactly one NoSelfPrivilegeEscalation obligation, every case of"
    , "which matches exactly one of two exact structural rules - the"
    , "mechanized safe changeRole change-other rule (three parameters:"
    , "subject, scope, payload) or the bounded self-update rule (two"
    , "parameters: scope, payload; the actor's own tuple written to a"
    , "payload bounded by its authority) - is checked by generating a"
    , "deterministic Agda module with one proof group per case against"
    , "the embedded trusted kernel and running exactly Agda 2.8.0 with"
    , "--safe --no-libraries --ignore-interfaces (exit 0, VERIFIED, for"
    , "exactly the selected cases of that one obligation)."
    , "Everything else is UNSUPPORTED (exit 3) - including the canonical"
    , "Acme example, whose TenantIsolation and AuthenticatedMutation"
    , "obligations remain unverified, documents selecting no or several"
    , "guarantees, cases matching neither rule, and semantically"
    , "equivalent but differently authored shapes."
    , "verify never reports a violation: an unsafe variant is"
    , "unsupported, not a proved violation, and a checker problem is a"
    , "tool failure (exit 2), never a semantic verdict. The generator,"
    , "the embedded Agda kernel, the Agda toolchain, and the support"
    , "rules themselves remain trusted components."
    , "wasp generate and wasp check implement the Wasp Confinement Profiles for"
    , "the verified NoSelfPrivilegeEscalation slice, which both require to be"
    , "VERIFIED first: Profile v0 lowers exactly the singleton change-other"
    , "(rule-1) case as one authenticated Action, and Profile v1 lowers exactly"
    , "the ordered change-other, bounded self-update (rule-1, rule-2) case pair"
    , "as two authenticated Actions exported by the one generated operation"
    , "file over the same fourteen managed paths; arbitrary multi-case lowering"
    , "is not implemented, so a verified document with any other case sequence"
    , "(a singleton bounded self-update case, two rule-1 cases, the reversed"
    , "pair, three or more cases) is refused by the profile dispatcher (exit 3)"
    , "before any destination access - VERIFIED but Wasp-UNSUPPORTED is a valid"
    , "outcome. Each profile is a normal Wasp 0.25.0 application on"
    , "PostgreSQL whose specification, Prisma schema, dependency configuration,"
    , "generated Actions, client shell, ownership marker, and manifest are"
    , "managed inputs regenerated from the same typed normalized Core the"
    , "verifier consumed, with fixed target names (never authored names) for"
    , "every identifier, file, and route. check walks the source root without"
    , "following symbolic links, rejects hard links, and rejects every missing,"
    , "altered, or unexpected input (exit 4); generate stages the complete"
    , "bundle beside the root, checks it, swaps it into place as a whole"
    , "(an owned root of either profile transitions to the requested one),"
    , "refuses an unmarked nonempty root or an unmanaged path without mutation"
    , "(exit 4), refuses root paths with dot, empty, or trailing-separator"
    , "components, linked ancestors, a linked root, or an existing backup"
    , "sibling (exit 1), creates the root private (mode 0700 whatever the"
    , "umask), and finishes with the same check."
    , "A document outside the support rule is UNSUPPORTED (exit 3). Wasp, Node,"
    , "Prisma, PostgreSQL, the templates, and the lowering remain trusted; no"
    , "semantic-preservation theorem exists (a rendered bundle is trusted"
    , "correspondence evidence, not a proof); the confinement claim covers the"
    , "source snapshot at the time of checking, not concurrent same-user"
    , "mutation after it, privileged users, checker or CI compromise,"
    , "dependency compromise, external database credential holders, or"
    , "tampering after the Wasp build; this is not a general Wasp backend, a"
    , "whole-product generator, a complete verifier, or a runtime sandbox."
    , "No other compiler stage is implemented: no complete verifier, no"
    , "semantic diff, and no target generation beyond these two profiles."
    ]

-- | Version line for the given package version string.
renderVersion :: String -> String
renderVersion versionString = "mithril " ++ versionString
