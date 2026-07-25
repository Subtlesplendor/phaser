# Phaser

Phaser is a Zig library for deriving and evaluating perturbative quantum field
theory calculations. The repository is currently implementing Milestone 0: the
design baseline and correctness substrate for the first scalar vertical slice.

## Toolchain

Phaser requires exactly Zig 0.16.0. The expected version is recorded in
`.zigversion`; other Zig versions are rejected during build configuration.

The CI installer downloads the official archive for Linux x86-64 or macOS ARM64
and verifies its pinned SHA-256 checksum before use:

```text
tools/ci/install_zig.sh INSTALL_DIRECTORY
```

The pinned compiler and Zig standard library are the only implementation
dependencies.

## Build and test

Build the static library:

```text
zig build
```

Run the bounded deterministic suite in the two supported development modes:

```text
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
```

Run only colocated foundation unit tests:

```text
zig build test-unit
```

Replay the permanent fuzz seeds:

```text
zig build fuzz
```

Run a bounded coverage-guided campaign of 1,000 generated inputs:

```text
zig build fuzz -Doptimize=ReleaseSafe --fuzz=1000
```

No bounded command claims to complete fuzzing. A discovered failure must be
preserved, minimized where practical, and committed to the corresponding
`test/corpus/` directory.

Zig 0.16.0's live fuzzer currently requires ReleaseSafe on the supported macOS
ARM64 toolchain because its Debug test runner fails to compile before the target
executes. Ordinary seed replay remains part of both Debug and ReleaseSafe tests.

## Current scope

Milestone 0 provides:

- explicit allocator and resource-limit plumbing;
- typed local identifiers and byte source spans;
- checked capacity arithmetic and transactional budgets;
- immutable structured diagnostics;
- exact scalar conformance fixtures; and
- Debug, ReleaseSafe, and bounded fuzz CI on the required native platforms.

Model parsing begins in Milestone 1. Numerical potential evaluation, the CLI,
the C ABI, and language bindings are not implemented yet.

The architecture and milestone contracts are documented in
[DESIGN.md](DESIGN.md) and
[Implementation Roadmap](docs/architecture/IMPLEMENTATION_ROADMAP.md).
