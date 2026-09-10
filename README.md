<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/brand/mithril-logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="docs/assets/brand/mithril-logo.svg">
  <img src="docs/assets/brand/mithril-logo.svg" alt="Mithril: pixelated ingot mark and wordmark" width="220" height="48">
</picture>

# Mithril

**Formal verification for backend permissions.**

Mithril helps developers check permission rules before those rules become
backend code. Its current prototype can prove that selected role-changing
operations do not let a user promote themselves to admin.

You describe the permissions and database changes in JSON. Mithril generates
and checks proofs for the rules it supports, and can generate a small
[Wasp](https://wasp.sh/) backend demo from the same description. You do not
write the proofs yourself.

[Try the demo](#try-the-demo) · [How it works](#how-it-works) · [Documentation](#documentation)

> **Experimental.** You can try the role-management demo today. Integration
> into an existing application is not available yet.

## Why Mithril?

A role-management endpoint can accept valid input, require login, and still
let an ordinary member assign themselves `Admin`. Authentication establishes
who is making the request; the permission checks must also restrict what
that person can change. A developer or coding agent can miss that distinction
while adding an endpoint or updating a handler.

Tests can catch this bug when they exercise the relevant request. Formal
verification can establish a property for every request and state covered
by a mathematical model, under its stated assumptions. For the supported
role-changing operations, Mithril checks a proof that the caller's own role
cannot increase.

Mithril puts the permission checks and the data updates they guard in one
description. You can review it and rerun verification whenever you or a coding
agent changes it. The aim is to make this kind of security check practical
without requiring application developers to write mathematical proofs.

## Example: prevent self-promotion

Consider an app where users belong to organizations as either a `Member` or
an `Admin`. The [example document](test/fixtures/acme-nspe-self-update.mir.json)
selects these two operations for verification:

| Operation | Permission rule |
|---|---|
| Change another member's role | The caller must be an admin in that organization, and the target must be a different, existing member. |
| Change your own role | The requested role must be equal to or below your current role in that organization. |

The self-update condition, written as pseudocode, is:

```text
newRole <= currentRole
```

An admin can demote themselves or promote someone else. A member cannot use
either operation to make themselves an admin. This is the property Mithril
checks, called **No Self Privilege Escalation**.

The example file also contains other actions. Only the two selected
operations are covered by this verification result.

## How it works

1. **Describe the operations.** A JSON file called Mithril Core describes
   the relevant data, roles, permission checks, database updates, and the
   security property to verify. You can author it directly or have a coding
   agent propose it. You still review whether it expresses your intent.

2. **Review and verify.** Mithril validates the description and can render
   a text summary for review. For supported rules, it generates proofs and
   runs [Agda](https://agda.readthedocs.io/), a mathematical proof checker.
   `VERIFIED` means Agda accepted every required proof for the selected
   operations. Inputs outside the supported rules return `UNSUPPORTED`;
   that result does not tell you whether those inputs are safe or unsafe.
   The review summary's presentation is still being improved.

3. **Generate the demo backend.** For the supported Wasp operation
   combinations, Mithril generates a standalone application with
   authenticated operations that check permissions and update PostgreSQL
   in a transaction. Its source checker can then detect changes to that
   generated application. This is a demo of executable enforcement, with
   the exact supported combinations documented in the
   [current scope](docs/current-scope.md#wasp-profile-dispatch-exact).

An LLM can help author the input; it does not generate or approve the proofs
or backend inside Mithril's pipeline. That work is done by the compiler and
proof checker.

## Try the demo

The current tool runs from source on Linux. You need **GHC 9.12.4**,
**cabal-install 3.18.1.0**, and **Agda 2.8.0** on your search path. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup.

```sh
git clone https://github.com/mithril-ir/mithril.git
cd mithril
cabal run mithril -- verify test/fixtures/acme-nspe-self-update.mir.json
```

The first run builds the tool. The command should report `VERIFIED` for
the selected operations. The input is a test fixture you can inspect and edit.

To see the generated review text:

```sh
cabal run mithril -- contract test/fixtures/acme-nspe-self-update.mir.json
```

<details>
<summary>Generate and check the Wasp demo</summary>

From the repository root:

```sh
mithril_demo_dir=$(mktemp -d /tmp/mithril-demo.XXXXXX)
cabal run mithril -- wasp generate test/fixtures/acme-nspe-self-update.mir.json "$mithril_demo_dir/wasp"
cabal run mithril -- wasp check test/fixtures/acme-nspe-self-update.mir.json "$mithril_demo_dir/wasp"
```

`CONFINED` means the source tree matches the generated demo at check time.
It does not check a running deployment. These two commands generate and
compare source files; they do not start a server. Wasp, Node, and PostgreSQL
are needed for the separate
[integration battery](CONTRIBUTING.md#build-and-test).

</details>

<a name="trust-and-limitations"></a>

## What the proof covers

The prototype verifies one property for a limited set of role-changing
rules. It checks the operations described in Core, rather than analyzing
arbitrary application code. Other authorization properties and integration
with existing applications remain future work.

The proof applies to the selected operations in the mathematical model.
The translations from Core to that model and to the generated backend have
not themselves been proved correct. The compiler and runtime remain trusted,
and the result does not establish the security of a complete deployed app.
The [scope and trust documentation](docs/current-scope.md) gives the precise
boundaries.

## Documentation

- [How Mithril works](docs/how-mithril-works.md): a walkthrough of the example and the implementation.
- [Current scope](docs/current-scope.md): supported rules, result meanings, and security assumptions.
- [Compiler architecture](docs/compiler-architecture.md) and [Agda kernel](agda/README.md): the technical details.
- [Contributing](CONTRIBUTING.md): development setup, tests, and contribution workflow.

Feedback on real authorization use cases is welcome in
[GitHub issues](https://github.com/mithril-ir/mithril/issues). Report
vulnerabilities through [SECURITY.md](SECURITY.md), and follow our
[code of conduct](CODE_OF_CONDUCT.md) when participating.

This repository has been developed with substantial coding-agent assistance,
under human-directed architecture, review, and testing. That assistance is
not evidence that the implementation is correct.

If Mithril saves you from an authorization bug, feel free to buy us a beer
(preferably a Hacker-Pschorr).

Licensed under [Apache 2.0](LICENSE).
