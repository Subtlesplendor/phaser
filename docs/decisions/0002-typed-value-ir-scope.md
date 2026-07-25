# Decision 0002: Typed Value IR as a separate interned arena

Status: accepted for Milestone 2

## Context

Milestone 1 implements `expression.Expression`: a source-expression
representation in which each expression owns a private arena and stores a flat
value array addressed by `ValueId`. It has no interning, no shared arena across
expressions, and no node kind for a field or background input, because model
source expressions depend only on parameters.

Milestone 2 needs a value representation with different properties. One artifact
holds many contributions that share subexpressions, so a shared arena and
structural interning are required for common-subexpression sharing to survive
into lowering. Background coordinates must be inputs. Exact symbolic
differentiation must produce new nodes into the same arena. Derived values may
apply stronger canonicalization than the source language guarantees, which
[Phaser Internal Representations §5.5](../architecture/INTERNAL_REPRESENTATIONS.md)
explicitly distinguishes from source-expression normalization.

## Decision

Milestone 2 adds a separate Typed Value IR module holding one interned,
acyclic value graph per artifact in a shared arena. It reuses the Milestone 1
exact-arithmetic primitives unchanged.

An explicit import operation lowers a model `Expression` into the shared arena.
The Milestone 1 source-expression representation and its contract remain
unchanged, and continue to own the model boundary.

The Milestone 2 node set is the Milestone 1 set — reduced rationals, parameter
inputs, `pi`, exact square roots of positive rationals, negation, ordered
addition and multiplication, division, and non-negative integer powers — plus a
background-coordinate input.

## Alternatives

Extending `expression.Expression` in place was rejected. It would rework a
boundary that Milestone 1 validated, fuzzed, and covered with a permanent
regression corpus, in order to add properties the source language does not
need. It would also blur the deliberate distinction between the normalization
the source format guarantees and the canonicalization the derived IR may apply.

Keeping two representations without sharing the exact-arithmetic primitives was
rejected because it would duplicate the bounded rational implementation and its
resource contract.

Deferring interning until a measured need appeared was rejected because
contribution values in one artifact share subexpressions by construction, and
retrofitting interning after differentiation and lowering exist would be more
disruptive than starting with it.

## Revisit when

Revisit this decision if the import operation becomes a material cost for large
models, if the two representations converge to the point that maintaining both
has no benefit, or if a later milestone needs source expressions to carry
non-parameter inputs.
