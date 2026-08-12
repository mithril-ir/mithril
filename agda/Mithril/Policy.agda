{-# OPTIONS --safe #-}

-- Mithril Agda spike: principals, typed policy terms and total evaluation.
--
-- GENERIC IN SHAPE: terms are indexed by an authentication level, a typed
-- argument context and a result type; evaluation is total by construction
-- (no partiality, no relation unwrap).  SPECIALIZED: the attribute
-- projection, relation lookup and relation presence forms are fixed to the
-- spike's schema (Project.organization, Membership) instead of ranging over
-- declared attributes/relations.
--
-- Evaluation is total even for requests naming nonexistent ("ghost")
-- references; such evaluations are semantically meaningless and are never
-- accepted as authorization: capability construction in `Mithril.Effect`
-- requires request validity (`ValidCaller`, `ValidArgs`, `WF`) alongside
-- the policy equation.

module Mithril.Policy where

open import Mithril.Base
open import Mithril.Core

-- Authentication level and environments --------------------------------------

data Auth : Set where
  anon authed : Auth

-- An authenticated environment carries the actor.
record AuthedEnv : Set where
  constructor mkAuthed
  field actor : EntityRef UserK
open AuthedEnv public

-- An anonymous environment is the unit type: an actor is unconstructable
-- from it BY TYPE — there is no field to read, no optional/null value, and
-- no runtime check involved.
--
-- SCOPE OF THIS CLAIM: it excludes DIRECT access to the principal
-- (`actorT`/the environment field) from anonymous terms.  It does not — and
-- Core v0 does not claim to — prevent an ordinary valid User ARGUMENT from
-- having the same extensional value as the authenticated actor, nor such an
-- argument being consumed by anonymous-level effects or outputs.  No
-- provenance tracking or non-interference property is claimed.  (See
-- `Mithril.Spike.actor-value-flows-as-argument`.)
PEnv : Auth → Set
PEnv anon   = ⊤
PEnv authed = AuthedEnv

-- Typed argument contexts (de Bruijn) ----------------------------------------

infixl 5 _▸_

data Ctx : Set where
  ∅   : Ctx
  _▸_ : Ctx → Ty → Ctx

data Var : Ctx → Ty → Set where
  here  : ∀ {Γ t} → Var (Γ ▸ t) t
  there : ∀ {Γ t u} → Var Γ t → Var (Γ ▸ u) t

data Args : Ctx → Set where
  ∅   : Args ∅
  _▸_ : ∀ {Γ t} → Args Γ → Val t → Args (Γ ▸ t)

lookupArg : ∀ {Γ t} → Args Γ → Var Γ t → Val t
lookupArg (γ ▸ v) here      = v
lookupArg (γ ▸ v) (there x) = lookupArg γ x

-- Terms ----------------------------------------------------------------------

-- `Term a Γ t`: a policy/effect expression of type t, over typed arguments Γ,
-- at authentication level a.  `actorT` only exists at `authed`; there is no
-- way to form it in an anonymous term.  There are no entity literals: an
-- entity-typed term denotes only values reachable from the arguments, the
-- actor, or attribute paths.  Under a valid request every such value exists
-- in the pre-state (`eval-valid`), so no term of a valid request evaluates
-- to a fresh allocation candidate (`fresh-not-evaluable`).
data Term : Auth → Ctx → Ty → Set where
  arg      : ∀ {a Γ t} → Var Γ t → Term a Γ t
  actorT   : ∀ {Γ} → Term authed Γ (entity UserK)
  boolL    : ∀ {a Γ} → Bool → Term a Γ bool
  unitL    : ∀ {a Γ} → Term a Γ unit
  roleL    : ∀ {a Γ} → Role → Term a Γ role
  justT    : ∀ {a Γ t} → Term a Γ t → Term a Γ (maybe t)
  nothingT : ∀ {a Γ t} → Term a Γ (maybe t)
  -- total attribute projection (statically finite path step)
  orgOfT   : ∀ {a Γ} → Term a Γ (entity ProjectK) → Term a Γ (entity OrgK)
  -- relation lookup returning Maybe (no unwrap form exists)
  memT     : ∀ {a Γ} → Term a Γ (entity UserK) → Term a Γ (entity OrgK)
           → Term a Γ (maybe role)
  -- relation presence
  hasMemT  : ∀ {a Γ} → Term a Γ (entity UserK) → Term a Γ (entity OrgK)
           → Term a Γ bool
  -- typed equality (total on the whole universe)
  eqT      : ∀ {a Γ t} → Term a Γ t → Term a Γ t → Term a Γ bool
  -- ordered comparison; on Maybe, absence is bottom
  leqT     : ∀ {a Γ t} → Ordered t → Term a Γ t → Term a Γ t → Term a Γ bool
  andT     : ∀ {a Γ} → Term a Γ bool → Term a Γ bool → Term a Γ bool
  orT      : ∀ {a Γ} → Term a Γ bool → Term a Γ bool → Term a Γ bool
  notT     : ∀ {a Γ} → Term a Γ bool → Term a Γ bool

-- Total evaluation: no Maybe in the result, no failure, no partiality.
eval : ∀ {a Γ t} → State → PEnv a → Args Γ → Term a Γ t → Val t
eval s ρ γ (arg x)          = lookupArg γ x
eval s ρ γ actorT           = actor ρ
eval s ρ γ (boolL b)        = b
eval s ρ γ unitL            = tt
eval s ρ γ (roleL r)        = r
eval s ρ γ (justT e)        = just (eval s ρ γ e)
eval s ρ γ nothingT         = nothing
eval s ρ γ (orgOfT e)       = ref (projOrg s (ix (eval s ρ γ e)))
eval s ρ γ (memT eu eo)     = lookupMem s (eval s ρ γ eu) (eval s ρ γ eo)
eval s ρ γ (hasMemT eu eo)  = isJust (lookupMem s (eval s ρ γ eu) (eval s ρ γ eo))
eval s ρ γ (eqT {t = t} e₁ e₂) = eqVal t (eval s ρ γ e₁) (eval s ρ γ e₂)
eval s ρ γ (leqT o e₁ e₂)   = leqVal o (eval s ρ γ e₁) (eval s ρ γ e₂)
eval s ρ γ (andT e₁ e₂)     = eval s ρ γ e₁ && eval s ρ γ e₂
eval s ρ γ (orT e₁ e₂)      = eval s ρ γ e₁ || eval s ρ γ e₂
eval s ρ γ (notT e)         = notB (eval s ρ γ e)

-- Principal modes, policies and callers --------------------------------------

data Mode : Set where
  anyPrincipal authenticatedOnly : Mode

-- The authentication level available to an action's EFFECTS (and outputs):
-- an AnyPrincipal action may be executed by an anonymous caller, so its
-- effects live at `anon` and cannot reference the actor, by type.
modeAuth : Mode → Auth
modeAuth anyPrincipal      = anon
modeAuth authenticatedOnly = authed

-- An AnyPrincipal policy has separate anonymous and authenticated branches;
-- an AuthenticatedOnly policy has a single authenticated branch.
data Policy (Γ : Ctx) : Mode → Set where
  anyP  : Term anon Γ bool → Term authed Γ bool → Policy Γ anyPrincipal
  authP : Term authed Γ bool → Policy Γ authenticatedOnly

-- Who is actually calling.  An anonymous caller only exists for
-- AnyPrincipal actions: `Caller authenticatedOnly` has exactly the
-- authenticated constructor.
data Caller : Mode → Set where
  anonC : Caller anyPrincipal
  authC : ∀ {m} → EntityRef UserK → Caller m

checkPolicy : ∀ {Γ m} → State → Args Γ → Caller m → Policy Γ m → Bool
checkPolicy s γ anonC     (anyP pa pu) = eval s tt γ pa
checkPolicy s γ (authC u) (anyP pa pu) = eval s (mkAuthed u) γ pu
checkPolicy s γ (authC u) (authP p)    = eval s (mkAuthed u) γ p

-- The environment an action's effects run in.  For AnyPrincipal actions this
-- is the anonymous environment even for an authenticated caller: effects of
-- AnyPrincipal actions cannot depend on the actor.
effEnv : ∀ {m} → Caller m → PEnv (modeAuth m)
effEnv anonC                      = tt
effEnv {anyPrincipal}      (authC u) = tt
effEnv {authenticatedOnly} (authC u) = mkAuthed u

-- Validity: values, arguments, environments, callers -------------------------

-- A value is valid in a state when every entity reference in it exists.
ValidVal : State → (t : Ty) → Val t → Set
ValidVal s bool       _        = ⊤
ValidVal s unit       _        = ⊤
ValidVal s (entity k) r        = Exists s r
ValidVal s role       _        = ⊤
ValidVal s (maybe t)  nothing  = ⊤
ValidVal s (maybe t)  (just v) = ValidVal s t v

ValidArgs : ∀ {Γ} → State → Args Γ → Set
ValidArgs s ∅ = ⊤
ValidArgs {Γ ▸ t} s (γ ▸ v) = ValidArgs s γ × ValidVal s t v

ValidEnv : ∀ {a} → State → PEnv a → Set
ValidEnv {anon}   s _ = ⊤
ValidEnv {authed} s ρ = Exists s (actor ρ)

ValidCaller : ∀ {m} → State → Caller m → Set
ValidCaller s anonC     = ⊤
ValidCaller s (authC u) = Exists s u

effEnv-valid : ∀ {m} (s : State) (c : Caller m)
             → ValidCaller s c → ValidEnv s (effEnv c)
effEnv-valid s anonC                      cv = tt
effEnv-valid {anyPrincipal}      s (authC u) cv = tt
effEnv-valid {authenticatedOnly} s (authC u) cv = cv

lookupArg-valid : ∀ {Γ t} (s : State) (γ : Args Γ) (x : Var Γ t)
                → ValidArgs s γ → ValidVal s t (lookupArg γ x)
lookupArg-valid s (γ ▸ v) here      γv = snd γv
lookupArg-valid s (γ ▸ v) (there x) γv = lookupArg-valid s γ x (fst γv)

-- Evaluation sends valid inputs to valid values in a well-formed state.
-- This covers every term form uniformly — in particular ALL the
-- entity-typed forms: arguments (`arg`), the actor (`actorT`, where the
-- authentication level makes it available) and attribute paths (`orgOfT`,
-- which leans on WF.proj-ok).
eval-valid : ∀ {a Γ t} (s : State) (ρ : PEnv a) (γ : Args Γ) (e : Term a Γ t)
           → WF s → ValidEnv s ρ → ValidArgs s γ
           → ValidVal s t (eval s ρ γ e)
eval-valid s ρ γ (arg x)         wf ρv γv = lookupArg-valid s γ x γv
eval-valid s ρ γ actorT          wf ρv γv = ρv
eval-valid s ρ γ (boolL b)       wf ρv γv = tt
eval-valid s ρ γ unitL           wf ρv γv = tt
eval-valid s ρ γ (roleL r)       wf ρv γv = tt
eval-valid s ρ γ (justT e)       wf ρv γv = eval-valid s ρ γ e wf ρv γv
eval-valid s ρ γ nothingT        wf ρv γv = tt
eval-valid s ρ γ (orgOfT e)      wf ρv γv =
  proj-ok wf (ix (eval s ρ γ e)) (eval-valid s ρ γ e wf ρv γv)
eval-valid s ρ γ (memT eu eo)    wf ρv γv
  with lookupMem s (eval s ρ γ eu) (eval s ρ γ eo)
... | nothing = tt
... | just _  = tt
eval-valid s ρ γ (hasMemT eu eo) wf ρv γv = tt
eval-valid s ρ γ (eqT e₁ e₂)     wf ρv γv = tt
eval-valid s ρ γ (leqT o e₁ e₂)  wf ρv γv = tt
eval-valid s ρ γ (andT e₁ e₂)    wf ρv γv = tt
eval-valid s ρ γ (orT e₁ e₂)     wf ρv γv = tt
eval-valid s ρ γ (notT e)        wf ρv γv = tt

-- Under a well-formed state and a valid environment and arguments, NO
-- entity-reference term — argument, actor where available, or attribute
-- path — can evaluate to a reference that is fresh for the pre-state:
-- evaluation of a valid request only reaches entities that exist.
fresh-not-evaluable :
  ∀ {a Γ k} (s : State) (ρ : PEnv a) (γ : Args Γ)
    (e : Term a Γ (entity k)) (r : EntityRef k)
  → WF s → ValidEnv s ρ → ValidArgs s γ
  → Fresh s k r
  → ¬ (eval s ρ γ e ≡ r)
fresh-not-evaluable {k = k} s ρ γ e r wf ρv γv fr eq =
  fresh-not-exists s k r fr
    (subst (λ x → Exists s x) eq (eval-valid s ρ γ e wf ρv γv))
