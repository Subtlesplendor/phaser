# Numerical Comparison

Status: initial specification

This document is the normative catalog of Phaser's numerical-comparison
policies. It instantiates the field list of
[Verification and Testing §9.3](VERIFICATION_AND_TESTING.md#93-independent-numerical-paths)
for the quantities Phaser actually compares, and it is the operation-aware
policy that [Potential Kernel §15.3](POTENTIAL_KERNEL.md#153-cross-platform-numerical-agreement)
requires cross-platform agreement to be stated against.

It does not introduce a comparison framework. Verification and Testing owns
which fields a policy records, which domains are exact, and what independence
means; this document supplies the policies themselves, their measured bounds,
and the evidence for them.

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations and test suites.

## 1. Scope

This specification covers:

- what identifies a comparison policy;
- the arithmetic every approximate policy shares;
- the comparison contexts and conditioning regimes currently defined;
- the catalog of declared policies and the evidence for each bound;
- the form later spectral and degenerate entries must take; and
- how test code names a policy instead of carrying its own literal.

It does not cover exact domains, which
[Verification and Testing §9.1](VERIFICATION_AND_TESTING.md#91-exact-domains)
owns, and it does not define test tiers or budgets, which
[Development Workflow](../../DEVELOPMENT_WORKFLOW.md) owns.

## 2. What identifies a policy

A policy is keyed by three things:

- the **comparison context**, which says what the two sides are;
- the **quantity and operation**, which says what is being compared; and
- the **conditioning regime**, which says which points the policy is claimed to
  hold at.

All three are required. A stress regime such as `near_degenerate` or `zero_mode`
is a regime, not a policy: it says where a comparison happens, not what
agreement means there. A policy name that omits the regime is incomplete, and a
policy MUST NOT be applied outside the regime it declares.

Every approximate policy records the nine fields §9.3 requires: quantity and
operation, absolute tolerance, relative tolerance, optional ULP bound, reference
precision, expected conditioning or scale, treatment of zero, subnormal,
non-finite and complex values, permitted point statuses, and branch policy.
Exact policies are cataloged alongside them and are not approximate policies:
they record what they compare and the contract that promises it.

There is no universal Phaser tolerance, and no policy is declared for a regime
that has not been measured. An undeclared bound is a gap to close, not a value
to guess.

## 3. The comparison rule

Every approximate policy accepts a pair when

```text
|expected - actual| <= absolute
                     + relative * magnitude
                     + reference_error_multiple * reference_error
```

where `magnitude` and `reference_error` describe the conditioning of that
particular comparison:

- `magnitude` is what the relative tolerance applies to. It defaults to the
  larger of the two compared magnitudes, and a policy MAY declare a different
  one. It MUST declare a different one where the compared magnitude is not what
  bounds the error: the rounding introduced by reordering a sum is bounded by
  the sum of its terms' magnitudes, which near a cancellation is many orders of
  magnitude above the total.
- `reference_error` is the absolute error the reference side of the comparison
  carries. It is zero when neither side is an approximate reference. A reference
  that reports its own error bar, such as a difference quotient reporting the
  roundoff it inherits from the values it cancelled, supplies it directly.

Two exceptions apply to every approximate policy:

- values that are equal compare equal, which covers identical infinities and the
  two signed zeros; and
- a non-finite value otherwise never satisfies an approximate policy. A point
  producing one fails its status check first: `non_finite` is a point-level
  outcome, not a number to compare.

Complex quantities compare their real and imaginary components independently,
each under the policy's own bounds and each with its own conditioning. A policy
that compares magnitudes or moduli instead MUST say so, because a comparison of
moduli does not constrain a branch.

Statuses are compared exactly under every policy, and each policy names the
statuses at which it applies. Comparing values at a point whose statuses differ,
or at a point that failed, is outside every policy in this catalog.

## 4. Comparison contexts

| Context | The two sides are |
|---|---|
| `same_kernel` | one kernel object, executed twice, or executed through operations its contract promises are indistinguishable |
| `reordered_inputs` | one mathematical quantity reached through two canonical accumulation orders |
| `independent_reference` | a Phaser result and a deliberately simple test-only reference, including a hand-transcribed exact identity evaluated in the test |
| `cross_platform` | the same quantity on different supported targets or build modes |

## 5. Conditioning regimes

| Regime | Meaning |
|---|---|
| `well_conditioned` | the compared quantity's magnitude is representative of the magnitudes that produced it, and no derivative being compared is evaluated at a stationary or degenerate point |
| `cancellation` | the result is far below the largest term summed to reach it |
| `near_degenerate` | eigenvalues, masses, or scales approach each other but remain separated |
| `zero_mode` | a quantity vanishes exactly, and the comparison concerns the limit or the status taken there |

The `cancellation` regime is reached by declaring the conditioning scale rather
than by a separate policy: §6.2 and the spectral value policies apply at any
point precisely because they use the unsigned sum that bounds their error.
Sections 6.6 and 6.7 declare the measured near-degenerate and zero-mode
policies; neither may be generalized to a more severe regime without new
evidence.

## 6. Catalog

### 6.1 `same_kernel_bitwise`

- **Context and regime**: `same_kernel`, every regime.
- **Quantity and operation**: every published output component and status of one
  kernel object evaluated with the same inputs, operation, and workspace
  configuration. Also the operations
  [Potential Kernel §15.1](POTENTIAL_KERNEL.md#151-same-kernel-reproducibility)
  promises are indistinguishable from repetition: scalar against batch, any
  batch partition or permutation, staged against unstaged binding, evaluation
  after the kernel or binding has been moved, and a fresh binding of the same
  kernel to the same parameter point.
- **Comparison**: bitwise equality of the value's bits, and exact equality of
  statuses. Bitwise rather than arithmetic equality, so that the two signed
  zeros are distinguished and two identical NaN payloads agree: the contract
  promises identical results, and that is what is tested.
- **Not an approximate policy.** It is cataloged so that a test naming it states
  which contract it tests, rather than reading as an unexplained strict
  comparison.

### 6.2 `reordered_value_well_conditioned`

- **Context and regime**: `reordered_inputs` and `independent_reference`,
  `well_conditioned`, valid at any point through its declared scale.
- **Quantity and operation**: a real published output component — potential
  value, gradient entry, or Hessian entry — of one exact quantity summed in two
  different canonical orders. Reached by field relabelling, coordinate
  permutation, a supported basis transformation, dropping a term bound to
  exactly zero, and by comparing against a hand-transcribed exact identity
  evaluated in `f64` in the test.
- **Absolute tolerance**: none.
- **Relative tolerance**: `1e-14`.
- **ULP bound**: none declared.
- **Reference precision**: none. Both sides are `f64` Phaser or hand-transcribed
  evaluations of the same exact quantity, so the comparison is symmetric and
  neither side is a reference.
- **Expected conditioning or scale**: the sum of the terms' magnitudes at the
  compared point, supplied by the caller. Applying the relative tolerance to the
  magnitude of the result instead would assert a bound the arithmetic does not
  obey wherever the sum cancels.
- **Zero, subnormal, non-finite, complex**: §3 applies. No absolute floor is
  needed: the declared scale is zero only where every term is zero, and the
  comparison is then exact on both sides.
- **Permitted point statuses**: `ok` on both sides, compared first.
- **Branch policy**: not applicable while results are real.

Evidence. Floating-point addition is not associative, so two orders of the same
fifteen-term sum differ by roughly `n * eps` of the terms' magnitudes, about
`3e-15`. Over 2000 generated cases per property, the largest observed difference
was `4.1e-16` of the declared scale, about two units in the last place, using 4%
of the declared bound.

This replaces a locally chosen `1e-12` applied to the magnitude of the result.
That literal was not loosened but rescaled, and at a well-conditioned point the
comparison is now roughly two orders of magnitude stricter. It was also
measurably unsafe: over the same 2000 cases the observed relative difference
reached `4.5e-13` against that `1e-12`, because the generated backgrounds reach
points where the potential passes through zero and the terms cancel by seven
orders of magnitude. The bound held only because a closer approach to the zero
set had not yet been generated.

### 6.3 `finite_difference_gradient_well_conditioned`

- **Context and regime**: `independent_reference`, `well_conditioned`.
- **Quantity and operation**: one exact gradient component against a central
  first difference of the same kernel's values.
- **Absolute tolerance**: none.
- **Relative tolerance**: `1e-8`.
- **ULP bound**: none declared.
- **Reference precision**: an `f64` central difference at step
  `eps^(1/3) * max(|x|, 1)`, chosen where truncation error, which grows as the
  square of the step, balances roundoff, which grows as its inverse. The
  reference reports the roundoff it inherits, and the policy permits 10 times
  that error.
- **Expected conditioning or scale**: the larger of the two compared magnitudes.
  Points where the derivative is small compared with the magnitudes differenced
  to produce it are outside this policy, as are stationary and degenerate
  points.
- **Zero, subnormal, non-finite, complex**: §3 applies.
- **Permitted point statuses**: `ok`, at the point and at every sampled
  neighbor.
- **Branch policy**: not applicable while results are real.

Evidence. The two terms answer the reference's two error sources rather than one
bound covering both. Across the committed test points the largest observed
difference used 0.03% of the permitted budget. The relative term is what carries
the truncation-dominated points: at the φ⁴ point `600`, where the difference
reaches 2300 times the reference's roundoff floor, the observed relative
difference is `6.9e-11`.

This tightens the `1e-7` literal it replaces by one order of magnitude. The
truncation error it bounds is a deterministic property of the difference formula
and the model, not rounding noise, and the measured margin is a factor of 3000.

### 6.4 `finite_difference_hessian_well_conditioned`

- **Context and regime**: `independent_reference`, `well_conditioned`.
- **Quantity and operation**: one exact Hessian entry against a central second
  difference of the same kernel's values.
- **Absolute tolerance**: none.
- **Relative tolerance**: `1e-7`.
- **ULP bound**: none declared.
- **Reference precision**: an `f64` central second difference at step
  `eps^(1/4) * max(|x|, 1)`. A second difference divides by the square of the
  step, so its roundoff grows as the inverse square and the balance moves,
  leaving this reference four orders of magnitude less accurate than the
  first-difference one. That is why this policy is separate rather than shared
  with §6.3. The reference reports the roundoff it inherits, and the policy
  permits 10 times that error.
- **Expected conditioning or scale, special values, statuses, branch**: as §6.3.

Evidence. The relative tolerance is unchanged from the literal it replaces; the
reference-error term is new. It is what makes the bound justified rather than
coincidental: at the multi-scalar point `(100, 50)` the mixed partial is
roundoff-dominated, and the observed difference used 91% of the old relative
literal on its own. Under this policy the worst observed comparison uses 19% of
the permitted budget, a margin of a factor of five, and every other committed
point uses less than 6%.

### 6.5 `spectral_value_known_spectrum`

- **Context and regime**: `independent_reference`, `well_conditioned` and
  `cancellation`.
- **Quantity and operation**: the real or imaginary component of a complex
  scalar one-loop value against the direct test-only evaluator over an
  analytically known eigenvalue multiset.
- **Absolute tolerance**: none.
- **Relative tolerance**: `5e-15`.
- **ULP bound**: none declared.
- **Reference precision**: Zig `f64`, using `@log` for each nonzero eigenvalue.
  The reference deliberately shares this primitive with production; it does not
  claim to verify libm or provide higher precision.
- **Expected conditioning or scale**: separately for each component, the sum of
  the magnitudes of that component of every individual eigenvalue contribution.
  This is the unsigned contribution sum, not the magnitude of the final value.
- **Zero, subnormal, non-finite, complex**: §3 applies. An exact zero eigenvalue
  contributes `(0, 0)` before a logarithm is formed. Real and imaginary
  components compare independently.
- **Permitted point statuses**: `ok` on both sides, compared first.
- **Branch policy**: principal complex logarithm with
  `Arg(z) in (-pi, pi]`; negative real eigenvalues have positive imaginary
  contribution `x^2/(64*pi)`.

Evidence. The prototype compares the independent evaluator with the hand
expressions for the existing phi4 and two-scalar positive, negative,
indefinite, and repeated-negative cases. It also compares permutations of the
dense three-scalar spectrum. The largest observed component error is reported
in §7. The declared bound is also more than seven times the elementary
three-term `3 * eps` rounding estimate.

### 6.6 Near-degenerate spectral policies

The measured case has exact binary separation `2^-20` between the two lowest
eigenvalues. This is close enough to exercise the near-degenerate regime while
remaining distinguishable by more than four billion binary64 spacings near one.
It is not evidence for arbitrarily smaller separations.

| Policy | Quantity and operation | Absolute | Relative | Reference-error multiple |
|---|---|---:|---:|---:|
| `spectral_value_near_degenerate` | complex value against a reordered explicit known-spectrum sum | none | `1e-14` | none |
| `spectral_gradient_near_degenerate` | analytic known-spectrum gradient against a central value difference | none | `2e-8` | `10` |
| `spectral_hessian_near_degenerate` | analytic known-spectrum Hessian against a central second value difference | none | `2e-6` | `10` |

For all three:

- **Context and regime**: `independent_reference`, `near_degenerate`.
- **ULP bound**: none declared.
- **Reference precision**: Zig `f64`. The value reference directly sums the
  known eigenvalues. The gradient uses step `eps^(1/3)` and the Hessian uses
  `eps^(1/4)`; each difference reports the roundoff inherited from the values
  it cancels.
- **Expected conditioning or scale**: the value uses the unsigned contribution
  sum component by component. Derivatives use the larger compared derivative
  magnitude plus the reference's separately reported error.
- **Zero, subnormal, non-finite, complex**: §3 applies. Value components compare
  independently. The measured derivative case is real and contains no zero
  eigenvalue.
- **Permitted point statuses**: `ok` at the named point and at every sampled
  neighbor.
- **Branch policy**: the principal branch of §6.5.

Evidence. `test/reference/scalar_one_loop.zig` fixes the spectrum, its
background derivatives, the two step rules, and the exact separation. Section 7
records the observed errors and budget use.

### 6.7 Zero-mode spectral policies

| Policy | Quantity and operation | Absolute | Relative | Reference-error multiple |
|---|---|---:|---:|---:|
| `spectral_value_zero_mode` | complex value with an exact zero eigenvalue | none | `5e-15` | none |
| `spectral_gradient_zero_mode` | finite first-derivative zero-mode limit | none | `2e-8` | `10` |
| `spectral_hessian_zero_mode` | finite analytic cancellation, or exact singular status | none | `2e-6` | `10` |

For all three:

- **Context and regime**: `independent_reference`, `zero_mode`.
- **ULP bound**: none declared.
- **Reference precision**: Zig `f64`, with the exact analytic value and
  first-derivative limits established before numerical evaluation. A numerical
  derivative reference uses its coarse-to-fine change plus inherited roundoff
  as an error estimate.
- **Expected conditioning or scale**: the value uses the component-wise unsigned
  contribution sum, including zero for the zero-mode term. A finite derivative
  uses the unsigned derivative scale; an isolated exact zero is therefore an
  exact comparison unless a reference supplies a nonzero error estimate.
- **Zero, subnormal, non-finite, complex**: an exact zero contribution is formed
  without evaluating `log(0)`. Components compare independently under §3.
- **Permitted point statuses**: value and gradient require `ok`. Hessian permits
  `ok` only after an analytic finite cancellation, or
  `singular_derivative` when a required spectral second derivative diverges.
  Status is exact and no number is compared in the singular case.
- **Branch policy**: the principal branch of §6.5.

Evidence. The prototype checks the exact value and gradient limits, the singular
linear zero-mode Hessian, the finite quadratic zero-mode cancellation, and a
seeded implementation that forms floating-point zero times infinity. The last
produces non-finite output and is rejected before a numerical comparison.

### 6.8 Cross-platform application

Cross-platform agreement is not a policy of its own. A quantity's cross-platform
requirement is discharged by requiring every supported target to satisfy that
quantity's operation-specific policy, from §6.2 to §6.7, against the same
target-independent reference. A direct cross-target differential, when one
exists, uses the same operation-specific bounds; it does not receive a separate,
looser cross-platform tolerance.

What is currently observed is stronger and is deliberately not promised: on the
required native platforms Linux x86-64 and macOS ARM64, the pre-one-loop
conformance and differential comparisons agree bitwise, because the lowered
program is the same and every `f64` operation in it is correctly rounded. The
Milestone 3 policies apply in cross-platform context with the same bounds; their
current prototype evidence is native macOS ARM64, and the pull-request matrix
supplies the required Linux x86-64 measurement.

Milestone 4 adds Windows x86-64 as a third required native platform. It is worth
being precise about what that does and does not add here: Windows x86-64 and
Linux x86-64 execute the same instruction set with the same rounding, so a third
platform is not a third *arithmetic*. It can expose a divergence in compiler
code generation, calling convention, or library `log` implementation, and it
does not weaken the observation above. The one operation that could distinguish
the supported platforms remains the one-loop logarithm, and the platform that
could distinguish it from x86-64 remains macOS ARM64.

## 7. Milestone 3 measurement

The committed prototype uses:

- exact spectra with positive, negative, repeated, zero, indefinite, and
  near-degenerate eigenvalues;
- a dense three-scalar matrix related to its diagonal spectrum by an explicitly
  recorded orthogonal matrix;
- hand expressions from the existing phi4 and two-scalar fixtures;
- central differences of the independent known-spectrum evaluator; and
- component-wise unsigned contribution sums for cancellation scales.

The test records a near-degenerate separation of `2^-20`, gradient step
`eps^(1/3)`, and Hessian step `eps^(1/4)`. On macOS ARM64 with the pinned Zig
0.16.0 toolchain, every hand-expression and value-reordering comparison was
bitwise equal. The near-degenerate analytic gradient and central difference
differed by `1.78e-13`, using 0.34% of its total policy budget after the
reference-error term. The analytic Hessian and central second difference
differed by `2.78e-10`, using 4.12% of its budget. These measurements are
evidence for the bounds, not a second contract. At the zero-mode cases, the
refined central gradient was `-7.53e-9` in the imaginary component and used
10.0% of the budget supplied by its coarse-to-fine error estimate. The finite
quadratic-zero-mode Hessian reference was `-2.47e-10` and used 3.66% of its
budget.

The executable acceptance criterion is stronger: each committed case must
continue to satisfy its named policy in Debug and ReleaseSafe, and every seeded
defect must continue to be rejected.

These measurements prove the declared policies only for the named conditioning
regimes. A production eigensolver residual larger than the prototype error, a
smaller near-degenerate separation, or a derivative with more severe
cancellation requires a new measurement; it does not inherit these bounds.

## 8. Executable mirror

`test/support/numerical_comparison.zig` mirrors this catalog. It carries each
policy's name and numerical fields and the §3 arithmetic; the remaining fields
are prose and stay here, summarized in each constant's doc comment.

A test MUST name the policy it appeals to rather than carry its own tolerance
literal, and MUST supply the conditioning that policy declares. Independently
editable literals were how the two defects recorded in §6.2 and §6.4 stayed
invisible: nothing connected a number in a test file to a claim anyone had
checked.

The mirror is not normative. Where the two disagree, this document is correct
and the module has a defect.

## 9. Adoption

Naming a policy today:

- `test/property/properties.zig`, for the metamorphic relabelling and
  zero-coupling properties and for every same-kernel comparison; and
- `test/differential/finite_differences.zig`, for the gradient, Hessian, and
  transcribed-identity comparisons;
- `test/reference/scalar_one_loop.zig`, for the independent known-spectrum,
  near-degenerate, and zero-mode prototype; and
- `test/conformance/scalar_one_loop.zig`, for the existing hand-transcription
  smoke checks.

Still carrying local literals, deliberately:

- `test/conformance/parameter_binding.zig` and
  `test/conformance/potential_kernel.zig`, which compare against values
  transcribed from a language-neutral fixture. Their policy belongs to the
  fixture case rather than to the test file, and
  [Conformance Models](CONFORMANCE_MODELS.md) already requires every case to
  state its precision and comparison policy. They are retrofitted when the
  fixture format carries that field.

## 10. Deferred

- The first ULP bound, and with it the ULP field in the executable mirror. No
  cataloged policy needs one: each is scale-aware instead.
- A higher-precision reference. Every policy here compares `f64` against `f64`,
  and the one-loop oracle work records why that remains acceptable and when it
  would not.
- Policies for a nondeterministic parallel reduction, which
  [Potential Kernel §15.4](POTENTIAL_KERNEL.md#154-faster-policies) requires to
  be selected explicitly and tested separately.
