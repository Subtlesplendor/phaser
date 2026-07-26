//! Numerical Kernel IR, lowering, and the safe reference backend.

pub const program = @import("program.zig");
pub const lowering = @import("lower.zig");
pub const interpreter = @import("interpret.zig");
pub const potential = @import("potential.zig");

pub const Scalar = program.Scalar;
pub const Opcode = program.Opcode;
pub const Instruction = program.Instruction;
pub const Capability = program.Capability;
pub const Status = program.Status;
pub const Outputs = program.Outputs;
pub const WorkspaceLayout = program.WorkspaceLayout;
pub const Program = program.Program;
pub const ValidationError = program.ValidationError;

pub const LowerError = lowering.LowerError;
pub const LowerOptions = lowering.LowerOptions;
pub const Request = lowering.Request;
pub const lower = lowering.lower;
pub const rationalToScalar = lowering.rationalToScalar;

pub const CallError = interpreter.CallError;
pub const Inputs = interpreter.Inputs;
pub const OutputBuffers = interpreter.OutputBuffers;
pub const evaluate = interpreter.evaluate;
pub const integerPower = interpreter.integerPower;

pub const Kernel = potential.Kernel;
pub const Configuration = potential.Configuration;
pub const Channel = potential.Channel;
pub const CompileError = potential.CompileError;
pub const compile = potential.compile;

test {
    _ = program;
    _ = lowering;
    _ = interpreter;
    _ = potential;
}
