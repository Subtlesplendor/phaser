//! Effective-potential calculation requests.
//!
//! Parses, validates, and normalizes the source request specified in
//! `docs/formats/EFFECTIVE_POTENTIAL_REQUEST.md`, and fingerprints the
//! normalized form so that a planned calculation is identified by the pair of
//! model fingerprint and request fingerprint.
//!
//! A request describes structure only. Numerical parameter values, scales, and
//! background points are dynamic and never appear here.

const std = @import("std");
const foundation = @import("../foundation/root.zig");
const limits_module = @import("limits.zig");

pub const CalculationLimits = limits_module.CalculationLimits;

/// Highest loop order Phaser derives.
///
/// Milestone 3 adds the zero-temperature scalar one-loop contribution, so a
/// request may truncate at order one. Higher orders remain explicit failures.
pub const supported_loop_order: u32 = 1;

pub const BackgroundMode = enum { full_scalar_space, component_slice };

pub const EnvironmentKind = enum { vacuum };

pub const Scheme = enum { msbar };

pub const CoordinateRequest = struct {
    id: []const u8,
    scalar: []const u8,
};

pub const Request = struct {
    arena: *std.heap.ArenaAllocator,
    background_mode: BackgroundMode,
    coordinates: []const CoordinateRequest,
    environment: EnvironmentKind,
    loop_order: u32,
    /// Present only when the source declared it. At loop order zero the tree
    /// potential carries no scheme dependence, so the declaration is optional
    /// and excluded from the normalized encoding.
    scheme: ?Scheme,

    pub fn deinit(self: *Request) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// True when the scheme affects the derived value and must therefore agree
    /// with the scheme of any bound parameter point.
    pub fn schemeIsLoadBearing(self: *const Request) bool {
        return self.loop_order >= 1;
    }

    /// Deterministic encoding of everything that can affect the derivation.
    ///
    /// An inert scheme declaration at loop order zero is omitted, so the two
    /// spellings of a tree request share one identity.
    pub fn writeCanonical(
        self: *const Request,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("calculation-request-canonical/1\x00");
        try writer.writeAll("phaser.calculation/0.1\x00effective_potential\x00");
        try writer.print("background:{s};", .{@tagName(self.background_mode)});
        for (self.coordinates) |coordinate| {
            try writer.print(
                "c:{d}:{s}:{d}:{s};",
                .{
                    coordinate.id.len,
                    coordinate.id,
                    coordinate.scalar.len,
                    coordinate.scalar,
                },
            );
        }
        try writer.print("environment:{s};", .{@tagName(self.environment)});
        try writer.print("loop_through:{d};", .{self.loop_order});
        if (self.schemeIsLoadBearing()) {
            try writer.print("scheme:{s};", .{@tagName(self.scheme.?)});
        }
    }

    pub fn fingerprint(
        self: *const Request,
        allocator: std.mem.Allocator,
    ) error{ OutOfMemory, WriteFailed }!Fingerprint {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try self.writeCanonical(&output.writer);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(output.written(), &digest, .{});
        return .{ .bytes = digest };
    }
};

pub const Fingerprint = struct {
    bytes: [32]u8,

    pub fn format(self: Fingerprint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.bytes) |byte| try writer.print("{x:0>2}", .{byte});
    }
};

pub const RequestSource = struct {
    source_id: foundation.SourceId,
    bytes: []const u8,
};

pub const ParseOptions = struct {
    limits: CalculationLimits = .{},
};

pub const ParseResult = union(enum) {
    request: Request,
    diagnostics: foundation.Diagnostics,
};

pub const ParseError = error{
    OutOfMemory,
    DiagnosticCapacityExceeded,
    RelatedLocationCapacityExceeded,
};

const Failure = error{
    InvalidCalculationSchema,
    UnsupportedCalculationKind,
    UnsupportedEnvironment,
    UnsupportedGaugeFixing,
    UnsupportedLoopOrder,
    UnsupportedScheme,
    InvalidBackgroundMode,
    InvalidBackgroundCoordinate,
    DuplicateBackgroundCoordinate,
    MissingProperty,
    UnknownProperty,
    InvalidPropertyType,
    InvalidIdentifier,
    CapacityExceeded,
};

fn failureInfo(failure: Failure) struct {
    code: foundation.Code,
    category: foundation.Category,
} {
    return switch (failure) {
        error.InvalidCalculationSchema => .{
            .code = .invalid_calculation_schema,
            .category = .calculation,
        },
        error.UnsupportedCalculationKind => .{
            .code = .unsupported_calculation_kind,
            .category = .calculation,
        },
        error.UnsupportedEnvironment => .{
            .code = .unsupported_environment,
            .category = .calculation,
        },
        error.UnsupportedGaugeFixing => .{
            .code = .unsupported_gauge_fixing,
            .category = .calculation,
        },
        error.UnsupportedLoopOrder => .{
            .code = .unsupported_loop_order,
            .category = .calculation,
        },
        error.UnsupportedScheme => .{
            .code = .unsupported_scheme,
            .category = .calculation,
        },
        error.InvalidBackgroundMode => .{
            .code = .invalid_background_mode,
            .category = .calculation,
        },
        error.InvalidBackgroundCoordinate => .{
            .code = .invalid_background_coordinate,
            .category = .calculation,
        },
        error.DuplicateBackgroundCoordinate => .{
            .code = .duplicate_background_coordinate,
            .category = .calculation,
        },
        error.MissingProperty => .{ .code = .missing_property, .category = .json },
        error.UnknownProperty => .{ .code = .unknown_property, .category = .json },
        error.InvalidPropertyType => .{ .code = .invalid_property_type, .category = .json },
        error.InvalidIdentifier => .{ .code = .invalid_identifier, .category = .calculation },
        error.CapacityExceeded => .{ .code = .capacity_exceeded, .category = .calculation },
    };
}

pub fn parseRequest(
    context: foundation.Context,
    source: RequestSource,
    options: ParseOptions,
) ParseError!ParseResult {
    if (options.limits.validate()) |diagnostic| {
        return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
    }
    if (source.bytes.len > options.limits.request_bytes) {
        return .{ .diagnostics = try capacityDiagnostics(
            context,
            source,
            .request_bytes,
            options.limits.request_bytes,
            source.bytes.len,
        ) };
    }
    if (try scanJson(context.allocator, source, options.limits)) |diagnostic| {
        return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        context.allocator,
        source.bytes,
        .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
            .max_value_len = options.limits.request_bytes,
            .allocate = .alloc_always,
        },
    ) catch |err| {
        return .{ .diagnostics = try simpleDiagnostics(
            context,
            source,
            if (err == error.DuplicateField) .duplicate_property else .invalid_json,
            .json,
        ) };
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .diagnostics = try simpleDiagnostics(
            context,
            source,
            .invalid_property_type,
            .json,
        ) },
    };

    const arena = try context.allocator.create(std.heap.ArenaAllocator);
    errdefer context.allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(context.allocator);
    errdefer arena.deinit();

    // Set by a failure that can say more than its code does.
    var detail: foundation.Detail = .none;
    const built = build(root, options, arena.allocator(), &detail) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            arena.deinit();
            context.allocator.destroy(arena);
            const info = failureInfo(@errorCast(err));
            var diagnostic = diagnosticAt(source, info.code, info.category, 0);
            diagnostic.detail = detail;
            return .{ .diagnostics = try oneDiagnostic(context, diagnostic) };
        },
    };

    return .{ .request = .{
        .arena = arena,
        .background_mode = built.background_mode,
        .coordinates = built.coordinates,
        .environment = built.environment,
        .loop_order = built.loop_order,
        .scheme = built.scheme,
    } };
}

const Built = struct {
    background_mode: BackgroundMode,
    coordinates: []const CoordinateRequest,
    environment: EnvironmentKind,
    loop_order: u32,
    scheme: ?Scheme,
};

fn build(
    root: std.json.ObjectMap,
    options: ParseOptions,
    allocator: std.mem.Allocator,
    detail: *foundation.Detail,
) !Built {
    try rejectUnknown(root, &.{
        "schema",
        "kind",
        "background",
        "environment",
        "orders",
        "renormalization",
        "gauge_fixing",
    });

    if (!std.mem.eql(u8, try requiredString(root, "schema"), "phaser.calculation/0.1")) {
        return error.InvalidCalculationSchema;
    }
    if (!std.mem.eql(u8, try requiredString(root, "kind"), "effective_potential")) {
        return error.UnsupportedCalculationKind;
    }

    // Gauge fixing is reserved for the milestone that introduces the general
    // gauge family. Presence is rejected rather than silently ignored.
    if (root.get("gauge_fixing") != null) return error.UnsupportedGaugeFixing;

    const loop_order = try parseOrders(root, detail);
    const environment = try parseEnvironment(root);
    const scheme = try parseRenormalization(root, loop_order);
    const background = try parseBackground(root, options, allocator);

    return .{
        .background_mode = background.mode,
        .coordinates = background.coordinates,
        .environment = environment,
        .loop_order = loop_order,
        .scheme = scheme,
    };
}

fn parseOrders(root: std.json.ObjectMap, detail: *foundation.Detail) !u32 {
    const orders = try requiredObject(root, "orders");
    try rejectUnknown(orders, &.{"loop"});
    const loop = try requiredObject(orders, "loop");
    try rejectUnknown(loop, &.{"through"});
    const through = try requiredInteger(u32, loop, "through");
    if (through > supported_loop_order) {
        // The diagnostic names the highest supported order, so a caller does
        // not have to consult the specification to learn what to ask for.
        detail.* = .{ .capacity = .{
            .resource = .loop_order,
            .limit = supported_loop_order,
            .current = 0,
            .requested = through,
        } };
        return error.UnsupportedLoopOrder;
    }
    return through;
}

fn parseEnvironment(root: std.json.ObjectMap) !EnvironmentKind {
    const environment = try requiredObject(root, "environment");
    try rejectUnknown(environment, &.{"kind"});
    const kind = try requiredString(environment, "kind");
    if (!std.mem.eql(u8, kind, "vacuum")) return error.UnsupportedEnvironment;
    return .vacuum;
}

fn parseRenormalization(root: std.json.ObjectMap, loop_order: u32) !?Scheme {
    const value = root.get("renormalization") orelse {
        // Required exactly when the calculation depends on the choice.
        if (loop_order >= 1) return error.MissingProperty;
        return null;
    };
    const object = switch (value) {
        .object => |map| map,
        else => return error.InvalidPropertyType,
    };
    try rejectUnknown(object, &.{"scheme"});
    const scheme = try requiredString(object, "scheme");
    // `MSbar` is the only scheme the scalar one-loop formula version is
    // defined in. Another declared scheme is unsupported, not an unsupported
    // calculation kind.
    if (!std.mem.eql(u8, scheme, "MSbar")) return error.UnsupportedScheme;
    return .msbar;
}

const ParsedBackground = struct {
    mode: BackgroundMode,
    coordinates: []const CoordinateRequest,
};

fn parseBackground(
    root: std.json.ObjectMap,
    options: ParseOptions,
    allocator: std.mem.Allocator,
) !ParsedBackground {
    const background = try requiredObject(root, "background");
    const mode_text = try requiredString(background, "mode");

    if (std.mem.eql(u8, mode_text, "full_scalar_space")) {
        try rejectUnknown(background, &.{"mode"});
        return .{ .mode = .full_scalar_space, .coordinates = &.{} };
    }
    if (!std.mem.eql(u8, mode_text, "component_slice")) {
        return error.InvalidBackgroundMode;
    }

    try rejectUnknown(background, &.{ "mode", "coordinates" });
    const raw = try requiredArray(background, "coordinates");
    if (raw.len == 0) return error.InvalidBackgroundCoordinate;
    if (raw.len > options.limits.background_coordinates) return error.CapacityExceeded;

    const coordinates = try allocator.alloc(CoordinateRequest, raw.len);
    for (raw, coordinates, 0..) |item, *coordinate, index| {
        const declaration = switch (item) {
            .object => |map| map,
            else => return error.InvalidPropertyType,
        };
        try rejectUnknown(
            declaration,
            &.{ "id", "scalar", "label", "latex", "description" },
        );
        const id = try requiredString(declaration, "id");
        if (!validIdentifier(id)) return error.InvalidIdentifier;
        const scalar = try requiredString(declaration, "scalar");

        for (coordinates[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, id)) {
                return error.DuplicateBackgroundCoordinate;
            }
            if (std.mem.eql(u8, previous.scalar, scalar)) {
                return error.DuplicateBackgroundCoordinate;
            }
        }
        coordinate.* = .{
            .id = try allocator.dupe(u8, id),
            .scalar = try allocator.dupe(u8, scalar),
        };
    }
    return .{ .mode = .component_slice, .coordinates = coordinates };
}

fn scanJson(
    allocator: std.mem.Allocator,
    source: RequestSource,
    limits: CalculationLimits,
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
            limits.request_bytes,
        ) catch {
            return diagnosticAt(
                source,
                .invalid_json,
                .json,
                @intCast(@min(diagnostics.getByteOffset(), source.bytes.len)),
            );
        };
        defer switch (token) {
            .allocated_string => |slice| allocator.free(slice),
            .allocated_number => |slice| allocator.free(slice),
            else => {},
        };
        token_count += 1;
        if (token_count > limits.request_json_tokens) {
            return diagnosticAt(source, .capacity_exceeded, .json, scanner.cursor);
        }
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.request_json_nesting) {
                    return diagnosticAt(source, .capacity_exceeded, .json, scanner.cursor);
                }
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => break,
            else => {},
        }
    }
    return null;
}

// -- JSON helpers ----------------------------------------------------------

fn requiredObject(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .object => |map| map,
        else => error.InvalidPropertyType,
    };
}

fn requiredArray(object: std.json.ObjectMap, key: []const u8) ![]const std.json.Value {
    const value = object.get(key) orelse return error.MissingProperty;
    return switch (value) {
        .array => |array| array.items,
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

fn requiredInteger(comptime T: type, object: std.json.ObjectMap, key: []const u8) !T {
    const value = object.get(key) orelse return error.MissingProperty;
    const number = switch (value) {
        .number_string => |string| string,
        else => return error.InvalidPropertyType,
    };
    return std.fmt.parseInt(T, number, 10) catch error.InvalidPropertyType;
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

fn validIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    if (!(std.ascii.isAlphabetic(identifier[0]) or identifier[0] == '_')) return false;
    for (identifier[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

// -- diagnostics -----------------------------------------------------------

fn diagnosticAt(
    source: RequestSource,
    code: foundation.Code,
    category: foundation.Category,
    offset: usize,
) foundation.Diagnostic {
    return .{
        .code = code,
        .category = category,
        .primary = foundation.SourceSpan.init(
            source.source_id,
            source.bytes.len,
            @min(offset, source.bytes.len),
            @min(offset + @intFromBool(offset < source.bytes.len), source.bytes.len),
        ) catch unreachable,
    };
}

fn simpleDiagnostics(
    context: foundation.Context,
    source: RequestSource,
    code: foundation.Code,
    category: foundation.Category,
) ParseError!foundation.Diagnostics {
    return oneDiagnostic(context, diagnosticAt(source, code, category, 0));
}

fn capacityDiagnostics(
    context: foundation.Context,
    source: RequestSource,
    resource: foundation.Resource,
    limit: usize,
    requested: usize,
) ParseError!foundation.Diagnostics {
    var diagnostic = diagnosticAt(source, .capacity_exceeded, .calculation, 0);
    diagnostic.detail = .{ .capacity = .{
        .resource = resource,
        .limit = limit,
        .current = 0,
        .requested = requested,
    } };
    return oneDiagnostic(context, diagnostic);
}

fn oneDiagnostic(
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

// -- tests -----------------------------------------------------------------

const full_space_request =
    \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
    \\"background":{"mode":"full_scalar_space"},
    \\"environment":{"kind":"vacuum"},
    \\"orders":{"loop":{"through":0}}}
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
    return parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = source,
    }, .{});
}

/// The rejection names the highest supported order, so a caller learns what to
/// ask for without consulting the specification.
fn expectLoopOrderDetail(source: []const u8) !void {
    const result = try parseForTest(source);
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            const detail = owned.items[0].detail.capacity;
            try std.testing.expectEqual(foundation.Resource.loop_order, detail.resource);
            try std.testing.expectEqual(@as(usize, supported_loop_order), detail.limit);
            try std.testing.expectEqual(@as(usize, 2), detail.requested);
        },
    }
}

fn expectDiagnostic(source: []const u8, code: foundation.Code) !void {
    const result = try parseForTest(source);
    switch (result) {
        .request => |request| {
            var owned = request;
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

test "a minimal full-space request parses" {
    const result = try parseForTest(full_space_request);
    var request = switch (result) {
        .request => |request| request,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer request.deinit();

    try std.testing.expectEqual(BackgroundMode.full_scalar_space, request.background_mode);
    try std.testing.expectEqual(EnvironmentKind.vacuum, request.environment);
    try std.testing.expectEqual(@as(u32, 0), request.loop_order);
    try std.testing.expectEqual(@as(?Scheme, null), request.scheme);
    try std.testing.expect(!request.schemeIsLoadBearing());
}

test "a component slice preserves declared coordinate order" {
    const source =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"b","scalar":"s"},{"id":"a","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}}}
    ;
    const result = try parseForTest(source);
    var request = switch (result) {
        .request => |request| request,
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 2), request.coordinates.len);
    try std.testing.expectEqualStrings("b", request.coordinates[0].id);
    try std.testing.expectEqualStrings("s", request.coordinates[0].scalar);
    try std.testing.expectEqualStrings("a", request.coordinates[1].id);
}

test "an inert scheme declaration does not change tree identity" {
    const with_scheme =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":0}}}
    ;
    var bare = switch (try parseForTest(full_space_request)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer bare.deinit();
    var declared = switch (try parseForTest(with_scheme)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer declared.deinit();

    // The declaration is retained for provenance.
    try std.testing.expectEqual(@as(?Scheme, null), bare.scheme);
    try std.testing.expectEqual(Scheme.msbar, declared.scheme.?);

    // It cannot affect a tree derivation, so both share one identity.
    const bare_fingerprint = try bare.fingerprint(std.testing.allocator);
    const declared_fingerprint = try declared.fingerprint(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &bare_fingerprint.bytes,
        &declared_fingerprint.bytes,
    );
}

test "coordinate order changes calculation identity" {
    const first =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h"},{"id":"b","scalar":"s"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    const second =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"b","scalar":"s"},{"id":"a","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    var left = switch (try parseForTest(first)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer left.deinit();
    var right = switch (try parseForTest(second)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer right.deinit();

    const left_fingerprint = try left.fingerprint(std.testing.allocator);
    const right_fingerprint = try right.fingerprint(std.testing.allocator);
    try std.testing.expect(
        !std.mem.eql(u8, &left_fingerprint.bytes, &right_fingerprint.bytes),
    );
}

test "presentation metadata does not change calculation identity" {
    const plain =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    const decorated =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h","label":"higgs","latex":"h",
        \\"description":"non-semantic"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    var left = switch (try parseForTest(plain)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer left.deinit();
    var right = switch (try parseForTest(decorated)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer right.deinit();

    const left_fingerprint = try left.fingerprint(std.testing.allocator);
    const right_fingerprint = try right.fingerprint(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &left_fingerprint.bytes,
        &right_fingerprint.bytes,
    );
}

test "json nesting past the request's own limit is rejected" {
    // Default `request_json_nesting` is 16; this is not a valid request
    // either way, but only the real scan step returns `capacity_exceeded` for
    // it specifically. A scan that never counted depth at all would fall
    // through to ordinary schema validation and report a different code
    // instead, for a document a schema check never reaches structurally.
    const deeply_nested = "[" ** 17 ++ "]" ** 17;
    try expectDiagnostic(deeply_nested, .capacity_exceeded);
}

test "json token count past the request's own limit is rejected" {
    // Default `request_json_tokens` is 4096; a flat array keeps nesting at 1
    // so only the token count trips, isolating it from the nesting check
    // above.
    const source = "[" ++ "0," ** 4100 ++ "0]";
    try expectDiagnostic(source, .capacity_exceeded);
}

test "a source at exactly the byte limit is not rejected for its size" {
    // The two tests above only exercise the limit from past it, which cannot
    // distinguish `>` from `>=` at the boundary. A source of exactly the
    // configured length must still reach ordinary parsing.
    var limits = CalculationLimits{};
    limits.request_bytes = full_space_request.len;
    var result = try parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = full_space_request,
    }, .{ .limits = limits });
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    }

    limits.request_bytes = full_space_request.len - 1;
    result = try parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = full_space_request,
    }, .{ .limits = limits });
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.capacity_exceeded,
                owned.items[0].code,
            );
        },
    }
}

test "a background coordinate count at exactly the limit is not rejected" {
    var limits = CalculationLimits{};
    limits.background_coordinates = 1;
    const source =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    var result = try parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = source,
    }, .{ .limits = limits });
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
    }

    const two_coordinates =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h"},{"id":"b","scalar":"s"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    ;
    result = try parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = two_coordinates,
    }, .{ .limits = limits });
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.capacity_exceeded,
                owned.items[0].code,
            );
        },
    }
}

test "the json token count at exactly a configured limit does not read as exceeded" {
    // `end_of_document` is itself counted, so a two-element flat array is
    // exactly five tokens: array_begin, two numbers, array_end,
    // end_of_document. A limit of five must let the scan finish and reach
    // ordinary schema validation instead of reporting capacity first.
    var limits = CalculationLimits{};
    limits.request_json_tokens = 5;
    const result = try parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = "[0,0]",
    }, .{ .limits = limits });
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.invalid_property_type,
                owned.items[0].code,
            );
        },
    }
}

test "json nesting at exactly a configured limit does not read as exceeded" {
    // An empty array reaches depth 1 and back to 0, so a nesting limit of 1
    // must let the scan finish rather than reject the depth itself.
    var limits = CalculationLimits{};
    limits.request_json_nesting = 1;
    const result = try parseRequest(testContext(), .{
        .source_id = try foundation.SourceId.fromUsize(0),
        .bytes = "[]",
    }, .{ .limits = limits });
    switch (result) {
        .request => |request| {
            var owned = request;
            owned.deinit();
            return error.TestUnexpectedResult;
        },
        .diagnostics => |diagnostics| {
            var owned = diagnostics;
            defer owned.deinit();
            try std.testing.expectEqual(
                foundation.Code.invalid_property_type,
                owned.items[0].code,
            );
        },
    }
}

test "identifier validation accepts underscore-led names and rejects invalid bytes" {
    try std.testing.expect(!validIdentifier(""));
    try std.testing.expect(validIdentifier("_"));
    try std.testing.expect(validIdentifier("phi"));
    try std.testing.expect(validIdentifier("_phi2"));
    try std.testing.expect(validIdentifier("phi_2"));
    // A leading digit is not itself alphabetic or an underscore.
    try std.testing.expect(!validIdentifier("2phi"));
    // A byte inside the identifier that is neither alphanumeric nor an
    // underscore, distinct from the leading-byte check above.
    try std.testing.expect(!validIdentifier("phi-2"));
}

test "each unsupported combination reports its own diagnostic" {
    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.2","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}}}
    , .invalid_calculation_schema);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"rg_functions",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}}}
    , .unsupported_calculation_kind);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"finite_temperature"},
        \\"orders":{"loop":{"through":0}}}
    , .unsupported_environment);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"gauge_fixing":{"family":"landau"},
        \\"orders":{"loop":{"through":0}}}
    , .unsupported_gauge_fixing);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":2}}}
    , .unsupported_loop_order);
    try expectLoopOrderDetail(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":2}}}
    );

    // At order one the scheme is load bearing, so it must be declared and must
    // be the one the formula version is defined in.
    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":1}}}
    , .missing_property);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"on_shell"},
        \\"orders":{"loop":{"through":1}}}
    , .unsupported_scheme);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"radial"},"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}}}
    , .invalid_background_mode);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h"},{"id":"a","scalar":"s"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    , .duplicate_background_coordinate);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"a","scalar":"h"},{"id":"b","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    , .duplicate_background_coordinate);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[
        \\{"id":"1bad","scalar":"h"}]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    , .invalid_identifier);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"component_slice","coordinates":[]},
        \\"environment":{"kind":"vacuum"},"orders":{"loop":{"through":0}}}
    , .invalid_background_coordinate);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}},"unexpected":1}
    , .unknown_property);

    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"}}
    , .missing_property);
}

test "duplicate members are rejected rather than resolved" {
    try expectDiagnostic(
        \\{"schema":"phaser.calculation/0.1","schema":"phaser.calculation/0.1"}
    , .duplicate_property);
}

test "normalization is independent of member order" {
    const ordered =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},"environment":{"kind":"vacuum"},
        \\"orders":{"loop":{"through":0}}}
    ;
    const shuffled =
        \\{"orders":{"loop":{"through":0}},"environment":{"kind":"vacuum"},
        \\"background":{"mode":"full_scalar_space"},
        \\"kind":"effective_potential","schema":"phaser.calculation/0.1"}
    ;
    var left = switch (try parseForTest(ordered)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer left.deinit();
    var right = switch (try parseForTest(shuffled)) {
        .request => |request| request,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer right.deinit();

    const left_fingerprint = try left.fingerprint(std.testing.allocator);
    const right_fingerprint = try right.fingerprint(std.testing.allocator);
    try std.testing.expectEqualSlices(
        u8,
        &left_fingerprint.bytes,
        &right_fingerprint.bytes,
    );
}

test "representative allocation failures never publish a partial request" {
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
        const result = parseRequest(context, .{
            .source_id = try foundation.SourceId.fromUsize(0),
            .bytes = full_space_request,
        }, .{}) catch |err| {
            try std.testing.expect(err == error.OutOfMemory);
            continue;
        };
        switch (result) {
            .request => |request| {
                var owned = request;
                owned.deinit();
            },
            .diagnostics => |diagnostics| {
                var owned = diagnostics;
                owned.deinit();
            },
        }
    }
}

test "an order-one request records the scheme in its identity" {
    const source =
        \\{"schema":"phaser.calculation/0.1","kind":"effective_potential",
        \\"background":{"mode":"full_scalar_space"},
        \\"environment":{"kind":"vacuum"},
        \\"renormalization":{"scheme":"MSbar"},
        \\"orders":{"loop":{"through":1}}}
    ;
    var request = switch (try parseForTest(source)) {
        .request => |parsed| parsed,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer request.deinit();

    try std.testing.expectEqual(@as(u32, 1), request.loop_order);
    try std.testing.expectEqual(Scheme.msbar, request.scheme.?);
    try std.testing.expect(request.schemeIsLoadBearing());

    // The scheme is load bearing at order one, so the encoding carries it and
    // the identity differs from the tree request over the same background.
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try request.writeCanonical(&encoded.writer);
    try std.testing.expect(
        std.mem.indexOf(u8, encoded.written(), "scheme:msbar;") != null,
    );

    var tree = switch (try parseForTest(full_space_request)) {
        .request => |parsed| parsed,
        .diagnostics => return error.TestUnexpectedResult,
    };
    defer tree.deinit();
    const loop_fingerprint = try request.fingerprint(std.testing.allocator);
    const tree_fingerprint = try tree.fingerprint(std.testing.allocator);
    try std.testing.expect(
        !std.mem.eql(u8, &loop_fingerprint.bytes, &tree_fingerprint.bytes),
    );
}
