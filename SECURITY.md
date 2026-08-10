# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** by email to:

**metacirculardispatches@gmail.com**

Please do **not** disclose vulnerabilities in public issues, discussions, or pull requests before a fix or a coordinated disclosure has been agreed. Include enough detail to reproduce the problem; we will acknowledge reports as quickly as we can, but as an experimental volunteer project we cannot promise fixed response times.

## Project status

Mithril is **experimental and pre-implementation**. There is currently no released software, no verifier, and no code generator, and therefore no verified artifacts of any kind. Nothing in this repository should be relied on to secure a production system.

## Scope of future verification claims

When Mithril does ship verification functionality, its claims will be deliberately narrow:

- Verification claims will apply **only to explicitly documented properties** (such as the target properties listed in the README), never to "security" in general.
- Every claim will be conditional on **explicitly documented trusted-computing-base assumptions** — at minimum the correctness of the verifier, the code generator, the target framework, and the runtime beneath them, plus the fidelity of the human's stated intent.
- Anything outside those documented properties and assumptions — including the LLM translation step from natural language to Mithril Core — is out of scope for verification claims and remains the user's responsibility.

A verified system can still be insecure in ways the verified properties do not cover. Reports that demonstrate a gap between our documented claims and actual behavior are exactly what this policy is for.
