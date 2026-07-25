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

The indefinite reference matrix has eigenvalues \(1\) and \(-1\). At
\(\mu_R=1\), their scalar one-loop sum is

\[
-\frac{3}{64\pi^2}+\frac{i}{64\pi}.
\]

Permuting the fields or applying a real orthogonal similarity transformation
preserves the eigenvalue multiset and therefore the complete complex spectral
sum. These comparisons must not depend on eigenvector labels.

All values are hand-derived from the conventions in
[Zero-Temperature One-Loop Scalar Effective Potential](../../../../docs/calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).
