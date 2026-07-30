//! Numerical Kernel IR, lowering, and the safe reference backend.

pub const program = @import("program.zig");
pub const lowering = @import("lower.zig");
pub const interpreter = @import("interpret.zig");
pub const optimized_plan = @import("optimized_plan.zig");
pub const optimized_interpreter = @import("optimized_interpret.zig");
/// Build-tool-only representation used by the explicit AOT prototype.
pub const aot_plan = @import("aot_plan.zig");
/// Deterministic source emitter for the explicit AOT prototype.
pub const aot_generate = @import("aot_generate.zig");
pub const chunking = @import("chunking.zig");
pub const potential = @import("potential.zig");
pub const bindings = @import("binding.zig");

pub const Scalar = program.Scalar;
pub const Complex64 = program.Complex64;
pub const ResultType = program.ResultType;
pub const SlotType = program.SlotType;
pub const Temporary = program.Temporary;
pub const LiveRange = program.LiveRange;
pub const Opcode = program.Opcode;
pub const Instruction = program.Instruction;
pub const Capability = program.Capability;
pub const Backend = program.Backend;
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
pub const ComplexOutputBuffers = interpreter.ComplexOutputBuffers;
pub const evaluate = interpreter.evaluate;
pub const evaluateComplex = interpreter.evaluateComplex;
pub const integerPower = interpreter.integerPower;
pub const scalarOneLoopTerm = interpreter.scalarOneLoopTerm;

pub const Kernel = potential.Kernel;
pub const Configuration = potential.Configuration;
pub const Selection = potential.Selection;
pub const Channel = potential.Channel;
pub const CompileError = potential.CompileError;
pub const compile = potential.compile;

pub const Binding = bindings.Binding;
pub const BindError = bindings.BindError;
pub const bind = bindings.bind;
pub const runParameterStage = interpreter.runParameterStage;
pub const evaluateStaged = interpreter.evaluateStaged;
pub const evaluateStagedComplex = interpreter.evaluateStagedComplex;
pub const ExecutionPlan = optimized_plan.ExecutionPlan;
pub const optimizedBlockWidth = optimized_plan.block_width;
pub const Chunk = chunking.Chunk;
pub const ChunkError = chunking.ChunkError;
pub const chunkForWorker = chunking.forWorker;

test {
    _ = program;
    _ = lowering;
    _ = interpreter;
    _ = optimized_plan;
    _ = optimized_interpreter;
    _ = aot_plan;
    _ = aot_generate;
    _ = chunking;
    _ = potential;
    _ = bindings;
}
