const std = @import("std");
const Vm = @import("vm.zig").Vm;
const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    var parser = Parser.init(allocator, "a+");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = Compiler.init(allocator);
    const bytecode = try compiler.compile(ast.?);
    
    var vm = Vm.init(allocator, bytecode);
    
    // 测试从不同位置匹配
    for (0..7) |i| {
        const result = try vm.exec("aabbaaa", i);
        std.debug.print("Match from {}: matched={}, start={}, end={}\n", .{i, result.matched, result.start, result.end});
    }
}
