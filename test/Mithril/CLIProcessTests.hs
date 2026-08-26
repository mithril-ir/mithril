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

import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.List (intercalate, isInfixOf, isPrefixOf, sort)
import System.Directory
  ( canonicalizePath
  , createDirectory
  , doesPathExist
  , getPermissions
  , getTemporaryDirectory
  , listDirectory
  , removeDirectory
  , removeDirectoryRecursive
  , removeFile
  , setOwnerExecutable
  , setPermissions
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Posix.Files (fileMode, getSymbolicLinkStatus)
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
      ( expectations
          <> contractExpectations acmeContract welltypedContract
          <> verifyExpectations
          <> waspExpectations
      )
  waspGenerateChecks <- waspProcessChecks
  helpTriple <- invokeMithril ["--help"]
  overrideChecks <- datadirOverrideChecks
  verifierToolFailureChecks <- verifierCheckerOverrideChecks
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
      <> verifierToolFailureChecks
      <> waspGenerateChecks

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

-- | The pinned @verify@ invocation matrix.  The supported
-- single-obligation fixture verifies under the real Agda 2.8.0
-- checker (exit 0, the deterministic report alone on stdout); every
-- unsupported document exits 3 with its deterministic report alone
-- on stdout; every input failure keeps the byte-exact validate
-- diagnostics and classification; and the verify grammar mirrors the
-- validate and contract grammars.  Each expectation runs twice
-- through 'expectationChecks', pinning repetition determinism.
verifyExpectations :: [CliExpectation]
verifyExpectations =
  [ CliExpectation
      { cliName = "verify verifies the supported single-obligation fixture"
      , cliArgs = ["verify", nspePath]
      , cliExit = ExitSuccess
      , cliStdout =
          "test/fixtures/acme-nspe.mir.json: VERIFIED\n\
          \  guarantee: NoSelfPrivilegeEscalation\n\
          \  case action: \"Membership.changeRole\"\n\
          \  checker: Agda 2.8.0 with --safe --no-libraries --ignore-interfaces\n\
          \  theorems: case-scope-is-scope-argument, policy-actor-distinct, actor-authority-unchanged, no-self-escalation\n\
          \  scope: exactly the one selected obligation of this document is verified; nothing else is\n"
      , cliStderr = ""
      }
  , CliExpectation
      { -- The canonical Acme document remains unsupported: its
        -- AuthenticatedMutation and TenantIsolation obligations are
        -- not implemented, and it selects three guarantees.
        cliName = "verify reports the canonical Acme document unsupported with exit 3"
      , cliArgs = ["verify", acmePath]
      , cliExit = ExitFailure 3
      , cliStdout =
          "examples/acme/acme.mir.json: UNSUPPORTED by the implemented verifier support rule\n\
          \  /guarantees: the document selects 3 guarantee obligations, but only a document selecting exactly one NoSelfPrivilegeEscalation obligation is supported\n\
          \  /guarantees/0: the AuthenticatedMutation guarantee family is not supported by the verifier\n\
          \  /guarantees/1: the TenantIsolation guarantee family is not supported by the verifier\n"
      , cliStderr = ""
      }
  , CliExpectation
      { -- The unsafe variant lacking the actor/subject guard is
        -- unsupported — never a proved violation.
        cliName = "verify reports the unsafe variant unsupported, not violated"
      , cliArgs = ["verify", unsafeNspePath]
      , cliExit = ExitFailure 3
      , cliStdout =
          "test/fixtures/acme-nspe-unsafe.mir.json: UNSUPPORTED by the implemented verifier support rule\n\
          \  /actions/4/allow/right: the second operand of the allow policy must itself be the conjunction And(actor/subject guard, subject membership)\n"
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "verify rejects malformed JSON with the validate bytes"
      , cliArgs = ["verify", "test/fixtures/malformed.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/malformed.mir.json: invalid JSON\n\
          \  Unexpected end-of-input, expecting key literal\n"
      }
  , CliExpectation
      { cliName = "verify rejects the near-Core document with the validate bytes"
      , cliArgs = ["verify", nearCorePath]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = nearCoreStderr
      }
  , CliExpectation
      { cliName = "verify rejects an unresolved name with the validate bytes"
      , cliArgs = ["verify", "test/fixtures/unknown-name.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/unknown-name.mir.json: invalid Mithril Core v0 name resolution\n\
          \  /guarantees/2/authority/payloadOrder: unknown enum \"Ghost\"\n"
      }
  , CliExpectation
      { cliName = "verify rejects the ill-typed coverage fixture with the validate bytes"
      , cliArgs = ["verify", "test/fixtures/coverage.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = coverageTypingStderr
      }
  , CliExpectation
      { cliName = "verify reports a nonexistent input"
      , cliArgs = ["verify", "test/fixtures/does-not-exist.mir.json"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/does-not-exist.mir.json: cannot read file\n\
          \  does not exist\n"
      }
  , CliExpectation
      { cliName = "verify without FILE is a usage error"
      , cliArgs = ["verify"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: 'verify' requires exactly one FILE argument\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an extra argument after verify FILE is a usage error"
      , cliArgs = ["verify", nspePath, "surplus"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unexpected extra arguments after 'verify FILE': 'surplus'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { -- After 'verify', a dash argument is FILE, never an option.
        cliName = "a hostile dash FILE after verify stays a file path"
      , cliArgs = ["verify", "--frobnicate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "--frobnicate: cannot read file\n\
          \  does not exist\n"
      }
  ]

nspePath :: FilePath
nspePath = "test/fixtures/acme-nspe.mir.json"

unsafeNspePath :: FilePath
unsafeNspePath = "test/fixtures/acme-nspe-unsafe.mir.json"

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

-- | The checker-substitution failure against the real process: with
-- a fake @agda@ reporting version 2.7.0 shadowing the search path,
-- @mithril verify@ on the supported fixture must exit 2 with the
-- exact escaped tool-failure diagnostic on stderr and nothing on
-- stdout — never a semantic verdict — twice, byte-identically.
-- Additionally, with a fake @agda@ reporting the required version but
-- a hostile, nonexistent TMPDIR, the workspace failure must render
-- the stable anchor-creation diagnostic with no trace of the
-- environment-supplied path — twice, byte-identically.
verifierCheckerOverrideChecks :: IO [Check]
verifierCheckerOverrideChecks = do
  baseEnvironment <- getEnvironment
  temporaryBase <- getTemporaryDirectory
  (anchorPath, handle) <- openTempFile temporaryBase "mithril-fake-agda.txt"
  hClose handle
  let fakeDirectory = anchorPath ++ ".d"
  createDirectory fakeDirectory
  let program = fakeDirectory </> "agda"
  writeFile program
    "#!/bin/sh\n\
    \if [ \"$1\" = \"--version\" ]; then echo \"Agda version 2.7.0\"; exit 0; fi\n\
    \exit 1\n"
  permissions <- getPermissions program
  setPermissions program (setOwnerExecutable True permissions)
  let rightVersionDirectory = anchorPath ++ ".v"
  createDirectory rightVersionDirectory
  let rightVersionProgram = rightVersionDirectory </> "agda"
  writeFile rightVersionProgram
    "#!/bin/sh\n\
    \if [ \"$1\" = \"--version\" ]; then echo \"Agda version 2.8.0\"; exit 0; fi\n\
    \exit 1\n"
  rightVersionPermissions <- getPermissions rightVersionProgram
  setPermissions
    rightVersionProgram
    (setOwnerExecutable True rightVersionPermissions)
  let overriddenEnvironment =
        [ ( name
          , if name == "PATH" then fakeDirectory ++ ":" ++ value else value
          )
        | (name, value) <- baseEnvironment
        ]
      invokeOverridden arguments =
        readCreateProcessWithExitCode
          (proc "mithril" arguments) {env = Just overriddenEnvironment}
          ""
      -- Hostile and never created: spaces and shell-sensitive text.
      hostileTemporary = fakeDirectory </> "missing tempdir $(hostile) chars"
      workspaceEnvironment =
        ("TMPDIR", hostileTemporary)
          : [ ( name
              , if name == "PATH"
                  then rightVersionDirectory ++ ":" ++ value
                  else value
              )
            | (name, value) <- baseEnvironment
            , name /= "TMPDIR"
            ]
      invokeWorkspace arguments =
        readCreateProcessWithExitCode
          (proc "mithril" arguments) {env = Just workspaceEnvironment}
          ""
  firstTriple <- invokeOverridden ["verify", nspePath]
  secondTriple <- invokeOverridden ["verify", nspePath]
  firstWorkspaceTriple <- invokeWorkspace ["verify", nspePath]
  secondWorkspaceTriple <- invokeWorkspace ["verify", nspePath]
  removeDirectoryRecursive rightVersionDirectory
  removeDirectoryRecursive fakeDirectory
  removeFile anchorPath
  pure
    [ check
        "a wrong-version checker fails the verify process with exit 2 and the exact diagnostic"
        ( firstTriple
            == ( ExitFailure 2
               , ""
               , "mithril: internal Core verifier error: the checker is not\
                 \ exactly Agda 2.8.0\n  reported: Agda version 2.7.0\n"
               )
        )
    , check
        "the wrong-version checker failure is byte-identical on repetition"
        (firstTriple == secondTriple)
    , check
        "a hostile nonexistent TMPDIR fails the verify process with the exact path-free diagnostic"
        ( firstWorkspaceTriple
            == ( ExitFailure 2
               , ""
               , "mithril: internal Core verifier error: the isolated checking\
                 \ workspace could not be prepared or cleaned\n\
                 \  creating the workspace anchor failed: does not exist\n"
               )
        )
    , check
        "the hostile TMPDIR value appears nowhere in the process output"
        ( case firstWorkspaceTriple of
            (_, out, err) ->
              not (hostileTemporary `isInfixOf` (out <> err))
        )
    , check
        "the workspace failure is byte-identical on repetition"
        (firstWorkspaceTriple == secondWorkspaceTriple)
    ]

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

-- | The pinned @wasp@ invocation matrix.  The committed fixture is
-- CONFINED against the supported single-obligation document (exit 0,
-- the deterministic report alone on stdout); the canonical Acme
-- document is UNSUPPORTED to the wasp commands with exit 3; input
-- failures keep the byte-exact validate diagnostics and
-- classification; a missing root is an unusable root with exit 1;
-- and the wasp grammar errors mirror the other commands'.  Each
-- expectation runs twice through 'expectationChecks', pinning
-- repetition determinism.
waspExpectations :: [CliExpectation]
waspExpectations =
  [ CliExpectation
      { cliName = "wasp check reports the committed fixture confined"
      , cliArgs = ["wasp", "check", nspePath, waspFixtureRoot]
      , cliExit = ExitSuccess
      , cliStdout = confinedReport waspFixtureRoot "CONFINED" <> "\n"
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "wasp check reports the canonical Acme document unsupported with exit 3"
      , cliArgs = ["wasp", "check", acmePath, waspFixtureRoot]
      , cliExit = ExitFailure 3
      , cliStdout =
          "examples/acme/acme.mir.json: UNSUPPORTED by the implemented Wasp support rule\n\
          \  /guarantees: the document selects 3 guarantee obligations, but only a document selecting exactly one NoSelfPrivilegeEscalation obligation is supported\n\
          \  /guarantees/0: the AuthenticatedMutation guarantee family is not supported by the verifier\n\
          \  /guarantees/1: the TenantIsolation guarantee family is not supported by the verifier\n"
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "wasp generate reports the unsafe variant unsupported with exit 3 and writes nothing"
      , cliArgs = ["wasp", "generate", unsafeNspePath, "test/fixtures/never-created"]
      , cliExit = ExitFailure 3
      , cliStdout =
          "test/fixtures/acme-nspe-unsafe.mir.json: UNSUPPORTED by the implemented Wasp support rule\n\
          \  /actions/4/allow/right: the second operand of the allow policy must itself be the conjunction And(actor/subject guard, subject membership)\n"
      , cliStderr = ""
      }
  , CliExpectation
      { cliName = "wasp check rejects malformed JSON with the validate bytes"
      , cliArgs = ["wasp", "check", "test/fixtures/malformed.mir.json", waspFixtureRoot]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "test/fixtures/malformed.mir.json: invalid JSON\n\
          \  Unexpected end-of-input, expecting key literal\n"
      }
  , CliExpectation
      { cliName = "wasp generate rejects the ill-typed coverage fixture with the validate bytes"
      , cliArgs = ["wasp", "generate", "test/fixtures/coverage.mir.json", "test/fixtures/never-created"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = coverageTypingStderr
      }
  , CliExpectation
      { cliName = "wasp check on a missing root is an unusable root with exit 1"
      , cliArgs = ["wasp", "check", nspePath, "test/fixtures/does-not-exist"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = "test/fixtures/does-not-exist: unusable Wasp root\n  does not exist\n"
      }
  , CliExpectation
      { cliName = "wasp check on a root that is a file is an unusable root with exit 1"
      , cliArgs = ["wasp", "check", nspePath, nspePath]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr = "test/fixtures/acme-nspe.mir.json: unusable Wasp root\n  is not a directory\n"
      }
  , CliExpectation
      { cliName = "wasp without a subcommand is a usage error"
      , cliArgs = ["wasp"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: 'wasp' requires a subcommand: generate or check\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an unknown wasp subcommand is a usage error"
      , cliArgs = ["wasp", "frobnicate"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unknown wasp subcommand 'frobnicate'\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "wasp generate with one argument is a usage error"
      , cliArgs = ["wasp", "generate", nspePath]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: 'wasp generate' requires exactly two arguments: CORE_FILE WASP_ROOT\n\
          \Run 'mithril --help' for usage.\n"
      }
  , CliExpectation
      { cliName = "an extra argument after wasp check CORE_FILE WASP_ROOT is a usage error"
      , cliArgs = ["wasp", "check", nspePath, waspFixtureRoot, "surplus"]
      , cliExit = ExitFailure 1
      , cliStdout = ""
      , cliStderr =
          "mithril: unexpected extra arguments after 'wasp check CORE_FILE WASP_ROOT': 'surplus'\n\
          \Run 'mithril --help' for usage.\n"
      }
  ]

waspFixtureRoot :: FilePath
waspFixtureRoot = "test/fixtures/wasp-acme"

-- | The deterministic report of a confined or generated root: the
-- verdict line, the summary lines, and the closed path inventory.
confinedReport :: FilePath -> String -> String
confinedReport root verdict =
  intercalate
    "\n"
    ( [ root ++ ": " ++ verdict ++ " (Wasp Confinement Profile v0)"
      , "  core: test/fixtures/acme-nspe.mir.json"
      , "  verification: VERIFIED by the production verifier before the bundle was rendered"
      , "  guarantee: NoSelfPrivilegeEscalation"
      , "  case action: \"Membership.changeRole\""
      , "  operation: mithrilCaseAction (POST /operations/mithril-case-action)"
      , "  target: Wasp 0.25.0, PostgreSQL, Prisma runtime supplied by Wasp"
      , "  managed files: 14"
      ]
        <> map ("    " ++) waspInventory
    )

waspInventory :: [String]
waspInventory =
  [ ".gitignore"
  , ".mithril-wasp-profile"
  , ".npmrc"
  , ".wasproot"
  , "main.wasp.ts"
  , "mithril.manifest.json"
  , "package.json"
  , "schema.prisma"
  , "src/MainPage.tsx"
  , "src/mithrilCaseAction.ts"
  , "tsconfig.json"
  , "tsconfig.src.json"
  , "tsconfig.wasp.json"
  , "vite.config.ts"
  ]

-- | The generate path against the real process: a fresh scratch root
-- is generated (exit 0, the GENERATED report with the verification
-- and confinement lines, byte-identical to the committed fixture),
-- checked (exit 0), tampered (the privilege floor of the generated
-- Action lowered) and rejected (exit 4, the exact NOT CONFINED report
-- on stdout, nothing on stderr), regenerated over the tampered owned
-- root (exit 0, the bundle recovered as a whole), a root holding an
-- unmanaged file refuses generation with exit 4 and stays untouched,
-- a root argument with a trailing separator (absolute or relative,
-- generate or check) is an unusable root with exit 1 before anything
-- is created, an occupied backup sibling path refuses generation with
-- exit 1 and touches neither the root nor the occupying entry, a
-- generation under @umask 000@ still installs a root with the private
-- permission bits 0700 (byte-identical and confined), and — with a
-- fake @agda@ ahead on PATH — a verifier tool failure exits 2 and
-- neither creates a root nor replaces an existing one.
waspProcessChecks :: IO [Check]
waspProcessChecks = do
  temporaryBase <- canonicalizePath =<< getTemporaryDirectory
  baseEnvironment <- getEnvironment
  (anchorPath, handle) <- openTempFile temporaryBase "mithril-wasp-process.txt"
  hClose handle
  let scratch = anchorPath ++ ".d"
      root = scratch </> "app"
      collisionRoot = scratch </> "occupied"
      fakeDirectory = scratch </> "fake-agda"
      fakeProgram = fakeDirectory </> "agda"
      neverCreated = scratch </> "never-created"
  createDirectory scratch
  generated <- invokeMithril ["wasp", "generate", nspePath, root]
  generatedAgain <- invokeMithril ["wasp", "generate", nspePath, root]
  checked <- invokeMithril ["wasp", "check", nspePath, root]
  fixtureBytes <- mapM (\path -> ByteString.readFile (waspFixtureRoot </> path)) waspInventory
  generatedBytes <- mapM (\path -> ByteString.readFile (root </> path)) waspInventory
  let operationFile = root </> "src" </> "mithrilCaseAction.ts"
  operation <- ByteString.readFile operationFile
  writeFile operationFile (replaceOnce "const floorRank = 1;" "const floorRank = 0;" (Char8.unpack operation))
  tampered <- invokeMithril ["wasp", "check", nspePath, root]
  recovered <- invokeMithril ["wasp", "generate", nspePath, root]
  recoveredBytes <- mapM (\path -> ByteString.readFile (root </> path)) waspInventory
  createDirectory collisionRoot
  writeFile (collisionRoot </> "notes.txt") "keep\n"
  collision <- invokeMithril ["wasp", "generate", nspePath, collisionRoot]
  collisionEntries <- listDirectory collisionRoot
  trailingGenerate <- invokeMithril ["wasp", "generate", nspePath, neverCreated ++ "/"]
  neverCreatedAfterTrailing <- doesPathExist neverCreated
  trailingCheck <- invokeMithril ["wasp", "check", nspePath, waspFixtureRoot ++ "/"]
  relativeTrailing <- invokeMithril ["wasp", "generate", nspePath, "test/fixtures/never-created/"]
  relativeTrailingExists <- doesPathExist "test/fixtures/never-created"
  let backupSibling = root ++ ".mithril-wasp-backup"
  createDirectory backupSibling
  occupiedBackup <- invokeMithril ["wasp", "generate", nspePath, root]
  occupiedBackupEntries <- listDirectory backupSibling
  afterOccupiedBackup <- mapM (\path -> ByteString.readFile (root </> path)) waspInventory
  removeDirectory backupSibling
  let umaskRoot = scratch </> "umask-app"
  umaskGenerated <-
    readProcessWithExitCode
      "sh"
      ["-c", "umask 000 && exec mithril wasp generate \"$1\" \"$2\"", "sh", nspePath, umaskRoot]
      ""
  umaskBits <- permissionBitsOf umaskRoot
  umaskChecked <- invokeMithril ["wasp", "check", nspePath, umaskRoot]
  umaskBytes <- mapM (\path -> ByteString.readFile (umaskRoot </> path)) waspInventory
  rootBits <- permissionBitsOf root
  createDirectory fakeDirectory
  writeFile fakeProgram
    "#!/bin/sh\n\
    \if [ \"$1\" = \"--version\" ]; then echo \"Agda version 2.7.0\"; exit 0; fi\n\
    \exit 1\n"
  fakePermissions <- getPermissions fakeProgram
  setPermissions fakeProgram (setOwnerExecutable True fakePermissions)
  let fakeEnvironment =
        [ (name, if name == "PATH" then fakeDirectory ++ ":" ++ value else value)
        | (name, value) <- baseEnvironment
        ]
      invokeFake arguments =
        readCreateProcessWithExitCode (proc "mithril" arguments) {env = Just fakeEnvironment} ""
  verifierFailureFresh <- invokeFake ["wasp", "generate", nspePath, neverCreated]
  neverCreatedExists <- doesPathExist neverCreated
  verifierFailureExisting <- invokeFake ["wasp", "generate", nspePath, root]
  afterVerifierFailure <- mapM (\path -> ByteString.readFile (root </> path)) waspInventory
  scratchEntries <- listDirectory scratch
  removeDirectoryRecursive scratch
  removeFile anchorPath
  pure
    [ check
        "wasp generate into a fresh root exits 0 with the GENERATED report"
        ( generated
            == ( ExitSuccess
               , confinedReport root "GENERATED" <> "\n  confinement: CONFINED\n"
               , ""
               )
        )
    , check
        "wasp generate into the managed root again is byte-identical"
        (generatedAgain == generated)
    , check
        "the generated root is byte-identical to the committed fixture"
        (generatedBytes == fixtureBytes)
    , check
        "wasp check of the generated root exits 0 with the CONFINED report"
        (checked == (ExitSuccess, confinedReport root "CONFINED" <> "\n", ""))
    , check
        "a tampered generated Action fails wasp check with exit 4 and the exact report"
        ( tampered
            == ( ExitFailure 4
               , root
                   ++ ": NOT CONFINED (Wasp Confinement Profile v0)\n\
                      \  src/mithrilCaseAction.ts: the generated Action differs from the regenerated bundle (edited generated authorization)\n"
               , ""
               )
        )
    , check
        "wasp generate over the tampered owned root recovers the complete bundle with exit 0"
        (recovered == generated && recoveredBytes == fixtureBytes)
    , check
        "wasp generate refuses an unmarked root holding an unmanaged file with exit 4 and writes nothing"
        ( collision
            == ( ExitFailure 4
               , collisionRoot
                   ++ ": NOT CONFINED (Wasp Confinement Profile v0)\n\
                      \  .mithril-wasp-profile: the root carries no byte-exact Mithril ownership marker, so it is not an owned Wasp Confinement Profile v0 root (an unmarked nonempty root is never replaced)\n\
                      \  notes.txt: an unexpected file is not part of the closed path inventory\n"
               , ""
               )
            && collisionEntries == ["notes.txt"]
        )
    , check
        "a trailing separator on an absolute root is an unusable root with exit 1 and creates nothing"
        ( trailingGenerate == (ExitFailure 1, "", neverCreated ++ "/: unusable Wasp root\n  " ++ emptyComponentReason ++ "\n")
            && not neverCreatedAfterTrailing
        )
    , check
        "a trailing separator on the checked root is an unusable root with exit 1"
        (trailingCheck == (ExitFailure 1, "", waspFixtureRoot ++ "/: unusable Wasp root\n  " ++ emptyComponentReason ++ "\n"))
    , check
        "a trailing separator on a relative root is an unusable root with exit 1 and creates nothing"
        ( relativeTrailing == (ExitFailure 1, "", "test/fixtures/never-created/: unusable Wasp root\n  " ++ emptyComponentReason ++ "\n")
            && not relativeTrailingExists
        )
    , check
        "an occupied backup sibling path refuses generation with exit 1 and touches neither the root nor the entry"
        ( occupiedBackup
            == ( ExitFailure 1
               , ""
               , root
                   ++ ": unusable Wasp root\n  its backup path "
                   ++ backupSibling
                   ++ " already exists (a directory) and is never replaced; move it away first\n"
               )
            && null occupiedBackupEntries
            && afterOccupiedBackup == fixtureBytes
        )
    , check
        "generation under umask 000 installs a private (0700) root that is byte-identical and confined"
        ( umaskGenerated
            == ( ExitSuccess
               , confinedReport umaskRoot "GENERATED" <> "\n  confinement: CONFINED\n"
               , ""
               )
            && umaskBits == 0o700
            && umaskChecked == (ExitSuccess, confinedReport umaskRoot "CONFINED" <> "\n", "")
            && umaskBytes == fixtureBytes
        )
    , check
        "generation under the ambient umask installs a private (0700) root"
        (rootBits == 0o700)
    , check
        "a verifier tool failure exits 2 with the verify diagnostic and creates no root"
        ( verifierFailureFresh
            == ( ExitFailure 2
               , ""
               , "mithril: internal Core verifier error: the checker is not\
                 \ exactly Agda 2.8.0\n  reported: Agda version 2.7.0\n"
               )
            && not neverCreatedExists
        )
    , check
        "a verifier tool failure exits 2 and replaces nothing in an existing owned root"
        ( verifierFailureExisting
            == ( ExitFailure 2
               , ""
               , "mithril: internal Core verifier error: the checker is not\
                 \ exactly Agda 2.8.0\n  reported: Agda version 2.7.0\n"
               )
            && afterVerifierFailure == fixtureBytes
            && sort scratchEntries == ["app", "fake-agda", "occupied", "umask-app"]
        )
    ]
  where
    emptyComponentReason =
      "contains an empty path component (a doubled or trailing separator); pass a path without empty components"
    permissionBitsOf path = do
      metadata <- getSymbolicLinkStatus path
      pure (fileMode metadata .&. 0o777)

-- | Replace the first occurrence of a substring.
replaceOnce :: String -> String -> String -> String
replaceOnce needle replacement haystack =
  case breakOn haystack of
    Just (before, after) -> before ++ replacement ++ after
    Nothing -> haystack
  where
    breakOn text
      | needle `isPrefixOf` text = Just ("", drop (length needle) text)
      | otherwise =
          case text of
            [] -> Nothing
            c : rest -> fmap (\(before, after) -> (c : before, after)) (breakOn rest)
