# Kernel Instruction Set

Status: provisional specification

This document specifies the initial instruction set executed by the safe
reference backend. It refines section 10 of
[Potential Kernel](POTENTIAL_KERNEL.md), which owns the surrounding kernel
contract.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

This specification fixes, through Milestone 3:

- the slot model and value types;
- the closed opcode catalog and each opcode's semantics;
- accumulation and exponentiation order;
- exact-to-`f64` conversion at lowering;
- real-symmetric matrix and scalar one-loop spectral operations;
- the workspace query contract;
- per-point status; and
- program validation.

It does not specify general complex inputs, a general complex logarithm, master
integrals beyond the scalar one-loop spectral operation, thermal functions, or
any optimized backend. Those extend the catalog in later milestones without
altering the semantics fixed here.

## 2. Value types

Every scalar temporary is statically one of:

```text
Real64
Complex64 { re: f64, im: f64 }
```

`Complex64` specifies two IEEE binary64 components and does not specify a stable
C layout. Constants, model parameters, renormalization scales, background
coordinates, real-symmetric matrix entries, eigenvalues, and eigensolver
workspace remain `Real64`. A kernel may therefore contain both real and complex
temporaries without converting its real input channels or matrix data to
complex storage.

`promote_real_to_complex` is the only real-to-complex conversion and produces
`(x, 0)`. There is no implicit or explicit complex-to-real projection in this
catalog. Taking a real part, imaginary part, magnitude, or absolute value would
be a separately named future scientific or presentation operation, not a
conversion inserted by lowering.

Every instruction declares its operand and result types. A type mismatch is
rejected during program validation; execution does not dispatch on an
unvalidated dynamic scalar type. The explicit type metadata preserves the
extension boundary required by
[Potential Kernel §6.2](POTENTIAL_KERNEL.md).

## 3. Slots

A lowered program addresses five disjoint slot spaces:

```text
constant   immutable, materialized at lowering
parameter  packed model-parameter input channel
scale      packed renormalization-scale input channel
background packed background-coordinate input channel
temporary  workspace, written during execution
```

Each slot space is indexed from zero. Slot indices are execution details and
MUST NOT replace semantic identities in provenance or metadata.

Output values are written to caller-provided output buffers, not to slots.
Every program declares which temporary slot supplies each declared output.

Constant, parameter, scale, and background slots hold `Real64`. Temporary
descriptors additionally carry a scalar type or one of these structured types:

```text
RealSymmetricMatrix(n)  authoritative upper triangle, n * (n + 1) / 2 entries
RealEigensystem(n)      n real eigenvalues plus real transformation state
ComplexVector(n)        n Complex64 components in canonical coordinate order
ComplexMatrix(n)        dense row-major n * n Complex64 entries
```

`ComplexVector` and `ComplexMatrix` exist because a spectral derivative
operation produces one structured result rather than one output per coordinate.
The Hessian's storage is dense rather than triangular because every entry is
evaluated from the formula; symmetry is a property to be checked, not a storage
saving. A structured slot is not itself a publishable output: a declared output
names an extracted `Complex64` component.

The corresponding matrix, spectrum, and eigensolver regions are workspace
subregions, not hidden allocations or complex-valued input channels. Parameter,
scale, and background slots remain distinct categories even though all hold
`f64`, as required by
[Potential Kernel §7.1](POTENTIAL_KERNEL.md).

## 4. Opcode catalog

The catalog is a closed, exhaustively checked tagged union for each Phaser
build.

| Opcode | Operands | Result | Semantics |
|---|---|---|---|
| `load_constant` | real constant index | `Real64` temporary | copy a materialized constant |
| `load_parameter` | real parameter index | `Real64` temporary | copy a bound parameter |
| `load_renormalization_scale` | real scale index | `Real64` temporary | copy the bound positive \(\mu_R\) |
| `load_background` | real background index | `Real64` temporary | copy a coordinate of the current point |
| `promote_real_to_complex` | 1 `Real64` temporary | `Complex64` temporary | produce `(x, 0)` exactly |
| `negate` | 1 scalar temporary | same scalar type | component-wise IEEE 754 negation |
| `add` | \(n\ge2\) scalar temporaries of one type | same scalar type | ordered accumulation, section 5.1 |
| `multiply` | \(n\ge2\) `Real64` temporaries | `Real64` | ordered accumulation, section 5.1 |
| `divide` | 2 `Real64` temporaries | `Real64` | IEEE 754 division |
| `power_integer` | 1 `Real64` temporary, exponent \(e\) | `Real64` | integer power, section 5.2 |
| `scalar_one_loop_term` | real eigenvalue \(x\), positive `Real64` \(\mu_R\) | `Complex64` | restricted principal-branch logarithmic term, section 5.3 |
| `assemble_real_symmetric` | \(n(n+1)/2\) `Real64` temporaries | `RealSymmetricMatrix(n)` | copy the canonical upper triangle, section 5.4 |
| `symmetric_eigensystem` | `RealSymmetricMatrix(n)` | `RealEigensystem(n)` | deterministic real-symmetric eigensolver, section 5.5 |
| `scalar_one_loop_sum` | `RealEigensystem(n)`, positive `Real64` \(\mu_R\) | `Complex64` | ordered sum of scalar one-loop terms, section 5.6 |
| `scalar_one_loop_gradient` | eigensystem, \(n_b\) first-derivative matrices, \(\mu_R\) | `ComplexVector(n_b)` | invariant spectral first derivative, section 5.7 |
| `scalar_one_loop_hessian` | eigensystem, first- and second-derivative matrices, \(\mu_R\) | `ComplexMatrix(n_b)` | invariant spectral second derivative, section 5.7 |
| `extract_element` | `ComplexVector(n)` or `ComplexMatrix(n)`, structural indices | `Complex64` | select one component of a structured result |

No opcode allocates. No opcode reads mutable global state.

`scalar_one_loop_term` is the per-eigenvalue kernel of `scalar_one_loop_sum`
and of the derivative operations rather than an instruction a program selects
on its own: no Typed Value IR node denotes a single eigenvalue's contribution,
so Milestone 3 lowering never emits it standalone. It is catalogued separately
because its branch and zero-mode behavior are what the operations above are
defined in terms of.

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
`Complex64` addition applies this sequence independently to `re` and `im`;
there is no complex multiply, divide, or power opcode in the Milestone 3
catalog.

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

### 5.3 Restricted scalar one-loop logarithmic term

`scalar_one_loop_term(x, mu_R)` is the only logarithmic opcode required by
Milestone 3. For finite real \(x\) and finite \(\mu_R>0\), it evaluates

\[
\frac{x^2}{64\pi^2}
\left[\operatorname{Log}(x/\mu_R^2)-\frac32\right].
\]

For \(x>0\), `Log` is the pinned Zig `f64` natural logarithm of
\(x/\mu_R^2\) and the imaginary component is exact zero. For \(x<0\), the
opcode evaluates that real primitive on \(|x|/\mu_R^2\) and adds the positive
imaginary component \(x^2/(64\pi)\). For \(x=0\), it returns exact `(0, 0)`
without forming a logarithm or multiplying zero by infinity.

This is not a general complex logarithm: it accepts no complex operand and
implements only the negative-real-axis branch fixed by formula version
`scalar-vacuum-msbar/1`. Binding validates that \(\mu_R\) is finite and
positive before point execution; an invalid packed scale is a call-level error.
Non-finite arithmetic from otherwise valid inputs produces `non_finite`.

### 5.4 Real symmetric matrices

`assemble_real_symmetric` receives the upper-triangular entries in lexical order

```text
(0,0), (0,1), ..., (0,n-1), (1,1), ..., (n-1,n-1).
```

That triangle is authoritative. The operation materializes exact mirrored
entries in real workspace when the selected eigensolver layout needs a dense
matrix; it MUST NOT average two independently rounded triangles or accept an
approximately symmetric input. Matrix dimension is structural and fixed by the
validated program.

### 5.5 Symmetric eigensystem

`symmetric_eigensystem` implements
[Decision 0008](../decisions/0008-symmetric-eigensolver.md): direct paths for
sizes zero through two and deterministic cyclic Jacobi sweeps for larger
matrices. The result retains every eigenvalue and multiplicity and is sorted
ascending only as an execution convention. The ordering does not become a
scientific identity and MUST NOT be differentiated. Any eigenvectors or
equivalent transformation state retained for residual checks and invariant
derivatives remain real execution data inside `RealEigensystem(n)`.

Non-finite input or rescaling produces `non_finite`. Failure to converge or to
satisfy the required residual postcondition produces `nonconvergent`. Neither
status publishes a partial spectrum. Negative and exactly zero eigenvalues are
successful results.

### 5.6 Scalar one-loop spectral sum

For a real eigenvalue multiset \(\{x_a\}\) and finite \(\mu_R>0\),
`scalar_one_loop_sum` evaluates, in stored spectrum order,

\[
\frac{1}{64\pi^2}\sum_a
x_a^2\left[\operatorname{Log}(x_a/\mu_R^2)-\frac32\right]
\]

by applying `scalar_one_loop_term` to every stored eigenvalue and adding the
`Complex64` terms strictly left to right. The branch and zero-mode behavior are
therefore those of section 5.3. Multiplicity is preserved by visiting every
eigensystem entry.

A negative eigenvalue and a nonzero finite imaginary component are successful.
Non-finite arithmetic or a non-finite final component produces `non_finite`.
The operation never substitutes `log(abs(x))` as a real answer, clips a
negative eigenvalue, or projects the result to real.

### 5.7 Scalar one-loop spectral derivatives

`scalar_one_loop_gradient` receives the eigensystem and one real-symmetric
first-derivative matrix for every ordered background coordinate.
`scalar_one_loop_hessian` additionally receives the canonical upper triangle of
real-symmetric second-derivative matrices over background-coordinate pairs.
Their outputs use that same coordinate order; the Hessian instruction writes
the full dense row-major candidate required by the Potential Kernel interface.

Both operations read the eigensystem the value operation already produced, so
one point cannot report one spectrum and differentiate another. Their
structured results reach a caller through `extract_element`, whose structural
indices are fixed by the validated program.

Both operations evaluate invariant spectral divided differences or another
method with identical mathematical semantics, as fixed by
[Decision 0009](../decisions/0009-scalar-spectral-derivatives.md). The
implementation uses the eigensystem-basis gradient and Hessian formulas,
deterministic same-sign nonzero clusters, and the stable close-pair divided
difference specified there. It MUST be invariant under eigenvalue reordering,
eigenvector sign, and rotations inside a degenerate eigenspace; it MUST NOT
differentiate the stored eigenvalue order.

The operations apply the analytic zero-mode value and first-derivative limits
before generating floating-point logarithms. The Hessian applies Decision
0009's exact projected zero-block criterion before evaluating a zero/zero
coefficient. A required divergent second derivative produces
`singular_derivative`; a zero block proven termwise exact remains `ok`.
Candidate derivative outputs remain in workspace until the complete requested
point operation succeeds.

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

For a real-scalar Milestone 2 program the requirement remains

```text
bytes     = temporary_slot_count * @sizeOf(f64)
alignment = @alignOf(f64)
```

For a Milestone 3 program the exact checked layout additionally accounts for:

- every simultaneously live `Real64` and `Complex64` scalar temporary;
- authoritative or materialized real-symmetric matrix storage;
- real eigenvalues;
- the real scaled working matrix;
- eigenvectors or equivalent transformation state needed by residual checks;
- fixed-order norm and residual scratch; and
- padding required to align every subregion.

Lowering assigns temporary regions with live-range reuse, so the requirement is
generally smaller than the sum of all instruction result sizes. Workspace is
accepted as an unaligned byte slice and its alignment is checked at the call
boundary rather than assumed from its type, because alignment is a contract a
foreign caller can violate. Every size, offset, and alignment calculation uses
checked arithmetic.

### 7.1 Binding stages

Instructions are partitioned so that every instruction depending only on
constants, bound parameters, and the bound renormalization scale precedes every
instruction depending on a background coordinate. The partition is a valid
topological order, because a binding-stage instruction never has a
background-dependent operand.

A binding executes the first section once and retains the resulting temporaries.
Each evaluation restores them and executes only the second section per point, so
parameter-dependent work is not repeated across a batch.

Slot reuse respects the partition: a binding-stage value read by the
background section is live for the whole program, since that section reruns for
every point. A staged evaluation and an unstaged one execute the same
instructions on the same inputs in the same order, and therefore MUST agree
bitwise.

For the serial reference backend the returned layout is independent of
`point_count`, because it evaluates points one at a time and reuses the same
temporaries. Callers MUST NOT rely on that independence: the query exists so a
later backend may return a point-count- or worker-count-dependent layout without
an API change, and
[Potential Kernel §13.2](POTENTIAL_KERNEL.md) forbids inferring workspace from
public input and output shapes.

The optimized interpreter returns a backend-specific layout containing a
slot-major bounded block frame, a scalar remainder/structured-operation frame,
and shared numerical scratch. Its immutable execution plan predecodes every
temporary to a scalar-frame offset and records the preferred block width.
Parameter binding stores only parameter-stage regions live into the background
stage or final publication and broadcasts those regions into each block.

On ARM64 and baseline x86-64, the current block contains four points and
arithmetic is issued as two portable two-lane `f64` vectors. SIMD is across
points only: accumulation and integer-power order inside a lane remain exactly
those of section 5. A partial final block executes through the predecoded scalar
leaf rather than changing the public point count or padding caller buffers.

Execution MUST allocate no memory. Insufficient size, insufficient alignment,
unrepresentable point-count-dependent shapes, and forbidden aliasing between
workspace, inputs, and outputs are call-level errors detected before any slot
is written.

## 8. Status

Every point carries exactly one status:

```text
ok
non_finite
division_by_zero
nonconvergent
singular_derivative
```

`non_finite` is reported when a numerical input or intermediate required for an
operation is non-finite, or when a declared output would be non-finite.
`division_by_zero` is reported when `divide` receives a zero divisor; this is
reachable because model expressions may divide by a parameter whose bound value
is zero.
`nonconvergent` is reported when a numerical operation exhausts its declared
iteration bound or fails a required postcondition. `singular_derivative` is
reported when a requested derivative is mathematically singular, including a
required uncancelled scalar zero-mode second derivative.

These outcomes are distinct. In particular, a converged spectrum followed by a
singular Hessian is not `nonconvergent`, and an analytically known derivative
singularity is not converted into a generated infinity and reported as
`non_finite`.

A batch retains independent status per point. A failed point MUST NOT corrupt
another point's output or workspace, and MUST NOT be replaced by
\(+\infty\), a real part, an absolute value, or any other penalty value.

The optimized blocked interpreter carries this status as one lane state.
Fallible arithmetic and structured numerical operations update only the
affected lane; inactive lanes are not published and successful lanes continue
in original point order. Infallible arithmetic spans do not re-test a common
point status after every instruction.

Publication is point-atomic. Instructions may accumulate candidate outputs in
workspace, but a point's declared output buffers are written only after every
instruction required by that operation has succeeded. If a fused
`value_gradient_hessian` operation reaches `singular_derivative`, none of that
point's value, gradient, or Hessian outputs are published. A separate value or
gradient operation at the same point may succeed because it requests a
different program and status boundary.

Invalid opcodes, slot types, and buffer plans are programmer errors asserted
after program validation, not statuses.

## 9. Program validation

A program becomes a kernel only after validation establishes:

- every operand index is within its slot space;
- every operand and result has the opcode's required scalar type, shape, and
  mass dimension;
- every operand is written before it is read, in program order;
- no instruction writes a slot that is read by an earlier instruction still
  live, unless the temporary's live range has ended;
- every declared output is written;
- the temporary slot count bounds every referenced temporary index;
- `add` and `multiply` have at least two operands;
- `power_integer` exponents are within the declared limit; and
- every structured result's dimension agrees with its matrix-entry and
  derivative-operand counts;
- every spectral operation uses one compatible eigensystem, scale, formula
  version, branch policy, and background-coordinate order; and
- the program is acyclic and terminates, which follows from straight-line
  instruction order.

Validation is complete before publication. Audit builds SHOULD additionally
verify temporary live ranges and the schedule independently.

## 10. Derivative programs

Polynomial gradient and Hessian outputs are lowered from Typed Value IR that has
already been symbolically differentiated, per
[Decision 0003](../decisions/0003-derivative-method.md).

Scalar one-loop spectral derivatives remain invariant operations. Lowering
supplies the mass matrix and the required first- and second-background
derivative matrices to the backend's spectral derivative operation. That
operation implements
[Decision 0009](../decisions/0009-scalar-spectral-derivatives.md); it MUST NOT
differentiate the output order of `symmetric_eigensystem` or an eigenvector sign
convention. Its candidate `Complex64` gradient and Hessian outputs use the same
workspace and point-atomic publication boundary as the value.

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
- real-to-complex promotion is exact and no complex-to-real projection can be
  inserted;
- symmetric assembly uses the canonical triangle and matrix storage is covered
  exactly by the workspace query;
- eigensolver spectra retain negative, zero, and repeated eigenvalues and fail
  atomically on non-finite input and nonconvergence;
- scalar one-loop sums implement the principal branch and analytic zero-mode
  value;
- spectral derivatives are invariant under permutations, basis changes,
  eigenvalue order, and eigenvector signs;
- workspace is sufficient at exactly the queried size and rejected one byte
  below it, and misalignment is rejected;
- evaluation performs no allocation, asserted with a failing allocator;
- one failed point does not corrupt unrelated batch points;
- a failed fused derivative operation publishes none of that point's
  lower-order outputs, while separately requested supported lower-order
  operations may succeed;
- repeated same-kernel evaluation is bitwise identical;
- every program-validation rule rejects a targeted invalid program; and
- program validation and input packing are fuzzed.

## 12. Deferred decisions

This specification deliberately does not fix:

- general complex inputs, a complex-to-real projection, or a general complex
  logarithm;
- matrix operations beyond real-symmetric assembly and the selected
  eigensolver;
- master integrals beyond the scalar one-loop spectral sum or thermal
  functions;
- fused multiply-add, vectorized, or blocked execution;
- any optimized or ahead-of-time backend;
- a binary program encoding; or
- point-count-dependent workspace formulas.

Later catalogs MUST preserve the slot model, ordering rules, status semantics,
and allocation-free execution fixed here.
