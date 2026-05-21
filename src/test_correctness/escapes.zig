const std = @import("std");
const regex = @import("../root.zig");

// Hex and Unicode escape correctness tests.

test "escape: \\xNN hex" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x41", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x42", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\x41", "B"));
}

test "escape: \\xNN lowercase hex" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x0a", "\n"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x0d", "\r"));
}

test "escape: \\uNNNN unicode" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\u0041", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\u0042", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\u0041", "B"));
}

test "escape: hex in char class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[\\x41-\\x43]", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\x41-\\x43]", "D"));
}
