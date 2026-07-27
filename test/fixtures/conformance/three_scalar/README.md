# Generated three-scalar Jacobi conformance fixture

This generated scalar-only variant is supplied through the ordinary public
`phaser.qft-model/0.1` format. It has no built-in model shortcut, fermions, or
gauge vectors. Its cubic potential is

\[
V_0(r,s,t)=\frac16\left(
c_{111}r^3+3c_{112}r^2s+3c_{113}r^2t+
3c_{122}rs^2+6c_{123}rst+3c_{133}rt^2\right).
\]

At background \((r,s,t)=(b,0,0)\), direct differentiation gives

\[
\mathcal M^2(b)=b
\begin{pmatrix}
c_{111}&c_{112}&c_{113}\\
c_{112}&c_{122}&c_{123}\\
c_{113}&c_{123}&c_{133}
\end{pmatrix}.
\]

This formula is the independent model/background-to-matrix oracle. It does not
use the future production mass-matrix derivation.

## Dense Jacobi case

At \(b=1\), the `positive_dense` parameters produce

\[
\begin{pmatrix}
53&26&-4\\
26&44&-22\\
-4&-22&29
\end{pmatrix}
=Q\,\operatorname{diag}(9,36,81)\,Q^T,
\qquad
Q=\frac13
\begin{pmatrix}
1&-2&-2\\
-2&1&-2\\
-2&-2&1
\end{pmatrix}.
\]

The exact characteristic polynomial is
\((\lambda-9)(\lambda-36)(\lambda-81)\). Every off-diagonal plane is nonzero,
so a production evaluation reaches the cyclic-Jacobi path instead of either
small closed form.

At \(\mu_R=3\), division by \(\mu_R^2=9\) gives the reviewable value

\[
\frac{
81(-3/2)+1296(\log4-3/2)+6561(\log9-3/2)
}{64\pi^2}.
\]

## Exact-spectrum catalog

| Case | Matrix rows | Expected spectrum | Exact characteristic polynomial |
|---|---|---|---|
| positive dense | `(53,26,-4); (26,44,-22); (-4,-22,29)` | `9, 36, 81` | `(lambda-9)(lambda-36)(lambda-81)` |
| positive degeneracy | `(30,12,-6); (12,30,-6); (-6,-6,21)` | `18, 18, 45` | `(lambda-18)^2(lambda-45)` |
| negative degeneracy | `(2,20,-10); (20,2,-10); (-10,-10,-13)` | `-18, -18, 27` | `(lambda+18)^2(lambda-27)` |
| zero mode | `(1,1,0); (1,1,0); (0,0,4)` | `0, 2, 4` | `lambda(lambda-2)(lambda-4)` |
| indefinite | `(0,2,0); (2,0,0); (0,0,3)` | `-2, 2, 3` | `(lambda+2)(lambda-2)(lambda-3)` |
| near degeneracy | `(1+2^-21,2^-21,0); (2^-21,1+2^-21,0); (0,0,4)` | `1, 1+2^-20, 4` | `(lambda-1)(lambda-(1+2^-20))(lambda-4)` |

The characteristic-polynomial coefficients establish each complete eigenvalue
multiset and its multiplicities. The complex values in `fixture.json` are
separate hand evaluations over those known spectra.

## Near degeneracy

The separation \(2^{-20}\) is exact in binary64 and is the measured regime
declared by the numerical-comparison policy. It is more than four billion
binary64 spacings near one. The case does not claim coverage for arbitrarily
smaller separations.

## Permutation and orthogonal relations

Swapping axes zero and two in the positive dense matrix gives
`(29,-22,-4); (-22,44,26); (-4,26,53)`. The fixture records the permutation
matrix explicitly and preserves the same spectrum and value. The displayed
orthogonal matrix \(Q\) separately relates the diagonal spectrum to the dense
public-fixture basis. Neither relation assigns identity to a sorted eigenvalue,
an eigenvector sign, or a basis inside a degenerate subspace.

## Provenance and transcription

Every matrix, spectrum, characteristic polynomial, and one-loop expression was
derived by hand from the displayed formulas. The exact strings in
`fixture.json` are authoritative. Their binary64 forms in
`test/conformance/scalar_one_loop.zig` and
`test/reference/scalar_one_loop.zig` are explicitly recorded manual
transcriptions; no fixture-expression parser or generated golden file exists.
The reference evaluator intentionally shares Zig binary64 and `@log` with
production, as accepted by Decision 0007.

## Future Milestone 3 conformance identifiers

This fixture documentation reserves these identifiers and marks them
`not_yet_supported` until their production boundary exists:

| Identifier | Future boundary |
|---|---|
| `m3.scalar.mass_matrix_entries` | every independently derived mass-matrix entry |
| `m3.scalar.known_spectra` | exact spectra, multiplicity, and Jacobi convergence |
| `m3.scalar.complex_values` | principal-branch complex scalar values |
| `m3.scalar.supported_derivatives` | invariant supported gradients and Hessians |
| `m3.scalar.singular_statuses` | exact `singular_derivative` outcomes |
| `m3.scalar.typed_value_ir_kernel_agreement` | direct Typed Value IR against kernel |
| `m3.scalar.fixed_parameter_scale_dependence` | held-parameter scale relation |
| `m3.scalar.exact_workspace_boundaries` | exact size succeeds and one byte less fails |

These identifiers document future activation; this preparation PR does not
implement the eigensolver, spectral IR, complex kernel, or derivative path.
