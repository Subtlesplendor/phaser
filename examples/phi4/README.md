# `phi4`

The single-scalar theory

$$V(\phi)=\Lambda+\tfrac12 m^2\phi^2+\tfrac1{24}\lambda\phi^4,$$

which is the smallest model exercising every Milestone 2 stage.

## Files

| File | Role |
|---|---|
| `model.json` | QFT model: one real scalar, vacuum energy, mass-squared, quartic |
| `request.json` | Tree-level effective-potential request over the full scalar space |
| `point.json` | Parameter point with $m^2<0$, so the symmetry is broken |
| `inspection.txt` | Golden output of the model-inspection example |
| `equations.txt` | Golden Phaser-notation equations, per contribution and summed |
| `equations.tex` | Golden delimiter-free MathJax fragment |
| `scan.tsv` | Golden sampled potential, gradient, and Hessian over $\phi\in[0,600]$ |

## Reproducing

```sh
zig build
./zig-out/bin/phaser inspect examples/phi4/model.json
./zig-out/bin/phaser export examples/phi4/model.json examples/phi4/request.json \
    --target=phaser --contributions --gradient
./zig-out/bin/phaser evaluate examples/phi4/model.json examples/phi4/request.json \
    examples/phi4/point.json --outputs=hessian --scan=0:0:600:13
```

## What to look for

With `m2 = -7812.5` and `lambda = 0.26` the stationary point sits at
$\phi_{\min}=\sqrt{-6m^2/\lambda}\approx 424.6$. In `scan.tsv` the gradient is
negative through $\phi=400$ and positive by $\phi=450$, so the minimum is
bracketed by the sampled interval, and the Hessian rises from $-7812.5$ at the
symmetric point to a positive value beyond the minimum.

Every coefficient in `equations.txt` is exact: `1/2` on the mass term and `1/24`
on the quartic are the orbit coefficients of
[Classical Scalar Potential](../../docs/calculations/CLASSICAL_SCALAR_POTENTIAL.md).

These files are the inputs the first Python notebook consumes in Milestone 4.
