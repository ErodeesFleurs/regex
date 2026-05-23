const std = @import("std");
const regex = @import("../root.zig");

// Backtracking protection (max_steps) tests.

test "backtracking protection: default limit prevents hang" {
    const allocator = std.testing.allocator;
    // Default max_steps is 1_000_000, which should prevent catastrophic backtracking
    var re = try regex.Regex.compile(allocator, "(a+)+b");
    defer re.deinit();
    // On a long string of 'a' without trailing 'b', catastrophic backtracking occurs
    // With the default limit, it should return false instead of hanging
    try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "backtracking protection: custom low limit" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(a+)+b", .{ .max_steps = 10000 });
    defer re.deinit();
    try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "backtracking protection: normal match still works with limit" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(a+)+b", .{ .max_steps = 100000 });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("aaab"));
    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(!try re.isMatch("aaa"));
}

test "backtracking protection: nested quantifiers" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(a*)*b", .{ .max_steps = 10000 });
    defer re.deinit();
    // Should not hang on long string of 'a'
    try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "backtracking protection: alternation with quantifier" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(a|aa)+b", .{ .max_steps = 10000 });
    defer re.deinit();
    try std.testing.expect(try re.isMatch("aaab"));
    // Long string of 'a' without 'b'
    try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "backtracking protection: find with limit" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(a+)+b", .{ .max_steps = 10000 });
    defer re.deinit();
    const result = try re.find("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(result == null);
}

test "backtracking protection: lookahead with limit" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(?=(a+)+b)", .{ .max_steps = 10000 });
    defer re.deinit();
    // Long string of 'a' without 'b'
    try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "backtracking protection: lookbehind with limit" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(?<=(a+)+b)", .{ .max_steps = 10000 });
    defer re.deinit();
    // Long string of 'a' without 'b'
    try std.testing.expect(!try re.isMatch("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}

test "backtracking protection: unlimited steps" {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, "(a+)+b", .{ .max_steps = null });
    defer re.deinit();
    // With unlimited steps, normal matches should still work
    try std.testing.expect(try re.isMatch("aaab"));
    try std.testing.expect(!try re.isMatch("aaa"));
}
