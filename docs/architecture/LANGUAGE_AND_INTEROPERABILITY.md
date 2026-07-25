# Language and Interoperability

Status: initial specification

This document specifies Phaser's implementation language and its supported
language boundaries. It defines the intended architecture, ownership rules, and
compatibility responsibilities. Exact function signatures, package names, and
the initial platform support matrix remain to be designed.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations.

## 1. Goals

The interoperability design must:

- keep one implementation of the physics and numerical behavior;
- provide a stable language-neutral embedding boundary;
- support allocation-free scalar and batch evaluation;
- make ownership, diagnostics, and thread safety explicit;
- permit natural C, C++, and Python clients;
- provide one language-independent command-line interface; and
- avoid exposing compiler-specific Zig or C++ representations.

Interoperability adapters MUST NOT independently implement scientific formulae,
canonicalization, lowering, or numerical kernels.

## 2. Implementation language

Zig is the sole primary implementation language for the Phaser core.

The repository MUST pin an exact supported Zig toolchain version. A toolchain
upgrade is a deliberate repository change and MUST pass the complete test,
conformance, fuzz-regression, and benchmark suites applicable at that time.

Compile-time metaprogramming and future model-specific builds follow
[Zig `comptime` and Model-Specific AOT Compilation](COMPTIME_AND_AOT.md).

Phaser's internal Zig APIs MAY evolve with the implementation and the pinned
toolchain. Neither internal Zig declarations nor Zig data layouts constitute a
stable binary interface.

Zig is used for:

- model parsing and validation;
- internal representations and transformations;
- scientific calculations;
- numerical lowering and kernel evaluation;
- the C ABI implementation;
- native CPython extension glue; and
- the Phaser command-line executable.

The initial architecture does not define a native plugin ABI.

## 3. Interoperability layers

The intended boundaries are:

```text
                                  +------------------+
                                  |   Phaser CLI     |
                                  |      (Zig)       |
                                  +---------+--------+
                                            |
                                            v
+----------+      +--------------+    +-----+----------+
| C client +----->|              |    |                |
+----------+      |              |    |    Zig core    |
                  | versioned    +--->|                |
+----------+      | C ABI        |    +----------------+
| C++ API  +----->|              |
+----------+      |              |
                  |              |
+----------+      +------+-------+
| CPython  +-------------+
| extension|
+----------+
```

The C ABI is the normative cross-language contract. Python adapts it in the
initial public-surface milestone. The C++ convenience layer is added in the
separate C++ and Wolfram Language interoperability milestone. The CLI MAY call
the Zig core directly because it is built and versioned together with the core.

An adapter MAY share private Zig implementation helpers with the C ABI, but its
observable lifecycle, validation, errors, and numerical results MUST agree with
the C ABI.

## 4. Distributed components

A native Phaser distribution is expected eventually to contain:

```text
include/phaser.h
lib/libphaser.a
lib/libphaser.so, libphaser.dylib, or phaser.dll
bin/phaser
```

The build MAY provide static libraries, shared libraries, or both. The same
public header and behavioral contract apply to both linkage modes.

The repository owns the authoritative `include/phaser.h`. A generated header MAY
be used only if its generator is deterministic, its output is checked in or
otherwise available to consumers, and CI verifies the generated and authoritative
forms agree.

## 5. C ABI

### 5.1 Scope

The C ABI is both:

- the native public library API for C callers; and
- the stable implementation boundary for other language adapters.

It SHOULD cover:

- context creation and destruction;
- source-model parsing and diagnostics;
- calculation planning and derivation;
- model, artifact, and kernel inspection;
- parameter and state binding;
- workspace-size queries;
- scalar, fused-output, and batch evaluation; and
- version and capability queries.

Exact function signatures are deferred until the corresponding core lifecycles
have executable prototypes.

### 5.2 Header compatibility

`phaser.h` MUST be a valid standalone C header for the selected minimum C
language version. It MUST also be directly includable by C++ and use `extern "C"`
guards when compiled as C++.

The public header MUST:

- include or define everything needed to interpret its declarations;
- avoid compiler extensions unless isolated behind portable feature checks;
- use a common export/import macro for symbol visibility; and
- expose the ABI version and library version separately.

The initial minimum C and C++ language versions remain to be selected.

### 5.3 Opaque objects

Long-lived core objects MUST cross the ABI as opaque handle types, conceptually:

```c
typedef struct phaser_context phaser_context;
typedef struct phaser_model phaser_model;
typedef struct phaser_plan phaser_plan;
typedef struct phaser_artifact phaser_artifact;
typedef struct phaser_kernel phaser_kernel;
typedef struct phaser_binding phaser_binding;
typedef struct phaser_diagnostics phaser_diagnostics;
```

Their representations are private. A client MUST NOT allocate, copy, inspect, or
free an opaque object except through its documented Phaser operations.

Every handle type MUST have an explicit ownership model. If handles can share
ownership, retain and release behavior MUST be explicit. Otherwise ownership
transfer and destruction MUST be explicit. Nullability MUST be documented for
every handle argument.

### 5.4 C-compatible values

The ABI MUST NOT expose:

- Zig slices, optionals, error unions, tagged unions, allocators, or internal IDs;
- C++ classes, templates, exceptions, standard-library containers, or references;
- compiler-dependent bit fields;
- untagged unions whose active member cannot be validated; or
- internal pointer ownership.

Public integer fields SHOULD use fixed-width integer types. Public floating-point
buffers initially contain C `double` values corresponding to the complete
production `f64` kernel.

Strings and serialized documents SHOULD cross as an explicit pointer and byte
length. Their encoding and whether embedded null bytes are permitted MUST be
specified for each operation. Human-readable Phaser documents use UTF-8.

Hot numerical arrays SHOULD cross as typed contiguous buffers with explicit
element counts and documented layouts. Strided or device-resident views are
future capabilities and MUST NOT complicate the initial ABI without a concrete
consumer.

### 5.5 Extensible structures

When a public structure is needed, it SHOULD begin with fields equivalent to:

```c
uint32_t struct_size;
uint32_t abi_version;
```

Newer callers initialize `struct_size`; implementations read only fields present
in that size. Reserved fields MUST be zero and MUST NOT be repurposed without the
documented versioning rule.

Structures SHOULD be passed through pointers rather than frequently returned or
passed by value. ABI tests MUST verify size, alignment, field offsets, and
constant values for every supported target.

### 5.6 Context and allocation

An explicit, bounded `phaser_context` owns control-plane allocation policy and
resource limits. A future cache, if introduced, is explicitly owned rather than
process-global. Core operations MUST NOT require mutable process-global state or
a global default context.

The complete allocation and ownership contract is specified in
[Memory Architecture](MEMORY_ARCHITECTURE.md).

Kernel evaluation follows
[Evaluation Lifecycle](EVALUATION_LIFECYCLE.md) and
[Potential Kernel](POTENTIAL_KERNEL.md):

- evaluation does not allocate;
- the caller provides input, output, and scratch buffers;
- required sizes can be queried before evaluation; and
- insufficient capacity is an ordinary reported failure.

An application MAY allocate those buffers by any method appropriate to C or C++.
Phaser does not require callers to use a Phaser allocator for ordinary numerical
arrays.

### 5.7 Errors and diagnostics

No Zig panic, trap caused by unvalidated client input, or language-level error
representation may cross the C boundary.

Control-plane operations SHOULD return a small stable status code and, when
needed, produce an immutable diagnostics handle containing structured,
inspectable messages. Diagnostics MUST NOT rely on mutable global or thread-local
“last error” state.

Hot evaluation calls SHOULD report statuses in caller-provided scalar or batch
outputs without allocating or formatting diagnostic strings. The status contract
must distinguish at least:

- success;
- invalid caller buffers or layouts;
- insufficient workspace;
- domain or branch-policy failures;
- non-finite results where prohibited; and
- internal invariant failure containment, where recovery is possible.

The process policy for a genuine internal invariant violation remains governed
by [Phaser Engineering Style](../../ENGINEERING_STYLE.md); the ABI must never
disguise such a violation as a valid scientific result.

### 5.8 Metadata and serialization

Human-readable, non-hot metadata MAY be returned as canonical JSON or another
versioned Phaser document. Essential inspection and hot-path information SHOULD
also have typed queries so that consumers need not parse JSON merely to size a
buffer or execute a kernel.

Returned byte views MUST have a documented lifetime. If the caller owns a copy,
the deallocation operation and allocator ownership MUST be unambiguous.

### 5.9 Thread safety

Scheduling and reentrancy follow
[Parallelism and Reentrancy](PARALLELISM.md).

Every public handle type and operation MUST document whether it is:

- immutable and safely shareable;
- mutable and externally synchronized;
- confined to one thread; or
- reentrant only with independent workspace.

No hidden mutable global state may affect evaluation. Separate contexts and
independent workspaces MUST be usable concurrently unless an explicitly
documented platform limitation prevents it.

### 5.10 ABI maturity

The ABI begins as experimental version `0`. Breaking changes are permitted while
the version is experimental, but they must be visible in release notes and
version queries.

ABI version `1` SHOULD be declared only after:

- at least one real C client exists;
- the Python binding exercises metadata and numerical buffers;
- conformance tests run against static and shared builds; and
- supported-platform packaging has been demonstrated.

ABI compatibility applies only within a documented major ABI version and support
matrix.

## 6. C clients

The C ABI itself is Phaser's C library interface; there is no second C-specific
implementation.

Phaser SHOULD provide small C examples that demonstrate:

- parsing a model;
- handling structured diagnostics;
- compiling or loading a potential kernel;
- querying and allocating workspace; and
- scalar and batch evaluation.

These examples are conformance consumers, not alternate scientific
implementations.

## 7. C++ clients

All supported C++ compilers MUST be able to consume `phaser.h` directly within
the documented platform matrix.

In the dedicated C++ and Wolfram Language interoperability milestone, Phaser
SHOULD additionally provide a thin, primarily header-only `phaser.hpp`.
This is a source-level convenience API, not a C++ binary ABI. It MAY provide:

- namespace-scoped types;
- RAII ownership of opaque handles;
- move-only model, artifact, and kernel objects;
- standard string and contiguous-array views;
- typed status and diagnostic access; and
- explicit exception-free and, optionally, throwing convenience operations.

The wrapper MUST contain no scientific or numerical implementation. Its lifetime
and error behavior MUST be testable against equivalent direct C calls.

The C++ language-version baseline, exception policy, and optional adapters for
libraries such as Eigen are deferred. An Eigen adapter, if ever accepted, MUST
not make Eigen part of the C ABI or the mandatory core dependency set.

Phaser MUST NOT publish a native C++ ABI for core objects.

## 8. Python

Python is the first planned high-level researcher-facing language.

The production binding SHOULD be a thin CPython extension written in Zig against
Python's Limited API. The initial planned minimum is CPython 3.11 because the
complete `Py_buffer` structure and the relevant buffer operations are part of the
Stable ABI from that version.

The extension SHOULD:

- mirror the core model, plan, artifact, binding, and kernel lifecycle at a
  suitably high level;
- translate structured diagnostics into appropriate Python exceptions and
  inspectable diagnostic objects;
- accept and expose numerical arrays through the Python buffer protocol;
- release the interpreter lock during sufficiently expensive independent core
  work where safe; and
- keep all physics and numerical evaluation in the Zig core.

Python symbolic objects SHOULD expose notebook rich representations through the
MathJax-compatible LaTeX exporter specified in
[Symbolic Export and Notebook Display](SYMBOLIC_EXPORT.md). Implementing that
display protocol MUST NOT introduce a required IPython or Jupyter dependency.

NumPy is the expected user-level array interface, but the initial binding SHOULD
use the general Python buffer protocol rather than require NumPy's C API.

A `ctypes` client SHOULD be maintained as an independent ABI conformance test. It
is not the intended production Python binding.

Wheel tooling, free-threaded CPython support, and the exact packaging system
remain deferred.

## 9. Command-line interface

Phaser provides one CLI executable implemented in Zig. Its file and stream
interfaces are language-independent; a separate C, C++, or Python implementation
of the same CLI is neither required nor desired.

The CLI MUST use the same parser, validation, calculation, lowering, and
evaluation implementations as library clients. It MUST NOT carry independent
scientific logic.

C and C++ embedding examples belong under `examples/`; they are not additional
CLIs unless a distinct end-user workflow later justifies one.

## 10. External numerical libraries

An accepted external numerical library MAY be used internally behind a private
Zig or C adapter. Its types, ownership, callbacks, allocators, and error
representations MUST NOT leak into `phaser.h`, `phaser.hpp`, serialized formats,
or kernel metadata.

All external dependencies are subject to the approval policy in
[Phaser Engineering Style](../../ENGINEERING_STYLE.md) and the repository
[agent instructions](../../AGENTS.md).

## 11. Conformance requirements

Architecture-wide client and language-neutral conformance rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

The initial C and Python interoperability tests SHOULD include:

- compiling `phaser.h` as both C and C++;
- C smoke tests against static and shared libraries;
- header layout and constant checks;
- public-symbol allow-list checks;
- invalid pointers, lengths, capacities, and version fields where safely
  testable;
- explicit ownership and repeated-destruction misuse tests;
- direct C and Python-buffer numerical equivalence;
- scalar and batch result equivalence;
- diagnostic lifetime tests;
- multithreaded tests matching each handle's declared contract; and
- fuzzing parsers and buffer-validation boundaries through the public ABI.

Header tests must compile with independent C and C++ compilers in CI, not only
through Zig's bundled C compiler. The later C++ milestone adds lifecycle
equivalence between direct C calls and `phaser.hpp`.

## 12. Deferred decisions

This specification deliberately leaves open:

- exact C function names and signatures;
- the minimum C and C++ language versions;
- supported compilers, targets, and package repositories;
- the static/shared linkage support matrix;
- symbol versioning mechanisms;
- custom allocator hooks;
- the exact C++ result and exception APIs;
- optional third-party C++ adapters;
- Python wheel tooling and free-threaded-runtime support; and
- whether an ABI-stable plugin protocol is ever needed.

## 13. References

- [Zig language reference: exporting a C library](https://ziglang.org/documentation/master/)
- [Zig build system: static and dynamic libraries](https://ziglang.org/learn/build-system/)
- [Python Stable Application Binary Interface](https://docs.python.org/3/c-api/stable.html)
- [Python buffer protocol](https://docs.python.org/3/c-api/buffer.html)
