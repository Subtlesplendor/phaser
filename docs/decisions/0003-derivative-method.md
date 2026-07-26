# Decision 0003: Exact symbolic differentiation before lowering

Status: accepted for Milestone 2

## Context

Milestone 2 must provide gradient and Hessian capabilities for the tree-level
potential with respect to background coordinates.
[Potential Kernel §12.2](../architecture/POTENTIAL_KERNEL.md) permits five
methods — differentiation of the Typed Value IR before lowering, forward-mode
automatic differentiation, analytic numerical-operation rules, a validated
hybrid, or an explicitly selected finite-difference method — and mandates none.
It names forward-mode automatic differentiation "an initial candidate, not a
mandated solution".

What the architecture does require is narrower: a derivative capability MUST NOT
silently fall back to finite differences, the method used MUST be recorded in
kernel metadata, and spectral derivatives SHOULD be expressed through invariant
matrix or spectral operations rather than by differentiating an eigenvalue
labeling procedure.

Differentiating an interned directed acyclic graph symbolically and running
forward-mode automatic differentiation are the same recurrence: one local rule
per node kind, with each node's derivative expressed in terms of its children
and their derivatives. They differ in when the recurrence runs and what it
leaves behind. The exponential growth associated with symbolic differentiation
is a property of tree-shaped computer-algebra representations that copy
subtrees; on an interned graph one directional derivative adds a number of nodes
proportional to the graph size.

## Decision

Phaser differentiates the Typed Value IR exactly and symbolically before
lowering. Derivatives are ordinary Typed Value IR in the same arena, lowered by
the same kernel path as values, and requiring no derivative-specific opcode.

Phaser 0.1 implements no evaluation-time automatic differentiation. There are no
dual-number slots, no parallel derivative opcode set, and no derivative mode in
the interpreter.

Finite differences remain available only as an explicitly selected capability
and as an independent test oracle at well-conditioned points, never as a silent
fallback.

Each contribution is differentiated separately so that loop order and provenance
survive differentiation.

## Consequences

Derivatives are exportable, inspectable, and directly comparable against the
`tree_gradient` and `tree_hessian` identities carried by the conformance
fixtures. Kernel metadata records the method with no additional machinery.

Cost grows with the background dimension: a gradient requires one directional
derivative per coordinate and a Hessian scales as the square of the coordinate
count, each multiplied by graph size. This is comfortable for the
one- and two-coordinate conformance fixtures and for the low-dimensional
background spaces the architecture anticipates.

At higher loop orders the objects to differentiate are not polynomials. The
relevant rules stay local: a logarithm differentiates to \(u'/u\), and an
invariant spectral operation differentiates as
\(\partial\,\mathrm{tr}f(M)=\mathrm{tr}\bigl(f'(M)\,\partial M\bigr)\), which is
expressed in the same spectral vocabulary the artifact already uses. This is the
invariant formulation the architecture prefers, and it avoids the persistent
eigenvector labels that differentiating through an eigensolver would require
near the exact and near degeneracies the conformance fixtures already contain.

## Alternatives

Evaluation-time forward-mode automatic differentiation was rejected. It requires
threading dual arithmetic through every instruction and a parallel opcode set,
it makes derivatives uninspectable and unexportable, and at higher loop orders
it pushes toward differentiating an eigensolver, which
[Potential Kernel §12.3](../architecture/POTENTIAL_KERNEL.md) warns is not by
itself a sufficient contract near degeneracies.

Reverse-mode differentiation was rejected for Milestone 2 as premature. It would
reduce gradient cost from linear to constant in the coordinate count, which is
not a benefit at one or two coordinates.

Finite differences as the primary method were rejected because the architecture
forbids them as an unrequested fallback and because they would forfeit the exact
agreement the Milestone 2 exit criteria require.

## Revisit when

Revisit this decision if measured derivative-graph size becomes a material cost
for a realistic model — the expected trigger is Hessian growth at higher loop
order with many background coordinates, in which case the response is
build-time reverse-mode differentiation for gradients rather than
evaluation-time automatic differentiation — or if a later milestone introduces
an operation whose derivative rule cannot be expressed symbolically in the
Typed Value IR.

Milestone 2 measures and records derivative-graph node counts so that this
trigger is evaluated against data. `zig build bench` reports them.

The first measurement, on the Milestone 2 conformance models:

| Model | Coordinates | Value only | Plus gradient | Plus Hessian |
|---|---:|---:|---:|---:|
| \(\phi^4\) | 1 | 15 | 30 | 43 |
| multi-scalar | 2 | 61 | 124 | 184 |

Growth is well below the bound this decision assumed. A naive accounting would
predict \((1+n+n^2)\) copies of the source graph, which is 427 nodes for the
two-coordinate model against the 184 observed. Interning is the reason: the
directional derivatives of one graph share most of their structure, and the
mixed partials share more again.

The trigger is therefore further away than the reasoning above suggested, and
build-time reverse mode is not warranted by any model Phaser currently
supports.
