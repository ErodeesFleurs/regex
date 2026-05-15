const std = @import("std");
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;
const RegexOptions = @import("options.zig").RegexOptions;

pub const MatchResult = struct {
    matched: bool,
    captures: std.ArrayList(?usize),
    start: usize,
    end: usize,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *MatchResult) void {
        self.captures.deinit(self.allocator);
    }
    
    pub fn getGroup(self: MatchResult, input: []const u8, group_idx: usize) ?[]const u8 {
        const captures = self.captures;
        
        const start_slot = group_idx * 2;
        const end_slot = group_idx * 2 + 1;
        
        if (start_slot >= captures.items.len or end_slot >= captures.items.len) {
            return null;
        }
        
        const start = captures.items[start_slot];
        const end = captures.items[end_slot];
        
        if (start == null or end == null) return null;
        
        return input[start.?..end.?];
    }
};

// 用于回溯的栈帧
const Frame = struct {
    pc: usize,
    pos: usize,
    capture_slot: ?usize,
    capture_old_value: ?usize,
};

pub const Vm = struct {
    bytecode: Bytecode,
    allocator: std.mem.Allocator,
    options: RegexOptions,

    pub fn init(allocator: std.mem.Allocator, bytecode: Bytecode, options: RegexOptions) Vm {
        return .{
            .bytecode = bytecode,
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *Vm) void {
        _ = self;
    }

    /// 在子指令范围内尝试匹配，返回匹配结束位置（失败返回 null）。
    /// 用于前瞻/后顾的独立子匹配。
    fn tryMatchSubpattern(self: *Vm, input: []const u8, start_pc: usize, end_pc: usize, start_pos: usize) !?usize {
        var sub_pc: usize = start_pc;
        var sub_pos: usize = start_pos;
        var sub_matched = false;
        var sub_match_end: usize = start_pos;

        var sub_captures: std.ArrayList(?usize) = .empty;
        try sub_captures.resize(self.allocator, (self.bytecode.num_groups + 1) * 2);
        @memset(sub_captures.items, null);
        defer sub_captures.deinit(self.allocator);

        var sub_stack: std.ArrayList(Frame) = .empty;
        defer sub_stack.deinit(self.allocator);

        while (true) {
            if (sub_pc >= end_pc) {
                if (sub_stack.items.len == 0) break;
                const frame = sub_stack.pop().?;
                sub_pc = frame.pc;
                sub_pos = frame.pos;
                if (frame.capture_slot) |slot| {
                    sub_captures.items[slot] = frame.capture_old_value;
                }
                continue;
            }

            const inst = self.bytecode.instructions.items[sub_pc];

            switch (inst.opcode) {
                .Char => {
                    if (sub_pos < input.len and input[sub_pos] == inst.char.?) {
                        sub_pc += 1;
                        sub_pos += 1;
                    } else {
                        if (sub_stack.items.len == 0) break;
                        const frame = sub_stack.pop().?;
                        sub_pc = frame.pc;
                        sub_pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            sub_captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .Any => {
                    if (sub_pos < input.len) {
                        sub_pc += 1;
                        sub_pos += 1;
                    } else {
                        if (sub_stack.items.len == 0) break;
                        const frame = sub_stack.pop().?;
                        sub_pc = frame.pc;
                        sub_pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            sub_captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .CharClass => {
                    if (sub_pos < input.len and inst.char_class.?.*.contains(input[sub_pos])) {
                        sub_pc += 1;
                        sub_pos += 1;
                    } else {
                        if (sub_stack.items.len == 0) break;
                        const frame = sub_stack.pop().?;
                        sub_pc = frame.pc;
                        sub_pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            sub_captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .Split => {
                    try sub_stack.append(self.allocator, .{
                        .pc = sub_pc + 1,
                        .pos = sub_pos,
                        .capture_slot = null,
                        .capture_old_value = null,
                    });
                    sub_pc = inst.target.?;
                },
                .Jmp => {
                    sub_pc = inst.target.?;
                },
                .Save => {
                    const slot = inst.save_slot.?;
                    const old_val = sub_captures.items[slot];
                    sub_captures.items[slot] = sub_pos;
                    try sub_stack.append(self.allocator, .{
                        .pc = sub_pc + 1,
                        .pos = sub_pos,
                        .capture_slot = slot,
                        .capture_old_value = old_val,
                    });
                    sub_pc += 1;
                },
                .Match => {
                    sub_matched = true;
                    sub_match_end = sub_pos;
                    break;
                },
                .AssertStart => {
                    if (sub_pos == 0) {
                        sub_pc += 1;
                    } else {
                        if (sub_stack.items.len == 0) break;
                        const frame = sub_stack.pop().?;
                        sub_pc = frame.pc;
                        sub_pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            sub_captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertEnd => {
                    if (sub_pos == input.len) {
                        sub_pc += 1;
                    } else {
                        if (sub_stack.items.len == 0) break;
                        const frame = sub_stack.pop().?;
                        sub_pc = frame.pc;
                        sub_pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            sub_captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                else => {
                    // 嵌套断言在本简化实现中直接跳过
                    sub_pc += 1;
                },
            }
        }

        if (sub_matched) {
            return sub_match_end;
        }
        return null;
    }

    pub fn match(self: *Vm, input: []const u8) !bool {
        var result = try self.exec(input, 0);
        defer result.deinit();
        return result.matched;
    }
    
    pub fn find(self: *Vm, input: []const u8) !?MatchResult {
        for (0..input.len + 1) |start| {
            var result = try self.exec(input, start);
            if (result.matched) {
                return result;
            }
            result.deinit();
        }
        return null;
    }
    
    pub fn exec(self: *Vm, input: []const u8, start_pos: usize) !MatchResult {
        var captures: std.ArrayList(?usize) = .empty;
        try captures.resize(self.allocator, (self.bytecode.num_groups + 1) * 2);
        @memset(captures.items, null);
        
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);
        
        var pc: usize = 0;
        var pos: usize = start_pos;
        var matched = false;
        var match_end: usize = start_pos;
        
        while (true) {
            if (pc >= self.bytecode.instructions.items.len) {
                // 回溯
                if (stack.items.len == 0) break;
                const frame = stack.pop().?;
                pc = frame.pc;
                pos = frame.pos;
                if (frame.capture_slot) |slot| {
                    captures.items[slot] = frame.capture_old_value;
                }
                continue;
            }
            
            const inst = self.bytecode.instructions.items[pc];
            
            switch (inst.opcode) {
                .Char => {
                    const matches = if (self.options.case_sensitive)
                        (pos < input.len and input[pos] == inst.char.?)
                    else
                        (pos < input.len and std.ascii.toLower(input[pos]) == std.ascii.toLower(inst.char.?));
                    if (matches) {
                        pc += 1;
                        pos += 1;
                    } else {
                        // 回溯
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .Any => {
                    if (pos < input.len and (self.options.dot_matches_newline or input[pos] != '\n')) {
                        pc += 1;
                        pos += 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .CharClass => {
                    if (pos < input.len and inst.char_class.?.*.contains(input[pos])) {
                        pc += 1;
                        pos += 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .Split => {
                    // 压栈第二个分支，执行第一个分支
                    try stack.append(self.allocator, .{
                        .pc = pc + 1,
                        .pos = pos,
                        .capture_slot = null,
                        .capture_old_value = null,
                    });
                    pc = inst.target.?;
                },
                .Jmp => {
                    pc = inst.target.?;
                },
                .Save => {
                    const slot = inst.save_slot.?;
                    const old_val = captures.items[slot];
                    captures.items[slot] = pos;
                    
                    try stack.append(self.allocator, .{
                        .pc = pc + 1,
                        .pos = pos,
                        .capture_slot = slot,
                        .capture_old_value = old_val,
                    });
                    pc += 1;
                },
                .Match => {
                    matched = true;
                    match_end = pos;
                    break;
                },
                .Backref => {
                    const group_idx = inst.backref_group.?;
                    const start_slot = group_idx * 2;
                    const end_slot = group_idx * 2 + 1;
                    if (start_slot >= captures.items.len or end_slot >= captures.items.len) {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                        continue;
                    }
                    const group_start = captures.items[start_slot];
                    const group_end = captures.items[end_slot];
                    if (group_start == null or group_end == null) {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                        continue;
                    }
                    const group_text = input[group_start.?..group_end.?];
                    const remaining = input[pos..];
                    if (remaining.len >= group_text.len and std.mem.startsWith(u8, remaining, group_text)) {
                        pc += 1;
                        pos += group_text.len;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .WordBoundary => {
                    const is_word = struct {
                        pub fn call(ch: u8) bool {
                            return (ch >= 'a' and ch <= 'z') or
                                (ch >= 'A' and ch <= 'Z') or
                                (ch >= '0' and ch <= '9') or
                                ch == '_';
                        }
                    }.call;
                    const left = if (pos > 0) is_word(input[pos - 1]) else false;
                    const right = if (pos < input.len) is_word(input[pos]) else false;
                    if (left != right) {
                        pc += 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .NotWordBoundary => {
                    const is_word = struct {
                        pub fn call(ch: u8) bool {
                            return (ch >= 'a' and ch <= 'z') or
                                (ch >= 'A' and ch <= 'Z') or
                                (ch >= '0' and ch <= '9') or
                                ch == '_';
                        }
                    }.call;
                    const left = if (pos > 0) is_word(input[pos - 1]) else false;
                    const right = if (pos < input.len) is_word(input[pos]) else false;
                    if (left == right) {
                        pc += 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertStart => {
                    const at_start = if (self.options.multiline)
                        (pos == 0 or input[pos - 1] == '\n')
                    else
                        (pos == 0);
                    if (at_start) {
                        pc += 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertEnd => {
                    const at_end = if (self.options.multiline)
                        (pos == input.len or input[pos] == '\n')
                    else
                        (pos == input.len);
                    if (at_end) {
                        pc += 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertForward => {
                    var depth: usize = 1;
                    var end_pc = pc + 1;
                    while (end_pc < self.bytecode.instructions.items.len) : (end_pc += 1) {
                        const inst2 = self.bytecode.instructions.items[end_pc];
                        switch (inst2.opcode) {
                            .AssertForward => depth += 1,
                            .AssertForwardEnd => {
                                depth -= 1;
                                if (depth == 0) break;
                            },
                            else => {},
                        }
                    }

                    const sub_end = try self.tryMatchSubpattern(input, pc + 1, end_pc, pos);
                    if (sub_end != null) {
                        pc = end_pc + 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertForwardNegative => {
                    var depth: usize = 1;
                    var end_pc = pc + 1;
                    while (end_pc < self.bytecode.instructions.items.len) : (end_pc += 1) {
                        const inst2 = self.bytecode.instructions.items[end_pc];
                        switch (inst2.opcode) {
                            .AssertForwardNegative => depth += 1,
                            .AssertForwardEnd => {
                                depth -= 1;
                                if (depth == 0) break;
                            },
                            else => {},
                        }
                    }

                    const sub_end = try self.tryMatchSubpattern(input, pc + 1, end_pc, pos);
                    if (sub_end == null) {
                        pc = end_pc + 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertForwardEnd => {
                    pc += 1;
                },
                .AssertBackward => {
                    var depth: usize = 1;
                    var end_pc = pc + 1;
                    while (end_pc < self.bytecode.instructions.items.len) : (end_pc += 1) {
                        const inst2 = self.bytecode.instructions.items[end_pc];
                        switch (inst2.opcode) {
                            .AssertBackward => depth += 1,
                            .AssertBackwardEnd => {
                                depth -= 1;
                                if (depth == 0) break;
                            },
                            else => {},
                        }
                    }

                    var success = false;
                    var try_pos: usize = 0;
                    while (try_pos <= pos) : (try_pos += 1) {
                        const sub_end = try self.tryMatchSubpattern(input, pc + 1, end_pc, try_pos);
                        if (sub_end) |se| {
                            if (se == pos) {
                                success = true;
                                break;
                            }
                        }
                    }

                    if (success) {
                        pc = end_pc + 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertBackwardNegative => {
                    var depth: usize = 1;
                    var end_pc = pc + 1;
                    while (end_pc < self.bytecode.instructions.items.len) : (end_pc += 1) {
                        const inst2 = self.bytecode.instructions.items[end_pc];
                        switch (inst2.opcode) {
                            .AssertBackwardNegative => depth += 1,
                            .AssertBackwardEnd => {
                                depth -= 1;
                                if (depth == 0) break;
                            },
                            else => {},
                        }
                    }

                    var success = true;
                    var try_pos: usize = 0;
                    while (try_pos <= pos) : (try_pos += 1) {
                        const sub_end = try self.tryMatchSubpattern(input, pc + 1, end_pc, try_pos);
                        if (sub_end) |se| {
                            if (se == pos) {
                                success = false;
                                break;
                            }
                        }
                    }

                    if (success) {
                        pc = end_pc + 1;
                    } else {
                        if (stack.items.len == 0) break;
                        const frame = stack.pop().?;
                        pc = frame.pc;
                        pos = frame.pos;
                        if (frame.capture_slot) |slot| {
                            captures.items[slot] = frame.capture_old_value;
                        }
                    }
                },
                .AssertBackwardEnd => {
                    pc += 1;
                },
            }
        }
        
        return MatchResult{
            .matched = matched,
            .captures = captures,
            .start = start_pos,
            .end = match_end,
            .allocator = self.allocator,
        };
    }
};

test "vm literal match" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "a");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = @import("compiler.zig").Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    
    var vm = Vm.init(allocator, bytecode, .{});
    defer vm.deinit();
    
    try std.testing.expect(try vm.match("a"));
    try std.testing.expect(!try vm.match("b"));
}

test "vm concat" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "ab");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = @import("compiler.zig").Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    
    var vm = Vm.init(allocator, bytecode, .{});
    defer vm.deinit();
    
    try std.testing.expect(try vm.match("ab"));
    try std.testing.expect(!try vm.match("a"));
}

test "vm alternate" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "a|b");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = @import("compiler.zig").Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    
    var vm = Vm.init(allocator, bytecode, .{});
    defer vm.deinit();
    
    try std.testing.expect(try vm.match("a"));
    try std.testing.expect(try vm.match("b"));
    try std.testing.expect(!try vm.match("c"));
}

test "vm star" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "a*");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = @import("compiler.zig").Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    
    var vm = Vm.init(allocator, bytecode, .{});
    defer vm.deinit();
    
    try std.testing.expect(try vm.match(""));
    try std.testing.expect(try vm.match("a"));
    try std.testing.expect(try vm.match("aaa"));
    // a* 可以匹配空字符串，所以在 "b" 的开头匹配空字符串
    // 这是正确的正则行为
    try std.testing.expect(try vm.match("b"));
}

test "vm group" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "(ab)");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = @import("compiler.zig").Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    
    var vm = Vm.init(allocator, bytecode, .{});
    defer vm.deinit();
    
    var result = try vm.find("ab");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.matched);
    
    const group = result.?.getGroup("ab", 1);
    try std.testing.expect(group != null);
    try std.testing.expectEqualStrings("ab", group.?);
    
    if (result) |*r| r.deinit();
}
