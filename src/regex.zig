const std = @import("std");
const builtin = @import("builtin");
const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;
const Vm = @import("vm.zig").Vm;
const MatchResult = @import("vm.zig").MatchResult;
const RegexOptions = @import("options.zig").RegexOptions;

const GroupNameEntry = struct {
    name: []const u8,
    index: usize,
};

pub const Regex = struct {
    vm: Vm,
    allocator: std.mem.Allocator,
    options: RegexOptions,
    group_names: std.ArrayList(GroupNameEntry),
    is_static: bool = false, // true for comptime-compiled regex; skips deallocation of comptime data

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithOptions(allocator, pattern, .{});
    }

    pub fn compileWithOptions(allocator: std.mem.Allocator, pattern: []const u8, options: RegexOptions) !Regex {
        var parser = Parser.initWithOptions(allocator, pattern, options);
        defer parser.deinit();
        const ast = parser.parse() catch |err| {
            if (parser.last_error) |last_err| {
                if (!builtin.is_test) {
                    std.debug.print("Regex compile error at position {d}: {s}\n", .{ last_err.position, last_err.message });
                }
            }
            return err;
        };
        defer {
            ast.?.deinit(allocator);
            allocator.destroy(ast.?);
        }

        var compiler = Compiler.init(allocator);
        // Note: do not deinit compiler here because bytecode needs to be kept

        const bytecode = try compiler.compile(ast.?, options);

        var group_names: std.ArrayList(GroupNameEntry) = .empty;
        var it = parser.group_names.iterator();
        while (it.next()) |entry| {
            const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
            try group_names.append(allocator, .{ .name = key_copy, .index = entry.value_ptr.* });
        }

        return Regex{
            .vm = Vm.init(allocator, bytecode, options),
            .allocator = allocator,
            .options = options,
            .group_names = group_names,
        };
    }

    pub fn deinit(self: *Regex) void {
        if (!self.is_static) {
            // Free char_class pointers in bytecode
            for (self.vm.bytecode.instructions.items) |inst| {
                if (inst.char_class) |cc| {
                    cc.deinit(self.allocator);
                    self.allocator.destroy(cc);
                }
            }
            for (self.group_names.items) |entry| {
                self.allocator.free(entry.name);
            }
            self.group_names.deinit(self.allocator);
        }
        self.vm.bytecode.deinit();
        self.vm.deinit();
    }

    /// Get capture group content by name
    pub fn getCaptureGroup(self: *Regex, match_result: MatchResult, input: []const u8, name: []const u8) ?[]const u8 {
        for (self.group_names.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return match_result.getGroup(input, entry.index);
            }
        }
        return null;
    }
    
    pub fn exec(self: *Regex, text: []const u8, start_pos: usize) !MatchResult {
        self.vm.last_match_end = start_pos;
        return try self.vm.exec(text, start_pos);
    }

    pub fn isMatch(self: *Regex, text: []const u8) !bool {
        self.vm.last_match_end = 0;
        return try self.vm.match(text);
    }

    pub fn find(self: *Regex, text: []const u8) !?MatchResult {
        const result = try self.vm.find(text);
        if (result) |*r| {
            if (r.matched) {
                self.vm.last_match_end = r.end;
            }
        }
        return result;
    }
    
    pub fn findAll(self: *Regex, text: []const u8) !std.ArrayList(MatchResult) {
        var results: std.ArrayList(MatchResult) = .empty;
        errdefer {
            for (0..results.items.len) |i| {
                var r = &results.items[i];
                r.deinit();
            }
            results.deinit(self.allocator);
        }

        var iter = self.findIter(text);
        while (try iter.next()) |result| {
            try results.append(self.allocator, result);
        }

        return results;
    }

    pub fn findIter(self: *Regex, text: []const u8) MatchIterator {
        return MatchIterator{
            .regex = self,
            .text = text,
            .pos = 0,
        };
    }

    pub fn matchAll(self: *Regex, text: []const u8) !std.ArrayList([]const u8) {
        var results: std.ArrayList([]const u8) = .empty;
        errdefer results.deinit(self.allocator);

        var iter = self.findIter(text);
        while (true) {
            var result = try iter.next();
            if (result) |*r| {
                try results.append(self.allocator, text[r.start..r.end]);
                r.deinit();
            } else {
                break;
            }
        }

        return results;
    }

    pub fn isMatchFull(self: *Regex, text: []const u8) !bool {
        var result = try self.vm.exec(text, 0);
        defer result.deinit();
        return result.matched and result.end == text.len;
    }
    
    fn appendReplacement(self: *Regex, result: *std.ArrayList(u8), text: []const u8, match_result: MatchResult, replacement: []const u8) !void {
        // Append replacement text (supports $0, $1, ..., ${10}, ${name}, $&, $`, $', $$)
        var rep_i: usize = 0;
        while (rep_i < replacement.len) {
            if (replacement[rep_i] == '$' and rep_i + 1 < replacement.len) {
                const next_ch = replacement[rep_i + 1];
                if (next_ch == '$') {
                    try result.append(self.allocator, '$');
                    rep_i += 2;
                } else if (next_ch == '&') {
                    // $& - full match
                    try result.appendSlice(self.allocator, text[match_result.start..match_result.end]);
                    rep_i += 2;
                } else if (next_ch == '`') {
                    // $` - text before match
                    if (match_result.start > 0) {
                        try result.appendSlice(self.allocator, text[0..match_result.start]);
                    }
                    rep_i += 2;
                } else if (next_ch == '\'') {
                    // $' - text after match
                    if (match_result.end < text.len) {
                        try result.appendSlice(self.allocator, text[match_result.end..]);
                    }
                    rep_i += 2;
                } else if (next_ch == '{') {
                    // ${name} or ${10}
                    var end_idx = rep_i + 2;
                    while (end_idx < replacement.len and replacement[end_idx] != '}') {
                        end_idx += 1;
                    }
                    if (end_idx < replacement.len and replacement[end_idx] == '}') {
                        const ref_name = replacement[rep_i + 2 .. end_idx];
                        if (std.fmt.parseInt(usize, ref_name, 10)) |group_idx| {
                            if (match_result.getGroup(text, group_idx)) |group_text| {
                                try result.appendSlice(self.allocator, group_text);
                            }
                        } else |_| {
                            // Try lookup by name
                            var found = false;
                            for (self.group_names.items) |entry| {
                                if (std.mem.eql(u8, entry.name, ref_name)) {
                                    if (match_result.getGroup(text, entry.index)) |group_text| {
                                        try result.appendSlice(self.allocator, group_text);
                                    }
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                // Neither a number nor a known name, output as literal
                                try result.appendSlice(self.allocator, replacement[rep_i .. end_idx + 1]);
                            }
                        }
                        rep_i = end_idx + 1;
                    } else {
                        try result.append(self.allocator, replacement[rep_i]);
                        rep_i += 1;
                    }
                } else if (std.ascii.isDigit(next_ch)) {
                    const group_idx = next_ch - '0';
                    if (match_result.getGroup(text, group_idx)) |group_text| {
                        try result.appendSlice(self.allocator, group_text);
                    }
                    rep_i += 2;
                } else {
                    try result.append(self.allocator, replacement[rep_i]);
                    rep_i += 1;
                }
            } else {
                try result.append(self.allocator, replacement[rep_i]);
                rep_i += 1;
            }
        }
    }

    pub fn replace(self: *Regex, text: []const u8, replacement: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var match_result_opt = try self.vm.find(text);
        if (match_result_opt) |*match_result| {
            defer match_result.deinit();
            // Append text before match
            if (match_result.start > 0) {
                try result.appendSlice(self.allocator, text[0..match_result.start]);
            }
            try self.appendReplacement(&result, text, match_result.*, replacement);
            try result.appendSlice(self.allocator, text[match_result.end..]);
            return result.toOwnedSlice(self.allocator);
        }

        // No match, return original text
        try result.appendSlice(self.allocator, text);
        return result.toOwnedSlice(self.allocator);
    }

    pub fn replaceAll(self: *Regex, text: []const u8, replacement: []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var last_end: usize = 0;
        var pos: usize = 0;

        while (pos <= text.len) {
            var match_result = try self.vm.exec(text, pos);
            if (!match_result.matched) {
                match_result.deinit();
                pos += 1;
                continue;
            }

            // Save start/end because they can't be accessed after deinit
            const m_start = match_result.start;
            const m_end = match_result.end;

            // Append text before match
            if (m_start > last_end) {
                try result.appendSlice(self.allocator, text[last_end..m_start]);
            }

            // Append replacement text
            try self.appendReplacement(&result, text, match_result, replacement);

            last_end = m_end;
            pos = m_end;
            match_result.deinit();

            if (m_start == m_end) {
                pos += 1;
            }
        }

        // Append remaining text
        if (last_end < text.len) {
            try result.appendSlice(self.allocator, text[last_end..]);
        }

        return result.toOwnedSlice(self.allocator);
    }

    pub fn replaceAllFn(self: *Regex, text: []const u8, comptime replFn: fn ([]const u8, MatchResult) []const u8) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var last_end: usize = 0;
        var pos: usize = 0;

        while (pos <= text.len) {
            var match_result = try self.vm.exec(text, pos);
            if (!match_result.matched) {
                match_result.deinit();
                pos += 1;
                continue;
            }

            // Save start/end because they can't be accessed after deinit
            const m_start = match_result.start;
            const m_end = match_result.end;

            // Append text before match
            if (m_start > last_end) {
                try result.appendSlice(self.allocator, text[last_end..m_start]);
            }

            // Call replacement function
            const match_text = text[match_result.start..match_result.end];
            const repl_text = replFn(match_text, match_result);
            try result.appendSlice(self.allocator, repl_text);

            last_end = m_end;
            pos = m_end;
            match_result.deinit();

            if (m_start == m_end) {
                pos += 1;
            }
        }

        // Append remaining text
        if (last_end < text.len) {
            try result.appendSlice(self.allocator, text[last_end..]);
        }

        return result.toOwnedSlice(self.allocator);
    }
    
    pub fn split(self: *Regex, text: []const u8) !std.ArrayList([]const u8) {
        return self.splitLimit(text, null);
    }

    pub fn splitLimit(self: *Regex, text: []const u8, limit: ?usize) !std.ArrayList([]const u8) {
        var results: std.ArrayList([]const u8) = .empty;
        errdefer results.deinit(self.allocator);

        var last_end: usize = 0;
        var pos: usize = 0;
        var count: usize = 0;
        const max_splits = if (limit) |l| l else std.math.maxInt(usize);

        while (pos <= text.len and count < max_splits) {
            var match_result = try self.vm.exec(text, pos);
            if (!match_result.matched) {
                match_result.deinit();
                pos += 1;
                continue;
            }
            defer match_result.deinit();

            // Append text before match (including empty string)
            try results.append(self.allocator, text[last_end..match_result.start]);
            count += 1;

            last_end = match_result.end;
            pos = match_result.end;

            if (match_result.start == match_result.end) {
                pos += 1;
            }
        }

        // Append remaining text (including empty string)
        try results.append(self.allocator, text[last_end..]);

        return results;
    }
};

pub const MatchIterator = struct {
    regex: *Regex,
    text: []const u8,
    pos: usize,

    pub fn next(self: *MatchIterator) !?MatchResult {
        while (self.pos <= self.text.len) {
            var result = try self.regex.vm.exec(self.text, self.pos);
            if (result.matched) {
                self.regex.vm.last_match_end = result.end;
                if (result.start == result.end) {
                    self.pos += 1;
                } else {
                    self.pos = result.end;
                }
                return result;
            } else {
                result.deinit();
                self.pos += 1;
            }
        }
        return null;
    }
};

test "regex basic" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "a*b");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(try regex.isMatch("aab"));
    // a*b fails to match "a" because it requires b
    try std.testing.expect(!try regex.isMatch("a"));
}

test "regex find" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("123"));
    // isMatch only starts matching from position 0, so "abc123def" doesn't match
    // Use find to search for substring
    try std.testing.expect(!try regex.isMatch("abc123def"));
}

test "regex char class" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "[a-z]+");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("abc"));
}

test "regex negated char class" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "\\D+");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("123"));
}

test "regex anchor start" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "^abc");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("xabc"));
}

test "regex anchor end" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "abc$");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("abcx"));
}

test "regex non-capturing group" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "(?:ab)+");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(try regex.isMatch("abab"));
}

test "regex quantifier" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "a{2,3}");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaa"));
    try std.testing.expect(!try regex.isMatch("a"));
    // a{2,3} can match the first 2-3 a's in "aaaa"
    try std.testing.expect(try regex.isMatch("aaaa"));
}

test "regex quantifier min only" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "a{2,}");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("aa"));
    try std.testing.expect(try regex.isMatch("aaaa"));
    try std.testing.expect(!try regex.isMatch("a"));
}

test "regex replace" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "a+");
    defer regex.deinit();
    
    const result = try regex.replace("aabbaaa", "X");
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings("Xbbaaa", result);
}

test "regex split" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, ",");
    defer regex.deinit();
    
    var parts = try regex.split("a,b,c");
    defer parts.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 3), parts.items.len);
    try std.testing.expectEqualStrings("a", parts.items[0]);
    try std.testing.expectEqualStrings("b", parts.items[1]);
    try std.testing.expectEqualStrings("c", parts.items[2]);
}

test "regex named group" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "(?<word>\\w+)");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("hello"));
}

test "regex options" {
    const allocator = std.testing.allocator;
    
    // Test options object creation
    var regex = try Regex.compileWithOptions(allocator, "hello", .{ .case_sensitive = true });
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("hello"));
}

test "regex matchAll" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();
    
    var matches = try regex.matchAll("abc 123 def 456 ghi 789");
    defer matches.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 3), matches.items.len);
    try std.testing.expectEqualStrings("123", matches.items[0]);
    try std.testing.expectEqualStrings("456", matches.items[1]);
    try std.testing.expectEqualStrings("789", matches.items[2]);
}

test "regex matchAll no match" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();
    
    var matches = try regex.matchAll("abc def ghi");
    defer matches.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 0), matches.items.len);
}

test "regex isMatchFull" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "^\\d+$");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatchFull("123"));
    try std.testing.expect(!try regex.isMatchFull("abc"));
    try std.testing.expect(!try regex.isMatchFull("123abc"));
}

test "regex isMatchFull with literal" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatchFull("hello"));
    try std.testing.expect(!try regex.isMatchFull("hello world"));
    try std.testing.expect(!try regex.isMatchFull("say hello"));
}

test "regex literal quote \\Q...\\E" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "\\Qa.b*c\\E+");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("a.b*ca.b*c"));
    try std.testing.expect(try regex.isMatch("a.b*c"));
    try std.testing.expect(try regex.isMatch("a.b*cc"));
    try std.testing.expect(!try regex.isMatch("abbc"));
}

test "regex literal quote with special chars" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "\\Q[$^|]\\E");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("[$^|]"));
    try std.testing.expect(try regex.isMatch("[$^|]x"));
    try std.testing.expect(!try regex.isMatch("[$^|"));
}

test "regex literal quote without end" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "\\Qabc");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("abc"));
    try std.testing.expect(!try regex.isMatch("ab"));
}

test "regex literal quote empty" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "a\\Q\\Eb");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(!try regex.isMatch("a+b"));
}

test "regex control character \\cX" {
    const allocator = std.testing.allocator;

    // \cA = 0x01 (SOH)
    var regex = try Regex.compile(allocator, "\\cA");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("\x01"));
    try std.testing.expect(!try regex.isMatch("A"));

    // \cZ = 0x1A (SUB)
    var regex2 = try Regex.compile(allocator, "\\cZ");
    defer regex2.deinit();
    try std.testing.expect(try regex2.isMatch("\x1A"));

    // \c[ = 0x1B (ESC)
    var regex3 = try Regex.compile(allocator, "\\c[");
    defer regex3.deinit();
    try std.testing.expect(try regex3.isMatch("\x1B"));
}

test "regex null character \\0" {
    const allocator = std.testing.allocator;

    var regex = try Regex.compile(allocator, "\\0");
    defer regex.deinit();
    try std.testing.expect(try regex.isMatch("\x00"));
    try std.testing.expect(!try regex.isMatch("0"));
}
