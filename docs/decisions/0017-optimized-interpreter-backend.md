# Decision 0017: Predecoded blocked optimized interpreter

Status: accepted

## Context

The safe point-major interpreter is Phaser's auditable numerical reference, but
representative fixed-binding scans spend substantial time resolving typed slot
descriptors, repeating structural numerical checks, dispatching each point
separately, and checking status after instructions that cannot fail. Those costs
are control-plane facts paid in the numerical data plane.

The workload to improve is repeated scalar and batch evaluation with fixed
model structure, parameter values, and renormalization scale. Scientific
semantics, status distinctions, output order, allocation behavior, and the
reference implementation must remain unchanged.

## Decision

Phaser provides two explicitly selected interpreted backends:

```text
reference_interpreter
optimized_interpreter
```

The reference interpreter remains complete and authoritative. Requesting the
optimized interpreter either constructs that backend or returns an ordinary
construction error; it never publishes a reference kernel under the optimized
identity.

The optimized backend compiles an already validated `Program` into an immutable
private `ExecutionPlan`. Compilation:

- converts temporary identifiers to checked scalar-frame offsets;
- copies variadic operand offsets into contiguous plan storage;
- prepares fixed eigensystem and spectral-derivative shapes once;
- records output offsets and the parameter-stage boundary;
- records only parameter-stage regions live into point execution or final
  publication; and
- computes one exact backend-specific workspace layout.

The plan does not change the opcode sequence, accumulation order, integer-power
sequence, branch policy, or numerical-operation selection.

On ARM64 and baseline x86-64, arithmetic batches use four-point slot-major
blocks implemented as two portable two-lane `f64` vectors. Vectorization is
only across independent points. A batch remainder uses the same predecoded
scalar leaf. Other targets use scalar width one until generated-code and
platform evidence justify another declared width.

Division carries one status per lane. Failed lanes publish nothing and cannot
affect successful lanes. Structured eigensystem and spectral-derivative
instructions initially execute the validated scalar numerical leaf once per
active lane; arithmetic before and after them remains blocked. This is part of
the optimized backend, not a backend fallback.

Runtime safety is disabled only in small arithmetic leaf functions entered
after complete call and plan validation. Plan construction, buffer validation,
workspace slicing, status handling, structured numerical operations, and
publication remain safety checked in `ReleaseSafe`. The unsafe leaves allocate
nothing, change no ownership, and accept only plan-derived offsets into
prevalidated typed storage.

Bindings remain immutable. An optimized binding stores a compact prologue
containing only live parameter-stage regions, the parameter-stage status, the
backend identity, and a borrowed immutable plan view. Evaluation materializes
those regions directly into each block.

Phaser creates no workers. Callers may partition a point range into deterministic
contiguous chunks, share one immutable kernel and binding, and provide one
workspace and disjoint output/status regions per worker.

## Verification

The safe interpreter is the differential oracle. Bounded tests and structured
fuzzing compare:

- scalar, full-block, and scalar-remainder execution;
- arbitrary point status patterns;
- tree value and fused derivatives;
- one-loop values for 1x1, 2x2, and 3x3 spectra;
- invariant spectral gradients and Hessians;
- direct and staged execution;
- exact workspace and one-byte-short rejection; and
- serial and caller-parallel output order.

Successful results and statuses are bitwise identical for the same program,
target, build configuration, and inputs. Benchmarks report both backend
identities separately.

Generated-code inspection confirms packed two-lane `f64` arithmetic rather
than relying on source-level vector syntax: the ReleaseSafe ARM64 binary
contains NEON `fadd.2d`, `fmul.2d`, `fdiv.2d`, and `fneg.2d`, while a baseline
Linux x86-64 cross-build contains SSE2 `addpd`, `mulpd`, `divpd`, and `subpd`.

## Alternatives

Replacing the safe interpreter was rejected because it would make performance
encoding the only scientific oracle.

Whole-library `ReleaseFast` was rejected because it would turn unrelated
assertions and bounds into optimizer assumptions without establishing a narrow
trusted boundary.

Point-major batching was retained only in the reference backend because it
cannot expose SIMD across independent backgrounds. A structure-of-arrays public
API was unnecessary: the optimized backend transposes a bounded block into
caller-owned private workspace.

An internal worker pool was rejected because it would add hidden scheduling,
allocation, oversubscription, and nested-parallelism behavior. Coarse scheduling
belongs to the caller.

Model-specific native code generation remains a separate AOT backend decision.
It may remove interpreter dispatch entirely, but is not required to obtain the
predecode, validation, and SIMD gains selected here.

## Consequences

Optimized kernels and bindings require more persistent plan metadata and more
workspace than the point-major reference backend. The workspace increase is
explicit in the exact query and buys contiguous lane storage without evaluation
allocation.

Structured operations do not yet vectorize their divergent eigensolver and
spectral-derivative control flow. Their scalar-per-lane execution is deliberate
and measured honestly; replacing it requires the same status, residual, and
reproducibility contracts.

On Apple M4 with Zig 0.16.0 in ReleaseSafe, seven samples of at least 50 ms
showed representative 1024-point value batches improving from about 33 to
12 ns/point for phi4 and from 137 to 42 ns/point for the two-coordinate tree
model. One-loop value batches improved from about 44 to 29 ns/point for 1x1,
244 to 146 ns/point for 2x2, and 459 to 435 ns/point for dense 3x3. A scalar
1x1 value call regressed from about 56 to 64 ns because it pays optimized-plan
setup without filling a vector block; callers retain explicit access to the
faster reference backend for that shape. Twelve caller-owned workers reached
about 1.8 and 5.4 ns/point on the two tree workloads, while 24-worker
oversubscription did not improve either result.

The 3x3 eigensolver leaf measured about 351 ns and dominates its end-to-end
workload. The small overall optimized-backend gain does not yet justify a
second comptime-fixed Jacobi implementation for dimensions three or four; the
general deterministic path remains authoritative until stronger evidence
supports that maintenance cost.

The backend and preferred block width are immutable metadata. Changing the
block layout or unsafe-leaf boundary requires renewed differential, fuzz,
generated-code, and performance evidence.

## Revisit when

Revisit the block width when supported target features change or measurements
show a different portable width wins. Revisit scalar-per-lane structured
operations when eigensystem or spectral work dominates representative batches.
Consider an automatic profile only after all supported workloads have stable
coverage and a failed optimized construction can still be reported without
silent fallback.
