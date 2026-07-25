# Memory Architecture

Status: initial specification

This document specifies memory ownership, allocation phases, capacity behavior,
and failure semantics for Phaser. It refines section 18 of
[DESIGN.md](../../DESIGN.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations.

## 1. Scope

This specification covers:

- control-plane allocation;
- allocator-backed control-plane operation;
- persistent object ownership;
- temporary transformation storage;
- parameter and state binding;
- numerical evaluation workspace;
- caller-owned numerical buffers;
- capacity diagnostics;
- concurrency; and
- memory-specific testing.

It does not select exact Zig type names, C ABI function signatures, allocator
implementations, default capacity values, or cache eviction algorithms.

## 2. Memory classes

Phaser distinguishes three properties that MUST NOT be conflated:

1. **Static storage** has a size fixed when Phaser or an application is compiled.
2. **Bounded allocation** obtains storage at runtime but cannot exceed an explicit
   budget or supplied region.
3. **Allocation-free execution** performs no allocation during a specified
   operation.

Phaser does not require exclusively static storage. Runtime models have
user-selected field content and may produce widely different expression,
diagram, and workspace sizes. A single compiled-in maximum would either waste
memory or impose an unrelated scientific limit.

The core MUST support bounded allocation. Numerical kernel evaluation MUST be
allocation-free.

## 3. Governing principles

- Every core allocation belongs to an explicit owner and lifetime.
- Every externally influenced resource has an explicit bound.
- Scientific subsystems MUST NOT directly use an implicit process-global or
  operating-system allocator.
- No hidden global or thread-local allocator, cache, or workspace may be required.
- Published scientific objects are complete and logically immutable.
- Temporary memory MUST NOT escape its operation.
- Allocation or capacity failure is an ordinary diagnostic, not an assertion.
- Failure MUST NOT publish or cache partial objects.
- Exact evaluation workspace requirements are queried before execution.
- Heapless or caller-provided fixed-buffer construction is deferred until a
  concrete consumer establishes its value and API requirements.

## 4. Allocation modes

### 4.1 Allocator-backed operation

The ordinary Zig core interface SHOULD accept an explicit allocator and resource
limits when creating its root context. All later control-plane allocation is
routed through that context or an object-owned allocator derived from it.

The CLI, Python binding, and ordinary C convenience API MAY provide a default
host allocator. Allocation is still governed by explicit context limits and
occurs only in documented control-plane lifecycle operations.

### 4.2 Future fixed-buffer operation

Version 0.1 does not require construction from one caller-provided fixed byte
region. Such support adds physical-region layout, independent reclamation,
alignment, fragmentation, and capacity-diagnostic obligations that are not
needed by the initial allocator-backed consumers.

A future fixed-buffer mode MUST preserve the same scientific semantics and
ordinary capacity-failure behavior, but its exact contract is deferred until a
concrete embedded, sandboxed, or externally managed-memory consumer exists.

### 4.3 Custom C allocators

Custom allocator callbacks are not required in the initial C ABI. They introduce
callback lifetime, reentrancy, thread-safety, and failure-reporting obligations
that should be accepted only for a concrete consumer.

Internal allocator injection MUST nevertheless exist from the start so that
failure injection and memory accounting use the same core paths as ordinary
allocation.

## 5. Ownership domains

The intended ownership domains are:

| Domain | Primary owner | Allocation policy | Lifetime |
|---|---|---|---|
| Source input | Caller or parsing operation | Externally supplied | At least through parsing |
| Parsing scratch | Parsing operation | Bounded resettable arena | One parse |
| Canonical model | Model object | Persistent object region | Until model release |
| Derivation scratch | Derivation operation | Bounded resettable arena | One derivation |
| Calculation artifact | Artifact object | Persistent object region | Until artifact release |
| Kernel program and metadata | Kernel object | Persistent object region | Until kernel release |
| Bound numerical state | Immutable binding object | Allocator-backed construction | One parameter or environment context |
| Evaluation workspace | Caller or evaluation stream | Supplied before execution | Reusable across calls |
| Numerical inputs and outputs | Caller | Caller-managed | At least one call |

These are semantic ownership domains. An implementation MAY combine physical
allocations when doing so preserves independent lifetimes, capacity accounting,
and failure isolation.

## 6. Context

The context is the root of control-plane allocation policy. It SHOULD contain or
reference:

- allocator mode;
- total memory budget;
- phase- or resource-specific limits;
- diagnostic policy;
- allocation-failure instrumentation; and
- optional memory statistics.

Context configuration is not scientific model content. A capacity configuration
MAY affect kernel identity only when it changes generated code, storage layouts,
or supported capabilities, as specified by
[Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md).

The public lifetime contract MUST prevent a model, artifact, kernel, binding, or
diagnostic object from accessing destroyed context state. An implementation may
enforce this through ownership, retained context state, or destruction rules.
The exact handle mechanism is deferred.

## 7. Persistent objects

Canonical models, calculation artifacts, and kernels are logically immutable
after publication.

Each independently releasable persistent object SHOULD have an independently
reclaimable ownership region. A single context-lifetime arena MUST NOT be the
only ownership strategy if it prevents ordinary applications from releasing
large models, artifacts, or kernels before destroying the context.

A child object may share immutable storage with a parent only when it keeps the
parent storage alive. The conceptual dependency graph is acyclic:

```text
model <- artifact <- kernel
```

An implementation MAY instead copy the minimal required parent data. In either
case:

- a canonical model MUST NOT borrow unowned source JSON bytes;
- an artifact MUST NOT reference derivation scratch after publication;
- a kernel MUST NOT reference lowering scratch after publication;
- a released object MUST NOT leave a surviving child with dangling storage; and
- ownership bookkeeping MUST remain outside numerical hot loops.

Opaque C handles, C++ RAII objects, and Python objects adapt these same ownership
semantics. They MUST NOT define competing lifetimes.

## 8. Source storage

Parsing MAY borrow source bytes for the duration of the parse. Any source text,
identifier, string value, or source excerpt required after parsing MUST be copied
into owned storage or retained through an explicit source owner.

Source spans MAY be preserved without retaining the complete source document if
diagnostics can still state the relevant location. The exact source-retention
policy is deferred.

Canonical scientific identity MUST NOT depend on the address, allocation layout,
or lifetime of source bytes.

## 9. Temporary arenas

Parsing, validation, canonicalization, derivation, simplification, and lowering
MAY use resettable scratch arenas.

Scratch storage:

- is owned by one operation or worker;
- has an explicit byte and object budget;
- is reset or discarded as a unit;
- MUST NOT be referenced by a published object;
- MUST NOT be shared concurrently unless designed and tested for that use; and
- SHOULD support cheap marks or subsidiary regions when transactional rollback
  benefits an operation.

Large user-dependent values MUST NOT be placed on the call stack merely to avoid
arena allocation. Stack storage is reserved for small statically bounded values.
Code MUST NOT recurse over user-controlled structures.

## 10. Transactional construction

Construction of a persistent object follows this observable transition:

```text
existing valid state
        |
        v
temporary bounded construction
        |
        +-- success --> publish one complete immutable object
        |
        `-- failure --> discard temporary state
```

On failure:

- no partial object is returned;
- existing published objects remain valid;
- existing immutable bindings remain valid; and
- temporary allocations can be reclaimed as a unit.

Construction routines SHOULD establish all fallible capacity requirements before
mutating durable state where practical.

## 11. Binding storage

A binding owns dense numerical storage associated with one kernel input layout.
Binding is control-plane construction and MAY allocate outside evaluation.

Creating a binding for:

- model parameters;
- renormalization scale;
- temperature;
- gauge parameters; and
- other declared dynamic state

MAY allocate. It MUST NOT repeat model validation, physics derivation, or kernel
lowering.

A parameter-point change initially creates a new immutable binding. This avoids
rollback, double-buffering, and concurrent-mutation contracts in the first
implementation. A future measured optimization MAY add mutable in-place
rebinding behind an explicit exclusive API. Such an operation must preserve a
valid old state on failure.

## 12. Evaluation workspace

The workspace contract is shared with
[Evaluation Lifecycle](EVALUATION_LIFECYCLE.md) and
[Potential Kernel](POTENTIAL_KERNEL.md).

Before execution, a kernel MUST provide an exact workspace layout for the:

- requested operation or fused capability;
- point count or backend capacity;
- worker count;
- scalar type;
- backend; and
- relevant output layout.

The public requirement includes at least byte size and alignment. Internal
subregions MAY remain private.

Kernel execution MUST:

- allocate no memory;
- validate size and alignment before unsafe access;
- use only the provided workspace and documented immutable state;
- avoid hidden thread-local scratch; and
- report insufficient workspace as a call-level error.

One mutable workspace belongs to at most one active evaluation stream unless its
implementation explicitly supports concurrent partitioning. Concurrent
evaluations normally share an immutable kernel and binding while using distinct
workspaces.

A high-level frontend MAY own reusable workspace objects, grow them before a
call, and retain separate scalar and batch capacities. It MUST NOT delay scalar
calls to create hidden batches.

## 13. Inputs, outputs, and aliasing

Numerical input and output buffers are caller-owned. Phaser borrows them only for
the duration of the call unless an API explicitly states otherwise.

Every operation MUST define:

- element type;
- shape and layout;
- required alignment;
- minimum capacity;
- mutability;
- permitted aliasing; and
- output validity on call-level and point-level failure.

Inputs, outputs, and workspace are non-overlapping by default. Any permitted
in-place operation must be explicit and tested. Buffer validation MUST use
overflow-checked range and size arithmetic.

Call-level preflight errors SHOULD be detected before outputs or workspace are
modified. Point-level failures follow the status and output policies of the
kernel specification.

## 14. Bounds and accounting

Every resource influenced by external input is bounded. This includes:

- source bytes and token count;
- parser nesting and expression depth;
- fields, parameters, and tensor components;
- expression and IR nodes;
- diagrams, contractions, rewrites, and rewrite iterations;
- persistent and scratch bytes;
- batch points, workers, and workspace bytes; and
- numerical iterations and explicit worklist depth.

Control-plane arenas MAY grow within their budgets. They need not know the exact
final allocation before an operation begins.

Capacity accounting MUST:

- use checked arithmetic;
- include required alignment and allocator overhead according to a documented
  policy;
- never intentionally exceed a hard budget;
- remain valid when a requested size is zero or near the integer limit; and
- distinguish required calculation memory from optional cache admission.

The shared checked-arithmetic and transactional-budget primitives are specified
in [Foundation Types and Failure Reporting](FOUNDATION.md).

Default limits and named capacity profiles remain to be chosen. Defaults are
ergonomic policy, not scientific constants.

Milestone 1 selects a standard model-loading profile with 32 MiB of scratch
storage and 64 MiB of persistent storage. Its tested hard ceilings are 256 MiB
and 512 MiB respectively. Model loading is transactional: temporary parse and
normalization state is discarded on failure, and a successful immutable model
owns independently reclaimable storage. A model retains copied identifiers,
presentation strings, exact values, and source spans, but does not borrow the
caller's JSON buffer.

## 15. Capacity diagnostics

A capacity failure SHOULD identify, where available:

- operation phase;
- resource category;
- configured limit;
- current usage;
- requested increment or required total;
- allocator and context mode; and
- the configuration field that controls the limit.

Diagnostics MUST NOT silently retry with a less accurate calculation, discard
terms, lower perturbative order, reduce derivatives, or otherwise change
scientific semantics.

Allocation failure and model invalidity are distinct diagnostics.

## 16. Future cache memory

Version 0.1 uses explicit retained objects and does not require a general cache.
Any future cache follows
[Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md),
uses a separate budget, publishes only complete objects, and never changes
scientific results on a hit, miss, refusal, or eviction.

## 17. Concurrency

Scheduling and reentrancy follow
[Parallelism and Reentrancy](PARALLELISM.md).

Canonical models, artifacts, kernels, and logically immutable bindings MAY be
shared between threads.

Mutable scratch arenas, workspaces, and bindings require exclusive access unless
they are explicitly partitioned or synchronized. The ordinary pattern is:

```text
shared immutable kernel and binding
        |
        +-- worker 1: workspace 1
        +-- worker 2: workspace 2
        `-- worker 3: workspace 3
```

A binding shared by active evaluations MUST NOT be rebound until those
evaluations have completed. A frontend MAY instead create independent bindings
for concurrent parameter or state points.

Allocator and reference-lifetime operations MAY synchronize outside evaluation.
Numerical evaluation MUST NOT acquire a hidden global allocator or cache lock.

## 18. Observability

When enabled, a context or operation SHOULD be able to report:

- current and peak persistent bytes;
- current and peak scratch bytes;
- allocation count;
- backing-allocation or arena-growth count;
- workspace requirements;
- configured limits; and
- capacity failures by resource category.

Instrumentation MUST be bounded. It MUST NOT allocate or format messages inside
numerical evaluation.

Memory statistics are operational metadata. They do not enter scientific content
identity unless a capacity setting changes the generated kernel or its supported
capabilities.

## 19. Validation, testing, and fuzzing

Architecture-wide fault-injection and regression rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

Required version 0.1 memory tests include:

- exact-capacity success;
- representative insufficient-capacity failure, including exact one-unit
  boundaries for foundational size and workspace calculations;
- zero-sized inputs and workspaces;
- large size and alignment arithmetic near integer limits;
- representative injected failures at subsystem ownership and publication
  boundaries, plus exhaustive failure testing for foundational transactional
  containers where practical;
- source-buffer release after successful parsing;
- persistent-object release in every valid ownership order;
- repeated independent binding construction and failed-binding sequences;
- workspace reuse across many scalar and batch calls;
- overlapping and misaligned buffer rejection;
- concurrent evaluation with independent workspaces;
- proof by instrumentation that kernel evaluation performs no allocation.

Debug, audit, and fuzz configurations SHOULD poison reset scratch memory and MAY
use canaries or guarded regions to detect escaped references and buffer overruns.

Structured fuzzing SHOULD vary capacity limits independently of model contents so
that both scientific validation and resource-failure paths are exercised.

## 20. Deferred decisions

This specification deliberately leaves open:

- exact Zig allocator and arena types;
- default capacity values and named profiles;
- physical region or slab layout for persistent objects;
- context and handle retention mechanics;
- source-document retention policy;
- the first concrete consumer and API for fixed-buffer or heapless operation;
- whether custom C allocator callbacks are ever needed;
- precise accounting of allocator metadata against budgets; and
- frontend workspace-pool policies.
