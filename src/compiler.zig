const std = @import("std");
const AstNode = @import("parser.zig").AstNode;
const NodeType = @import("parser.zig").NodeType;
const CharClass = @import("parser.zig").CharClass;
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;

pub const Compiler = struct {
    bytecode: Bytecode,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .bytecode = Bytecode.init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Compiler) void {
        self.bytecode.deinit();
    }
    
    pub fn compile(self: *Compiler, ast: *AstNode) !Bytecode {
        try self.compileNode(ast);
        
        // 添加 Match 指令作为结束
        _ = try self.bytecode.emit(.{ .opcode = .Match });
        
        return self.bytecode;
    }
    
    fn compileNode(self: *Compiler, node: *AstNode) !void {
        switch (node.type) {
            .Literal => {
                _ = try self.bytecode.emit(.{
                    .opcode = .Char,
                    .char = @intCast(node.value.?),
                });
            },
            .Any => {
                _ = try self.bytecode.emit(.{ .opcode = .Any });
            },
            .CharClass => {
                // 分配 CharClass 在堆上
                const cc = try self.allocator.create(CharClass);
                cc.* = node.char_class.?;
                node.char_class_transferred = true;
                _ = try self.bytecode.emit(.{
                    .opcode = .CharClass,
                    .char_class = cc,
                });
            },
            .Concat => {
                try self.compileNode(node.left.?);
                try self.compileNode(node.right.?);
            },
            .Alternate => {
                // L1: Split L2, L3
                //      ...left...
                //      Jmp L4
                // L2: ...right...
                // L3: 
                
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined, // 稍后填充
                });
                
                // 编译左分支
                try self.compileNode(node.left.?);
                const jmp_idx = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = undefined, // 稍后填充
                });
                
                // 右分支开始位置
                const right_start = self.bytecode.getPC();
                self.bytecode.patch(split_idx, right_start);
                
                // 编译右分支
                try self.compileNode(node.right.?);
                
                // 跳转目标位置
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(jmp_idx, end_pos);
            },
            .Star => {
                // 贪婪: L1: Split L2, L3
                // L2: ...operand...
                //      Jmp L1
                // L3:
                const loop_start = self.bytecode.getPC();
                _ = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = loop_start + 1,
                });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = loop_start,
                });
            },
            .LazyStar => {
                // 惰性: L1: Split L3, L2
                // L2: ...operand...
                //      Jmp L1
                // L3:
                const loop_start = self.bytecode.getPC();
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = loop_start,
                });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
            },
            .Plus => {
                // 贪婪: L1: ...operand...
                //      Split L1, L2
                // L2:
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = self.bytecode.getPC() - 1,
                });
            },
            .LazyPlus => {
                // 惰性: L1: ...operand...
                //      Split L2, L1
                // L2:
                try self.compileNode(node.left.?);
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
            },
            .Question => {
                // 贪婪: Split L1, L2
                // L1: ...operand...
                // L2:
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                _ = self.bytecode.getPC();
                self.bytecode.patch(split_idx, operand_start);
            },
            .LazyQuestion => {
                // 惰性: Split L2, L1
                // L1: ...operand...
                // L2:
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                try self.compileNode(node.left.?);
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
            },
            .Group => {
                if (node.group_index) |group_idx| {
                    // 捕获组：生成 Save 指令
                    _ = try self.bytecode.emit(.{
                        .opcode = .Save,
                        .save_slot = group_idx * 2,
                    });
                    
                    try self.compileNode(node.left.?);
                    
                    _ = try self.bytecode.emit(.{
                        .opcode = .Save,
                        .save_slot = group_idx * 2 + 1,
                    });
                    
                    if (group_idx > self.bytecode.num_groups) {
                        self.bytecode.num_groups = group_idx;
                    }
                } else {
                    // 非捕获组：只编译内部，不生成 Save 指令
                    try self.compileNode(node.left.?);
                }
            },
            .Quantifier => {
                try self.compileQuantifier(node, false);
            },
            .LazyQuantifier => {
                try self.compileQuantifier(node, true);
            },
            .Backref => {
                _ = try self.bytecode.emit(.{
                    .opcode = .Backref,
                    .backref_group = node.value.?,
                });
            },
            .WordBoundary => {
                _ = try self.bytecode.emit(.{ .opcode = .WordBoundary });
            },
            .NotWordBoundary => {
                _ = try self.bytecode.emit(.{ .opcode = .NotWordBoundary });
            },
            .Empty => {
                // 空表达式不生成指令
            },
            .AssertStart => {
                _ = try self.bytecode.emit(.{ .opcode = .AssertStart });
            },
            .AssertEnd => {
                _ = try self.bytecode.emit(.{ .opcode = .AssertEnd });
            },
            .AssertStringStart => {
                _ = try self.bytecode.emit(.{ .opcode = .AssertStringStart });
            },
            .AssertStringEnd => {
                _ = try self.bytecode.emit(.{ .opcode = .AssertStringEnd });
            },
            .AssertStringEndAllowNewline => {
                _ = try self.bytecode.emit(.{ .opcode = .AssertStringEndAllowNewline });
            },
            .AssertForward => {
                // 正向前瞻: 编译内部表达式，但使用特殊标记
                // 实际实现需要在 VM 中支持
                _ = try self.bytecode.emit(.{ .opcode = .AssertForward });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertForwardEnd });
            },
            .AssertForwardNegative => {
                // 负向前瞻
                _ = try self.bytecode.emit(.{ .opcode = .AssertForwardNegative });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertForwardEnd });
            },
            .AssertBackward => {
                // 正向后顾 (简化实现)
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackward });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackwardEnd });
            },
            .AssertBackwardNegative => {
                // 负向后顾 (简化实现)
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackwardNegative });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackwardEnd });
            },
        }
    }

    fn compileQuantifier(self: *Compiler, node: *AstNode, lazy: bool) error{OutOfMemory}!void {
        const min = node.value.?;
        const max = node.group_index; // 复用 group_index 字段存储 max

        // 生成 min 次必需的匹配
        for (0..min) |_| {
            try self.compileNode(node.left.?);
        }

        // 如果有最大值，生成额外的可选匹配
        if (max) |m| {
            for (min..m) |_| {
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                const end_pos = self.bytecode.getPC();
                if (lazy) {
                    // 惰性: Split end_pos, operand_start
                    self.bytecode.patch(split_idx, end_pos);
                } else {
                    // 贪婪: Split operand_start, end_pos
                    self.bytecode.patch(split_idx, operand_start);
                }
            }
        } else {
            // {n,} - 无限重复
            const loop_start = self.bytecode.getPC();
            const split_idx = try self.bytecode.emit(.{
                .opcode = .Split,
                .target = undefined,
            });
            const operand_start = self.bytecode.getPC();
            try self.compileNode(node.left.?);
            _ = try self.bytecode.emit(.{
                .opcode = .Jmp,
                .target = loop_start,
            });
            const end_pos = self.bytecode.getPC();
            if (lazy) {
                // 惰性: Split end_pos, operand_start
                self.bytecode.patch(split_idx, end_pos);
            } else {
                // 贪婪: Split operand_start, end_pos
                self.bytecode.patch(split_idx, operand_start);
            }
        }
    }
};

test "compiler literal" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "a");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    try std.testing.expectEqual(@as(usize, 2), bytecode.instructions.items.len);
    try std.testing.expectEqual(.Char, bytecode.instructions.items[0].opcode);
    try std.testing.expectEqual(@as(u8, 'a'), bytecode.instructions.items[0].char.?);
    try std.testing.expectEqual(.Match, bytecode.instructions.items[1].opcode);
}

test "compiler star" {
    const allocator = std.testing.allocator;
    
    var parser = @import("parser.zig").Parser.init(allocator, "a*");
    const ast = try parser.parse();
    defer {
        ast.?.deinit(allocator);
        allocator.destroy(ast.?);
    }
    
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    
    const bytecode = try compiler.compile(ast.?);
    try std.testing.expectEqual(@as(usize, 4), bytecode.instructions.items.len);
    try std.testing.expectEqual(.Split, bytecode.instructions.items[0].opcode);
    try std.testing.expectEqual(.Char, bytecode.instructions.items[1].opcode);
    try std.testing.expectEqual(.Jmp, bytecode.instructions.items[2].opcode);
    try std.testing.expectEqual(.Match, bytecode.instructions.items[3].opcode);
}
