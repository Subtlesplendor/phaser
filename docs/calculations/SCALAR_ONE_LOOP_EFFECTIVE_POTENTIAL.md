# Zero-Temperature One-Loop Scalar Effective Potential

Status: initial specification

This document specifies the first quantum effective-potential calculation:
the zero-temperature one-loop contribution of real scalar fluctuations in four
spacetime dimensions.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Supported calculation

The initial calculation supports:

- a validated four-dimensional model containing real scalar fields;
- the tree-level scalar potential and its field-dependent Hessian;
- the `MSbar` renormalization scheme;
- one explicit finite, positive renormalization scale;
- full-scalar-space or component-slice backgrounds;
- exact contribution provenance; and
- complex `f64` values produced from real `f64` inputs.

Fermion, gauge, ghost, thermal, counterterm, resummed, and higher-loop
contributions are outside this calculation. Their absence is structural and
MUST NOT be represented as a scalar approximation.

## 2. Field-dependent scalar mass matrix

Let \(b_\alpha\) be the selected background coordinates and
\(\phi_i(b)\) their exact component embedding. The scalar mass-squared matrix is

\[
\mathcal M^2_{ij}(b;p)
=
\left.
\frac{\partial^2 V_0(\phi;p)}
     {\partial\phi_i\partial\phi_j}
\right|_{\phi=\phi(b)}.
\]

It is a real symmetric matrix over the complete scalar fluctuation space.
Restricting the background does not remove unselected scalar fluctuations.

The matrix is represented as an invariant spectral operand. Phaser is not
required to assign persistent labels to its eigenvalues or derive symbolic
closed forms.

## 3. One-loop convention

For renormalization scale \(\mu_R>0\), the scalar contribution is

\[
V^{(1)}_{\mathrm{scalar}}(b;p,\mu_R)
=
\frac{1}{64\pi^2}
\operatorname{Tr}
\left[
(\mathcal M^2)^2
\left(
\operatorname{Log}\frac{\mathcal M^2}{\mu_R^2}
-\frac{3}{2}I
\right)
\right].
\]

Equivalently, for the real eigenvalue multiset \(\{x_a\}\),

\[
V^{(1)}_{\mathrm{scalar}}
=
\frac{1}{64\pi^2}
\sum_a
x_a^2
\left[
\operatorname{Log}\left(\frac{x_a}{\mu_R^2}\right)
-\frac32
\right].
\]

Each real scalar component has multiplicity one. Degenerate eigenvalues retain
their multiplicity. The `3/2` constant and overall normalization are part of
the formula-version contract.

The contribution is retained even when it is independent of the selected
background. No implicit subtraction, normalization at a reference background,
or dropping of vacuum terms occurs.

## 4. Complex branch convention

`Log` is the principal complex logarithm with

\[
\operatorname{Arg}z\in(-\pi,\pi].
\]

For a negative real eigenvalue \(x<0\),

\[
\operatorname{Log}(x/\mu_R^2)
=
\log(|x|/\mu_R^2)+i\pi.
\]

Therefore one negative real scalar eigenvalue contributes

\[
\operatorname{Im}V^{(1)}_{\mathrm{scalar}}
=
\frac{x^2}{64\pi}.
\]

Negative eigenvalues are valid inputs to this operation. The evaluator MUST
NOT reject them, replace the logarithm by `log(abs(x))`, clip them to zero, or
return only a real projection.

The symbolic artifact records the logarithm and branch convention. Numerical
results record that the principal branch was used and whether the imaginary
component is nonzero.

## 5. Numerical result type

Loop-containing value, gradient, and Hessian results use the semantic type

```text
Complex64 {
    re: f64,
    im: f64,
}
```

This specifies a pair of IEEE binary64 components, not a stable C layout.
Model parameters, scales, and background coordinates remain real `f64` inputs.

A real tree contribution promotes to `(tree_value, 0)` when summed with a
complex loop contribution. A selected tree-only result may remain real.

A nonzero imaginary component is a successful numerical result, not a
point-level failure. Batch status distinguishes a valid complex value from
non-finite arithmetic, a zero-mode derivative singularity, or another genuine
domain failure.

## 6. Zero modes and derivatives

Define

\[
f(x)
=
x^2\left[\operatorname{Log}(x/\mu_R^2)-\frac32\right].
\]

The value and first derivative have continuous limits:

\[
f(0)=0,
\qquad
\lim_{x\to0^\pm}f'(x)=0,
\]

where

\[
f'(x)=2x\left[\operatorname{Log}(x/\mu_R^2)-1\right].
\]

The second derivative,

\[
f''(x)=2\operatorname{Log}(x/\mu_R^2),
\]

is singular at zero.

Consequently:

- value evaluation includes a zero eigenvalue with contribution zero;
- a first derivative MAY use the finite invariant limit;
- a Hessian succeeds only when all required spectral second-derivative
  combinations are finite; and
- a required divergent zero-mode term produces an explicit point-level
  `singular_derivative` status.

An implementation MUST preserve an analytically established cancellation. It
MUST NOT infer one by multiplying a floating-point zero by an already generated
infinity.

Numerical eigensolver tolerances may identify degeneracies for algorithmic
stability, but they MUST NOT clip a negative eigenvalue to zero or decide
symbolic equality.

## 7. Degeneracies and basis covariance

The spectral sum is invariant under real orthogonal changes of scalar basis.
Exact positive or negative degeneracy does not make the value ambiguous.

Derivative algorithms use invariant spectral divided differences or another
method with the same semantics. They MUST NOT differentiate an arbitrary
eigenvalue ordering or eigenvector phase convention.

## 8. Interpretation and metadata

The imaginary component is part of the fixed-order mathematical effective
potential. It can signal expansion around an unstable background, but it is not
automatically a physical decay rate.

In particular, negative field-dependent Goldstone squared masses can produce
fixed-order imaginary contributions that require a separately specified
resummation for some physical uses. The initial calculation applies no
Goldstone or instability resummation.

Every artifact and result records:

- formula version `scalar-vacuum-msbar/1`;
- principal-log branch `arg(-pi,pi]`;
- `MSbar` and \(\mu_R\);
- scalar-loop provenance and multiplicity;
- whether the imaginary component is nonzero;
- result precision;
- resummation policy `none`; and
- any zero-mode derivative status.

A future real projection or resummation is an explicit named transformation or
calculation policy. It MUST retain provenance linking it to the unprojected
complex contribution and MUST NOT become an undocumented default.

## 9. Conformance requirements

Tests include:

- positive \(x\), with exactly zero imaginary component;
- negative \(x\), with imaginary component \(x^2/(64\pi)\);
- the value and first-derivative limits as \(x\to0^\pm\);
- an explicitly singular zero-mode Hessian;
- repeated positive and negative eigenvalues;
- an indefinite two-scalar matrix compared with an explicit eigenvalue sum;
- scalar field permutations; and
- orthogonal basis changes of the mass matrix.

The real and imaginary components are compared independently under named
numerical policies. The symbolic formula, branch, multiplicity, and provenance
are exact comparisons.

## 10. References

- Stephen P. Martin and Hiren H. Patel,
  [Two-loop effective potential for generalized gauge fixing](https://arxiv.org/abs/1808.07615).
- Stephen P. Martin,
  [Taming the Goldstone contributions to the effective potential](https://arxiv.org/abs/1406.2355).
