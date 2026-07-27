# Evaluation Lifecycle and API Semantics

Status: provisional specification

This document specifies the lifecycle from a validated calculation request to
repeated numerical evaluation in Phaser. It refines section 14 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

This specification defines semantic object boundaries and evaluation shapes. It
does not fix Python class names, C ABI signatures, or the numerical instruction
set of a Potential Kernel.

## 1. Goals

The lifecycle MUST support:

- deriving scientific structure once;
- compiling reusable numerical evaluators;
- cheaply changing model parameters, scales, gauge parameters, and temperature;
- evaluating arbitrary adaptively chosen background points;
- evaluating runtime batches when several independent points are available;
- fused value and derivative calculations;
- allocation-free core evaluation;
- explicit domain diagnostics; and
- use by external minimizers and other numerical workflows.

Batching is a performance capability. It is not a requirement that a caller know
future background points in advance.

## 2. Conceptual lifecycle

The principal lifecycle is:

```text
source model
    |
    v
parse, validate, and canonicalize
    |
    v
Canonical Model IR + calculation request
    |
    v
plan calculation
    |
    v
derive calculation artifact
    |
    v
lower numerical kernel
    |
    v
bind parameter and scale context
    |
    v
bind environment-dependent state when applicable
    |
    v
evaluate arbitrary scalar points or runtime batches
```

Each transition MUST be explicit and independently diagnosable. Failure at one
stage MUST NOT produce a valid-looking object for the following stage.

Implementations MAY combine adjacent stages in a convenience API. Such
combination MUST NOT hide the semantic inputs, defaults, provenance, or error
boundary of either stage.

## 3. Lifecycle objects

### 3.1 Canonical model

The canonical model is validated and immutable. It may be reused by any number
of calculation requests.

Numerical parameter values and calculation-specific choices are not stored in
the canonical model.

### 3.2 Calculation request

The request specifies the structural scientific calculation. It includes, as
applicable:

- calculation kind;
- background parametrization;
- environment kind;
- renormalization scheme;
- gauge fixing;
- perturbative truncation; and
- contribution selection.

It contains no background evaluation points or ordinary dynamic parameter
values.

### 3.3 Plan

A plan is the deterministic, validated dependency graph required to satisfy a
request for a particular model.

Planning MUST resolve:

- dependent derivations;
- supported calculation, order, scheme, gauge, and environment combinations;
- structural zeros and impossible sectors;
- required model tensors and conventions;
- resource limits known before derivation; and
- diagnostics for unsupported requests.

A plan MAY expose estimates and an explanation of its dependencies for
inspection. It contains no derived numerical result.

Whether `Plan` is a required public object or an inspectable intermediate behind
a convenience call is deferred.

### 3.4 Calculation artifact

The calculation artifact is the immutable scientific result of derivation. It
retains exact values, contribution structure, perturbative order, provenance,
dependencies, and scientific context.

For an effective potential, its detailed contract is
[Effective-Potential Artifact](../calculations/EFFECTIVE_POTENTIAL.md).

The artifact is suitable for inspection, symbolic export, selection, and
numerical lowering. It is not bound to a numerical parameter point.

### 3.5 Numerical kernel

A numerical kernel is an immutable evaluation plan lowered from an artifact and
an explicit kernel configuration.

Effective-potential kernels additionally follow the
[Potential Kernel](POTENTIAL_KERNEL.md) contract.

Its metadata declares:

- required dynamic input channels;
- background-coordinate layout;
- supported scalar type and precision;
- available output and derivative capabilities;
- backend and reproducibility policy;
- numerical domain and approximation policies;
- workspace requirements; and
- model, calculation, and specialization identities.

Compiling a kernel does not bind the current parameter point, temperature, or
background.

### 3.6 Bound parameter context

A bound parameter context associates a kernel with:

- model parameters at the intended scale;
- explicit renormalization scale;
- non-fixed gauge parameters; and
- other parameter-frequency dynamic inputs required by the kernel.

Binding MAY precompute values depending only on those inputs. It MUST NOT
perform background-dependent work.

The context is a complete immutable semantic value: evaluation MUST NOT observe
partially constructed binding state. Version 0.1 creates a new context for a new
parameter point. Mutable in-place rebinding is a future measured optimization.

### 3.7 Environment context

A calculation MAY have another binding stage for inputs reused across many
background evaluations, most notably temperature.

For a thermal potential, an environment context may precompute values depending
on the bound parameters, scale, gauge context, and temperature but not on the
background.

A vacuum calculation has no temperature-binding stage. An implementation MAY
fuse parameter and environment binding in its convenience API while preserving
their dependency metadata.

## 4. Background evaluation points

Background coordinates and their canonical order are defined by
[Background Parametrization](../formats/BACKGROUND_PARAMETRIZATION.md).

A background point is a vector containing exactly one numerical value per
declared background coordinate. It is selected entirely at runtime.

Background points:

- MAY be generated adaptively;
- MAY jump arbitrarily through field space;
- need not lie on a grid;
- need not be sorted;
- need not be close to previous points; and
- are never embedded in generic kernel identity.

Changing a background point MUST NOT trigger planning, derivation, compilation,
or parameter rebinding.

## 5. Evaluation shapes

### 5.1 Scalar evaluation

One-point evaluation is a first-class operation. Conceptually:

```text
value(point)
value_gradient(point)
value_gradient_hessian(point)
```

The supported operations are kernel capabilities, not universal promises.

A scalar operation MUST have a direct bounded execution path. It MUST NOT depend
on collecting future calls into a hidden batch.

An implementation MAY execute a scalar call through the batch machinery with
point count one, provided this does not change semantics or make scalar
evaluation unreasonably inefficient.

### 5.2 Batch evaluation

A batch is a runtime collection of independent background points:

```text
value_batch(points)
value_gradient_batch(points)
```

The points in one batch may be completely unrelated. The batch need not be known
when the kernel is compiled.

For a canonical dense interface, the logical shape is:

```text
[point_count, background_coordinate_count]
```

with coordinates in the order declared by kernel metadata. Exact C and Python
memory-layout rules are deferred, but a contiguous row-major representation
SHOULD be the initial interoperable fast path.

Batch output order MUST equal input point order. Permuting the input points MUST
produce the corresponding output permutation under a deterministic execution
policy.

### 5.3 Equal status

Scalar and batch interfaces represent the same mathematical evaluator.

For every valid point \(x\):

```text
value(x) == value_batch([x])[0]
```

under the same backend, precision, and reproducibility policy.

Neither interface is scientifically preferred. Scalar evaluation is appropriate
for adaptive algorithms; batching is appropriate when the caller naturally has
multiple independent points.

## 6. Fused outputs

Value, gradient, Hessian, spectral data, and contribution-group outputs may share
expensive intermediate calculations.

Phaser SHOULD support fused capabilities where the underlying kernel can reuse
work, including:

```text
value_gradient(point)
value_gradient_hessian(point)
```

A fused operation computes its requested outputs consistently at one point and
under one status policy.

Fused publication is point-atomic. Candidate outputs remain in workspace until
every requested value and derivative for that point has succeeded. If any
requested derivative fails, none of the fused outputs for that point are
published. For example, a `value_gradient_hessian` call that reaches a singular
zero-mode Hessian returns `singular_derivative` without publishing its otherwise
finite value or gradient.

Atomicity is per operation, not a claim that every lower-order quantity is
undefined. A caller that needs the supported lower-order result at the same
background may request `value` or `gradient` separately; that operation has its
own status and publication boundary.

The API MUST NOT silently calculate a derivative by finite differences because
a symbolic, analytic, or automatic derivative capability is unavailable.
Finite differences are an explicit numerical workflow or explicitly selected
kernel capability.

Calling separate value and gradient methods MAY repeat work. Callers and
optimizer adapters SHOULD use a fused operation when available.

Phaser SHOULD prefer fused operations over a hidden mutable “last evaluated
point” cache. Any memoization that is later introduced must have an exact
semantic key, bounded storage, explicit thread-safety behavior, and no effect on
results.

## 7. Batching and performance

Batch evaluation can provide:

- fewer language-boundary calls;
- reuse of parameter- and temperature-dependent state;
- parallel evaluation of independent points;
- vectorization of suitable operations;
- blocked matrix or special-function evaluation; and
- efficient population, scan, and finite-difference workflows.

These benefits are workload- and backend-dependent. Batch execution MUST be
benchmarked against repeated scalar evaluation on representative potentials.

Phaser MUST NOT manufacture batches by delaying unrelated scalar calls. Hidden
micro-batching changes latency and introduces state that is unsuitable for
adaptive minimizers.

A CPU kernel SHOULD accept runtime point counts within documented resource
limits rather than require compilation for one exact count. A backend MAY have:

- a maximum supported count;
- a preferred block size;
- a fixed-capacity configuration; or
- backend-specific batch restrictions.

Such properties belong to kernel configuration and metadata. The exact point
count of an ordinary evaluation is dynamic.

## 8. Workspace and allocation

Core kernel evaluation MUST allocate no memory.

Workspace ownership, capacity accounting, and the control-plane allocation
boundary follow
[Memory Architecture](MEMORY_ARCHITECTURE.md).

The kernel MUST provide enough information to determine required:

- output storage;
- scratch workspace;
- alignment; and
- per-worker state

for the requested operation and point count.

Conceptually:

```text
workspace_requirement(operation, point_count)
```

The requirement MAY be constant, proportional to point count, proportional to
worker count, or backend-specific. Callers MUST NOT infer it from matrix
dimensions alone.

A Python or other high-level frontend MAY allocate result objects and manage
reusable workspace for convenience. Such allocation occurs in the frontend,
outside the core evaluation operation.

The frontend SHOULD reuse one-point workspace for adaptive scalar calls and MAY
grow reusable batch buffers before evaluation. Failure to obtain frontend
storage is reported before entering the kernel.

## 9. Errors and per-point status

Evaluation distinguishes call-level errors from point-level numerical status.

Call-level errors include:

- wrong input shape or scalar type;
- incomplete or invalid binding;
- unknown requested capability;
- overlapping buffers where forbidden;
- insufficient or misaligned workspace; and
- point count outside backend limits.

These errors are detected before numerical evaluation where practical.

Point-level status includes failures or exceptional domains arising only for a
particular background, such as:

- `non_finite`, for non-finite inputs or arithmetic not covered by an analytic
  limit;
- `division_by_zero`, for a zero divisor in the ordinary real instruction set;
- `nonconvergent`, for a bounded numerical operation that exhausts its
  convergence or postcondition contract; and
- `singular_derivative`, for a requested derivative that is mathematically
  singular.

`ok` denotes success. These outcomes are distinct: a singular zero-mode Hessian
is not manufactured as infinity and reported `non_finite`, and a failed
eigensolver is not reported as a derivative singularity. For the supported
scalar one-loop principal branch, a negative eigenvalue and a finite nonzero
imaginary component are `ok`; they are not exceptional domains.

A batch interface SHOULD be able to return one status per point so a failed
point does not erase valid results for unrelated points. An explicit
`fail_fast` policy MAY be provided.

Output publication is point-atomic for every scalar, batch, or fused operation.
A failed point publishes none of the outputs declared by that operation,
including lower-order, loop-order, and contribution-group outputs. Successful
points before or after it in a collecting batch retain their results. A
`fail_fast` call may stop before later points, but it MUST NOT expose candidate
outputs from the point that caused the stop.

The core MUST NOT silently replace a failed point with \(+\infty\), a real part,
an absolute value, or another optimizer-oriented penalty. A workflow adapter MAY
apply such a policy only when explicitly configured and recorded.

## 10. External minimizers

Minimization is a consumer of a potential evaluator, not part of the fundamental
kernel lifecycle.

A conventional adaptive minimizer may call:

```text
value(point)
```

at one newly selected point at a time. A gradient-based minimizer may instead
use a fused value-and-gradient operation. Neither case requires batching.

Other algorithms may naturally provide batches, including:

- population-based global optimization;
- multi-start searches;
- finite-difference stencils;
- simultaneous phase comparisons; and
- vectorized sampling or scanning.

Adapters for SciPy, other optimization libraries, or future Phaser numerical
workflows MAY translate their callback and status conventions to this API.
Adapters MUST expose any policy for bounds, invalid points, penalties,
tolerances, and derivative fallback.

A future native minimizer MAY hold a kernel and workspace inside a tight Zig
loop to avoid language-boundary overhead. It remains a replaceable numerical
workflow and MUST use the same kernel semantics as external callers.

## 11. Python-facing ergonomics

The Python layer SHOULD offer explicit scalar and batch methods rather than
relying only on ambiguous array-rank dispatch. A provisional shape is:

```python
point = potential.backgrounds.pack(h=100.0, s=20.0)

value = potential.value(point)
value, gradient = potential.value_gradient(point)

values = potential.value_batch(points)
```

Named packing is a convenience and performs name resolution outside the hot
kernel path. Repeated high-throughput calls SHOULD accept contiguous numerical
arrays directly.

Python methods MAY allocate ordinary Python or array return values. Lower-level
methods MAY accept caller-provided `out` buffers to avoid repeated frontend
allocation.

The wrapper SHOULD release the Python interpreter lock during sufficiently
substantial core evaluation where safe. Exact binding technology remains
deferred.

## 12. Concurrency and ownership

The complete scheduling and reentrancy contract is specified in
[Parallelism and Reentrancy](PARALLELISM.md).

Canonical models, calculation artifacts, numerical kernels, and logically
immutable bound contexts MAY be shared across threads.

Mutable evaluation workspace MUST NOT be used concurrently unless its
implementation explicitly supports that use. The normal parallel contract is:

```text
shared immutable kernel and bound context
        |
        +-- evaluation stream 1 + workspace 1
        +-- evaluation stream 2 + workspace 2
        `-- evaluation stream 3 + workspace 3
```

No evaluation may depend on mutable global scientific state.

Parallel or batched execution MUST preserve output ordering. Reproducible mode
also preserves the specified reduction behavior.

## 13. Identity and caching

Planning, artifact, and kernel metadata follow
[Structural Compilation and Dynamic Binding](STRUCTURAL_COMPILATION.md)
and [Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md).

Ordinary background points and runtime batch sizes do not alter calculation or
kernel identity.

A fixed-capacity backend configuration MAY alter kernel identity if it changes
layouts or generated code. The number of points passed to one call within that
capacity does not.

Version 0.1 does not require bound-state or background-result caches. Explicit
immutable bindings and reusable workspaces provide the initial reuse mechanism.

## 14. Validation and testing

Architecture-wide stateful, differential, and fuzzing rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

Required tests include:

- every invalid public lifecycle transition is rejected;
- planning and derivation failures produce no valid downstream object;
- scalar evaluation agrees with batch-of-one evaluation;
- batch output order follows arbitrary input order;
- batch permutation produces the corresponding output permutation;
- fused outputs agree with separately evaluated outputs;
- adaptive nonuniform point sequences require no recompilation;
- parameter and temperature binding reuse only valid precomputations;
- independently constructed bindings with the same values agree;
- workspace requirements are sufficient at exact capacity boundaries;
- core evaluation performs no allocation;
- call-level validation occurs before unsafe buffer use;
- one failed batch point does not corrupt unrelated outputs;
- each failed point publishes none of that operation's outputs;
- a fused `singular_derivative` publishes no finite lower-order candidate,
  while a separate supported value or gradient call at the same point succeeds;
- finite nonzero imaginary results are `ok`, and `non_finite`,
  `nonconvergent`, and `singular_derivative` are distinguished;
- explicit `fail_fast` and collect policies agree on preceding valid points;
- concurrent evaluation with separate workspaces agrees with serial execution;
- Python convenience and low-level buffer interfaces agree; and
- external optimizer adapters preserve coordinate order and status policy.

Property tests SHOULD generate arbitrary point sequences and batch partitions,
then compare all partitions with scalar evaluation under the same numerical
policy.

Fuzzing SHOULD exercise public lifecycle state transitions, shapes, strides, point
counts, workspace boundaries, overlapping buffers, per-point statuses, and
repeated bind/evaluate/failure sequences.

## 15. Deferred decisions

This specification deliberately does not fix:

- exact Zig, C, or Python names and signatures;
- whether `Plan` is always public;
- concrete bound-context ownership and mutation APIs;
- zero-length batch semantics;
- supported strided or column-major layouts;
- default collect versus fail-fast policy;
- exact batch workspace formulas;
- backend threading and preferred block sizes;
- native minimizer implementations;
- optimizer-specific penalty policies; or
- GPU and accelerator batch interfaces.

These decisions MUST preserve first-class scalar evaluation and runtime,
non-predetermined batching.
