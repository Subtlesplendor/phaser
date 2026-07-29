//! Handle tagging for the C ABI.
//!
//! Every opaque handle carries a distinct tag as its first field. The tag is
//! checked before the handle is otherwise touched, so passing a handle of the
//! wrong type -- the mistake an opaque `void *` boundary makes easy -- is
//! reported as `invalid_argument` rather than dereferenced.
//!
//! On destruction the tag is overwritten before the memory is released. That
//! turns many double-destroy and use-after-free mistakes into a reported error
//! too, but it is best effort and not a guarantee: once the allocator has
//! reused the block, the bytes may spell anything. The contract remains that a
//! handle is destroyed exactly once. This is a diagnostic aid for a caller who
//! breaks it, not permission to.

/// Distinct per-type tags. The byte pattern is legible in a hex dump, which is
/// where these are usually read from.
pub const context: u32 = 0x5048_4301;
pub const model: u32 = 0x5048_4302;
pub const diagnostics: u32 = 0x5048_4303;
pub const request: u32 = 0x5048_4304;
pub const artifact: u32 = 0x5048_4305;
pub const kernel: u32 = 0x5048_4306;
pub const point: u32 = 0x5048_4307;
pub const binding: u32 = 0x5048_4308;

/// Written over a tag immediately before the handle's memory is freed.
pub const destroyed: u32 = 0x5048_44ED;

/// True when `tag` is the expected one for this handle type.
pub fn matches(tag: u32, expected: u32) bool {
    return tag == expected;
}

test "tags are distinct" {
    const std = @import("std");
    const tags = [_]u32{
        context,
        model,
        diagnostics,
        request,
        artifact,
        kernel,
        point,
        binding,
        destroyed,
    };
    for (tags, 0..) |left, i| {
        for (tags[i + 1 ..]) |right| {
            try std.testing.expect(left != right);
        }
    }
}
