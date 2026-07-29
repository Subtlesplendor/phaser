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

// ---------------------------------------------------------------------------
// CPython's Limited API, declared rather than translated.
//
// Zig's C translation cannot process Microsoft's headers here: the C runtime
// declares its bounds-checked `_s` string functions through inline wrappers
// that translate into unused local constants, which the compiler then rejects.
// Nothing in this file asks for `wcscat_s`; it arrives through Python.h. The
// documented macro for suppressing those declarations does not remove them.
//
// So the subset used is declared directly. That takes C translation out of the
// build on every platform rather than only where it breaks, and it removes the
// need for Python's headers at build time -- what remains is the Stable ABI
// stub on Windows.
//
// The safety this gives up is a compiler checking these signatures against the
// real header. Two things replace it. The Stable ABI is stable by contract,
// which is the entire reason for pinning `Py_LIMITED_API`: these declarations
// are guaranteed not to change under a conforming interpreter. And a mistake
// here is loud rather than subtle -- a wrong `PyModuleDef` layout makes
// `PyModule_Create2` fail and the module unimportable, which every test in
// `bindings/python/test/` would report on the first line.
// ---------------------------------------------------------------------------

const py = struct {
    /// Opaque to this file: every object is handled through the functions
    /// below, never by reaching into it.
    const PyObject = opaque {};

    const Py_ssize_t = isize;

    /// `PyModule_Create` passes this when `Py_LIMITED_API` is defined, in
    /// place of the unstable `PYTHON_API_VERSION` an unlimited build uses.
    const PYTHON_ABI_VERSION: c_int = 3;

    const METH_VARARGS: c_int = 0x0001;
    const METH_NOARGS: c_int = 0x0004;

    const PyCFunction = ?*const fn (?*PyObject, ?*PyObject) callconv(.c) ?*PyObject;

    const PyMethodDef = extern struct {
        ml_name: ?[*:0]const u8,
        ml_meth: PyCFunction,
        ml_flags: c_int,
        ml_doc: ?[*:0]const u8,
    };

    /// The `PyModuleDef_HEAD_INIT` prologue.
    ///
    /// `ob_base` is CPython's object head: a reference count and a type
    /// pointer. It is two machine words rather than named fields because
    /// free-threaded builds reshape the count into a union, and this file only
    /// ever zeroes the whole thing, exactly as `PyModuleDef_HEAD_INIT` does.
    const PyModuleDef_Base = extern struct {
        ob_base: [2]usize,
        m_init: ?*const fn () callconv(.c) ?*PyObject,
        m_index: Py_ssize_t,
        m_copy: ?*PyObject,
    };

    const PyModuleDef = extern struct {
        m_base: PyModuleDef_Base,
        m_name: ?[*:0]const u8,
        m_doc: ?[*:0]const u8,
        m_size: Py_ssize_t,
        m_methods: ?[*]PyMethodDef,
        m_slots: ?*anyopaque = null,
        m_traverse: ?*anyopaque = null,
        m_clear: ?*anyopaque = null,
        m_free: ?*anyopaque = null,
    };

    // None of these is variadic, deliberately.
    //
    // `PyArg_ParseTuple` and `Py_BuildValue` take printf-style format strings
    // whose `#` conversions change width with the `PY_SSIZE_T_CLEAN` macro --
    // which, when defined, also renames the functions. Interpreters differ in
    // whether the older narrow variants still exist, so the same call is
    // correct on one version and a `SystemError` on another. Reading tuples and
    // building dictionaries through the typed functions avoids the question
    // rather than answering it per version.
    extern fn PyModule_Create2(def: *PyModuleDef, apiver: c_int) ?*PyObject;
    extern fn PyLong_FromUnsignedLong(value: c_ulong) ?*PyObject;
    extern fn PyLong_FromSsize_t(value: Py_ssize_t) ?*PyObject;
    extern fn PyBool_FromLong(value: c_long) ?*PyObject;
    extern fn PyErr_SetString(exception: ?*PyObject, message: [*:0]const u8) void;
    extern fn Py_DecRef(object: ?*PyObject) void;

    extern fn PyTuple_Size(tuple: ?*PyObject) Py_ssize_t;
    extern fn PyTuple_GetItem(tuple: ?*PyObject, index: Py_ssize_t) ?*PyObject;
    extern fn PyTuple_New(size: Py_ssize_t) ?*PyObject;
    extern fn PyTuple_SetItem(tuple: ?*PyObject, index: Py_ssize_t, item: ?*PyObject) c_int;

    extern fn PyBytes_AsStringAndSize(
        object: ?*PyObject,
        buffer: *?[*]u8,
        length: *Py_ssize_t,
    ) c_int;

    extern fn PyDict_New() ?*PyObject;
    extern fn PyDict_SetItemString(
        dict: ?*PyObject,
        key: [*:0]const u8,
        value: ?*PyObject,
    ) c_int;

    extern fn PyUnicode_FromStringAndSize(
        text: [*]const u8,
        length: Py_ssize_t,
    ) ?*PyObject;

    // Built-in exception objects. These are pointers the interpreter owns; the
    // extern declaration is of the pointer variable itself.
    extern const PyExc_ValueError: *PyObject;
    extern const PyExc_TypeError: *PyObject;
    extern const PyExc_MemoryError: *PyObject;
    extern const PyExc_RuntimeError: *PyObject;
    extern const PyExc_NotImplementedError: *PyObject;
};

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

    const tuple = py.PyTuple_New(3) orelse return null;
    const parts = [_]u32{ major, minor, patch };
    for (parts, 0..) |part, index| {
        const item = py.PyLong_FromUnsignedLong(part) orelse {
            py.Py_DecRef(tuple);
            return null;
        };
        // PyTuple_SetItem steals the reference, including when it fails.
        if (py.PyTuple_SetItem(tuple, @intCast(index), item) != 0) {
            py.Py_DecRef(tuple);
            return null;
        }
    }
    return tuple;
}

/// Sets one dictionary entry, taking ownership of `value`.
///
/// PyDict_SetItemString does not steal the reference, so the caller would have
/// to release it on both paths. Doing that here keeps every call site to one
/// line and one decision.
fn setOwned(dict: ?*py.PyObject, key: [*:0]const u8, value: ?*py.PyObject) bool {
    const item = value orelse return false;
    defer py.Py_DecRef(item);
    return py.PyDict_SetItemString(dict, key, item) == 0;
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
    // One positional argument, read through the tuple rather than a format
    // string. PyBytes_AsStringAndSize accepts bytes without copying and raises
    // TypeError for anything else, so the caller decides the encoding rather
    // than the binding guessing at it.
    if (py.PyTuple_Size(args) != 1) {
        py.PyErr_SetString(py.PyExc_TypeError, "model_metadata expects one argument");
        return null;
    }
    const argument = py.PyTuple_GetItem(args, 0) orelse return null;

    var source: ?[*]u8 = null;
    var length: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(argument, &source, &length) != 0) return null;
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

    const metadata = py.PyDict_New() orelse return null;
    const filled = setOwned(
        metadata,
        "fingerprint",
        py.PyUnicode_FromStringAndSize(&hex, hex.len),
    ) and setOwned(
        metadata,
        "parameter_count",
        py.PyLong_FromSsize_t(@intCast(parameters)),
    ) and setOwned(
        metadata,
        "scalar_field_count",
        py.PyLong_FromSsize_t(@intCast(scalars)),
    );
    if (!filled) {
        py.Py_DecRef(metadata);
        return null;
    }
    return metadata;
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
