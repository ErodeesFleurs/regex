const std = @import("std");
const regex = @import("../root.zig");

// Grapheme cluster (\X) tests.

test "grapheme cluster: single ASCII char" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("a"));
    try std.testing.expect(try re.isMatch("A"));
    try std.testing.expect(!try re.isMatch(""));
}

test "grapheme cluster: single Unicode char" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("中"));
    try std.testing.expect(try re.isMatch("é"));
}

test "grapheme cluster: combining marks" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "^\\X$");
    defer re.deinit();
    // e + combining acute accent (U+0065 U+0301)
    try std.testing.expect(try re.isMatch("e\u{0301}"));
    // Should NOT match just "e" as a full grapheme cluster with the ^$ anchors
    // Actually, "e" alone IS a valid grapheme cluster
    try std.testing.expect(try re.isMatch("e"));
}

test "grapheme cluster: CR LF" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X");
    defer re.deinit();
    // \r\n is treated as a single grapheme cluster
    try std.testing.expect(try re.isMatch("\r\n"));
}

test "grapheme cluster: multiple clusters" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X+");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("中文字"));
}

test "grapheme cluster: find" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X");
    defer re.deinit();
    var result = try re.find("ab");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(@as(usize, 0), r.start);
        try std.testing.expectEqual(@as(usize, 1), r.end);
    } else {
        try std.testing.expect(false);
    }
}

test "grapheme cluster: find combining sequence" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X");
    defer re.deinit();
    // e + combining acute accent
    const text = "e\u{0301}";
    var result = try re.find(text);
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(@as(usize, 0), r.start);
        try std.testing.expectEqual(@as(usize, 3), r.end); // 1 byte for 'e' + 2 bytes for U+0301
    } else {
        try std.testing.expect(false);
    }
}

test "grapheme cluster: alternation" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X|\\d+");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("a"));
    try std.testing.expect(try re.isMatch("123"));
}

test "grapheme cluster: quantifier" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "\\X{3}");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(!try re.isMatch("ab"));
}
