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
| `request_one_loop.json` | Order-one effective-potential request in $\overline{\text{MS}}$ |
| `equations_one_loop.txt` | Golden Phaser-notation equations through one loop |
| `equations_one_loop.tex` | Golden delimiter-free MathJax fragment through one loop |
| `scan_tree.tsv` | Golden tree contribution, sampled on the shared grid |
| `scan_one_loop.tsv` | Golden scalar one-loop contribution on the same grid |
| `scan_total.tsv` | Golden summed truncation on the same grid |

## Reproducing

```sh
zig build
./zig-out/bin/phaser inspect examples/phi4/model.json
./zig-out/bin/phaser export examples/phi4/model.json examples/phi4/request.json \
    --target=phaser --contributions --gradient
./zig-out/bin/phaser evaluate examples/phi4/model.json examples/phi4/request.json \
    examples/phi4/point.json --outputs=hessian --format=tsv --scan=0:0:600:13
./zig-out/bin/phaser export examples/phi4/model.json \
    examples/phi4/request_one_loop.json --target=latex
```

The three order-one scans differ only in `--selection`:

```sh
for selection in loop:0 loop:1 total; do
  ./zig-out/bin/phaser evaluate examples/phi4/model.json \
      examples/phi4/request_one_loop.json examples/phi4/point.json \
      --outputs=gradient --format=tsv --selection=$selection --scan=0:0:600:13
done
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

The order-one files share that background grid, so the three scans line up row
by row and `scan_total.tsv` is exactly `scan_tree.tsv` plus `scan_one_loop.tsv`.
Their `value.re`/`value.im` column pair carries the principal-branch complex
result of
[Scalar One-Loop Effective Potential](../../docs/calculations/SCALAR_ONE_LOOP_EFFECTIVE_POTENTIAL.md):
the field-dependent mass-squared $m^2+\tfrac12\lambda\phi^2$ is negative below
$\phi\approx245.2$ and positive above it, so the sampled interval crosses the
branch and `value.im` falls to exactly zero at $\phi=250$. `equations_one_loop.txt`
keeps the spectral operation and its mass matrix symbolic rather than
diagonalizing them.

These files are the inputs the first Python notebook consumes in Milestone 4.
