# QFT Model Format: Lagrangian and Fermion Tensors

Status: provisional specification

This document specifies the four-dimensional Lagrangian convention, fermion
mass and Yukawa tensors, and complex tensor-component encoding of the Phaser QFT
Model Format. It refines section 6 of [DESIGN.md](../../DESIGN.md) and extends
[QFT Model Format: Fields and Tensor Components](QFT_MODEL_FIELDS.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

The convention follows the flattened general-theory notation used by Martin and
Patel and by DRalgo.

## 1. Scope

This specification fixes:

- the canonical four-dimensional kinetic and interaction convention;
- the normalization of scalar, fermion-mass, and Yukawa tensors;
- the source encoding of complex tensor components;
- tensor symmetries and mass dimensions;
- background-dependent fermion mass construction; and
- the boundary between source fields and derived spectral bases.

Gauge interaction tensors and their validation are specified separately in
[QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md).

Schema version 0.1 does not provide:

- complex scalar fields or multiplet declarations;
- four-component Dirac or Majorana fields;
- noncanonical kinetic terms;
- higher-dimensional operators;
- complex-valued parameter-point entries;
- CP classifications or automatic removal of unphysical phases;
- flavor or family replication; or
- user-supplied field-basis transformations.

## 2. Spacetime and field convention

The source theory is a four-dimensional Minkowski theory with

\[
g_{\mu\nu}=\operatorname{diag}(-1,+1,+1,+1)
\]

and functional-integral phase \(e^{iS}\).

The independent fields are:

- canonically normalized real scalars \(R_i\);
- left-handed two-component Weyl fermions \(\psi_I\); and
- real gauge vectors \(A_\mu^a\).

The source field arrays and their ordered index spaces are specified in
[QFT Model Format: Fields and Tensor Components](QFT_MODEL_FIELDS.md).
Conjugate Weyl fields are not separately declared.

## 3. Defining Lagrangian

Before gauge fixing, the defining Lagrangian is

\[
\begin{aligned}
\mathcal L={}&
-\frac14 F_{\mu\nu}^aF^{\mu\nu a}
-\frac12 D_\mu R_i D^\mu R_i
-V(R)\\
&+i\psi^{\dagger I}\bar\sigma^\mu D_\mu\psi_I
-\frac12\left(M^{IJ}\psi_I\psi_J+\text{h.c.}\right).
\end{aligned}
\]

The scalar potential is

\[
V(R)=
\Lambda+t_iR_i
+\frac12m^2_{ij}R_iR_j
+\frac1{3!}h_{ijk}R_iR_jR_k
+\frac1{4!}\lambda_{ijkl}R_iR_jR_kR_l.
\]

The covariant derivatives contain the flattened gauge tensors specified in
[QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md):

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

The Yukawa interaction is part of the interaction Lagrangian,

\[
\mathcal L_{\mathrm{Yukawa}}
=
-\frac12\left(
Y^{iIJ}R_i\psi_I\psi_J+\text{h.c.}
\right).
\]

Consequently, the complete fermion bilinear in a scalar configuration \(R\) is

\[
-\frac12\left[
\left(M^{IJ}+Y^{iIJ}R_i\right)\psi_I\psi_J+\text{h.c.}
\right].
\]

The displayed factors and signs define the tensor values accepted by the
format. A source model MUST NOT compensate for them by doubling or negating its
components.

Gauge-fixing and ghost terms are calculation data governed by
[Gauge Fixing and Gauge Parameters](GAUGE_FIXING.md); they are not model
tensors.

## 4. Scalar tensor summary

The scalar tensors already specified in
[QFT Model Format: Fields and Tensor Components](QFT_MODEL_FIELDS.md#6-scalar-potential-tensors)
have the following four-dimensional properties:

| JSON key | Tensor | Symmetry | Domain | Mass dimension |
|---|---|---|---|---:|
| `vacuum_energy` | \(\Lambda\) | none | real | 4 |
| `scalar_tadpole` | \(t_i\) | none | real | 3 |
| `scalar_mass_squared` | \(m^2_{ij}\) | fully symmetric | real | 2 |
| `scalar_cubic` | \(h_{ijk}\) | fully symmetric | real | 1 |
| `scalar_quartic` | \(\lambda_{ijkl}\) | fully symmetric | real | 0 |

The descriptive Phaser names do not change their correspondence to the
\(\lambda_i,\mu_{ij},\lambda_{ijk},\lambda_{ijkl}\) notation commonly used in
flattened general-theory formulae.

## 5. Fermion tensors

### 5.1 Fermion mass

The `fermion_mass` tensor represents \(M^{IJ}\):

```json
"fermion_mass": {
  "components": [
    {
      "indices": ["psi_1", "psi_2"],
      "value": "m12"
    }
  ]
}
```

It has two Weyl-fermion slots, mass dimension one, and complex-symmetric
semantics:

\[
M^{IJ}=M^{JI}.
\]

The user supplies exactly one nonzero component for each unordered fermion pair,
with the IDs in ascending fermion-array order.

### 5.2 Yukawa coupling

The `yukawa` tensor represents \(Y^{iIJ}\):

```json
"yukawa": {
  "components": [
    {
      "indices": ["phi", "psi_1", "psi_2"],
      "value": "y12"
    }
  ]
}
```

Its slots are, in order:

1. one real-scalar index \(i\);
2. one Weyl-fermion index \(I\); and
3. one Weyl-fermion index \(J\).

It is dimensionless in four dimensions and symmetric only in its two fermion
slots:

\[
Y^{iIJ}=Y^{iJI}.
\]

The scalar slot is not part of this symmetry orbit. The two fermion IDs MUST be
in ascending fermion-array order.

### 5.3 Conjugate tensors

The model stores \(M^{IJ}\) and \(Y^{iIJ}\). Phaser derives their complex
conjugates when required.

A source model MUST NOT provide separate conjugate mass or Yukawa tensors. Index
height in mathematical output distinguishes a tensor from its conjugate; JSON
field IDs do not encode index height.

## 6. Complex component values

### 6.1 Source forms

A tensor kind whose schema domain is complex accepts either a real-expression
string or a structured complex value.

A string is shorthand for a purely real value:

```json
{
  "indices": ["s", "psi", "psi"],
  "value": "y / sqrt(2)"
}
```

A structured value has this form:

```json
{
  "indices": ["p", "psi", "psi"],
  "value": {
    "imaginary": "y / sqrt(2)"
  }
}
```

The object MAY contain `real`, `imaginary`, or both:

```json
{
  "indices": ["phi", "psi_1", "psi_2"],
  "value": {
    "real": "y_re",
    "imaginary": "y_im"
  }
}
```

The rules are:

- at least one of `real` or `imaginary` is required;
- no other property is permitted;
- each present part is a string in the
  [QFT Model Expression Language](QFT_MODEL_EXPRESSIONS.md);
- an omitted part denotes exact zero;
- a string and an object are alternative forms and cannot be combined; and
- the imaginary unit is structural and does not enter either expression.

Real tensor kinds accept only the string form.

### 6.2 Normalization

Normalization parses, resolves, dimension-checks, and canonicalizes the real and
imaginary expressions independently.

- If the imaginary part is absent or normalizes to zero, the canonical value is
  real.
- If the real part is absent or normalizes to zero, the canonical value is
  purely imaginary.
- If both parts normalize to zero, the component is rejected as an explicit
  sparse zero.
- Both nonzero parts MUST have the mass dimension required by the tensor kind.

Different accepted source spellings that normalize to the same ordered pair of
real expressions have the same semantic component value.

### 6.3 Parameters and CP phases

Schema version 0.1 model parameters and parameter-point entries are real. A
general complex tensor component is represented using independent real
parameters in its two parts.

For example,

```json
"value": {
  "real": "y_re",
  "imaginary": "y_im"
}
```

represents \(y_{\mathrm{re}}+i y_{\mathrm{im}}\) without declaring a
complex-valued parameter.

This representation permits explicit CP-violating phases. Phaser 0.1 does not
infer CP conservation, determine whether phases are removable, or quotient
models by fermion rephasings.

## 7. Background shift and fermion spectrum

For a background \(\phi_i\) and fluctuation \(r_i\),

\[
R_i=\phi_i+r_i,
\]

the background-dependent fermion mass matrix is

\[
\mathcal M^{IJ}(\phi)
=
M^{IJ}+Y^{iIJ}\phi_i.
\]

The Yukawa interaction with fluctuations remains

\[
-\frac12\left(Y^{iIJ}r_i\psi_I\psi_J+\text{h.c.}\right).
\]

The fermion squared masses are the eigenvalues of

\[
\mathcal M^\dagger(\phi)\mathcal M(\phi).
\]

The source Weyl fields are not required to diagonalize \(M\),
\(\mathcal M(\phi)\), or \(\mathcal M^\dagger\mathcal M\). Any Takagi
factorization, singular-value decomposition, or other spectral basis is
background-dependent derived calculation data.

A derived spectral representation MUST retain any transformations needed to
rotate Yukawa and gauge tensors for a requested calculation. It MUST NOT replace
the source fields with persistent physical-particle or mass-eigenstate records.
Labels attached to numerically ordered eigenvalues are not stable identities
through crossings or degeneracies.

## 8. Flavor and family treatment

Every independent Weyl component used by the tensors is explicitly declared in
`fields.weyl_fermions`.

Schema version 0.1 has no semantic family count, implicit tensor replication,
implicit Kronecker delta, or flavor-multiplicity factor. Presentation metadata
MAY document families but MUST NOT alter the theory.

A future frontend MAY generate an expanded component model from a higher-level
family description. The resulting ordinary QFT model is the input to Phaser's
core and receives no special family semantics.

## 9. Validation

Model validation MUST:

1. validate the tensor keys, ranks, slot index spaces, and mass dimensions;
2. resolve field IDs before canonical orbit construction;
3. enforce the symmetric fermion-index ordering;
4. reject duplicate symmetric orbits;
5. validate both parts of every structured complex value;
6. derive conjugates rather than accepting duplicate conjugate tensors;
7. reject complex syntax on a real tensor kind; and
8. apply the gauge-invariance checks specified in
   [QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md) when a gauge
   sector is present.

Failure to establish an exact required tensor identity is a validation error. A
finite set of floating-point sample points is not proof of a structural
symmetry, Hermiticity condition, or gauge-invariance identity.

## 10. Required tests

Tests MUST cover:

- mass and Yukawa factorial and sign conventions through derived vertices;
- symmetric fermion-index orbit construction;
- diagonal and off-diagonal complex components;
- purely real and purely imaginary source forms;
- rejection of empty, zero, malformed, and dimensionally inconsistent complex
  values;
- automatic conjugate construction;
- the exact relation
  \(\mathcal M(\phi)=M+Y^i\phi_i\);
- non-diagonal fermion mass matrices;
- exact and near-degenerate squared masses;
- invariance under fermion relabeling;
- absence of fermion work for a fermion-free model; and
- parser and model fuzzing of both complex-value alternatives.

The Wess--Zumino conformance fixture is the first complete acceptance test for
the imaginary Yukawa path.

## 11. References

- Stephen P. Martin and Hiren H. Patel,
  [Two-loop effective potential for generalized gauge
  fixing](https://arxiv.org/abs/1808.07615).
- Andreas Ekstedt, Philipp Schicho, and Tuomas V. I. Tenkanen,
  [DRalgo: a package for effective field theory approach for thermal phase
  transitions](https://arxiv.org/abs/2205.08815).

