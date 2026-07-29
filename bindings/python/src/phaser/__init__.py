"""Phaser's Python binding.

This package is a thin surface over the native extension, which is itself a
thin surface over Phaser's experimental C ABI. No physics, no numerics, and no
validation live here: every result comes from the same core the command-line
client and the C conformance client use.

The extension publishes one capsule per ABI handle. The classes below hold a
reference from each object to the handles it must not outlive, which is how the
C ABI's ownership rules are kept without asking a caller to remember them. A
``Model`` keeps its ``Context`` alive, an ``Artifact`` keeps its ``Model`` and
``Request``, a ``Kernel`` keeps its ``Artifact``, and a ``Binding`` keeps its
``Kernel``, ``Model``, and ``ParameterPoint``. Reference counting then destroys
them in a valid order, because a parent's capsule cannot be collected while a
child still refers to it.

Nothing here creates a reference cycle, which is what would defeat that: the
references all point from child to parent.

ABI version 0 is experimental. Breaking changes are permitted while
``abi_experimental()`` returns True, and this package tracks them.
"""

import array
from collections import namedtuple

from . import _phaser
from ._phaser import (  # noqa: F401
    SourceError,
    abi_experimental,
    abi_version,
    library_version,
)

__all__ = [
    "Artifact",
    "Binding",
    "Context",
    "Diagnostic",
    "Evaluation",
    "Kernel",
    "Model",
    "ParameterPoint",
    "PointResult",
    "Request",
    "SourceError",
    "abi_experimental",
    "abi_version",
    "library_version",
    "model_metadata",
]

# Enumerator names, mapped here rather than exposed as bare integers. The ABI
# rejects an unrecognized enumerator instead of resolving it to a default, and
# a misspelled name has to fail the same way rather than quietly meaning
# something.
CAPABILITIES = {
    "value": 0,
    "value_gradient": 1,
    "value_gradient_hessian": 2,
}
EXPORT_TARGETS = {"phaser": 0, "latex": 1}
RESULT_TYPES = {0: "real64", 1: "complex64"}
POINT_STATUSES = {
    0: "ok",
    1: "non_finite",
    2: "division_by_zero",
    3: "nonconvergent",
    4: "singular_derivative",
}

SEVERITIES = {0: "error", 1: "warning", 2: "note"}
CATEGORIES = {
    0: "source",
    1: "capacity",
    2: "allocation",
    3: "configuration",
    4: "json",
    5: "expression",
    6: "model",
    7: "calculation",
}

_CAPABILITY_NAMES = {code: name for name, code in CAPABILITIES.items()}

#: One point's results, as returned by :meth:`Binding.evaluate_at`.
PointResult = namedtuple("PointResult", "value gradient hessian status")

#: One structured diagnostic. ``source_id``, ``start``, and ``end`` are None
#: when the diagnostic carries no primary source location -- which is different
#: from a span at offset zero, and has to stay different.
Diagnostic = namedtuple(
    "Diagnostic",
    "code severity category message related_count source_id start end",
    defaults=(None, None, None),
)


def _diagnostic(entry):
    return Diagnostic(
        code=entry["code"],
        # Unlike everywhere else, an unrecognized enumerator falls back to its
        # number instead of raising. This runs while an exception is already
        # being reported, and refusing to name a category is no reason to
        # replace the diagnostic the caller actually needs to read.
        severity=SEVERITIES.get(entry["severity"], entry["severity"]),
        category=CATEGORIES.get(entry["category"], entry["category"]),
        message=entry["message"],
        related_count=entry["related_count"],
        source_id=entry.get("source_id"),
        start=entry.get("start"),
        end=entry.get("end"),
    )


def _structured(call, *arguments):
    """Calls a parse primitive, naming the diagnostics it may raise.

    The extension attaches the raw records; the names live here, next to the
    tables that define them, rather than being duplicated in Zig.
    """
    try:
        return call(*arguments)
    except SourceError as error:
        error.diagnostics = tuple(_diagnostic(entry) for entry in error.diagnostics)
        raise


def _named(table, code, what):
    """Maps an ABI enumerator to its name, refusing to invent one.

    An unrecognized value must be treated as a failure of its kind rather than
    as success, which is the header's rule for the per-point status space and
    the safe reading of every other enumerator here.
    """
    try:
        return table[code]
    except KeyError:
        raise ValueError(f"unrecognized {what} from the ABI: {code}") from None


def _code(table, name, what):
    try:
        return table[name]
    except KeyError:
        options = ", ".join(sorted(table))
        raise ValueError(f"unknown {what} {name!r}; expected one of {options}") from None


def _same_context(first, second, what):
    if first.context is not second.context:
        raise ValueError(f"{what} must share one context")


class Context:
    """Allocation policy and resource limits for everything derived from it.

    There is no global default context. Each object below either takes one or
    creates its own, so two independent calculations share no mutable state.
    """

    def __init__(self):
        self._capsule = _phaser.context_create()

    @property
    def context(self):
        # So that _same_context can compare any two objects uniformly.
        return self

    def __repr__(self):
        return "<phaser.Context>"


class Model:
    """A parsed and validated model."""

    def __init__(self, source, *, context=None):
        self.context = Context() if context is None else context
        self._capsule = _structured(
            _phaser.model_load, self.context._capsule, source
        )
        info = _phaser.model_info(self._capsule)
        self.fingerprint = info["fingerprint"]
        self.parameter_count = info["parameter_count"]
        self.scalar_field_count = info["scalar_field_count"]

    def derive(self, request):
        """Derives the effective potential for `request` against this model."""
        return Artifact(self, request)

    def __repr__(self):
        return (
            f"<phaser.Model fingerprint={self.fingerprint[:12]}"
            f" parameters={self.parameter_count}"
            f" scalars={self.scalar_field_count}>"
        )


class Request:
    """A parsed calculation request, reusable across models."""

    def __init__(self, source, *, context=None):
        self.context = Context() if context is None else context
        self._capsule = _structured(
            _phaser.request_parse, self.context._capsule, source
        )
        info = _phaser.request_info(self._capsule)
        self.loop_order = info["loop_order"]
        self.coordinate_count = info["coordinate_count"]

    def __repr__(self):
        return (
            f"<phaser.Request loop_order={self.loop_order}"
            f" coordinates={self.coordinate_count}>"
        )


class Artifact:
    """The symbolic effective potential derived from a model and a request."""

    def __init__(self, model, request):
        _same_context(model, request, "a model and a request")
        self.model = model
        self.request = request
        self.context = model.context
        self._capsule = _structured(
            _phaser.artifact_derive,
            self.context._capsule,
            model._capsule,
            request._capsule,
        )
        info = _phaser.artifact_info(self._capsule)
        self.loop_order = info["loop_order"]
        self.coordinate_count = info["coordinate_count"]
        self.contribution_count = info["contribution_count"]
        self.result_type = _named(RESULT_TYPES, info["result_type"], "result type")

    def export(self, target="phaser"):
        """Renders the equations as text for `target`.

        ``latex`` produces a delimiter-free MathJax-compatible fragment, which
        is what a notebook's rich display consumes.
        """
        return _phaser.artifact_export(
            self._capsule, _code(EXPORT_TARGETS, target, "export target")
        )

    def to_latex(self):
        """The delimiter-free MathJax-compatible fragment.

        No ``$``, no preamble, no document class: the consumer chooses inline
        or display delimiters. :meth:`_repr_latex_` is one such consumer.
        """
        return self.export("latex")

    def to_phaser(self):
        """The compact plain-text notation, for terminals and logs."""
        return self.export("phaser")

    def compile(self, capability="value_gradient_hessian"):
        """Lowers the symbolic graph to a numerical kernel."""
        return Kernel(self, capability)

    def _repr_latex_(self):
        """Rich display in a notebook frontend.

        This is a protocol, not a dependency: IPython calls the method if it
        exists and nothing here imports it, so the package works identically
        with no notebook stack installed. Outside a frontend the ordinary
        `repr` below is what a reader sees, and ``print`` gives the equations
        as plain text.

        The delimiters are added here rather than by the exporter, which emits
        a fragment precisely so that each consumer can choose them.
        """
        return f"$\\displaystyle {self.to_latex()}$"

    def __str__(self):
        return self.to_phaser()

    def __repr__(self):
        return (
            f"<phaser.Artifact loop_order={self.loop_order}"
            f" coordinates={self.coordinate_count}"
            f" contributions={self.contribution_count}"
            f" result={self.result_type}>"
        )


class Kernel:
    """A compiled numerical program for one artifact."""

    def __init__(self, artifact, capability="value_gradient_hessian"):
        self.artifact = artifact
        self.context = artifact.context
        self._capsule = _phaser.kernel_compile(
            self.context._capsule,
            artifact._capsule,
            _code(CAPABILITIES, capability, "capability"),
        )
        info = _phaser.kernel_info(self._capsule)
        self.capability = _named(
            _CAPABILITY_NAMES, info["capability"], "capability"
        )
        self.result_type = _named(RESULT_TYPES, info["result_type"], "result type")
        self.coordinate_count = info["coordinate_count"]
        self.parameter_count = info["parameter_count"]

    def bind(self, point):
        """Binds `point`, doing the parameter-dependent work once."""
        return Binding(self, point)

    def __repr__(self):
        return (
            f"<phaser.Kernel capability={self.capability}"
            f" result={self.result_type}"
            f" coordinates={self.coordinate_count}>"
        )


class ParameterPoint:
    """A parsed parameter point, bindable to more than one kernel."""

    def __init__(self, source, *, context=None):
        self.context = Context() if context is None else context
        self._capsule = _structured(
            _phaser.point_parse, self.context._capsule, source
        )
        self.reference_scale = _phaser.point_info(self._capsule)["reference_scale"]

    def __repr__(self):
        return f"<phaser.ParameterPoint reference_scale={self.reference_scale}>"


class Binding:
    """A kernel bound to a parameter point, ready to evaluate."""

    def __init__(self, kernel, point):
        _same_context(kernel, point, "a kernel and a parameter point")
        self.kernel = kernel
        self.point = point
        self.model = kernel.artifact.model
        self.context = kernel.context
        self._capsule = _phaser.binding_create(
            self.context._capsule,
            kernel._capsule,
            self.model._capsule,
            point._capsule,
        )
        info = _phaser.binding_info(self._capsule)
        self.coordinate_count = info["coordinate_count"]
        self.result_type = _named(RESULT_TYPES, info["result_type"], "result type")

    def evaluate(self, backgrounds):
        """Evaluates a batch of background points.

        `backgrounds` is ``point_count * coordinate_count`` values in row-major
        order. Anything exposing a C-contiguous buffer of float64 items -- a
        NumPy array, an ``array.array('d')``, a ``memoryview`` cast to ``'d'``
        -- crosses without a copy. A plain sequence of numbers, or a sequence
        of per-point sequences, is copied into one.
        """
        prepared = _as_double_buffer(backgrounds)
        return Evaluation(
            self,
            _phaser.evaluate(self._capsule, self.kernel._capsule, prepared),
        )

    def evaluate_at(self, *coordinates):
        """Evaluates one background point and returns its results directly.

        The batch path underneath is the same one :meth:`evaluate` takes, so a
        scalar call and a one-point batch cannot disagree by construction. What
        a test still has to check is that a point evaluated alone agrees with
        the same point evaluated inside a larger batch.
        """
        if len(coordinates) == 1 and not isinstance(coordinates[0], (int, float)):
            coordinates = tuple(coordinates[0])
        if len(coordinates) != self.coordinate_count:
            raise ValueError(
                f"expected {self.coordinate_count} coordinate(s),"
                f" got {len(coordinates)}"
            )
        return self.evaluate(array.array("d", coordinates)).point(0)

    def __repr__(self):
        return (
            f"<phaser.Binding coordinates={self.coordinate_count}"
            f" result={self.result_type}>"
        )


class Evaluation:
    """The results of one batch call.

    Every array is a ``memoryview`` over the bytes the extension filled, shaped
    but not copied. A complex result's trailing axis is the real and imaginary
    parts, which is `phaser_complex`'s layout and also NumPy's ``complex128``:
    ``numpy.frombuffer(evaluation.raw["values"], dtype="complex128")`` views the
    same bytes with no conversion, for a caller who has NumPy. The binding
    itself never requires it.

    Index a multi-dimensional view with a tuple -- ``gradients[point, axis]``
    -- rather than with one index at a time. CPython does not implement
    sub-views of multi-dimensional buffers, so ``gradients[point]`` raises. The
    accessors below take that path for you and return ordinary Python numbers.
    """

    def __init__(self, binding, raw):
        self.binding = binding
        self.raw = raw
        self.point_count = raw["point_count"]
        self.coordinate_count = raw["coordinate_count"]
        self.result_type = _named(RESULT_TYPES, raw["result_type"], "result type")
        self._complex = self.result_type == "complex64"

        points = self.point_count
        coordinates = self.coordinate_count
        # A trailing axis of two for a complex result, and none for a real one.
        parts = (2,) if self._complex else ()

        self.values = _shaped(raw["values"], (points,) + parts)
        self.gradients = _shaped(
            raw.get("gradients"), (points, coordinates) + parts
        )
        self.hessians = _shaped(
            raw.get("hessians"), (points, coordinates, coordinates) + parts
        )
        self.statuses = memoryview(raw["statuses"]).cast("i")

    def __len__(self):
        return self.point_count

    def value(self, index):
        return self._scalar(self.values, (index,))

    def gradient(self, index):
        if self.gradients is None:
            return None
        return tuple(
            self._scalar(self.gradients, (index, axis))
            for axis in range(self.coordinate_count)
        )

    def hessian(self, index):
        if self.hessians is None:
            return None
        return tuple(
            tuple(
                self._scalar(self.hessians, (index, row, column))
                for column in range(self.coordinate_count)
            )
            for row in range(self.coordinate_count)
        )

    def status(self, index):
        return _named(POINT_STATUSES, self.statuses[index], "point status")

    def point(self, index):
        """Gathers one point's results into plain Python values."""
        return PointResult(
            value=self.value(index),
            gradient=self.gradient(index),
            hessian=self.hessian(index),
            status=self.status(index),
        )

    def _scalar(self, view, position):
        if self._complex:
            return complex(view[position + (0,)], view[position + (1,)])
        return view[position]

    def __repr__(self):
        return (
            f"<phaser.Evaluation points={self.point_count}"
            f" coordinates={self.coordinate_count}"
            f" result={self.result_type}>"
        )


def _shaped(buffer, shape):
    """Views raw bytes as a shaped array of float64, without copying."""
    if buffer is None:
        return None
    return memoryview(buffer).cast("d", shape)


def _as_double_buffer(backgrounds):
    """Returns something the extension can read as float64 through a buffer.

    ``bytes`` and ``bytearray`` are refused rather than reinterpreted: they do
    expose a buffer, but of unsigned bytes, and treating those bytes as doubles
    would turn a plausible mistake into a plausible-looking wrong answer.
    """
    if isinstance(backgrounds, (bytes, bytearray)):
        raise TypeError(
            "backgrounds must be typed float64 data, not raw bytes;"
            " use memoryview(...).cast('d') if the bytes really are float64"
        )
    try:
        view = memoryview(backgrounds)
    except TypeError:
        view = None
    if view is not None:
        if view.format != "d":
            raise TypeError(
                f"backgrounds buffer holds {view.format!r} items, expected 'd'"
            )
        if not view.c_contiguous:
            raise ValueError("backgrounds buffer must be C-contiguous")
        return backgrounds

    flat = array.array("d")
    for item in backgrounds:
        if isinstance(item, (int, float)):
            flat.append(item)
        else:
            flat.extend(item)
    return flat


def model_metadata(source):
    """Parses a model and returns its metadata as a dictionary.

    A convenience over :class:`Model` for callers that want the numbers and
    nothing else; the handle does not outlive the call.
    """
    model = Model(source)
    return {
        "fingerprint": model.fingerprint,
        "parameter_count": model.parameter_count,
        "scalar_field_count": model.scalar_field_count,
    }
