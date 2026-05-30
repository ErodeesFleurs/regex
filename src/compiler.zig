const std = @import("std");
const AstNode = @import("parser.zig").AstNode;
const CharClass = @import("parser.zig").CharClass;
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;

const RegexOptions = @import("options.zig").RegexOptions;
const NodeType = @import("parser.zig").NodeType;

/// Return the fixed byte width of a node, or null if variable width.
fn computeFixedWidth(node: *AstNode) ?usize {
    switch (node.type) {
        .Literal,
        .Any,
        .CharClass,
        .UnicodeProperty,
        .NotUnicodeProperty,
        .GraphemeCluster,
        .Newline,
        .NotNewline,
        .NotVerticalWhitespace,
        .WordBoundary,
        .NotWordBoundary,
        => return 1,
        .AssertStart,
        .AssertEnd,
        .AssertStringStart,
        .AssertStringEnd,
        .AssertStringEndAllowNewline,
        .AssertMatchStart,
        .AssertForward,
        .AssertForwardNegative,
        .AssertBackward,
        .AssertBackwardNegative,
        .ResetMatchStart,
        .Empty,
        .InlineFlag,
        => return 0,
        .Group,
        .AtomicGroup,
        .Conditional,
        => return if (node.left) |l| computeFixedWidth(l) else 0,
        .Concat => {
            const left_width = computeFixedWidth(node.left.?) orelse return null;
            const right_width = computeFixedWidth(node.right.?) orelse return null;
            return left_width + right_width;
        },
        .Alternate => {
            const left_width = computeFixedWidth(node.left.?);
            const right_width = computeFixedWidth(node.right.?);
            if (left_width) |lw| {
                if (right_width) |rw| {
                    if (lw == rw) return lw;
                }
            }
            return null;
        },
        .Star,
        .LazyStar,
        .PossessiveStar,
        .Plus,
        .LazyPlus,
        .PossessivePlus,
        .Question,
        .LazyQuestion,
        .PossessiveQuestion,
        => return null,
        .Quantifier,
        .LazyQuantifier,
        .PossessiveQuantifier,
        => {
            const child_width = computeFixedWidth(node.left.?) orelse return null;
            const min_count = node.value.?;
            const max_count = node.group_index;
            if (max_count) |max| {
                if (min_count == max) {
                    return child_width * min_count;
                }
            }
            return null;
        },
        .Backref,
        .SubroutineCall,
        => return null,
    }
}

/// Find the end PC of an assert block (lookahead/lookbehind).
fn findAssertEnd(instructions: []const Instruction, start_pc: usize) usize {
    var depth: usize = 1;
    var end_pc = start_pc;
    while (end_pc < instructions.len) : (end_pc += 1) {
        const inst2 = instructions[end_pc];
        switch (inst2) {
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
        const inst = @unionInit(Instruction, @tagName(op), {});
        _ = try self.bytecode.emit(inst);
    }

    pub fn compile(self: *Compiler, ast: *AstNode, options: RegexOptions) !Bytecode {
        self.options = options;
        try self.compileNode(ast);

        // Append Match instruction as terminator
        try self.emitOp(.Match);

        self.patchSubroutineCalls();

        self.detectFirstLiteralAndAnchor();

        // Peephole: merge consecutive Char instructions into String
        try self.mergeLiteralStrings();

        // Peephole: eliminate Jmp chains
        self.eliminateJmpChains();

        try self.buildAssertEnds();

        self.buildSkipTable();

        // Move bytecode out to avoid double-free when compiler.deinit runs
        const bytecode = self.bytecode;
        self.bytecode = Bytecode.init(self.allocator);
        return bytecode;
    }

    fn compileNode(self: *Compiler, node: *AstNode) !void {
        switch (node.type) {
            .Literal => {
                const value = node.value.?;
                if (!self.options.case_sensitive and value > 127) {
                    // For case-insensitive mode with non-ASCII characters, use CharUtf8
                    _ = try self.bytecode.emit(.{ .CharUtf8 = @intCast(value) });
                } else if (value <= 127) {
                    _ = try self.bytecode.emit(.{ .Char = @intCast(value) });
                } else {
                    // Encode Unicode code point > 127 as UTF-8 byte sequence (case-sensitive mode)
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(value), &buf) catch {
                        // Invalid code point, emit a placeholder
                        _ = try self.bytecode.emit(.{ .Char = '?' });
                        return;
                    };
                    for (0..len) |i| {
                        _ = try self.bytecode.emit(.{ .Char = buf[i] });
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
                _ = try self.bytecode.emit(.{ .CharClass = cc });
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

                const split_idx = try self.bytecode.emit(.{ .Split = undefined });

                // Compile left branch
                try self.compileNode(node.left.?);
                const jmp_idx = try self.bytecode.emit(.{ .Jmp = undefined });

                // Right branch start position
                const right_start = self.bytecode.getPC();
                self.bytecode.patch(split_idx, right_start);

                // Compile right branch
                try self.compileNode(node.right.?);

                // Jump target position
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(jmp_idx, end_pos);
            },
            .Star, .LazyStar, .Plus, .LazyPlus, .Question, .LazyQuestion => |tag| {
                const min: usize = switch (tag) {
                    .Plus, .LazyPlus => 1,
                    else => 0,
                };
                const max: ?usize = switch (tag) {
                    .Question, .LazyQuestion => 1,
                    else => null,
                };
                const lazy = switch (tag) {
                    .LazyStar, .LazyPlus, .LazyQuestion => true,
                    else => false,
                };
                try self.emitLoop(node.left.?, min, max, lazy);
            },
            .Group => {
                if (node.group_index) |group_idx| {
                    // Capturing group: emit Save instructions
                    const group_start = self.bytecode.getPC();
                    _ = try self.bytecode.emit(.{ .Save = group_idx * 2 });

                    try self.compileNode(node.left.?);
                    const inner_end = self.bytecode.getPC();

                    // SubroutineReturn: returns to caller if entered via SubroutineCall
                    try self.emitOp(.SubroutineReturn);

                    _ = try self.bytecode.emit(.{ .Save = group_idx * 2 + 1 });

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
            .PossessiveStar, .PossessivePlus, .PossessiveQuestion => |tag| {
                try self.emitOp(.AtomicStart);
                const min: usize = switch (tag) {
                    .PossessivePlus => 1,
                    else => 0,
                };
                const max: ?usize = switch (tag) {
                    .PossessiveQuestion => 1,
                    else => null,
                };
                try self.emitLoop(node.left.?, min, max, false);
                try self.emitOp(.AtomicEnd);
            },
            .PossessiveQuantifier => {
                try self.emitOp(.AtomicStart);
                try self.compileQuantifier(node, false);
                try self.emitOp(.AtomicEnd);
            },
            .Backref => {
                _ = try self.bytecode.emit(.{ .Backref = node.value.? });
            },
            .WordBoundary => try self.emitOp(.WordBoundary),
            .NotWordBoundary => try self.emitOp(.NotWordBoundary),
            .UnicodeProperty, .NotUnicodeProperty => {
                const prop_copy = try self.allocator.dupe(u8, node.unicode_property.?);
                try self.bytecode.unicode_properties.append(self.allocator, prop_copy);
                _ = try self.bytecode.emit(.{ .UnicodeProperty = .{ .property = prop_copy, .negated = node.type == .NotUnicodeProperty } });
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
            .AssertForward, .AssertForwardNegative, .AssertBackward, .AssertBackwardNegative => try self.emitAssertBlock(node),
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
                _ = try self.bytecode.emit(.{ .SetOption = new_opts });
                if (node.left) |inner| {
                    try self.compileNode(inner);
                    // Restore original options for scoped flag
                    self.options = old_options;
                    _ = try self.bytecode.emit(.{ .SetOption = old_options });
                }
            },
            .AtomicGroup => {
                try self.emitOp(.AtomicStart);
                try self.compileNode(node.left.?);
                try self.emitOp(.AtomicEnd);
            },
            .Conditional => try self.compileConditional(node),
            .SubroutineCall => {
                const group_idx = node.value.?;
                _ = try self.bytecode.emit(.{ .SubroutineCall = .{ .group = group_idx, .target = undefined } });
            },
        }
    }

    fn buildAssertEnds(self: *Compiler) !void {
        try self.bytecode.assert_ends.resize(self.allocator, self.bytecode.instructions.items.len);
        @memset(self.bytecode.assert_ends.items, 0);
        for (self.bytecode.instructions.items, 0..) |inst, pc| {
            switch (inst) {
                .AssertForward, .AssertForwardNegative, .AssertBackward, .AssertBackwardNegative => {
                    self.bytecode.assert_ends.items[pc] = findAssertEnd(self.bytecode.instructions.items, pc + 1);
                },
                else => {},
            }
        }
    }

    fn buildSkipTable(self: *Compiler) void {
        if (self.bytecode.instructions.items.len == 0) return;
        const first_inst = self.bytecode.instructions.items[0];
        if (first_inst != .String) return;
        const prefix = first_inst.String;
        if (prefix.len < 2) return;
        self.bytecode.prefix_len = prefix.len;
        self.bytecode.has_skip_table = true;
        @memset(&self.bytecode.skip_table, @intCast(prefix.len + 1));
        for (0..prefix.len) |i| {
            self.bytecode.skip_table[prefix[i]] = @intCast(prefix.len - i);
        }
    }

    fn patchSubroutineCalls(self: *Compiler) void {
        for (self.bytecode.instructions.items, 0..) |*inst, i| {
            if (inst.* == .SubroutineCall) {
                const group_idx = inst.SubroutineCall.group;
                if (self.group_ranges.get(group_idx)) |range| {
                    self.bytecode.patch(i, range.start);
                } else {
                    self.bytecode.patch(i, i + 1);
                }
            }
        }
    }

    fn detectFirstLiteralAndAnchor(self: *Compiler) void {
        if (self.bytecode.instructions.items.len == 0) return;
        const first_inst = self.bytecode.instructions.items[0];
        if (first_inst == .Char) {
            self.bytecode.first_char = first_inst.Char;
        } else if (first_inst == .String) {
            self.bytecode.first_char = first_inst.String[0];
        } else if (first_inst == .CharUtf8) {
            const cp = first_inst.CharUtf8;
            if (cp < 0x80) {
                self.bytecode.first_byte = @intCast(cp);
            } else if (cp < 0x800) {
                self.bytecode.first_byte = @intCast(0xC0 | (cp >> 6));
            } else if (cp < 0x10000) {
                self.bytecode.first_byte = @intCast(0xE0 | (cp >> 12));
            } else {
                self.bytecode.first_byte = @intCast(0xF0 | (cp >> 18));
            }
        }
        if (first_inst == .AssertStringStart) {
            self.bytecode.is_anchored = true;
        }
    }

    fn emitAssertBlock(self: *Compiler, node: *AstNode) error{OutOfMemory}!void {
        switch (node.type) {
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
                const width = computeFixedWidth(node.left.?);
                _ = try self.bytecode.emit(.{ .AssertBackward = width });
                try self.compileNode(node.left.?);
                try self.emitOp(.AssertBackwardEnd);
            },
            .AssertBackwardNegative => {
                const width = computeFixedWidth(node.left.?);
                _ = try self.bytecode.emit(.{ .AssertBackwardNegative = width });
                try self.compileNode(node.left.?);
                try self.emitOp(.AssertBackwardEnd);
            },
            else => unreachable,
        }
    }

    fn compileConditional(self: *Compiler, node: *AstNode) error{OutOfMemory}!void {
        if (node.condition) |cond| {
            var yes_node = node.left.?;
            var no_node = node.right;

            if (yes_node.type == .Alternate and no_node == null) {
                no_node = yes_node.right;
                yes_node = yes_node.left.?;
            }

            const split_idx = try self.bytecode.emit(.{ .Split = undefined });
            try self.emitOp(.AtomicStart);
            try self.emitAssertBlock(cond);
            try self.compileNode(yes_node);
            try self.emitOp(.AtomicEnd);
            const jmp_idx = try self.bytecode.emit(.{ .Jmp = undefined });

            const no_start = self.bytecode.getPC();
            if (no_node) |no| {
                try self.compileNode(no);
            }
            const end_pos = self.bytecode.getPC();

            self.bytecode.patch(jmp_idx, end_pos);
            self.bytecode.patch(split_idx, no_start);
        } else {
            const group_idx = node.value.?;
            const cond_idx = try self.bytecode.emit(.{ .Conditional = .{ .group = group_idx, .target = undefined } });

            const yes_node = node.left.?;
            const no_node = node.right;

            if (yes_node.type == .Alternate and no_node == null) {
                try self.compileNode(yes_node.left.?);
                const jmp_idx = try self.bytecode.emit(.{ .Jmp = undefined });
                const no_start = self.bytecode.getPC();
                try self.compileNode(yes_node.right.?);
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(cond_idx, no_start);
                self.bytecode.patch(jmp_idx, end_pos);
            } else {
                try self.compileNode(yes_node);

                if (no_node) |no| {
                    const jmp_idx = try self.bytecode.emit(.{ .Jmp = undefined });
                    const no_start = self.bytecode.getPC();
                    try self.compileNode(no);
                    const end_pos = self.bytecode.getPC();
                    self.bytecode.patch(cond_idx, no_start);
                    self.bytecode.patch(jmp_idx, end_pos);
                } else {
                    const end_pos = self.bytecode.getPC();
                    self.bytecode.patch(cond_idx, end_pos);
                }
            }
        }
    }

    fn compileQuantifier(self: *Compiler, node: *AstNode, lazy: bool) error{OutOfMemory}!void {
        const min = node.value.?;
        const max = node.group_index; // reuse group_index field to store max
        try self.emitLoop(node.left.?, min, max, lazy);
    }

    /// Emit one optional match: Split to operand or past it.
    /// Returns the Split instruction index.
    fn emitOptional(self: *Compiler, operand: *AstNode, lazy: bool) error{OutOfMemory}!usize {
        const split_idx = try self.bytecode.emit(.{ .Split = undefined });
        if (lazy) {
            const jmp_idx = try self.bytecode.emit(.{ .Jmp = undefined });
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
        return split_idx;
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
                _ = try self.emitOptional(operand, lazy);
            }
        } else {
            // {n,} - infinite repetition
            const loop_start = self.bytecode.getPC();
            const split_idx = try self.bytecode.emit(.{ .Split = undefined });
            if (lazy) {
                const jmp_idx = try self.bytecode.emit(.{ .Jmp = undefined });
                const operand_start = self.bytecode.getPC();
                try self.compileNode(operand);
                _ = try self.bytecode.emit(.{ .Jmp = loop_start });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, operand_start);
                self.bytecode.patch(jmp_idx, end_pos);
            } else {
                try self.compileNode(operand);
                _ = try self.bytecode.emit(.{ .Jmp = loop_start });
                const end_pos = self.bytecode.getPC();
                self.bytecode.patch(split_idx, end_pos);
            }
        }
    }

    /// Peephole optimization: merge consecutive Char instructions into String.
    /// Only merges sequences where no jump target points into the sequence interior.
    fn mergeLiteralStrings(self: *Compiler) !void {
        const old = self.bytecode.instructions.items;
        if (old.len < 2) return;

        // Collect all jump targets
        var jump_targets = try self.allocator.alloc(bool, old.len);
        defer self.allocator.free(jump_targets);
        @memset(jump_targets, false);
        for (old) |inst| {
            switch (inst) {
                .Split => |t| {
                    if (t < old.len) jump_targets[t] = true;
                },
                .Jmp => |t| {
                    if (t < old.len) jump_targets[t] = true;
                },
                .Conditional => |c| {
                    if (c.target < old.len) jump_targets[c.target] = true;
                },
                .SubroutineCall => |s| {
                    if (s.target < old.len) jump_targets[s.target] = true;
                },
                else => {},
            }
        }

        var new_insts: std.ArrayList(Instruction) = .empty;

        // Map old PC -> new PC
        var remap = try self.allocator.alloc(usize, old.len);
        defer self.allocator.free(remap);

        var i: usize = 0;
        while (i < old.len) {
            remap[i] = new_insts.items.len;

            // Check for consecutive literal chars
            if (old[i] == .Char) {
                var len: usize = 1;
                while (i + len < old.len and old[i + len] == .Char) {
                    len += 1;
                }
                // Only merge if no jump target points into the sequence interior (after start)
                var has_jump_into = false;
                for (1..len) |j| {
                    if (jump_targets[i + j]) {
                        has_jump_into = true;
                        break;
                    }
                }
                if (len >= 2 and !has_jump_into) {
                    const buf = try self.allocator.alloc(u8, len);
                    for (0..len) |j| {
                        buf[j] = old[i + j].Char;
                        remap[i + j] = new_insts.items.len;
                    }
                    try self.bytecode.strings.append(self.allocator, buf);
                    try new_insts.append(self.allocator, .{ .String = buf });
                    i += len;
                    continue;
                }
            }

            try new_insts.append(self.allocator, old[i]);
            i += 1;
        }

        // Remap jump targets
        for (new_insts.items) |*inst| {
            switch (inst.*) {
                .Split => |*t| t.* = remap[t.*],
                .Jmp => |*t| t.* = remap[t.*],
                .Conditional => |*c| c.target = remap[c.target],
                .SubroutineCall => |*s| s.target = remap[s.target],
                else => {},
            }
        }

        // Replace instructions
        self.bytecode.instructions.deinit(self.allocator);
        self.bytecode.instructions = new_insts;
    }

    /// Peephole: eliminate Split that branches to the next instruction.
    /// Peephole: eliminate Jmp chains (Jmp -> Jmp -> ... -> target).
    fn eliminateJmpChains(self: *Compiler) void {
        const insts = self.bytecode.instructions.items;
        if (insts.len == 0) return;

        var visited: std.ArrayList(u32) = .empty;
        defer visited.deinit(self.allocator);
        visited.resize(self.allocator, insts.len) catch return;
        @memset(visited.items, 0);

        var generation: u32 = 1;
        // Resolve final target for each Jmp
        for (insts) |*inst| {
            if (inst.* == .Jmp) {
                var target = inst.Jmp;
                while (target < insts.len and insts[target] == .Jmp) {
                    if (visited.items[target] == generation) break; // cycle
                    visited.items[target] = generation;
                    target = insts[target].Jmp;
                }
                inst.* = .{ .Jmp = target };
                generation += 1;
                if (generation == 0) {
                    @memset(visited.items, 0);
                    generation = 1;
                }
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

    var bytecode = try compiler.compile(ast.?, .{});
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(usize, 2), bytecode.instructions.items.len);
    try std.testing.expect(bytecode.instructions.items[0] == .Char);
    try std.testing.expectEqual(@as(u8, 'a'), bytecode.instructions.items[0].Char);
    try std.testing.expect(bytecode.instructions.items[1] == .Match);
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

    var bytecode = try compiler.compile(ast.?, .{});
    defer bytecode.deinit();
    try std.testing.expectEqual(@as(usize, 4), bytecode.instructions.items.len);
    try std.testing.expect(bytecode.instructions.items[0] == .Split);
    try std.testing.expect(bytecode.instructions.items[1] == .Char);
    try std.testing.expect(bytecode.instructions.items[2] == .Jmp);
    try std.testing.expect(bytecode.instructions.items[3] == .Match);
}
