# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** by email to:

**metacirculardispatches@gmail.com**

Please do **not** disclose vulnerabilities in public issues, discussions, or pull requests before a fix or a coordinated disclosure has been agreed. Include enough detail to reproduce the problem; we will acknowledge reports as quickly as we can, but as an experimental volunteer project we cannot promise fixed response times.

## Project status

Mithril is **experimental and incomplete**. There is currently no released software, no complete or general verifier, and no production or target code generator — what is implemented is the deterministic Haskell frontend through the typed normalized Core, deterministic technical-contract rendering, and one narrow, structurally gated NoSelfPrivilegeEscalation proof-artifact generator whose output is checked by Agda 2.8.0. Two checked formal artifacts exist. First, an experimental, hand-transcribed, fixed-schema Agda proof slice ([`agda/README.md`](agda/README.md)): the Acme example's `Membership.changeRole` action satisfies one selected NoSelfPrivilegeEscalation case, with checked negative evidence that an unsafe self-promotion variant violates the same proposition. Second, the host tool's first connected verifier slice: `mithril verify` connects exactly one structurally gated NoSelfPrivilegeEscalation obligation shape from normalized Core through a generated Agda module checked by Agda 2.8.0. Everything else remains unconnected and unverified: the canonical `examples/acme/acme.mir.json` is reported UNSUPPORTED and, like the complete Acme model, remains unverified; TenantIsolation and AuthenticatedMutation remain unverified; no other action or guarantee family is proved; there is no semantic diff and no general JSON-to-Agda backend; and neither slice provides production-security assurance. Nothing in this repository should be relied on to secure a production system.

## Scope of future verification claims

Mithril's implemented verification functionality is deliberately narrow — today it covers exactly one structurally gated NoSelfPrivilegeEscalation obligation shape, connected from normalized Core through generated Agda checked by Agda 2.8.0 — and as that functionality grows, its claims will stay deliberately narrow:

- Verification claims will apply **only to explicitly documented properties** (such as the target properties listed in the README), never to "security" in general.
- Every claim will be conditional on **explicitly documented trusted-computing-base assumptions** — at minimum the correctness of the verifier, the code generator, the target framework, and the runtime beneath them, plus the fidelity of the human's stated intent.
- Anything outside those documented properties and assumptions — including the LLM translation step from natural language to Mithril Core — is out of scope for verification claims and remains the user's responsibility.

A verified system can still be insecure in ways the verified properties do not cover. Reports that demonstrate a gap between our documented claims and actual behavior are exactly what this policy is for.
