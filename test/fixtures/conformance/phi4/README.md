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

## One-loop value points

The one-loop scalar eigenvalue is \(x=V_0''(\phi)\). At \(\mu_R=1\),
\(x=1\) gives \(-3/(128\pi^2)\), while the selected principal branch gives

\[
x=-1:
\qquad
V_1=-\frac{3}{128\pi^2}+\frac{i}{64\pi}.
\]

The fixture keeps these exact expressions as the authoritative values. Their
binary64 counterparts in `test/conformance/scalar_one_loop.zig` are manual
transcriptions, not generated output.

## Zero-mode derivatives

At the zero-mode point, \(x^2\operatorname{Log}(x)\) and its first derivative
have zero limits. The second spectral derivative contains
\(2\operatorname{Log}(x)\). Here \(dx/d\phi=\lambda\phi=2\ne0\), so the
background Hessian is singular. Value and gradient therefore have status `ok`;
the separately requested Hessian has status `singular_derivative`.

## Fixed-parameter scale variation

The scale pair holds \(\Omega=0\), \(m^2=1\), \(\lambda=2\), and \(\phi=0\)
fixed, so \(x=1\) at both points. Only the positive scale changes:

\[
\begin{aligned}
V^{(1)}(\mu_1=1)&=-\frac{3}{128\pi^2},\\
V^{(1)}(\mu_2=2)&=\frac{-\log4-3/2}{64\pi^2}.
\end{aligned}
\]

Consequently,

\[
V^{(1)}(2)-V^{(1)}(1)
=-\frac{\log2}{32\pi^2},
\]

which is the one-eigenvalue instance of the fixed-parameter scale relation in
[Decision 0007](../../../../docs/decisions/0007-milestone-3-oracle.md).
No parameter running or RG-improvement operation is implied.

All values are hand-derived from the conventions in
[Zero-Temperature One-Loop Scalar Effective Potential](../../../../docs/calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md).
