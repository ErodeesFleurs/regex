const std = @import("std");
const regex = @import("../root.zig");

// Anchor (^, $) correctness tests.
// Covers POSIX / PCRE line-anchor semantics.

test "anchor: start of string ^" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^abc", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc", "xabc"));
    try std.testing.expect(try regex.isMatch(allocator, "^abc", "abcx"));
}

test "anchor: end of string $" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "abc$", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc$", "abcx"));
    // Prefix match: "abc$" does not match at position 0 of "xabc".
    try std.testing.expect(!try regex.isMatch(allocator, "abc$", "xabc"));
}

test "anchor: both ^ and $" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^abc$", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc$", "xabc"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc$", "abcx"));
    try std.testing.expect(!try regex.isMatch(allocator, "^abc$", "xabcx"));
}

test "anchor: ^ with empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^", ""));
    try std.testing.expect(try regex.isMatch(allocator, "^a", "a"));
}

test "anchor: $ with empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "$", ""));
    try std.testing.expect(try regex.isMatch(allocator, "a$", "a"));
}

test "anchor: ^$ empty match" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^$", ""));
    try std.testing.expect(!try regex.isMatch(allocator, "^$", "a"));
}

test "anchor: multiple anchors" {
    const allocator = std.testing.allocator;
    // "^a$b$" is impossible (requires end-of-string twice).
    // PCRE semantics: first $ can match before final newline, but here it's strict.
    try std.testing.expect(!try regex.isMatch(allocator, "^a$b$", "ab"));
}

test "anchor: multiline" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "^b$", .{ .multiline = true });
    defer re.deinit();
    // Prefix match: isMatch only tries position 0.
    try std.testing.expect(!try re.isMatch("a\nb\nc"));
    var result = try re.find("a\nb\nc");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("b", "a\nb\nc"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }
}

test "anchor: \\G match start or previous match end" {
    const allocator = std.testing.allocator;
    // \\Gabc on "abcabc" — findIter should match twice because \\G advances
    var re = try regex.Regex.compile(allocator, "\\Gabc");
    defer re.deinit();

    var iter = re.findIter("abcabc");

    var result = try iter.next();
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("abc", "abcabc"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }

    var result2 = try iter.next();
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("abc", "abcabc"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }
}

test "anchor: \\G fails when not at previous match end" {
    const allocator = std.testing.allocator;
    // Pattern: \\Gword — must be at previous match end or start
    var re = try regex.Regex.compile(allocator, "\\Gword");
    defer re.deinit();

    // First match at position 0 fails (starts with "hello")
    var result = try re.find("hello word");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(!r.matched);
    } else {
        // null means no match
    }

    // After failed find, last_match_end is 0, so \\G still at start
    var result2 = try re.find("word hello");
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("word", "word hello"[r.start..r.end]);
    } else {
        try std.testing.expect(false);
    }
}

test "anchor: anchor with alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^(a|b)$", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "^(a|b)$", "b"));
    try std.testing.expect(!try regex.isMatch(allocator, "^(a|b)$", "ab"));
}

test "anchor: anchor with quantifier" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "^a+$", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "^a+$", "aaa"));
    try std.testing.expect(!try regex.isMatch(allocator, "^a+$", ""));
    try std.testing.expect(!try regex.isMatch(allocator, "^a+$", "aaab"));
}
