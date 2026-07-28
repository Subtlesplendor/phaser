//! The versioned C-facing boundary.
//!
//! The exported symbols live in `exports.zig`. Importing this file is what
//! causes them to be analyzed and emitted, so the library root imports it for
//! its side effect rather than for a declaration.
//!
//! Nothing here is part of the supported Zig API. A Zig caller uses the core
//! directly; this subsystem exists for C and for the language adapters built on
//! top of it, and it contains no independent physics or numerical logic.

pub const exports = @import("exports.zig");
pub const handle = @import("handle.zig");
pub const status = @import("status.zig");

pub const Status = status.Status;
pub const PointStatus = status.PointStatus;

test {
    _ = exports;
    _ = handle;
    _ = status;
}
