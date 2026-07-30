# Zig `comptime` and Model-Specific AOT Compilation

Status: implemented for the narrow tree-value prototype; broader AOT remains deferred

This document specifies how Phaser uses Zig `comptime` in its ordinary build and
how a future model-specific ahead-of-time backend may turn runtime-derived
structure into input for a separate Zig compilation. It refines section 20 of
[DESIGN.md](../../DESIGN.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations.

## 1. Scope

This specification covers:

- finite compile-time metadata and validation;
- bounded generic specialization;
- compile-time resource discipline;
- the boundary between Zig compile time and Phaser's runtime compiler stages;
- small compile-time conformance checks;
- future model-specific Zig code generation;
- AOT identity, metadata, and differential validation; and
- build-time performance testing.

The first prototype fixes one instruction subset, generated source layout, and
repository build workflow. A general loading mechanism, public command-line
surface, and artifact package format remain deferred.

## 2. Governing distinction

Phaser uses the word “compile” at two different levels:

1. Zig compiles the Phaser implementation.
2. Phaser structurally compiles a user model and calculation into reusable
   artifacts and numerical kernels.

These stages MUST NOT be conflated. A model loaded from JSON after Phaser starts
is runtime information from Zig's perspective, even though Phaser treats model
loading and derivation as compilation stages.

The ordinary Phaser build uses `comptime` only for finite, Phaser-owned structure.
It MUST NOT parse, derive, or specialize arbitrary runtime user models.

## 3. Knowledge stages

Information becomes known at the following stages:

| Stage | Newly known information | Intended work |
|---|---|---|
| Phaser build | IR variants, builtin functions, supported finite capabilities, topology catalogs | `comptime` validation and generation |
| Model load | Field content, index dimensions, declared sparsity | Canonical runtime Model IR |
| Calculation derivation | Actual diagrams, contractions, expressions, structural zeros | Immutable calculation artifact |
| Kernel lowering | Instruction graph, layouts, temporaries, capabilities | Immutable runtime kernel |
| Parameter binding | Masses, couplings, and other parameter values | Reusable numerical binding |
| State binding | Scale, temperature, gauge parameters, environment | Update dependency-directed state |
| Evaluation | Background coordinates and batch points | Allocation-free execution |
| Optional AOT build | One validated artifact or lowered plan is supplied to a separate compilation | Model-specific generated kernel |

Work SHOULD occur at the earliest stage at which all required information is
known and doing the work benefits the complete workload. “Earliest stage” does
not imply Zig compile time.

## 4. Ordinary-build uses

### 4.1 Implementation completeness

`comptime` SHOULD validate that every supported variant has all required
implementation metadata and operations.

Applicable finite sets include:

- source-expression node kinds;
- Typed Value IR operations;
- numerical instruction kinds;
- calculation kinds;
- diagnostic categories;
- serialization variants;
- kernel capabilities; and
- C ABI status mappings.

Depending on the type, validation may cover:

- serialization and parsing;
- hashing and canonical ordering;
- formatting;
- differentiation support;
- numerical lowering;
- evaluation;
- provenance;
- fuzz-generator coverage; and
- capability reporting.

Exhaustive Zig `switch` expressions remain useful and SHOULD be preferred where
they state behavior more clearly than reflection.

### 4.2 Reflection and stable identity

Compile-time reflection MAY generate internal tables and dispatch.

Source declaration order, type names, and reflected field positions MUST NOT
implicitly define stable serialized tags, content-domain identifiers, or public
ABI constants. Stable external identifiers are explicit and independently
validated.

Reordering an internal Zig declaration MUST NOT silently change public model
semantics or persisted identities.

### 4.3 Parser and builtin tables

The expression language's finite operator, function, and constant vocabulary
SHOULD have one declarative source of metadata. `comptime` MAY generate or
validate:

- spellings and aliases;
- token and operation kinds;
- precedence and associativity;
- arity;
- argument and result categories;
- availability in source and canonical expressions; and
- documentation or test tables.

Constants such as `pi` remain symbolic until explicit numerical lowering.
Generating a builtin table MUST NOT force approximate evaluation.

### 4.4 Finite generic axes

Suitable compile-time parameters MAY include:

- numerical scalar implementation;
- small tensor rank;
- derivative capability;
- backend implementation;
- a finite output-capability set; and
- a bounded internal storage strategy.

Every generic axis MUST have a deliberately supported finite set of
instantiations in ordinary builds. User input MUST NOT create an unbounded family
of Zig types or functions.

The first complete production numerical implementation is `f64`. Code SHOULD NOT
be made generically polymorphic without a concrete second implementation or a
clear testing benefit.

### 4.5 Runtime dimensions

The following remain runtime data in the ordinary library:

- field and background counts;
- index-space dimensions;
- tensor-component counts;
- expression and instruction counts;
- model-specific matrix dimensions;
- parameter counts; and
- model-specific sparsity.

The ordinary library MUST NOT instantiate a distinct Zig kernel type for every
combination of these values.

Small tensor rank may be a compile-time type parameter while the dimensions of
its index spaces remain runtime values.

### 4.6 Topology catalogs

Abstract diagram topologies for an explicitly supported perturbative order are a
finite Phaser-owned set. `comptime` MAY validate or generate:

- topology identifiers;
- abstract edge and vertex incidence;
- symmetry metadata;
- admissible field-kind assignments; and
- dispatch tables.

Actual model-specific field assignments, index contractions, diagrams,
structural-zero pruning, and contribution expressions are derived at runtime.

### 4.7 ABI and layout assertions

Compile-time checks SHOULD cover:

- C structure size, alignment, and relevant offsets;
- public constant and status relationships;
- scalar-width assumptions;
- completeness of status and diagnostic conversion;
- generated table invariants; and
- fixed internal layout assumptions required by a backend.

Compile-time assertions supplement independent C and C++ conformance builds.
They do not replace them.

## 5. Runtime-callable helpers

When practical, a bounded pure helper SHOULD be callable both at runtime and at
compile time rather than having separate implementations.

Small compile-time assertions may exercise:

- exact integer and rational arithmetic;
- index permutations and signs;
- tiny tensor contractions;
- topology metadata;
- layout formulas; and
- canonical finite lookup tables.

The runtime form remains available for unit tests, property tests, fuzzing, and
differential testing. Compile-time success does not replace validation of
external input at runtime.

Zig compile-time integers or floats MUST NOT silently become Phaser's scientific
exact-expression domain. Exact symbolic values continue to use the explicitly
specified Phaser representation.

## 6. Prohibited ordinary-build uses

The ordinary Phaser build MUST NOT use `comptime` to:

- parse arbitrary model or calculation JSON;
- canonicalize arbitrary user expressions;
- derive model-specific diagrams;
- perform unbounded symbolic simplification;
- expand arbitrary indexed contractions;
- generate a unique Zig type for every field, parameter, component, expression,
  or index space;
- specialize on ordinary numerical parameter, temperature, scale, gauge, or
  background values;
- create model-sized global arrays; or
- make the normal library build depend on a particular user model.

Scientific structure and dynamic binding follow
[Structural Compilation and Dynamic Binding](STRUCTURAL_COMPILATION.md).
Version 0.1 has no general scientific-specialization mechanism; `comptime` MUST
NOT become an undocumented substitute for one.

## 7. Compile-time resource discipline

Every nontrivial `comptime` use SHOULD be classified as:

1. correctness or completeness validation;
2. finite implementation generation; or
3. measured runtime optimization.

Before adding a compile-time transformation, determine:

- whether all inputs are finite and Phaser-owned;
- the maximum number of instantiations;
- whether equivalent runtime code remains testable;
- whether generated types leak into public boundaries;
- expected compiler time and memory;
- expected binary-size change; and
- how the behavior is validated.

Compile-time work MUST NOT grow with arbitrary runtime model contents in the
ordinary build.

### 7.1 Evaluation branch quota

Any use of Zig's `@setEvalBranchQuota` MUST:

- be local rather than repository-wide;
- operate over a statically bounded input;
- document the bound and reason;
- have a compile-time regression test; and
- be reviewed as evidence that the work may belong at runtime.

It MUST NOT be used merely to force a large or model-dependent computation
through the compiler.

### 7.2 Explicit inlining and unrolling

`inline for`, explicit inlining, and compile-time unrolling SHOULD be used when
required for heterogeneous types or compile-time field selection.

Using them solely for performance requires representative benchmark evidence.
Large unrolled kernels MUST be evaluated for compiler memory, binary size, and
instruction-cache effects.

## 8. Build-cost observability

The project SHOULD track, when stable enough for meaningful comparison:

- clean build time;
- incremental build time;
- peak compiler memory;
- output binary size;
- generated AOT source and object size;
- number of deliberately instantiated backend combinations; and
- runtime performance affected by the compile-time choice.

Regression thresholds should be established only after representative baselines
exist. Compile-time optimization is rejected when its total build and runtime
tradeoff is not justified.

The exact Zig toolchain is pinned according to
[Language and Interoperability](LANGUAGE_AND_INTEROPERABILITY.md), because
compiler behavior and generated code are part of AOT provenance.

## 9. Model-specific AOT boundary

Model-specific AOT compilation is a separate, explicit workflow. It is not the
ordinary model-loading path.

Conceptually:

```text
validated model + calculation artifact
                    |
                    v
          ordinary kernel lowering
                    |
                    v
       validated backend-neutral plan
                    |
                    v
       deterministic Zig source generation
                    |
                    v
          pinned Zig toolchain build
                    |
                    v
          model-specific AOT kernel
```

The generator SHOULD consume a validated calculation artifact or lowered kernel
plan. It SHOULD NOT emit a program that reparses original source JSON at Zig
compile time.

The first prototype consumes a bounded, arena-owned AOT plan compiled from a
validated `kernel.Program`. Temporary-slot reuse is resolved into immutable
instruction-definition identifiers before emission. The accepted subset is:

- tree-level, real `f64`, value-only kernels;
- three runtime parameter channels and one runtime background channel;
- no renormalization-scale channel;
- constant, parameter, and background loads;
- negation, ordered variadic addition and multiplication; and
- the instruction set's normative binary integer-power sequence.

Every other capability, type, shape, or opcode is rejected before source
emission. This is an experimental subset exercised by the committed phi4
fixture, not a promise that every three-parameter model is an AOT-supported
public surface.

The deterministic module uses numeric definition identifiers, exact `f64`
bit-pattern literals, escaped names only in metadata, an immutable bound
parameter value, a checked public call boundary, a scalar remainder, and a
four-point vector leaf. Arithmetic order within each independent lane is
identical to the validated program.

## 10. AOT-known and dynamic data

A generated model-specific module MAY know at Zig compile time:

- field and background counts;
- index-space and matrix dimensions;
- tensor sparsity and contraction plans;
- expression and instruction topology;
- temporary live ranges;
- derivative capabilities;
- fixed output layouts; and
- reproducible reduction structure.

It continues to receive as runtime input:

- ordinary numerical parameter points;
- renormalization scale;
- temperature and other environmental values;
- gauge parameters;
- background coordinates and batches;
- input and output buffers; and
- evaluation workspace.

A future explicit scientific specialization may fix additional values only
through its recorded contract. Merely generating AOT code MUST NOT freeze a
parameter that remains dynamic in the parent artifact.

## 11. AOT behavioral contract

An AOT backend implements the same scientific artifact as another numerical
backend. It MUST preserve:

- declared input names, categories, order, and units;
- output layouts and ordering;
- binding and workspace semantics;
- status and branch behavior;
- complex-value policy;
- derivative capabilities;
- reproducibility policy;
- contribution and perturbative-order metadata; and
- scientific provenance.

An unsupported AOT capability fails during backend construction. It MUST NOT
silently change the calculation or use a lower-accuracy implementation.

The safe interpreted kernel remains the initial executable reference.

## 12. AOT identity and provenance

An AOT kernel has a distinct backend identity even when it implements the same
calculation artifact and numerical policy as an interpreted kernel.

Its identity and provenance include, as applicable:

- calculation metadata and any future structural assumptions;
- lowering and generator versions;
- generated-plan identity;
- pinned Zig version;
- target and CPU features;
- optimization and safety mode;
- numerical scalar implementation;
- backend configuration;
- reproducibility policy; and
- external dependency versions, if explicitly approved and used.

Generated source formatting that has no semantic effect SHOULD be normalized or
excluded from semantic identity. The exact generated source and object may have
separate diagnostic hashes.

AOT cache compatibility follows
[Content Fingerprints and Deferred Caching](CONTENT_IDENTITY_AND_CACHING.md).

## 13. Loading and distribution

The prototype is compiled and linked statically into its dedicated differential
test and benchmark executables. It creates no dynamic loading or plugin ABI.
Broader delivery remains deferred. Possibilities include:

- linking it into a generated application;
- producing a model-specific static or shared library; or
- loading it behind a future internal backend boundary.

This specification does not create a public plugin ABI. A loading mechanism must
not expose internal Zig layouts as a stable cross-version contract.

The ordinary interpreted path remains available without requiring the user to
install a Zig compiler at runtime. A user generating or compiling this
prototype needs the repository's pinned Zig toolchain; executing an already
linked application does not.

## 14. Security and resource limits

AOT generation and compilation consume external process, filesystem, CPU, and
memory resources. They MUST be explicit user actions and obey declared limits.

Untrusted model input MUST pass the ordinary parser, validation, canonicalization,
and derivation boundaries before code generation.

Generated identifiers, paths, literals, and data MUST be emitted through
structured code-generation routines rather than raw source interpolation.

The prototype bounds instruction count, aggregate operand count, metadata-name
bytes, and generated-source bytes. It generates only into build-owned paths.
Process isolation, compilation timeouts, and a user-controlled output/package
surface remain deferred.

## 15. Validation and differential testing

Architecture-wide oracle-independence and benchmark rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

Required ordinary-build tests include:

- every finite metadata table is complete and duplicate-free;
- every reflected external identifier agrees with an explicit stable mapping;
- compile-time assertions agree with runtime checks;
- generic instantiations cover only the supported finite set;
- parser and builtin tables agree with expression-language behavior;
- ABI layout assertions agree with independent C and C++ tests; and
- compile-time helpers agree with runtime execution.

The prototype tests:

- deterministic generation from identical input IR;
- generated source builds with the pinned toolchain;
- AOT and safe-interpreter agreement;
- scalar and batch agreement;
- value agreement for its declared value-only subset;
- runtime parameter and background binding;
- status and failure equivalence;
- workspace-boundary checks;
- reproducibility checks;
- build-time, compiler-memory, binary-size, and runtime benchmarks.

Structured fuzzing SHOULD target the AOT generator input IR. Arbitrary fuzz
inputs MUST NOT be interpolated directly into source or shell commands.

## 16. Adoption threshold and prototype outcome

The prototype began after:

- the safe interpreter is complete for the target calculation;
- numerical semantics and workspace behavior are stable;
- representative benchmarks identify interpretation or generic lowering as a
  material bottleneck;
- the expected speedup justifies compiler and packaging complexity; and
- differential reference tests are available.

Decision 0018 records that the phi4 prototype clears its runtime threshold by a
wide margin and should be retained as an explicit experimental workflow. It
does not justify making AOT part of ordinary loading or broadening the supported
scientific subset yet. The next work is to harden packaging and native-platform
evidence, then evaluate one larger tree-value model through a separately
reviewed subset extension.

`comptime` remains valuable for correctness metadata independent of AOT.

## 17. Deferred decisions

This specification deliberately leaves open:

- exact finite generic axes and supported instantiations;
- compile-time and binary-size regression thresholds;
- topology-catalog representation;
- general generated-code IR beyond the prototype subset;
- general generated Zig source organization;
- public AOT command and packaging format;
- static, shared, or application-linked delivery;
- loading and compatibility mechanism;
- compiler-process isolation and limits;
- AOT cache storage; and
- the second benchmark-driven model subset for AOT.

## 18. References

- [Zig language reference: `comptime`](https://ziglang.org/documentation/master/#comptime)
- [Zig language reference: `@setEvalBranchQuota`](https://ziglang.org/documentation/master/#setEvalBranchQuota)
