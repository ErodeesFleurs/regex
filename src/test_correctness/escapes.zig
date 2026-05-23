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

test "escape: \\x{hhhh} variable hex" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x{41}", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x{1F600}", "\u{1F600}"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\x{41}", "B"));
}

test "escape: \\x{hhhh} emoji" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x{2764}", "\u{2764}"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x{1F525}", "\u{1F525}"));
}

test "escape: \\a bell" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\a", "\x07"));
}

test "escape: \\e escape" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\e", "\x1B"));
}

test "escape: \\f form feed" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\f", "\x0C"));
}

test "escape: \\v vertical tab" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\v", "\x0B"));
}
