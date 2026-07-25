# QFT Model Format: Parameters and Source Versioning

Status: initial specification

This document specifies symbolic parameter declarations and source-schema
version handling for the human-authored Phaser QFT Model Format.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

A model declares symbolic independent parameters. Numerical values at a
reference scale belong to a separate parameter point as specified in
[Renormalization Scales, Parameter Points, and RG Evolution](RENORMALIZATION_GROUP.md).

Schema version `phaser.qft-model/0.1` supports real independent parameters only.
It does not support derived parameters, aliases, distributions, complex
parameters, or semantic range assumptions.

## 2. Source form

Parameters are members of the required top-level `parameters` object:

```json
{
  "schema": "phaser.qft-model/0.1",
  "parameters": {
    "mu2": {
      "domain": "real",
      "mass_dimension": 2,
      "label": "scalar mass squared",
      "latex": "\\mu^2",
      "description": "Optional non-semantic documentation."
    },
    "lambda": {
      "domain": "real",
      "mass_dimension": 0
    }
  }
}
```

The `parameters` object is required and MAY be empty. JSON member order has no
semantic meaning. Duplicate members MUST be rejected by the JSON boundary.

## 3. Parameter identifiers

The object key is the parameter's stable source identifier. It:

- MUST match `[A-Za-z_][A-Za-z0-9_]*`;
- MUST be unique within `parameters`;
- is case-sensitive;
- occupies a namespace distinct from field identifiers; and
- MUST NOT be `pi`, `sqrt`, or `i`, which are reserved by the model expression
  language.

Phaser MUST NOT infer a scheme, scale, physical role, sign, or allowed range
from an identifier.

## 4. Declaration properties

Every parameter declaration contains exactly:

- required `domain`, whose only version 0.1 value is `"real"`;
- required `mass_dimension`, a JSON integer representable by `i16`; and
- optional `label`, `latex`, and `description` strings.

Unknown properties are rejected. Presentation properties are non-semantic and
MUST NOT affect model identity, parameter ordering, tensor values, or numerical
results.

Mass dimension is signed because exact model expressions may combine parameters
through multiplication and division. Renormalizability is checked on completed
model tensors and operators, not inferred from one parameter declaration.

Version 0.1 has no `default`, `value`, `derived`, `expression`, `minimum`,
`maximum`, `positive`, or `nonzero` property. Such behavior would introduce
parameter-point or domain assumptions into the structural model.

## 5. Resolution and canonical ordering

Every ordinary identifier in a model expression resolves to exactly one
declared parameter. Unknown identifiers are errors. Unused declarations are
permitted because separate supported calculations may use different tensor
subsets.

Canonical Model IR orders parameters by the unsigned ASCII byte order of their
identifiers. Because version 0.1 identifiers are ASCII, this is also UTF-8 byte
order. Source JSON object order and hash-map iteration order MUST NOT affect
canonical IDs, serialization, or model fingerprints.

Presentation metadata remains associated with the resolved parameter but is
excluded from scientific identity.

## 6. Source-schema versioning

The top-level `schema` property is required and MUST equal
`"phaser.qft-model/0.1"`.

Version 0.1 behavior is strict:

- an absent, malformed, or unknown schema identifier is rejected;
- unknown top-level and nested properties are rejected unless their owning
  specification explicitly allows metadata or extensions;
- no unknown minor version is treated as compatible;
- no best-effort migration or downgrade occurs; and
- a model is validated entirely under the one declared schema version.

The normalized schema version is semantic model content and participates in
canonical model identity.

A future schema migration is an explicit source-to-source or source-to-canonical
operation with diagnostics and tests. Loading a newer document MUST NOT silently
discard fields or reinterpret conventions.

## 7. Dimensional validation

Parameter references carry their declared mass dimensions into the exact model
expression type checker. Completed tensor expressions MUST match the dimension
required by their tensor kind and spacetime dimension.

Dimension arithmetic is exact signed-integer arithmetic. Overflow of the
implementation's bounded dimension representation is a resource or validation
error, not wrapping behavior.

## 8. Validation and testing

Tests MUST cover:

- empty and populated parameter objects;
- every invalid identifier class and reserved identifier;
- missing, unknown, and invalid-domain properties;
- signed mass-dimension boundaries and overflow;
- duplicate JSON members;
- unknown and unused parameters;
- deterministic canonical ordering under object-member permutations;
- separation of presentation metadata from scientific identity;
- strict rejection of unknown source versions and properties; and
- parameter declarations and uses in the scalar conformance fixtures.

Parser resource limits and arbitrary-byte fuzzing are introduced with the model
parser in Milestone 1.

## 9. Deferred decisions

Later schema versions may specify:

- complex parameter values;
- derived-parameter declarations;
- typed assumptions used by a proven transformation;
- unit systems beyond the containing parameter-point contract;
- explicit compatibility or migration paths; and
- a public canonical JSON representation.
