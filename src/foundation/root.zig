//! Domain-independent correctness substrate.

const typed_id = @import("typed_id.zig");
const source = @import("source.zig");
const diagnostic = @import("diagnostic.zig");
const capacity = @import("capacity.zig");
const context = @import("context.zig");
const validation = @import("validation.zig");

pub const TypedId = typed_id.TypedId;
pub const SourceId = typed_id.SourceId;

pub const SourceSpan = source.SourceSpan;
pub const SourceSpanError = source.SourceSpanError;
pub const SourceSpanResult = validation.SourceSpanResult;
pub const makeSourceSpan = validation.makeSourceSpan;

pub const Code = diagnostic.Code;
pub const Category = diagnostic.Category;
pub const Severity = diagnostic.Severity;
pub const Resource = diagnostic.Resource;
pub const LimitName = diagnostic.LimitName;
pub const Detail = diagnostic.Detail;
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticId = diagnostic.DiagnosticId;
pub const DiagnosticTemplate = diagnostic.Template;
pub const Diagnostics = diagnostic.Diagnostics;
pub const DiagnosticBuilder = diagnostic.Builder;
pub const allocationFailure = diagnostic.allocationFailure;

pub const ByteSize = capacity.ByteSize;
pub const CapacityResult = capacity.Result;
pub const Budget = capacity.Budget;
pub const Reservation = capacity.Reservation;

pub const Limits = context.Limits;
pub const Context = context.Context;
pub const ContextResult = context.Result;

test {
    _ = typed_id;
    _ = source;
    _ = diagnostic;
    _ = capacity;
    _ = context;
    _ = validation;
}
