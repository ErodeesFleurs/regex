const std = @import("std");
const regex = @import("../root.zig");

// Stress and edge-case tests.

test "stress: long string literal match" {
    const allocator = std.testing.allocator;
    const text = "a" ** 100;
    try std.testing.expect(try regex.isMatch(allocator, "a+", text));
    try std.testing.expect(try regex.isMatch(allocator, "a{50}", text));
    try std.testing.expect(try regex.isMatch(allocator, "a{100}", text));
    try std.testing.expect(!try regex.isMatch(allocator, "a{101}", text));
}

test "stress: deep nesting" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "((((a))))", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "((((a)+)))", "aaa"));
}

test "stress: complex alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a|b|c|d|e)*", "abcde"));
    try std.testing.expect(try regex.isMatch(allocator, "(a|b|c|d|e)*", "edcba"));
}

test "stress: star vs plus empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a*", ""));
    try std.testing.expect(!try regex.isMatch(allocator, "a+", ""));
}

test "stress: overlapping patterns" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "aa", "aaaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqual(0, r.start);
        try std.testing.expectEqual(2, r.end);
    } else {
        try std.testing.expect(false);
    }
}

test "stress: all chars dot match" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, ".*", "!@#$%^&*()"));
}

test "stress: mixed features" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^\\d+[a-z]+$", "123abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^\\d+[a-z]+$", "abc123"));
}
