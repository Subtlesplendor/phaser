# QFT Model Format: Gauge Tensors

Status: provisional specification

This document specifies the flattened gauge-interaction tensors of the Phaser
QFT Model Format. It refines section 6 of [DESIGN.md](../../DESIGN.md) and uses
the Lagrangian convention in
[QFT Model Format: Lagrangian and Fermion Tensors](QFT_MODEL_LAGRANGIAN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

The representation follows the coupling-weighted tensors used by Martin and
Patel and by DRalgo.

## 1. Scope

The canonical source model supplies three gauge-interaction tensors:

\[
g^{abc},\qquad
g^a{}_{ij},\qquad
g^a{}_I{}^J.
\]

They contain both group-theory structure and coupling normalization. Phaser 0.1
does not require semantic gauge-factor objects, named gauge groups, named
representations, or separately supplied generators.

This specification fixes:

- tensor keys, slot types, domains, and symmetries;
- the relation to factorized coupling-and-generator notation;
- the gauge interactions derived from the tensors;
- the representation of product and Abelian gauge sectors;
- canonical kinetic-term assumptions; and
- exact gauge-algebra and gauge-invariance obligations.

Gauge fixing remains a calculation choice specified by
[Gauge Fixing and Gauge Parameters](GAUGE_FIXING.md).

## 2. Flattened convention

In a factorized basis, Martin--Patel notation uses a coupling \(g_a\), structure
constants \(f^{abc}\), real-scalar generators \(t^a{}_{ij}\), and Weyl-fermion
generators \(T^a{}_I{}^J\). The flattened tensors are

\[
g^{abc}=g_a f^{abc},
\]

\[
g^a{}_{ij}=i g_a t^a{}_{ij},
\]

\[
g^a{}_I{}^J=g_a T^a{}_I{}^J.
\]

For a simple non-Abelian factor in an orthonormal vector basis, the same coupling
appears for all vector components of that factor. Cross-factor components
vanish. Phaser records these facts in the tensor values themselves rather than
in a separate factor declaration.

The model author supplies the flattened tensors directly. Phaser does not
multiply a separately declared coupling into a named representation.

## 3. Defining gauge interactions

The field strength and covariant derivatives are

\[
F_{\mu\nu}^a
=
\partial_\mu A_\nu^a-\partial_\nu A_\mu^a
+g^{abc}A_\mu^bA_\nu^c,
\]

\[
D_\mu R_i
=
\partial_\mu R_i-g^a{}_{ij}A_\mu^aR_j,
\]

\[
D_\mu\psi_I
=
\partial_\mu\psi_I
-i g^a{}_I{}^J A_\mu^a\psi_J.
\]

Together with the canonical kinetic terms

\[
-\frac14F_{\mu\nu}^aF^{\mu\nu a}
-\frac12D_\mu R_iD^\mu R_i
+i\psi^{\dagger I}\bar\sigma^\mu D_\mu\psi_I,
\]

these equations define all vector self-interactions, vector--scalar
interactions, and vector--fermion interactions.

In particular, vector quartics and scalar seagull interactions are derived.
They MUST NOT be supplied as independent model tensors. This prevents an input
from specifying cubic gauge interactions inconsistent with its quartic ones.

## 4. Tensor schemas

### 4.1 Vector cubic tensor

`gauge_vector_cubic` represents \(g^{abc}\):

```json
"gauge_vector_cubic": {
  "components": [
    {
      "indices": ["W1", "W2", "W3"],
      "value": "g2"
    }
  ]
}
```

Its three slots are gauge-vector indices. It is dimensionless, real, and fully
antisymmetric:

\[
g^{abc}=g^{bca}=g^{cab}
=-g^{acb}=-g^{bac}=-g^{cba}.
\]

The source representative MUST satisfy \(a<b<c\) in gauge-vector array order.
Any component with a repeated index is identically zero and MUST NOT be
supplied.

### 4.2 Vector--scalar tensor

`gauge_scalar` represents \(g^a{}_{ij}\):

```json
"gauge_scalar": {
  "components": [
    {
      "indices": ["B", "h_re", "h_im"],
      "value": "-g1 / 2"
    }
  ]
}
```

Its slots are one gauge-vector index followed by two real-scalar indices. It is
dimensionless, real, and antisymmetric in the scalar slots:

\[
g^a{}_{ij}=-g^a{}_{ji}.
\]

The source representative MUST satisfy \(i<j\). A component with \(i=j\) is
identically zero and MUST NOT be supplied.

### 4.3 Vector--fermion tensor

`gauge_fermion` represents \(g^a{}_I{}^J\):

```json
"gauge_fermion": {
  "components": [
    {
      "indices": ["B", "psi_1", "psi_2"],
      "value": {
        "real": "g_re",
        "imaginary": "g_im"
      }
    }
  ]
}
```

Its slots are one gauge-vector index followed by two Weyl-fermion indices. It is
dimensionless, complex, and Hermitian in fermion space:

\[
g^a{}_J{}^I
=
\left(g^a{}_I{}^J\right)^*.
\]

The source representative MUST satisfy \(I\leq J\). A diagonal component is
real; a nonzero imaginary part on \(I=J\) is invalid.

The complex value syntax is specified in
[QFT Model Format: Lagrangian and Fermion Tensors](QFT_MODEL_LAGRANGIAN.md#6-complex-component-values).

## 5. Signed and conjugating tensor orbits

The common sparse tensor representation is extended beyond symmetric
permutations:

- an antisymmetric orbit records the permutation sign;
- a Hermitian orbit records whether reconstruction applies complex
  conjugation; and
- an identically vanishing repeated-index orbit has no stored representative.

The source contains exactly one canonical representative of each nonzero orbit.
Supplying another ordering from the same orbit is an error even if its value has
the expected sign or conjugation.

Canonical Model IR records the tensor symmetry kind explicitly through its
schema type, not through flags supplied by the model author.

## 6. Product gauge groups

Product structure is represented by the tensors' block structure.

- `gauge_vector_cubic` has no components joining different non-Abelian factors.
- Scalar and fermion fields may couple to vectors from several factors through
  separate `gauge_scalar` and `gauge_fermion` components.
- Reusing the same parameter expression across components records a shared
  coupling.
- Phaser does not infer a shared coupling from field names or neighboring vector
  positions.

No semantic `"SU2"`, `"U1"`, representation-name, Dynkin-label, or family object
is part of schema version 0.1. A frontend MAY generate flattened tensors from
such higher-level data, but the generated ordinary model is authoritative.

This convention permits arbitrary products and avoids assigning physical
meaning to serialized names.

## 7. Abelian sectors and kinetic terms

Gauge-vector kinetic terms use the canonical metric \(\delta_{ab}\). Schema
version 0.1 does not accept a gauge kinetic matrix or an operator

\[
K_{ab}F_{\mu\nu}^aF^{\mu\nu b}
\]

with nontrivial \(K_{ab}\).

Several Abelian vectors are nevertheless allowed. They have no
`gauge_vector_cubic` components, and their commuting actions on scalars and
fermions are supplied through the other two gauge tensors. Thus a model already
written in a canonical kinetic basis can represent a general matrix of Abelian
couplings and charges.

Phaser 0.1 does not:

- canonicalize a user-supplied kinetic matrix;
- infer an Abelian coupling matrix from named charges;
- promise an RG prescription that preserves a chosen canonical Abelian basis;
  or
- perform scale-dependent vector-basis rotations automatically.

Those operations require a later specification even though their result at one
scale may be expressible using the flattened tensors.

## 8. Exact consistency identities

Gauge tensors define a valid model only if they satisfy the identities implied
by canonical gauge invariance.

Let \(G^a\) denote the real antisymmetric scalar matrix with entries
\((G^a)_{ij}=g^a{}_{ij}\), and let \(H^a\) denote the Hermitian fermion matrix
with entries \((H^a)_I{}^J=g^a{}_I{}^J\).

### 8.1 Gauge algebra

The vector tensor satisfies the Jacobi identity:

\[
g^{abe}g^{ecd}
+g^{bce}g^{ead}
+g^{cae}g^{ebd}
=0.
\]

The scalar and fermion matrices represent the same algebra:

\[
[G^a,G^b]
=
-g^{abc}G^c,
\]

\[
[H^a,H^b]
=
i g^{abc}H^c.
\]

For Abelian vectors these equations require the associated scalar matrices to
commute and the associated fermion matrices to commute.

### 8.2 Scalar potential

The complete scalar potential is invariant under

\[
\delta R_i
=
\alpha^a G^a{}_{ij}R_j.
\]

Equivalently, for every \(a\),

\[
G^a{}_{ij}R_j\frac{\partial V}{\partial R_i}=0
\]

as an exact polynomial identity. This one condition covers the tadpole,
mass-squared, cubic, and quartic tensor identities.

### 8.3 Fermion mass

The fermion mass tensor satisfies

\[
(H^a)^T M+M H^a=0
\]

for every gauge-vector index \(a\).

### 8.4 Yukawa tensor

Writing \(Y^i\) for the symmetric fermion matrix with entries \(Y^{iIJ}\), the
Yukawa tensors satisfy, for every \(a\) and scalar index \(k\),

\[
\sum_i G^a{}_{ik}Y^i
+i\left[(H^a)^T Y^k+Y^k H^a\right]
=0.
\]

These equations use the signs and index orientation fixed in sections 2 and 3.
Implementations MUST test them against direct infinitesimal variation of the
defining Lagrangian.

## 9. Validation policy

Validation MUST establish:

1. ranks, index spaces, domains, and mass dimensions;
2. antisymmetric and Hermitian orbit rules;
3. total antisymmetry of `gauge_vector_cubic`;
4. reality of `gauge_vector_cubic` and `gauge_scalar`;
5. Hermiticity of `gauge_fermion`;
6. the Jacobi and representation identities;
7. gauge invariance of the scalar and fermion tensors; and
8. structural absence of all derived gauge work when no gauge vectors are
   declared.

The identities are exact structural requirements. A validator MUST NOT accept a
model solely because the identities are small at sampled floating-point
parameter values.

To avoid turning model validation into a general computer algebra system, the
initial exact proof domain is deliberately narrower than the complete source
expression grammar. Every coefficient participating in a gauge-algebra or
gauge-invariance identity MUST normalize to a sparse multivariate polynomial in
declared parameters with exact rational or supported algebraic constants.
Parameter-dependent denominators are outside the initial proof domain.

The identity checker canonicalizes parameter monomials, exact coefficients, and
sums before comparison. If an identity lies outside the supported polynomial
domain or exceeds its documented term bound, validation returns an explicit
unsupported-identity diagnostic; it does not silently accept the model or
substitute numerical sampling.

Validation SHOULD accumulate only potentially nonzero sparse contractions and
MUST enforce intermediate monomial and term bounds. It MUST NOT materialize
complete dense rank-four or higher tensors merely to check a sparse model.

This restriction applies to the identity-checking boundary, not to every future
use of the source expression language. Extending the proof domain requires a
focused algebraic design and implementation evidence.

## 10. Derived structures

The following are derived from the validated model and a calculation context:

- scalar and vector covariant-kinetic vertices;
- vector cubic and quartic vertices;
- scalar seagull interactions;
- background-dependent vector mass matrices;
- background-dependent scalar--vector mixing;
- ghost fields and ghost interactions after gauge fixing;
- broken and unbroken generator structure relative to a background; and
- rotated gauge tensors in a derived spectral basis.

They are not additional source tensors. Goldstone labels, mass eigenstates, and
physical-particle records are likewise not source-model data.

## 11. Required tests

Tests MUST include:

- a non-Abelian algebra with nonzero `gauge_vector_cubic`;
- two commuting Abelian vectors;
- scalar and fermion representation closure;
- exact Jacobi success and failure cases;
- exact scalar-potential, mass, and Yukawa invariance checks;
- antisymmetric sign reconstruction;
- Hermitian conjugation reconstruction;
- rejection of repeated-index antisymmetric components;
- rejection of imaginary Hermitian diagonal components;
- product-sector block separation;
- structurally absent gauge sectors;
- derived cubic/quartic and scalar-seagull agreement with direct expansion of
  the defining kinetic terms;
- field and vector relabeling;
- zero-coupling and structurally reduced models; and
- fuzzing of valid, near-valid, and invalid sparse gauge tensors.

The Abelian Higgs model is the minimal complete gauge fixture. Selected Standard
Model fixtures exercise product structure, chiral fermions, and realistic sparse
tensors.

## 12. Decisions deferred

This specification deliberately leaves open:

- exact public diagnostics for unproved identities;
- the first exact identity-checking algorithm and its supported expression
  subset;
- optional non-semantic gauge-factor presentation metadata;
- input and canonicalization of noncanonical Abelian kinetic matrices;
- scale-dependent canonicalization of Abelian mixing;
- named-representation generator utilities outside the core model format; and
- whether a later schema accepts factorized generators as source shorthand.

## 13. References

- Stephen P. Martin and Hiren H. Patel,
  [Two-loop effective potential for generalized gauge
  fixing](https://arxiv.org/abs/1808.07615).
- Andreas Ekstedt, Philipp Schicho, and Tuomas V. I. Tenkanen,
  [DRalgo: a package for effective field theory approach for thermal phase
  transitions](https://arxiv.org/abs/2205.08815).
