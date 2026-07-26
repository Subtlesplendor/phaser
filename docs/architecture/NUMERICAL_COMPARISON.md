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

Only `well_conditioned` policies are declared here. The `cancellation` regime is
reached today by declaring the conditioning scale rather than by a separate
policy: §6.2 applies at any point precisely because it is compared at the scale
that bounds its error. The remaining regimes belong to the one-loop spectral
work and are specified in §7 rather than declared with invented numbers.

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

### 6.5 Cross-platform application

Cross-platform agreement is not a policy of its own. A quantity's cross-platform
requirement is discharged by requiring every supported target to satisfy that
quantity's operation-specific policy, from §6.2 to §6.4, against the same
target-independent reference. A direct cross-target differential, when one
exists, uses the same operation-specific bounds; it does not receive a separate,
looser cross-platform tolerance.

What is currently observed is stronger and is deliberately not promised: on the
two required native platforms, Linux x86-64 and macOS ARM64, the committed
conformance and differential comparisons agree bitwise, because the lowered
program is the same and every `f64` operation in it is correctly rounded. That is
a measurement on two platforms, not a contract. It will not survive a target
whose libm differs once the one-loop logarithm enters, which is exactly why the
requirement is stated per operation rather than as one universal bound.

## 7. Entries not yet declared

The one-loop work needs policies this document deliberately does not yet
contain, because their bounds must be measured before they are declared. Each
MUST arrive with the §2 key, the nine §9.3 fields, and the measurement that
justifies its numbers:

- `spectral_value_known_spectrum`, comparing a complex one-loop value against a
  simple evaluator over an analytically known eigenvalue multiset. Real and
  imaginary components compare independently, and the conditioning scale is the
  magnitude of the unsigned sum of the individual contributions, because a
  spectral sum over eigenvalues of both signs cancels.
- Operation-specific `near_degenerate` policies for values, gradients, and
  Hessians, separately, since a divided difference between nearly equal
  eigenvalues loses accuracy that the value does not.
- Operation-specific `zero_mode` policies, which are as much about the permitted
  status as about a tolerance: a required derivative at a zero mode is
  `singular_derivative`, not a large number.
- The cross-platform applications of each of those, under §6.5.

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
  transcribed-identity comparisons.

Still carrying local literals, deliberately:

- `test/conformance/parameter_binding.zig` and
  `test/conformance/potential_kernel.zig`, which compare against values
  transcribed from a language-neutral fixture. Their policy belongs to the
  fixture case rather than to the test file, and
  [Conformance Models](CONFORMANCE_MODELS.md) already requires every case to
  state its precision and comparison policy. They are retrofitted when the
  fixture format carries that field.
- `test/conformance/scalar_one_loop.zig`, whose transcription smoke tests are
  the Milestone 0 precursor of the spectral policies §7 describes. It is
  retrofitted with them, not before them.

## 10. Deferred

- The measured bounds for every entry in §7.
- The first ULP bound, and with it the ULP field in the executable mirror. No
  cataloged policy needs one: each is scale-aware instead.
- A higher-precision reference. Every policy here compares `f64` against `f64`,
  and the one-loop oracle work records why that remains acceptable and when it
  would not.
- Policies for a nondeterministic parallel reduction, which
  [Potential Kernel §15.4](POTENTIAL_KERNEL.md#154-faster-policies) requires to
  be selected explicitly and tested separately.
