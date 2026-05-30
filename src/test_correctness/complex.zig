const std = @import("std");
const regex = @import("../root.zig");

// Complex combination and edge-case correctness tests.
// Drawn from Henry Spencer, PCRE, and RE2 canonical test suites.

test "complex: alternation |" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a|b", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a|b", "b"));
    try std.testing.expect(!try regex.isMatch(allocator, "a|b", "c"));
    try std.testing.expect(try regex.isMatch(allocator, "ab|cd", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "ab|cd", "cd"));
    try std.testing.expect(!try regex.isMatch(allocator, "ab|cd", "ac"));
}

test "complex: alternation with groups" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a|b)c", "ac"));
    try std.testing.expect(try regex.isMatch(allocator, "(a|b)c", "bc"));
    try std.testing.expect(!try regex.isMatch(allocator, "(a|b)c", "c"));
}

test "complex: concatenation precedence" {
    const allocator = std.testing.allocator;
    // ab|cd should match "ab" or "cd", not "a" followed by "b|cd".
    try std.testing.expect(try regex.isMatch(allocator, "ab|cd", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "ab|cd", "cd"));
    try std.testing.expect(!try regex.isMatch(allocator, "ab|cd", "ad"));
}

test "complex: star of group" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(ab)*", ""));
    try std.testing.expect(try regex.isMatch(allocator, "(ab)*", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "(ab)*", "abab"));
    // Prefix match: "(ab)*" matches empty string at position 0.
    try std.testing.expect(try regex.isMatch(allocator, "(ab)*", "aba"));
}

test "complex: plus of group" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "(ab)+", ""));
    try std.testing.expect(try regex.isMatch(allocator, "(ab)+", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "(ab)+", "abab"));
}

test "complex: dot . matches any char" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, ".", "a"));
    try std.testing.expect(try regex.isMatch(allocator, ".", "0"));
    try std.testing.expect(try regex.isMatch(allocator, ".", "!"));
    try std.testing.expect(!try regex.isMatch(allocator, ".", ""));
}

test "complex: dot with quantifier" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, ".*", ""));
    try std.testing.expect(try regex.isMatch(allocator, ".*", "abc"));
    try std.testing.expect(try regex.isMatch(allocator, "a.b", "acb"));
    try std.testing.expect(!try regex.isMatch(allocator, "a.b", "ab"));
}

test "complex: mixed anchors and quantifiers" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^.*$", ""));
    try std.testing.expect(try regex.isMatch(allocator, "^.*$", "abc"));
    try std.testing.expect(try regex.isMatch(allocator, "^a.*z$", "abcdefghijklmnopqrstuvwxyz"));
}

test "complex: repeating alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a|)*", ""));
    try std.testing.expect(try regex.isMatch(allocator, "(a|)*", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "(a|)*", "aaa"));
}

test "complex: empty alternative" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a|", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a|", ""));
    // Prefix match: "a|" matches empty string at position 0.
    try std.testing.expect(try regex.isMatch(allocator, "a|", "b"));
}

test "complex: deeply nested" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "((a))", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "(((a)))", "a"));
}

test "complex: overlapping patterns" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "aba", "aba"));
    try std.testing.expect(try regex.isMatch(allocator, "aba", "ababa"));
}

test "complex: find overlapping" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "aba", "ababa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(0, r.start);
        try std.testing.expectEqual(3, r.end);
    } else {
        try std.testing.expect(false);
    }
}
