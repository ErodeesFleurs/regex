const std = @import("std");
const regex = @import("../root.zig");

// Conditional pattern correctness tests.

// Conditional: (?(n)yes|no)
// If capture group n has a match, match yes-pattern; otherwise match no-pattern.

test "conditional: basic (?(1)yes|no)" {
    const allocator = std.testing.allocator;
    // If group 1 matches, require 'b'; otherwise require 'c'
    var re = try regex.Regex.compile(allocator, "(a)(?(1)b|c)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(!try re.isMatch("c"));
}

test "conditional: with no branch" {
    const allocator = std.testing.allocator;
    // If group 1 matches, require 'b'; otherwise fail
    var re = try regex.Regex.compile(allocator, "(a)(?(1)b)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
}

test "conditional: lookahead positive" {
    const allocator = std.testing.allocator;
    // If next is digit, match 3 digits; otherwise match 'xx'
    var re = try regex.Regex.compile(allocator, "(?(?=\\d)\\d{3}|[a-z]{2})");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("123"));
    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(!try re.isMatch("1a"));
}

test "conditional: lookahead negative" {
    const allocator = std.testing.allocator;
    // If next is NOT digit, match 2 letters; otherwise match 3 digits
    var re = try regex.Regex.compile(allocator, "(?(?!\\d)[a-z]{2}|\\d{3})");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(try re.isMatch("123"));
    try std.testing.expect(!try re.isMatch("1a"));
}

test "conditional: lookbehind positive" {
    const allocator = std.testing.allocator;
    // If preceded by 'a', match 'b'; otherwise match 'c'
    var re = try regex.Regex.compile(allocator, "(?<=a)(?(?<=a)b|c)");
    defer re.deinit();

    var result = try re.find("ab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("b", "ab"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }

    var result2 = try re.find("ac");
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("c", "ac"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }
}

test "conditional: with backref" {
    const allocator = std.testing.allocator;
    // Match 'aa' or 'bb' depending on first capture
    var re = try regex.Regex.compile(allocator, "(a|b)(?(1)\\1)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("aa"));
    try std.testing.expect(try re.isMatch("bb"));
}

test "conditional: nested groups" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "((a))(?(1)b|c)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(!try re.isMatch("c"));
}

test "conditional: simple digit" {
    const allocator = std.testing.allocator;
    // Group 1 is optional, condition checks if it matched
    var re = try regex.Regex.compile(allocator, "(a)?(?(1)b|c)");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(try re.isMatch("c"));
    try std.testing.expect(!try re.isMatch("b"));
}

test "conditional: find" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(\\d)(?(1)abc|def)");
    defer re.deinit();

    var result1 = try re.find("123abc");
    if (result1) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("3abc", "123abc"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }
}
