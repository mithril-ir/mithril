# Guidelines for coding agents working on Mithril

This file is operational guidance for AI coding agents (and useful context for humans supervising them). It is repository-specific; follow it over generic defaults.

## What this project is

Mithril is experimental formal-verification infrastructure for authorization and data-access security in AI-generated web backends. Intended flow: natural-language intent → authored Mithril Core JSON (written by a human, optionally proposed by an untrusted LLM) → one deterministic Haskell frontend → typed normalized Core → human-readable contract, Agda checking, and deterministic Wasp generation. `docs/compiler-architecture.md` is authoritative for this pipeline and for artifact ownership.

**Current status: no compiler stage is implemented.** The repository contains documentation (including the accepted compiler-architecture specification, `docs/compiler-architecture.md`), repository configuration, an experimental Agda semantic spike under `agda/` (see `agda/README.md`) — an exploratory mechanization of candidate kernel semantics that neither selects Agda as the implementation language nor constitutes a product prototype — the Core v0 concrete-syntax checkpoint described below, and a minimal Haskell host-tool scaffold with pinned Haskell CI: Cabal package `mithril-ir`, whose `mithril` CLI prints only help and version output, with base-only unit tests. There is still no parser, validator, resolver, typechecker, normalizer, verifier, or generator.

## Core v0 concrete syntax

- `core/schema.json` (JSON Schema, draft 2020-12) is the source of truth for the current external JSON shape of a Mithril Core v0 document.
- `examples/acme/acme.mir.json` is a handwritten source example. Neither file is generated; both are edited by hand.
- Schema acceptance is structural validation only — required fields, closed constructor sets, principal-mode surface shape, classification/effect/result compatibility. It is not semantic validation and not proof: declaration uniqueness, name resolution, typing, enum-order permutation checks, policy evaluation, and guarantee verification all require the later parser, resolver, typechecker, and normalizer, none of which exists.
- Haskell is the selected implementation language for the deterministic host tool (see `docs/compiler-architecture.md`). A minimal scaffold and Haskell CI now exist, but no parser or frontend stage has been built.
- The Agda spike under `agda/` remains a separate exploration; it does not consume this JSON. It now contains one hand-transcribed application slice — a checked NoSelfPrivilegeEscalation case for `Membership.changeRole` (see `agda/README.md`) — which does not establish the JSON document's guarantees.

## Hard rules

1. **No Git or GitHub operations.** Do not commit, branch, merge, rebase, push, tag, or open/modify pull requests, issues, or releases. The human operates version control.
2. **No unrequested scope expansion.** Do exactly what was asked. Do not add source directories, package manifests, CI workflows, architecture documents, templates, or "helpful" extras that were not requested.
3. **No arbitrary escape hatches inside verified policy logic.** Once implementation exists, verified policy logic must never embed arbitrary JavaScript, raw SQL, FFI calls, or other unanalyzable code. Anything the verifier cannot reason about does not belong inside the verified boundary.
4. **No unchecked proof escape hatches for claimed guarantees.** Never use `postulate`, `unsafe`, `assume`, `admit`, `sorry`, or equivalent mechanisms to make a claimed guarantee check. An axiom needed for a documented, reviewed trusted-computing-base assumption is a human decision, not something an agent introduces to make a build pass.
5. **Never hand-edit generated files.** Once code generation exists, generated artifacts are modified only by changing their source and regenerating. If a generated file looks wrong, fix the generator or the input, and say so.
6. **Do not overstate security.** Documentation and code you write must describe TenantIsolation, AuthenticatedMutation, and NoSelfPrivilegeEscalation (and any future properties) as targets until they are actually verified, and must never claim general security.

## Decided architecture — follow it

The following decisions are made and documented. Do not re-open them, contradict them, or describe them as undecided.

- **Haskell is the selected implementation language** for the deterministic host tool: the CLI, the frontend stages (conceptually `Raw -> Resolved -> Typed -> Normalized`), the contract renderer, and the backend emitters. Agda remains the separate formal backend/checker, reached through generated files and a process boundary — the Haskell decision does not make Haskell the proof backend, and the host tool must not import or depend on Agda compiler internals as a Haskell library.
- **The Haskell bootstrap is minimal, and its configuration is fixed.** GHC 9.12.4, cabal-install 3.18.1.0, and the GHC2021 language edition are the supported bootstrap configuration, and `base` is the only dependency. The canonical commands, run from the repository root, are `cabal check`, `cabal build all --enable-tests`, `cabal test all --test-show-details=direct`, `cabal run mithril -- --help`, and `cabal run mithril -- --version`. Do not add dependencies and do not select packaging or distribution mechanisms without an explicit task; the scaffold implements no compiler stage.
- **`docs/compiler-architecture.md` is authoritative** for the compiler pipeline and for artifact ownership (authored vs. derived vs. trusted). `core/schema.json` remains authoritative for the external Core v0 JSON shape.
- **One frontend, one typed normalized Core.** Contract generation, Agda generation, and executable enforcement must all consume the same typed normalized Core produced by the single frontend. Never create or imply an independent per-backend interpretation of the JSON.
- **No LLM output in the deterministic path.** An LLM may at most propose the authored Mithril JSON. LLM-generated Agda, contracts, normalization, or target enforcement code is forbidden.
- **Generated files are never hand-edited** (hard rule 5) — and, today, nothing is generated: the `Mithril.Acme` proof slice remains hand-transcribed authored Agda, not a derived artifact of `examples/acme/acme.mir.json`.

## Still undecided — do not decide them

- **Do not invent lint or formatting commands.** The Haskell build and test commands listed above are now real, but no lint or formatting command exists or has been selected; if a task seems to require one, report that it does not exist instead of fabricating one. The experimental Agda spike is unchanged: its only real commands are the authoritative checks documented in `agda/README.md` — run exactly those, and only when a task involves the spike.
- **Haskell choices beyond the bootstrap are open.** Dependency selection beyond `base` — including the JSON Schema validator library — and packaging and distribution mechanisms have not been decided; do not select or imply them.
- **Emitter surface details are open.** Exact generated filenames, the generated-artifact metadata/manifest format, and the final target-adapter API are deferred to emitter design; do not freeze them in documentation or code.

## Reporting

At the end of every task, report:

- **Files changed** — created, modified, or deleted, by path.
- **Decisions made** — anything you chose that the task did not fully specify.
- **Checks run** — what you actually verified and how (and what you could not verify).
- **Unresolved questions** — anything ambiguous, blocked, or deferred to a human.

Report failures and skipped steps plainly. A wrong "done" is worse than an honest "blocked".
