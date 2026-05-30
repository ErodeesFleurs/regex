const std = @import("std");
const regex = @import("../root.zig");

// findAll tests

fn expectFindAll(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, expected: []const []const u8) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
    var results = try re.findAll(text);
    defer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }
    try std.testing.expectEqual(expected.len, results.items.len);
    for (expected, results.items) |exp, result| {
        const match = result.getGroup(text, 0).?;
        try std.testing.expectEqualStrings(exp, match);
    }
}

test "findAll: simple literal" {
    const allocator = std.testing.allocator;
    try expectFindAll(allocator, "a", "aabbaa", &.{ "a", "a", "a", "a" });
    try expectFindAll(allocator, "ab", "abab", &.{ "ab", "ab" });
}

test "findAll: quantifier" {
    const allocator = std.testing.allocator;
    try expectFindAll(allocator, "a+", "aabbaaa", &.{ "aa", "aaa" });
}

test "findAll: no match" {
    const allocator = std.testing.allocator;
    try expectFindAll(allocator, "x", "abc", &.{});
}

test "findAll: single match" {
    const allocator = std.testing.allocator;
    try expectFindAll(allocator, "hello", "hello world", &.{"hello"});
}

test "findAll: capture groups" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(\\w+)-(\\d+)");
    defer re.deinit();
    var results = try re.findAll("foo-123 bar-456");
    defer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }
    try std.testing.expectEqual(2, results.items.len);
    try std.testing.expectEqualStrings("foo", results.items[0].getGroup("foo-123 bar-456", 1).?);
    try std.testing.expectEqualStrings("123", results.items[0].getGroup("foo-123 bar-456", 2).?);
    try std.testing.expectEqualStrings("bar", results.items[1].getGroup("foo-123 bar-456", 1).?);
    try std.testing.expectEqualStrings("456", results.items[1].getGroup("foo-123 bar-456", 2).?);
}

test "findAll: zero-width matches" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "^");
    defer re.deinit();
    var results = try re.findAll("abc");
    defer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }
    try std.testing.expectEqual(1, results.items.len);
}

// replaceAll tests

fn expectReplaceAll(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, replacement: []const u8, expected: []const u8) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
    const result = try re.replaceAll(text, replacement);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "replaceAll: simple literal" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a", "aabbaa", "X", "XXbbXX");
    try expectReplaceAll(allocator, "ab", "abab", "X", "XX");
}

test "replaceAll: quantifier" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a+", "aabbaaa", "X", "XbbX");
}

test "replaceAll: no match" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "x", "abc", "X", "abc");
}

test "replaceAll: with capture groups" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "(a+)", "aabbaaa", "[$1]", "[aa]bb[aaa]");
}

test "replaceAll: with full match $&" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a+", "aabbaaa", "[$&]", "[aa]bb[aaa]");
}

test "replaceAll: with backtick $`" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a+", "aabbaaa", "($`)", "()bb(aabb)");
}

test "replaceAll: with quote $'" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a+", "aabbaaa", "($')", "(bbaaa)bb()");
}

test "replaceAll: $$ escape" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a+", "aabbaaa", "$$", "$bb$");
}

test "replaceAll: empty replacement" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "a+", "aabbaaa", "", "bb");
}

test "replaceAll: delimiter at boundaries" {
    const allocator = std.testing.allocator;
    try expectReplaceAll(allocator, "^", "abc", "X", "Xabc");
    try expectReplaceAll(allocator, "$", "abc", "X", "abcX");
}

// findIter tests

test "findIter: simple literal" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a");
    defer re.deinit();

    var iter = re.findIter("aabbaa");
    var count: usize = 0;
    while (try iter.next()) |match| {
        var result = match;
        defer result.deinit();
        count += 1;
    }
    try std.testing.expectEqual(4, count);
}

test "findIter: quantifier" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a+");
    defer re.deinit();

    var iter = re.findIter("aabbaaa");
    var results: [2][]const u8 = undefined;
    var idx: usize = 0;
    while (try iter.next()) |match| : (idx += 1) {
        var result = match;
        defer result.deinit();
        results[idx] = result.getGroup("aabbaaa", 0).?;
    }
    try std.testing.expectEqualStrings("aa", results[0]);
    try std.testing.expectEqualStrings("aaa", results[1]);
}

test "findIter: no match" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "x");
    defer re.deinit();

    var iter = re.findIter("abc");
    try std.testing.expect(try iter.next() == null);
}

test "findIter: capture groups" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(\\w+)-(\\d+)");
    defer re.deinit();

    var iter = re.findIter("foo-123 bar-456");
    var count: usize = 0;
    while (try iter.next()) |match| {
        var result = match;
        defer result.deinit();
        count += 1;
        if (count == 1) {
            try std.testing.expectEqualStrings("foo", result.getGroup("foo-123 bar-456", 1).?);
            try std.testing.expectEqualStrings("123", result.getGroup("foo-123 bar-456", 2).?);
        } else if (count == 2) {
            try std.testing.expectEqualStrings("bar", result.getGroup("foo-123 bar-456", 1).?);
            try std.testing.expectEqualStrings("456", result.getGroup("foo-123 bar-456", 2).?);
        }
    }
    try std.testing.expectEqual(2, count);
}

// replaceAllFn tests

test "replaceAllFn: uppercase match" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\w+");
    defer re.deinit();

    const result = try re.replaceAllFn("hello world", struct {
        pub fn replace(match: []const u8, _: regex.MatchResult) []const u8 {
            _ = match;
            return "WORD";
        }
    }.replace);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("WORD WORD", result);
}

test "replaceAllFn: wrap in brackets" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\d+");
    defer re.deinit();

    const result = try re.replaceAllFn("abc123def456", struct {
        pub fn replace(match: []const u8, _: regex.MatchResult) []const u8 {
            _ = match;
            return "[NUM]";
        }
    }.replace);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc[NUM]def[NUM]", result);
}

test "replaceAllFn: no match" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "x+");
    defer re.deinit();

    const result = try re.replaceAllFn("abc", struct {
        pub fn replace(match: []const u8, _: regex.MatchResult) []const u8 {
            _ = match;
            return "X";
        }
    }.replace);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("abc", result);
}
