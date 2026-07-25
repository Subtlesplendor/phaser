# Parallelism and Reentrancy

Status: initial specification

This document specifies Phaser's concurrency, scheduling, and reproducibility
contracts. It refines section 19 of [DESIGN.md](../../DESIGN.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations.

## 1. Scope

This specification covers:

- reentrant numerical evaluation;
- ownership of parallel scheduling;
- object-level concurrency;
- batch execution;
- future internal parallel backends;
- deterministic floating-point reductions;
- deterministic symbolic derivation;
- language-frontend behavior;
- parallel failure reporting; and
- concurrency-specific testing.

It does not require an initial thread pool, choose an executor implementation,
specify CPU affinity or NUMA policy, or define accelerator execution.

## 2. Initial execution model

The initial Phaser core is serial but reentrant.

Serial means that one core operation does not itself create worker threads or
dispatch work to a hidden executor. Reentrant means that independent calls may
execute concurrently when they obey the ownership rules in this specification.

Caller-owned scheduling is the initial primary parallelism strategy. C, C++,
Python, command-line workflows, and future higher-level tools may parallelize
over parameter points, temperatures, background points, or independent
calculations without requiring a Phaser-owned thread pool.

The initial serial backend is a complete supported backend. It MUST preserve the
same scalar, batch, status, and reproducibility semantics as a future internally
parallel backend.

## 3. Definitions

An operation is **reentrant** when concurrent invocations with valid independent
mutable storage do not interfere and do not depend on call ordering.

An object is **shareable** when concurrent read-only operations are supported
while the object remains alive.

An object is **exclusively mutable** when mutation requires that no other
operation reads or mutates it concurrently.

An implementation is **internally parallel** when one Phaser call schedules work
on more than one worker.

Batching is an API and data-layout property. It does not imply internal
parallelism.

## 4. Concurrency contract by object

The initial concurrency contract is:

| Object or storage | Concurrent use |
|---|---|
| Canonical model | Immutable and shareable |
| Calculation artifact | Immutable and shareable |
| Potential kernel | Immutable and shareable |
| Immutable diagnostic set | Shareable |
| Immutable binding | Shareable |
| Evaluation workspace | Exclusive to one active stream |
| Evaluation output | Exclusive unless explicitly partitioned |
| Read-only numerical input | Shareable while its bytes remain unchanged |
| Evaluation session | Exclusive unless explicitly partitioned |
| Context control-plane mutation | Not assumed concurrent |
| Optional cache | Only as concurrent as its declared implementation |

Every public object and operation MUST document any stronger or narrower
thread-safety contract.

Concurrent parameter or state points use separate immutable bindings.

All shared handles and their parent storage MUST remain alive until the final
concurrent operation completes. Exact handle-retention mechanics follow
[Memory Architecture](MEMORY_ARCHITECTURE.md).

## 5. Reentrant evaluation

A kernel and unchanged binding are reentrant when every active call has
independent mutable workspace and output:

```text
shared immutable kernel and binding
        |
        +-- stream 1: input 1 + output 1 + workspace 1
        +-- stream 2: input 2 + output 2 + workspace 2
        `-- stream 3: input 3 + output 3 + workspace 3
```

Evaluation MUST NOT:

- modify the kernel or binding;
- perform lazy initialization;
- allocate memory;
- create threads;
- use hidden thread-local scratch or sessions;
- update a hidden “last point” cache;
- depend on mutable global scientific or numerical state; or
- acquire a process-global allocator or cache lock.

Optional operational metrics inside evaluation must obey the bounded,
nonallocating rules of the memory specification and MUST NOT affect results.

## 6. Evaluation sessions

A frontend MAY provide an evaluation-session abstraction that owns:

- one kernel reference;
- one immutable binding reference;
- one workspace;
- reusable output storage; and
- frontend-only convenience state.

An ordinary session is exclusively mutable and is intended to belong to one
evaluation stream. Several sessions may share the same immutable kernel.

Evaluation sessions are operational objects. They are not serialized scientific
artifacts and do not contribute to model or calculation identity.

The exact Zig, C++, and Python session APIs are deferred.

## 7. Primary parallel dimensions

The preferred initial parallel dimensions, roughly from coarsest to finest, are:

1. independent calculations or models;
2. parameter points;
3. temperatures or other environmental states;
4. background points;
5. contributions within one evaluation;
6. matrix, contraction, and special-function operations; and
7. arithmetic within one operation.

Caller-owned parallelism SHOULD initially use coarse tasks such as parameter
points or temperatures. Coarse tasks reduce scheduling overhead and normally
require little shared mutable state.

Fine-grained internal parallelism MUST be justified by representative benchmarks
and must preserve the selected reproducibility policy.

## 8. Batch execution

A batch is an ordered collection of points. Output and per-point status at index
`i` correspond to input point `i`, independent of execution or completion order.

A backend may implement a batch through:

- a serial loop;
- vectorized instructions;
- blocked numerical operations;
- caller-scheduled independent scalar calls;
- an explicitly enabled internal worker executor; or
- a future accelerator.

These strategies MUST preserve public batch semantics.

Phaser MUST NOT delay unrelated scalar calls to manufacture hidden batches. An
adaptive minimizer can therefore issue unpredictable scalar calls without
interacting with hidden scheduling state.

## 9. Caller-owned scheduling

The initial library does not prescribe a caller threading system. A caller may
use native threads, a language runtime, processes, or another scheduler.

Phaser MUST NOT require a particular C or C++ threading library. The Python
binding MUST NOT impose a Python-specific thread pool.

The caller is responsible for:

- keeping shared objects alive;
- keeping each immutable binding alive;
- providing one mutable workspace and output region per active stream;
- avoiding forbidden buffer overlap; and
- coordinating any caller-owned cancellation.

Violating these ownership rules is a caller concurrency error. Debug or audit
builds SHOULD detect common misuse where doing so is bounded and race-free, but
the core cannot generally diagnose an arbitrary external data race.

## 10. Future internal parallelism

Internal parallel execution is a future explicit backend capability. It MUST NOT
be silently enabled based on detected CPU count.

An internally parallel backend must declare:

- supported worker-count range;
- workspace requirements per worker and in total;
- reproducibility policy;
- scheduling or executor requirements;
- nested-parallelism behavior;
- interaction with external numerical libraries; and
- whether worker count changes kernel layout or identity.

The caller explicitly selects a worker count greater than one. The backend MUST
use no more than the declared count.

Worker threads, executor queues, and per-worker resources MUST be established
outside numerical evaluation. Evaluation may dispatch to a pre-existing executor
only when dispatch itself satisfies the allocation, locking, and reproducibility
contracts.

Nested parallelism MUST NOT arise implicitly. A backend that calls a numerical
library with its own worker pool must control and report that library's threading
behavior.

Passing a caller-owned executor or callbacks through the C ABI is deferred until
a concrete consumer justifies the additional lifetime and reentrancy contract.

## 11. Execution configuration and identity

Worker count and scheduling placement are operational configuration when they do
not change:

- numerical operation order;
- generated code;
- storage layout;
- supported capabilities; or
- reproducibility policy.

In that case they do not change model, calculation, artifact, or kernel content
identity.

A fixed-capacity or specialized parallel backend MAY include worker capacity in
kernel identity when it changes generated code or layouts. A faster reduction
policy that changes possible numerical results MUST be explicit and recorded in
kernel identity and provenance.

## 12. Reproducible numerical execution

### 12.1 Output order

Parallel or batched execution MUST preserve declared output order. Diagnostic and
status collections MUST use stable input indices or canonical task keys rather
than completion order.

### 12.2 Reduction order

In reproducible mode, the arithmetic reduction graph for one result MUST be
defined independently of worker scheduling.

A suitable design is:

```text
canonically ordered contributions
              |
              v
fixed logical partition
              |
              v
fixed pairwise reduction tree
              |
              v
            result
```

Workers may evaluate independent nodes in any order, but scheduling MUST NOT
change which values are combined or the combination order.

On the same supported target, backend, compiler configuration, kernel, and
inputs, a backend claiming Phaser's reproducible policy MUST produce the same
successful output bits and statuses for every supported worker count. A backend
that cannot provide worker-count-independent reductions must expose a different,
explicitly selected reproducibility policy.

Universal cross-platform bitwise identity is not required. Cross-platform
agreement follows the numerical-comparison policy in
[Potential Kernel](POTENTIAL_KERNEL.md).

### 12.3 Faster policies

A future faster policy MAY permit worker-dependent or schedule-dependent
reductions. It must be:

- explicitly selected;
- recorded in kernel identity and result provenance;
- clearly distinguishable from reproducible execution;
- tested separately; and
- forbidden as a silent fallback.

## 13. Deterministic symbolic work

Parallel execution MUST NOT change canonical symbolic output, model
fingerprints, serialization, provenance, or diagnostic ordering.

Future parallel symbolic derivation SHOULD:

1. enumerate tasks in canonical order;
2. give each task or worker private bounded scratch storage;
3. produce task-local results;
4. merge results by stable structural keys; and
5. intern expressions and assign final local IDs in deterministic order.

Completion order, allocation address, hash-table iteration, and worker count MUST
NOT determine canonical IDs or serialization order.

Model validation, diagram generation, canonicalization, simplification, and
lowering are serial in the initial implementation. Their data structures should
not prevent a later deterministic task-local and merge-based implementation.

## 14. Caches

Evaluation MUST NOT require a mutable cache.

Concurrent control-plane cache misses MAY construct the same immutable result
more than once and retain one complete result. Avoiding duplicate work is an
optional later optimization.

A future single-flight mechanism must follow
[Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md). In particular,
it must be bounded, avoid dependency-cycle deadlocks, publish no partial object,
and propagate failure without poisoning future attempts.

Cache eviction or insertion order MUST NOT affect scientific results or
canonical artifacts.

## 15. Errors, statuses, and cancellation

Call-level contract errors SHOULD be detected before parallel work begins.

For batch evaluation:

- each point retains an independent status;
- one point's numerical failure MUST NOT corrupt another point;
- outputs remain associated with original input indices; and
- diagnostic aggregation is deterministic.

Internal invariant failures follow the production assertion policy and MUST NOT
be converted into successful or partially valid scientific results.

Fail-fast batch behavior, cooperative cancellation of internal work, and
partially completed output policy are deferred. Any such feature must be explicit
and define deterministic status and output validity.

## 16. Language frontends

### 16.1 C and C++

C and C++ callers may call a shared kernel concurrently when they preserve
binding, workspace, buffer, and lifetime rules. Phaser does not require them to
use a particular thread or task library.

The C++ convenience layer MAY provide a move-only evaluation session but MUST NOT
create a hidden global executor.

### 16.2 Python

The CPython extension SHOULD release the interpreter lock around sufficiently
substantial reentrant core calls when safe.

Python users may choose batches, several explicit sessions, threads, or
processes. The binding MUST NOT create a hidden Python thread pool or store
workspace in implicit thread-local state.

Free-threaded CPython support remains a separate packaging and validation
decision; the core ownership contract does not depend on the interpreter lock.

### 16.3 CLI

The initial CLI MAY schedule independent work at the application layer in the
future. It uses the same public ownership and reproducibility policies and MUST
NOT cause the library kernel to become implicitly threaded.

## 17. Observability and performance

When internal parallelism exists, operational metadata SHOULD expose:

- selected and effective worker counts;
- scheduling backend;
- task granularity or logical partition policy;
- per-worker workspace;
- reproducibility policy;
- nested-parallelism behavior; and
- relevant external-library threading configuration.

Instrumentation MUST NOT change scientific results or canonical ordering.

Parallel implementations require representative end-to-end benchmarks. They
must be compared against:

- serial scalar execution;
- serial batch execution;
- caller-parallel scalar execution; and
- caller-parallel batch execution where meaningful.

Benchmarks SHOULD include latency, throughput, scaling efficiency, allocation,
workspace bytes, and oversubscription behavior.

## 18. Validation, testing, and fuzzing

Architecture-wide schedule-injection and differential rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

Required tests include:

- concurrent scalar evaluation of one shared kernel and binding;
- independent bindings containing different parameter and state points;
- one workspace and output region per active stream;
- scalar and batch equivalence;
- stable output, status, and diagnostic ordering;
- randomized task completion order;
- one worker versus every supported larger worker count;
- bitwise worker-count independence under the reproducible policy;
- serial and parallel symbolic content-ID equivalence when symbolic parallelism
  is introduced;
- cache races and duplicate construction when a cache is later implemented;
- exact per-worker workspace boundaries;
- proof that evaluation performs no allocation or lazy initialization; and
- repeated lifecycle stress under concurrency sanitizers where supported.

Structured fuzzing SHOULD generate public sequences of bind, evaluate, share,
release, and create-another-binding operations. Tests MUST avoid introducing data races in the test
harness when checking valid behavior; separately designed misuse tests may
exercise detectable contract violations.

## 19. Deferred decisions

This specification deliberately leaves open:

- exact evaluation-session APIs;
- the first internally parallel backend;
- executor ownership and implementation;
- logical partition sizes and reduction-tree representation;
- control-plane context and cache synchronization;
- caller-executor support through the C ABI;
- fail-fast and cancellation behavior;
- CPU affinity and NUMA policy;
- accelerator execution; and
- free-threaded CPython packaging.
