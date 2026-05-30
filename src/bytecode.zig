const std = @import("std");
const CharClass = @import("parser.zig").CharClass;
const RegexOptions = @import("options.zig").RegexOptions;

pub const OpCode = enum(u8) {
    // Basic instructions
    Char,          // match single character
    String,        // match literal string
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

    // Subroutine calls
    SubroutineCall,
    SubroutineReturn,

    // Newline sequence \R
    Newline,

    // Reset match start \K
    ResetMatchStart,

    // Not newline \N
    NotNewline,

    // Not vertical whitespace \V
    NotVerticalWhitespace,
};

pub const Instruction = union(OpCode) {
    Char: u8,
    String: []const u8,
    Any: void,
    CharClass: *CharClass,
    Split: usize,
    Jmp: usize,
    Match: void,
    Save: usize,
    AssertStart: void,
    AssertEnd: void,
    AssertStringStart: void,
    AssertStringEnd: void,
    AssertStringEndAllowNewline: void,
    AssertMatchStart: void,
    AssertForward: void,
    AssertForwardEnd: void,
    AssertForwardNegative: void,
    AssertBackward: ?usize, // fixed width, null = variable
    AssertBackwardEnd: void,
    AssertBackwardNegative: ?usize, // fixed width, null = variable
    Backref: usize,
    WordBoundary: void,
    NotWordBoundary: void,
    SetOption: RegexOptions,
    AtomicStart: void,
    AtomicEnd: void,
    UnicodeProperty: struct { property: []const u8, negated: bool },
    CharUtf8: u21,
    GraphemeCluster: void,
    Conditional: struct { group: usize, target: usize },
    SubroutineCall: struct { group: usize, target: usize },
    SubroutineReturn: void,
    Newline: void,
    ResetMatchStart: void,
    NotNewline: void,
    NotVerticalWhitespace: void,

    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Char => |ch| try writer.print("Char({c})", .{ch}),
            .String => |s| try writer.print("String({s})", .{s}),
            .Any => try writer.print("Any", .{}),
            .CharClass => try writer.print("CharClass", .{}),
            .Split => |target| try writer.print("Split -> {}", .{target}),
            .Jmp => |target| try writer.print("Jmp -> {}", .{target}),
            .Match => try writer.print("Match", .{}),
            .Save => |slot| try writer.print("Save({})", .{slot}),
            .AssertStart => try writer.print("AssertStart", .{}),
            .AssertEnd => try writer.print("AssertEnd", .{}),
            .AssertStringStart => try writer.print("AssertStringStart", .{}),
            .AssertStringEnd => try writer.print("AssertStringEnd", .{}),
            .AssertStringEndAllowNewline => try writer.print("AssertStringEndAllowNewline", .{}),
            .AssertMatchStart => try writer.print("AssertMatchStart", .{}),
            .AssertForward => try writer.print("AssertForward", .{}),
            .AssertForwardEnd => try writer.print("AssertForwardEnd", .{}),
            .AssertForwardNegative => try writer.print("AssertForwardNegative", .{}),
            .AssertBackward => |width| try writer.print("AssertBackward(width={?})", .{width}),
            .AssertBackwardEnd => try writer.print("AssertBackwardEnd", .{}),
            .AssertBackwardNegative => |width| try writer.print("AssertBackwardNegative(width={?})", .{width}),
            .Backref => |group| try writer.print("Backref({})", .{group}),
            .WordBoundary => try writer.print("WordBoundary", .{}),
            .NotWordBoundary => try writer.print("NotWordBoundary", .{}),
            .SetOption => try writer.print("SetOption", .{}),
            .AtomicStart => try writer.print("AtomicStart", .{}),
            .AtomicEnd => try writer.print("AtomicEnd", .{}),
            .UnicodeProperty => |p| try writer.print("UnicodeProperty({s}{s})", .{
                if (p.negated) "P{" else "p{",
                p.property, 
            }),
            .Conditional => |c| try writer.print("Conditional({}) -> {}", .{c.group, c.target}),
            .SubroutineCall => |s| try writer.print("SubroutineCall({}) -> {}", .{s.group, s.target}),
            .SubroutineReturn => try writer.print("SubroutineReturn", .{}),
            .Newline => try writer.print("Newline", .{}),
            .ResetMatchStart => try writer.print("ResetMatchStart", .{}),
            .NotNewline => try writer.print("NotNewline", .{}),
            .NotVerticalWhitespace => try writer.print("NotVerticalWhitespace", .{}),
            .CharUtf8 => |cp| try writer.print("CharUtf8(U+{X:0>4})", .{cp}),
            .GraphemeCluster => try writer.print("GraphemeCluster", .{}),
        }
    }
};

pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),
    num_groups: usize,
    unicode_properties: std.ArrayList([]const u8),
    strings: std.ArrayList([]const u8), // string pool for String opcode
    first_char: ?u8 = null, // first literal character, used for fast skipping in find()
    first_byte: ?u8 = null, // first byte of CharUtf8 literal, used for fast skipping in find()
    assert_ends: std.ArrayList(usize), // indexed by PC, contains end PC for assert instructions
    is_anchored: bool = false, // true if pattern starts with ^ or \A
    // Sunday skip table for fast skipping when pattern starts with a fixed string
    skip_table: [256]u16 = undefined,
    prefix_len: usize = 0,
    has_skip_table: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bytecode {
        return .{
            .instructions = .empty,
            .num_groups = 0,
            .unicode_properties = .empty,
            .strings = .empty,
            .first_char = null,
            .first_byte = null,
            .assert_ends = .empty,
            .is_anchored = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bytecode) void {
        for (self.unicode_properties.items) |prop| {
            self.allocator.free(prop);
        }
        self.unicode_properties.deinit(self.allocator);
        for (self.strings.items) |s| {
            self.allocator.free(s);
        }
        self.strings.deinit(self.allocator);
        self.instructions.deinit(self.allocator);
        self.assert_ends.deinit(self.allocator);
    }
    
    pub fn emit(self: *Bytecode, inst: Instruction) !usize {
        const idx = self.instructions.items.len;
        try self.instructions.append(self.allocator, inst);
        return idx;
    }
    
    pub fn patch(self: *Bytecode, idx: usize, target: usize) void {
        switch (self.instructions.items[idx]) {
            .Split => |*t| t.* = target,
            .Jmp => |*t| t.* = target,
            .Conditional => |*c| c.target = target,
            .SubroutineCall => |*s| s.target = target,
            else => unreachable,
        }
    }
    
    pub fn getPC(self: Bytecode) usize {
        return self.instructions.items.len;
    }
    
    pub fn dump(self: Bytecode, writer: *std.Io.Writer) !void {
        for (self.instructions.items, 0..) |inst, i| {
            try writer.print("{:3}: {s}\n", .{i, @tagName(inst)});
        }
    }
};
