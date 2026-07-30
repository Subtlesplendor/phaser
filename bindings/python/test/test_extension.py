"""Tests for the native Phaser extension and the objects over it.

Run through ``zig build test-python``, which builds the extension, installs it
where an interpreter can find it, and runs this file with that interpreter.

These tests are written against the interpreter rather than against the Zig
types behind it, because what matters here is what an importing interpreter
sees: whether the module loads at all, whether its results match the C ABI, and
whether a rejected document raises rather than returning something wrong.

The standard library's ``unittest`` is used deliberately. Decision 0015 approved
a Python dependency set for the binding and the notebook; a test runner was not
in it, and nothing here needs one.
"""

import array
import gc
import os
import sys
import unittest
from pathlib import Path

import phaser
from phaser import _phaser

# The smallest valid model: two parameters and one real scalar field. Kept here
# rather than shared with the Zig fixtures so a change to one cannot silently
# change what the other asserts.
VALID_MODEL = b"""{
  "schema": "phaser.qft-model/0.1",
  "spacetime_dimension": 4,
  "conventions": {
    "metric": "mostly_plus",
    "scalar_representation": "real_components",
    "fermions": "two_component_weyl"
  },
  "parameters": {
    "lambda": {"domain": "real", "mass_dimension": 0},
    "m2": {"domain": "real", "mass_dimension": 2}
  },
  "fields": {
    "real_scalars": [{"id": "phi"}],
    "weyl_fermions": [],
    "gauge_vectors": []
  },
  "tensors": {
    "scalar_mass_squared": {
      "components": [{"indices": ["phi", "phi"], "value": "m2"}]
    },
    "scalar_quartic": {
      "components": [{"indices": ["phi", "phi", "phi", "phi"], "value": "lambda"}]
    }
  }
}
"""

ONE_LOOP_REQUEST = b"""{
  "schema": "phaser.calculation/0.1",
  "kind": "effective_potential",
  "background": { "mode": "full_scalar_space" },
  "environment": { "kind": "vacuum" },
  "renormalization": { "scheme": "MSbar" },
  "orders": { "loop": { "through": 1 } }
}
"""

# Individually valid, but it names a scalar this model does not have. That is
# the derive-time rejection: neither document is wrong on its own.
MISMATCHED_REQUEST = b"""{
  "schema": "phaser.calculation/0.1",
  "kind": "effective_potential",
  "background": {
    "mode": "component_slice",
    "coordinates": [{"id": "h", "scalar": "nonexistent"}]
  },
  "environment": { "kind": "vacuum" },
  "renormalization": { "scheme": "MSbar" },
  "orders": { "loop": { "through": 1 } }
}
"""

TREE_REQUEST = b"""{
  "schema": "phaser.calculation/0.1",
  "kind": "effective_potential",
  "background": { "mode": "full_scalar_space" },
  "environment": { "kind": "vacuum" },
  "renormalization": { "scheme": "MSbar" },
  "orders": { "loop": { "through": 0 } }
}
"""

# The field-dependent mass-squared is m2 + lambda * phi^2 / 2, negative below
# |phi| ~= 245 and positive above.
PARAMETER_POINT = b"""{
  "schema": "phaser.parameter-point/0.1",
  "units": { "mass": "GeV" },
  "renormalization": { "scheme": "MSbar", "reference_scale": 125.0 },
  "values": { "lambda": 0.26, "m2": -7812.5 }
}
"""


def build(request=ONE_LOOP_REQUEST, capability="value_gradient_hessian"):
    """Builds a binding over one shared context, as a client would."""
    context = phaser.Context()
    model = phaser.Model(VALID_MODEL, context=context)
    artifact = model.derive(phaser.Request(request, context=context))
    point = phaser.ParameterPoint(PARAMETER_POINT, context=context)
    return artifact.compile(capability).bind(point)


class TestInterpreterRequirements(unittest.TestCase):
    def test_interpreter_meets_the_documented_minimum(self):
        # The extension is built against the Limited API at 3.11, which is the
        # version from which the complete Py_buffer structure is part of the
        # Stable ABI. Running it on an older interpreter is not supported, and
        # this states that rather than leaving it to a confusing failure later.
        self.assertGreaterEqual(sys.version_info[:2], (3, 11))


class TestVersions(unittest.TestCase):
    def test_abi_version_is_zero(self):
        self.assertEqual(phaser.abi_version(), 0)

    def test_abi_reports_itself_experimental(self):
        # Milestone 4 requires that version 0 stay explicitly experimental, and
        # every surface has to say so, not just the header.
        self.assertIs(phaser.abi_experimental(), True)

    def test_library_version_is_a_three_part_tuple(self):
        version = phaser.library_version()
        self.assertIsInstance(version, tuple)
        self.assertEqual(len(version), 3)
        for part in version:
            self.assertIsInstance(part, int)
            self.assertGreaterEqual(part, 0)


class TestModelMetadata(unittest.TestCase):
    def test_a_valid_model_reports_its_counts(self):
        metadata = phaser.model_metadata(VALID_MODEL)
        self.assertEqual(metadata["parameter_count"], 2)
        self.assertEqual(metadata["scalar_field_count"], 1)

    def test_the_fingerprint_is_stable_and_well_formed(self):
        first = phaser.model_metadata(VALID_MODEL)["fingerprint"]
        second = phaser.model_metadata(VALID_MODEL)["fingerprint"]
        self.assertEqual(first, second)
        self.assertEqual(len(first), 64)
        # Hexadecimal, so it survives being written into a document or a log.
        int(first, 16)

    def test_whitespace_changes_do_not_change_the_fingerprint(self):
        # The fingerprint identifies the canonical model, not its source text.
        # A reformatted document is the same model.
        compact = b" ".join(VALID_MODEL.split())
        self.assertEqual(
            phaser.model_metadata(compact)["fingerprint"],
            phaser.model_metadata(VALID_MODEL)["fingerprint"],
        )

    def test_an_invalid_model_raises_with_its_diagnostic(self):
        with self.assertRaises(ValueError) as raised:
            phaser.model_metadata(b"{ not json")
        message = str(raised.exception)
        # The structured diagnostic reaches the exception, so a caller learns
        # why the document was rejected rather than only that it was.
        self.assertIn("model", message)
        self.assertIn("invalid_json", message)

    def test_a_semantically_invalid_model_also_raises(self):
        # Valid JSON, wrong schema. This goes down a different path in the
        # loader than a parse failure and must still surface as an exception.
        with self.assertRaises(ValueError):
            phaser.model_metadata(b'{"schema": "not.a.phaser.schema/0.1"}')

    def test_str_is_rejected_rather_than_guessed_at(self):
        # The binding takes bytes, so the caller decides the encoding. Accepting
        # str would mean guessing one.
        with self.assertRaises(TypeError):
            phaser.model_metadata(VALID_MODEL.decode())

    def test_empty_input_raises(self):
        with self.assertRaises(ValueError):
            phaser.model_metadata(b"")


class TestObjects(unittest.TestCase):
    def test_the_whole_lifecycle_reports_its_metadata(self):
        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        self.assertEqual(model.parameter_count, 2)
        self.assertEqual(model.scalar_field_count, 1)

        request = phaser.Request(ONE_LOOP_REQUEST, context=context)
        self.assertEqual(request.loop_order, 1)

        artifact = model.derive(request)
        self.assertEqual(artifact.loop_order, 1)
        self.assertEqual(artifact.coordinate_count, 1)
        self.assertGreater(artifact.contribution_count, 0)
        self.assertEqual(artifact.result_type, "complex64")

        kernel = artifact.compile()
        self.assertEqual(kernel.capability, "value_gradient_hessian")
        self.assertEqual(kernel.result_type, "complex64")
        self.assertEqual(kernel.coordinate_count, 1)
        self.assertEqual(kernel.parameter_count, model.parameter_count)

        point = phaser.ParameterPoint(PARAMETER_POINT, context=context)
        self.assertEqual(point.reference_scale, 125.0)

        binding = kernel.bind(point)
        self.assertEqual(binding.coordinate_count, 1)
        self.assertEqual(binding.result_type, "complex64")

    def test_a_tree_level_calculation_is_real(self):
        # The two result types are not a formatting choice: a tree-level
        # potential is real and a loop-containing one is not, and the binding
        # has to report which without the caller asking the physics.
        self.assertEqual(build(TREE_REQUEST).result_type, "real64")

    def test_repeated_construction_and_collection_is_clean(self):
        # A regression test with a specific history. Holding the parent objects
        # as attributes of the child is not enough to order destruction: when
        # the last reference to a binding goes, its instance dictionary is
        # released and the context inside it can be freed before the binding's
        # own handle. That destroyed a context while its children were live,
        # which the core's allocator reported as leaks and which then crashed.
        #
        # The ordering now lives in the capsules, so this loop is silent. It is
        # a weak test in isolation and a sharp one in context: the failure it
        # guards against was a segmentation fault within a few iterations.
        for _ in range(20):
            binding = build()
            binding.evaluate_at(100.0)
            del binding
            gc.collect()

    def test_a_binding_outlives_the_names_of_the_handles_it_needs(self):
        # Every intermediate goes out of scope inside build(). If any of them
        # were released early the evaluation below would read freed memory.
        binding = build()
        gc.collect()
        self.assertEqual(binding.evaluate_at(100.0).status, "ok")

    def test_objects_from_different_contexts_are_refused(self):
        model = phaser.Model(VALID_MODEL)
        request = phaser.Request(ONE_LOOP_REQUEST)
        with self.assertRaises(ValueError):
            model.derive(request)

    def test_a_handle_of_the_wrong_type_is_rejected(self):
        # The capsules are named and the name is checked, so a mistake at this
        # level raises rather than reinterpreting a pointer.
        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        with self.assertRaises(TypeError):
            _phaser.model_info(context._capsule)
        with self.assertRaises(TypeError):
            _phaser.kernel_info(model._capsule)

    def test_a_plain_object_is_not_a_handle(self):
        with self.assertRaises(TypeError):
            _phaser.model_info(object())


class TestDiagnostics(unittest.TestCase):
    """A rejected document reaches Python as inspectable structure.

    The rendered text alone was enough to say a document was rejected. It is
    not enough to act on one: a tool that wants to underline the offending
    span, or filter by severity, would have to parse the message back apart.
    """

    def rejected(self, *arguments, **keywords):
        constructor = arguments[0]
        with self.assertRaises(phaser.SourceError) as raised:
            constructor(*arguments[1:], **keywords)
        return raised.exception

    def test_the_error_is_still_a_value_error(self):
        # Callers that only want to know a document was rejected keep catching
        # what they always caught. The structure is additional, not a change.
        error = self.rejected(phaser.Model, b"{ not json")
        self.assertIsInstance(error, ValueError)

    def test_a_rejected_model_carries_its_diagnostics(self):
        error = self.rejected(phaser.Model, b"{ not json")
        self.assertGreater(len(error.diagnostics), 0)
        diagnostic = error.diagnostics[0]
        self.assertIsInstance(diagnostic, phaser.Diagnostic)
        self.assertIsInstance(diagnostic.code, int)
        self.assertEqual(diagnostic.severity, "error")
        self.assertEqual(diagnostic.category, "json")
        self.assertIn("invalid_json", diagnostic.message)
        self.assertEqual(diagnostic.related_count, 0)

    def test_the_summary_message_names_the_first_diagnostic(self):
        error = self.rejected(phaser.Model, b"{ not json")
        self.assertIn("model", str(error))
        self.assertIn(error.diagnostics[0].message, str(error))

    def test_a_primary_span_reaches_python_when_there_is_one(self):
        error = self.rejected(phaser.Model, b"{ not json")
        diagnostic = error.diagnostics[0]
        self.assertIsNotNone(diagnostic.start)
        self.assertIsNotNone(diagnostic.end)
        self.assertIsNotNone(diagnostic.source_id)
        self.assertLessEqual(diagnostic.start, diagnostic.end)

    def test_a_diagnostic_without_a_span_reports_none_rather_than_zero(self):
        # A span of [0, 0) is a location in the document. No span at all is
        # not, and collapsing the two would point a reader at the first byte
        # of a file the diagnostic has nothing to do with.
        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        request = phaser.Request(MISMATCHED_REQUEST, context=context)
        error = self.rejected(model.derive, request)

        diagnostic = error.diagnostics[0]
        self.assertEqual(diagnostic.category, "calculation")
        self.assertIn("invalid_background_coordinate", diagnostic.message)
        self.assertIsNone(diagnostic.source_id)
        self.assertIsNone(diagnostic.start)
        self.assertIsNone(diagnostic.end)

    def test_every_parse_path_raises_the_same_way(self):
        for what, constructor in [
            ("model", phaser.Model),
            ("request", phaser.Request),
            ("point", phaser.ParameterPoint),
        ]:
            with self.subTest(document=what):
                error = self.rejected(constructor, b"{ not json")
                self.assertGreater(len(error.diagnostics), 0)
                self.assertIn(what, str(error))

    def test_the_enumerators_are_named_rather_than_numbered(self):
        error = self.rejected(phaser.Model, b'{"schema": "not.a.phaser.schema/0.1"}')
        diagnostic = error.diagnostics[0]
        self.assertIn(diagnostic.severity, phaser.SEVERITIES.values())
        self.assertIn(diagnostic.category, phaser.CATEGORIES.values())

    def test_diagnostics_survive_the_source_bytes_they_describe(self):
        # The C ABI promises a diagnostics handle does not borrow from the
        # source buffer. The extension copies the rendering out before the
        # handle is destroyed, so this holds in Python for a stronger reason,
        # and the test states the guarantee a caller relies on.
        source = bytearray(b"{ not json")
        error = self.rejected(phaser.Model, bytes(source))
        source[:] = b"          "
        del source
        gc.collect()
        self.assertIn("invalid_json", error.diagnostics[0].message)


class TestRichDisplay(unittest.TestCase):
    """Notebook display, without a notebook.

    `_repr_latex_` is a protocol rather than a dependency: a frontend calls the
    method if it exists. Nothing in the package imports IPython, so all of this
    is checkable with no notebook stack installed -- which is also the point of
    the last test here.
    """

    def artifact(self):
        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        return model.derive(phaser.Request(ONE_LOOP_REQUEST, context=context))

    def test_the_latex_fragment_carries_no_delimiters_or_preamble(self):
        latex = self.artifact().to_latex()
        for forbidden in ("$", r"\(", r"\[", r"\begin{document}", r"\documentclass"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, latex)

    def test_rich_display_wraps_the_fragment_the_frontend_needs(self):
        artifact = self.artifact()
        rendered = artifact._repr_latex_()
        self.assertTrue(rendered.startswith("$\\displaystyle "))
        self.assertTrue(rendered.endswith("$"))
        # The delimiters are the only difference: the exporter emits a fragment
        # precisely so each consumer chooses its own.
        self.assertIn(artifact.to_latex(), rendered)

    def test_printing_gives_plain_text_and_repr_gives_a_summary(self):
        artifact = self.artifact()
        self.assertEqual(str(artifact), artifact.to_phaser())
        self.assertNotEqual(str(artifact), artifact.to_latex())
        self.assertTrue(repr(artifact).startswith("<phaser.Artifact "))

    def test_the_explicit_methods_agree_with_export(self):
        artifact = self.artifact()
        self.assertEqual(artifact.to_latex(), artifact.export("latex"))
        self.assertEqual(artifact.to_phaser(), artifact.export("phaser"))

    def test_importing_phaser_does_not_import_ipython(self):
        # The specification forbids implementing the display protocol from
        # introducing a required IPython or Jupyter dependency. Since `phaser`
        # is already imported at the top of this file, a module here would mean
        # importing it pulled one in.
        for forbidden in ("IPython", "jupyter_core", "ipykernel"):
            with self.subTest(module=forbidden):
                self.assertNotIn(forbidden, sys.modules)


class TestExport(unittest.TestCase):
    def test_both_targets_render_and_differ(self):
        artifact = build().kernel.artifact
        plain = artifact.export("phaser")
        latex = artifact.export("latex")
        self.assertIsInstance(plain, str)
        self.assertIsInstance(latex, str)
        self.assertNotEqual(plain, latex)
        self.assertGreater(len(plain), 0)
        # A MathJax-compatible fragment: no delimiters and no preamble.
        self.assertNotIn("$", latex)
        self.assertNotIn(r"\begin{document}", latex)

    def test_an_unknown_target_is_refused_rather_than_defaulted(self):
        artifact = build().kernel.artifact
        with self.assertRaises(ValueError):
            artifact.export("markdown")

    def test_an_unknown_capability_is_refused(self):
        artifact = build().kernel.artifact
        with self.assertRaises(ValueError):
            artifact.compile("value_and_everything")


class TestEvaluation(unittest.TestCase):
    def test_the_two_branches_cross_the_boundary_undamaged(self):
        # Below the sign change of the field-dependent mass-squared the result
        # is a successful complex value; above it the same calculation is
        # exactly real. Neither is an error, and the distinction must survive
        # the trip through Python.
        results = build().evaluate([100.0, 500.0])
        self.assertEqual(results.result_type, "complex64")
        self.assertEqual(results.status(0), "ok")
        self.assertNotEqual(results.value(0).imag, 0.0)
        self.assertEqual(results.status(1), "ok")
        self.assertEqual(results.value(1).imag, 0.0)

    def test_a_scalar_call_agrees_with_the_same_point_in_a_batch(self):
        binding = build()
        batch = binding.evaluate([0.0, 100.0, 250.0, 500.0])
        for index, phi in enumerate([0.0, 100.0, 250.0, 500.0]):
            with self.subTest(phi=phi):
                self.assertEqual(binding.evaluate_at(phi), batch.point(index))

    def test_the_grouping_of_a_batch_does_not_change_its_results(self):
        # Points are independent. Splitting one batch in two must reproduce it
        # exactly, not approximately.
        binding = build()
        whole = binding.evaluate([0.0, 100.0, 250.0, 500.0])
        first = binding.evaluate([0.0, 100.0])
        second = binding.evaluate([250.0, 500.0])
        parts = [first.point(0), first.point(1), second.point(0), second.point(1)]
        self.assertEqual([whole.point(index) for index in range(4)], parts)

    def test_every_accepted_input_form_gives_the_same_answer(self):
        binding = build()
        expected = binding.evaluate(array.array("d", [100.0, 500.0]))
        typed = array.array("d", [100.0, 500.0])
        forms = {
            "flat sequence": [100.0, 500.0],
            "sequence of points": [[100.0], [500.0]],
            "array.array": typed,
            "memoryview": memoryview(typed),
            "cast memoryview": memoryview(bytearray(typed.tobytes())).cast("d"),
            "tuple": (100.0, 500.0),
        }
        for name, backgrounds in forms.items():
            with self.subTest(form=name):
                results = binding.evaluate(backgrounds)
                self.assertEqual(
                    [results.point(index) for index in range(2)],
                    [expected.point(index) for index in range(2)],
                )

    def test_raw_bytes_are_refused_rather_than_reinterpreted(self):
        # bytes does expose a buffer, of unsigned bytes. Reading those bytes as
        # doubles would turn a plausible mistake into a plausible wrong answer.
        binding = build()
        with self.assertRaises(TypeError):
            binding.evaluate(array.array("d", [100.0]).tobytes())

    def test_a_buffer_of_the_wrong_item_type_is_refused(self):
        binding = build()
        with self.assertRaises(TypeError):
            binding.evaluate(array.array("f", [100.0, 500.0]))
        with self.assertRaises(TypeError):
            binding.evaluate(array.array("q", [100, 500]))

    def test_a_non_contiguous_buffer_is_refused(self):
        binding = build()
        every_other = memoryview(array.array("d", [100.0, 0.0, 500.0, 0.0]))[::2]
        self.assertFalse(every_other.c_contiguous)
        with self.assertRaises(ValueError):
            binding.evaluate(every_other)

    def test_a_partial_point_is_refused(self):
        # One coordinate per point here, so this needs a model with more. The
        # empty batch is the reachable case: it has no whole point in it.
        binding = build()
        with self.assertRaises(ValueError):
            binding.evaluate([])
        with self.assertRaises(ValueError):
            binding.evaluate_at(100.0, 200.0)

    def test_a_value_only_kernel_reports_no_derivatives(self):
        binding = build(capability="value")
        results = binding.evaluate([100.0])
        self.assertIsNone(results.gradients)
        self.assertIsNone(results.hessians)
        self.assertIsNone(results.gradient(0))
        self.assertIsNone(results.hessian(0))
        # The value itself is the same one the full kernel computes.
        self.assertEqual(results.value(0), build().evaluate([100.0]).value(0))

    def test_the_shapes_are_what_the_documented_layout_says(self):
        binding = build()
        results = binding.evaluate([100.0, 500.0])
        coordinates = binding.coordinate_count
        # A trailing axis of two for the real and imaginary parts, which is
        # phaser_complex's layout and NumPy's complex128.
        self.assertEqual(results.values.shape, (2, 2))
        self.assertEqual(results.gradients.shape, (2, coordinates, 2))
        self.assertEqual(results.hessians.shape, (2, coordinates, coordinates, 2))
        self.assertEqual(results.statuses.shape, (2,))

    def test_a_real_binding_reports_plain_floats(self):
        results = build(TREE_REQUEST).evaluate([100.0, 500.0])
        self.assertEqual(results.result_type, "real64")
        self.assertEqual(results.values.shape, (2,))
        for index in range(2):
            self.assertIsInstance(results.value(index), float)


class TestGoldenAgreement(unittest.TestCase):
    """Compares the binding against the committed command-line output.

    This is the exit criterion that Python results agree with the direct Zig,
    C, and CLI results, checked against the same committed files the C ABI and
    the CLI are checked against rather than against a second copy of them.

    The comparison is exact. The scan's fields are shortest round-trip
    decimals, so parsing one recovers the identical double; a disagreement in
    the last bit fails here rather than being absorbed by a tolerance.
    """

    @classmethod
    def setUpClass(cls):
        directory = os.environ.get("PHASER_EXAMPLES")
        if not directory:
            raise RuntimeError(
                "PHASER_EXAMPLES is not set. Run this through "
                "`zig build test-python -Dpython=<interpreter>`, which points "
                "it at the committed example inputs."
            )
        cls.examples = Path(directory) / "phi4"

    def read(self, name):
        return (self.examples / name).read_bytes()

    def scan(self, name):
        """Reads a committed scan as (backgrounds, rows)."""
        backgrounds = []
        rows = []
        for line in (self.examples / name).read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            fields = line.split("\t")
            if fields[0] == "phi":
                continue
            backgrounds.append(float(fields[0]))
            rows.append(fields[1:])
        return backgrounds, rows

    def binding(self, request_name):
        context = phaser.Context()
        model = phaser.Model(self.read("model.json"), context=context)
        request = phaser.Request(self.read(request_name), context=context)
        point = phaser.ParameterPoint(self.read("point.json"), context=context)
        return model.derive(request).compile().bind(point)

    def test_the_one_loop_scan_matches_the_committed_output(self):
        binding = self.binding("request_one_loop.json")
        backgrounds, rows = self.scan("scan_total.tsv")
        self.assertGreater(len(backgrounds), 1)

        results = binding.evaluate(backgrounds)
        self.assertEqual(len(results), len(backgrounds))

        for index, (phi, row) in enumerate(zip(backgrounds, rows)):
            with self.subTest(phi=phi):
                value_re, value_im, gradient_re, gradient_im, status = row
                value = results.value(index)
                gradient = results.gradient(index)[0]
                self.assertEqual(value.real, float(value_re))
                self.assertEqual(value.imag, float(value_im))
                self.assertEqual(gradient.real, float(gradient_re))
                self.assertEqual(gradient.imag, float(gradient_im))
                self.assertEqual(results.status(index), status)

    def test_the_tree_scan_matches_both_committed_routes_to_it(self):
        """The tree curve the notebook plots, against two committed files.

        `scan.tsv` is a loop-order-zero request evaluated directly, which is
        what the binding below computes. `scan_tree.tsv` is the loop-order-one
        request with `--selection=loop:0` -- a four-contribution artifact with
        the loop term selected away, rather than a three-contribution artifact
        that never had one.

        Asserting both matters for the notebook. It plots the tree from its own
        request and the total from another, and shows the loop contribution as
        the difference; that decomposition means what it claims only if the two
        routes to the tree are the same numbers. They are, bitwise.
        """
        binding = self.binding("request.json")
        self.assertEqual(binding.result_type, "real64")

        backgrounds, rows = self.scan("scan_tree.tsv")
        results = binding.evaluate(backgrounds)

        selected, selected_rows = self.scan("scan.tsv")
        self.assertEqual(selected, backgrounds)

        for index, phi in enumerate(backgrounds):
            with self.subTest(phi=phi):
                value, gradient, status = rows[index]
                self.assertEqual(results.value(index), float(value))
                self.assertEqual(results.gradient(index)[0], float(gradient))
                self.assertEqual(results.status(index), status)
                # The same two columns from the separately derived artifact.
                self.assertEqual(results.value(index), float(selected_rows[index][0]))
                self.assertEqual(
                    results.gradient(index)[0], float(selected_rows[index][1])
                )

    def test_the_loop_correction_is_where_the_imaginary_part_comes_from(self):
        """The property that makes the notebook's decomposition readable.

        The tree potential is real everywhere; the total is complex below the
        sign change. So the entire imaginary part of the total belongs to the
        loop correction, and a reader looking at the two curves can attribute
        it without being told.
        """
        tree = self.binding("request.json")
        total = self.binding("request_one_loop.json")
        self.assertEqual(tree.result_type, "real64")
        self.assertEqual(total.result_type, "complex64")

        backgrounds, _ = self.scan("scan_total.tsv")
        tree_results = tree.evaluate(backgrounds)
        total_results = total.evaluate(backgrounds)

        for index, phi in enumerate(backgrounds):
            with self.subTest(phi=phi):
                self.assertIsInstance(tree_results.value(index), float)
                correction = total_results.value(index) - tree_results.value(index)
                self.assertEqual(correction.imag, total_results.value(index).imag)

    def test_a_selected_loop_order_matches_the_committed_contribution(self):
        """The reason `phaser_kernel_options` grew a selection.

        Before it, the one-loop contribution could only be reached by
        subtracting the tree from the total -- a cancellation about `1.3e-11`
        away from the command line's directly summed value, with no comparison
        policy covering the pair. Selecting the loop order asks the core the
        same question the command line asks, so the answer is the same bits.
        """
        context = phaser.Context()
        model = phaser.Model(self.read("model.json"), context=context)
        request = phaser.Request(self.read("request_one_loop.json"), context=context)
        point = phaser.ParameterPoint(self.read("point.json"), context=context)
        artifact = model.derive(request)

        binding = artifact.compile(selection=("loop_order", 1)).bind(point)
        self.assertEqual(binding.result_type, "complex64")

        backgrounds, rows = self.scan("scan_one_loop.tsv")
        results = binding.evaluate(backgrounds)

        for index, (phi, row) in enumerate(zip(backgrounds, rows)):
            with self.subTest(phi=phi):
                value_re, value_im, gradient_re, gradient_im, status = row
                value = results.value(index)
                gradient = results.gradient(index)[0]
                self.assertEqual(value.real, float(value_re))
                self.assertEqual(value.imag, float(value_im))
                self.assertEqual(gradient.real, float(gradient_re))
                self.assertEqual(gradient.imag, float(gradient_im))
                self.assertEqual(results.status(index), status)

    def test_selecting_the_tree_order_out_of_a_one_loop_artifact_is_real(self):
        context = phaser.Context()
        model = phaser.Model(self.read("model.json"), context=context)
        request = phaser.Request(self.read("request_one_loop.json"), context=context)
        point = phaser.ParameterPoint(self.read("point.json"), context=context)

        binding = model.derive(request).compile(
            selection=("loop_order", 0)
        ).bind(point)
        self.assertEqual(binding.result_type, "real64")

        backgrounds, rows = self.scan("scan_tree.tsv")
        results = binding.evaluate(backgrounds)
        for index, phi in enumerate(backgrounds):
            with self.subTest(phi=phi):
                self.assertEqual(results.value(index), float(rows[index][0]))
                self.assertEqual(results.gradient(index)[0], float(rows[index][1]))

    def test_the_scan_crosses_both_branches(self):
        # The agreement above is only worth what it covers, so this asserts the
        # committed scan is not entirely on one side of the sign change.
        _, rows = self.scan("scan_total.tsv")
        imaginary = [float(row[1]) for row in rows]
        self.assertTrue(any(part != 0.0 for part in imaginary))
        self.assertTrue(any(part == 0.0 for part in imaginary))

    def test_the_exported_latex_matches_the_committed_document(self):
        # The committed document is the CLI's output, which prefixes the
        # background map the client adds; `phaser_artifact_export` renders the
        # equations alone. So the equations are compared, exactly, and the
        # prefix is what the two surfaces are allowed to differ by.
        context = phaser.Context()
        model = phaser.Model(self.read("model.json"), context=context)
        request = phaser.Request(self.read("request_one_loop.json"), context=context)
        exported = model.derive(request).export("latex").strip()
        committed = (self.examples / "equations_one_loop.tex").read_text().strip()
        self.assertTrue(exported.startswith("V^{"), exported[:40])
        self.assertTrue(
            committed.endswith(exported),
            f"exported equations are not the tail of the committed document:\n"
            f"{exported}\n---\n{committed}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
