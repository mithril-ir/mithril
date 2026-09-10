<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/brand/mithril-logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/brand/mithril-logo.svg">
  <img src="docs/assets/brand/mithril-logo.svg" alt="Mithril: pixelated ingot mark and wordmark" width="220" height="48">
</picture>

# Mithril

Mithril is an experimental, narrow prototype for authorization policies. It
is for developers and researchers exploring how one constrained policy source
can drive human review, formal checking, and a small executable demonstration.
It is not a ready-to-install security product or a general authorization
verifier.

Authorization logic is easy for people and coding agents to get subtly wrong.
If the policy a reviewer reads, the model a proof checker checks, and the code
a server runs are written independently, they can encode different rules.
Mithril makes all three derive deterministically from one authored Mithril Core
document, currently represented as JSON.

One frontend parses, validates, resolves, typechecks, and normalizes that
document. The resulting checked internal representation is the sole input to
every downstream generator. This avoids independent backend interpretations
of the JSON. It does not prove that a generated proof model or application has
the same semantics as the Core document; those correspondences remain trusted
boundaries.

> **Status: experimental.** The verifier supports one property with exactly
> two accepted action shapes. Everything outside those shapes is
> `UNSUPPORTED`, which is a support decision, not a safety or violation
> verdict. The complete implementation and claim ledger is
> [docs/current-scope.md](docs/current-scope.md).

## A concrete supported example

The runnable [fixture with two selected NSPE cases](test/fixtures/acme-nspe-self-update.mir.json)
models organization roles ordered as `Member < Admin`:

- Rule 1 lets an actor with the top authority, `Admin`, change another
  existing member's role.
- Rule 2 lets an authenticated actor update their own role only when
  `newRole <= currentRole`.

The selected property is **No Self Privilege Escalation** (NSPE). For these
two actions, a user may demote themselves but cannot use either action to
promote themselves. Mithril calls the two accepted action shapes
*structural proof rules* because the support gate matches their policy and
effect structure exactly. A differently written policy is `UNSUPPORTED` even
if it appears semantically equivalent.

## What the prototype does today

Given Core JSON, the source build can produce three derived surfaces from the
same checked internal representation, called the typed normalized Core:

1. `mithril contract` renders a deterministic text contract for human review.
   Its human-facing presentation is provisional, and the contract is not a
   proof.
2. `mithril verify` generates a document-specific Agda module. For a supported
   document, Agda 2.8.0 checks every selected case of its one selected NSPE
   obligation.
3. `mithril wasp generate` can emit one of two exact, closed 14-file
   [Wasp](https://wasp.sh/) demonstrator profiles when the verified case
   sequence is supported by the emitter. `mithril wasp check` compares a
   source root with the regenerated profile.

`VERIFIED` means exactly that Agda 2.8.0 accepted every required theorem for
every selected case of the document's one selected NSPE obligation. It says
nothing about other guarantees, actions outside the selected cases, including
other actions that can write the role relation but were not selected for the
NSPE obligation, or the security of a complete application. There is no
general proof search, `VIOLATED` verdict, or counterexample engine.

The Wasp demonstrator makes the supported policies executable as authenticated
Actions over PostgreSQL. Profile v0 accepts exactly `[Rule 1]`; Profile v1
accepts exactly `[Rule 1, Rule 2]` in authored order. Every other verified case
sequence is refused before the destination is accessed.
Each generated Action performs its authorization reads and single relation
update in a Prisma transaction at PostgreSQL `Serializable` isolation.
The separate integration battery builds both generated profiles and exercises
their Actions through Wasp's HTTP and authentication path against PostgreSQL.

Both profiles own the complete 14-file source tree. `CONFINED` means that the
root walked by the checker was, at that time, byte-identical to the regenerated
closed profile. The profiles are demonstrators, not a composable Wasp
integration or a runtime sandbox. Code or data can still be changed after the
check, and no whole-runtime or general application-security claim follows.

### Trust and limitations

The relevant trusted computing base includes the Haskell tool, the embedded
Agda kernel and support rules, Agda 2.8.0, and, for the executable slice, Wasp,
Node, Prisma, PostgreSQL, the templates, and the lowering. No theorem currently
proves Core-to-Agda or Core-to-Wasp semantic preservation. See the
[exact trusted components and non-claims](docs/current-scope.md#trusted-components).

## LLM and coding-agent boundary

An optional, untrusted LLM may propose the authored Core JSON. Mithril has no
natural-language interface, and no LLM participates in parsing, normalization,
contract rendering, Agda generation or checking, Wasp generation, or
verification verdicts.

Separately, this repository has been developed with substantial coding-agent
assistance under human-directed architecture, review, and testing. Agent-written
code is reviewed and tested like other code. Passing tests are evidence, not a
proof or a reason to trust the implementation.

## Quickstart

The runnable supported document used here is currently a test fixture. There
is no released binary, installer, container image, Nix setup, or Homebrew
package, so the current path builds and runs the tool from this repository.

Prerequisites:

- GHC 9.12.4
- cabal-install 3.18.1.0
- Agda 2.8.0 on the search path (`verify` and both `wasp` commands invoke it)
- a Linux/POSIX environment

From the repository root:

```sh
cabal run mithril -- validate test/fixtures/acme-nspe-self-update.mir.json
cabal run mithril -- contract test/fixtures/acme-nspe-self-update.mir.json
cabal run mithril -- verify test/fixtures/acme-nspe-self-update.mir.json
mithril_demo_dir=$(mktemp -d /tmp/mithril-demo.XXXXXX)
cabal run mithril -- wasp generate test/fixtures/acme-nspe-self-update.mir.json "$mithril_demo_dir/wasp"
cabal run mithril -- wasp check test/fixtures/acme-nspe-self-update.mir.json "$mithril_demo_dir/wasp"
```

The first invocation builds the tool and can take a few minutes. The commands
should report the fixture as `VERIFIED` and the generated Wasp root as
`CONFINED`. Wasp 0.25.0, Node 24, and PostgreSQL 16 are needed only for the
separate live integration battery, not for these source-tree generation and
comparison commands.

The broader handwritten example,
[`examples/acme/acme.mir.json`](examples/acme/acme.mir.json), validates and
renders a contract but is deliberately `UNSUPPORTED` by `verify`: it selects
additional guarantee families that are not implemented.

## The pipeline in one view

```text
human authorization intent
    |  optional, untrusted human or LLM translation
    v
authored Mithril Core JSON
    |  parse -> structural validation -> resolution -> typecheck -> normalize
    v
typed normalized Core
    |-- text contract for human review
    |-- document-specific Agda module, checked by Agda 2.8.0
    `-- closed Wasp demonstrator, for either exact supported profile
```

Normalization is structural canonicalization, not policy evaluation. It does
not simplify policies or establish that differently authored documents mean
the same thing.

For an accessible explanation of the stages, Agda check, and Wasp boundary,
read [docs/how-mithril-works.md](docs/how-mithril-works.md). The
[compiler architecture](docs/compiler-architecture.md) is authoritative for
the pipeline and artifact ownership.

## Documentation

| Document | Purpose |
|---|---|
| [docs/how-mithril-works.md](docs/how-mithril-works.md) | An introduction for programmers new to formal methods and compiler terminology. |
| [docs/current-scope.md](docs/current-scope.md) | The exact supported slice, result meanings, trusted components, non-claims, and versions. |
| [docs/compiler-architecture.md](docs/compiler-architecture.md) | The normative compiler pipeline and artifact-ownership specification. |
| [agda/README.md](agda/README.md) | The Agda kernel, experiments, and checking commands. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributor workflow and canonical commands. |
| [SECURITY.md](SECURITY.md) | Vulnerability reporting and claim scoping. |
| [AGENTS.md](AGENTS.md) | Repository-specific rules for coding agents. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the current contribution workflow
and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards. Report
security issues according to [SECURITY.md](SECURITY.md).

If Mithril saves you from an authorization bug, feel free to buy us a beer
(preferably a Hacker-Pschorr).

## License

Mithril is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for
the full text.
