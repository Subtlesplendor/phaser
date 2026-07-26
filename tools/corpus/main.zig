//! Corpus maintenance for the fuzz targets.
//!
//! The toolchain keeps a coverage-guided corpus inside the build cache and, in
//! its own words, accumulates it "across multiple runs when preserving the
//! cache". A hosted runner discards that cache, so growing the permanent corpus
//! is a local activity: run a long campaign, then look at what it found.
//!
//!     zig build fuzz -Doptimize=ReleaseSafe --fuzz=2M
//!     zig build corpus -- list
//!     zig build corpus -- stage
//!
//! `list` reports what the cache holds against what the repository already
//! commits. `stage` copies the inputs that are not committed yet into a
//! scratch directory for review.
//!
//! The tool deliberately does not write into `test/corpus/`.
//! `DEVELOPMENT_WORKFLOW.md` §7 requires that generated corpus growth is not
//! committed automatically: an input becomes permanent when a person judges it
//! worth the replay cost, names it for what it covers, and adds it to the
//! target's `.corpus` list.

const std = @import("std");
const targets = @import("fuzz_targets");

/// Largest corpus input the tool will read. Generated inputs are bounded by the
/// per-target limits and are far smaller; the bound only keeps a corrupt or
/// unrelated file in the cache directory from being read into memory whole.
const max_input_bytes: usize = 1024 * 1024;

const default_cache_dir = ".zig-cache";
const default_staging_dir = ".corpus-candidates";

const usage =
    \\phaser corpus — inspect and stage generated fuzz corpus entries
    \\
    \\Usage:
    \\  zig build corpus -- list  [--cache-dir=PATH]
    \\  zig build corpus -- stage [--cache-dir=PATH] [--out=PATH]
    \\
    \\Options:
    \\  --cache-dir=PATH  Build cache holding the generated corpus
    \\                    (default: .zig-cache)
    \\  --out=PATH        Directory to stage candidates into
    \\                    (default: .corpus-candidates)
    \\
    \\A staged candidate becomes permanent only by review: move it into
    \\test/corpus/<target>/ under a name that says what it covers, and add it to
    \\that target's .corpus list in test/fuzz/root.zig.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &file_writer.interface;

    const code = run(init, out) catch |err| switch (err) {
        error.Usage => blk: {
            try out.writeAll(usage);
            break :blk @as(u8, 2);
        },
        else => return err,
    };

    try out.flush();
    return code;
}

const Command = enum { list, stage };

fn run(init: std.process.Init, out: *std.Io.Writer) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer iterator.deinit();
    _ = iterator.skip();

    const command_name = iterator.next() orelse return error.Usage;
    const command = std.meta.stringToEnum(Command, command_name) orelse return error.Usage;

    var cache_dir_path: []const u8 = default_cache_dir;
    var staging_dir_path: []const u8 = default_staging_dir;
    while (iterator.next()) |argument| {
        if (std.mem.startsWith(u8, argument, "--cache-dir=")) {
            cache_dir_path = argument["--cache-dir=".len..];
        } else if (std.mem.startsWith(u8, argument, "--out=")) {
            staging_dir_path = argument["--out=".len..];
        } else return error.Usage;
    }

    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    // Every target lives under the cache's fuzz directory. Its absence is the
    // ordinary state of a fresh clone, not an error.
    const fuzz_dir_path = try std.fmt.allocPrint(arena, "{s}/f", .{cache_dir_path});
    const fuzz_dir: ?std.Io.Dir = cwd.openDir(io, fuzz_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (fuzz_dir) |dir| dir.close(io);

    if (fuzz_dir == null) {
        try out.print(
            \\No generated corpus in '{s}'.
            \\
            \\Produce one with a campaign that preserves the cache, for example
            \\
            \\    zig build fuzz -Doptimize=ReleaseSafe --fuzz=2M
            \\
            \\
        , .{fuzz_dir_path});
        return 0;
    }

    var staged_total: usize = 0;
    var new_total: usize = 0;

    for (targets.names) |name| {
        var target_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer target_arena.deinit();
        const scratch = target_arena.allocator();

        const directory = cacheDirectoryName(name);
        const committed = try readCommitted(io, scratch, name);
        const generated = try readGenerated(io, scratch, fuzz_dir.?, &directory);

        var new: std.ArrayList([]const u8) = .empty;
        for (generated) |input| {
            if (contains(committed, input)) continue;
            try new.append(scratch, input);
        }
        new_total += new.items.len;

        try out.print("{s}\n", .{name});
        try out.print("  cache directory    f/{s}\n", .{&directory});
        try out.print("  committed inputs   {d}\n", .{committed.len});
        try out.print("  generated inputs   {d}\n", .{generated.len});
        try out.print("  already committed  {d}\n", .{generated.len - new.items.len});

        if (command == .stage and new.items.len != 0) {
            const written = try stage(io, scratch, staging_dir_path, name, new.items);
            staged_total += written;
            try out.print("  staged             {d} new of {d} in {s}/{s}\n", .{
                written,
                new.items.len,
                staging_dir_path,
                name,
            });
        }
        try out.writeAll("\n");
    }

    switch (command) {
        .list => try out.print(
            \\{d} generated inputs are not committed verbatim.
            \\Run `zig build corpus -- stage` to write them out for review.
            \\
            \\"already committed" counts generated inputs matching a committed file
            \\byte for byte. A hand-written seed is ordinary text read as a value
            \\stream, so it rarely matches anything the fuzzer stores and a zero
            \\there is the normal case, not a coverage measurement. What the fuzzer
            \\stores is one input per distinct coverage class it reached locally.
            \\
        , .{new_total}),
        .stage => try out.print(
            \\Staged {d} of {d} uncommitted inputs into '{s}'.
            \\
            \\Nothing has been committed. Per DEVELOPMENT_WORKFLOW.md section 7, an
            \\input becomes permanent by review: keep the ones that cover something
            \\the committed corpus does not, move each into test/corpus/<target>/
            \\under a name that says what it covers, and add it to that target's
            \\.corpus list in test/fuzz/root.zig.
            \\
        , .{ staged_total, new_total, staging_dir_path }),
    }

    return 0;
}

/// The toolchain names a target's corpus directory by hashing the fully
/// qualified test name, so this must hash exactly what the test runner reports.
/// The guard test in `test/fuzz/root.zig` checks that the prefix still matches.
fn cacheDirectoryName(target: []const u8) [16]u8 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(targets.test_name_prefix);
    hasher.update(target);
    return std.fmt.hex(hasher.final());
}

/// Reads the permanent corpus a target replays on every run.
fn readCommitted(
    io: std.Io,
    arena: std.mem.Allocator,
    target: []const u8,
) ![]const []const u8 {
    const path = try std.fmt.allocPrint(arena, "test/corpus/{s}", .{target});
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var inputs: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, arena, .limited(max_input_bytes));
        try inputs.append(arena, bytes);
    }
    return inputs.items;
}

/// Reads the corpus a campaign left in the build cache.
fn readGenerated(
    io: std.Io,
    arena: std.mem.Allocator,
    fuzz_dir: std.Io.Dir,
    directory: []const u8,
) ![]const []const u8 {
    var dir = fuzz_dir.openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);

    var inputs: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Inputs are numbered; the directory also holds the fuzzer's lock files.
        if (!isNumeric(entry.name)) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, arena, .limited(max_input_bytes));
        if (bytes.len == 0) continue;
        try inputs.append(arena, bytes);
    }
    return inputs.items;
}

/// Writes candidates out for review, named by content so that staging the same
/// input twice does not produce two copies of it.
fn stage(
    io: std.Io,
    arena: std.mem.Allocator,
    staging_dir_path: []const u8,
    target: []const u8,
    inputs: []const []const u8,
) !usize {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ staging_dir_path, target });
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);

    var written: usize = 0;
    for (inputs) |input| {
        const digest = std.fmt.hex(std.hash.Wyhash.hash(0, input));
        const name = try std.fmt.allocPrint(arena, "candidate-{s}.bin", .{&digest});
        // Content-addressed names make a repeated staging idempotent, and
        // leaving an existing file alone preserves a rename or an annotation a
        // reviewer has already made.
        dir.access(io, name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try dir.writeFile(io, .{ .sub_path = name, .data = input });
                written += 1;
                continue;
            },
            else => return err,
        };
    }
    return written;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) return true;
    }
    return false;
}

fn isNumeric(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |character| {
        if (!std.ascii.isDigit(character)) return false;
    }
    return true;
}
