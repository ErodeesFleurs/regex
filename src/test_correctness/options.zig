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
    try std.testing.expect(!try re1.isMatch("a\nb"));

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
    try std.testing.expect(try re2.isMatch("x\nhello\ny"));
}

test "options: default is case sensitive" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "hello", "hello"));
    try std.testing.expect(!try regex.isMatch(allocator, "hello", "HELLO"));
}
