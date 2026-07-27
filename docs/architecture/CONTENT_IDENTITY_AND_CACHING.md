# Content Fingerprints and Deferred Caching

Status: provisional specification

The minimal fingerprint contract is implemented across `src/model/`,
`src/calculation/`, and `src/kernel/binding.zig`. The deferred-caching
boundary it defines is still the active contract cited by
[POTENTIAL_KERNEL.md](POTENTIAL_KERNEL.md) and
[EVALUATION_LIFECYCLE.md](EVALUATION_LIFECYCLE.md), so it is kept in full
rather than compressed.

This document specifies the minimal deterministic fingerprint contract required
by Phaser version 0.1 and defines the boundary behind which richer identity and
cache systems are deferred. It refines section 15 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

## 1. Scope

Phaser version 0.1 needs deterministic scientific objects and useful diagnostic
fingerprints. It does not require a general object cache, persistent artifact
identity, or cross-process cache compatibility.

The initial contract covers:

- a deterministic canonical-model fingerprint;
- normalized calculation requests;
- typed in-memory lookup keys when an implementation has a measured reuse need;
- ordinary object metadata sufficient to reproduce a calculation; and
- rules that prevent an optional cache from changing scientific behavior.

It does not define:

- physical equivalence of differently represented QFTs;
- `ArtifactContentId`, `ParameterPointContentId`, or a family of public digest
  types;
- a persistent disk-cache format;
- remote or distributed caches;
- cross-build identity of internal IR;
- hash-based equality of arbitrary produced objects; or
- a general specialization-identity system.

## 2. Determinism before identity

Canonical models, normalized requests, contribution order, symbolic exports,
diagnostics, and numerical lowering MUST be deterministic under their declared
contracts. Determinism is required independently of whether an object is hashed
or cached.

Internal arena IDs, pointer values, allocation order, hash-map iteration order,
and thread scheduling MUST NOT appear in canonical scientific output.

A fingerprint is a compact diagnostic and lookup aid. It is not proof of
physical equivalence, mathematical equality beyond the canonicalization
contract, or successful validation.

## 3. Model fingerprint

`ModelFingerprint` is computed from an unambiguous canonical encoding of the
validated model. It covers every scientifically semantic model property,
including:

- source-schema and canonicalization versions;
- spacetime dimension and conventions;
- ordered field and index spaces;
- parameter declarations;
- canonical tensors; and
- exact normalized model expressions.

It excludes:

- JSON whitespace and semantically irrelevant object-member order;
- source file paths and spans;
- descriptions, display labels, and LaTeX; and
- allocation and local arena IDs.

Field-array order remains semantic where the model format defines component
layout. Phaser does not search for field permutations or basis transformations
that make separately authored models equivalent.

The fingerprint encoding MUST be domain-separated and versioned. The exact
digest algorithm and external spelling are implementation choices until a
public persisted consumer requires a stable contract.

Milestone 1 uses SHA-256 from the pinned Zig standard library over the private
domain `model-canonical/1`. Exact integers are encoded by sign and minimal
big-endian magnitude rather than native limbs. `ModelFingerprint` is an opaque
32-byte diagnostic value; neither its hexadecimal rendering nor the complete
canonical byte stream is a stable interchange contract.

## 4. Calculation and kernel metadata

A normalized calculation request plus a `ModelFingerprint` identifies the
scientific inputs to planning and derivation for diagnostic purposes.

Artifacts and kernels MUST retain enough explicit metadata to state:

- the model fingerprint and normalized request;
- scientific conventions and contribution selection;
- backend, scalar type, derivative capabilities, and numerical policies;
- the Phaser build or formula version needed to interpret the object; and
- any other option that can affect supported behavior or results.

Version 0.1 does not require a canonical hash of the complete produced artifact
or kernel. In particular, it need not remap and hash every arena-local reference
after derivation. Implementations MAY expose opaque process-local object IDs for
logs and handles.

Milestone 2 fingerprints the normalized calculation request with SHA-256 over
the private domain `calculation-request-canonical/1`, mirroring the model
fingerprint construction of section 3. The encoding covers the calculation kind,
background mode and complete coordinate-to-scalar map in declared order,
environment kind, loop truncation, and renormalization scheme when present. It
excludes presentation metadata. The normalization rules are specified in
[Effective-Potential Calculation Request §10](../formats/EFFECTIVE_POTENTIAL_REQUEST.md).

## 5. Parameter points

Parameter points are validated semantic values associated with a model. Version
0.1 converts accepted finite JSON numbers directly to the supported numerical
scalar type, initially `f64`, under a documented conversion policy.

Equivalent source spellings are not required to have a persistent exact-decimal
identity. If an application needs a reproducible parameter-set label, it SHOULD
provide one or serialize the validated `f64` values using a canonical
type-specific encoding.

Support for a future scalar type MAY add a corresponding direct parser without
changing model semantics.

## 6. Explicit reuse before caches

The primary version 0.1 reuse mechanism is object ownership:

```text
canonical model
    -> reusable calculation artifact
    -> reusable numerical kernel
    -> one or more immutable bindings
    -> repeated evaluations
```

Keeping these objects alive avoids repeated parsing, derivation, and lowering.
No cache is required to satisfy the derive-once, evaluate-many requirement.

An implementation MAY add a small explicit in-memory memo table when a measured
workflow repeatedly requests the same transformation. Its typed lookup key MUST
contain every input and implementation version that can affect the produced
object. A miss, refusal, eviction, or disabled table MUST NOT change scientific
results.

## 7. Deferred cache requirements

Before Phaser introduces a general in-memory cache, its specification must
define:

- the concrete repeated-workload benefit;
- ownership and memory budgets;
- typed transformation keys;
- collision handling appropriate to the selected key representation;
- publication of complete immutable entries only;
- concurrency and eviction behavior; and
- tests proportional to the cache's trust boundary.

A persistent cache additionally requires:

- stable or explicitly versioned serialization;
- corruption and truncation detection;
- atomic file publication;
- compiler, target, and dependency compatibility;
- concurrent-process coordination; and
- recovery and eviction policy.

These obligations are not version 0.1 implementation or test requirements.

## 8. Validation and testing

Required version 0.1 tests include:

- irrelevant JSON whitespace and object order do not change
  `ModelFingerprint`;
- every tested semantic model change changes the fingerprint;
- presentation metadata does not change the fingerprint;
- field order affects the fingerprint where it defines component layout;
- allocation and insertion order do not affect canonical model output or its
  fingerprint;
- normalized calculation requests are deterministic;
- explicitly retained model, artifact, and kernel objects can be reused without
  changing results; and
- any implemented memo table produces equivalent results on hit, miss, refusal,
  and disabled paths.

Injected digest-collision tests, cache-eviction fuzzing, bound-state cache keys,
and concurrent cache-state testing are required only when the corresponding
cache mechanism exists.

## 9. Deferred decisions

- Stable public fingerprint spelling and digest algorithm.
- Canonical artifact and kernel content identities.
- Exact-decimal parameter-point identities.
- General transformation-key types.
- In-memory cache ownership and eviction.
- Bound-state caches.
- Persistent or distributed cache formats.
- Name-insensitive or basis-insensitive equivalence identifiers.
