//! Derived Typed Value IR.
//!
//! Holds the interned value graph of one calculation artifact and its exact
//! symbolic derivatives. The separation from the source-expression
//! representation is recorded in decision 0002; the differentiation method in
//! decision 0003.

pub const limits = @import("limits.zig");
pub const graph = @import("graph.zig");
pub const differentiation = @import("differentiate.zig");

pub const ValueLimits = limits.ValueLimits;
pub const HardLimits = limits.HardLimits;

pub const ValueId = graph.ValueId;
pub const Node = graph.Node;
pub const Value = graph.Value;
pub const ValueType = graph.ValueType;
pub const Domain = graph.Domain;
pub const Shape = graph.Shape;
pub const FormulaVersion = graph.FormulaVersion;
pub const BranchPolicy = graph.BranchPolicy;
pub const Parameter = graph.Parameter;
pub const BackgroundInput = graph.Background;
pub const Scale = graph.Scale;
pub const Element = graph.Element;
pub const SymmetricMatrix = graph.SymmetricMatrix;
pub const SpectralValue = graph.SpectralValue;
pub const SpectralDerivative = graph.SpectralDerivative;
pub const Graph = graph.Graph;
pub const Builder = graph.Builder;
pub const BuildError = graph.BuildError;
pub const Rational = graph.Rational;
pub const childAt = graph.childAt;
pub const upperTriangleCount = graph.upperTriangleCount;
pub const upperTriangleIndex = graph.upperTriangleIndex;
pub const scale_mass_dimension = graph.scale_mass_dimension;
pub const mass_squared_dimension = graph.mass_squared_dimension;
pub const spectral_value_mass_dimension = graph.spectral_value_mass_dimension;
pub const importExpression = graph.importExpression;

pub const Background = differentiation.Background;
pub const differentiate = differentiation.differentiate;
pub const gradient = differentiation.gradient;
pub const hessian = differentiation.hessian;

test {
    _ = limits;
    _ = graph;
    _ = differentiation;
}
