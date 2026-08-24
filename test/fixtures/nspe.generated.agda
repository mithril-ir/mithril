{-# OPTIONS --safe #-}

-- Generated Mithril Core v0 verification artifact.  DO NOT EDIT.
--
-- This module was derived deterministically by the mithril verifier
-- from the normalized evidence of one authored Mithril Core v0
-- document; correcting it means correcting the authored document or
-- the generator, never editing this file.  It instantiates the
-- trusted fixed-schema Agda kernel (Mithril.Base, Mithril.Core,
-- Mithril.Policy, Mithril.Effect, Mithril.Guarantee) for exactly one
-- selected NoSelfPrivilegeEscalation obligation.
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
-- case action: "Membership.changeRole" (action 4)
-- case scope binding: endpoint "organization" = Argument "organization" (parameter 1)
-- principal mode: AuthenticatedOnly
-- parameter 0: "target" : EntityRef "User"
-- parameter 1: "organization" : EntityRef "Organization"
-- parameter 2: "newRole" : Enum "MembershipRole"
-- allow policy: And(LessOrEqual[order optional "MembershipRole", absence as bottom](Some(Enum["MembershipRole"."Admin"]), Lookup["Membership"]("user" = Actor, "organization" = Argument["organization"])), And(Not(Equal(Actor, Argument["target"])), IsSome(Lookup["Membership"]("user" = Argument["target"], "organization" = Argument["organization"]))))
-- effect: SetRelation["Membership"]("user" = Argument["target"], "organization" = Argument["organization"]) payload Argument["newRole"]
-- result: Done

module Mithril.Generated where

open import Mithril.Base
open import Mithril.Core
open import Mithril.Policy
open import Mithril.Effect
open import Mithril.Guarantee

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

-- The materialized authority ranking: rank 0 ("Member") is the
-- kernel's bottom ranked value, rank 1 ("Admin") the top.

rankBottom : Role
rankBottom = memberR

rankTop : Role
rankTop = adminR

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

-- Checked theorem manifest.  Each entry restates one required
-- theorem's exact type and is defined by the qualified name of the
-- generated theorem itself, so Agda's acceptance of this module
-- proves that every required theorem above exists at exactly its
-- required type: a name occurring only in a comment, a string, a
-- hole, or a longer identifier declares nothing, and a qualified
-- reference into the inner theorem module can never resolve to an
-- imported or otherwise coincidental outer name.

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
