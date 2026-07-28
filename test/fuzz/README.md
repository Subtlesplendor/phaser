# Fuzz targets

The active target identifiers are:

- `foundation_capacity`;
- `expression_parser`;
- `scalar_model_parser`;
- `value_ir_builder`;
- `calculation_request_parser`;
- `symbolic_exporter`;
- `kernel_lowering`;
- `one_loop_pipeline`; and
- `parameter_point_parser`.

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

`value_ir_builder` and `kernel_lowering` share one generated construction
script, which covers the typed and structured node kinds as well as the real
scalar ones: explicit real-to-complex promotion, symmetric matrices of two
dimensions, structured element access, and the scalar spectral value. A
generated graph therefore reaches either result type, and `kernel_lowering`
selects its buffers from the lowered program's declared type, checks that
calling the other type's method is a call-level error, and checks that a failed
point publishes nothing.

`one_loop_pipeline` drives the whole order-one path -- matrix assembly, the
symmetric eigensolver, the spectral sum, the invariant gradient and Hessian,
and complex publication -- over a mass matrix `b` times a generated coefficient
matrix of dimension one to three. That shape keeps the derivative matrices
exact while letting a generated case choose the spectrum, so degenerate,
indefinite, zero, and non-finite spectra are all reachable. Its permanent
corpus is under `test/corpus/one_loop_pipeline/`; `status_independence.bin`
comes from the campaign that found a point reporting its neighbour's failure
status, whose fix is in `src/kernel/interpret.zig` and whose deterministic
regression test is in `test/conformance/scalar_one_loop.zig`.

Ordinary `zig build test` replays every committed corpus. Live coverage-guided
campaigns run nightly and may be launched manually before a high-risk parser,
model-loader, request-parser, kernel-lowering, ABI, or fuzz-harness change is
merged:

```text
zig build fuzz -Doptimize=ReleaseSafe --fuzz=1000
```

Failures report the Zig-generated reproduction file. Minimize a failure where
practical, retain its original campaign metadata during triage, and commit the
permanent regression input to the target's corpus directory.
