# Contributing to Mithril

Thanks for your interest in Mithril. Please read this short document before opening an issue or pull request.

## Where the project stands

Mithril's compiler is **not implemented**. On the Haskell side the repository contains the `mithril-ir` Cabal package (GHC 9.12.4, cabal-install 3.18.1.0, GHC2021) whose `mithril` CLI prints help and version output and implements one deterministic frontend boundary: `mithril validate FILE`, JSON parsing plus structural Core v0 validation against the bundled `core/schema.json` (JSON parsing via `aeson`; validation via the exactly pinned, provisional `jsonschema 0.3.0.1` behind an explicit schema-profile gate), together with unit tests for those boundaries and pinned Haskell CI. Structural validation establishes JSON shape only. No resolver, Mithril typechecker, normalizer, verifier, or generator exists yet; see [`docs/compiler-architecture.md`](docs/compiler-architecture.md).

The canonical Haskell checks, run from the repository root:

```
cabal check
cabal build all --enable-tests
cabal test all --test-show-details=direct
cabal run mithril -- --help
cabal run mithril -- --version
cabal run mithril -- validate examples/acme/acme.mir.json
```

CI runs all of them on every push and pull request. Run them locally before submitting a change that touches the Haskell tool, `core/schema.json`, or `examples/acme/acme.mir.json`; the final command must keep reporting the Acme example as structurally valid.

Two operational caveats of the current validator — known gaps, not contracts: duplicate JSON object members are accepted under Aeson's member semantics rather than rejected (no particular occurrence is contractually the winner), and no independent input-size, nesting, memory, or execution-resource limits exist yet. Do not describe `mithril validate` as hardened validation for arbitrary untrusted, unbounded input. Neither caveat affects the narrower claim that the unchanged Acme example structurally validates.

- **No lint or formatting command has been selected.** Do not invent one — any Haskell lint or format command you find elsewhere is not real. Such tools will be documented here if and when they are chosen.
- The experimental Agda semantic spike described below stays separate from the Haskell scaffold; its checks are real and remain required whenever files under `agda/` change.
- The most valuable contributions right now are design discussion, review of the scope and non-guarantees documented in the README, and prior-art references — not product code.

### The experimental Agda semantic spike

The repository does contain an experimental Agda mechanization of candidate kernel semantics under `agda/`. It is an exploratory spike, not a product prototype, and it does not select Agda as the implementation language.

It requires **exactly Agda 2.8.0** and uses Agda builtins only (no standard library and no other external library). Its only application-level result is one checked, hand-transcribed, fixed-schema proof slice (see [`agda/README.md`](agda/README.md)): the Acme example's `Membership.changeRole` action satisfies its selected NoSelfPrivilegeEscalation case, with checked negative evidence that an unsafe self-promotion variant violates the same proposition. Everything else remains unverified: there is no automated JSON-to-Agda connection, neither `examples/acme/acme.mir.json` nor the complete Acme model is verified, no other action or guarantee family (TenantIsolation, AuthenticatedMutation) is proved, and the slice is an experiment, not a product verifier.

Its two authoritative checks are real commands. Run both from the repository root, and run each from deleted `.agdai` interfaces so that neither check can succeed through interfaces produced by the other:

```
find . -type f -name '*.agdai' -delete
agda --safe -i agda agda/Mithril/Everything.agda

find . -type f -name '*.agdai' -delete
agda --safe --no-libraries --ignore-interfaces -i agda agda/Mithril/Everything.agda
```

[`agda/README.md`](agda/README.md) is the detailed source for the spike's boundary and these commands. Changes touching `agda/` must keep both checks passing.

## Discuss before building

Major architectural changes — the design of Mithril Core, the verification approach, the code-generation strategy — should be **discussed in an issue before any implementation work begins**. A pull request that lands a large unsolicited design is likely to be closed in favor of a discussion, however good the code is. Small fixes (typos, broken links, clarifications) can go straight to a pull request.

## Conventions

- **Branch names** are lowercase kebab-case with an optional short prefix, for example `feat/core-v0`, `docs/threat-model`, `fix/readme-links`.
- **Commit and PR titles** are concise English in sentence case: an initial capital letter, no final period. For example: `Clarify verifier trust assumptions in README`.
- We do **not** use Conventional Commit prefixes (`feat:`, `fix:`, `chore:`) by default.

## Honesty about security claims

Mithril's credibility depends on never overstating what is verified. Documentation and code comments must not describe target properties as implemented guarantees. When in doubt, say less. See [SECURITY.md](SECURITY.md) and the non-guarantees section of the [README](README.md).

## Code of conduct

All participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
