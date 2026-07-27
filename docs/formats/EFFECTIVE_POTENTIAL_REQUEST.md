# Effective-Potential Calculation Request

Status: provisional specification

This document specifies the source schema of the `effective_potential`
calculation request and the subset of it supported through Milestone 3. It refines
section 8 of [Phaser Calculation Format](CALCULATION_FORMAT.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

This specification fixes:

- the request envelope accepted for `kind: effective_potential`;
- the `background`, `environment`, `renormalization`, and `orders` sub-schemas;
- which combinations through Milestone 3 are supported;
- the rejection behavior for every unsupported combination; and
- the normalized encoding that contributes to calculation identity.

It does not specify the derived artifact, which is governed by
[Effective-Potential Artifact](../calculations/EFFECTIVE_POTENTIAL.md) and, for
the tree-level slice, by
[Classical Scalar Potential](../calculations/CLASSICAL_SCALAR_POTENTIAL.md), and
for the order-one scalar contribution by
[Zero-Temperature One-Loop Scalar Effective Potential](../calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).

## 2. Request envelope

A complete request has the form:

```json
{
  "schema": "phaser.calculation/0.1",
  "kind": "effective_potential",
  "background": {
    "mode": "full_scalar_space"
  },
  "environment": {
    "kind": "vacuum"
  },
  "orders": {
    "loop": {
      "through": 1
    }
  },
  "renormalization": {
    "scheme": "MSbar"
  }
}
```

For schema version `phaser.calculation/0.1`:

- `schema` is required and MUST equal `phaser.calculation/0.1`.
- `kind` is required and MUST equal `effective_potential` for this schema.
- `background`, `environment`, and `orders` are required.
- `renormalization` is conditionally required as specified in section 5.
- `gauge_fixing` is accepted only as specified in section 6.
- Property names are case-sensitive.
- Unknown properties are rejected with `unknown_property`.
- Duplicate JSON member names are rejected with `duplicate_property` rather
  than resolved by a first- or last-value rule.
- Object member order has no semantic meaning.

A request document does not embed or identify its model. It is applied to an
already loaded canonical model as specified in
[Phaser Calculation Format §3](CALCULATION_FORMAT.md).

## 3. Background

The `background` object follows
[Background Parametrization](BACKGROUND_PARAMETRIZATION.md). Both schema
version 0.1 modes are supported:

```json
{
  "background": {
    "mode": "full_scalar_space"
  }
}
```

```json
{
  "background": {
    "mode": "component_slice",
    "coordinates": [
      { "id": "h", "scalar": "h" }
    ]
  }
}
```

Validation MUST reject:

- an unknown `mode`;
- any property other than `mode` under `full_scalar_space`;
- an empty or absent `coordinates` array under `component_slice`;
- a coordinate `id` that does not match `[A-Za-z_][A-Za-z0-9_]*`;
- a duplicate coordinate `id`;
- a `scalar` that names no real scalar declared by the model; and
- the same `scalar` selected by more than one coordinate.

Coordinate order is the declared array order and is semantic. Two requests
selecting the same scalars in different orders are distinct calculations.

## 4. Environment

```json
{
  "environment": {
    "kind": "vacuum"
  }
}
```

`kind` is required. Milestones 2 and 3 support only `vacuum`. Any other value,
including a finite-temperature environment, is rejected with
`unsupported_environment`.

No other property is permitted under `environment` in schema version 0.1.

## 5. Renormalization

```json
{
  "renormalization": {
    "scheme": "MSbar"
  }
}
```

The tree-level potential carries no renormalization-scheme dependence and no
renormalization-scale input. Accordingly:

- When `orders.loop.through` is `0`, `renormalization` is optional. If present,
  `scheme` is required and MUST equal `MSbar`; the value is recorded in artifact
  metadata and does not affect the derived value.
- When `orders.loop.through` is at least `1`, `renormalization` is required.
  Omitting it is rejected with `missing_property`.

This preserves the rule in
[Phaser Calculation Format §6.2](CALCULATION_FORMAT.md) that a request MUST NOT
silently select a scheme when the calculation depends on that choice, without
requiring an inert declaration at tree level.

No other property is permitted under `renormalization` in schema version 0.1.
The numerical renormalization scale is dynamic and MUST NOT appear here.

### 5.1 Scheme consistency

The scheme of this request governs the *derivation*. It does not describe the
numerical parameter values, which carry their own scheme and reference scale on
the parameter point specified by
[Renormalization Scales, Parameter Points, and RG Evolution §3](RENORMALIZATION_GROUP.md).

Making the request property optional at loop order zero therefore loses no
scheme information: the tree-level derivation is scheme independent, and the
scheme of the values remains declared where those values are supplied.

Because the parameters of one evaluation must all be renormalized in one scheme,
binding MUST reject a parameter point whose declared scheme differs from a
scheme declared by the artifact. Contributions within one artifact MUST share
one scheme context; a single potential MUST NOT combine contributions
renormalized in different schemes.

The check is implemented. It is also vacuous while `MSbar` is the only
supported scheme, because no pair of declarations can differ. It becomes
effective when a second scheme is supported, and a conformance tripwire fails at
that point so the mismatch case is not left untested.

## 6. Gauge fixing

Gauge fixing is required only by calculations that include gauge-fixed
propagators or fluctuation operators. Milestone 3 derives only the real-scalar
fluctuation operator and still supports no model containing gauge vectors.

A `gauge_fixing` property present in a Milestone 2 or 3 request is rejected with
`unsupported_gauge_fixing`. The property is reserved for the milestone that
introduces the general gauge family specified in
[Gauge Fixing and Gauge Parameters](GAUGE_FIXING.md).

Rejection is explicit rather than silent acceptance of an ignored property.

## 7. Perturbative orders

```json
{
  "orders": {
    "loop": {
      "through": 1
    }
  }
}
```

`orders.loop.through` is required and MUST be a non-negative integer, with
semantics specified in
[Perturbative Order and Power-Counting Boundary](PERTURBATIVE_ORDER.md).

Milestone 3 supports `through: 0` and `through: 1`. Because `through` is an
inclusive truncation, `through: 1` requests the tree contribution and the
zero-temperature real-scalar one-loop contribution. A request for a higher
order is rejected with `unsupported_loop_order` and names `1` as the highest
supported order in its diagnostic detail.

Truncation MUST NOT erase the loop order or provenance of retained
contributions.

## 8. Model compatibility

The complete Milestone 3 supported combination is:

- a four-dimensional canonical model with zero or more real scalar components
  and no Weyl fermions or gauge vectors;
- `vacuum`;
- either version 0.1 background mode;
- `through: 0` or `through: 1`; and
- `MSbar` whenever a scheme is declared, with the declaration required for
  `through: 1`.

At `through: 1`, the fluctuation space is the model's complete real-scalar
component space even when the background is a component slice. No fermion,
gauge, ghost, thermal, resummed, or higher-loop contribution is silently
omitted from a request that purports to include it; those combinations are
unsupported.

Planning validates the request against the canonical model. It MUST reject:

- a model whose `spacetime_dimension` is not 4, with `unsupported_sector`;
- a model declaring Weyl fermions or gauge vectors, with `unsupported_sector`;
  and
- a `component_slice` naming a scalar the model does not declare, with
  `invalid_background_coordinate`.

A model declaring no real scalars is valid. Its `full_scalar_space` background
has zero coordinates, and its effective potential is a background-independent
constant.

Tensor kinds absent from the model are structural absences, not failures. They
are recorded as specified in
[Classical Scalar Potential §6](../calculations/CLASSICAL_SCALAR_POTENTIAL.md).

### 8.1 Targeted rejection cases

Conformance coverage distinguishes at least:

- missing `renormalization` at `through: 1` as `missing_property`;
- any scheme other than case-sensitive `MSbar` as `unsupported_scheme`;
- `through: 2` and larger values as `unsupported_loop_order`;
- a non-vacuum environment as `unsupported_environment`;
- any `gauge_fixing` block as `unsupported_gauge_fixing`;
- any declared Weyl-fermion or gauge-vector sector as `unsupported_sector`;
- a spacetime dimension other than four as `unsupported_sector`; and
- an invalid component slice as `invalid_background_coordinate`.

These cases are rejected during parsing or planning as applicable. They MUST
NOT fall back to a tree-only result, a scalar-only projection of a broader
model, another renormalization scheme, or a full-scalar background.

## 9. Resource limits

Request parsing and planning are subject to caller-selected limits with
documented hard ceilings, following the model-limit pattern established in
Milestone 1:

```text
request_bytes
request_json_tokens
request_json_nesting
background_coordinates
```

A limit at zero or above its hard ceiling is rejected with `invalid_limit`
before any parsing occurs. Exceeding a limit during parsing is an ordinary
capacity diagnostic, never a partial request.

## 10. Normalization and identity

A validated request is normalized before it contributes to calculation identity.
Normalization MUST:

- resolve every `scalar` reference to its model scalar index;
- preserve declared coordinate order;
- encode the background mode and the complete coordinate-to-scalar map;
- encode the environment kind and loop truncation;
- encode the renormalization scheme only when it can affect the derivation,
  which is from loop order one onward; and
- exclude `label`, `latex`, and `description` presentation metadata.

Omitting an inert scheme from the encoding means the two spellings of a tree
request — with and without a `renormalization` block — share one calculation
identity, which matches the fact that they derive the same potential. The
declaration is still retained in artifact metadata for provenance and for the
binding-time consistency check of section 5.1.

The canonical encoding is domain-separated under
`calculation-request-canonical/1` and hashed with SHA-256, matching the model
fingerprint construction in
[Content Fingerprints and Deferred Caching §3](../architecture/CONTENT_IDENTITY_AND_CACHING.md).

The semantic identity of a planned calculation is the pair of the model
fingerprint and the normalized request fingerprint. Neither the hexadecimal
rendering nor the canonical byte stream is a stable interchange contract.

## 11. Validation and testing

Required tests include:

- every supported request parses and normalizes deterministically;
- normalization is idempotent and independent of JSON member order;
- unknown, duplicate, and misplaced properties are rejected individually;
- each unsupported environment, gauge-fixing, and loop-order case produces its
  specified diagnostic code;
- `renormalization` is optional at order 0 and required above it;
- `through: 1` retains separately identifiable tree and scalar-loop
  contributions;
- every targeted rejection in section 8.1 produces its owned diagnostic;
- coordinate-order changes produce distinct request fingerprints;
- presentation metadata does not change a request fingerprint;
- capacity limits are enforced at exact boundaries; and
- request parsing is fuzzed with a permanent seed and regression corpus.

## 12. Deferred decisions

This specification deliberately does not fix:

- contribution-selection and diagram-filter syntax;
- finite-temperature environment properties;
- the gauge-fixing sub-schema;
- explicit subtraction or normalization policies; and
- request schemas for other calculation kinds.
