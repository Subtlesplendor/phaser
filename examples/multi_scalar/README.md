# `multi_scalar`

A two-scalar theory with every scalar tensor kind populated, including the
off-diagonal components that distinguish the orbit-coefficient rule from a naive
$1/r!$.

## Files

| File | Role |
|---|---|
| `model.json` | Two real scalars `h` and `s`; vacuum energy, tadpole, mass-squared, cubic, quartic |
| `request.json` | Tree-level effective-potential request over the full scalar space |
| `point.json` | Parameter point with $m_h^2<0$ |
| `inspection.txt` | Golden output of the model-inspection example |
| `equations.txt` | Golden Phaser-notation equations, per contribution and summed |
| `equations.tex` | Golden delimiter-free MathJax fragment |
| `scan.tsv` | Golden sampled potential and gradient along `h`, with `s` held at zero |

## Reproducing

```sh
zig build
./zig-out/bin/phaser export examples/multi_scalar/model.json \
    examples/multi_scalar/request.json --target=phaser --contributions --gradient
./zig-out/bin/phaser evaluate examples/multi_scalar/model.json \
    examples/multi_scalar/request.json examples/multi_scalar/point.json \
    --outputs=gradient --format=tsv --scan=0:0:600:13
```

## What to look for

The quartic line of `equations.txt` reads

```text
1/24 * lh * h^4 + 1/6 * l3 * h^3 * s + 1/4 * l2 * h^2 * s^2
  + 1/6 * l1 * h * s^3 + 1/24 * ls * s^4
```

Those five coefficients are the whole orbit rule in one line. A component with
distinct-index multiplicities $m_v$ contributes $1/\prod_v m_v!$, giving
$1/24,\,1/6,\,1/4,\,1/6,\,1/24$ — not $1/24$ throughout, which is what treating
every component as diagonal would produce. The single-scalar `phi4` example
cannot distinguish those two rules; this one can.

`scan.tsv` varies `h` while holding `s` at exactly zero, which is the scan a
`component_slice` request would perform structurally.

These files are the inputs the first Python notebook consumes in Milestone 4.
