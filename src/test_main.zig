const std = @import("std");
const Regex = @import("regex.zig").Regex;

pub fn main() !void {
    var re = try Regex.compile(std.heap.page_allocator, "a*");
    defer re.deinit();

    const m = try re.isMatch("");
    std.debug.print("a* matches '': {}\n", .{m});

    const m2 = try re.isMatch("a");
    std.debug.print("a* matches 'a': {}\n", .{m2});

    const m3 = try re.isMatch("aaa");
    std.debug.print("a* matches 'aaa': {}\n", .{m3});

    // Test a?
    var re2 = try Regex.compile(std.heap.page_allocator, "a?");
    defer re2.deinit();

    const m4 = try re2.isMatch("");
    std.debug.print("a? matches '': {}\n", .{m4});
}
