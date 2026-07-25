# Foundation capacity fuzz target

Stable target identifier: `foundation_capacity`.

The target uses `std.testing.Smith` to generate one bounded sequence containing:

- checked `usize` addition;
- checked `usize` multiplication;
- alignment to one valid power of two; and
- two transactional budget reservations.

Addition, multiplication, and alignment are compared with a `u128` oracle.
Rejected budget reservations must preserve current and peak usage. The target
checks structured failure codes in addition to process survival.

The permanent seed corpus is under
`test/corpus/foundation_capacity/`. Ordinary `zig build test` and
`zig build fuzz` replay it. A bounded live campaign is:

```text
zig build fuzz -Doptimize=ReleaseSafe --fuzz=1000
```

Failures report the Zig-generated reproduction file. Minimize a failure where
practical, retain its original campaign metadata during triage, and commit the
permanent regression input to the target's corpus directory.
