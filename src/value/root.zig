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
pub const Parameter = graph.Parameter;
pub const Background = graph.Background;
pub const Graph = graph.Graph;
pub const Builder = graph.Builder;
pub const BuildError = graph.BuildError;
pub const Rational = graph.Rational;
pub const importExpression = graph.importExpression;

pub const differentiate = differentiation.differentiate;
pub const gradient = differentiation.gradient;
pub const hessian = differentiation.hessian;

test {
    _ = limits;
    _ = graph;
    _ = differentiation;
}
