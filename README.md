# Mithril

> **Status: experimental, pre-implementation.** This repository currently contains project scaffolding and documentation only. There is no working code, no verifier, and no code generator yet. Nothing described below is implemented or verified.

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
| **Exists today** | This documentation, contribution and security policies, and agent guidelines. |
| **Does not exist yet** | The Mithril Core language, the verifier, the Wasp generator, the LLM translation layer, any test suite, and any toolchain. The implementation language has not been selected. |

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
