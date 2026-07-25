# Perturbative Order and Power-Counting Boundary

Status: provisional specification

This document specifies perturbative-order tracking in Phaser 0.1 and defines
the boundary of any future power-counting support. It refines section 8 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

Phaser 0.1 tracks ordinary loop order. It does not implement a general
power-counting or asymptotic-expansion engine.

Loop-order tracking supports:

- separate tree-level and loop contributions;
- explicit loop truncation;
- diagrammatic and renormalization provenance;
- symbolic export by loop order;
- order-specific conformance tests; and
- RG-consistency checks.

The following are outside the Phaser 0.1 contract:

- inferring coupling order from parameter assignments;
- arbitrary user-defined grading axes;
- rational or multivariate grades;
- automatic expansion of masses, eigenvalues, or matrix functions;
- automatic expansion of logarithms, thermal functions, or loop integrals; and
- automatic hard-, soft-, or ultrasoft-region expansion.

## 2. Loop order

Every perturbative contribution derived by Phaser MUST carry a non-negative
integer `loop_order`.

Conceptually:

```text
Term {
    value: ValueId
    loop_order: LoopOrder
    provenance: Provenance
}
```

`ValueId` is the arena-local typed reference defined by
[Phaser Internal Representations](../architecture/INTERNAL_REPRESENTATIONS.md);
it is not a persistent serialized identifier.

`LoopOrder` is a distinct semantic type. Its serialized value is a
non-negative integer. Implementations MAY use a bounded integer representation
and MUST reject values outside their documented supported range.

The classical action and tree-level potential have loop order zero.

For diagrams built only from classical vertices, `loop_order` equals the number
of independent momentum loops. More generally, it denotes order in the
perturbative loop or \(\hbar\) expansion. If a contribution contains
counterterm or effective vertices already assigned a loop order in the same
expansion, then

\[
L_{\mathrm{total}}
= L_{\mathrm{topology}}
+ \sum_v L_v.
\]

The provenance record SHOULD retain both the total loop order and enough origin
information to explain it.

Loop order is local to the calculation stage identified by the artifact and its
provenance. For example, a 4D matching-loop order and a 3D
effective-potential-loop order are not automatically added or collapsed into
one integer. Combining such orders requires a separately defined expansion and
is outside version 0.1.

## 3. Loop-order requests

A calculation kind that supports loop truncation uses:

```json
{
  "orders": {
    "loop": {
      "through": 1
    }
  }
}
```

`through` is required when the calculation-specific schema requires an explicit
loop truncation. It MUST be a non-negative integer and is inclusive. The example
requests contributions with loop orders zero and one.

A calculation-specific schema MAY omit `orders` when its result has a fixed
order, such as a request for the classical action.

The planner MUST reject a requested loop order that the selected calculation,
model class, scheme, or gauge implementation does not support. It MUST NOT
silently return the highest implemented order instead.

A structurally vanishing contribution at a supported order is a valid zero
result. It is not equivalent to an unsupported order.

## 4. Representation and arithmetic

Loop order is metadata on a perturbative term, not a numeric variable embedded
in its expression.

Addition of contributions with different loop orders MUST retain them as
separate terms until an explicit selection or summation operation is requested.

When a perturbative derivation multiplies two already classified
contributions, their loop orders add:

\[
L(xy) = L(x) + L(y).
\]

This rule applies only when multiplication represents multiplication of
perturbative contributions. Ordinary subexpressions within one classified term
do not each require loop-order metadata.

Algebraic simplification MUST NOT erase the loop-order distinction between
terms. If equal expressions from different loop orders cancel after an explicit
sum, their separate provenance remains available in the unsummed artifact.

## 5. Truncation

Loop truncation is an explicit operation. Truncation through order \(L\) selects
terms satisfying

\[
0 \leq \texttt{loop_order} \leq L.
\]

The untruncated or originally derived artifact SHOULD remain immutable.
Truncation produces a view or a new artifact rather than destructively removing
terms.

An artifact and kernel MUST record the loop truncation used to construct them.
Cache identity MUST include the normalized calculation request and therefore
the requested truncation.

Where practical, symbolic and numerical APIs SHOULD permit callers to inspect
individual loop-order contributions in addition to their selected sum.

## 6. Loop order is not general power counting

Loop order describes diagrammatic perturbation theory. It does not by itself
determine the order of a term in a coupling, thermal, EFT, or hierarchy
expansion.

For example, if

\[
m^2 = m_0^2 + \delta m^2
\]

with differently counted pieces, expanding

\[
(m^2)^{3/2},\qquad
m^4\log(m^2/\mu^2),\qquad
J_B(m^2/T^2)
\]

requires more than attaching orders to expression nodes. It requires expansion
rules, hierarchy assumptions, branch information, and physics-specific
treatment of loop functions. Matrix spectra introduce additional degeneracy
and eigenvalue-labeling issues.

Phaser 0.1 MUST NOT claim a coupling or thermal accuracy merely by translating a
loop order into another order label.

Hard, soft, and ultrasoft designations are region or provenance metadata unless
a future, explicitly defined counting scheme assigns them mathematical orders.

## 7. Pre-expanded series

A future Phaser subsystem, plugin, or external program may derive an expression
that has already been expanded under a named power-counting scheme. Such a
result may conceptually contain:

```text
PreExpandedSeries {
    scheme_id
    terms: [
        { expansion_order, expression, provenance },
        ...
    ]
    remainder
}
```

For such an artifact, Phaser could preserve terms, select a truncation, export
coefficients, and numerically evaluate the selected sum without deriving the
expansion itself.

The producer of a pre-expanded series is responsible for:

- defining the counting scheme;
- deriving every expansion coefficient;
- recording assumptions and scale hierarchies;
- assigning expansion orders;
- stating the known remainder or accuracy; and
- preserving the loop and region provenance needed to audit the result.

Loop order and expansion order answer different questions and MUST remain
separate metadata.

No public `PreExpandedSeries` JSON schema is defined in version 0.1. In
particular, the QFT Model Format does not accept an unexpanded potential plus
parameter-order declarations and promise to expand it.

## 8. Possible future capability levels

Future work should distinguish:

1. Storing order labels on already expanded terms.
2. Adding, multiplying, and truncating compatible formal series.
3. Expanding ordinary expression functions under declared assumptions.
4. Deriving physics-specific asymptotic expansions of spectra and loop
   integrals.

Each level requires a separate design and validation contract. Implementing one
level MUST NOT imply support for the following levels.

Formal series from different schemes or incompatible assumptions MUST NOT be
combined without an explicit, validated conversion.

## 9. Provenance

Loop order is only one part of contribution provenance. Separate fields may
record:

- diagram topology;
- particle or field sector;
- counterterm origin;
- renormalization scheme;
- gauge-fixing context;
- dimensional-reduction stage; and
- hard, soft, or ultrasoft region.

These categories MUST NOT be encoded as numerical loop orders.

## 10. Validation and testing

Architecture-wide exact-comparison and conformance rules follow
[Verification and Testing](../architecture/VERIFICATION_AND_TESTING.md).

Required tests include:

- tree-level contributions receive loop order zero;
- diagrammatic loop counts are correct;
- counterterm and effective-vertex orders contribute to total loop order;
- multiplication adds loop orders where the perturbative operation requires it;
- addition retains terms of distinct loop order;
- truncation is inclusive and non-destructive;
- unsupported requested orders are rejected;
- supported but structurally absent contributions produce zero;
- simplification and export preserve loop-order provenance;
- artifact and kernel identities include requested truncation; and
- request parsing and loop-order bounds are fuzzed.

Conformance tests SHOULD compare each loop order independently against analytic
or separately implemented reference results.

## 11. Deferred decisions

The following are intentionally deferred:

- a public interchange format for pre-expanded series;
- named power-counting scheme definitions;
- formal-series arithmetic;
- expression-level series expansion;
- asymptotic expansions of thermal functions and loop integrals;
- expansion of matrix spectra; and
- strict thermodynamic expansion algorithms.

These are added only when a concrete calculation supplies their scientific
requirements.
