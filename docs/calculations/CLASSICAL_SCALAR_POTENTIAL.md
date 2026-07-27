# Classical Scalar Potential

Status: provisional specification

This document specifies the tree-level scalar effective-potential artifact
derived by Milestone 2. It refines
[Effective-Potential Artifact](EFFECTIVE_POTENTIAL.md) for loop order zero.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

Implemented in `src/calculation/potential.zig`, exercised by
`test/conformance/classical_scalar.zig`. The Milestone 3 cross-reference in
this document (loop order one, in
[EFFECTIVE_POTENTIAL.md](EFFECTIVE_POTENTIAL.md)) is still active and
unimplemented — see [docs/README.md](../README.md).

## 1. Scope

This specification fixes:

- the tree-level potential derived from canonical model tensors;
- the exact orbit coefficient relating canonical stored components to the full
  index sum;
- the background embedding and structural substitution;
- contribution granularity, roles, and deterministic order;
- structural absence records;
- background derivatives; and
- the required verification.

It does not specify loop contributions, renormalization-scale dependence,
spectral operations, or thermal contributions.

## 2. Defining potential

[QFT Model Format: Lagrangian and Fermion Tensors §3](../formats/QFT_MODEL_LAGRANGIAN.md)
fixes the scalar potential of a model with real scalar components \(R_i\) as

\[
V(R)=
\Lambda+t_iR_i
+\frac12m^2_{ij}R_iR_j
+\frac1{3!}h_{ijk}R_iR_jR_k
+\frac1{4!}\lambda_{ijkl}R_iR_jR_kR_l,
\]

with every repeated index summed over the complete real-scalar index space. The
tree-level effective potential is this classical potential evaluated on the
background embedding.

The potential density has mass dimension equal to the model's spacetime
dimension, which is 4 for every model supported by Milestone 2. Every retained
contribution MUST carry that dimension after the background map is applied.

## 3. Orbit coefficients

### 3.1 Canonical storage

The Canonical Model IR stores only components whose index tuple is
nondecreasing, one per orbit of the fully symmetric index group. The defining
sums above run over all index tuples. Derivation MUST therefore reconstruct the
full sum from the stored orbit representatives.

### 3.2 Coefficient rule

Let a stored component of a rank-\(r\) scalar tensor have index tuple \(c\) with
exact expression \(E_c\), and let \(m_v\) be the multiplicity of each distinct
scalar index \(v\) occurring in \(c\). The orbit contains

\[
N_c=\frac{r!}{\prod_v m_v!}
\]

distinct index tuples, each carrying the same component value by full symmetry.
Combining \(N_c\) with the defining \(1/r!\) normalization, the monomial
coefficient is

\[
\frac{N_c}{r!}=\frac{1}{\prod_v m_v!}.
\]

The tree potential is therefore the exact sum over stored components

\[
V_{\mathrm{tree}}
=
\sum_{r}\;\sum_{c\in\mathcal C_r}
\frac{E_c}{\prod_v m_v!}
\prod_{i\in c}R_i ,
\]

where \(\mathcal C_r\) is the set of stored components of rank \(r\) and the
product runs over the tuple with multiplicity.

The factorial denominator MUST be constructed as an exact rational in the Typed
Value IR. It MUST NOT be evaluated in floating point during derivation.

### 3.3 Worked values

For the `vacuum_energy` and `scalar_tadpole` tensors the denominator is
\(1\). The remaining cases occurring in the Milestone 2 conformance fixtures
are:

| Tensor | Component | \(\prod_v m_v!\) | Monomial coefficient |
|---|---|---:|---|
| `scalar_mass_squared` | \([\phi,\phi]\) | 2 | \(m^2/2\) |
| `scalar_mass_squared` | \([h,s]\) | 1 | \(m^2_{hs}\) |
| `scalar_cubic` | \([h,h,s]\) | 2 | \(b/2\) |
| `scalar_quartic` | \([\phi,\phi,\phi,\phi]\) | 24 | \(\lambda/24\) |
| `scalar_quartic` | \([h,h,h,s]\) | 6 | \(l_3/6\) |
| `scalar_quartic` | \([h,h,s,s]\) | 4 | \(l_2/4\) |

These agree term by term with the `exact_identities.tree_potential` entries of
the `scalar.phi4` and `scalar.multi_scalar` fixtures, which are the independent
oracle for this rule.

## 4. Background embedding

The background parametrization is resolved before derivation as specified in
[Background Parametrization §7](../formats/BACKGROUND_PARAMETRIZATION.md). The
tree potential is the exact restriction

\[
V_{\mathrm{slice}}(b)=V_{\mathrm{tree}}\bigl(\bar\phi(b)\bigr).
\]

For `full_scalar_space` the embedding is the identity and coordinate order is
the model's real-scalar order.

For `component_slice` each selected scalar receives its coordinate and every
unselected scalar background is exactly zero. Derivation MUST substitute those
exact zeros before constructing contribution values. Any monomial containing an
unselected scalar is then structurally absent, not numerically small.

This pruning is valid because the substituted value is structurally zero for
every point on the slice. A term MUST NOT be pruned because it vanishes at a
particular coordinate value.

Selecting a component slice restricts only the scalar backgrounds. Every model
scalar component remains a fluctuation field, which becomes observable from
Milestone 3 onward when the fluctuation operator is derived. Milestone 2 derives
no fluctuation operator, so the slice affects only which monomials survive.

## 5. Contributions

### 5.1 Granularity

The artifact contains one contribution per model tensor kind that is present and
does not vanish under the background substitution. A contribution is the
complete sum over that tensor's stored components, not one monomial per
contribution.

Per-tensor granularity is chosen because a source tensor is the coherent
derivation unit with a single provenance, and because it keeps artifact size
proportional to the number of tensor kinds rather than to component count. This
follows [Effective-Potential Artifact §4.2](EFFECTIVE_POTENTIAL.md), which
permits a contribution to contain an internal sum.

### 5.2 Required metadata

Every contribution carries:

- `loop_order` equal to `0`;
- a role naming its originating tensor kind;
- provenance identifying the model tensor and the applied background map; and
- a dependency summary recording whether the value depends on background
  coordinates.

The vacuum-energy contribution is background independent. It MUST be retained by
default, per [Effective-Potential Artifact §7](EFFECTIVE_POTENTIAL.md). No
subtraction or reference normalization is applied.

### 5.3 Deterministic order

Contribution order is the tensor-kind order

```text
vacuum_energy
scalar_tadpole
scalar_mass_squared
scalar_cubic
scalar_quartic
```

independent of model source order, JSON member order, arena allocation, and
hash-table iteration.

## 6. Structural absences

A tensor kind that the model does not declare, or whose contribution vanishes
identically after the background substitution, is recorded as a structural
absence naming the kind and the reason.

A structural absence is a valid zero result. It MUST remain distinguishable from
an unsupported calculation, which produces a diagnostic and no artifact.

## 7. Derivatives

Gradient and Hessian capabilities are defined with respect to the ordered
background coordinates.

Both schema version 0.1 background modes are linear embeddings
\(\bar\phi=Bb\) with \(B\) a selection matrix whose entries are 0 or 1, so
[Background Parametrization §9](../formats/BACKGROUND_PARAMETRIZATION.md) gives

\[
\nabla_bV_{\mathrm{slice}}=B^{T}\nabla_\phi V_{\mathrm{tree}},
\qquad
H_b=B^{T}H_\phi B.
\]

Because the exact zeros are substituted before differentiation, derivation
differentiates the restricted value directly with respect to its coordinates;
the chain rule above is the equivalence this must satisfy, and is a required
test rather than an implementation step.

The differentiation method is exact symbolic differentiation of the Typed Value
IR before lowering, selected in
[Decision 0003](../decisions/0003-derivative-method.md). Each contribution is
differentiated separately so loop order and provenance survive.

The restricted gradient and Hessian are distinct objects from the full scalar
tadpole vector and full scalar fluctuation Hessian evaluated on the slice. The
latter two retain components transverse to the slice and MUST NOT be
reconstructed by padding the restricted derivatives with zeros. Milestone 2
exposes only the restricted objects and names them as such.

## 8. Validation and testing

Required tests include:

- the summed artifact equals the fixture `exact_identities.tree_potential` for
  `scalar.phi4` and `scalar.multi_scalar`;
- the orbit coefficient is correct for every multiplicity pattern occurring at
  ranks 1 through 4;
- gradient and Hessian agree with the fixture `tree_gradient` and
  `tree_hessian` identities and with independently written polynomial
  references;
- the chain-rule identities of section 7 hold for a component slice;
- every unselected scalar background is exactly zero and its monomials are
  structurally absent;
- structural absences are distinguishable from unsupported requests;
- the background-independent vacuum-energy contribution is retained;
- contribution order is deterministic under different derivation schedules;
- selection followed by summation agrees with a direct reference sum and leaves
  the unsummed artifact inspectable;
- every retained contribution has mass dimension 4; and
- derivation is fuzzed through the request and model boundaries with a permanent
  regression corpus.

## 9. Deferred decisions

This specification deliberately does not fix:

- loop contributions and their spectral structure;
- counterterms and renormalization-scale dependence;
- explicit subtraction or normalization requests;
- full tadpole and fluctuation-Hessian public APIs; or
- contribution-group query syntax.
