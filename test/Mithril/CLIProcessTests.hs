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
  acmeContract <- readFile acmeContractPath
  welltypedContract <- readFile welltypedContractPath
  matrixChecks <-
    traverse
      expectationChecks
      (expectations <> contractExpectations acmeContract welltypedContract)
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
-- invocation can construct an internal schema, resolver, typechecker,
-- normalizer, or contract-renderer error, so those classifications
-- stay pinned by unit tests over their pure seams.)
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
          "examples/acme/acme.mir.json: valid Mithril Core v0 through normalization\n"
      , cliStderr = ""
      }
  , CliExpectation
      { -- The well-typed full-coverage fixture: every Core v0
        -- constructor family flows through parsing, structural
        -- validation, name resolution, static typing, and
        -- normalization; the (twice-run, byte-identical) success
        -- line pins the complete frontend at the process level.
        cliName = "validate accepts the well-typed coverage fixture through normalization"
      , cliArgs = ["validate", welltypedPath]
      , cliExit = ExitSuccess
      , cliStdout =
          "test/fixtures/welltyped.mir.json: valid Mithril Core v0 through normalization\n"
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
      { -- The deliberately ill-typed (but resolvable) coverage
        -- fixture: rejected by the static-typing stage with exactly
        -- its independent type violations — sorted, deduplicated,
        -- and free of dependent cascades — never as a name problem.
        cliName = "validate rejects the ill-typed coverage fixture at static typing"
      , cliArgs = ["validate", "test/fixtures/coverage.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = coverageTypingStderr
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

-- | The pinned @contract@ invocation matrix, parameterized by the two
-- frozen golden contracts (read from @test\/fixtures\/@ so the
-- process expectation stays independent of the renderer).  A
-- successful contract invocation exits 0 and writes only the complete
-- contract to stdout — no validate success line, nothing on stderr —
-- and every input failure keeps the byte-exact validate diagnostics
-- and classification.  Each expectation runs twice through
-- 'expectationChecks', pinning repetition determinism.
contractExpectations :: String -> String -> [CliExpectation]
contractExpectations acmeContract welltypedContract =
  [ CliExpectation
      { cliName = "contract renders the frozen Acme security contract"
      , cliArgs = ["contract", acmePath]
      , cliExit = ExitSuccess
      , cliStdout = acmeContract
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "contract renders the frozen well-typed coverage contract"
      , cliArgs = ["contract", welltypedPath]
      , cliExit = ExitSuccess
      , cliStdout = welltypedContract
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "contract rejects malformed JSON with the validate bytes"
      , cliArgs = ["contract", "test/fixtures/malformed.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/malformed.mir.json: invalid JSON\n\
          \  Unexpected end-of-input, expecting key literal\n"
      }
  , CliExpectation
      { cliName = "contract rejects the near-Core document with the validate bytes"
      , cliArgs = ["contract", nearCorePath]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = nearCoreStderr
      }
  , CliExpectation
      { cliName = "contract rejects an unresolved name with the validate bytes"
      , cliArgs = ["contract", "test/fixtures/unknown-name.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/unknown-name.mir.json: invalid Mithril Core v0 name resolution\n\
          \  /guarantees/2/authority/payloadOrder: unknown enum \"Ghost\"\n"
      }
  , CliExpectation
      { cliName = "contract rejects the ill-typed coverage fixture with the validate bytes"
      , cliArgs = ["contract", "test/fixtures/coverage.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = coverageTypingStderr
      }
  , CliExpectation
      { cliName = "contract reports a nonexistent input"
      , cliArgs = ["contract", "test/fixtures/does-not-exist.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/does-not-exist.mir.json: cannot read file\n\
          \  does not exist\n"
      }
  , CliExpectation
      { cliName = "contract without FILE is a usage error"
      , cliArgs = ["contract"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: 'contract' requires exactly one FILE argument\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an extra argument after contract FILE is a usage error"
      , cliArgs = ["contract", acmePath, "surplus"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unexpected extra arguments after 'contract FILE': 'surplus'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { -- After 'contract', a dash argument is FILE, never an option:
        -- it is looked up as a path and reported unreadable.
        cliName = "a hostile dash FILE after contract stays a file path"
      , cliArgs = ["contract", "--frobnicate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "--frobnicate: cannot read file\n\
          \  does not exist\n"
      }
  ]

acmePath :: FilePath
acmePath = "examples/acme/acme.mir.json"

acmeContractPath :: FilePath
acmeContractPath = "test/fixtures/acme.contract.txt"

welltypedPath :: FilePath
welltypedPath = "test/fixtures/welltyped.mir.json"

welltypedContractPath :: FilePath
welltypedContractPath = "test/fixtures/welltyped.contract.txt"

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

-- | The exact static-typing rejection of the coverage fixture: every
-- deliberately ill-typed construct it carries — an operand mismatch
-- in each principal-mode family, a lookup arity mismatch (with no
-- cascaded per-endpoint errors), a non-entity Observe term, a
-- missing guarantee scope term, and the doubly incompatible
-- payload-order enum — sorted by path then message, nothing else.
coverageTypingStderr :: String
coverageTypingStderr =
  "test/fixtures/coverage.mir.json: invalid Mithril Core v0 static typing\n\
  \  /actions/0/allow/right/right: the operands of \"Equal\" have incompatible types: Optional Unit and Bool\n\
  \  /actions/6/allow/anonymous/left/right/value/value: relation \"Flagged\" declares 1 endpoint, but 2 endpoint terms are given\n\
  \  /actions/6/allow/anonymous/right: the operands of \"Equal\" have incompatible types: Optional (Enum \"Level\") and Optional Unit\n\
  \  /actions/6/result/entity: an \"Observe\" result must observe an entity reference, but this term has type Bool\n\
  \  /guarantees/2/cases/1: this case names no scope term, but the authority declares the scope endpoint \"organization\"\n\
  \  /guarantees/3/authority/payloadOrder: enum \"Badge\" declares no order, so it cannot rank authority levels\n\
  \  /guarantees/3/authority/payloadOrder: relation \"Flagged\" has a Unit payload, so enum \"Badge\" cannot rank its authority levels\n"

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
                 , "examples/acme/acme.mir.json: valid Mithril Core v0 through normalization\n"
                 , ""
                 )
          )
      , check
          "hostile datadir override: near-Core is still rejected structurally"
          (nearCoreTriple == (ExitFailure 1, "", nearCoreStderr))
      ]
