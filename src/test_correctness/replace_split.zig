const std = @import("std");
const regex = @import("../root.zig");

// Replace and split correctness tests.

fn expectReplace(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, replacement: []const u8, expected: []const u8) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
    const result = try re.replace(text, replacement);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

fn expectSplitLen(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, expected_len: usize) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
    var parts = try re.split(text);
    defer parts.deinit(allocator);
    try std.testing.expectEqual(@as(usize, expected_len), parts.items.len);
}

test "replace: simple literal" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "a", "abc", "X", "Xbc");
    try expectReplace(allocator, "a", "aaa", "X", "Xaa");
}

test "replace: with quantifier" {
    const allocator = std.testing.allocator;
    // replace replaces only the first match.
    try expectReplace(allocator, "a+", "aabbaaa", "X", "Xbbaaa");
    try expectReplace(allocator, "a+", "bbb", "X", "bbb");
}

test "replace: empty replacement" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "a", "abc", "", "bc");
    // replace replaces only the first match.
    try expectReplace(allocator, "a+", "aabbaaa", "", "bbaaa");
}

test "replace: no match" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "x", "abc", "X", "abc");
}

test "replace: pattern at boundaries" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "^a", "abc", "X", "Xbc");
    try expectReplace(allocator, "c$", "abc", "X", "abX");
}

test "replace: multiple matches" {
    const allocator = std.testing.allocator;
    // replace replaces only the first match.
    try expectReplace(allocator, ",", "a,b,c", ";", "a;b,c");
}

test "replace: group replacement literal" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "(a+)", "aaabb", "X", "Xbb");
}

test "replace: $0 full match" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "a+", "aaabb", "[$0]", "[aaa]bb");
}

test "replace: $1 capture group" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "(a)(b)", "ab", "$1-$2", "a-b");
}

test "replace: $$ escape" {
    const allocator = std.testing.allocator;
    try expectReplace(allocator, "a", "abc", "$$", "$bc");
}

test "split: simple delimiter" {
    const allocator = std.testing.allocator;
    try expectSplitLen(allocator, ",", "a,b,c", 3);
    try expectSplitLen(allocator, " ", "one two three", 3);
}

test "split: regex delimiter" {
    const allocator = std.testing.allocator;
    try expectSplitLen(allocator, "\\s+", "one  two   three", 3);
    // "baaac" split on "a+" yields ["b", "c"].
    try expectSplitLen(allocator, "a+", "baaac", 2);
}

test "split: no delimiter match" {
    const allocator = std.testing.allocator;
    try expectSplitLen(allocator, ",", "abc", 1);
}

test "split: delimiter at start/end" {
    const allocator = std.testing.allocator;
    try expectSplitLen(allocator, ",", ",a,b,", 4);
}

test "split: empty string" {
    const allocator = std.testing.allocator;
    try expectSplitLen(allocator, ",", "", 1);
}
