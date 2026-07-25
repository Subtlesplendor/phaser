//! Public experimental Zig interface for Phaser.
//!
//! Internal Zig APIs may evolve with the pinned compiler. No declaration in
//! this module defines a stable C ABI or persisted binary layout.

pub const foundation = @import("foundation/root.zig");
pub const model = @import("model/root.zig");
pub const expression = @import("expression/root.zig");
pub const value = @import("value/root.zig");

pub const Context = foundation.Context;
pub const Limits = foundation.Limits;
pub const TypedId = foundation.TypedId;
pub const SourceId = foundation.SourceId;
pub const SourceSpan = foundation.SourceSpan;
pub const SourceSpanResult = foundation.SourceSpanResult;
pub const makeSourceSpan = foundation.makeSourceSpan;
pub const ByteSize = foundation.ByteSize;
pub const Budget = foundation.Budget;
pub const Code = foundation.Code;
pub const Category = foundation.Category;
pub const Severity = foundation.Severity;
pub const Resource = foundation.Resource;
pub const Detail = foundation.Detail;
pub const Diagnostic = foundation.Diagnostic;
pub const Diagnostics = foundation.Diagnostics;
pub const DiagnosticBuilder = foundation.DiagnosticBuilder;
pub const allocationFailure = foundation.allocationFailure;
pub const ModelLimits = model.ModelLimits;
pub const Model = model.Model;
pub const ModelSource = model.ModelSource;
pub const ModelLoadOptions = model.ModelLoadOptions;
pub const ModelLoadResult = model.ModelLoadResult;
pub const ModelLoadError = model.ModelLoadError;
pub const ModelFingerprint = model.ModelFingerprint;
pub const TensorKind = model.TensorKind;
pub const loadModel = model.loadModel;
pub const ValueLimits = value.ValueLimits;
pub const ValueGraph = value.Graph;
pub const ValueGraphBuilder = value.Builder;
pub const ValueId = value.ValueId;

test {
    _ = foundation;
    _ = model;
    _ = expression;
    _ = value;
}
