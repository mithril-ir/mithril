-- | Pure command-line boundary for the @mithril@ executable.
--
-- Argument interpretation and output rendering live here so they can be
-- tested without I/O.  All effects — reading arguments, writing to
-- handles, choosing the exit status — belong to the executable's
-- @Main@ module.
--
-- The tool understands the self-describing invocations plus two real
-- commands: @validate FILE@, JSON parsing plus structural Core v0
-- validation plus complete name resolution plus complete static
-- typing plus deterministic normalization, and @contract FILE@, the
-- same complete pipeline followed by deterministic rendering of the
-- normalized document as the human-readable security contract.  No
-- later compiler stage exists yet.
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
  deriving (Eq, Show)

-- | Interpret raw command-line arguments.
--
-- Exactly these invocations are accepted: no arguments (help),
-- @--help@, @-h@, @--version@, @validate FILE@, and @contract FILE@.
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
    , "No other compiler stage is implemented yet: no verifier, no"
    , "proof generation or checking, and no target code generation."
    ]

-- | Version line for the given package version string.
renderVersion :: String -> String
renderVersion versionString = "mithril " ++ versionString
