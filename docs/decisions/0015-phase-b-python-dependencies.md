# Decision 0015: Milestone 4 Phase B dependencies

Status: **proposed** — each dependency below awaits the repository owner's
explicit approval under [AGENTS.md](../../AGENTS.md). No Phase B work may begin
against an unapproved item.

## Context

[Implementation Roadmap §8](../architecture/IMPLEMENTATION_ROADMAP.md#8-milestone-4-experimental-public-client-surfaces)
Phase B needs three things Phaser does not have: a way to build a CPython
extension, a way to plot, and a way to execute a notebook in CI. Roadmap §17
still defers the last two, while §3 requires a notebook that cannot exist
without them. That tension is what this record resolves.

Each proposal below carries the fields
[Phaser Engineering Style](../../ENGINEERING_STYLE.md) requires. They are
independent: approving one does not approve another, and rejecting the plotting
dependency does not block the extension.

One point applies to all three. Nothing proposed here may be linked into,
imported by, or required for the Phaser library, the Zig core, the CLI, or any
test that asserts a numerical result. Every one of them is confined to the
Python binding, the notebook, and the CI tier that executes them. A contributor
who declines all three can still build, test, benchmark, and fuzz the whole of
Phaser.

## Proposal 1: CPython Limited API headers

**Recommended.** Without it there is no Python binding, and the roadmap requires
one.

- **Exact dependency and source.** The CPython C headers (`Python.h` and what it
  includes) from CPython 3.11 or later, compiled against with `Py_LIMITED_API`
  set to `0x030B0000`. Obtained from the interpreter already present on the
  build machine and on the GitHub-hosted runner images; no vendored copy.
- **Purpose.** To build the production Python extension in Zig against the
  Stable ABI, as
  [Language and Interoperability §8](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#8-python)
  specifies. 3.11 is the minimum because the complete `Py_buffer` structure and
  its operations entered the Stable ABI there, and the buffer protocol is how
  batch arrays cross without requiring NumPy's C API.
- **Internal alternative.** A pure-Python `ctypes` client over the C ABI needs
  no headers and no compilation. It is genuinely viable and already planned —
  but §8 designates it "an independent ABI conformance test... not the intended
  production Python binding," precisely because a binding that is also the
  oracle cannot check itself. Keeping `ctypes` as the independent consumer
  requires the extension to be something else.
- **Justification.** The Limited API is the narrowest possible form of this
  dependency: one ABI, stable across 3.11+, so a single built extension loads on
  every supported interpreter without a per-version build matrix.
- **License and maintenance risks.** PSF License Agreement, permissive and
  compatible with Phaser's MIT license. The Stable ABI is a compatibility
  promise CPython has kept; the main maintenance risk is that the Limited API
  omits conveniences, so the glue is more verbose than an unlimited-API binding.
  That is a code-volume cost, not a correctness one.
- **Runtime behavior relevant to Phaser.** Reference counting, the interpreter
  lock, and exception state. The extension releases the lock around expensive
  core work where safe, per §8. CPython's allocator is used only for Python
  objects; Phaser's numerical buffers stay under Phaser's contract.
- **Boundary.** `bindings/python/` only. No physics, no numerical evaluation, no
  canonicalization — §1 forbids adapters from reimplementing any of it.

## Proposal 2: Plotting — matplotlib

**Recommended with reservations**, stated below.

- **Exact dependency and source.** `matplotlib`, from PyPI, pinned to an exact
  version with hashes in a checked-in requirements file, in the manner
  `tools/ci/install_zig.sh` already pins the toolchain by SHA-256.
- **Purpose.** The notebook plots required by roadmap §3 and §8: tree,
  one-loop, and selected sum over a background interval.
- **Internal alternative.** Two exist. Phaser could emit SVG directly from Zig,
  which avoids the dependency but means writing and maintaining a plotting
  library to serve one notebook. Or the notebook could present tables and the
  committed `scan_*.tsv` files instead of plots — the data is already
  committed and already asserted. That second option is cheaper than it sounds
  and is the honest fallback if this proposal is rejected; what it loses is the
  visual inspection path that §8's exit criteria name explicitly.
- **Justification.** It is the de facto standard, every target reader already
  has it, and its output is deterministic enough to be reviewed.
- **License and maintenance risks.** Matplotlib's license is BSD-style and
  PSF-derived, compatible with MIT. **The reservation is the transitive tree**:
  matplotlib pulls NumPy, Pillow, fonttools, kiwisolver, contourpy, cycler,
  packaging, and dateutil. That is a large surface to accept for one notebook's
  figures, and it is the single biggest dependency expansion in Phaser's history
  to date. Pinning with hashes bounds the supply-chain risk but does not shrink
  the tree.
- **Runtime behavior relevant to Phaser.** None in the library. In the notebook,
  plots must be rendered from a fixed backend with no network access and no
  timestamps, per §3's determinism rules.
- **Boundary.** The notebook and its CI execution tier. Never imported by the
  Phaser package, the extension, the CLI, or any test asserting a numerical
  result. NumPy arrives transitively here and is permitted at that same
  boundary — it MUST NOT become a requirement of the binding, whose buffer
  protocol exists precisely to avoid it.

## Proposal 3: Notebook execution — nbclient and nbformat

**Recommended**, in the minimal form given here rather than the usual one.

- **Exact dependency and source.** `nbclient` and `nbformat` from PyPI, pinned
  to exact versions with hashes in the same requirements file, plus the
  `ipykernel` they need to start a kernel.
- **Purpose.** To execute the notebook in CI from a fresh kernel and fail the
  build if it errors, which is the only way to verify §8's exit criterion that
  "the notebook runs from a fresh kernel using public APIs only."
- **Internal alternative.** Do not execute notebooks in CI at all. Roadmap §3
  permits this — execution belongs to a CI tier "once approved notebook tooling
  exists" — and the roadmap separately requires the plotted data to be covered
  by machine tests, so the *numbers* would still be checked. What would go
  unchecked is the notebook itself: it would rot silently as the API evolved,
  and the exit criterion above would be unverifiable rather than merely unmet.
  A second alternative, maintaining a plain Python script that mirrors the
  notebook, checks the API path but not the notebook, and creates two artifacts
  that drift.
- **Justification.** `nbclient` is the execution engine underneath the larger
  tools, without their surface. The obvious alternatives are heavier for no
  gain here: the `jupyter` metapackage pulls a server, a web frontend, and
  their transitive trees for a job that needs none of them, and `papermill` adds
  parameterization Phaser does not use.
- **License and maintenance risks.** BSD 3-Clause, compatible with MIT. These
  packages track the Jupyter protocol and change more often than the others
  proposed here; pinning is what keeps that from reaching CI unannounced.
- **Runtime behavior relevant to Phaser.** Starts a subprocess kernel and
  executes cells in order. CI execution must set a bounded timeout and must not
  reach the network, per §3.
- **Boundary.** CI job steps and the notebook tier. No Phaser source imports
  either package.

## Deferred within this record

The committed-notebook-output and rendered-artifact policy that roadmap §17
also defers is **not** settled here. Whether a notebook keeps reviewed outputs in
version control is a reviewability and diff-noise question, independent of which
packages execute it, and it should be decided when there is a real notebook to
look at. Executing in CI does not require committed outputs, and committing
outputs does not require executing in CI.

## Consequences if approved

Phaser acquires a Python dependency set for the first time, and with it a
requirements file, a pinning discipline, and a CI tier that installs from PyPI.
The supply-chain surface grows from one pinned Zig archive to that plus a
hash-pinned Python environment. This is a real change in the project's posture
and should be recorded as one.

The library itself remains dependency-free. That property is worth protecting
explicitly, because it will be under continuous pressure once a Python
environment exists and importing something from it becomes easy.

## Consequences if rejected

Phase B contracts to what needs no dependency. The `ctypes` client can still
exercise the C ABI from Python, since it needs only the standard library. There
is no extension, no notebook, and roadmap §3's notebook requirement and §8's
notebook exit criteria must be amended rather than left unmet.

## Revisit when

Revisit proposal 2 if the transitive tree becomes a maintenance burden or if a
substantially smaller plotting option becomes standard among the target readers.
Revisit proposal 3 if notebook execution proves flaky in CI, which is a common
failure mode and would make the tier worse than useless. Revisit proposal 1 only
if the Limited API blocks something the binding genuinely needs — the escape
hatch is an unlimited-API build with a per-version matrix, and its cost is why
it is not proposed now.
