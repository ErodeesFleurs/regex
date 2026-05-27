const std = @import("std");
const regex = @import("../root.zig");

// Grouping and capturing correctness tests.
// Covers PCRE / POSIX capture semantics.

test "group: simple capturing group" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "(ab)", "ab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        const g0 = r.getGroup("ab", 0);
        try std.testing.expect(g0 != null);
        try std.testing.expectEqualStrings("ab", g0.?);
        const g1 = r.getGroup("ab", 1);
        try std.testing.expect(g1 != null);
        try std.testing.expectEqualStrings("ab", g1.?);
    } else {
        try std.testing.expect(false);
    }
}

test "group: multiple capturing groups" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "(a)(b)", "ab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("ab", r.getGroup("ab", 0).?);
        try std.testing.expectEqualStrings("a", r.getGroup("ab", 1).?);
        try std.testing.expectEqualStrings("b", r.getGroup("ab", 2).?);
    } else {
        try std.testing.expect(false);
    }
}

test "group: non-capturing group" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(?:ab)+", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "(?:ab)+", "abab"));
    // Non-capturing groups should not create capture slots.
    var result = try regex.find(allocator, "(?:ab)+", "abab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("abab", r.getGroup("abab", 0).?);
        // Group 1 should not exist or be null.
        try std.testing.expect(r.getGroup("abab", 1) == null);
    } else {
        try std.testing.expect(false);
    }
}

test "group: nested groups" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "((a)(b))", "ab");
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

test "group: group with quantifier" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "(a+)", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("aaa", r.getGroup("aaa", 0).?);
        try std.testing.expectEqualStrings("aaa", r.getGroup("aaa", 1).?);
    } else {
        try std.testing.expect(false);
    }
}

test "group: alternation inside group" {
    const allocator = std.testing.allocator;
    var result1 = try regex.find(allocator, "(a|b)", "a");
    if (result1) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("a", r.getGroup("a", 1).?);
    } else {
        try std.testing.expect(false);
    }

    var result2 = try regex.find(allocator, "(a|b)", "b");
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("b", r.getGroup("b", 1).?);
    } else {
        try std.testing.expect(false);
    }
}

test "group: named capturing group" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "(?<word>\\w+)", "hello");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("hello", r.getGroup("hello", 0).?);
        try std.testing.expectEqualStrings("hello", r.getGroup("hello", 1).?);
    } else {
        try std.testing.expect(false);
    }
}

test "group: empty capturing group" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "(a?)", "");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("", r.getGroup("", 0).?);
        try std.testing.expectEqualStrings("", r.getGroup("", 1).?);
    } else {
        try std.testing.expect(false);
    }
}

test "group: backreference \\1" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a)\\1", "aa"));
    try std.testing.expect(!try regex.isMatch(allocator, "(a)\\1", "ab"));
}

test "group: backreference \\2" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(a)(b)\\2", "abb"));
    try std.testing.expect(!try regex.isMatch(allocator, "(a)(b)\\2", "abc"));
}

test "group: backreference with different content" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "(ab)+\\1", "ababab"));
    // Prefix match: "(ab)+\\1" matches "abab" at position 0; does not need to consume whole string.
    try std.testing.expect(try regex.isMatch(allocator, "(ab)+\\1", "ababc"));
}

test "branch reset group: (?|...|...)" {
    const allocator = std.testing.allocator;
    // (?|(a)|(b)|(c)) - all branches use group 1
    var re = try regex.compile(allocator, "(?|(a)|(b)|(c))");
    defer re.deinit();

    var result1 = try re.find("a");
    defer if (result1) |*r| r.deinit();
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualStrings("a", result1.?.getGroup("a", 1).?);

    var result2 = try re.find("b");
    defer if (result2) |*r| r.deinit();
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings("b", result2.?.getGroup("b", 1).?);

    var result3 = try re.find("c");
    defer if (result3) |*r| r.deinit();
    try std.testing.expect(result3 != null);
    try std.testing.expectEqualStrings("c", result3.?.getGroup("c", 1).?);
}

test "branch reset group: with backref" {
    const allocator = std.testing.allocator;
    // (?|(a)|(b))\1 matches "aa" or "bb"
    var re = try regex.compile(allocator, "^(?|(a)|(b))\\1$");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("aa"));
    try std.testing.expect(try re.isMatch("bb"));
    try std.testing.expect(!try re.isMatch("ab"));
}

test "branch reset group: nested groups" {
    const allocator = std.testing.allocator;
    // (?|(a(x))|(b(y))) - group 1 is outer, group 2 is inner in both branches
    var re = try regex.compile(allocator, "(?|(a(x))|(b(y)))");
    defer re.deinit();

    var result1 = try re.find("ax");
    defer if (result1) |*r| r.deinit();
    try std.testing.expect(result1 != null);
    try std.testing.expectEqualStrings("ax", result1.?.getGroup("ax", 1).?);
    try std.testing.expectEqualStrings("x", result1.?.getGroup("ax", 2).?);

    var result2 = try re.find("by");
    defer if (result2) |*r| r.deinit();
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings("by", result2.?.getGroup("by", 1).?);
    try std.testing.expectEqualStrings("y", result2.?.getGroup("by", 2).?);
}
