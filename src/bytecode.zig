const std = @import("std");
const AstNode = @import("parser.zig").AstNode;
const NodeType = @import("parser.zig").NodeType;
const CharClass = @import("parser.zig").CharClass;

pub const OpCode = enum(u8) {
    // 基础指令
    Char,          // 匹配单个字符
    Any,           // 匹配任意字符
    CharClass,     // 匹配字符类
    
    // 控制流
    Split,         // 分裂执行 (NFA)
    Jmp,           // 跳转
    Match,         // 匹配成功
    
    // 分组
    Save,          // 保存捕获组位置
    
    // 零宽断言
    AssertStart,
    AssertEnd,
    AssertStringStart,       // \A
    AssertStringEnd,         // \z
    AssertStringEndAllowNewline, // \Z
    AssertForward,
    AssertForwardEnd,
    AssertForwardNegative,
    AssertBackward,
    AssertBackwardEnd,
    AssertBackwardNegative,

    // 反向引用
    Backref,

    // 单词边界
    WordBoundary,
    NotWordBoundary,
};

pub const Instruction = struct {
    opcode: OpCode,
    char: ?u8 = null,
    char_class: ?*CharClass = null,
    target: ?usize = null,
    save_slot: ?usize = null,
    backref_group: ?usize = null,
    
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
            .AssertForward => try writer.print("AssertForward", .{}),
            .AssertForwardEnd => try writer.print("AssertForwardEnd", .{}),
            .AssertForwardNegative => try writer.print("AssertForwardNegative", .{}),
            .AssertBackward => try writer.print("AssertBackward", .{}),
            .AssertBackwardEnd => try writer.print("AssertBackwardEnd", .{}),
            .AssertBackwardNegative => try writer.print("AssertBackwardNegative", .{}),
            .Backref => try writer.print("Backref({})", .{self.backref_group.?}),
            .WordBoundary => try writer.print("WordBoundary", .{}),
            .NotWordBoundary => try writer.print("NotWordBoundary", .{}),
        }
    }
};

pub const Bytecode = struct {
    instructions: std.ArrayList(Instruction),
    num_groups: usize,
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Bytecode {
        return .{
            .instructions = .empty,
            .num_groups = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Bytecode) void {
        self.instructions.deinit(self.allocator);
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
