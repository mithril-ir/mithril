-- | Pure command-line boundary for the @mithril@ executable.
--
-- Argument interpretation and output rendering live here so they can be
-- tested without I/O.  All effects — reading arguments, writing to
-- handles, choosing the exit status — belong to the executable's
-- @Main@ module.
--
-- The tool understands the self-describing invocations plus one real
-- command: @validate FILE@, JSON parsing plus structural Core v0
-- validation plus complete name resolution.  No later compiler stage
-- exists yet.
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
    -- Core v0 schema, and resolve every Core v0 name.
    Validate FilePath
  deriving (Eq, Show)

-- | Interpret raw command-line arguments.
--
-- Exactly these invocations are accepted: no arguments (help),
-- @--help@, @-h@, @--version@, and @validate FILE@.  Anything else —
-- an unknown argument, a missing FILE, or extra arguments after a
-- complete invocation — yields a deterministic error message intended
-- for stderr.  Every user-supplied argument embedded in such a
-- message is rendered through 'displayArgument', so no argument can
-- add physical lines or terminal controls to a diagnostic.
parseCommand :: [String] -> Either String Command
parseCommand [] = Right ShowHelp
parseCommand ("validate" : rest) =
  case rest of
    [file] -> Right (Validate file)
    [] -> Left missingFileError
    (_file : extras) -> Left (extraArgumentsError "validate FILE" extras)
parseCommand (argument : rest) =
  case recognize argument of
    Nothing -> Left (unknownArgumentError argument)
    Just command
      | null rest -> Right command
      | otherwise -> Left (extraArgumentsError argument rest)

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

-- | Deterministic error for @validate@ without its FILE argument.
missingFileError :: String
missingFileError =
  "mithril: 'validate' requires exactly one FILE argument\n" ++ usageHint

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
    , "                         compiled-in Mithril Core v0 schema, and"
    , "                         resolve every Core v0 name."
    , ""
    , "validate performs JSON parsing, structural Core v0 validation"
    , "against the supported profile of core/schema.json (compiled into"
    , "the tool at build time), and complete Core v0 name resolution:"
    , "declaration-name uniqueness in every namespace and resolution"
    , "of every name reference in its namespace. It is"
    , "not semantic verification and not proof checking; it does not"
    , "typecheck, normalize, verify guarantees, or generate anything."
    , "No other compiler stage is implemented yet."
    ]

-- | Version line for the given package version string.
renderVersion :: String -> String
renderVersion versionString = "mithril " ++ versionString
