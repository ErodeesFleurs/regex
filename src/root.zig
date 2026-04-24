const std = @import("std");
const Io = std.Io;

// 导出公共 API
pub const Regex = @import("regex.zig").Regex;
pub const MatchResult = @import("vm.zig").MatchResult;
pub const RegexOptions = @import("options.zig").RegexOptions;
pub const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const Parser = @import("parser.zig").Parser;
pub const Compiler = @import("compiler.zig").Compiler;
pub const Vm = @import("vm.zig").Vm;
pub const Bytecode = @import("bytecode.zig").Bytecode;
pub const Instruction = @import("bytecode.zig").Instruction;
pub const OpCode = @import("bytecode.zig").OpCode;

/// 便捷的编译函数
pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
    return Regex.compile(allocator, pattern);
}

/// 便捷的匹配函数
pub fn isMatch(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !bool {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.isMatch(text);
}

/// 便捷的查找函数
pub fn find(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8) !?MatchResult {
    var regex = try Regex.compile(allocator, pattern);
    defer regex.deinit();
    return try regex.find(text);
}

test "root basic usage" {
    const allocator = std.testing.allocator;
    
    // 测试便捷函数
    try std.testing.expect(try isMatch(allocator, "hello", "hello"));
    try std.testing.expect(!try isMatch(allocator, "hello", "world"));
    
    // 测试 Regex 对象
    var regex = try compile(allocator, "a+");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("a"));
    try std.testing.expect(try regex.isMatch("aaa"));
}
