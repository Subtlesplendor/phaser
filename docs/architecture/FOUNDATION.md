# Foundation Types and Failure Reporting

Status: initial specification

This document specifies the small, domain-independent substrate shared by
Phaser's parsers, scientific representations, and public adapters. It owns the
contracts for typed local identifiers, source spans, checked capacity
arithmetic, resource budgets, allocator plumbing, and structured diagnostics.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

The foundation subsystem provides:

- semantically distinct local identifier types;
- source identifiers and byte spans;
- overflow-checked size and alignment arithmetic;
- transactional resource-budget accounting;
- a root context carrying allocation and limit policy; and
- structured, deterministic diagnostics.

It does not own model semantics, expression syntax, numerical policies,
serialization formats, C ABI layouts, or user-facing localization.

The subsystem MUST remain small. A type belongs here only when it is independent
of all scientific domains and prevents those domains from duplicating a
cross-cutting correctness contract.

## 2. Typed local identifiers

An identifier type is an opaque `u32` value created for one semantic tag.
Different tags produce different Zig types even when their representations are
identical.

An identifier:

- MUST be constructed from an integer through a checked conversion;
- MUST convert back to `usize` without loss on supported targets;
- MUST NOT reserve a sentinel value;
- MUST NOT be freely interchangeable with a different identifier type; and
- is local to the table, arena, or source registry that issued it.

Optional identifiers use the language's optional type rather than an integer
sentinel. Owners validate that an identifier is in range before indexing.
Local identifiers are not persisted scientific identities.

## 3. Source locations

`SourceId` is a typed local identifier for a source registry. `SourceSpan`
contains:

- one `SourceId`;
- an inclusive zero-based byte start; and
- an exclusive zero-based byte end.

The invariant is `start <= end <= source_length`. Empty spans are valid and
locate insertion points or missing tokens.

Offsets count bytes in the decoded source buffer, not Unicode scalar values,
grapheme clusters, or display columns. Line and column values are derived from
the owned or borrowed source document when diagnostics are presented; they are
not stored redundantly in the span.

Creating a span from external values MUST validate the invariant and return a
structured diagnostic on failure. Code operating on a span from a validated IR
MAY assert the invariant.

The version 0.1 span representation uses `u32` offsets. A source document whose
length cannot be represented is rejected before span construction. Milestone 1
will select a substantially smaller parser hard limit.

## 4. Checked capacity arithmetic

All byte sizes, element counts, offsets, and alignment adjustments influenced by
external data use checked arithmetic.

Foundation operations cover at least:

- addition;
- multiplication;
- conversion to and from `usize`; and
- forward alignment to a nonzero power-of-two alignment.

Overflow, invalid alignment, and loss during conversion are ordinary errors.
They MUST NOT wrap, saturate, panic, or silently reduce a request.

Zero is a valid count and byte size. Aligning zero produces zero. An alignment
of zero or a non-power-of-two alignment is invalid.

## 5. Resource budgets

A resource budget records:

- a resource category;
- a hard limit in units declared by that category;
- current usage; and
- peak committed usage.

Reservation is transactional:

```text
old usage
   |
   +-- request fits --> commit new usage and update peak
   |
   `-- overflow/excess --> return diagnostic; preserve old usage and peak
```

An exact-limit reservation succeeds. Releasing more than the committed usage is
an internal invariant violation. Optional caches, when introduced, use separate
budgets from required calculation storage.

Version 0.1 accounts requested usable bytes and explicit alignment padding.
Allocator-private metadata is not charged because it is not portably
observable. The backing allocator may still return `OutOfMemory` below a Phaser
budget; that remains distinct from `capacity_exceeded`.

## 6. Context and allocation

The Zig root context is created from:

- a caller-provided `std.mem.Allocator`; and
- validated resource limits.

It MUST NOT choose a default allocator or reach for a process-global,
thread-local, or operating-system allocator. Scientific constructors receive
the context or an explicitly derived allocator and budget.

Context initialization validates limit relationships without allocating where
practical. Objects using the context's allocator MUST be destroyed before that
allocator becomes invalid.

The initial context carries policy and plumbing only. It does not introduce a
general cache, persistent-object arena, fixed-buffer construction mode, or
reference-counted handle mechanism.

## 7. Diagnostic structure

A diagnostic contains structured data:

- a stable code and category;
- severity;
- optional primary source span;
- a typed detail payload;
- zero or more related locations; and
- an optional cause referring to an earlier diagnostic in the same set.

Foundation diagnostic categories cover configuration, source location,
capacity, and allocation failures. Scientific subsystems extend the code
catalog without changing the common record.

Diagnostic detail payloads carry machine-readable values such as:

- resource category;
- configured limit;
- current usage;
- requested increment or required total;
- invalid span bounds; and
- required alignment.

Exact human prose is not the stable contract. Rendering derives deterministic
text from the code and payload into a caller-provided writer. Rendering MUST
NOT mutate the diagnostic or require a global allocator.

## 8. Diagnostic ordering and ownership

Diagnostics are ordered by deterministic discovery order. Parallel producers,
when later introduced, merge task-local results by a defined canonical key.
Hash-map or allocator iteration order MUST NOT be exposed.

A mutable builder may allocate through the explicit context. Finishing the
builder transfers its complete storage into one logically immutable diagnostic
set. On any failure:

- no immutable set is published;
- builder-owned allocations remain reclaimable;
- a previously published set remains unchanged; and
- allocation failure is not misreported as a scientific validation error.

Cause references point only to earlier entries, making the cause graph acyclic
by construction. Related source locations preserve insertion order.

## 9. Error and assertion boundary

Invalid external values, unsupported requests, capacity exhaustion, and backing
allocator failure return errors. When an external boundary has enough context
to classify the failure, it also provides a structured diagnostic.

Assertions are reserved for trusted-state invariants, including:

- releasing unreserved budget;
- using an ID with the wrong owner or outside its validated table;
- constructing an immutable diagnostic set with invalid cause references; and
- observing a published object that borrows builder storage.

An assertion MUST NOT be the expected response to malformed external input.

## 10. Validation and testing

Foundation tests MUST cover:

- compile-time distinction and runtime round trips for typed IDs;
- zero-width, complete-source, reversed, and out-of-range spans;
- zero, exact, one-over, and near-`usize` capacity arithmetic;
- every invalid alignment class;
- transactional budget success and rollback;
- deterministic diagnostic equality, ordering, causes, and rendering;
- exhaustive allocation failure for diagnostic construction where practical;
- absence of leaks and partial publication; and
- bounded structured fuzzing of capacity-operation sequences against a wider
  exact oracle.

The default deterministic suite replays every committed fuzz seed. A bounded
coverage-guided campaign is exposed separately through the Zig build.

## 11. Deferred decisions

The following remain owned by later milestones:

- concrete parser and model default limits;
- source-document storage and line-index representation;
- localized or styled diagnostic presentation;
- stable C diagnostic codes and layouts;
- fixed-buffer construction;
- persistent-object region layout;
- allocator-private metadata estimation; and
- process-level memory statistics.
