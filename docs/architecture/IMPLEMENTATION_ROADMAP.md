# Implementation Roadmap

Status: provisional roadmap

This document organizes Phaser implementation into independently verifiable
vertical milestones. It refines section 23 of [DESIGN.md](../../DESIGN.md).

The roadmap records dependency order and delivery criteria. It is not a schedule,
release promise, or authorization to begin implementation before the relevant
design has been reviewed.

## 1. Roadmap principles

- Deliver end-to-end scientific capabilities rather than completing every
  architectural layer horizontally.
- Introduce the simplest reference execution path early.
- Expand physical scope only after the preceding slice is independently tested.
- Keep unsupported sectors explicit; never substitute a narrower calculation.
- Treat tests, fuzzing, examples, documentation, and resource bounds as milestone
  exit criteria.
- Exercise public language boundaries while their ABI remains experimental.
- Prioritize dimensional reduction and three-dimensional EFT calculations over
  reproducing a large conventional four-dimensional thermal framework.
- Elaborate distant milestones only when preceding implementation evidence makes
  their boundaries clearer.

## 2. Common milestone gate

Every completed milestone requires, as applicable:

- a reviewed specification for the implemented capability;
- an explicit supported domain and explicit unsupported cases;
- one end-to-end public example;
- independent reference or conformance evidence;
- unit, property, differential, and fuzz coverage appropriate to new boundaries;
- exact capacity tests and representative allocation-failure tests at ownership
  and publication boundaries;
- deterministic fingerprints, serialization, diagnostics, and output where
  promised;
- Debug, ReleaseSafe, and relevant ReleaseFast comparison;
- representative performance measurements for hot paths;
- updated user and developer documentation; and
- no known correctness debt hidden behind a later milestone.

The verification policy follows
[Verification and Testing](VERIFICATION_AND_TESTING.md).

## 3. Research notebooks

Jupyter notebooks are public examples and human validation aids. They complement
machine tests; plots and rendered equations are not sole scientific oracles.

Milestone 4 MUST deliver the first Phaser notebook using the public Python API.
A later milestone adds or extends a notebook only when visual or interactive
inspection materially improves validation or user understanding. A new notebook
is not an automatic milestone gate when an existing example and machine
conformance suite communicate the capability more clearly.

Notebooks SHOULD demonstrate, where relevant:

- loading a model and calculation;
- inspecting scientific metadata and contribution provenance;
- rendering equations through the LaTeX/MathJax path;
- constructing bindings for multiple parameter points;
- scalar and batch evaluation;
- gradients and Hessians;
- plotting potentials or other calculated quantities;
- comparison with an exact or independent reference;
- scale, temperature, or gauge-parameter scans; and
- visible diagnostics for an intentionally unsupported or invalid case.

Notebook plots expose underlying numerical arrays and comparison data so the
same quantities can be asserted in machine tests.

Every maintained notebook:

- uses only public Phaser interfaces;
- identifies its model, conventions, calculation, and parameter point;
- runs from a fresh kernel without hidden execution-order state;
- uses fixed seeds where randomness is present;
- requires no network access;
- has a bounded representative runtime;
- avoids timestamps and other nondeterministic output;
- states which visual or numerical features the researcher should inspect; and
- is executed in an appropriate CI or scheduled validation tier once approved
  notebook tooling exists.

Short canonical demonstration notebooks MAY retain reviewed outputs so equations
and plots are visible when opened. The policy for committed outputs, deterministic
execution, and rendered derivatives remains to be selected before notebooks are
added.

Neither a plotting package nor notebook-execution package is selected by this
roadmap. Adding one is subject to the external-dependency proposal and explicit
approval required by [Phaser Engineering Style](../../ENGINEERING_STYLE.md).

Before Milestone 4, examples SHOULD produce the same models, reference data, and
LaTeX fragments that the first notebook will later consume. A Python notebook is
not required before a supported Python API exists.

## 4. Milestone 0: design baseline and implementation substrate

### Objective

Establish only the repository and correctness substrate required for the first
scalar vertical slice.

### Scope

- Maintain the design and engineering specifications.
- Resolve scientific conventions required by Milestones 1 through 3.
- Pin the Zig toolchain.
- Establish the build and test entry points when real implementation exists.
- Implement foundational diagnostics, source spans, typed IDs, checked capacity
  arithmetic, and explicit allocator plumbing as needed.
- Establish allocation-failure injection and initial fuzz-target infrastructure.
- Select the first exact conformance fixtures.

The shared implementation substrate is specified in
[Foundation Types and Failure Reporting](FOUNDATION.md). The initial model
parameter/version and scalar one-loop conventions are specified in
[QFT Model Format: Parameters and Source Versioning](../formats/QFT_MODEL_PARAMETERS.md)
and
[Zero-Temperature One-Loop Scalar Effective Potential](../calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).

### Exit criteria

- The repository builds and runs meaningful bounded tests in Debug and
  ReleaseSafe.
- Failures at external boundaries use structured diagnostics.
- Memory and test foundations do not require an external dependency.
- No empty subsystem scaffolding is created merely to mirror the long-term tree.

## 5. Milestone 1: scalar model and expression foundation

Status: implemented

### Objective

Parse and canonicalize real scalar theories with exact structural expressions.

### Scope

- Exact integers, rationals, and symbolic constants.
- Source-expression parsing, resolution, and normalization.
- Parameters, dimensions, and dependencies.
- Real scalar fields.
- Scalar quadratic, cubic, and quartic tensors.
- The required Typed Value IR subset.
- Canonical Model IR and deterministic model fingerprint.
- Semantic validation and deterministic diagnostics.

Field, parameter, and index counts remain runtime values.

### Exit criteria

- The complete model-parameter declaration schema and source-schema versioning
  policy are reviewed.
- The model and expression parsers enforce documented numerical resource limits.
- Real \(\phi^4\) and multi-scalar models parse and validate.
- Invalid and targeted near-valid models produce structured diagnostics.
- Sparse and dense scalar tensor references agree.
- Canonicalization is deterministic and idempotent.
- Parser, expression, and scalar-model fuzz targets are active.
- Unsupported field sectors and calculations fail explicitly.

### Examples

Provide minimal model JSON and inspection output for \(\phi^4\) and a
multi-scalar model. Preserve these fixtures for the later notebook.

## 6. Milestone 2: tree-level scalar vertical slice

Status: implemented

### Objective

Deliver the first complete model-to-symbolic-and-numerical calculation.

### Scope

```text
model JSON
    |
canonical scalar model
    |
calculation request + background slice
    |
classical-potential artifact
    |
Typed Value IR
    +--------> Phaser and LaTeX rendering
    |
safe numerical kernel
    |
binding + scalar/batch evaluation
```

Implement:

- a minimal calculation request;
- selected background components;
- a classical-potential artifact;
- value, gradient, and Hessian support for the tree potential;
- immutable parameter binding; binding may allocate and must not repeat
  structural derivation;
- scalar and batch evaluation;
- exact workspace queries;
- a safe reference kernel interpreter;
- human-readable Phaser and MathJax-compatible LaTeX export; and
- a minimal Zig CLI.

The request schema is specified in
[Effective-Potential Calculation Request](../formats/EFFECTIVE_POTENTIAL_REQUEST.md),
the derived artifact in
[Classical Scalar Potential](../calculations/CLASSICAL_SCALAR_POTENTIAL.md), and
the reference backend's opcodes in
[Kernel Instruction Set](KERNEL_INSTRUCTION_SET.md). The Typed Value IR
boundary and the derivative method are recorded in
[Decision 0002](../decisions/0002-typed-value-ir-scope.md) and
[Decision 0003](../decisions/0003-derivative-method.md).

### Exit criteria

- \(\phi^4\) and multi-scalar examples run end to end.
- Fresh and rebound bindings agree.
- Scalar, batch-of-one, arbitrary batch partitions, and permutations agree.
- Symbolic derivatives and direct polynomial references agree.
- Kernel evaluation is allocation-free at exact workspace boundaries.
- Exported equations preserve exact coefficients and background embedding.

### Examples

Provide CLI workflows that emit equations and sampled potential data. These form
the data and expected behavior for the first Python notebook in Milestone 4.

The delivered workflows are `phaser inspect`, `phaser export`, and
`phaser evaluate`, with committed inputs and golden outputs under
`examples/phi4/` and `examples/multi_scalar/`.

### Gate accounting

Each exit criterion and the evidence that closes it:

| Criterion | Evidence |
|---|---|
| \(\phi^4\) and multi-scalar examples run end to end | `examples/*/`, golden equations and sampled data, compared byte for byte |
| Fresh and rebound bindings agree | `test/conformance/parameter_binding.zig` |
| Scalar, batch-of-one, arbitrary batch partitions, and permutations agree | `test/conformance/potential_kernel.zig`, every prefix/suffix split of a seven-point batch plus a permutation |
| Symbolic derivatives and direct polynomial references agree | `test/conformance/classical_scalar.zig` against transcribed fixture identities, and `test/differential/finite_differences.zig` against central differences |
| Kernel evaluation is allocation-free at exact workspace boundaries | `evaluate` takes no allocator; workspace sufficient at exactly the queried size and rejected one byte below |
| Exported equations preserve exact coefficients and background embedding | `test/integration/symbolic_export.zig` and the committed golden equations |

Common-gate items: specifications reviewed in the Milestone 2 documentation
change; supported and unsupported cases stated in each new specification;
`zig build bench` provides the representative measurements; Debug, ReleaseSafe,
and ReleaseFast all run in continuous integration. The pull-request tier covers
Debug and ReleaseFast on the primary Linux platform and ReleaseSafe on both
native platforms; the nightly tier exercises their full Cartesian product.

### Requirements satisfied only trivially

One requirement is implemented but cannot currently be exercised, and is
recorded here rather than counted as verified.

- **Scheme mismatch at binding.** Rejecting a parameter point whose scheme
  differs from the artifact's cannot fire while `MSbar` is the only supported
  scheme. A conformance tripwire fails when a second scheme is added.

One additional requirement was recorded here and has since been discharged.

- **Cross-platform numerical agreement.** The operation-aware comparison policy
  of [Potential Kernel §15.3](POTENTIAL_KERNEL.md) is now written, in
  [Numerical Comparison](NUMERICAL_COMPARISON.md), and the metamorphic and
  finite-difference comparisons name policies from it instead of locally chosen
  literals.

  Writing it found that one of those literals was not merely undeclared but
  wrong in kind: the relabelling property compared a cancelling sum at the
  magnitude of its result rather than of its terms, and the generated
  backgrounds already reach points where those differ by seven orders of
  magnitude. Both facts are recorded with their measurements in that document.

  What remains a measurement rather than a contract is the cross-platform
  evidence itself: results still agree bitwise on Linux x86-64 and macOS ARM64,
  which is two platforms whose arithmetic happens to be identical, and no
  operation yet in the kernel can distinguish them. The one-loop logarithm is
  the first that can.

### Known characteristics

Not defects, but measured behavior a later milestone should know about.

- Derivation costs roughly 0.1 ms for \(\phi^4\) and 0.8 ms for the
  multi-scalar model, two orders of magnitude more than lowering. Exact rational
  arithmetic and string-keyed interning dominate. This is irrelevant at present
  scale, because derivation happens once, and it is the first thing to examine
  if derivation ever appears in a hot path.
- Staged binding reduces per-point cost by roughly a fifth at large batch sizes
  and is neutral at a single point, where copying the parameter-stage prologue
  costs about what it saves.

## 7. Milestone 3: zero-temperature one-loop scalar potential

Status: implemented

### Prerequisites: discharged

Milestone 3 implementation may begin only after agreement, the independent
oracle, the eigensolver, and the representational contracts have precise
meanings. Those prerequisites are now discharged:

- [Numerical Comparison](NUMERICAL_COMPARISON.md) declares and measures the
  known-spectrum, near-degenerate, and zero-mode value, gradient, and Hessian
  policies.
- [Decision 0007](../decisions/0007-milestone-3-oracle.md) adopts
  fixture-specific mass-matrix formulas, exact characteristic polynomials,
  known eigenvalue multisets, a private test-only `f64` scalar evaluator, and
  structural identities. It also records why the scalar-only milestone cannot
  use the Wess–Zumino cancellation before Milestone 6.
- [Decision 0008](../decisions/0008-symmetric-eigensolver.md) selects the
  deterministic real-symmetric cyclic Jacobi solver, direct small-size paths,
  exact caller-workspace accounting, and explicit `nonconvergent` behavior.
- [Decision 0009](../decisions/0009-scalar-spectral-derivatives.md) selects the
  specialized invariant Fréchet/divided-difference gradient and Hessian,
  deterministic nonzero degeneracy clusters, stable close-pair evaluation, and
  the exact zero-block singularity criterion.
- [Kernel Instruction Set](KERNEL_INSTRUCTION_SET.md) and
  [Internal Representations](INTERNAL_REPRESENTATIONS.md#54-matrices-and-spectral-operations)
  define mixed real and `Complex64` temporaries, real matrix and eigensolver
  storage, the restricted logarithm, and invariant spectral value and derivative
  operations.
- [Effective-Potential Calculation Request](../formats/EFFECTIVE_POTENTIAL_REQUEST.md)
  activates the scalar-only `through: 1` request under `MSbar`, while
  [Effective-Potential Artifact](../calculations/EFFECTIVE_POTENTIAL.md),
  [Potential Kernel](POTENTIAL_KERNEL.md), and
  [Evaluation Lifecycle](EVALUATION_LIFECYCLE.md) define stable complex result
  types, distinct numerical statuses, and point-atomic fused publication.
- [Conformance Models](CONFORMANCE_MODELS.md) defines the generated
  three-scalar cyclic-Jacobi variant and the per-case Milestone 3 fixture
  metadata.

The complex-result and branch-policy requirement is no longer listed under
Milestone 2's trivially satisfied requirements. The Milestone 3 contracts make
it reachable: a negative scalar mass-squared eigenvalue is a successful
principal-branch `Complex64` result, and conformance cases can now detect an
unrequested real projection or absolute-value substitution.

### Objective

Deliver the first quantum effective-potential calculation without yet requiring
gauge fixing or a general diagram engine.

### Scope

- Field-dependent scalar mass matrices.
- Explicit spectral-operation representation.
- Zero-temperature one-loop scalar functions.
- Renormalization scheme and scale.
- Loop-order-separated contributions and provenance.
- Domain and negative-mass policies.
- Value, gradient, and Hessian capabilities where scientifically supported.

The initial numerical result preserves the full principal-branch complex value
for negative scalar mass-squared eigenvalues. Such points are successful complex
results rather than unsupported-domain failures.

### Exit criteria

- \(\phi^4\) and multi-scalar results agree with independent derivations.
- Degenerate and near-degenerate cases follow the declared policies.
- Scale dependence has the expected finite-order behavior.
- Direct Typed Value IR and kernel evaluation agree.
- Symbolic exports preserve spectral structure and loop-order separation.

### Examples

Provide a deterministic parameter scan and sampled tree-plus-one-loop potential
data. The Milestone 4 notebook will render and plot this calculation.

The delivered data is `examples/phi4/request_one_loop.json` with
`equations_one_loop.txt`, `equations_one_loop.tex`, and three scans over one
shared background grid: `scan_tree.tsv`, `scan_one_loop.tsv`, and
`scan_total.tsv`. They differ only in `phaser evaluate --selection`, so the
curves add point by point, and the interval crosses the sign change of the
field-dependent mass-squared, so the sampled imaginary component is nonzero
below it and exactly zero above.

### Gate accounting

Each exit criterion and the evidence that closes it:

| Criterion | Evidence |
|---|---|
| \(\phi^4\) and multi-scalar results agree with independent derivations | `test/conformance/scalar_one_loop.zig` runs every recorded fixture case model → artifact → kernel against the known-spectrum evaluator, and separately checks the derivation's mass-matrix entries against the fixture's transcribed identities and the fixture spectra against their characteristic polynomials; `test/reference/scalar_one_loop.zig` keeps the evaluator independent and executes decision 0007's seeded defects as negative controls |
| Degenerate and near-degenerate cases follow the declared policies | The exact-spectrum catalog of all three fixtures, each case naming its policy from [Numerical Comparison](NUMERICAL_COMPARISON.md): `spectral_value_known_spectrum` for the exact multisets including the repeated positive and repeated negative ones, `spectral_value_near_degenerate` for the measured close pairs, `spectral_value_zero_mode` for the exact zeros; derivatives in `test/conformance/one_loop_derivatives.zig` under the matching gradient and Hessian policies |
| Scale dependence has the expected finite-order behavior | `test/conformance/scalar_one_loop.zig` compares the two-scale difference against \(-\operatorname{Tr}[(\mathcal M^2)^2]\log(\mu_2/\mu_1)/32\pi^2\), computed from the fixture's transcribed matrix entries rather than from anything the kernel reports, for the one-by-one and every dense three-by-three case |
| Direct Typed Value IR and kernel evaluation agree | `test/conformance/scalar_one_loop.zig` evaluates the derived graph directly — recursively, sharing no lowering, scheduling, or slot machinery, and taking the spectral node's spectrum from the fixture rather than from an eigensolver — and compares it against kernel output at all three fluctuation dimensions; `test/conformance/potential_kernel.zig` does the same for the real tree subset |
| Symbolic exports preserve spectral structure and loop-order separation | `test/integration/symbolic_export.zig` and the committed `examples/phi4/equations_one_loop.txt`, whose one-loop line keeps `scalar_one_loop([[m2 + 1/2 * lambda * phi^2]]; muR)` symbolic and whose total is labelled `V^(<=1)` alongside the per-order `V^(0)` and `V^(1)` contributions |

Common-gate items: the specifications this milestone implements were reviewed
in the preceding decision and specification changes; supported and unsupported
cases are stated in each; `zig build bench` provides the representative
measurements, now including one-by-one and dense three-by-three one-loop value
and fused-derivative workloads whose outputs are verified against the closed
form before anything is timed; Debug, ReleaseSafe, and ReleaseFast all run in
continuous integration.

### Requirements satisfied only trivially

Implemented but not currently exercisable, recorded here rather than counted as
verified.

- **Scheme mismatch at binding.** Unchanged from Milestone 2: rejecting a
  parameter point whose scheme differs from the artifact's cannot fire while
  `MSbar` is the only supported scheme.
- **`nonconvergent`.** Decision 0008 bounds the cyclic Jacobi sweeps well above
  what any admissible input needs, and no matrix has been found that exhausts
  them. The status is reached only through the test-only Tripwire checkpoint in
  `src/numerics/symmetric_eigensolver.zig`, which is what keeps its handling
  from decaying untested.
- **Cross-platform numerical agreement.** The one-loop logarithm is the first
  operation whose result could differ between the two supported platforms, and
  the continuous-integration matrix is now the measurement that would show it.
  Nothing in this repository can produce that evidence from one host.

### Known characteristics

Not defects, but measured behavior a later milestone should know about.
Measured on Apple M4, Zig 0.16.0, ReleaseSafe, seven samples of at least 50 ms
each; see `zig build bench` for the full table and its variance.

- A one-by-one one-loop value costs roughly 73 ns per point at a single point
  and 64 ns in a large batch, against 46 ns and 33 ns for the same model's tree
  value. The one-loop term is therefore about twice the tree cost at this size,
  most of it the logarithm.
- A dense three-by-three one-loop value costs roughly 430 ns per point, about
  six times the one-by-one case for three times the eigenvalues: the cyclic
  Jacobi sweeps, not the spectral sum, dominate as soon as the direct small-size
  paths stop applying.
- Fusing the gradient and Hessian onto the value costs about 2.6x at one-by-one
  and about 1.6x at three-by-three. The eigensystem is computed once and reused,
  so the marginal cost of the derivatives falls as the diagonalization grows.

## 8. Milestone 4: experimental public client surfaces

### Objective

Exercise a useful scientific calculation through the first public client
boundaries while the ABI remains experimental.

### Scope

- Experimental C ABI version 0.
- C conformance client.
- Python extension and high-level objects.
- Jupyter rich display backed by the LaTeX exporter.
- Stable command-line workflows for the supported slice.

### Required notebook

Provide at least one end-to-end scalar effective-potential notebook that:

1. loads a \(\phi^4\) or multi-scalar model;
2. constructs the calculation;
3. displays the classical and one-loop equations through rich LaTeX rendering;
4. inspects loop-order and renormalization metadata;
5. constructs and evaluates more than one parameter-point binding;
6. evaluates scalar and batch inputs;
7. compares a gradient or Hessian against an independent reference;
8. plots the tree, one-loop contribution, and selected sum over a background
   interval; and
9. states the expected features of the plot.

The underlying plotted data must also be covered by machine-readable tests.

### Exit criteria

- Direct Zig, C, Python, and CLI results agree.
- Ownership, diagnostic lifetime, and invalid-buffer behavior are tested.
- Python scalar and buffer-based batch calls agree.
- The notebook runs from a fresh kernel using public APIs only.
- Equations and plots provide an effective human inspection path.
- ABI version 0 remains explicitly experimental.

## 9. Milestone 5: C++ and Wolfram Language interoperability

### Objective

Add the deferred convenience and semantic-export surfaces after the C ABI,
Python objects, and symbolic artifact contracts have been exercised by a
complete scientific slice.

### Scope

- Thin, primarily header-only C++ RAII wrapper over the C ABI.
- C++ views and idiomatic error adaptation without a native C++ ABI.
- C++ embedding example using the supported scalar calculation.
- Wolfram Language export from the authoritative scientific IR.
- Documented Phaser-specific Wolfram heads for operations without a faithful
  built-in representation.

### Exit criteria

- Direct C-header use and the C++ wrapper agree with C and Zig results.
- C++ ownership and diagnostic behavior are exercised through an independent
  compiler.
- Wolfram exports preserve exact values, contribution selection, spectral
  structure, and scientific metadata.
- Supported Wolfram output is parsed or evaluated through an independent path
  where approved tooling is available; otherwise reviewed semantic fixtures
  and target-specific structural tests are used.
- Neither surface contains independent physics or numerical implementation.

## 10. Milestone 6: general 4D field content at one loop

### Objective

Add Weyl fermions and gauge vectors to the model and quadratic one-loop
calculation in a deliberately selected initial gauge.

### Scope

- Weyl fermion declarations and fermion mass and Yukawa tensors.
- Structurally complex fermion-tensor components whose real and imaginary parts
  use the exact real expression language.
- Gauge fields, flattened coupling-weighted gauge tensors, and exact algebra and
  invariance validation.
- Fermion and gauge-boson field-dependent mass structures.
- Structural pruning by field sector.
- One-loop contributions in the explicitly supported gauge, initially expected
  to be Landau gauge.

Landau support is an explicit intermediate capability, not a substitute for the
general gauge-family milestone.

### Exit criteria

- Fermion-only, scalar-only, and gauge-free models omit irrelevant sectors
  structurally.
- The explicit-component Wess–Zumino fixture reproduces its field-dependent
  masses, all-background supertrace identity, degenerate supersymmetric minima,
  and separate tree and one-loop vacuum-energy cancellations.
- Abelian Higgs and selected Standard Model cases agree with references.
- Mass structures satisfy required symmetry and covariance properties.
- Existing scalar-only results remain unchanged.

### Notebook

Add or extend notebooks to inspect particle-sector mass structures and separate
one-loop contributions. Include a focused Wess–Zumino notebook showing its
mass relations and cancellations, and plot a representative gauge-theory
potential in the supported gauge.

## 11. Milestone 7: generalized gauge fixing

### Objective

Implement the generalized background-field \(R_{\xi,\tilde\xi}\) family and its
named subcases.

### Scope

- Landau gauge.
- Fermi gauge.
- Background-field \(R_\xi\) gauge.
- Generalized independent gauge-parameter channels.
- Scalar-vector mixing.
- Ghost sectors.
- Gauge-parameter binding and dependency metadata.

### Exit criteria

- General expressions reproduce every supported subcase.
- The structural Landau limit uses no singular division.
- Expected mixing cancellations occur.
- Gauge-parameter and scale metadata are complete.
- Gauge-dependent intermediate quantities and gauge-independent checks are
  distinguished correctly.

### Notebook

Provide a gauge-comparison notebook that displays the gauge configuration,
scans selected gauge parameters, plots intermediate potentials where meaningful,
and verifies known subcase limits numerically.

## 12. Milestone 8: higher-loop structural compiler

### Objective

Introduce the general diagrammatic machinery when a concrete higher-loop
calculation requires it.

### Scope

- Background-expanded interaction vertices.
- Bounded diagram-topology catalogs.
- Field assignments and symmetry factors.
- Indexed contraction construction.
- Counterterm insertions.
- Master-integral representation.
- Structural pruning and detailed provenance.

The first target SHOULD be a scalar two-loop zero-temperature potential. Gauge
and fermion sectors may require additional sub-milestones.

When mixed scalar–fermion higher-loop sectors are added, the Wess–Zumino
fixture becomes an exit criterion for those sectors. Its separate two-loop and
eventual three-loop vacuum-energy contributions must vanish at both
supersymmetric minima with term-level cancellation evidence.

### Exit criteria

- Diagram and contraction generation agrees with independent small enumerations.
- Scalar two-loop results agree with established references.
- Structural zeros and unsupported sectors remain distinct.
- Contribution, counterterm, and perturbative-order metadata are complete.

### Notebook

Provide a loop-order notebook that displays selected diagram classes, compares
tree, one-loop, and two-loop contributions, and plots their relative sizes over a
documented domain.

## 13. Milestone 9: RG representation and evolution

### Objective

Support explicit RG functions and consistent evolution without requiring general
beta-function derivation as the first deliverable.

### Capability sequence

1. Represent beta functions and anomalous dimensions.
2. Consume supplied functions to evolve a parameter point.
3. Derive supported RG functions from a model in later work.

The third capability is a distinct scientific project and MUST NOT block the
first two.

### Exit criteria

- The running parameter set is closed and validated.
- Evolution reports scheme, order, scale interval, and provenance.
- Forward and reverse evolution agree within the numerical policy on controlled
  cases.
- Effective-potential RG residuals have the expected first-omitted order.
- The Wess–Zumino finite-order RG identity holds through every supported order
  for which the fixture supplies reference beta functions and anomalous
  dimensions.
- Supplied and Phaser-derived functions are distinguishable.

### Notebook

Provide an RG notebook that plots running parameters and scale dependence,
compares fixed-scale and evolved evaluations, and displays the expected
finite-order residual rather than implying exact invariance.

## 14. Milestone 10: first dimensional-reduction vertical slice

### Objective

Connect a validated four-dimensional model to an internal three-dimensional EFT
and a reusable 3D potential kernel.

### Scope

```text
validated 4D model
       |
matching calculation
       |
internal 3D EFT representation
       |
3D effective-potential artifact
       |
safe 3D potential kernel
```

Begin with a scalar theory to establish dimensions, matching provenance, scale
separation, and 3D conventions. Follow it with Abelian Higgs as the first
gauge-thermal slice.

This milestone does not require a stable external EFT Artifact Format. The 3D
representation remains internal until a concrete interoperability use case
justifies a public format.

### Exit criteria

- Matching relations preserve complete 4D source and calculation provenance.
- 3D dimensions and normalization conventions are validated.
- Scalar matching agrees with independent references.
- The resulting 3D potential is symbolically inspectable and numerically
  evaluable through the ordinary kernel contract.
- Scale-separation assumptions and truncations are explicit.

### Notebook

Provide a dimensional-reduction notebook that displays matching relations,
tabulates matched 3D parameters versus temperature or scale, and plots the
resulting 3D potential for a documented example.

## 15. Milestone 11: broader modern thermal workflow

### Objective

Generalize dimensional reduction and 3D thermodynamics to realistic electroweak
models and controlled accuracy targets.

### Scope

- Non-Abelian gauge theories.
- Standard Model and selected extensions.
- Higher-order matching.
- Hard, soft, and ultrasoft scale separation.
- Three-dimensional loop potentials.
- Strict thermodynamic expansions.
- Controlled RG improvement.

A conventional four-dimensional thermal effective potential MAY be implemented
as an explicit comparison or diagnostic calculation. It is not the central
roadmap path and MUST NOT delay dimensional reduction merely to reproduce a
large conventional resummed framework.

### Exit criteria

Exit criteria are refined after Milestone 10 provides implementation and
benchmark evidence. They must include reference matching calculations,
scale-order consistency, 3D potential verification, and representative realistic
models.

### Notebooks

Add focused notebooks for each supported realistic workflow. They SHOULD compare
orders and scale choices, expose uncertainty or truncation metadata, and plot
quantities whose visual behavior aids scientific review.

## 16. Downstream work

Phase tracing, critical-temperature searches, bounce solutions, nucleation,
sphaleron calculations, bubble-wall dynamics, baryogenesis inputs, and
gravitational-wave predictions remain downstream consumers.

They enter the roadmap only after the calculation-artifact and kernel boundaries
have demonstrated their usefulness for the modern 3D EFT workflow.

## 17. Decisions intentionally deferred

- The exact split of scalar and general higher-loop work.
- The first complete higher-loop gauge-theory target.
- The first beta-function derivation scope.
- Detailed dimensional-reduction accuracy and supported gauge-model subset.
- Plotting and notebook-execution dependencies.
- Committed notebook-output and rendered-artifact policy.
- Release numbering and compatibility promises for each milestone.
- Calendar estimates and staffing.
