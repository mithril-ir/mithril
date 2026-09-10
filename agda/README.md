# Mithril Agda kernel

The `agda/` tree holds three kinds of Agda module. The checking commands
below type-check all of them together, but their standing differs:

- **The embedded fixed-schema kernel:** the five handwritten modules
  `Mithril.Base`, `Mithril.Core`, `Mithril.Policy`, `Mithril.Effect`, and
  `Mithril.Guarantee`. `mithril verify FILE` embeds exactly these at
  compile time as its trusted kernel, so changing any of them changes the
  verifier's trusted computing base: keep both checks below and the
  Haskell test suite passing. They mechanize the representation choices of
  the provisional Mithril Core v0 semantic kernel, specialized to one fixed
  schema (three entity kinds, one attribute, one relation, one enum) and to
  the supported NoSelfPrivilegeEscalation slice. They are **not** a
  general-purpose kernel, and **not** the Mithril Core language, parser,
  JSON representation, verifier, or an application implementation.
- **The generated document-specific module:** for a supported document,
  `mithril verify` generates one obligation module against the embedded
  kernel and checks it in a fresh isolated workspace. It is never written
  under `agda/`; its bytes are pinned by the goldens
  [`test/fixtures/nspe.generated.agda`](../test/fixtures/nspe.generated.agda)
  and
  [`test/fixtures/nspe-self-update.generated.agda`](../test/fixtures/nspe-self-update.generated.agda).
- **Experiments and examples outside the verifier kernel:**
  `Mithril.Spike`, a representative Acme-style example carrying the
  regression evidence for the capability boundary, and `Mithril.Acme`, the
  hand-transcribed `Membership.changeRole` slice (see
  ["The Acme application slice"](#the-acme-application-slice) below). The
  tool neither embeds them nor imports them from generated code; they are
  authored experiments that exercise the kernel. `Mithril.Everything` is
  the entry point importing all seven modules.

Of the project's target properties (TenantIsolation, AuthenticatedMutation,
NoSelfPrivilegeEscalation), the Agda tree carries exactly one: the
fixed-schema NoSelfPrivilegeEscalation proposition of `Mithril.Guarantee`,
instantiated by hand in `Mithril.Acme` for the Acme example's
`Membership.changeRole` action and, through the generated module, by
`mithril verify` for the supported document shapes. The other two property
families, the rest of the Acme model, and the canonical JSON document itself
remain unverified.

The tool's connection is deliberately narrow. The supported normalized
guarantee family is the fixed NoSelfPrivilegeEscalation family of this
kernel: one selected guarantee whose non-empty case collection is
classified case by case as exact rule-1 change-other cases (structurally
corresponding to the safe `changeRole` proof rule below) and/or exact
rule-2 bounded-self-update cases (an authenticated principal writing its
own authority tuple to a payload bounded by its pre-state authority).
For that family, `mithril verify` generates an obligation module with one
proof group per case against the five kernel modules and checks it with exactly Agda 2.8.0
in safe mode inside an isolated workspace; the generated module re-proves
the matching rule for every selected case of a supported document. No
general verifier or general JSON-to-Agda lowering exists. Everything
outside that one guarantee family and its two exact case rules is
UNSUPPORTED to the tool, and no violation is ever reported by it. The
tool's Wasp Confinement Profile v0 lowers only exactly one rule-1 case and
its Wasp Confinement Profile v1 only the exact ordered rule-1, rule-2 case
pair, so a document verified with any other case sequence (a singleton
rule-2 case, two rule-1 cases, the reversed pair, three or more cases) has
no Wasp counterpart and is UNSUPPORTED to `mithril wasp generate|check`.

## Checking

Requires Agda 2.8.0. From the repository root:

```
agda --safe -i agda agda/Mithril/Everything.agda
```

Stricter from-scratch variant:

```
agda --safe --no-libraries --ignore-interfaces -i agda agda/Mithril/Everything.agda
```

Every module, kernel and experiment alike, is checked in `--safe` mode,
uses Agda builtins only (no external library), and contains no
`postulate`, no `primTrustMe`, no termination or rewrite pragmas, and no
holes.

## Modules

| Module | Standing | Contents |
|---|---|---|
| `Mithril.Base` | Embedded kernel | Minimal prelude: negation, sums/products, `≤` on `Nat`, decidable equality. |
| `Mithril.Core` | Embedded kernel | Entity kinds and references, the value universe, finite state, total closed-world relation lookup, `SetRelation` upsert, freshness, allocation, well-formedness (`WF`), and the *unauthorized* state-level lemmas: update/frame lemmas and conditional `WF` preservation. |
| `Mithril.Policy` | Embedded kernel | Authentication levels and environments, typed argument contexts, policy terms, total evaluation, principal modes, policies with anonymous/authenticated branches, callers, validity, `eval-valid`, `fresh-not-evaluable`. |
| `Mithril.Effect` | Embedded kernel | Result descriptors, effects indexed by the descriptor they produce, actions, the `Capability` authorization evidence, the authorized transition `execute`, `execute-wf`, and general read/upsert/creation theorems. |
| `Mithril.Guarantee` | Embedded kernel | The fixed-schema NoSelfPrivilegeEscalation proposition: authority as the Membership payload with absence as bottom (`nothing < Member < Admin`), non-escalation for one transition, and the unchanged-authority route into it. |
| `Mithril.Spike` | Experiment, not embedded | The representative Acme-style example: capabilities, authorized executions, and the regression evidence (ghost requests, fresh-candidate exclusion, complete-action binding). |
| `Mithril.Acme` | Experiment, not embedded | The application slice: the hand-transcribed `Membership.changeRole` action, its universal no-self-escalation theorems, a non-vacuity execution, and the checked unsafe-variant counterexample. |
| `Mithril.Everything` | Entry point | Imports all of the above. |

## The authorization boundary

Authorization is a proof-relevant capability:

```
Capability s c γ act
```

indexed by the **exact pre-state `s`, caller `c`, argument environment `γ`,
and complete action `act`** (including its effect or designated read
observation, not merely its policy). Its fields (`grant` packages them)
are:

- `pre-wf : WF s`: the pre-state is well-formed;
- `caller-ok : ValidCaller s c`: an authenticated caller exists in `s`;
- `args-ok : ValidArgs s γ`: every entity reference in the arguments
  exists in `s`;
- `policy-ok : checkPolicy s γ c (policyOf act) ≡ true`.

A policy equation alone is never authorization: it is only accepted when
packaged with the validity evidence for the same request. Because the
capability is indexed by the complete action, evidence for one action
cannot authorize another with a different effect or observation, however
the policy equations happen to normalize. Two *definitionally equal*
actions are the same semantic action (adjudicated for Core v0; no nominal
action-ID mechanism is used).

The only public transition is

```
execute : Capability s c γ act → Allocator s → ExecOut d
```

and the general preservation theorem needs nothing beyond it:

```
execute-wf : (cap : Capability s c γ act) (al : Allocator s)
           → WF (postState (execute cap al))
```

The raw effect interpreter (`execMut`) and its conditional preservation
lemma are **private** to `Mithril.Effect`: they carry no authorization and
cannot be invoked from outside as a transition. `Mithril.Core`'s state
combinators (`setMem`, `alloc`) remain public as *unauthorized semantics*:
total functions on states with conditional lemmas. They are documented as
such; only `execute` consumes authorization and represents an authorized
transition. Consequently, since any `execute` post-state is well-formed, no
authorized execution can install a Membership tuple with a nonexistent
endpoint (`Mithril.Spike` additionally shows the ghost-request capabilities
are unconstructable).

## Representation choices

- **Anonymous actor access is a type error, not a runtime check.**
  `PEnv anon = ⊤` carries no actor, and the `actorT` term former only
  exists at the `authed` index (`Mithril.Spike.no-anon-actorT`).
  `AnyPrincipal` policies carry separate anonymous and authenticated
  branches; effects and outputs of `AnyPrincipal` actions live at the
  anonymous level (`modeAuth`), so they cannot contain `actorT`.
- **Scope of the Actor claim.** The above excludes *direct actor syntax and
  environment access*, and nothing more. An ordinary valid `User` argument may
  have the same extensional value as the authenticated actor, and such an
  argument may be consumed by anonymous-indexed effects or outputs
  (`Mithril.Spike.actor-value-flows-as-argument`). Core v0 claims no value
  provenance tracking and no information-flow non-interference.
- **Total, closed-world semantics, with ghost regions.** Relation lookup
  is a total function into `Maybe`; there is no unwrap form and no partial
  evaluation (`eval` returns a bare `Val t`). Absence orders as bottom.
  State functions are total over `Nat` indices: `projOrg` values at or
  above the `projects` counter are unconstrained "ghost region" garbage,
  and `WF` constrains only the meaningful region below the counter. The
  Membership clauses of `WF` are *global* instead: a present tuple at any
  index pair whatsoever must have existing endpoints, so a well-formed
  relation has no populated ghost region. Evaluation stays total even for
  requests naming ghost references; such evaluations are meaningless and
  are never accepted as authorization, because capability construction
  requires validity.
- **Result shape is forced by the effect.** `MutEffect a Γ d` is indexed by
  its result descriptor: `SetRelation`/`NoChange` mutations can only answer
  `done`, `CreateEntity` alone answers `created`, and reads (which carry no
  effect slot at all) answer `observed`. A mutation returning an arbitrary
  unrelated entity is unrepresentable.
- **Reads return their designated observation.** A read action carries a
  designated observation term; the policy is not required to mention it (a
  permissive policy may authorize a designated target without inspecting
  it). The capability binds policy and observation as one complete action;
  `execute-read-exact` shows the result is exactly the designated
  observation's evaluation, and `execute-read-exists` that the observed
  entity exists in the valid pre-state.
- **Fresh references are execution-only inputs.** `CreateEntity` carries no
  reference. `execute` receives an `Allocator`: per kind, a candidate
  reference plus a proof it is fresh in the pre-state. The candidate is not
  part of the request, the action arguments, or the policy environment, and
  the allocator supplies no initializer values (required attributes come
  from the declared `InitTerm`). Beyond unrepresentability, this is now a
  semantic theorem: `fresh-not-evaluable` shows no entity-reference term of
  a valid request (argument, actor, or attribute path) can evaluate to a
  fresh candidate, and a fresh candidate offered *as* an argument makes the
  request invalid, so no capability exists for it.
- **Freshness is the exact next index, not mere nonmembership.** For the
  counter representation, `Fresh s k r` means `ix r ≡ count s k`, which is strictly
  stronger than "does not exist". Nonmembership follows
  (`fresh-not-exists`), and exactness is what makes the candidate exist
  after allocation (`alloc-exists`). A generic kernel with abstract
  reference domains would define freshness as nonmembership in the domain
  and re-establish both facts.
- **Creation changes exactly what it must.** Under the fixed-schema,
  counter-representation specialization, authorized creation is pinned
  exactly, not merely bounded: the selected kind's counter increments by
  exactly one (`alloc-count`; authorized: `execute-create-count-selected`);
  every unrelated kind's counter is exactly unchanged (`alloc-count-other`;
  authorized: `execute-create-count-other`); together these establish the exact
  counter-vector change. The created Project's `organization` attribute is
  exactly the evaluation of the capability-indexed action's declared
  initializer under the capability's pre-state, caller environment and
  arguments, at exactly the allocator's candidate (`alloc-projOrg-new`;
  authorized: `execute-create-project-init`); the allocator contributes
  only the candidate and freshness evidence, unavailable to policy
  evaluation. Pre-existing entities, attribute values and relation tuples
  are preserved (`alloc-preserves-exists`, `alloc-projOrg`, `alloc-mem`,
  and their `execute-create-*` corollaries).
- **Preservation is capability-enforced at the boundary.** Internal
  preservation lemmas (`setMem-wf`, `alloc-wf`, the private interpreter's
  lemma) are *conditional* on validity premises. The public guarantee,
  `execute-wf`, takes only a capability and the allocator: the conditions
  travel inside the authorization evidence and cannot be omitted. Frame
  lemmas for the upsert (`setMem-lookup-other`, `setMem-count`,
  `setMem-projOrg`, and `execute-setRel-frame`) show everything outside
  the written tuple is preserved; creation's exact footprint is itemized
  in the previous bullet.

## The Acme application slice

`Mithril.Guarantee` (kernel) and `Mithril.Acme` (experiment) carry the
first application-level proof slice on top of the kernel: **one action, one
property, by hand**. `Mithril.Acme` is a hand-transcribed, fixed-schema
Agda application *experiment* outside the verifier kernel: `mithril verify`
neither embeds nor imports it, no JSON-to-Agda lowering produces it, and
nothing checks the transcription against the JSON document. The tool's
own generated module is derived separately from the normalized document.

- `Mithril.Acme.changeRole` hand-transcribes the `Membership.changeRole`
  action of [`examples/acme/acme.mir.json`](../examples/acme/acme.mir.json):
  the parameters `target : User`, `organization : Organization`,
  `newRole : MembershipRole` become the typed context; the allow policy
  (actor is Admin in the organization, actor is not the target, the target
  currently has a Membership there) and the SetRelation effect
  (`Membership(target, organization) := newRole`, result `Done`) are
  transcribed constructor by constructor with the JSON's nesting.
- `Mithril.Guarantee.NoSelfPrivilegeEscalation` states the selected
  guarantee case for one transition: the subject's own Membership
  authority in the scope organization, with the payload ordered using absence
  as bottom (`nothing < Member < Admin`), does not increase.
- `Mithril.Acme.changeRole-actor-authority-unchanged` proves the stronger
  fact for **every** pre-state, authenticated actor, argument environment,
  capability and allocator: an authorized execution leaves the actor's own
  Membership tuple in the selected organization exactly unchanged. Policy
  success forces actor ≠ target, and the kernel's SetRelation frame lemma
  does the rest. `changeRole-no-self-escalation` derives the guarantee
  form, and a concrete admin-promotes-another-member execution shows the
  theorems are not vacuous.
- Negative evidence, checked rather than inspected:
  `Mithril.Acme.changeRoleUnsafe` (not part of the JSON document) keeps the
  parameters and effect but weakens the policy to "actor holds at least
  Member", so a Member may target themself. A concrete valid, authorized
  execution takes that Member's own tuple from Member to Admin, and
  `changeRoleUnsafe-violates-no-self-escalation` proves the transition
  violates the same proposition; `changeRole-denies-self-promotion` shows
  the safe action has no capability for the identical request.

The slice verifies nothing beyond this: not the JSON document, not the
remaining Acme actions (`Project.delete`'s DeleteEntity effect is not even
representable in the kernel), not the other guarantee families, and no
general property of Core.

## Generic vs. specialized

**Generic in shape** (expected to survive generalization): the indexing
disciplines (terms by authentication level/context/type, effects by result
descriptor, capabilities by pre-state/caller/arguments/complete action),
plus total closed-world lookup, upsert semantics,
freshness-as-execution-input, and the structure of the validity,
preservation and frame lemmas.

**Specialized to the fixed schema** (would need generalization before the
kernel could serve any other schema):

- The schema is fixed: three entity kinds, one attribute
  (`Project.organization`), one relation (`Membership`), one enum (`Role`).
  A full kernel would parameterize state, terms, and lookup over a declared
  schema; that dependent plumbing was deliberately avoided here.
- Entity domains are counters, so freshness is the exact next index (see
  above for what changes with abstract domains).
- The creation payload (`AllocInit`/`InitTerm`) is a kind-indexed special
  case of "required attributes at creation".
- Capability construction is by direct evidence (`grant`); a complete
  Invalid/Denied decision procedure for requests is not part of this
  correction.

**Not mechanized in Agda at all**: JSON representation, parsing, the CLI,
Wasp generation, production reference allocation, concurrency, the full
Core action language, and the TenantIsolation and AuthenticatedMutation
property families. Where any of these exist, they are host-tool code
outside every Agda claim. Of NoSelfPrivilegeEscalation, the Agda tree
carries only the fixed-schema proposition, its hand-transcribed
`Membership.changeRole` instance, and, through the generated module, the
two exact case rules of `mithril verify`; nothing else is verified.
