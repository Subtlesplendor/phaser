# Structural Compilation and Dynamic Binding

Status: provisional specification

This document specifies the boundary between structural derivation and dynamic
numerical evaluation in Phaser. It refines section 12 of
[DESIGN.md](../../DESIGN.md).

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative requirements.

Version 0.1 does not define a general exact-assumption specialization system.

## 1. Purpose

Phaser derives a calculation once and evaluates it many times. Parameter scans
MUST NOT repeat model validation, diagram generation, tensor analysis, or
symbolic construction for every parameter or background point.

The architecture distinguishes:

- scientific structure fixed by the model and calculation;
- kernel configuration fixed by numerical lowering; and
- numerical values supplied through bindings and evaluation.

A numerical value that happens to be zero is not an identically zero
interaction.

## 2. Lifecycle

```text
source model + calculation request
                |
                v
       planning and derivation
                |
                v
       calculation artifact
                |
                v
          kernel lowering
                |
                v
        numerical kernel
                |
                v
    immutable dynamic binding
                |
                v
       repeated evaluation
```

Each published object is immutable once valid. Creating another binding does not
mutate the kernel or its scientific structure.

## 3. Stage-relative structure

### 3.1 Scientific structure

Scientific structure affects planning or derivation and includes, as
applicable:

- canonical model meaning and field content;
- index-space dimensions and canonical tensor structure;
- calculation kind;
- background parametrization;
- environment kind;
- gauge-fixing family and parameter-channel relations;
- renormalization scheme;
- requested perturbative orders; and
- requested contribution classes.

Changing scientific structure requires a new calculation artifact.

### 3.2 Kernel configuration

Kernel configuration affects lowering without changing the upstream scientific
artifact. It includes, as applicable:

- numerical scalar type and precision;
- backend and target;
- derivative capabilities;
- reproducibility policy;
- numerical implementations of special functions;
- matrix and contraction strategy;
- batch or workspace policy; and
- explicit numerical approximation policies.

Changing kernel configuration produces a distinct kernel. An approximation that
changes scientific content belongs in the calculation request, not in a hidden
backend option.

### 3.3 Dynamic inputs

Dynamic inputs include:

- model masses and couplings;
- renormalization scale;
- non-fixed gauge-parameter values;
- temperature and other environment values;
- background coordinates; and
- runtime batch length.

Changing a dynamic input MUST NOT implicitly re-plan, re-derive, or recompile the
generic calculation.

## 4. Structural zeros

A structural zero is an expression or contribution proven identically zero from
validated structural information. Examples include:

- an omitted tensor kind;
- a component removed by exact normalization;
- a gauge contribution in a model with no gauge vectors; and
- a diagram class impossible for the available vertices.

Planning and derivation MAY prune structural zeros. Artifact-level support
metadata MUST still distinguish:

- supported and structurally zero;
- excluded by request; and
- unsupported.

A value that evaluates to zero at one parameter point is not structural.
Crossing zero during a scan MUST NOT trigger recompilation or pruning.

## 5. Immutable binding

Binding associates numerical values with the typed input channels declared by a
kernel. A binding operation MUST:

- require every necessary channel exactly once;
- reject unknown or duplicate channels;
- validate domains, dimensions, shapes, and finiteness policies;
- preserve distinctions among parameter, scale, gauge, and environment inputs;
- establish all prerequisites required by evaluation;
- leave the kernel unchanged; and
- publish either one complete immutable binding or no binding.

Binding is control-plane work and MAY allocate. A new parameter or environment
point initially produces a new binding. Binding MUST NOT repeat model validation,
scientific derivation, or kernel lowering.

Fresh bindings created with the same values MUST evaluate equivalently under the
same numerical and reproducibility policy.

## 6. Staged binding and reuse

An implementation MAY expose binding in stages where inputs naturally change at
different frequencies:

```text
kernel
  -> bind model parameters, scale, and gauge parameters
  -> bind temperature-dependent state
  -> evaluate background points
```

Only stages needed by an implemented calculation should become public objects.
A vacuum scalar calculation does not need an environment-binding abstraction.

Binding MAY precompute numerical subexpressions whose dependencies are already
fixed. Dependency analysis MUST be conservative and derived from the validated
value or kernel graph rather than an unrelated handwritten list.

Version 0.1 need not implement incremental invalidation inside a mutable
binding. Reconstructing the affected immutable binding is correct. Dependency-
directed incremental rebinding is a future optimization that requires benchmark
evidence.

## 7. Future explicit specialization

A future specialization capability may promote exact assumptions, such as a
coupling being identically zero or two channels being equal, into structural
information. It is deliberately outside version 0.1.

Before adoption, a specialization specification must define:

- the supported exact predicates;
- public syntax and validation;
- artifact and kernel provenance;
- exposed validity domains;
- input-layout changes;
- identity or lookup behavior; and
- equivalence tests against the generic calculation on the valid domain.

Phaser MUST NOT infer specialization from a bound floating-point value, a
tolerance, scan history, or a cache entry.

Until such a capability exists, a caller constructs a distinct model or
calculation request when an assumption is scientifically structural.

## 8. RG evolution, thresholds, and model changes

RG evolution changes dynamic parameter values and normally does not change
calculation structure. A coupling running through zero does not cause implicit
specialization.

Crossing a threshold may require a different active EFT, matching relation, or
field content. Such a change produces a distinct model and calculation artifact;
it is not ordinary rebinding.

## 9. Inspection

Artifacts and kernels MUST expose enough metadata for callers to determine:

- their structural calculation choices;
- their free dynamic input channels;
- kernel configuration;
- supported evaluation domain; and
- structurally absent, excluded, and unsupported contribution classes at a
  compact artifact-summary level.

Detailed derivation traces are optional audit data. They are not required on
every contribution in the production representation.

## 10. Validation and testing

Required version 0.1 tests include:

- parameter changes do not alter generic calculation structure;
- scanning through a dynamic zero does not trigger recompilation;
- no tolerance is used to infer structural equality;
- structurally absent and unsupported contributions remain distinguishable;
- bindings created with identical values agree;
- failed binding construction publishes no partial object;
- changing each input affects a conservative superset of its dependent
  precomputations;
- model changes and kernel-configuration changes rebuild the appropriate stage;
  and
- zero-coupling limits agree with independently constructed reduced models where
  the theories are genuinely equivalent.

Property tests MAY generate dependency graphs and input mutations, comparing
binding precomputation with complete recomputation. Stateful fuzzing of mutable
rebind rollback and specialization predicates is not a version 0.1 requirement.

## 11. Deferred decisions

- Mutable allocation-free rebinding.
- Public environment-binding stages beyond implemented needs.
- Incremental dependency-directed invalidation.
- Bound-state caching.
- Exact-assumption specialization syntax and predicates.
- Backend-specific partial evaluation.
- Threshold-matching and EFT-switching workflows.
