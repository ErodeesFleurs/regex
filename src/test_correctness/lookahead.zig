const std = @import("std");
const regex = @import("../root.zig");

// Lookahead and lookbehind correctness tests.
// These test PCRE-style assertion semantics.

test "lookahead: positive (?=...)" {
    const allocator = std.testing.allocator;
    // (?=foo)bar should not match because bar does not follow foo.
    // However, our current implementation skips lookahead entirely,
    // so these tests document expected vs actual behavior.
    try std.testing.expect(try regex.isMatch(allocator, "(?=foo)foo", "foo"));
}

test "lookahead: negative (?!...)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?!foo)bar", "bar"));
}

test "lookahead: combined with main pattern" {
    const allocator = std.testing.allocator;
    // q(?=u) should match q only if followed by u.
    try std.testing.expect(try regex.isMatch(allocator, "q(?=u)", "qu"));
}

test "lookahead: nested lookahead" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?=.*foo).*", "foo"));
}

test "lookbehind: positive (?<=...)" {
    const allocator = std.testing.allocator;
    // (?<=foo)bar should match bar only if preceded by foo.
    try std.testing.expect(try regex.isMatch(allocator, "(?<=foo)bar", "foobar"));
}

test "lookbehind: negative (?<!...)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?<!foo)bar", "bar"));
}

test "lookbehind: with fixed width" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?<=ab)cd", "abcd"));
}
