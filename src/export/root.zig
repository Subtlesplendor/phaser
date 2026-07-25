//! Symbolic export of Typed Value IR and derived artifacts.
//!
//! Provides the human-readable Phaser notation and the delimiter-free
//! MathJax-compatible LaTeX fragment. Scientific selection happens through
//! artifact metadata before rendering; a target renderer never decides which
//! contributions to include.

pub const render = @import("render.zig");
pub const potential = @import("potential.zig");

pub const Target = render.Target;
pub const Options = render.Options;
pub const RenderError = render.RenderError;
pub const writeValue = render.writeValue;
pub const writeValuePreview = render.writeValuePreview;
pub const renderAlloc = render.renderAlloc;
pub const countNodes = render.countNodes;

pub const writePotential = potential.writePotential;
pub const writeContribution = potential.writeContribution;
pub const writeGradientComponent = potential.writeGradientComponent;
pub const writeBackground = potential.writeBackground;
pub const writeSummary = potential.writeSummary;

test {
    _ = render;
    _ = potential;
}
