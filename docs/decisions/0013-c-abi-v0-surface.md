# Decision 0013: C ABI version 0 surface

Status: accepted for Milestone 4

## Context

[Language and Interoperability §5.1](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#51-scope)
deferred exact function signatures "until the corresponding core lifecycles have
executable prototypes." Milestone 3 produced them. The lifecycle a client needs
to drive is now fixed and exercised end to end by `src/cli/` and the committed
examples:

```text
Context -> loadModel -> parseRequest -> deriveEffectivePotential
        -> compileKernel -> parseParameterPoint -> bindParameters
        -> workspaceLayout -> evaluate / evaluateComplex
```

What remains undecided is not the physics but the boundary: which objects cross
as handles, who owns them, how a failure that has a structured diagnostic is
distinguished from one that does not, and how a per-point numerical outcome
crosses without being flattened into a call-level error code. That last question
is the sharp one. Milestone 3 spent
[Decision 0007](0007-milestone-3-oracle.md) through
[Decision 0009](0009-scalar-spectral-derivatives.md) establishing that a
negative scalar mass-squared eigenvalue is a *successful complex result*, that a
zero mode is a successful exact zero, and that `nonconvergent` and
`singular_derivative`
are distinct from both and from each other. An ABI that returns "evaluation
failed" for any of these would discard the milestone's central distinction at
the moment it becomes visible to users.

## Decision

### Handles

ABI version 0 exposes eight opaque handle types:

```c
typedef struct phaser_context     phaser_context;
typedef struct phaser_model       phaser_model;
typedef struct phaser_request     phaser_request;
typedef struct phaser_artifact    phaser_artifact;
typedef struct phaser_kernel      phaser_kernel;
typedef struct phaser_point       phaser_point;
typedef struct phaser_binding     phaser_binding;
typedef struct phaser_diagnostics phaser_diagnostics;
```

This revises the conceptual list in
[§5.3](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#53-opaque-objects),
which was written before the core existed. `phaser_plan` is dropped: no such
object was built. Its role is split between `phaser_request`, the parsed
calculation request, and `phaser_artifact`, the derived potential. Both are
real, separately addressable, and separately inspectable, and a client that
wants to derive two artifacts from one request needs them apart. `phaser_point`
and `phaser_request` are added for the same reason — they are handles in the
core and pretending otherwise would force clients to re-parse JSON per binding.

Ownership is unique and non-shared. Every handle has exactly one owner, no
handle is retained or released, and each has one explicit destructor. A handle
derived from another does not extend its parent's lifetime; the specification
states the required outlives-relationship for each pair, and destroying a parent
before its derived handles is a client error, not a supported ordering. Nothing
in version 0 is reference-counted, because nothing in the core is, and adding
retain/release later is a smaller change than removing it.

Every handle argument documents its nullability. A null handle where one is
required is `PHASER_STATUS_INVALID_ARGUMENT`, never a crash and never a trap.

### Two status spaces, never merged

The ABI has two status types, and no operation converts between them.

`phaser_status` is the control-plane code returned by operations that can fail
structurally:

```text
PHASER_STATUS_OK
PHASER_STATUS_INVALID_ARGUMENT   null handle, bad length, misaligned buffer
PHASER_STATUS_INVALID_SOURCE     parse or validation failed; has diagnostics
PHASER_STATUS_UNSUPPORTED        outside the supported domain, stated explicitly
PHASER_STATUS_LIMIT_EXCEEDED     a declared resource limit was reached
PHASER_STATUS_INSUFFICIENT_SPACE a caller buffer or workspace is too small
PHASER_STATUS_OUT_OF_MEMORY      the context's allocator refused
PHASER_STATUS_INTERNAL           contained invariant failure
```

`phaser_point_status` is the per-point numerical outcome, and it mirrors
`src/kernel/program.zig`'s `Status` exactly, value for value:

```text
PHASER_POINT_OK
PHASER_POINT_NON_FINITE
PHASER_POINT_DIVISION_BY_ZERO
PHASER_POINT_NONCONVERGENT
PHASER_POINT_SINGULAR_DERIVATIVE
```

Per-point statuses are written into a caller-provided array, one entry per
point, exactly as the Zig kernel writes them. `phaser_evaluate` returns
`PHASER_STATUS_OK` when the call itself was well formed, whatever the individual
points reported. A batch in which every point is `PHASER_POINT_NON_FINITE` is a
successful call; the client reads the point array to learn that. The reverse
also holds: a control-plane failure publishes no point statuses at all, so a
client can never mistake an unwritten array for a batch of successes, and the
evaluation entry points require the status array's length to equal the point
count so there is no partial-write ambiguity.

Adding a status value to either space is a breaking ABI change while the version
is experimental, and is recorded as such. A client is nonetheless required to
treat an unrecognized value as a failure of its kind rather than as success.

The two spaces are never merged because they answer different questions. "Your
buffer was too small" and "this point's Hessian is genuinely singular at a zero
mode" are not the same event, and only the second is a scientific result.

### Diagnostics

`PHASER_STATUS_INVALID_SOURCE` is the only status that promises a diagnostics
handle. Operations that can produce one take a `phaser_diagnostics **` out
parameter; on any other status they write null to it. The handle is immutable
once produced, owned by the caller, and destroyed by the caller. It does not
borrow from the model or source buffer it describes, so the client may free the
source text immediately.

There is no "last error" state, global or thread-local, as
[§5.7](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#57-errors-and-diagnostics)
requires. Diagnostics are inspected through typed queries — count, and
per-index code, category, severity, span, and message — rather than by parsing
a rendered string. A rendering operation is also provided, because the C client
and the CLI both want one, but it is a convenience over the typed queries and
not the only access path.

Byte views returned from a diagnostics handle are valid until that handle is
destroyed and are not separately freed.

### Buffers and hot paths

Hot evaluation allocates nothing and formats no strings, per
[§5.7](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#57-errors-and-diagnostics).
The caller supplies background inputs, outputs, per-point statuses, and
workspace as typed contiguous buffers with explicit element counts. Workspace
size and alignment are queried before evaluation through the existing exact
layout query, which already returns a byte count rather than an estimate; the
ABI passes it through unchanged rather than rounding it up.

Real and complex results use separate entry points, matching
`evaluate`/`evaluateComplex`, rather than one entry point with a mode flag. The
result type is a property of the compiled kernel and is queryable; a client that
calls the real entry point on a complex-result kernel gets
`PHASER_STATUS_INVALID_ARGUMENT` rather than a silently projected real part.
This is the same substitution
[Milestone 3's conformance cases](../architecture/IMPLEMENTATION_ROADMAP.md#7-milestone-3-zero-temperature-one-loop-scalar-potential)
were written to detect internally, and it must not become reachable at the
boundary.

Complex values cross as a pair of `double` fields in an explicit struct, not as
C99 `_Complex`. `_Complex` is optional in C11, absent from C++, and its layout
guarantee is not worth the portability cost for two doubles.

Insufficient capacity is `PHASER_STATUS_INSUFFICIENT_SPACE`, reported before any
output is written, and is an ordinary result rather than an error to be avoided
by over-allocating.

### Versioning

`phaser_abi_version()` returns 0 and a separate `phaser_library_version()`
returns the library version, per
[§5.2](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#52-header-compatibility).
A capability query reports which result types and derivative capabilities the
build supports, so a client can refuse a kernel it cannot consume without
parsing metadata JSON.

Version 0 is experimental and says so in the header, in the version query's
documentation, and in release notes. The conditions for declaring version 1 are
[§5.10](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#510-abi-maturity)'s and
are not weakened here.

## Alternatives

**One merged status space.** Simpler for clients that only check "did it work",
and it is what most numerical C libraries do. Rejected because it destroys the
distinction Milestone 3 exists to establish: a negative eigenvalue would become
indistinguishable from a bad buffer, and the physics would be reported through
the same channel as a programming mistake.

**An error-callback or `errno`-style handle.** Rejected by
[§5.7](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#57-errors-and-diagnostics)'s
prohibition on mutable "last error" state, which is also unusable from the
threading contract the same specification requires.

**Returning diagnostics for every failing status.** Rejected as a false promise:
an invalid pointer has no source span to report, and allocating a diagnostics
object on an out-of-memory path is the wrong response. Restricting the promise
to `PHASER_STATUS_INVALID_SOURCE` makes the out parameter's contract checkable.

**Reference-counted handles.** Rejected for version 0. Shared ownership is easy
to add and impossible to remove, and no current consumer needs it.

**A single evaluation entry point with a result-type flag.** Rejected because
the flag would be the one place a real projection of a complex result could be
requested by accident, and the type is already known from the kernel.

## Consequences

The ABI has more handle types than the original sketch and more status values
than a minimal binding would need. Both costs are deliberate: the handles match
objects that actually exist, and the statuses match distinctions the core
already makes.

Client code must read a per-point status array to interpret a batch. This is
more work than checking one return code, and it is the only form that does not
lie about a batch in which some points are non-finite.

Because the status spaces mirror internal enums value for value, a change to
`kernel.Status` is an ABI change. A conformance test asserts the two agree, so
the coupling fails loudly at build time rather than silently at a user's
boundary.

The specification must now carry operation-level signatures for this surface
before implementation begins. Nothing here fixes function *names*; the
specification does.

## Revisit when

Revisit if a real client needs shared handle ownership, if a second scheme or a
result type outside `double` and its complex pair enters the kernel, if the
per-point status array becomes a measured bottleneck at large batch sizes, or if
Phase B's Python extension finds a lifecycle it cannot express without borrowing
a parent handle's lifetime. Revisit the merged-status rejection only with
evidence that clients are misreading the two-space form — not merely that it
is more verbose.
