const std = @import("std");
const Io = std.Io;
const regex = @import("regex");

const Benchmark = struct {
    name: []const u8,
    pattern: []const u8,
    text: []const u8,
    iterations: usize,
};

const benchmarks = [_]Benchmark{
    .{ .name = "literal short", .pattern = "hello", .text = "hello world", .iterations = 10000 },
    .{ .name = "alternation", .pattern = "foo|bar|baz|qux", .text = "qux qux qux", .iterations = 10000 },
    .{ .name = "star", .pattern = "a*b", .text = "a" ** 20 ++ "b", .iterations = 5000 },
    .{ .name = "plus", .pattern = "a+b", .text = "a" ** 20 ++ "b", .iterations = 5000 },
    .{ .name = "quantifier {10,20}", .pattern = "a{10,20}b", .text = "a" ** 15 ++ "b", .iterations = 10000 },
    .{ .name = "group", .pattern = "(abc)+", .text = "abc" ** 5, .iterations = 10000 },
    .{ .name = "char class [a-z]+", .pattern = "[a-z]+", .text = "abcdefghijklmnopqrstuvwxyz", .iterations = 10000 },
    .{ .name = "digit \\d+", .pattern = "\\d+", .text = "12345678901234567890", .iterations = 10000 },
    .{ .name = "word \\w+", .pattern = "\\w+", .text = "hello_world_123", .iterations = 10000 },
    .{ .name = "unicode property \\p{Han}", .pattern = "\\p{Han}+", .text = "中文字符测试", .iterations = 5000 },
    .{ .name = "unicode case insensitive", .pattern = "café", .text = "CAFÉ", .iterations = 5000 },
    .{ .name = "grapheme cluster \\X", .pattern = "\\X+", .text = "e\u{0301}" ** 5, .iterations = 5000 },
    .{ .name = "lookahead (?=...)", .pattern = "(?=foo)foo", .text = "foobar", .iterations = 10000 },
    .{ .name = "possessive a*+b", .pattern = "a*+b", .text = "a" ** 20 ++ "b", .iterations = 10000 },
};

fn getMonotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn runBenchmark(allocator: std.mem.Allocator, b: Benchmark, writer: *Io.Writer) !void {
    // Warmup
    {
        var re = try regex.compile(allocator, b.pattern);
        defer re.deinit();
        _ = try re.isMatch(b.text);
    }

    // Measure compile time
    const compile_start = getMonotonicNs();
    var re = try regex.compile(allocator, b.pattern);
    const compile_ns = getMonotonicNs() - compile_start;
    defer re.deinit();

    // Measure match time
    const match_start = getMonotonicNs();
    for (0..b.iterations) |_| {
        _ = try re.isMatch(b.text);
    }
    const total_match_ns = getMonotonicNs() - match_start;
    const avg_match_ns = @divFloor(total_match_ns, b.iterations);

    // Measure find time
    const find_start = getMonotonicNs();
    for (0..b.iterations) |_| {
        var result = try re.find(b.text);
        if (result) |*r| r.deinit();
    }
    const total_find_ns = getMonotonicNs() - find_start;
    const avg_find_ns = @divFloor(total_find_ns, b.iterations);

    try writer.print("{s:30} | compile: {d:>8} us | isMatch: {d:>6} ns | find: {d:>6} ns\n", .{
        b.name,
        @divFloor(compile_ns, 1000),
        avg_match_ns,
        avg_find_ns,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const allocator = debug_alloc.allocator();

    try stdout_writer.print("\n=== Regex Benchmark ===\n", .{});
    try stdout_writer.print("{s:30} | {s:>17} | {s:>14} | {s:>14}\n", .{ "Pattern", "Compile (us)", "isMatch (ns)", "find (ns)" });
    try stdout_writer.print("{s}\n", .{"-" ** 80});

    for (benchmarks) |b| {
        runBenchmark(allocator, b, stdout_writer) catch |err| {
            try stdout_writer.print("{s:30} | ERROR: {s}\n", .{ b.name, @errorName(err) });
        };
    }

    try stdout_writer.print("{s}\n", .{"-" ** 80});
    try stdout_writer.flush();
}
