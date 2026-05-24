const std = @import("std");
const regex = @import("../root.zig");

// Word boundary correctness tests.

test "word boundary: \\b simple" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\bword\\b", "word"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\bword\\b", "sword"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\bword\\b", "words"));
}

test "word boundary: \\b at start" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\bhello", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\bhello", "ahello"));
}

test "word boundary: \\b at end" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "hello\\b", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "hello\\b", "helloa"));
}

test "word boundary: \\B simple" {
    const allocator = std.testing.allocator;
    // Prefix match: at position 0 of "aworda" there IS a word boundary (start -> 'a'),
    // so \\B fails. Use find to locate the pattern at position 1.
    try std.testing.expect(!try regex.isMatch(allocator, "\\Bword\\B", "aworda"));
    var find_result = try regex.find(allocator, "\\Bword\\B", "aworda");
    if (find_result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
    try std.testing.expect(!try regex.isMatch(allocator, "\\Bword\\B", "word"));
}

test "word boundary: \\b with digits" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\b123\\b", "123"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\b123\\b", "a123"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\b123\\b", "123b"));
}

test "word boundary: \\b empty string" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "\\b", ""));
    // \b at position 0 with no word char after is not a boundary
}

test "word boundary: \\b underscore" {
    const allocator = std.testing.allocator;
    // underscore is a word char. After 'a' (word) a word boundary requires a non-word
    // char next, but '_' is a word char, so "a\\b_" can never match.
    try std.testing.expect(!try regex.isMatch(allocator, "a\\b_", "a_"));
    try std.testing.expect(!try regex.isMatch(allocator, "a\\b_", "a _"));
}

test "word boundary: unicode letters" {
    const allocator = std.testing.allocator;
    // Unicode letters (e.g., Greek, Cyrillic) should be treated as word characters
    var re1 = try regex.Regex.compile(allocator, "\\bαβγ\\b");
    defer re1.deinit();
    try std.testing.expect(try re1.isMatch("αβγ"));
    try std.testing.expect(!try re1.isMatch("αβγδ"));

    var re2 = try regex.Regex.compile(allocator, "\\bпривет\\b");
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch("привет"));
    try std.testing.expect(try re2.isMatch("привет!"));
    try std.testing.expect(!try re2.isMatch("приветы"));
}

test "word boundary: mixed ascii and unicode" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "\\bcafé\\b");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("café"));
    try std.testing.expect(try re.isMatch("café!"));
    try std.testing.expect(!try re.isMatch("écafé"));
    try std.testing.expect(!try re.isMatch("caféé"));
}

test "word boundary: chinese characters" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "\\b你好\\b");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("你好"));
    try std.testing.expect(!try re.isMatch("你好世界"));
}

test "word boundary: emoji" {
    const allocator = std.testing.allocator;
    // Emoji are not word characters, so there should be a boundary between word and emoji
    var re = try regex.Regex.compile(allocator, "\\bhello\\b");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));

    var result1 = try re.find("hello😀");
    if (result1) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }

    var result2 = try re.find("😀hello");
    if (result2) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}
