const std = @import("std");
const regex = @import("../root.zig");
const RegexOptions = @import("../options.zig").RegexOptions;

/// Check that pattern matches text.
pub fn expectMatch(pattern: []const u8, text: []const u8) !void {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, pattern, text));
}

/// Check that pattern does NOT match text.
pub fn expectNoMatch(pattern: []const u8, text: []const u8) !void {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, pattern, text));
}

/// Check that pattern with options matches text.
pub fn expectMatchOpts(pattern: []const u8, text: []const u8, opts: RegexOptions) !void {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, pattern, opts);
    defer re.deinit();
    try std.testing.expect(try re.isMatch(text));
}

/// Check that pattern with options does NOT match text.
pub fn expectNoMatchOpts(pattern: []const u8, text: []const u8, opts: RegexOptions) !void {
    const allocator = std.testing.allocator;
    var re = try regex.Regex.compileWithOptions(allocator, pattern, opts);
    defer re.deinit();
    try std.testing.expect(!try re.isMatch(text));
}
