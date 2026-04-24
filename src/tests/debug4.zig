const std = @import("std");
const Regex = @import("regex.zig").Regex;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();
    
    // 测试 find
    var result = try regex.find("aabbaaa");
    if (result) |*r| {
        std.debug.print("Find: start={}, end={}\n", .{r.start, r.end});
        r.deinit();
    } else {
        std.debug.print("Find: no match\n", .{});
    }
    
    // 测试 match
    const matched = try regex.isMatch("aabbaaa");
    std.debug.print("isMatch: {}\n", .{matched});
}
