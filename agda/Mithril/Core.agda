{-# OPTIONS --safe #-}

-- Mithril Agda spike: core vocabulary and state.
--
-- SPECIALIZED FOR THE SPIKE: the entity kinds (User, Organization, Project),
-- the single attribute (Project.organization), the single relation
-- (Membership : User × Organization ⇀ Role) and the single enum (Role) are
-- fixed here rather than being drawn from a generic schema.  A full kernel
-- would parameterize state, lookup and update over a declared schema; the
-- *shapes* below (counter-based entity domains, total closed-world lookup
-- into Maybe, point-update upsert, freshness as the exact next index) are
-- the part this spike is testing and are intended to generalize.
--
-- IMPORTANT: everything in this module is UNAUTHORIZED state semantics —
-- total combinators on states and the conditional lemmas about them.
-- Nothing here consumes authorization evidence.  The only authorized
-- transition of the spike is `Mithril.Effect.execute`, which requires a
-- `Capability`.

module Mithril.Core where

open import Mithril.Base

-- Entity kinds and references ------------------------------------------------

data EntityKind : Set where
  UserK OrgK ProjectK : EntityKind

-- References are indices into a per-kind counter domain: in a state with
-- `count s k = n`, exactly the references with index < n exist.
record EntityRef (k : EntityKind) : Set where
  constructor ref
  field ix : Nat
open EntityRef public

eqRef : ∀ {k} → EntityRef k → EntityRef k → Bool
eqRef r₁ r₂ = eqNat (ix r₁) (ix r₂)
  where
  eqNat : Nat → Nat → Bool
  eqNat zero    zero    = true
  eqNat zero    (suc _) = false
  eqNat (suc _) zero    = false
  eqNat (suc m) (suc n) = eqNat m n

-- The spike's representative finite ordered enum: Membership payloads.
-- Order: memberR < adminR.

data Role : Set where
  memberR adminR : Role

eqRole : Role → Role → Bool
eqRole memberR memberR = true
eqRole adminR  adminR  = true
eqRole memberR adminR  = false
eqRole adminR  memberR = false

roleLeq : Role → Role → Bool
roleLeq memberR _       = true
roleLeq adminR  adminR  = true
roleLeq adminR  memberR = false

-- Value universe -------------------------------------------------------------

data Ty : Set where
  bool   : Ty
  unit   : Ty
  entity : EntityKind → Ty
  role   : Ty                    -- representative finite ordered enum
  maybe  : Ty → Ty

Val : Ty → Set
Val bool       = Bool
Val unit       = ⊤
Val (entity k) = EntityRef k
Val role       = Role
Val (maybe t)  = Maybe (Val t)

-- Typed equality is total on the whole universe.
eqVal : (t : Ty) → Val t → Val t → Bool
eqVal bool       b₁       b₂       = eqBool b₁ b₂
eqVal unit       _        _        = true
eqVal (entity k) r₁       r₂       = eqRef r₁ r₂
eqVal role       r₁       r₂       = eqRole r₁ r₂
eqVal (maybe t)  nothing  nothing  = true
eqVal (maybe t)  nothing  (just _) = false
eqVal (maybe t)  (just _) nothing  = false
eqVal (maybe t)  (just v) (just w) = eqVal t v w

-- Ordered types: the enum is ordered, and Maybe over an ordered type is
-- ordered with absence (`nothing`) as bottom.
data Ordered : Ty → Set where
  role-ord  : Ordered role
  maybe-ord : ∀ {t} → Ordered t → Ordered (maybe t)

leqVal : ∀ {t} → Ordered t → Val t → Val t → Bool
leqVal role-ord      v        w        = roleLeq v w
leqVal (maybe-ord o) nothing  _        = true
leqVal (maybe-ord o) (just _) nothing  = false
leqVal (maybe-ord o) (just v) (just w) = leqVal o v w

-- State ----------------------------------------------------------------------

-- Membership : User × Organization ⇀ Role, as a total function into Maybe.
-- Closed world: a missing tuple IS `nothing`; there is no separate failure
-- outcome (infrastructure failure is out of scope for the semantics).
MembershipMap : Set
MembershipMap = Nat → Nat → Maybe Role

-- `projOrg` and `membership` are TOTAL functions over Nat indices.  Only
-- `projOrg` values at indices below `projects` are meaningful; values in
-- the "ghost region" at or above the counter are unconstrained garbage and
-- carry no meaning.  Well-formedness (`WF`, below) constrains exactly the
-- meaningful region of `projOrg` — but constrains `membership` GLOBALLY:
-- a present tuple at ANY index pair must have existing endpoints, so a
-- well-formed membership relation has no populated ghost region at all.
record State : Set where
  field
    users    : Nat               -- users with index < users exist
    orgs     : Nat
    projects : Nat
    projOrg  : Nat → Nat         -- Project.organization; meaningful below projects
    membership : MembershipMap
open State public

count : State → EntityKind → Nat
count s UserK    = users s
count s OrgK     = orgs s
count s ProjectK = projects s

Exists : State → ∀ {k} → EntityRef k → Set
Exists s {k} r = ix r < count s k

-- Total closed-world relation lookup.
lookupMem : State → EntityRef UserK → EntityRef OrgK → Maybe Role
lookupMem s u o = membership s (ix u) (ix o)

-- Point updates --------------------------------------------------------------

updFun : (Nat → Nat) → Nat → Nat → (Nat → Nat)
updFun f p₀ v p′ = decIf (p₀ ≟ p′) v (f p′)

updMem : MembershipMap → Nat → Nat → Role → MembershipMap
updMem f u₀ o₀ r₀ u′ o′ = decIf (u₀ ≟ u′) (decIf (o₀ ≟ o′) (just r₀) (f u′ o′)) (f u′ o′)

-- SetRelation as a typed upsert: inserts an absent tuple or replaces an
-- existing payload, in one total operation.
setMem : State → EntityRef UserK → EntityRef OrgK → Role → State
setMem s u o r = record s { membership = updMem (membership s) (ix u) (ix o) r }

-- Update lemmas --------------------------------------------------------------

≟-refl : ∀ n → (n ≟ n) ≡ yes refl
≟-refl zero = refl
≟-refl (suc n) rewrite ≟-refl n = refl

updFun-cases : ∀ f p₀ v p′
             → ((p₀ ≡ p′) × (updFun f p₀ v p′ ≡ v))
             ⊎ ((¬ (p₀ ≡ p′)) × (updFun f p₀ v p′ ≡ f p′))
updFun-cases f p₀ v p′ with p₀ ≟ p′
... | yes p = inl (p , refl)
... | no np = inr (np , refl)

updFun-point : ∀ f p v → updFun f p v p ≡ v
updFun-point f p v rewrite ≟-refl p = refl

updMem-point : ∀ f u o r → updMem f u o r u o ≡ just r
updMem-point f u o r rewrite ≟-refl u | ≟-refl o = refl

updMem-cases : ∀ f u₀ o₀ r₀ u′ o′
             → ((u₀ ≡ u′) × (o₀ ≡ o′) × (updMem f u₀ o₀ r₀ u′ o′ ≡ just r₀))
             ⊎ (updMem f u₀ o₀ r₀ u′ o′ ≡ f u′ o′)
updMem-cases f u₀ o₀ r₀ u′ o′ with u₀ ≟ u′ | o₀ ≟ o′
... | yes p | yes q = inl (p , (q , refl))
... | yes p | no _  = inr refl
... | no _  | _     = inr refl

-- SetRelation produces the expected updated lookup (insertion when the
-- tuple was absent, replacement when it was present: the upsert is the
-- same total operation either way) …
setMem-lookup : ∀ s u o r → lookupMem (setMem s u o r) u o ≡ just r
setMem-lookup s u o r = updMem-point (membership s) (ix u) (ix o) r

-- … and frame lemmas: everything else is untouched.
setMem-lookup-other : ∀ s u o r (u′ : EntityRef UserK) (o′ : EntityRef OrgK)
                    → ¬ ((ix u ≡ ix u′) × (ix o ≡ ix o′))
                    → lookupMem (setMem s u o r) u′ o′ ≡ lookupMem s u′ o′
setMem-lookup-other s u o r u′ o′ np
  with updMem-cases (membership s) (ix u) (ix o) r (ix u′) (ix o′)
... | inl (p , (q , _)) = absurd (np (p , q))
... | inr e             = e

setMem-count : ∀ s u o r k → count (setMem s u o r) k ≡ count s k
setMem-count s u o r UserK    = refl
setMem-count s u o r OrgK     = refl
setMem-count s u o r ProjectK = refl

setMem-projOrg : ∀ s u o r pj → projOrg (setMem s u o r) pj ≡ projOrg s pj
setMem-projOrg s u o r pj = refl

-- Freshness and allocation ---------------------------------------------------

-- SPECIALIZED: with counter domains, freshness means EXACTLY the next
-- counter value — deliberately stronger than mere nonmembership in the
-- entity domain.  Nonmembership follows (`fresh-not-exists`), and the
-- exactness is what makes the candidate exist after allocation
-- (`alloc-exists`): a merely-nonexistent candidate above the counter would
-- not.  A generic kernel with abstract reference domains would define
-- freshness as nonmembership and discharge the same two obligations.
Fresh : State → (k : EntityKind) → EntityRef k → Set
Fresh s k r = ix r ≡ count s k

fresh-not-exists : ∀ s k (r : EntityRef k) → Fresh s k r → ¬ Exists s r
fresh-not-exists s k r p q = <-irrefl (subst (λ n → n < count s k) p q)

-- Kind-dependent creation payload: a new Project must be born with its
-- organization attribute set (otherwise well-formedness could not survive
-- creation); Users and Organizations need nothing.  The payload comes from
-- the request's declared initializer (`Mithril.Effect.InitTerm`), never
-- from the allocator, which supplies only the candidate reference.
AllocInit : EntityKind → Set
AllocInit UserK    = ⊤
AllocInit OrgK     = ⊤
AllocInit ProjectK = EntityRef OrgK

alloc : (s : State) (k : EntityKind) → AllocInit k → State
alloc s UserK    _ = record s { users = suc (users s) }
alloc s OrgK     _ = record s { orgs = suc (orgs s) }
alloc s ProjectK o = record s { projects = suc (projects s)
                              ; projOrg  = updFun (projOrg s) (projects s) (ix o) }

alloc-count : ∀ s k i → count (alloc s k i) k ≡ suc (count s k)
alloc-count s UserK    i = refl
alloc-count s OrgK     i = refl
alloc-count s ProjectK i = refl

-- Allocation of kind k leaves every OTHER kind's counter EXACTLY
-- unchanged — not merely bounded.  Together with `alloc-count` this pins
-- the exact counter-vector change of creation: selected kind +1,
-- unrelated kinds untouched.
alloc-count-other : ∀ s k (i : AllocInit k) k′ → ¬ (k′ ≡ k)
                  → count (alloc s k i) k′ ≡ count s k′
alloc-count-other s UserK    i UserK    np = absurd (np refl)
alloc-count-other s UserK    i OrgK     np = refl
alloc-count-other s UserK    i ProjectK np = refl
alloc-count-other s OrgK     i UserK    np = refl
alloc-count-other s OrgK     i OrgK     np = absurd (np refl)
alloc-count-other s OrgK     i ProjectK np = refl
alloc-count-other s ProjectK i UserK    np = refl
alloc-count-other s ProjectK i OrgK     np = refl
alloc-count-other s ProjectK i ProjectK np = absurd (np refl)

-- A reference fresh in the pre-state exists in the post-state of alloc.
alloc-exists : ∀ s k i (r : EntityRef k) → Fresh s k r → Exists (alloc s k i) r
alloc-exists s k i r fr rewrite alloc-count s k i | fr = s≤s ≤-refl

-- Frame lemmas: allocation touches nothing that already existed.

alloc-mem : ∀ s k (i : AllocInit k) u o
          → membership (alloc s k i) u o ≡ membership s u o
alloc-mem s UserK    i u o = refl
alloc-mem s OrgK     i u o = refl
alloc-mem s ProjectK i u o = refl

alloc-projOrg : ∀ s k (i : AllocInit k) pj → pj < projects s
              → projOrg (alloc s k i) pj ≡ projOrg s pj
alloc-projOrg s UserK    i pj plt = refl
alloc-projOrg s OrgK     i pj plt = refl
alloc-projOrg s ProjectK i pj plt
  with updFun-cases (projOrg s) (projects s) (ix i) pj
... | inl (peq , _) = absurd (<-irrefl (subst (λ n → n < projects s) (sym peq) plt))
... | inr (_ , e)   = e

-- The newly created Project (at the pre-state's next index) stores EXACTLY
-- the supplied initializer as its organization attribute.
alloc-projOrg-new : ∀ s (o : EntityRef OrgK)
                  → projOrg (alloc s ProjectK o) (projects s) ≡ ix o
alloc-projOrg-new s o = updFun-point (projOrg s) (projects s) (ix o)

alloc-count-mono : ∀ s k (i : AllocInit k) k′ → count s k′ ≤ count (alloc s k i) k′
alloc-count-mono s UserK    i UserK    = ≤-step ≤-refl
alloc-count-mono s UserK    i OrgK     = ≤-refl
alloc-count-mono s UserK    i ProjectK = ≤-refl
alloc-count-mono s OrgK     i UserK    = ≤-refl
alloc-count-mono s OrgK     i OrgK     = ≤-step ≤-refl
alloc-count-mono s OrgK     i ProjectK = ≤-refl
alloc-count-mono s ProjectK i UserK    = ≤-refl
alloc-count-mono s ProjectK i OrgK     = ≤-refl
alloc-count-mono s ProjectK i ProjectK = ≤-step ≤-refl

alloc-preserves-exists : ∀ s k (i : AllocInit k) {k′} (r : EntityRef k′)
                       → Exists s r → Exists (alloc s k i) r
alloc-preserves-exists s k i {k′} r ex = ≤-trans ex (alloc-count-mono s k i k′)

-- Well-formedness ------------------------------------------------------------

-- The spike's state invariant.  `proj-ok` constrains only the meaningful
-- region of the total attribute function (indices below the counter);
-- `mem-user-ok`/`mem-org-ok` are the GLOBAL endpoint condition on the
-- relation: any tuple present at any index pair refers to existing
-- entities.
record WF (s : State) : Set where
  field
    proj-ok     : ∀ p → p < projects s → projOrg s p < orgs s
    mem-user-ok : ∀ u o r → membership s u o ≡ just r → u < users s
    mem-org-ok  : ∀ u o r → membership s u o ≡ just r → o < orgs s
open WF public

-- Conditional, state-level preservation lemmas ---------------------------------
--
-- These are NOT authorization: their validity premises are supplied, at the
-- authorized boundary, from a `Mithril.Effect.Capability`.

-- Validity of a creation payload: a new Project's organization must exist.
ValidInit : (s : State) (k : EntityKind) → AllocInit k → Set
ValidInit s UserK    _ = ⊤
ValidInit s OrgK     _ = ⊤
ValidInit s ProjectK o = Exists s o

-- SetRelation preserves well-formedness when both keys exist.
setMem-wf : ∀ s u o r → WF s → Exists s u → Exists s o → WF (setMem s u o r)
setMem-wf s u o r wf uex oex = record
  { proj-ok     = proj-ok wf
  ; mem-user-ok = user-ok
  ; mem-org-ok  = org-ok
  }
  where
  user-ok : ∀ u′ o′ r′
          → updMem (membership s) (ix u) (ix o) r u′ o′ ≡ just r′
          → u′ < users s
  user-ok u′ o′ r′ h with updMem-cases (membership s) (ix u) (ix o) r u′ o′
  ... | inl (p , _) = subst (λ n → n < users s) p uex
  ... | inr e       = mem-user-ok wf u′ o′ r′ (trans (sym e) h)

  org-ok : ∀ u′ o′ r′
         → updMem (membership s) (ix u) (ix o) r u′ o′ ≡ just r′
         → o′ < orgs s
  org-ok u′ o′ r′ h with updMem-cases (membership s) (ix u) (ix o) r u′ o′
  ... | inl (_ , (q , _)) = subst (λ n → n < orgs s) q oex
  ... | inr e             = mem-org-ok wf u′ o′ r′ (trans (sym e) h)

-- Creation preserves well-formedness when its payload is valid.
alloc-wf : ∀ s k (i : AllocInit k) → WF s → ValidInit s k i → WF (alloc s k i)
alloc-wf s UserK i wf iv = record
  { proj-ok     = proj-ok wf
  ; mem-user-ok = λ u o r h → ≤-step (mem-user-ok wf u o r h)
  ; mem-org-ok  = mem-org-ok wf
  }
alloc-wf s OrgK i wf iv = record
  { proj-ok     = λ p plt → ≤-step (proj-ok wf p plt)
  ; mem-user-ok = mem-user-ok wf
  ; mem-org-ok  = λ u o r h → ≤-step (mem-org-ok wf u o r h)
  }
alloc-wf s ProjectK i wf iv = record
  { proj-ok     = po
  ; mem-user-ok = mem-user-ok wf
  ; mem-org-ok  = mem-org-ok wf
  }
  where
  below : ∀ p → ¬ (projects s ≡ p) → p < suc (projects s) → p < projects s
  below p np plt with ≤→<⊎≡ (≤-pred plt)
  ... | inl q = q
  ... | inr q = absurd (np (sym q))

  po : ∀ p → p < suc (projects s)
     → updFun (projOrg s) (projects s) (ix i) p < orgs s
  po p plt with updFun-cases (projOrg s) (projects s) (ix i) p
  ... | inl (_ , e)  = subst (λ n → n < orgs s) (sym e) iv
  ... | inr (np , e) = subst (λ n → n < orgs s) (sym e) (proj-ok wf p (below p np plt))
