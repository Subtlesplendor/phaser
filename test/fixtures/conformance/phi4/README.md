# Real scalar phi4 conformance fixture

This fixture uses

\[
V_0(\phi)
=
\Omega+\frac{m^2}{2}\phi^2+\frac{\lambda}{4!}\phi^4.
\]

Direct differentiation gives

\[
V_0'(\phi)=m^2\phi+\frac{\lambda}{6}\phi^3,
\qquad
V_0''(\phi)=m^2+\frac{\lambda}{2}\phi^2.
\]

The one-loop scalar eigenvalue is \(x=V_0''(\phi)\). At \(\mu_R=1\),
\(x=1\) gives \(-3/(128\pi^2)\), while the selected principal branch gives

\[
x=-1:
\qquad
V_1=-\frac{3}{128\pi^2}+\frac{i}{64\pi}.
\]

At the zero-mode point, \(x^2\operatorname{Log}(x)\) and its first derivative
have zero limits. The second derivative contains \(2\operatorname{Log}(x)\);
the chosen point has \(dx/d\phi\ne0\), so the background Hessian is singular.

All values are hand-derived from the conventions in
[Zero-Temperature One-Loop Scalar Effective Potential](../../../../docs/calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).
