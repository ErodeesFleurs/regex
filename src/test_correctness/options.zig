const std = @import("std");
const regex = @import("../root.zig");

// RegexOptions correctness tests.

test "options: case insensitive" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "hello", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));
    try std.testing.expect(try re.isMatch("HELLO"));
    try std.testing.expect(try re.isMatch("HeLLo"));
}

test "options: dot matches newline" {
    const allocator = std.testing.allocator;
    var re1 = try regex.Regex.compileWithOptions(allocator, ".*", .{ .dot_matches_newline = false });
    defer re1.deinit();
    // Prefix match: ".*" matches empty string at position 0 regardless of newline handling.
    try std.testing.expect(try re1.isMatch("a\nb"));

    var re2 = try regex.Regex.compileWithOptions(allocator, ".*", .{ .dot_matches_newline = true });
    defer re2.deinit();
    try std.testing.expect(try re2.isMatch("a\nb"));
}

test "options: multiline anchors" {
    const allocator = std.testing.allocator;
    var re1 = try regex.Regex.compileWithOptions(allocator, "^hello$", .{ .multiline = false });
    defer re1.deinit();
    try std.testing.expect(!try re1.isMatch("x\nhello\ny"));

    var re2 = try regex.Regex.compileWithOptions(allocator, "^hello$", .{ .multiline = true });
    defer re2.deinit();
    // Prefix match: isMatch only tries position 0; "x\nhello\ny" does not start with "hello".
    try std.testing.expect(!try re2.isMatch("x\nhello\ny"));

    var find_result = try re2.find("x\nhello\ny");
    if (find_result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}

test "options: case insensitive char class" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "[a-z]+", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("abc"));
    try std.testing.expect(try re.isMatch("ABC"));
}

test "options: case insensitive backref" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(abc)\\1", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("abcabc"));
    try std.testing.expect(try re.isMatch("abcABC"));
    try std.testing.expect(try re.isMatch("ABCabc"));
}

test "options: default is case sensitive" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "hello", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "hello", "HELLO"));
}

test "options: unicode case insensitive literal" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "café", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("café"));
    try std.testing.expect(try re.isMatch("CAFÉ"));
    try std.testing.expect(try re.isMatch("CafÉ"));
}

test "options: unicode case insensitive greek" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "αβγ", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("αβγ"));
    try std.testing.expect(try re.isMatch("ΑΒΓ"));
    try std.testing.expect(try re.isMatch("ΑβΓ"));
}

test "options: unicode case insensitive cyrillic" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "привет", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("привет"));
    try std.testing.expect(try re.isMatch("ПРИВЕТ"));
    try std.testing.expect(try re.isMatch("ПриВет"));
}

test "options: unicode case insensitive find" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "École", .{ .case_sensitive = false });
    defer re.deinit();
    var result = try re.find("une école à PARIS");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqual(4, r.start);
        try std.testing.expectEqual(10, r.end);
    } else {
        try std.testing.expect(false);
    }
}

test "options: unicode case insensitive backref" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(café)\\1", .{ .case_sensitive = false });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("cafécafé"));
    try std.testing.expect(try re.isMatch("caféCAFÉ"));
    try std.testing.expect(try re.isMatch("CAFÉcafé"));
}

test "options: global inline flag (?i)" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?i)hello");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));
    try std.testing.expect(try re.isMatch("HELLO"));
    try std.testing.expect(try re.isMatch("HeLLo"));
}

test "options: global inline flag (?m)" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?m)^hello$");
    defer re.deinit();
    try std.testing.expect(!try re.isMatch("x\nhello\ny"));
    var result = try re.find("x\nhello\ny");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
}

test "options: global inline flag (?s)" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?s)a.b");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("a\nb"));
}

test "options: scoped inline flag (?i:) restores" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?i:hello)WORLD");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("helloWORLD"));
    try std.testing.expect(try re.isMatch("HELLOWORLD"));
    try std.testing.expect(!try re.isMatch("helloworld"));
}

test "options: combined global inline flag (?im)" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?im)^hello$");
    defer re.deinit();
    try std.testing.expect(!try re.isMatch("x\nhello\ny"));
    var result = try re.find("x\nhello\ny");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
    } else {
        try std.testing.expect(false);
    }
    try std.testing.expect(try re.isMatch("HELLO"));
    try std.testing.expect(try re.isMatch("hello"));
}

test "options: free-spacing via RegexOptions" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "h e l l o", .{ .free_spacing = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));
}

test "options: free-spacing with comment" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "hello # this is a comment\nworld", .{ .free_spacing = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("helloworld"));
}

test "options: free-spacing preserves char class whitespace" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "[a z]", .{ .free_spacing = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("a"));
    try std.testing.expect(try re.isMatch("z"));
    try std.testing.expect(try re.isMatch(" "));
    try std.testing.expect(!try re.isMatch("b"));
}

test "options: global inline flag (?x)" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?x)h e l l o");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));
}

test "options: global inline flag (?x) with comment" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(?x)hello # match greeting\nworld");
    defer re.deinit();
    try std.testing.expect(try re.isMatch("helloworld"));
}

test "exec: match from position" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "world");
    defer re.deinit();

    var result = try re.exec("hello world", 0);
    defer result.deinit();
    try std.testing.expect(!result.matched);

    var result2 = try re.exec("hello world", 6);
    defer result2.deinit();
    try std.testing.expect(result2.matched);
    try std.testing.expectEqual(6, result2.start);
    try std.testing.expectEqual(11, result2.end);
}

test "exec: match with captures from position" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "(\\w+) (\\w+)");
    defer re.deinit();

    var result = try re.exec("hello world foo bar", 6);
    defer result.deinit();
    try std.testing.expect(result.matched);
    try std.testing.expectEqual(6, result.start);
    try std.testing.expectEqual(15, result.end);
}

test "exec: no match beyond end" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compile(allocator, "hello");
    defer re.deinit();

    var result = try re.exec("hello", 5);
    defer result.deinit();
    try std.testing.expect(!result.matched);
}
