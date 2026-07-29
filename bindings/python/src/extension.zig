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
//!
//! What this file publishes is a set of primitives, not the user-facing API.
//! Each ABI handle becomes a named capsule; `phaser/__init__.py` wraps those
//! capsules in classes that hold references to their parents. The C ABI's
//! outlives-relationships are then enforced by Python's own reference counting
//! rather than by a rule a caller has to remember: a model cannot be collected
//! after its context, because the model object holds the context object.
//!
//! Splitting it that way keeps the C-facing half small enough to read. The
//! parts that must be native are the ones that touch the ABI or the buffer
//! protocol; presentation, naming, and convenience are ordinary Python.

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

    /// The saved state of a thread that has released the interpreter lock.
    const PyThreadState = opaque {};

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

    /// The buffer-protocol view. Complete and part of the Stable ABI from 3.11,
    /// which is why the binding's minimum is 3.11 rather than something older.
    const Py_buffer = extern struct {
        buf: ?*anyopaque,
        obj: ?*PyObject,
        len: Py_ssize_t,
        itemsize: Py_ssize_t,
        readonly: c_int,
        ndim: c_int,
        format: ?[*:0]u8,
        shape: ?[*]Py_ssize_t,
        strides: ?[*]Py_ssize_t,
        suboffsets: ?[*]Py_ssize_t,
        internal: ?*anyopaque,
    };

    const PyBUF_FORMAT: c_int = 0x0004;
    const PyBUF_ND: c_int = 0x0008;
    const PyBUF_STRIDES: c_int = 0x0010 | PyBUF_ND;
    /// Row-major and gap-free, which is what the ABI's background array is.
    /// Requesting `ANY_CONTIGUOUS` instead would accept a Fortran-ordered
    /// two-dimensional array and then read it in the wrong order.
    const PyBUF_C_CONTIGUOUS: c_int = 0x0020 | PyBUF_STRIDES;

    const PyCapsule_Destructor = ?*const fn (?*PyObject) callconv(.c) void;

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
    extern fn PyLong_AsLong(object: ?*PyObject) c_long;
    extern fn PyFloat_FromDouble(value: f64) ?*PyObject;
    extern fn PyBool_FromLong(value: c_long) ?*PyObject;
    extern fn PyErr_SetString(exception: ?*PyObject, message: [*:0]const u8) void;
    extern fn PyErr_Occurred() ?*PyObject;
    extern fn Py_IncRef(object: ?*PyObject) void;
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

    extern fn PyByteArray_FromStringAndSize(
        bytes: ?[*]const u8,
        length: Py_ssize_t,
    ) ?*PyObject;
    extern fn PyByteArray_AsString(object: ?*PyObject) ?[*]u8;

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

    extern fn PyCapsule_New(
        pointer: ?*anyopaque,
        name: ?[*:0]const u8,
        destructor: PyCapsule_Destructor,
    ) ?*PyObject;
    extern fn PyCapsule_GetPointer(
        capsule: ?*PyObject,
        name: ?[*:0]const u8,
    ) ?*anyopaque;
    extern fn PyCapsule_IsValid(capsule: ?*PyObject, name: ?[*:0]const u8) c_int;

    extern fn PyObject_GetBuffer(
        exporter: ?*PyObject,
        view: *Py_buffer,
        flags: c_int,
    ) c_int;
    extern fn PyBuffer_Release(view: *Py_buffer) void;

    extern fn PyEval_SaveThread() ?*PyThreadState;
    extern fn PyEval_RestoreThread(state: ?*PyThreadState) void;

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
const PhaserRequest = opaque {};
const PhaserArtifact = opaque {};
const PhaserKernel = opaque {};
const PhaserPoint = opaque {};
const PhaserBinding = opaque {};
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

const RESULT_COMPLEX64: i32 = 1;

const KernelOptions = extern struct {
    struct_size: u32,
    abi_version: u32,
    capability: i32,
    reserved: u32,
};

const Complex = extern struct {
    re: f64,
    im: f64,
};

const Outputs = extern struct {
    struct_size: u32,
    abi_version: u32,
    values: ?[*]f64,
    value_count: usize,
    gradients: ?[*]f64,
    gradient_count: usize,
    hessians: ?[*]f64,
    hessian_count: usize,
    statuses: ?[*]i32,
    status_count: usize,
};

const ComplexOutputs = extern struct {
    struct_size: u32,
    abi_version: u32,
    values: ?[*]Complex,
    value_count: usize,
    gradients: ?[*]Complex,
    gradient_count: usize,
    hessians: ?[*]Complex,
    hessian_count: usize,
    statuses: ?[*]i32,
    status_count: usize,
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

extern fn phaser_request_parse(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_request: ?*?*PhaserRequest,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_request_destroy(request: ?*PhaserRequest) callconv(.c) void;
extern fn phaser_request_loop_order(
    request: ?*const PhaserRequest,
    out_loop_order: ?*u32,
) callconv(.c) Status;
extern fn phaser_request_coordinate_count(
    request: ?*const PhaserRequest,
    out_count: ?*usize,
) callconv(.c) Status;

extern fn phaser_artifact_derive(
    context: ?*PhaserContext,
    model: ?*const PhaserModel,
    request: ?*const PhaserRequest,
    out_artifact: ?*?*PhaserArtifact,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_artifact_destroy(artifact: ?*PhaserArtifact) callconv(.c) void;
extern fn phaser_artifact_loop_order(
    artifact: ?*const PhaserArtifact,
    out_loop_order: ?*u32,
) callconv(.c) Status;
extern fn phaser_artifact_coordinate_count(
    artifact: ?*const PhaserArtifact,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_artifact_contribution_count(
    artifact: ?*const PhaserArtifact,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_artifact_result_type(
    artifact: ?*const PhaserArtifact,
    out_result_type: ?*i32,
) callconv(.c) Status;
extern fn phaser_artifact_export(
    artifact: ?*const PhaserArtifact,
    target: i32,
    buffer: ?*anyopaque,
    capacity: usize,
    out_length: ?*usize,
) callconv(.c) Status;

extern fn phaser_kernel_compile(
    context: ?*PhaserContext,
    artifact: ?*const PhaserArtifact,
    options: ?*const KernelOptions,
    out_kernel: ?*?*PhaserKernel,
) callconv(.c) Status;
extern fn phaser_kernel_destroy(kernel: ?*PhaserKernel) callconv(.c) void;
extern fn phaser_kernel_result_type(
    kernel: ?*const PhaserKernel,
    out_result_type: ?*i32,
) callconv(.c) Status;
extern fn phaser_kernel_capability(
    kernel: ?*const PhaserKernel,
    out_capability: ?*i32,
) callconv(.c) Status;
extern fn phaser_kernel_coordinate_count(
    kernel: ?*const PhaserKernel,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_kernel_parameter_count(
    kernel: ?*const PhaserKernel,
    out_count: ?*usize,
) callconv(.c) Status;

extern fn phaser_point_parse(
    context: ?*PhaserContext,
    source: ?*const anyopaque,
    source_length: usize,
    out_point: ?*?*PhaserPoint,
    out_diagnostics: ?*?*PhaserDiagnostics,
) callconv(.c) Status;
extern fn phaser_point_destroy(point: ?*PhaserPoint) callconv(.c) void;
extern fn phaser_point_reference_scale(
    point: ?*const PhaserPoint,
    out_scale: ?*f64,
) callconv(.c) Status;

extern fn phaser_binding_create(
    context: ?*PhaserContext,
    kernel: ?*const PhaserKernel,
    model: ?*const PhaserModel,
    point: ?*const PhaserPoint,
    out_binding: ?*?*PhaserBinding,
) callconv(.c) Status;
extern fn phaser_binding_destroy(binding: ?*PhaserBinding) callconv(.c) void;
extern fn phaser_binding_workspace(
    binding: ?*const PhaserBinding,
    point_count: usize,
    out_bytes: ?*usize,
    out_alignment: ?*usize,
) callconv(.c) Status;
extern fn phaser_binding_coordinate_count(
    binding: ?*const PhaserBinding,
    out_count: ?*usize,
) callconv(.c) Status;
extern fn phaser_binding_result_type(
    binding: ?*const PhaserBinding,
    out_result_type: ?*i32,
) callconv(.c) Status;

extern fn phaser_evaluate(
    binding: ?*const PhaserBinding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?*anyopaque,
    workspace_bytes: usize,
    outputs: ?*Outputs,
) callconv(.c) Status;
extern fn phaser_evaluate_complex(
    binding: ?*const PhaserBinding,
    backgrounds: ?[*]const f64,
    background_count: usize,
    point_count: usize,
    workspace: ?*anyopaque,
    workspace_bytes: usize,
    outputs: ?*ComplexOutputs,
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

fn raiseType(comptime message: []const u8) ?*py.PyObject {
    py.PyErr_SetString(
        py.PyExc_TypeError,
        std.fmt.comptimePrint("{s}", .{message}),
    );
    return null;
}

fn raiseValue(comptime message: []const u8) ?*py.PyObject {
    py.PyErr_SetString(
        py.PyExc_ValueError,
        std.fmt.comptimePrint("{s}", .{message}),
    );
    return null;
}

// ---------------------------------------------------------------------------
// Handles
//
// Each ABI handle crosses into Python as a named capsule whose destructor
// calls the matching ABI destructor exactly once, when the capsule is
// collected. The name is checked on the way back in, so passing a model where
// a kernel belongs raises rather than reinterpreting a pointer.
//
// The C ABI's outlives-relationships are carried by the capsules themselves
// rather than by the Python objects holding them. Each capsule owns a strong
// reference to the capsules its handle was derived from, and releases those
// references only after its own handle has been destroyed.
//
// It has to be done at this level. Having the Python classes hold the parent
// objects is not enough: when the last reference to a child object goes, its
// instance dictionary is released and the parent may be freed while the
// child's own capsule is still in that same dictionary, waiting its turn. The
// order attributes are torn down in is an interpreter implementation detail,
// and relying on it destroyed the context before the model it owned -- which
// the core's leak-checking allocator reported, and which then crashed.
// ---------------------------------------------------------------------------

/// One ABI handle plus the capsules it must not outlive.
///
/// Four is what the widest relationship needs: a binding is derived from a
/// context, a kernel, a model, and a parameter point.
const Node = struct {
    handle: *anyopaque,
    parents: [4]?*py.PyObject,
};

fn Handle(
    comptime T: type,
    comptime capsule_name: [:0]const u8,
    comptime destroy: fn (?*T) callconv(.c) void,
) type {
    return struct {
        /// Called by the interpreter when the capsule is collected.
        fn release(capsule: ?*py.PyObject) callconv(.c) void {
            // A destructor must not leave an exception set, so the name is
            // checked with the query that does not raise.
            if (py.PyCapsule_IsValid(capsule, capsule_name.ptr) == 0) return;
            const pointer = py.PyCapsule_GetPointer(capsule, capsule_name.ptr) orelse
                return;
            const node: *Node = @ptrCast(@alignCast(pointer));
            destroy(@ptrCast(node.handle));
            // Only now may the handles this one was derived from be released.
            for (node.parents) |parent| py.Py_DecRef(parent);
            std.heap.c_allocator.destroy(node);
        }

        /// Takes ownership of `pointer`, destroying it if the capsule cannot
        /// be created -- at which point nothing else will ever see it.
        fn wrap(pointer: *T, parents: []const ?*py.PyObject) ?*py.PyObject {
            std.debug.assert(parents.len <= 4);
            const node = std.heap.c_allocator.create(Node) catch {
                destroy(pointer);
                return raiseStatus(.out_of_memory, capsule_name);
            };
            node.* = .{ .handle = pointer, .parents = @splat(null) };
            for (parents, 0..) |parent, index| node.parents[index] = parent;

            const capsule = py.PyCapsule_New(node, capsule_name.ptr, release);
            if (capsule == null) {
                destroy(pointer);
                std.heap.c_allocator.destroy(node);
                return null;
            }
            // Claimed only once the capsule exists to release them again.
            for (parents) |parent| py.Py_IncRef(parent);
            return capsule;
        }

        fn unwrap(object: ?*py.PyObject) ?*T {
            if (py.PyCapsule_IsValid(object, capsule_name.ptr) == 0) {
                return typeError();
            }
            const pointer = py.PyCapsule_GetPointer(object, capsule_name.ptr) orelse
                return null;
            const node: *Node = @ptrCast(@alignCast(pointer));
            return @ptrCast(node.handle);
        }

        fn typeError() ?*T {
            py.PyErr_SetString(py.PyExc_TypeError, std.fmt.comptimePrint(
                "expected a {s} handle",
                .{capsule_name},
            ));
            return null;
        }
    };
}

const ContextHandle = Handle(PhaserContext, "phaser.context", phaser_context_destroy);
const ModelHandle = Handle(PhaserModel, "phaser.model", phaser_model_destroy);
const RequestHandle = Handle(PhaserRequest, "phaser.request", phaser_request_destroy);
const ArtifactHandle = Handle(PhaserArtifact, "phaser.artifact", phaser_artifact_destroy);
const KernelHandle = Handle(PhaserKernel, "phaser.kernel", phaser_kernel_destroy);
const PointHandle = Handle(PhaserPoint, "phaser.point", phaser_point_destroy);
const BindingHandle = Handle(PhaserBinding, "phaser.binding", phaser_binding_destroy);

// ---------------------------------------------------------------------------
// Argument and result plumbing
// ---------------------------------------------------------------------------

/// Reads exactly `count` positional arguments, borrowing each.
fn takeArgs(
    arguments: ?*py.PyObject,
    comptime count: usize,
    comptime what: []const u8,
) ?[count]?*py.PyObject {
    if (py.PyTuple_Size(arguments) != @as(py.Py_ssize_t, count)) {
        py.PyErr_SetString(py.PyExc_TypeError, std.fmt.comptimePrint(
            "{s} expects {d} argument(s)",
            .{ what, count },
        ));
        return null;
    }
    var borrowed: [count]?*py.PyObject = undefined;
    for (&borrowed, 0..) |*slot, index| {
        slot.* = py.PyTuple_GetItem(arguments, @intCast(index)) orelse return null;
    }
    return borrowed;
}

/// Borrows source bytes. `str` is rejected rather than encoded, so the caller
/// decides the encoding instead of the binding guessing one.
fn takeSource(object: ?*py.PyObject) ?[]const u8 {
    var data: ?[*]u8 = null;
    var length: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(object, &data, &length) != 0) return null;
    if (length <= 0) return &.{};
    return (data orelse return &.{})[0..@intCast(length)];
}

fn takeEnumerator(object: ?*py.PyObject, comptime what: []const u8) ?i32 {
    const value = py.PyLong_AsLong(object);
    if (value == -1 and py.PyErr_Occurred() != null) return null;
    return std.math.cast(i32, value) orelse {
        py.PyErr_SetString(py.PyExc_ValueError, std.fmt.comptimePrint(
            "{s} is out of range",
            .{what},
        ));
        return null;
    };
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

fn setCount(dict: ?*py.PyObject, key: [*:0]const u8, value: usize) bool {
    const widened = std.math.cast(py.Py_ssize_t, value) orelse return false;
    return setOwned(dict, key, py.PyLong_FromSsize_t(widened));
}

/// Adds a freshly allocated byte buffer under `key` and returns its storage.
///
/// The dictionary holds the only reference afterwards, which keeps the storage
/// alive for as long as the caller is filling it: a bytearray never moves its
/// data while the object lives.
fn addBuffer(dict: ?*py.PyObject, key: [*:0]const u8, bytes: usize) ?[*]u8 {
    const length = std.math.cast(py.Py_ssize_t, bytes) orelse {
        _ = raiseStatus(.limit_exceeded, "outputs");
        return null;
    };
    const object = py.PyByteArray_FromStringAndSize(null, length) orelse return null;
    defer py.Py_DecRef(object);
    const storage = py.PyByteArray_AsString(object) orelse return null;
    if (py.PyDict_SetItemString(dict, key, object) != 0) return null;
    return storage;
}

/// The evaluation workspace: raw bytes aligned as the ABI asked for.
///
/// The ABI reports an exact size and an alignment, and rejects a buffer that
/// misses either. libc's allocator promises neither beyond its own maximum, so
/// the alignment is taken by over-allocating and walking forward rather than
/// assumed.
const Workspace = struct {
    raw: []u8,
    aligned: []u8,

    fn init(bytes: usize, alignment: usize) ?Workspace {
        const unit = if (alignment == 0) 1 else alignment;
        const total = std.math.add(usize, bytes, unit - 1) catch return null;
        const raw = std.heap.c_allocator.alloc(u8, total) catch return null;
        const offset = (unit - (@intFromPtr(raw.ptr) % unit)) % unit;
        return .{ .raw = raw, .aligned = raw[offset..][0..bytes] };
    }

    fn deinit(self: Workspace) void {
        std.heap.c_allocator.free(self.raw);
    }
};

// ---------------------------------------------------------------------------
// Versions
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

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

fn contextCreate(_: ?*py.PyObject, _: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var context: ?*PhaserContext = null;
    if (phaser_context_create(null, &context) != .ok) {
        return raiseStatus(.out_of_memory, "context");
    }
    return ContextHandle.wrap(context.?, &.{});
}

/// Generates the three parse entry points, which differ only in which ABI
/// function they call and what they are called in a diagnostic.
fn Parser(
    comptime T: type,
    comptime HandleType: type,
    comptime what: []const u8,
    comptime parse: fn (
        ?*PhaserContext,
        ?*const anyopaque,
        usize,
        ?*?*T,
        ?*?*PhaserDiagnostics,
    ) callconv(.c) Status,
) type {
    return struct {
        fn call(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
            const given = takeArgs(arguments, 2, what) orelse return null;
            const context = ContextHandle.unwrap(given[0]) orelse return null;
            const source = takeSource(given[1]) orelse return null;

            var parsed: ?*T = null;
            var diagnostics: ?*PhaserDiagnostics = null;
            const status = parse(
                context,
                source.ptr,
                source.len,
                &parsed,
                &diagnostics,
            );
            if (status == .invalid_source) return raiseDiagnostics(diagnostics, what);
            if (status != .ok) return raiseStatus(status, what);
            return HandleType.wrap(parsed.?, &.{given[0]});
        }
    };
}

const modelLoad = Parser(PhaserModel, ModelHandle, "model", phaser_model_load).call;
const requestParse = Parser(PhaserRequest, RequestHandle, "request", phaser_request_parse).call;
const pointParse = Parser(PhaserPoint, PointHandle, "point", phaser_point_parse).call;

fn artifactDerive(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 3, "artifact_derive") orelse return null;
    const context = ContextHandle.unwrap(given[0]) orelse return null;
    const model = ModelHandle.unwrap(given[1]) orelse return null;
    const request = RequestHandle.unwrap(given[2]) orelse return null;

    var artifact: ?*PhaserArtifact = null;
    var diagnostics: ?*PhaserDiagnostics = null;
    const status = phaser_artifact_derive(
        context,
        model,
        request,
        &artifact,
        &diagnostics,
    );
    if (status == .invalid_source) return raiseDiagnostics(diagnostics, "artifact");
    if (status != .ok) return raiseStatus(status, "artifact");
    // The artifact does not borrow from the model or the request -- both need
    // only outlive the call -- so the context is the one handle it must not
    // outlive.
    return ArtifactHandle.wrap(artifact.?, &.{given[0]});
}

fn kernelCompile(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 3, "kernel_compile") orelse return null;
    const context = ContextHandle.unwrap(given[0]) orelse return null;
    const artifact = ArtifactHandle.unwrap(given[1]) orelse return null;
    const capability = takeEnumerator(given[2], "capability") orelse return null;

    const options = KernelOptions{
        .struct_size = @sizeOf(KernelOptions),
        .abi_version = 0,
        .capability = capability,
        .reserved = 0,
    };
    var kernel: ?*PhaserKernel = null;
    const status = phaser_kernel_compile(context, artifact, &options, &kernel);
    if (status != .ok) return raiseStatus(status, "kernel");
    return KernelHandle.wrap(kernel.?, &.{ given[0], given[1] });
}

fn bindingCreate(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 4, "binding_create") orelse return null;
    const context = ContextHandle.unwrap(given[0]) orelse return null;
    const kernel = KernelHandle.unwrap(given[1]) orelse return null;
    const model = ModelHandle.unwrap(given[2]) orelse return null;
    const point = PointHandle.unwrap(given[3]) orelse return null;

    var binding: ?*PhaserBinding = null;
    const status = phaser_binding_create(context, kernel, model, point, &binding);
    if (status != .ok) return raiseStatus(status, "binding");
    return BindingHandle.wrap(
        binding.?,
        &.{ given[0], given[1], given[2], given[3] },
    );
}

// ---------------------------------------------------------------------------
// Typed metadata
//
// One dictionary per handle rather than one function per field. The ABI
// publishes typed queries precisely so no consumer parses JSON to size a
// buffer, and gathering them per handle keeps that property without turning
// this file into thirty near-identical accessors.
// ---------------------------------------------------------------------------

fn modelInfo(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 1, "model_info") orelse return null;
    const model = ModelHandle.unwrap(given[0]) orelse return null;

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

    const info = py.PyDict_New() orelse return null;
    const filled = setOwned(
        info,
        "fingerprint",
        py.PyUnicode_FromStringAndSize(&hex, hex.len),
    ) and
        setCount(info, "parameter_count", parameters) and
        setCount(info, "scalar_field_count", scalars);
    if (!filled) {
        py.Py_DecRef(info);
        return null;
    }
    return info;
}

fn requestInfo(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 1, "request_info") orelse return null;
    const request = RequestHandle.unwrap(given[0]) orelse return null;

    var loop_order: u32 = 0;
    var coordinates: usize = 0;
    if (phaser_request_loop_order(request, &loop_order) != .ok or
        phaser_request_coordinate_count(request, &coordinates) != .ok)
    {
        return raiseStatus(.internal, "request");
    }

    const info = py.PyDict_New() orelse return null;
    const filled = setOwned(info, "loop_order", py.PyLong_FromUnsignedLong(loop_order)) and
        setCount(info, "coordinate_count", coordinates);
    if (!filled) {
        py.Py_DecRef(info);
        return null;
    }
    return info;
}

fn artifactInfo(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 1, "artifact_info") orelse return null;
    const artifact = ArtifactHandle.unwrap(given[0]) orelse return null;

    var loop_order: u32 = 0;
    var coordinates: usize = 0;
    var contributions: usize = 0;
    var result_type: i32 = 0;
    if (phaser_artifact_loop_order(artifact, &loop_order) != .ok or
        phaser_artifact_coordinate_count(artifact, &coordinates) != .ok or
        phaser_artifact_contribution_count(artifact, &contributions) != .ok or
        phaser_artifact_result_type(artifact, &result_type) != .ok)
    {
        return raiseStatus(.internal, "artifact");
    }

    const info = py.PyDict_New() orelse return null;
    const filled = setOwned(info, "loop_order", py.PyLong_FromUnsignedLong(loop_order)) and
        setCount(info, "coordinate_count", coordinates) and
        setCount(info, "contribution_count", contributions) and
        setOwned(info, "result_type", py.PyLong_FromSsize_t(result_type));
    if (!filled) {
        py.Py_DecRef(info);
        return null;
    }
    return info;
}

fn kernelInfo(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 1, "kernel_info") orelse return null;
    const kernel = KernelHandle.unwrap(given[0]) orelse return null;

    var result_type: i32 = 0;
    var capability: i32 = 0;
    var coordinates: usize = 0;
    var parameters: usize = 0;
    if (phaser_kernel_result_type(kernel, &result_type) != .ok or
        phaser_kernel_capability(kernel, &capability) != .ok or
        phaser_kernel_coordinate_count(kernel, &coordinates) != .ok or
        phaser_kernel_parameter_count(kernel, &parameters) != .ok)
    {
        return raiseStatus(.internal, "kernel");
    }

    const info = py.PyDict_New() orelse return null;
    const filled = setOwned(info, "result_type", py.PyLong_FromSsize_t(result_type)) and
        setOwned(info, "capability", py.PyLong_FromSsize_t(capability)) and
        setCount(info, "coordinate_count", coordinates) and
        setCount(info, "parameter_count", parameters);
    if (!filled) {
        py.Py_DecRef(info);
        return null;
    }
    return info;
}

fn pointInfo(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 1, "point_info") orelse return null;
    const point = PointHandle.unwrap(given[0]) orelse return null;

    var scale: f64 = 0;
    if (phaser_point_reference_scale(point, &scale) != .ok) {
        return raiseStatus(.internal, "point");
    }

    const info = py.PyDict_New() orelse return null;
    if (!setOwned(info, "reference_scale", py.PyFloat_FromDouble(scale))) {
        py.Py_DecRef(info);
        return null;
    }
    return info;
}

fn bindingInfo(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 1, "binding_info") orelse return null;
    const binding = BindingHandle.unwrap(given[0]) orelse return null;

    var coordinates: usize = 0;
    var result_type: i32 = 0;
    if (phaser_binding_coordinate_count(binding, &coordinates) != .ok or
        phaser_binding_result_type(binding, &result_type) != .ok)
    {
        return raiseStatus(.internal, "binding");
    }

    const info = py.PyDict_New() orelse return null;
    const filled = setCount(info, "coordinate_count", coordinates) and
        setOwned(info, "result_type", py.PyLong_FromSsize_t(result_type));
    if (!filled) {
        py.Py_DecRef(info);
        return null;
    }
    return info;
}

fn artifactExport(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const given = takeArgs(arguments, 2, "artifact_export") orelse return null;
    const artifact = ArtifactHandle.unwrap(given[0]) orelse return null;
    const target = takeEnumerator(given[1], "export target") orelse return null;

    // The ABI's one sizing convention: a null buffer reports the length that
    // would be written, and says so with INSUFFICIENT_SPACE rather than OK.
    var required: usize = 0;
    const sizing = phaser_artifact_export(artifact, target, null, 0, &required);
    if (sizing != .insufficient_space) return raiseStatus(sizing, "export");
    if (required == 0) return py.PyUnicode_FromStringAndSize("", 0);

    const buffer = std.heap.c_allocator.alloc(u8, required) catch
        return raiseStatus(.out_of_memory, "export");
    defer std.heap.c_allocator.free(buffer);

    var written: usize = 0;
    const status = phaser_artifact_export(
        artifact,
        target,
        buffer.ptr,
        buffer.len,
        &written,
    );
    if (status != .ok) return raiseStatus(status, "export");
    return py.PyUnicode_FromStringAndSize(buffer.ptr, @intCast(written));
}

// ---------------------------------------------------------------------------
// Batch evaluation
//
// Backgrounds arrive through the buffer protocol, so a NumPy array, an
// `array.array('d')`, and a `memoryview` all cross without a copy and without
// this file knowing which one it was handed. Results leave as byte buffers the
// Python layer presents as shaped memoryviews -- also the buffer protocol, and
// also without a copy.
//
// A NumPy dependency is deliberately not required for either direction, per
// decision 0015: `phaser_complex` is two adjacent doubles, which is exactly
// `complex128`, so a caller who does have NumPy can view the same bytes as a
// complex array with no conversion step here.
// ---------------------------------------------------------------------------

fn evaluate(_: ?*py.PyObject, arguments: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const outputs = py.PyDict_New() orelse return null;
    if (!evaluateInto(outputs, arguments)) {
        py.Py_DecRef(outputs);
        return null;
    }
    return outputs;
}

/// Returns false with a Python exception set; the caller owns `outputs`.
fn evaluateInto(outputs: ?*py.PyObject, arguments: ?*py.PyObject) bool {
    const given = takeArgs(arguments, 3, "evaluate") orelse return false;
    const binding = BindingHandle.unwrap(given[0]) orelse return false;
    // The kernel is passed alongside the binding because its capability
    // decides the exact output lengths the ABI requires, and the ABI has no
    // query for a binding's capability. Reading it from the kernel keeps that
    // a fact rather than something the Python layer asserts.
    const kernel = KernelHandle.unwrap(given[1]) orelse return false;

    var coordinates: usize = 0;
    var result_type: i32 = 0;
    var capability: i32 = 0;
    if (phaser_binding_coordinate_count(binding, &coordinates) != .ok or
        phaser_binding_result_type(binding, &result_type) != .ok or
        phaser_kernel_capability(kernel, &capability) != .ok)
    {
        _ = raiseStatus(.internal, "binding");
        return false;
    }
    if (coordinates == 0) {
        _ = raiseStatus(.internal, "binding");
        return false;
    }

    var view: py.Py_buffer = undefined;
    if (py.PyObject_GetBuffer(
        given[2],
        &view,
        py.PyBUF_C_CONTIGUOUS | py.PyBUF_FORMAT,
    ) != 0) return false;
    defer py.PyBuffer_Release(&view);

    const format = view.format orelse {
        _ = raiseType("backgrounds must expose an item format");
        return false;
    };
    if (view.itemsize != @sizeOf(f64) or !std.mem.eql(u8, std.mem.span(format), "d")) {
        _ = raiseType("backgrounds must be a contiguous buffer of float64 items");
        return false;
    }

    const background_count: usize = @as(usize, @intCast(@max(view.len, 0))) /
        @sizeOf(f64);
    if (background_count == 0 or background_count % coordinates != 0) {
        _ = raiseValue(
            "backgrounds must hold a positive whole number of points",
        );
        return false;
    }
    const point_count = background_count / coordinates;
    const backgrounds: [*]const f64 = @ptrCast(@alignCast(view.buf orelse {
        _ = raiseValue("backgrounds buffer has no storage");
        return false;
    }));

    const complex = result_type == RESULT_COMPLEX64;
    const element_bytes: usize = if (complex) @sizeOf(Complex) else @sizeOf(f64);

    // The shapes the ABI requires exactly: it rejects a mismatched count
    // rather than writing as much as fits.
    const gradient_count: usize = if (capability >= 1) background_count else 0;
    const hessian_count: usize = if (capability >= 2)
        std.math.mul(usize, background_count, coordinates) catch {
            _ = raiseStatus(.limit_exceeded, "outputs");
            return false;
        }
    else
        0;

    const values = addBuffer(
        outputs,
        "values",
        point_count * element_bytes,
    ) orelse return false;
    const statuses = addBuffer(
        outputs,
        "statuses",
        point_count * @sizeOf(i32),
    ) orelse return false;
    const gradients = if (gradient_count == 0) null else addBuffer(
        outputs,
        "gradients",
        gradient_count * element_bytes,
    ) orelse return false;
    const hessians = if (hessian_count == 0) null else addBuffer(
        outputs,
        "hessians",
        hessian_count * element_bytes,
    ) orelse return false;

    var workspace_bytes: usize = 0;
    var workspace_alignment: usize = 0;
    if (phaser_binding_workspace(
        binding,
        point_count,
        &workspace_bytes,
        &workspace_alignment,
    ) != .ok) {
        _ = raiseStatus(.limit_exceeded, "workspace");
        return false;
    }
    const workspace = Workspace.init(workspace_bytes, workspace_alignment) orelse {
        _ = raiseStatus(.out_of_memory, "workspace");
        return false;
    };
    defer workspace.deinit();

    // The interpreter lock is released around the core call, which is the one
    // part of this function whose cost grows with the batch. Nothing inside
    // touches a Python object: the background bytes are pinned by the buffer
    // view, and the output buffers were created here and are not yet reachable
    // from any other thread.
    const saved = py.PyEval_SaveThread();
    const status = if (complex) blk: {
        var description = ComplexOutputs{
            .struct_size = @sizeOf(ComplexOutputs),
            .abi_version = 0,
            .values = @ptrCast(@alignCast(values)),
            .value_count = point_count,
            .gradients = if (gradients) |g| @ptrCast(@alignCast(g)) else null,
            .gradient_count = gradient_count,
            .hessians = if (hessians) |h| @ptrCast(@alignCast(h)) else null,
            .hessian_count = hessian_count,
            .statuses = @ptrCast(@alignCast(statuses)),
            .status_count = point_count,
        };
        break :blk phaser_evaluate_complex(
            binding,
            backgrounds,
            background_count,
            point_count,
            workspace.aligned.ptr,
            workspace.aligned.len,
            &description,
        );
    } else blk: {
        var description = Outputs{
            .struct_size = @sizeOf(Outputs),
            .abi_version = 0,
            .values = @ptrCast(@alignCast(values)),
            .value_count = point_count,
            .gradients = if (gradients) |g| @ptrCast(@alignCast(g)) else null,
            .gradient_count = gradient_count,
            .hessians = if (hessians) |h| @ptrCast(@alignCast(h)) else null,
            .hessian_count = hessian_count,
            .statuses = @ptrCast(@alignCast(statuses)),
            .status_count = point_count,
        };
        break :blk phaser_evaluate(
            binding,
            backgrounds,
            background_count,
            point_count,
            workspace.aligned.ptr,
            workspace.aligned.len,
            &description,
        );
    };
    py.PyEval_RestoreThread(saved);

    if (status != .ok) {
        _ = raiseStatus(status, "evaluate");
        return false;
    }

    return setCount(outputs, "point_count", point_count) and
        setCount(outputs, "coordinate_count", coordinates) and
        setOwned(outputs, "result_type", py.PyLong_FromSsize_t(result_type));
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
        .ml_name = "context_create",
        .ml_meth = contextCreate,
        .ml_flags = py.METH_NOARGS,
        .ml_doc = "Create a context handle.",
    },
    .{
        .ml_name = "model_load",
        .ml_meth = modelLoad,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Parse a model from bytes and return a handle.",
    },
    .{
        .ml_name = "model_info",
        .ml_meth = modelInfo,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Return a model's fingerprint and typed counts.",
    },
    .{
        .ml_name = "request_parse",
        .ml_meth = requestParse,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Parse a calculation request from bytes and return a handle.",
    },
    .{
        .ml_name = "request_info",
        .ml_meth = requestInfo,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Return a request's loop order and coordinate count.",
    },
    .{
        .ml_name = "artifact_derive",
        .ml_meth = artifactDerive,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Derive the effective potential and return a handle.",
    },
    .{
        .ml_name = "artifact_info",
        .ml_meth = artifactInfo,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Return an artifact's typed metadata.",
    },
    .{
        .ml_name = "artifact_export",
        .ml_meth = artifactExport,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Render an artifact's equations for an export target.",
    },
    .{
        .ml_name = "kernel_compile",
        .ml_meth = kernelCompile,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Compile a numerical kernel for an artifact.",
    },
    .{
        .ml_name = "kernel_info",
        .ml_meth = kernelInfo,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Return a kernel's result type, capability, and counts.",
    },
    .{
        .ml_name = "point_parse",
        .ml_meth = pointParse,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Parse a parameter point from bytes and return a handle.",
    },
    .{
        .ml_name = "point_info",
        .ml_meth = pointInfo,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Return a parameter point's reference scale.",
    },
    .{
        .ml_name = "binding_create",
        .ml_meth = bindingCreate,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Bind a parameter point to a kernel.",
    },
    .{
        .ml_name = "binding_info",
        .ml_meth = bindingInfo,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Return a binding's coordinate count and result type.",
    },
    .{
        .ml_name = "evaluate",
        .ml_meth = evaluate,
        .ml_flags = py.METH_VARARGS,
        .ml_doc = "Evaluate a batch of background points into byte buffers.",
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
