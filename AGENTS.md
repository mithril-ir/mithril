# Guidelines for coding agents working on Mithril

Operational guidance for AI coding agents (and useful context for humans
supervising them). It is repository-specific; follow it over generic
defaults.

## What this project is

Mithril is an experimental verification-oriented compiler toolchain for a
small authorization DSL/IR (Mithril Core, authored as JSON). One
deterministic Haskell frontend — parse → structural validation → resolution
→ typecheck → normalization — produces the typed normalized Core that the
contract renderer, the Agda verifier slice, and the confined Wasp emitter
all consume.

**Current supported slice**: the verifier recognizes exactly two structural
NSPE (No Self Privilege Escalation) proof rules — Rule 1 (change-other) and
Rule 2 (bounded-self-update) — and nothing else; the Wasp backend lowers
exactly `[Rule 1]` (Profile v0) and `[Rule 1, Rule 2]` (Profile v1) as
closed 14-file demonstrators. Everything else fails closed as
`UNSUPPORTED`, which is never a safety or violation verdict. The complete
ledger — supported shapes, exit codes, trusted components, non-claims — is
[docs/current-scope.md](docs/current-scope.md); do not restate it here or
in code comments.

## Authoritative documents

1. [`docs/compiler-architecture.md`](docs/compiler-architecture.md) —
   authoritative for the pipeline and artifact ownership (authored vs.
   derived vs. trusted).
2. [`core/schema.json`](core/schema.json) — authoritative for the external
   Core v0 JSON shape.
3. [`docs/current-scope.md`](docs/current-scope.md) — the exact current
   scope and claim boundary.
4. [`docs/how-mithril-works.md`](docs/how-mithril-works.md) — accessible
   background; not normative.

## Hard rules

1. **No Git or GitHub operations.** Do not commit, branch, merge, rebase,
   push, tag, or open/modify pull requests, issues, or releases. The human
   operates version control.
2. **No unrequested scope expansion.** Do exactly what was asked; no
   "helpful" extra directories, workflows, dependencies, or documents.
3. **One frontend, one typed normalized Core.** Contract generation, Agda
   generation, and executable enforcement must all consume the same typed
   normalized Core. Never create or imply an independent per-backend
   interpretation of the JSON.
4. **The LLM boundary is fixed.** An LLM may at most propose the authored
   Mithril JSON. LLM-generated Agda, contracts, normalization, or target
   enforcement code is forbidden — and LLM assistance in *developing this
   repository* never changes that product boundary.
5. **Fail closed.** Unsupported forms are `UNSUPPORTED`, never approximated,
   silently widened, or reported as verdicts. Never weaken the support gate
   to make a document pass.
6. **No unchecked proof escape hatches.** Never use `postulate`, `unsafe`,
   `admit`, `sorry`, or equivalents to make a claimed guarantee check.
   TCB axioms are a human decision. Likewise, verified policy logic must
   never embed arbitrary JavaScript, raw SQL, FFI, or other unanalyzable
   code.
7. **Never hand-edit generated artifacts or goldens.** The generated Agda
   goldens (`test/fixtures/nspe.generated.agda`,
   `test/fixtures/nspe-self-update.generated.agda`), the generated Wasp
   trees (`test/fixtures/wasp-acme`, `test/fixtures/wasp-acme-self-update`),
   and the golden contracts are corrected only by fixing the generator or
   the authored input and regenerating. `node_modules`, `.wasp`,
   `package-lock.json`, migrations, and environment files must never appear
   under the fixtures; Wasp runs only in the integration harness's private
   working directory.
8. **Do not overstate security.** Describe target properties as targets
   until verified; never claim general security; never call `UNSUPPORTED`
   safe, unsafe, or violated; never call a golden or a passing test a
   proof.
9. **Do not invent commands or capabilities.** No lint or formatting
   command exists or has been selected. The canonical build/test commands
   are listed in [CONTRIBUTING.md](CONTRIBUTING.md); the only real checks
   for `agda/` (embedded kernel modules and experiments alike) are in
   [`agda/README.md`](agda/README.md). If a task seems to need a command
   that does not exist, report that instead of fabricating one.
10. **Preserve public API compatibility.** The public library surface and
    its stage discipline are pinned by the compile-fail probes
    (`test/api-probes/`); changing what external code can construct, import,
    or coerce requires an explicit task, and the probes must keep passing.

## Architecture constraints (decided — do not reopen)

- Haskell (GHC 9.12.4, cabal-install 3.18.1.0, GHC2021) is the host-tool
  language; Agda 2.8.0 is the separate checker, reached only through
  generated files and a process boundary — never as a Haskell library.
- The internal representations live in a package-private sublibrary;
  identifier namespaces are distinct non-coercible types; stage indexes
  gate every boundary. Do not add dependencies or select
  packaging/distribution mechanisms without an explicit task.
- **Schema/frontend evolution audit**: any `core/schema.json` change
  touching namespaces, reference-bearing fields, constructors, enum
  order/uniqueness, `User` assumptions, or structural invariants requires
  the mandatory audit of the decoder, representations, resolver,
  typechecker, normalizer, and renderer coverage plus targeted regressions
  in the same change — see
  [the architecture rule](docs/compiler-architecture.md#schema-and-resolver-evolution).
  Recompilation is not the audit.
- **Wasp profile limits are exact**: Profile v0 lowers exactly one Rule-1
  case; Profile v1 exactly the ordered Rule-1, Rule-2 pair; every other
  verified sequence is refused before destination access. Do not
  generalize the profiles, add a profile, or freeze anything beyond them
  in documentation or code. VERIFIED-but-Wasp-UNSUPPORTED is a valid
  outcome.
- Python is not part of the product or CI. Never add Python files, CI
  steps, or documented Python dependencies.

## Comments and documentation

- Comments explain invariants, security boundaries, or non-obvious
  reasons. They must not preserve a chronological debugging diary, and
  must not restate obvious code.
- A historical incident explanation must distinguish what was observed
  from what was inferred.
- Long implementation/state ledgers belong in focused documentation
  ([docs/current-scope.md](docs/current-scope.md),
  [docs/compiler-architecture.md](docs/compiler-architecture.md)), not in
  inline comments.
- Public documentation must separate implemented behavior, evidence,
  trusted assumptions, and future design — and keep limitations next to
  the claims they limit.

## Working discipline

- **Inspect a dirty worktree before starting.** If the worktree carries
  uncommitted changes, understand them and preserve every unrelated one;
  never revert, overwrite, or "clean up" work that is not yours.
- **Validate proportionately.** For Haskell/tool changes, run the
  canonical commands in [CONTRIBUTING.md](CONTRIBUTING.md); for changes
  under `agda/`, run the Agda checks in `agda/README.md` (a change to one
  of the five embedded kernel modules also needs the Haskell test suite);
  the real Wasp/PostgreSQL battery is required only when it is affected
  (generated-bundle or harness changes), not for documentation-only work.
  Verify that goldens and fixtures are unchanged unless the task changes
  them through the generator.

## Reporting

At the end of every task, report:

- **Files changed** — created, modified, or deleted, by path.
- **Decisions made** — anything you chose that the task did not fully
  specify.
- **Checks run** — what you actually verified and how (and what you could
  not verify).
- **Unresolved questions** — anything ambiguous, blocked, or deferred to a
  human.

Report failures and skipped steps plainly. A wrong "done" is worse than an
honest "blocked".
