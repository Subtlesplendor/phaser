const std = @import("std");

const BigInt = std.math.big.int.Managed;

pub const Rational = struct {
    numerator: []const u8,
    denominator: []const u8,

    pub fn isZero(self: Rational) bool {
        return std.mem.eql(u8, self.numerator, "0");
    }
};

pub const MutableRational = struct {
    numerator: BigInt,
    denominator: BigInt,

    pub fn initInteger(allocator: std.mem.Allocator, digits: []const u8) !MutableRational {
        var numerator = try BigInt.init(allocator);
        errdefer numerator.deinit();
        try numerator.setString(10, digits);
        var denominator = try BigInt.initSet(allocator, 1);
        errdefer denominator.deinit();
        return .{ .numerator = numerator, .denominator = denominator };
    }

    pub fn initOne(allocator: std.mem.Allocator) !MutableRational {
        return initInteger(allocator, "1");
    }

    pub fn clone(self: *const MutableRational) !MutableRational {
        var numerator = try BigInt.clone(self.numerator);
        errdefer numerator.deinit();
        var denominator = try BigInt.clone(self.denominator);
        errdefer denominator.deinit();
        return .{ .numerator = numerator, .denominator = denominator };
    }

    pub fn deinit(self: *MutableRational) void {
        self.numerator.deinit();
        self.denominator.deinit();
        self.* = undefined;
    }

    pub fn isZero(self: *const MutableRational) bool {
        return self.numerator.eqlZero();
    }

    pub fn isPositive(self: *const MutableRational) bool {
        return !self.numerator.eqlZero() and self.numerator.isPositive();
    }

    pub fn negate(self: *MutableRational) void {
        if (!self.numerator.eqlZero()) self.numerator.negate();
    }

    pub fn bitCount(self: *const MutableRational) usize {
        return @max(
            self.numerator.bitCountAbs(),
            self.denominator.bitCountAbs(),
        );
    }

    pub fn add(
        allocator: std.mem.Allocator,
        lhs: *const MutableRational,
        rhs: *const MutableRational,
    ) !MutableRational {
        var left = try BigInt.init(allocator);
        defer left.deinit();
        try left.mul(&lhs.numerator, &rhs.denominator);

        var right = try BigInt.init(allocator);
        defer right.deinit();
        try right.mul(&rhs.numerator, &lhs.denominator);

        var numerator = try BigInt.init(allocator);
        errdefer numerator.deinit();
        try numerator.add(&left, &right);

        var denominator = try BigInt.init(allocator);
        errdefer denominator.deinit();
        try denominator.mul(&lhs.denominator, &rhs.denominator);

        var result = MutableRational{
            .numerator = numerator,
            .denominator = denominator,
        };
        try result.reduce(allocator);
        return result;
    }

    pub fn subtract(
        allocator: std.mem.Allocator,
        lhs: *const MutableRational,
        rhs: *const MutableRational,
    ) !MutableRational {
        var negated = try rhs.clone();
        defer negated.deinit();
        negated.negate();
        return add(allocator, lhs, &negated);
    }

    pub fn multiply(
        allocator: std.mem.Allocator,
        lhs: *const MutableRational,
        rhs: *const MutableRational,
    ) !MutableRational {
        var numerator = try BigInt.init(allocator);
        errdefer numerator.deinit();
        try numerator.mul(&lhs.numerator, &rhs.numerator);

        var denominator = try BigInt.init(allocator);
        errdefer denominator.deinit();
        try denominator.mul(&lhs.denominator, &rhs.denominator);

        var result = MutableRational{
            .numerator = numerator,
            .denominator = denominator,
        };
        try result.reduce(allocator);
        return result;
    }

    pub fn divide(
        allocator: std.mem.Allocator,
        lhs: *const MutableRational,
        rhs: *const MutableRational,
    ) !MutableRational {
        if (rhs.isZero()) return error.DivisionByZero;

        var numerator = try BigInt.init(allocator);
        errdefer numerator.deinit();
        try numerator.mul(&lhs.numerator, &rhs.denominator);

        var denominator = try BigInt.init(allocator);
        errdefer denominator.deinit();
        try denominator.mul(&lhs.denominator, &rhs.numerator);
        if (!denominator.isPositive()) {
            denominator.negate();
            numerator.negate();
        }

        var result = MutableRational{
            .numerator = numerator,
            .denominator = denominator,
        };
        try result.reduce(allocator);
        return result;
    }

    pub fn power(
        allocator: std.mem.Allocator,
        base: *const MutableRational,
        exponent: u32,
    ) !MutableRational {
        var numerator = try BigInt.init(allocator);
        errdefer numerator.deinit();
        try numerator.pow(&base.numerator, exponent);

        var denominator = try BigInt.init(allocator);
        errdefer denominator.deinit();
        try denominator.pow(&base.denominator, exponent);
        return .{ .numerator = numerator, .denominator = denominator };
    }

    pub fn perfectSquareRoot(
        self: *const MutableRational,
        allocator: std.mem.Allocator,
    ) !?MutableRational {
        if (!self.isPositive()) return null;

        var numerator_root = try BigInt.init(allocator);
        errdefer numerator_root.deinit();
        try numerator_root.sqrt(&self.numerator);
        var numerator_square = try BigInt.init(allocator);
        defer numerator_square.deinit();
        try numerator_square.sqr(&numerator_root);
        if (!BigInt.eql(numerator_square, self.numerator)) {
            numerator_root.deinit();
            return null;
        }

        var denominator_root = try BigInt.init(allocator);
        errdefer denominator_root.deinit();
        try denominator_root.sqrt(&self.denominator);
        var denominator_square = try BigInt.init(allocator);
        defer denominator_square.deinit();
        try denominator_square.sqr(&denominator_root);
        if (!BigInt.eql(denominator_square, self.denominator)) {
            numerator_root.deinit();
            denominator_root.deinit();
            return null;
        }

        return .{
            .numerator = numerator_root,
            .denominator = denominator_root,
        };
    }

    pub fn publish(
        self: *const MutableRational,
        allocator: std.mem.Allocator,
    ) !Rational {
        // Both parts are separate allocations, so the first has to be released
        // when the second fails. Publishing is otherwise not atomic and leaks
        // the numerator under allocation failure.
        const numerator = try self.numerator.toString(allocator, 10, .lower);
        errdefer allocator.free(numerator);
        const denominator = try self.denominator.toString(allocator, 10, .lower);
        return .{ .numerator = numerator, .denominator = denominator };
    }

    fn reduce(self: *MutableRational, allocator: std.mem.Allocator) !void {
        if (self.numerator.eqlZero()) {
            try self.denominator.set(1);
            return;
        }

        var absolute = try BigInt.clone(self.numerator);
        defer absolute.deinit();
        absolute.abs();

        var divisor = try BigInt.init(allocator);
        defer divisor.deinit();
        try divisor.gcd(&absolute, &self.denominator);

        var quotient = try BigInt.init(allocator);
        defer quotient.deinit();
        var remainder = try BigInt.init(allocator);
        defer remainder.deinit();

        try quotient.divTrunc(&remainder, &self.numerator, &divisor);
        try self.numerator.copy(quotient.toConst());
        try quotient.divTrunc(&remainder, &self.denominator, &divisor);
        try self.denominator.copy(quotient.toConst());
    }
};

test "isPositive is false at zero and only true for a positive numerator" {
    // A big integer's own `isPositive` reads its sign bit, which zero carries
    // as positive by convention. `MutableRational.isPositive` must gate that
    // with its own zero check rather than relying on `eqlZero` alone.
    var zero = try MutableRational.initInteger(std.testing.allocator, "0");
    defer zero.deinit();
    try std.testing.expect(!zero.isPositive());

    var negative = try MutableRational.initInteger(std.testing.allocator, "-5");
    defer negative.deinit();
    try std.testing.expect(!negative.isPositive());

    var positive = try MutableRational.initInteger(std.testing.allocator, "5");
    defer positive.deinit();
    try std.testing.expect(positive.isPositive());
}

test "arbitrary precision rationals reduce exactly" {
    const allocator = std.testing.allocator;
    var lhs = try MutableRational.initInteger(
        allocator,
        "123456789012345678901234567890",
    );
    defer lhs.deinit();
    var rhs = try MutableRational.initInteger(allocator, "3");
    defer rhs.deinit();
    var quotient = try MutableRational.divide(allocator, &lhs, &rhs);
    defer quotient.deinit();
    const published = try quotient.publish(allocator);
    defer allocator.free(published.numerator);
    defer allocator.free(published.denominator);

    try std.testing.expectEqualStrings(
        "41152263004115226300411522630",
        published.numerator,
    );
    try std.testing.expectEqualStrings("1", published.denominator);
}
