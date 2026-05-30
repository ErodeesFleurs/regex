const std = @import("std");
const AstNode = @import("parser.zig").AstNode;
const NodeType = @import("parser.zig").NodeType;
const CharClass = @import("parser.zig").CharClass;
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;

const RegexOptions = @import("options.zig").RegexOptions;

/// Find the end PC of an assert block (lookahead/lookbehind).
fn findAssertEnd(instructions: []const Instruction, start_pc: usize) usize {
    var depth: usize = 1;
    var end_pc = start_pc;
    while (end_pc < instructions.len) : (end_pc += 1) {
        const inst2 = instructions[end_pc];
        switch (inst2.opcode) {
            .AssertForward, .AssertForwardNegative, .AssertBackward, .AssertBackwardNegative => depth += 1,
            .AssertForwardEnd, .AssertBackwardEnd => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    return end_pc;
}

const GroupRange = struct {
    start: usize,
    end: usize,
};

pub const Compiler = struct {
    bytecode: Bytecode,
    allocator: std.mem.Allocator,
    options: RegexOptions = .{},
    group_ranges: std.AutoHashMap(usize, GroupRange),
    recursion_depth: usize = 0,
    max_recursion_depth: usize = 10,

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .bytecode = Bytecode.init(allocator),
            .allocator = allocator,
            .group_ranges = std.AutoHashMap(usize, GroupRange).init(allocator),
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.group_ranges.deinit();
        self.bytecode.deinit();
    }

    /// Emit a single opcode with no operands.
    inline fn emitOp(self: *Compiler, op: OpCode) !void {
        _ = try self.bytecode.emit(.{ .opcode = op });
    }

    pub fn compile(self: *Compiler, ast: *AstNode, options: RegexOptions) !Bytecode {
        self.options = options;
        try self.compileNode(ast);
        
        // Append Match instruction as terminator
        try self.emitOp(.Match);

        // Patch SubroutineCall targets to point to group starts
        for (self.bytecode.instructions.items, 0..) |*inst, i| {
            if (inst.opcode == .SubroutineCall) {
                const group_idx = inst.subroutine_group.?;
                if (self.group_ranges.get(group_idx)) |range| {
                    inst.target = range.start;
                } else {
                    // Group not defined: treat as no-op (jump to next instruction)
                    inst.target = i + 1;
                }
            }
        }

        // Set first literal char for fast skipping in find()
        if (self.bytecode.instructions.items.len > 0) {
            const first_inst = self.bytecode.instructions.items[0];
            if (first_inst.opcode == .Char) {
                self.bytecode.first_char = first_inst.char;
            }
        }

        // Build assert_ends lookup table for fast VM execution
        try self.bytecode.assert_ends.resize(self.allocator, self.bytecode.instructions.items.len);
        @memset(self.bytecode.assert_ends.items, 0);
        for (self.bytecode.instructions.items, 0..) |inst, pc| {
            switch (inst.opcode) {
                .AssertForward, .AssertForwardNegative, .AssertBackward, .AssertBackwardNegative => {
                    self.bytecode.assert_ends.items[pc] = findAssertEnd(self.bytecode.instructions.items, pc + 1);
                },
                else => {},
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
            .Any => try self.emitOp(.Any),
            .CharClass => {
                const cc = try self.allocator.create(CharClass);
                if (node.char_class_transferred) {
                    // Deep copy for additional uses (e.g. quantifier repetition)
                    cc.* = CharClass.init(self.allocator, node.char_class.?.negated);
                    for (node.char_class.?.ranges.items) |range| {
                        try cc.addRange(range.start, range.end);
                    }
                    for (node.char_class.?.posix_classes.items) |name| {
                        try cc.addPosixClass(name);
                    }
                    for (node.char_class.?.unicode_properties.items) |entry| {
                        try cc.addUnicodeProperty(entry.name, entry.negated);
                    }
                } else {
                    cc.* = node.char_class.?;
                    node.char_class_transferred = true;
                }
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
            .Star => try self.emitLoop(node.left.?, 0, null, false),
            .LazyStar => try self.emitLoop(node.left.?, 0, null, true),
            .Plus => try self.emitLoop(node.left.?, 1, null, false),
            .LazyPlus => try self.emitLoop(node.left.?, 1, null, true),
            .Question => try self.emitLoop(node.left.?, 0, 1, false),
            .LazyQuestion => try self.emitLoop(node.left.?, 0, 1, true),
            .Group => {
                if (node.group_index) |group_idx| {
                    // Capturing group: emit Save instructions
                    const group_start = self.bytecode.getPC();
                    _ = try self.bytecode.emit(.{
                        .opcode = .Save,
                        .save_slot = group_idx * 2,
                    });

                    try self.compileNode(node.left.?);
                    const inner_end = self.bytecode.getPC();

                    // SubroutineReturn: returns to caller if entered via SubroutineCall
                    _ = try self.bytecode.emit(.{ .opcode = .SubroutineReturn });

                    _ = try self.bytecode.emit(.{
                        .opcode = .Save,
                        .save_slot = group_idx * 2 + 1,
                    });

                    // Record the group start (including Save start) for subroutine calls
                    self.group_ranges.put(group_idx, GroupRange{ .start = group_start, .end = inner_end }) catch {};

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
                try self.emitOp(.AtomicStart);
                try self.emitLoop(node.left.?, 0, null, false);
                try self.emitOp(.AtomicEnd);
            },
            .PossessivePlus => {
                try self.emitOp(.AtomicStart);
                try self.emitLoop(node.left.?, 1, null, false);
                try self.emitOp(.AtomicEnd);
            },
            .PossessiveQuestion => {
                try self.emitOp(.AtomicStart);
                try self.emitLoop(node.left.?, 0, 1, false);
                try self.emitOp(.AtomicEnd);
            },
            .PossessiveQuantifier => {
                try self.emitOp(.AtomicStart);
                try self.compileQuantifier(node, false);
                try self.emitOp(.AtomicEnd);
            },
            .Backref => {
                _ = try self.bytecode.emit(.{
                    .opcode = .Backref,
                    .backref_group = node.value.?,
                });
            },
            .WordBoundary => try self.emitOp(.WordBoundary),
            .NotWordBoundary => try self.emitOp(.NotWordBoundary),
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
            .GraphemeCluster => try self.emitOp(.GraphemeCluster),
            .Newline => try self.emitOp(.Newline),
            .ResetMatchStart => try self.emitOp(.ResetMatchStart),
            .NotNewline => try self.emitOp(.NotNewline),
            .NotVerticalWhitespace => try self.emitOp(.NotVerticalWhitespace),
            .Empty => {},
            .AssertStart => try self.emitOp(.AssertStart),
            .AssertEnd => try self.emitOp(.AssertEnd),
            .AssertStringStart => try self.emitOp(.AssertStringStart),
            .AssertStringEnd => try self.emitOp(.AssertStringEnd),
            .AssertStringEndAllowNewline => try self.emitOp(.AssertStringEndAllowNewline),
            .AssertMatchStart => try self.emitOp(.AssertMatchStart),
            .AssertForward => {
                try self.emitOp(.AssertForward);
                try self.compileNode(node.left.?);
                try self.emitOp(.AssertForwardEnd);
            },
            .AssertForwardNegative => {
                try self.emitOp(.AssertForwardNegative);
                try self.compileNode(node.left.?);
                try self.emitOp(.AssertForwardEnd);
            },
            .AssertBackward => {
                try self.emitOp(.AssertBackward);
                try self.compileNode(node.left.?);
                try self.emitOp(.AssertBackwardEnd);
            },
            .AssertBackwardNegative => {
                try self.emitOp(.AssertBackwardNegative);
                try self.compileNode(node.left.?);
                try self.emitOp(.AssertBackwardEnd);
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
                try self.emitOp(.AtomicStart);
                try self.compileNode(node.left.?);
                try self.emitOp(.AtomicEnd);
            },
            .Conditional => {
                if (node.condition) |cond| {
                    // Lookahead/lookbehind condition: (?(?=cond)yes|no) or (?(?<=cond)yes|no)
                    // Compile as:
                    //   Split L_yes, L_no
                    //   L_yes:
                    //       AtomicStart
                    //       AssertForward[Negative] / AssertBackward[Negative]
                    //       ...cond...
                    //       AssertForward[Negative]End / AssertBackward[Negative]End
                    //       ...yes...
                    //       AtomicEnd
                    //       Jmp L_end
                    //   L_no:
                    //       ...no...
                    //   L_end:
                    const cond_type = cond.type;
                    var yes_node = node.left.?;
                    var no_node = node.right;

                    // If yes is Alternate and no is null, parser included | in yes
                    // Use left/right of Alternate as yes/no branches
                    if (yes_node.type == .Alternate and no_node == null) {
                        no_node = yes_node.right;
                        yes_node = yes_node.left.?;
                    }

                    const split_idx = try self.bytecode.emit(.{
                        .opcode = .Split,
                        .target = undefined,
                    });

                    try self.emitOp(.AtomicStart);
                    switch (cond_type) {
                        .AssertForward => {
                            try self.emitOp(.AssertForward);
                            try self.compileNode(cond.left.?);
                            try self.emitOp(.AssertForwardEnd);
                        },
                        .AssertForwardNegative => {
                            try self.emitOp(.AssertForwardNegative);
                            try self.compileNode(cond.left.?);
                            try self.emitOp(.AssertForwardEnd);
                        },
                        .AssertBackward => {
                            try self.emitOp(.AssertBackward);
                            try self.compileNode(cond.left.?);
                            try self.emitOp(.AssertBackwardEnd);
                        },
                        .AssertBackwardNegative => {
                            try self.emitOp(.AssertBackwardNegative);
                            try self.compileNode(cond.left.?);
                            try self.emitOp(.AssertBackwardEnd);
                        },
                        else => unreachable,
                    }
                    try self.compileNode(yes_node);
                    try self.emitOp(.AtomicEnd);
                    const jmp_idx = try self.bytecode.emit(.{
                        .opcode = .Jmp,
                        .target = undefined,
                    });

                    const no_start = self.bytecode.getPC();
                    if (no_node) |no| {
                        try self.compileNode(no);
                    }
                    const end_pos = self.bytecode.getPC();

                    self.bytecode.patch(jmp_idx, end_pos);
                    self.bytecode.instructions.items[split_idx].target = no_start;
                } else {
                    // Group number condition: (?(n)yes|no)
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
                }
            },
            .SubroutineCall => {
                const group_idx = node.value.?;
                _ = try self.bytecode.emit(.{
                    .opcode = .SubroutineCall,
                    .subroutine_group = group_idx,
                });
            },
        }
    }

    fn compileQuantifier(self: *Compiler, node: *AstNode, lazy: bool) error{OutOfMemory}!void {
        const min = node.value.?;
        const max = node.group_index; // reuse group_index field to store max
        try self.emitLoop(node.left.?, min, max, lazy);
    }

    /// Emit loop bytecode for quantifier-like constructs.
    /// min: minimum repetitions (e.g. 0 for Star, 1 for Plus)
    /// max: maximum repetitions (null for infinite)
    /// lazy: true for lazy matching
    fn emitLoop(self: *Compiler, operand: *AstNode, min: usize, max: ?usize, lazy: bool) error{OutOfMemory}!void {
        // Emit min required matches
        for (0..min) |_| {
            try self.compileNode(operand);
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
                    try self.compileNode(operand);
                    const end_pos = self.bytecode.getPC();
                    self.bytecode.patch(split_idx, operand_start);
                    self.bytecode.patch(jmp_idx, end_pos);
                } else {
                    try self.compileNode(operand);
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
                try self.compileNode(operand);
                _ = try self.bytecode.emit(.{
                    .opcode = .Jmp,
                    .target = loop_start,
                });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, operand_start);
                self.bytecode.patch(jmp_idx, end_pos);
            } else {
                try self.compileNode(operand);
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
