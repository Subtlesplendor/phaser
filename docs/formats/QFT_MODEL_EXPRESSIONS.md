# QFT Model Format: Expression Language

Status: provisional specification

This document specifies expression strings in the human-authored Phaser QFT
Model Format. It refines section 6.3 of [DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Purpose and scope

Model expressions describe exact relationships between model parameters. They
are used for values such as tensor components:

```json
{
  "indices": ["h", "h", "h", "h"],
  "value": "6 * lambda"
}
```

The language is:

- exact;
- deterministic;
- independent of any host programming language;
- small enough to parse, validate, fuzz, and serialize reliably; and
- incapable of performing assignment, control flow, I/O, or host evaluation.

This language is not the complete expression IR used for derived calculations.
Functions such as logarithms and thermal integrals may exist in the derived IR
without being legal in a model expression.

## 2. Character set and whitespace

The grammar uses ASCII tokens. JSON supplies the surrounding string encoding.

ASCII spaces, horizontal tabs, carriage returns, and line feeds MAY occur
between tokens and have no semantic meaning. Whitespace MUST NOT occur inside an
integer or identifier.

Unicode mathematical symbols such as `π`, `√`, and `−` are not tokens. Their
ASCII spellings are `pi`, `sqrt`, and `-`.

## 3. Grammar

The version 0.1 grammar is:

```text
expression       := sum
sum              := product (("+" | "-") product)*
product          := unary (("*" | "/") unary)*
unary            := ("+" | "-") unary | power
power            := primary ("^" unsigned_integer)?
primary          := unsigned_integer
                  | parameter_identifier
                  | "pi"
                  | "sqrt" "(" expression ")"
                  | "(" expression ")"
unsigned_integer := "0" | nonzero_digit digit*
nonzero_digit    := "1" | "2" | "3" | "4" | "5"
                  | "6" | "7" | "8" | "9"
digit            := "0" | nonzero_digit
```

`+`, `-`, `*`, and `/` are left-associative. Unary signs bind less tightly than
exponentiation, so `-2^2` means `-(2^2)`. An exponent applies only once;
`a^2^3` is invalid.

An exponent MUST be a non-negative integer literal. Negative powers are written
using division:

```text
1 / mu2
1 / g^2
```

Implicit multiplication is not permitted. For example, `2 pi`, `2(lambda)`, and
`g sqrt(2)` are invalid.

## 4. Numeric literals

The only numeric token is an unsigned base-ten integer. A negative integer is a
unary minus applied to an unsigned integer.

Leading zeros are not permitted except for the literal `0`.

These are valid:

```text
0
17
-3
1 / 2
-7 / 12
```

These are invalid:

```text
01
.5
0.5
1.
1e-3
0x10
NaN
inf
```

There is no decimal, scientific-notation, hexadecimal, NaN, or infinity literal.
Exact rational numbers are expressed using integer division. During
normalization, a rational value is stored as coprime integers with a positive
denominator.

Numerical parameter points are separate from model expressions. The
[Parameter Point Format](RENORMALIZATION_GROUP.md#3-parameter-point-format)
accepts decimal numerical values without adding decimals to this language.

## 5. Identifiers and built-ins

Every ordinary identifier in an expression MUST resolve to a parameter declared
by the same model. Field identifiers, background coordinates, temperature,
renormalization scale, gauge parameters, and numerical parameter-point values
are not in scope.

The lexical form of a parameter identifier is
`[A-Za-z_][A-Za-z0-9_]*`. Declaration, reserved-name, ordering, and source
version rules are specified in
[QFT Model Format: Parameters and Source Versioning](QFT_MODEL_PARAMETERS.md).

`pi` is a reserved built-in constant. It denotes the exact mathematical constant
\(\pi\), not a pre-rounded floating-point value.

`sqrt` is a reserved built-in function name. `i` is reserved and is not a valid
expression in version 0.1. Complex tensor components are represented
structurally outside this grammar according to
[QFT Model Format: Lagrangian and Fermion Tensors](QFT_MODEL_LAGRANGIAN.md#6-complex-component-values),
with their real and imaginary parts each using this real expression language.

A model MUST NOT declare a parameter named `pi`, `sqrt`, or `i`.

No other constants or functions are built in. In particular, version 0.1 has no
Euler constant, exponential, logarithm, trigonometric function, absolute value,
minimum, or maximum.

## 6. Square roots

The argument of `sqrt` is parsed as an expression and then constant-folded. The
result MUST be a strictly positive, dimensionless exact rational number.

These are valid:

```text
sqrt(2)
sqrt(3 / 5)
1 / sqrt(2)
sqrt((1 + 2) / 5)
```

These are invalid:

```text
sqrt(0)
sqrt(-1)
sqrt(lambda)
sqrt(m2)
sqrt(pi)
```

This restriction makes every square root an exact, real algebraic constant. It
avoids parameter-domain assumptions, branch choices, and dimensionful radicals.
Support for more general radicals requires a later schema version.

A rational perfect square MUST normalize to a rational value. Phaser is not
required to prove arbitrary algebraic equivalences between expressions
containing radicals.

## 7. Examples

Valid model expressions include:

```text
-mu2
6 * lambda
g / sqrt(2)
sqrt(3 / 5) * g1
g^2 / (16 * pi^2)
(lambda1 + lambda2) / 4
```

Invalid model expressions include:

```text
2lambda
lambda(h)
sin(theta)
log(mu2)
fields.h
g^-2
```

An otherwise valid identifier is rejected if the model does not declare it as a
parameter. Names such as `temperature` or `mu` introduced by a calculation are
not implicitly visible, though those spellings may be used for ordinary model
parameters. `g^-2` is invalid regardless of whether `g` is declared because
version 0.1 requires inverse powers to use division.

## 8. Exact internal representation

Parsing MUST produce an AST with source spans for diagnostics. Before a model
enters canonical Model IR, each expression MUST be name-resolved,
dimension-checked, and normalized.

The exact representation distinguishes at least:

- rational numbers;
- parameter references;
- the symbolic constant `pi`;
- exact square roots of positive rationals;
- addition and subtraction;
- multiplication and division;
- unary negation; and
- non-negative integer powers.

Neither `pi` nor an irrational square root is converted to a floating-point value
during model parsing or normalization. Numerical conversion occurs only when an
expression is specialized for a chosen numerical scalar type. Exporters SHOULD
preserve exact constants whenever their target supports them.

## 9. Dimensional analysis

Integer and rational constants, `pi`, and every permitted `sqrt` value have mass
dimension zero.

Expression dimensions follow these rules:

- operands of `+` and `-` MUST have equal mass dimension;
- dimensions add under multiplication;
- dimensions subtract under division;
- raising to the integer power \(n\) multiplies the base dimension by \(n\); and
- the completed expression MUST have the dimension required by its containing
  schema property.

The relevant spacetime dimension and tensor kind determine the required final
dimension.

## 10. Errors during specialization

Static division by an expression proven to be zero MUST be rejected during model
validation.

A denominator containing parameters may become zero at a numerical parameter
point. Specialization or evaluation MUST report this as an error according to
the numerical API contract; it MUST NOT silently introduce a NaN or infinity.

The same principle applies to overflow or failure when converting an exact
constant to a requested numerical scalar type.

## 11. Normalization guarantees

Normalization MUST:

- remove irrelevant whitespace and parentheses;
- reduce rational constants to lowest terms;
- use a positive rational denominator;
- fold arithmetic subexpressions containing only rational constants;
- normalize redundant unary signs;
- normalize rational perfect squares under `sqrt`; and
- flatten associative addition and multiplication nodes while preserving operand
  order.

Version 0.1 does not require a general computer-algebra equivalence proof. In
particular, normalization need not:

- reorder commutative operands;
- distribute multiplication over addition;
- factor expressions;
- cancel arbitrary parameter-dependent factors; or
- prove general identities involving radicals or `pi`.

Consequently, mathematically equal expressions are not guaranteed to have equal
canonical representations unless their equivalence follows from the required
normalization rules.

Subsystems that require exact identity proofs MAY accept a narrower algebraic
subset. In particular, version 0.1 gauge-algebra and gauge-invariance validation
requires participating coefficients to normalize to bounded sparse
multivariate polynomials and rejects parameter-dependent denominators as
unsupported. That proof-domain normalization is separate from general source
expression normalization.

## 12. Resource limits

An implementation MUST impose documented limits on at least:

- source-string length;
- token count;
- parser nesting depth;
- AST node count;
- integer digit count; and
- exponent magnitude.

Limits MUST be checked before or during parsing and exact arithmetic so malformed
or adversarial input cannot cause unbounded allocation or computation.

Milestone 1 defines a standard profile and immutable tested hard ceilings.
Callers MAY select lower limits or values between the standard profile and the
hard ceiling, but MUST NOT exceed a hard ceiling. The expression-specific
standard/hard pairs are:

| Resource | Standard | Hard ceiling |
|---|---:|---:|
| decoded expression bytes | 8 KiB | 64 KiB |
| tokens | 2,048 | 16,384 |
| AST or value nodes per expression | 2,048 | 16,384 |
| nesting depth | 64 | 256 |
| digits in one integer literal | 256 | 4,096 |
| exponent magnitude | 64 | 1,024 |
| exact intermediate integer magnitude | 16,384 bits | 1,048,576 bits |

Exact integers use Zig's pinned standard-library arbitrary-precision
implementation behind a Phaser-owned adapter. The adapter checks the configured
digit, exponent, bit, work, and byte budgets before publication. Exhausting one
of these limits is an ordinary structured diagnostic and never changes the
expression's meaning.

## 13. Validation and testing

Architecture-wide parser, property, and fuzzing rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

The parser, resolver, normalizer, dimensional analyzer, and evaluator are
separate testable stages.

Required test classes include:

- grammar examples and operator-precedence tests;
- rejection of every unsupported numeric spelling;
- exact rational reduction;
- exact preservation and target-specific evaluation of `pi`;
- valid and invalid `sqrt` arguments;
- unknown and reserved identifier rejection;
- dimensional-analysis success and failure;
- division-by-zero handling;
- normalization idempotence;
- parse-normalize-serialize-parse stability of a future canonical form;
- boundary tests for every resource limit;
- property tests comparing exact and numerical evaluation where applicable; and
- parser and normalizer fuzzing with arbitrary byte strings.

Malformed input MUST produce a bounded diagnostic. It MUST NOT panic, corrupt
memory, hang, or reach host-language evaluation.
