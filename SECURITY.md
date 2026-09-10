# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** by email to:

**metacirculardispatches@gmail.com**

Please do **not** disclose vulnerabilities in public issues, discussions,
or pull requests before a fix or a coordinated disclosure has been agreed.
Include enough detail to reproduce the problem; we will acknowledge
reports as quickly as we can, but as an experimental volunteer project we
cannot promise fixed response times.

## Project status

Mithril is **experimental and incomplete**. There is no released software,
no complete or general verifier, and no general target code generator.
Nothing in this repository should be relied on to secure a production
system.

The implemented deterministic frontend, contract renderer, narrow NSPE
verifier slice (two structural proof rules, checked by Agda 2.8.0), and two
confined Wasp demonstrator profiles are documented
exactly, with their trusted components and non-claims, in
[docs/current-scope.md](docs/current-scope.md). In particular:

- A `VERIFIED` outcome covers exactly the selected cases of the one
  selected obligation of a supported document under the documented
  trusted components: the Haskell tool, the embedded Agda kernel, the
  support rules, and the Agda 2.8.0 toolchain. It covers nothing else.
- The verified **model slice** is distinct from the generated and runtime
  **implementation**: no semantic-preservation theorem proves
  Core-to-Agda or Core-to-Wasp correspondence, so Wasp, Node, Prisma,
  PostgreSQL, the templates, and the lowering remain trusted, and a
  generated bundle is trusted correspondence evidence, not a proof.
- The Wasp confinement claim covers a valid clean source snapshot at the
  time of checking or generation; mutation after the check, tampering
  after the Wasp build, dependency compromise, and processes holding the
  database credentials are outside it.
- `UNSUPPORTED` is a support decision, never a safety or violation
  verdict, and no `VIOLATED` result exists.

## Scope of verification claims

Mithril's verification claims are deliberately narrow today and will stay
deliberately narrow as functionality grows:

- Verification claims apply **only to explicitly documented properties**,
  never to "security" in general.
- Every claim is conditional on **explicitly documented
  trusted-computing-base assumptions**, at minimum the correctness of
  the verifier, the code generator, the target framework, and the runtime
  beneath them, plus the fidelity of the human's stated intent.
- Anything outside those documented properties and assumptions, including
  the untrusted LLM translation step from natural language to Mithril Core,
  is out of scope for verification claims and remains the
  user's responsibility.

A verified system can still be insecure in ways the verified properties
do not cover. Reports that demonstrate a gap between our documented
claims and actual behavior are exactly what this policy is for.
