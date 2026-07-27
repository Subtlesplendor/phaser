# Milestone 3 scalar oracle prototype fixture

This is reference-only preparation for the Milestone 3 conformance fixture. The
model uses the ordinary public `phaser.qft-model/0.1` format and has no built-in
model shortcut. Its only interaction is

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

Thus the `positive_dense` parameter point at \(b=1\) reaches

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
\((\lambda-9)(\lambda-36)(\lambda-81)\). The dense matrix therefore reaches all
three off-diagonal Jacobi planes without relying on a production eigensolver to
establish its expected spectrum. `cases.json` also records an exact zero-mode
point.

The complete prototype catalog is:

| Case | Matrix rows | Expected spectrum | Exact characteristic polynomial |
|---|---|---|---|
| positive dense | `(53,26,-4); (26,44,-22); (-4,-22,29)` | `9, 36, 81` | `(lambda-9)(lambda-36)(lambda-81)` |
| positive degeneracy | `(30,12,-6); (12,30,-6); (-6,-6,21)` | `18, 18, 45` | `(lambda-18)^2(lambda-45)` |
| negative degeneracy | `(2,20,-10); (20,2,-10); (-10,-10,-13)` | `-18, -18, 27` | `(lambda+18)^2(lambda-27)` |
| zero mode | `(1,1,0); (1,1,0); (0,0,4)` | `0, 2, 4` | `lambda(lambda-2)(lambda-4)` |
| indefinite | `(0,2,0); (2,0,0); (0,0,3)` | `-2, 2, 3` | `(lambda+2)(lambda-2)(lambda-3)` |
| near degeneracy | `(1+2^-21,2^-21,0); (2^-21,1+2^-21,0); (0,0,4)` | `1, 1+2^-20, 4` | `(lambda-1)(lambda-(1+2^-20))(lambda-4)` |

Swapping axes zero and two in the positive dense matrix gives
`(29,-22,-4); (-22,44,26); (-4,26,53)`. The prototype records this matrix and
the permutation matrix
\(P=((0,0,1),(0,1,0),(1,0,0))\) explicitly and checks the same characteristic
polynomial and spectral value. Together with the displayed \(Q\), this covers
both planned matrix relations.

## Oracle coverage

| Boundary | Independent input | Expected result | Oracle or identity |
|---|---|---|---|
| model/background → mass matrix | public model, six cubic parameters, and \((1,0,0)\) | every symmetric matrix entry | the fixture-specific differentiated formula above |
| symmetric matrix → spectrum | exact-spectrum matrices in `test/reference/scalar_one_loop.zig` | eigenvalue multiset and multiplicity | hand derivation plus all three exact characteristic-polynomial coefficients |
| spectrum → one-loop value | known eigenvalues and positive scale | principal-branch `Complex64` value | private direct scalar evaluator over the explicit multiset |
| value → gradient/Hessian | named near-degenerate and zero-mode spectra | derivative or `singular_derivative` | analytic scalar derivatives plus finite differences of the independent known-spectrum evaluator |
| Typed Value IR → kernel | the same future bound inputs | value, outputs, and status | direct reference evaluation; activation waits for the Milestone 3 production boundary |

The reference and future production paths intentionally share Zig `f64`,
`@log`, and `@sqrt`. This prototype verifies formula assembly, the complex
branch, matrix/spectrum boundaries, multiplicity, derivatives, and statuses; it
does not verify libm or provide more-than-`f64` answers for extremely
ill-conditioned spectra.

## Seeded defects

The executable prototype demonstrates rejection of a wrong `3/2` constant,
wrong `1/(64*pi^2)` normalization, a real `log(abs(x))`, use of `muR` instead of
`muR^2`, dropped multiplicity, clipping a negative eigenvalue, an
ordering-dependent derivative, and a zero-mode cancellation attempted as
floating-point zero times infinity. No planned seeded defect is left uncovered.

All matrices, spectra, transformations, and values were transcribed by hand
from the displayed formulas. There is no generated numerical golden file and no
external dependency.

PR E materializes the authoritative language-neutral version under
`test/fixtures/conformance/three_scalar/`. This directory remains the isolated
PR B oracle prototype and seeded-defect evidence. The executable reference test
transcribes every authoritative exact-spectrum case separately so the
conformance fixture does not become an input to its own numerical oracle.
