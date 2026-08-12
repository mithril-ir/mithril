# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** by email to:

**metacirculardispatches@gmail.com**

Please do **not** disclose vulnerabilities in public issues, discussions, or pull requests before a fix or a coordinated disclosure has been agreed. Include enough detail to reproduce the problem; we will acknowledge reports as quickly as we can, but as an experimental volunteer project we cannot promise fixed response times.

## Project status

Mithril is **experimental and pre-implementation**. There is currently no released software, no product verifier, and no code generator. The only checked formal artifact is an experimental, hand-transcribed, fixed-schema Agda proof slice ([`agda/README.md`](agda/README.md)): the Acme example's `Membership.changeRole` action satisfies one selected NoSelfPrivilegeEscalation case, with checked negative evidence that an unsafe self-promotion variant violates the same proposition. No tool connects that slice to the JSON example: `examples/acme/acme.mir.json` and the complete Acme model remain unverified, no other action or guarantee family is proved, and the slice provides no production-security assurance. Nothing in this repository should be relied on to secure a production system.

## Scope of future verification claims

When Mithril does ship verification functionality, its claims will be deliberately narrow:

- Verification claims will apply **only to explicitly documented properties** (such as the target properties listed in the README), never to "security" in general.
- Every claim will be conditional on **explicitly documented trusted-computing-base assumptions** — at minimum the correctness of the verifier, the code generator, the target framework, and the runtime beneath them, plus the fidelity of the human's stated intent.
- Anything outside those documented properties and assumptions — including the LLM translation step from natural language to Mithril Core — is out of scope for verification claims and remains the user's responsibility.

A verified system can still be insecure in ways the verified properties do not cover. Reports that demonstrate a gap between our documented claims and actual behavior are exactly what this policy is for.
