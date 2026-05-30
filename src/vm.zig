const std = @import("std");
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;
const OpCode = @import("bytecode.zig").OpCode;
const RegexOptions = @import("options.zig").RegexOptions;
const unicode_case = @import("unicode_case.zig");

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

// Stack frame used for backtracking
const Frame = struct {
    pc: usize,
    pos: usize,
    capture_slot: ?usize,
    capture_old_value: ?usize,
    paired_capture_slot: ?usize = null,
    paired_capture_old_value: ?usize = null,
    options: RegexOptions,
    subroutine_stack_len: usize = 0,
};

/// Restore state from a backtrack frame, handling both main and sub-match modes.
fn backtrack(
    comptime is_sub: bool,
    frame: Frame,
    captures: *std.ArrayList(?usize),
    pc: *usize,
    pos: *usize,
    subroutine_stack: *std.ArrayList(usize),
    options: *RegexOptions,
) void {
    subroutine_stack.shrinkRetainingCapacity(frame.subroutine_stack_len);
    pc.* = frame.pc;
    pos.* = frame.pos;
    if (frame.capture_slot) |slot| {
        captures.items[slot] = frame.capture_old_value;
    }
    if (frame.paired_capture_slot) |slot| {
        captures.items[slot] = frame.paired_capture_old_value;
    }
    if (!is_sub) {
        options.* = frame.options;
    }
}

/// Pop frame and backtrack if stack is non-empty. Returns false if stack was empty.
fn maybeBacktrack(
    comptime is_sub: bool,
    stack: *std.ArrayList(Frame),
    captures: *std.ArrayList(?usize),
    pc: *usize,
    pos: *usize,
    subroutine_stack: *std.ArrayList(usize),
    options: *RegexOptions,
) bool {
    if (stack.items.len == 0) return false;
    backtrack(is_sub, stack.pop().?, captures, pc, pos, subroutine_stack, options);
    return true;
}

/// If `advance` is non-null, advance pc/pos and return true.
/// Otherwise backtrack and return whether backtracking succeeded.
fn tryMatchOpt(
    comptime is_sub: bool,
    stack: *std.ArrayList(Frame),
    captures: *std.ArrayList(?usize),
    pc: *usize,
    pos: *usize,
    subroutine_stack: *std.ArrayList(usize),
    options: *RegexOptions,
    advance: ?usize,
) bool {
    if (advance) |len| {
        pc.* += 1;
        pos.* += len;
        return true;
    }
    return maybeBacktrack(is_sub, stack, captures, pc, pos, subroutine_stack, options);
}

/// If `matched` is true, advance pc/pos by `advance_by` and return true.
/// Otherwise backtrack and return whether backtracking succeeded.
fn tryMatch(
    comptime is_sub: bool,
    stack: *std.ArrayList(Frame),
    captures: *std.ArrayList(?usize),
    pc: *usize,
    pos: *usize,
    subroutine_stack: *std.ArrayList(usize),
    options: *RegexOptions,
    matched: bool,
    advance_by: usize,
) bool {
    if (matched) {
        pc.* += 1;
        pos.* += advance_by;
        return true;
    }
    return maybeBacktrack(is_sub, stack, captures, pc, pos, subroutine_stack, options);
}

/// Match a CharClass instruction at the given position.
/// Returns the byte length to advance if matched, null otherwise.
inline fn matchCharClass(inst: Instruction, input: []const u8, pos: usize, case_sensitive: bool) ?usize {
    if (pos >= input.len) return null;
    const ch = input[pos];
    var matches = false;
    var advance_len: usize = 1;
    const cc = inst.char_class.?.*;

    // Check ranges and POSIX classes (ASCII single-byte)
    if (ch < 128 and cc.has_ranges_or_posix) {
        const range_match = if (case_sensitive)
            cc.contains(ch)
        else
            cc.contains(ch) or cc.contains(std.ascii.toLower(ch)) or cc.contains(std.ascii.toUpper(ch));
        const posix_match = if (case_sensitive)
            cc.containsPosixClass(ch)
        else
            cc.containsPosixClass(ch) or cc.containsPosixClass(std.ascii.toLower(ch)) or cc.containsPosixClass(std.ascii.toUpper(ch));
        matches = range_match or posix_match;
    }

    // Check Unicode ranges (both ASCII and non-ASCII)
    if (!matches and cc.has_unicode_ranges) {
        if (ch < 128) {
            matches = cc.containsUnicodeRange(ch);
        } else {
            const byte_len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
            if (pos + byte_len <= input.len) {
                const cp = std.unicode.utf8Decode(input[pos..pos + byte_len]) catch ch;
                if (cc.containsUnicodeRange(cp)) {
                    matches = true;
                    advance_len = byte_len;
                }
            }
        }
    }

    // Check Unicode properties (handles both ASCII and non-ASCII)
    if (!matches and cc.has_unicode_props) {
        if (matchUnicodePropertyInClass(input, pos, cc)) |byte_len| {
            matches = true;
            advance_len = byte_len;
        }
    }

    if (matches) return advance_len;
    return null;
}

/// Match a CharUtf8 instruction at the given position.
/// Returns the byte length to advance if matched, null otherwise.
inline fn matchCharUtf8(input: []const u8, pos: usize, expected_cp: u21, case_sensitive: bool) ?usize {
    if (pos >= input.len) return null;
    const first = input[pos];
    // Fast path for ASCII characters
    if (expected_cp < 128 and first < 128) {
        const matches = if (case_sensitive)
            first == expected_cp
        else
            std.ascii.toLower(first) == std.ascii.toLower(@intCast(expected_cp));
        if (matches) return 1;
        return null;
    }
    const byte_len = std.unicode.utf8ByteSequenceLength(first) catch return null;
    if (pos + byte_len > input.len) return null;
    const cp = std.unicode.utf8Decode(input[pos .. pos + byte_len]) catch return null;
    const matches = if (case_sensitive)
        cp == expected_cp
    else
        unicode_case.caseInsensitiveEqual(cp, expected_cp);
    if (matches) return byte_len;
    return null;
}

/// Find the end PC of an assert block (lookahead/lookbehind).
fn findAssertEnd(bytecode: []const Instruction, start_pc: usize) usize {
    var depth: usize = 1;
    var end_pc = start_pc;
    while (end_pc < bytecode.len) : (end_pc += 1) {
        const inst2 = bytecode[end_pc];
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

/// Match a backref at the given position.
/// Returns the byte length to advance if matched, null otherwise.
inline fn matchBackref(input: []const u8, pos: usize, captures: []const ?usize, group_idx: usize, case_sensitive: bool) ?usize {
    const start_slot = group_idx * 2;
    const end_slot = group_idx * 2 + 1;
    if (start_slot >= captures.len or end_slot >= captures.len) return null;
    const group_start = captures[start_slot];
    const group_end = captures[end_slot];
    if (group_start == null or group_end == null) return null;
    const group_text = input[group_start.?..group_end.?];
    const remaining = input[pos..];
    const matches = if (case_sensitive)
        remaining.len >= group_text.len and std.mem.startsWith(u8, remaining, group_text)
    else
        remaining.len >= group_text.len and unicode_case.unicodeEqlIgnoreCase(remaining[0..group_text.len], group_text);
    if (matches) return group_text.len;
    return null;
}

/// Check if position is at a word boundary.
inline fn checkWordBoundary(input: []const u8, pos: usize) bool {
    const left = if (pos > 0) isUnicodeWordChar(input, pos - 1) else false;
    const right = if (pos < input.len) isUnicodeWordChar(input, pos) else false;
    return left != right;
}

/// Check assert-start condition (^).
inline fn checkAssertStart(pos: usize, input: []const u8, multiline: bool) bool {
    return if (multiline) (pos == 0 or input[pos - 1] == '\n') else (pos == 0);
}

/// Check assert-end condition ($).
inline fn checkAssertEnd(pos: usize, input: []const u8, multiline: bool) bool {
    return if (multiline) (pos == input.len or input[pos] == '\n') else (pos == input.len);
}

fn isUnicodeProperty(cp: u21, property: []const u8) bool {
    // Fast path for ASCII characters
    if (cp < 128) {
        const ch: u8 = @intCast(cp);
        if (property.len == 1) {
            switch (property[0]) {
                'L' => return std.ascii.isAlphabetic(ch),
                'N' => return std.ascii.isDigit(ch),
                'P' => return std.ascii.isPunctuation(ch),
                'S' => return ch == '$' or ch == '+' or ch == '<' or ch == '=' or ch == '>' or ch == '^' or ch == '|' or ch == '~',
                'Z' => return std.ascii.isWhitespace(ch),
                'C' => return ch < 0x20 or ch == 0x7F,
                'M' => return false,
                else => {},
            }
        } else if (property.len == 2) {
            switch (property[0]) {
                'L' => switch (property[1]) {
                    'u' => return std.ascii.isUpper(ch),
                    'l' => return std.ascii.isLower(ch),
                    't', 'm', 'o' => return false,
                    else => {},
                },
                'N' => switch (property[1]) {
                    'd' => return std.ascii.isDigit(ch),
                    'l', 'o' => return false,
                    else => {},
                },
                'P' => switch (property[1]) {
                    'c' => return ch == '_',
                    'd' => return ch == '-',
                    's' => return ch == '(' or ch == '[' or ch == '{',
                    'e' => return ch == ')' or ch == ']' or ch == '}',
                    'i' => return ch == 0xAB,
                    'f' => return ch == 0xBB,
                    'o' => return std.ascii.isPunctuation(ch) and ch != '_' and ch != '-' and ch != '(' and ch != '[' and ch != '{' and ch != ')' and ch != ']' and ch != '}',
                    else => {},
                },
                'S' => switch (property[1]) {
                    'c' => return ch == '$',
                    'k' => return ch == '^' or ch == '`',
                    'm' => return ch == '+' or ch == '<' or ch == '=' or ch == '>' or ch == '|' or ch == '~',
                    'o' => return false,
                    else => {},
                },
                'Z' => switch (property[1]) {
                    's' => return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r',
                    'l', 'p' => return false,
                    else => {},
                },
                'C' => switch (property[1]) {
                    'c' => return ch < 0x20 or ch == 0x7F,
                    'f', 'o', 's' => return false,
                    else => {},
                },
                'M' => return false,
                else => {},
            }
        }
    }
    // Slow path for non-ASCII or unhandled properties
    if (property.len == 1 and property[0] == 'L') {
        // Letter: includes all letter subcategories
        return isUnicodeProperty(cp, "Lu") or
               isUnicodeProperty(cp, "Ll") or
               isUnicodeProperty(cp, "Lt") or
               isUnicodeProperty(cp, "Lm") or
               isUnicodeProperty(cp, "Lo");
    } else if (property.len == 2 and property[0] == 'L' and property[1] == 'u') {
        // Uppercase Letter
        return (cp >= 0x0041 and cp <= 0x005A) or
               (cp >= 0x00C0 and cp <= 0x00D6) or
               (cp >= 0x00D8 and cp <= 0x00DE) or
               (cp >= 0x0100 and cp <= 0x0136 and cp % 2 == 0) or
               (cp >= 0x0139 and cp <= 0x0147 and cp % 2 == 1) or
               (cp >= 0x014A and cp <= 0x0176 and cp % 2 == 0) or
               (cp >= 0x0386 and cp <= 0x0386) or
               (cp >= 0x0388 and cp <= 0x038A) or
               (cp >= 0x0391 and cp <= 0x03A1) or
               (cp >= 0x03A3 and cp <= 0x03AB) or
               (cp >= 0x0401 and cp <= 0x040C) or
               (cp >= 0x040E and cp <= 0x042F) or
               (cp >= 0x1F08 and cp <= 0x1F0F) or
               (cp >= 0x1F18 and cp <= 0x1F1D) or
               (cp >= 0x1F28 and cp <= 0x1F2F) or
               (cp >= 0x1F38 and cp <= 0x1F3F) or
               (cp >= 0x1F48 and cp <= 0x1F4D) or
               (cp >= 0x1F59 and cp <= 0x1F59) or
               (cp >= 0x1F5B and cp <= 0x1F5B) or
               (cp >= 0x1F5D and cp <= 0x1F5D) or
               (cp >= 0x1F5F and cp <= 0x1F5F) or
               (cp >= 0x1F68 and cp <= 0x1F6F) or
               (cp >= 0x1FB8 and cp <= 0x1FBB) or
               (cp >= 0x1FC8 and cp <= 0x1FCB) or
               (cp >= 0x1FD8 and cp <= 0x1FDB) or
               (cp >= 0x1FE8 and cp <= 0x1FEC) or
               (cp >= 0x1FF8 and cp <= 0x1FFB);
    } else if (property.len == 2 and property[0] == 'L' and property[1] == 'l') {
        // Lowercase Letter
        return (cp >= 0x0061 and cp <= 0x007A) or
               (cp >= 0x00DF and cp <= 0x00F6) or
               (cp >= 0x00F8 and cp <= 0x00FF) or
               (cp >= 0x0101 and cp <= 0x0137 and cp % 2 == 1) or
               (cp >= 0x0138 and cp <= 0x0138) or
               (cp >= 0x013A and cp <= 0x0148 and cp % 2 == 0) or
               (cp >= 0x0149 and cp <= 0x0149) or
               (cp >= 0x014B and cp <= 0x0177 and cp % 2 == 1) or
               (cp >= 0x017A and cp <= 0x017E and cp % 2 == 0) or
               (cp >= 0x03AC and cp <= 0x03CE) or
               (cp >= 0x0430 and cp <= 0x044F) or
               (cp >= 0x0451 and cp <= 0x045C) or
               (cp >= 0x045E and cp <= 0x045F) or
               (cp >= 0x1F00 and cp <= 0x1F07) or
               (cp >= 0x1F10 and cp <= 0x1F15) or
               (cp >= 0x1F20 and cp <= 0x1F27) or
               (cp >= 0x1F30 and cp <= 0x1F37) or
               (cp >= 0x1F40 and cp <= 0x1F45) or
               (cp >= 0x1F50 and cp <= 0x1F57) or
               (cp >= 0x1F60 and cp <= 0x1F67) or
               (cp >= 0x1F70 and cp <= 0x1F7D) or
               (cp >= 0x1F80 and cp <= 0x1F87) or
               (cp >= 0x1F90 and cp <= 0x1F97) or
               (cp >= 0x1FA0 and cp <= 0x1FA7) or
               (cp >= 0x1FB0 and cp <= 0x1FB1) or
               (cp >= 0x1FD0 and cp <= 0x1FD1) or
               (cp >= 0x1FE0 and cp <= 0x1FE1) or
               (cp >= 0x214E and cp <= 0x214E) or
               (cp >= 0x2170 and cp <= 0x217F);
    } else if (property.len == 2 and property[0] == 'L' and property[1] == 't') {
        // Titlecase Letter
        return (cp >= 0x01C5 and cp <= 0x01C5) or
               (cp >= 0x01C8 and cp <= 0x01C8) or
               (cp >= 0x01CB and cp <= 0x01CB) or
               (cp >= 0x01F2 and cp <= 0x01F2) or
               (cp >= 0x1F88 and cp <= 0x1F8F) or
               (cp >= 0x1F98 and cp <= 0x1F9F) or
               (cp >= 0x1FA8 and cp <= 0x1FAF) or
               (cp >= 0x1FBC and cp <= 0x1FBC) or
               (cp >= 0x1FCC and cp <= 0x1FCC) or
               (cp >= 0x1FFC and cp <= 0x1FFC);
    } else if (property.len == 2 and property[0] == 'L' and property[1] == 'm') {
        // Modifier Letter
        return (cp >= 0x02B0 and cp <= 0x02C1) or
               (cp >= 0x02C6 and cp <= 0x02D1) or
               (cp >= 0x02E0 and cp <= 0x02E4) or
               (cp >= 0x02EC and cp <= 0x02EC) or
               (cp >= 0x02EE and cp <= 0x02EE) or
               (cp >= 0x0374 and cp <= 0x0374) or
               (cp >= 0x037A and cp <= 0x037A) or
               (cp >= 0x0559 and cp <= 0x0559) or
               (cp >= 0x0640 and cp <= 0x0640) or
               (cp >= 0x06E5 and cp <= 0x06E6) or
               (cp >= 0x07F4 and cp <= 0x07F5) or
               (cp >= 0x07FA and cp <= 0x07FA) or
               (cp >= 0x0E46 and cp <= 0x0E46) or
               (cp >= 0x0EC6 and cp <= 0x0EC6) or
               (cp >= 0x10FC and cp <= 0x10FC) or
               (cp >= 0x17D7 and cp <= 0x17D7) or
               (cp >= 0x1843 and cp <= 0x1843) or
               (cp >= 0x1D2C and cp <= 0x1D6A) or
               (cp >= 0x1D78 and cp <= 0x1D78) or
               (cp >= 0x1D9B and cp <= 0x1DBF) or
               (cp >= 0x2071 and cp <= 0x2071) or
               (cp >= 0x207F and cp <= 0x207F) or
               (cp >= 0x2090 and cp <= 0x209C) or
               (cp >= 0x2C7C and cp <= 0x2C7D) or
               (cp >= 0x2D6F and cp <= 0x2D6F) or
               (cp >= 0x2E2F and cp <= 0x2E2F) or
               (cp >= 0x3005 and cp <= 0x3005) or
               (cp >= 0x3031 and cp <= 0x3035) or
               (cp >= 0x303B and cp <= 0x303B) or
               (cp >= 0x309D and cp <= 0x309E) or
               (cp >= 0x30FC and cp <= 0x30FE) or
               (cp >= 0xA015 and cp <= 0xA015) or
               (cp >= 0xA4F8 and cp <= 0xA4FD) or
               (cp >= 0xA60C and cp <= 0xA60C) or
               (cp >= 0xA67F and cp <= 0xA67F) or
               (cp >= 0xA69C and cp <= 0xA69D) or
               (cp >= 0xA717 and cp <= 0xA71F) or
               (cp >= 0xA770 and cp <= 0xA770) or
               (cp >= 0xA788 and cp <= 0xA788) or
               (cp >= 0xA7F8 and cp <= 0xA7F9) or
               (cp >= 0xA9CF and cp <= 0xA9CF) or
               (cp >= 0xAA70 and cp <= 0xAA70) or
               (cp >= 0xAADD and cp <= 0xAADD) or
               (cp >= 0xAAF3 and cp <= 0xAAF4) or
               (cp >= 0xFF70 and cp <= 0xFF70) or
               (cp >= 0xFF9E and cp <= 0xFF9F);
    } else if (property.len == 2 and property[0] == 'L' and property[1] == 'o') {
        // Other Letter
        return (cp >= 0x01BB and cp <= 0x01BB) or
               (cp >= 0x01C0 and cp <= 0x01C3) or
               (cp >= 0x0294 and cp <= 0x0294) or
               (cp >= 0x05D0 and cp <= 0x05EA) or
               (cp >= 0x05F0 and cp <= 0x05F2) or
               (cp >= 0x0621 and cp <= 0x063F) or
               (cp >= 0x0641 and cp <= 0x064A) or
               (cp >= 0x066E and cp <= 0x066F) or
               (cp >= 0x0671 and cp <= 0x06D3) or
               (cp >= 0x06D5 and cp <= 0x06D5) or
               (cp >= 0x06EE and cp <= 0x06EF) or
               (cp >= 0x06FA and cp <= 0x06FC) or
               (cp >= 0x06FF and cp <= 0x06FF) or
               (cp >= 0x0710 and cp <= 0x0710) or
               (cp >= 0x0712 and cp <= 0x072F) or
               (cp >= 0x074D and cp <= 0x07A5) or
               (cp >= 0x07B1 and cp <= 0x07B1) or
               (cp >= 0x07CA and cp <= 0x07EA) or
               (cp >= 0x0800 and cp <= 0x0815) or
               (cp >= 0x0840 and cp <= 0x0858) or
               (cp >= 0x08A0 and cp <= 0x08AC) or
               (cp >= 0x0904 and cp <= 0x0939) or
               (cp >= 0x093D and cp <= 0x093D) or
               (cp >= 0x0950 and cp <= 0x0950) or
               (cp >= 0x0958 and cp <= 0x0961) or
               (cp >= 0x0972 and cp <= 0x0980) or
               (cp >= 0x0985 and cp <= 0x098C) or
               (cp >= 0x098F and cp <= 0x0990) or
               (cp >= 0x0993 and cp <= 0x09A8) or
               (cp >= 0x09AA and cp <= 0x09B0) or
               (cp >= 0x09B2 and cp <= 0x09B2) or
               (cp >= 0x09B6 and cp <= 0x09B9) or
               (cp >= 0x09BD and cp <= 0x09BD) or
               (cp >= 0x09CE and cp <= 0x09CE) or
               (cp >= 0x09DC and cp <= 0x09DD) or
               (cp >= 0x09DF and cp <= 0x09E1) or
               (cp >= 0x09F0 and cp <= 0x09F1) or
               (cp >= 0x0A05 and cp <= 0x0A0A) or
               (cp >= 0x0A0F and cp <= 0x0A10) or
               (cp >= 0x0A13 and cp <= 0x0A28) or
               (cp >= 0x0A2A and cp <= 0x0A30) or
               (cp >= 0x0A32 and cp <= 0x0A33) or
               (cp >= 0x0A35 and cp <= 0x0A36) or
               (cp >= 0x0A38 and cp <= 0x0A39) or
               (cp >= 0x0A59 and cp <= 0x0A5C) or
               (cp >= 0x0A5E and cp <= 0x0A5E) or
               (cp >= 0x0A72 and cp <= 0x0A74) or
               (cp >= 0x0A85 and cp <= 0x0A8D) or
               (cp >= 0x0A8F and cp <= 0x0A91) or
               (cp >= 0x0A93 and cp <= 0x0AA8) or
               (cp >= 0x0AAA and cp <= 0x0AB0) or
               (cp >= 0x0AB2 and cp <= 0x0AB3) or
               (cp >= 0x0AB5 and cp <= 0x0AB9) or
               (cp >= 0x0ABD and cp <= 0x0ABD) or
               (cp >= 0x0AD0 and cp <= 0x0AD0) or
               (cp >= 0x0AE0 and cp <= 0x0AE1) or
               (cp >= 0x0B05 and cp <= 0x0B0C) or
               (cp >= 0x0B0F and cp <= 0x0B10) or
               (cp >= 0x0B13 and cp <= 0x0B28) or
               (cp >= 0x0B2A and cp <= 0x0B30) or
               (cp >= 0x0B32 and cp <= 0x0B33) or
               (cp >= 0x0B35 and cp <= 0x0B39) or
               (cp >= 0x0B3D and cp <= 0x0B3D) or
               (cp >= 0x0B5C and cp <= 0x0B5D) or
               (cp >= 0x0B5F and cp <= 0x0B61) or
               (cp >= 0x0B71 and cp <= 0x0B71) or
               (cp >= 0x0B83 and cp <= 0x0B83) or
               (cp >= 0x0B85 and cp <= 0x0B8A) or
               (cp >= 0x0B8E and cp <= 0x0B90) or
               (cp >= 0x0B92 and cp <= 0x0B95) or
               (cp >= 0x0B99 and cp <= 0x0B9A) or
               (cp >= 0x0B9C and cp <= 0x0B9C) or
               (cp >= 0x0B9E and cp <= 0x0B9F) or
               (cp >= 0x0BA3 and cp <= 0x0BA4) or
               (cp >= 0x0BA8 and cp <= 0x0BAA) or
               (cp >= 0x0BAE and cp <= 0x0BB9) or
               (cp >= 0x0BD0 and cp <= 0x0BD0) or
               (cp >= 0x0C05 and cp <= 0x0C0C) or
               (cp >= 0x0C0E and cp <= 0x0C10) or
               (cp >= 0x0C12 and cp <= 0x0C28) or
               (cp >= 0x0C2A and cp <= 0x0C39) or
               (cp >= 0x0C3D and cp <= 0x0C3D) or
               (cp >= 0x0C58 and cp <= 0x0C5A) or
               (cp >= 0x0C60 and cp <= 0x0C61) or
               (cp >= 0x0C85 and cp <= 0x0C8C) or
               (cp >= 0x0C8E and cp <= 0x0C90) or
               (cp >= 0x0C92 and cp <= 0x0CA8) or
               (cp >= 0x0CAA and cp <= 0x0CB3) or
               (cp >= 0x0CB5 and cp <= 0x0CB9) or
               (cp >= 0x0CBD and cp <= 0x0CBD) or
               (cp >= 0x0CDE and cp <= 0x0CDE) or
               (cp >= 0x0CE0 and cp <= 0x0CE1) or
               (cp >= 0x0CF1 and cp <= 0x0CF2) or
               (cp >= 0x0D05 and cp <= 0x0D0C) or
               (cp >= 0x0D0E and cp <= 0x0D10) or
               (cp >= 0x0D12 and cp <= 0x0D3A) or
               (cp >= 0x0D3D and cp <= 0x0D3D) or
               (cp >= 0x0D4E and cp <= 0x0D4E) or
               (cp >= 0x0D5F and cp <= 0x0D61) or
               (cp >= 0x0D7A and cp <= 0x0D7F) or
               (cp >= 0x0D85 and cp <= 0x0D96) or
               (cp >= 0x0D9A and cp <= 0x0DB1) or
               (cp >= 0x0DB3 and cp <= 0x0DBB) or
               (cp >= 0x0DBD and cp <= 0x0DBD) or
               (cp >= 0x0DC0 and cp <= 0x0DC6) or
               (cp >= 0x0E01 and cp <= 0x0E30) or
               (cp >= 0x0E32 and cp <= 0x0E33) or
               (cp >= 0x0E40 and cp <= 0x0E46) or
               (cp >= 0x0E81 and cp <= 0x0E82) or
               (cp >= 0x0E84 and cp <= 0x0E84) or
               (cp >= 0x0E87 and cp <= 0x0E88) or
               (cp >= 0x0E8A and cp <= 0x0E8A) or
               (cp >= 0x0E8D and cp <= 0x0E8D) or
               (cp >= 0x0E94 and cp <= 0x0E97) or
               (cp >= 0x0E99 and cp <= 0x0E9F) or
               (cp >= 0x0EA1 and cp <= 0x0EA3) or
               (cp >= 0x0EA5 and cp <= 0x0EA5) or
               (cp >= 0x0EA7 and cp <= 0x0EA7) or
               (cp >= 0x0EAA and cp <= 0x0EAB) or
               (cp >= 0x0EAD and cp <= 0x0EB0) or
               (cp >= 0x0EB2 and cp <= 0x0EB3) or
               (cp >= 0x0EBD and cp <= 0x0EBD) or
               (cp >= 0x0EC0 and cp <= 0x0EC4) or
               (cp >= 0x0EC6 and cp <= 0x0EC6) or
               (cp >= 0x0EDC and cp <= 0x0EDF) or
               (cp >= 0x0F00 and cp <= 0x0F00) or
               (cp >= 0x0F40 and cp <= 0x0F47) or
               (cp >= 0x0F49 and cp <= 0x0F6C) or
               (cp >= 0x0F88 and cp <= 0x0F8C) or
               (cp >= 0x1000 and cp <= 0x102A) or
               (cp >= 0x103F and cp <= 0x103F) or
               (cp >= 0x1050 and cp <= 0x1055) or
               (cp >= 0x105A and cp <= 0x105D) or
               (cp >= 0x1061 and cp <= 0x1061) or
               (cp >= 0x1065 and cp <= 0x1066) or
               (cp >= 0x106E and cp <= 0x1070) or
               (cp >= 0x1075 and cp <= 0x1081) or
               (cp >= 0x108E and cp <= 0x108E) or
               (cp >= 0x10A0 and cp <= 0x10C5) or
               (cp >= 0x10C7 and cp <= 0x10C7) or
               (cp >= 0x10CD and cp <= 0x10CD) or
               (cp >= 0x10D0 and cp <= 0x10FA) or
               (cp >= 0x10FC and cp <= 0x1248) or
               (cp >= 0x124A and cp <= 0x124D) or
               (cp >= 0x1250 and cp <= 0x1256) or
               (cp >= 0x1258 and cp <= 0x1258) or
               (cp >= 0x125A and cp <= 0x125D) or
               (cp >= 0x1260 and cp <= 0x1288) or
               (cp >= 0x128A and cp <= 0x128D) or
               (cp >= 0x1290 and cp <= 0x12B0) or
               (cp >= 0x12B2 and cp <= 0x12B5) or
               (cp >= 0x12B8 and cp <= 0x12BE) or
               (cp >= 0x12C0 and cp <= 0x12C0) or
               (cp >= 0x12C2 and cp <= 0x12C5) or
               (cp >= 0x12C8 and cp <= 0x12D6) or
               (cp >= 0x12D8 and cp <= 0x1310) or
               (cp >= 0x1312 and cp <= 0x1315) or
               (cp >= 0x1318 and cp <= 0x135A) or
               (cp >= 0x1380 and cp <= 0x138F) or
               (cp >= 0x13A0 and cp <= 0x13F5) or
               (cp >= 0x13F8 and cp <= 0x13FD) or
               (cp >= 0x1401 and cp <= 0x166C) or
               (cp >= 0x166F and cp <= 0x167F) or
               (cp >= 0x1681 and cp <= 0x169A) or
               (cp >= 0x16A0 and cp <= 0x16EA) or
               (cp >= 0x16EE and cp <= 0x16F0) or
               (cp >= 0x1700 and cp <= 0x170C) or
               (cp >= 0x170E and cp <= 0x1711) or
               (cp >= 0x1720 and cp <= 0x1731) or
               (cp >= 0x1740 and cp <= 0x1751) or
               (cp >= 0x1760 and cp <= 0x176C) or
               (cp >= 0x176E and cp <= 0x1770) or
               (cp >= 0x1780 and cp <= 0x17B3) or
               (cp >= 0x17D7 and cp <= 0x17D7) or
               (cp >= 0x17DC and cp <= 0x17DC) or
               (cp >= 0x1820 and cp <= 0x1877) or
               (cp >= 0x1880 and cp <= 0x1884) or
               (cp >= 0x1887 and cp <= 0x18A8) or
               (cp >= 0x18AA and cp <= 0x18AA) or
               (cp >= 0x18B0 and cp <= 0x18F5) or
               (cp >= 0x1900 and cp <= 0x191E) or
               (cp >= 0x1950 and cp <= 0x196D) or
               (cp >= 0x1970 and cp <= 0x1974) or
               (cp >= 0x1980 and cp <= 0x19AB) or
               (cp >= 0x19C1 and cp <= 0x19C7) or
               (cp >= 0x1A00 and cp <= 0x1A16) or
               (cp >= 0x1A20 and cp <= 0x1A54) or
               (cp >= 0x1AA7 and cp <= 0x1AA7) or
               (cp >= 0x1B05 and cp <= 0x1B33) or
               (cp >= 0x1B45 and cp <= 0x1B4B) or
               (cp >= 0x1B83 and cp <= 0x1BA0) or
               (cp >= 0x1BAE and cp <= 0x1BAF) or
               (cp >= 0x1BBA and cp <= 0x1BE5) or
               (cp >= 0x1C00 and cp <= 0x1C23) or
               (cp >= 0x1C4D and cp <= 0x1C4F) or
               (cp >= 0x1C5A and cp <= 0x1C7D) or
               (cp >= 0x1C80 and cp <= 0x1C88) or
               (cp >= 0x1CE9 and cp <= 0x1CEC) or
               (cp >= 0x1CEE and cp <= 0x1CF1) or
               (cp >= 0x1CF5 and cp <= 0x1CF6) or
               (cp >= 0x1D00 and cp <= 0x1DBF) or
               (cp >= 0x1E00 and cp <= 0x1F15) or
               (cp >= 0x1F18 and cp <= 0x1F1D) or
               (cp >= 0x1F20 and cp <= 0x1F45) or
               (cp >= 0x1F48 and cp <= 0x1F4D) or
               (cp >= 0x1F50 and cp <= 0x1F57) or
               (cp >= 0x1F59 and cp <= 0x1F59) or
               (cp >= 0x1F5B and cp <= 0x1F5B) or
               (cp >= 0x1F5D and cp <= 0x1F5D) or
               (cp >= 0x1F5F and cp <= 0x1F7D) or
               (cp >= 0x1F80 and cp <= 0x1FB4) or
               (cp >= 0x1FB6 and cp <= 0x1FBC) or
               (cp >= 0x1FBE and cp <= 0x1FBE) or
               (cp >= 0x1FC2 and cp <= 0x1FC4) or
               (cp >= 0x1FC6 and cp <= 0x1FCC) or
               (cp >= 0x1FD0 and cp <= 0x1FD3) or
               (cp >= 0x1FD6 and cp <= 0x1FDB) or
               (cp >= 0x1FE0 and cp <= 0x1FEC) or
               (cp >= 0x1FF2 and cp <= 0x1FF4) or
               (cp >= 0x1FF6 and cp <= 0x1FFC) or
               (cp >= 0x2071 and cp <= 0x2071) or
               (cp >= 0x207F and cp <= 0x207F) or
               (cp >= 0x2090 and cp <= 0x209C) or
               (cp >= 0x2102 and cp <= 0x2102) or
               (cp >= 0x2107 and cp <= 0x2107) or
               (cp >= 0x210A and cp <= 0x2113) or
               (cp >= 0x2115 and cp <= 0x2115) or
               (cp >= 0x2119 and cp <= 0x211D) or
               (cp >= 0x2124 and cp <= 0x2124) or
               (cp >= 0x2126 and cp <= 0x2126) or
               (cp >= 0x2128 and cp <= 0x2128) or
               (cp >= 0x212A and cp <= 0x212D) or
               (cp >= 0x212F and cp <= 0x2139) or
               (cp >= 0x213C and cp <= 0x213F) or
               (cp >= 0x2145 and cp <= 0x2149) or
               (cp >= 0x214E and cp <= 0x214E) or
               (cp >= 0x2183 and cp <= 0x2184) or
               (cp >= 0x2C00 and cp <= 0x2C2E) or
               (cp >= 0x2C30 and cp <= 0x2C5E) or
               (cp >= 0x2C60 and cp <= 0x2CE4) or
               (cp >= 0x2CEB and cp <= 0x2CEE) or
               (cp >= 0x2CF2 and cp <= 0x2CF3) or
               (cp >= 0x2D00 and cp <= 0x2D25) or
               (cp >= 0x2D27 and cp <= 0x2D27) or
               (cp >= 0x2D2D and cp <= 0x2D2D) or
               (cp >= 0x2D30 and cp <= 0x2D67) or
               (cp >= 0x2D6F and cp <= 0x2D6F) or
               (cp >= 0x2D80 and cp <= 0x2D96) or
               (cp >= 0x2DA0 and cp <= 0x2DA6) or
               (cp >= 0x2DA8 and cp <= 0x2DAE) or
               (cp >= 0x2DB0 and cp <= 0x2DB6) or
               (cp >= 0x2DB8 and cp <= 0x2DBE) or
               (cp >= 0x2DC0 and cp <= 0x2DC6) or
               (cp >= 0x2DC8 and cp <= 0x2DCE) or
               (cp >= 0x2DD0 and cp <= 0x2DD6) or
               (cp >= 0x2DD8 and cp <= 0x2DDE) or
               (cp >= 0x2E2F and cp <= 0x2E2F) or
               (cp >= 0x3005 and cp <= 0x3005) or
               (cp >= 0x3007 and cp <= 0x3007) or
               (cp >= 0x3021 and cp <= 0x3029) or
               (cp >= 0x3031 and cp <= 0x3035) or
               (cp >= 0x3038 and cp <= 0x303A) or
               (cp >= 0x303B and cp <= 0x303B) or
               (cp >= 0x303C and cp <= 0x303C) or
               (cp >= 0x3041 and cp <= 0x3096) or
               (cp >= 0x309D and cp <= 0x309F) or
               (cp >= 0x30A1 and cp <= 0x30FA) or
               (cp >= 0x30FC and cp <= 0x30FF) or
               (cp >= 0x3105 and cp <= 0x312D) or
               (cp >= 0x3131 and cp <= 0x318E) or
               (cp >= 0x31A0 and cp <= 0x31BA) or
               (cp >= 0x31F0 and cp <= 0x31FF) or
               (cp >= 0x3400 and cp <= 0x4DB5) or
               (cp >= 0x4E00 and cp <= 0x9FCC) or
               (cp >= 0xA000 and cp <= 0xA48C) or
               (cp >= 0xA4D0 and cp <= 0xA4FD) or
               (cp >= 0xA500 and cp <= 0xA60C) or
               (cp >= 0xA610 and cp <= 0xA61F) or
               (cp >= 0xA62A and cp <= 0xA62B) or
               (cp >= 0xA640 and cp <= 0xA66E) or
               (cp >= 0xA67F and cp <= 0xA697) or
               (cp >= 0xA6A0 and cp <= 0xA6E5) or
               (cp >= 0xA717 and cp <= 0xA71F) or
               (cp >= 0xA722 and cp <= 0xA788) or
               (cp >= 0xA78B and cp <= 0xA78E) or
               (cp >= 0xA790 and cp <= 0xA793) or
               (cp >= 0xA7A0 and cp <= 0xA7AA) or
               (cp >= 0xA7F8 and cp <= 0xA801) or
               (cp >= 0xA803 and cp <= 0xA805) or
               (cp >= 0xA807 and cp <= 0xA80A) or
               (cp >= 0xA80C and cp <= 0xA822) or
               (cp >= 0xA840 and cp <= 0xA873) or
               (cp >= 0xA882 and cp <= 0xA8B3) or
               (cp >= 0xA8F2 and cp <= 0xA8F7) or
               (cp >= 0xA8FB and cp <= 0xA8FB) or
               (cp >= 0xA90A and cp <= 0xA925) or
               (cp >= 0xA930 and cp <= 0xA946) or
               (cp >= 0xA960 and cp <= 0xA97C) or
               (cp >= 0xA984 and cp <= 0xA9B2) or
               (cp >= 0xA9CF and cp <= 0xA9CF) or
               (cp >= 0xA9E0 and cp <= 0xA9E4) or
               (cp >= 0xA9E6 and cp <= 0xA9EF) or
               (cp >= 0xA9FA and cp <= 0xA9FE) or
               (cp >= 0xAA00 and cp <= 0xAA28) or
               (cp >= 0xAA40 and cp <= 0xAA42) or
               (cp >= 0xAA44 and cp <= 0xAA4B) or
               (cp >= 0xAA60 and cp <= 0xAA76) or
               (cp >= 0xAA7A and cp <= 0xAA7A) or
               (cp >= 0xAA80 and cp <= 0xAAAF) or
               (cp >= 0xAAB1 and cp <= 0xAAB1) or
               (cp >= 0xAAB5 and cp <= 0xAAB6) or
               (cp >= 0xAAB9 and cp <= 0xAABD) or
               (cp >= 0xAAC0 and cp <= 0xAAC0) or
               (cp >= 0xAAC2 and cp <= 0xAAC2) or
               (cp >= 0xAADB and cp <= 0xAADD) or
               (cp >= 0xAAE0 and cp <= 0xAAEA) or
               (cp >= 0xAAF2 and cp <= 0xAAF4) or
               (cp >= 0xAB01 and cp <= 0xAB06) or
               (cp >= 0xAB09 and cp <= 0xAB0E) or
               (cp >= 0xAB11 and cp <= 0xAB16) or
               (cp >= 0xAB20 and cp <= 0xAB26) or
               (cp >= 0xAB28 and cp <= 0xAB2E) or
               (cp >= 0xAB30 and cp <= 0xAB5A) or
               (cp >= 0xAB5C and cp <= 0xAB5F) or
               (cp >= 0xAB60 and cp <= 0xAB65) or
               (cp >= 0xAB70 and cp <= 0xABBF) or
               (cp >= 0xABC0 and cp <= 0xABE2) or
               (cp >= 0xAC00 and cp <= 0xD7A3) or
               (cp >= 0xD7B0 and cp <= 0xD7C6) or
               (cp >= 0xD7CB and cp <= 0xD7FB) or
               (cp >= 0xF900 and cp <= 0xFA6D) or
               (cp >= 0xFA70 and cp <= 0xFAD9) or
               (cp >= 0xFB00 and cp <= 0xFB06) or
               (cp >= 0xFB13 and cp <= 0xFB17) or
               (cp >= 0xFB1D and cp <= 0xFB1D) or
               (cp >= 0xFB1F and cp <= 0xFB28) or
               (cp >= 0xFB2A and cp <= 0xFB36) or
               (cp >= 0xFB38 and cp <= 0xFB3C) or
               (cp >= 0xFB3E and cp <= 0xFB3E) or
               (cp >= 0xFB40 and cp <= 0xFB41) or
               (cp >= 0xFB43 and cp <= 0xFB44) or
               (cp >= 0xFB46 and cp <= 0xFBB1) or
               (cp >= 0xFBD3 and cp <= 0xFD3D) or
               (cp >= 0xFD50 and cp <= 0xFD8F) or
               (cp >= 0xFD92 and cp <= 0xFDC7) or
               (cp >= 0xFDF0 and cp <= 0xFDFB) or
               (cp >= 0xFE70 and cp <= 0xFE74) or
               (cp >= 0xFE76 and cp <= 0xFEFC) or
               (cp >= 0xFF66 and cp <= 0xFF6F) or
               (cp >= 0xFF71 and cp <= 0xFF9D) or
               (cp >= 0xFFA0 and cp <= 0xFFBE) or
               (cp >= 0xFFC2 and cp <= 0xFFC7) or
               (cp >= 0xFFCA and cp <= 0xFFCF) or
               (cp >= 0xFFD2 and cp <= 0xFFD7) or
               (cp >= 0xFFDA and cp <= 0xFFDC);
    } else if (property.len == 1 and property[0] == 'N') {
        return isUnicodeProperty(cp, "Nd") or
               isUnicodeProperty(cp, "Nl") or
               isUnicodeProperty(cp, "No");
    } else if (property.len == 2 and property[0] == 'N' and property[1] == 'd') {
        // Decimal Number
        return (cp >= 0x0030 and cp <= 0x0039) or
               (cp >= 0x0660 and cp <= 0x0669) or
               (cp >= 0x06F0 and cp <= 0x06F9) or
               (cp >= 0x07C0 and cp <= 0x07C9) or
               (cp >= 0x0966 and cp <= 0x096F) or
               (cp >= 0x09E6 and cp <= 0x09EF) or
               (cp >= 0x0A66 and cp <= 0x0A6F) or
               (cp >= 0x0AE6 and cp <= 0x0AEF) or
               (cp >= 0x0B66 and cp <= 0x0B6F) or
               (cp >= 0x0BE6 and cp <= 0x0BEF) or
               (cp >= 0x0C66 and cp <= 0x0C6F) or
               (cp >= 0x0CE6 and cp <= 0x0CEF) or
               (cp >= 0x0D66 and cp <= 0x0D6F) or
               (cp >= 0x0E50 and cp <= 0x0E59) or
               (cp >= 0x0ED0 and cp <= 0x0ED9) or
               (cp >= 0x0F20 and cp <= 0x0F29) or
               (cp >= 0x1040 and cp <= 0x1049) or
               (cp >= 0x1090 and cp <= 0x1099) or
               (cp >= 0x17E0 and cp <= 0x17E9) or
               (cp >= 0x1810 and cp <= 0x1819) or
               (cp >= 0x1946 and cp <= 0x194F) or
               (cp >= 0x19D0 and cp <= 0x19D9) or
               (cp >= 0x1A80 and cp <= 0x1A89) or
               (cp >= 0x1A90 and cp <= 0x1A99) or
               (cp >= 0x1B50 and cp <= 0x1B59) or
               (cp >= 0x1BB0 and cp <= 0x1BB9) or
               (cp >= 0x1C40 and cp <= 0x1C49) or
               (cp >= 0x1C50 and cp <= 0x1C59) or
               (cp >= 0xA620 and cp <= 0xA629) or
               (cp >= 0xA8D0 and cp <= 0xA8D9) or
               (cp >= 0xA900 and cp <= 0xA909) or
               (cp >= 0xA9D0 and cp <= 0xA9D9) or
               (cp >= 0xA9F0 and cp <= 0xA9F9) or
               (cp >= 0xAA50 and cp <= 0xAA59) or
               (cp >= 0xABF0 and cp <= 0xABF9) or
               (cp >= 0xFF10 and cp <= 0xFF19);
    } else if (property.len == 2 and property[0] == 'N' and property[1] == 'l') {
        // Letter Number
        return (cp >= 0x16EE and cp <= 0x16F0) or
               (cp >= 0x2160 and cp <= 0x2182) or
               (cp >= 0x2185 and cp <= 0x2188) or
               (cp >= 0x3007 and cp <= 0x3007) or
               (cp >= 0x3021 and cp <= 0x3029) or
               (cp >= 0x3038 and cp <= 0x303A) or
               (cp >= 0xA6E6 and cp <= 0xA6EF);
    } else if (property.len == 2 and property[0] == 'N' and property[1] == 'o') {
        // Other Number
        return (cp >= 0x00B2 and cp <= 0x00B3) or
               (cp >= 0x00B9 and cp <= 0x00B9) or
               (cp >= 0x00BC and cp <= 0x00BE) or
               (cp >= 0x09F4 and cp <= 0x09F9) or
               (cp >= 0x0B72 and cp <= 0x0B77) or
               (cp >= 0x0BF0 and cp <= 0x0BF2) or
               (cp >= 0x0C78 and cp <= 0x0C7E) or
               (cp >= 0x0D58 and cp <= 0x0D5E) or
               (cp >= 0x0D70 and cp <= 0x0D78) or
               (cp >= 0x0F2A and cp <= 0x0F33) or
               (cp >= 0x1369 and cp <= 0x1371) or
               (cp >= 0x17F0 and cp <= 0x17F9) or
               (cp >= 0x19DA and cp <= 0x19DA) or
               (cp >= 0x2070 and cp <= 0x2070) or
               (cp >= 0x2074 and cp <= 0x2079) or
               (cp >= 0x2080 and cp <= 0x2089) or
               (cp >= 0x2150 and cp <= 0x215F) or
               (cp >= 0x2189 and cp <= 0x2189) or
               (cp >= 0x2460 and cp <= 0x249B) or
               (cp >= 0x24EA and cp <= 0x24FF) or
               (cp >= 0x2776 and cp <= 0x2793) or
               (cp >= 0x2CFD and cp <= 0x2CFD) or
               (cp >= 0x3192 and cp <= 0x3195) or
               (cp >= 0x3220 and cp <= 0x3229) or
               (cp >= 0x3248 and cp <= 0x324F) or
               (cp >= 0x3251 and cp <= 0x325F) or
               (cp >= 0x3280 and cp <= 0x3289) or
               (cp >= 0x32B1 and cp <= 0x32BF) or
               (cp >= 0xA830 and cp <= 0xA835);
    } else if (property.len == 1 and property[0] == 'P') {
        return isUnicodeProperty(cp, "Pc") or
               isUnicodeProperty(cp, "Pd") or
               isUnicodeProperty(cp, "Ps") or
               isUnicodeProperty(cp, "Pe") or
               isUnicodeProperty(cp, "Pi") or
               isUnicodeProperty(cp, "Pf") or
               isUnicodeProperty(cp, "Po");
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 'c') {
        // Connector Punctuation
        return (cp >= 0x005F and cp <= 0x005F) or
               (cp >= 0x203F and cp <= 0x2040) or
               (cp >= 0x2054 and cp <= 0x2054) or
               (cp >= 0xFE33 and cp <= 0xFE34) or
               (cp >= 0xFE4D and cp <= 0xFE4F) or
               (cp >= 0xFF3F and cp <= 0xFF3F);
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 'd') {
        // Dash Punctuation
        return (cp >= 0x002D and cp <= 0x002D) or
               (cp >= 0x058A and cp <= 0x058A) or
               (cp >= 0x05BE and cp <= 0x05BE) or
               (cp >= 0x1400 and cp <= 0x1400) or
               (cp >= 0x1806 and cp <= 0x1806) or
               (cp >= 0x2010 and cp <= 0x2015) or
               (cp >= 0x2E17 and cp <= 0x2E17) or
               (cp >= 0x2E1A and cp <= 0x2E1A) or
               (cp >= 0x2E3A and cp <= 0x2E3B) or
               (cp >= 0x2E40 and cp <= 0x2E40) or
               (cp >= 0x301C and cp <= 0x301C) or
               (cp >= 0x3030 and cp <= 0x3030) or
               (cp >= 0x30A0 and cp <= 0x30A0) or
               (cp >= 0xFE31 and cp <= 0xFE32) or
               (cp >= 0xFE58 and cp <= 0xFE58) or
               (cp >= 0xFE63 and cp <= 0xFE63) or
               (cp >= 0xFF0D and cp <= 0xFF0D);
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 's') {
        // Open Punctuation
        return (cp >= 0x0028 and cp <= 0x0028) or
               (cp >= 0x005B and cp <= 0x005B) or
               (cp >= 0x007B and cp <= 0x007B) or
               (cp >= 0x0F3A and cp <= 0x0F3A) or
               (cp >= 0x0F3C and cp <= 0x0F3C) or
               (cp >= 0x169B and cp <= 0x169B) or
               (cp >= 0x201A and cp <= 0x201A) or
               (cp >= 0x201E and cp <= 0x201E) or
               (cp >= 0x2045 and cp <= 0x2045) or
               (cp >= 0x207D and cp <= 0x207D) or
               (cp >= 0x208D and cp <= 0x208D) or
               (cp >= 0x2308 and cp <= 0x2308) or
               (cp >= 0x230A and cp <= 0x230A) or
               (cp >= 0x2329 and cp <= 0x2329) or
               (cp >= 0x2768 and cp <= 0x2768) or
               (cp >= 0x276A and cp <= 0x276A) or
               (cp >= 0x276C and cp <= 0x276C) or
               (cp >= 0x276E and cp <= 0x276E) or
               (cp >= 0x2770 and cp <= 0x2770) or
               (cp >= 0x2772 and cp <= 0x2772) or
               (cp >= 0x2774 and cp <= 0x2774) or
               (cp >= 0x27C5 and cp <= 0x27C5) or
               (cp >= 0x27E6 and cp <= 0x27E6) or
               (cp >= 0x27E8 and cp <= 0x27E8) or
               (cp >= 0x27EA and cp <= 0x27EA) or
               (cp >= 0x27EC and cp <= 0x27EC) or
               (cp >= 0x27EE and cp <= 0x27EE) or
               (cp >= 0x2983 and cp <= 0x2983) or
               (cp >= 0x2985 and cp <= 0x2985) or
               (cp >= 0x2987 and cp <= 0x2987) or
               (cp >= 0x2989 and cp <= 0x2989) or
               (cp >= 0x298B and cp <= 0x298B) or
               (cp >= 0x298D and cp <= 0x298D) or
               (cp >= 0x298F and cp <= 0x298F) or
               (cp >= 0x2991 and cp <= 0x2991) or
               (cp >= 0x2993 and cp <= 0x2993) or
               (cp >= 0x2995 and cp <= 0x2995) or
               (cp >= 0x2997 and cp <= 0x2997) or
               (cp >= 0x29D8 and cp <= 0x29D8) or
               (cp >= 0x29DA and cp <= 0x29DA) or
               (cp >= 0x29FC and cp <= 0x29FC) or
               (cp >= 0x2E22 and cp <= 0x2E22) or
               (cp >= 0x2E24 and cp <= 0x2E24) or
               (cp >= 0x2E26 and cp <= 0x2E26) or
               (cp >= 0x2E28 and cp <= 0x2E28) or
               (cp >= 0x3008 and cp <= 0x3008) or
               (cp >= 0x300A and cp <= 0x300A) or
               (cp >= 0x300C and cp <= 0x300C) or
               (cp >= 0x300E and cp <= 0x300E) or
               (cp >= 0x3010 and cp <= 0x3010) or
               (cp >= 0x3014 and cp <= 0x3014) or
               (cp >= 0x3016 and cp <= 0x3016) or
               (cp >= 0x3018 and cp <= 0x3018) or
               (cp >= 0x301A and cp <= 0x301A) or
               (cp >= 0x301D and cp <= 0x301D) or
               (cp >= 0xFD3F and cp <= 0xFD3F) or
               (cp >= 0xFE17 and cp <= 0xFE17) or
               (cp >= 0xFE35 and cp <= 0xFE35) or
               (cp >= 0xFE37 and cp <= 0xFE37) or
               (cp >= 0xFE39 and cp <= 0xFE39) or
               (cp >= 0xFE3B and cp <= 0xFE3B) or
               (cp >= 0xFE3D and cp <= 0xFE3D) or
               (cp >= 0xFE3F and cp <= 0xFE3F) or
               (cp >= 0xFE41 and cp <= 0xFE41) or
               (cp >= 0xFE43 and cp <= 0xFE43) or
               (cp >= 0xFE47 and cp <= 0xFE47) or
               (cp >= 0xFE59 and cp <= 0xFE59) or
               (cp >= 0xFE5B and cp <= 0xFE5B) or
               (cp >= 0xFE5D and cp <= 0xFE5D) or
               (cp >= 0xFF08 and cp <= 0xFF08) or
               (cp >= 0xFF3B and cp <= 0xFF3B) or
               (cp >= 0xFF5B and cp <= 0xFF5B) or
               (cp >= 0xFF5F and cp <= 0xFF5F) or
               (cp >= 0xFF62 and cp <= 0xFF62);
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 'e') {
        // Close Punctuation
        return (cp >= 0x0029 and cp <= 0x0029) or
               (cp >= 0x005D and cp <= 0x005D) or
               (cp >= 0x007D and cp <= 0x007D) or
               (cp >= 0x0F3B and cp <= 0x0F3B) or
               (cp >= 0x0F3D and cp <= 0x0F3D) or
               (cp >= 0x169C and cp <= 0x169C) or
               (cp >= 0x2046 and cp <= 0x2046) or
               (cp >= 0x207E and cp <= 0x207E) or
               (cp >= 0x208E and cp <= 0x208E) or
               (cp >= 0x2309 and cp <= 0x2309) or
               (cp >= 0x230B and cp <= 0x230B) or
               (cp >= 0x232A and cp <= 0x232A) or
               (cp >= 0x2769 and cp <= 0x2769) or
               (cp >= 0x276B and cp <= 0x276B) or
               (cp >= 0x276D and cp <= 0x276D) or
               (cp >= 0x276F and cp <= 0x276F) or
               (cp >= 0x2771 and cp <= 0x2771) or
               (cp >= 0x2773 and cp <= 0x2773) or
               (cp >= 0x2775 and cp <= 0x2775) or
               (cp >= 0x27C6 and cp <= 0x27C6) or
               (cp >= 0x27E7 and cp <= 0x27E7) or
               (cp >= 0x27E9 and cp <= 0x27E9) or
               (cp >= 0x27EB and cp <= 0x27EB) or
               (cp >= 0x27ED and cp <= 0x27ED) or
               (cp >= 0x27EF and cp <= 0x27EF) or
               (cp >= 0x2984 and cp <= 0x2984) or
               (cp >= 0x2986 and cp <= 0x2986) or
               (cp >= 0x2988 and cp <= 0x2988) or
               (cp >= 0x298A and cp <= 0x298A) or
               (cp >= 0x298C and cp <= 0x298C) or
               (cp >= 0x298E and cp <= 0x298E) or
               (cp >= 0x2990 and cp <= 0x2990) or
               (cp >= 0x2992 and cp <= 0x2992) or
               (cp >= 0x2994 and cp <= 0x2994) or
               (cp >= 0x2996 and cp <= 0x2996) or
               (cp >= 0x2998 and cp <= 0x2998) or
               (cp >= 0x29D9 and cp <= 0x29D9) or
               (cp >= 0x29DB and cp <= 0x29DB) or
               (cp >= 0x29FD and cp <= 0x29FD) or
               (cp >= 0x2E23 and cp <= 0x2E23) or
               (cp >= 0x2E25 and cp <= 0x2E25) or
               (cp >= 0x2E27 and cp <= 0x2E27) or
               (cp >= 0x2E29 and cp <= 0x2E29) or
               (cp >= 0x3009 and cp <= 0x3009) or
               (cp >= 0x300B and cp <= 0x300B) or
               (cp >= 0x300D and cp <= 0x300D) or
               (cp >= 0x300F and cp <= 0x300F) or
               (cp >= 0x3011 and cp <= 0x3011) or
               (cp >= 0x3015 and cp <= 0x3015) or
               (cp >= 0x3017 and cp <= 0x3017) or
               (cp >= 0x3019 and cp <= 0x3019) or
               (cp >= 0x301B and cp <= 0x301B) or
               (cp >= 0x301E and cp <= 0x301F) or
               (cp >= 0xFD3E and cp <= 0xFD3E) or
               (cp >= 0xFE18 and cp <= 0xFE18) or
               (cp >= 0xFE36 and cp <= 0xFE36) or
               (cp >= 0xFE38 and cp <= 0xFE38) or
               (cp >= 0xFE3A and cp <= 0xFE3A) or
               (cp >= 0xFE3C and cp <= 0xFE3C) or
               (cp >= 0xFE3E and cp <= 0xFE3E) or
               (cp >= 0xFE40 and cp <= 0xFE40) or
               (cp >= 0xFE42 and cp <= 0xFE42) or
               (cp >= 0xFE44 and cp <= 0xFE44) or
               (cp >= 0xFE48 and cp <= 0xFE48) or
               (cp >= 0xFE5A and cp <= 0xFE5A) or
               (cp >= 0xFE5C and cp <= 0xFE5C) or
               (cp >= 0xFE5E and cp <= 0xFE5E) or
               (cp >= 0xFF09 and cp <= 0xFF09) or
               (cp >= 0xFF3D and cp <= 0xFF3D) or
               (cp >= 0xFF5D and cp <= 0xFF5D) or
               (cp >= 0xFF60 and cp <= 0xFF60) or
               (cp >= 0xFF63 and cp <= 0xFF63);
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 'i') {
        // Initial Punctuation
        return (cp >= 0x00AB and cp <= 0x00AB) or
               (cp >= 0x2018 and cp <= 0x2018) or
               (cp >= 0x201B and cp <= 0x201C) or
               (cp >= 0x201F and cp <= 0x201F) or
               (cp >= 0x2039 and cp <= 0x2039);
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 'f') {
        // Final Punctuation
        return (cp >= 0x00BB and cp <= 0x00BB) or
               (cp >= 0x2019 and cp <= 0x2019) or
               (cp >= 0x201D and cp <= 0x201D) or
               (cp >= 0x203A and cp <= 0x203A);
    } else if (property.len == 2 and property[0] == 'P' and property[1] == 'o') {
        // Other Punctuation
        return (cp >= 0x0021 and cp <= 0x0023) or
               (cp >= 0x0025 and cp <= 0x002A) or
               (cp >= 0x002C and cp <= 0x002C) or
               (cp >= 0x002E and cp <= 0x002F) or
               (cp >= 0x003A and cp <= 0x003B) or
               (cp >= 0x003F and cp <= 0x0040) or
               (cp >= 0x005C and cp <= 0x005C) or
               (cp >= 0x00A1 and cp <= 0x00A1) or
               (cp >= 0x00A7 and cp <= 0x00A7) or
               (cp >= 0x00B6 and cp <= 0x00B7) or
               (cp >= 0x00BF and cp <= 0x00BF) or
               (cp >= 0x037E and cp <= 0x037E) or
               (cp >= 0x0387 and cp <= 0x0387) or
               (cp >= 0x055A and cp <= 0x055F) or
               (cp >= 0x0589 and cp <= 0x0589) or
               (cp >= 0x05C0 and cp <= 0x05C0) or
               (cp >= 0x05C3 and cp <= 0x05C3) or
               (cp >= 0x05C6 and cp <= 0x05C6) or
               (cp >= 0x05F3 and cp <= 0x05F4) or
               (cp >= 0x0609 and cp <= 0x060A) or
               (cp >= 0x060C and cp <= 0x060D) or
               (cp >= 0x061B and cp <= 0x061B) or
               (cp >= 0x061E and cp <= 0x061F) or
               (cp >= 0x066A and cp <= 0x066D) or
               (cp >= 0x06D4 and cp <= 0x06D4) or
               (cp >= 0x0700 and cp <= 0x070D) or
               (cp >= 0x07F7 and cp <= 0x07F9) or
               (cp >= 0x0830 and cp <= 0x083E) or
               (cp >= 0x085E and cp <= 0x085E) or
               (cp >= 0x0964 and cp <= 0x0965) or
               (cp >= 0x0970 and cp <= 0x0970) or
               (cp >= 0x09FD and cp <= 0x09FD) or
               (cp >= 0x0A76 and cp <= 0x0A76) or
               (cp >= 0x0AF0 and cp <= 0x0AF0) or
               (cp >= 0x0C77 and cp <= 0x0C77) or
               (cp >= 0x0C84 and cp <= 0x0C84) or
               (cp >= 0x0DF4 and cp <= 0x0DF4) or
               (cp >= 0x0E4F and cp <= 0x0E4F) or
               (cp >= 0x0E5A and cp <= 0x0E5B) or
               (cp >= 0x0F04 and cp <= 0x0F12) or
               (cp >= 0x0F14 and cp <= 0x0F14) or
               (cp >= 0x0F3A and cp <= 0x0F3D) or
               (cp >= 0x0F85 and cp <= 0x0F85) or
               (cp >= 0x0FD0 and cp <= 0x0FD4) or
               (cp >= 0x0FD9 and cp <= 0x0FDA) or
               (cp >= 0x104A and cp <= 0x104F) or
               (cp >= 0x10FB and cp <= 0x10FB) or
               (cp >= 0x1360 and cp <= 0x1368) or
               (cp >= 0x166E and cp <= 0x166E) or
               (cp >= 0x169B and cp <= 0x169C) or
               (cp >= 0x16EB and cp <= 0x16ED) or
               (cp >= 0x1735 and cp <= 0x1736) or
               (cp >= 0x17D4 and cp <= 0x17D6) or
               (cp >= 0x17D8 and cp <= 0x17DA) or
               (cp >= 0x1800 and cp <= 0x1805) or
               (cp >= 0x1807 and cp <= 0x180A) or
               (cp >= 0x1944 and cp <= 0x1945) or
               (cp >= 0x1A1E and cp <= 0x1A1F) or
               (cp >= 0x1AA0 and cp <= 0x1AA6) or
               (cp >= 0x1AA8 and cp <= 0x1AAD) or
               (cp >= 0x1B5A and cp <= 0x1B60) or
               (cp >= 0x1BFC and cp <= 0x1BFF) or
               (cp >= 0x1C3B and cp <= 0x1C3F) or
               (cp >= 0x1C7E and cp <= 0x1C7F) or
               (cp >= 0x1CC0 and cp <= 0x1CC7) or
               (cp >= 0x1CD3 and cp <= 0x1CD3) or
               (cp >= 0x2010 and cp <= 0x2027) or
               (cp >= 0x2030 and cp <= 0x2043) or
               (cp >= 0x2045 and cp <= 0x2051) or
               (cp >= 0x2053 and cp <= 0x205E) or
               (cp >= 0x207D and cp <= 0x207E) or
               (cp >= 0x208D and cp <= 0x208E) or
               (cp >= 0x2308 and cp <= 0x230B) or
               (cp >= 0x2329 and cp <= 0x232A) or
               (cp >= 0x2768 and cp <= 0x2775) or
               (cp >= 0x27C5 and cp <= 0x27C6) or
               (cp >= 0x27E6 and cp <= 0x27EF) or
               (cp >= 0x2983 and cp <= 0x2998) or
               (cp >= 0x29D8 and cp <= 0x29DB) or
               (cp >= 0x29FC and cp <= 0x29FD) or
               (cp >= 0x2CF9 and cp <= 0x2CFC) or
               (cp >= 0x2CFE and cp <= 0x2CFF) or
               (cp >= 0x2D70 and cp <= 0x2D70) or
               (cp >= 0x2E00 and cp <= 0x2E2E) or
               (cp >= 0x2E30 and cp <= 0x2E4F) or
               (cp >= 0x2E52 and cp <= 0x2E5D) or
               (cp >= 0x3001 and cp <= 0x3003) or
               (cp >= 0x303D and cp <= 0x303D) or
               (cp >= 0x30FB and cp <= 0x30FB) or
               (cp >= 0xA4FE and cp <= 0xA4FF) or
               (cp >= 0xA60D and cp <= 0xA60F) or
               (cp >= 0xA673 and cp <= 0xA673) or
               (cp >= 0xA67E and cp <= 0xA67E) or
               (cp >= 0xA6F2 and cp <= 0xA6F7) or
               (cp >= 0xA874 and cp <= 0xA877) or
               (cp >= 0xA8CE and cp <= 0xA8CF) or
               (cp >= 0xA8F8 and cp <= 0xA8FA) or
               (cp >= 0xA8FC and cp <= 0xA8FC) or
               (cp >= 0xA92E and cp <= 0xA92F) or
               (cp >= 0xA95F and cp <= 0xA95F) or
               (cp >= 0xA9C1 and cp <= 0xA9CD) or
               (cp >= 0xA9DE and cp <= 0xA9DF) or
               (cp >= 0xAA5C and cp <= 0xAA5F) or
               (cp >= 0xAADE and cp <= 0xAADF) or
               (cp >= 0xAAF0 and cp <= 0xAAF1) or
               (cp >= 0xABEB and cp <= 0xABEB) or
               (cp >= 0xFE10 and cp <= 0xFE19) or
               (cp >= 0xFE30 and cp <= 0xFE52) or
               (cp >= 0xFE54 and cp <= 0xFE61) or
               (cp >= 0xFE63 and cp <= 0xFE63) or
               (cp >= 0xFE68 and cp <= 0xFE68) or
               (cp >= 0xFE6A and cp <= 0xFE6B) or
               (cp >= 0xFF01 and cp <= 0xFF03) or
               (cp >= 0xFF05 and cp <= 0xFF0A) or
               (cp >= 0xFF0C and cp <= 0xFF0C) or
               (cp >= 0xFF0E and cp <= 0xFF0F) or
               (cp >= 0xFF1A and cp <= 0xFF1B) or
               (cp >= 0xFF1F and cp <= 0xFF20) or
               (cp >= 0xFF3C and cp <= 0xFF3C) or
               (cp >= 0xFF61 and cp <= 0xFF61) or
               (cp >= 0xFF64 and cp <= 0xFF65);
    } else if (property.len == 1 and property[0] == 'S') {
        return isUnicodeProperty(cp, "Sc") or
               isUnicodeProperty(cp, "Sk") or
               isUnicodeProperty(cp, "Sm") or
               isUnicodeProperty(cp, "So");
    } else if (property.len == 2 and property[0] == 'S' and property[1] == 'c') {
        // Currency Symbol
        return (cp >= 0x0024 and cp <= 0x0024) or
               (cp >= 0x00A2 and cp <= 0x00A5) or
               (cp >= 0x058F and cp <= 0x058F) or
               (cp >= 0x060B and cp <= 0x060B) or
               (cp >= 0x09F2 and cp <= 0x09F3) or
               (cp >= 0x09FB and cp <= 0x09FB) or
               (cp >= 0x0AF1 and cp <= 0x0AF1) or
               (cp >= 0x0BF9 and cp <= 0x0BF9) or
               (cp >= 0x0E3F and cp <= 0x0E3F) or
               (cp >= 0x17DB and cp <= 0x17DB) or
               (cp >= 0x20A0 and cp <= 0x20C0) or
               (cp >= 0xA838 and cp <= 0xA838) or
               (cp >= 0xFDFC and cp <= 0xFDFC) or
               (cp >= 0xFE69 and cp <= 0xFE69) or
               (cp >= 0xFF04 and cp <= 0xFF04) or
               (cp >= 0xFFE0 and cp <= 0xFFE1) or
               (cp >= 0xFFE5 and cp <= 0xFFE6);
    } else if (property.len == 2 and property[0] == 'S' and property[1] == 'k') {
        // Modifier Symbol
        return (cp >= 0x005E and cp <= 0x005E) or
               (cp >= 0x0060 and cp <= 0x0060) or
               (cp >= 0x00A8 and cp <= 0x00A8) or
               (cp >= 0x00AF and cp <= 0x00AF) or
               (cp >= 0x00B4 and cp <= 0x00B4) or
               (cp >= 0x00B8 and cp <= 0x00B8) or
               (cp >= 0x02C2 and cp <= 0x02C5) or
               (cp >= 0x02D2 and cp <= 0x02DF) or
               (cp >= 0x02E5 and cp <= 0x02EB) or
               (cp >= 0x02ED and cp <= 0x02ED) or
               (cp >= 0x02EF and cp <= 0x02FF) or
               (cp >= 0x0375 and cp <= 0x0375) or
               (cp >= 0x0384 and cp <= 0x0385) or
               (cp >= 0x1FBD and cp <= 0x1FBD) or
               (cp >= 0x1FBF and cp <= 0x1FC1) or
               (cp >= 0x1FCD and cp <= 0x1FCF) or
               (cp >= 0x1FDD and cp <= 0x1FDF) or
               (cp >= 0x1FED and cp <= 0x1FEF) or
               (cp >= 0x1FFD and cp <= 0x1FFE) or
               (cp >= 0x309B and cp <= 0x309C) or
               (cp >= 0xA700 and cp <= 0xA716) or
               (cp >= 0xA720 and cp <= 0xA721) or
               (cp >= 0xA789 and cp <= 0xA78A) or
               (cp >= 0xAB5B and cp <= 0xAB5B) or
               (cp >= 0xFBB2 and cp <= 0xFBC1) or
               (cp >= 0xFF3E and cp <= 0xFF3E) or
               (cp >= 0xFF40 and cp <= 0xFF40) or
               (cp >= 0xFFE3 and cp <= 0xFFE3);
    } else if (property.len == 2 and property[0] == 'S' and property[1] == 'm') {
        // Math Symbol
        return (cp >= 0x002B and cp <= 0x002B) or
               (cp >= 0x003C and cp <= 0x003E) or
               (cp >= 0x007C and cp <= 0x007C) or
               (cp >= 0x007E and cp <= 0x007E) or
               (cp >= 0x00AC and cp <= 0x00AC) or
               (cp >= 0x00B1 and cp <= 0x00B1) or
               (cp >= 0x00D7 and cp <= 0x00D7) or
               (cp >= 0x00F7 and cp <= 0x00F7) or
               (cp >= 0x03F6 and cp <= 0x03F6) or
               (cp >= 0x0606 and cp <= 0x0608) or
               (cp >= 0x2044 and cp <= 0x2044) or
               (cp >= 0x2052 and cp <= 0x2052) or
               (cp >= 0x207A and cp <= 0x207C) or
               (cp >= 0x208A and cp <= 0x208C) or
               (cp >= 0x2118 and cp <= 0x2118) or
               (cp >= 0x2140 and cp <= 0x2144) or
               (cp >= 0x214B and cp <= 0x214B) or
               (cp >= 0x2190 and cp <= 0x2194) or
               (cp >= 0x219A and cp <= 0x219B) or
               (cp >= 0x21A0 and cp <= 0x21A0) or
               (cp >= 0x21A3 and cp <= 0x21A3) or
               (cp >= 0x21A6 and cp <= 0x21A6) or
               (cp >= 0x21AE and cp <= 0x21AE) or
               (cp >= 0x21CE and cp <= 0x21CF) or
               (cp >= 0x21D2 and cp <= 0x21D2) or
               (cp >= 0x21D4 and cp <= 0x21D4) or
               (cp >= 0x21F4 and cp <= 0x22FF) or
               (cp >= 0x2320 and cp <= 0x2321) or
               (cp >= 0x237C and cp <= 0x237C) or
               (cp >= 0x239B and cp <= 0x23B3) or
               (cp >= 0x23DC and cp <= 0x23E1) or
               (cp >= 0x25B7 and cp <= 0x25B7) or
               (cp >= 0x25C1 and cp <= 0x25C1) or
               (cp >= 0x25F8 and cp <= 0x25FF) or
               (cp >= 0x266F and cp <= 0x266F) or
               (cp >= 0x27C0 and cp <= 0x27C4) or
               (cp >= 0x27C7 and cp <= 0x27E5) or
               (cp >= 0x27F0 and cp <= 0x27FF) or
               (cp >= 0x2900 and cp <= 0x2982) or
               (cp >= 0x2999 and cp <= 0x29D7) or
               (cp >= 0x29DC and cp <= 0x29FB) or
               (cp >= 0x29FE and cp <= 0x2AFF) or
               (cp >= 0x2B30 and cp <= 0x2B44) or
               (cp >= 0x2B47 and cp <= 0x2B4C) or
               (cp >= 0xFB29 and cp <= 0xFB29) or
               (cp >= 0xFDFC and cp <= 0xFDFC) or
               (cp >= 0xFE62 and cp <= 0xFE62) or
               (cp >= 0xFE64 and cp <= 0xFE66) or
               (cp >= 0xFF0B and cp <= 0xFF0B) or
               (cp >= 0xFF1C and cp <= 0xFF1E) or
               (cp >= 0xFF5C and cp <= 0xFF5C) or
               (cp >= 0xFF5E and cp <= 0xFF5E) or
               (cp >= 0xFFE2 and cp <= 0xFFE2) or
               (cp >= 0xFFE9 and cp <= 0xFFEC);
    } else if (property.len == 2 and property[0] == 'S' and property[1] == 'o') {
        // Other Symbol
        return (cp >= 0x00A6 and cp <= 0x00A7) or
               (cp >= 0x00A9 and cp <= 0x00A9) or
               (cp >= 0x00AE and cp <= 0x00AE) or
               (cp >= 0x00B0 and cp <= 0x00B0) or
               (cp >= 0x0482 and cp <= 0x0482) or
               (cp >= 0x060E and cp <= 0x060F) or
               (cp >= 0x06DE and cp <= 0x06DE) or
               (cp >= 0x06E9 and cp <= 0x06E9) or
               (cp >= 0x06FD and cp <= 0x06FE) or
               (cp >= 0x07F6 and cp <= 0x07F6) or
               (cp >= 0x09FA and cp <= 0x09FA) or
               (cp >= 0x0B70 and cp <= 0x0B70) or
               (cp >= 0x0BF3 and cp <= 0x0BF8) or
               (cp >= 0x0BFA and cp <= 0x0BFA) or
               (cp >= 0x0C7F and cp <= 0x0C7F) or
               (cp >= 0x0D4F and cp <= 0x0D4F) or
               (cp >= 0x0D79 and cp <= 0x0D79) or
               (cp >= 0x0F01 and cp <= 0x0F03) or
               (cp >= 0x0F13 and cp <= 0x0F17) or
               (cp >= 0x0F1A and cp <= 0x0F1F) or
               (cp >= 0x0F34 and cp <= 0x0F34) or
               (cp >= 0x0F36 and cp <= 0x0F36) or
               (cp >= 0x0F38 and cp <= 0x0F38) or
               (cp >= 0x0FBE and cp <= 0x0FC5) or
               (cp >= 0x0FC7 and cp <= 0x0FCC) or
               (cp >= 0x0FCE and cp <= 0x0FD4) or
               (cp >= 0x0FD9 and cp <= 0x0FDA) or
               (cp >= 0x109E and cp <= 0x109F) or
               (cp >= 0x1360 and cp <= 0x1360) or
               (cp >= 0x1390 and cp <= 0x1399) or
               (cp >= 0x1940 and cp <= 0x1940) or
               (cp >= 0x19DE and cp <= 0x19FF) or
               (cp >= 0x1B61 and cp <= 0x1B6A) or
               (cp >= 0x1B74 and cp <= 0x1B7C) or
               (cp >= 0x2100 and cp <= 0x2101) or
               (cp >= 0x2103 and cp <= 0x2106) or
               (cp >= 0x2108 and cp <= 0x2109) or
               (cp >= 0x2114 and cp <= 0x2114) or
               (cp >= 0x2116 and cp <= 0x2117) or
               (cp >= 0x211E and cp <= 0x2123) or
               (cp >= 0x2125 and cp <= 0x2125) or
               (cp >= 0x2127 and cp <= 0x2127) or
               (cp >= 0x2129 and cp <= 0x2129) or
               (cp >= 0x212E and cp <= 0x212E) or
               (cp >= 0x213A and cp <= 0x213B) or
               (cp >= 0x214A and cp <= 0x214A) or
               (cp >= 0x214C and cp <= 0x214D) or
               (cp >= 0x214F and cp <= 0x214F) or
               (cp >= 0x2195 and cp <= 0x2199) or
               (cp >= 0x219C and cp <= 0x219F) or
               (cp >= 0x21A1 and cp <= 0x21A2) or
               (cp >= 0x21A4 and cp <= 0x21A5) or
               (cp >= 0x21A7 and cp <= 0x21AD) or
               (cp >= 0x21AF and cp <= 0x21CD) or
               (cp >= 0x21D0 and cp <= 0x21D1) or
               (cp >= 0x21D3 and cp <= 0x21D3) or
               (cp >= 0x21D5 and cp <= 0x21F3) or
               (cp >= 0x2300 and cp <= 0x231F) or
               (cp >= 0x2322 and cp <= 0x2328) or
               (cp >= 0x232B and cp <= 0x237B) or
               (cp >= 0x237D and cp <= 0x239A) or
               (cp >= 0x23B4 and cp <= 0x23DB) or
               (cp >= 0x23E2 and cp <= 0x2426) or
               (cp >= 0x2440 and cp <= 0x244A) or
               (cp >= 0x249C and cp <= 0x24E9) or
               (cp >= 0x2500 and cp <= 0x25B6) or
               (cp >= 0x25B8 and cp <= 0x25C0) or
               (cp >= 0x25C2 and cp <= 0x25F7) or
               (cp >= 0x2600 and cp <= 0x266E) or
               (cp >= 0x2670 and cp <= 0x2775) or
               (cp >= 0x2794 and cp <= 0x27BF) or
               (cp >= 0x2800 and cp <= 0x28FF) or
               (cp >= 0x2B00 and cp <= 0x2B2F) or
               (cp >= 0x2B45 and cp <= 0x2B46) or
               (cp >= 0x2B50 and cp <= 0x2B59) or
               (cp >= 0x2CE5 and cp <= 0x2CEA) or
               (cp >= 0x2E80 and cp <= 0x2E99) or
               (cp >= 0x2E9B and cp <= 0x2EF3) or
               (cp >= 0x2F00 and cp <= 0x2FD5) or
               (cp >= 0x2FF0 and cp <= 0x2FFB) or
               (cp >= 0x3004 and cp <= 0x3004) or
               (cp >= 0x3012 and cp <= 0x3013) or
               (cp >= 0x3020 and cp <= 0x3020) or
               (cp >= 0x3036 and cp <= 0x3037) or
               (cp >= 0x303E and cp <= 0x303F) or
               (cp >= 0x3190 and cp <= 0x3191) or
               (cp >= 0x3196 and cp <= 0x319F) or
               (cp >= 0x31C0 and cp <= 0x31E3) or
               (cp >= 0x3200 and cp <= 0x321E) or
               (cp >= 0x322A and cp <= 0x3247) or
               (cp >= 0x3250 and cp <= 0x3250) or
               (cp >= 0x3260 and cp <= 0x327F) or
               (cp >= 0x328A and cp <= 0x32B0) or
               (cp >= 0x32C0 and cp <= 0x32FE) or
               (cp >= 0x3300 and cp <= 0x33FF) or
               (cp >= 0x4DC0 and cp <= 0x4DFF) or
               (cp >= 0xA490 and cp <= 0xA4C6) or
               (cp >= 0xA828 and cp <= 0xA82B) or
               (cp >= 0xA836 and cp <= 0xA837) or
               (cp >= 0xAA77 and cp <= 0xAA79) or
               (cp >= 0xFDFD and cp <= 0xFDFD) or
               (cp >= 0xFFFC and cp <= 0xFFFD);
    } else if (property.len == 1 and property[0] == 'Z') {
        return isUnicodeProperty(cp, "Zs") or
               isUnicodeProperty(cp, "Zl") or
               isUnicodeProperty(cp, "Zp");
    } else if (property.len == 2 and property[0] == 'Z' and property[1] == 's') {
        // Space Separator
        return (cp >= 0x0020 and cp <= 0x0020) or
               (cp >= 0x00A0 and cp <= 0x00A0) or
               (cp >= 0x1680 and cp <= 0x1680) or
               (cp >= 0x2000 and cp <= 0x200A) or
               (cp >= 0x202F and cp <= 0x202F) or
               (cp >= 0x205F and cp <= 0x205F) or
               (cp >= 0x3000 and cp <= 0x3000);
    } else if (property.len == 2 and property[0] == 'Z' and property[1] == 'l') {
        // Line Separator
        return (cp >= 0x2028 and cp <= 0x2028);
    } else if (property.len == 2 and property[0] == 'Z' and property[1] == 'p') {
        // Paragraph Separator
        return (cp >= 0x2029 and cp <= 0x2029);
    } else if (property.len == 1 and property[0] == 'C') {
        // Other
        return isUnicodeProperty(cp, "Cc") or
               isUnicodeProperty(cp, "Cf") or
               isUnicodeProperty(cp, "Co") or
               isUnicodeProperty(cp, "Cs");
    } else if (property.len == 2 and property[0] == 'C' and property[1] == 'c') {
        // Control
        return (cp >= 0x0000 and cp <= 0x001F) or
               (cp >= 0x007F and cp <= 0x009F);
    } else if (property.len == 2 and property[0] == 'C' and property[1] == 'f') {
        // Format
        return (cp >= 0x00AD and cp <= 0x00AD) or
               (cp >= 0x0600 and cp <= 0x0605) or
               (cp >= 0x061C and cp <= 0x061C) or
               (cp >= 0x06DD and cp <= 0x06DD) or
               (cp >= 0x070F and cp <= 0x070F) or
               (cp >= 0x08E2 and cp <= 0x08E2) or
               (cp >= 0x180E and cp <= 0x180E) or
               (cp >= 0x200B and cp <= 0x200F) or
               (cp >= 0x202A and cp <= 0x202E) or
               (cp >= 0x2060 and cp <= 0x2064) or
               (cp >= 0x2066 and cp <= 0x206F) or
               (cp >= 0xFEFF and cp <= 0xFEFF) or
               (cp >= 0xFFF9 and cp <= 0xFFFB) or
               (cp >= 0x110BD and cp <= 0x110BD) or
               (cp >= 0x1BCA0 and cp <= 0x1BCA3) or
               (cp >= 0x1D173 and cp <= 0x1D17A) or
               (cp >= 0xE0001 and cp <= 0xE0001) or
               (cp >= 0xE0020 and cp <= 0xE007F);
    } else if (property.len == 2 and property[0] == 'C' and property[1] == 'o') {
        // Private Use
        return (cp >= 0xE000 and cp <= 0xF8FF) or
               (cp >= 0xF0000 and cp <= 0xFFFFD) or
               (cp >= 0x100000 and cp <= 0x10FFFD);
    } else if (property.len == 2 and property[0] == 'C' and property[1] == 's') {
        // Surrogate
        return (cp >= 0xD800 and cp <= 0xDFFF);
    } else if (property.len == 1 and property[0] == 'M') {
        // Mark
        return isUnicodeProperty(cp, "Mn") or
               isUnicodeProperty(cp, "Mc") or
               isUnicodeProperty(cp, "Me");
    } else if (property.len == 2 and property[0] == 'M' and property[1] == 'n') {
        // Nonspacing Mark
        return (cp >= 0x0300 and cp <= 0x036F) or
               (cp >= 0x0483 and cp <= 0x0489) or
               (cp >= 0x0591 and cp <= 0x05BD) or
               (cp >= 0x05BF and cp <= 0x05BF) or
               (cp >= 0x05C1 and cp <= 0x05C2) or
               (cp >= 0x05C4 and cp <= 0x05C5) or
               (cp >= 0x05C7 and cp <= 0x05C7) or
               (cp >= 0x0610 and cp <= 0x061A) or
               (cp >= 0x064B and cp <= 0x065F) or
               (cp >= 0x0670 and cp <= 0x0670) or
               (cp >= 0x06D6 and cp <= 0x06DC) or
               (cp >= 0x06DF and cp <= 0x06E4) or
               (cp >= 0x06E7 and cp <= 0x06E8) or
               (cp >= 0x06EA and cp <= 0x06ED) or
               (cp >= 0x0711 and cp <= 0x0711) or
               (cp >= 0x0730 and cp <= 0x074A) or
               (cp >= 0x07A6 and cp <= 0x07B0) or
               (cp >= 0x07EB and cp <= 0x07F3) or
               (cp >= 0x0816 and cp <= 0x0819) or
               (cp >= 0x081B and cp <= 0x0823) or
               (cp >= 0x0825 and cp <= 0x0827) or
               (cp >= 0x0829 and cp <= 0x082D) or
               (cp >= 0x0859 and cp <= 0x085B) or
               (cp >= 0x08E3 and cp <= 0x0902) or
               (cp >= 0x093A and cp <= 0x093A) or
               (cp >= 0x093C and cp <= 0x093C) or
               (cp >= 0x0941 and cp <= 0x0948) or
               (cp >= 0x094D and cp <= 0x094D) or
               (cp >= 0x0951 and cp <= 0x0957) or
               (cp >= 0x0962 and cp <= 0x0963) or
               (cp >= 0x0981 and cp <= 0x0981) or
               (cp >= 0x09BC and cp <= 0x09BC) or
               (cp >= 0x09C1 and cp <= 0x09C4) or
               (cp >= 0x09CD and cp <= 0x09CD) or
               (cp >= 0x09E2 and cp <= 0x09E3) or
               (cp >= 0x0A01 and cp <= 0x0A02) or
               (cp >= 0x0A3C and cp <= 0x0A3C) or
               (cp >= 0x0A41 and cp <= 0x0A42) or
               (cp >= 0x0A47 and cp <= 0x0A48) or
               (cp >= 0x0A4B and cp <= 0x0A4D) or
               (cp >= 0x0A51 and cp <= 0x0A51) or
               (cp >= 0x0A70 and cp <= 0x0A71) or
               (cp >= 0x0A75 and cp <= 0x0A75) or
               (cp >= 0x0A81 and cp <= 0x0A82) or
               (cp >= 0x0ABC and cp <= 0x0ABC) or
               (cp >= 0x0AC1 and cp <= 0x0AC5) or
               (cp >= 0x0AC7 and cp <= 0x0AC8) or
               (cp >= 0x0ACD and cp <= 0x0ACD) or
               (cp >= 0x0AE2 and cp <= 0x0AE3) or
               (cp >= 0x0B01 and cp <= 0x0B01) or
               (cp >= 0x0B3C and cp <= 0x0B3C) or
               (cp >= 0x0B3F and cp <= 0x0B3F) or
               (cp >= 0x0B41 and cp <= 0x0B44) or
               (cp >= 0x0B4D and cp <= 0x0B4D) or
               (cp >= 0x0B56 and cp <= 0x0B56) or
               (cp >= 0x0B62 and cp <= 0x0B63) or
               (cp >= 0x0B82 and cp <= 0x0B82) or
               (cp >= 0x0BC0 and cp <= 0x0BC0) or
               (cp >= 0x0BCD and cp <= 0x0BCD) or
               (cp >= 0x0C00 and cp <= 0x0C00) or
               (cp >= 0x0C3E and cp <= 0x0C40) or
               (cp >= 0x0C46 and cp <= 0x0C48) or
               (cp >= 0x0C4A and cp <= 0x0C4D) or
               (cp >= 0x0C55 and cp <= 0x0C56) or
               (cp >= 0x0C62 and cp <= 0x0C63) or
               (cp >= 0x0C81 and cp <= 0x0C81) or
               (cp >= 0x0CBC and cp <= 0x0CBC) or
               (cp >= 0x0CBF and cp <= 0x0CBF) or
               (cp >= 0x0CC6 and cp <= 0x0CC6) or
               (cp >= 0x0CCC and cp <= 0x0CCD) or
               (cp >= 0x0CE2 and cp <= 0x0CE3) or
               (cp >= 0x0D01 and cp <= 0x0D01) or
               (cp >= 0x0D41 and cp <= 0x0D44) or
               (cp >= 0x0D4D and cp <= 0x0D4D) or
               (cp >= 0x0D62 and cp <= 0x0D63) or
               (cp >= 0x0DCA and cp <= 0x0DCA) or
               (cp >= 0x0DD2 and cp <= 0x0DD4) or
               (cp >= 0x0DD6 and cp <= 0x0DD6) or
               (cp >= 0x0E31 and cp <= 0x0E31) or
               (cp >= 0x0E34 and cp <= 0x0E3A) or
               (cp >= 0x0E47 and cp <= 0x0E4E) or
               (cp >= 0x0EB1 and cp <= 0x0EB1) or
               (cp >= 0x0EB4 and cp <= 0x0EB9) or
               (cp >= 0x0EBB and cp <= 0x0EBC) or
               (cp >= 0x0EC8 and cp <= 0x0ECD) or
               (cp >= 0x0F18 and cp <= 0x0F19) or
               (cp >= 0x0F35 and cp <= 0x0F35) or
               (cp >= 0x0F37 and cp <= 0x0F37) or
               (cp >= 0x0F39 and cp <= 0x0F39) or
               (cp >= 0x0F71 and cp <= 0x0F7E) or
               (cp >= 0x0F80 and cp <= 0x0F84) or
               (cp >= 0x0F86 and cp <= 0x0F87) or
               (cp >= 0x0F8D and cp <= 0x0F97) or
               (cp >= 0x0F99 and cp <= 0x0FBC) or
               (cp >= 0x0FC6 and cp <= 0x0FC6) or
               (cp >= 0x102D and cp <= 0x1030) or
               (cp >= 0x1032 and cp <= 0x1037) or
               (cp >= 0x1039 and cp <= 0x103A) or
               (cp >= 0x103D and cp <= 0x103E) or
               (cp >= 0x1058 and cp <= 0x1059) or
               (cp >= 0x105E and cp <= 0x1060) or
               (cp >= 0x1071 and cp <= 0x1074) or
               (cp >= 0x1082 and cp <= 0x1082) or
               (cp >= 0x1085 and cp <= 0x1086) or
               (cp >= 0x108D and cp <= 0x108D) or
               (cp >= 0x109D and cp <= 0x109D) or
               (cp >= 0x135D and cp <= 0x135F) or
               (cp >= 0x1712 and cp <= 0x1714) or
               (cp >= 0x1732 and cp <= 0x1734) or
               (cp >= 0x1752 and cp <= 0x1753) or
               (cp >= 0x1772 and cp <= 0x1773) or
               (cp >= 0x17B4 and cp <= 0x17B5) or
               (cp >= 0x17B7 and cp <= 0x17BD) or
               (cp >= 0x17C6 and cp <= 0x17C6) or
               (cp >= 0x17C9 and cp <= 0x17D3) or
               (cp >= 0x17DD and cp <= 0x17DD) or
               (cp >= 0x180B and cp <= 0x180D) or
               (cp >= 0x1885 and cp <= 0x1886) or
               (cp >= 0x18A9 and cp <= 0x18A9) or
               (cp >= 0x1920 and cp <= 0x1922) or
               (cp >= 0x1927 and cp <= 0x1928) or
               (cp >= 0x1932 and cp <= 0x1932) or
               (cp >= 0x1939 and cp <= 0x193B) or
               (cp >= 0x1A17 and cp <= 0x1A18) or
               (cp >= 0x1A56 and cp <= 0x1A56) or
               (cp >= 0x1A58 and cp <= 0x1A5E) or
               (cp >= 0x1A60 and cp <= 0x1A60) or
               (cp >= 0x1A62 and cp <= 0x1A62) or
               (cp >= 0x1A65 and cp <= 0x1A6C) or
               (cp >= 0x1A73 and cp <= 0x1A7C) or
               (cp >= 0x1A7F and cp <= 0x1A7F) or
               (cp >= 0x1AB0 and cp <= 0x1ABD) or
               (cp >= 0x1B00 and cp <= 0x1B03) or
               (cp >= 0x1B34 and cp <= 0x1B34) or
               (cp >= 0x1B36 and cp <= 0x1B3A) or
               (cp >= 0x1B3C and cp <= 0x1B3C) or
               (cp >= 0x1B42 and cp <= 0x1B42) or
               (cp >= 0x1B6B and cp <= 0x1B73) or
               (cp >= 0x1B80 and cp <= 0x1B81) or
               (cp >= 0x1BA2 and cp <= 0x1BA5) or
               (cp >= 0x1BA8 and cp <= 0x1BA9) or
               (cp >= 0x1BAB and cp <= 0x1BAD) or
               (cp >= 0x1BE6 and cp <= 0x1BE6) or
               (cp >= 0x1BE8 and cp <= 0x1BE9) or
               (cp >= 0x1BED and cp <= 0x1BED) or
               (cp >= 0x1BEF and cp <= 0x1BF1) or
               (cp >= 0x1C2C and cp <= 0x1C33) or
               (cp >= 0x1C36 and cp <= 0x1C37) or
               (cp >= 0x1CD0 and cp <= 0x1CD2) or
               (cp >= 0x1CD4 and cp <= 0x1CE0) or
               (cp >= 0x1CE2 and cp <= 0x1CE8) or
               (cp >= 0x1CED and cp <= 0x1CED) or
               (cp >= 0x1CF4 and cp <= 0x1CF4) or
               (cp >= 0x1CF8 and cp <= 0x1CF9) or
               (cp >= 0x1DC0 and cp <= 0x1DF5) or
               (cp >= 0x1DFC and cp <= 0x1DFF) or
               (cp >= 0x20D0 and cp <= 0x20DC) or
               (cp >= 0x20E1 and cp <= 0x20E1) or
               (cp >= 0x20E5 and cp <= 0x20F0) or
               (cp >= 0x2CEF and cp <= 0x2CF1) or
               (cp >= 0x2D7F and cp <= 0x2D7F) or
               (cp >= 0x2DE0 and cp <= 0x2DFF) or
               (cp >= 0x302A and cp <= 0x302D) or
               (cp >= 0x3099 and cp <= 0x309A) or
               (cp >= 0xA66F and cp <= 0xA66F) or
               (cp >= 0xA674 and cp <= 0xA67D) or
               (cp >= 0xA69E and cp <= 0xA69F) or
               (cp >= 0xA6F0 and cp <= 0xA6F1) or
               (cp >= 0xA802 and cp <= 0xA802) or
               (cp >= 0xA806 and cp <= 0xA806) or
               (cp >= 0xA80B and cp <= 0xA80B) or
               (cp >= 0xA825 and cp <= 0xA826) or
               (cp >= 0xA8C4 and cp <= 0xA8C5) or
               (cp >= 0xA8E0 and cp <= 0xA8F1) or
               (cp >= 0xA926 and cp <= 0xA92D) or
               (cp >= 0xA947 and cp <= 0xA951) or
               (cp >= 0xA980 and cp <= 0xA982) or
               (cp >= 0xA9B3 and cp <= 0xA9B3) or
               (cp >= 0xA9B6 and cp <= 0xA9B9) or
               (cp >= 0xA9BC and cp <= 0xA9BC) or
               (cp >= 0xA9E5 and cp <= 0xA9E5) or
               (cp >= 0xAA29 and cp <= 0xAA2E) or
               (cp >= 0xAA31 and cp <= 0xAA32) or
               (cp >= 0xAA35 and cp <= 0xAA36) or
               (cp >= 0xAA43 and cp <= 0xAA43) or
               (cp >= 0xAA4C and cp <= 0xAA4C) or
               (cp >= 0xAA7C and cp <= 0xAA7C) or
               (cp >= 0xAAB0 and cp <= 0xAAB0) or
               (cp >= 0xAAB2 and cp <= 0xAAB4) or
               (cp >= 0xAAB7 and cp <= 0xAAB8) or
               (cp >= 0xAABE and cp <= 0xAABF) or
               (cp >= 0xAAC1 and cp <= 0xAAC1) or
               (cp >= 0xAAEC and cp <= 0xAAED) or
               (cp >= 0xAAF6 and cp <= 0xAAF6) or
               (cp >= 0xABE5 and cp <= 0xABE5) or
               (cp >= 0xABE8 and cp <= 0xABE8) or
               (cp >= 0xABED and cp <= 0xABED) or
               (cp >= 0xFB1E and cp <= 0xFB1E) or
               (cp >= 0xFE00 and cp <= 0xFE0F) or
               (cp >= 0xFE20 and cp <= 0xFE2F);
    } else if (property.len == 2 and property[0] == 'M' and property[1] == 'c') {
        // Spacing Combining Mark
        return (cp >= 0x0903 and cp <= 0x0903) or
               (cp >= 0x093B and cp <= 0x093B) or
               (cp >= 0x093E and cp <= 0x0940) or
               (cp >= 0x0949 and cp <= 0x094C) or
               (cp >= 0x094E and cp <= 0x094E) or
               (cp >= 0x0955 and cp <= 0x0957) or
               (cp >= 0x0962 and cp <= 0x0963) or
               (cp >= 0x0982 and cp <= 0x0983) or
               (cp >= 0x09BE and cp <= 0x09C0) or
               (cp >= 0x09C7 and cp <= 0x09C8) or
               (cp >= 0x09CB and cp <= 0x09CC) or
               (cp >= 0x09D7 and cp <= 0x09D7) or
               (cp >= 0x0A03 and cp <= 0x0A03) or
               (cp >= 0x0A3E and cp <= 0x0A40) or
               (cp >= 0x0A83 and cp <= 0x0A83) or
               (cp >= 0x0ABE and cp <= 0x0AC0) or
               (cp >= 0x0AC9 and cp <= 0x0AC9) or
               (cp >= 0x0ACB and cp <= 0x0ACC) or
               (cp >= 0x0AD0 and cp <= 0x0AD0) or
               (cp >= 0x0B02 and cp <= 0x0B03) or
               (cp >= 0x0B3E and cp <= 0x0B3E) or
               (cp >= 0x0B40 and cp <= 0x0B40) or
               (cp >= 0x0B47 and cp <= 0x0B48) or
               (cp >= 0x0B4B and cp <= 0x0B4C) or
               (cp >= 0x0B57 and cp <= 0x0B57) or
               (cp >= 0x0BBE and cp <= 0x0BBF) or
               (cp >= 0x0BC1 and cp <= 0x0BC2) or
               (cp >= 0x0BC6 and cp <= 0x0BC8) or
               (cp >= 0x0BCA and cp <= 0x0BCC) or
               (cp >= 0x0BD7 and cp <= 0x0BD7) or
               (cp >= 0x0C01 and cp <= 0x0C03) or
               (cp >= 0x0C41 and cp <= 0x0C44) or
               (cp >= 0x0C82 and cp <= 0x0C83) or
               (cp >= 0x0CBE and cp <= 0x0CBE) or
               (cp >= 0x0CC0 and cp <= 0x0CC4) or
               (cp >= 0x0CC7 and cp <= 0x0CC8) or
               (cp >= 0x0CCA and cp <= 0x0CCB) or
               (cp >= 0x0CD5 and cp <= 0x0CD6) or
               (cp >= 0x0D02 and cp <= 0x0D03) or
               (cp >= 0x0D3E and cp <= 0x0D40) or
               (cp >= 0x0D46 and cp <= 0x0D48) or
               (cp >= 0x0D4A and cp <= 0x0D4C) or
               (cp >= 0x0D57 and cp <= 0x0D57) or
               (cp >= 0x0D82 and cp <= 0x0D83) or
               (cp >= 0x0DCF and cp <= 0x0DD1) or
               (cp >= 0x0DD8 and cp <= 0x0DDF) or
               (cp >= 0x0DF2 and cp <= 0x0DF3) or
               (cp >= 0x0F3E and cp <= 0x0F3F) or
               (cp >= 0x0F7F and cp <= 0x0F7F) or
               (cp >= 0x102B and cp <= 0x102C) or
               (cp >= 0x1031 and cp <= 0x1031) or
               (cp >= 0x1038 and cp <= 0x1038) or
               (cp >= 0x103B and cp <= 0x103C) or
               (cp >= 0x1056 and cp <= 0x1057) or
               (cp >= 0x1062 and cp <= 0x1064) or
               (cp >= 0x1067 and cp <= 0x106D) or
               (cp >= 0x1083 and cp <= 0x1084) or
               (cp >= 0x1087 and cp <= 0x108C) or
               (cp >= 0x108F and cp <= 0x108F) or
               (cp >= 0x109A and cp <= 0x109C) or
               (cp >= 0x17B6 and cp <= 0x17B6) or
               (cp >= 0x17BE and cp <= 0x17C5) or
               (cp >= 0x17C7 and cp <= 0x17C8) or
               (cp >= 0x1923 and cp <= 0x1926) or
               (cp >= 0x1929 and cp <= 0x192B) or
               (cp >= 0x1930 and cp <= 0x1931) or
               (cp >= 0x1933 and cp <= 0x1938) or
               (cp >= 0x1A19 and cp <= 0x1A1A) or
               (cp >= 0x1A55 and cp <= 0x1A55) or
               (cp >= 0x1A57 and cp <= 0x1A57) or
               (cp >= 0x1A61 and cp <= 0x1A61) or
               (cp >= 0x1A63 and cp <= 0x1A64) or
               (cp >= 0x1A6D and cp <= 0x1A72) or
               (cp >= 0x1B04 and cp <= 0x1B04) or
               (cp >= 0x1B35 and cp <= 0x1B35) or
               (cp >= 0x1B3B and cp <= 0x1B3B) or
               (cp >= 0x1B3D and cp <= 0x1B41) or
               (cp >= 0x1B43 and cp <= 0x1B44) or
               (cp >= 0x1B82 and cp <= 0x1B82) or
               (cp >= 0x1BA1 and cp <= 0x1BA1) or
               (cp >= 0x1BA6 and cp <= 0x1BA7) or
               (cp >= 0x1BAA and cp <= 0x1BAA) or
               (cp >= 0x1BE7 and cp <= 0x1BE7) or
               (cp >= 0x1BEA and cp <= 0x1BEC) or
               (cp >= 0x1BEE and cp <= 0x1BEE) or
               (cp >= 0x1BF2 and cp <= 0x1BF3) or
               (cp >= 0x1C24 and cp <= 0x1C2B) or
               (cp >= 0x1C34 and cp <= 0x1C35) or
               (cp >= 0x1CE1 and cp <= 0x1CE1) or
               (cp >= 0x1CF7 and cp <= 0x1CF7) or
               (cp >= 0xA823 and cp <= 0xA824) or
               (cp >= 0xA827 and cp <= 0xA827) or
               (cp >= 0xA880 and cp <= 0xA881) or
               (cp >= 0xA8B4 and cp <= 0xA8C3) or
               (cp >= 0xA952 and cp <= 0xA953) or
               (cp >= 0xA983 and cp <= 0xA983) or
               (cp >= 0xA9B4 and cp <= 0xA9B5) or
               (cp >= 0xA9BA and cp <= 0xA9BB) or
               (cp >= 0xA9BD and cp <= 0xA9C0) or
               (cp >= 0xAA2F and cp <= 0xAA30) or
               (cp >= 0xAA33 and cp <= 0xAA34) or
               (cp >= 0xAA4D and cp <= 0xAA4D) or
               (cp >= 0xAA7B and cp <= 0xAA7B) or
               (cp >= 0xAA7D and cp <= 0xAA7D) or
               (cp >= 0xAABE and cp <= 0xAABF) or
               (cp >= 0xAAC0 and cp <= 0xAAC0) or
               (cp >= 0xAAC2 and cp <= 0xAAC2) or
               (cp >= 0xAADB and cp <= 0xAADC) or
               (cp >= 0xAAF2 and cp <= 0xAAF2) or
               (cp >= 0xAB01 and cp <= 0xAB06) or
               (cp >= 0xAB09 and cp <= 0xAB0E) or
               (cp >= 0xAB11 and cp <= 0xAB16) or
               (cp >= 0xAB20 and cp <= 0xAB26) or
               (cp >= 0xAB28 and cp <= 0xAB2E) or
               (cp >= 0xAB30 and cp <= 0xAB5A) or
               (cp >= 0xAB5C and cp <= 0xAB5F) or
               (cp >= 0xAB60 and cp <= 0xAB65);
    } else if (property.len == 2 and property[0] == 'M' and property[1] == 'e') {
        // Enclosing Mark
        return (cp >= 0x0488 and cp <= 0x0489) or
               (cp >= 0x1ABE and cp <= 0x1ABE) or
               (cp >= 0x20DD and cp <= 0x20E0) or
               (cp >= 0x20E2 and cp <= 0x20E4) or
               (cp >= 0xA670 and cp <= 0xA672);
    } else if (property.len == 3 and property[0] == 'H' and property[1] == 'a' and property[2] == 'n') {
        return (cp >= 0x4E00 and cp <= 0x9FFF) or
               (cp >= 0x3400 and cp <= 0x4DBF) or
               (cp >= 0xF900 and cp <= 0xFAFF);
    } else if (property.len == 5 and property[0] == 'L' and property[1] == 'a' and property[2] == 't' and property[3] == 'i' and property[4] == 'n') {
        return (cp >= 0x0041 and cp <= 0x007A) or
               (cp >= 0x00C0 and cp <= 0x00FF) or
               (cp >= 0x0100 and cp <= 0x017F) or
               (cp >= 0x0180 and cp <= 0x024F);
    } else if (property.len == 5 and property[0] == 'G' and property[1] == 'r' and property[2] == 'e' and property[3] == 'e' and property[4] == 'k') {
        return (cp >= 0x0370 and cp <= 0x03FF) or
               (cp >= 0x1F00 and cp <= 0x1FFF);
    } else if (property.len == 8 and property[0] == 'C' and property[1] == 'y' and property[2] == 'r' and property[3] == 'i' and property[4] == 'l' and property[5] == 'l' and property[6] == 'i' and property[7] == 'c') {
        return (cp >= 0x0400 and cp <= 0x04FF) or
               (cp >= 0x0500 and cp <= 0x052F) or
               (cp >= 0x2DE0 and cp <= 0x2DFF) or
               (cp >= 0xA640 and cp <= 0xA69F);
    } else if (property.len == 6 and property[0] == 'A' and property[1] == 'r' and property[2] == 'a' and property[3] == 'b' and property[4] == 'i' and property[5] == 'c') {
        return (cp >= 0x0600 and cp <= 0x06FF) or
               (cp >= 0x0750 and cp <= 0x077F) or
               (cp >= 0x08A0 and cp <= 0x08FF) or
               (cp >= 0xFB50 and cp <= 0xFDFF) or
               (cp >= 0xFE70 and cp <= 0xFEFF);
    } else if (property.len == 6 and property[0] == 'H' and property[1] == 'e' and property[2] == 'b' and property[3] == 'r' and property[4] == 'e' and property[5] == 'w') {
        return (cp >= 0x0590 and cp <= 0x05FF) or
               (cp >= 0xFB1D and cp <= 0xFB4F);
    } else if (property.len == 8 and property[0] == 'A' and property[1] == 'r' and property[2] == 'm' and property[3] == 'e' and property[4] == 'n' and property[5] == 'i' and property[6] == 'a' and property[7] == 'n') {
        return cp >= 0x0530 and cp <= 0x058F;
    } else if (property.len == 8 and property[0] == 'G' and property[1] == 'e' and property[2] == 'o' and property[3] == 'r' and property[4] == 'g' and property[5] == 'i' and property[6] == 'a' and property[7] == 'n') {
        return (cp >= 0x10A0 and cp <= 0x10FF) or
               (cp >= 0x2D00 and cp <= 0x2D2F);
    } else if (property.len == 4 and property[0] == 'T' and property[1] == 'h' and property[2] == 'a' and property[3] == 'i') {
        return cp >= 0x0E00 and cp <= 0x0E7F;
    } else if (property.len == 10 and property[0] == 'D' and property[1] == 'e' and property[2] == 'v' and property[3] == 'a' and property[4] == 'n' and property[5] == 'a' and property[6] == 'g' and property[7] == 'a' and property[8] == 'r' and property[9] == 'i') {
        return cp >= 0x0900 and cp <= 0x097F;
    } else if (property.len == 8 and property[0] == 'H' and property[1] == 'i' and property[2] == 'r' and property[3] == 'a' and property[4] == 'g' and property[5] == 'a' and property[6] == 'n' and property[7] == 'a') {
        return (cp >= 0x3040 and cp <= 0x309F) or
               (cp >= 0x1B001 and cp <= 0x1B11F);
    } else if (property.len == 8 and property[0] == 'K' and property[1] == 'a' and property[2] == 't' and property[3] == 'a' and property[4] == 'k' and property[5] == 'a' and property[6] == 'n' and property[7] == 'a') {
        return (cp >= 0x30A0 and cp <= 0x30FF) or
               (cp >= 0x31F0 and cp <= 0x31FF) or
               (cp >= 0xFF65 and cp <= 0xFF9F);
    } else if (property.len == 6 and property[0] == 'H' and property[1] == 'a' and property[2] == 'n' and property[3] == 'g' and property[4] == 'u' and property[5] == 'l') {
        return (cp >= 0x1100 and cp <= 0x11FF) or
               (cp >= 0x3130 and cp <= 0x318F) or
               (cp >= 0xA960 and cp <= 0xA97F) or
               (cp >= 0xAC00 and cp <= 0xD7AF) or
               (cp >= 0xD7B0 and cp <= 0xD7FF);
    }
    return false;
}

fn matchUnicodeProperty(input: []const u8, pos: usize, property: []const u8, negated: bool) ?usize {
    if (pos >= input.len) return null;
    
    // Get UTF-8 sequence length
    const byte_len = std.unicode.utf8ByteSequenceLength(input[pos]) catch {
        const ch = input[pos];
        const matches = isUnicodeProperty(ch, property);
        if (negated) {
            if (matches) return null;
            return 1;
        } else {
            if (!matches) return null;
            return 1;
        }
    };
    
    if (pos + byte_len > input.len) {
        const ch = input[pos];
        const matches = isUnicodeProperty(ch, property);
        if (negated) {
            if (matches) return null;
            return 1;
        } else {
            if (!matches) return null;
            return 1;
        }
    }
    
    const cp = std.unicode.utf8Decode(input[pos..pos + byte_len]) catch {
        const ch = input[pos];
        const matches = isUnicodeProperty(ch, property);
        if (negated) {
            if (matches) return null;
            return 1;
        } else {
            if (!matches) return null;
            return 1;
        }
    };
    
    const matches = isUnicodeProperty(cp, property);
    
    if (negated) {
        if (matches) return null;
        return byte_len;
    } else {
        if (!matches) return null;
        return byte_len;
    }
}

/// Check if a character at position `pos` in `input` is a Unicode word character.
/// Word characters include: ASCII letters/digits/underscore, Unicode letters (L),
/// decimal digits (Nd), and marks (M).
fn isUnicodeWordChar(input: []const u8, pos: usize) bool {
    if (pos >= input.len) return false;
    var start = pos;
    const ch = input[start];
    // ASCII fast path
    if (ch < 128) {
        return std.ascii.isAlphanumeric(ch) or ch == '_';
    }
    // If pos points to a continuation byte (0x80-0xBF), walk back to the start byte
    if (ch >= 0x80 and ch <= 0xBF) {
        while (start > 0) {
            start -= 1;
            if (input[start] >= 0xC0 or input[start] < 0x80) break;
        }
    }
    if (start >= input.len) return false;
    const start_byte = input[start];
    const byte_len = std.unicode.utf8ByteSequenceLength(start_byte) catch return false;
    if (start + byte_len > input.len) return false;
    const cp = std.unicode.utf8Decode(input[start..start + byte_len]) catch return false;
    return isUnicodeProperty(cp, "L") or isUnicodeProperty(cp, "Nd") or isUnicodeProperty(cp, "M");
}

/// Check if a character at position `pos` matches any Unicode property in the given CharClass.
/// Returns the byte length of the matched UTF-8 sequence, or null if no match.
fn matchUnicodePropertyInClass(input: []const u8, pos: usize, cc: @import("parser.zig").CharClass) ?usize {
    if (pos >= input.len or cc.unicode_properties.items.len == 0) return null;

    const byte_len = std.unicode.utf8ByteSequenceLength(input[pos]) catch 1;
    const actual_len = if (pos + byte_len > input.len) 1 else byte_len;

    const cp = if (actual_len == 1)
        @as(u21, input[pos])
    else
        std.unicode.utf8Decode(input[pos..pos + actual_len]) catch @as(u21, input[pos]);

    var matches = false;
    for (cc.unicode_properties.items) |entry| {
        var prop_match = isUnicodeProperty(cp, entry.name);
        if (entry.negated) {
            prop_match = !prop_match;
        }
        if (prop_match) {
            matches = true;
            break;
        }
    }

    if (cc.negated) {
        matches = !matches;
    }

    if (matches) return actual_len;
    return null;
}

/// Check if the character at pos is a line ending character (single char, not CRLF).
/// Returns byte length (1 or 3), or null.
fn isLineEndingChar(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;

    switch (input[pos]) {
        '\r', '\n', '\x0B', '\x0C', '\x85' => return 1,
        else => {},
    }

    // Multi-byte: U+2028 (LS) and U+2029 (PS)
    if (input[pos] == 0xE2 and pos + 2 < input.len) {
        if (input[pos + 1] == 0x80) {
            if (input[pos + 2] == 0xA8 or input[pos + 2] == 0xA9) {
                return 3;
            }
        }
    }

    return null;
}

/// Match a single grapheme cluster (simplified implementation).
/// Returns the total byte length of the cluster, or null if no cluster at pos.
fn matchNewline(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;

    // CRLF sequence
    if (input[pos] == '\r' and pos + 1 < input.len and input[pos + 1] == '\n') {
        return 2;
    }

    return isLineEndingChar(input, pos);
}

fn matchGraphemeCluster(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;

    // CR LF sequence is a single grapheme cluster
    if (input[pos] == '\r' and pos + 1 < input.len and input[pos + 1] == '\n') {
        return 2;
    }

    // Get first codepoint byte length
    const first_len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return 1;
    if (pos + first_len > input.len) return 1;

    _ = std.unicode.utf8Decode(input[pos..pos + first_len]) catch return 1;
    var total_len: usize = first_len;

    // Consume subsequent combining marks (General Category M)
    while (pos + total_len < input.len) {
        const next_len = std.unicode.utf8ByteSequenceLength(input[pos + total_len]) catch break;
        if (pos + total_len + next_len > input.len) break;
        const next_cp = std.unicode.utf8Decode(input[pos + total_len..pos + total_len + next_len]) catch break;
        if (!isUnicodeProperty(next_cp, "M")) break;
        total_len += next_len;
    }

    return total_len;
}

pub const Vm = struct {
    bytecode: Bytecode,
    allocator: std.mem.Allocator,
    options: RegexOptions,
    atomic_stack: std.ArrayList(usize) = .empty,
    last_match_end: usize = 0,
    last_pos: std.ArrayList(?usize) = .empty,
    // Reusable per-match buffer for captures (size is fixed after compile)
    captures_buf: std.ArrayList(?usize) = .empty,

    pub fn init(allocator: std.mem.Allocator, bytecode: Bytecode, options: RegexOptions) !Vm {
        var vm = Vm{
            .bytecode = bytecode,
            .allocator = allocator,
            .options = options,
            .atomic_stack = .empty,
            .last_match_end = 0,
            .last_pos = .empty,
            .captures_buf = .empty,
        };
        // Pre-allocate fixed-size buffers based on bytecode size
        try vm.captures_buf.resize(allocator, (bytecode.num_groups + 1) * 2);
        try vm.last_pos.resize(allocator, bytecode.instructions.items.len);
        try vm.atomic_stack.ensureTotalCapacity(allocator, 64);
        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.atomic_stack.deinit(self.allocator);
        self.last_pos.deinit(self.allocator);
        self.captures_buf.deinit(self.allocator);
    }

    /// Shared VM execution engine.
    fn execInternal(comptime is_sub: bool, self: *Vm, input: []const u8, start_pos: usize, start_pc: usize, end_pc: usize) !MatchResult {
        // Use pre-allocated captures buffer, resizing only if bytecode grew
        const captures_needed = (self.bytecode.num_groups + 1) * 2;
        if (self.captures_buf.items.len < captures_needed) {
            try self.captures_buf.resize(self.allocator, captures_needed);
        }
        var captures: std.ArrayList(?usize) = .empty;
        captures.items = self.captures_buf.items[0..captures_needed];
        captures.capacity = captures_needed;
        if (!is_sub) {
            @memset(captures.items, null);
        }

        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);

        var pc: usize = start_pc;
        var pos: usize = start_pos;
        var matched = false;
        var match_end: usize = start_pos;
        var step_counter: usize = 0;
        const max_steps = self.options.max_steps;

        if (!is_sub) {
            if (self.last_pos.items.len < self.bytecode.instructions.items.len) {
                try self.last_pos.resize(self.allocator, self.bytecode.instructions.items.len);
            }
            @memset(self.last_pos.items, null);
        }

        var subroutine_stack: std.ArrayList(usize) = .empty;
        defer subroutine_stack.deinit(self.allocator);

        const final_pc = if (is_sub) end_pc else self.bytecode.instructions.items.len;

        while (true) {
            if (max_steps) |limit| {
                if (step_counter >= limit) break;
            }
            step_counter += 1;

            if (pc >= final_pc) {
                if (is_sub) {
                    matched = true;
                    match_end = pos;
                    break;
                } else {
                    if (stack.items.len == 0) break;
                    const frame = stack.pop().?;
                    backtrack(false, frame, &captures, &pc, &pos, &subroutine_stack, &self.options);
                    continue;
                }
            }

            const inst = self.bytecode.instructions.items[pc];

            switch (inst.opcode) {
                .Char => {
                    var matches = false;
                    if (pos < input.len) {
                        const ch = input[pos];
                        const pat = inst.char.?;
                        if (self.options.case_sensitive or ch >= 128 or pat >= 128) {
                            matches = ch == pat;
                        } else {
                            matches = std.ascii.toLower(ch) == std.ascii.toLower(pat);
                        }
                    }
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matches, 1)) break;
                },
                .CharUtf8 => {
                    if (!tryMatchOpt(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matchCharUtf8(input, pos, inst.char_codepoint.?, self.options.case_sensitive))) break;
                },
                .Any => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, pos < input.len and (self.options.dot_matches_newline or input[pos] != '\n'), 1)) break;
                },
                .CharClass => {
                    if (!tryMatchOpt(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matchCharClass(inst, input, pos, self.options.case_sensitive))) break;
                },
                .UnicodeProperty => {
                    if (!tryMatchOpt(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matchUnicodeProperty(input, pos, inst.unicode_property.?, inst.unicode_negated))) break;
                },
                .GraphemeCluster => {
                    if (!tryMatchOpt(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matchGraphemeCluster(input, pos))) break;
                },
                .Newline => {
                    if (!tryMatchOpt(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matchNewline(input, pos))) break;
                },
                .ResetMatchStart => {
                    captures.items[0] = pos;
                    pc += 1;
                },
                .NotNewline => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, pos < input.len and input[pos] != '\n', 1)) break;
                },
                .NotVerticalWhitespace => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, pos < input.len and isLineEndingChar(input, pos) == null, 1)) break;
                },
                .Split => {
                    if (!is_sub) {
                        if (self.last_pos.items[pc]) |lp| {
                            if (lp == pos) {
                                pc = inst.target.?;
                                continue;
                            }
                        }
                        self.last_pos.items[pc] = pos;
                    }
                    try stack.append(self.allocator, .{
                        .pc = inst.target.?,
                        .pos = pos,
                        .capture_slot = null,
                        .capture_old_value = null,
                        .options = self.options,
                        .subroutine_stack_len = subroutine_stack.items.len,
                    });
                    pc += 1;
                },
                .Jmp => {
                    pc = inst.target.?;
                },
                .Save => {
                    const slot = inst.save_slot.?;
                    const old_val = captures.items[slot];
                    captures.items[slot] = pos;
                    var frame = Frame{
                        .pc = pc + 1,
                        .pos = pos,
                        .capture_slot = slot,
                        .capture_old_value = old_val,
                        .options = self.options,
                        .subroutine_stack_len = subroutine_stack.items.len,
                    };
                    if (slot % 2 == 1) {
                        const start_slot = slot - 1;
                        frame.paired_capture_slot = start_slot;
                        frame.paired_capture_old_value = captures.items[start_slot];
                    }
                    try stack.append(self.allocator, frame);
                    pc += 1;
                },
                .Match => {
                    matched = true;
                    match_end = pos;
                    if (!is_sub) {
                        if (captures.items[0] == null) captures.items[0] = start_pos;
                        captures.items[1] = pos;
                    }
                    break;
                },
                .SetOption => {
                    self.options = inst.options.?;
                    pc += 1;
                },
                .AtomicStart => {
                    try self.atomic_stack.append(self.allocator, stack.items.len);
                    pc += 1;
                },
                .AtomicEnd => {
                    if (self.atomic_stack.items.len > 0) {
                        const depth = self.atomic_stack.pop().?;
                        while (stack.items.len > depth) {
                            _ = stack.pop();
                        }
                    }
                    pc += 1;
                },
                .Conditional => {
                    const group_idx = inst.backref_group.?;
                    const start_slot = group_idx * 2;
                    const end_slot = group_idx * 2 + 1;
                    var condition_met = false;
                    if (start_slot < captures.items.len and end_slot < captures.items.len) {
                        const group_start = captures.items[start_slot];
                        const group_end = captures.items[end_slot];
                        condition_met = group_start != null and group_end != null;
                    }
                    if (condition_met) {
                        pc += 1;
                    } else {
                        pc = inst.target.?;
                    }
                },
                .Backref => {
                    if (!tryMatchOpt(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, matchBackref(input, pos, captures.items, inst.backref_group.?, self.options.case_sensitive))) break;
                },
                .WordBoundary => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, checkWordBoundary(input, pos), 0)) break;
                },
                .NotWordBoundary => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, !checkWordBoundary(input, pos), 0)) break;
                },
                .AssertStart => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, checkAssertStart(pos, input, self.options.multiline), 0)) break;
                },
                .AssertEnd => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, checkAssertEnd(pos, input, self.options.multiline), 0)) break;
                },
                .AssertStringStart => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, pos == 0, 0)) break;
                },
                .AssertStringEnd => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, pos == input.len, 0)) break;
                },
                .AssertStringEndAllowNewline => {
                    if (!tryMatch(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options, pos == input.len or (pos + 1 == input.len and input[pos] == '\n'), 0)) break;
                },
                .AssertMatchStart => {
                    if (is_sub) {
                        pc += 1;
                    } else {
                        if (pos == self.last_match_end) {
                            pc += 1;
                        } else {
                            if (stack.items.len == 0) break;
                            backtrack(is_sub, stack.pop().?, &captures, &pc, &pos, &subroutine_stack, &self.options);
                        }
                    }
                },
                .AssertForward => {
                    const epc = findAssertEnd(self.bytecode.instructions.items, pc + 1);
                    var sub_result = try execInternal(true, self, input, pos, pc + 1, epc);
                    defer sub_result.deinit();
                    if (sub_result.matched) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options)) break;
                    }
                },
                .AssertForwardNegative => {
                    const epc = findAssertEnd(self.bytecode.instructions.items, pc + 1);
                    var sub_result = try execInternal(true, self, input, pos, pc + 1, epc);
                    defer sub_result.deinit();
                    if (!sub_result.matched) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options)) break;
                    }
                },
                .AssertForwardEnd => {
                    pc += 1;
                },
                .AssertBackward => {
                    const epc = findAssertEnd(self.bytecode.instructions.items, pc + 1);
                    var success = false;
                    var try_pos: usize = 0;
                    while (try_pos <= pos) : (try_pos += 1) {
                        var sub_result = try execInternal(true, self, input, try_pos, pc + 1, epc);
                        defer sub_result.deinit();
                        if (sub_result.matched) {
                            if (sub_result.end == pos) {
                                success = true;
                                break;
                            }
                        }
                    }
                    if (success) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options)) break;
                    }
                },
                .AssertBackwardNegative => {
                    const epc = findAssertEnd(self.bytecode.instructions.items, pc + 1);
                    var success = true;
                    var try_pos: usize = 0;
                    while (try_pos <= pos) : (try_pos += 1) {
                        var sub_result = try execInternal(true, self, input, try_pos, pc + 1, epc);
                        defer sub_result.deinit();
                        if (sub_result.matched) {
                            if (sub_result.end == pos) {
                                success = false;
                                break;
                            }
                        }
                    }
                    if (success) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(is_sub, &stack, &captures, &pc, &pos, &subroutine_stack, &self.options)) break;
                    }
                },
                .AssertBackwardEnd => {
                    pc += 1;
                },
                .SubroutineCall => {
                    if (inst.target.? != pc + 1) {
                        try subroutine_stack.append(self.allocator, pc + 1);
                    }
                    pc = inst.target.?;
                },
                .SubroutineReturn => {
                    if (subroutine_stack.items.len > 0) {
                        pc = subroutine_stack.pop().?;
                    } else {
                        pc += 1;
                    }
                },
            }
        }

        if (is_sub) {
            // Sub-matches don't need to return captures
            return MatchResult{
                .matched = matched,
                .captures = .empty,
                .start = start_pos,
                .end = match_end,
                .allocator = self.allocator,
            };
        } else {
            // Main match: clone captures for the caller
            const owned_captures = try self.allocator.dupe(?usize, captures.items);
            return MatchResult{
                .matched = matched,
                .captures = .{ .items = owned_captures, .capacity = owned_captures.len },
                .start = if (captures.items[0]) |s| s else start_pos,
                .end = match_end,
                .allocator = self.allocator,
            };
        }
    }



    pub fn match(self: *Vm, input: []const u8) !bool {
        var result = try self.exec(input, 0);
        defer result.deinit();
        return result.matched;
    }

    pub fn find(self: *Vm, input: []const u8) !?MatchResult {
        // If pattern starts with a fixed char, jump directly to matching positions
        if (self.bytecode.first_char) |first| {
            var start: usize = 0;
            while (start <= input.len) {
                // Find next position matching first_char
                if (self.options.case_sensitive) {
                    if (std.mem.indexOfScalar(u8, input[start..], first)) |idx| {
                        start += idx;
                    } else {
                        break;
                    }
                } else {
                    // Fast path: ASCII characters can use simple toLower comparison
                    if (first < 128) {
                        const first_lower = std.ascii.toLower(first);
                        while (start < input.len and std.ascii.toLower(input[start]) != first_lower) {
                            start += 1;
                        }
                    } else {
                        while (start < input.len and !unicode_case.caseInsensitiveEqual(input[start], first)) {
                            start += 1;
                        }
                    }
                }
                if (start > input.len) break;
                
                var result = try self.exec(input, start);
                if (result.matched) {
                    return result;
                }
                result.deinit();
                start += 1;
            }
            return null;
        }
        
        // Generic path
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
        return execInternal(false, self, input, start_pos, 0, self.bytecode.instructions.items.len);
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

    const bytecode = try compiler.compile(ast.?, .{});

    var vm = try Vm.init(allocator, bytecode, .{});
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

    const bytecode = try compiler.compile(ast.?, .{});

    var vm = try Vm.init(allocator, bytecode, .{});
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

    const bytecode = try compiler.compile(ast.?, .{});

    var vm = try Vm.init(allocator, bytecode, .{});
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

    const bytecode = try compiler.compile(ast.?, .{});

    var vm = try Vm.init(allocator, bytecode, .{});
    defer vm.deinit();

    try std.testing.expect(try vm.match(""));
    try std.testing.expect(try vm.match("a"));
    try std.testing.expect(try vm.match("aaa"));
    // a* can match empty string, so it matches empty at the start of "b"
    // This is correct regex behavior
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

    const bytecode = try compiler.compile(ast.?, .{});

    var vm = try Vm.init(allocator, bytecode, .{});
    defer vm.deinit();

    var result = try vm.find("ab");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.matched);

    const group = result.?.getGroup("ab", 1);
    try std.testing.expect(group != null);
    try std.testing.expectEqualStrings("ab", group.?);

    if (result) |*r| r.deinit();
}
