//! The native half of the Phaser Python binding.
//!
//! This is a thin CPython extension written in Zig against Python's Limited
//! API, as `docs/architecture/LANGUAGE_AND_INTEROPERABILITY.md` §8 specifies.
//! It contains no physics: every result comes from the C ABI, reached through
//! the same exported symbols a C client links against.
//!
//! Going through the C ABI rather than the Zig core directly is deliberate.
//! §3 permits either, but the specification also requires that this adapter's
//! observable lifecycle, validation, errors, and numerical results agree with
//! the C ABI. Calling that boundary is the cheapest way to make the agreement
//! structural rather than something a test has to keep rediscovering.
//!
//! `Py_LIMITED_API` is pinned to 3.11, the version from which the complete
//! `Py_buffer` structure and its operations are part of the Stable ABI. One
//! built extension therefore loads on every supported interpreter, with no
//! per-version build matrix.

const std = @import("std");

const py = @cImport({
    @cDefine("Py_LIMITED_API", "0x030B0000");
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ---------------------------------------------------------------------------
// The C ABI, declared as a C consumer declares it.
//
// These resolve to the symbols in the Phaser library this extension links, so
// the binding crosses exactly the boundary `include/phaser.h` publishes.
// ---------------------------------------------------------------------------

const PhaserContext = opaque {};
const PhaserModel = opaque {};
const PhaserDiagnostics = opaque {};

const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    invalid_source = 2,
    unsupported = 3,
    limit_exceeded = 4,
    insufficient_space = 5,
    out_of_memory = 6,
    internal = 7,
};

extern fn phaser_abi_version() callconv(.c) u32;
extern fn phaser_abi_experimental() callconv(.c) c_int;
extern fn phaser_library_version(
    major: ?*u32,
    minor: ?*u32,
    patch: ?*u32,
) callconv(.c) void;

extern fn phaser_context_create(
    options: ?*const anyopaque,
    out_context: ?*?*PhaserContext,
) callconv(.c) Status;
extern fn phaser_context_destroy(context: ?*PhaserContext) callconv(.c) void;

extern fn phaser_model_load(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_model: ?*?*PhaserModel,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_model_destroy(model: ?*PhaserModel) callconv(.c) void;
extern fn phaser_model_fingerprint(
    model: ?*const PhaserModel,
    out_bytes: ?[*]u8,
    capacity: usize,
) callconv(.c) Status;
extern fn phaser_model_parameter_count(
    model: ?*const PhaserModel,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_model_scalar_field_count(
    model: ?*const PhaserModel,
    out_count: ?*usize,
) callconv(.c) Status;

extern fn phaser_diagnostics_destroy(
    diagnostics: ?*PhaserDiagnostics,
) callconv(.c) void;
extern fn phaser_diagnostics_count(
    diagnostics: ?*const PhaserDiagnostics,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_diagnostics_render(
    diagnostics: ?*const PhaserDiagnostics,
    index: usize,
    buffer: ?[*]u8,
    capacity: usize,
    out_length: ?*usize,
) callconv(.c) Status;

// ---------------------------------------------------------------------------
// Error translation
//
// A structured diagnostic becomes an exception carrying the rendered text, so
// a Python caller sees why a document was rejected rather than only that it
// was. The high-level package refines these into its own exception types; the
// extension raises the closest built-in.
// ---------------------------------------------------------------------------

fn raiseStatus(status: Status, what: []const u8) ?*py.PyObject {
    const message = switch (status) {
        .ok => "no error",
        .invalid_argument => "invalid argument",
        .invalid_source => "invalid source",
        .unsupported => "unsupported",
        .limit_exceeded => "resource limit exceeded",
        .insufficient_space => "insufficient space",
        .out_of_memory => "out of memory",
        .internal => "internal error",
    };
    const exception = switch (status) {
        .out_of_memory => py.PyExc_MemoryError,
        .invalid_source, .invalid_argument => py.PyExc_ValueError,
        .unsupported => py.PyExc_NotImplementedError,
        .limit_exceeded, .insufficient_space => py.PyExc_MemoryError,
        else => py.PyExc_RuntimeError,
    };
    var buffer: [160]u8 = undefined;
    const text = std.fmt.bufPrintZ(
        &buffer,
        "{s}: {s}",
        .{ what, message },
    ) catch "phaser: error";
    py.PyErr_SetString(exception, text.ptr);
    return null;
}

/// Renders the first diagnostic into an exception message, then releases the
/// handle. The diagnostics are owned by this call; the caller does not free
/// them.
fn raiseDiagnostics(diagnostics: ?*PhaserDiagnostics, what: []const u8) ?*py.PyObject {
    defer phaser_diagnostics_destroy(diagnostics);

    var count: usize = 0;
    if (phaser_diagnostics_count(diagnostics, &count) != .ok or count == 0) {
        return raiseStatus(.invalid_source, what);
    }

    var required: usize = 0;
    _ = phaser_diagnostics_render(diagnostics, 0, null, 0, &required);

    var rendered: [512]u8 = undefined;
    if (required == 0 or required > rendered.len) {
        return raiseStatus(.invalid_source, what);
    }
    var written: usize = 0;
    if (phaser_diagnostics_render(
        diagnostics,
        0,
        &rendered,
        rendered.len,
        &written,
    ) != .ok) {
        return raiseStatus(.invalid_source, what);
    }

    var message: [700]u8 = undefined;
    const text = std.fmt.bufPrintZ(&message, "{s}: {s}{s}", .{
        what,
        rendered[0..written],
        if (count > 1) " (and further diagnostics)" else "",
    }) catch return raiseStatus(.invalid_source, what);
    py.PyErr_SetString(py.PyExc_ValueError, text.ptr);
    return null;
}

// ---------------------------------------------------------------------------
// Module functions
// ---------------------------------------------------------------------------

fn abiVersion(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    return py.PyLong_FromUnsignedLong(phaser_abi_version());
}

fn abiExperimental(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    return py.PyBool_FromLong(phaser_abi_experimental());
}

fn libraryVersion(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var major: u32 = 0;
    var minor: u32 = 0;
    var patch: u32 = 0;
    phaser_library_version(&major, &minor, &patch);
    return py.Py_BuildValue("(III)", major, minor, patch);
}

/// Parses a model and returns its metadata as a dictionary.
///
/// The model handle does not outlive this call. Long-lived handles arrive with
/// the object types the high-level package wraps; this entry point exists so
/// the whole chain -- interpreter, extension, C ABI, core -- is exercised
/// before any of that machinery is built on top of it.
fn modelMetadata(
    _: ?*py.PyObject,
    args: ?*py.PyObject,
) callconv(.c) ?*py.PyObject {
    var source: [*c]const u8 = undefined;
    var length: py.Py_ssize_t = 0;
    // `y#` accepts bytes without copying and rejects str, so the caller
    // decides the encoding rather than the binding guessing at it.
    if (py.PyArg_ParseTuple(args, "y#", &source, &length) == 0) return null;
    if (length < 0) return raiseStatus(.invalid_argument, "model");

    var context: ?*PhaserContext = null;
    if (phaser_context_create(null, &context) != .ok) {
        return raiseStatus(.out_of_memory, "context");
    }
    defer phaser_context_destroy(context);

    var model: ?*PhaserModel = null;
    var diagnostics: ?*PhaserDiagnostics = null;
    const status = phaser_model_load(
        context,
        source,
        @intCast(length),
        &model,
        &diagnostics,
    );
    if (status == .invalid_source) return raiseDiagnostics(diagnostics, "model");
    if (status != .ok) return raiseStatus(status, "model");
    defer phaser_model_destroy(model);

    var parameters: usize = 0;
    var scalars: usize = 0;
    var fingerprint: [32]u8 = undefined;
    if (phaser_model_parameter_count(model, &parameters) != .ok or
        phaser_model_scalar_field_count(model, &scalars) != .ok or
        phaser_model_fingerprint(model, &fingerprint, fingerprint.len) != .ok)
    {
        return raiseStatus(.internal, "model");
    }

    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&fingerprint}) catch
        return raiseStatus(.internal, "model");

    return py.Py_BuildValue(
        "{s:s#,s:n,s:n}",
        "fingerprint",
        &hex,
        @as(py.Py_ssize_t, hex.len),
        "parameter_count",
        @as(py.Py_ssize_t, @intCast(parameters)),
        "scalar_field_count",
        @as(py.Py_ssize_t, @intCast(scalars)),
    );
}

// ---------------------------------------------------------------------------
// Module definition
// ---------------------------------------------------------------------------

var methods = [_]py.PyMethodDef{
    .{
        .ml_name = "abi_version",
        .ml_meth = abiVersion,
        .ml_flags = py.METH_NOARGS,
        .ml_doc = "Return the C ABI version this extension was built against.",
    },
    .{
        .ml_name = "abi_experimental",
        .ml_meth = abiExperimental,
        .ml_flags = py.METH_NOARGS,
        .ml_doc = "Return True while the ABI is experimental.",
    },
    .{
        .ml_name = "library_version",
        .ml_meth = libraryVersion,
        .ml_flags = py.METH_NOARGS,
        .ml_doc = "Return the library version as a (major, minor, patch) tuple.",
    },
    .{
        .ml_name = "model_metadata",
        .ml_meth = modelMetadata,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Parse a model from bytes and return its metadata.",
    },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var module = py.PyModuleDef{
    // The equivalent of PyModuleDef_HEAD_INIT. Zeroing rather than naming the
    // fields keeps this compiling across interpreter versions that have
    // reshaped the object head, which free-threading did.
    .m_base = std.mem.zeroes(py.PyModuleDef_Base),
    .m_name = "phaser._phaser",
    .m_doc = "Native Phaser binding over the experimental C ABI.",
    .m_size = -1,
    .m_methods = &methods,
};

export fn PyInit__phaser() ?*py.PyObject {
    return py.PyModule_Create2(&module, py.PYTHON_ABI_VERSION);
}
