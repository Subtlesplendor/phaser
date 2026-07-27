# Potential Kernel

Status: provisional specification

This document specifies the numerical evaluator produced from an
effective-potential artifact. It refines section 16 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

This specification defines the initial kernel architecture and numerical
contract. It does not define particular effective-potential formulas,
eigensolver algorithms, thermal-function approximations, or C ABI signatures.

## 1. Scope

A Potential Kernel evaluates a fixed, explicitly selected
effective-potential calculation for dynamic numerical inputs.

It supports, as declared capabilities:

- potential values;
- scalar and runtime-batch evaluation;
- gradients with respect to background coordinates;
- Hessians with respect to background coordinates;
- fused value and derivative outputs;
- separate perturbative-order or provenance-group outputs; and
- later derivatives with respect to explicitly selected non-background inputs.

Not every kernel supports every capability.

A Potential Kernel does not:

- derive diagrams or symbolic contributions;
- perform RG evolution implicitly;
- choose a background slice;
- minimize the potential;
- select a phase-transition workflow;
- infer an approximation from numerical failure; or
- provide the authoritative symbolic representation of the calculation.

## 2. Relationship to other representations

The lowering path is:

```text
Effective-Potential Artifact
        |
        | explicit contribution selection
        | kernel configuration
        v
Numerical Kernel IR
        |
        v
Potential Kernel
```

The effective-potential artifact is governed by
[Effective-Potential Artifact](../calculations/EFFECTIVE_POTENTIAL.md). The
general Numerical Kernel IR is governed by
[Phaser Internal Representations](INTERNAL_REPRESENTATIONS.md#6-numerical-kernel-ir).

`NumericalKernel` denotes reusable infrastructure for lowered numerical
programs. `PotentialKernel` denotes the potential-specific semantic interface
and capabilities. These terms do not require implementation-language
inheritance.

Other calculation kinds MAY later produce other typed kernel interfaces without
acquiring potential-specific background derivatives.

## 3. Meaning of compilation

Compiling a Potential Kernel means lowering exact scientific structure into a
bounded numerical evaluation plan. It includes:

- selecting requested contributions and outputs;
- choosing numerical implementations of operations;
- resolving typed dynamic input channels;
- scheduling evaluation;
- assigning temporary storage;
- planning tensor and matrix operations;
- choosing accumulation order;
- determining exact workspace requirements; and
- validating backend support.

Compilation does not necessarily generate native machine code.

### 3.1 Initial reference backend

Phaser 0.1 MUST provide a safe reference backend that executes an immutable
lowered instruction program.

The reference backend:

- uses the same binding and evaluation semantics as every optimized backend;
- remains suitable for scientific conformance tests;
- retains runtime-safety checks appropriate to the selected build mode;
- is independently testable from Typed Value IR evaluation; and
- defines the expected semantics of supported instructions.

Performance optimization MAY improve instruction dispatch, layouts, contraction
plans, and numerical operations without changing those semantics.

### 3.2 Deferred code generation

Ahead-of-time generated Zig or native code MAY be added as a later backend. It
MUST consume the same validated kernel configuration and preserve the same
scientific metadata, input categories, status rules, and declared
reproducibility policy.

Phaser 0.1 does not require a JIT backend. Runtime executable-memory management,
JIT security, and JIT cache compatibility are outside the initial contract.

## 4. Kernel configuration

A Potential Kernel is constructed from:

- a validated effective-potential artifact;
- explicit contribution selection;
- requested output capabilities;
- numerical scalar type;
- backend and target;
- derivative methods where applicable;
- reproducibility policy;
- special-function and master-integral policies;
- complex-result and branch policies;
- numerical approximation policies; and
- resource or fixed-capacity backend options.

Every configuration field that can affect the numerical program, supported
domain, output, or reproducibility MUST be retained in kernel metadata and in
any typed in-memory lookup key that an implementation actually uses, according
to [Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md).

There are no undocumented kernel-configuration defaults. A frontend MAY provide
named profiles, but each profile resolves to a complete configuration recorded
by the kernel.

## 5. Capabilities

### 5.1 Capability discovery

Kernel metadata MUST enumerate its supported operations before binding or
evaluation.

Initial capability categories are conceptually:

```text
value
value_batch
gradient
gradient_batch
hessian
hessian_batch
value_gradient
value_gradient_batch
value_gradient_hessian
loop_order_outputs
contribution_group_outputs
```

The exact enum and public names are deferred.

An implementation MAY infer batch support from the corresponding scalar
capability if their output contract is otherwise identical. Metadata must make
the supported shapes unambiguous.

Requesting an unavailable capability produces an ordinary error. Phaser MUST
NOT silently calculate an unavailable derivative by finite differences or
return fewer outputs than requested.

### 5.2 Fused capabilities

Fused operations SHOULD reuse field-dependent matrices, spectra, special
functions, contractions, and other intermediates.

`value_gradient` and `value_gradient_hessian` are distinct capabilities from
separate value, gradient, and Hessian calls. Separate calls MAY repeat work.

Every fused call evaluates all requested outputs at one input point and under
one consistent status and branch policy.

Publication is point-atomic. A fused operation computes into workspace and
publishes none of a point's requested outputs until every required value and
derivative has succeeded. If a requested Hessian produces
`singular_derivative`, the fused call publishes no value or gradient for that
point even when those lower-order quantities are finite. The caller may issue a
separate value or gradient operation at the same point; each operation has its
own status and publication boundary.

### 5.3 Capability sets and identity

The compiled capability set contributes to kernel identity when it changes the
instruction program, layouts, numerical algorithms, or workspace.

An evaluation call MAY request a subset of compiled capabilities. It MUST NOT
expand the kernel's capability set dynamically.

## 6. Numerical scalar types

### 6.1 Initial production type

`f64` is the initial real input scalar type and the result type for a selected
tree-only output. Every output selection containing a loop contribution uses
`Complex64 { re: f64, im: f64 }` for values, gradient entries, Hessian entries,
and separated loop-order or contribution-group outputs. Real contributions
promote to `(x, 0)`. Parameters, scales, environments, backgrounds,
field-dependent mass matrices, eigenvalues, and eigensolver work remain real
`f64`.

The result type is kernel metadata and does not change by point. A finite
nonzero imaginary component is a successful `Complex64` result with status
`ok`.

Every operation used by such a kernel MUST support its declared real or complex
result domain consistently,
including:

- exact-constant conversion;
- scalar arithmetic;
- matrix operations;
- spectral operations;
- implemented master integrals and thermal functions;
- derivative operations; and
- status and branch handling.

Supporting another scalar type in an isolated instruction does not imply
complete Potential Kernel support for that type.

### 6.2 Future types

The architecture MUST retain explicit scalar-type metadata and MUST NOT encode
`f64` assumptions into scientific IR semantics.

Future complete kernel types may include:

- `f32`;
- `f128` or another extended real type;
- externally provided multiprecision real types; or
- complex types beyond the paired binary64 result capability required by the
  initial scalar one-loop effective potential.

Each requires an explicit support matrix covering all operations reachable by
the kernel.

Higher-precision external calculations SHOULD be used as independent references
for numerical testing before Phaser provides a complete higher-precision
backend.

### 6.3 Exact conversion

Exact constants and normalized decimal inputs are converted directly to `f64`
under an explicit checked conversion policy.

Overflow, unsupported underflow, or loss prohibited by the responsible input
contract produces a diagnostic. Conversion MUST NOT silently pass through a
less capable intermediate representation.

## 7. Dynamic input interface

### 7.1 Input categories

Potential Kernel inputs remain separately typed categories:

```text
PotentialKernel inputs
|-- model parameters at the intended scale
|-- renormalization scale
|-- gauge parameters
|-- environment values
|   `-- temperature when applicable
`-- background coordinates
```

The exact set is determined by the artifact and configuration. A vacuum
gauge-free scalar potential has no temperature or gauge-parameter channels.

Input categories MUST NOT become interchangeable merely because they use the
same machine type.

### 7.2 High-level binding

A high-level immutable binding SHOULD normally accept a complete validated parameter
point compatible with the model and scheme, even if one kernel depends on only
a subset of its values.

This permits:

- model and scheme compatibility validation;
- parameter-point provenance;
- reference-scale checks;
- consistent reuse across kernels; and
- dependency-directed packing.

The binder resolves required values into a compact kernel input buffer. Unknown,
missing, duplicate, dimensionally invalid, or non-representable inputs are
rejected.

The exact distinction between complete high-level objects and low-level packed
buffers is an API decision. Both MUST represent the same typed channels.

### 7.3 Staged binding

Parameters, renormalization scale, gauge parameters, and environment state MAY
be bound in stages according to
[Evaluation Lifecycle and API Semantics](EVALUATION_LIFECYCLE.md).

Binding MAY allocate and prepare values whose dependencies are already fixed. It MUST NOT
perform work depending on a later background coordinate.

A new value initially creates a new immutable binding. A future incremental
rebinding optimization must invalidate every dependent precomputation.
Dependency tracking follows
[Structural Compilation and Dynamic Binding](STRUCTURAL_COMPILATION.md).

### 7.4 Packed metadata

Kernel metadata MUST describe every packed input channel:

- category;
- semantic ID or stable source reference;
- human-readable diagnostic name;
- scalar type;
- shape;
- mass dimension or units;
- buffer offset and stride where applicable; and
- dependency stage.

Packed offsets are execution details and MUST NOT replace semantic identities in
provenance.

## 8. Background evaluation

Background inputs follow
[Background Parametrization](../formats/BACKGROUND_PARAMETRIZATION.md).

A scalar point has logical shape:

```text
[background_coordinate_count]
```

A batch has logical shape:

```text
[point_count, background_coordinate_count]
```

with a contiguous row-major fast path initially. Points are supplied at runtime,
may be nonuniform and adaptive, and do not alter kernel identity.

Scalar and batch-of-one evaluation MUST agree under the same numerical and
reproducibility policy.

No scalar call is delayed to manufacture a hidden batch.

## 9. Output interface

### 9.1 Scalar-point outputs

For \(n\) background coordinates, supported outputs have logical shapes:

```text
value                         scalar
gradient                      [n]
hessian                       [n, n]
loop-order values             [n_orders]
contribution-group values     [n_groups]
status                        status record
```

Only declared outputs are present.

Each logical element has the result type declared by the selected contribution
set under section 6.1. In particular, an order-one selected value, gradient, or
Hessian element is `Complex64` even at a point where its imaginary component is
zero.

### 9.2 Batch outputs

Batch output prepends the point dimension:

```text
values                        [point_count]
gradients                     [point_count, n]
hessians                      [point_count, n, n]
loop-order values             [point_count, n_orders]
statuses                      [point_count]
```

Output point order MUST equal input point order.

### 9.3 Hessian representation

The initial public Potential Kernel interface returns a full dense Hessian in
canonical background-coordinate order.

The kernel MAY exploit symmetry and packed storage internally. It MUST
materialize the declared full output without requiring callers to understand
the internal representation.

Hessian symmetry is a scientific and numerical invariant tested under the
declared comparison policy. The evaluator MUST NOT silently symmetrize an
otherwise inconsistent result merely to pass that check.

### 9.4 Buffer rules

The low-level API validates:

- output element type;
- shape and capacity;
- alignment;
- strides where supported;
- permitted input/output aliasing; and
- workspace separation.

Unsupported or dangerous overlaps are rejected before execution. Exact ABI
rules are deferred to the C interface specification.

## 10. Lowered instruction program

### 10.1 Program properties

The reference backend consumes an immutable, acyclic or otherwise
termination-proven instruction program with:

- typed operands and results;
- statically validated shapes;
- explicit input and output slots;
- bounded temporary slots;
- deterministic instruction order;
- explicit numerical operation selection; and
- no dynamic instruction creation during evaluation.

All instruction references MUST be validated before the program becomes a
kernel.

### 10.2 Instruction contracts

Every implemented instruction kind defines:

- operand and result types;
- mathematical semantics;
- supported scalar types;
- value domain and branch behavior;
- status behavior;
- workspace and alignment;
- aliasing rules;
- derivative support;
- reproducibility behavior; and
- reference implementation.

The reference backend's complete semantic opcode catalog is specified in
[Kernel Instruction Set](KERNEL_INSTRUCTION_SET.md). It is a closed,
exhaustively checked tagged union for each Phaser build. Concrete Zig and binary
layouts remain internal.

### 10.3 Scheduling and temporaries

Lowering assigns:

- topological or otherwise valid execution order;
- common subexpressions;
- temporary storage and lifetimes;
- matrix and contraction layouts;
- accumulation order; and
- reusable parameter- or environment-dependent stages.

Temporary-slot reuse MUST respect live ranges, types, shapes, alignment, and
aliasing. Audit mode SHOULD verify the schedule independently where practical.

### 10.4 Optimization

An optimization pass MUST preserve:

- typed numerical semantics;
- selected outputs;
- contribution selection and perturbative truncation;
- status and branch policy;
- reproducibility guarantees; and
- dependency metadata.

An optimization MUST NOT introduce a new scientific assumption. Such a
transformation belongs to a future explicit specialization capability, not
ordinary lowering.

The reference interpreter SHOULD keep loop nesting and batch storage policy open
to measurement. A row-major public input buffer does not require point-major
instruction dispatch internally. A backend MAY process blocked instruction-
major lanes, transpose a bounded block into caller-provided workspace, or use a
point-major scalar path. Representative scalar and batch benchmarks decide among
these strategies; no hidden allocation or API layout change is implied.

## 11. Numerical operation boundary

Potential kernels may require:

- scalar elementary functions;
- dense and structured matrix operations;
- symmetric or Hermitian eigensolvers;
- invariant spectral sums;
- zero- and finite-temperature master integrals;
- thermal functions;
- interpolation or approximation tables; and
- reproducible reductions.

Each implementation belongs to a versioned numerical-operation catalog. The
kernel records the selected implementation or policy wherever it can affect
results.

A numerical operation unavailable for the selected scalar type, domain,
derivative capability, or backend causes lowering to fail. Phaser MUST NOT
replace it with an unrequested approximation.

Detailed eigensolver, master-integral, and thermal-function contracts require
separate specifications.

## 12. Derivatives

### 12.1 Capability semantics

Potential Kernel gradients and Hessians are derivatives with respect to the
ordered background coordinates unless another category is explicitly selected.

They obey the background embedding and chain-rule contract in
[Background Parametrization](../formats/BACKGROUND_PARAMETRIZATION.md#9-restricted-and-full-derivatives).

The kernel metadata records the method used for each derivative capability.

### 12.2 Permitted methods

A kernel MAY use:

- differentiation of the Typed Value IR before lowering;
- forward-mode automatic differentiation;
- analytic numerical-operation rules;
- a validated hybrid; or
- an explicitly selected finite-difference method.

No one method is required for every operation in version 0.1.

Because selected background spaces are often low-dimensional, forward-mode
automatic differentiation is an initial candidate, not a mandated solution.

### 12.3 Spectral derivatives

Differentiating through a generic eigenvalue-labeling procedure is not by itself
a sufficient contract near degeneracies.

Spectral derivatives SHOULD be expressed through invariant matrix or spectral
operations where practical. Their implementation MUST declare:

- supported matrix properties;
- degeneracy behavior;
- zero-mode and branch behavior;
- derivative order;
- numerical tolerances; and
- unsupported domains.

The exact spectral-derivative algorithm is deferred.

### 12.4 Finite differences

Finite differences are an explicit capability or external workflow.

They MUST record stencil, step policy, bounds handling, scale policy, and
failure behavior. A kernel MUST NOT silently use finite differences because an
analytic or automatic method is unavailable.

## 13. Workspace

The general ownership, allocation, and capacity rules are specified in
[Memory Architecture](MEMORY_ARCHITECTURE.md).

### 13.1 Exact query

Before execution, the kernel provides exact workspace requirements for:

- requested operation or fused capability;
- point count or backend capacity;
- scalar type;
- worker count;
- backend; and
- relevant output layout.

Conceptually:

```text
workspace_layout(operation, point_count, worker_count)
```

The returned layout includes total byte size, alignment, and any required
subregions or per-worker constraints.

### 13.2 Workspace contents

Workspace may include:

- typed real and `Complex64` numerical temporary slots;
- authoritative and materialized real-symmetric matrices;
- real eigenvalues, scaled working matrices, eigenvectors or equivalent
  transformation state, and residual scratch;
- derivative values;
- contraction scratch;
- special-function state;
- reduction buffers;
- per-point status state; and
- per-worker storage.

Callers MUST NOT infer workspace solely from public input and output shapes.
Matrix dimension and the selected eigensolver are fixed kernel structure, so
the query accounts for their exact checked byte sizes and alignments rather than
returning an asymptotic estimate. Exact-size workspace succeeds and one byte
less fails before evaluation.

### 13.3 Allocation

Kernel execution MUST allocate no memory. Insufficient or misaligned workspace
is a call-level error detected before unsafe use.

High-level frontends MAY allocate or grow reusable workspace outside the core
evaluation call.

## 14. Status and failure

Potential Kernel evaluation distinguishes:

- call-level contract errors;
- point-level numerical status; and
- internal invariant failures.

The detailed division follows
[Evaluation Lifecycle and API Semantics](EVALUATION_LIFECYCLE.md#9-errors-and-per-point-status).

Every numerical instruction must map its expected domain and convergence
failures into the kernel status system. Internal invalid opcodes, slot types,
or buffer plans are asserted programmer errors after kernel validation.

The initial point statuses and meanings are:

```text
ok
non_finite
division_by_zero
nonconvergent
singular_derivative
```

`non_finite` reports non-finite input to a point operation or non-finite
arithmetic for which no analytic limit applies. `nonconvergent` reports a
bounded numerical operation that exhausted its convergence or postcondition
contract. `singular_derivative` reports a mathematically singular requested
derivative, including an uncancelled zero-mode scalar Hessian term. These
statuses MUST NOT be collapsed into one another. A negative mass-squared
eigenvalue and a finite nonzero imaginary component remain `ok`.

A batch SHOULD retain independent status for each point. A failed point MUST
NOT corrupt another point's output or workspace.

For a failed point, an operation publishes none of that point's declared
outputs. This point-atomic rule applies to scalar, batch, fused, loop-order, and
contribution-group outputs. Other points in a collecting batch retain their
independent successful outputs.

The kernel MUST NOT silently:

- take a real part;
- replace an argument by its absolute value;
- return \(+\infty\) as an optimizer penalty;
- suppress a nonconvergence;
- downgrade precision; or
- select another approximation.

Any such behavior belongs to an explicit numerical or workflow policy.

## 15. Reproducibility

Phaser distinguishes three scopes. Only the first is required by the initial
serial reference backend.

### 15.1 Same-kernel reproducibility

Repeated execution of the same kernel object, inputs, operation, and workspace
configuration produces bitwise-identical successful outputs and statuses under
the version 0.1 reproducible policy.

This is the initial mandatory reproducibility level.

Requirements across scheduling and worker counts are defined only when an
internally parallel backend is introduced. They are not version 0.1 reference-
backend implementation or test work.

### 15.2 Same-target rebuild reproducibility

Independently constructed kernels with equivalent content, the same declared
target, compiler and dependency versions, configuration, and lowering version
SHOULD produce bitwise-identical results.

Failure to achieve this must be documented in backend metadata and tested under
the next level.

### 15.3 Cross-platform numerical agreement

Different targets or numerical libraries are required to agree under a declared
scientific numerical-comparison policy. Universal cross-platform bitwise
identity is not promised.

Comparison policies must be operation-aware and include difficult cases such as
degeneracies, cancellations, and special-function boundaries. They are declared
in [Numerical Comparison](NUMERICAL_COMPARISON.md), which states how a
cross-platform requirement is discharged for a quantity through that quantity's
own operation-specific policy.

### 15.4 Faster policies

A future policy MAY permit nondeterministic parallel reductions or other
relaxations. It must be explicitly selected, recorded in kernel identity, and
tested separately.

Reproducibility MUST NOT depend on hash-map iteration, allocation order, or
thread scheduling under the reproducible policy.

## 16. Reentrancy and parallelism

The complete contract is specified in
[Parallelism and Reentrancy](PARALLELISM.md).

A kernel and logically immutable bound context are reentrant when each
evaluation stream has independent workspace and output buffers.

No evaluation may depend on mutable global numerical or scientific state.

Parallelism MAY occur over points, contractions, matrix operations, or other
independent work. The selected strategy is backend configuration and must obey
the reproducibility policy.

The initial reference backend MAY be serial. A serial backend is not permitted
to change scalar versus batch semantics.

## 17. Metadata and inspection

A Potential Kernel MUST expose enough metadata to inspect:

- parent model fingerprint, normalized calculation request, and opaque object
  identifiers where useful;
- contribution selection and perturbative truncation;
- future structural assumptions, if such a capability is later implemented;
- input channels and packing order;
- background-coordinate embedding;
- capabilities and output layouts;
- scalar type and precision;
- backend, target, compiler, and build mode;
- derivative methods;
- numerical-operation and approximation policies;
- complex and branch policies;
- reproducibility level;
- workspace requirements;
- supported point-count or capacity bounds; and
- relevant status semantics.

Metadata is immutable and available without performing an evaluation.

## 18. Cache behavior

Optional kernel lookup and fingerprint behavior follow
[Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md).

Cache presence does not affect kernel semantics. An interpreted kernel and a
future AOT kernel have different backend identities even when they implement the
same artifact and numerical policy.

The AOT compilation boundary and its validation requirements are specified in
[Zig `comptime` and Model-Specific AOT Compilation](COMPTIME_AND_AOT.md).

Dynamic background points are not part of kernel identity and are not
implicitly memoized.

## 19. Validation and testing

Architecture-wide reference, numerical-comparison, and fuzzing rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

Required construction and lowering tests include:

- every instruction program is typed, bounded, and valid before publication;
- invalid instruction references and type mismatches are rejected;
- requested unsupported capabilities fail during lowering;
- input and output metadata agree with actual layouts;
- workspace queries agree with actual access at exact boundaries;
- temporary live ranges and aliasing are valid;
- dependency stages contain no later-stage work;
- deterministic lowering is independent of allocation and scheduling; and
- kernel metadata and any implemented lookup key cover every effective
  configuration field.

Required execution tests include:

- reference interpreter agrees with direct Typed Value IR evaluation;
- scalar and batch-of-one agree;
- arbitrary batch partitions and permutations agree with scalar evaluation;
- fused and separate outputs agree;
- dense Hessian output has correct coordinate order and symmetry;
- all supported input categories produce correct immutable bindings;
- evaluation performs no allocation;
- insufficient and misaligned workspace fail before execution;
- per-point failure cannot corrupt other batch points;
- repeated same-kernel evaluation is bitwise reproducible;
- safe and optimized implementations agree under their declared policy;
- exact constants and normalized decimals convert correctly;
- negative, zero, degenerate, hierarchical, and near-singular cases;
- finite complex results are `ok`, while `non_finite`, `nonconvergent`, and
  `singular_derivative` are exercised separately;
- a failed fused point publishes no partial lower-order, loop-order, or
  contribution-group output, while a separate supported lower-order operation
  at the same point succeeds;
- no unrequested real-part, absolute-value, penalty, or precision fallback; and
- concurrent evaluation with separate workspaces agrees with serial execution.

Property tests SHOULD generate valid typed instruction programs, compare their
reference execution with direct expression evaluation, and partition arbitrary
point sets into scalar and batch calls.

Fuzzing SHOULD target:

- instruction-program validation;
- slot and buffer layouts;
- capability combinations;
- input packing;
- point counts and shapes;
- workspace sizes and alignments;
- aliasing;
- numerical status propagation; and
- bind, evaluate, fail, and create-another-binding state sequences.

## 20. Deferred decisions

This specification deliberately does not fix:

- concrete instruction-record and binary layouts;
- public configuration syntax;
- C ABI handles and function signatures;
- Python class and method names;
- the first optimized or AOT backend;
- JIT support;
- scalar types beyond complete `f64` support;
- complex inputs and result types beyond `Complex64`;
- spectral-derivative algorithms beyond their invariant semantic contract;
- master-integral and thermal-function implementations;
- automatic-differentiation implementation;
- precise numerical tolerance catalogs;
- backend threading strategies;
- strided and non-row-major public buffers; or
- GPU and accelerator support.

Future backends MUST preserve the Potential Kernel semantics and capability
contracts defined here.
