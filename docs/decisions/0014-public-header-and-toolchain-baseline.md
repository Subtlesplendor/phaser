# Decision 0014: Public header and toolchain baseline

Status: accepted for Milestone 4; the dependency proposal below awaits the
repository owner's approval

## Context

[Decision 0013](0013-c-abi-v0-surface.md) fixes what crosses the C boundary.
This decision fixes the artifact that declares it and the toolchains that must
agree about it.

Three questions were left open by
[Language and Interoperability §12](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#12-deferred-decisions)
and are now blocking: the minimum C and C++ language versions, the
static/shared linkage support matrix, and which compilers verify them.
[§11](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#11-conformance-requirements)
already requires that header tests "compile with independent C and C++ compilers
in CI, not only through Zig's bundled C compiler," which the repository cannot
currently satisfy — CI installs the pinned Zig toolchain and nothing else.

A fourth question is forced by
[Development Workflow §10](../../DEVELOPMENT_WORKFLOW.md#10-initial-native-platform-policy),
which says Windows "becomes a required native test platform when Phaser claims
Windows support, expected no later than the public C ABI and shared-library
work." Milestone 4 is that work. Whether Phaser claims Windows has to be
answered here rather than left to be inferred.

## Decision

### The header is authoritative and hand-written

`include/phaser.h` is written and reviewed as source, not generated.
[§4](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#4-distributed-components)
permits a generated header under conditions — deterministic generator,
checked-in output, CI agreement check — but permitting is not requiring, and
no generator
exists. A hand-written header is reviewed like the contract it is, carries the
documentation comments that make the ownership and nullability rules readable at
the point of use, and needs no second tool to be trusted.

What CI checks is the reverse direction: that the Zig implementation matches the
header, through layout, constant, and symbol tests described below.

### Language baseline

The minimum is **C11** for `phaser.h` as a C header, and **C++17** for the same
header included from C++.

C11 gives `<stdint.h>` fixed-width types, `<stdalign.h>`, and `_Static_assert`,
which the extensible-structure rule of
[§5.5](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#55-extensible-structures)
wants for its `struct_size`/`abi_version` prologue. It is old enough that no
supported compiler lacks it. C99 was considered and rejected only because
`_Static_assert` would have to be emulated with an array-size trick that
produces worse diagnostics; nothing else in the header needs C11.

C++17 is chosen as the *include* baseline now so the later C++ milestone does
not discover that `phaser.h` requires something newer than its wrapper targets.
Nothing in version 0 uses a C++17 feature; the number is a ceiling on what the
header may assume, not a floor it exploits.

The header uses `extern "C"` guards, includes everything needed to interpret its
declarations, and uses one export macro for symbol visibility. It uses no
compiler extension that is not behind a portable feature check.

### Linkage and platform matrix

Both static and shared linkage are supported and both are tested, on:

- Linux x86-64 — primary, required;
- macOS ARM64 — required.

**Windows is not claimed by Milestone 4.** This is the explicit answer
[Development Workflow §10](../../DEVELOPMENT_WORKFLOW.md#10-initial-native-platform-policy)
asks for. Claiming it would add a third native test tier, a third compiler
family, a `__declspec` export path, and a DLL packaging story to a milestone
whose purpose is to exercise the boundary at all. The export macro is written so
that adding `__declspec(dllexport)` later is a definition change rather than a
redesign, and no other part of the header assumes ELF or Mach-O semantics.

### What CI must check

Beyond compiling the header, the per-change tier gains:

- **Layout tests.** Size, alignment, and every field offset of every public
  structure, asserted against expected values for the target rather than against
  the Zig type's own `@sizeOf` — an assertion that a type equals itself proves
  nothing.
- **Constant tests.** Every enumerator's numeric value, including the two status
  spaces of [Decision 0013](0013-c-abi-v0-surface.md), asserted against the
  internal enums they mirror so a drift fails at build time.
- **Symbol allow-list.** The exported symbols of the shared library are compared
  against the documented public set. A newly exported internal symbol fails the
  check; the point is that the ABI surface cannot grow by accident.
- **Both linkages.** The C conformance client is built and run against the
  static and the shared library.

### Dependency proposal

Satisfying "independent C and C++ compilers" requires compilers that are not
Zig. This is a system and test-tier dependency and therefore requires the
repository owner's explicit permission under
[AGENTS.md](../../AGENTS.md). The proposal:

- **Exact dependency and source.** GCC and Clang as preinstalled on the
  `ubuntu-24.04` GitHub-hosted runner image, and Apple Clang as preinstalled on
  `macos-15`. No package is installed, downloaded, pinned, or vendored; the
  proposal is to *invoke* compilers the runner image already contains.
- **Purpose.** To compile `include/phaser.h` and the C conformance client
  through a toolchain that shares no front end with the implementation, as
  [§11](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#11-conformance-requirements)
  requires.
- **Internal alternative.** Zig's bundled Clang can compile C and C++. It is not
  independent: a header that is malformed in a way Zig's own front end tolerates
  would compile in both places. That is the specific failure the requirement
  exists to catch, so the internal alternative does not satisfy it.
- **Justification.** The header is the ABI contract. A contract verified only by
  the party that wrote it is not verified.
- **License and maintenance risks.** Neither compiler is linked into or
  distributed with Phaser; they are build-time verification tools, so their
  licenses do not attach to any Phaser artifact. The maintenance risk is runner
  image drift — a future image could change default compiler versions and
  surface a new warning. Mitigated by recording the versions in the job log and
  treating a diagnostic change as an ordinary CI failure to triage.
- **Runtime behavior relevant to Phaser.** None. Nothing produced by these
  compilers ships, and no Phaser numerical result depends on them.
- **Boundary.** Confined to CI job steps and the `examples/` C client. No Zig
  source, no `build.zig` product, and no distributed artifact depends on either
  compiler being present. A contributor without them can still build, test, and
  run everything except this one check.

Until this is approved, the header check runs through Zig's bundled compiler
only, and the Milestone 4 Phase A gate cannot close, because
[§11](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#11-conformance-requirements)'s
requirement would be unmet.

## Alternatives

**Generating `phaser.h` from Zig.** Rejected for version 0 as described above:
it adds a tool to trust in exchange for removing a file to review, and the
agreement check it would need is most of the work of the layout and constant
tests that are wanted regardless.

**C99 baseline.** Rejected for weaker static assertions only. Reconsider if a
supported consumer turns out to be C99-bound.

**Claiming Windows now.** Rejected as scope. It is a defensible reading of
[Development Workflow §10](../../DEVELOPMENT_WORKFLOW.md#10-initial-native-platform-policy)
that the C ABI milestone should carry it, which is exactly why the answer is
written down rather than assumed.

**Shared-library-only or static-only support.** Rejected because
[§4](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#4-distributed-components)
states the same header and behavioral contract apply to both, and an untested
linkage mode is an unsupported one.

**Skipping the symbol allow-list.** Rejected: without it, ABI version 0's
surface is whatever happened to be exported, and version 1 would be declared
over a boundary nobody chose.

## Consequences

Phaser gains a CI dependency on runner-provided compilers, in exchange for the
header being checked by something that did not write it. The dependency is
unusually cheap — nothing is installed — but it is still a dependency and is
recorded as one.

Windows users get no Milestone 4 support and no promise of it. The roadmap
should not imply otherwise.

The layout, constant, and symbol tests are new machinery with no precedent in
the repository. They are cheap to write and are the only evidence that the
header and the implementation describe the same ABI.

## Revisit when

Revisit the platform matrix when a user needs Windows or when the C++ milestone
adds its own compiler requirements. Revisit the language baseline if a consumer
is C99-bound or if the C++ wrapper wants a newer standard than the header
permits. Revisit the hand-written-header choice if the public surface grows past
what stays consistent under review, at which point generation buys more than it
costs.
