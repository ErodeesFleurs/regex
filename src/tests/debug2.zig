const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("Testing a{{2,3}}:\n", .{});
    var parser = Parser.init(allocator, "a{2,3}");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = Compiler.init(allocator);
    const bytecode = try compiler.compile(ast.?);
    
    std.debug.print("Bytecode instructions:\n", .{});
    for (bytecode.instructions.items, 0..) |inst, i| {
        std.debug.print("  {}: {s}", .{ i, @tagName(inst.opcode) });
        if (inst.char) |c| {
            std.debug.print(" ({c})", .{c});
        }
        if (inst.target) |t| {
            std.debug.print(" -> {}", .{t});
        }
        std.debug.print("\n", .{});
    }
}
