# Decision 0008: Deterministic real-symmetric eigensolver

Status: accepted for Milestone 3

## Context

The scalar one-loop potential is a spectral function of a real symmetric
field-dependent mass matrix. Milestone 3 needs all eigenvalues, including
negative, zero, repeated, and near-repeated values. Later invariant derivative
rules may also require eigenvectors, but no scientific result may depend on an
arbitrary eigenvalue label or eigenvector sign.

The initial safe reference backend must remain dependency-free,
allocation-free during evaluation, and bitwise reproducible for repeated
execution of the same kernel, inputs, operation, and workspace. A failure to
converge must be distinguishable from a plausible partial spectrum.

## Decision

Phaser implements an in-repository cyclic Jacobi eigensolver for real symmetric
`f64` matrices. Sizes zero, one, and two use direct paths; sizes three and above
use deterministic cyclic sweeps.

This is a numerical identity operation, not a symbolic equality test.
Eigensolver tolerances may decide convergence and choose stable formulas. As
required by
[Scalar One-Loop Effective Potential §6](../calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md#6-zero-modes-and-derivatives),
they MUST NOT clip a negative eigenvalue to zero, merge numerical values into a
symbolic degeneracy, or discard multiplicity.

### Input and scaling

The operation accepts a structurally real-symmetric matrix. The instruction and
storage specification must either represent one triangle as authoritative or
establish exact mirrored entries before evaluation; the eigensolver does not
average asymmetric input under a tolerance.

Every input entry is checked before an output is published. A NaN or infinity
produces the point-level `non_finite` outcome. Size zero succeeds with an empty
spectrum. An exactly zero matrix succeeds with exact zero eigenvalues and, when
requested, the identity eigenvector matrix.

An exactly diagonal matrix of any size is the no-rotation case. After finite
checks it retains its entries without global scaling, executes the same bounded
convergence and postcondition path for its dimension, and publishes the stably
sorted diagonal with the corresponding identity columns. This preserves an
isolated representable diagonal entry even when another diagonal entry differs
from it by the complete `f64` dynamic range.

For any other finite matrix, the solver selects a power-of-two scale from the
maximum absolute entry and diagonalizes the scaled matrix. The largest scaled
entry lies in a fixed normal range. Power-of-two scaling avoids overflow in norm
and rotation calculations and introduces no avoidable rounding into normal
inputs. Eigenvalues are rescaled only after convergence; a non-finite rescaled
result produces `non_finite`.

This makes very large, very small, and mixed-scale finite matrices ordinary
inputs when their eigenvalues remain representable. It does not promise
relative accuracy for information already lost when a tiny entry is combined
with a much larger `f64` entry.

### Small sizes

For size one, the sole diagonal entry is the sole eigenvalue and the
eigenvector matrix is \([1]\).

For size two, the scaled matrix

\[
\begin{pmatrix}a&b\\b&d\end{pmatrix}
\]

uses

\[
m=\frac{a+d}{2},\qquad
r=\operatorname{hypot}\left(\frac{a-d}{2},b\right).
\]

The mathematical eigenvalues are \(m-r\) and \(m+r\), but the implementation
does not form a cancellation-prone smaller root that way. It uses a scale-safe
`hypot`, applies the stable rotation rule below, and takes the two updated
diagonal entries as the eigenvalues. An already diagonal matrix returns its
diagonal entries directly. This avoids both squaring unscaled entries and
discarding a representable small eigenvalue through the final subtraction.

### Cyclic sweeps and rotations

Each complete sweep visits every upper-triangular pair in the fixed lexical
order

```text
(0,1), (0,2), ..., (0,n-1), (1,2), ..., (n-2,n-1).
```

No hash, allocation, magnitude sort, or backend scheduling decision changes
this order. An exactly zero off-diagonal entry is skipped; every other visited
entry receives one rotation.

For a pivot block with entries \(a_{pp}\), \(a_{pq}\), and \(a_{qq}\), define

\[
\delta=\frac{a_{qq}-a_{pp}}{2}.
\]

If \(\delta=0\), choose \(t=1\). Otherwise choose

\[
t=
\frac{a_{pq}}
{\delta+\operatorname{copysign}
(\operatorname{hypot}(\delta,a_{pq}),\delta)}.
\]

Then

\[
c=\frac{1}{\sqrt{1+t^2}},\qquad s=tc.
\]

This is the stable Jacobi root with \(|t|\leq1\); the scaled operands and
scale-safe `hypot` avoid overflow in its construction. The implementation
updates the two diagonal entries using

\[
a'_{pp}=a_{pp}-t a_{pq},\qquad
a'_{qq}=a_{qq}+t a_{pq},
\]

sets the pivot off-diagonal pair to exact zero, and updates remaining matrix and
eigenvector entries in a fixed operand order. Backends may not reassociate those
updates under the reproducible policy.

The working matrix's Frobenius norm is measured with a scale-safe fixed-order
sum. After each complete sweep, convergence is reached when

\[
\lVert\operatorname{offdiag}(A)\rVert_F
\leq
8n\epsilon_{64}\lVert A\rVert_F.
\]

The solver performs at most

\[
\max(12,8n)
\]

complete sweeps. Reaching that bound without convergence produces
`nonconvergent`; no diagonal of the partially reduced matrix is published as a
spectrum.

### Ordering and postconditions

Successful eigenvalues are sorted in ascending numerical order by a stable
sort. Eigenvector columns receive the same permutation. Equal eigenvalues retain
their pre-sort column order.

When eigenvectors are produced, each column has a deterministic sign: find the
largest absolute component, choosing the lowest row on a tie, and make that
component nonnegative. This convention supports reproducibility and debugging;
it does not give an eigenvector or an index scientific identity. Spectral values
and derivatives remain invariant under eigenvalue reordering, rotations inside
a degenerate subspace, and eigenvector sign.

Before publication, all requested eigenvalues and eigenvectors must be finite.
For the unmodified scaled input \(A\), eigenvector matrix \(Q\), and diagonal
\(\Lambda\), the solver checks

\[
\lVert AQ-Q\Lambda\rVert_F
\leq64n\epsilon_{64}\lVert A\rVert_F
\]

and

\[
\lVert Q^TQ-I\rVert_F
\leq64n\epsilon_{64}.
\]

The reductions use fixed iteration order and scale-safe norm accumulation.
Failure of either postcondition is `nonconvergent`, not a successful
low-accuracy result. Eigenvalue-only callers may omit retained eigenvectors from
their public result, but the implementation must retain enough transformation
state to enforce an equivalent residual postcondition.

### Workspace and publication

All point-count- and matrix-size-dependent storage is reported through the
existing exact Potential Kernel workspace query. As required by
[Potential Kernel §13](../architecture/POTENTIAL_KERNEL.md#13-workspace), the
layout accounts for:

- the scaled symmetric working matrix;
- eigenvalues;
- eigenvectors or equivalent transformation state required by the operation;
- fixed-order norm and residual scratch; and
- alignment and checked size arithmetic for every subregion.

The compiled operation records the matrix dimension, so the query returns an
exact byte count rather than an asymptotic estimate. Exact-size workspace
succeeds, one byte less fails before evaluation, and no user-sized scratch is
placed implicitly on the stack. `evaluate` allocates no memory.

The operation computes entirely in caller-owned workspace and publishes
eigenvalues, eigenvectors, and dependent spectral outputs only after
convergence, finite checks, and postconditions succeed. `non_finite` and
`nonconvergent` therefore cannot expose a partial spectrum.

## Alternatives

LAPACK symmetric eigensolvers were not selected. Adopting LAPACK would add an
external numerical-library, ABI, version, licensing, packaging, and
platform-support obligation. It would also require a reviewed adapter for exact
caller-owned workspace and make same-target reproducibility depend on an
additional implementation. These are integration costs, not a claim that every
LAPACK implementation allocates or cannot be isolated safely.

Apple Accelerate was not selected because it adds the same numerical-library
boundary while being platform-specific. It could not be the sole implementation
on Phaser's Linux and macOS support matrix, and different platform backends
would make bitwise same-kernel behavior harder to define.

Analytic characteristic polynomials beyond size two were rejected. Cubic and
quartic formulas are fragile near repeated roots, do not extend to general
model size, and would create a second ordering and branch contract.

Householder reduction followed by QR, divide-and-conquer, and bisection-based
solvers remain viable future performance choices. They are more complex than
cyclic Jacobi for the small dense scalar matrices that establish Milestone 3,
and they would need the same workspace, determinism, residual, and oracle
contracts.

## Consequences

The initial implementation is simple enough to audit against the exact-spectrum
catalog accepted by
[Decision 0007](0007-milestone-3-oracle.md). It naturally preserves
multiplicity and handles indefinite matrices without a positive-semidefinite
assumption.

Cyclic Jacobi performs \(O(n^3)\) work and stores \(O(n^2)\) matrix and
transformation state. That is appropriate for the initial small dense scalar
sector, not a permanent performance claim for large models. Benchmarks must
precede any replacement.

Sorting and eigenvector sign normalization are deterministic presentation
choices. Invariant spectral differentiation remains mandatory at degeneracies;
the conventions do not license differentiating a sorted eigenvalue label.

This decision adds no dependency and changes no public ABI. The instruction-set
and lifecycle specifications must materialize the matrix storage, statuses, and
point-atomic publication rules before implementation.

## Revisit when

Revisit if representative scalar sectors make cyclic Jacobi a measured
bottleneck, if the sweep bound rejects valid matrices within the supported
conditioning regime, if another scalar type is introduced, or if a supported
platform provides a numerical library whose dependency, workspace,
reproducibility, and residual contracts are explicitly approved. Any replacement
must remain differential-tested against this safe implementation and the
independent oracle rather than merely reproducing its output order.
