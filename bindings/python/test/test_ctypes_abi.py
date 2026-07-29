"""An independent ``ctypes`` consumer of the Phaser C ABI.

Required by ``docs/architecture/LANGUAGE_AND_INTEROPERABILITY.md`` §8: a
``ctypes`` client is maintained as an ABI conformance test, and is explicitly
not the production binding.

Its value is that it shares nothing with the extension but the ABI itself. The
extension is compiled against ``phaser.h`` by a compiler that checks every
signature; this file re-declares the same functions by hand, in a different
language, from the header read as documentation. A signature that drifted, a
struct field that moved, or an enumerator that was renumbered would be caught
here even if the extension and the library were rebuilt together and agreed
with each other.

That is the same reasoning as ``test/integration/abi_layout.zig``, which
transcribes the header's offsets rather than reading them from the Zig types.
Two independent descriptions of one interface, compared.

Run through ``zig build test-python``, which builds the shared library and
points ``PHASER_SHARED_LIBRARY`` at it.
"""

import ctypes
import os
import unittest
from pathlib import Path

import phaser

# --- Status codes, transcribed from include/phaser.h ------------------------

STATUS_OK = 0
STATUS_INVALID_ARGUMENT = 1
STATUS_INVALID_SOURCE = 2
STATUS_UNSUPPORTED = 3
STATUS_LIMIT_EXCEEDED = 4
STATUS_INSUFFICIENT_SPACE = 5
STATUS_OUT_OF_MEMORY = 6
STATUS_INTERNAL = 7

POINT_OK = 0

RESULT_REAL64 = 0
RESULT_COMPLEX64 = 1

CAPABILITY_VALUE_GRADIENT_HESSIAN = 2

EXPORT_PHASER = 0
EXPORT_LATEX = 1

FINGERPRINT_BYTES = 32


class Complex(ctypes.Structure):
    _fields_ = [("re", ctypes.c_double), ("im", ctypes.c_double)]


SEVERITY_ERROR = 0

CATEGORY_JSON = 4
CATEGORY_MODEL = 6


class DiagnosticRecord(ctypes.Structure):
    """`phaser_diagnostic`, transcribed field by field from the header."""

    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("code", ctypes.c_uint32),
        ("category", ctypes.c_int32),
        ("severity", ctypes.c_int32),
        ("has_primary", ctypes.c_int32),
        ("primary_source_id", ctypes.c_uint32),
        ("primary_start", ctypes.c_uint32),
        ("primary_end", ctypes.c_uint32),
        ("related_count", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
    ]


class ComplexOutputs(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("values", ctypes.POINTER(Complex)),
        ("value_count", ctypes.c_size_t),
        ("gradients", ctypes.POINTER(Complex)),
        ("gradient_count", ctypes.c_size_t),
        ("hessians", ctypes.POINTER(Complex)),
        ("hessian_count", ctypes.c_size_t),
        ("statuses", ctypes.POINTER(ctypes.c_int32)),
        ("status_count", ctypes.c_size_t),
    ]


def find_library():
    """Locates the shared library the build produced.

    A missing or unbuilt library is a hard failure rather than a skip. A
    conformance suite that skips still exits zero, so the one outcome worse
    than failing is quietly not running -- this file's entire value is being
    a second, independent consumer, and a green tick that skipped it would
    report agreement nobody checked.
    """
    explicit = os.environ.get("PHASER_SHARED_LIBRARY")
    if not explicit:
        raise RuntimeError(
            "PHASER_SHARED_LIBRARY is not set. Run this through "
            "`zig build test-python -Dpython=<interpreter>`, which builds the "
            "shared library and points this variable at it."
        )
    path = Path(explicit)
    if not path.exists():
        raise RuntimeError(f"shared library not found: {path}")
    return path


def load():
    """Loads the library and declares every signature this file uses.

    Declaring ``argtypes`` and ``restype`` for each function is the point of
    the exercise, not ceremony: without them ctypes would guess, and a
    mismatch would show up as a wrong answer rather than as a failure.
    """
    library = ctypes.CDLL(str(find_library()))

    p = ctypes.c_void_p
    pp = ctypes.POINTER(ctypes.c_void_p)
    size_p = ctypes.POINTER(ctypes.c_size_t)

    signatures = {
        "phaser_abi_version": ([], ctypes.c_uint32),
        "phaser_abi_experimental": ([], ctypes.c_int),
        "phaser_library_version": (
            [ctypes.POINTER(ctypes.c_uint32)] * 3,
            None,
        ),
        "phaser_context_create": ([p, pp], ctypes.c_int),
        "phaser_context_destroy": ([p], None),
        "phaser_model_load": ([p, p, ctypes.c_size_t, pp, pp], ctypes.c_int),
        "phaser_model_destroy": ([p], None),
        "phaser_model_fingerprint": (
            [p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t],
            ctypes.c_int,
        ),
        "phaser_model_parameter_count": ([p, size_p], ctypes.c_int),
        "phaser_model_scalar_field_count": ([p, size_p], ctypes.c_int),
        "phaser_request_parse": ([p, p, ctypes.c_size_t, pp, pp], ctypes.c_int),
        "phaser_request_destroy": ([p], None),
        "phaser_request_loop_order": (
            [p, ctypes.POINTER(ctypes.c_uint32)],
            ctypes.c_int,
        ),
        "phaser_artifact_derive": ([p, p, p, pp, pp], ctypes.c_int),
        "phaser_artifact_destroy": ([p], None),
        "phaser_artifact_result_type": (
            [p, ctypes.POINTER(ctypes.c_int32)],
            ctypes.c_int,
        ),
        "phaser_artifact_export": (
            [p, ctypes.c_int32, p, ctypes.c_size_t, size_p],
            ctypes.c_int,
        ),
        "phaser_kernel_compile": ([p, p, p, pp], ctypes.c_int),
        "phaser_kernel_destroy": ([p], None),
        "phaser_kernel_capability": (
            [p, ctypes.POINTER(ctypes.c_int32)],
            ctypes.c_int,
        ),
        "phaser_point_parse": ([p, p, ctypes.c_size_t, pp, pp], ctypes.c_int),
        "phaser_point_destroy": ([p], None),
        "phaser_point_reference_scale": (
            [p, ctypes.POINTER(ctypes.c_double)],
            ctypes.c_int,
        ),
        "phaser_binding_create": ([p, p, p, p, pp], ctypes.c_int),
        "phaser_binding_destroy": ([p], None),
        "phaser_binding_workspace": (
            [p, ctypes.c_size_t, size_p, size_p],
            ctypes.c_int,
        ),
        "phaser_binding_result_type": (
            [p, ctypes.POINTER(ctypes.c_int32)],
            ctypes.c_int,
        ),
        "phaser_evaluate_complex": (
            [
                p,
                ctypes.POINTER(ctypes.c_double),
                ctypes.c_size_t,
                ctypes.c_size_t,
                p,
                ctypes.c_size_t,
                ctypes.POINTER(ComplexOutputs),
            ],
            ctypes.c_int,
        ),
        "phaser_diagnostics_destroy": ([p], None),
        "phaser_diagnostics_count": ([p, size_p], ctypes.c_int),
        "phaser_diagnostics_at": (
            [p, ctypes.c_size_t, ctypes.POINTER(DiagnosticRecord)],
            ctypes.c_int,
        ),
        "phaser_diagnostics_render": (
            [p, ctypes.c_size_t, p, ctypes.c_size_t, size_p],
            ctypes.c_int,
        ),
    }
    for name, (argtypes, restype) in signatures.items():
        function = getattr(library, name)
        function.argtypes = argtypes
        function.restype = restype
    return library


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

# The field-dependent mass-squared is m2 + lambda * phi^2 / 2, negative below
# |phi| ~= 245 and positive above.
PARAMETER_POINT = b"""{
  "schema": "phaser.parameter-point/0.1",
  "units": { "mass": "GeV" },
  "renormalization": { "scheme": "MSbar", "reference_scale": 125.0 },
  "values": { "lambda": 0.26, "m2": -7812.5 }
}
"""


class AbiTestCase(unittest.TestCase):
    """Base class that loads the library and tracks handles for cleanup."""

    @classmethod
    def setUpClass(cls):
        cls.lib = load()

    def setUp(self):
        self._handles = []

    def tearDown(self):
        # Reverse construction order, as the ownership rules require.
        for destroy, handle in reversed(self._handles):
            destroy(handle)

    def own(self, destroy, handle):
        self._handles.append((destroy, handle))
        return handle

    def context(self):
        out = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_context_create(None, ctypes.byref(out)), STATUS_OK
        )
        return self.own(self.lib.phaser_context_destroy, out)

    def build_binding(self):
        context = self.context()

        model = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_model_load(
                context, VALID_MODEL, len(VALID_MODEL), ctypes.byref(model), None
            ),
            STATUS_OK,
        )
        self.own(self.lib.phaser_model_destroy, model)

        request = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_request_parse(
                context,
                ONE_LOOP_REQUEST,
                len(ONE_LOOP_REQUEST),
                ctypes.byref(request),
                None,
            ),
            STATUS_OK,
        )
        self.own(self.lib.phaser_request_destroy, request)

        artifact = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_artifact_derive(
                context, model, request, ctypes.byref(artifact), None
            ),
            STATUS_OK,
        )
        self.own(self.lib.phaser_artifact_destroy, artifact)

        kernel = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_kernel_compile(
                context, artifact, None, ctypes.byref(kernel)
            ),
            STATUS_OK,
        )
        self.own(self.lib.phaser_kernel_destroy, kernel)

        point = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_point_parse(
                context,
                PARAMETER_POINT,
                len(PARAMETER_POINT),
                ctypes.byref(point),
                None,
            ),
            STATUS_OK,
        )
        self.own(self.lib.phaser_point_destroy, point)

        binding = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_binding_create(
                context, kernel, model, point, ctypes.byref(binding)
            ),
            STATUS_OK,
        )
        self.own(self.lib.phaser_binding_destroy, binding)
        return artifact, kernel, binding


class TestVersions(AbiTestCase):
    def test_the_library_and_the_extension_report_the_same_versions(self):
        # Two independent consumers of one library. A disagreement would mean
        # one of them is bound to a different build than it thinks.
        self.assertEqual(self.lib.phaser_abi_version(), phaser.abi_version())
        self.assertEqual(
            bool(self.lib.phaser_abi_experimental()), phaser.abi_experimental()
        )

        major = ctypes.c_uint32()
        minor = ctypes.c_uint32()
        patch = ctypes.c_uint32()
        self.lib.phaser_library_version(
            ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch)
        )
        self.assertEqual(
            (major.value, minor.value, patch.value), phaser.library_version()
        )


class TestModel(AbiTestCase):
    def load_model(self, context, source):
        model = ctypes.c_void_p()
        diagnostics = ctypes.c_void_p()
        status = self.lib.phaser_model_load(
            context,
            source,
            len(source),
            ctypes.byref(model),
            ctypes.byref(diagnostics),
        )
        return status, model, diagnostics

    def test_metadata_matches_what_the_extension_reports(self):
        context = self.context()
        status, model, diagnostics = self.load_model(context, VALID_MODEL)
        self.assertEqual(status, STATUS_OK)
        self.assertFalse(diagnostics)
        self.own(self.lib.phaser_model_destroy, model)

        parameters = ctypes.c_size_t()
        scalars = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_model_parameter_count(model, ctypes.byref(parameters)),
            STATUS_OK,
        )
        self.assertEqual(
            self.lib.phaser_model_scalar_field_count(model, ctypes.byref(scalars)),
            STATUS_OK,
        )

        fingerprint = (ctypes.c_uint8 * FINGERPRINT_BYTES)()
        self.assertEqual(
            self.lib.phaser_model_fingerprint(
                model, fingerprint, FINGERPRINT_BYTES
            ),
            STATUS_OK,
        )
        rendered = bytes(fingerprint).hex()

        # The extension reached the same library through the same ABI. Every
        # field must agree, or one of the two paths is transforming something.
        from_extension = phaser.model_metadata(VALID_MODEL)
        self.assertEqual(parameters.value, from_extension["parameter_count"])
        self.assertEqual(scalars.value, from_extension["scalar_field_count"])
        self.assertEqual(rendered, from_extension["fingerprint"])

    def test_a_short_fingerprint_buffer_is_rejected(self):
        context = self.context()
        _, model, _ = self.load_model(context, VALID_MODEL)
        self.own(self.lib.phaser_model_destroy, model)

        buffer = (ctypes.c_uint8 * (FINGERPRINT_BYTES - 1))()
        self.assertEqual(
            self.lib.phaser_model_fingerprint(
                model, buffer, FINGERPRINT_BYTES - 1
            ),
            STATUS_INSUFFICIENT_SPACE,
        )

    def test_invalid_source_produces_diagnostics_and_no_handle(self):
        context = self.context()
        status, model, diagnostics = self.load_model(context, b"{ not json")
        self.assertEqual(status, STATUS_INVALID_SOURCE)
        self.assertFalse(model)
        self.assertTrue(diagnostics)
        self.own(self.lib.phaser_diagnostics_destroy, diagnostics)

        count = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_diagnostics_count(diagnostics, ctypes.byref(count)),
            STATUS_OK,
        )
        self.assertGreater(count.value, 0)

    def test_null_handles_are_rejected(self):
        count = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_model_parameter_count(None, ctypes.byref(count)),
            STATUS_INVALID_ARGUMENT,
        )
        self.assertEqual(
            self.lib.phaser_context_create(None, None), STATUS_INVALID_ARGUMENT
        )


class TestEvaluation(AbiTestCase):
    def test_the_one_loop_calculation_is_complex_and_evaluates(self):
        artifact, kernel, binding = self.build_binding()

        result_type = ctypes.c_int32()
        self.assertEqual(
            self.lib.phaser_artifact_result_type(
                artifact, ctypes.byref(result_type)
            ),
            STATUS_OK,
        )
        self.assertEqual(result_type.value, RESULT_COMPLEX64)

        capability = ctypes.c_int32()
        self.assertEqual(
            self.lib.phaser_kernel_capability(kernel, ctypes.byref(capability)),
            STATUS_OK,
        )
        self.assertEqual(capability.value, CAPABILITY_VALUE_GRADIENT_HESSIAN)

        point_count = 2
        backgrounds = (ctypes.c_double * 2)(100.0, 500.0)

        required = ctypes.c_size_t()
        alignment = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_binding_workspace(
                binding,
                point_count,
                ctypes.byref(required),
                ctypes.byref(alignment),
            ),
            STATUS_OK,
        )
        self.assertGreater(required.value, 0)
        # ctypes buffers are suitably aligned for any fundamental type, which
        # covers every alignment this ABI reports.
        workspace = ctypes.create_string_buffer(required.value)

        values = (Complex * point_count)()
        gradients = (Complex * point_count)()
        hessians = (Complex * point_count)()
        statuses = (ctypes.c_int32 * point_count)()

        outputs = ComplexOutputs(
            struct_size=ctypes.sizeof(ComplexOutputs),
            abi_version=0,
            values=values,
            value_count=point_count,
            gradients=gradients,
            gradient_count=point_count,
            hessians=hessians,
            hessian_count=point_count,
            statuses=statuses,
            status_count=point_count,
        )
        self.assertEqual(
            self.lib.phaser_evaluate_complex(
                binding,
                backgrounds,
                point_count,
                point_count,
                workspace,
                required.value,
                ctypes.byref(outputs),
            ),
            STATUS_OK,
        )

        # The claim the two status spaces exist for, reached from a third
        # consumer: below the sign change the result is a successful complex
        # value, above it the same calculation is exactly real.
        self.assertEqual(statuses[0], POINT_OK)
        self.assertNotEqual(values[0].im, 0.0)
        self.assertEqual(statuses[1], POINT_OK)
        self.assertEqual(values[1].im, 0.0)

    def test_a_short_status_array_is_rejected(self):
        _, _, binding = self.build_binding()
        point_count = 2
        backgrounds = (ctypes.c_double * 2)(100.0, 500.0)

        required = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_binding_workspace(
                binding, point_count, ctypes.byref(required), None
            ),
            STATUS_OK,
        )
        workspace = ctypes.create_string_buffer(required.value)

        values = (Complex * point_count)()
        gradients = (Complex * point_count)()
        hessians = (Complex * point_count)()
        statuses = (ctypes.c_int32 * point_count)()

        outputs = ComplexOutputs(
            struct_size=ctypes.sizeof(ComplexOutputs),
            abi_version=0,
            values=values,
            value_count=point_count,
            gradients=gradients,
            gradient_count=point_count,
            hessians=hessians,
            hessian_count=point_count,
            statuses=statuses,
            status_count=point_count - 1,
        )
        self.assertEqual(
            self.lib.phaser_evaluate_complex(
                binding,
                backgrounds,
                point_count,
                point_count,
                workspace,
                required.value,
                ctypes.byref(outputs),
            ),
            STATUS_INVALID_ARGUMENT,
        )

    def test_one_byte_less_workspace_is_rejected(self):
        _, _, binding = self.build_binding()
        point_count = 1
        backgrounds = (ctypes.c_double * 1)(100.0)

        required = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_binding_workspace(
                binding, point_count, ctypes.byref(required), None
            ),
            STATUS_OK,
        )
        workspace = ctypes.create_string_buffer(required.value)

        values = (Complex * point_count)()
        gradients = (Complex * point_count)()
        hessians = (Complex * point_count)()
        statuses = (ctypes.c_int32 * point_count)()
        outputs = ComplexOutputs(
            struct_size=ctypes.sizeof(ComplexOutputs),
            abi_version=0,
            values=values,
            value_count=point_count,
            gradients=gradients,
            gradient_count=point_count,
            hessians=hessians,
            hessian_count=point_count,
            statuses=statuses,
            status_count=point_count,
        )

        self.assertEqual(
            self.lib.phaser_evaluate_complex(
                binding,
                backgrounds,
                point_count,
                point_count,
                workspace,
                required.value - 1,
                ctypes.byref(outputs),
            ),
            STATUS_INSUFFICIENT_SPACE,
        )

    def test_export_sizes_then_fills_for_both_targets(self):
        artifact, _, _ = self.build_binding()
        for target in (EXPORT_PHASER, EXPORT_LATEX):
            required = ctypes.c_size_t()
            self.assertEqual(
                self.lib.phaser_artifact_export(
                    artifact, target, None, 0, ctypes.byref(required)
                ),
                STATUS_INSUFFICIENT_SPACE,
            )
            self.assertGreater(required.value, 0)

            buffer = ctypes.create_string_buffer(required.value)
            written = ctypes.c_size_t()
            self.assertEqual(
                self.lib.phaser_artifact_export(
                    artifact,
                    target,
                    buffer,
                    required.value,
                    ctypes.byref(written),
                ),
                STATUS_OK,
            )
            self.assertEqual(written.value, required.value)

    def test_an_unrecognized_export_target_is_rejected(self):
        artifact, _, _ = self.build_binding()
        required = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_artifact_export(
                artifact, 7, None, 0, ctypes.byref(required)
            ),
            STATUS_INVALID_ARGUMENT,
        )


class TestExtensionAgreement(AbiTestCase):
    """Compares this client's results against the production binding's.

    Two consumers of one library, reaching it by different routes: this file
    loads the shared library and drives it through hand-written ctypes
    declarations, while the extension is compiled against `phaser.h` and linked
    against the same core statically. Where they overlap they must agree
    exactly, and a tolerance here would defeat the purpose -- the question is
    whether the two paths compute the same thing, not whether they compute
    something similar.
    """

    BACKGROUNDS = (0.0, 100.0, 250.0, 500.0)

    def through_ctypes(self):
        _, _, binding = self.build_binding()
        point_count = len(self.BACKGROUNDS)
        backgrounds = (ctypes.c_double * point_count)(*self.BACKGROUNDS)

        required = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_binding_workspace(
                binding, point_count, ctypes.byref(required), None
            ),
            STATUS_OK,
        )
        workspace = ctypes.create_string_buffer(required.value)

        values = (Complex * point_count)()
        gradients = (Complex * point_count)()
        hessians = (Complex * point_count)()
        statuses = (ctypes.c_int32 * point_count)()
        outputs = ComplexOutputs(
            struct_size=ctypes.sizeof(ComplexOutputs),
            abi_version=0,
            values=values,
            value_count=point_count,
            gradients=gradients,
            gradient_count=point_count,
            hessians=hessians,
            hessian_count=point_count,
            statuses=statuses,
            status_count=point_count,
        )
        self.assertEqual(
            self.lib.phaser_evaluate_complex(
                binding,
                backgrounds,
                point_count,
                point_count,
                workspace,
                required.value,
                ctypes.byref(outputs),
            ),
            STATUS_OK,
        )
        return values, gradients, hessians, statuses

    def through_extension(self):
        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        request = phaser.Request(ONE_LOOP_REQUEST, context=context)
        point = phaser.ParameterPoint(PARAMETER_POINT, context=context)
        binding = model.derive(request).compile().bind(point)
        return binding.evaluate(list(self.BACKGROUNDS))

    def test_values_gradients_hessians_and_statuses_all_agree(self):
        values, gradients, hessians, statuses = self.through_ctypes()
        native = self.through_extension()

        self.assertEqual(len(native), len(self.BACKGROUNDS))
        for index in range(len(self.BACKGROUNDS)):
            with self.subTest(phi=self.BACKGROUNDS[index]):
                value = native.value(index)
                self.assertEqual(value.real, values[index].re)
                self.assertEqual(value.imag, values[index].im)

                # One coordinate, so the gradient and the Hessian each have a
                # single entry per point.
                gradient = native.gradient(index)[0]
                self.assertEqual(gradient.real, gradients[index].re)
                self.assertEqual(gradient.imag, gradients[index].im)

                hessian = native.hessian(index)[0][0]
                self.assertEqual(hessian.real, hessians[index].re)
                self.assertEqual(hessian.imag, hessians[index].im)

                self.assertEqual(statuses[index], POINT_OK)
                self.assertEqual(native.status(index), "ok")

    def test_the_typed_metadata_agrees(self):
        artifact, kernel, binding = self.build_binding()

        result_type = ctypes.c_int32()
        capability = ctypes.c_int32()
        coordinates = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_artifact_result_type(artifact, ctypes.byref(result_type)),
            STATUS_OK,
        )
        self.assertEqual(
            self.lib.phaser_kernel_capability(kernel, ctypes.byref(capability)),
            STATUS_OK,
        )
        self.assertEqual(
            self.lib.phaser_binding_coordinate_count(
                binding, ctypes.byref(coordinates)
            ),
            STATUS_OK,
        )

        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        request = phaser.Request(ONE_LOOP_REQUEST, context=context)
        native_artifact = model.derive(request)
        native_kernel = native_artifact.compile()

        self.assertEqual(
            native_artifact.result_type,
            phaser.RESULT_TYPES[result_type.value],
        )
        self.assertEqual(
            phaser.CAPABILITIES[native_kernel.capability], capability.value
        )
        self.assertEqual(native_kernel.coordinate_count, coordinates.value)

    def test_the_structured_diagnostics_agree(self):
        # The extension's `phaser_diagnostic` layout is transcribed here by
        # hand, from the header. A field that moved would show up as a wrong
        # value in one description and not the other, which is the same
        # reasoning as `test/integration/abi_layout.zig`.
        context = self.context()
        model = ctypes.c_void_p()
        diagnostics = ctypes.c_void_p()
        self.assertEqual(
            self.lib.phaser_model_load(
                context,
                b"{ not json",
                len(b"{ not json"),
                ctypes.byref(model),
                ctypes.byref(diagnostics),
            ),
            STATUS_INVALID_SOURCE,
        )
        self.own(self.lib.phaser_diagnostics_destroy, diagnostics)

        count = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_diagnostics_count(diagnostics, ctypes.byref(count)),
            STATUS_OK,
        )

        record = DiagnosticRecord()
        record.struct_size = ctypes.sizeof(DiagnosticRecord)
        self.assertEqual(
            self.lib.phaser_diagnostics_at(diagnostics, 0, ctypes.byref(record)),
            STATUS_OK,
        )
        self.assertEqual(record.severity, SEVERITY_ERROR)
        self.assertEqual(record.category, CATEGORY_JSON)
        self.assertNotEqual(record.has_primary, 0)

        required = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_diagnostics_render(
                diagnostics, 0, None, 0, ctypes.byref(required)
            ),
            STATUS_INSUFFICIENT_SPACE,
        )
        buffer = ctypes.create_string_buffer(required.value)
        written = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_diagnostics_render(
                diagnostics, 0, buffer, required.value, ctypes.byref(written)
            ),
            STATUS_OK,
        )
        rendered = buffer.raw[: written.value].decode("utf-8")

        with self.assertRaises(phaser.SourceError) as raised:
            phaser.Model(b"{ not json")
        native = raised.exception

        self.assertEqual(len(native.diagnostics), count.value)
        first = native.diagnostics[0]
        self.assertEqual(first.code, record.code)
        self.assertEqual(first.message, rendered)
        self.assertEqual(first.related_count, record.related_count)
        self.assertEqual(phaser.SEVERITIES[record.severity], first.severity)
        self.assertEqual(phaser.CATEGORIES[record.category], first.category)
        self.assertEqual(first.source_id, record.primary_source_id)
        self.assertEqual(first.start, record.primary_start)
        self.assertEqual(first.end, record.primary_end)

    def test_the_rendered_equations_agree(self):
        artifact, _, _ = self.build_binding()

        required = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_artifact_export(
                artifact, EXPORT_LATEX, None, 0, ctypes.byref(required)
            ),
            STATUS_INSUFFICIENT_SPACE,
        )
        buffer = ctypes.create_string_buffer(required.value)
        written = ctypes.c_size_t()
        self.assertEqual(
            self.lib.phaser_artifact_export(
                artifact, EXPORT_LATEX, buffer, required.value, ctypes.byref(written)
            ),
            STATUS_OK,
        )
        # No null terminator is written, so the length is authoritative.
        rendered = buffer.raw[: written.value].decode("utf-8")

        context = phaser.Context()
        model = phaser.Model(VALID_MODEL, context=context)
        request = phaser.Request(ONE_LOOP_REQUEST, context=context)
        self.assertEqual(model.derive(request).export("latex"), rendered)


if __name__ == "__main__":
    unittest.main(verbosity=2)
