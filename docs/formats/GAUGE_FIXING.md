# Gauge Fixing and Gauge Parameters

Status: provisional specification

This document specifies the initial gauge-fixing families, their calculation
request representation, and the treatment of gauge parameters in Phaser. It
refines section 10 of [DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

The initial design follows the conventions and gauge-family organization of
[Martin and Patel](https://arxiv.org/abs/1808.07615).

## 1. Scope

Gauge fields and flattened gauge-interaction tensors belong to the QFT model.
Gauge fixing is selected by a calculation request. The model convention is
specified in [QFT Model Format: Gauge Tensors](QFT_MODEL_GAUGE_TENSORS.md).

Phaser initially supports:

- generalized background-field \(R_{\xi,\widetilde\xi}\) gauge;
- Fermi gauge as a specialization;
- background-field \(R_\xi\) gauge as a specialization; and
- Landau gauge as a dedicated limiting specialization.

The generalized background-field \(R_{\xi,\widetilde\xi}\) family is the most
general gauge-fixing family Phaser initially implements. It is not the most
general gauge fixing mathematically possible.

Version 0.1 does not support:

- a full matrix \(\xi_{ab}\);
- arbitrary independent tensors \(\widetilde\phi^a_j\);
- nonlinear gauge-fixing functions;
- unitary gauge;
- user-defined gauge-fixing functionals; or
- implicit selection of a gauge.

## 2. Gauge-family convention

In the Martin--Patel notation, the family has the schematic gauge-fixing
Lagrangian

\[
\mathcal L_{\mathrm{gf}}
=
-\frac{1}{2}\sum_a\frac{1}{\xi_a}
\left(
\partial^\mu A^a_\mu
+ \widetilde\xi_a\phi_j g^a{}_{jk}R_k
\right)^2,
\]

where \(R_k\) denotes a scalar fluctuation around the background
\(\phi_j\), and \(g^a{}_{jk}=i g_at^a{}_{jk}\) is the real antisymmetric
flattened scalar gauge tensor. The parameters \(\xi_a\) and
\(\widetilde\xi_a\) are independent in the general family.

The displayed sign follows the defining covariant derivative
\(D_\mu R_i=\partial_\mu R_i-g^a{}_{ij}A_\mu^aR_j\). In particular, the
background-field \(R_\xi\) specialization MUST cancel the scalar--vector kinetic
cross terms.

The index \(a\) is the ordered gauge-vector component index declared by the
model. Version 0.1 takes \(\xi\) and \(\widetilde\xi\) to be diagonal in that
declared gauge-vector basis.

For a generator unbroken by the selected background, the
background-dependent scalar term vanishes through the model tensors; Phaser
MUST NOT infer this from a gauge-vector name.

## 3. Supported families

The calculation request uses one of four family identifiers.

### 3.1 Generalized background-field \(R_{\xi,\widetilde\xi}\)

```json
{
  "gauge_fixing": {
    "family": "generalized_background_r_xi",
    "parameters": {
      "xi": {
        "B": "xi_B",
        "W1": "xi_W",
        "W2": "xi_W",
        "W3": "xi_W"
      },
      "xi_tilde": {
        "B": "xi_tilde_B",
        "W1": "xi_tilde_W",
        "W2": "xi_tilde_W",
        "W3": "xi_tilde_W"
      }
    }
  }
}
```

Both parameter maps are required. Their numerical values are independent unless
the maps deliberately use a shared binding channel.

### 3.2 Fermi gauge

Fermi gauge imposes

\[
\widetilde\xi_a=0
\]

while retaining dynamic \(\xi_a\):

```json
{
  "gauge_fixing": {
    "family": "fermi",
    "parameters": {
      "xi": {
        "B": "xi_B",
        "W1": "xi_W",
        "W2": "xi_W",
        "W3": "xi_W"
      }
    }
  }
}
```

The `xi_tilde` property is invalid for this specialized request.

### 3.3 Background-field \(R_\xi\) gauge

Background-field \(R_\xi\) gauge imposes

\[
\widetilde\xi_a=\xi_a.
\]

Only the independent \(\xi_a\) channels are declared:

```json
{
  "gauge_fixing": {
    "family": "background_r_xi",
    "parameters": {
      "xi": {
        "B": "xi_B",
        "W1": "xi_W",
        "W2": "xi_W",
        "W3": "xi_W"
      }
    }
  }
}
```

The `xi_tilde` property is invalid for this specialized request. The planner
derives it from `xi`.

### 3.4 Landau gauge

Landau gauge is the limit

\[
\widetilde\xi_a=0,
\qquad
\xi_a\rightarrow0.
\]

It has no dynamic gauge parameters:

```json
{
  "gauge_fixing": {
    "family": "landau"
  }
}
```

Landau gauge MUST be implemented as a structural limit. A generic or Fermi-gauge
kernel MUST NOT accept `xi = 0` as a substitute when its derived expressions
contain \(1/\xi_a\) or otherwise assume nonzero \(\xi_a\).

## 4. Parameter maps

For every parameter map:

- each key is a gauge-vector ID from the input model;
- every gauge-vector component MUST occur exactly once;
- unknown or duplicate gauge-vector IDs are rejected;
- duplicate JSON member names are rejected;
- each value is a gauge-parameter binding-channel ID;
- a channel ID MUST match `[A-Za-z_][A-Za-z0-9_]*`;
- object member order has no semantic meaning; and
- no numerical gauge-parameter value occurs in the calculation request.

Channel IDs are scoped to the entire `gauge_fixing` object. Using the same
channel ID more than once, including across the `xi` and `xi_tilde` maps,
constrains those entries to the same dynamic value. In the examples, `W1`,
`W2`, and `W3` share `xi_W`. Phaser MUST NOT infer such equality from gauge
groups, field names, or representations.

Binding-channel IDs occupy a gauge-parameter namespace separate from model
parameters, background coordinates, scales, and temperature.

A future repeated-channel shorthand MAY lower to the explicit per-vector map.
The canonical request representation remains explicit.

## 5. Structural and dynamic data

The following are structural and contribute to calculation identity:

- gauge-fixing family;
- gauge-vector-to-channel maps;
- relations imposed by a specialized family; and
- any future specialization assumptions.

Numerical values of non-fixed gauge parameters are dynamic and do not alter
calculation identity.

A kernel derived for the general family may evaluate:

- a Fermi point by binding every `xi_tilde` channel to zero; or
- a background-field \(R_\xi\) point by tying corresponding `xi_tilde` and
  `xi` values.

Alternatively, a caller may request a specialized Fermi or background-field
\(R_\xi\) artifact. Specialized derivation MAY simplify propagators,
quadratic operators, vertices, expressions, and workspace.

The general-family and specialized artifacts MUST agree wherever their
scientific conditions and numerical domains coincide.

Binding a general-family kernel at a special parameter point does not silently
create or cache a specialized artifact.

## 6. Dynamic gauge-parameter values

Gauge parameters are dimensionless real numerical inputs. Their numerical
spelling and conversion follow the finite JSON-number rules of
[Renormalization Scales, Parameter Points, and RG Evolution](RENORMALIZATION_GROUP.md#4-numerical-values),
although their serialized binding format remains to be specified.

For non-Landau families:

- every required channel MUST be bound exactly once;
- `xi` MUST be finite and nonzero;
- `xi_tilde` MUST be finite and MAY be zero; and
- unknown or missing channels are errors.

Negative or large parameter values are not rejected solely by the source schema.
They may lead to non-convergent fixed-order behavior, complex squared masses, or
unsupported numerical operations. The calculation and numerical backend MUST
report such conditions explicitly.

The limit \(\xi\rightarrow\infty\) is not treated as unitary gauge.

## 7. Derived structures

The selected gauge fixing determines or affects:

- gauge-fixing terms;
- ghost fields, masses, and interactions;
- scalar--vector kinetic mixing;
- longitudinal-vector propagator structure;
- Goldstone and unphysical scalar sectors;
- field-dependent quadratic operators;
- vertices; and
- effective-potential contributions.

These are calculation data, not additions to the fundamental QFT model.

Quadratic-operator IR MUST represent mixed scalar--vector blocks in gauges where
they occur. It MUST NOT assume that every calculation reduces immediately to
separate scalar and vector mass matrices.

Background-field \(R_\xi\) specialization MUST cancel the scalar--vector kinetic
mixing implied by the background shift. Fermi and general-family derivations
MUST retain mixed blocks whenever their coefficients do not cancel.

Ghost contributions MUST NOT be omitted merely because an individual numerical
point makes one of their masses vanish.

## 8. RG treatment

Gauge-parameter values are separate from the model parameter point. When their
beta functions are available, the general family may treat \(\xi_a\) and
\(\widetilde\xi_a\) as independently running quantities.

Phaser distinguishes:

1. **Fixed at the calculation scale.** Model parameters are supplied or evolved
   to \(\mu_R\), then gauge parameters are bound at that scale.
2. **Run in the general family.** Independent gauge parameters are evolved with
   a closed set of gauge-parameter beta functions.
3. **Reimpose a specialization at the calculation scale.** General parameters
   are evolved to \(\mu_R\), then a relation such as
   \(\widetilde\xi_a=\xi_a\) is imposed there.

The background-field \(R_\xi\) relation is not generally invariant under RG
evolution. Reimposing it at a new scale is an explicit projection or boundary
prescription, not evolution within an invariant subfamily. The provenance MUST
record this choice.

Phaser MUST NOT silently evolve `xi` while assuming that
`xi_tilde == xi` remains true.

Failure of a specialized gauge condition to be RG invariant does not make that
gauge unsupported. It requires an explicit scale prescription.

## 9. Gauge dependence

Gauge-dependent intermediate quantities are valid calculation results. The
off-shell effective potential and the location of its extrema generally depend
on gauge fixing.

Properly defined physical observables are expected to be gauge independent when
all required contributions are combined consistently. A finite-loop
calculation may retain residual gauge dependence and MUST NOT be presented as
exactly gauge independent.

Gauge-parameter scans are supported as diagnostics. Calculation artifacts and
kernel metadata MUST retain the family, parameter channels, specialized
relations, and bound values needed to reproduce such a scan.

Large gauge parameters may expose a breakdown of fixed-order perturbation
theory. Phaser SHOULD make numerical warnings and complex-result policies
available rather than silently discarding imaginary parts or unstable regions.

## 10. Calculation-request rules

A calculation on a model with gauge vectors MUST explicitly select gauge fixing
when gauge-fixed propagators or fluctuation operators are required. There is no
implicit Landau-gauge default.

A calculation on a model without gauge vectors MUST omit `gauge_fixing`.

The planner MUST reject:

- an unknown family;
- properties not allowed by the selected family;
- incomplete or invalid parameter maps;
- a family unsupported for the requested calculation, loop order, scheme, or
  environment; and
- gauge fixing supplied where it has no meaning.

The support matrix is explicit. Supporting a family at one loop or in a
four-dimensional vacuum calculation does not imply support at every loop order,
at finite temperature, or in a 3D EFT.

## 11. Numerical and symbolic outputs

Every affected calculation artifact records:

- gauge-fixing family;
- canonical parameter maps;
- imposed family relations;
- gauge-parameter dependency names;
- RG or fixed-at-scale prescription when applicable; and
- the gauge convention version.

Symbolic export MUST reproduce enough information to identify the gauge fixing
used. A numerical kernel MUST list gauge-parameter channels and their canonical
buffer order in its metadata.

If a backend cannot evaluate complex masses or loop functions produced at a
valid gauge-parameter point, it MUST return an unsupported-domain diagnostic.
It MUST NOT silently take a real part unless the calculation request explicitly
selects a future policy that permits doing so.

## 12. Validation and testing

Architecture-wide scientific conformance and comparison rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Required tests include:

- parameter-map coverage, tying, and namespace validation;
- derivation of ghost terms and interactions;
- scalar--vector mixing in general and Fermi gauges;
- cancellation of that mixing in background-field \(R_\xi\) gauge;
- a structural Landau limit without division by zero;
- agreement between general-family bindings and specialized artifacts;
- structurally absent gauge sectors;
- deterministic request normalization and structural metadata;
- RG running versus fixed-at-scale and reimposed-specialization policies;
- preservation of gauge metadata through symbolic and numerical lowering;
- gauge-parameter scans of known conformance models;
- diagnostics for complex or unsupported numerical regions; and
- fuzzing of family tags, parameter maps, and dynamic bindings.

Where a physical quantity is known to be gauge independent through a stated
order, conformance tests SHOULD verify the expected cancellation or residual
higher-order dependence. Such a test MUST state the perturbative prescription
and must not assume that arbitrary fixed-order quantities are gauge independent.

## 13. Deferred decisions

The following are intentionally deferred:

- full matrix-valued \(\xi_{ab}\);
- arbitrary \(\widetilde\phi^a_j\);
- nonlinear and user-defined gauge fixing;
- exact gauge-parameter beta functions and trajectory serialization;
- compact repeated-channel parameter-map syntax;
- detailed complex-mass and imaginary-part policies;
- Nielsen-identity checks;
- finite-temperature and 3D support matrices; and
- additional gauge families.
