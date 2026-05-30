const std = @import("std");

// Public API exports
pub const Regex = @import("regex.zig").Regex;
comptime {
    _ = @import("test_correctness/root.zig");
}
pub const MatchResult = @import("vm.zig").MatchResult;
pub const RegexOptions = @import("options.zig").RegexOptions;

// Internal implementation details (not part of public API)
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;
const Vm = @import("vm.zig").Vm;
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;

/// Convenience function to compile a regex pattern.
/// Note: for repeated use, compile once and reuse the Regex object.
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
    return Regex.compile(allocator, pattern);
}

/// Convenience function to test if a pattern matches text.
/// Note: compiles the pattern on every call; reuse Regex for performance.
pub fn isMatch(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.isMatch(text);
}

/// Convenience function to find the first match of a pattern in text.
/// Note: compiles the pattern on every call; reuse Regex for performance.
pub fn find(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !?MatchResult {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.find(text);
}

/// Convenience function to test if a pattern matches the entire text.
/// Note: compiles the pattern on every call; reuse Regex for performance.
pub fn isMatchFull(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.isMatchFull(text);
}

/// Convenience function to execute a match from a given position.
/// Note: compiles the pattern on every call; reuse Regex for performance.
pub fn exec(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, start_pos: usize) !MatchResult {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.exec(text, start_pos);
}

/// Convenience function to find all non-overlapping matches.
/// Note: compiles the pattern on every call; reuse Regex for performance.
pub fn matchAll(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !std.ArrayList([]const u8) {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.matchAll(text);
}

test "root basic usage" {
    const allocator = std.testing.allocator;

    // Test convenience functions
    try std.testing.expect(try isMatch(allocator, "hello", "hello"));
    try std.testing.expect(!try isMatch(allocator, "hello", "world"));

    // Test Regex object reuse
    var regex = try compile(allocator, "a+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}
