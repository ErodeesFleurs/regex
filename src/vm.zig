const std = @import("std");
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;

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
    
    pub fn init(allocator: std.mem.Allocator, bytecode: Bytecode) Vm {
        return .{
            .bytecode = bytecode,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Vm) void {
        _ = self;
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
                    if (pos < input.len and input[pos] == inst.char.?) {
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
                    if (pos < input.len) {
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
                .AssertStart => {
                    if (pos == 0) {
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
                    if (pos == input.len) {
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
                    // 正向前瞻: 保存当前状态并跳转到匹配结束后的位置
                    // 找到对应的 AssertForwardEnd
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
                    
                    // 简化: 直接跳过到 AssertForwardEnd 之后
                    // 实际实现需要保存状态并尝试匹配
                    pc = end_pc + 1;
                },
                .AssertForwardNegative => {
                    // 负向前瞻: 类似正向前瞻，但匹配失败才算成功
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
                    
                    // 简化: 直接跳过
                    pc = end_pc + 1;
                },
                .AssertForwardEnd => {
                    // 不应该直接执行到这里
                    pc += 1;
                },
                .AssertBackward => {
                    // 正向后顾 (简化实现: 直接跳过)
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
                    pc = end_pc + 1;
                },
                .AssertBackwardNegative => {
                    // 负向后顾 (简化实现: 直接跳过)
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
                    pc = end_pc + 1;
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
    
    var vm = Vm.init(allocator, bytecode);
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
    
    var vm = Vm.init(allocator, bytecode);
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
    
    var vm = Vm.init(allocator, bytecode);
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
    
    var vm = Vm.init(allocator, bytecode);
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
    
    var vm = Vm.init(allocator, bytecode);
    defer vm.deinit();
    
    var result = try vm.find("ab");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.matched);
    
    const group = result.?.getGroup("ab", 1);
    try std.testing.expect(group != null);
    try std.testing.expectEqualStrings("ab", group.?);
    
    if (result) |*r| r.deinit();
}
