# Mithril

Mithril is an experimental compiler for authorization policies. It turns a
small JSON DSL into a human-readable contract, a document-specific Agda proof
module, and — for two currently supported NoSelfPrivilegeEscalation profiles —
a confined [Wasp](https://wasp.sh/) application.

The problem it addresses: when a human (or an untrusted LLM on their behalf)
states an access-control policy, the contract a reviewer reads, the model a
proof checker verifies, and the code that executes should all derive
deterministically from the same document — never from independent
interpretations of it.

> **Status: experimental.** Mithril is not a complete verifier, not a general
> web framework, and not a finished security product. The verifier accepts
> exactly two structural proof rules; everything outside them fails closed as
> `UNSUPPORTED`. The exact boundary lives in
> [docs/current-scope.md](docs/current-scope.md).

## What can I do with it?

Today, building from source, you can:

- **Validate** an authorization model authored as Mithril Core JSON through
  the complete deterministic frontend (`mithril validate`).
- **Render a security contract** — a deterministic, human-readable
  restatement of the normalized document for review (`mithril contract`).
  A review artifact, not a proof.
- **Verify one narrow property**: for a document selecting exactly one
  NoSelfPrivilegeEscalation (NSPE) obligation whose cases match the two
  supported structural rules, generate a document-specific Agda module and
  have Agda 2.8.0 check it (`mithril verify`).
- **Generate a demonstrator web application**: lower that same verified
  obligation into a closed 14-file Wasp application, and check
  byte-for-byte that a source tree is exactly that application
  (`mithril wasp generate`, `mithril wasp check`).

What is verified is deliberately narrow: exactly the selected cases of the
one selected obligation of a supported document — nothing else about the
document, and nothing about a whole application beyond the closed
demonstrator's confinement check.

## Quickstart

Prerequisites for the current source build (no prebuilt binaries, installer,
Docker image, Nix setup, or Homebrew package exists yet):

- GHC 9.12.4
- cabal-install 3.18.1.0
- Agda 2.8.0 on the search path (`verify` and the `wasp` commands invoke it)
- a Linux/POSIX environment (the documented current workflow)

Wasp 0.25.0, Node 24, and PostgreSQL 16 are needed only for the full live
generated-app integration path — ordinary `wasp generate`/`wasp check`
source-tree generation and comparison need none of them.

From the repository root (the first invocation builds the tool, which takes a
few minutes):

```sh
cabal run mithril -- contract test/fixtures/acme-nspe-self-update.mir.json
cabal run mithril -- verify test/fixtures/acme-nspe-self-update.mir.json
mithril_demo_dir=$(mktemp -d /tmp/mithril-demo.XXXXXX)
cabal run mithril -- wasp generate test/fixtures/acme-nspe-self-update.mir.json "$mithril_demo_dir/wasp"
cabal run mithril -- wasp check test/fixtures/acme-nspe-self-update.mir.json "$mithril_demo_dir/wasp"
```

The repository uses `cabal run mithril --` because the tool is built and run
in place from source; a future installed binary would be invoked directly as
`mithril verify ...`.

The `contract` command prints the full human-readable contract; its guarantee
section ends like this (abbreviated):

```text
Selected guarantees (unverified proof obligations)
  guarantee NoSelfPrivilegeEscalation (unverified proof obligation)
    authority relation: Membership
    authority subject endpoint: user
    authority scope endpoint: organization
    ...
```

The `verify` command generates the Agda obligation module, has Agda 2.8.0
check it, and reports (abbreviated):

```text
test/fixtures/acme-nspe-self-update.mir.json: VERIFIED
  guarantee: NoSelfPrivilegeEscalation
  cases: 2
  case 0: rule 1 (change-other), action "Membership.changeRole"
  case 1: rule 2 (bounded-self-update), action "Membership.changeOwnRole"
  checker: Agda 2.8.0 with --safe --no-libraries --ignore-interfaces
```

The `wasp generate` command installs the closed application and confirms its
confinement; `wasp check` re-checks it (abbreviated):

```text
/tmp/mithril-demo.XXXXXX/wasp: GENERATED (Wasp Confinement Profile v1)
  verification: VERIFIED by the production verifier before the bundle was rendered
  operations: 2
  managed files: 14
  confinement: CONFINED
```

The quickstart input is currently a test fixture; promoting a verified
document into `examples/` is a recorded follow-up. The canonical broad
example, `examples/acme/acme.mir.json`, validates and renders a contract but
is deliberately reported `UNSUPPORTED` by `verify` — its additional
guarantees are not yet supported.

## How it works

```text
natural-language intent
    │  optional, untrusted human or LLM translation
    ▼
authored Mithril Core JSON
    │  one deterministic frontend:
    │  parse → structural validation → resolution → typecheck → normalize
    ▼
typed normalized Core ──┬──▶ human-readable security contract
                        ├──▶ generated Agda module, checked by Agda 2.8.0
                        └──▶ confined Wasp application (two profiles)
```

Any LLM involvement ends at the authored Core document. Contract rendering,
Agda generation, and Wasp generation all consume the same typed normalized
Core produced by the single frontend; no backend re-interprets the JSON.
Normalization is structural canonicalization only — it evaluates no policy
and claims no equivalence between differently authored documents.

[docs/how-mithril-works.md](docs/how-mithril-works.md) explains every piece
accessibly; [docs/compiler-architecture.md](docs/compiler-architecture.md) is
authoritative for the pipeline and artifact ownership.

## Supported verification slice

NSPE means No Self Privilege Escalation: no principal can use the modeled
operations to raise their own authority. The verifier recognizes exactly two
structural proof rules:

- **Rule 1 — change-other**: an authenticated top-authority actor changes
  *another* user's authority (actor distinct from subject, subject already
  present).
- **Rule 2 — bounded-self-update**: an authenticated actor writes *their own*
  authority tuple, bounded by their pre-state authority (self-demotion, never
  self-promotion).

A supported document selects exactly one NSPE obligation whose every case
matches one of these rules exactly and structurally; semantically equivalent
but differently authored policies are `UNSUPPORTED`, and unsupported forms
fail closed. `UNSUPPORTED` (exit 3) is a support decision, not a safety or
violation verdict — no general `VIOLATED` result or counterexample engine
exists. The supported fixtures are
[`test/fixtures/acme-nspe.mir.json`](test/fixtures/acme-nspe.mir.json) and
[`test/fixtures/acme-nspe-self-update.mir.json`](test/fixtures/acme-nspe-self-update.mir.json);
[`test/fixtures/acme-nspe-dangerous.mir.json`](test/fixtures/acme-nspe-dangerous.mir.json)
is a genuine self-promotion counterexample that is deliberately
`UNSUPPORTED`, exit 3 — not a violation verdict.

The exact rule shapes, result meanings, and exit classification are in
[docs/current-scope.md](docs/current-scope.md).

## Wasp demonstrator

The Wasp commands lower a verified obligation into a closed 14-file
Wasp 0.25.0/PostgreSQL application: Profile v0 accepts exactly `[Rule 1]`,
Profile v1 exactly `[Rule 1, Rule 2]` in authored order, and every other
verified case sequence is refused before any destination access. Every
generated identifier is a fixed role-derived target name, and
`mithril wasp check` rejects missing, altered, and extra files.

The profiles are deliberately closed: the current backend is not composable
with arbitrary manually edited pages or server code, because generating
correct handlers alone cannot establish whole-application security —
manually written server code could bypass them. A future composable adapter
is plausible; it is not implemented.

## Trust and limitations

What this does **not** prove:

- No semantic-preservation theorem proves Core-to-Agda correspondence, and
  none proves Core-to-Wasp correspondence — a generated Wasp bundle is
  trusted correspondence evidence, not a proof.
- `core/schema.json` defines the structural JSON grammar, not semantic
  correctness; the rendered contract is a review artifact, not a proof;
  golden files pin deterministic output and expose drift, they are not
  proofs.
- The Haskell tool, the embedded Agda kernel, the two support rules, the
  Agda 2.8.0 toolchain, and — for the Wasp slice — Wasp, Node, Prisma,
  PostgreSQL, the templates, and the lowering remain trusted.
- Verification never means "secure" in general: vulnerabilities outside the
  verified policy logic, infrastructure and operational security, denial of
  service, side channels, bugs in the trusted computing base, and the gap
  between what a human *meant* and what they *stated* are all out of scope.

Claims are always scoped to explicitly documented properties under
explicitly documented assumptions: see [SECURITY.md](SECURITY.md) and the
[trusted components and non-claims](docs/current-scope.md#trusted-components)
in the scope ledger.

## Documentation

| Document | Purpose |
|---|---|
| [docs/how-mithril-works.md](docs/how-mithril-works.md) | Accessible technical explanation of every piece. |
| [docs/current-scope.md](docs/current-scope.md) | The exact current scope: supported slice, exit codes, trusted components, non-claims, versions. |
| [docs/compiler-architecture.md](docs/compiler-architecture.md) | Authoritative compiler pipeline and artifact-ownership specification. |
| [agda/README.md](agda/README.md) | The Agda kernel spike and its checks. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributor workflow and canonical commands. |
| [SECURITY.md](SECURITY.md) | Vulnerability reporting and claim scoping. |
| [AGENTS.md](AGENTS.md) | Operational rules for coding agents. |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved at this early
stage, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards.
Security reports should follow [SECURITY.md](SECURITY.md).

**Development disclosure.** Mithril has been developed with substantial
coding-agent assistance under human-directed architecture, review, and
testing. That is separate from Mithril's product architecture: in the product
pipeline, an LLM may only propose the authored Core JSON, and the
deterministic contract, proof-module, and Wasp generation do not use an LLM.
Agent-written code is reviewed and tested like any other code; tests passing
is evidence, not a trust argument.

If Mithril saves you from an authorization bug, feel free to buy us a beer
(preferably a Hacker-Pschorr).

## License

Mithril is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for
the full text.
