# Language and Interoperability

Status: active — the Milestone 4 contract

This document specifies Phaser's implementation language and its supported
language boundaries. It defines the intended architecture, ownership rules, and
compatibility responsibilities. Sections 5 and 8 are the contract Milestone 4
implements; exact parameter lists and package names remain to be designed.

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
lib/libphaser.a          (Windows: lib/phaser_static.lib)
lib/libphaser.so, libphaser.dylib
bin/phaser.dll, lib/phaser.lib   (Windows: the DLL and its import library)
bin/phaser
```

The build MAY provide static libraries, shared libraries, or both. The same
public header and behavioral contract apply to both linkage modes.

The static library carries a distinct name on Windows because the plain name
collides: a shared build produces `phaser.dll` together with an import library
also called `phaser.lib`, which would silently replace the static
`phaser.lib` in the same directory and leave static linkage with no artifact.
ELF and Mach-O have no such collision, so they keep `libphaser.a` beside
`libphaser.so` or `libphaser.dylib`.

Both distributed library products MUST be position-independent. A shared library
requires it, and in practice the static library does too: mainstream Linux
distributions default their compilers to `-pie`, so an ordinary
`cc client.c libphaser.a` against a non-position-independent archive fails to
link. A consumer MUST NOT have to pass `-no-pie` to use the static library.

The static library MUST also carry the compiler-support routines the
implementation language would otherwise contribute at its own link step, because
a distributed archive is linked by the consumer's toolchain rather than ours.

The distributed products are stripped, which removes the implementation
language's stack-trace symbolizer along with its debug info. A client cannot act
on an implementation-language stack trace, and §5.7 requires that no such panic
cross the boundary in any case. Stripping also removes what that machinery
drags in: it roughly tripled the artifacts, and on Windows it referenced an
ntdll entry point the platform SDK's import library does not export, failing a
consumer's static link over a feature they could not use. Runtime safety checks
are unaffected; a violated check still traps, without symbolizing.

### 4.1 Linking statically on Windows

Two things a Windows consumer must know, neither of which applies to Linux or
macOS.

**Link `ntdll.lib`.** The static library reaches the NT native API directly for
files, memory sections, and timing, so a static link needs `ntdll.lib` in
addition to the C runtime. Nothing in the archive carries a `/DEFAULTLIB`
directive for it. Omitting it produces around twenty undefined `Ldr*`, `Nt*`,
and `Rtl*` symbols. The shared library is unaffected: it resolves them
internally, and a consumer of the DLL links only its import library.

**`link.exe` cannot consume the static library** as of ABI version 0. Both
available configurations fail:

- with the Zig compiler-support object bundled, `link.exe` rejects it with
  `LNK1143: invalid or corrupt file: no symbol for COMDAT section`; and
- without it, `__divti3` and `__udivti3` are undefined, because the library
  references them and the Microsoft C runtime provides no 128-bit division
  helpers.

A Windows consumer linking statically therefore uses `lld-link`, which ships
with LLVM and with the Zig toolchain, and which links the same archive
successfully. Compilation is unaffected: MSVC compiles `phaser.h` and consumer
sources normally, and only the final link step differs.

Windows consumers who cannot change linker SHOULD use the DLL and its import
library, which `link.exe` consumes without difficulty.

This is a limitation of the interaction between the two toolchains, not a
property of the ABI, and it does not affect Linux or macOS. Conformance runs the
Windows static-linkage check through `lld-link` so the archive itself stays
exercised; what remains untested is `link.exe` specifically.

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

Milestone 3 produced those executable lifecycles, so the deferral of exact
signatures has expired. The version 0 operation set is specified in §5.11.

### 5.2 Header compatibility

`phaser.h` MUST be a valid standalone C header for the selected minimum C
language version. It MUST also be directly includable by C++ and use `extern "C"`
guards when compiled as C++.

The public header MUST:

- include or define everything needed to interpret its declarations;
- avoid compiler extensions unless isolated behind portable feature checks;
- use a common export/import macro for symbol visibility; and
- expose the ABI version and library version separately.

The minimum is C11 for `phaser.h` as a C header and C++17 for the same header
included from C++, selected in
[Decision 0014](../decisions/0014-public-header-and-toolchain-baseline.md). That
decision also makes the header authoritative and hand-written rather than
generated, and records the supported linkage and platform matrix: static and
shared linkage on Linux x86-64, macOS ARM64, and Windows x86-64, each a required
native test platform. On Windows the single export macro must additionally
distinguish building the shared library from consuming it, because
`__declspec(dllimport)` has no ELF or Mach-O counterpart.

### 5.3 Opaque objects

Long-lived core objects MUST cross the ABI as opaque handle types, conceptually:

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

[Decision 0013](../decisions/0013-c-abi-v0-surface.md) fixed this set against
the lifecycle Milestone 3 actually built. It drops the `phaser_plan` this
document sketched before the core existed — no such object was implemented, and
its role is split between the parsed `phaser_request` and the derived
`phaser_artifact` — and adds `phaser_point` for the parsed parameter point.

Their representations are private. A client MUST NOT allocate, copy, inspect, or
free an opaque object except through its documented Phaser operations.

Every handle type MUST have an explicit ownership model. Ownership in version 0
is unique and non-shared: every handle has exactly one owner and exactly one
destructor, and no handle is retained or released. A handle derived from another
does not extend its parent's lifetime; each specified operation states the
required outlives-relationship. Nullability MUST be documented for every handle
argument, and passing null where a handle is required MUST report
`PHASER_STATUS_INVALID_ARGUMENT` rather than trap.

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

[Decision 0013](../decisions/0013-c-abi-v0-surface.md) realizes this as two
status types that are never converted into one another: a control-plane
`phaser_status` returned by structurally fallible operations, and a per-point
`phaser_point_status` written one entry per point, mirroring the kernel's
internal `Status` value for value. An evaluation whose points all report a
numerical outcome is a successful call; the per-point array is where that
outcome is read. A control-plane failure publishes no point statuses at all.

This separation is a requirement, not an implementation convenience. The
distinction between a successful complex result at a negative eigenvalue, an
exact zero mode, a `nonconvergent` solve, and a `singular_derivative` is the
scientific content of Milestone 3, and MUST NOT be collapsed into a call-level
error code at the boundary.

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

### 5.11 Version 0 operation set

Version 0 wraps the lifecycle Milestone 3 delivered and adds nothing to it:

```text
context -> model -> request -> artifact -> kernel
                                  point ------+
                                              v
                                           binding -> workspace query
                                                   -> evaluate
```

The operations below are the required surface. Names are normative; exact
parameter lists are fixed by the header, which
[Decision 0014](../decisions/0014-public-header-and-toolchain-baseline.md) makes
authoritative. Every operation marked fallible returns `phaser_status`.

| Group | Operations | Notes |
|---|---|---|
| Version | `phaser_abi_version`, `phaser_abi_experimental`, `phaser_library_version` | Infallible. ABI and library versions are separate, per §5.2. |
| Context | `phaser_context_create`, `phaser_context_destroy` | Carries limits and allocation policy. No global default context. |
| Model | `phaser_model_load`, `phaser_model_destroy`, `phaser_model_fingerprint`, `phaser_model_parameter_count`, `phaser_model_scalar_field_count` | Load takes source bytes and length and may produce diagnostics. |
| Request | `phaser_request_parse`, `phaser_request_destroy`, `phaser_request_loop_order`, `phaser_request_coordinate_count` | The parsed calculation request, reusable across derivations. |
| Artifact | `phaser_artifact_derive`, `phaser_artifact_destroy`, `phaser_artifact_loop_order`, `phaser_artifact_coordinate_count`, `phaser_artifact_contribution_count`, `phaser_artifact_result_type`, `phaser_artifact_export` | Export renders Phaser notation or LaTeX per [Symbolic Export](SYMBOLIC_EXPORT.md). |
| Kernel | `phaser_kernel_compile`, `phaser_kernel_destroy`, `phaser_kernel_result_type`, `phaser_kernel_capability`, `phaser_kernel_coordinate_count`, `phaser_kernel_parameter_count` | Typed queries, so no client parses JSON to size a buffer. Compilation takes a capability and a selection. |
| Point | `phaser_point_parse`, `phaser_point_destroy`, `phaser_point_reference_scale` | A parsed parameter point, bindable more than once. |
| Binding | `phaser_binding_create`, `phaser_binding_destroy`, `phaser_binding_workspace`, `phaser_binding_coordinate_count`, `phaser_binding_result_type`, `phaser_binding_capability` | Workspace returns exact bytes and alignment for a point count. The query set is closed under sizing an evaluation: a client holding only a binding can size every output buffer. |
| Evaluation | `phaser_evaluate`, `phaser_evaluate_complex` | Allocation-free. Separate entry points by result type; no mode flag. |
| Diagnostics | `phaser_diagnostics_destroy`, `phaser_diagnostics_count`, `phaser_diagnostics_at`, `phaser_diagnostics_render` | Typed access is primary; rendering is a convenience over it. |

Requirements on this surface:

- Every `*_destroy` MUST accept null as a no-op and MUST be safe exactly once
  per handle. Repeated destruction of the same handle is a client error that
  conformance tests exercise.
- Every operation that can produce diagnostics MUST take a
  `phaser_diagnostics **` out parameter and MUST write null to it on any status
  other than `PHASER_STATUS_INVALID_SOURCE`.
- `phaser_evaluate` MUST report `PHASER_STATUS_INVALID_ARGUMENT` when called on
  a kernel whose result type is complex. It MUST NOT project a real part.
- Evaluation MUST require the per-point status array's length to equal the point
  count, so an unwritten entry is never mistaken for success.
- Complex values cross as an explicit struct of two `double` fields, not as C99
  `_Complex`.
- The workspace size an evaluation requires MUST be queryable before the call,
  MUST be exact rather than an estimate, and MUST be the figure the caller
  passes back. It is the boundary's requirement, which is not necessarily the
  core's: widening the kernel's per-point statuses to the published `int32_t`
  needs scratch, and evaluation may not allocate. A caller queries the number
  and does not need to know why it is what it is.
- Every text-producing operation uses one sizing convention: a null buffer
  reports the required length and `PHASER_STATUS_INSUFFICIENT_SPACE`, a large
  enough buffer is filled exactly, and no null terminator is written. A short
  buffer is a reported failure, never a truncation.
- An unrecognized enumerator in a caller-supplied field — an export target, a
  derivative capability, a selection kind or role — MUST be rejected rather than
  resolved to a default. Choosing one silently would answer a different question
  than the caller asked. A selection payload alongside `PHASER_SELECTION_TOTAL`
  is rejected for the same reason: it describes something the caller did not get.

- A client MUST be able to ask for one loop order or one contribution role
  directly. Reconstructing a contribution by subtracting two totals is a
  cancellation wherever the parts are close, and there is no comparison policy
  under which the reconstruction and the directly summed value agree. Selection
  is a kernel compile-time property, so it travels in `phaser_kernel_options`
  rather than in an evaluation flag.

The CLI is not reimplemented over this surface. It continues to call the Zig
core directly, as §9 permits, and Milestone 4's agreement criterion compares
their results rather than their implementations.

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
[Decision 0015](../decisions/0015-phase-b-python-dependencies.md) approves that
dependency at `Py_LIMITED_API` `0x030B0000`, together with the plotting and
notebook-execution packages the first notebook needs.

The extension SHOULD:

- mirror the core model, plan, artifact, binding, and kernel lifecycle at a
  suitably high level;
- translate structured diagnostics into appropriate Python exceptions and
  inspectable diagnostic objects;
- accept and expose numerical arrays through the Python buffer protocol;
- release the interpreter lock during sufficiently expensive independent core
  work where safe; and
- keep all physics and numerical evaluation in the Zig core.

### 8.1 Objects and lifetimes

The extension publishes primitives, not the user-facing API. Each ABI handle
crosses into Python as a named capsule; `bindings/python/src/phaser/__init__.py`
wraps those capsules in classes. Presentation, naming, and convenience are
ordinary Python, and only what touches the ABI or the buffer protocol is native.

Each capsule owns a strong reference to the capsules its handle was derived
from, and releases those references only after its own handle has been
destroyed. That is what enforces the C ABI's outlives-relationships, and it MUST
stay at the capsule level rather than moving to the Python classes. Holding the
parent object as an attribute of the child is not sufficient: when the last
reference to a child goes, its instance dictionary is released and the parent
may be freed while the child's own capsule is still in that dictionary awaiting
its turn. The order attributes are torn down in is an interpreter implementation
detail, and depending on it destroyed a context before the model it owned.

A capsule's name is checked on the way back in, so passing a model where a
kernel belongs raises rather than reinterpreting a pointer.

### 8.2 Arrays

Backgrounds arrive through the buffer protocol and MUST be C-contiguous
`float64`. A NumPy array, an `array.array('d')`, and a cast `memoryview` all
cross without a copy; a plain sequence is copied into one. `bytes` and
`bytearray` MUST be refused rather than reinterpreted: they do export a buffer,
of unsigned bytes, and reading those bytes as doubles would turn a plausible
mistake into a plausible wrong answer.

Results leave as byte buffers the Python layer presents as shaped memoryviews.
A complex result's trailing axis is the real and imaginary parts, which is
`phaser_complex`'s layout and also NumPy's `complex128`, so a caller who has
NumPy views the same bytes with no conversion step in the binding. NumPy MUST
NOT become a requirement of the binding in either direction.

NumPy is the expected user-level array interface, but the initial binding SHOULD
use the general Python buffer protocol rather than require NumPy's C API.

The interpreter lock is released around the core evaluation call and MUST NOT be
released around anything that touches a Python object.

### 8.3 Diagnostics

A rejected document raises `SourceError`, which subclasses `ValueError` so that
a caller who only wants to know the document was rejected keeps catching what it
always caught. The structure is additional rather than a replacement.

Every diagnostic the operation produced reaches the exception's `diagnostics`
attribute, carrying the code, severity, category, rendered message, related
count, and primary span. Severity and category are named rather than numbered;
the names live in the Python layer, next to the tables that define them.

The exception's message summarizes the first diagnostic only, because that is
what a traceback shows. It MAY be abbreviated; the attribute MUST NOT be.

A diagnostic with no primary source location MUST report no span rather than a
span of zero. `[0, 0)` is a location in the document, and collapsing the two
would point a reader at the first byte of a file the diagnostic has nothing to
do with.

An unrecognized severity or category MUST fall back to its number rather than
raise. This runs while an exception is already being reported, and refusing to
name a category is no reason to replace the diagnostic the caller needs to read.
That is a deliberate exception to the rule elsewhere in the binding, where an
unrecognized enumerator is a failure of its kind.

### 8.4 Rich display

Python symbolic objects SHOULD expose notebook rich representations through the
MathJax-compatible LaTeX exporter specified in
[Symbolic Export and Notebook Display](SYMBOLIC_EXPORT.md). Implementing that
display protocol MUST NOT introduce a required IPython or Jupyter dependency.

The artifact implements `_repr_latex_`, which a frontend calls if it exists.
Nothing in the package imports IPython, and a test asserts that importing
`phaser` leaves no notebook module loaded. Delimiters are added by the display
method rather than by the exporter, which emits a fragment precisely so each
consumer chooses its own; `to_latex`, `to_phaser`, `str`, and `repr` remain
available and unchanged outside a frontend.

### 8.5 Independent conformance client

A `ctypes` client SHOULD be maintained as an independent ABI conformance test. It
is not the intended production Python binding.

That client lives in `bindings/python/test/test_ctypes_abi.py`. Its
independence is the point and has to be preserved: it re-declares every
signature it uses by hand, from the header read as documentation, rather than
sharing declarations with the extension. The extension is compiled against
`phaser.h` by a compiler that checks each signature, so the two would agree
even if both drifted together; a hand transcription in another language would
not. It loads the shared library rather than importing the extension, and it
compares the results of both where they overlap.

A run that cannot find the shared library MUST fail rather than skip. A
conformance suite that skips still reports success, which would claim an
agreement nobody checked.

Wheel tooling, free-threaded CPython support, and the exact packaging system
remain deferred.

### 8.6 Build and platform status

The extension is built by `zig build -Dpython=<interpreter>`, which is opt-in.
Without that option nothing about the binding is configured, so a contributor
without a suitable interpreter builds, tests, and fuzzes everything else
unchanged. The interpreter is asked for its own extension suffix, and on Windows
for the directory holding the Stable ABI stub, rather than either being assumed,
so the same build serves a system interpreter and a virtual environment.

The extension declares the Limited API subset it uses rather than translating
`Python.h`, so Python's headers are not a build input on any platform. Two
reasons, one forced and one preferred. The forced one: Microsoft's C runtime
declares its bounds-checked `_s` string functions through inline wrappers that
Zig's C translation renders as unused local constants and then rejects, and
they reach the extension through `Python.h` without it asking for them. The
preferred one: a declared subset behaves the same on every platform, where a
translated header behaves however each platform's headers happen to translate.

What this gives up is a compiler checking those signatures against the real
header. The Stable ABI is stable by contract, which is the reason for pinning
`Py_LIMITED_API` in the first place, and a mistake in the declarations is loud
rather than subtle: a wrong `PyModuleDef` layout makes the module unimportable,
which every test in the binding reports immediately.

The Phaser core is linked statically into the module, which therefore needs no
co-installed shared library and no `rpath`.

On ELF and Mach-O the module leaves the interpreter's symbols undefined and has
them resolved at load time by the process that imports it, which is how CPython
extensions are built on those platforms. Windows cannot do that and links the
Stable ABI stub `python3.lib` instead.

That stub is `python3.lib` rather than `python3X.lib`: the latter pins one minor
version and would defeat the purpose of building against a stable ABI. It lives
in `libs/` beside the interpreter's base installation, whose path the build asks
the interpreter for. A virtual environment reports its base installation, which
is where the import libraries actually are.

All three platforms build and test the binding.

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

Decisions [0013](../decisions/0013-c-abi-v0-surface.md) and
[0014](../decisions/0014-public-header-and-toolchain-baseline.md) closed the
exact operation set, the language baseline, and the linkage and platform matrix.
This specification still leaves open:

- exact parameter lists, which the authoritative header fixes;
- package repositories and distribution channels;
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
