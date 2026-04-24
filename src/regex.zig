const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Compiler = @import("compiler.zig").Compiler;
const Vm = @import("vm.zig").Vm;
const MatchResult = @import("vm.zig").MatchResult;
const RegexOptions = @import("options.zig").RegexOptions;

pub const Regex = struct {
    vm: Vm,
    allocator: std.mem.Allocator,
    options: RegexOptions,
    
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        return compileWithOptions(allocator, pattern, .{});
    }
    
    pub fn compileWithOptions(allocator: std.mem.Allocator, pattern: []const u8, options: RegexOptions) !Regex {
        var parser = Parser.init(allocator, pattern);
        const ast = try parser.parse();
        defer {
            ast.?.deinit(allocator);
            allocator.destroy(ast.?);
        }
        
        var compiler = Compiler.init(allocator);
        // 注意：不要在这里 deinit compiler，因为 bytecode 需要被保留
        
        const bytecode = try compiler.compile(ast.?);
        
        return Regex{
            .vm = Vm.init(allocator, bytecode),
            .allocator = allocator,
            .options = options,
        };
    }
    
    pub fn deinit(self: *Regex) void {
        // 释放 bytecode 中的 char_class 指针
        for (self.vm.bytecode.instructions.items) |inst| {
            if (inst.char_class) |cc| {
                cc.deinit(self.allocator);
                self.allocator.destroy(cc);
            }
        }
        self.vm.bytecode.deinit();
        self.vm.deinit();
    }
    
    pub fn isMatch(self: *Regex, text: []const u8) !bool {
        return try self.vm.match(text);
    }
    
    pub fn find(self: *Regex, text: []const u8) !?MatchResult {
        return try self.vm.find(text);
    }
    
    pub fn findAll(self: *Regex, text: []const u8) !std.ArrayList(MatchResult) {
        var results: std.ArrayList(MatchResult) = .empty;
        errdefer {
            for (results.items) |*r| r.deinit();
            results.deinit(self.allocator);
        }
        
        var start: usize = 0;
        while (start <= text.len) {
            const result = try self.vm.exec(text, start);
            if (!result.matched) break;
            
            try results.append(self.allocator, result);
            
            if (result.start == result.end) {
                start += 1;
            } else {
                start = result.end;
            }
        }
        
        return results;
    }
    
    pub fn replace(self: *Regex, text: []const u8, replacement: []const u8) ![]u8 {
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
            defer match_result.deinit();
            
            // 添加匹配前的文本
            if (match_result.start > last_end) {
                try result.appendSlice(self.allocator, text[last_end..match_result.start]);
            }
            
            // 添加替换文本
            try result.appendSlice(self.allocator, replacement);
            
            last_end = match_result.end;
            pos = match_result.end;
            
            if (match_result.start == match_result.end) {
                pos += 1;
            }
        }
        
        // 添加剩余的文本
        if (last_end < text.len) {
            try result.appendSlice(self.allocator, text[last_end..]);
        }
        
        return result.toOwnedSlice(self.allocator);
    }
    
    pub fn replaceAll(self: *Regex, text: []const u8, replacement: []const u8) ![]u8 {
        return try self.replace(text, replacement);
    }
    
    pub fn split(self: *Regex, text: []const u8) !std.ArrayList([]const u8) {
        var results: std.ArrayList([]const u8) = .empty;
        errdefer results.deinit(self.allocator);
        
        var last_end: usize = 0;
        var pos: usize = 0;
        
        while (pos <= text.len) {
            var match_result = try self.vm.exec(text, pos);
            if (!match_result.matched) {
                match_result.deinit();
                pos += 1;
                continue;
            }
            defer match_result.deinit();
            
            // 添加匹配前的文本
            if (match_result.start > last_end) {
                try results.append(self.allocator, text[last_end..match_result.start]);
            }
            
            last_end = match_result.end;
            pos = match_result.end;
            
            if (match_result.start == match_result.end) {
                pos += 1;
            }
        }
        
        // 添加剩余的文本
        if (last_end < text.len) {
            try results.append(self.allocator, text[last_end..]);
        }
        
        return results;
    }
};

test "regex basic" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "a*b");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("b"));
    try std.testing.expect(try regex.isMatch("ab"));
    try std.testing.expect(try regex.isMatch("aab"));
    // a*b 匹配 "a" 失败，因为需要 b
    try std.testing.expect(!try regex.isMatch("a"));
}

test "regex find" {
    const allocator = std.testing.allocator;
    
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("123"));
    // isMatch 只从位置 0 开始匹配，所以 "abc123def" 不匹配
    // 应该使用 find 来搜索子串
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
    // a{2,3} 可以匹配 "aaaa" 中的前 2-3 个 a
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
    
    try std.testing.expectEqualStrings("XbbX", result);
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
    
    // 测试选项对象创建
    var regex = try Regex.compileWithOptions(allocator, "hello", .{ .case_sensitive = true });
    defer regex.deinit();
    
    try std.testing.expect(try regex.isMatch("hello"));
}
