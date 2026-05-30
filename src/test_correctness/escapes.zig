const std = @import("std");
const regex = @import("../root.zig");

// Hex and Unicode escape correctness tests.

test "escape: \\xNN hex" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x41", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x42", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\x41", "B"));
}

test "escape: \\xNN lowercase hex" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x0a", "\n"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x0d", "\r"));
}

test "escape: \\uNNNN unicode" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\u0041", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\u0042", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\u0041", "B"));
}

test "escape: hex in char class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[\\x41-\\x43]", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\x41-\\x43]", "D"));
}

test "escape: \\x{hhhh} variable hex" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x{41}", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x{1F600}", "\u{1F600}"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\x{41}", "B"));
}

test "escape: \\x{hhhh} emoji" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\x{2764}", "\u{2764}"));
    try std.testing.expect(try regex.isMatch(allocator, "\\x{1F525}", "\u{1F525}"));
}

test "escape: \\a bell" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\a", "\x07"));
}

test "escape: \\e escape" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\e", "\x1B"));
}

test "escape: \\f form feed" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\f", "\x0C"));
}

test "escape: \\v vertical tab" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\v", "\x0B"));
}

test "escape: \\N{U+HHHH} unicode code point" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\N{U+0041}", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\N{U+03B1}", "\u{03B1}"));
    try std.testing.expect(try regex.isMatch(allocator, "\\N{U+1F600}", "\u{1F600}"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\N{U+0041}", "B"));
}

test "escape: \\o{NNN} octal" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\o{101}", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\o{102}", "B"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\o{101}", "B"));
    try std.testing.expect(try regex.isMatch(allocator, "\\o{377}", "\u{00FF}"));
}

test "escape: \\R newline sequence" {
    const allocator = std.testing.allocator;
    // Single-byte line endings
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\n"));
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\r"));
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\x0B"));
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\x0C"));
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\x85"));
    // CRLF sequence (should match as a single unit)
    try std.testing.expect(try regex.isMatch(allocator, "^\\R$", "\r\n"));
    // Unicode line separators
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\u{2028}"));
    try std.testing.expect(try regex.isMatch(allocator, "\\R", "\u{2029}"));
    // Non-newline characters should not match
    try std.testing.expect(!try regex.isMatch(allocator, "\\R", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\R", " "));
}

test "escape: \\R in alternation" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a\\Rb");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("a\nb"));
    try std.testing.expect(try re.isMatch("a\r\nb"));
    try std.testing.expect(!try re.isMatch("ab"));
}

test "escape: \\h horizontal whitespace" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\h", "\t"));
    try std.testing.expect(try regex.isMatch(allocator, "\\h", " "));
    try std.testing.expect(!try regex.isMatch(allocator, "\\h", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\h", "A"));
}

test "escape: \\H not horizontal whitespace" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\H", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\H", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\H", "\t"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\H", " "));
}

test "escape: \\K reset match start" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "foo\\Kbar");
    defer re.deinit();

    var result = try re.find("foobar");
    defer if (result) |*r| r.deinit();

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.matched);
    // \\K resets match start to position 3 (after "foo")
    try std.testing.expectEqual(3, result.?.start);
    try std.testing.expectEqual(6, result.?.end);
    try std.testing.expectEqualStrings("bar", result.?.getGroup("foobar", 0).?);
}

test "escape: \\K with capture" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(foo)\\K(bar)");
    defer re.deinit();

    var result = try re.find("foobar");
    defer if (result) |*r| r.deinit();

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.matched);
    // Full match starts after \\K
    try std.testing.expectEqual(3, result.?.start);
    try std.testing.expectEqual(6, result.?.end);
    // Group 1 still captures "foo"
    try std.testing.expectEqualStrings("foo", result.?.getGroup("foobar", 1).?);
    // Group 2 captures "bar"
    try std.testing.expectEqualStrings("bar", result.?.getGroup("foobar", 2).?);
}

test "comment: (?#...)" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "a(?#comment)b", "ab"));
    try std.testing.expect(try regex.isMatch(allocator, "(?#start)a(?#middle)b(?#end)", "ab"));
    try std.testing.expect(!try regex.isMatch(allocator, "a(?#comment)b", "ac"));
}

test "escape: \\h in char class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[\\h]", "\t"));
    try std.testing.expect(try regex.isMatch(allocator, "[\\h]", " "));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\h]", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\h]", "A"));
}

test "escape: \\H in char class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[\\H]", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "[\\H]", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\H]", "\t"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\H]", " "));
}

test "escape: \\N not newline" {
    const allocator = std.testing.allocator;
    // \\N matches any character except \n (default newline)
    try std.testing.expect(try regex.isMatch(allocator, "\\N", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\N", " "));
    try std.testing.expect(try regex.isMatch(allocator, "\\N", "\r")); // \r is not \n
    try std.testing.expect(!try regex.isMatch(allocator, "\\N", "\n")); // \n is newline
}

test "escape: \\N does not match newline variants" {
    const allocator = std.testing.allocator;
    // \\N only excludes \n (LF)
    try std.testing.expect(!try regex.isMatch(allocator, "^\\N$", "\n"));
    try std.testing.expect(try regex.isMatch(allocator, "^\\N$", "\r"));
    try std.testing.expect(try regex.isMatch(allocator, "^\\N$", "A"));
}

test "escape: \\N with dotall" {
    const allocator = std.testing.allocator;
    // \\N should not match newlines even with dotall=true
    var re = try regex.Regex.compileWithOptions(allocator, "\\N", .{ .dot_matches_newline = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("A"));
    try std.testing.expect(!try re.isMatch("\n"));
}

test "escape: \\V not vertical whitespace" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\V", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\V", " "));
    try std.testing.expect(!try regex.isMatch(allocator, "\\V", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\V", "\r"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\V", "\x0B"));
}

test "escape: \\N vs \\V distinction" {
    const allocator = std.testing.allocator;
    // \\N matches \r (because \r is not \n)
    try std.testing.expect(try regex.isMatch(allocator, "\\N", "\r"));
    // \\V does not match \r (because \r is vertical whitespace)
    try std.testing.expect(!try regex.isMatch(allocator, "\\V", "\r"));
    // Both match normal chars
    try std.testing.expect(try regex.isMatch(allocator, "\\N", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\V", "A"));
    // Both don't match \n
    try std.testing.expect(!try regex.isMatch(allocator, "\\N", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\V", "\n"));
}

test "escape: [\\b] backspace in char class" {
    const allocator = std.testing.allocator;
    // \\b inside char class should match backspace (0x08), not word boundary
    try std.testing.expect(try regex.isMatch(allocator, "[\\b]", "\x08"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\b]", "b"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\b]", "A"));
}

