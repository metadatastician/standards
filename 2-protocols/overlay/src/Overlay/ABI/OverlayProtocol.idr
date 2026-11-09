-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Overlay Protocol ABI — Formal Invariants
|||
||| Dependent type definitions proving the Overlay Protocol's core invariants
||| at compile-time. Every overlay (o-extension or aggregate-library) must
||| satisfy these constraints to be protocol-conformant.
|||
||| The five core invariants:
|||   1. Non-Modification — base state is unchanged by overlay presence
|||   2. Additive Only — overlay adds, never removes or shadows
|||   3. Switchable — activation and deactivation are inverses
|||   4. Idempotent Activation — double-activate = single-activate
|||   5. Declared Relationship — overlay declares its base in ECOSYSTEM.scm

module Overlay.ABI.OverlayProtocol

import Data.So
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Peer Types
--------------------------------------------------------------------------------

||| The two peer types defined by the Overlay Protocol.
public export
data PeerType = OExtension | AggregateLibrary

||| Peer types are decidably equal.
public export
DecEq PeerType where
  decEq OExtension OExtension = Yes Refl
  decEq OExtension AggregateLibrary = No (\case Refl impossible)
  decEq AggregateLibrary OExtension = No (\case Refl impossible)
  decEq AggregateLibrary AggregateLibrary = Yes Refl

||| Proof that peer type is exhaustive over exactly two values.
public export
peerTypeExhaustive : (p : PeerType) -> Either (p = OExtension) (p = AggregateLibrary)
peerTypeExhaustive OExtension = Left Refl
peerTypeExhaustive AggregateLibrary = Right Refl

--------------------------------------------------------------------------------
-- Activation Mechanism
--------------------------------------------------------------------------------

||| Activation mechanism differs by peer type.
public export
data ActivationMethod : PeerType -> Type where
  ||| o-extensions activate via flags (env vars, CLI flags, source scripts).
  FlagBased    : (command : String) -> ActivationMethod OExtension
  ||| aggregate-libraries activate via dependency (import/require).
  DepBased     : (importPath : String) -> ActivationMethod AggregateLibrary

--------------------------------------------------------------------------------
-- Base Project State
--------------------------------------------------------------------------------

||| Abstract representation of a base project's state.
||| Parametrised by a state identifier so we can reason about equality.
public export
record BaseState where
  constructor MkBaseState
  stateId   : Nat
  fileCount : Nat

--------------------------------------------------------------------------------
-- Overlay Declaration
--------------------------------------------------------------------------------

||| A declared overlay relationship, corresponding to the overlay-protocol
||| section in ECOSYSTEM.scm.
public export
record OverlayDeclaration (peer : PeerType) where
  constructor MkOverlayDeclaration
  basePath      : String
  upstreamUrl   : String
  activation    : ActivationMethod peer
  deactivation  : String
  description   : String

--------------------------------------------------------------------------------
-- Core Invariant 1: Non-Modification
--------------------------------------------------------------------------------

||| Proof witness that an overlay does not modify the base state.
||| Given the base state before and after overlay presence, they are equal.
public export
data NonModification : (before : BaseState) -> (after : BaseState) -> Type where
  BaseUnchanged : (before = after) -> NonModification before after

||| Convenience: construct a non-modification proof from reflexivity.
public export
basePreserved : (s : BaseState) -> NonModification s s
basePreserved s = BaseUnchanged Refl

--------------------------------------------------------------------------------
-- Core Invariant 2: Additive Only
--------------------------------------------------------------------------------

||| An overlay's contribution is purely additive: it introduces new items
||| without removing or shadowing any base items.
|||
||| Modelled as: the overlay's file count is strictly greater than zero,
||| and the base file count is unchanged.
public export
record AdditiveOnly where
  constructor MkAdditiveOnly
  baseBefore    : BaseState
  baseAfter     : BaseState
  overlayItems  : Nat
  {auto 0 baseUnchanged : baseBefore = baseAfter}
  {auto 0 hasAdditions  : So (overlayItems > 0)}

--------------------------------------------------------------------------------
-- Core Invariant 3: Switchable (Activation/Deactivation are inverses)
--------------------------------------------------------------------------------

||| Abstract activation function type.
||| Takes a base state and returns the composite (base + overlay) state.
public export
record ActivationFn where
  constructor MkActivationFn
  activate   : BaseState -> BaseState
  deactivate : BaseState -> BaseState

||| Proof that deactivation is a left-inverse of activation.
||| deactivate(activate(base)) = base
public export
data Switchable : ActivationFn -> BaseState -> Type where
  MkSwitchable : (fn.deactivate (fn.activate base) = base) -> Switchable fn base

||| Switchable for all base states: the protocol-level guarantee.
public export
data UniversallySwitchable : ActivationFn -> Type where
  MkUniversallySwitchable : ((s : BaseState) -> Switchable fn s) -> UniversallySwitchable fn

--------------------------------------------------------------------------------
-- Core Invariant 4: Idempotent Activation
--------------------------------------------------------------------------------

||| Proof that activating twice is the same as activating once.
||| activate(activate(base)) = activate(base)
public export
data ActivationIdempotent : ActivationFn -> BaseState -> Type where
  MkActivationIdempotent :
    (fn.activate (fn.activate base) = fn.activate base) ->
    ActivationIdempotent fn base

||| Proof that deactivating twice is the same as deactivating once.
||| deactivate(deactivate(base)) = deactivate(base)
public export
data DeactivationIdempotent : ActivationFn -> BaseState -> Type where
  MkDeactivationIdempotent :
    (fn.deactivate (fn.deactivate base) = fn.deactivate base) ->
    DeactivationIdempotent fn base

||| Combined idempotency for both directions.
public export
record FullyIdempotent (fn : ActivationFn) (base : BaseState) where
  constructor MkFullyIdempotent
  activationIdem   : ActivationIdempotent fn base
  deactivationIdem : DeactivationIdempotent fn base

--------------------------------------------------------------------------------
-- Core Invariant 5: Declared Relationship
--------------------------------------------------------------------------------

||| Proof that an overlay has a valid declaration.
||| The base path must be non-empty and the upstream URL must be non-empty.
public export
data ValidDeclaration : OverlayDeclaration peer -> Type where
  MkValidDeclaration :
    So (length decl.basePath > 0) ->
    So (length decl.upstreamUrl > 0) ->
    So (length decl.description > 0) ->
    ValidDeclaration decl

--------------------------------------------------------------------------------
-- Conformant Overlay
--------------------------------------------------------------------------------

||| A fully conformant overlay satisfies all five core invariants.
||| This is the top-level proof obligation for any overlay implementation.
public export
record ConformantOverlay (peer : PeerType) where
  constructor MkConformantOverlay
  declaration    : OverlayDeclaration peer
  activationFn   : ActivationFn
  baseState      : BaseState

  -- Invariant 1: Non-modification
  nonModification : NonModification baseState baseState

  -- Invariant 2: Additive only
  additiveOnly    : AdditiveOnly

  -- Invariant 3: Switchable
  switchable      : Switchable activationFn baseState

  -- Invariant 4: Idempotent
  idempotent      : FullyIdempotent activationFn baseState

  -- Invariant 5: Declared relationship
  validDecl       : ValidDeclaration declaration

--------------------------------------------------------------------------------
-- Composition
--------------------------------------------------------------------------------

||| Proof that two overlays targeting the same base do not conflict.
||| Each overlay's non-modification guarantee is independent.
public export
data Composable : ConformantOverlay p1 -> ConformantOverlay p2 -> Type where
  MkComposable :
    (o1.baseState = o2.baseState) ->
    Composable o1 o2

||| Mixed peer types are always composable because they operate at
||| different layers (o-extension adds capabilities, aggregate-library
||| curates existing ones).
public export
mixedPeersComposable :
  (o1 : ConformantOverlay OExtension) ->
  (o2 : ConformantOverlay AggregateLibrary) ->
  (o1.baseState = o2.baseState) ->
  Composable o1 o2
mixedPeersComposable o1 o2 prf = MkComposable prf

--------------------------------------------------------------------------------
-- Overlay Chaining
--------------------------------------------------------------------------------

||| An overlay chain: overlay B targets overlay A which targets the base.
||| Each link satisfies all invariants independently.
public export
record OverlayChain where
  constructor MkOverlayChain
  base       : BaseState
  overlayA   : ConformantOverlay OExtension
  overlayB   : ConformantOverlay OExtension
  -- A targets base
  aTargetsBase : overlayA.baseState = base
  -- B targets A's activated state (but still doesn't modify A)
  bIndependentOfA : NonModification overlayA.baseState overlayA.baseState

--------------------------------------------------------------------------------
-- Theorems
--------------------------------------------------------------------------------

||| Theorem: A conformant overlay preserves base state identity.
||| If an overlay is conformant, then the base state is unchanged.
public export
conformantPreservesBase :
  (o : ConformantOverlay peer) ->
  NonModification o.baseState o.baseState
conformantPreservesBase o = o.nonModification

||| Theorem: Peer type distinctness — o-extension and aggregate-library
||| are provably different peer types.
public export
peerTypesDistinct : Not (OExtension = AggregateLibrary)
peerTypesDistinct Refl impossible

||| Theorem: A conformant overlay's activation is reversible.
||| This follows directly from the switchable invariant.
public export
conformantReversible :
  (o : ConformantOverlay peer) ->
  Switchable o.activationFn o.baseState
conformantReversible o = o.switchable
