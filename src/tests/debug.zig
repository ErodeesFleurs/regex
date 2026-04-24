const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;
const Vm = @import("vm.zig").Vm;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // 测试 \d+
    std.debug.print("Testing \\d+:\n", .{});
    var parser = Parser.init(allocator, "\\d+");
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
    
    var vm = Vm.init(allocator, bytecode);
    const matched = try vm.match("123");
    std.debug.print("Match '123': {}\n", .{matched});
}
