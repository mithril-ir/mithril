-- | Pure command-line boundary for the @mithril@ executable.
--
-- Argument interpretation and output rendering live here so they can be
-- tested without I/O.  All effects — reading arguments, writing to
-- handles, choosing the exit status — belong to the executable's
-- @Main@ module.
--
-- The bootstrap tool understands only self-describing invocations.
-- No compiler stage exists yet.
module Mithril.CLI
  ( Command (..)
  , parseCommand
  , renderHelp
  , renderVersion
  ) where

-- | A fully interpreted command-line invocation.
data Command
  = -- | Print the help text and exit successfully.
    ShowHelp
  | -- | Print the package version and exit successfully.
    ShowVersion
  deriving (Eq, Show)

-- | Interpret raw command-line arguments.
--
-- No arguments selects 'ShowHelp'.  Anything else that is not exactly
-- one recognized option yields a deterministic error message intended
-- for stderr.
parseCommand :: [String] -> Either String Command
parseCommand [] = Right ShowHelp
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

-- | Deterministic error for an unrecognized argument.
unknownArgumentError :: String -> String
unknownArgumentError argument =
  "mithril: unknown argument '" ++ argument ++ "'\n" ++ usageHint

-- | Deterministic error for arguments after a recognized option.
extraArgumentsError :: String -> [String] -> String
extraArgumentsError argument extras =
  "mithril: unexpected extra arguments after '"
    ++ argument
    ++ "': "
    ++ unwords extras
    ++ "\n"
    ++ usageHint

usageHint :: String
usageHint = "Run 'mithril --help' for usage."

-- | Help text.  Ends with a newline; print with 'putStr'.
renderHelp :: String
renderHelp =
  unlines
    [ "mithril - host-tool bootstrap for the Mithril Core IR"
    , ""
    , "Usage:"
    , "  mithril            Print this help text."
    , "  mithril --help     Print this help text."
    , "  mithril -h         Print this help text."
    , "  mithril --version  Print the package version."
    , ""
    , "Compiler commands are not implemented yet. This bootstrap only"
    , "prints the help and version output described above."
    ]

-- | Version line for the given package version string.
renderVersion :: String -> String
renderVersion versionString = "mithril " ++ versionString
