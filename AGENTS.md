# Guidelines for coding agents working on Mithril

This file is operational guidance for AI coding agents (and useful context for humans supervising them). It is repository-specific; follow it over generic defaults.

## What this project is

Mithril is experimental formal-verification infrastructure for authorization and data-access security in AI-generated web backends. Intended flow: natural language → LLM → Mithril Core → formal verification and deterministic Wasp generation.

**Current status: pre-implementation.** The repository contains only documentation and repository configuration. There is no source code, no verifier, no generator, no test suite, and no toolchain.

## Hard rules

1. **No Git or GitHub operations.** Do not commit, branch, merge, rebase, push, tag, or open/modify pull requests, issues, or releases. The human operates version control.
2. **No unrequested scope expansion.** Do exactly what was asked. Do not add source directories, package manifests, CI workflows, architecture documents, templates, or "helpful" extras that were not requested.
3. **No arbitrary escape hatches inside verified policy logic.** Once implementation exists, verified policy logic must never embed arbitrary JavaScript, raw SQL, FFI calls, or other unanalyzable code. Anything the verifier cannot reason about does not belong inside the verified boundary.
4. **No unchecked proof escape hatches for claimed guarantees.** Never use `postulate`, `unsafe`, `assume`, `admit`, `sorry`, or equivalent mechanisms to make a claimed guarantee check. An axiom needed for a documented, reviewed trusted-computing-base assumption is a human decision, not something an agent introduces to make a build pass.
5. **Never hand-edit generated files.** Once code generation exists, generated artifacts are modified only by changing their source and regenerating. If a generated file looks wrong, fix the generator or the input, and say so.
6. **Do not overstate security.** Documentation and code you write must describe TenantIsolation, AuthenticatedMutation, and NoSelfPrivilegeEscalation (and any future properties) as targets until they are actually verified, and must never claim general security.

## Undecided things — do not decide them

- The **implementation language and toolchain are undecided.** Do not select or imply TypeScript, Haskell, Rust, OCaml, or any other language; do not add language-specific configuration, manifests, or scaffolding.
- **Do not invent build, test, lint, or formatting commands.** None exist. If a task seems to require running such a command, report that it does not exist instead of fabricating one.
- **Architecture and source-of-truth boundaries** (what is authored, what is derived, what is trusted) must be documented and agreed before product implementation begins. Do not begin implementing the product ahead of that documentation.

## Reporting

At the end of every task, report:

- **Files changed** — created, modified, or deleted, by path.
- **Decisions made** — anything you chose that the task did not fully specify.
- **Checks run** — what you actually verified and how (and what you could not verify).
- **Unresolved questions** — anything ambiguous, blocked, or deferred to a human.

Report failures and skipped steps plainly. A wrong "done" is worse than an honest "blocked".
