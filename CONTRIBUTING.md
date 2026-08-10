# Contributing to Mithril

Thanks for your interest in Mithril. Please read this short document before opening an issue or pull request.

## Where the project stands

Mithril is in a **pre-implementation phase**. There is no source code, no chosen implementation language, and no toolchain yet. Because of that:

- There are **no setup, build, test, or formatting commands** to document. Any such commands you find elsewhere are not real. They will be documented here once a toolchain exists.
- The most valuable contributions right now are design discussion, review of the scope and non-guarantees documented in the README, and prior-art references — not code.

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
