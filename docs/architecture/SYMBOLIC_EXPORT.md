# Symbolic Export and Notebook Display

Status: initial specification

This document specifies symbolic inspection, target rendering, and Jupyter
notebook display in Phaser. It refines section 21 of
[DESIGN.md](../../DESIGN.md).

The key words MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are to be interpreted as
requirements on Phaser implementations.

## 1. Scope

This specification covers both the initial targets and the later Wolfram
Language milestone:

- authoritative inputs to symbolic export;
- scientific selection before rendering;
- exact expression rendering;
- human-readable Phaser notation;
- MathJax-compatible LaTeX;
- Python and Jupyter rich display;
- Wolfram Language export;
- presentation labels;
- complete exports and bounded previews;
- deterministic output and resource limits; and
- exporter validation and fuzzing.

It does not define a stable calculation-artifact interchange format, a public
canonical JSON AST, complete standalone LaTeX documents, notebook widgets, or
round-trip import from every target.

## 2. Governing principles

- Exporters consume the Derived Physics IR, Typed Value IR, and their scientific
  metadata.
- The Numerical Kernel IR is not an authoritative symbolic source.
- Scientific contribution selection occurs before target rendering.
- Rendering MUST NOT silently change, approximate, or simplify scientific
  content.
- Exact values remain exact where the target can represent them.
- Target limitations and any deliberate loss of structure are explicit.
- Complete exports are complete or fail clearly.
- Automatic rich-display previews are bounded and visibly identify omissions.
- Presentation metadata does not alter scientific content identity.
- Jupyter consumes the LaTeX representation; it is not a separate symbolic
  language.

## 3. Export pipeline

The conceptual pipeline is:

```text
Derived Physics IR / Typed Value IR
                |
                v
     explicit contribution selection
                |
                v
        symbolic export view
                |
                v
      target-specific renderer
         /       |        \
      LaTeX   Phaser     Wolfram (later milestone)
         |
         v
  Python rich-display adapter
         |
         v
    Jupyter / MathJax
```

Selection, presentation construction, and rendering are distinct operations.

## 4. Symbolic export view

A symbolic export view is an immutable bounded description of what will be
rendered. It references or owns:

- selected scientific objects;
- contribution selection and summation policy;
- loop and perturbative orders;
- background-coordinate definitions;
- dependencies on parameters, scales, temperature, gauge parameters, and other
  environmental state;
- gauge and renormalization context;
- future structural assumptions, if implemented;
- approximation metadata;
- provenance requested for display; and
- presentation options.

The exact internal type is deferred. It is not a new scientific artifact format
and has no independent persistence guarantee.

An exporter MUST NOT independently decide which loop orders or contribution
classes to include. Selection uses the artifact APIs specified by
[Effective-Potential Artifact](../calculations/EFFECTIVE_POTENTIAL.md).

## 5. Scientific preservation

An export MUST retain or accompany, as applicable:

- the identity or unambiguous description of the exported scientific object;
- model and calculation context;
- contribution selection;
- perturbative order;
- background parametrization;
- renormalization scheme and scale dependence;
- gauge-fixing family and gauge-parameter dependence;
- future exact structural assumptions, if implemented;
- approximation policies;
- matrix and spectral-operation semantics; and
- provenance.

Presentation options MAY omit metadata from the visible equation only when the
metadata remains available alongside the export or the caller explicitly asks
for an expression-only fragment.

An expression-only fragment MUST NOT be presented as a complete self-describing
calculation artifact.

## 6. Exact expression rendering

Renderers MUST preserve:

- integers;
- exact rational coefficients;
- symbolic constants such as `pi`;
- sums, products, powers, and function application;
- operand order where semantically relevant;
- field, tensor, and dummy indices;
- matrices and indexed contractions;
- explicit spectral operations;
- background-coordinate relationships; and
- distinctions between structurally absent, unsupported, and zero terms where
  the containing export exposes them.

An exact rational such as \(3/4\) MUST NOT be rendered as `0.75` unless the
caller explicitly requests a numerical approximation export.

The renderer MAY apply presentation-only rewrites such as:

- conventional unary minus;
- omission of multiplication signs where unambiguous;
- redundant-parenthesis removal;
- fraction layout;
- canonical spacing; and
- line breaking.

It MUST NOT perform target-dependent algebraic simplification, cancellation,
factorization, numerical evaluation, resummation, or contribution removal.
Those are explicit upstream transformations.

## 7. Matrices, contractions, and spectra

Closed-form eigenvalues are not required for symbolic export.

A target MAY represent spectral structure using:

- an explicit matrix with a named spectral operation;
- eigenvalue notation;
- a trace of a function of a matrix;
- a finite component sum already present in the artifact; or
- an explicitly named Phaser operation.

The chosen representation MUST preserve semantics and document any assumptions.
An exporter MUST NOT expand a compact contraction or matrix operation merely
because the target can express component sums.

Expansion, common-subexpression extraction, or introduction of named temporary
definitions is an explicit rendering option. Any introduced definitions are
deterministic and exactly equivalent to the source expression.

## 8. Background parametrization

Every export of a background-dependent object follows
[Background Parametrization](../formats/BACKGROUND_PARAMETRIZATION.md).

The visible expression MAY use only selected background coordinates. The export
must nevertheless make the coordinate-to-full-scalar embedding available and
must not imply that unselected scalar fluctuations were removed.

Objects carrying full scalar indices retain their relationship to every model
scalar component.

The default effective-potential equation SHOULD make relevant dependencies
visible, conceptually:

```text
V_eff(phi; T, mu, xi)
```

Exact notation is target-specific and omits variables proven absent by artifact
dependency metadata.

## 9. Presentation layer

Human-oriented renderers MAY share a private presentation tree with concepts
such as:

```text
MathLayout {
    identifier
    number
    sum
    product
    fraction
    power
    function
    indexed
    matrix
    equation
    aligned_equations
    annotation
}
```

This presentation tree:

- is derived from validated scientific IR;
- has no numerical execution role;
- has no scientific content identity;
- is not a public serialization contract; and
- MAY change when rendering requirements evolve.

Its purpose is to centralize precedence, parentheses, grouping, line breaking,
and matrix layout for plain-text and LaTeX renderers.

A semantic target such as Wolfram Language MAY render directly from Typed Value
IR when an intermediate presentation tree would lose target meaning.

## 10. Identifiers and presentation labels

Semantic identifiers and presentation labels are distinct.

A semantic identifier participates in model APIs and content identity. A LaTeX
label, descriptive label, or typography preference does not.

The default renderer MUST safely escape arbitrary semantic identifiers. It MUST
NOT interpret ordinary identifier text as raw LaTeX or target-language source.

Optional target-specific labels MAY be supported later. If supported, they must:

- be explicitly marked as presentation metadata;
- follow a defined validation and trust policy;
- remain excluded from scientific identity;
- avoid ambiguity between distinct visible objects; and
- have a safe fallback to the semantic identifier.

If two distinct semantic objects receive the same visible label in one export,
the renderer MUST reject the ambiguous configuration or visibly disambiguate it.

## 11. Target classes

Phaser distinguishes presentation targets from semantic syntax targets.

### 11.1 Human-readable Phaser notation

Human-readable Phaser notation SHOULD provide a compact plain-text
representation suitable for:

- terminals;
- logs and diagnostics;
- Python `repr`;
- test failures; and
- copying simple expressions.

Derived operations that are not legal in the QFT Model source-expression
language may use explicit Phaser-specific notation.

Parseability is guaranteed only for a deliberately specified subset. The
exporter MUST NOT imply round-trip source compatibility for unsupported derived
constructs.

### 11.2 LaTeX

The initial LaTeX target is a delimiter-free mathematical fragment compatible
with the MathJax subset used by Jupyter.

The core returns content conceptually like:

```latex
V_{\mathrm{eff}}(\varphi;T,\mu,\xi)
=V^{(0)}(\varphi)+V^{(1)}(\varphi;T,\mu,\xi)
```

It does not include:

- `$`, `$$`, `\(`, or `\[` delimiters;
- a document class;
- a preamble;
- `\begin{document}`;
- package imports; or
- frontend-specific HTML.

The consumer chooses inline or display delimiters and environments.

The initial profile SHOULD avoid package-dependent macros. Standalone documents,
custom macro packages, equation numbering, and cross-references are future
presentation features.

### 11.3 Wolfram Language

Wolfram Language export is a semantic target. It SHOULD preserve exact numbers,
symbolic operations, matrices, indices, and dependencies using target-native
constructs or documented Phaser-specific heads.

Unknown or unsupported operations MUST produce a diagnostic rather than
plausible-looking but altered code.

Executable target output does not imply round-trip import into Phaser.

### 11.4 Canonical JSON AST

A public canonical JSON expression AST is deferred. Defining one would establish
a symbolic interchange and compatibility contract beyond presentation.

Internal diagnostic JSON MAY exist under its own explicitly unstable version,
but MUST NOT be advertised as a stable public export format.

## 12. Python and Jupyter

Jupyter notebook display uses the MathJax-compatible LaTeX renderer.

Notebook delivery and validation milestones follow
[Implementation Roadmap](IMPLEMENTATION_ROADMAP.md).

Python expression and contribution objects SHOULD support rich display through
`_repr_latex_` or an equivalent MIME-bundle implementation. The adapter wraps
the delimiter-free core fragment in the form required by the frontend.

Conceptually:

```python
def _repr_latex_(self):
    return rf"$\displaystyle {self.to_latex()}$"
```

This is illustrative rather than a fixed class signature.

The Python package MUST NOT require IPython or Jupyter merely to implement this
protocol. A normal plain-text `repr` remains available outside notebooks.

Conceptual explicit methods include:

```python
expression.to_latex()
expression.to_phaser()
expression.to_wolfram()
```

Exact names and option objects remain to be designed with the Python API.

Using `print(expression)` produces plain text. Displaying the object as the last
notebook expression, or passing it to the notebook display mechanism, selects
the rich LaTeX representation.

## 13. Expressions, contributions, and artifacts

An individual expression MAY render directly as mathematics.

A contribution SHOULD identify its role and order, conceptually:

```text
V_eff^(1, scalar)(phi) = ...
```

An entire effective-potential artifact may be much larger. Its default rich
representation SHOULD be a bounded summary containing, as practical:

- calculation kind;
- background coordinates;
- loop orders;
- contribution count;
- dependency summary; and
- a complete equation only when it fits the preview budget.

The complete artifact remains explicitly exportable with a selected contribution
view.

## 14. Complete exports and previews

A complete export MUST either:

- emit the entire requested representation; or
- return an explicit resource or unsupported-operation diagnostic.

It MUST NOT silently truncate.

An automatic notebook or diagnostic preview MAY apply stricter limits on:

- expression nodes;
- terms;
- output bytes;
- lines;
- matrices; and
- displayed metadata.

A preview that omits content MUST state that it is incomplete and SHOULD report
the omitted count or complete object size when known. An unmarked ellipsis is
not sufficient.

Conceptually:

```text
V_eff = [expression omitted from preview: 12481 nodes]
```

Preview output is presentation, not a scientific export artifact.

## 15. Output API and memory

Symbolic export is bounded control-plane work. It is not numerical evaluation
and may allocate through the explicit memory context.

The low-level implementation SHOULD support a bounded writer or an equivalent
size-query and caller-buffer interface. It MUST NOT require one unbounded
intermediate string.

The Python frontend MAY allocate a Python string after the core has established
the output requirement or while consuming a bounded writer.

Exporter traversal follows [Memory Architecture](MEMORY_ARCHITECTURE.md):

- user-dependent traversal uses bounded explicit worklists;
- size arithmetic is checked;
- output capacity failures are ordinary diagnostics;
- temporary layout memory does not escape; and
- failure does not publish a partial complete export.

Streaming output MAY expose bytes before a later failure. Such an API must be
explicitly distinguished from an atomic complete-export API.

## 16. Determinism and identity

For fixed:

- scientific source object;
- contribution selection;
- target;
- exporter version;
- presentation options; and
- resource-independent complete-output policy,

the output bytes MUST be deterministic.

Output MUST NOT depend on:

- arena IDs;
- allocation addresses;
- hash-table iteration;
- thread scheduling;
- locale;
- terminal width unless explicitly supplied; or
- notebook frontend.

Presentation options and labels do not alter model, request, artifact, or kernel
content identity. A separately stored export MAY have an `ExportContentId`
covering its source identity, selection, target, exporter version, and normalized
rendering options. The exact identity type is deferred.

## 17. Target limitations

Every exporter documents its supported Typed Value IR operations and container
objects.

If a target cannot faithfully represent an operation, the exporter must:

1. emit an explicit documented target-native representation;
2. emit a documented Phaser-specific symbolic head; or
3. fail with a diagnostic.

It MUST NOT:

- drop the operation;
- substitute a numerical value;
- take a real part;
- expand outside declared limits;
- change a branch convention; or
- emit syntactically valid but semantically different output.

## 18. Validation, testing, and fuzzing

Architecture-wide oracle and golden-file rules follow
[Verification and Testing](VERIFICATION_AND_TESTING.md).

Required common tests include:

- deterministic output independent of allocation and insertion order;
- correct precedence and parentheses;
- exact integers, rationals, and symbolic constants;
- arbitrary identifier escaping;
- stable dummy-index naming;
- collision handling for visible labels;
- scalar, indexed, matrix, contraction, and spectral examples;
- background-coordinate and full-field relationships;
- contribution selection independent of rendering;
- loop-order and provenance preservation;
- complete export versus visibly bounded preview;
- exact output-capacity boundaries;
- invalid IR rejection or assertion at the established trust boundary; and
- fuzzing valid Typed Value IR and presentation-option combinations.

Phaser-notation tests SHOULD parse exported expressions back where the supported
subset promises round trips.

Wolfram Language tests SHOULD compare semantics through an independent path when
one is available and explicitly approved for the test environment. Golden target
files are useful but are presentation evidence, not the sole correctness oracle.

LaTeX tests SHOULD include delimiter absence, balanced grouping produced by the
renderer, MathJax-profile restrictions, and representative notebook fragments.
Browser rendering is a presentation integration test, not a scientific oracle.

## 19. Staged implementation scope

The initial public-surface milestone implements:

1. human-readable Phaser notation for Typed Value IR;
2. delimiter-free MathJax-compatible LaTeX fragments;
3. Python rich display backed by the LaTeX renderer;
4. effective-potential contribution and artifact views.

The separate C++ and Wolfram Language interoperability milestone then implements
Wolfram Language export against the already exercised artifact and selection
contracts.

A stable JSON AST, standalone LaTeX documents, custom target labels, notebook
widgets, and general import are deferred.

## 20. Deferred decisions

This specification deliberately leaves open:

- exact exporter and option type names;
- the private presentation-tree node set;
- initial preview limits;
- supported presentation-label syntax and trust policy;
- common-subexpression and temporary-definition options;
- the parseable subset of derived Phaser notation;
- Wolfram names for Phaser-specific spectral operations;
- low-level C writer and buffer signatures;
- whether stored exports receive typed content IDs;
- standalone LaTeX document support; and
- the eventual scope and versioning of a public JSON AST.

## 21. References

- [Jupyter Notebook: LaTeX equations in Markdown](https://jupyter-notebook.readthedocs.io/en/stable/examples/Notebook/Working%20With%20Markdown%20Cells.html)
- [IPython display API and rich representations](https://ipython.readthedocs.io/en/stable/api/generated/IPython.display.html)
