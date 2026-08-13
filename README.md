# Mithril

> **Status: experimental; the compiler is not implemented.** This repository currently contains documentation — including the accepted compiler-architecture specification, [`docs/compiler-architecture.md`](docs/compiler-architecture.md) — an experimental Agda semantic spike (`agda/`), the first Mithril Core v0 concrete-syntax checkpoint: a normative JSON Schema plus one handwritten example model, and a minimal Haskell host-tool scaffold with pinned Haskell CI. The scaffold's `mithril` CLI supports only help and version output; no parser, validator, resolver, typechecker, normalizer, verifier, or generator exists yet. The spike now includes one hand-transcribed application experiment — a NoSelfPrivilegeEscalation proof for a single Acme action inside the fixed-schema Agda kernel ([`agda/README.md`](agda/README.md)) — but no automated verifier or JSON-to-Agda connection exists, and the JSON document itself and everything else described below remain unverified.

Mithril is experimental formal-verification infrastructure for **authorization and data-access security in AI-generated web backends**. That is its entire initial scope: it is not a general-purpose verification framework, not a web framework, and not a security product.

## The idea

Humans describe access-control intent in natural language, and that intent is captured in **Mithril Core**, a small, explicit intermediate representation authored as a JSON document. A human may write the JSON directly; an untrusted LLM may optionally propose it. Everything downstream derives from the authored document deterministically, through a single frontend and one shared typed normalized Core:

```
natural-language intent
    │  optional, untrusted human or LLM translation
    ▼
authored Mithril Core JSON
    │  one deterministic frontend (planned Haskell host tool):
    │  parse → validate → resolve → typecheck → normalize
    ▼
typed normalized Core ──┬──▶ human-readable security contract
                        ├──▶ Agda checking of stated properties
                        └──▶ deterministic generation of Wasp code
```

The key design commitment is that any LLM involvement ends at the authored Core document, and that contract rendering, Agda verification, and target code generation all consume the same typed normalized Core rather than interpreting the JSON independently. Everything downstream of the authored document is intended to be deterministic and auditable, so that what gets checked is exactly what gets executed. Haskell has been selected as the implementation language for this future deterministic host tool; today only a minimal CLI scaffold exists (help and version output), and none of the pipeline stages is implemented. [Wasp](https://wasp.sh/) is the first planned executable target. [`docs/compiler-architecture.md`](docs/compiler-architecture.md) is authoritative for the pipeline and its artifact-ownership boundaries.

## Current status vs. intended functionality

| Status | Description |
|---|---|
| **Exists today** | This documentation, the accepted compiler-architecture specification ([`docs/compiler-architecture.md`](docs/compiler-architecture.md)), contribution and security policies, agent guidelines, an experimental Agda semantic spike under `agda/` (including one hand-transcribed application slice: a checked NoSelfPrivilegeEscalation proof for the Acme `Membership.changeRole` action, see [`agda/README.md`](agda/README.md)), the Core v0 concrete-syntax checkpoint: [`core/schema.json`](core/schema.json) with the handwritten [`examples/acme/acme.mir.json`](examples/acme/acme.mir.json), and a minimal Haskell host-tool scaffold with pinned Haskell CI: Cabal package `mithril-ir` building the `mithril` CLI (help and version output only) with base-only unit tests (GHC 9.12.4, cabal-install 3.18.1.0). |
| **Does not exist yet** | Everything beyond Core's concrete JSON syntax: the parser, structural validator, resolver, typechecker, normalizer, verifier, contract renderer, Wasp generator, and the optional LLM authoring aid (untrusted; it may propose Mithril Core JSON but remains outside the deterministic and trusted compiler pipeline). The Haskell scaffold implements none of these: its CLI supports only help and version output, and its unit tests cover only that CLI boundary. |

### Canonical Haskell commands

The scaffold's authoritative build and test commands, run from the repository root:

```
cabal check
cabal build all --enable-tests
cabal test all --test-show-details=direct
cabal run mithril -- --help
cabal run mithril -- --version
```

## Core v0 syntax checkpoint

[`core/schema.json`](core/schema.json) is the first normative concrete-syntax checkpoint for generic Mithril Core v0: a JSON Schema (draft 2020-12) that freezes the external JSON shape of a Core document — schema declarations, term constructors, effects, results, principal modes, and guarantee selections.

It validates JSON shape only. Schema acceptance establishes structural facts (required fields, closed constructor sets, principal-mode surface shape, action classification/effect/result compatibility, and the structural exclusion of direct `Actor` syntax from anonymous policy branches and from `AnyPrincipal` effects and results). It establishes no name resolution, no uniqueness, no typing, no enum-order correctness, no policy evaluation, and no security property.

[`examples/acme/acme.mir.json`](examples/acme/acme.mir.json) is a handwritten example model. It is neither generated nor verified. The three guarantee objects it selects — TenantIsolation, AuthenticatedMutation, and NoSelfPrivilegeEscalation — remain unverified for this document; their appearance in the JSON selects proof obligations and proves nothing. Separately, the Agda spike hand-transcribes the `Membership.changeRole` action and proves its selected NoSelfPrivilegeEscalation case inside the fixed-schema kernel ([`agda/README.md`](agda/README.md)); no tool connects that proof to this JSON document.

No parser, resolver, typechecker, normalizer, verifier, or Wasp generator exists yet; the Haskell scaffold's CLI prints only help and version output. Those deferred semantic stages belong to the planned single Haskell frontend, which will produce the one typed normalized Core consumed by contract rendering, Agda checking, and target generation alike ([`docs/compiler-architecture.md`](docs/compiler-architecture.md)). Conformance of an instance to the schema can be checked with any standard JSON Schema draft 2020-12 validator. The separate Agda spike under `agda/` explores candidate kernel semantics; it does not consume this JSON, and its single hand-transcribed application proof does not verify this document.

## Target properties (not implemented guarantees)

The following are properties Mithril **aims to verify in the future**. No product implementation of them exists, and none of them is guaranteed for any real application:

- **TenantIsolation** — a request executing on behalf of one tenant cannot read or write another tenant's data through generated data-access paths.
- **AuthenticatedMutation** — no generated mutation endpoint is reachable without an authenticated principal.
- **NoSelfPrivilegeEscalation** — no principal can use generated endpoints to raise their own privileges.

The only formal artifact so far is the Agda spike's hand-transcribed, fixed-schema experiment ([`agda/README.md`](agda/README.md)): one NoSelfPrivilegeEscalation action/property slice — the Acme `Membership.changeRole` action — is proved inside the kernel, with a checked counterexample for an unsafe variant. It covers nothing else: not the complete Acme model, not the JSON document, and not the other two properties. No automated verifier or JSON-to-Agda connection exists yet.

## What Mithril will not guarantee

Even once implemented, Mithril will not make an application "secure" in any general sense, and it will never be reasonable to describe a Mithril-verified backend as unhackable. In particular, Mithril does not and will not address:

- vulnerabilities in code outside the verified policy logic (frontends, custom handlers, third-party dependencies);
- infrastructure, deployment, and operational security (TLS configuration, secret management, database hardening);
- denial of service, side channels, and timing attacks;
- bugs in the trusted computing base: the verifier itself, the code generator, the target framework, and the runtime beneath them;
- the gap between what a human *meant* and what they *stated* — the LLM translation step is explicitly untrusted, and a faithful verification of the wrong intent is still the wrong policy.

Future verification claims will always be scoped to explicitly documented properties under explicitly documented assumptions, as described in [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved at this early stage, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards. Security reports should follow [SECURITY.md](SECURITY.md).

If Mithril saves you from an authorization bug, feel free to buy us a beer (preferably a Hacker-Pschorr).

## License

Mithril is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
