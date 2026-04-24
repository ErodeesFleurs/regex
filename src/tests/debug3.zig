const std = @import("std");
const Regex = @import("regex.zig").Regex;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();
    
    const result = try regex.replace("aabbaaa", "X");
    std.debug.print("Result: \"{s}\"\n", .{result});
}
