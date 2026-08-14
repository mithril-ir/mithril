-- | Process-level regression tests over the real @mithril@
-- executable.
--
-- Every check here spawns the actually-built binary — provided on the
-- test suite's @PATH@ by the Cabal @build-tool-depends@ stanza, never
-- located through hardcoded @dist-newstyle@ paths — and pins the
-- complete observable contract of one invocation: the exit code, the
-- exact stdout bytes, and the exact stderr bytes.  Success output
-- appears only on stdout and failure output only on stderr, which the
-- exact full-string expectations enforce (the opposite stream is
-- pinned empty).  Each invocation runs twice and must be
-- byte-identical, pinning determinism.
--
-- The final group re-runs the review's schema-substitution attack
-- against the real process: with @mithril_ir_datadir@ pointing at a
-- directory containing an in-profile permissive schema, the binary
-- must behave exactly as without the override, because the canonical
-- schema is compiled in.
--
-- The checks assume the test process runs from the package root,
-- which is how @cabal test@ runs it; the fixture inputs live under
-- @test\/fixtures\/@.
module Mithril.CLIProcessTests
  ( tests
  ) where

import Data.List (isPrefixOf)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..)
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
  )

import Mithril.CLI (renderHelp)
import Mithril.Test (Check, check)
import Mithril.TestEnv (datadirVariable, withPermissiveDatadir)

-- | One pinned invocation of the real executable.
data CliExpectation = CliExpectation
  { cliName :: String
  , cliArgs :: [String]
  , cliExit :: ExitCode
  , cliStdout :: String
  , cliStderr :: String
  }

-- | All process-level checks.  If the @mithril@ executable is not on
-- @PATH@ (the tests were started outside @cabal test@), the spawn
-- raises and the harness reports this group as failed with that
-- exception.
tests :: IO [Check]
tests = do
  matrixChecks <- traverse expectationChecks expectations
  helpTriple <- invokeMithril ["--help"]
  overrideChecks <- datadirOverrideChecks
  pure $
    concat matrixChecks
      <> [ -- Belt to the renderHelp-equality braces: the first help
           -- line is also pinned literally, so the process contract
           -- does not rest solely on the library value.
           check
            "--help output begins with the literal header line"
            ( case helpTriple of
                (_, stdoutText, _) ->
                  "mithril - host tool for the Mithril Core IR\n"
                    `isPrefixOf` stdoutText
            )
         ]
      <> overrideChecks

-- | Spawn the real executable with the inherited environment and no
-- stdin, capturing everything it observably does.
invokeMithril :: [String] -> IO (ExitCode, String, String)
invokeMithril arguments = readProcessWithExitCode "mithril" arguments ""

-- | Run one expectation twice: pin exit code, exact stdout bytes,
-- exact stderr bytes, and repetition determinism.
expectationChecks :: CliExpectation -> IO [Check]
expectationChecks expectation = do
  firstRun <- invokeMithril (cliArgs expectation)
  secondRun <- invokeMithril (cliArgs expectation)
  let (exitCode, stdoutText, stderrText) = firstRun
  pure
    [ check
        (cliName expectation ++ ": exit code")
        (exitCode == cliExit expectation)
    , check
        (cliName expectation ++ ": exact stdout bytes")
        (stdoutText == cliStdout expectation)
    , check
        (cliName expectation ++ ": exact stderr bytes")
        (stderrText == cliStderr expectation)
    , check
        (cliName expectation ++ ": repeated invocation is byte-identical")
        (firstRun == secondRun)
    ]

-- | The pinned invocation matrix.  Successful invocations exit 0 and
-- write only to stdout; every user-input failure exits 1 and writes
-- only to stderr.  (The internal-error exit 2 does not appear here:
-- with the schema compiled in and gated at build time, no public
-- invocation can construct an internal schema or resolver error, so
-- that classification stays pinned by unit tests over its pure seam.)
expectations :: [CliExpectation]
expectations =
  [ CliExpectation
      { cliName = "no arguments"
      , cliArgs = []
      , cliExit = ExitSuccess
      , cliStdout = renderHelp
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "--help"
      , cliArgs = ["--help"]
      , cliExit = ExitSuccess
      , cliStdout = renderHelp
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "-h"
      , cliArgs = ["-h"]
      , cliExit = ExitSuccess
      , cliStdout = renderHelp
      , cliStderr = ""
      }
  , CliExpectation
      { -- The literal version line: a version bump must update this
        -- expectation consciously, keeping the released contract
        -- deliberate.
        cliName = "--version"
      , cliArgs = ["--version"]
      , cliExit = ExitSuccess
      , cliStdout = "mithril 0.1.0.0\n"
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "validate accepts the Acme example"
      , cliArgs = ["validate", acmePath]
      , cliExit = ExitSuccess
      , cliStdout =
          "examples/acme/acme.mir.json: valid Mithril Core v0 through name resolution\n"
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "validate rejects malformed JSON"
      , cliArgs = ["validate", "test/fixtures/malformed.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/malformed.mir.json: invalid JSON\n\
          \  Unexpected end-of-input, expecting key literal\n"
      }
  , CliExpectation
      { -- The independent review's near-Core document: rejected for
        -- the missing canonical root requirements, so it can never
        -- reach resolution through the real binary.
        cliName = "validate rejects the near-Core document structurally"
      , cliArgs = ["validate", nearCorePath]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = nearCoreStderr
      }
  , CliExpectation
      { cliName = "validate rejects an unresolved name"
      , cliArgs = ["validate", "test/fixtures/unknown-name.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/unknown-name.mir.json: invalid Mithril Core v0 name resolution\n\
          \  /guarantees/2/authority/payloadOrder: unknown enum \"Ghost\"\n"
      }
  , CliExpectation
      { cliName = "validate reports a nonexistent input"
      , cliArgs = ["validate", "test/fixtures/does-not-exist.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/does-not-exist.mir.json: cannot read file\n\
          \  does not exist\n"
      }
  , CliExpectation
      { cliName = "validate without FILE is a usage error"
      , cliArgs = ["validate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: 'validate' requires exactly one FILE argument\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an unknown argument is a usage error"
      , cliArgs = ["frobnicate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unknown argument 'frobnicate'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an extra argument after --version is a usage error"
      , cliArgs = ["--version", "extra"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unexpected extra arguments after '--version': 'extra'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an extra argument after validate FILE is a usage error"
      , cliArgs = ["validate", acmePath, "surplus"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unexpected extra arguments after 'validate FILE': 'surplus'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "a hostile dash argument is a usage error, not an option"
      , cliArgs = ["--frobnicate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unknown argument '--frobnicate'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { -- After 'validate', a dash argument is FILE, never an option:
        -- it is looked up as a path and reported unreadable.
        cliName = "a hostile dash FILE stays a file path"
      , cliArgs = ["validate", "--frobnicate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "--frobnicate: cannot read file\n\
          \  does not exist\n"
      }
  ]

acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

nearCorePath :: FilePath
nearCorePath = "test/fixtures/near-core.mir.json"

-- | The exact structural rejection of the near-Core fixture: the
-- three missing canonical root requirements, sorted, nothing else.
nearCoreStderr :: String
nearCoreStderr =
  "test/fixtures/near-core.mir.json: invalid Mithril Core v0 structure\n\
  \  /: Missing required property: format\n\
  \  /: Missing required property: formatVersion\n\
  \  /: Missing required property: name\n"

-- | The substitution attack against the real process: a hostile
-- @mithril_ir_datadir@ pointing at an in-profile permissive schema
-- must change nothing — the Acme document still validates, and the
-- near-Core document is still rejected structurally with the same
-- bytes, instead of being minted \"valid\" by the planted grammar.
datadirOverrideChecks :: IO [Check]
datadirOverrideChecks = do
  baseEnvironment <- getEnvironment
  withPermissiveDatadir $ \datadir -> do
    let overriddenEnvironment =
          (datadirVariable, datadir)
            : [entry | entry@(name, _) <- baseEnvironment, name /= datadirVariable]
        invokeOverridden arguments =
          readCreateProcessWithExitCode
            (proc "mithril" arguments) {env = Just overriddenEnvironment}
            ""
    acmeTriple <- invokeOverridden ["validate", acmePath]
    nearCoreTriple <- invokeOverridden ["validate", nearCorePath]
    pure
      [ check
          "hostile datadir override: Acme still validates with exit 0"
          ( acmeTriple
              == ( ExitSuccess
                 , "examples/acme/acme.mir.json: valid Mithril Core v0 through name resolution\n"
                 , ""
                 )
          )
      , check
          "hostile datadir override: near-Core is still rejected structurally"
          (nearCoreTriple == (ExitFailure 1, "", nearCoreStderr))
      ]
