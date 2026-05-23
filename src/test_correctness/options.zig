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
        try std.testing.expectEqual(@as(usize, 4), r.start);
        try std.testing.expectEqual(@as(usize, 10), r.end);
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
