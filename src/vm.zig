const std = @import("std");
const Bytecode = @import("bytecode.zig").Bytecode;
const Instruction = @import("bytecode.zig").Instruction;

const RegexOptions = @import("options.zig").RegexOptions;
const unicode_case = @import("unicode_case.zig");

pub const MatchResult = struct {
    matched: bool,
    captures: std.ArrayList(?usize),
    start: usize,
    end: usize,
    allocator: std.mem.Allocator,
    captures_owned: bool = true,

    pub fn deinit(self: *MatchResult) void {
        if (self.captures_owned) {
            self.captures.deinit(self.allocator);
        }
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

    /// Create a sub-match result (no captures, owned).
    pub fn sub(matched: bool, start_pos: usize, end_pos: usize, allocator: std.mem.Allocator) MatchResult {
        return .{
            .matched = matched,
            .captures = .empty,
            .start = start_pos,
            .end = end_pos,
            .allocator = allocator,
            .captures_owned = true,
        };
    }

    /// Create a main match result with borrowed captures.
    pub fn borrow(matched_: bool, captures_buf: std.ArrayList(?usize), start_pos: usize, end_pos: usize, allocator: std.mem.Allocator) MatchResult {
        const match_start = if (captures_buf.items[0]) |s| s else start_pos;
        return .{
            .matched = matched_,
            .captures = captures_buf,
            .start = match_start,
            .end = end_pos,
            .allocator = allocator,
            .captures_owned = false,
        };
    }

    /// Create a main match result with owned captures.
    pub fn owned(matched_: bool, captures_slice: []?usize, start_pos: usize, end_pos: usize, allocator: std.mem.Allocator) MatchResult {
        const match_start = if (captures_slice.len > 0 and captures_slice[0] != null) captures_slice[0].? else start_pos;
        return .{
            .matched = matched_,
            .captures = .{ .items = captures_slice, .capacity = captures_slice.len },
            .start = match_start,
            .end = end_pos,
            .allocator = allocator,
            .captures_owned = true,
        };
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
    options.* = frame.options;
}

/// Pop frame and backtrack if stack is non-empty. Returns false if stack was empty.
fn maybeBacktrack(
    stack: *std.ArrayList(Frame),
    captures: *std.ArrayList(?usize),
    pc: *usize,
    pos: *usize,
    subroutine_stack: *std.ArrayList(usize),
    options: *RegexOptions,
) bool {
    if (stack.items.len == 0) return false;
    backtrack(stack.pop().?, captures, pc, pos, subroutine_stack, options);
    return true;
}

/// If `advance` is non-null, advance pc/pos and return true.
/// Otherwise backtrack and return whether backtracking succeeded.
fn tryMatchOpt(
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
    return maybeBacktrack(stack, captures, pc, pos, subroutine_stack, options);
}

/// If `matched` is true, advance pc/pos by `advance_by` and return true.
/// Otherwise backtrack and return whether backtracking succeeded.
fn tryMatch(
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
    return maybeBacktrack(stack, captures, pc, pos, subroutine_stack, options);
}

/// Match a CharClass instruction at the given position.
/// Returns the byte length to advance if matched, null otherwise.
fn matchCharClass(cc: *const @import("parser.zig").CharClass, input: []const u8, pos: usize, case_sensitive: bool) ?usize {
    if (pos >= input.len) return null;
    const ch = input[pos];

    // Fast path for ASCII: check dense bitmap first (O(1)).
    // Only use bitmap for non-negated classes with no POSIX/Unicode classes,
    // because bitmap tracks ranges only.
    if (ch < 128 and cc.has_ascii_bitmap and !cc.negated and !cc.has_ranges_or_posix and !cc.has_unicode_ranges and !cc.has_unicode_props) {
        const byte = ch;
        const byte_mask = @as(u1, @truncate(cc.ascii_bitmap[byte >> 3] >> @truncate(byte & 7)));
        if (byte_mask != 0) return 1;
        return null;
    }

    // Check ranges and POSIX classes (ASCII single-byte)
    if (ch < 128 and cc.has_ranges_or_posix) {
        const range_match = if (case_sensitive)
            cc.contains(ch)
        else
            cc.contains(ch) or cc.contains(std.ascii.toLower(ch)) or cc.contains(std.ascii.toUpper(ch));
        if (range_match) return 1;
        const posix_match = if (case_sensitive)
            cc.containsPosixClass(ch)
        else
            cc.containsPosixClass(ch) or cc.containsPosixClass(std.ascii.toLower(ch)) or cc.containsPosixClass(std.ascii.toUpper(ch));
        if (posix_match) return 1;
    }

    // For ASCII chars with no Unicode data, we're done
    if (ch < 128 and !cc.has_unicode_ranges and !cc.has_unicode_props) return null;

    // Check Unicode ranges
    if (cc.has_unicode_ranges) {
        if (ch < 128) {
            if (cc.containsUnicodeRange(ch)) return 1;
        } else {
            const byte_len = std.unicode.utf8ByteSequenceLength(ch) catch 1;
            if (pos + byte_len <= input.len) {
                const cp = std.unicode.utf8Decode(input[pos .. pos + byte_len]) catch ch;
                if (cc.containsUnicodeRange(cp)) return byte_len;
            }
        }
    }

    // Check Unicode properties
    if (cc.has_unicode_props) {
        if (matchUnicodePropertyInClass(input, pos, cc)) |byte_len| {
            return byte_len;
        }
    }

    return null;
}

/// Match a CharUtf8 instruction at the given position.
/// Returns the byte length to advance if matched, null otherwise.
fn matchCharUtf8(input: []const u8, pos: usize, expected_cp: u21, case_sensitive: bool) ?usize {
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
/// Match a backref at the given position.
/// Returns the byte length to advance if matched, null otherwise.
fn matchBackref(input: []const u8, pos: usize, captures: []const ?usize, group_idx: usize, case_sensitive: bool) ?usize {
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

inline fn inUnicodeRanges(cp: u21, ranges: []const [2]u21) bool {
    var left: usize = 0;
    var right: usize = ranges.len;
    while (left < right) {
        const mid = (left + right) / 2;
        const range = ranges[mid];
        if (cp < range[0]) {
            right = mid;
        } else if (cp > range[1]) {
            left = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

const _Cs_ranges = [_][2]u21{
    .{ 0xD800, 0xDFFF },
};

const _Cf_ranges = [_][2]u21{
    .{ 0x00AD, 0x00AD },
    .{ 0x0600, 0x0605 },
    .{ 0x061C, 0x061C },
    .{ 0x06DD, 0x06DD },
    .{ 0x070F, 0x070F },
    .{ 0x08E2, 0x08E2 },
    .{ 0x180E, 0x180E },
    .{ 0x200B, 0x200F },
    .{ 0x202A, 0x202E },
    .{ 0x2060, 0x2064 },
    .{ 0x2066, 0x206F },
    .{ 0xFEFF, 0xFEFF },
    .{ 0xFFF9, 0xFFFB },
    .{ 0x110BD, 0x110BD },
    .{ 0x1BCA0, 0x1BCA3 },
    .{ 0x1D173, 0x1D17A },
    .{ 0xE0001, 0xE0001 },
    .{ 0xE0020, 0xE007F },
};

const _Sc_ranges = [_][2]u21{
    .{ 0x0024, 0x0024 },
    .{ 0x00A2, 0x00A5 },
    .{ 0x058F, 0x058F },
    .{ 0x060B, 0x060B },
    .{ 0x09F2, 0x09F3 },
    .{ 0x09FB, 0x09FB },
    .{ 0x0AF1, 0x0AF1 },
    .{ 0x0BF9, 0x0BF9 },
    .{ 0x0E3F, 0x0E3F },
    .{ 0x17DB, 0x17DB },
    .{ 0x20A0, 0x20C0 },
    .{ 0xA838, 0xA838 },
    .{ 0xFDFC, 0xFDFC },
    .{ 0xFE69, 0xFE69 },
    .{ 0xFF04, 0xFF04 },
    .{ 0xFFE0, 0xFFE1 },
    .{ 0xFFE5, 0xFFE6 },
};

const _Pf_ranges = [_][2]u21{
    .{ 0x00BB, 0x00BB },
    .{ 0x2019, 0x2019 },
    .{ 0x201D, 0x201D },
    .{ 0x203A, 0x203A },
};

const _Ps_ranges = [_][2]u21{
    .{ 0x0028, 0x0028 },
    .{ 0x005B, 0x005B },
    .{ 0x007B, 0x007B },
    .{ 0x0F3A, 0x0F3A },
    .{ 0x0F3C, 0x0F3C },
    .{ 0x169B, 0x169B },
    .{ 0x201A, 0x201A },
    .{ 0x201E, 0x201E },
    .{ 0x2045, 0x2045 },
    .{ 0x207D, 0x207D },
    .{ 0x208D, 0x208D },
    .{ 0x2308, 0x2308 },
    .{ 0x230A, 0x230A },
    .{ 0x2329, 0x2329 },
    .{ 0x2768, 0x2768 },
    .{ 0x276A, 0x276A },
    .{ 0x276C, 0x276C },
    .{ 0x276E, 0x276E },
    .{ 0x2770, 0x2770 },
    .{ 0x2772, 0x2772 },
    .{ 0x2774, 0x2774 },
    .{ 0x27C5, 0x27C5 },
    .{ 0x27E6, 0x27E6 },
    .{ 0x27E8, 0x27E8 },
    .{ 0x27EA, 0x27EA },
    .{ 0x27EC, 0x27EC },
    .{ 0x27EE, 0x27EE },
    .{ 0x2983, 0x2983 },
    .{ 0x2985, 0x2985 },
    .{ 0x2987, 0x2987 },
    .{ 0x2989, 0x2989 },
    .{ 0x298B, 0x298B },
    .{ 0x298D, 0x298D },
    .{ 0x298F, 0x298F },
    .{ 0x2991, 0x2991 },
    .{ 0x2993, 0x2993 },
    .{ 0x2995, 0x2995 },
    .{ 0x2997, 0x2997 },
    .{ 0x29D8, 0x29D8 },
    .{ 0x29DA, 0x29DA },
    .{ 0x29FC, 0x29FC },
    .{ 0x2E22, 0x2E22 },
    .{ 0x2E24, 0x2E24 },
    .{ 0x2E26, 0x2E26 },
    .{ 0x2E28, 0x2E28 },
    .{ 0x3008, 0x3008 },
    .{ 0x300A, 0x300A },
    .{ 0x300C, 0x300C },
    .{ 0x300E, 0x300E },
    .{ 0x3010, 0x3010 },
    .{ 0x3014, 0x3014 },
    .{ 0x3016, 0x3016 },
    .{ 0x3018, 0x3018 },
    .{ 0x301A, 0x301A },
    .{ 0x301D, 0x301D },
    .{ 0xFD3F, 0xFD3F },
    .{ 0xFE17, 0xFE17 },
    .{ 0xFE35, 0xFE35 },
    .{ 0xFE37, 0xFE37 },
    .{ 0xFE39, 0xFE39 },
    .{ 0xFE3B, 0xFE3B },
    .{ 0xFE3D, 0xFE3D },
    .{ 0xFE3F, 0xFE3F },
    .{ 0xFE41, 0xFE41 },
    .{ 0xFE43, 0xFE43 },
    .{ 0xFE47, 0xFE47 },
    .{ 0xFE59, 0xFE59 },
    .{ 0xFE5B, 0xFE5B },
    .{ 0xFE5D, 0xFE5D },
    .{ 0xFF08, 0xFF08 },
    .{ 0xFF3B, 0xFF3B },
    .{ 0xFF5B, 0xFF5B },
    .{ 0xFF5F, 0xFF5F },
    .{ 0xFF62, 0xFF62 },
};

const _Ll_ranges = [_][2]u21{
    .{ 0x0061, 0x007A },
    .{ 0x00DF, 0x00F6 },
    .{ 0x00F8, 0x00FF },
    .{ 0x0138, 0x0138 },
    .{ 0x0149, 0x0149 },
    .{ 0x03AC, 0x03CE },
    .{ 0x0430, 0x044F },
    .{ 0x0451, 0x045C },
    .{ 0x045E, 0x045F },
    .{ 0x1F00, 0x1F07 },
    .{ 0x1F10, 0x1F15 },
    .{ 0x1F20, 0x1F27 },
    .{ 0x1F30, 0x1F37 },
    .{ 0x1F40, 0x1F45 },
    .{ 0x1F50, 0x1F57 },
    .{ 0x1F60, 0x1F67 },
    .{ 0x1F70, 0x1F7D },
    .{ 0x1F80, 0x1F87 },
    .{ 0x1F90, 0x1F97 },
    .{ 0x1FA0, 0x1FA7 },
    .{ 0x1FB0, 0x1FB1 },
    .{ 0x1FD0, 0x1FD1 },
    .{ 0x1FE0, 0x1FE1 },
    .{ 0x214E, 0x214E },
    .{ 0x2170, 0x217F },
};

const _Zl_ranges = [_][2]u21{
    .{ 0x2028, 0x2028 },
};

const _Pi_ranges = [_][2]u21{
    .{ 0x00AB, 0x00AB },
    .{ 0x2018, 0x2018 },
    .{ 0x201B, 0x201C },
    .{ 0x201F, 0x201F },
    .{ 0x2039, 0x2039 },
};

const _Lm_ranges = [_][2]u21{
    .{ 0x02B0, 0x02C1 },
    .{ 0x02C6, 0x02D1 },
    .{ 0x02E0, 0x02E4 },
    .{ 0x02EC, 0x02EC },
    .{ 0x02EE, 0x02EE },
    .{ 0x0374, 0x0374 },
    .{ 0x037A, 0x037A },
    .{ 0x0559, 0x0559 },
    .{ 0x0640, 0x0640 },
    .{ 0x06E5, 0x06E6 },
    .{ 0x07F4, 0x07F5 },
    .{ 0x07FA, 0x07FA },
    .{ 0x0E46, 0x0E46 },
    .{ 0x0EC6, 0x0EC6 },
    .{ 0x10FC, 0x10FC },
    .{ 0x17D7, 0x17D7 },
    .{ 0x1843, 0x1843 },
    .{ 0x1D2C, 0x1D6A },
    .{ 0x1D78, 0x1D78 },
    .{ 0x1D9B, 0x1DBF },
    .{ 0x2071, 0x2071 },
    .{ 0x207F, 0x207F },
    .{ 0x2090, 0x209C },
    .{ 0x2C7C, 0x2C7D },
    .{ 0x2D6F, 0x2D6F },
    .{ 0x2E2F, 0x2E2F },
    .{ 0x3005, 0x3005 },
    .{ 0x3031, 0x3035 },
    .{ 0x303B, 0x303B },
    .{ 0x309D, 0x309E },
    .{ 0x30FC, 0x30FE },
    .{ 0xA015, 0xA015 },
    .{ 0xA4F8, 0xA4FD },
    .{ 0xA60C, 0xA60C },
    .{ 0xA67F, 0xA67F },
    .{ 0xA69C, 0xA69D },
    .{ 0xA717, 0xA71F },
    .{ 0xA770, 0xA770 },
    .{ 0xA788, 0xA788 },
    .{ 0xA7F8, 0xA7F9 },
    .{ 0xA9CF, 0xA9CF },
    .{ 0xAA70, 0xAA70 },
    .{ 0xAADD, 0xAADD },
    .{ 0xAAF3, 0xAAF4 },
    .{ 0xFF70, 0xFF70 },
    .{ 0xFF9E, 0xFF9F },
};

const _Nl_ranges = [_][2]u21{
    .{ 0x16EE, 0x16F0 },
    .{ 0x2160, 0x2182 },
    .{ 0x2185, 0x2188 },
    .{ 0x3007, 0x3007 },
    .{ 0x3021, 0x3029 },
    .{ 0x3038, 0x303A },
    .{ 0xA6E6, 0xA6EF },
};

const _Mn_ranges = [_][2]u21{
    .{ 0x0300, 0x036F },
    .{ 0x0483, 0x0489 },
    .{ 0x0591, 0x05BD },
    .{ 0x05BF, 0x05BF },
    .{ 0x05C1, 0x05C2 },
    .{ 0x05C4, 0x05C5 },
    .{ 0x05C7, 0x05C7 },
    .{ 0x0610, 0x061A },
    .{ 0x064B, 0x065F },
    .{ 0x0670, 0x0670 },
    .{ 0x06D6, 0x06DC },
    .{ 0x06DF, 0x06E4 },
    .{ 0x06E7, 0x06E8 },
    .{ 0x06EA, 0x06ED },
    .{ 0x0711, 0x0711 },
    .{ 0x0730, 0x074A },
    .{ 0x07A6, 0x07B0 },
    .{ 0x07EB, 0x07F3 },
    .{ 0x0816, 0x0819 },
    .{ 0x081B, 0x0823 },
    .{ 0x0825, 0x0827 },
    .{ 0x0829, 0x082D },
    .{ 0x0859, 0x085B },
    .{ 0x08E3, 0x0902 },
    .{ 0x093A, 0x093A },
    .{ 0x093C, 0x093C },
    .{ 0x0941, 0x0948 },
    .{ 0x094D, 0x094D },
    .{ 0x0951, 0x0957 },
    .{ 0x0962, 0x0963 },
    .{ 0x0981, 0x0981 },
    .{ 0x09BC, 0x09BC },
    .{ 0x09C1, 0x09C4 },
    .{ 0x09CD, 0x09CD },
    .{ 0x09E2, 0x09E3 },
    .{ 0x0A01, 0x0A02 },
    .{ 0x0A3C, 0x0A3C },
    .{ 0x0A41, 0x0A42 },
    .{ 0x0A47, 0x0A48 },
    .{ 0x0A4B, 0x0A4D },
    .{ 0x0A51, 0x0A51 },
    .{ 0x0A70, 0x0A71 },
    .{ 0x0A75, 0x0A75 },
    .{ 0x0A81, 0x0A82 },
    .{ 0x0ABC, 0x0ABC },
    .{ 0x0AC1, 0x0AC5 },
    .{ 0x0AC7, 0x0AC8 },
    .{ 0x0ACD, 0x0ACD },
    .{ 0x0AE2, 0x0AE3 },
    .{ 0x0B01, 0x0B01 },
    .{ 0x0B3C, 0x0B3C },
    .{ 0x0B3F, 0x0B3F },
    .{ 0x0B41, 0x0B44 },
    .{ 0x0B4D, 0x0B4D },
    .{ 0x0B56, 0x0B56 },
    .{ 0x0B62, 0x0B63 },
    .{ 0x0B82, 0x0B82 },
    .{ 0x0BC0, 0x0BC0 },
    .{ 0x0BCD, 0x0BCD },
    .{ 0x0C00, 0x0C00 },
    .{ 0x0C3E, 0x0C40 },
    .{ 0x0C46, 0x0C48 },
    .{ 0x0C4A, 0x0C4D },
    .{ 0x0C55, 0x0C56 },
    .{ 0x0C62, 0x0C63 },
    .{ 0x0C81, 0x0C81 },
    .{ 0x0CBC, 0x0CBC },
    .{ 0x0CBF, 0x0CBF },
    .{ 0x0CC6, 0x0CC6 },
    .{ 0x0CCC, 0x0CCD },
    .{ 0x0CE2, 0x0CE3 },
    .{ 0x0D01, 0x0D01 },
    .{ 0x0D41, 0x0D44 },
    .{ 0x0D4D, 0x0D4D },
    .{ 0x0D62, 0x0D63 },
    .{ 0x0DCA, 0x0DCA },
    .{ 0x0DD2, 0x0DD4 },
    .{ 0x0DD6, 0x0DD6 },
    .{ 0x0E31, 0x0E31 },
    .{ 0x0E34, 0x0E3A },
    .{ 0x0E47, 0x0E4E },
    .{ 0x0EB1, 0x0EB1 },
    .{ 0x0EB4, 0x0EB9 },
    .{ 0x0EBB, 0x0EBC },
    .{ 0x0EC8, 0x0ECD },
    .{ 0x0F18, 0x0F19 },
    .{ 0x0F35, 0x0F35 },
    .{ 0x0F37, 0x0F37 },
    .{ 0x0F39, 0x0F39 },
    .{ 0x0F71, 0x0F7E },
    .{ 0x0F80, 0x0F84 },
    .{ 0x0F86, 0x0F87 },
    .{ 0x0F8D, 0x0F97 },
    .{ 0x0F99, 0x0FBC },
    .{ 0x0FC6, 0x0FC6 },
    .{ 0x102D, 0x1030 },
    .{ 0x1032, 0x1037 },
    .{ 0x1039, 0x103A },
    .{ 0x103D, 0x103E },
    .{ 0x1058, 0x1059 },
    .{ 0x105E, 0x1060 },
    .{ 0x1071, 0x1074 },
    .{ 0x1082, 0x1082 },
    .{ 0x1085, 0x1086 },
    .{ 0x108D, 0x108D },
    .{ 0x109D, 0x109D },
    .{ 0x135D, 0x135F },
    .{ 0x1712, 0x1714 },
    .{ 0x1732, 0x1734 },
    .{ 0x1752, 0x1753 },
    .{ 0x1772, 0x1773 },
    .{ 0x17B4, 0x17B5 },
    .{ 0x17B7, 0x17BD },
    .{ 0x17C6, 0x17C6 },
    .{ 0x17C9, 0x17D3 },
    .{ 0x17DD, 0x17DD },
    .{ 0x180B, 0x180D },
    .{ 0x1885, 0x1886 },
    .{ 0x18A9, 0x18A9 },
    .{ 0x1920, 0x1922 },
    .{ 0x1927, 0x1928 },
    .{ 0x1932, 0x1932 },
    .{ 0x1939, 0x193B },
    .{ 0x1A17, 0x1A18 },
    .{ 0x1A56, 0x1A56 },
    .{ 0x1A58, 0x1A5E },
    .{ 0x1A60, 0x1A60 },
    .{ 0x1A62, 0x1A62 },
    .{ 0x1A65, 0x1A6C },
    .{ 0x1A73, 0x1A7C },
    .{ 0x1A7F, 0x1A7F },
    .{ 0x1AB0, 0x1ABD },
    .{ 0x1B00, 0x1B03 },
    .{ 0x1B34, 0x1B34 },
    .{ 0x1B36, 0x1B3A },
    .{ 0x1B3C, 0x1B3C },
    .{ 0x1B42, 0x1B42 },
    .{ 0x1B6B, 0x1B73 },
    .{ 0x1B80, 0x1B81 },
    .{ 0x1BA2, 0x1BA5 },
    .{ 0x1BA8, 0x1BA9 },
    .{ 0x1BAB, 0x1BAD },
    .{ 0x1BE6, 0x1BE6 },
    .{ 0x1BE8, 0x1BE9 },
    .{ 0x1BED, 0x1BED },
    .{ 0x1BEF, 0x1BF1 },
    .{ 0x1C2C, 0x1C33 },
    .{ 0x1C36, 0x1C37 },
    .{ 0x1CD0, 0x1CD2 },
    .{ 0x1CD4, 0x1CE0 },
    .{ 0x1CE2, 0x1CE8 },
    .{ 0x1CED, 0x1CED },
    .{ 0x1CF4, 0x1CF4 },
    .{ 0x1CF8, 0x1CF9 },
    .{ 0x1DC0, 0x1DF5 },
    .{ 0x1DFC, 0x1DFF },
    .{ 0x20D0, 0x20DC },
    .{ 0x20E1, 0x20E1 },
    .{ 0x20E5, 0x20F0 },
    .{ 0x2CEF, 0x2CF1 },
    .{ 0x2D7F, 0x2D7F },
    .{ 0x2DE0, 0x2DFF },
    .{ 0x302A, 0x302D },
    .{ 0x3099, 0x309A },
    .{ 0xA66F, 0xA66F },
    .{ 0xA674, 0xA67D },
    .{ 0xA69E, 0xA69F },
    .{ 0xA6F0, 0xA6F1 },
    .{ 0xA802, 0xA802 },
    .{ 0xA806, 0xA806 },
    .{ 0xA80B, 0xA80B },
    .{ 0xA825, 0xA826 },
    .{ 0xA8C4, 0xA8C5 },
    .{ 0xA8E0, 0xA8F1 },
    .{ 0xA926, 0xA92D },
    .{ 0xA947, 0xA951 },
    .{ 0xA980, 0xA982 },
    .{ 0xA9B3, 0xA9B3 },
    .{ 0xA9B6, 0xA9B9 },
    .{ 0xA9BC, 0xA9BC },
    .{ 0xA9E5, 0xA9E5 },
    .{ 0xAA29, 0xAA2E },
    .{ 0xAA31, 0xAA32 },
    .{ 0xAA35, 0xAA36 },
    .{ 0xAA43, 0xAA43 },
    .{ 0xAA4C, 0xAA4C },
    .{ 0xAA7C, 0xAA7C },
    .{ 0xAAB0, 0xAAB0 },
    .{ 0xAAB2, 0xAAB4 },
    .{ 0xAAB7, 0xAAB8 },
    .{ 0xAABE, 0xAABF },
    .{ 0xAAC1, 0xAAC1 },
    .{ 0xAAEC, 0xAAED },
    .{ 0xAAF6, 0xAAF6 },
    .{ 0xABE5, 0xABE5 },
    .{ 0xABE8, 0xABE8 },
    .{ 0xABED, 0xABED },
    .{ 0xFB1E, 0xFB1E },
    .{ 0xFE00, 0xFE0F },
    .{ 0xFE20, 0xFE2F },
};

const _Lo_ranges = [_][2]u21{
    .{ 0x01BB, 0x01BB },
    .{ 0x01C0, 0x01C3 },
    .{ 0x0294, 0x0294 },
    .{ 0x05D0, 0x05EA },
    .{ 0x05F0, 0x05F2 },
    .{ 0x0621, 0x063F },
    .{ 0x0641, 0x064A },
    .{ 0x066E, 0x066F },
    .{ 0x0671, 0x06D3 },
    .{ 0x06D5, 0x06D5 },
    .{ 0x06EE, 0x06EF },
    .{ 0x06FA, 0x06FC },
    .{ 0x06FF, 0x06FF },
    .{ 0x0710, 0x0710 },
    .{ 0x0712, 0x072F },
    .{ 0x074D, 0x07A5 },
    .{ 0x07B1, 0x07B1 },
    .{ 0x07CA, 0x07EA },
    .{ 0x0800, 0x0815 },
    .{ 0x0840, 0x0858 },
    .{ 0x08A0, 0x08AC },
    .{ 0x0904, 0x0939 },
    .{ 0x093D, 0x093D },
    .{ 0x0950, 0x0950 },
    .{ 0x0958, 0x0961 },
    .{ 0x0972, 0x0980 },
    .{ 0x0985, 0x098C },
    .{ 0x098F, 0x0990 },
    .{ 0x0993, 0x09A8 },
    .{ 0x09AA, 0x09B0 },
    .{ 0x09B2, 0x09B2 },
    .{ 0x09B6, 0x09B9 },
    .{ 0x09BD, 0x09BD },
    .{ 0x09CE, 0x09CE },
    .{ 0x09DC, 0x09DD },
    .{ 0x09DF, 0x09E1 },
    .{ 0x09F0, 0x09F1 },
    .{ 0x0A05, 0x0A0A },
    .{ 0x0A0F, 0x0A10 },
    .{ 0x0A13, 0x0A28 },
    .{ 0x0A2A, 0x0A30 },
    .{ 0x0A32, 0x0A33 },
    .{ 0x0A35, 0x0A36 },
    .{ 0x0A38, 0x0A39 },
    .{ 0x0A59, 0x0A5C },
    .{ 0x0A5E, 0x0A5E },
    .{ 0x0A72, 0x0A74 },
    .{ 0x0A85, 0x0A8D },
    .{ 0x0A8F, 0x0A91 },
    .{ 0x0A93, 0x0AA8 },
    .{ 0x0AAA, 0x0AB0 },
    .{ 0x0AB2, 0x0AB3 },
    .{ 0x0AB5, 0x0AB9 },
    .{ 0x0ABD, 0x0ABD },
    .{ 0x0AD0, 0x0AD0 },
    .{ 0x0AE0, 0x0AE1 },
    .{ 0x0B05, 0x0B0C },
    .{ 0x0B0F, 0x0B10 },
    .{ 0x0B13, 0x0B28 },
    .{ 0x0B2A, 0x0B30 },
    .{ 0x0B32, 0x0B33 },
    .{ 0x0B35, 0x0B39 },
    .{ 0x0B3D, 0x0B3D },
    .{ 0x0B5C, 0x0B5D },
    .{ 0x0B5F, 0x0B61 },
    .{ 0x0B71, 0x0B71 },
    .{ 0x0B83, 0x0B83 },
    .{ 0x0B85, 0x0B8A },
    .{ 0x0B8E, 0x0B90 },
    .{ 0x0B92, 0x0B95 },
    .{ 0x0B99, 0x0B9A },
    .{ 0x0B9C, 0x0B9C },
    .{ 0x0B9E, 0x0B9F },
    .{ 0x0BA3, 0x0BA4 },
    .{ 0x0BA8, 0x0BAA },
    .{ 0x0BAE, 0x0BB9 },
    .{ 0x0BD0, 0x0BD0 },
    .{ 0x0C05, 0x0C0C },
    .{ 0x0C0E, 0x0C10 },
    .{ 0x0C12, 0x0C28 },
    .{ 0x0C2A, 0x0C39 },
    .{ 0x0C3D, 0x0C3D },
    .{ 0x0C58, 0x0C5A },
    .{ 0x0C60, 0x0C61 },
    .{ 0x0C85, 0x0C8C },
    .{ 0x0C8E, 0x0C90 },
    .{ 0x0C92, 0x0CA8 },
    .{ 0x0CAA, 0x0CB3 },
    .{ 0x0CB5, 0x0CB9 },
    .{ 0x0CBD, 0x0CBD },
    .{ 0x0CDE, 0x0CDE },
    .{ 0x0CE0, 0x0CE1 },
    .{ 0x0CF1, 0x0CF2 },
    .{ 0x0D05, 0x0D0C },
    .{ 0x0D0E, 0x0D10 },
    .{ 0x0D12, 0x0D3A },
    .{ 0x0D3D, 0x0D3D },
    .{ 0x0D4E, 0x0D4E },
    .{ 0x0D5F, 0x0D61 },
    .{ 0x0D7A, 0x0D7F },
    .{ 0x0D85, 0x0D96 },
    .{ 0x0D9A, 0x0DB1 },
    .{ 0x0DB3, 0x0DBB },
    .{ 0x0DBD, 0x0DBD },
    .{ 0x0DC0, 0x0DC6 },
    .{ 0x0E01, 0x0E30 },
    .{ 0x0E32, 0x0E33 },
    .{ 0x0E40, 0x0E46 },
    .{ 0x0E81, 0x0E82 },
    .{ 0x0E84, 0x0E84 },
    .{ 0x0E87, 0x0E88 },
    .{ 0x0E8A, 0x0E8A },
    .{ 0x0E8D, 0x0E8D },
    .{ 0x0E94, 0x0E97 },
    .{ 0x0E99, 0x0E9F },
    .{ 0x0EA1, 0x0EA3 },
    .{ 0x0EA5, 0x0EA5 },
    .{ 0x0EA7, 0x0EA7 },
    .{ 0x0EAA, 0x0EAB },
    .{ 0x0EAD, 0x0EB0 },
    .{ 0x0EB2, 0x0EB3 },
    .{ 0x0EBD, 0x0EBD },
    .{ 0x0EC0, 0x0EC4 },
    .{ 0x0EC6, 0x0EC6 },
    .{ 0x0EDC, 0x0EDF },
    .{ 0x0F00, 0x0F00 },
    .{ 0x0F40, 0x0F47 },
    .{ 0x0F49, 0x0F6C },
    .{ 0x0F88, 0x0F8C },
    .{ 0x1000, 0x102A },
    .{ 0x103F, 0x103F },
    .{ 0x1050, 0x1055 },
    .{ 0x105A, 0x105D },
    .{ 0x1061, 0x1061 },
    .{ 0x1065, 0x1066 },
    .{ 0x106E, 0x1070 },
    .{ 0x1075, 0x1081 },
    .{ 0x108E, 0x108E },
    .{ 0x10A0, 0x10C5 },
    .{ 0x10C7, 0x10C7 },
    .{ 0x10CD, 0x10CD },
    .{ 0x10D0, 0x10FA },
    .{ 0x10FC, 0x1248 },
    .{ 0x124A, 0x124D },
    .{ 0x1250, 0x1256 },
    .{ 0x1258, 0x1258 },
    .{ 0x125A, 0x125D },
    .{ 0x1260, 0x1288 },
    .{ 0x128A, 0x128D },
    .{ 0x1290, 0x12B0 },
    .{ 0x12B2, 0x12B5 },
    .{ 0x12B8, 0x12BE },
    .{ 0x12C0, 0x12C0 },
    .{ 0x12C2, 0x12C5 },
    .{ 0x12C8, 0x12D6 },
    .{ 0x12D8, 0x1310 },
    .{ 0x1312, 0x1315 },
    .{ 0x1318, 0x135A },
    .{ 0x1380, 0x138F },
    .{ 0x13A0, 0x13F5 },
    .{ 0x13F8, 0x13FD },
    .{ 0x1401, 0x166C },
    .{ 0x166F, 0x167F },
    .{ 0x1681, 0x169A },
    .{ 0x16A0, 0x16EA },
    .{ 0x16EE, 0x16F0 },
    .{ 0x1700, 0x170C },
    .{ 0x170E, 0x1711 },
    .{ 0x1720, 0x1731 },
    .{ 0x1740, 0x1751 },
    .{ 0x1760, 0x176C },
    .{ 0x176E, 0x1770 },
    .{ 0x1780, 0x17B3 },
    .{ 0x17D7, 0x17D7 },
    .{ 0x17DC, 0x17DC },
    .{ 0x1820, 0x1877 },
    .{ 0x1880, 0x1884 },
    .{ 0x1887, 0x18A8 },
    .{ 0x18AA, 0x18AA },
    .{ 0x18B0, 0x18F5 },
    .{ 0x1900, 0x191E },
    .{ 0x1950, 0x196D },
    .{ 0x1970, 0x1974 },
    .{ 0x1980, 0x19AB },
    .{ 0x19C1, 0x19C7 },
    .{ 0x1A00, 0x1A16 },
    .{ 0x1A20, 0x1A54 },
    .{ 0x1AA7, 0x1AA7 },
    .{ 0x1B05, 0x1B33 },
    .{ 0x1B45, 0x1B4B },
    .{ 0x1B83, 0x1BA0 },
    .{ 0x1BAE, 0x1BAF },
    .{ 0x1BBA, 0x1BE5 },
    .{ 0x1C00, 0x1C23 },
    .{ 0x1C4D, 0x1C4F },
    .{ 0x1C5A, 0x1C7D },
    .{ 0x1C80, 0x1C88 },
    .{ 0x1CE9, 0x1CEC },
    .{ 0x1CEE, 0x1CF1 },
    .{ 0x1CF5, 0x1CF6 },
    .{ 0x1D00, 0x1DBF },
    .{ 0x1E00, 0x1F15 },
    .{ 0x1F18, 0x1F1D },
    .{ 0x1F20, 0x1F45 },
    .{ 0x1F48, 0x1F4D },
    .{ 0x1F50, 0x1F57 },
    .{ 0x1F59, 0x1F59 },
    .{ 0x1F5B, 0x1F5B },
    .{ 0x1F5D, 0x1F5D },
    .{ 0x1F5F, 0x1F7D },
    .{ 0x1F80, 0x1FB4 },
    .{ 0x1FB6, 0x1FBC },
    .{ 0x1FBE, 0x1FBE },
    .{ 0x1FC2, 0x1FC4 },
    .{ 0x1FC6, 0x1FCC },
    .{ 0x1FD0, 0x1FD3 },
    .{ 0x1FD6, 0x1FDB },
    .{ 0x1FE0, 0x1FEC },
    .{ 0x1FF2, 0x1FF4 },
    .{ 0x1FF6, 0x1FFC },
    .{ 0x2071, 0x2071 },
    .{ 0x207F, 0x207F },
    .{ 0x2090, 0x209C },
    .{ 0x2102, 0x2102 },
    .{ 0x2107, 0x2107 },
    .{ 0x210A, 0x2113 },
    .{ 0x2115, 0x2115 },
    .{ 0x2119, 0x211D },
    .{ 0x2124, 0x2124 },
    .{ 0x2126, 0x2126 },
    .{ 0x2128, 0x2128 },
    .{ 0x212A, 0x212D },
    .{ 0x212F, 0x2139 },
    .{ 0x213C, 0x213F },
    .{ 0x2145, 0x2149 },
    .{ 0x214E, 0x214E },
    .{ 0x2183, 0x2184 },
    .{ 0x2C00, 0x2C2E },
    .{ 0x2C30, 0x2C5E },
    .{ 0x2C60, 0x2CE4 },
    .{ 0x2CEB, 0x2CEE },
    .{ 0x2CF2, 0x2CF3 },
    .{ 0x2D00, 0x2D25 },
    .{ 0x2D27, 0x2D27 },
    .{ 0x2D2D, 0x2D2D },
    .{ 0x2D30, 0x2D67 },
    .{ 0x2D6F, 0x2D6F },
    .{ 0x2D80, 0x2D96 },
    .{ 0x2DA0, 0x2DA6 },
    .{ 0x2DA8, 0x2DAE },
    .{ 0x2DB0, 0x2DB6 },
    .{ 0x2DB8, 0x2DBE },
    .{ 0x2DC0, 0x2DC6 },
    .{ 0x2DC8, 0x2DCE },
    .{ 0x2DD0, 0x2DD6 },
    .{ 0x2DD8, 0x2DDE },
    .{ 0x2E2F, 0x2E2F },
    .{ 0x3005, 0x3005 },
    .{ 0x3007, 0x3007 },
    .{ 0x3021, 0x3029 },
    .{ 0x3031, 0x3035 },
    .{ 0x3038, 0x303A },
    .{ 0x303B, 0x303B },
    .{ 0x303C, 0x303C },
    .{ 0x3041, 0x3096 },
    .{ 0x309D, 0x309F },
    .{ 0x30A1, 0x30FA },
    .{ 0x30FC, 0x30FF },
    .{ 0x3105, 0x312D },
    .{ 0x3131, 0x318E },
    .{ 0x31A0, 0x31BA },
    .{ 0x31F0, 0x31FF },
    .{ 0x3400, 0x4DB5 },
    .{ 0x4E00, 0x9FCC },
    .{ 0xA000, 0xA48C },
    .{ 0xA4D0, 0xA4FD },
    .{ 0xA500, 0xA60C },
    .{ 0xA610, 0xA61F },
    .{ 0xA62A, 0xA62B },
    .{ 0xA640, 0xA66E },
    .{ 0xA67F, 0xA697 },
    .{ 0xA6A0, 0xA6E5 },
    .{ 0xA717, 0xA71F },
    .{ 0xA722, 0xA788 },
    .{ 0xA78B, 0xA78E },
    .{ 0xA790, 0xA793 },
    .{ 0xA7A0, 0xA7AA },
    .{ 0xA7F8, 0xA801 },
    .{ 0xA803, 0xA805 },
    .{ 0xA807, 0xA80A },
    .{ 0xA80C, 0xA822 },
    .{ 0xA840, 0xA873 },
    .{ 0xA882, 0xA8B3 },
    .{ 0xA8F2, 0xA8F7 },
    .{ 0xA8FB, 0xA8FB },
    .{ 0xA90A, 0xA925 },
    .{ 0xA930, 0xA946 },
    .{ 0xA960, 0xA97C },
    .{ 0xA984, 0xA9B2 },
    .{ 0xA9CF, 0xA9CF },
    .{ 0xA9E0, 0xA9E4 },
    .{ 0xA9E6, 0xA9EF },
    .{ 0xA9FA, 0xA9FE },
    .{ 0xAA00, 0xAA28 },
    .{ 0xAA40, 0xAA42 },
    .{ 0xAA44, 0xAA4B },
    .{ 0xAA60, 0xAA76 },
    .{ 0xAA7A, 0xAA7A },
    .{ 0xAA80, 0xAAAF },
    .{ 0xAAB1, 0xAAB1 },
    .{ 0xAAB5, 0xAAB6 },
    .{ 0xAAB9, 0xAABD },
    .{ 0xAAC0, 0xAAC0 },
    .{ 0xAAC2, 0xAAC2 },
    .{ 0xAADB, 0xAADD },
    .{ 0xAAE0, 0xAAEA },
    .{ 0xAAF2, 0xAAF4 },
    .{ 0xAB01, 0xAB06 },
    .{ 0xAB09, 0xAB0E },
    .{ 0xAB11, 0xAB16 },
    .{ 0xAB20, 0xAB26 },
    .{ 0xAB28, 0xAB2E },
    .{ 0xAB30, 0xAB5A },
    .{ 0xAB5C, 0xAB5F },
    .{ 0xAB60, 0xAB65 },
    .{ 0xAB70, 0xABBF },
    .{ 0xABC0, 0xABE2 },
    .{ 0xAC00, 0xD7A3 },
    .{ 0xD7B0, 0xD7C6 },
    .{ 0xD7CB, 0xD7FB },
    .{ 0xF900, 0xFA6D },
    .{ 0xFA70, 0xFAD9 },
    .{ 0xFB00, 0xFB06 },
    .{ 0xFB13, 0xFB17 },
    .{ 0xFB1D, 0xFB1D },
    .{ 0xFB1F, 0xFB28 },
    .{ 0xFB2A, 0xFB36 },
    .{ 0xFB38, 0xFB3C },
    .{ 0xFB3E, 0xFB3E },
    .{ 0xFB40, 0xFB41 },
    .{ 0xFB43, 0xFB44 },
    .{ 0xFB46, 0xFBB1 },
    .{ 0xFBD3, 0xFD3D },
    .{ 0xFD50, 0xFD8F },
    .{ 0xFD92, 0xFDC7 },
    .{ 0xFDF0, 0xFDFB },
    .{ 0xFE70, 0xFE74 },
    .{ 0xFE76, 0xFEFC },
    .{ 0xFF66, 0xFF6F },
    .{ 0xFF71, 0xFF9D },
    .{ 0xFFA0, 0xFFBE },
    .{ 0xFFC2, 0xFFC7 },
    .{ 0xFFCA, 0xFFCF },
    .{ 0xFFD2, 0xFFD7 },
    .{ 0xFFDA, 0xFFDC },
};

const _Mc_ranges = [_][2]u21{
    .{ 0x0903, 0x0903 },
    .{ 0x093B, 0x093B },
    .{ 0x093E, 0x0940 },
    .{ 0x0949, 0x094C },
    .{ 0x094E, 0x094E },
    .{ 0x0955, 0x0957 },
    .{ 0x0962, 0x0963 },
    .{ 0x0982, 0x0983 },
    .{ 0x09BE, 0x09C0 },
    .{ 0x09C7, 0x09C8 },
    .{ 0x09CB, 0x09CC },
    .{ 0x09D7, 0x09D7 },
    .{ 0x0A03, 0x0A03 },
    .{ 0x0A3E, 0x0A40 },
    .{ 0x0A83, 0x0A83 },
    .{ 0x0ABE, 0x0AC0 },
    .{ 0x0AC9, 0x0AC9 },
    .{ 0x0ACB, 0x0ACC },
    .{ 0x0AD0, 0x0AD0 },
    .{ 0x0B02, 0x0B03 },
    .{ 0x0B3E, 0x0B3E },
    .{ 0x0B40, 0x0B40 },
    .{ 0x0B47, 0x0B48 },
    .{ 0x0B4B, 0x0B4C },
    .{ 0x0B57, 0x0B57 },
    .{ 0x0BBE, 0x0BBF },
    .{ 0x0BC1, 0x0BC2 },
    .{ 0x0BC6, 0x0BC8 },
    .{ 0x0BCA, 0x0BCC },
    .{ 0x0BD7, 0x0BD7 },
    .{ 0x0C01, 0x0C03 },
    .{ 0x0C41, 0x0C44 },
    .{ 0x0C82, 0x0C83 },
    .{ 0x0CBE, 0x0CBE },
    .{ 0x0CC0, 0x0CC4 },
    .{ 0x0CC7, 0x0CC8 },
    .{ 0x0CCA, 0x0CCB },
    .{ 0x0CD5, 0x0CD6 },
    .{ 0x0D02, 0x0D03 },
    .{ 0x0D3E, 0x0D40 },
    .{ 0x0D46, 0x0D48 },
    .{ 0x0D4A, 0x0D4C },
    .{ 0x0D57, 0x0D57 },
    .{ 0x0D82, 0x0D83 },
    .{ 0x0DCF, 0x0DD1 },
    .{ 0x0DD8, 0x0DDF },
    .{ 0x0DF2, 0x0DF3 },
    .{ 0x0F3E, 0x0F3F },
    .{ 0x0F7F, 0x0F7F },
    .{ 0x102B, 0x102C },
    .{ 0x1031, 0x1031 },
    .{ 0x1038, 0x1038 },
    .{ 0x103B, 0x103C },
    .{ 0x1056, 0x1057 },
    .{ 0x1062, 0x1064 },
    .{ 0x1067, 0x106D },
    .{ 0x1083, 0x1084 },
    .{ 0x1087, 0x108C },
    .{ 0x108F, 0x108F },
    .{ 0x109A, 0x109C },
    .{ 0x17B6, 0x17B6 },
    .{ 0x17BE, 0x17C5 },
    .{ 0x17C7, 0x17C8 },
    .{ 0x1923, 0x1926 },
    .{ 0x1929, 0x192B },
    .{ 0x1930, 0x1931 },
    .{ 0x1933, 0x1938 },
    .{ 0x1A19, 0x1A1A },
    .{ 0x1A55, 0x1A55 },
    .{ 0x1A57, 0x1A57 },
    .{ 0x1A61, 0x1A61 },
    .{ 0x1A63, 0x1A64 },
    .{ 0x1A6D, 0x1A72 },
    .{ 0x1B04, 0x1B04 },
    .{ 0x1B35, 0x1B35 },
    .{ 0x1B3B, 0x1B3B },
    .{ 0x1B3D, 0x1B41 },
    .{ 0x1B43, 0x1B44 },
    .{ 0x1B82, 0x1B82 },
    .{ 0x1BA1, 0x1BA1 },
    .{ 0x1BA6, 0x1BA7 },
    .{ 0x1BAA, 0x1BAA },
    .{ 0x1BE7, 0x1BE7 },
    .{ 0x1BEA, 0x1BEC },
    .{ 0x1BEE, 0x1BEE },
    .{ 0x1BF2, 0x1BF3 },
    .{ 0x1C24, 0x1C2B },
    .{ 0x1C34, 0x1C35 },
    .{ 0x1CE1, 0x1CE1 },
    .{ 0x1CF7, 0x1CF7 },
    .{ 0xA823, 0xA824 },
    .{ 0xA827, 0xA827 },
    .{ 0xA880, 0xA881 },
    .{ 0xA8B4, 0xA8C3 },
    .{ 0xA952, 0xA953 },
    .{ 0xA983, 0xA983 },
    .{ 0xA9B4, 0xA9B5 },
    .{ 0xA9BA, 0xA9BB },
    .{ 0xA9BD, 0xA9C0 },
    .{ 0xAA2F, 0xAA30 },
    .{ 0xAA33, 0xAA34 },
    .{ 0xAA4D, 0xAA4D },
    .{ 0xAA7B, 0xAA7B },
    .{ 0xAA7D, 0xAA7D },
    .{ 0xAABE, 0xAABF },
    .{ 0xAAC0, 0xAAC0 },
    .{ 0xAAC2, 0xAAC2 },
    .{ 0xAADB, 0xAADC },
    .{ 0xAAF2, 0xAAF2 },
    .{ 0xAB01, 0xAB06 },
    .{ 0xAB09, 0xAB0E },
    .{ 0xAB11, 0xAB16 },
    .{ 0xAB20, 0xAB26 },
    .{ 0xAB28, 0xAB2E },
    .{ 0xAB30, 0xAB5A },
    .{ 0xAB5C, 0xAB5F },
    .{ 0xAB60, 0xAB65 },
};

const _Zp_ranges = [_][2]u21{
    .{ 0x2029, 0x2029 },
};

const _No_ranges = [_][2]u21{
    .{ 0x00B2, 0x00B3 },
    .{ 0x00B9, 0x00B9 },
    .{ 0x00BC, 0x00BE },
    .{ 0x09F4, 0x09F9 },
    .{ 0x0B72, 0x0B77 },
    .{ 0x0BF0, 0x0BF2 },
    .{ 0x0C78, 0x0C7E },
    .{ 0x0D58, 0x0D5E },
    .{ 0x0D70, 0x0D78 },
    .{ 0x0F2A, 0x0F33 },
    .{ 0x1369, 0x1371 },
    .{ 0x17F0, 0x17F9 },
    .{ 0x19DA, 0x19DA },
    .{ 0x2070, 0x2070 },
    .{ 0x2074, 0x2079 },
    .{ 0x2080, 0x2089 },
    .{ 0x2150, 0x215F },
    .{ 0x2189, 0x2189 },
    .{ 0x2460, 0x249B },
    .{ 0x24EA, 0x24FF },
    .{ 0x2776, 0x2793 },
    .{ 0x2CFD, 0x2CFD },
    .{ 0x3192, 0x3195 },
    .{ 0x3220, 0x3229 },
    .{ 0x3248, 0x324F },
    .{ 0x3251, 0x325F },
    .{ 0x3280, 0x3289 },
    .{ 0x32B1, 0x32BF },
    .{ 0xA830, 0xA835 },
};

const _Sk_ranges = [_][2]u21{
    .{ 0x005E, 0x005E },
    .{ 0x0060, 0x0060 },
    .{ 0x00A8, 0x00A8 },
    .{ 0x00AF, 0x00AF },
    .{ 0x00B4, 0x00B4 },
    .{ 0x00B8, 0x00B8 },
    .{ 0x02C2, 0x02C5 },
    .{ 0x02D2, 0x02DF },
    .{ 0x02E5, 0x02EB },
    .{ 0x02ED, 0x02ED },
    .{ 0x02EF, 0x02FF },
    .{ 0x0375, 0x0375 },
    .{ 0x0384, 0x0385 },
    .{ 0x1FBD, 0x1FBD },
    .{ 0x1FBF, 0x1FC1 },
    .{ 0x1FCD, 0x1FCF },
    .{ 0x1FDD, 0x1FDF },
    .{ 0x1FED, 0x1FEF },
    .{ 0x1FFD, 0x1FFE },
    .{ 0x309B, 0x309C },
    .{ 0xA700, 0xA716 },
    .{ 0xA720, 0xA721 },
    .{ 0xA789, 0xA78A },
    .{ 0xAB5B, 0xAB5B },
    .{ 0xFBB2, 0xFBC1 },
    .{ 0xFF3E, 0xFF3E },
    .{ 0xFF40, 0xFF40 },
    .{ 0xFFE3, 0xFFE3 },
};

const _Me_ranges = [_][2]u21{
    .{ 0x0488, 0x0489 },
    .{ 0x1ABE, 0x1ABE },
    .{ 0x20DD, 0x20E0 },
    .{ 0x20E2, 0x20E4 },
    .{ 0xA670, 0xA672 },
};

const _Co_ranges = [_][2]u21{
    .{ 0xE000, 0xF8FF },
    .{ 0xF0000, 0xFFFFD },
    .{ 0x100000, 0x10FFFD },
};

const _Po_ranges = [_][2]u21{
    .{ 0x0021, 0x0023 },
    .{ 0x0025, 0x002A },
    .{ 0x002C, 0x002C },
    .{ 0x002E, 0x002F },
    .{ 0x003A, 0x003B },
    .{ 0x003F, 0x0040 },
    .{ 0x005C, 0x005C },
    .{ 0x00A1, 0x00A1 },
    .{ 0x00A7, 0x00A7 },
    .{ 0x00B6, 0x00B7 },
    .{ 0x00BF, 0x00BF },
    .{ 0x037E, 0x037E },
    .{ 0x0387, 0x0387 },
    .{ 0x055A, 0x055F },
    .{ 0x0589, 0x0589 },
    .{ 0x05C0, 0x05C0 },
    .{ 0x05C3, 0x05C3 },
    .{ 0x05C6, 0x05C6 },
    .{ 0x05F3, 0x05F4 },
    .{ 0x0609, 0x060A },
    .{ 0x060C, 0x060D },
    .{ 0x061B, 0x061B },
    .{ 0x061E, 0x061F },
    .{ 0x066A, 0x066D },
    .{ 0x06D4, 0x06D4 },
    .{ 0x0700, 0x070D },
    .{ 0x07F7, 0x07F9 },
    .{ 0x0830, 0x083E },
    .{ 0x085E, 0x085E },
    .{ 0x0964, 0x0965 },
    .{ 0x0970, 0x0970 },
    .{ 0x09FD, 0x09FD },
    .{ 0x0A76, 0x0A76 },
    .{ 0x0AF0, 0x0AF0 },
    .{ 0x0C77, 0x0C77 },
    .{ 0x0C84, 0x0C84 },
    .{ 0x0DF4, 0x0DF4 },
    .{ 0x0E4F, 0x0E4F },
    .{ 0x0E5A, 0x0E5B },
    .{ 0x0F04, 0x0F12 },
    .{ 0x0F14, 0x0F14 },
    .{ 0x0F3A, 0x0F3D },
    .{ 0x0F85, 0x0F85 },
    .{ 0x0FD0, 0x0FD4 },
    .{ 0x0FD9, 0x0FDA },
    .{ 0x104A, 0x104F },
    .{ 0x10FB, 0x10FB },
    .{ 0x1360, 0x1368 },
    .{ 0x166E, 0x166E },
    .{ 0x169B, 0x169C },
    .{ 0x16EB, 0x16ED },
    .{ 0x1735, 0x1736 },
    .{ 0x17D4, 0x17D6 },
    .{ 0x17D8, 0x17DA },
    .{ 0x1800, 0x1805 },
    .{ 0x1807, 0x180A },
    .{ 0x1944, 0x1945 },
    .{ 0x1A1E, 0x1A1F },
    .{ 0x1AA0, 0x1AA6 },
    .{ 0x1AA8, 0x1AAD },
    .{ 0x1B5A, 0x1B60 },
    .{ 0x1BFC, 0x1BFF },
    .{ 0x1C3B, 0x1C3F },
    .{ 0x1C7E, 0x1C7F },
    .{ 0x1CC0, 0x1CC7 },
    .{ 0x1CD3, 0x1CD3 },
    .{ 0x2010, 0x2027 },
    .{ 0x2030, 0x2043 },
    .{ 0x2045, 0x2051 },
    .{ 0x2053, 0x205E },
    .{ 0x207D, 0x207E },
    .{ 0x208D, 0x208E },
    .{ 0x2308, 0x230B },
    .{ 0x2329, 0x232A },
    .{ 0x2768, 0x2775 },
    .{ 0x27C5, 0x27C6 },
    .{ 0x27E6, 0x27EF },
    .{ 0x2983, 0x2998 },
    .{ 0x29D8, 0x29DB },
    .{ 0x29FC, 0x29FD },
    .{ 0x2CF9, 0x2CFC },
    .{ 0x2CFE, 0x2CFF },
    .{ 0x2D70, 0x2D70 },
    .{ 0x2E00, 0x2E2E },
    .{ 0x2E30, 0x2E4F },
    .{ 0x2E52, 0x2E5D },
    .{ 0x3001, 0x3003 },
    .{ 0x303D, 0x303D },
    .{ 0x30FB, 0x30FB },
    .{ 0xA4FE, 0xA4FF },
    .{ 0xA60D, 0xA60F },
    .{ 0xA673, 0xA673 },
    .{ 0xA67E, 0xA67E },
    .{ 0xA6F2, 0xA6F7 },
    .{ 0xA874, 0xA877 },
    .{ 0xA8CE, 0xA8CF },
    .{ 0xA8F8, 0xA8FA },
    .{ 0xA8FC, 0xA8FC },
    .{ 0xA92E, 0xA92F },
    .{ 0xA95F, 0xA95F },
    .{ 0xA9C1, 0xA9CD },
    .{ 0xA9DE, 0xA9DF },
    .{ 0xAA5C, 0xAA5F },
    .{ 0xAADE, 0xAADF },
    .{ 0xAAF0, 0xAAF1 },
    .{ 0xABEB, 0xABEB },
    .{ 0xFE10, 0xFE19 },
    .{ 0xFE30, 0xFE52 },
    .{ 0xFE54, 0xFE61 },
    .{ 0xFE63, 0xFE63 },
    .{ 0xFE68, 0xFE68 },
    .{ 0xFE6A, 0xFE6B },
    .{ 0xFF01, 0xFF03 },
    .{ 0xFF05, 0xFF0A },
    .{ 0xFF0C, 0xFF0C },
    .{ 0xFF0E, 0xFF0F },
    .{ 0xFF1A, 0xFF1B },
    .{ 0xFF1F, 0xFF20 },
    .{ 0xFF3C, 0xFF3C },
    .{ 0xFF61, 0xFF61 },
    .{ 0xFF64, 0xFF65 },
};

const _Nd_ranges = [_][2]u21{
    .{ 0x0030, 0x0039 },
    .{ 0x0660, 0x0669 },
    .{ 0x06F0, 0x06F9 },
    .{ 0x07C0, 0x07C9 },
    .{ 0x0966, 0x096F },
    .{ 0x09E6, 0x09EF },
    .{ 0x0A66, 0x0A6F },
    .{ 0x0AE6, 0x0AEF },
    .{ 0x0B66, 0x0B6F },
    .{ 0x0BE6, 0x0BEF },
    .{ 0x0C66, 0x0C6F },
    .{ 0x0CE6, 0x0CEF },
    .{ 0x0D66, 0x0D6F },
    .{ 0x0E50, 0x0E59 },
    .{ 0x0ED0, 0x0ED9 },
    .{ 0x0F20, 0x0F29 },
    .{ 0x1040, 0x1049 },
    .{ 0x1090, 0x1099 },
    .{ 0x17E0, 0x17E9 },
    .{ 0x1810, 0x1819 },
    .{ 0x1946, 0x194F },
    .{ 0x19D0, 0x19D9 },
    .{ 0x1A80, 0x1A89 },
    .{ 0x1A90, 0x1A99 },
    .{ 0x1B50, 0x1B59 },
    .{ 0x1BB0, 0x1BB9 },
    .{ 0x1C40, 0x1C49 },
    .{ 0x1C50, 0x1C59 },
    .{ 0xA620, 0xA629 },
    .{ 0xA8D0, 0xA8D9 },
    .{ 0xA900, 0xA909 },
    .{ 0xA9D0, 0xA9D9 },
    .{ 0xA9F0, 0xA9F9 },
    .{ 0xAA50, 0xAA59 },
    .{ 0xABF0, 0xABF9 },
    .{ 0xFF10, 0xFF19 },
};

const _Cc_ranges = [_][2]u21{
    .{ 0x0000, 0x001F },
    .{ 0x007F, 0x009F },
};

const _Zs_ranges = [_][2]u21{
    .{ 0x0020, 0x0020 },
    .{ 0x00A0, 0x00A0 },
    .{ 0x1680, 0x1680 },
    .{ 0x2000, 0x200A },
    .{ 0x202F, 0x202F },
    .{ 0x205F, 0x205F },
    .{ 0x3000, 0x3000 },
};

const _Sm_ranges = [_][2]u21{
    .{ 0x002B, 0x002B },
    .{ 0x003C, 0x003E },
    .{ 0x007C, 0x007C },
    .{ 0x007E, 0x007E },
    .{ 0x00AC, 0x00AC },
    .{ 0x00B1, 0x00B1 },
    .{ 0x00D7, 0x00D7 },
    .{ 0x00F7, 0x00F7 },
    .{ 0x03F6, 0x03F6 },
    .{ 0x0606, 0x0608 },
    .{ 0x2044, 0x2044 },
    .{ 0x2052, 0x2052 },
    .{ 0x207A, 0x207C },
    .{ 0x208A, 0x208C },
    .{ 0x2118, 0x2118 },
    .{ 0x2140, 0x2144 },
    .{ 0x214B, 0x214B },
    .{ 0x2190, 0x2194 },
    .{ 0x219A, 0x219B },
    .{ 0x21A0, 0x21A0 },
    .{ 0x21A3, 0x21A3 },
    .{ 0x21A6, 0x21A6 },
    .{ 0x21AE, 0x21AE },
    .{ 0x21CE, 0x21CF },
    .{ 0x21D2, 0x21D2 },
    .{ 0x21D4, 0x21D4 },
    .{ 0x21F4, 0x22FF },
    .{ 0x2320, 0x2321 },
    .{ 0x237C, 0x237C },
    .{ 0x239B, 0x23B3 },
    .{ 0x23DC, 0x23E1 },
    .{ 0x25B7, 0x25B7 },
    .{ 0x25C1, 0x25C1 },
    .{ 0x25F8, 0x25FF },
    .{ 0x266F, 0x266F },
    .{ 0x27C0, 0x27C4 },
    .{ 0x27C7, 0x27E5 },
    .{ 0x27F0, 0x27FF },
    .{ 0x2900, 0x2982 },
    .{ 0x2999, 0x29D7 },
    .{ 0x29DC, 0x29FB },
    .{ 0x29FE, 0x2AFF },
    .{ 0x2B30, 0x2B44 },
    .{ 0x2B47, 0x2B4C },
    .{ 0xFB29, 0xFB29 },
    .{ 0xFDFC, 0xFDFC },
    .{ 0xFE62, 0xFE62 },
    .{ 0xFE64, 0xFE66 },
    .{ 0xFF0B, 0xFF0B },
    .{ 0xFF1C, 0xFF1E },
    .{ 0xFF5C, 0xFF5C },
    .{ 0xFF5E, 0xFF5E },
    .{ 0xFFE2, 0xFFE2 },
    .{ 0xFFE9, 0xFFEC },
};

const _Pc_ranges = [_][2]u21{
    .{ 0x005F, 0x005F },
    .{ 0x203F, 0x2040 },
    .{ 0x2054, 0x2054 },
    .{ 0xFE33, 0xFE34 },
    .{ 0xFE4D, 0xFE4F },
    .{ 0xFF3F, 0xFF3F },
};

const _Lt_ranges = [_][2]u21{
    .{ 0x01C5, 0x01C5 },
    .{ 0x01C8, 0x01C8 },
    .{ 0x01CB, 0x01CB },
    .{ 0x01F2, 0x01F2 },
    .{ 0x1F88, 0x1F8F },
    .{ 0x1F98, 0x1F9F },
    .{ 0x1FA8, 0x1FAF },
    .{ 0x1FBC, 0x1FBC },
    .{ 0x1FCC, 0x1FCC },
    .{ 0x1FFC, 0x1FFC },
};

const _Pd_ranges = [_][2]u21{
    .{ 0x002D, 0x002D },
    .{ 0x058A, 0x058A },
    .{ 0x05BE, 0x05BE },
    .{ 0x1400, 0x1400 },
    .{ 0x1806, 0x1806 },
    .{ 0x2010, 0x2015 },
    .{ 0x2E17, 0x2E17 },
    .{ 0x2E1A, 0x2E1A },
    .{ 0x2E3A, 0x2E3B },
    .{ 0x2E40, 0x2E40 },
    .{ 0x301C, 0x301C },
    .{ 0x3030, 0x3030 },
    .{ 0x30A0, 0x30A0 },
    .{ 0xFE31, 0xFE32 },
    .{ 0xFE58, 0xFE58 },
    .{ 0xFE63, 0xFE63 },
    .{ 0xFF0D, 0xFF0D },
};

const _Lu_ranges = [_][2]u21{
    .{ 0x0041, 0x005A },
    .{ 0x00C0, 0x00D6 },
    .{ 0x00D8, 0x00DE },
    .{ 0x0386, 0x0386 },
    .{ 0x0388, 0x038A },
    .{ 0x0391, 0x03A1 },
    .{ 0x03A3, 0x03AB },
    .{ 0x0401, 0x040C },
    .{ 0x040E, 0x042F },
    .{ 0x1F08, 0x1F0F },
    .{ 0x1F18, 0x1F1D },
    .{ 0x1F28, 0x1F2F },
    .{ 0x1F38, 0x1F3F },
    .{ 0x1F48, 0x1F4D },
    .{ 0x1F59, 0x1F59 },
    .{ 0x1F5B, 0x1F5B },
    .{ 0x1F5D, 0x1F5D },
    .{ 0x1F5F, 0x1F5F },
    .{ 0x1F68, 0x1F6F },
    .{ 0x1FB8, 0x1FBB },
    .{ 0x1FC8, 0x1FCB },
    .{ 0x1FD8, 0x1FDB },
    .{ 0x1FE8, 0x1FEC },
    .{ 0x1FF8, 0x1FFB },
};

const _So_ranges = [_][2]u21{
    .{ 0x00A6, 0x00A7 },
    .{ 0x00A9, 0x00A9 },
    .{ 0x00AE, 0x00AE },
    .{ 0x00B0, 0x00B0 },
    .{ 0x0482, 0x0482 },
    .{ 0x060E, 0x060F },
    .{ 0x06DE, 0x06DE },
    .{ 0x06E9, 0x06E9 },
    .{ 0x06FD, 0x06FE },
    .{ 0x07F6, 0x07F6 },
    .{ 0x09FA, 0x09FA },
    .{ 0x0B70, 0x0B70 },
    .{ 0x0BF3, 0x0BF8 },
    .{ 0x0BFA, 0x0BFA },
    .{ 0x0C7F, 0x0C7F },
    .{ 0x0D4F, 0x0D4F },
    .{ 0x0D79, 0x0D79 },
    .{ 0x0F01, 0x0F03 },
    .{ 0x0F13, 0x0F17 },
    .{ 0x0F1A, 0x0F1F },
    .{ 0x0F34, 0x0F34 },
    .{ 0x0F36, 0x0F36 },
    .{ 0x0F38, 0x0F38 },
    .{ 0x0FBE, 0x0FC5 },
    .{ 0x0FC7, 0x0FCC },
    .{ 0x0FCE, 0x0FD4 },
    .{ 0x0FD9, 0x0FDA },
    .{ 0x109E, 0x109F },
    .{ 0x1360, 0x1360 },
    .{ 0x1390, 0x1399 },
    .{ 0x1940, 0x1940 },
    .{ 0x19DE, 0x19FF },
    .{ 0x1B61, 0x1B6A },
    .{ 0x1B74, 0x1B7C },
    .{ 0x2100, 0x2101 },
    .{ 0x2103, 0x2106 },
    .{ 0x2108, 0x2109 },
    .{ 0x2114, 0x2114 },
    .{ 0x2116, 0x2117 },
    .{ 0x211E, 0x2123 },
    .{ 0x2125, 0x2125 },
    .{ 0x2127, 0x2127 },
    .{ 0x2129, 0x2129 },
    .{ 0x212E, 0x212E },
    .{ 0x213A, 0x213B },
    .{ 0x214A, 0x214A },
    .{ 0x214C, 0x214D },
    .{ 0x214F, 0x214F },
    .{ 0x2195, 0x2199 },
    .{ 0x219C, 0x219F },
    .{ 0x21A1, 0x21A2 },
    .{ 0x21A4, 0x21A5 },
    .{ 0x21A7, 0x21AD },
    .{ 0x21AF, 0x21CD },
    .{ 0x21D0, 0x21D1 },
    .{ 0x21D3, 0x21D3 },
    .{ 0x21D5, 0x21F3 },
    .{ 0x2300, 0x231F },
    .{ 0x2322, 0x2328 },
    .{ 0x232B, 0x237B },
    .{ 0x237D, 0x239A },
    .{ 0x23B4, 0x23DB },
    .{ 0x23E2, 0x2426 },
    .{ 0x2440, 0x244A },
    .{ 0x249C, 0x24E9 },
    .{ 0x2500, 0x25B6 },
    .{ 0x25B8, 0x25C0 },
    .{ 0x25C2, 0x25F7 },
    .{ 0x2600, 0x266E },
    .{ 0x2670, 0x2775 },
    .{ 0x2794, 0x27BF },
    .{ 0x2800, 0x28FF },
    .{ 0x2B00, 0x2B2F },
    .{ 0x2B45, 0x2B46 },
    .{ 0x2B50, 0x2B59 },
    .{ 0x2CE5, 0x2CEA },
    .{ 0x2E80, 0x2E99 },
    .{ 0x2E9B, 0x2EF3 },
    .{ 0x2F00, 0x2FD5 },
    .{ 0x2FF0, 0x2FFB },
    .{ 0x3004, 0x3004 },
    .{ 0x3012, 0x3013 },
    .{ 0x3020, 0x3020 },
    .{ 0x3036, 0x3037 },
    .{ 0x303E, 0x303F },
    .{ 0x3190, 0x3191 },
    .{ 0x3196, 0x319F },
    .{ 0x31C0, 0x31E3 },
    .{ 0x3200, 0x321E },
    .{ 0x322A, 0x3247 },
    .{ 0x3250, 0x3250 },
    .{ 0x3260, 0x327F },
    .{ 0x328A, 0x32B0 },
    .{ 0x32C0, 0x32FE },
    .{ 0x3300, 0x33FF },
    .{ 0x4DC0, 0x4DFF },
    .{ 0xA490, 0xA4C6 },
    .{ 0xA828, 0xA82B },
    .{ 0xA836, 0xA837 },
    .{ 0xAA77, 0xAA79 },
    .{ 0xFDFD, 0xFDFD },
    .{ 0xFFFC, 0xFFFD },
};

const _Pe_ranges = [_][2]u21{
    .{ 0x0029, 0x0029 },
    .{ 0x005D, 0x005D },
    .{ 0x007D, 0x007D },
    .{ 0x0F3B, 0x0F3B },
    .{ 0x0F3D, 0x0F3D },
    .{ 0x169C, 0x169C },
    .{ 0x2046, 0x2046 },
    .{ 0x207E, 0x207E },
    .{ 0x208E, 0x208E },
    .{ 0x2309, 0x2309 },
    .{ 0x230B, 0x230B },
    .{ 0x232A, 0x232A },
    .{ 0x2769, 0x2769 },
    .{ 0x276B, 0x276B },
    .{ 0x276D, 0x276D },
    .{ 0x276F, 0x276F },
    .{ 0x2771, 0x2771 },
    .{ 0x2773, 0x2773 },
    .{ 0x2775, 0x2775 },
    .{ 0x27C6, 0x27C6 },
    .{ 0x27E7, 0x27E7 },
    .{ 0x27E9, 0x27E9 },
    .{ 0x27EB, 0x27EB },
    .{ 0x27ED, 0x27ED },
    .{ 0x27EF, 0x27EF },
    .{ 0x2984, 0x2984 },
    .{ 0x2986, 0x2986 },
    .{ 0x2988, 0x2988 },
    .{ 0x298A, 0x298A },
    .{ 0x298C, 0x298C },
    .{ 0x298E, 0x298E },
    .{ 0x2990, 0x2990 },
    .{ 0x2992, 0x2992 },
    .{ 0x2994, 0x2994 },
    .{ 0x2996, 0x2996 },
    .{ 0x2998, 0x2998 },
    .{ 0x29D9, 0x29D9 },
    .{ 0x29DB, 0x29DB },
    .{ 0x29FD, 0x29FD },
    .{ 0x2E23, 0x2E23 },
    .{ 0x2E25, 0x2E25 },
    .{ 0x2E27, 0x2E27 },
    .{ 0x2E29, 0x2E29 },
    .{ 0x3009, 0x3009 },
    .{ 0x300B, 0x300B },
    .{ 0x300D, 0x300D },
    .{ 0x300F, 0x300F },
    .{ 0x3011, 0x3011 },
    .{ 0x3015, 0x3015 },
    .{ 0x3017, 0x3017 },
    .{ 0x3019, 0x3019 },
    .{ 0x301B, 0x301B },
    .{ 0x301E, 0x301F },
    .{ 0xFD3E, 0xFD3E },
    .{ 0xFE18, 0xFE18 },
    .{ 0xFE36, 0xFE36 },
    .{ 0xFE38, 0xFE38 },
    .{ 0xFE3A, 0xFE3A },
    .{ 0xFE3C, 0xFE3C },
    .{ 0xFE3E, 0xFE3E },
    .{ 0xFE40, 0xFE40 },
    .{ 0xFE42, 0xFE42 },
    .{ 0xFE44, 0xFE44 },
    .{ 0xFE48, 0xFE48 },
    .{ 0xFE5A, 0xFE5A },
    .{ 0xFE5C, 0xFE5C },
    .{ 0xFE5E, 0xFE5E },
    .{ 0xFF09, 0xFF09 },
    .{ 0xFF3D, 0xFF3D },
    .{ 0xFF5D, 0xFF5D },
    .{ 0xFF60, 0xFF60 },
    .{ 0xFF63, 0xFF63 },
};

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
    if (property.len == 1) {
        switch (property[0]) {
            'L' => return isUnicodeProperty(cp, "Lu") or
                isUnicodeProperty(cp, "Ll") or
                isUnicodeProperty(cp, "Lt") or
                isUnicodeProperty(cp, "Lm") or
                isUnicodeProperty(cp, "Lo"),
            'N' => return isUnicodeProperty(cp, "Nd") or
                isUnicodeProperty(cp, "Nl") or
                isUnicodeProperty(cp, "No"),
            'P' => return isUnicodeProperty(cp, "Pc") or
                isUnicodeProperty(cp, "Pd") or
                isUnicodeProperty(cp, "Ps") or
                isUnicodeProperty(cp, "Pe") or
                isUnicodeProperty(cp, "Pi") or
                isUnicodeProperty(cp, "Pf") or
                isUnicodeProperty(cp, "Po"),
            'S' => return isUnicodeProperty(cp, "Sc") or
                isUnicodeProperty(cp, "Sk") or
                isUnicodeProperty(cp, "Sm") or
                isUnicodeProperty(cp, "So"),
            'Z' => return isUnicodeProperty(cp, "Zs") or
                isUnicodeProperty(cp, "Zl") or
                isUnicodeProperty(cp, "Zp"),
            'C' => return isUnicodeProperty(cp, "Cc") or
                isUnicodeProperty(cp, "Cf") or
                isUnicodeProperty(cp, "Co") or
                isUnicodeProperty(cp, "Cs"),
            'M' => return isUnicodeProperty(cp, "Mn") or
                isUnicodeProperty(cp, "Mc") or
                isUnicodeProperty(cp, "Me"),
            else => return false,
        }
    }
    if (property.len == 2) {
        switch (property[0]) {
            'L' => switch (property[1]) {
                'u' => return inUnicodeRanges(cp, &_Lu_ranges) or
                    (cp >= 0x0100 and cp <= 0x0136 and cp % 2 == 0) or
                    (cp >= 0x0139 and cp <= 0x0147 and cp % 2 == 1) or
                    (cp >= 0x014A and cp <= 0x0176 and cp % 2 == 0),
                'l' => return inUnicodeRanges(cp, &_Ll_ranges) or
                    (cp >= 0x0101 and cp <= 0x0137 and cp % 2 == 1) or
                    (cp >= 0x013A and cp <= 0x0148 and cp % 2 == 0) or
                    (cp >= 0x014B and cp <= 0x0177 and cp % 2 == 1) or
                    (cp >= 0x017A and cp <= 0x017E and cp % 2 == 0),
                't' => return inUnicodeRanges(cp, &_Lt_ranges),
                'm' => return inUnicodeRanges(cp, &_Lm_ranges),
                'o' => return inUnicodeRanges(cp, &_Lo_ranges),
                else => return false,
            },
            'N' => switch (property[1]) {
                'd' => return inUnicodeRanges(cp, &_Nd_ranges),
                'l' => return inUnicodeRanges(cp, &_Nl_ranges),
                'o' => return inUnicodeRanges(cp, &_No_ranges),
                else => return false,
            },
            'P' => switch (property[1]) {
                'c' => return inUnicodeRanges(cp, &_Pc_ranges),
                'd' => return inUnicodeRanges(cp, &_Pd_ranges),
                's' => return inUnicodeRanges(cp, &_Ps_ranges),
                'e' => return inUnicodeRanges(cp, &_Pe_ranges),
                'i' => return inUnicodeRanges(cp, &_Pi_ranges),
                'f' => return inUnicodeRanges(cp, &_Pf_ranges),
                'o' => return inUnicodeRanges(cp, &_Po_ranges),
                else => return false,
            },
            'S' => switch (property[1]) {
                'c' => return inUnicodeRanges(cp, &_Sc_ranges),
                'k' => return inUnicodeRanges(cp, &_Sk_ranges),
                'm' => return inUnicodeRanges(cp, &_Sm_ranges),
                'o' => return inUnicodeRanges(cp, &_So_ranges),
                else => return false,
            },
            'Z' => switch (property[1]) {
                's' => return inUnicodeRanges(cp, &_Zs_ranges),
                'l' => return inUnicodeRanges(cp, &_Zl_ranges),
                'p' => return inUnicodeRanges(cp, &_Zp_ranges),
                else => return false,
            },
            'C' => switch (property[1]) {
                'c' => return inUnicodeRanges(cp, &_Cc_ranges),
                'f' => return inUnicodeRanges(cp, &_Cf_ranges),
                'o' => return inUnicodeRanges(cp, &_Co_ranges),
                's' => return inUnicodeRanges(cp, &_Cs_ranges),
                else => return false,
            },
            'M' => switch (property[1]) {
                'n' => return inUnicodeRanges(cp, &_Mn_ranges),
                'c' => return inUnicodeRanges(cp, &_Mc_ranges),
                'e' => return inUnicodeRanges(cp, &_Me_ranges),
                else => return false,
            },
            else => return false,
        }
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
        return matchPropertyResult(isUnicodeProperty(ch, property), negated, 1);
    }

    const cp = std.unicode.utf8Decode(input[pos .. pos + byte_len]) catch {
        const ch = input[pos];
        return matchPropertyResult(isUnicodeProperty(ch, property), negated, 1);
    };

    return matchPropertyResult(isUnicodeProperty(cp, property), negated, byte_len);
}

/// Return byte_len if (matches XOR negated), else null.
fn matchPropertyResult(matches: bool, negated: bool, byte_len: usize) ?usize {
    if (matches != negated) return byte_len;
    return null;
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
    const cp = std.unicode.utf8Decode(input[start .. start + byte_len]) catch return false;
    return isUnicodeProperty(cp, "L") or isUnicodeProperty(cp, "Nd") or isUnicodeProperty(cp, "M");
}

/// Check if a character at position `pos` matches any Unicode property in the given CharClass.
/// Returns the byte length of the matched UTF-8 sequence, or null if no match.
fn matchUnicodePropertyInClass(input: []const u8, pos: usize, cc: *const @import("parser.zig").CharClass) ?usize {
    if (pos >= input.len or cc.unicode_properties.items.len == 0) return null;

    const byte_len = std.unicode.utf8ByteSequenceLength(input[pos]) catch 1;
    const actual_len = if (pos + byte_len > input.len) 1 else byte_len;

    const cp = if (actual_len == 1)
        @as(u21, input[pos])
    else
        std.unicode.utf8Decode(input[pos .. pos + actual_len]) catch @as(u21, input[pos]);

    for (cc.unicode_properties.items) |entry| {
        if (isUnicodeProperty(cp, entry.name) != entry.negated) {
            return matchPropertyResult(true, cc.negated, actual_len);
        }
    }
    return matchPropertyResult(false, cc.negated, actual_len);
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
/// Check for CRLF sequence at position.
fn isCrlf(input: []const u8, pos: usize) bool {
    return pos < input.len and input[pos] == '\r' and pos + 1 < input.len and input[pos + 1] == '\n';
}

fn matchNewline(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;

    // CRLF sequence
    if (isCrlf(input, pos)) {
        return 2;
    }

    return isLineEndingChar(input, pos);
}

fn matchGraphemeCluster(input: []const u8, pos: usize) ?usize {
    if (pos >= input.len) return null;

    // CR LF sequence is a single grapheme cluster
    if (isCrlf(input, pos)) {
        return 2;
    }

    // Get first codepoint byte length
    const first_len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return 1;
    if (pos + first_len > input.len) return 1;

    _ = std.unicode.utf8Decode(input[pos .. pos + first_len]) catch return 1;
    var total_len: usize = first_len;

    // Consume subsequent combining marks (General Category M)
    while (pos + total_len < input.len) {
        const next_len = std.unicode.utf8ByteSequenceLength(input[pos + total_len]) catch break;
        if (pos + total_len + next_len > input.len) break;
        const next_cp = std.unicode.utf8Decode(input[pos + total_len .. pos + total_len + next_len]) catch break;
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
    last_pos: std.ArrayList(usize) = .empty,
    last_pos_gen: std.ArrayList(u32) = .empty,
    match_generation: u32 = 0,
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
            .last_pos_gen = .empty,
            .match_generation = 0,
            .captures_buf = .empty,
        };
        // Pre-allocate fixed-size buffers based on bytecode size
        try vm.captures_buf.resize(allocator, (bytecode.num_groups + 1) * 2);
        try vm.last_pos.resize(allocator, bytecode.instructions.items.len);
        try vm.last_pos_gen.resize(allocator, bytecode.instructions.items.len);
        try vm.atomic_stack.ensureTotalCapacity(allocator, 64);
        return vm;
    }

    pub fn deinit(self: *Vm) void {
        self.atomic_stack.deinit(self.allocator);
        self.last_pos.deinit(self.allocator);
        self.last_pos_gen.deinit(self.allocator);
        self.captures_buf.deinit(self.allocator);
        self.bytecode.deinit();
    }

    /// Shared VM execution engine.
    /// When `return_captures` is false, the returned MatchResult borrows the internal
    /// captures buffer. The caller must not use the captures after the next exec call.
    fn execInternal(comptime is_sub: bool, comptime return_captures: bool, self: *Vm, input: []const u8, start_pos: usize, start_pc: usize, end_pc: usize) !MatchResult {
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

        var stack_local: std.ArrayList(Frame) = .empty;
        defer stack_local.deinit(self.allocator);
        try stack_local.ensureTotalCapacity(self.allocator, 64);
        var stack: *std.ArrayList(Frame) = &stack_local;

        var subroutine_stack_local: std.ArrayList(usize) = .empty;
        defer subroutine_stack_local.deinit(self.allocator);
        try subroutine_stack_local.ensureTotalCapacity(self.allocator, 32);
        var subroutine_stack: *std.ArrayList(usize) = &subroutine_stack_local;

        const saved_options = self.options;
        defer if (is_sub) {
            self.options = saved_options;
        };

        var pc: usize = start_pc;
        var pos: usize = start_pos;
        var matched = false;
        var match_end: usize = start_pos;
        var step_counter: usize = 0;

        if (!is_sub) {
            if (self.last_pos.items.len < self.bytecode.instructions.items.len) {
                try self.last_pos.resize(self.allocator, self.bytecode.instructions.items.len);
                try self.last_pos_gen.resize(self.allocator, self.bytecode.instructions.items.len);
            }
            self.match_generation +%= 1;
        }

        const final_pc = if (is_sub) end_pc else self.bytecode.instructions.items.len;

        while (true) {
            if (self.options.max_steps) |max| {
                if (step_counter >= max) break;
                step_counter += 1;
            }

            if (pc >= final_pc) {
                if (is_sub) {
                    matched = true;
                    match_end = pos;
                    break;
                } else {
                    if (stack.items.len == 0) break;
                    const frame = stack.pop().?;
                    backtrack(frame, &captures, &pc, &pos, subroutine_stack, &self.options);
                    continue;
                }
            }

            const inst = self.bytecode.instructions.items[pc];

            switch (inst) {
                .Char => |pat| {
                    var matches = false;
                    if (pos < input.len) {
                        const ch = input[pos];
                        if (self.options.case_sensitive or ch >= 128 or pat >= 128) {
                            matches = ch == pat;
                        } else {
                            matches = std.ascii.toLower(ch) == std.ascii.toLower(pat);
                        }
                    }
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matches, 1)) break;
                },
                .String => |pat| {
                    var matches = false;
                    var advance_len: usize = 0;
                    if (pos + pat.len <= input.len) {
                        const slice = input[pos .. pos + pat.len];
                        if (self.options.case_sensitive) {
                            matches = std.mem.eql(u8, slice, pat);
                            advance_len = pat.len;
                        } else {
                            // Case-insensitive: check ASCII chars with toLower
                            matches = true;
                            for (pat, slice) |p, s| {
                                if (p >= 128 or s >= 128) {
                                    if (p != s) {
                                        matches = false;
                                        break;
                                    }
                                } else if (std.ascii.toLower(p) != std.ascii.toLower(s)) {
                                    matches = false;
                                    break;
                                }
                            }
                            advance_len = pat.len;
                        }
                    }
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matches, advance_len)) break;
                },
                .CharUtf8 => |cp| {
                    if (!tryMatchOpt(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matchCharUtf8(input, pos, cp, self.options.case_sensitive))) break;
                },
                .Any => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, pos < input.len and (self.options.dot_matches_newline or input[pos] != '\n'), 1)) break;
                },
                .CharClass => |cc| {
                    if (!tryMatchOpt(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matchCharClass(cc, input, pos, self.options.case_sensitive))) break;
                },
                .UnicodeProperty => |p| {
                    if (!tryMatchOpt(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matchUnicodeProperty(input, pos, p.property, p.negated))) break;
                },
                .GraphemeCluster => {
                    if (!tryMatchOpt(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matchGraphemeCluster(input, pos))) break;
                },
                .Newline => {
                    if (!tryMatchOpt(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matchNewline(input, pos))) break;
                },
                .ResetMatchStart => {
                    captures.items[0] = pos;
                    pc += 1;
                },
                .NotNewline => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, pos < input.len and input[pos] != '\n', 1)) break;
                },
                .NotVerticalWhitespace => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, pos < input.len and isLineEndingChar(input, pos) == null, 1)) break;
                },
                .Split => |target| {
                    if (!is_sub) {
                        if (self.last_pos_gen.items[pc] == self.match_generation and self.last_pos.items[pc] == pos) {
                            pc = target;
                            continue;
                        }
                        self.last_pos_gen.items[pc] = self.match_generation;
                        self.last_pos.items[pc] = pos;
                    }
                    try stack.append(self.allocator, .{
                        .pc = target,
                        .pos = pos,
                        .capture_slot = null,
                        .capture_old_value = null,
                        .options = self.options,
                        .subroutine_stack_len = subroutine_stack.items.len,
                    });
                    pc += 1;
                },
                .Jmp => |target| {
                    pc = target;
                },
                .Save => |slot| {
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
                .SetOption => |opts| {
                    self.options = opts;
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
                .Conditional => |c| {
                    const group_idx = c.group;
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
                        pc = c.target;
                    }
                },
                .Backref => |group| {
                    if (!tryMatchOpt(stack, &captures, &pc, &pos, subroutine_stack, &self.options, matchBackref(input, pos, captures.items, group, self.options.case_sensitive))) break;
                },
                .WordBoundary => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, checkWordBoundary(input, pos), 0)) break;
                },
                .NotWordBoundary => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, !checkWordBoundary(input, pos), 0)) break;
                },
                .AssertStart => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, checkAssertStart(pos, input, self.options.multiline), 0)) break;
                },
                .AssertEnd => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, checkAssertEnd(pos, input, self.options.multiline), 0)) break;
                },
                .AssertStringStart => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, pos == 0, 0)) break;
                },
                .AssertStringEnd => {
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, pos == input.len, 0)) break;
                },
                .AssertStringEndAllowNewline => {
                    const at_end = pos == input.len;
                    const before_lf = pos + 1 == input.len and input[pos] == '\n';
                    const before_crlf = pos + 2 == input.len and input[pos] == '\r' and input[pos + 1] == '\n';
                    if (!tryMatch(stack, &captures, &pc, &pos, subroutine_stack, &self.options, at_end or before_lf or before_crlf, 0)) break;
                },
                .AssertMatchStart => {
                    if (is_sub) {
                        pc += 1;
                    } else {
                        if (pos == self.last_match_end) {
                            pc += 1;
                        } else {
                            if (stack.items.len == 0) break;
                            backtrack(stack.pop().?, &captures, &pc, &pos, subroutine_stack, &self.options);
                        }
                    }
                },
                .AssertForward => {
                    const epc = self.bytecode.assert_ends.items[pc];
                    var sub_result = try execInternal(true, false, self, input, pos, pc + 1, epc);
                    defer sub_result.deinit();
                    if (sub_result.matched) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(stack, &captures, &pc, &pos, subroutine_stack, &self.options)) break;
                    }
                },
                .AssertForwardNegative => {
                    const epc = self.bytecode.assert_ends.items[pc];
                    var sub_result = try execInternal(true, false, self, input, pos, pc + 1, epc);
                    defer sub_result.deinit();
                    if (!sub_result.matched) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(stack, &captures, &pc, &pos, subroutine_stack, &self.options)) break;
                    }
                },
                .AssertForwardEnd => {
                    pc += 1;
                },
                .AssertBackward => |width| {
                    const epc = self.bytecode.assert_ends.items[pc];
                    var success = false;
                    if (width) |w| {
                        if (pos >= w) {
                            const try_pos = pos - w;
                            var sub_result = try execInternal(true, false, self, input, try_pos, pc + 1, epc);
                            defer sub_result.deinit();
                            if (sub_result.matched and sub_result.end == pos) {
                                success = true;
                            }
                        }
                    } else {
                        var try_pos: usize = 0;
                        while (try_pos <= pos) : (try_pos += 1) {
                            var sub_result = try execInternal(true, false, self, input, try_pos, pc + 1, epc);
                            defer sub_result.deinit();
                            if (sub_result.matched and sub_result.end == pos) {
                                success = true;
                                break;
                            }
                        }
                    }
                    if (success) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(stack, &captures, &pc, &pos, subroutine_stack, &self.options)) break;
                    }
                },
                .AssertBackwardNegative => |width| {
                    const epc = self.bytecode.assert_ends.items[pc];
                    var success = true;
                    if (width) |w| {
                        if (pos >= w) {
                            const try_pos = pos - w;
                            var sub_result = try execInternal(true, false, self, input, try_pos, pc + 1, epc);
                            defer sub_result.deinit();
                            if (sub_result.matched and sub_result.end == pos) {
                                success = false;
                            }
                        }
                    } else {
                        var try_pos: usize = 0;
                        while (try_pos <= pos) : (try_pos += 1) {
                            var sub_result = try execInternal(true, false, self, input, try_pos, pc + 1, epc);
                            defer sub_result.deinit();
                            if (sub_result.matched and sub_result.end == pos) {
                                success = false;
                                break;
                            }
                        }
                    }
                    if (success) {
                        pc = epc + 1;
                    } else {
                        if (!maybeBacktrack(stack, &captures, &pc, &pos, subroutine_stack, &self.options)) break;
                    }
                },
                .AssertBackwardEnd => {
                    pc += 1;
                },
                .SubroutineCall => |s| {
                    if (s.target != pc + 1) {
                        try subroutine_stack.append(self.allocator, pc + 1);
                    }
                    pc = s.target;
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
            return MatchResult.sub(matched, start_pos, match_end, self.allocator);
        }
        if (return_captures) {
            const owned_captures = try self.allocator.dupe(?usize, captures.items);
            return MatchResult.owned(matched, owned_captures, start_pos, match_end, self.allocator);
        }
        return MatchResult.borrow(matched, captures, start_pos, match_end, self.allocator);
    }

    pub fn match(self: *Vm, input: []const u8) !bool {
        var result = try self.execFast(input, 0);
        defer result.deinit();
        return result.matched;
    }

    pub fn find(self: *Vm, input: []const u8) !?MatchResult {
        return try findFromInternal(self, input, 0, false);
    }

    pub fn exec(self: *Vm, input: []const u8, start_pos: usize) !MatchResult {
        return execInternal(false, true, self, input, start_pos, 0, self.bytecode.instructions.items.len);
    }

    /// Fast exec that borrows the internal captures buffer.
    /// Caller must not access captures after the next exec call on this Vm.
    pub fn execFast(self: *Vm, input: []const u8, start_pos: usize) !MatchResult {
        return execInternal(false, false, self, input, start_pos, 0, self.bytecode.instructions.items.len);
    }

    /// Clone a borrowed MatchResult into an owned one.
    fn cloneResult(self: *Vm, result: MatchResult) !MatchResult {
        const owned_captures = try self.allocator.dupe(?usize, result.captures.items);
        return MatchResult{
            .matched = result.matched,
            .captures = .{ .items = owned_captures, .capacity = owned_captures.len },
            .start = result.start,
            .end = result.end,
            .allocator = self.allocator,
            .captures_owned = true,
        };
    }

    /// Try matching at `start`; on success clone captures unless `fast`.
    fn tryAt(self: *Vm, input: []const u8, start: usize, comptime fast: bool) !?MatchResult {
        const result = try self.execFast(input, start);
        if (!result.matched) return null;
        if (fast) return result;
        return try self.cloneResult(result);
    }

    /// Skip past UTF-8 continuation bytes (0x80-0xBF).
    fn skipCont(input: []const u8, start: usize) usize {
        var pos = start;
        while (pos < input.len and input[pos] >= 0x80 and input[pos] <= 0xBF) {
            pos += 1;
        }
        return pos;
    }

    fn findFromInternal(self: *Vm, input: []const u8, from_pos: usize, comptime fast: bool) !?MatchResult {
        // Sunday algorithm: if pattern starts with a fixed string, use skip table
        if (self.bytecode.has_skip_table) {
            const prefix_len = self.bytecode.prefix_len;
            const skip_table = self.bytecode.skip_table;
            var start: usize = from_pos;
            while (start + prefix_len <= input.len) {
                if (try self.tryAt(input, start, fast)) |result| return result;
                if (start + prefix_len >= input.len) break;
                start += skip_table[input[start + prefix_len]];
            }
            return null;
        }

        const first_byte = self.bytecode.first_char orelse self.bytecode.first_byte;
        if (first_byte) |first| {
            var start: usize = from_pos;
            while (start <= input.len) {
                if (self.options.case_sensitive) {
                    if (std.mem.indexOfScalar(u8, input[start..], first)) |idx| {
                        start += idx;
                    } else {
                        break;
                    }
                } else {
                    if (first < 128) {
                        const first_lower = std.ascii.toLower(first);
                        const first_upper = std.ascii.toUpper(first);
                        const needles = if (first_lower == first_upper)
                            &[_]u8{first_lower}
                        else
                            &[_]u8{ first_lower, first_upper };
                        while (start < input.len) {
                            const slice = input[start..];
                            const idx = std.mem.indexOfAny(u8, slice, needles) orelse break;
                            start += idx;
                            if (try self.tryAt(input, start, fast)) |result| return result;
                            start = skipCont(input, start + 1);
                        }
                        break;
                    } else {
                        // Non-ASCII case-insensitive: cannot safely skip by first byte
                        // because case folding may change the entire UTF-8 sequence.
                        // Fall through to position-by-position matching.
                    }
                }
                if (start > input.len) break;
                if (try self.tryAt(input, start, fast)) |result| return result;
                start = skipCont(input, start + 1);
            }
            return null;
        }

        // Anchored pattern: only try from_pos
        if (self.bytecode.is_anchored) {
            if (from_pos != 0) return null;
            return try self.tryAt(input, 0, fast);
        }

        // Generic path
        var start: usize = from_pos;
        while (start <= input.len) {
            if (try self.tryAt(input, start, fast)) |result| return result;
            start = skipCont(input, start + 1);
        }
        return null;
    }

    /// Find the first match starting from `from_pos`. Uses fast skipping when possible.
    pub fn findFrom(self: *Vm, input: []const u8, from_pos: usize) !?MatchResult {
        return findFromInternal(self, input, from_pos, false);
    }

    pub fn findFast(self: *Vm, input: []const u8) !?MatchResult {
        return findFromInternal(self, input, 0, true);
    }

    /// Fast version of findFrom that borrows the internal captures buffer.
    /// Caller must not access captures after the next exec/findFromFast call on this Vm.
    pub fn findFromFast(self: *Vm, input: []const u8, from_pos: usize) !?MatchResult {
        return findFromInternal(self, input, from_pos, true);
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
