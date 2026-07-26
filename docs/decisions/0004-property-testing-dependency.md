# Decision 0004: Minish as the property-testing dependency

Status: accepted for Milestone 2, approved by the repository owner

## Context

Phaser's engineering style and verification policy both call for property-based
testing and name Minish as a candidate rather than an adopted dependency. Both
also require that property generators sit behind Phaser-owned interfaces whether
or not Minish is adopted.

Milestone 2 shipped with three of the properties the style guide already lists
unwritten, and two defects reached review that property or stateful testing
covers directly: an interning omission in the Typed Value IR, and a binding that
held a pointer to a kernel that callers naturally move.

## Decision

Phaser adopts Minish for property-based testing.

- **Dependency**: `minish`, version 0.3.0, from
  `https://github.com/CogitatorTech/minish`, pinned by tag and content hash in
  `build.zig.zon`.
- **License**: Apache-2.0.
- **Capability**: randomized case generation with automatic shrinking of a
  failing input to a minimal reproduction.
- **Boundary**: reachable only from `test/property/harness.zig`. Library code,
  the command-line client, examples, benchmarks, and every other test tier
  neither import nor link it. No published Phaser interface exposes a Minish
  type.
- **Role**: test-only. It is not in the numerical data plane, so its allocation,
  threading, and floating-point behavior cannot affect a scientific result.

The Phaser-owned harness enforces two policies Minish does not.

Seeds are always explicit. Minish derives a seed from address-space layout when
none is supplied, which would make a pull-request run nondeterministic. Every
budget in the harness carries fixed seeds and no path reaches Minish without one.

Failures report the configuration the workflow requires: property name, seed,
run budget, build mode, and target.

Property runs execute from a bounded campaign executable rather than the Zig test
runner, because Minish reports progress unconditionally on the standard streams
and the engineering style reserves those for the build and test runners'
coordination protocol.

## Alternatives

`std.testing.Smith`, already used by every fuzz target, generates structured
input from the pinned toolchain with no dependency at all. It was retained for
fuzzing and rejected as the property mechanism because it provides no shrinking:
a failure arriving as a forty-eight step generated script is materially harder to
diagnose than its minimal form, and the workflow requires minimized failures to
become permanent regression fixtures.

A Phaser-owned shrinking implementation was rejected as a poor trade. Shrinking
is a general testing facility with no scientific content, so writing and
maintaining one would spend effort where Phaser has no particular advantage.

## Consequences

Property tests are cheap enough to run on every change, unlike a fuzz campaign,
so `zig build test` includes them at a bounded budget of three fixed seeds and
one hundred runs per property.

The first metamorphic property adopted under this decision immediately showed
that relabelling model fields preserves results only to floating-point rounding,
not bitwise, because the transformation changes canonical accumulation order.
That is correct behavior, and it makes the missing declared
numerical-comparison policy a concrete gap rather than a theoretical one.

## Revisit when

Revisit this decision if Minish stops being maintained, if its generator or
shrinking contract changes in a way the harness cannot absorb, if it acquires
transitive dependencies, or if the pinned toolchain gains equivalent shrinking
and the dependency stops paying for itself.
