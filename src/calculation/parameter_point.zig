//! Numerical parameter points.
//!
//! Parses and validates the `phaser.parameter-point/0.1` source form specified
//! in `docs/formats/RENORMALIZATION_GROUP.md` sections 3 and 4.
//!
//! A parameter point is data, not structure. It carries the numerical values a
//! calculation is evaluated at, together with the scheme and reference scale
//! those values belong to.

const std = @import("std");
const foundation = @import("../foundation/root.zig");
const model_module = @import("../model/root.zig");
const request_module = @import("request.zig");
const limits_module = @import("limits.zig");

pub const Scheme = request_module.Scheme;

/// Version 0.1 supports one mass unit.
pub const MassUnit = enum { gev };

pub const PointHardLimits = struct {
    pub const source_bytes: usize = 1024 * 1024;
    pub const json_tokens: usize = 64 * 1024;
    pub const json_nesting: usize = 64;
    pub const significant_digits: usize = 4096;
    pub const decimal_exponent: usize = 4096;
};

pub const PointLimits = struct {
    source_bytes: usize = 64 * 1024,
    json_tokens: usize = 4096,
    json_nesting: usize = 16,
    /// Documented bound on significant digits, required by section 4.
    significant_digits: usize = 40,
    /// Documented bound on the decimal exponent, required by section 4.
    decimal_exponent: usize = 300,

    pub fn validate(self: PointLimits) ?foundation.Diagnostic {
        inline for (@typeInfo(PointLimits).@"struct".fields) |field| {
            const value = @field(self, field.name);
            const hard = @field(PointHardLimits, field.name);
            if (value == 0 or value > hard) {
                return .{
                    .code = .invalid_limit,
                    .category = .configuration,
                    .detail = .{ .invalid_limit = .{
                        .name = @field(foundation.LimitName, field.name),
                        .value = value,
                    } },
                };
            }
        }
        return null;
    }
};

pub const Entry = struct {
    name: []const u8,
    value: f64,
};

pub const ParameterPoint = struct {
    arena: *std.heap.ArenaAllocator,
    mass_unit: MassUnit,
    scheme: Scheme,
    reference_scale: f64,
    /// Sorted by name, so lookup is deterministic and duplicate detection is
    /// a neighbour comparison.
    entries: []const Entry,

    pub fn deinit(self: *ParameterPoint) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn lookup(self: *const ParameterPoint, name: []const u8) ?f64 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.value;
        }
        return null;
    }
};

pub const PointSource = struct {
    source_id: foundation.SourceId,
    bytes: []const u8,
};

pub const ParseOptions = struct {
    limits: PointLimits = .{},
};

pub const ParseResult = union(enum) {
    point: ParameterPoint,
    diagnostics: foundation.Diagnostics,
};

pub const ParseError = error{
    OutOfMemory,
    DiagnosticCapacityExceeded,
    RelatedLocationCapacityExceeded,
};

const Failure = error{
    InvalidParameterPointSchema,
    MissingProperty,
    UnknownProperty,
    InvalidPropertyType,
    UnsupportedMassUnit,
    UnsupportedScheme,
    InvalidScale,
    InvalidNumber,
    NumberNotRepresentable,
    DuplicateParameterValue,
    CapacityExceeded,
};

fn failureInfo(failure: Failure) foundation.Code {
    return switch (failure) {
        error.InvalidParameterPointSchema => .invalid_parameter_point_schema,
        error.MissingProperty => .missing_property,
        error.UnknownProperty => .unknown_property,
        error.InvalidPropertyType => .invalid_property_type,
        error.UnsupportedMassUnit => .unsupported_mass_unit,
        error.UnsupportedScheme => .unsupported_scheme,
        error.InvalidScale => .invalid_scale,
        error.InvalidNumber => .invalid_number,
        error.NumberNotRepresentable => .number_not_representable,
        error.DuplicateParameterValue => .duplicate_property,
        error.CapacityExceeded => .capacity_exceeded,
    };
}

pub fn parseParameterPoint(
    context: foundation.Context,
    source: PointSource,
    options: ParseOptions,
) ParseError!ParseResult {
    if (options.limits.validate()) |diagnostic| {
        return .{ .diagnostics = try oneDiagnosticValue(context, diagnostic) };
    }
    if (source.bytes.len > options.limits.source_bytes) {
        return .{ .diagnostics = try oneDiagnostic(
            context,
            .capacity_exceeded,
            .calculation,
        ) };
    }

    if (try scanJson(context.allocator, source, options.limits)) |diagnostic| {
        return .{ .diagnostics = try oneDiagnosticValue(context, diagnostic) };
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        context.allocator,
        source.bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
            .max_value_len = options.limits.source_bytes,
            .allocate = .alloc_always,
        },
    ) catch |err| {
        return .{ .diagnostics = try oneDiagnostic(
            context,
            if (err == error.DuplicateField) .duplicate_property else .invalid_json,
            .json,
        ) };
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .diagnostics = try oneDiagnostic(
            context,
            .invalid_property_type,
            .json,
        ) },
    };

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    errdefer context.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer arena.deinit();

    const built = build(root, options, arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            arena.deinit();
            context.allocator.destroy(arena);
            return .{ .diagnostics = try oneDiagnostic(
                context,
                failureInfo(@errorCast(err)),
                .calculation,
            ) };
        },
    };

    return .{ .point = .{
        .arena = arena,
        .mass_unit = built.mass_unit,
        .scheme = built.scheme,
        .reference_scale = built.reference_scale,
        .entries = built.entries,
    } };
}

const Built = struct {
    mass_unit: MassUnit,
    scheme: Scheme,
    reference_scale: f64,
    entries: []const Entry,
};

fn build(
    root: std.json.ObjectMap,
    options: ParseOptions,
    allocator: std.mem.Allocator,
) !Built {
    try rejectUnknown(root, &.{ "schema", "units", "renormalization", "values" });
    if (!std.mem.eql(
        u8,
        try requiredString(root, "schema"),
        "phaser.parameter-point/0.1",
    )) {
        return error.InvalidParameterPointSchema;
    }

    const units = try requiredObject(root, "units");
    try rejectUnknown(units, &.{"mass"});
    if (!std.mem.eql(u8, try requiredString(units, "mass"), "GeV")) {
        return error.UnsupportedMassUnit;
    }

    const renormalization = try requiredObject(root, "renormalization");
    try rejectUnknown(renormalization, &.{ "scheme", "reference_scale" });
    if (!std.mem.eql(u8, try requiredString(renormalization, "scheme"), "MSbar")) {
        return error.UnsupportedScheme;
    }
    const reference_scale = try parseNumber(
        try requiredNumberText(renormalization, "reference_scale"),
        options.limits,
    );
    // Every numerical scale is finite and strictly positive.
    if (!(reference_scale > 0) or !std.math.isFinite(reference_scale)) {
        return error.InvalidScale;
    }

    const values = try requiredObject(root, "values");
    const entries = try allocator.alloc(Entry, values.count());
    var iterator = values.iterator();
    var index: usize = 0;
    while (iterator.next()) |item| : (index += 1) {
        const text = switch (item.value_ptr.*) {
            .number_string => |number| number,
            else => return error.InvalidPropertyType,
        };
        entries[index] = .{
            .name = try allocator.dupe(u8, item.key_ptr.*),
            .value = try parseNumber(text, options.limits),
        };
    }

    // Member order carries no meaning, so a canonical sort makes lookup and
    // duplicate detection deterministic.
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.less);
    if (entries.len > 1) {
        for (entries[1..], entries[0 .. entries.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current.name, previous.name)) {
                return error.DuplicateParameterValue;
            }
        }
    }

    return .{
        .mass_unit = .gev,
        .scheme = .msbar,
        .reference_scale = reference_scale,
        .entries = entries,
    };
}

/// Converts one JSON number to `f64`.
///
/// These are JSON numbers, not model expressions: no parameters, arithmetic,
/// `pi`, or `sqrt`. Non-finite spellings are invalid, overflow and underflow
/// that would change a nonzero value are diagnostics rather than silent
/// conversions, and negative zero normalizes to zero.
fn parseNumber(text: []const u8, limits: PointLimits) !f64 {
    if (text.len == 0) return error.InvalidNumber;

    var digits: usize = 0;
    var exponent_digits: usize = 0;
    var seen_exponent = false;
    for (text) |byte| {
        switch (byte) {
            '0'...'9' => if (seen_exponent) {
                exponent_digits += 1;
            } else {
                digits += 1;
            },
            'e', 'E' => seen_exponent = true,
            '+', '-', '.' => {},
            // Rejects nan, inf, hexadecimal, and any other non-JSON spelling.
            else => return error.InvalidNumber,
        }
    }
    if (digits == 0) return error.InvalidNumber;
    if (digits > limits.significant_digits) return error.CapacityExceeded;
    if (exponent_digits > 4) return error.CapacityExceeded;

    const parsed = std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
    if (!std.math.isFinite(parsed)) return error.NumberNotRepresentable;

    // A nonzero source value that converts to zero has lost its magnitude.
    if (parsed == 0) {
        for (text) |byte| {
            if (byte >= '1' and byte <= '9') return error.NumberNotRepresentable;
        }
        // Negative zero normalizes to zero.
        return 0;
    }

    if (seen_exponent) {
        const marker = std.mem.indexOfAny(u8, text, "eE").?;
        const magnitude = std.fmt.parseInt(i32, text[marker + 1 ..], 10) catch
            return error.InvalidNumber;
        if (@abs(magnitude) > limits.decimal_exponent) return error.CapacityExceeded;
    }
    return parsed;
}

// -- JSON helpers ----------------------------------------------------------

fn requiredObject(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .object => |map| map,
        else => error.InvalidPropertyType,
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidPropertyType,
    };
}

fn requiredNumberText(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .number_string => |number| number,
        else => error.InvalidPropertyType,
    };
}

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnknownProperty;
    }
}

fn scanJson(
    allocator: std.mem.Allocator,
    source: PointSource,
    limits: PointLimits,
) !?foundation.Diagnostic {
    var scanner = std.json.Scanner.initCompleteInput(allocator, source.bytes);
    defer scanner.deinit();
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    var token_count: usize = 0;
    var depth: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.source_bytes,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{
                .code = .invalid_json,
                .category = .json,
            };
        };
        defer switch (token) {
            .allocated_string => |slice| allocator.free(slice),
            .allocated_number => |slice| allocator.free(slice),
            else => {},
        };
        token_count += 1;
        if (token_count > limits.json_tokens) {
            return .{ .code = .capacity_exceeded, .category = .json };
        }
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.json_nesting) {
                    return .{ .code = .capacity_exceeded, .category = .json };
                }
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => break,
            else => {},
        }
    }
    return null;
}

fn oneDiagnosticValue(
    context: foundation.Context,
    diagnostic: foundation.Diagnostic,
) ParseError!foundation.Diagnostics {
    var builder = context.diagnosticBuilder();
    defer builder.deinit();
    builder.append(.{
        .code = diagnostic.code,
        .category = diagnostic.category,
        .severity = diagnostic.severity,
        .primary = diagnostic.primary,
        .detail = diagnostic.detail,
        .related = diagnostic.related,
        .cause = diagnostic.cause,
    }) catch |err| switch (err) {
        error.InvalidCause => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
        error.DiagnosticCapacityExceeded => return error.DiagnosticCapacityExceeded,
        error.RelatedLocationCapacityExceeded => return error.RelatedLocationCapacityExceeded,
    };
    return builder.finish();
}

fn oneDiagnostic(
    context: foundation.Context,
    code: foundation.Code,
    category: foundation.Category,
) ParseError!foundation.Diagnostics {
    var builder = context.diagnosticBuilder();
    defer builder.deinit();
    builder.append(.{ .code = code, .category = category }) catch |err| switch (err) {
        error.InvalidCause => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
        error.DiagnosticCapacityExceeded => return error.DiagnosticCapacityExceeded,
        error.RelatedLocationCapacityExceeded => return error.RelatedLocationCapacityExceeded,
    };
    return builder.finish();
}

// -- model coverage --------------------------------------------------------

pub const CoverageError = error{
    MissingParameterValue,
    UnknownParameterValue,
};

/// Validates a point against a model.
///
/// Every parameter the model declares occurs exactly once, and no value names
/// something the model does not declare. A kernel that depends on only a subset
/// still binds against the complete point.
pub fn validateCoverage(
    point: *const ParameterPoint,
    source_model: *const model_module.Model,
) CoverageError!void {
    for (source_model.parameters) |parameter| {
        if (point.lookup(parameter.name) == null) return error.MissingParameterValue;
    }
    for (point.entries) |entry| {
        var known = false;
        for (source_model.parameters) |parameter| {
            if (std.mem.eql(u8, parameter.name, entry.name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.UnknownParameterValue;
    }
}

// -- tests -----------------------------------------------------------------

const valid_point =
    \\{"schema":"phaser.parameter-point/0.1",
    \\"units":{"mass":"GeV"},
    \\"renormalization":{"scheme":"MSbar","reference_scale":91.1876},
    \\"values":{"lambda":0.126,"m2":7812.5,"omega":0}}
;

fn testContext() foundation.Context {
    return switch (foundation.Context.init(std.testing.allocator, .{
        .max_diagnostics = 8,
        .max_related_locations = 8,
    })) {
        .context => |context| context,
        .failure => unreachable,
    };
}

fn parseForTest(source: []const u8) !ParseResult {
    return parseParameterPoint(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = source,
    }, .{});
}

fn expectDiagnostic(source: []const u8, code: foundation.Code) !void {
    switch (try parseForTest(source)) {
        .point => |point| {
            var owned = point;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(code, owned.items[0].code);
        },
    }
}

test "a valid parameter point parses" {
    var point = switch (try parseForTest(valid_point)) {
        .point => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer point.deinit();

    try std.testing.expectEqual(MassUnit.gev, point.mass_unit);
    try std.testing.expectEqual(Scheme.msbar, point.scheme);
    try std.testing.expectApproxEqAbs(
        @as(f64, 91.1876),
        point.reference_scale,
        1e-12,
    );
    try std.testing.expectEqual(@as(usize, 3), point.entries.len);
    // Entries are sorted by name.
    try std.testing.expectEqualStrings("lambda", point.entries[0].name);
    try std.testing.expectEqualStrings("m2", point.entries[1].name);
    try std.testing.expectEqualStrings("omega", point.entries[2].name);
    try std.testing.expectEqual(@as(f64, 0), point.lookup("omega").?);
}

test "integer, decimal, and scientific spellings are all accepted" {
    const source =
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},
        \\"values":{"a":1,"b":0.125,"c":1.25e-3,"d":-2.5E2}}
    ;
    var point = switch (try parseForTest(source)) {
        .point => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer point.deinit();

    try std.testing.expectEqual(@as(f64, 1), point.lookup("a").?);
    try std.testing.expectEqual(@as(f64, 0.125), point.lookup("b").?);
    try std.testing.expectEqual(@as(f64, 1.25e-3), point.lookup("c").?);
    try std.testing.expectEqual(@as(f64, -250), point.lookup("d").?);
}

test "negative zero normalizes to zero" {
    const source =
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},
        \\"values":{"a":-0.0}}
    ;
    var point = switch (try parseForTest(source)) {
        .point => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer point.deinit();

    const stored = point.lookup("a").?;
    try std.testing.expectEqual(@as(f64, 0), stored);
    try std.testing.expect(!std.math.signbit(stored));
}

test "non-finite and unrepresentable numbers are rejected" {
    // JSON has no nan or inf spelling; a bare token is not a number.
    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},
        \\"values":{"a":1e400}}
    , .number_not_representable);

    // A nonzero value that would underflow to zero loses its magnitude.
    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},
        \\"values":{"a":1e-400}}
    , .number_not_representable);
}

test "a nonpositive or non-finite reference scale is rejected" {
    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":0},
        \\"values":{"a":1}}
    , .invalid_scale);

    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":-5},
        \\"values":{"a":1}}
    , .invalid_scale);
}

test "each unsupported or malformed field reports its own diagnostic" {
    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.2","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},"values":{}}
    , .invalid_parameter_point_schema);

    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"TeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},"values":{}}
    , .unsupported_mass_unit);

    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"OnShell","reference_scale":100},"values":{}}
    , .unsupported_scheme);

    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},"values":{},
        \\"extra":1}
    , .unknown_property);

    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar"},"values":{}}
    , .missing_property);

    // A value must be a number, not an expression string.
    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","units":{"mass":"GeV"},
        \\"renormalization":{"scheme":"MSbar","reference_scale":100},
        \\"values":{"a":"1/2"}}
    , .invalid_property_type);
}

test "duplicate JSON members are rejected rather than resolved" {
    try expectDiagnostic(
        \\{"schema":"phaser.parameter-point/0.1","schema":"phaser.parameter-point/0.1"}
    , .duplicate_property);
}

test "significant digit and exponent bounds are enforced" {
    const long = "0." ++ ("1" ** 64);
    var buffer: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(
        &buffer,
        \\{{"schema":"phaser.parameter-point/0.1","units":{{"mass":"GeV"}},
        \\"renormalization":{{"scheme":"MSbar","reference_scale":100}},
        \\"values":{{"a":{s}}}}}
    ,
        .{long},
    );
    try expectDiagnostic(source, .capacity_exceeded);
}

test "JSON token and nesting limits are enforced" {
    var token_limits = PointLimits{};
    token_limits.json_tokens = 1;
    const tokens = try parseParameterPoint(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = valid_point,
    }, .{ .limits = token_limits });
    var token_diagnostics = switch (tokens) {
        .diagnostics => |value| value,
        .point => |value| {
            var owned = value;
            defer owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer token_diagnostics.deinit();
    try std.testing.expectEqual(
        foundation.Code.capacity_exceeded,
        token_diagnostics.items[0].code,
    );

    var nesting_limits = PointLimits{};
    nesting_limits.json_nesting = 1;
    const nesting = try parseParameterPoint(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = valid_point,
    }, .{ .limits = nesting_limits });
    var nesting_diagnostics = switch (nesting) {
        .diagnostics => |value| value,
        .point => |value| {
            var owned = value;
            defer owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer nesting_diagnostics.deinit();
    try std.testing.expectEqual(
        foundation.Code.capacity_exceeded,
        nesting_diagnostics.items[0].code,
    );
}

test "every parameter-point limit checks zero exact and one-over boundaries" {
    inline for (@typeInfo(PointLimits).@"struct".fields) |field| {
        var limits = PointLimits{};
        @field(limits, field.name) = 0;
        try std.testing.expectEqual(
            foundation.Code.invalid_limit,
            limits.validate().?.code,
        );

        limits = .{};
        @field(limits, field.name) = @field(PointHardLimits, field.name);
        try std.testing.expectEqual(
            @as(?foundation.Diagnostic, null),
            limits.validate(),
        );

        @field(limits, field.name) = @field(PointHardLimits, field.name) + 1;
        try std.testing.expectEqual(
            foundation.Code.invalid_limit,
            limits.validate().?.code,
        );
    }
}

test "member order does not affect the parsed point" {
    const shuffled =
        \\{"values":{"omega":0,"m2":7812.5,"lambda":0.126},
        \\"renormalization":{"reference_scale":91.1876,"scheme":"MSbar"},
        \\"units":{"mass":"GeV"},"schema":"phaser.parameter-point/0.1"}
    ;
    var ordered = switch (try parseForTest(valid_point)) {
        .point => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer ordered.deinit();
    var reordered = switch (try parseForTest(shuffled)) {
        .point => |value| value,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer reordered.deinit();

    try std.testing.expectEqual(ordered.entries.len, reordered.entries.len);
    for (ordered.entries, reordered.entries) |left, right| {
        try std.testing.expectEqualStrings(left.name, right.name);
        try std.testing.expectEqual(left.value, right.value);
    }
}

test "representative allocation failures never publish a partial point" {
    for (0..48) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const context = switch (foundation.Context.init(failing.allocator(), .{
            .max_diagnostics = 4,
            .max_related_locations = 4,
        })) {
            .context => |context| context,
            .failure => unreachable,
        };
        const result = parseParameterPoint(context, .{
            .source_id = try foundation.SourceId.fromUsize(0),
            .bytes = valid_point,
        }, .{}) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
            continue;
        };
        switch (result) {
            .point => |point| {
                var owned = point;
                owned.deinit();
            },
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
            },
        }
    }
}
