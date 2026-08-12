# Contributing to Mithril

Thanks for your interest in Mithril. Please read this short document before opening an issue or pull request.

## Where the project stands

Mithril is in a **pre-implementation phase**. There is no product source code, no selected implementation language, and no product build, test, lint, or formatting toolchain. Because of that:

- There are **no product setup, build, test, lint, or formatting commands** to document. Any such commands you find elsewhere are not real. They will be documented here once a toolchain exists.
- The one exception is the experimental Agda semantic spike described below, whose checks are real.
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

Major architectural changes — the design of Mithril Core, the verification approach, the choice of implementation language, the code-generation strategy — should be **discussed in an issue before any implementation work begins**. A pull request that lands a large unsolicited design is likely to be closed in favor of a discussion, however good the code is. Small fixes (typos, broken links, clarifications) can go straight to a pull request.

## Conventions

- **Branch names** are lowercase kebab-case with an optional short prefix, for example `feat/core-v0`, `docs/threat-model`, `fix/readme-links`.
- **Commit and PR titles** are concise English in sentence case: an initial capital letter, no final period. For example: `Clarify verifier trust assumptions in README`.
- We do **not** use Conventional Commit prefixes (`feat:`, `fix:`, `chore:`) by default.

## Honesty about security claims

Mithril's credibility depends on never overstating what is verified. Documentation and code comments must not describe target properties as implemented guarantees. When in doubt, say less. See [SECURITY.md](SECURITY.md) and the non-guarantees section of the [README](README.md).

## Code of conduct

All participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
