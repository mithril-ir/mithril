{-# OPTIONS --safe #-}

-- Generated Mithril Core v0 verification artifact.  DO NOT EDIT.
--
-- This module was derived deterministically by the mithril verifier
-- from the normalized evidence of one authored Mithril Core v0
-- document; correcting it means correcting the authored document or
-- the generator, never editing this file.  It instantiates the
-- trusted fixed-schema Agda kernel (Mithril.Base, Mithril.Core,
-- Mithril.Policy, Mithril.Effect, Mithril.Guarantee) for exactly one
-- selected NoSelfPrivilegeEscalation obligation with 2 escalation
-- cases, each proved in its own inner module qualified by its
-- zero-based authored case position.
--
-- Consumed normalized evidence:
--
-- model: "Acme"
-- guarantee: NoSelfPrivilegeEscalation
-- authority relation: "Membership" (relation 0)
-- authority subject endpoint: "user" (endpoint 0 of relation 0), entity "User" (entity 0)
-- authority scope endpoint: "organization" (endpoint 1 of relation 0), entity "Organization" (entity 1)
-- authority absence level: Bottom
-- authority payload order: enum "MembershipRole" (enum 0)
-- materialized authority ranking: rank 0 = "Member" (value 0 of enum 0), rank 1 = "Admin" (value 1 of enum 0)
-- selected cases: 2
--
-- case 0: rule 1 (change-other)
-- case action: "Membership.changeRole" (action 4)
-- case scope binding: endpoint "organization" = Argument "organization" (parameter 1)
-- principal mode: AuthenticatedOnly
-- parameter 0: "target" : EntityRef "User"
-- parameter 1: "organization" : EntityRef "Organization"
-- parameter 2: "newRole" : Enum "MembershipRole"
-- allow policy: And(LessOrEqual[order optional "MembershipRole", absence as bottom](Some(Enum["MembershipRole"."Admin"]), Lookup["Membership"]("user" = Actor, "organization" = Argument["organization"])), And(Not(Equal(Actor, Argument["target"])), IsSome(Lookup["Membership"]("user" = Argument["target"], "organization" = Argument["organization"]))))
-- effect: SetRelation["Membership"]("user" = Argument["target"], "organization" = Argument["organization"]) payload Argument["newRole"]
-- result: Done
--
-- case 1: rule 2 (bounded-self-update)
-- case action: "Membership.changeOwnRole" (action 5)
-- case scope binding: endpoint "organization" = Argument "organization" (parameter 0)
-- principal mode: AuthenticatedOnly
-- parameter 0: "organization" : EntityRef "Organization"
-- parameter 1: "newRole" : Enum "MembershipRole"
-- allow policy: LessOrEqual[order optional "MembershipRole", absence as bottom](Some(Argument["newRole"]), Lookup["Membership"]("user" = Actor, "organization" = Argument["organization"]))
-- effect: SetRelation["Membership"]("user" = Actor, "organization" = Argument["organization"]) payload Argument["newRole"]
-- result: Done

module Mithril.Generated where

open import Mithril.Base
open import Mithril.Core
open import Mithril.Policy
open import Mithril.Effect
open import Mithril.Guarantee

-- The materialized authority ranking: rank 0 ("Member") is the
-- kernel's bottom ranked value, rank 1 ("Admin") the top.

rankBottom : Role
rankBottom = memberR

rankTop : Role
rankTop = adminR

-- Case 0: rule 1 (change-other), case action "Membership.changeRole" (action 4).
-- Every definition and theorem of this case lives in the inner module
-- Case0, qualified by the zero-based authored case position.

module Case0 where

  -- The action's parameter context, in declaration order (parameter 0
  -- outermost); the kernel renders the subject entity as UserK, the
  -- scope entity as OrgK, and the two-value authority enum as Role.

  obligationCtx : Ctx
  obligationCtx = ∅ ▸ entity UserK ▸ entity OrgK ▸ role

  -- parameter 0 "target"
  subjectParam : Var obligationCtx (entity UserK)
  subjectParam = there (there here)

  -- parameter 1 "organization"
  scopeParam : Var obligationCtx (entity OrgK)
  scopeParam = there here

  -- parameter 2 "newRole"
  payloadParam : Var obligationCtx role
  payloadParam = here

  -- The three authored allow-policy conjuncts, transcribed constructor
  -- by constructor with the authored nesting And(first, And(guard, third)).

  allowFirst : Term authed obligationCtx bool
  allowFirst = leqT (maybe-ord role-ord)
                    (justT (roleL rankTop))
                    (memT actorT (arg scopeParam))

  allowGuard : Term authed obligationCtx bool
  allowGuard = notT (eqT actorT (arg subjectParam))

  allowThird : Term authed obligationCtx bool
  allowThird = hasMemT (arg subjectParam) (arg scopeParam)

  allowPolicy : Term authed obligationCtx bool
  allowPolicy = andT allowFirst (andT allowGuard allowThird)

  -- The complete case action: AuthenticatedOnly principal mode, the
  -- transcribed allow policy, and the SetRelation effect writing the
  -- authority relation at (subject parameter, scope parameter) with the
  -- payload parameter; the effect descriptor forces the Done result.

  obligationAction : Action authenticatedOnly obligationCtx doneD
  obligationAction =
    mutA (authP allowPolicy)
         (setRelE (arg subjectParam) (arg scopeParam) (arg payloadParam))

  -- Request projections.

  subjectOf : Args obligationCtx → EntityRef UserK
  subjectOf γ = lookupArg γ subjectParam

  scopeOf : Args obligationCtx → EntityRef OrgK
  scopeOf γ = lookupArg γ scopeParam

  -- The case scope binding: the guarantee's selected scope term is the
  -- scope parameter, so it evaluates to exactly the scope argument the
  -- theorems below quantify over.

  caseScopeTerm : Term authed obligationCtx (entity OrgK)
  caseScopeTerm = arg scopeParam

  -- The required theorems, declared in a named inner module so the
  -- checked manifest below can reference each one by a qualified name.

  module GeneratedTheorems where

    case-scope-is-scope-argument :
      ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
      → eval s (mkAuthed a) γ caseScopeTerm ≡ scopeOf γ
    case-scope-is-scope-argument s a γ = refl

    -- Policy success separates the actor from the subject parameter: the
    -- guard conjunct evaluates to notB (eqNat (ix actor) (ix subject)),
    -- so an equal index would collapse the policy value to
    -- allowFirst && false, refuted by &&-false-absurd.

    policy-actor-distinct :
      ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
      → checkPolicy s γ (authC a) (policyOf obligationAction) ≡ true
      → ¬ (ix a ≡ ix (subjectOf γ))
    policy-actor-distinct s a γ pol p =
      &&-false-absurd (eval s (mkAuthed a) γ allowFirst)
        (subst (λ b → (eval s (mkAuthed a) γ allowFirst
                       && (notB b && eval s (mkAuthed a) γ allowThird))
                      ≡ true)
               (trans (sym (cong (eqNat (ix a)) p)) (eqNat-refl (ix a)))
               pol)

    -- Strong form: every authorized execution of the case action leaves
    -- the authenticated actor's own authority tuple in the selected scope
    -- exactly unchanged (the SetRelation frame lemma, fed by the policy's
    -- actor/subject disequality).

    actor-authority-unchanged :
      ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
        (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
      → authorityOf (postState (execute cap al)) a (scopeOf γ)
      ≡ authorityOf s a (scopeOf γ)
    actor-authority-unchanged {s} {a} {γ} cap al =
      execute-setRel-frame cap al a (scopeOf γ) noHit
      where
      noHit : ¬ ((ix (subjectOf γ) ≡ ix a)
               × (ix (scopeOf γ) ≡ ix (scopeOf γ)))
      noHit (tEq , _) =
        policy-actor-distinct s a γ (policy-ok cap) (sym tEq)

    -- The selected obligation: no authorized execution of the case action
    -- raises the authenticated actor's own authority in the selected
    -- scope, with absence ranked as bottom.

    no-self-escalation :
      ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
        (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
      → NoSelfPrivilegeEscalation s (postState (execute cap al))
                                  a (scopeOf γ)
    no-self-escalation {s} {a} {γ} cap al =
      authority-unchanged→no-escalation
        s (postState (execute cap al)) a (scopeOf γ)
        (actor-authority-unchanged cap al)

-- Case 1: rule 2 (bounded-self-update), case action "Membership.changeOwnRole" (action 5).
-- Every definition and theorem of this case lives in the inner module
-- Case1, qualified by the zero-based authored case position.

module Case1 where

  -- The action's parameter context, in declaration order (parameter 0
  -- outermost); the kernel renders the scope entity as OrgK and the
  -- two-value authority enum as Role, and the authenticated actor is a
  -- reference of the subject entity, rendered as UserK.

  obligationCtx : Ctx
  obligationCtx = ∅ ▸ entity OrgK ▸ role

  -- parameter 0 "organization"
  scopeParam : Var obligationCtx (entity OrgK)
  scopeParam = there here

  -- parameter 1 "newRole"
  payloadParam : Var obligationCtx role
  payloadParam = here

  -- The single authored allow-policy comparison, transcribed constructor
  -- by constructor: the requested payload, lifted, is bounded by the
  -- actor's own authority in the scope parameter (absence as bottom).

  allowPolicy : Term authed obligationCtx bool
  allowPolicy = leqT (maybe-ord role-ord)
                     (justT (arg payloadParam))
                     (memT actorT (arg scopeParam))

  -- The complete case action: AuthenticatedOnly principal mode, the
  -- transcribed allow policy, and the SetRelation effect writing the
  -- authority relation at (Actor, scope parameter) with the payload
  -- parameter; the effect descriptor forces the Done result.

  obligationAction : Action authenticatedOnly obligationCtx doneD
  obligationAction =
    mutA (authP allowPolicy)
         (setRelE actorT (arg scopeParam) (arg payloadParam))

  -- Request projections.

  scopeOf : Args obligationCtx → EntityRef OrgK
  scopeOf γ = lookupArg γ scopeParam

  payloadOf : Args obligationCtx → Role
  payloadOf γ = lookupArg γ payloadParam

  -- The case scope binding: the guarantee's selected scope term is the
  -- scope parameter, so it evaluates to exactly the scope argument the
  -- theorems below quantify over.

  caseScopeTerm : Term authed obligationCtx (entity OrgK)
  caseScopeTerm = arg scopeParam

  -- The required theorems, declared in a named inner module so the
  -- checked manifest below can reference each one by a qualified name.

  module GeneratedTheorems where

    case-scope-is-scope-argument :
      ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
      → eval s (mkAuthed a) γ caseScopeTerm ≡ scopeOf γ
    case-scope-is-scope-argument s a γ = refl

    -- Policy success bounds the requested payload by the actor's own
    -- pre-state authority in the selected scope: the single authored
    -- comparison evaluates to exactly that bound, with absence ranked as
    -- bottom, so the policy equation is the bound itself.

    policy-bounds-payload :
      ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
      → checkPolicy s γ (authC a) (policyOf obligationAction) ≡ true
      → authLeq (just (payloadOf γ)) (authorityOf s a (scopeOf γ)) ≡ true
    policy-bounds-payload s a γ pol = pol

    -- Every authorized execution of the case action writes exactly the
    -- requested payload to the authenticated actor's own authority tuple
    -- in the selected scope (the SetRelation point lemma).

    actor-authority-written :
      ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
        (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
      → authorityOf (postState (execute cap al)) a (scopeOf γ)
      ≡ just (payloadOf γ)
    actor-authority-written cap al = execute-setRel-point cap al

    -- The selected obligation: the written payload is bounded by the
    -- actor's pre-state authority, so no authorized execution of the case
    -- action raises the actor's own authority in the selected scope, with
    -- absence ranked as bottom.

    no-self-escalation :
      ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
        (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
      → NoSelfPrivilegeEscalation s (postState (execute cap al))
                                  a (scopeOf γ)
    no-self-escalation {s} {a} {γ} cap al =
      trans
        (cong (λ level → authLeq level (authorityOf s a (scopeOf γ)))
              (actor-authority-written cap al))
        (policy-bounds-payload s a γ (policy-ok cap))

-- Checked theorem manifests.  Each case's manifest module opens that
-- case's inner module and restates every required theorem's exact
-- type, defined by the qualified name of the generated theorem itself,
-- so Agda's acceptance of this module proves that every required
-- theorem of every case exists at exactly its required type: a name
-- occurring only in a comment, a string, a hole, or a longer
-- identifier declares nothing, and a qualified reference into a case's
-- inner theorem module can never resolve to an imported or otherwise
-- coincidental outer name.

module ManifestCase0 where

  open Case0

  manifest-case-scope-is-scope-argument :
    ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
    → eval s (mkAuthed a) γ caseScopeTerm ≡ scopeOf γ
  manifest-case-scope-is-scope-argument = GeneratedTheorems.case-scope-is-scope-argument

  manifest-policy-actor-distinct :
    ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
    → checkPolicy s γ (authC a) (policyOf obligationAction) ≡ true
    → ¬ (ix a ≡ ix (subjectOf γ))
  manifest-policy-actor-distinct = GeneratedTheorems.policy-actor-distinct

  manifest-actor-authority-unchanged :
    ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
      (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
    → authorityOf (postState (execute cap al)) a (scopeOf γ)
    ≡ authorityOf s a (scopeOf γ)
  manifest-actor-authority-unchanged = GeneratedTheorems.actor-authority-unchanged

  manifest-no-self-escalation :
    ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
      (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
    → NoSelfPrivilegeEscalation s (postState (execute cap al))
                                a (scopeOf γ)
  manifest-no-self-escalation = GeneratedTheorems.no-self-escalation

module ManifestCase1 where

  open Case1

  manifest-case-scope-is-scope-argument :
    ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
    → eval s (mkAuthed a) γ caseScopeTerm ≡ scopeOf γ
  manifest-case-scope-is-scope-argument = GeneratedTheorems.case-scope-is-scope-argument

  manifest-policy-bounds-payload :
    ∀ (s : State) (a : EntityRef UserK) (γ : Args obligationCtx)
    → checkPolicy s γ (authC a) (policyOf obligationAction) ≡ true
    → authLeq (just (payloadOf γ)) (authorityOf s a (scopeOf γ)) ≡ true
  manifest-policy-bounds-payload = GeneratedTheorems.policy-bounds-payload

  manifest-actor-authority-written :
    ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
      (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
    → authorityOf (postState (execute cap al)) a (scopeOf γ)
    ≡ just (payloadOf γ)
  manifest-actor-authority-written = GeneratedTheorems.actor-authority-written

  manifest-no-self-escalation :
    ∀ {s : State} {a : EntityRef UserK} {γ : Args obligationCtx}
      (cap : Capability s (authC a) γ obligationAction) (al : Allocator s)
    → NoSelfPrivilegeEscalation s (postState (execute cap al))
                                a (scopeOf γ)
  manifest-no-self-escalation = GeneratedTheorems.no-self-escalation
