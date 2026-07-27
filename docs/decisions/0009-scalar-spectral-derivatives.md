# Decision 0009: Scalar spectral derivatives

Status: accepted for Milestone 3

## Context

The scalar one-loop contribution is the invariant matrix function

\[
V^{(1)}(b)=\operatorname{Tr}\Phi_{\mu_R}(A(b)),
\qquad
A(b)=\mathcal M^2(b),
\]

where

\[
\Phi_{\mu}(x)=
\frac{x^2}{64\pi^2}
\left[
\operatorname{Log}\left(\frac{x}{\mu^2}\right)-\frac32
\right].
\]

Milestone 3 requires background gradients and Hessians. Differentiating
numerically sorted eigenvalue labels is not an acceptable method: labels can
exchange at a crossing, and eigenvectors are non-unique up to sign and rotations
inside a degenerate eigenspace. Those presentation choices must not affect a
scientific derivative.

For example,

\[
A(b)=
\begin{pmatrix}
1&b\\
b&1
\end{pmatrix}
\]

has the smooth invariant value
\(\Phi(1+b)+\Phi(1-b)\). A sorted eigensolver instead presents the eigenvalues
as \(1-|b|\) and \(1+|b|\). Differentiating either sorted label at \(b=0\)
introduces a false cusp even though the spectral trace has zero first derivative
and second derivative \(2\Phi''(1)\).

The architecture therefore already requires an invariant spectral derivative,
but the precise algorithm, close-eigenvalue evaluation, and zero-mode decision
were deferred. Those choices affect scientific status, reproducibility, and the
workspace layout and must be fixed before implementation.

## Decision

Phaser implements the first two background derivatives of the scalar one-loop
spectral trace through the specialized Fréchet derivative of a real-symmetric
matrix function. This is not a general matrix-function framework. It is the
closed analytic operation required by formula version
`scalar-vacuum-msbar/1`.

Let

\[
A_i=\frac{\partial A}{\partial b_i},
\qquad
A_{ij}=\frac{\partial^2 A}{\partial b_i\partial b_j},
\qquad
A=Q\Lambda Q^T.
\]

Define

\[
G_i=Q^TA_iQ,
\qquad
H_{ij}=Q^TA_{ij}Q.
\]

For every nonzero real \(x\),

\[
\Phi'_\mu(x)=
\frac{x}{32\pi^2}
\left[
\operatorname{Log}\left(\frac{x}{\mu^2}\right)-1
\right],
\]

using the same principal branch as the value. Its continuous zero limit is
\(\Phi'_\mu(0)=0\).

The gradient is

\[
\frac{\partial V^{(1)}}{\partial b_i}
=
\sum_a \Phi'_\mu(\lambda_a)(G_i)_{aa}.
\]

The Hessian is

\[
\frac{\partial^2 V^{(1)}}{\partial b_i\partial b_j}
=
\sum_a \Phi'_\mu(\lambda_a)(H_{ij})_{aa}
+
\sum_{a,b}
\Phi_\mu'^{[1]}(\lambda_a,\lambda_b)
(G_i)_{ab}(G_j)_{ba},
\]

where

\[
\Phi_\mu'^{[1]}(x,y)=
\begin{cases}
\dfrac{\Phi'_\mu(x)-\Phi'_\mu(y)}{x-y},&x\ne y,\\[6pt]
\Phi''_\mu(x),&x=y\ne0.
\end{cases}
\]

The formula includes both ordered pairs. No additional factor of two is
inserted for off-diagonal entries.

### Degenerate eigenspaces

The derivative operation groups consecutive sorted eigenvalues into
deterministic same-sign clusters when their adjacent separation is at most

\[
\tau=8n\epsilon_{64}\lVert A\rVert_F.
\]

Clustering is transitive in ascending spectrum order. Exact zero eigenvalues
form a separate zero cluster. Zero is never clustered with a nonzero
eigenvalue, and positive and negative eigenvalues are never clustered together.
The rule therefore cannot clip or reclassify a negative eigenvalue.

Each nonzero cluster uses one representative formed as a fixed-order running
mean. Starting with its first value, member \(k\) in stored order updates the
representative as
\(\bar\lambda_k=\bar\lambda_{k-1}
 +(\lambda_k-\bar\lambda_{k-1})/k\).
Same-sign clustering keeps the subtraction scale-safe, and the update avoids
the overflow risk of a direct sum.

\(\Phi'\) is evaluated once at the representative and used for every member.
The divided difference within a cluster is
\(\Phi''\) at that representative. Between clusters it uses their
representatives. Consequently every coefficient is constant on a degenerate
block, so rotating the eigenvectors inside that block cannot change the
gradient or Hessian.

This is a numerical stability classification, not symbolic equality. A
nonzero clustered eigenvalue remains nonzero in the value, spectrum,
provenance, and zero-mode policy.

### Stable divided differences

For same-sign nonzero representatives \(x\) and \(y\), define

\[
m=\frac{x+y}{2},\qquad
d=\frac{x-y}{2},\qquad
r=\frac{d}{m}.
\]

When \(|r|\le1/16\), the real component is evaluated without subtracting two
nearby \(\Phi'\) values:

\[
\operatorname{Re}\Phi_\mu'^{[1]}(x,y)
=
\frac{1}{32\pi^2}
\left[
\log\left(\frac{|m|}{\mu^2}\right)
-
\sum_{k=1}^{8}\frac{r^{2k}}{(2k)(2k+1)}
\right].
\]

The fixed eight-term series ends at \(r^{16}\). Its imaginary component is
zero for a positive pair and \(1/(32\pi)\) for a negative pair. For a
same-sign pair outside this range, and for opposite-sign or zero/nonzero pairs,
the evaluator uses the direct complex divided difference in fixed operand
order. An exactly equal nonzero pair uses \(\Phi''_\mu(x)\) directly.

### Exact zero modes

Only an eigenvalue whose computed `f64` value is exactly zero enters the
zero-mode rule. No tolerance changes the sign or zero classification of a
spectrum entry.

The gradient applies \(\Phi'_\mu(0)=0\) before forming a logarithm.
A zero/nonzero divided difference is finite and is evaluated from
\(\Phi'_\mu(0)=0\) and the nonzero endpoint.

For the zero/zero Hessian block, the operation first examines every projected
first-derivative block \(P_0A_iP_0\), represented by the zero-eigenvalue rows
and columns of \(G_i\). If every entry of every required block is exactly zero,
the complete zero/zero contribution is analytically zero and is skipped before
forming \(\Phi''_\mu(0)\). This covers cases such as an eigenvalue beginning
quadratically in a background coordinate.

If any required zero-block entry is nonzero, at least one diagonal background
Hessian contains a positive sum of squares multiplying the divergent
\(\Phi''_\mu(0)\). The fused Hessian operation returns
`singular_derivative` and publishes no candidate output.

An implementation does not multiply an infinity by a floating-point zero and
does not use a tolerance to declare a zero block finite. A cancellation that is
not established by this block criterion remains outside the successful
Milestone 3 Hessian domain.

### Evaluation and publication

All rotations, cluster construction, coefficient evaluation, and reductions
use fixed lexical loop order. The operation uses the eigensystem already
computed for the value and caller-provided workspace for transformed
first- and second-derivative matrices and candidate outputs.

The full dense Hessian is evaluated entry by entry. Symmetry is tested; it is
not manufactured by copying one triangle. Candidate value, gradient, and
Hessian outputs remain unpublished until the complete fused operation has
status `ok`.

## Alternatives

Differentiating sorted eigenvalues and eigenvectors was rejected because it
makes results depend on label exchanges, eigenvector signs, and bases selected
inside degenerate eigenspaces.

Finite differences remain a valid explicitly selected future capability, but
were rejected as the Milestone 3 production derivative. They require an
additional stencil and step policy, repeat eigensolutions, do not identify an
exact zero-mode singularity reliably, and provide weaker evidence than the
analytic formulas already used by the independent oracle.

Contour integrals, polynomial matrix-function approximations, and automatic
differentiation through a degeneracy-aware eigensolver could implement
equivalent invariant semantics. They are broader and more complex than the
small dense real-symmetric operation required here.

Reporting every degeneracy as unsupported was rejected because a symmetric
spectral trace is well defined at ordinary nonzero degeneracies. Treating every
small eigenvalue as zero was rejected because it would clip physical negative
eigenvalues and change the specified branch.

## Consequences

The derivative backend needs eigenvectors in addition to eigenvalues, matching
the workspace already required by Decision 0008. Its dominant work remains
\(O(n^3)\) for the initial small dense scalar sector.

The method is invariant under eigenvalue ordering, eigenvector signs, and
rotations within a numerically identified nonzero degenerate block. Near but
resolved eigenvalues retain the stable divided difference rather than being
differentiated as labels.

An exact zero mode can have a successful value and gradient while the fused
Hessian reports `singular_derivative`. A termwise analytic zero-block
cancellation succeeds without generating a non-finite intermediate.

The production implementation and private known-spectrum oracle retain
independent control flow. They share only the deliberately trusted `f64`
elementary primitives recorded by Decision 0007.

## Revisit when

Revisit if supported scalar sectors make the transformed derivative matrices a
measured bottleneck, if a required finite zero-mode cancellation is not
captured by the exact block criterion, if comparison evidence requires a
different close-pair series boundary, or if a new scalar type changes the
clustering and error analysis. Any replacement must preserve the invariant
formula, explicit zero-mode status, fixed-order reproducibility, and independent
oracle coverage.
