const std = @import("std");
const regex = @import("../root.zig");

// Anchor (^, $) correctness tests.
// Covers POSIX / PCRE line-anchor semantics.

test "anchor: start of string ^" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^abc", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc", "xabc"));
    try std.testing.expect(try regex.isMatch(allocator, "^abc", "abcx"));
}

test "anchor: end of string $" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "abc$", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc$", "abcx"));
    // Prefix match: "abc$" does not match at position 0 of "xabc".
    try std.testing.expect(!try regex.isMatch(allocator, "abc$", "xabc"));
}

test "anchor: both ^ and $" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^abc$", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc$", "xabc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc$", "abcx"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc$", "xabcx"));
}

test "anchor: ^ with empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^", ""));
    try std.testing.expect(try regex.isMatch(allocator, "^a", "a"));
}

test "anchor: $ with empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "$", ""));
    try std.testing.expect(try regex.isMatch(allocator, "a$", "a"));
}

test "anchor: ^$ empty match" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^$", ""));
    try std.testing.expect(!try regex.isMatch(allocator, "^$", "a"));
}

test "anchor: multiple anchors" {
    const allocator = std.testing.allocator;
    // "^a$b$" is impossible (requires end-of-string twice).
    try std.testing.expect(!try regex.isMatch(allocator, "^a$b$", "ab"));
    try std.testing.expect(!try regex.isMatch(allocator, "^a$b$", "abc"));
}

test "anchor: anchor with alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^(a|b)$", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "^(a|b)$", "b"));
    try std.testing.expect(!try regex.isMatch(allocator, "^(a|b)$", "ab"));
}

test "anchor: anchor with quantifier" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^a+$", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "^a+$", "aaa"));
    try std.testing.expect(!try regex.isMatch(allocator, "^a+$", ""));
    try std.testing.expect(!try regex.isMatch(allocator, "^a+$", "aaab"));
}
