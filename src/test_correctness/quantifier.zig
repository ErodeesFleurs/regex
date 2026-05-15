const std = @import("std");
const regex = @import("../root.zig");

// POSIX / PCRE-inspired quantifier correctness tests.

test "quantifier: star (zero or more)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a*", ""));
    try std.testing.expect(try regex.isMatch(allocator, "a*", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a*", "aaa"));
    try std.testing.expect(try regex.isMatch(allocator, "a*b", "b"));
    try std.testing.expect(try regex.isMatch(allocator, "a*b", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "a*b", "aaab"));
}

test "quantifier: plus (one or more)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "a+", ""));
    try std.testing.expect(try regex.isMatch(allocator, "a+", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a+", "aaa"));
    try std.testing.expect(!try regex.isMatch(allocator, "a+b", "b"));
    try std.testing.expect(try regex.isMatch(allocator, "a+b", "ab"));
}

test "quantifier: question (zero or one)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a?", ""));
    try std.testing.expect(try regex.isMatch(allocator, "a?", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a?b", "b"));
    try std.testing.expect(try regex.isMatch(allocator, "a?b", "ab"));
    try std.testing.expect(!try regex.isMatch(allocator, "a?b", "aab"));
}

test "quantifier: exact {n}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "a{3}", "aa"));
    try std.testing.expect(try regex.isMatch(allocator, "a{3}", "aaa"));
    try std.testing.expect(try regex.isMatch(allocator, "a{3}", "aaaa"));
}

test "quantifier: range {n,m}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "a{2,3}", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a{2,3}", "aa"));
    try std.testing.expect(try regex.isMatch(allocator, "a{2,3}", "aaa"));
    try std.testing.expect(try regex.isMatch(allocator, "a{2,3}", "aaaa"));
}

test "quantifier: min only {n,}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "a{2,}", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "a{2,}", "aa"));
    try std.testing.expect(try regex.isMatch(allocator, "a{2,}", "aaaa"));
}

test "quantifier: complex combination" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(ab)+", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "(ab)+", "abab"));
    try std.testing.expect(!try regex.isMatch(allocator, "(ab)+", ""));
}

test "quantifier: nested quantifiers" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a*b)*", ""));
    try std.testing.expect(try regex.isMatch(allocator, "(a*b)*", "b"));
    try std.testing.expect(try regex.isMatch(allocator, "(a*b)*", "aab"));
    try std.testing.expect(try regex.isMatch(allocator, "(a*b)*", "aabaab"));
}

test "quantifier: with alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a|b)*", ""));
    try std.testing.expect(try regex.isMatch(allocator, "(a|b)*", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "(a|b)*", "abab"));
    try std.testing.expect(try regex.isMatch(allocator, "(a|b)+", "ab"));
    try std.testing.expect(!try regex.isMatch(allocator, "(a|b)+", ""));
}
