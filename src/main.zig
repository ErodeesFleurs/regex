const std = @import("std");
const Io = std.Io;
const Regex = @import("regex.zig").Regex;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 3) {
        std.debug.print("Usage: regex <pattern> <text>\n", .{});
        std.debug.print("  pattern: 正则表达式模式\n", .{});
        std.debug.print("  text:    要匹配的文本\n", .{});
        return;
    }

    const pattern = args[1];
    const text = args[2];

    var regex = Regex.compile(arena, pattern) catch |err| {
        std.debug.print("Error compiling regex: {s}\n", .{@errorName(err)});
        return;
    };
    defer regex.deinit();

    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // 尝试匹配
    const matched = try regex.isMatch(text);
    if (matched) {
        try stdout_writer.print("Match: YES\n", .{});

        // 查找匹配位置
        var result = try regex.find(text);
        if (result) |*r| {
            defer r.deinit();
            if (r.getGroup(text, 0)) |full_match| {
                try stdout_writer.print("Full match: \"{s}\"\n", .{full_match});
            }
        }
    } else {
        try stdout_writer.print("Match: NO\n", .{});
    }

    try stdout_writer.flush();
}

test "main test" {
    // 这里可以添加集成测试
}
