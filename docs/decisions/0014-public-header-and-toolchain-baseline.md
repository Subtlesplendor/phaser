# Decision 0014: Public header and toolchain baseline

Status: accepted for Milestone 4; approved by the repository owner, including
the dependency proposal below

Amended after acceptance: the platform matrix now claims Windows as a required
native platform. The original text did not, and the reasoning that replaced it
is recorded in "Linkage and platform matrix" and "Consequences" below.

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
checked-in output, CI agreement check — but permitting is not requiring, and no
generator exists. A hand-written header is reviewed like the contract it is,
carries the
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
- macOS ARM64 — required;
- Windows x86-64 — required.

**Windows is claimed by Milestone 4 as a required native platform.** This is the
explicit answer
[Development Workflow §10](../../DEVELOPMENT_WORKFLOW.md#10-initial-native-platform-policy)
asks for, and it takes that section at its word: Windows "becomes a required
native test platform when Phaser claims Windows support, expected no later than
the public C ABI and shared-library work." This is that work. Deferring would
mean designing the export, packaging, and symbol-visibility story twice — once
for ELF and Mach-O now, once for PE later — and discovering Windows-specific
ABI constraints after the header had already been declared stable enough to
build clients on.

Claiming it commits Milestone 4 to:

- **A third native test tier.** `windows-2025`, running the same bounded
  suites the other two platforms run, per §10's rule that cross-compilation
  checks portability but does not replace native execution.
- **A third compiler family.** MSVC (`cl.exe`) is the compiler Windows C clients
  actually use, and it is preinstalled on the runner image. The C conformance
  client and the header's C and C++ compile checks run under it. Phaser's own
  code continues to build with the pinned Zig toolchain targeting
  `x86_64-windows-msvc`.
- **A `__declspec` export path.** The single export macro resolves to
  `__declspec(dllexport)` when building the shared library and
  `__declspec(dllimport)` when consuming it, and nothing for static linkage.
  Unlike ELF and Mach-O, the import side is not optional on Windows, so the
  macro must distinguish building from consuming — a distinction the ELF-only
  form would not have needed.
- **DLL packaging.** A shared build produces `phaser.dll` and its import
  library; both are consumed by the conformance client. The import library is
  also `phaser.lib`, which collides with the static library's name, so the
  static library is `phaser_static.lib` on Windows only. Without the rename the
  second artifact installed silently replaces the first and static linkage has
  nothing to link against. ELF and Mach-O have no such collision.
- **A second symbol-allow-list mechanism.** PE exports are enumerated with
  `dumpbin /exports` rather than `nm`, so the allow-list check has two
  implementations that must agree on the same documented public set.

Nothing in the header assumes ELF, Mach-O, or PE semantics beyond the export
macro.

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
  against the documented public set, through `nm` on ELF and Mach-O and
  `dumpbin /exports` on PE. A newly exported internal symbol fails the check;
  the point is that the ABI surface cannot grow by accident. The two
  implementations must agree on one documented set, not maintain two.
- **Both linkages, all three platforms.** The C conformance client is built and
  run against the static and the shared library on Linux x86-64, macOS ARM64,
  and Windows x86-64. The Windows static link uses `lld-link` rather than
  `link.exe`, which cannot consume the archive; MSVC still compiles the header
  and the client, so the independent-compiler requirement is met by the front
  end that reads them. The limitation and its two failing configurations are
  recorded in
  [Language and Interoperability §4.1](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#41-linking-statically-on-windows),
  where a Windows consumer will look for it.
- **Layout parity across ABIs.** The layout tests run on all three platforms
  rather than one, because the Windows x64 calling convention and structure
  packing rules are where a divergence would appear if one exists.

### Dependency proposal

Satisfying "independent C and C++ compilers" requires compilers that are not
Zig. This is a system and test-tier dependency and therefore requires the
repository owner's explicit permission under
[AGENTS.md](../../AGENTS.md). **The repository owner approved this proposal as
stated.**

- **Exact dependency and source.** GCC and Clang as preinstalled on the
  `ubuntu-24.04` GitHub-hosted runner image, Apple Clang as preinstalled on
  `macos-15`, and MSVC (`cl.exe`) with `dumpbin` as preinstalled on
  `windows-2025`. No package is installed, downloaded, pinned, or vendored;
  the proposal is to *invoke* compilers the runner images already contain.
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
- **License and maintenance risks.** No compiler is linked into or distributed
  with Phaser; they are build-time verification tools, so their licenses do not
  attach to any Phaser artifact. The maintenance risk is runner image drift: a
  future image could change default compiler versions and surface a new warning.
  Mitigated by recording the versions in the job log and treating a diagnostic
  change as an ordinary CI failure to triage. MSVC carries the additional risk
  that it is neither redistributable nor available outside Windows, so the
  Windows checks cannot be reproduced on a contributor's Linux or macOS machine.
- **Runtime behavior relevant to Phaser.** None. Nothing produced by these
  compilers ships, and no Phaser numerical result depends on them.
- **Boundary.** Confined to CI job steps and the `examples/` C client. No Zig
  source, no `build.zig` product, and no distributed artifact depends on any of
  these compilers being present. A contributor without them can still build,
  test, and run everything except these checks.

## Alternatives

**Generating `phaser.h` from Zig.** Rejected for version 0 as described above:
it adds a tool to trust in exchange for removing a file to review, and the
agreement check it would need is most of the work of the layout and constant
tests that are wanted regardless.

**C99 baseline.** Rejected for weaker static assertions only. Reconsider if a
supported consumer turns out to be C99-bound.

**Deferring Windows to a later milestone.** This was the original decision and
was reversed. Deferral is cheaper in Milestone 4 and more expensive afterwards:
the export macro, the packaging story, and the symbol-visibility check would
each be designed for ELF and Mach-O first and revised for PE later, and any
Windows-specific ABI constraint would surface after clients had been built
against a header presented as settled. The reversal accepts a larger Phase A in
exchange for designing the boundary once.

**Windows as a compile-only target.** Rejected because
[Development Workflow §10](../../DEVELOPMENT_WORKFLOW.md#10-initial-native-platform-policy)
states that cross-compilation "checks portability but does not replace native
execution," and that every claimed supported platform has a documented native
test tier. A compile-only Windows target would not be claimed support, so it
would not discharge §10 for this milestone — it would only postpone it while
still paying part of the cost.

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

Claiming Windows makes Phase A materially larger, and the cost should not be
understated. It adds a third native CI tier to every per-change run, a compiler
family whose diagnostics and structure-packing rules nobody here has yet
exercised, an export macro with a build/consume distinction the other two
platforms do not need, and a second symbol-enumeration path. It also makes one
class of failure unreproducible locally on the maintainers' machines, since MSVC
runs only on Windows. Milestone 4's schedule absorbs all of that.

What it buys is that the boundary is designed once. Every one of those items
would otherwise be built for ELF and Mach-O in Milestone 4 and revised for PE
later, against a header that clients had already been told was stable enough to
build on. The reversal trades a larger Phase A for not paying that revision.

Windows users get Milestone 4 support on the same terms as Linux and macOS
users: experimental ABI version 0, natively tested.

The layout, constant, and symbol tests are new machinery with no precedent in
the repository. They are cheap to write and are the only evidence that the
header and the implementation describe the same ABI.

## Revisit when

Revisit the platform matrix when the C++ milestone adds its own compiler
requirements, or if the Windows tier's cost in per-change CI time proves
disproportionate to the defects it catches — that is a measurement to take
after a few months of runs, not a reason to reverse again on prediction.
Revisit the language baseline if a consumer is C99-bound or if the C++ wrapper
wants a newer standard than the header permits. Revisit the hand-written-header choice if the
public surface grows past what stays consistent under review, at which point
generation buys more than it costs.
