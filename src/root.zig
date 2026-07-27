//! Public experimental Zig interface for Phaser.
//!
//! Internal Zig APIs may evolve with the pinned compiler. No declaration in
//! this module defines a stable C ABI or persisted binary layout.

pub const foundation = @import("foundation/root.zig");
pub const model = @import("model/root.zig");
pub const expression = @import("expression/root.zig");
pub const value = @import("value/root.zig");
pub const calculation = @import("calculation/root.zig");
pub const symbolic = @import("export/root.zig");
pub const kernel = @import("kernel/root.zig");
const numerics = @import("numerics/root.zig");

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
pub const CalculationLimits = calculation.CalculationLimits;
pub const CalculationRequest = calculation.Request;
pub const RequestSource = calculation.RequestSource;
pub const parseRequest = calculation.parseRequest;
pub const PotentialArtifact = calculation.Artifact;
pub const PotentialContribution = calculation.Contribution;
pub const PotentialRole = calculation.Role;
pub const PotentialSelection = calculation.Selection;
pub const ResultType = calculation.ResultType;
pub const deriveEffectivePotential = calculation.deriveEffectivePotential;
pub const deriveClassicalPotential = calculation.deriveClassicalPotential;
pub const ParameterPoint = calculation.ParameterPoint;
pub const PointSource = calculation.PointSource;
pub const parseParameterPoint = calculation.parseParameterPoint;
pub const PotentialKernel = kernel.Kernel;
pub const KernelConfiguration = kernel.Configuration;
pub const KernelSelection = kernel.Selection;
pub const Complex64 = kernel.Complex64;
pub const KernelResultType = kernel.ResultType;
pub const OutputBuffers = kernel.OutputBuffers;
pub const ComplexOutputBuffers = kernel.ComplexOutputBuffers;
pub const Binding = kernel.Binding;
pub const compileKernel = kernel.compile;
pub const bindParameters = kernel.bind;

test {
    _ = foundation;
    _ = model;
    _ = expression;
    _ = value;
    _ = calculation;
    _ = symbolic;
    _ = kernel;
    _ = numerics;
}
