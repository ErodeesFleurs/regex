const std = @import("std");
const regex = @import("../root.zig");

// Word boundary correctness tests.

test "word boundary: \\b simple" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\bword\\b", "word"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\bword\\b", "sword"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\bword\\b", "words"));
}

test "word boundary: \\b at start" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\bhello", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\bhello", "ahello"));
}

test "word boundary: \\b at end" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "hello\\b", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "hello\\b", "helloa"));
}

test "word boundary: \\B simple" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\Bword\\B", "aworda"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\Bword\\B", "word"));
}

test "word boundary: \\b with digits" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\b123\\b", "123"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\b123\\b", "a123"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\b123\\b", "123b"));
}

test "word boundary: \\b empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "\\b", ""));
    // \b at position 0 with no word char after is not a boundary
}

test "word boundary: \\b underscore" {
    const allocator = std.testing.allocator;
    // underscore is a word char
    try std.testing.expect(!try regex.isMatch(allocator, "a\\b_", "a_"));
    try std.testing.expect(try regex.isMatch(allocator, "a\\b_", "a _"));
}
