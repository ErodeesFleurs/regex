const std = @import("std");
const regex = @import("../root.zig");

// Boundary and corner case tests.

test "boundary: empty pattern" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "");
    defer re.deinit();
    // Empty pattern matches empty string at any position (prefix match)
    try std.testing.expect(try re.isMatch(""));
    try std.testing.expect(try re.isMatch("abc"));
}

test "boundary: empty input" {
    const allocator = std.testing.allocator;
    var re1 = try regex.compile(allocator, "a");
    defer re1.deinit();
    try std.testing.expect(!try re1.isMatch(""));

    var re2 = try regex.compile(allocator, "a*");
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch(""));

    var re3 = try regex.compile(allocator, "a?");
    defer re3.deinit();
    try std.testing.expect(try re3.isMatch(""));
}

test "boundary: single character" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("a"));
    try std.testing.expect(!try re.isMatch("b"));
    try std.testing.expect(!try re.isMatch(""));
}

test "boundary: long literal" {
    const allocator = std.testing.allocator;
    const long_text = "a" ** 50;
    var re = try regex.compile(allocator, long_text);
    defer re.deinit();
    try std.testing.expect(try re.isMatch(long_text));
}

test "boundary: zero-width match" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a*");
    defer re.deinit();
    // a* matches empty string at position 0
    try std.testing.expect(try re.isMatch("b"));
    try std.testing.expect(try re.isMatch(""));
}

test "boundary: zero-width match find" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "");
    defer re.deinit();
    var result = try re.find("abc");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(@as(usize, 0), r.start);
        try std.testing.expectEqual(@as(usize, 0), r.end);
    } else {
        try std.testing.expect(false);
    }
}

test "boundary: max repetition" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a{5}");
    defer re.deinit();
    const text = "a" ** 5;
    try std.testing.expect(try re.isMatch(text));
}

test "boundary: nested groups" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "((a)(b))");
    defer re.deinit();
    var result = try re.find("ab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("ab", r.getGroup("ab", 0).?);
        try std.testing.expectEqualStrings("ab", r.getGroup("ab", 1).?);
        try std.testing.expectEqualStrings("a", r.getGroup("ab", 2).?);
        try std.testing.expectEqualStrings("b", r.getGroup("ab", 3).?);
    } else {
        try std.testing.expect(false);
    }
}

test "boundary: unmatched closing paren" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, regex.compile(allocator, "a)"));
}

test "boundary: unmatched opening paren" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, regex.compile(allocator, "(a"));
}

test "boundary: empty group" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.EmptyGroup, regex.compile(allocator, "()"));
}

test "boundary: empty alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, regex.compile(allocator, "|"));
}

test "boundary: invalid quantifier" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidQuantifier, regex.compile(allocator, "a{2,1}"));
}

test "boundary: unterminated char class" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedCharClass, regex.compile(allocator, "[abc"));
}

test "boundary: invalid escape" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, regex.compile(allocator, "\\"));
}

test "boundary: replace empty match" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "");
    defer re.deinit();
    const result = try re.replaceAll("ab", "X");
    defer allocator.free(result);
    // Empty pattern matches at every position, including start, between chars, and end
    try std.testing.expectEqualStrings("XaXbX", result);
}

test "boundary: split empty match" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "");
    defer re.deinit();
    var parts = try re.splitLimit("ab", 2);
    defer parts.deinit(allocator);
    // Empty pattern matches at position 0, then between chars, then at end
    try std.testing.expectEqual(@as(usize, 3), parts.items.len);
    try std.testing.expectEqualStrings("", parts.items[0]);
    try std.testing.expectEqualStrings("a", parts.items[1]);
    try std.testing.expectEqualStrings("b", parts.items[2]);
}

test "boundary: unicode empty input" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\p{Han}");
    defer re.deinit();
    try std.testing.expect(!try re.isMatch(""));
}

test "boundary: unicode single char" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\p{Han}");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("中"));
    try std.testing.expect(!try re.isMatch("a"));
}

test "boundary: case insensitive empty" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch(""));
    try std.testing.expect(try re.isMatch("ABC"));
}

test "boundary: dot with newline" {
    const allocator = std.testing.allocator;
    var re1 = try regex.Regex.compileWithOptions(allocator, ".*", .{ .dot_matches_newline = false });
    defer re1.deinit();
    try std.testing.expect(try re1.isMatch("a\nb"));

    var re2 = try regex.Regex.compileWithOptions(allocator, ".*", .{ .dot_matches_newline = true });
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch("a\nb"));
}

test "boundary: multiline empty" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "^$", .{ .multiline = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch(""));
    try std.testing.expect(try re.isMatch("\n"));
    // isMatch is prefix match; "a\nb" starts with 'a', so ^$ doesn't match at position 0
    try std.testing.expect(!try re.isMatch("a\nb"));
}

test "boundary: findAll no matches" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "z");
    defer re.deinit();
    var results = try re.findAll("abc");
    defer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "boundary: backref empty capture" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(a*)\\1");
    defer re.deinit();
    try std.testing.expect(try re.isMatch(""));
    try std.testing.expect(try re.isMatch("aa"));
    // a* greedily matches "a", then \1 matches "a", so "a" should match
    try std.testing.expect(try re.isMatch("a"));
}
