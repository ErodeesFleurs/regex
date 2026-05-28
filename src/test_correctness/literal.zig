const std = @import("std");
const regex = @import("../root.zig");
const h = @import("helpers.zig");

// Henry Spencer-inspired literal match correctness tests.
// These are the canonical baseline tests for any regex engine.

test "literal: exact match" {
    try h.expectMatch("abc", "abc");
    try h.expectNoMatch("abc", "ab");
    // isMatch uses prefix semantics (matches from position 0, need not consume entire string).
    try h.expectMatch("abc", "abcd");
}

test "literal: empty pattern" {
    // Empty regex matches empty string at position 0.
    try h.expectMatch("", "");
    try h.expectMatch("", "abc");
}

test "literal: single character" {
    try h.expectMatch("a", "a");
    try h.expectNoMatch("a", "b");
    try h.expectNoMatch("a", "");
}

test "literal: escaped special chars" {
    try h.expectMatch("\\.", ".");
    try h.expectNoMatch("\\.", "a");
    try h.expectMatch("\\*", "*");
    try h.expectMatch("\\+", "+");
    try h.expectMatch("\\?", "?");
    try h.expectMatch("\\[", "[");
    try h.expectMatch("\\]", "]");
    try h.expectMatch("\\(", "(");
    try h.expectMatch("\\)", ")");
}

test "literal: escaped backslash" {
    try h.expectMatch("\\\\", "\\");
}

test "literal: escaped whitespace" {
    try h.expectMatch("\\t", "\t");
    try h.expectMatch("\\n", "\n");
    try h.expectMatch("\\r", "\r");
}

test "literal: case sensitivity" {
    try h.expectMatch("Hello", "Hello");
    try h.expectNoMatch("Hello", "hello");
    try h.expectNoMatch("Hello", "HELLO");
}

test "literal: long string" {
    try h.expectMatch("abcdefghij", "abcdefghij");
    try h.expectNoMatch("abcdefghij", "abcdefghi");
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
