const std = @import("std");
const regex = @import("../root.zig");

// Absolute anchor correctness tests.

test "anchor: \\A absolute start" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\Aabc", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\Aabc", "xabc"));
    // \\A always matches at position 0 regardless of multiline.
    var re = try regex.Regex.compileWithOptions(allocator, "\\Ahello", .{ .multiline = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));
    try std.testing.expect(!try re.isMatch("x\nhello"));
}

test "anchor: \\z absolute end" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "abc\\z", "abc"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc\\z", "abcx"));
    // \\z always matches only at end regardless of multiline.
    var re = try regex.Regex.compileWithOptions(allocator, "hello\\z", .{ .multiline = true });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("hello"));
    try std.testing.expect(!try re.isMatch("hello\nworld"));
}

test "anchor: \\Z end allowing trailing newline" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "abc\\Z", "abc"));
    try std.testing.expect(try regex.isMatch(allocator, "abc\\Z", "abc\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc\\Z", "abc\n\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "abc\\Z", "abcx"));
}
