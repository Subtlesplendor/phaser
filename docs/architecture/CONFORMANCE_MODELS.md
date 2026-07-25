# Scientific Conformance Models

Status: initial specification

This document specifies the scientific model suite used to validate Phaser
across implementation milestones. It refines section 24 of
[DESIGN.md](../../DESIGN.md) and the conformance requirements in
[Verification and Testing](VERIFICATION_AND_TESTING.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are requirements on
Phaser implementations and conformance fixtures.

## 1. Purpose

A conformance model is a deliberately selected scientific fixture with assigned
verification obligations. It is not merely an example model or a benchmark.

The suite exists to test:

- model-format and convention choices;
- exact tensor normalization and symmetries;
- background embedding and field-dependent structures;
- structural presence and absence of field sectors;
- symbolic and numerical calculation results;
- cancellations involving several independently generated contributions;
- perturbative and renormalization-group consistency; and
- agreement across public language boundaries.

A named model is added only when it verifies a new scientific or
representational requirement.

## 2. Component theories, not named-model shortcuts

Every conformance model is supplied through the ordinary public QFT model
format. A fixture MUST NOT rely on a built-in model name that bypasses normal
parsing, validation, tensor construction, or calculation derivation.

In particular, the Wess–Zumino fixture is an explicitly supplied component
theory containing real scalars and a Weyl fermion. Phaser does not need
superfields, a superpotential parser, supersymmetry metadata, auxiliary fields,
or automatic derivation of component interactions.

Reference derivations MAY use a more compact formulation, provided that the
mapping to Phaser's explicit component conventions is recorded.

## 3. Fixture contract

Each conformance fixture MUST record:

- a stable fixture identifier and fixture-format version;
- the public model-format version;
- the scientific and representational properties it verifies;
- the specifications and roadmap milestones to which it applies;
- field, tensor, metric, sign, and normalization conventions;
- the background parametrization;
- the calculation kind, perturbative order, scheme, scale, and gauge where
  applicable;
- exact expected identities and structural results;
- numerical reference values and their comparison policies;
- derivation or publication provenance;
- any transformation applied to published notation or parameters;
- known limitations and deliberately unsupported checks; and
- tool names and versions for externally generated data.

The initial language-neutral manifest uses schema identifier
`phaser.conformance-fixture/0.1`. It contains:

- `fixture_id`, `model_file`, and `model_schema`;
- the applicable roadmap milestones;
- the scientific conventions needed to interpret the expected results;
- exact identities and named reference points;
- structured metamorphic cases with their transformations, expected relations,
  and exact common results;
- derivation or external provenance; and
- deliberately unsupported obligations.

Unknown top-level properties are rejected when machine loading is introduced.
Exact mathematical values are stored as reviewable strings rather than rounded
JSON numbers. The target-specific parser for those expected-value expressions
is introduced only when a milestone first consumes the quantity; the manifest
itself does not extend the QFT model expression language.

An obligation becomes active only when its required Phaser capability is
supported. A fixture MUST distinguish `not_yet_supported` from failure of an
implemented calculation.

External reference data SHOULD be stored in language-neutral files where
licensing permits. Ordinary conformance tests MUST remain deterministic,
bounded, offline, and independent of the program that generated the reference
data.

## 4. Initial named suite

The initial named suite is:

| Model | First relevant milestone | Principal obligations |
|---|---:|---|
| Real scalar \(\phi^4\) | 1 | exact coefficients, normalization, derivatives, minimal scalar path |
| Multi-scalar theory | 1 | mixing, cubic terms, tensor symmetry, background slices, basis covariance |
| Wess–Zumino model | 6 | scalar–Weyl interactions, complex Yukawa components, gauge-sector absence, supersymmetric cancellations |
| Abelian Higgs model | 6 | gauge tensors, Goldstone structure, gauge fixing, first gauge-thermal slice |
| Standard Model | 6 | realistic chiral field content, product gauge structure, published reference results |
| Real-singlet extension of the Standard Model | 6 | multiple active backgrounds, mixing, model extension, realistic thermal use |

Large fixtures MAY have reduced variants for bounded per-change tests. A reduced
variant does not replace the complete fixture's broader or scheduled
conformance obligations.

## 5. Generated cases and limits

The following are conformance transformations or model families rather than
additional named physical models:

- field and parameter relabeling;
- tensor-component insertion-order changes;
- supported scalar-basis transformations supplied as separate explicit models;
- zero-coupling and decoupling limits;
- comparison with a structurally reduced model;
- scalar-only, fermion-free, and gauge-free sector pruning;
- full-background derivation followed by restriction versus direct background
  restriction; and
- parameter choices for which particular masses, vertices, diagrams, or diagram
  classes vanish.

Each transformation MUST state the expected relation between results. A
zero-coupling limit is not a structural zero inside the generic source model;
tests MUST distinguish numerical specialization from derivation of a model in
which the interaction is absent structurally.

## 6. Wess-Zumino component fixture

### 6.1 Reference theory

The reference theory is the Wess–Zumino model with real parameters \(m\) and
\(y\) and superpotential

\[
W = \frac{m}{2}\Phi^2 + \frac{y}{6}\Phi^3.
\]

This compact definition is reference provenance, not Phaser input syntax.
The effective-potential reference uses dimensional regularization and the
\(\overline{\mathrm{MS}}\) scheme. The model has no gauge fields, so its fixture
does not exercise the paper's Landau-gauge restriction or imply that the same
scheme preserves supersymmetric identities in gauge theories.

Write its complex scalar component as

\[
A = \frac{s + i p}{\sqrt{2}},
\]

where \(s\) and \(p\) are canonically normalized real scalar fields. The Phaser
fixture declares:

- real scalar fields `s` and `p`;
- one two-component Weyl field `psi`;
- no gauge-vector fields; and
- all scalar, fermion-mass, and Yukawa tensor components explicitly.

The scalar potential is

\[
V^{(0)}(s,p)
=
\frac{m^2}{2}(s^2+p^2)
+\frac{my}{2\sqrt{2}}(s^3+sp^2)
+\frac{y^2}{16}(s^2+p^2)^2.
\]

With Phaser's factorial tensor normalization, the nonzero independent scalar
components are

\[
\begin{aligned}
m^2_{ss} &= m^2_{pp} = m^2,\\
h_{sss} &= \frac{3my}{\sqrt{2}},
&
h_{spp} &= \frac{my}{\sqrt{2}},\\
\lambda_{ssss} &= \lambda_{pppp} = \frac{3y^2}{2},
&
\lambda_{sspp} &= \frac{y^2}{2}.
\end{aligned}
\]

Under Phaser's fermion convention, the nonzero components are

\[
M_{\psi\psi}=m,\qquad
Y_{s\psi\psi}=\frac{y}{\sqrt{2}},\qquad
Y_{p\psi\psi}=\frac{i y}{\sqrt{2}}.
\]

The fixture MUST record the convention mapping when comparing with a reference
that uses different field or index conventions.

### 6.2 Complex tensor requirement

The Wess–Zumino model has real parameters and no CP-violating input, but its
Weyl-component Yukawa tensor contains an imaginary component. It therefore
serves as the first acceptance case for complex-valued fermion tensors.

Complex tensor values MUST be structurally separated into real and imaginary
parts, each expressed using the ordinary exact real expression language. This
does not:

- add complex scalar multiplets to the model format;
- add complex-to-real lowering;
- require an imaginary-unit operator in ordinary source expressions; or
- imply support for arbitrary complex numerical potential kernels.

The exact encoding is specified in
[QFT Model Format: Lagrangian and Fermion Tensors](../formats/QFT_MODEL_LAGRANGIAN.md).
In particular, the `p,psi,psi` component uses a structured `imaginary` value and
does not place `i` in the ordinary expression string.

### 6.3 Background mapping

The primary calculation selects `s` as its active background component and fixes
the background of `p` exactly to zero.

Martin writes the complex scalar as

\[
A=\phi+\frac{R+iI}{\sqrt{2}}.
\]

The comparison therefore uses

\[
s=\sqrt{2}\phi.
\]

This is an explicit relation used by the fixture and reference derivation.
Phaser is not required to infer or execute a field-basis transformation.

In the paper's background coordinate, the field-dependent squared masses are

\[
\begin{aligned}
R &= m^2+3ym\phi+\frac{3}{2}y^2\phi^2,\\
I &= m^2+ym\phi+\frac{1}{2}y^2\phi^2,\\
\psi &= (m+y\phi)^2.
\end{aligned}
\]

The names \(R\), \(I\), and \(\psi\) in these equations denote squared masses
following the reference notation.

### 6.4 Milestone 6 obligations

Once general four-dimensional field content and one-loop contributions are
supported, the fixture MUST verify:

1. the complete model validates with no gauge sector;
2. gauge contributions and gauge workspaces are structurally absent;
3. the field-dependent scalar and fermion mass structures agree with the
   reference equations;
4. the exact identity

   \[
   R + I - 2\psi = 0
   \]

   holds for an arbitrary background;
5. the two supersymmetric background points

   \[
   \phi=0,\qquad \phi=-\frac{2m}{y}
   \]

   give

   \[
   R=I=\psi=m^2;
   \]
6. the tree contribution vanishes at both points; and
7. the one-loop contribution

   \[
   V^{(1)}=f(R)+f(I)-2f(\psi)
   \]

   vanishes at both points.

Items 4 through 7 SHOULD be checked symbolically or exactly before adding a
numerical comparison.

### 6.5 Higher-loop obligations

The first scalar-only higher-loop milestone is not blocked on mixed
scalar–fermion diagrams. Once a claimed higher-loop capability supports the
required mixed sectors, the Wess–Zumino fixture becomes an exit criterion for
that capability.

At each supported order through the reference order, the suite MUST:

- verify generated diagram classes, field assignments, coefficients, and
  symmetry factors against an independent enumeration or published expression;
- verify the separate loop contribution at each of the two supersymmetric
  minima; and
- verify that \(V^{(2)}=0\), and eventually \(V^{(3)}=0\), without relying only
  on a small final `f64` value.

The higher-loop cancellations involve identities among several equal-mass
master-integral functions. Conformance evidence MUST expose the individual
terms and cancellation scale. It SHOULD combine exact equal-mass reductions
with an independent higher-precision numerical path.

### 6.6 RG obligations

When supplied beta functions and anomalous dimensions are supported, the
fixture MUST verify the finite-order RG identity

\[
Q\frac{\partial V^{(\ell)}}{\partial Q}
+
\sum_{n=0}^{\ell-1}
\sum_X
\beta_X^{(\ell-n)}
\frac{\partial V^{(n)}}{\partial X}
=0
\]

at every supported loop order for which reference RG functions are available.
Here \(X\) includes the independent Lagrangian parameters and the background
field with its anomalous-dimension contribution.

The fixture records the renormalization scheme and the normalization of loop
factors. It tests the expected perturbative residual rather than claiming
all-order scale independence for a truncated result.

### 6.7 Notebook

After Milestone 6, a focused public-API notebook SHOULD:

- display the component potential and field-dependent masses in LaTeX;
- show the absence of the gauge sector;
- plot tree, one-loop, and selected summed contributions;
- evaluate both supersymmetric minima;
- display the mass degeneracy and order-by-order cancellations; and
- expose the plotted and cancellation data to the machine conformance tests.

Later versions SHOULD extend the same notebook when mixed higher-loop and RG
checks become supported.

## 7. Other named-model obligations

### 7.1 Real scalar \(\phi^4\)

This is the minimal exact fixture for expression parsing, factorial
normalization, scalar tensors, background selection, derivatives, binding,
kernel evaluation, and symbolic export. Its version 0.1 source model, exact
identities, positive/zero/negative mass-squared points, and principal-branch
complex one-loop values live under
`test/fixtures/conformance/phi4/`.

### 7.2 Multi-scalar theory

This fixture contains at least two real scalars, a non-diagonal quadratic tensor,
cubic interactions, and mixed quartics. It verifies tensor orbit handling,
field-dependent mixing, multiple background choices, and covariance comparisons
against explicitly recorded permutation and orthogonal transformations. Its
version 0.1 source,
symmetric-orbit multiplicities, definite/degenerate/indefinite matrices, and
complex spectral references live under
`test/fixtures/conformance/multi_scalar/`.

### 7.3 Abelian Higgs model

This is the smallest gauge fixture. It verifies scalar and gauge
representations, Goldstone and ghost sectors, gauge subcases, scalar–vector
mixing where present, and the first gauge-theory dimensional-reduction slice.

### 7.4 Standard Model

The Standard Model exercises realistic chiral fermions, product gauge structure,
non-Abelian structure, several couplings, large sparse tensors, gauge fixing,
RG data, and published effective-potential and thermal references. Reduced
sector limits SHOULD be used to localize failures.

### 7.5 Real-singlet extension

The real-singlet extension exercises a realistic multi-background scalar sector,
mixing, decoupling to the Standard Model, additional scalar thermal effects, and
eventual dimensional reduction for a common phenomenological model.

## 8. Acceptance and staging

A roadmap milestone selects the subset of fixtures and obligations matching its
supported capability. The milestone specification MUST name that subset.

Per-change CI SHOULD use small exact or bounded parameter cases. Larger Standard
Model, high-precision, and higher-loop checks MAY run in broader or scheduled
tiers, but every supported calculation retains at least one bounded per-change
conformance case.

A conformance model is not accepted solely because:

- Phaser reproduces a golden file generated by Phaser;
- several frontends agree while sharing the same core implementation;
- a final cancellation is numerically small without term-level evidence; or
- an external program produces the same result under undocumented conventions.

## 9. Decisions intentionally deferred

- Compatibility rules for conformance-fixture schemas after version 0.1.
- Numerical comparison policies for higher-loop master integrals.
- The first independent high-precision implementation.
- The bounded and scheduled division of Standard Model cases.
- Exact reference parameter points for each named model.

## 10. References

- Stephen P. Martin,
  [Effective potential at three loops](https://arxiv.org/abs/1709.02397).
- Stephen P. Martin and Hiren H. Patel,
  [Two-loop effective potential for generalized gauge
  fixing](https://arxiv.org/abs/1808.07615).
- Andreas Ekstedt, Philipp Schicho, and Tuomas V. I. Tenkanen,
  [DRalgo: a package for effective field theory approach for thermal phase
  transitions](https://arxiv.org/abs/2205.08815).
