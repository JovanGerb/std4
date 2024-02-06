/-
Copyright (c) 2023 J. W. Gerbscheid. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: J. W. Gerbscheid
-/
import Std.Data.StateList
import Std.Data.List.Basic
import Lean.Meta

/-!
We define discrimination trees for the purpose of unifying local expressions with library results.

This implementation is based on the `DiscrTree` in Lean.
I document here what features are not in the original:

- The keys `Key.lam`, `Key.forall` and `Key.bvar` have been introduced in order to allow for
  matching under lambda and forall binders. `Key.lam` has arity 1 and indexes the body.
  `Key.forall` has arity 2 and indexes the domain and the body. The reason for not indexing the
  domain of a lambda expression is that it is usually already determined, for example in
  `∃ a : α, p`, which is `@Exists α fun a : α => p`, we don't want to index the domain `α` twice.
  In a forall expression it is necessary to index the domain, because in an implication `p → q`
  we need to index both `p` and `q`. `Key.bvar` works the same as `Key.fvar`, but stores the
  De Bruijn index to identify it.

  For example, this allows for more specific matching with the left hand side of
  `∑ i in range n, i = n * (n - 1) / 2`, which is indexed by
  `[⟨Finset.sum, 5⟩, ⟨Nat, 0⟩, ⟨Nat, 0⟩, *0, ⟨Finset.Range, 1⟩, *1, λ, ⟨#0, 0⟩]`.

- The key `Key.star` now takes a `Nat` identifier as an argument. For example,
  the library pattern `?a + ?a` is encoded as `[⟨Hadd.hadd, 6⟩, *0, *0, *0, *1, *2, *2]`.
  `*0` corresponds to the type of `a`, `*1` to the `Hadd` instance, and `*2` to `a`.
  This means that it will only match an expression `x + y` if `x` is definitionally equal to `y`.
  The matching algorithm requires that the same stars from the discrimination tree match with
  the same patterns in the lookup expression, and similarly requires that the same metavariables
  form the lookup expression match with the same pattern in the discrimination tree.

- The key `Key.opaque` has been introduced in order to index existential variables
  in lemmas like `Nat.exists_prime_and_dvd {n : ℕ} (hn : n ≠ 1) : ∃ p, Prime p ∧ p ∣ n`,
  where the part `Prime p` gets the pattern `[⟨Nat.Prime, 1⟩, ◾]`. (◾ represents `Key.opaque`)
  When matching, `Key.opaque` can only be matched by `Key.star`.

  Using the `WhnfCoreConfig` argument, it is possible to disable β-reduction and ζ-reduction.
  As a result, we may get a lambda expression applied to an argument or a let-expression.
  Since there is no support for indexing these, they will be indexed by `Key.opaque`.

- We keep track of the matching score of a unification.
  This score represents the number of keys that had to be the same for the unification to succeed.
  For example, matching `(1 + 2) + 3` with `add_comm` gives a score of 2,
  since the pattern of commutativity is [⟨Hadd.hadd, 6⟩, *0, *0, *0, *1, *2, *3],
  so matching `⟨Hadd.hadd, 6⟩` gives 1 point,
  and matching `*0` after its first appearence gives another point, but the third argument is an
  outParam, so this gets ignored. Similarly, matching it with `add_assoc` gives a score of 5.

- Patterns that have the potential to be η-reduced are put into the `RefinedDiscrTree` under all
  possible reduced key sequences. This is for terms of the form `fun x => f (?m x₁ .. xₙ)`, where
  `?m` is a metavariable, and one of `x₁, .., xₙ` in `x`.
  For example, the pattern `Continuous fun y => Real.exp (f y)])` is indexed by
  both `[⟨Continuous, 5⟩, *0, ⟨Real, 0⟩, *1, *2, λ, ⟨Real.exp⟩, *3]`
  and  `[⟨Continuous, 5⟩, *0, ⟨Real, 0⟩, *1, *2, ⟨Real.exp⟩]`
  so that it also comes up if you search with `Continuous Real.exp`.
  Similarly, `Continuous fun x => f x + g x` is indexed by
  both `[⟨Continuous, 1⟩, λ, ⟨Hadd.hadd, 6⟩, *0, *0, *0, *1, *2, *3]`
  and  `[⟨Continuous, 1⟩, ⟨Hadd.hadd, 5⟩, *0, *0, *0, *1, *2]`.

I have also made some changes in the implementation:

- Instead of directly converting from `Expr` to `Array Key` during insertion, and directly
  looking up from an `Expr` during lookup, I defined the intermediate structure `DTExpr`,
  which is a form of `Expr` that only contains information relevant for the discrimination tree.
  Each `Expr` is transformed into a `DTExpr` before insertion or lookup. For insertion there
  could be multiple `DTExpr` representations due to potential η-reductions as mentioned above.

TODO:

- The η-reduction case handling is a bit awkward and the implementation should probably be
  reworked, but it works like this.

- More thought could be put into the matching algorithm for non-trivial unifications.
  For example, when looking up the expression `?a + ?a`, there will only be results like
  `n + n = 2 * n` or `a + b = b + a`, but not like `n + 1 = n.succ`,
  even though this would still unify.

- Only reducible constants are reduced, so there are some terms with multiple
  representations, that should really be represented in the same way. e.g.
  - `fun x => x` and `id`.
  - `fun x => f (g x)` and `f ∘ g`.
  - `fun x => f x + g x` and `f + g`. Similar to `+`, all of
    `1`, `0`, `*`, `+ᵥ`, `•`, `^`, `-`, `⁻¹`, and `/` are defined point-wise on Pi-types.

  This can either be programmed on a case by case basis,
  or it can be designed to be extended dynamically.
  And the normalization could happen on either the `Expr` or `DTExpr` level.
  I have now made it so that the pattern `[λ, ⟨#0, 0⟩]` is always replaced by `[⟨id, 1⟩, ..]`,
  where the implicit argument of `id` is also indexed.

  Note that for each of these equivalences, they should not apply at the root, so that
  for example `Function.id_def : id = fun x => x` can still be used as a rewriting lemma.

- The reason why implicit arguments are not ignored by the discrimination tree is that they provide
  important type information. Because of this it seems more natural to index the types of
  expressions instead of indexing the implicit type arguments. Then each key would additionally
  index the type of that expression. So instead of indexing `?a + ?b` as
  `[⟨HAdd.hAdd, 6⟩, *0, *0, *0, *1, *2, *3]`, it would be indexed by something like
  `[(*0, ⟨HAdd.hAdd, 6⟩), _, _, _, _, (*0, *1), (*0, *2)]`.
  The advantage of this would be that there will be less duplicate indexing of types,
  because many functions index the types of their arguments and their return type
  with implicit arguments, meaning that types unnecessarily get indexed multiple times.
  This modification can be explored, but it could very well not be an improvement.

-/

open Lean Meta

namespace Std.RefinedDiscrTree

/-! ## Definitions -/

/-- Discrimination tree key. -/
inductive Key where
  /-- A metavariable. This key matches with anything. It stores an index. -/
  | star : Nat → Key
  /-- An opaque variable. This key only matches with itself or `Key.star`. -/
  | opaque : Key
  /-- A constant. It stores the name and the arity. -/
  | const : Name → Nat → Key
  /-- A free variable. It stores the `FVarId` and the arity. -/
  | fvar : FVarId → Nat → Key
  /-- A bound variable, from a lambda or forall binder.
  It stores the De Bruijn index and the arity. -/
  | bvar : Nat → Nat → Key
  /-- A literal. -/
  | lit : Literal → Key
  /-- A sort. Universe levels are ignored. -/
  | sort : Key
  /-- A lambda function. -/
  | lam : Key
  /-- A dependent arrow. -/
  | forall : Key
  /-- A projection. It stores the structure name, the projection index and the arity. -/
  | proj : Name → Nat → Nat → Key
  deriving Inhabited, BEq, Repr

private nonrec def Key.hash : Key → UInt64
  | .star i     => mixHash 7883 $ hash i
  | .opaque     => 342
  | .const n a  => mixHash 5237 $ mixHash (hash n) (hash a)
  | .fvar  n a  => mixHash 8765 $ mixHash (hash n) (hash a)
  | .bvar i a   => mixHash 4323 $ mixHash (hash i) (hash a)
  | .lit v      => mixHash 1879 $ hash v
  | .sort       => 2411
  | .lam        => 4742
  | .«forall»   => 9752
  | .proj s i a => mixHash (hash a) $ mixHash (hash s) (hash i)

instance : Hashable Key := ⟨Key.hash⟩

/-- Constructor index used for ordering `Key`.
Note that the index of the star pattern is 0, so that when looking up in a `Trie`,
we can look at the start of the sorted array for all `.star` patterns. -/
def Key.ctorIdx : Key → Nat
  | .star ..   => 0
  | .opaque .. => 1
  | .const ..  => 2
  | .fvar ..   => 3
  | .bvar ..   => 4
  | .lit ..    => 5
  | .sort      => 6
  | .lam       => 7
  | .forall    => 8
  | .proj ..   => 9

/-- The order on `Key` used in the `RefinedDiscrTree`. -/
private def Key.lt : Key → Key → Bool
  | .star i₁,       .star i₂       => i₁ < i₂
  | .const n₁ a₁,   .const n₂ a₂   => Name.quickLt n₁ n₂ || (n₁ == n₂ && a₁ < a₂)
  | .fvar f₁ a₁,    .fvar f₂ a₂    => Name.quickLt f₁.name f₂.name || (f₁ == f₂ && a₁ < a₂)
  | .bvar i₁ a₁,    .bvar i₂ a₂    => i₁ < i₂ || (i₁ == i₂ && a₁ < a₂)
  | .lit v₁,        .lit v₂        => v₁ < v₂
  | .proj s₁ i₁ a₁, .proj s₂ i₂ a₂ => Name.quickLt s₁ s₂ ||
    (s₁ == s₂ && (i₁ < i₂ || (i₁ == i₂ && a₁ < a₂)))
  | k₁,             k₂             => k₁.ctorIdx < k₂.ctorIdx

instance : LT Key := ⟨fun a b => Key.lt a b⟩
instance (a b : Key) : Decidable (a < b) := inferInstanceAs (Decidable (Key.lt a b))

private def Key.format : Key → Format
  | .star i                 => "*" ++ Std.format i
  | .opaque                 => "◾"
  | .const k a              => "⟨" ++ Std.format k ++ ", " ++ Std.format a ++ "⟩"
  | .fvar k a               => "⟨" ++ Std.format k.name ++ ", " ++ Std.format a ++ "⟩"
  | .lit (Literal.natVal v) => Std.format v
  | .lit (Literal.strVal v) => repr v
  | .sort                   => "sort"
  | .bvar i a               => "⟨" ++ "#" ++ Std.format i ++ ", " ++ Std.format a ++ "⟩"
  | .lam                    => "λ"
  | .forall                 => "∀"
  | .proj s i a             => "⟨" ++ Std.format s ++"."++ Std.format i ++", "++ Std.format a ++ "⟩"

instance : ToFormat Key := ⟨Key.format⟩

/-- Return the number of arguments that the `Key` takes. -/
def Key.arity : Key → Nat
  | .const _ a  => a
  | .fvar _ a   => a
  | .bvar _ a   => a
  | .lam        => 1
  | .forall     => 2
  | .proj _ _ a => 1 + a
  | _           => 0


/-- Discrimination tree trie. See `RefinedDiscrTree`. -/
inductive Trie (α : Type) where
  /-- Map from `Key` to `Trie`. Children is an `Array` of size at least 2,
  sorted in increasing order using `Key.lt`. -/
  | node (children : Array (Key × Trie α))
  /-- Sequence of nodes with only one child. `keys` is an `Array` of size at least 1. -/
  | path (keys : Array Key) (child : Trie α)
  /-- Leaf of the Trie. `values` is an `Array` of size at least 1. -/
  | values (vs : Array α)
instance : Inhabited (Trie α) := ⟨.node #[]⟩

/-- `Trie.path` constructor that only inserts the path if it is non-empty. -/
def Trie.mkPath (keys : Array Key) (child : Trie α) :=
  if keys.isEmpty then child else Trie.path keys child

/-- `Trie` constructor for a single value, taking the keys starting at index `i`. -/
def Trie.singleton (keys : Array Key) (value : α) (i : Nat) : Trie α :=
  mkPath keys[i:] (values #[value])

/-- `Trie.node` constructor for combining two `Key`, `Trie α` pairs. -/
def Trie.mkNode2 (k1 : Key) (t1 : Trie α) (k2 : Key) (t2 : Trie α) : Trie α :=
  if k1 < k2 then
    .node #[(k1, t1), (k2, t2)]
  else
    .node #[(k2, t2), (k1, t1)]

/-- Return the values from a `Trie α`, assuming that it is a leaf -/
def Trie.values! : Trie α → Array α
  | .values vs => vs
  | _ => panic! "expected .values constructor"

/-- Return the children of a `Trie α`, assuming that it is not a leaf.
The result is sorted by the `Key`'s -/
def Trie.children! : Trie α → Array (Key × Trie α)
| .node cs => cs
| .path ks c => #[(ks[0]!, mkPath ks[1:] c)]
| .values _ => panic! "did not expect .values constructor"

private partial def Trie.format [ToFormat α] : Trie α → Format
  | .node cs => Format.group $ Format.paren $
    "node" ++ Format.join (cs.toList.map fun (k, c) =>
      Format.line ++ Format.paren (Std.format k ++ " => " ++ format c))
  | .values vs => "values" ++ if vs.isEmpty then Format.nil else " " ++ Std.format vs
  | .path ks c => "path" ++ Std.format ks ++ Format.line ++ format c

instance [ToFormat α] : ToFormat (Trie α) := ⟨Trie.format⟩


/-- Discrimination tree. It is an index from expressions to values of type `α`. -/
structure _root_.Std.RefinedDiscrTree (α : Type) where
  /-- The underlying `PersistentHashMap` of a `RefinedDiscrTree`. -/
  root : PersistentHashMap Key (Trie α) := {}
instance : Inhabited (RefinedDiscrTree α) := ⟨{}⟩

private partial def format [ToFormat α] (d : RefinedDiscrTree α) : Format :=
  let (_, r) := d.root.foldl
    (fun (p : Bool × Format) k c =>
      (false,
        p.2 ++ (if p.1 then Format.nil else Format.line) ++
          Format.paren (Std.format k ++ " => " ++ Std.format c)))
    (true, Format.nil)
  Format.group r

instance [ToFormat α] : ToFormat (RefinedDiscrTree α) := ⟨format⟩


/-- `DTExpr` is a simplified form of `Expr`.
It is the intermediate step for converting from `Expr` to `Array Key`. -/
inductive DTExpr where
  /-- A metavariable. I optionally stores an `MVarId`. -/
  | star : Option MVarId → DTExpr
  /-- An opaque variable or a let-expression in the case `WhnfCoreConfig.zeta := false`. -/
  | opaque : DTExpr
  /-- A constant. It stores the name and the arguments. -/
  | const : Name → Array DTExpr → DTExpr
  /-- A free variable. It stores the `FVarId` and the argumenst -/
  | fvar : FVarId → Array DTExpr → DTExpr
  /-- A bound variable. It stores the De Bruijn index and the arguments -/
  | bvar : Nat → Array DTExpr → DTExpr
  /-- A literal. -/
  | lit : Literal → DTExpr
  /-- A sort. -/
  | sort : DTExpr
  /-- A lambda function. It stores the body. -/
  | lam : DTExpr → DTExpr
  /-- A dependent arrow. It stores the domain and body. -/
  | forall : DTExpr → DTExpr → DTExpr
  /-- A projection. It stores the structure name, projection index, struct body and arguments. -/
  | proj : Name → Nat → DTExpr → Array DTExpr → DTExpr
deriving Inhabited, BEq

private partial def DTExpr.format : DTExpr → Format
  | .star _                 => "*"
  | .opaque                 => "◾"
  | .const n as             => Std.format n ++ formatArgs as
  | .fvar n as             => Std.format n.name ++ formatArgs as
  | .bvar i as              => "#" ++ Std.format i  ++ formatArgs as
  | .lit (Literal.natVal v) => Std.format v
  | .lit (Literal.strVal v) => repr v
  | .sort                   => "Sort"
  | .lam b                  => "λ " ++ DTExpr.format b
  | .forall d b             => DTExpr.format d ++ " → " ++ DTExpr.format b
  | .proj _ i a as          => DTExpr.format a ++ "." ++ Std.format i ++ formatArgs as
where
  formatArgs (as : Array DTExpr) :=
    if as.isEmpty
      then .nil
      else " " ++ Format.paren (@Format.joinSep _ ⟨DTExpr.format⟩ as.toList ", ")

instance : ToFormat DTExpr := ⟨DTExpr.format⟩

/-- Return the size of the `DTExpr`. This is used for calculating the matching score when two
expressions are equal.
The score is not incremented at a lambda, which is so that the expressions
`∀ x, p[x]` and `∃ x, p[x]` get the same size. -/
partial def DTExpr.size : DTExpr → Nat
| .const _ args
| .fvar _ args
| .bvar _ args => args.foldl (init := 1) (· + ·.size)
| .lam b => b.size
| .forall d b => 1 + d.size + b.size
| _ => 1


/-! ## Encoding an Expr -/

/-- This state is used to turn the indexing by `MVarId` and `FVarId` in `DTExpr` into
indexing by `Nat` in `Key`. -/
private structure Flatten.State where
  stars : Array MVarId := #[]

private def getStar (mvarId? : Option MVarId) : StateM Flatten.State Nat :=
  modifyGet fun s =>
    match mvarId? with
    | some mvarId => match s.stars.findIdx? (· == mvarId) with
      | some idx => (idx, s)
      | none => (s.stars.size, { s with stars := s.stars.push mvarId })
    | none => (s.stars.size, { s with stars := s.stars.push ⟨.anonymous⟩ })

private partial def DTExpr.flattenAux (todo : Array Key) : DTExpr → StateM Flatten.State (Array Key)
  | .star i => return todo.push (.star (← getStar i))
  | .opaque => return todo.push .opaque
  | .const n as => as.foldlM flattenAux (todo.push (.const n as.size))
  | .fvar  f as => as.foldlM flattenAux (todo.push (.fvar f as.size))
  | .bvar  i as => as.foldlM flattenAux (todo.push (.bvar i as.size))
  | .lit l => return todo.push (.lit l)
  | .sort  => return todo.push .sort
  | .lam b => flattenAux (todo.push .lam) b
  | .«forall» d b => do flattenAux (← flattenAux (todo.push .forall) d) b
  | .proj n i e as => do as.foldlM flattenAux (← flattenAux (todo.push (.proj n i as.size)) e)

/-- Given a `DTExpr`, return the linearized encoding in terms of `Key`,
which is used for `RefinedDiscrTree` indexing. -/
def DTExpr.flatten (e : DTExpr) (initCapacity := 16) : Array Key :=
  (DTExpr.flattenAux (.mkEmpty initCapacity) e).run' {}



/-- Return true if `e` is one of the following
- A nat literal (numeral)
- `Nat.zero`
- `Nat.succ x` where `isNumeral x`
- `OfNat.ofNat _ x _` where `isNumeral x` -/
private partial def isNumeral (e : Expr) : Bool :=
  if e.isNatLit then true
  else
    let f := e.getAppFn
    if !f.isConst then false
    else
      let fName := f.constName!
      if fName == ``Nat.succ && e.getAppNumArgs == 1 then isNumeral e.appArg!
      else if fName == ``OfNat.ofNat && e.getAppNumArgs == 3 then isNumeral (e.getArg! 1)
      else if fName == ``Nat.zero && e.getAppNumArgs == 0 then true
      else false

/-- Return `some n` if `e` is definitionally equal to the natural number `n`. -/
private partial def toNatLit? (e : Expr) : Option Literal :=
  if isNumeral e then
    if let some n := loop e then
      some (.natVal n)
    else
      none
  else
    none
where
  loop (e : Expr) : OptionT Id Nat := do
    let f := e.getAppFn
    match f with
    | .lit (.natVal n) => return n
    | .const fName .. =>
      if fName == ``Nat.succ && e.getAppNumArgs == 1 then
        let r ← loop e.appArg!
        return r+1
      else if fName == ``OfNat.ofNat && e.getAppNumArgs == 3 then
        loop (e.getArg! 1)
      else if fName == ``Nat.zero && e.getAppNumArgs == 0 then
        return 0
      else
        failure
    | _ => failure

/-- Reduction procedure for the `RefinedDiscrTree` indexing. -/
partial def reduce (e : Expr) (config : WhnfCoreConfig) : MetaM Expr := do
  let e ← whnfCore e config
  match (← unfoldDefinition? e) with
  | some e => reduce e config
  | none => match e.etaExpandedStrict? with
    | some e => reduce e config
    | none   => return e



/-- Check whether the expression is represented by `Key.star`. -/
def isStar : Expr → Bool
  | .mvar .. => true
  | .app f _ => isStar f
  | _ => false

/-- Check whether the expression is represented by `Key.star` and has `arg` as an argument. -/
def isStarWithArg (arg : Expr) : Expr → Bool
  | .app f a => if a == arg then isStar f else isStarWithArg arg f
  | _ => false

private partial def DTExpr.hasLooseBVarsAux (i : Nat) : DTExpr → Bool
  | .const  _ as   => as.any (hasLooseBVarsAux i)
  | .fvar   _ as   => as.any (hasLooseBVarsAux i)
  | .bvar j as     => j ≥ i || as.any (hasLooseBVarsAux i)
  | .proj _ _ a as => a.hasLooseBVarsAux i || as.any (hasLooseBVarsAux i)
  | .forall d b    => d.hasLooseBVarsAux i || b.hasLooseBVarsAux (i+1)
  | .lam b         => b.hasLooseBVarsAux (i+1)
  | _              => false

/-- Return `true` if `e` contains a loose bound variable. -/
def DTExpr.hasLooseBVars (e : DTExpr) : Bool :=
  e.hasLooseBVarsAux 0


namespace MkDTExpr

private structure Context where
  /-- Variables that come from a lambda or forall binder.
  The list index gives the De Bruijn index. -/
  bvars : List FVarId := []
  /-- Variables that come from a lambda that has been removed via η-reduction. -/
  unbvars : List FVarId := []
  config : WhnfCoreConfig
  fvarInContext : FVarId → Bool

/-- Return for each argument whether it should be ignored. -/
def getIgnores (fn : Expr) (args : Array Expr) : MetaM (Array Bool) := do
  let mut fnType ← inferType fn
  let mut result := Array.mkEmpty args.size
  let mut j := 0
  for i in [:args.size] do
    unless fnType matches .forallE .. do
      fnType ← whnfD (fnType.instantiateRevRange j i args)
      j := i
    let .forallE _ d b bi := fnType | throwError m! "expected function type {indentExpr fnType}"
    fnType := b
    result := result.push (← isIgnoredArg args[i]! d bi)
  return result
where
  /-- Return whether the argument should be ignored. -/
  isIgnoredArg (arg domain : Expr) (binderInfo : BinderInfo) : MetaM Bool := do
    if domain.isOutParam then
      return true
    match binderInfo with
    | .instImplicit => return true
    | .implicit
    | .strictImplicit => return !(← isType arg)
    | .default => isProof arg

private def mkLams (lambdas : List Expr) (e : DTExpr) : DTExpr :=
  match lambdas with
  | [] => e
  | _ :: lambdas => mkLams lambdas (.lam e)

/-- Return the encoding of `e` as a `DTExpr`.
If `root = false`, then `e` is a strict sub expression of the original expression. -/
partial def mkDTExprAux (e : Expr) (root : Bool) (lambdas : List Expr)
    : ReaderT Context MetaM DTExpr := do
  let e ← reduce e (← read).config
  Expr.withApp e fun fn args => do

  let argDTExpr (arg : Expr) (ignore : Bool) : ReaderT Context MetaM DTExpr :=
    if ignore then pure (.star none) else mkDTExprAux arg false []

  let argDTExprs : ReaderT Context MetaM (Array DTExpr) := do
    let ignores ← getIgnores fn args
    args.mapIdxM fun i arg =>
      argDTExpr arg ignores[i]!

  match fn with
  | .const c _ =>
    unless root do
      if let some v := toNatLit? e then
        return mkLams lambdas $ .lit v
    return mkLams lambdas $ .const c (← argDTExprs)
  | .proj s i a =>
    let a ← argDTExpr a (isClass (← getEnv) s)
    return mkLams lambdas $ .proj s i a (← argDTExprs)
  | .fvar fvarId =>
    let c ← read
    if let some idx := c.bvars.findIdx? (· == fvarId) then
      /- we index `fun x => x` as `id` when not at the root -/
      if idx == 0 && args.isEmpty && !root then
        if let d :: lambdas := lambdas then
          return mkLams lambdas $ .const ``id #[← mkDTExprAux d false []]
      return mkLams lambdas $ .bvar idx (← argDTExprs)
    if c.fvarInContext fvarId then
      return mkLams lambdas $ .fvar fvarId (← argDTExprs)
    else
      return .opaque /- note that `[λ,◾]` is equivalent to `[◾]` -/
  | .mvar mvarId =>
    if (e matches .app ..) then
      return .star none /- note that `[λ,*]` is equivalent to `[*]` for non-repeating stars. -/
    else
      return mkLams lambdas $ .star (some mvarId)

  | .lam _ d b _ =>
    unless args.isEmpty do
      return .opaque
    mkBinderDTExpr d b root (d :: lambdas)

  | .forallE _ d b _ =>
    return mkLams lambdas $ .forall (← mkDTExprAux d false []) (← mkBinderDTExpr d b false [])
  | .lit v      => return mkLams lambdas $ .lit v
  | .sort _     => return mkLams lambdas $ .sort
  | .letE ..    => return .opaque
  | _           => unreachable!

where
  /-- Introduce a bound variable of type `domain` to the context, instantiate it in `e`,
  and then return all encodings of `e` as a `DTExpr` -/
  mkBinderDTExpr (domain e : Expr) (root : Bool) (lambdas : List Expr)
      : ReaderT Context MetaM DTExpr := do
    withLocalDeclD `_a domain fun fvar =>
      withReader (fun c => { c with bvars := fvar.fvarId! :: c.bvars }) do
        mkDTExprAux (e.instantiate1 fvar) root lambdas

private abbrev M := ReaderT Context $ StateListT (AssocList Expr DTExpr) MetaM

/-
Caching values is a bit dangerous, because when two expressions are be equal and they live under
a different number of binders, then the resulting De Bruijn indices are offset.
In practice, getting a `.bvar` in a `DTExpr` is very rare, so we exclude such values from the cache.
-/
instance : MonadCache Expr DTExpr M where
  findCached? e := do
    let c ← get
    return c.find? e
  cache e e' :=
    if e'.hasLooseBVars then
      return
    else
      modify (·.insert e e')

/-- Return all encodings of `e` as a `DTExpr`, taking possible η-reductions into account.
If `root = false`, then `e` is a strict sub expression of the original expression. -/
partial def mkDTExprsAux (e : Expr) (root : Bool) (lambdas : List Expr) : M DTExpr := do
  let e ← reduce e (← read).config
  (do
  let _ :: lambdas := lambdas | failure
  let .app f a := e | failure
  let bvar :: bvars := (← read).bvars | failure
  guard (isStarWithArg (.fvar bvar) a)
  withReader (fun c => {c with bvars, unbvars := bvar :: c.unbvars}) do
    mkDTExprsAux f root lambdas
  ) <|>
  Expr.withApp e fun fn args => do

  let argDTExpr (arg : Expr) (ignore : Bool) : M DTExpr :=
    if ignore then pure (.star none) else mkDTExprsAux arg false []

  let argDTExprs : M (Array DTExpr) := do
    let ignores ← getIgnores fn args
    args.mapIdxM fun i arg =>
      argDTExpr arg ignores[i]!

  match fn with
  | .const c _ =>
    unless root do
      if let some v := toNatLit? e then
        return mkLams lambdas $ .lit v
    return mkLams lambdas $ .const c (← argDTExprs)
  | .proj s i a =>
    let a ← argDTExpr a (isClass (← getEnv) s)
    return mkLams lambdas $ .proj s i a (← argDTExprs)
  | .fvar fvarId =>
    let c ← read
    if let some idx := c.bvars.findIdx? (· == fvarId) then
      /- we index `fun x => x` as `id` when not at the root -/
      if idx == 0 && args.isEmpty && !root then
        if let d :: lambdas := lambdas then
          return mkLams lambdas $ .const ``id #[← mkDTExprsAux d false []]
      return mkLams lambdas $ .bvar idx (← argDTExprs)
    if c.unbvars.contains fvarId then
      failure
    if c.fvarInContext fvarId then
      return mkLams lambdas $ .fvar fvarId (← argDTExprs)
    else
      return .opaque /- note that `[λ,◾]` is equivalent to `[◾]` -/
  | .mvar mvarId =>
    if (e matches .app ..) then
      return .star none /- note that `[λ,*]` is equivalent to `[*]` for non-repeating stars. -/
    else
      return mkLams lambdas $ .star (some mvarId)

  | .lam _ d b _ => do
    unless args.isEmpty do
      return .opaque
    checkCache fn fun _ => mkBinderDTExprs d b root (d :: lambdas)

  | .forallE _ d b _ =>
    return mkLams lambdas $ .forall (← mkDTExprsAux d false []) (← mkBinderDTExprs d b false [])
  | .lit v      => return mkLams lambdas $ .lit v
  | .sort _     => return mkLams lambdas .sort
  | .letE ..    => return .opaque
  | _           => unreachable!

where
  /-- Introduce a bound variable of type `domain` to the context, instantiate it in `e`,
  and then return all encodings of `e` as a `DTExpr` -/
  mkBinderDTExprs (domain e : Expr) (root : Bool) (lambdas : List Expr) : M DTExpr := do
    withLocalDeclD `_a domain fun fvar =>
      withReader (fun c => { c with bvars := fvar.fvarId! :: c.bvars }) do
        mkDTExprsAux (e.instantiate1 fvar) root lambdas

end MkDTExpr

/-- Return the encoding of `e` as a `DTExpr`.

Warning: to account for potential η-reductions of `e`, use `mkDTExprs` instead.

The argument `fvarInContext` allows you to specify which free variables in `e` will still be
in the context when the `RefinedDiscrTree` is being used for lookup.
It should return true only if the `RefinedDiscrTree` is built and used locally. -/
def mkDTExpr (e : Expr) (config : WhnfCoreConfig)
    (fvarInContext : FVarId → Bool := fun _ => false) : MetaM DTExpr :=
  withReducible do (MkDTExpr.mkDTExprAux e true [] |>.run {config, fvarInContext})

/-- Similar to `mkDTExpr`.
Return all encodings of `e` as a `DTExpr`, taking potential further η-reductions into account. -/
def mkDTExprs (e : Expr) (config : WhnfCoreConfig)
    (fvarInContext : FVarId → Bool := fun _ => false) : MetaM (List DTExpr) :=
  withReducible do (MkDTExpr.mkDTExprsAux e true [] |>.run {config, fvarInContext}).run' {}


/-! ## Inserting intro a RefinedDiscrTree -/

variable {α : Type}

/-- If `vs` contains an element `v'` such that `v == v'`, then replace `v'` with `v`.
Otherwise, push `v`.
See issue #2155
Recall that `BEq α` may not be Lawful.
-/
private def insertInArray [BEq α] (vs : Array α) (v : α) : Array α :=
  loop 0
where
  loop (i : Nat) : Array α :=
    if h : i < vs.size then
      if v == vs[i] then
        vs.set ⟨i,h⟩ v
      else
        loop (i+1)
    else
      vs.push v
termination_by loop i => vs.size - i

/-- Insert the value `v` at index `keys : Array Key` in a `Trie`. -/
partial def insertInTrie [BEq α] (keys : Array Key) (v : α) (i : Nat) : Trie α → Trie α
  | .node cs =>
      let k := keys[i]!
      let c := Id.run $ cs.binInsertM
        (fun a b => a.1 < b.1)
        (fun (k', s) => (k', insertInTrie keys v (i+1) s))
        (fun _ => (k, Trie.singleton keys v (i+1)))
        (k, default)
      .node c
  | .values vs =>
      .values (insertInArray vs v)
  | .path ks c => Id.run do
    for n in [:ks.size] do
      let k1 := keys[i+n]!
      let k2 := ks[n]!
      if k1 != k2 then
        let shared := ks[:n]
        let rest := ks[n+1:]
        return .mkPath shared (.mkNode2 k1 (.singleton keys v (i+n+1)) k2 (.mkPath rest c))
    return .path ks (insertInTrie keys v (i + ks.size) c)

/-- Insert the value `v` at index `keys : Array Key` in a `RefinedDiscrTree`.

Warning: to accound for η-reduction, an entry may need to be added at multiple indexes,
so it is recommended to use `RefinedDiscrTree.insert` for insertion. -/
def insertInRefinedDiscrTree [BEq α] (d : RefinedDiscrTree α) (keys : Array Key) (v : α)
  : RefinedDiscrTree α :=
  let k := keys[0]!
  match d.root.find? k with
  | none =>
    let c := .singleton keys v 1
    { root := d.root.insert k c }
  | some c =>
    let c := insertInTrie keys v 1 c
    { root := d.root.insert k c }

/-- Insert the value `v` at index `e : DTExpr` in a `RefinedDiscrTree`.

Warning: to accound for η-reduction, an entry may need to be added at multiple indexes,
so it is recommended to use `RefinedDiscrTree.insert` for insertion. -/
def insertDTExpr [BEq α] (d : RefinedDiscrTree α) (e : DTExpr) (v : α) : RefinedDiscrTree α :=
  insertInRefinedDiscrTree d e.flatten v

/-- Insert the value `v` at index `e : Expr` in a `RefinedDiscrTree`.
The argument `fvarInContext` allows you to specify which free variables in `e` will still be
in the context when the `RefinedDiscrTree` is being used for lookup.
It should return true only if the `RefinedDiscrTree` is built and used locally. -/
def insert [BEq α] (d : RefinedDiscrTree α) (e : Expr) (v : α) (config : WhnfCoreConfig := {})
  (fvarInContext : FVarId → Bool := fun _ => false) : MetaM (RefinedDiscrTree α) := do
  let keys ← mkDTExprs e config fvarInContext
  return keys.foldl (insertDTExpr · · v) d



/-! ## Matching with a RefinedDiscrTree

We use a very simple unification algorithm. For all star/metavariable patterns in the
`RefinedDiscrTree` and in the target, we store the assignment, and when it is assigned again,
we check that it is the same assignment.
-/

namespace GetUnify

/-- If `k` is a key in `children`, return the corresponding `Trie α`. Otherwise return `none`. -/
def findKey (children : Array (Key × Trie α)) (k : Key) : Option (Trie α) :=
  (·.2) <$> children.binSearch (k, default) (fun a b => a.1 < b.1)

private structure Context where
  unify : Bool
  config : WhnfCoreConfig

private structure State where
  /-- Score representing how good the match is. -/
  score : Nat := 0
  /-- Metavariable assignments for the `Key.star` patterns in the `RefinedDiscrTree`. -/
  starAssignments : HashMap Nat DTExpr := {}
  /-- Metavariable assignments for the `Expr.mvar` in the expression. -/
  mvarAssignments : HashMap MVarId (Array Key) := {}


private abbrev M := ReaderT Context $ StateListM State

/-- Return all values from `x` in an array, together with their scores. -/
private def M.run (unify : Bool) (config : WhnfCoreConfig) (x : M (Trie α))
  : Array (Array α × Nat) :=
  ((x.run { unify, config }).run {}).toArray.map (fun (t, s) => (t.values!, s.score))

/-- Increment the score by `n`. -/
private def incrementScore (n : Nat) : M Unit :=
  modify fun s => { s with score := s.score + n }

/-- Log a metavariable assignment in the `State`. -/
private def insertStarAssignment (n : Nat) (e : DTExpr) : M Unit :=
  modify fun s => { s with starAssignments := s.starAssignments.insert n e }

/-- Log a metavariable assignment in the `State`. -/
private def assignMVar (mvarId : MVarId) (e : Array Key) : M Unit := do
  let { mvarAssignments, .. } ← get
  match mvarAssignments.find? mvarId with
  | some e' => guard (e == e')
  | none =>
    modify fun s => { s with mvarAssignments := s.mvarAssignments.insert mvarId e }

/-- Return the possible `Trie α` that match with `n` metavariable. -/
partial def skipEntries (t : Trie α) (skipped : Array Key) : Nat → M (Array Key × Trie α)
  | 0      => pure (skipped, t)
  | skip+1 =>
    t.children!.foldr (init := failure) fun (k, c) x =>
      (skipEntries c (skipped.push k) (skip + k.arity)) <|> x
/-- Return the possible `Trie α` that match with anything.
We add 1 to the matching score when the key is `.opaque`,
since this pattern is "harder" to match with. -/
def matchTargetStar (mvarId? : Option MVarId) (t : Trie α) : M (Trie α) := do
  let (keys, t) ← t.children!.foldr (init := failure) fun (k, c) x => (do
    if k == .opaque then
      incrementScore 1
    skipEntries c #[k] k.arity
    ) <|> x
  if let some mvarId := mvarId? then
    assignMVar mvarId keys
  return t

/-- Return the possible `Trie α` that come from a `Key.star`,
while keeping track of the `Key.star` assignments. -/
def matchTreeStars (e : DTExpr) (t : Trie α) : M (Trie α) := do
  let {starAssignments, ..} ← get
  let mut result := failure
  /- The `Key.star` are at the start of the `t.children!`,
  so this loops through all of them. -/
  for (k, c) in t.children! do
    let .star i := k | break
    if let some assignment := starAssignments.find? i then
      if e == assignment then
        result := (incrementScore e.size *> pure c) <|> result
    else
      result := (insertStarAssignment i e *> pure c) <|> result
  result

mutual
  /-- Return the possible `Trie α` that match with `e`. -/
  partial def matchExpr (e : DTExpr) (t : Trie α) : M (Trie α) := do
    match ← exactMatch e (findKey t.children!) with
      | .inr mvarId? => matchTargetStar mvarId? t
      | .inl result  => matchTreeStars e t <|> result

  /-- If the head of `e` is not a metavariable,
  return the possible `Trie α` that exactly match with `e`. -/
  partial def exactMatch (e : DTExpr) (find? : Key → Option (Trie α))
    : M (M (Trie α) ⊕ Option MVarId) := do

    let findKey (k : Key) (x : Trie α → M (Trie α) := pure) (score := 1) :=
      pure $ .inl $ match find? k with
        | none => failure
        | some trie => do
          incrementScore score
          x trie

    let matchArgs (args : Array DTExpr) : Trie α → M (Trie α) :=
      args.foldlM (fun t e => matchExpr e t)

    match e with
    | .star mvarId?     => return if (← read).unify then .inr mvarId? else .inl failure
    | .opaque           => findKey .opaque
    | .const c args     => findKey (.const c args.size) (matchArgs args)
    | .fvar fvarId args => findKey (.fvar fvarId args.size) (matchArgs args)
    | .bvar i args      => findKey (.bvar i args.size) (matchArgs args)
    | .lit v            => findKey (.lit v)
    | .sort             => findKey .sort
    | .lam b            => findKey .lam (matchExpr b) 0
    | .forall d b       => findKey .forall (matchExpr d >=> matchExpr b)
    | .proj n i a args  => findKey (.proj n i args.size) (matchExpr a >=> matchArgs args)

end

end GetUnify

/--
Return the results from the `RefinedDiscrTree` that match the given expression,
together with their matching scores, in decreasing order of score.

Each entry of type `Array α × Nat` corresponds to one pattern.

If `unify := false`, then metavariables in `e` are treated as opaque variables.
This is for when you don't want the matched keys to instantiate metavariables in `e`.

If `allowRootStar := false`, then we don't allow `e` or the matched key in `d`
to be a star pattern. -/
partial def getMatchWithScore (d : RefinedDiscrTree α) (e : Expr) (unify : Bool)
    (config : WhnfCoreConfig) (allowRootStar : Bool := false) : MetaM (Array (Array α × Nat)) := do
  let e ← mkDTExpr e config
  return (·.qsort (·.2 > ·.2)) <| (do
    match ← GetUnify.exactMatch e d.root.find? with
    | .inr _ =>
      if allowRootStar then
        d.root.foldl (init := failure) fun x k c => (do
              if k == Key.opaque then
                GetUnify.incrementScore 1
              Prod.snd <$> GetUnify.skipEntries c #[k] k.arity) <|> x
      else
        failure
    | .inl result =>
      (if allowRootStar then
        if let some c := d.root.find? (.star 0) then
          pure c
        else
          failure
      else
        failure)
      <|> result
    ).run unify config


variable {m : Type → Type} [Monad m]

/-- Apply a monadic function to the array of values at each node in a `RefinedDiscrTree`. -/
partial def Trie.mapArraysM (t : RefinedDiscrTree.Trie α) (f : Array α → m (Array β)) :
    m (Trie β) := do
  match t with
  | .node children =>
    return .node (← children.mapM fun (k, t') => do pure (k, ← t'.mapArraysM f))
  | .values vs =>
    return .values (← f vs)
  | .path ks c =>
    return .path ks (← c.mapArraysM f)

/-- Apply a monadic function to the array of values at each node in a `RefinedDiscrTree`. -/
def mapArraysM (d : RefinedDiscrTree α) (f : Array α → m (Array β)) : m (RefinedDiscrTree β) :=
  return { root := ← d.root.mapM (·.mapArraysM f) }

/-- Apply a function to the array of values at each node in a `RefinedDiscrTree`. -/
def mapArrays (d : RefinedDiscrTree α) (f : Array α → Array β) : RefinedDiscrTree β :=
  d.mapArraysM (m := Id) f
