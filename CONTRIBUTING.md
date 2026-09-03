# Contributing to Mithril

Thanks for your interest in Mithril. This is the practical entry point for
contributors; read it before opening an issue or pull request.

Mithril is experimental: the frontend, the contract renderer, one narrow
NSPE verifier slice, and two confined Wasp profiles are implemented, and
nothing beyond them. The exact scope, result meanings, and trusted
components live in [docs/current-scope.md](docs/current-scope.md); the
accessible explanation is
[docs/how-mithril-works.md](docs/how-mithril-works.md); the authoritative
pipeline specification is
[docs/compiler-architecture.md](docs/compiler-architecture.md).

The most valuable contributions right now are design discussion, review of
the documented scope and non-guarantees, and prior-art references — not
product code.

## Prerequisites

- GHC 9.12.4 and cabal-install 3.18.1.0 (GHC2021 language edition)
- Agda 2.8.0 on the search path (the test suite and `mithril verify` invoke
  the real executable)
- a POSIX shell on Linux (the documented current workflow)
- only for the separate Wasp integration battery: the Wasp 0.25.0 CLI,
  Node.js 24, and PostgreSQL 16

No lint or formatting command has been selected. Do not invent one; such
tools will be documented here if and when they are chosen.

## Repository layout

| Path | Contents |
|---|---|
| `core/schema.json` | Normative Core v0 JSON grammar (structural authority only). |
| `examples/acme/` | Handwritten human-facing example model. |
| `src/`, `src-internal/`, `app/` | The Haskell host tool (`src-internal/` is the package-private sublibrary). |
| `agda/Mithril/` | The Agda kernel spike; five modules are the embedded trusted kernel. |
| `test/` | Test suite, fixtures and goldens, API-boundary probes, Wasp integration harness. |
| `docs/` | Explanatory, scope, and architecture documentation. |

`examples/` holds authored examples; `test/fixtures/` holds authored
regression inputs plus committed golden outputs. Golden outputs are never
edited by hand — fix the generator or the authored input and regenerate.
Local experiments belong in `/tmp`, a Git-ignored path, or a separate
clone.

## Build and test

The canonical checks, run from the repository root:

```
cabal check
cabal build all --enable-tests
cabal test all --test-show-details=direct
sh test/api-probes/run-api-probes.sh
cabal run mithril -- --help
cabal run mithril -- --version
cabal run mithril -- validate examples/acme/acme.mir.json
cabal run mithril -- contract examples/acme/acme.mir.json
cabal run mithril -- verify test/fixtures/acme-nspe.mir.json
cabal run mithril -- verify test/fixtures/acme-nspe-self-update.mir.json
cabal run mithril -- verify test/fixtures/acme-nspe-dangerous.mir.json
cabal run mithril -- verify examples/acme/acme.mir.json
cabal run mithril -- wasp check test/fixtures/acme-nspe.mir.json test/fixtures/wasp-acme
cabal run mithril -- wasp check test/fixtures/acme-nspe-self-update.mir.json test/fixtures/wasp-acme-self-update
sh test/wasp-integration/test-harness.sh
sh test/api-probes/test-run-api-probes.sh
```

CI runs all of them on every push and pull request; none needs Wasp, Node,
or PostgreSQL. Expected results: the first two `verify` commands exit 0
(`VERIFIED`); the third and fourth deliberately exit 3 (`UNSUPPORTED` — the
dangerous self-promotion mutation and the canonical Acme document lie
outside the support rule, and `UNSUPPORTED` is never a violation verdict);
the two `wasp check` commands report the committed golden fixtures
`CONFINED`. `sh test/wasp-integration/test-harness.sh` runs the integration
harness library's stub-driven self-tests (plus generation smoke tests
needing the built `mithril`, Agda 2.8.0, and Node);
`sh test/api-probes/test-run-api-probes.sh` runs the probe driver's own
isolation self-test. The probe script verifies that every compile-fail
attack on the stage and identifier abstractions still fails for its
intended reason.

The real Wasp 0.25.0 / PostgreSQL vertical battery is deliberately
separate:

```
sh test/wasp-integration/run-wasp-integration.sh
```

It needs the Wasp 0.25.0 CLI, Node.js 24, and PostgreSQL 16 (server
binaries for a private cluster, or `MITHRIL_PG_ADMIN_URL`), has its own
pinned CI workflow (`.github/workflows/wasp.yml`), and installs, compiles,
and builds each freshly generated root in private working directories — so
`node_modules`, `.wasp`, `package-lock.json`, and migrations never enter
the repository. Run it when a change affects the generated bundles, the
emitter, or the harness itself; documentation-only changes do not need it.

### The Agda spike checks

Changes under `agda/` must keep both spike checks passing, each run from
deleted `.agdai` interfaces (see [`agda/README.md`](agda/README.md) for the
spike's boundary):

```
find . -type f -name '*.agdai' -delete
agda --safe -i agda agda/Mithril/Everything.agda

find . -type f -name '*.agdai' -delete
agda --safe --no-libraries --ignore-interfaces -i agda agda/Mithril/Everything.agda
```

Five spike modules (`Base`, `Core`, `Policy`, `Effect`, `Guarantee`) are
also the trusted kernel the host tool embeds for `mithril verify`; changing
them changes the verifier's trusted computing base and must keep both the
spike checks and the Haskell test suite passing.

## When to discuss first

Major architectural changes — the design of Mithril Core, the verification
approach, the code-generation strategy — should be **discussed in an issue
before any implementation work begins**. A pull request landing a large
unsolicited design is likely to be closed in favor of a discussion,
however good the code is. Small fixes (typos, broken links,
clarifications) can go straight to a pull request.

If a `core/schema.json` change affects declaration namespaces,
reference-bearing fields, Core constructors, enum uniqueness/order or
`User` assumptions, or structural invariants used by resolution, typing, or
normalization, follow the
[mandatory schema-and-frontend audit](docs/compiler-architecture.md#schema-and-resolver-evolution)
in the same change. Recompilation is not the audit.

## Security-claim discipline

Mithril's credibility depends on never overstating what is verified.
Documentation and code comments must not describe target properties as
implemented guarantees, must not call `UNSUPPORTED` a safety or violation
verdict, and must not call test evidence or a golden file a proof. When in
doubt, say less. See [SECURITY.md](SECURITY.md) and
[docs/current-scope.md](docs/current-scope.md).

## Generated and golden artifacts

Derived artifacts — the golden contracts, the generated Agda modules
(`test/fixtures/nspe.generated.agda`,
`test/fixtures/nspe-self-update.generated.agda`), and the generated Wasp
trees (`test/fixtures/wasp-acme`, `test/fixtures/wasp-acme-self-update`) —
are regenerated only through the tool and reviewed, never hand-edited. If
a generated file looks wrong, fix the generator or the authored input.

## Pull request expectations

- **Branch names**: lowercase kebab-case with an optional short prefix,
  e.g. `feat/core-v0`, `docs/threat-model`, `fix/readme-links`.
- **Commit and PR titles**: concise English in sentence case (initial
  capital, no final period), e.g.
  `Clarify verifier trust assumptions in README`. No Conventional Commit
  prefixes.
- Run the canonical checks relevant to your change before submitting, and
  say in the PR what you ran.
- Keep goldens and fixtures byte-identical unless your change regenerates
  them through the tool — and then say so explicitly.

## Code of conduct

All participation is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).
