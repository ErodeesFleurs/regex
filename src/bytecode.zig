const std = @import("std");
const AstNode = @import("parser.zig").AstNode;
const NodeType = @import("parser.zig").NodeType;
const CharClass = @import("parser.zig").CharClass;
const RegexOptions = @import("options.zig").RegexOptions;

pub const OpCode = enum(u8) {
    // Basic instructions
    Char,          // match single character
    Any,           // match any character
    CharClass,     // match character class
    
    // Control flow
    Split,         // split execution (NFA)
    Jmp,           // jump
    Match,         // match success
    
    // Grouping
    Save,          // save capture group position
    
    // Zero-width assertions
    AssertStart,
    AssertEnd,
    AssertStringStart,       // \A
    AssertStringEnd,         // \z
    AssertStringEndAllowNewline, // \Z
    AssertMatchStart,        // \G
    AssertForward,
    AssertForwardEnd,
    AssertForwardNegative,
    AssertBackward,
    AssertBackwardEnd,
    AssertBackwardNegative,

    // Backreferences
    Backref,

    // Word boundaries
    WordBoundary,
    NotWordBoundary,

    // Inline flags
    SetOption,

    // Atomic groups
    AtomicStart,
    AtomicEnd,
    
    // Unicode properties
    UnicodeProperty,

    // Unicode character (for case-insensitive matching of non-ASCII literals)
    CharUtf8,

    // Grapheme cluster
    GraphemeCluster,

    // Conditional (?(n)yes|no)
    Conditional,
};

pub const Instruction = struct {
    opcode: OpCode,
    char: ?u8 = null,
    char_codepoint: ?u21 = null, // for CharUtf8 instruction
    char_class: ?*CharClass = null,
    target: ?usize = null,
    save_slot: ?usize = null,
    backref_group: ?usize = null,
    options: ?RegexOptions = null,
    unicode_property: ?[]const u8 = null,
    unicode_negated: bool = false,
    
    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.opcode) {
            .Char => try writer.print("Char({c})", .{self.char.?}),
            .Any => try writer.print("Any", .{}),
            .CharClass => try writer.print("CharClass", .{}),
            .Split => try writer.print("Split -> {}", .{self.target.?}),
            .Jmp => try writer.print("Jmp -> {}", .{self.target.?}),
            .Match => try writer.print("Match", .{}),
            .Save => try writer.print("Save({})", .{self.save_slot.?}),
            .AssertStart => try writer.print("AssertStart", .{}),
            .AssertEnd => try writer.print("AssertEnd", .{}),
            .AssertStringStart => try writer.print("AssertStringStart", .{}),
            .AssertStringEnd => try writer.print("AssertStringEnd", .{}),
            .AssertStringEndAllowNewline => try writer.print("AssertStringEndAllowNewline", .{}),
            .AssertMatchStart => try writer.print("AssertMatchStart", .{}),
            .AssertForward => try writer.print("AssertForward", .{}),
            .AssertForwardEnd => try writer.print("AssertForwardEnd", .{}),
            .AssertForwardNegative => try writer.print("AssertForwardNegative", .{}),
            .AssertBackward => try writer.print("AssertBackward", .{}),
            .AssertBackwardEnd => try writer.print("AssertBackwardEnd", .{}),
            .AssertBackwardNegative => try writer.print("AssertBackwardNegative", .{}),
            .Backref => try writer.print("Backref({})", .{self.backref_group.?}),
            .WordBoundary => try writer.print("WordBoundary", .{}),
            .NotWordBoundary => try writer.print("NotWordBoundary", .{}),
            .SetOption => try writer.print("SetOption", .{}),
            .AtomicStart => try writer.print("AtomicStart", .{}),
            .AtomicEnd => try writer.print("AtomicEnd", .{}),
            .UnicodeProperty => try writer.print("UnicodeProperty({s}{s})", .{
                if (self.unicode_negated) "P{" else "p{",
                self.unicode_property.?, 
            }),
            .Conditional => try writer.print("Conditional({}) -> {}", .{self.backref_group.?, self.target.?}),
        }
    }
};

pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),
    num_groups: usize,
    unicode_properties: std.ArrayList([]const u8),
    first_char: ?u8 = null, // first literal character, used for fast skipping in find()

    allocator: std.mem.Allocator,
    is_static: bool = false, // true for comptime-compiled bytecode; skips deallocation

    pub fn init(allocator: std.mem.Allocator) Bytecode {
        return .{
            .instructions = .empty,
            .num_groups = 0,
            .unicode_properties = .empty,
            .first_char = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bytecode) void {
        if (!self.is_static) {
            for (self.unicode_properties.items) |prop| {
                self.allocator.free(prop);
            }
            self.unicode_properties.deinit(self.allocator);
            self.instructions.deinit(self.allocator);
        }
    }
    
    pub fn emit(self: *Bytecode, inst: Instruction) !usize {
        const idx = self.instructions.items.len;
        try self.instructions.append(self.allocator, inst);
        return idx;
    }
    
    pub fn patch(self: *Bytecode, idx: usize, target: usize) void {
        self.instructions.items[idx].target = target;
    }
    
    pub fn getPC(self: Bytecode) usize {
        return self.instructions.items.len;
    }
    
    pub fn dump(self: Bytecode, writer: *std.Io.Writer) !void {
        for (self.instructions.items, 0..) |inst, i| {
            try writer.print("{:4}: {f}\n", .{ i, inst });
        }
    }
};
