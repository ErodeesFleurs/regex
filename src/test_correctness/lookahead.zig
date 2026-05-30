const std = @import("std");
const regex = @import("../root.zig");

// Lookahead and lookbehind correctness tests.
// These test PCRE-style assertion semantics.

test "lookahead: positive (?=...)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?=foo)foo", "foo"));
}

test "lookahead: negative (?!...)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?!foo)bar", "bar"));
    try std.testing.expect(!try regex.isMatch(allocator, "(?!foo)foo", "foo"));
}

test "lookahead: combined with main pattern" {
    const allocator = std.testing.allocator;
    // q(?=u) should match q only if followed by u.
    try std.testing.expect(try regex.isMatch(allocator, "q(?=u)", "qu"));
    try std.testing.expect(!try regex.isMatch(allocator, "q(?=u)", "qa"));
}

test "lookahead: nested lookahead" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?=.*foo).*", "foo"));
}

test "lookbehind: positive (?<=...)" {
    const allocator = std.testing.allocator;
    // (?<=foo)bar matches from position 3, so use find instead of isMatch.
    var result = try regex.find(allocator, "(?<=foo)bar", "foobar");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}

test "lookbehind: negative (?<!...)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?<!foo)bar", "bar"));
    try std.testing.expect(!try regex.isMatch(allocator, "(?<!foo)bar", "foobar"));
}

test "lookbehind: with fixed width" {
    const allocator = std.testing.allocator;
    // (?<=ab)cd matches from position 2, so use find instead of isMatch.
    var result = try regex.find(allocator, "(?<=ab)cd", "abcd");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}

test "lookbehind: variable width" {
    const allocator = std.testing.allocator;
    // (?<=a+)b should match b preceded by one or more a's.
    var result = try regex.find(allocator, "(?<=a+)b", "aaab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }

    var result2 = try regex.find(allocator, "(?<=a+)b", "ab");
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}

test "lookbehind: alternation" {
    const allocator = std.testing.allocator;
    // (?<=foo|bar)baz
    var result = try regex.find(allocator, "(?<=foo|bar)baz", "foobaz");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }

    var result2 = try regex.find(allocator, "(?<=foo|bar)baz", "barbaz");
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}
