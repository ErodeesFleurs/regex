const std = @import("std");
const AstNode = @import("parser.zig").AstNode;
const NodeType = @import("parser.zig").NodeType;
const CharClass = @import("parser.zig").CharClass;
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;

const RegexOptions = @import("options.zig").RegexOptions;

pub const Compiler = struct {
    bytecode: Bytecode,
    allocator: std.mem.Allocator,
    options: RegexOptions = .{},
    
    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .bytecode = Bytecode.init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Compiler) void {
        self.bytecode.deinit();
    }
    
    pub fn compile(self: *Compiler, ast: *AstNode, options: RegexOptions) !Bytecode {
        self.options = options;
        try self.compileNode(ast);
        
        // Append Match instruction as terminator
        _ = try self.bytecode.emit(.{ .opcode = .Match });
        
        // Set first literal char for fast skipping in find()
        if (self.bytecode.instructions.items.len > 0) {
            const first_inst = self.bytecode.instructions.items[0];
            if (first_inst.opcode == .Char) {
                self.bytecode.first_char = first_inst.char;
            }
        }
        
        return self.bytecode;
    }
    
    fn compileNode(self: *Compiler, node: *AstNode) !void {
        switch (node.type) {
            .Literal => {
                const value = node.value.?;
                if (!self.options.case_sensitive and value > 127) {
                    // For case-insensitive mode with non-ASCII characters, use CharUtf8
                    _ = try self.bytecode.emit(.{
                        .opcode = .CharUtf8,
                        .char_codepoint = @intCast(value),
                    });
                } else if (value <= 127) {
                    _ = try self.bytecode.emit(.{
                        .opcode = .Char,
                        .char = @intCast(value),
                    });
                } else {
                    // Encode Unicode code point > 127 as UTF-8 byte sequence (case-sensitive mode)
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(value), &buf) catch {
                        // Invalid code point, emit a placeholder
                        _ = try self.bytecode.emit(.{
                            .opcode = .Char,
                            .char = '?',
                        });
                        return;
                    };
                    for (0..len) |i| {
                        _ = try self.bytecode.emit(.{
                            .opcode = .Char,
                            .char = buf[i],
                        });
                    }
                }
            },
            .Any => {
                _ = try self.bytecode.emit(.{ .opcode = .Any });
            },
            .CharClass => {
                // Allocate CharClass on the heap
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
                    .target = undefined, // filled in later
                });
                
                // Compile left branch
                try self.compileNode(node.left.?);
                const jmp_idx = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = undefined, // filled in later
                });
                
                // Right branch start position
                const right_start = self.bytecode.getPC();
                self.bytecode.patch(split_idx, right_start);
                
                // Compile right branch
                try self.compileNode(node.right.?);
                
                // Jump target position
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(jmp_idx, end_pos);
            },
            .Star => {
                // Greedy: Split after, operand, Jmp Split
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = split_idx,
                });
                const after_loop = self.bytecode.getPC();
                self.bytecode.patch(split_idx, after_loop);
            },
            .LazyStar => {
                // Lazy: Split operand, Jmp after, operand, Jmp Split
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                const jmp_idx = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = undefined,
                });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = split_idx,
                });
                const after_loop = self.bytecode.getPC();
                self.bytecode.patch(split_idx, operand_start);
                self.bytecode.patch(jmp_idx, after_loop);
            },
            .Plus => {
                // Greedy: operand, Split after, Jmp operand
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = operand_start,
                });
                const after_loop = self.bytecode.getPC();
                self.bytecode.patch(split_idx, after_loop);
            },
            .LazyPlus => {
                // Lazy: operand, Split operand
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                self.bytecode.patch(split_idx, operand_start);
            },
            .Question => {
                // Greedy: Split after, operand
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                try self.compileNode(node.left.?);
                const after_operand = self.bytecode.getPC();
                self.bytecode.patch(split_idx, after_operand);
            },
            .LazyQuestion => {
                // Lazy: Split operand, Jmp after, operand
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                const jmp_idx = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = undefined,
                });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                const after_operand = self.bytecode.getPC();
                self.bytecode.patch(split_idx, operand_start);
                self.bytecode.patch(jmp_idx, after_operand);
            },
            .Group => {
                if (node.group_index) |group_idx| {
                    // Capturing group: emit Save instructions
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
                    // Non-capturing group: compile inner only, no Save instructions
                    try self.compileNode(node.left.?);
                }
            },
            .Quantifier => {
                try self.compileQuantifier(node, false);
            },
            .LazyQuantifier => {
                try self.compileQuantifier(node, true);
            },
            .PossessiveStar => {
                // a*+ is equivalent to (?>a*)
                _ = try self.bytecode.emit(.{ .opcode = .AtomicStart });
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
                _ = try self.bytecode.emit(.{ .opcode = .AtomicEnd });
            },
            .PossessivePlus => {
                _ = try self.bytecode.emit(.{ .opcode = .AtomicStart });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = operand_start,
                });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
                _ = try self.bytecode.emit(.{ .opcode = .AtomicEnd });
            },
            .PossessiveQuestion => {
                _ = try self.bytecode.emit(.{ .opcode = .AtomicStart });
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                try self.compileNode(node.left.?);
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
                _ = try self.bytecode.emit(.{ .opcode = .AtomicEnd });
            },
            .PossessiveQuantifier => {
                _ = try self.bytecode.emit(.{ .opcode = .AtomicStart });
                try self.compileQuantifier(node, false);
                _ = try self.bytecode.emit(.{ .opcode = .AtomicEnd });
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
            .UnicodeProperty => {
                const prop_copy = try self.allocator.dupe(u8, node.unicode_property.?);
                try self.bytecode.unicode_properties.append(self.allocator, prop_copy);
                _ = try self.bytecode.emit(.{
                    .opcode = .UnicodeProperty,
                    .unicode_property = prop_copy, 
                    .unicode_negated = false,
                });
            },
            .NotUnicodeProperty => {
                const prop_copy = try self.allocator.dupe(u8, node.unicode_property.?);
                try self.bytecode.unicode_properties.append(self.allocator, prop_copy);
                _ = try self.bytecode.emit(.{
                    .opcode = .UnicodeProperty,
                    .unicode_property = prop_copy,
                    .unicode_negated = true,
                });
            },
            .GraphemeCluster => {
                _ = try self.bytecode.emit(.{ .opcode = .GraphemeCluster });
            },
            .Empty => {
                // Empty expression generates no instructions
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
                // Positive lookahead: compile inner expression with special markers
                // Actual implementation needs VM support
                _ = try self.bytecode.emit(.{ .opcode = .AssertForward });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertForwardEnd });
            },
            .AssertForwardNegative => {
                // Negative lookahead
                _ = try self.bytecode.emit(.{ .opcode = .AssertForwardNegative });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertForwardEnd });
            },
            .AssertBackward => {
                // Positive lookbehind (simplified implementation)
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackward });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackwardEnd });
            },
            .AssertBackwardNegative => {
                // Negative lookbehind (simplified implementation)
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackwardNegative });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AssertBackwardEnd });
            },
            .InlineFlag => {
                const old_options = self.options;
                var new_opts = old_options;
                if (node.value) |flag_bits| {
                    if (flag_bits & 1 != 0) new_opts.case_sensitive = node.options.?.case_sensitive;
                    if (flag_bits & 2 != 0) new_opts.multiline = node.options.?.multiline;
                    if (flag_bits & 4 != 0) new_opts.dot_matches_newline = node.options.?.dot_matches_newline;
                    if (flag_bits & 8 != 0) new_opts.free_spacing = node.options.?.free_spacing;
                }
                self.options = new_opts;
                _ = try self.bytecode.emit(.{
                    .opcode = .SetOption,
                    .options = new_opts,
                });
                if (node.left) |inner| {
                    try self.compileNode(inner);
                    // Restore original options for scoped flag
                    self.options = old_options;
                    _ = try self.bytecode.emit(.{
                        .opcode = .SetOption,
                        .options = old_options,
                    });
                }
            },
            .AtomicGroup => {
                _ = try self.bytecode.emit(.{ .opcode = .AtomicStart });
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{ .opcode = .AtomicEnd });
            },
            .Conditional => {
                // (?(n)yes|no)
                const group_idx = node.value.?;
                const cond_idx = try self.bytecode.emit(.{
                    .opcode = .Conditional,
                    .backref_group = group_idx,
                    .target = undefined,
                });

                const yes_node = node.left.?;
                const no_node = node.right;

                // If left is Alternate, use its children as yes/no branches
                if (yes_node.type == .Alternate and no_node == null) {
                    try self.compileNode(yes_node.left.?);
                    const jmp_idx = try self.bytecode.emit(.{
                        .opcode = .Jmp,
                        .target = undefined,
                    });
                    const no_start = self.bytecode.getPC();
                    try self.compileNode(yes_node.right.?);
                    const end_pos = self.bytecode.getPC();
                    self.bytecode.patch(cond_idx, no_start);
                    self.bytecode.patch(jmp_idx, end_pos);
                } else {
                    // Compile yes branch
                    try self.compileNode(yes_node);

                    if (no_node) |no| {
                        // There is a no branch: yes branch needs to jump over it
                        const jmp_idx = try self.bytecode.emit(.{
                            .opcode = .Jmp,
                            .target = undefined,
                        });
                        const no_start = self.bytecode.getPC();
                        try self.compileNode(no);
                        const end_pos = self.bytecode.getPC();
                        self.bytecode.patch(cond_idx, no_start);
                        self.bytecode.patch(jmp_idx, end_pos);
                    } else {
                        // No no-branch: if condition fails, jump past yes branch
                        const end_pos = self.bytecode.getPC();
                        self.bytecode.patch(cond_idx, end_pos);
                    }
                }
            },
        }
    }

    fn compileQuantifier(self: *Compiler, node: *AstNode, lazy: bool) error{OutOfMemory}!void {
        const min = node.value.?;
        const max = node.group_index; // reuse group_index field to store max

        // Emit min required matches
        for (0..min) |_| {
            try self.compileNode(node.left.?);
        }

        // If there is a max, emit additional optional matches
        if (max) |m| {
            for (min..m) |_| {
                const split_idx = try self.bytecode.emit(.{
                    .opcode = .Split,
                    .target = undefined,
                });
                if (lazy) {
                    const jmp_idx = try self.bytecode.emit(.{
                        .opcode = .Jmp,
                        .target = undefined,
                    });
                    const operand_start = self.bytecode.getPC();
                    try self.compileNode(node.left.?);
                    const end_pos = self.bytecode.getPC();
                    self.bytecode.patch(split_idx, operand_start);
                    self.bytecode.patch(jmp_idx, end_pos);
                } else {
                    try self.compileNode(node.left.?);
                    const end_pos = self.bytecode.getPC();
                    self.bytecode.patch(split_idx, end_pos);
                }
            }
        } else {
            // {n,} - infinite repetition
            const loop_start = self.bytecode.getPC();
            const split_idx = try self.bytecode.emit(.{
                .opcode = .Split,
                .target = undefined,
            });
            if (lazy) {
                const jmp_idx = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = undefined,
                });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = loop_start,
                });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, operand_start);
                self.bytecode.patch(jmp_idx, end_pos);
            } else {
                try self.compileNode(node.left.?);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = loop_start,
                });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
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
    
    const bytecode = try compiler.compile(ast.?, .{});
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
    
    const bytecode = try compiler.compile(ast.?, .{});
    try std.testing.expectEqual(@as(usize, 4), bytecode.instructions.items.len);
    try std.testing.expectEqual(.Split, bytecode.instructions.items[0].opcode);
    try std.testing.expectEqual(.Char, bytecode.instructions.items[1].opcode);
    try std.testing.expectEqual(.Jmp, bytecode.instructions.items[2].opcode);
    try std.testing.expectEqual(.Match, bytecode.instructions.items[3].opcode);
}
