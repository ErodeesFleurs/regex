const std = @import("std");
const regex = @import("../root.zig");

/// Check that pattern matches text.
pub fn expectMatch(pattern: []const u8, text: []const u8) !void {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, pattern, text));
}

/// Check that pattern does NOT match text.
pub fn expectNoMatch(pattern: []const u8, text: []const u8) !void {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, pattern, text));
}
