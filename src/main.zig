const std = @import("std");
const Io = std.Io;
const Regex = @import("regex.zig").Regex;
const RegexOptions = @import("options.zig").RegexOptions;

const CliOptions = struct {
    pattern: []const u8 = "",
    text: []const u8 = "",
    find_all: bool = false,
    replacement: ?[]const u8 = null,
    case_insensitive: bool = false,
    multiline: bool = false,
    dot_matches_newline: bool = false,
    debug: bool = false,
    help: bool = false,
};

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.print("Usage: regex [options] <pattern> <text>\n", .{});
    try writer.print("\nOptions:\n", .{});
    try writer.print("  -a, --find-all              Find all matches\n", .{});
    try writer.print("  -r, --replace <repl>        Replace matches with <repl>\n", .{});
    try writer.print("  -i, --case-insensitive      Case insensitive matching\n", .{});
    try writer.print("  -m, --multiline             Multiline mode (^ and $ match line boundaries)\n", .{});
    try writer.print("  -s, --dot-matches-newline   Dot (.) matches newline\n", .{});
    try writer.print("  -d, --debug                 Dump bytecode instructions\n", .{});
    try writer.print("  -h, --help                  Show this help message\n", .{});
    try writer.print("\nReplacement special sequences:\n", .{});
    try writer.print("  $&    Full match\n", .{});
    try writer.print("  $`    Text before match\n", .{});
    try writer.print("  $'    Text after match\n", .{});
    try writer.print("  $$    Literal $ \n", .{});
    try writer.print("  $1-$9 Capture groups\n", .{});
}

fn parseArgs(args: []const []const u8) !CliOptions {
    var opts = CliOptions{};
    var i: usize = 1;
    
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--find-all")) {
            opts.find_all = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--replace")) {
            i += 1;
            if (i >= args.len) return error.MissingReplacement;
            opts.replacement = args[i];
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--case-insensitive")) {
            opts.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--multiline")) {
            opts.multiline = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--dot-matches-newline")) {
            opts.dot_matches_newline = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--debug")) {
            opts.debug = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.help = true;
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else if (opts.pattern.len == 0) {
            opts.pattern = arg;
        } else if (opts.text.len == 0) {
            opts.text = arg;
        } else {
            return error.TooManyArguments;
        }
    }
    
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;
    
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_file_writer.interface;

    const opts = parseArgs(args) catch |err| {
        switch (err) {
            error.MissingReplacement => try stderr_writer.print("Error: Missing replacement after -r/--replace\n", .{}),
            error.UnknownOption => try stderr_writer.print("Error: Unknown option\n", .{}),
            error.TooManyArguments => try stderr_writer.print("Error: Too many arguments\n", .{}),
        }
        try printUsage(stderr_writer);
        try stderr_writer.flush();
        return;
    };
    
    if (opts.help) {
        try printUsage(stdout_writer);
        try stdout_writer.flush();
        return;
    }

    if (opts.pattern.len == 0 or opts.text.len == 0) {
        try stderr_writer.print("Error: Pattern and text are required\n", .{});
        try printUsage(stderr_writer);
        try stderr_writer.flush();
        return;
    }
    
    const regex_opts = RegexOptions{
        .case_sensitive = !opts.case_insensitive,
        .multiline = opts.multiline,
        .dot_matches_newline = opts.dot_matches_newline,
    };

    var regex = Regex.compileWithOptions(arena, opts.pattern, regex_opts) catch |err| {
        try stderr_writer.print("Error compiling regex: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        return;
    };
    defer regex.deinit();
    
    if (opts.debug) {
        try stdout_writer.print("Bytecode:\n", .{});
        for (regex.vm.bytecode.instructions.items, 0..) |inst, i| {
            try stdout_writer.print("{:4}: {s}\n", .{ i, @tagName(inst.opcode) });
        }
        try stdout_writer.print("\n", .{});
    }

    if (opts.replacement) |repl| {
        // Replace mode
        if (opts.find_all) {
            const result = try regex.replaceAll(opts.text, repl);
            try stdout_writer.print("{s}\n", .{result});
        } else {
            const result = try regex.replace(opts.text, repl);
            try stdout_writer.print("{s}\n", .{result});
        }
    } else if (opts.find_all) {
        // Find all mode
        var results = try regex.findAll(opts.text);
        defer {
            for (results.items) |*r| r.deinit();
            results.deinit(arena);
        }
        
        if (results.items.len == 0) {
            try stdout_writer.print("No matches found\n", .{});
        } else {
            try stdout_writer.print("Found {d} match(es):\n", .{results.items.len});
            for (results.items, 0..) |result, i| {
                if (result.getGroup(opts.text, 0)) |match| {
                    try stdout_writer.print("  [{d}] \"{s}\" at {d}-{d}\n", .{ i, match, result.start, result.end });
                }
            }
        }
    } else {
        // Simple match mode
        const matched = try regex.isMatch(opts.text);
        if (matched) {
            try stdout_writer.print("Match: YES\n", .{});
            
            var result = try regex.find(opts.text);
            if (result) |*r| {
                defer r.deinit();
                if (r.getGroup(opts.text, 0)) |full_match| {
                    try stdout_writer.print("Full match: \"{s}\" at {d}-{d}\n", .{ full_match, r.start, r.end });
                }
                
                // Show capture groups
                var group_idx: usize = 1;
                while (r.getGroup(opts.text, group_idx)) |group| : (group_idx += 1) {
                    try stdout_writer.print("Group {d}: \"{s}\"\n", .{ group_idx, group });
                }
            }
        } else {
            try stdout_writer.print("Match: NO\n", .{});
        }
    }

    try stdout_writer.flush();
}

test "main test" {
    // Integration tests can be added here
}
