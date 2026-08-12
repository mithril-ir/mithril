# Mithril

> **Status: experimental, pre-implementation.** This repository currently contains documentation, an experimental Agda semantic spike (`agda/`), and the first Mithril Core v0 concrete-syntax checkpoint: a normative JSON Schema plus one handwritten example model. There is no parser, verifier, or code generator yet, and nothing described below is verified.

Mithril is experimental formal-verification infrastructure for **authorization and data-access security in AI-generated web backends**. That is its entire initial scope: it is not a general-purpose verification framework, not a web framework, and not a security product.

## The idea

Humans describe access-control intent in natural language. An LLM translates that intent into **Mithril Core**, a small, explicit intermediate representation. Everything downstream derives from Core deterministically:

```
natural language ──▶ LLM ──▶ Mithril Core ──┬──▶ formal verification of stated properties
                                            └──▶ deterministic generation of Wasp code
```

The key design commitment is that the LLM's role ends at Core. Verification and code generation are intended to be deterministic and auditable, so that what gets checked is exactly what gets executed. [Wasp](https://wasp.sh/) is the first planned executable target.

## Current status vs. intended functionality

| Status | Description |
|---|---|
| **Exists today** | This documentation, contribution and security policies, agent guidelines, an experimental Agda semantic spike under `agda/`, and the Core v0 concrete-syntax checkpoint: [`core/schema.json`](core/schema.json) with the handwritten [`examples/acme/acme.mir.json`](examples/acme/acme.mir.json). |
| **Does not exist yet** | Everything beyond Core's concrete JSON syntax: the parser, resolver, typechecker, normalizer, verifier, Wasp generator, LLM translation layer, any test suite, and any product toolchain. The implementation language has not been selected. |

## Core v0 syntax checkpoint

[`core/schema.json`](core/schema.json) is the first normative concrete-syntax checkpoint for generic Mithril Core v0: a JSON Schema (draft 2020-12) that freezes the external JSON shape of a Core document — schema declarations, term constructors, effects, results, principal modes, and guarantee selections.

It validates JSON shape only. Schema acceptance establishes structural facts (required fields, closed constructor sets, principal-mode surface shape, action classification/effect/result compatibility, and the structural exclusion of direct `Actor` syntax from anonymous policy branches and from `AnyPrincipal` effects and results). It establishes no name resolution, no uniqueness, no typing, no enum-order correctness, no policy evaluation, and no security property.

[`examples/acme/acme.mir.json`](examples/acme/acme.mir.json) is a handwritten example model. It is neither generated nor verified. The three guarantee objects it selects — TenantIsolation, AuthenticatedMutation, and NoSelfPrivilegeEscalation — remain unverified target properties, exactly as described below; their appearance in the JSON selects proof obligations and proves nothing.

No parser, resolver, typechecker, normalizer, verifier, application proof, Wasp generator, or product toolchain exists yet. Conformance of an instance to the schema can be checked with any standard JSON Schema draft 2020-12 validator. The separate Agda spike under `agda/` explores candidate kernel semantics and does not consume this JSON.

## Target properties (not implemented guarantees)

The following are properties Mithril **aims to verify in the future**. None of them is implemented, checked, or guaranteed by anything in this repository today:

- **TenantIsolation** — a request executing on behalf of one tenant cannot read or write another tenant's data through generated data-access paths.
- **AuthenticatedMutation** — no generated mutation endpoint is reachable without an authenticated principal.
- **NoSelfPrivilegeEscalation** — no principal can use generated endpoints to raise their own privileges.

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
