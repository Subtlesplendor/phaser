//! Bounded deterministic property-test campaign.
//!
//! Runs as an executable rather than through the Zig test runner: the property
//! framework reports progress unconditionally on the standard streams, which
//! `ENGINEERING_STYLE.md` reserves for the build and test runners' coordination
//! protocol.
//!
//! The budget is small enough to run on every change, which is the advantage
//! property tests have over a fuzz campaign.

const std = @import("std");
const harness = @import("harness.zig");
const properties = @import("properties.zig");

pub fn main(init: std.process.Init) !void {
    var arguments = try std.process.Args.Iterator.initAllocator(
        init.minimal.args,
        init.gpa,
    );
    defer arguments.deinit();
    _ = arguments.skip();

    // The extended budget belongs to scheduled runs.
    var budget = harness.standard;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--extended")) {
            budget = harness.extended;
        } else if (std.mem.eql(u8, argument, "--smoke")) {
            // One seed and a handful of runs, for diagnosing the harness itself.
            budget = .{ .runs = 5, .seeds = &.{0x9e3779b97f4a7c15} };
        } else {
            std.debug.print("usage: phaser-property [--extended]\n", .{});
            return error.InvalidArguments;
        }
    }

    std.debug.print(
        "phaser properties: {d} seeds x {d} runs = {d} cases per property\n",
        .{ budget.seeds.len, budget.runs, budget.cases() },
    );
    try properties.runAll(init.gpa, budget);
    std.debug.print("phaser properties: all properties held\n", .{});
}
