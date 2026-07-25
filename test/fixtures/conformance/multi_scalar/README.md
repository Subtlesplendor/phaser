# Multi-scalar conformance fixture

The exact potential is

\[
\begin{aligned}
V_0(h,s)={}&\Omega+t_hh+t_ss
+\frac12(m_h^2h^2+2m_{hs}^2hs+m_s^2s^2)\\
&+\frac16(ah^3+3bh^2s+3chs^2+ds^3)\\
&+\frac1{24}(\lambda_hh^4+4\lambda_3h^3s
+6\lambda_2h^2s^2+4\lambda_1hs^3+\lambda_ss^4).
\end{aligned}
\]

Its Hessian entries are recorded in `fixture.json`. The coefficients `3`, `4`,
and `6` expose the symmetric tensor-orbit multiplicities directly.

The non-diagonal indefinite reference matrix

\[
\begin{pmatrix}3/2&5/2\\5/2&3/2\end{pmatrix}
\]

has eigenvalues \(4\) and \(-1\). At \(\mu_R=1\), their scalar one-loop
sum is

\[
\frac{\log 4-3/2}{4\pi^2}
-\frac{3}{128\pi^2}
+\frac{i}{64\pi}.
\]

The `field_permutation` case exchanges the two basis vectors explicitly. The
`orthogonal_basis_change` case applies

\[
Q=\frac1{\sqrt2}\begin{pmatrix}1&1\\1&-1\end{pmatrix}
\]

to \(\operatorname{diag}(4,-1)\), producing the non-diagonal matrix above.
Both cases record the input matrix, transformation, result, eigenvalue
multiset, and exact common complex sum. The `negative_degeneracy` point records
two eigenvalues equal to \(-2\), giving

\[
2f(-2)=\frac{\log 2-3/2}{8\pi^2}+\frac{i}{8\pi}.
\]

These comparisons preserve multiplicity and do not depend on eigenvector
labels.

All values are hand-derived from the conventions in
[Zero-Temperature One-Loop Scalar Effective Potential](../../../../docs/calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).
