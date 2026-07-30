# Decision 0018: Narrow model-specific AOT prototype

Status: accepted

## Context

The safe and optimized interpreters preserve one reusable runtime kernel across
arbitrary validated models. That generality has a measurable fixed cost. For
the small phi4 tree-value workload, the optimized interpreter takes about
12 ns/point in a 1024-point batch while direct C takes less than 1 ns/point.
Repeated fixed-model scans therefore provide enough work to test whether
model-specific ahead-of-time generation justifies a separate build workflow.

The experiment must not weaken the interpreter oracle, freeze numerical
parameters or backgrounds, introduce runtime compilation, or turn arbitrary
model text into source code.

## Decision

Phaser retains a narrow experimental AOT workflow for the existing phi4
tree-level value fixture.

An explicit host tool loads and derives the ordinary fixture, lowers and
validates the ordinary kernel, compiles a bounded AOT plan, and emits one
deterministic Zig module. The plan resolves temporary-slot reuse into immutable
instruction-definition identifiers. Generated source never reparses JSON and
never uses model names as identifiers.

The accepted prototype subset is:

- real `f64`, value-only, tree-level execution;
- three runtime parameters and one runtime background;
- no scale channel;
- constant, parameter, and background loads;
- negation, ordered addition and multiplication; and
- the kernel instruction set's binary integer-power sequence.

Every unsupported capability, shape, slot type, or opcode fails before
emission. There is no interpreter fallback under the AOT identity.

Parameters remain runtime values. Binding evaluates only the parameter-stage
prefix and returns an immutable generated `Bound`. Scalar and batch evaluation
accept runtime backgrounds. The exact workspace is zero bytes with alignment
one.

The generated public functions are safety checked in `ReleaseSafe`: they
validate shapes, checked size arithmetic, workspace, and disjoint storage
before entering a narrow trusted arithmetic leaf. Per-point publication matches
the interpreter: a finite candidate writes the value and `ok`; a non-finite
candidate writes only `non_finite`.

The scalar remainder preserves source instruction and operand order. Four
independent points use an explicit `@Vector(4, f64)` leaf with the same
per-lane operation order. This was added only after the original ordinary loop
compiled as scalar unrolled code. The native ARM64 object contains NEON
`fmul.2d` and `fadd.2d`; the baseline x86-64 Linux object contains SSE2 `mulpd`
and `addpd`.

The workflow is repository-build-only:

```text
zig build emit-aot-prototype
zig build test-aot-prototype
zig build bench-aot-prototype
```

`emit-aot-prototype` writes generated source and an inspectable object under
`zig-out/aot/`. Tests and benchmarks link the generated module statically.
Ordinary model loading, library building, and execution do not invoke the
generator. Generating or compiling requires the pinned Zig toolchain; running
an already linked application does not.

## Verification

The dedicated differential suite compares the generated module bitwise with
the safe interpreter over scalar calls, batch calls, vector blocks, remainders,
partitions, signed zero, subnormal, large, infinite, and NaN backgrounds. It
also checks point-atomic output, scalar/batch-of-one equality, zero workspace,
shape and alias rejection, and model/request identity mismatch.

Planning tests cover the accepted subset, operand order, input-shape and
capability rejection, and instruction, operand, and name limits. Generation
tests cover byte determinism, escaped hostile names, and atomic source-size
failure. A committed generated-source golden detects source-shape drift.

The structured `aot_generation` fuzz target builds supported typed value
graphs, lowers and validates them, constructs the AOT plan, and requires two
independent emissions to agree byte for byte. Fuzz bytes are never interpolated
into identifiers, paths, or shell commands.

The generated object cross-compiles with the pinned toolchain for baseline
x86-64 Linux, AArch64 Linux, and x86-64 Windows. Native execution remains the
required portability evidence; cross-compilation does not replace the native
CI matrix.

## Measurements

On Apple M4 with Zig 0.16.0 in `ReleaseSafe`, seven samples of at least 50 ms
gave these medians:

| Shape | Direct C | Optimized interpreter | AOT prototype |
|---|---:|---:|---:|
| scalar throughput | 1.189 ns | 39.669 ns | 3.534 ns |
| dependent scalar latency, including carrier | 7.205 ns | 40.813 ns | 7.545 ns |
| batch, 8 points | 0.852 ns/point | 13.557 ns/point | 0.788 ns/point |
| batch, 64 points | 0.742 ns/point | 12.155 ns/point | 0.413 ns/point |
| batch, 1024 points | 0.735 ns/point | 12.012 ns/point | 0.360 ns/point |

The AOT binding itself measured 0.625 ns. The prototype therefore clears both
experimental thresholds: scalar execution is substantially faster than the
optimized interpreter, and batch execution is within two times direct C. For
full vector batches it exceeds this direct C baseline's throughput.

The generated source is 7,715 bytes. The native inspectable Mach-O object is
182,280 bytes including object metadata; its reported text and data total only
784 bytes. Baseline cross-compiled objects measured about 360 KiB for x86-64
Linux, 357 KiB for AArch64 Linux, and 15 KiB for x86-64 Windows, demonstrating
why raw object-container size is not a portable regression metric.

An isolated build with empty local and global Zig caches took 16.25 seconds and
reported 718 MB maximum resident size (600 MB peak footprint). Repeating the
unchanged build with those caches took 0.12 seconds and 36 MB maximum resident
size. These measurements include the host derivation/generator executable and
the inspectable target object, not only parsing the 7.5 KiB generated source.
No regression threshold is set from one machine.

## Alternatives

Replacing either interpreter was rejected. The reference remains the scientific
oracle, and the optimized interpreter remains the fast general runtime path for
models without a separately built module.

Runtime Zig invocation and dynamic loading were rejected for this prototype.
They would combine untrusted process management, packaging, cache identity, and
plugin-boundary decisions with the numerical code-generation experiment.

Generating a direct expression from original JSON was rejected. The validated
kernel program is the semantic boundary, and a typed AOT plan is the only
source-emitter input.

Relying on automatic vectorization was tried first. Inspection showed scalar
unrolling rather than packed arithmetic, so the measured explicit vector leaf
was retained.

## Consequences

The prototype demonstrates that interpreter dispatch, typed-slot access, and
generic control flow dominate this very small polynomial. Model-specific source
generation can remove nearly all of that cost while retaining a checked call
boundary and exact interpreter agreement.

The improvement comes with real build and maintenance cost. The generated API
is an internal Zig interface, not a stable ABI. The current channel shape,
instruction subset, four-lane width, source format, and static build wiring are
experimental and deliberately narrow.

The outcome is to retain and harden the explicit prototype, not to integrate it
into ordinary loading. Packaging, native-platform evidence, process isolation,
timeouts, caching, and a public command remain unsolved.

## Revisit when

Evaluate one larger tree-value fixture after packaging and native CI evidence
are settled. Expanding parameter/background shapes or opcodes requires a new
bounded plan contract, differential and fuzz coverage, generated-code
inspection, build-cost measurements, and direct-C comparisons. Consider a
public AOT surface only when execution and cache identity can be specified
without exposing internal Zig layouts.
