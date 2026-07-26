//! Calculation requests, planning, and derived artifacts.

pub const limits = @import("limits.zig");
pub const request = @import("request.zig");
pub const potential = @import("potential.zig");
pub const parameter_point = @import("parameter_point.zig");

pub const CalculationLimits = limits.CalculationLimits;
pub const HardLimits = limits.HardLimits;

pub const Request = request.Request;
pub const RequestSource = request.RequestSource;
pub const RequestFingerprint = request.Fingerprint;
pub const ParseOptions = request.ParseOptions;
pub const ParseResult = request.ParseResult;
pub const ParseError = request.ParseError;
pub const BackgroundMode = request.BackgroundMode;
pub const EnvironmentKind = request.EnvironmentKind;
pub const Scheme = request.Scheme;
pub const parseRequest = request.parseRequest;
pub const supported_loop_order = request.supported_loop_order;

pub const Artifact = potential.Artifact;
pub const Contribution = potential.Contribution;
pub const Coordinate = potential.Coordinate;
pub const Role = potential.Role;
pub const StructuralAbsence = potential.StructuralAbsence;
pub const AbsenceReason = potential.AbsenceReason;
pub const Derivatives = potential.Derivatives;
pub const DeriveOptions = potential.DeriveOptions;
pub const DeriveResult = potential.DeriveResult;
pub const DeriveError = potential.DeriveError;
pub const deriveClassicalPotential = potential.deriveClassicalPotential;

pub const ParameterPoint = parameter_point.ParameterPoint;
pub const PointSource = parameter_point.PointSource;
pub const PointLimits = parameter_point.PointLimits;
pub const MassUnit = parameter_point.MassUnit;
pub const parseParameterPoint = parameter_point.parseParameterPoint;
pub const validateCoverage = parameter_point.validateCoverage;

test {
    _ = limits;
    _ = request;
    _ = potential;
    _ = parameter_point;
}
