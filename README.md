<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/brand/mithril-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/brand/mithril-logo.svg">
    <img src="docs/assets/brand/mithril-logo.svg" alt="Mithril: pixelated ingot mark and wordmark" width="220" height="48">
  </picture>
</p>

Mithril is an open-source tool for defining web application permissions and checking that they satisfy specific security guarantees.

You (or a coding agent) use the Mithril language to describe what users are allowed to do and how their actions change your data. Mithril formally verifies supported properties of those rules using mathematical proofs, and can generate backend code from the same description.

**Mithril is an early prototype.** Today, it verifies a limited set of role-changing operations and generates a standalone Wasp demonstration.

## Why Mithril?

When you build a web app, you write rules about who can access data, change records, and manage other users. Those rules need to remain correct as you add features and change the backend.

A missing permission check can let someone modify another customer's data or give themselves administrator access. These mistakes can appear in code written by a developer or a coding agent, even when the application seems to work correctly.

Formal verification gives you a way to check a precise security property across all cases covered by a mathematical model. For example: can any permitted role change increase the caller's own privileges?

Writing those proofs usually requires specialist knowledge and considerable time. Mithril aims to make it part of ordinary backend development: describe the operations, check the supported guarantees, and repeat the check whenever the rules change.

## How it works

Mithril brings three steps together:

1. **Describe your permissions.** Write a structured description of your data, roles, operations, and permission rules. This format is called Mithril Core and currently uses JSON. You can tell a coding agent what you need in natural language and have it propose Core JSON. You then read the generated contract to check whether it describes the behavior you want.

2. **Check the security property.** Mithril validates the description, generates the required proofs for supported rules, and checks them with [Agda](https://agda.readthedocs.io/), a proof checker.

3. **Generate the backend demonstration.** For supported combinations of operations, Mithril generates a small [Wasp](https://wasp.sh/) application whose operations check permissions and update PostgreSQL in a transaction.

Proof generation and backend generation are deterministic and use the same checked Core description. No LLM participates in these stages.

## An example: managing organization roles

Suppose your application has two roles: `Member` and `Admin`.

You want to support these operations:

| Operation | Permission rule |
|---|---|
| Change another member's role | The caller must be an admin in that organization. The target must be a different, existing member. |
| Change your own role | The requested role must be equal to or below your current role in that organization. |

An admin can promote another member or demote themselves. A member cannot use either operation to become an admin.

Mithril checks a proof of this property, called **No Self Privilege Escalation**, for the selected operations. The [example document](test/fixtures/acme-nspe-self-update.mir.json) also contains other actions; those actions are outside this verification result.

## Try it

The prototype runs from source on Linux. You need GHC 9.12.4, cabal-install 3.18.1.0, and Agda 2.8.0. See [Contributing](CONTRIBUTING.md) for setup instructions.

```sh
git clone https://github.com/mithril-ir/mithril.git
cd mithril

cabal run mithril -- verify test/fixtures/acme-nspe-self-update.mir.json
```

The first run builds the tool. This command checks the example's selected operations and should return `VERIFIED`.

`VERIFIED` means Agda accepted the required proofs for those operations. Rules outside the implemented support return `UNSUPPORTED`, which does not establish whether they are safe or unsafe.

To inspect the generated review text:

```sh
cabal run mithril -- contract test/fixtures/acme-nspe-self-update.mir.json
```

The input is currently a test fixture. The review text's presentation is still provisional. See [How Mithril works](docs/how-mithril-works.md) for the walkthrough and Wasp generation commands.

<a name="trust-and-limitations"></a>

## What is actually proved?

The current proof concerns the selected role-changing operations in a mathematical model. It does not establish the security of a complete application.

The translations from Core to the proof model and to the generated backend have not themselves been proved correct. Those translations and the runtime remain trusted.

The [current scope](docs/current-scope.md) documents the exact supported rules, assumptions, and limitations.

## Vision

Our goal is to make verified authorization part of everyday development for humans and coding agents, whether they are starting a new app or adopting Mithril in an existing one. We want to support more security guarantees, generate enforcement for common backend stacks, and check authorization changes in CI before a pull request is merged. We also want to prove that the generated code faithfully implements the verified rules. These are future goals, beyond the current Wasp prototype.

## Documentation and contributing

- [How Mithril works](docs/how-mithril-works.md)
- [Current capabilities and limitations](docs/current-scope.md)
- [Compiler architecture](docs/compiler-architecture.md)
- [Agda kernel](agda/README.md)
- [Development setup and contributing](CONTRIBUTING.md)

Feedback on real authorization use cases is welcome in [GitHub issues](https://github.com/mithril-ir/mithril/issues). Please follow the [code of conduct](CODE_OF_CONDUCT.md) and report vulnerabilities through [SECURITY.md](SECURITY.md).

This software is developed with assistance from AI coding agents, with humans providing the ideas and leading the testing and debugging. We say this openly because it shaped how the project was built. If you are not happy with AI-developed code, this software is not for you. We are thankful to the great Antirez because the AI development workflow adopted in this project is largely based on his ideas about the thoughtful use of coding agents and software development in the AI era.

Licensed under [Apache 2.0](LICENSE).
