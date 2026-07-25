# Foundation and parser fuzz targets

The active target identifiers are:

- `foundation_capacity`;
- `expression_parser`; and
- `scalar_model_parser`.

`foundation_capacity` uses `std.testing.Smith` to generate bounded state-machine sequences
of at most 64 operations containing:

- checked `usize` addition;
- checked `usize` multiplication;
- valid and invalid alignment;
- transactional budget reservation; and
- valid release of committed budget.

Addition, multiplication, and alignment are compared with a `u128` oracle.
Budget current and peak usage are compared with an independent `u128` state
after every operation. Rejected arithmetic and reservation operations are
immediately repeated; they must return identical structured failures and
preserve all prior state.

The parser targets feed bounded arbitrary bytes into the expression and JSON
trust boundaries, repeat each operation, and compare diagnostics, canonical
expression output, or model fingerprints. Their permanent corpora are under
`test/corpus/expression_parser/` and `test/corpus/scalar_model_parser/`.

Ordinary `zig build test` and `zig build fuzz` replay every corpus. A bounded
live campaign is:

```text
zig build fuzz -Doptimize=ReleaseSafe --fuzz=1000
```

Failures report the Zig-generated reproduction file. Minimize a failure where
practical, retain its original campaign metadata during triage, and commit the
permanent regression input to the target's corpus directory.
