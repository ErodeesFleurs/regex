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
    
    // 从位置 2 开始匹配
    const result = try vm.exec("aabbaaa", 2);
    std.debug.print("Match from 2: matched={}, start={}, end={}\n", .{result.matched, result.start, result.end});
}
