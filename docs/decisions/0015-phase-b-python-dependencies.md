# Decision 0015: Milestone 4 Phase B dependencies

Status: accepted for Milestone 4; all three dependencies approved by the
repository owner under [AGENTS.md](../../AGENTS.md)

Each was proposed and approved separately. The approval covers the exact
sources, versions, and boundaries recorded below and nothing wider: changing a
source, a version, an enabled feature, a transitive set, or a role requires
renewed permission, per [AGENTS.md](../../AGENTS.md).

## Context

[Implementation Roadmap §8](../architecture/IMPLEMENTATION_ROADMAP.md#8-milestone-4-experimental-public-client-surfaces)
Phase B needs three things Phaser did not have: a way to build a CPython
extension, a way to plot, and a way to execute a notebook in CI. Roadmap §17
deferred the plotting and notebook-execution choices, while §3 required a
notebook that cannot exist without them. That tension is what this record
resolves.

Each proposal below carries the fields
[Phaser Engineering Style](../../ENGINEERING_STYLE.md) requires. They were kept
independent so that approving one did not approve another; all three were
approved, and the "Recommended" notes are retained as the reasoning that was
put to the owner rather than rewritten after the fact.

One constraint applies to all three and is part of what was approved. None of
them may be linked into, imported by, or required for the Phaser library, the
Zig core, the CLI, or any test that asserts a numerical result. Each is confined
to the Python binding, the notebook, and the CI tier that executes them. A
contributor who installs none of them can still build, test, benchmark, and fuzz
the whole of Phaser — that is the property these boundaries exist to preserve,
and a change that breaks it is a dependency change requiring its own approval.

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

**Narrowed in implementation.** What is actually used is less than this proposal
approved. The extension declares the Limited API subset it needs rather than
translating `Python.h`, so the headers are not a build input on any platform;
what remains of this dependency is the Stable ABI stub `python3.lib` on Windows
and an interpreter to run against. The reason is recorded in
[Language and Interoperability §8.6](../architecture/LANGUAGE_AND_INTEROPERABILITY.md#86-build-and-platform-status).
Using less than was approved needs no further permission, but it is recorded
here so this record continues to describe the dependency Phaser actually has.

## Proposal 2: Plotting — matplotlib

**Recommended with reservations**, stated below.

- **Exact dependency and source.** `matplotlib`, from PyPI, pinned to an exact
  version with hashes in `tools/ci/python-requirements.txt`, in the manner
  `tools/ci/install_zig.sh` already pins the toolchain by SHA-256. That file is
  the Python counterpart of `build.zig.zon`: every entry names the decision that
  approved it, and an unpinned or unhashed entry is a defect.
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
  to exact versions with hashes in `tools/ci/python-requirements.txt`, plus the
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

## Transitive set, recorded in implementation

This record enumerated matplotlib's transitive tree when it was written and did
not enumerate the others'. The four approved packages resolve to **47** on Linux
x86-64 and CPython 3.12, and since this record states that "a transitive set"
requires renewed permission, the resolved set is written down here rather than
left to be discovered in a lock file. `tools/ci/python-requirements.txt` carries
the same list with hashes and is the operative artifact; this table is what was
put to the owner and approved.

| Package | Version | | Package | Version |
|---|---|---|---|---|
| `appnope` (Darwin only) | 0.1.4 | | `packaging` | 26.2 |
| `asttokens` | 3.0.2 | | `parso` | 0.8.7 |
| `attrs` | 26.1.0 | | `pexpect` | 4.9.0 |
| `comm` | 0.2.3 | | `pillow` | 12.2.0 |
| `contourpy` | 1.3.2 | | `platformdirs` | 4.11.0 |
| `cycler` | 0.12.1 | | `prompt-toolkit` | 3.0.53 |
| `debugpy` | 1.8.21 | | `psutil` | 7.2.2 |
| `decorator` | 5.3.1 | | `ptyprocess` | 0.7.0 |
| `executing` | 2.2.1 | | `pure-eval` | 0.2.3 |
| `fastjsonschema` | 2.22.1 | | `pygments` | 2.20.0 |
| `fonttools` | 4.63.0 | | `pyparsing` | 3.3.2 |
| **`ipykernel`** | 7.3.0 | | `python-dateutil` | 2.9.0.post0 |
| `ipython` | 9.15.0 | | `pyzmq` | 26.4.0 |
| `ipython-pygments-lexers` | 1.1.1 | | `referencing` | 0.37.0 |
| `jedi` | 0.20.0 | | `rpds-py` | 2026.6.3 |
| `jsonschema` | 4.26.0 | | `six` | 1.17.0 |
| `jsonschema-specifications` | 2025.9.1 | | `stack-data` | 0.6.3 |
| `jupyter-client` | 8.9.1 | | `tornado` | 6.5.7 |
| `jupyter-core` | 5.9.1 | | `traitlets` | 5.15.1 |
| `kiwisolver` | 1.5.0 | | `typing-extensions` | 4.16.0 |
| **`matplotlib`** | 3.11.1 | | `wcwidth` | 0.8.2 |
| `matplotlib-inline` | 0.2.2 | | **`nbclient`** | 0.11.0 |
| `nest-asyncio2` | 1.7.2 | | **`nbformat`** | 5.10.4 |
| `numpy` | 2.2.6 | | | |

The four in bold are the ones this record approved by name. The rest arrive
through them.

### One entry that needed a decision of its own

`nest-asyncio2` is not the well-known `nest_asyncio`. It is a fork of it,
published from `github.com/Chaoses-Ib/nest-asyncio2`, which retains the original
author's name and email in its package metadata while being maintained by
someone else. `ipykernel` 7 depends on it; `ipykernel` 6.31 depends on the
original `nest_asyncio` instead, and the two resolutions are otherwise identical
package for package.

It was checked rather than waved through, because a package named after another
with a digit appended is also what a typosquat looks like. What it actually is:
a self-declared fork of an unmaintained project, BSD licensed, adding CPython
3.12 and 3.14 support, and depended on by `ipython/ipykernel` upstream rather
than pulled in by Phaser's own resolution.

The owner chose `ipykernel` 7 knowing this. The trade is one additional
maintainer to trust against staying on a version line whose own dependency is
unmaintained. Revisit if the fork is abandoned or if `ipykernel` changes course
again.

## Deferred within this record, and since settled

The committed-notebook-output and rendered-artifact policy that roadmap §17 also
defers was **not** settled when this record was written. Whether a notebook keeps
reviewed outputs in version control is a reviewability and diff-noise question,
independent of which packages execute it, and it was left until there was a real
notebook to look at. Executing in CI does not require committed outputs, and
committing outputs does not require executing in CI.

There is now a real notebook, and the repository owner has settled both open
points.

**Notebook outputs are not versioned.** A committed notebook carries no stored
outputs and no execution counts. A reader runs it to see the figures and the
printed numbers. Roadmap §3's allowance that "short canonical demonstration
notebooks MAY retain reviewed outputs" is therefore declined for Phaser rather
than left open.

What this costs is real and is accepted: a notebook opened on a repository
browser shows source without figures, and a reviewer who wants to see a plot
must run it. What it buys is that the history carries no base64 images, no
diffs that change on every execution, and no rendered output that can disagree
with the code above it — an output committed once and not re-run is a claim
nobody is checking.

The policy needs a guard, because a frontend stores outputs on save.
`tools/ci/check_notebook_outputs.py` fails the repository tier if any survive,
and `tools/ci/clear_notebook_outputs.py` removes them. Both are standard library
only, so neither depends on anything this record approved.

**The notebook tier runs on Linux x86-64 only.** The three approved packages are
installed on that platform and nowhere else. Every number the notebook plots is
already asserted bitwise on all three platforms by tests that import none of
them, so executing the notebook on macOS and Windows would establish that
matplotlib renders rather than that Phaser computes, at the cost of pinning
wheels for three platforms and three interpreter versions.

The limit is worth stating plainly: "the notebook runs from a fresh kernel using
public APIs only" is verified on one platform. A Python-level portability defect
that the machine tests do not already cover would not be caught by this tier.

## Consequences

Phaser acquires a Python dependency set for the first time, and with it
`tools/ci/python-requirements.txt`, a pinning discipline, and a CI tier that
installs from PyPI. The supply-chain surface grows from one pinned Zig archive
and two Zig packages to that plus a hash-pinned Python environment. This is a
real change in the project's posture and is recorded as one rather than
absorbed quietly.

[Development Workflow §9](../../DEVELOPMENT_WORKFLOW.md#9-toolchain-ci-and-security)
requires that "test execution is offline after explicitly approved and pinned
tools have been obtained." The Python environment is obtained in an explicit
install step and nothing after it reaches the network — notebook execution in
particular must not, which §3 of the roadmap already requires of every notebook.

The library itself remains dependency-free. That property is worth protecting
explicitly, because it will be under continuous pressure once a Python
environment exists and importing something from it becomes easy. The boundary
statements in each proposal above are what enforce it, and the reviewer of any
future change that crosses one should treat it as a dependency change.

Approving all three means Phase B is unblocked and Milestone 4's prerequisites
are fully discharged. Nothing in Milestone 4 now waits on a decision.

## What rejection would have meant

Recorded because it was a live option and bounds what is being bought.

Phase B would have contracted to what needs no dependency. The `ctypes` client
would still exercise the C ABI from Python, since it needs only the standard
library. There would be no extension and no notebook, and roadmap §3's notebook
requirement and §8's notebook exit criteria would have had to be amended rather
than left unmet.

## Revisit when

Revisit proposal 2 if the transitive tree becomes a maintenance burden or if a
substantially smaller plotting option becomes standard among the target readers.
Revisit proposal 3 if notebook execution proves flaky in CI, which is a common
failure mode and would make the tier worse than useless. Revisit proposal 1 only
if the Limited API blocks something the binding genuinely needs — the escape
hatch is an unlimited-API build with a per-version matrix, and its cost is why
it is not proposed now.
