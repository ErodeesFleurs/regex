const std = @import("std");
const regex = @import("../root.zig");

// Henry Spencer-inspired literal match correctness tests.
// These are the canonical baseline tests for any regex engine.

test "literal: exact match" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "abc", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc", "ab"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc", "abcd"));
}

test "literal: empty pattern" {
    const allocator = std.testing.allocator;
    // Empty regex matches empty string at position 0.
    try std.testing.expect(try regex.isMatch(allocator, "", ""));
    try std.testing.expect(try regex.isMatch(allocator, "", "abc"));
}

test "literal: single character" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "a", "b"));
    try std.testing.expect(!try regex.isMatch(allocator, "a", ""));
}

test "literal: escaped special chars" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\.", "."));
    try std.testing.expect(!try regex.isMatch(allocator, "\\.", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "\\*", "*"));
    try std.testing.expect(try regex.isMatch(allocator, "\\+", "+"));
    try std.testing.expect(try regex.isMatch(allocator, "\\?", "?"));
    try std.testing.expect(try regex.isMatch(allocator, "\\[", "["));
    try std.testing.expect(try regex.isMatch(allocator, "\\]", "]"));
    try std.testing.expect(try regex.isMatch(allocator, "\\(", "("));
    try std.testing.expect(try regex.isMatch(allocator, "\\)", ")"));
}

test "literal: escaped backslash" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\\\", "\\"));
}

test "literal: escaped whitespace" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\t", "\t"));
    try std.testing.expect(try regex.isMatch(allocator, "\\n", "\n"));
    try std.testing.expect(try regex.isMatch(allocator, "\\r", "\r"));
}

test "literal: case sensitivity" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "Hello", "Hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "Hello", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "Hello", "HELLO"));
}

test "literal: long string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "abcdefghij", "abcdefghij"));
    try std.testing.expect(!try regex.isMatch(allocator, "abcdefghij", "abcdefghi"));
}

test "literal: substring via find" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "abc", "xxabcyy");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(@as(usize, 2), r.start);
        try std.testing.expectEqual(@as(usize, 5), r.end);
    } else {
        try std.testing.expect(false);
    }
}
