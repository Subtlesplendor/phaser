# Decision 0006: Tripwire as the targeted error-injection dependency

Status: accepted; approved by the repository owner

## Context

Phaser requires deterministic fault injection at subsystem ownership and
publication boundaries. Its allocator injection already exercises allocation
failure, but an allocator cannot precisely force a higher-level operation to
fail after a chosen sequence of successful steps. Those paths are where
`errdefer` cleanup is most important and least naturally reachable.

Tripwire is a small Zig module by Mitchell Hashimoto that adds named test-only
failure points. A test selects a point and error, calls production code, and
then verifies that the point was reached. The checks are no-ops outside Zig test
builds.

## Experiment

The experiment copied `src/tripwire.zig` from Ghostty commit
`2de5e7d38e1354759211722a8687c0815d2cf02c` into Phaser. The upstream
warning-producing self-test for an
intentionally untripped expectation is omitted so a successful Phaser test run
remains quiet. The implementation itself is unchanged.

The initial boundary is Typed Value IR lowering. Six named points inject
`error.OutOfMemory` before:

1. collecting roots;
2. marking reachable values;
3. classifying dependency stages;
4. assigning temporary slots;
5. emitting instructions; and
6. publishing the program.

One colocated test iterates over the complete fail-point enum. The ordinary test
allocator then detects any storage the existing rollback path fails to release.

### Result

The current lowering cleanup passes all six injected failures. The experiment
did not uncover an existing defect.

As a negative control, removing only `errdefer arena.deinit()` left all 123 test
assertions passing but made the Tripwire test report one leaked arena allocation
and fail the unit-test step. Restoring the cleanup restored a clean run. This
shows that the new test constrains error-only behavior that the prior lowering
tests did not.

As a production-cost control, ReleaseSafe artifacts were built once with the
Tripwire source checks and once with the import, fail-point module, checks, and
test removed. Both command-line executables were 919,128 bytes, their Mach-O
section sizes were identical, and their 622,412-byte `__text` sections were
byte-identical. The complete files were not byte-identical because source
changes alter build UUID and debug metadata. No Tripwire code was present in the
production machine-code section.

After permanent coverage expanded to compilation and binding, the ReleaseSafe
branch artifact was compared again with the rebased `main` baseline at
`9d5a2a4`. Every loadable section retained the same size, and the 622,412-byte
`__text` sections had the same SHA-256 digest. The complete executable differed
by 16 bytes because the source change alters non-executable build metadata.

## Decision

Adopt the vendored Tripwire module for targeted, representative transactional
boundaries where allocator failure or valid input cannot reliably reach the
cleanup state under test.

- **Dependency**: Ghostty's `src/tripwire.zig` at commit
  `2de5e7d38e1354759211722a8687c0815d2cf02c`.
- **License**: MIT. The complete notice and immutable source URL are retained in
  the vendored file.
- **Capability**: named deterministic error injection, verification that the
  selected point was reached, and delayed injection for repeated operations.
- **Boundary**: the immutable copy lives at
  `src/testing/vendor/tripwire.zig`. Phaser code imports only the owned wrapper
  at `src/testing/error_injection.zig`. Neither file is exported by
  `src/root.zig`, and no published interface exposes a Tripwire type.
- **Role**: test-only error-path verification. It is not a package-manager
  dependency and has no transitive dependencies.
- **Runtime behavior**: outside test builds, checks inline to a no-op and no
  Tripwire state is emitted. The Phaser-specific production artifact comparison
  confirms identical machine code.
- **Allocation, threading, and floating-point behavior**: the fixed enum map
  does not heap-allocate and performs no floating-point work. Its mutable state
  is process-global per declared fail-point module while testing, so a single
  module must not be configured concurrently.

Tripwire complements `std.testing.FailingAllocator`; it does not replace it.
Allocator campaigns remain the better tool for exhaustive allocation-site
coverage. Tripwire is preferable when a test needs a stable semantic checkpoint
or a non-allocation error after partial state exists.

## Alternative

Phaser could own a smaller fail-point helper using `builtin.is_test`, a nullable
selected enum, and an injected error. That would avoid vendored code, but Phaser
would need to implement and maintain expectation verification, delayed
injection, error-set constraints, reset behavior, and the compile-away contract.
Tripwire already packages and tests those details in one dependency-free file.

The standard library alone remains sufficient for allocation faults. It does not
provide named injection for other error paths.

## Risks and constraints

- Fail points are manually curated and can drift away from the cleanup boundary
  they name. They should sit immediately before the fallible operation whose
  predecessor state is under test.
- Tests must reset configured state even when an expectation fails. Phaser tests
  use a defensive `defer reset()` in addition to `end(.reset)`.
- A fail-point module is mutable test-global state. Future parallel execution of
  tests configuring the same module would require serialization or a different
  design.
- An injected error proves rollback from that program point; it does not prove
  the underlying operation can naturally return that exact error.
- The source is copied from an application repository rather than a versioned
  package. Updating it requires a new immutable commit, license review, diff,
  and renewed dependency approval.
- Named checks add source-level instrumentation to production functions even
  though they emit no production code. They should be limited to meaningful
  transactional boundaries rather than placed before every `try`.

## Consequences

The initial permanent coverage spans three nested transactional operations:
Typed Value IR lowering, kernel compilation, and parameter binding. Every
declared checkpoint is exercised under `std.testing.allocator`, so the test
runner turns missed rollback cleanup into a leak failure. Contributor guidance
in `ENGINEERING_STYLE.md` limits new checks to stable semantic transitions and
keeps allocation-site campaigns on `std.testing.FailingAllocator`.

## Revisit when

Revisit if Zig gains equivalent standard-library support, test execution
becomes parallel by default, the compile-away comparison stops holding for the
pinned compiler, or upstream Tripwire changes its state or dependency model.
