# Decision 0001: Bounded exact arithmetic

Status: accepted for Milestone 1

## Context

Model expressions require exact integers, rationals, `pi`, and restricted exact
square roots. A fixed-width representation would impose an unnecessarily small
scientific boundary, while unbounded arithmetic would violate Phaser's resource
contract.

## Decision

Phaser uses Zig 0.16's standard-library arbitrary-precision integer primitives
behind a private Phaser adapter. Every parse and arithmetic operation is subject
to caller-selected limits no greater than the tested digit, exponent, bit, work,
scratch-byte, and persistent-byte ceilings. Published rationals are reduced and
have positive denominators.

No external arithmetic dependency is added. Canonical identity never hashes
native limb layout.

## Alternatives

A fixed-width integer was rejected because otherwise modest generated
coefficients can overflow despite remaining scientifically exact. An external
computer-algebra library was rejected because Milestone 1 requires only a small
exact domain and Phaser's dependency process found no concrete need for one.

## Revisit when

Revisit this decision if the pinned standard-library implementation cannot meet
measured workloads, if algebraic-number support expands materially, or if a
stable cross-version exact-value ABI is proposed.
