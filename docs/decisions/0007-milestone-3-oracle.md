# Decision 0007: Milestone 3 scalar one-loop oracle

Status: accepted for Milestone 3

## Context

[Implementation Roadmap §7](../architecture/IMPLEMENTATION_ROADMAP.md#7-milestone-3-zero-temperature-one-loop-scalar-potential)
requires an independent oracle before implementation of the scalar one-loop
potential begins. A spectral implementation can return plausible values while
using a wrong normalization, logarithm branch, eigenvalue multiplicity, or
zero-mode rule. Comparing production lowering with production execution would
not expose those shared defects.

The roadmap originally listed the Wess–Zumino supertrace and vacuum-energy
cancellations as a possible Milestone 3 oracle. That option is not available at
this milestone. The cancellation

\[
R+I-2\psi=0
\]

and the one-loop identity

\[
V^{(1)}=f(R)+f(I)-2f(\psi)
\]

both require the fermion contribution. The scalar-only Milestone 3 calculation
cannot represent the second identity or use the first to verify its complete
spectral sum. [Conformance Models §6.4](../architecture/CONFORMANCE_MODELS.md#64-milestone-6-obligations)
therefore activates those checks at Milestone 6. This decision supersedes the
Wess–Zumino option in the roadmap for Milestone 3 rather than silently treating
it as scalar-only evidence.

[Verification and Testing §3](../architecture/VERIFICATION_AND_TESTING.md#3-oracle-hierarchy)
prefers exact results, a deliberately simple independent implementation, and
algebraic or metamorphic properties before a higher-precision or external
calculation. PR B proved that this hierarchy can distinguish the planned
Milestone 3 defects using dependency-free, reviewable `f64` cases.

## Decision

Milestone 3 adopts a layered scalar one-loop oracle:

1. Fixture-specific formulas independently map a public model, parameters, and
   background to every entry of its field-dependent mass matrix.
2. Small non-diagonal symmetric matrices have analytically known eigenvalue
   multisets. Their characteristic-polynomial coefficients independently check
   trace, pairwise products, determinant, and multiplicity.
3. A private test-only evaluator accepts an explicit eigenvalue multiset and
   positive renormalization scale and directly evaluates the principal-branch
   scalar sum.
4. Analytic scalar derivatives and finite differences of that known-spectrum
   evaluator check gradients, Hessians, and zero-mode statuses.
5. Exact and metamorphic identities exercise the same boundaries over generated
   cases and transformed fixtures.

The prototype and its derivations live in
`test/reference/scalar_one_loop.zig` and
`test/fixtures/reference/scalar_one_loop/`. The production implementation may
copy neither their control flow nor their role: it receives a field-dependent
matrix and must use the production eigensolver and spectral operation.

### Independence

The reference evaluator begins after diagonalization. It receives the known
eigenvalue multiset directly and never imports or calls production model
derivation, Typed Value IR lowering, eigensolver, spectral, or one-loop
operations. It is therefore independent of eigenvalue iteration, ordering,
rotation, and convergence defects.

Independently transcribed fixture formulas establish the preceding
model/background-to-matrix boundary. Exact characteristic polynomials establish
the matrix-to-spectrum boundary without a second numerical eigensolver.
Metamorphic identities cover transformations that do not need sampled golden
values. Direct reference evaluation then covers the Typed Value IR and kernel
boundary once the production operation exists.

No one layer is claimed to prove the complete calculation alone. Their
independent inputs and overlapping boundaries are the reason the set is an
oracle.

### Structural identities

Milestone 3 tests the following identities independently of the production
eigensolver.

For the diagnostic operation named `fixed_parameter_scale_variation`, the model
parameters and background are held fixed while only the positive
renormalization scale changes. If \(x_a\) are the eigenvalues of
\(\mathcal M^2\), then

\[
V^{(1)}(\mu_2)-V^{(1)}(\mu_1)
=
-\frac{\operatorname{Tr}[(\mathcal M^2)^2]}{32\pi^2}
\log\frac{\mu_2}{\mu_1}.
\]

This is not RG evolution: no parameter is run and no claim of finite-order scale
independence is made.

The spectral power sums obey

\[
\sum_a x_a=\operatorname{Tr}\mathcal M^2,
\qquad
\sum_a x_a^2=\operatorname{Tr}[(\mathcal M^2)^2].
\]

They are computed directly from matrix entries on one side and from the
reported spectrum on the other.

For every applicable public fixture and generated case:

- real orthogonal basis changes and scalar permutations preserve the spectral
  value under the applicable reordering policy;
- exact degeneracies retain every scalar multiplicity, including repeated
  negative eigenvalues; and
- binding a coupling to exact numerical zero agrees with a separately derived
  model in which the interaction is structurally absent. The test records that
  numerical specialization and structural reduction are different derivation
  paths even when their values agree.

### Seeded-defect acceptance

An oracle is accepted only if a deliberately seeded instance of every planned
defect disagrees under the named numerical policy or violates an exact
identity.

| Seeded defect | Case that exposes it | Oracle or identity that rejects it |
|---|---|---|
| replace \(3/2\) by another constant | positive known spectrum | direct scalar reference value |
| use \(1/(32\pi^2)\) or another normalization | positive known spectrum and two scales | direct value and fixed-parameter scale relation |
| use `log(abs(x))` as a real result | negative and indefinite spectra | principal-branch imaginary reference component |
| divide by \(\mu_R\) instead of \(\mu_R^2\) | non-unit scale | direct value and fixed-parameter scale variation |
| drop a repeated eigenvalue | exact positive and negative degeneracies | explicit multiset, characteristic polynomial, and power sums |
| clip a negative eigenvalue to zero | negative and indefinite spectra | direct complex value, power sums, and multiplicity |
| differentiate an eigenvalue ordering or eigenvector phase | permuted and orthogonally transformed near-degenerate cases | invariant known-spectrum derivative and transformation comparison |
| infer zero-mode cancellation as floating-point \(0\times\infty\) | exact zero mode | analytic limit plus finite result or explicit `singular_derivative` status |

The PR B prototype executes each row as a negative control. No planned row is
covered only by an assertion that the reference and production paths agree.
The rows become the initial scalar one-loop mutation target list under
[Decision 0005](0005-mutation-testing-dependency.md) once production code
exists.

### Shared numerical primitives

The reference and production paths deliberately share Zig `f64`, `@log`,
`@sqrt`, and the pinned standard library. The oracle checks formula assembly,
matrix and spectral boundaries, the principal branch, multiplicity,
transformations, derivatives, and statuses. It does not verify the standard
library's logarithm or provide greater-than-`f64` answers for extremely
ill-conditioned spectra.

The near-degenerate separation and derivative steps are consequently selected
from measured cases whose error remains distinguishable under the named
policies in [Numerical Comparison](../architecture/NUMERICAL_COMPARISON.md).

## Alternatives

A higher-precision external implementation could provide a stronger numerical
reference for ill-conditioned spectra. It was not selected because the proven
exact-spectrum and structural suite catches every planned defect without adding
an executable, dependency, license, platform, or offline-CI obligation.

The Wess–Zumino cancellations remain valuable exact evidence, but they were
rejected for Milestone 3 because their fermion term first exists at Milestone 6.
They remain conformance obligations at that milestone.

Using only production self-consistency, sampled golden output, or a second call
through another public API was rejected because those paths can share the
formula, lowering, or eigensolver defect being tested.

## Consequences

Milestone 3 implementation can begin with an executable meaning of agreement
and with exact checks around the numerical eigensolver. The production suite
must preserve the oracle boundary: convenience helpers from production do not
move into the private reference evaluator, and reference helpers do not become
production implementation.

The exact-spectrum catalog includes positive, negative, zero, indefinite,
degenerate, near-degenerate, permuted, and orthogonally transformed matrices.
The named comparison policies remain component-wise for complex values and use
the unsigned contribution sum as the cancellation scale.

This decision adds no dependency and changes no public format or runtime
interface.

## Revisit when

Revisit if measured production residuals cannot be separated reliably from
reference error, if supported spectra become more ill-conditioned than the
declared cases, if a platform's `f64` logarithm disagrees outside the current
policies, or if Milestone 6 makes the Wess–Zumino cancellations available as an
additional exact oracle. At that point, prefer adding an independent
higher-precision layer rather than weakening a comparison until it passes.
