# Kernel Instruction Set

Status: provisional specification

This document specifies the initial instruction set executed by the safe
reference backend. It refines section 10 of
[Potential Kernel](POTENTIAL_KERNEL.md), which defers the opcode catalog.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

This specification fixes, for Milestone 2:

- the slot model and value types;
- the closed opcode catalog and each opcode's semantics;
- accumulation and exponentiation order;
- exact-to-`f64` conversion at lowering;
- the workspace query contract;
- per-point status; and
- program validation.

It does not specify complex results, matrix or spectral operations, master
integrals, thermal functions, or any optimized backend. Those extend the
catalog in later milestones without altering the semantics fixed here.

## 2. Value types

Milestone 2 kernels are real. Every slot holds one `f64`.

The instruction set carries explicit scalar-type metadata so that later
milestones can add types without encoding `f64` assumptions into the scientific
IR, as required by
[Potential Kernel §6.2](POTENTIAL_KERNEL.md). A kernel declares exactly one
scalar type; Milestone 2 declares `f64`.

Complex results are introduced with the one-loop calculation in Milestone 3 and
are not representable by this catalog.

## 3. Slots

A lowered program addresses four disjoint slot spaces:

```text
constant   immutable, materialized at lowering
parameter  packed model-parameter input channel
background packed background-coordinate input channel
temporary  workspace, written during execution
```

Each slot space is indexed from zero. Slot indices are execution details and
MUST NOT replace semantic identities in provenance or metadata.

Output values are written to caller-provided output buffers, not to slots.
Every program declares which temporary slot supplies each declared output.

Parameter and background slots remain distinct categories even though both hold
`f64`, as required by
[Potential Kernel §7.1](POTENTIAL_KERNEL.md).

## 4. Opcode catalog

The catalog is a closed, exhaustively checked tagged union for each Phaser
build. Milestone 2 defines eight opcodes.

| Opcode | Operands | Result | Semantics |
|---|---|---|---|
| `load_constant` | constant index | temporary | copy a materialized constant |
| `load_parameter` | parameter index | temporary | copy a bound parameter |
| `load_background` | background index | temporary | copy a coordinate of the current point |
| `negate` | 1 temporary | temporary | IEEE 754 negation |
| `add` | \(n\ge2\) temporaries | temporary | ordered accumulation, section 5.1 |
| `multiply` | \(n\ge2\) temporaries | temporary | ordered accumulation, section 5.1 |
| `divide` | 2 temporaries | temporary | IEEE 754 division |
| `power_integer` | 1 temporary, exponent \(e\) | temporary | integer power, section 5.2 |

No opcode allocates. No opcode reads mutable global state.

There is no runtime square-root or `pi` opcode. Exact square roots of rationals
and the symbolic constant `pi` are compile-time constants folded into
`load_constant` at lowering, as specified in section 6.

## 5. Evaluation order

Reproducibility under the version 0.1 policy requires that evaluation order be
fixed by the program rather than derived from allocation, hash-table iteration,
or thread scheduling. The following rules make the catalog deterministic.

### 5.1 Accumulation

`add` and `multiply` are variadic and accumulate strictly left to right over
their operand list in the order recorded by the program:

```text
result = op(... op(op(x[0], x[1]), x[2]) ..., x[n-1])
```

Operand order is fixed by Typed Value IR canonical ordering during lowering. A
backend MUST NOT reassociate or reorder operands under the reproducible policy,
because floating-point addition and multiplication are not associative.

### 5.2 Integer powers

`power_integer` with exponent \(e\) evaluates by binary exponentiation over the
bits of \(e\) from least significant to most significant, accumulating

```text
result = 1
base   = x
while e != 0:
    if e & 1: result = result * base
    e >>= 1
    if e != 0: base = base * base
```

with \(e=0\) yielding exactly `1.0`. This sequence is normative: repeated
multiplication and binary exponentiation give different roundings, so the choice
MUST be fixed rather than left to the backend.

Negative exponents are not representable. Division is an explicit `divide`.

## 6. Exact conversion at lowering

Constants originate as exact rationals, exact square roots of positive
rationals, or `pi` in the Typed Value IR. Lowering converts each to `f64` once,
under a checked conversion policy, and stores it in the constant slot space.

Conversion MUST fail with a diagnostic on overflow to infinity, on underflow of
a nonzero value to zero, and on any loss prohibited by the responsible input
contract. It MUST NOT pass through a less capable intermediate representation.

Conversion happens at lowering, never during evaluation. Evaluation therefore
performs no exact arithmetic.

### 6.1 Milestone 2 conversion policy

A rational converts by rounding its numerator and its denominator each through
the correctly rounded decimal-to-`f64` path, then performing one rounded
division. The result is therefore within 1.5 units in the last place of the
exact value.

Conversion fails when either part overflows to infinity, when a nonzero part
underflows to zero, or when the quotient does. A rational whose parts are
individually outside the representable range but whose quotient would be
representable is consequently rejected rather than approximated. Rejecting a
representable value is a conservative failure and is preferred to returning a
value the policy cannot justify.

Exactly rounded conversion of arbitrary big rationals is deferred. It becomes
necessary only when a supported model produces coefficients outside the range
this policy accepts.

## 7. Workspace

A kernel answers an exact workspace query before execution:

```text
workspace_layout(operation, point_count)
```

The returned layout gives total byte size and required alignment.

For the Milestone 2 serial reference backend the requirement is

```text
bytes     = temporary_slot_count * @sizeOf(f64)
alignment = @alignOf(f64)
```

Lowering assigns temporary slots with live-range reuse, so the slot count is
generally smaller than the instruction count. Workspace is accepted as an
unaligned byte slice and its alignment is checked at the call boundary rather
than assumed from its type, because alignment is a contract a foreign caller
can violate.

### 7.1 Binding stages

Instructions are partitioned so that every instruction depending only on
constants and bound parameters precedes every instruction depending on a
background coordinate. The partition is a valid topological order, because a
parameter-stage instruction never has a background-dependent operand.

A binding executes the first section once and retains the resulting temporaries.
Each evaluation restores them and executes only the second section per point, so
parameter-dependent work is not repeated across a batch.

Slot reuse respects the partition: a parameter-stage value read by the
background section is live for the whole program, since that section reruns for
every point. A staged evaluation and an unstaged one execute the same
instructions on the same inputs in the same order, and therefore MUST agree
bitwise.

independent of `point_count`, because the reference backend evaluates points one
at a time and reuses the same temporaries. Callers MUST NOT rely on that
independence: the query exists so a later backend may return a point-count- or
worker-count-dependent layout without an API change, and
[Potential Kernel §13.2](POTENTIAL_KERNEL.md) forbids inferring workspace from
public input and output shapes.

Execution MUST allocate no memory. Insufficient size, insufficient alignment,
and forbidden aliasing between workspace, inputs, and outputs are call-level
errors detected before any slot is written.

## 8. Status

Every point carries one status. Milestone 2 defines:

```text
ok
non_finite
division_by_zero
```

`non_finite` is reported when a declared output is not finite. `division_by_zero`
is reported when `divide` receives a zero divisor; this is reachable because
model expressions may divide by a parameter whose bound value is zero.

A batch retains independent status per point. A failed point MUST NOT corrupt
another point's output or workspace, and MUST NOT be replaced by
\(+\infty\), a real part, an absolute value, or any other penalty value.

Invalid opcodes, slot types, and buffer plans are programmer errors asserted
after program validation, not statuses.

## 9. Program validation

A program becomes a kernel only after validation establishes:

- every operand index is within its slot space;
- every operand is written before it is read, in program order;
- no instruction writes a slot that is read by an earlier instruction still
  live, unless the temporary's live range has ended;
- every declared output is written;
- the temporary slot count bounds every referenced temporary index;
- `add` and `multiply` have at least two operands;
- `power_integer` exponents are within the declared limit; and
- the program is acyclic and terminates, which follows from straight-line
  instruction order.

Validation is complete before publication. Audit builds SHOULD additionally
verify temporary live ranges and the schedule independently.

## 10. Derivative programs

Gradient and Hessian outputs are lowered from Typed Value IR that has already
been symbolically differentiated, per
[Decision 0003](../decisions/0003-derivative-method.md). They introduce no
opcode.

A fused capability such as `value_gradient_hessian` lowers to one program whose
common subexpressions are shared across the value and derivative outputs, and
whose declared outputs name distinct temporary slots. Separate calls MAY repeat
work; a fused call MUST evaluate all requested outputs at one point under one
status policy.

## 11. Validation and testing

Required tests include:

- reference execution agrees with direct Typed Value IR evaluation;
- scalar and batch-of-one agree, and arbitrary batch partitions and
  permutations agree with scalar evaluation;
- fused and separate outputs agree;
- accumulation order is observable and stable for deliberately
  non-associative operand sets;
- `power_integer` matches its normative sequence, including \(e=0\) and \(e=1\);
- exact-to-`f64` conversion succeeds and fails at its documented boundaries;
- workspace is sufficient at exactly the queried size and rejected one byte
  below it, and misalignment is rejected;
- evaluation performs no allocation, asserted with a failing allocator;
- one failed point does not corrupt unrelated batch points;
- repeated same-kernel evaluation is bitwise identical;
- every program-validation rule rejects a targeted invalid program; and
- program validation and input packing are fuzzed.

## 12. Deferred decisions

This specification deliberately does not fix:

- complex-valued slots and opcodes;
- matrix, eigensolver, and spectral opcodes;
- logarithms, master integrals, and thermal functions;
- fused multiply-add, vectorized, or blocked execution;
- any optimized or ahead-of-time backend;
- a binary program encoding; or
- point-count-dependent workspace formulas.

Later catalogs MUST preserve the slot model, ordering rules, status semantics,
and allocation-free execution fixed here.
