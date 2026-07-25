# Renormalization Scales, Parameter Points, and RG Evolution

Status: provisional specification

This document specifies the representation and lifecycle of renormalized
parameter points, renormalization scales, RG-function calculations, and RG
evolution in Phaser. It refines section 9 of [DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

Phaser distinguishes:

- symbolic parameters declared by a QFT model;
- a numerical parameter point specified at a reference scale;
- RG functions derived under a declared scheme and conventions;
- RG evolution from one scale to another; and
- the explicit renormalization scale used by a calculation or kernel.

Renormalization data is not thermal state. Temperature, thermal matching scales,
and EFT factorization scales have separate roles even when an orchestration
policy chooses numerical relations among them.

Version 0.1 does not provide automatic threshold matching, scheme conversion, or
RG improvement of a potential.

## 2. Scale terminology

The **reference scale** \(\mu_0\) is the scale at which a parameter point's
values are specified.

The **renormalization scale** \(\mu_R\) is the explicit scale used by a
calculation, including logarithms such as
\(\log(m^2/\mu_R^2)\).

A calculation may later introduce other typed scale roles, including thermal
matching or EFT factorization scales. A generic unlabelled `mu` value MUST NOT
stand for multiple scale roles.

Every numerical scale MUST be finite, strictly positive, and expressed in the
mass unit declared by its containing object.

## 3. Parameter Point Format

A version 0.1 parameter point has the source form:

```json
{
  "schema": "phaser.parameter-point/0.1",
  "units": {
    "mass": "GeV"
  },
  "renormalization": {
    "scheme": "MSbar",
    "reference_scale": 91.1876
  },
  "values": {
    "g1": 0.357,
    "g2": 0.652,
    "lambda_h": 0.126,
    "mu2": 7812.5
  }
}
```

The properties have these semantics:

- `schema` is required and MUST equal `phaser.parameter-point/0.1`.
- `units` is required.
- `units.mass` is required and case-sensitive. Version 0.1 supports `GeV`.
- `renormalization` is required.
- `renormalization.scheme` is a required, case-sensitive scheme identifier.
- `renormalization.reference_scale` is the required value of \(\mu_0\) in the
  declared mass unit.
- `values` is required and maps model parameter IDs to numerical values.
- Unknown properties are rejected.

A parameter point is applied to an already loaded model. It does not embed the
model or its hash:

```text
validate_parameter_point(model, point)
```

The semantic identity of a validated point includes both the canonical model
identity and the normalized point identity.

### 3.1 Dimensionful values

If a model parameter has mass dimension \(d\), its numerical value is expressed
in

\[
(\texttt{units.mass})^d.
\]

For example, a mass-squared parameter has units of `GeV^2` when
`units.mass` is `GeV`. Individual values do not repeat their units.

Unit conversion is not implicit. A future unit-conversion utility may produce a
new normalized parameter point.

### 3.2 Coverage and names

Every required independent model parameter MUST occur exactly once in `values`.
Unknown parameter IDs are rejected. A missing required parameter is an error.
Duplicate JSON member names MUST be rejected rather than resolved using a
first- or last-value rule. Object member order has no semantic meaning.

An identically zero value is written explicitly as `0`; omission does not mean
zero.

Aliases, derived parameters, partially specified points, and distributions over
parameters are outside version 0.1.

## 4. Numerical values

Parameter values and scales use standard JSON number syntax. Integer, decimal,
and scientific-notation spellings are permitted:

```json
{
  "integer": 1,
  "decimal": 0.125,
  "scientific": 1.25e-3
}
```

These numbers are not QFT Model expression strings. They cannot contain
parameters, arithmetic, `pi`, or `sqrt`.

Version 0.1 parses directly to its supported production scalar type, initially
`f64`, without promising a persistent exact-decimal identity. Negative zero
normalizes to zero. Implementations MUST impose documented bounds on significant
digits and decimal exponent.

A future additional scalar type may provide its own direct conversion path.
Parameter-point fingerprinting and bound-state caching are deferred according to
[Content Fingerprints and Deferred Caching](../architecture/CONTENT_IDENTITY_AND_CACHING.md).

NaN and positive or negative infinity are invalid. Overflow, underflow that
changes a nonzero value to zero, or inability to represent a value in the
requested numerical type MUST produce a diagnostic rather than silent
conversion.

Version 0.1 parameter points contain real values. Complex parameter encoding is
deferred until complex model parameters are specified.

## 5. Renormalization schemes

Scheme identifiers are case-sensitive. The calculation request, RG-function
artifact, parameter point, and bound kernel MUST use compatible schemes.

Changing only a scheme label does not convert a parameter point. A scheme
conversion is an explicit calculation with its own perturbative order and
provenance.

`MSbar` is the initial scheme name used by the design examples. The exact
support matrix by calculation kind, model class, and loop order is reported by
the implementation rather than inferred from the identifier.

## 6. RG functions

RG functions are calculation results, not properties stored in the fundamental
QFT model.

An `rg_functions` request specifies at least:

- the renormalization scheme;
- the requested loop truncation; and
- any calculation-specific gauge-fixing context needed by the requested
  outputs.

Gauge-fixing families, gauge-parameter channels, and their scale prescriptions
are specified in [Gauge Fixing and Gauge Parameters](GAUGE_FIXING.md).

Its artifact may contain:

- beta functions for dimensionless and dimensionful model parameters;
- the vacuum-energy beta function;
- scalar and fermion anomalous-dimension matrices; and
- gauge-parameter beta functions.

Every expression is loop-resolved according to
[Perturbative Order and Power-Counting Boundary](PERTURBATIVE_ORDER.md).

For a renormalized parameter \(p_a\), Phaser uses

\[
\beta_{p_a}
\equiv
\mu_R\frac{d p_a}{d\mu_R}
=
\frac{d p_a}{d\ln\mu_R}.
\]

An identically zero beta function MUST be represented explicitly as zero in a
complete requested result. A missing beta function means unavailable or not
requested; it MUST NOT be interpreted as zero.

The artifact MUST record whether it is complete for the requested parameter set.
RG evolution may proceed only when the supplied functions form a closed system
for all evolved values.

RG functions may depend on model parameters, gauge parameters, and explicitly
on scale in a scheme where that is required. Every dependency MUST be declared.

## 7. Anomalous-dimension convention

For scalar fields, Phaser defines the anomalous-dimension matrix by

\[
\mu_R\frac{d\phi_i}{d\mu_R}
= -\gamma_i{}^j\phi_j.
\]

The same sign convention applies to analogous fermion field-renormalization
matrices. Index orientation and any complex conjugation rules for Weyl fermions
will be fixed by the fermion tensor specification.

With this convention, the scalar-background part of an RG operator contains

\[
-\gamma_i{}^j\phi_j\frac{\partial}{\partial\phi_i}.
\]

An anomalous-dimension artifact MUST record its field index spaces, basis,
scheme, gauge context, and loop order. Phaser does not infer a diagonal basis.

## 8. RG evolution

RG evolution is a numerical operation using an `rg_functions` artifact. It is
not another diagrammatic calculation kind.

With

\[
t = \ln(\mu/\mu_0),
\]

the evolution equations are

\[
\frac{d p_a}{dt} = \beta_{p_a}(p,\mu,\ldots).
\]

Conceptually:

```text
evolve(
    parameter_point_at_mu_0,
    rg_functions,
    target_scale,
    solver_configuration,
) -> parameter_point_at_target_scale
```

Evolution produces a new immutable parameter point whose reference scale is the
target scale. It MUST NOT mutate the boundary point.

The result provenance MUST identify:

- the boundary-point identity;
- RG-function artifact identity and loop truncation;
- source and target scales;
- numerical solver and relevant configuration;
- achieved error estimates or tolerances; and
- warnings or termination status.

A failure to reach the target scale, a singularity, a non-finite intermediate
value, or an unsatisfied error criterion MUST be reported. A partial trajectory
MUST NOT be presented as a successfully evolved target point.

## 9. Binding parameters to a calculation

RG evolution occurs outside the hot potential kernel:

```text
parameter point at mu_0
        |
        v
explicit RG evolution
        |
        v
parameter point at mu_R
        |
        v
kernel binding with explicit mu_R
```

The kernel receives:

- numerical parameter values intended for the evaluation scale; and
- the explicit renormalization-scale value used by its expressions.

The kernel MUST NOT solve RG equations implicitly during potential evaluation.

The API distinguishes these operations:

1. **Evolve then bind.** Evolve a boundary point to \(\mu_R\), then bind the
   resulting values and \(\mu_R\).
2. **Bind at the supplied scale.** Use a point whose reference scale already
   equals \(\mu_R\).
3. **Hold parameters fixed.** Bind values specified at one scale while varying
   the explicit \(\mu_R\), solely through an explicitly named diagnostic
   operation.

The third operation is intentionally not called RG evolution.

A normal binding MUST reject an unexplained mismatch between the parameter
point's reference scale and the kernel's renormalization scale.

## 10. Thermal state and scale policies

Temperature does not determine \(\mu_R\) automatically. An orchestration layer
may implement a policy such as \(\mu_R=cT\), but it MUST resolve that policy to
an explicit renormalization scale before kernel binding.

Likewise, thermal matching and EFT factorization scales remain separately typed
inputs. Equality among scale values does not make their semantic roles
interchangeable.

Varying \(\mu_R\) while holding temperature fixed and varying temperature while
holding \(\mu_R\) fixed are distinct operations.

## 11. Thresholds and scheme changes

Version 0.1 evolution assumes a fixed model and a fixed active field content
along the trajectory.

Crossing a particle threshold does not silently remove a field. Decoupling,
threshold matching, and changes of EFT are explicit future calculations that
produce new models or parameter points with provenance.

Changing renormalization scheme likewise requires an explicit conversion.
Neither operation is represented by relabelling an existing point.

## 12. RG consistency checks

For an effective potential, the RG operator has the schematic form

\[
\mathcal D
=
\mu_R\frac{\partial}{\partial\mu_R}
+ \sum_a \beta_{p_a}\frac{\partial}{\partial p_a}
- \gamma_i{}^j\phi_j\frac{\partial}{\partial\phi_i}
+ \cdots,
\]

where additional terms include any running gauge parameters or other dynamic
inputs required by the calculation.

Applying \(\mathcal D\) to a loop-truncated result should cancel through the
claimed perturbative accuracy, leaving terms of higher order. Phaser SHOULD use
this as an order-by-order consistency test where the necessary RG functions are
available.

The check MUST report the scheme, gauge context, loop truncations, and assumptions
used. It MUST NOT claim exact scale independence for a finite-order result.

## 13. Validation and testing

Architecture-wide numerical-comparison and scientific conformance rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Required validation includes:

- schema and unknown-property rejection;
- finite positive reference and target scales;
- known and compatible scheme identifiers;
- exact coverage of required model parameter IDs;
- parameter-domain and mass-dimension checks;
- deterministic conversion of accepted decimal JSON numbers to `f64`;
- direct conversion to every supported numerical scalar type;
- closure and dependency checks for RG functions;
- loop-order and provenance preservation;
- source/target scale and unit compatibility; and
- explicit rejection of implicit threshold or scheme changes.

Required tests include:

- equivalent decimal spellings convert to the same `f64` value where exactly
  representable;
- analytic RG flows with known solutions;
- identity evolution from a scale to itself;
- forward and reverse evolution within solver tolerances;
- rejection of incomplete beta-function systems;
- solver failure and singularity handling;
- distinction between fixed-parameter scale variation and RG evolution;
- RG-consistency checks order by order; and
- fuzzing of parameter-point parsing, numeric bounds, and evolution inputs.

## 14. Deferred decisions

The following remain to be specified:

- the full model-parameter declaration schema;
- additional mass units and unit conversion;
- complex parameter points;
- exact numerical ODE solvers and tolerance API;
- serialized gauge-parameter bindings and trajectories;
- threshold matching and EFT transitions;
- scheme-conversion calculations;
- RG-trajectory interpolation and caching; and
- RG improvement and optimized scale-setting policies.
