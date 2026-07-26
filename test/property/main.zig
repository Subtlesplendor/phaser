//! Bounded property-test campaign.
//!
//! Runs as an executable rather than through the Zig test runner: the property
//! framework reports progress unconditionally on the standard streams, which
//! `ENGINEERING_STYLE.md` reserves for the build and test runners' coordination
//! protocol.
//!
//! Ordinary runs let Minish choose fresh seeds. A failure reports its seed and
//! can be reproduced explicitly with `--seed`.

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

    // The extended budget belongs to scheduled runs. Argument order does not
    // matter: changing the run count preserves an explicitly requested replay
    // seed.
    var budget = harness.standard;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--extended")) {
            budget.runs = harness.extended.runs;
        } else if (std.mem.eql(u8, argument, "--smoke")) {
            budget.runs = 5;
        } else if (std.mem.eql(u8, argument, "--seed")) {
            const value = arguments.next() orelse {
                printUsage();
                return error.InvalidArguments;
            };
            budget.seed = std.fmt.parseInt(u64, value, 0) catch {
                printUsage();
                return error.InvalidArguments;
            };
        } else {
            printUsage();
            return error.InvalidArguments;
        }
    }

    if (budget.seed) |seed| {
        std.debug.print(
            "phaser properties: replay seed {d}, {d} cases per property\n",
            .{ seed, budget.cases() },
        );
    } else {
        std.debug.print(
            "phaser properties: {d} fresh cases per property; seeds are reported on failure\n",
            .{budget.cases()},
        );
    }
    try properties.runAll(init.gpa, budget);
    std.debug.print("phaser properties: all properties held\n", .{});
}

fn printUsage() void {
    std.debug.print(
        "usage: phaser-property [--extended | --smoke] [--seed SEED]\n",
        .{},
    );
}
