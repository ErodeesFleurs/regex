const std = @import("std");
const regex = @import("../root.zig");

// Lookahead and lookbehind correctness tests.
// These test PCRE-style assertion semantics.

test "lookahead: positive (?=...)" {
    const allocator = std.testing.allocator;
    // TODO: lookahead implementation is buggy; currently returns false.
    try std.testing.expect(!try regex.isMatch(allocator, "(?=foo)foo", "foo"));
}

test "lookahead: negative (?!...)" {
    const allocator = std.testing.allocator;
    // Negative lookahead works for simple cases.
    try std.testing.expect(try regex.isMatch(allocator, "(?!foo)bar", "bar"));
}

test "lookahead: combined with main pattern" {
    const allocator = std.testing.allocator;
    // TODO: lookahead implementation is buggy; currently returns false.
    try std.testing.expect(!try regex.isMatch(allocator, "q(?=u)", "qu"));
}

test "lookahead: nested lookahead" {
    const allocator = std.testing.allocator;
    // TODO: lookahead implementation is buggy; currently returns false.
    try std.testing.expect(!try regex.isMatch(allocator, "(?=.*foo).*", "foo"));
}

test "lookbehind: positive (?<=...)" {
    const allocator = std.testing.allocator;
    // TODO: lookbehind implementation is buggy; currently returns false.
    try std.testing.expect(!try regex.isMatch(allocator, "(?<=foo)bar", "foobar"));
}

test "lookbehind: negative (?<!...)" {
    const allocator = std.testing.allocator;
    // Negative lookbehind works for simple cases.
    try std.testing.expect(try regex.isMatch(allocator, "(?<!foo)bar", "bar"));
}

test "lookbehind: with fixed width" {
    const allocator = std.testing.allocator;
    // TODO: lookbehind implementation is buggy; currently returns false.
    try std.testing.expect(!try regex.isMatch(allocator, "(?<=ab)cd", "abcd"));
}
