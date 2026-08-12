# Mithril Agda kernel spike

An experimental Agda mechanization of the hardest representation choices in
the provisional Mithril Core v0 semantic kernel. It is **not** the Mithril
Core language, parser, JSON representation, verifier, or an application
implementation, and it verifies none of the project's target properties
(TenantIsolation, AuthenticatedMutation, NoSelfPrivilegeEscalation). It
exists to validate or falsify kernel-representation choices before any
product implementation is designed.

## Checking

Requires Agda 2.8.0. From the repository root:

```
agda --safe -i agda agda/Mithril/Everything.agda
```

Stricter from-scratch variant:

```
agda --safe --no-libraries --ignore-interfaces -i agda agda/Mithril/Everything.agda
```

Every module is checked in `--safe` mode, uses Agda builtins only (no
external library), and contains no `postulate`, no `primTrustMe`, no
termination or rewrite pragmas, and no holes.

## Modules

| Module | Contents |
|---|---|
| `Mithril.Base` | Minimal prelude: negation, sums/products, `≤` on `Nat`, decidable equality. |
| `Mithril.Core` | Entity kinds and references, the value universe, finite state, total closed-world relation lookup, `SetRelation` upsert, freshness, allocation, well-formedness (`WF`), and the *unauthorized* state-level lemmas: update/frame lemmas and conditional `WF` preservation. |
| `Mithril.Policy` | Authentication levels and environments, typed argument contexts, policy terms, total evaluation, principal modes, policies with anonymous/authenticated branches, callers, validity, `eval-valid`, `fresh-not-evaluable`. |
| `Mithril.Effect` | Result descriptors, effects indexed by the descriptor they produce, actions, the `Capability` authorization evidence, the authorized transition `execute`, `execute-wf`, and general read/upsert/creation theorems. |
| `Mithril.Spike` | The representative Acme-style example: capabilities, authorized executions, and the regression evidence (ghost requests, fresh-candidate exclusion, complete-action binding). |
| `Mithril.Everything` | Entry point importing all of the above. |

## The authorization boundary

Authorization is a proof-relevant capability:

```
Capability s c γ act
```

indexed by the **exact pre-state `s`, caller `c`, argument environment `γ`,
and complete action `act`** — the action including its effect or designated
read observation, not merely its policy. Its fields (`grant` packages them)
are:

- `pre-wf : WF s` — the pre-state is well-formed;
- `caller-ok : ValidCaller s c` — an authenticated caller exists in `s`;
- `args-ok : ValidArgs s γ` — every entity reference in the arguments
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
combinators (`setMem`, `alloc`) remain public as *unauthorized semantics* —
total functions on states with conditional lemmas — and are documented as
such; only `execute` consumes authorization and represents an authorized
transition. Consequently, since any `execute` post-state is well-formed, no
authorized execution can install a Membership tuple with a nonexistent
endpoint (`Mithril.Spike` additionally shows the ghost-request capabilities
are unconstructable).

## Representation choices under test

- **Anonymous actor access is a type error, not a runtime check.**
  `PEnv anon = ⊤` carries no actor, and the `actorT` term former only
  exists at the `authed` index (`Mithril.Spike.no-anon-actorT`).
  `AnyPrincipal` policies carry separate anonymous and authenticated
  branches; effects and outputs of `AnyPrincipal` actions live at the
  anonymous level (`modeAuth`), so they cannot contain `actorT`.
- **Scope of the Actor claim.** The above excludes *direct actor syntax and
  environment access* — nothing more. An ordinary valid `User` argument may
  have the same extensional value as the authenticated actor, and such an
  argument may be consumed by anonymous-indexed effects or outputs
  (`Mithril.Spike.actor-value-flows-as-argument`). Core v0 claims no value
  provenance tracking and no information-flow non-interference.
- **Total, closed-world semantics — with ghost regions.** Relation lookup
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
  a valid request — argument, actor, or attribute path — can evaluate to a
  fresh candidate, and a fresh candidate offered *as* an argument makes the
  request invalid, so no capability exists for it.
- **Freshness is the exact next index, not mere nonmembership.** For the
  counter representation, `Fresh s k r` means `ix r ≡ count s k` — strictly
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
  authorized: `execute-create-count-other`) — together, the exact
  counter-vector change. The created Project's `organization` attribute is
  exactly the evaluation of the capability-indexed action's declared
  initializer under the capability's pre-state, caller environment and
  arguments, at exactly the allocator's candidate (`alloc-projOrg-new`;
  authorized: `execute-create-project-init`) — the allocator contributes
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

## Generic vs. specialized

**Generic in shape** (expected to survive generalization): the indexing
disciplines — terms by authentication level/context/type, effects by result
descriptor, capabilities by pre-state/caller/arguments/complete action —
plus total closed-world lookup, upsert semantics,
freshness-as-execution-input, and the structure of the validity,
preservation and frame lemmas.

**Specialized for the spike** (would need generalization in a real kernel):

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

**Deferred entirely**: JSON representation, parsing, a CLI, Wasp
generation, production reference allocation, concurrency, the full Core
action language, and the three application-level target properties.
