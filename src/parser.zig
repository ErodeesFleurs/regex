const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const RegexOptions = @import("options.zig").RegexOptions;

pub const NodeType = enum {
    Literal, // single character
    Concat, // concatenation (ab)
    Alternate, // alternation (a|b)
    Star, // zero or more (a*)
    Plus, // one or more (a+)
    Question, // zero or one (a?)
    Quantifier, // {n,m} quantifier
    LazyStar, // lazy zero or more (a*?)
    LazyPlus, // lazy one or more (a+?)
    LazyQuestion, // lazy zero or one (a??)
    LazyQuantifier, // lazy {n,m} quantifier
    PossessiveStar, // possessive zero or more (a*+)
    PossessivePlus, // possessive one or more (a++)
    PossessiveQuestion, // possessive zero or one (a?+)
    PossessiveQuantifier, // possessive {n,m} quantifier
    Group, // capturing group ((...))
    Any, // any character (.)
    CharClass, // character class ([...])
    AssertStart, // start anchor (^)
    AssertEnd, // end anchor ($)
    AssertStringStart, // \A
    AssertStringEnd, // \z
    AssertStringEndAllowNewline, // \Z
    AssertMatchStart, // \G
    AssertForward, // positive lookahead (?=...)
    AssertForwardNegative, // negative lookahead (?!...)
    AssertBackward, // positive lookbehind (?<=...)
    AssertBackwardNegative, // negative lookbehind (?<!...)
    InlineFlag, // inline flag (?i:...)
    AtomicGroup, // atomic group (?>...)
    Backref, // backreference \1, \2, ...
    WordBoundary, // word boundary \b
    NotWordBoundary, // non-word boundary \B
    UnicodeProperty, // Unicode property \p{...}
    NotUnicodeProperty, // negated Unicode property \P{...}
    GraphemeCluster, // grapheme cluster \X
    Conditional, // conditional (?(n)yes|no)
    SubroutineCall, // subroutine call (?1) or (?&name)
    Newline, // newline sequence \R
    ResetMatchStart, // \K reset match start
    NotNewline, // \N not newline
    NotVerticalWhitespace, // \V not vertical whitespace
    Empty, // empty expression
};

pub const AstNode = struct {
    type: NodeType,
    value: ?usize = null, // for Literal (char cast), Quantifier (min), Backref (group_idx)
    left: ?*AstNode = null, // left subtree
    right: ?*AstNode = null, // right subtree
    char_class: ?CharClass = null, // for CharClass
    group_index: ?usize = null, // for Group
    group_name: ?[]const u8 = null, // for named capturing group
    options: ?RegexOptions = null, // for InlineFlag
    char_class_transferred: bool = false, // whether char_class has been transferred to bytecode
    unicode_property: ?[]const u8 = null, // for UnicodeProperty
    unicode_negated: bool = false, // for UnicodeProperty
    condition: ?*AstNode = null, // for Conditional (lookahead/lookbehind condition)

    pub fn deinit(self: *AstNode, allocator: std.mem.Allocator) void {
        if (self.group_name) |name| {
            allocator.free(name);
        }
        if (self.unicode_property) |prop| {
            allocator.free(prop);
        }
        if (self.condition) |cond| {
            cond.deinit(allocator);
            allocator.destroy(cond);
        }
        if (self.left) |left| {
            left.deinit(allocator);
            allocator.destroy(left);
        }
        if (self.right) |right| {
            right.deinit(allocator);
            allocator.destroy(right);
        }
        if (self.char_class) |*cc| {
            if (!self.char_class_transferred) {
                cc.deinit();
            }
        }
    }
};

pub const CharClass = struct {
    pub const CharRange = struct {
        start: u8,
        end: u8,
    };

    pub const UnicodeRange = struct {
        start: u21,
        end: u21,
    };

    pub const UnicodePropEntry = struct {
        name: []const u8,
        negated: bool,
    };

    ranges: std.ArrayList(CharRange),
    unicode_ranges: std.ArrayList(UnicodeRange),
    posix_classes: std.ArrayList([]const u8),
    unicode_properties: std.ArrayList(UnicodePropEntry),
    negated: bool,
    allocator: std.mem.Allocator,
    // Cached flags to avoid recomputing on every match
    has_ranges_or_posix: bool = false,
    has_posix_classes: bool = false,
    has_unicode_ranges: bool = false,
    has_unicode_props: bool = false,

    ascii_bitmap: [32]u8 = .{0} ** 32,
    has_ascii_bitmap: bool = false,

    pub fn init(allocator: std.mem.Allocator, negated: bool) CharClass {
        return .{
            .ranges = .empty,
            .unicode_ranges = .empty,
            .posix_classes = .empty,
            .unicode_properties = .empty,
            .negated = negated,
            .allocator = allocator,
            .has_ranges_or_posix = false,
            .has_unicode_ranges = false,
            .has_unicode_props = false,
            .ascii_bitmap = .{0} ** 32,
            .has_ascii_bitmap = false,
        };
    }

    pub fn deinit(self: *CharClass) void {
        for (self.posix_classes.items) |name| {
            self.allocator.free(name);
        }
        self.posix_classes.deinit(self.allocator);
        for (self.unicode_properties.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.unicode_properties.deinit(self.allocator);
        self.unicode_ranges.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
    }

    pub fn addRange(self: *CharClass, start: u8, end: u8) !void {
        try self.ranges.append(self.allocator, .{ .start = start, .end = end });
        self.has_ranges_or_posix = true;
        if (end < 128) {
            self.has_ascii_bitmap = true;
            var i: usize = start;
            while (i <= end) : (i += 1) {
                self.ascii_bitmap[i >> 3] |= @as(u8, 1) << @truncate(i & 7);
            }
        } else if (start < 128) {
            // Range extends past ASCII; fill the ASCII portion in the bitmap.
            self.has_ascii_bitmap = true;
            var i: usize = start;
            while (i < 128) : (i += 1) {
                self.ascii_bitmap[i >> 3] |= @as(u8, 1) << @truncate(i & 7);
            }
        }
    }

    pub fn addUnicodeRange(self: *CharClass, start: u21, end: u21) !void {
        try self.unicode_ranges.append(self.allocator, .{ .start = start, .end = end });
        self.has_unicode_ranges = true;
    }

    pub fn addPosixClass(self: *CharClass, name: []const u8) !void {
        const copy = try self.allocator.dupe(u8, name);
        try self.posix_classes.append(self.allocator, copy);
        self.has_ranges_or_posix = true;
        self.has_posix_classes = true;
    }

    pub fn addShorthandClass(self: *CharClass, shorthand: u8) !void {
        switch (shorthand) {
            'd' => try self.addRange('0', '9'),
            'D' => {
                try self.addRange(0, '/' - 1);
                try self.addRange(':', 255);
            },
            'w' => {
                try self.addRange('a', 'z');
                try self.addRange('A', 'Z');
                try self.addRange('0', '9');
                try self.addRange('_', '_');
            },
            'W' => {
                try self.addRange(0, '0' - 1);
                try self.addRange('9' + 1, 'A' - 1);
                try self.addRange('Z' + 1, '_' - 1);
                try self.addRange('_' + 1, 'a' - 1);
                try self.addRange('z' + 1, 255);
            },
            's' => {
                try self.addRange('\t', '\t');
                try self.addRange(' ', ' ');
                try self.addRange('\n', '\n');
                try self.addRange('\r', '\r');
            },
            'S' => {
                try self.addRange(0, '\t' - 1);
                try self.addRange('\t' + 1, '\n' - 1);
                try self.addRange('\n' + 1, '\r' - 1);
                try self.addRange('\r' + 1, ' ' - 1);
                try self.addRange(' ' + 1, 255);
            },
            'h' => {
                try self.addRange('\t', '\t');
                try self.addRange(' ', ' ');
            },
            'H' => {
                try self.addRange(0, '\t' - 1);
                try self.addRange('\t' + 1, ' ' - 1);
                try self.addRange(' ' + 1, 255);
            },
            else => unreachable,
        }
    }

    pub fn addUnicodeProperty(self: *CharClass, name: []const u8, negated_prop: bool) !void {
        const copy = try self.allocator.dupe(u8, name);
        try self.unicode_properties.append(self.allocator, .{ .name = copy, .negated = negated_prop });
        self.has_unicode_props = true;
    }

    pub fn contains(self: CharClass, ch: u8) bool {
        for (self.ranges.items) |range| {
            if (ch >= range.start and ch <= range.end) {
                return !self.negated;
            }
        }
        return self.negated;
    }

    pub fn containsUnicodeRange(self: CharClass, cp: u21) bool {
        for (self.unicode_ranges.items) |range| {
            if (cp >= range.start and cp <= range.end) {
                return !self.negated;
            }
        }
        return self.negated;
    }

    pub fn containsPosixClass(self: CharClass, ch: u8) bool {
        if (self.posix_classes.items.len == 0) {
            return false;
        }
        for (self.posix_classes.items) |name| {
            if (isPosixClass(ch, name)) {
                return !self.negated;
            }
        }
        return self.negated;
    }
};

/// Check if a character belongs to a POSIX character class.
/// Supports: alpha, alnum, ascii, blank, cntrl, digit, graph, lower, print, punct, space, upper, word, xdigit
fn isPosixClass(ch: u8, name: []const u8) bool {
    const negated = name.len > 0 and name[0] == '^';
    const class_name = if (negated) name[1..] else name;
    const result = if (class_name.len == 0) false else switch (class_name[0]) {
        'a' => switch (class_name[1]) {
            'l' => if (class_name.len == 5 and class_name[2] == 'p' and class_name[3] == 'h' and class_name[4] == 'a')
                std.ascii.isAlphabetic(ch)
            else if (class_name.len == 5 and class_name[2] == 'n' and class_name[3] == 'u' and class_name[4] == 'm')
                std.ascii.isAlphanumeric(ch)
            else if (class_name.len == 5 and class_name[2] == 's' and class_name[3] == 'c' and class_name[4] == 'i')
                ch < 128
            else
                false,
            else => false,
        },
        'b' => if (class_name.len == 5 and class_name[1] == 'l' and class_name[2] == 'a' and class_name[3] == 'n' and class_name[4] == 'k')
            ch == ' ' or ch == '\t'
        else
            false,
        'c' => if (class_name.len == 5 and class_name[1] == 'n' and class_name[2] == 't' and class_name[3] == 'r' and class_name[4] == 'l')
            ch < 0x20 or ch == 0x7F
        else
            false,
        'd' => if (class_name.len == 5 and class_name[1] == 'i' and class_name[2] == 'g' and class_name[3] == 'i' and class_name[4] == 't')
            std.ascii.isDigit(ch)
        else
            false,
        'g' => if (class_name.len == 5 and class_name[1] == 'r' and class_name[2] == 'a' and class_name[3] == 'p' and class_name[4] == 'h')
            ch >= 0x21 and ch <= 0x7E
        else
            false,
        'l' => if (class_name.len == 5 and class_name[1] == 'o' and class_name[2] == 'w' and class_name[3] == 'e' and class_name[4] == 'r')
            std.ascii.isLower(ch)
        else
            false,
        'p' => if (class_name.len == 5 and class_name[1] == 'r' and class_name[2] == 'i' and class_name[3] == 'n' and class_name[4] == 't')
            ch >= 0x20 and ch <= 0x7E
        else if (class_name.len == 5 and class_name[1] == 'u' and class_name[2] == 'n' and class_name[3] == 'c' and class_name[4] == 't')
            std.ascii.isPunctuation(ch)
        else
            false,
        's' => if (class_name.len == 5 and class_name[1] == 'p' and class_name[2] == 'a' and class_name[3] == 'c' and class_name[4] == 'e')
            ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0C' or ch == '\x0B'
        else
            false,
        'u' => if (class_name.len == 5 and class_name[1] == 'p' and class_name[2] == 'p' and class_name[3] == 'e' and class_name[4] == 'r')
            std.ascii.isUpper(ch)
        else
            false,
        'w' => if (class_name.len == 4 and class_name[1] == 'o' and class_name[2] == 'r' and class_name[3] == 'd')
            std.ascii.isAlphanumeric(ch) or ch == '_'
        else
            false,
        'x' => if (class_name.len == 6 and class_name[1] == 'd' and class_name[2] == 'i' and class_name[3] == 'g' and class_name[4] == 'i' and class_name[5] == 't')
            std.ascii.isHex(ch)
        else
            false,
        else => false,
    };
    if (negated) return !result;
    return result;
}

pub const ParseErrorInfo = struct {
    message: []const u8,
    position: usize,

    pub fn format(self: ParseErrorInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Parse error at position {d}: {s}", .{ self.position, self.message });
    }
};

pub const Parser = struct {
    tokenizer: Tokenizer,
    allocator: std.mem.Allocator,
    group_counter: usize,
    group_names: std.StringHashMap(usize),
    last_error: ?ParseErrorInfo,
    // Branch reset group support: stack of base group counters
    branch_reset_stack: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return initWithOptions(allocator, input, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, input: []const u8, options: RegexOptions) Parser {
        var tokenizer = Tokenizer.init(input);
        tokenizer.free_spacing = options.free_spacing;
        return .{
            .tokenizer = tokenizer,
            .allocator = allocator,
            .group_counter = 0,
            .group_names = std.StringHashMap(usize).init(allocator),
            .last_error = null,
            .branch_reset_stack = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.group_names.deinit();
        self.branch_reset_stack.deinit(self.allocator);
    }

    fn setError(self: *Parser, message: []const u8, position: usize) void {
        self.last_error = ParseErrorInfo{
            .message = message,
            .position = position,
        };
    }

    fn setErrorAtToken(self: *Parser, message: []const u8, token: Token) void {
        self.setError(message, token.position);
    }

    fn createEmptyNode(self: *Parser) !*AstNode {
        return try self.createSimpleNode(.Empty);
    }

    fn createSimpleNode(self: *Parser, node_type: NodeType) !*AstNode {
        const node = try self.allocator.create(AstNode);
        node.* = .{ .type = node_type };
        return node;
    }

    /// Parse a group body and return an AST node with the given type.
    fn parseGroupNode(self: *Parser, node_type: NodeType, group_idx: ?usize) ParserError!*AstNode {
        const inner = try self.parseExpression() orelse {
            self.setErrorAtToken("Empty group", self.tokenizer.peek());
            return error.EmptyGroup;
        };
        _ = self.tokenizer.expect(.RParen) catch {
            self.setErrorAtToken("Unclosed group", self.tokenizer.peek());
            inner.deinit(self.allocator);
            self.allocator.destroy(inner);
            return error.UnexpectedToken;
        };
        const node = try self.allocator.create(AstNode);
        node.* = .{ .type = node_type, .left = inner, .group_index = group_idx };
        return node;
    }

    pub fn parse(self: *Parser) !?*AstNode {
        var node = try self.parseExpression();

        // Ensure we've reached the end of input
        const token = self.tokenizer.nextToken();
        if (token.type != .EOF) {
            self.setErrorAtToken("Unexpected token after expression", token);
            if (node) |n| {
                n.deinit(self.allocator);
                self.allocator.destroy(n);
            }
            return error.UnexpectedToken;
        }

        if (node == null) {
            node = try self.createEmptyNode();
        }

        return node;
    }

    // expression = term ( '|' term )*
    fn parseExpression(self: *Parser) ParserError!?*AstNode {
        var left = try self.parseTerm() orelse return null;

        while (true) {
            const token = self.tokenizer.peek();
            if (token.type != .Pipe) break;

            _ = self.tokenizer.nextToken(); // consume '|'

            // Branch reset: reset group counter to base at each branch boundary
            if (self.branch_reset_stack.items.len > 0) {
                self.group_counter = self.branch_reset_stack.items[self.branch_reset_stack.items.len - 1];
            }

            var right = try self.parseTerm();
            if (right == null) {
                right = try self.createEmptyNode();
            }

            const node = try self.allocator.create(AstNode);
            node.* = .{ .type = .Alternate, .left = left, .right = right };

            left = node;
        }

        return left;
    }

    // term = factor+
    fn parseTerm(self: *Parser) ParserError!?*AstNode {
        var left = try self.parseFactor() orelse return null;

        while (true) {
            const right = try self.parseFactor() orelse break;

            const node = try self.allocator.create(AstNode);
            node.* = .{ .type = .Concat, .left = left, .right = right };

            left = node;
        }

        return left;
    }

    fn makeQuantifierNode(self: *Parser, primary: *AstNode, base: NodeType, lazy: NodeType, possessive: NodeType) !*AstNode {
        const next = self.tokenizer.peek().type;
        const node = try self.allocator.create(AstNode);
        if (next == .Question) {
            _ = self.tokenizer.nextToken();
            node.* = .{ .type = lazy, .left = primary };
        } else if (next == .Plus) {
            _ = self.tokenizer.nextToken();
            node.* = .{ .type = possessive, .left = primary };
        } else {
            node.* = .{ .type = base, .left = primary };
        }
        return node;
    }

    // factor = primary quantifier?
    fn parseFactor(self: *Parser) ParserError!?*AstNode {
        const primary = try self.parsePrimary() orelse return null;
        errdefer {
            primary.deinit(self.allocator);
            self.allocator.destroy(primary);
        }

        const token = self.tokenizer.peek();
        switch (token.type) {
            .Star => {
                _ = self.tokenizer.nextToken();
                return try self.makeQuantifierNode(primary, .Star, .LazyStar, .PossessiveStar);
            },
            .Plus => {
                _ = self.tokenizer.nextToken();
                return try self.makeQuantifierNode(primary, .Plus, .LazyPlus, .PossessivePlus);
            },
            .Question => {
                _ = self.tokenizer.nextToken();
                return try self.makeQuantifierNode(primary, .Question, .LazyQuestion, .PossessiveQuestion);
            },
            .LBrace => {
                const qnode = try self.parseQuantifier(primary);
                if (qnode) |qn| {
                    const next = self.tokenizer.peek().type;
                    if (next == .Question) {
                        _ = self.tokenizer.nextToken();
                        qn.type = .LazyQuantifier;
                    } else if (next == .Plus) {
                        _ = self.tokenizer.nextToken();
                        qn.type = .PossessiveQuantifier;
                    }
                }
                return qnode;
            },
            else => return primary,
        }
    }

    fn parseQuantifier(self: *Parser, primary: *AstNode) ParserError!?*AstNode {
        _ = self.tokenizer.nextToken(); // consume '{'

        // Parse minimum value (supports multiple digits)
        var min_buf: [64]u8 = undefined;
        var min_len: usize = 0;
        var t = self.tokenizer.nextToken();
        while (t.type == .Literal and t.value.len == 1 and std.ascii.isDigit(t.value[0])) {
            if (min_len >= min_buf.len) {
                self.setErrorAtToken("Quantifier minimum value too long", t);
                return error.InvalidQuantifier;
            }
            min_buf[min_len] = t.value[0];
            min_len += 1;
            const peek = self.tokenizer.peek();
            if (peek.type == .Literal and peek.value.len == 1 and std.ascii.isDigit(peek.value[0])) {
                t = self.tokenizer.nextToken();
            } else {
                break;
            }
        }
        if (min_len == 0) {
            self.setErrorAtToken("Invalid quantifier: expected minimum value", t);
            return error.InvalidQuantifier;
        }
        const min = try std.fmt.parseInt(usize, min_buf[0..min_len], 10);

        const next = self.tokenizer.peek();
        var max: ?usize = min;

        if (next.type == .Literal and next.value.len == 1 and next.value[0] == ',') {
            _ = self.tokenizer.nextToken(); // consume ','
            const after_comma = self.tokenizer.peek();
            if (after_comma.type == .RBrace) {
                // {n,} - at least n times
                max = null;
            } else {
                // {n,m} - n to m times (supports multiple digits)
                var max_buf: [64]u8 = undefined;
                var max_len: usize = 0;
                var mt = self.tokenizer.nextToken();
                while (mt.type == .Literal and mt.value.len == 1 and std.ascii.isDigit(mt.value[0])) {
                    if (max_len >= max_buf.len) {
                        self.setErrorAtToken("Quantifier maximum value too long", mt);
                        return error.InvalidQuantifier;
                    }
                    max_buf[max_len] = mt.value[0];
                    max_len += 1;
                    const peek = self.tokenizer.peek();
                    if (peek.type == .Literal and peek.value.len == 1 and std.ascii.isDigit(peek.value[0])) {
                        mt = self.tokenizer.nextToken();
                    } else {
                        break;
                    }
                }
                if (max_len == 0) {
                    self.setErrorAtToken("Invalid quantifier: expected maximum value", mt);
                    return error.InvalidQuantifier;
                }
                max = try std.fmt.parseInt(usize, max_buf[0..max_len], 10);
            }
        }

        _ = self.tokenizer.expect(.RBrace) catch {
            self.setErrorAtToken("Expected }", self.tokenizer.peek());
            return error.UnexpectedToken;
        };

        if (max) |m| {
            if (min > m) {
                self.setError("Invalid quantifier: minimum greater than maximum", self.tokenizer.peek().position);
                return error.InvalidQuantifier;
            }
        }

        // Create quantifier node
        const node = try self.allocator.create(AstNode);
        node.* = .{
            .type = .Quantifier,
            .value = min,
            .left = primary,
            .group_index = max,
        };
        return node;
    }

    fn parseEscapeValue(token_value: []const u8) usize {
        if (token_value.len >= 2 and token_value[0] == '\\') {
            return switch (token_value[1]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                'a' => '\x07',
                'e' => '\x1B',
                'f' => '\x0C',
                'v' => '\x0B',
                '\\' => '\\',
                'x' => blk: {
                    if (token_value.len >= 4 and token_value[2] == '{') {
                        const hex = token_value[3 .. token_value.len - 1];
                        break :blk std.fmt.parseInt(u21, hex, 16) catch token_value[1];
                    } else {
                        const hex = token_value[2..];
                        break :blk std.fmt.parseInt(u8, hex, 16) catch token_value[1];
                    }
                },
                'u' => blk: {
                    const hex = token_value[2..];
                    break :blk std.fmt.parseInt(u16, hex, 16) catch token_value[1];
                },
                'c' => blk: {
                    if (token_value.len >= 3) {
                        const ctrl_ch = token_value[2];
                        break :blk ctrl_ch & 0x1F;
                    }
                    break :blk 0;
                },
                '0' => 0,
                'o' => blk: {
                    if (token_value.len >= 4 and token_value[2] == '{') {
                        const oct = token_value[3 .. token_value.len - 1];
                        break :blk std.fmt.parseInt(u21, oct, 8) catch token_value[1];
                    }
                    break :blk token_value[1];
                },
                'N' => blk: {
                    if (token_value.len >= 6 and token_value[2] == '{' and token_value[3] == 'U' and token_value[4] == '+') {
                        const hex = token_value[5 .. token_value.len - 1];
                        break :blk std.fmt.parseInt(u21, hex, 16) catch token_value[1];
                    }
                    break :blk token_value[1];
                },
                else => token_value[1],
            };
        } else {
            if (token_value.len == 1) {
                return token_value[0];
            } else {
                return std.unicode.utf8Decode(token_value) catch token_value[0];
            }
        }
    }

    fn parseNamedBackrefValue(self: *Parser, token: Token) ParserError!usize {
        if (std.mem.indexOf(u8, token.value, "<")) |name_start| {
            if (std.mem.lastIndexOf(u8, token.value, ">")) |name_end| {
                const ref = token.value[name_start + 1 .. name_end];
                return self.group_names.get(ref) orelse {
                    self.setErrorAtToken("Unknown named capture group", token);
                    return error.InvalidBackref;
                };
            } else {
                self.setErrorAtToken("Invalid named backreference syntax", token);
                return error.InvalidBackref;
            }
        } else if (std.mem.indexOf(u8, token.value, "{")) |brace_start| {
            if (std.mem.lastIndexOf(u8, token.value, "}")) |brace_end| {
                const ref = token.value[brace_start + 1 .. brace_end];
                if (ref.len >= 2 and (ref[0] == '-' or ref[0] == '+')) {
                    const rel = std.fmt.parseInt(isize, ref, 10) catch {
                        self.setErrorAtToken("Invalid relative backreference", token);
                        return error.InvalidBackref;
                    };
                    if (rel < 0) {
                        return if (self.group_counter >= @abs(rel)) self.group_counter - @abs(rel) + 1 else 0;
                    } else {
                        return self.group_counter + @abs(rel);
                    }
                } else if (std.fmt.parseInt(usize, ref, 10)) |n| {
                    return n;
                } else |_| {
                    return self.group_names.get(ref) orelse {
                        self.setErrorAtToken("Unknown named capture group", token);
                        return error.InvalidBackref;
                    };
                }
            } else {
                self.setErrorAtToken("Invalid named backreference syntax", token);
                return error.InvalidBackref;
            }
        } else {
            self.setErrorAtToken("Invalid named backreference syntax", token);
            return error.InvalidBackref;
        }
    }

    fn createShorthandCharClassNode(self: *Parser, token_type: TokenType) !*AstNode {
        const node = try self.allocator.create(AstNode);
        const negated = switch (token_type) {
            .NotDigit, .NotWord, .NotWhitespace, .NotHorizontalWhitespace => true,
            else => false,
        };
        var cc = CharClass.init(self.allocator, negated);
        const shorthand: u8 = switch (token_type) {
            .Digit, .NotDigit => 'd',
            .Word, .NotWord => 'w',
            .Whitespace, .NotWhitespace => 's',
            .HorizontalWhitespace, .NotHorizontalWhitespace => 'h',
            else => unreachable,
        };
        try cc.addShorthandClass(shorthand);
        node.* = .{ .type = .CharClass, .char_class = cc };
        return node;
    }

    // primary = literal | '.' | '(' expression ')' | '[' char_class ']'
    fn parsePrimary(self: *Parser) ParserError!?*AstNode {
        const token = self.tokenizer.peek();

        switch (token.type) {
            .Literal => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Literal,
                    .value = @intCast(parseEscapeValue(token.value)),
                };
                return node;
            },
            .Dot => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{ .type = .Any };
                return node;
            },
            .Digit, .NotDigit, .Word, .NotWord, .Whitespace, .NotWhitespace, .HorizontalWhitespace, .NotHorizontalWhitespace => {
                _ = self.tokenizer.nextToken();
                return try self.createShorthandCharClassNode(token.type);
            },
            .WordBoundary, .NotWordBoundary => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = if (token.type == .WordBoundary) .WordBoundary else .NotWordBoundary,
                };
                return node;
            },
            .UnicodeProperty, .NotUnicodeProperty => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                const prop_name = token.value[3 .. token.value.len - 1];
                const prop_copy = try self.allocator.dupe(u8, prop_name);
                node.* = .{
                    .type = if (token.type == .UnicodeProperty) .UnicodeProperty else .NotUnicodeProperty,
                    .unicode_property = prop_copy,
                    .unicode_negated = token.type == .NotUnicodeProperty,
                };
                return node;
            },
            .LParen => {
                return try self.parseGroup();
            },
            .LBracket => {
                return try self.parseCharClass();
            },
            .Backref => {
                _ = self.tokenizer.nextToken();
                const group_idx = try std.fmt.parseInt(usize, token.value[1..], 10);
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Backref,
                    .value = group_idx,
                };
                return node;
            },
            .NamedBackref => {
                _ = self.tokenizer.nextToken();
                const group_idx = try self.parseNamedBackrefValue(token);
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Backref,
                    .value = group_idx,
                };
                return node;
            },
            .GraphemeCluster => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.GraphemeCluster);
            },
            .Newline => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.Newline);
            },
            .ResetMatchStart => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.ResetMatchStart);
            },
            .NotNewline => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.NotNewline);
            },
            .NotVerticalWhitespace => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.NotVerticalWhitespace);
            },
            .Caret => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.AssertStart);
            },
            .Dollar => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.AssertEnd);
            },
            .AssertStringStart => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.AssertStringStart);
            },
            .AssertStringEnd => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.AssertStringEnd);
            },
            .AssertStringEndAllowNewline => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.AssertStringEndAllowNewline);
            },
            .AssertMatchStart => {
                _ = self.tokenizer.nextToken();
                return try self.createSimpleNode(.AssertMatchStart);
            },
            else => return null,
        }
    }

    fn parseCharClass(self: *Parser) ParserError!?*AstNode {
        const lbracket_token = self.tokenizer.peek();
        _ = self.tokenizer.expect(.LBracket) catch {
            self.setErrorAtToken("Invalid character class", lbracket_token);
            return error.InvalidCharClass;
        };

        const token = self.tokenizer.peek();
        const negated = token.type == .Caret;
        if (negated) {
            _ = self.tokenizer.nextToken();
        }

        var cc = CharClass.init(self.allocator, negated);
        errdefer cc.deinit();

        while (true) {
            const t = self.tokenizer.peek();
            if (t.type == .RBracket) {
                _ = self.tokenizer.nextToken();
                break;
            }

            if (t.type == .EOF) {
                self.setErrorAtToken("Unterminated character class", t);
                return error.UnterminatedCharClass;
            }

            _ = self.tokenizer.nextToken();

            // Unicode property inside character class: \p{...} or \P{...}
            if (t.type == .UnicodeProperty or t.type == .NotUnicodeProperty) {
                const prop_name = t.value[3 .. t.value.len - 1]; // skip \p{ and }
                try cc.addUnicodeProperty(prop_name, t.type == .NotUnicodeProperty);
                continue;
            }

            // POSIX character class: [:name:]
            const is_lbracket = t.type == .LBracket;
            const is_literal_bracket = t.type == .Literal and t.value.len == 1 and t.value[0] == '[';
            if (is_lbracket or is_literal_bracket) {
                const next_t = self.tokenizer.peek();
                if (next_t.type == .Literal and next_t.value.len == 1 and next_t.value[0] == ':') {
                    // Consume ':'
                    _ = self.tokenizer.nextToken();

                    // Read the class name
                    const name = self.tokenizer.scanPosixClassName();
                    if (name) |n| {
                        if (n.len > 0) {
                            // Negated POSIX class: add with ^ prefix for isPosixClass to handle
                            try cc.addPosixClass(n);
                            continue;
                        }
                    }
                    // Not a valid POSIX class; fall through to normal literal handling for ':' and '['
                }
            }

            // Process shorthand escape sequences inside char class (\d, \w, \s, etc.)
            if (t.value.len == 2 and t.value[0] == '\\') {
                const ch = t.value[1];
                if (ch == 'd' or ch == 'D' or ch == 'w' or ch == 'W' or
                    ch == 's' or ch == 'S' or ch == 'h' or ch == 'H')
                {
                    try cc.addShorthandClass(ch);
                    continue;
                }
            }

            // Parse character value (supports ASCII and Unicode)
            const start_info = try self.parseClassCharValue(t.value);

            // Check if it's a range (a-z)
            const next = self.tokenizer.peek();
            if (next.type == .Literal and next.value.len == 1 and next.value[0] == '-') {
                _ = self.tokenizer.nextToken(); // consume '-'

                const end_token = self.tokenizer.peek();
                if (end_token.type == .EOF or end_token.type == .RBracket) {
                    // '-' at the end, treat as literal
                    if (start_info.unicode) {
                        try cc.addUnicodeRange(start_info.cp, start_info.cp);
                    } else {
                        try cc.addRange(@intCast(start_info.cp), @intCast(start_info.cp));
                    }
                    try cc.addRange('-', '-');
                    continue;
                }

                _ = self.tokenizer.nextToken();
                const end_info = try self.parseClassCharValue(end_token.value);

                if (start_info.unicode or end_info.unicode) {
                    try cc.addUnicodeRange(start_info.cp, end_info.cp);
                } else {
                    try cc.addRange(@intCast(start_info.cp), @intCast(end_info.cp));
                }
            } else {
                if (start_info.unicode) {
                    try cc.addUnicodeRange(start_info.cp, start_info.cp);
                } else {
                    try cc.addRange(@intCast(start_info.cp), @intCast(start_info.cp));
                }
            }
        }

        const node = try self.allocator.create(AstNode);
        node.* = .{
            .type = .CharClass,
            .value = null,
            .left = null,
            .right = null,
            .char_class = cc,
            .group_index = null,
        };
        return node;
    }

    const ClassCharInfo = struct {
        cp: u21,
        unicode: bool,
    };

    fn parseClassCharValue(self: *Parser, value: []const u8) ParserError!ClassCharInfo {
        if (value.len >= 2 and value[0] == '\\') {
            switch (value[1]) {
                't' => return .{ .cp = '\t', .unicode = false },
                'n' => return .{ .cp = '\n', .unicode = false },
                'r' => return .{ .cp = '\r', .unicode = false },
                'a' => return .{ .cp = '\x07', .unicode = false },
                'b' => return .{ .cp = '\x08', .unicode = false }, // backspace inside char class
                'e' => return .{ .cp = '\x1B', .unicode = false },
                'f' => return .{ .cp = '\x0C', .unicode = false },
                'v' => return .{ .cp = '\x0B', .unicode = false },
                '\\' => return .{ .cp = '\\', .unicode = false },
                'x' => {
                    if (value.len >= 4 and value[2] == '{') {
                        // \x{hhhh}
                        const hex = value[3 .. value.len - 1];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch {
                            self.setError("Invalid hex escape", 0);
                            return error.InvalidEscapeSequence;
                        };
                        return .{ .cp = cp, .unicode = cp > 255 };
                    } else {
                        // \xNN
                        const cp = std.fmt.parseInt(u8, value[2..], 16) catch {
                            self.setError("Invalid hex escape", 0);
                            return error.InvalidEscapeSequence;
                        };
                        return .{ .cp = cp, .unicode = false };
                    }
                },
                'u' => {
                    if (value.len >= 4 and value[2] == '{') {
                        // \u{hhhh}
                        const hex = value[3 .. value.len - 1];
                        const cp = std.fmt.parseInt(u21, hex, 16) catch {
                            self.setError("Invalid Unicode escape", 0);
                            return error.InvalidEscapeSequence;
                        };
                        return .{ .cp = cp, .unicode = true };
                    } else {
                        // \uNNNN
                        const cp = std.fmt.parseInt(u21, value[2..], 16) catch {
                            self.setError("Invalid Unicode escape", 0);
                            return error.InvalidEscapeSequence;
                        };
                        return .{ .cp = cp, .unicode = cp > 255 };
                    }
                },
                else => return .{ .cp = value[1], .unicode = false },
            }
        } else if (value.len == 1) {
            return .{ .cp = value[0], .unicode = false };
        } else {
            // Multi-byte UTF-8 character
            const cp = std.unicode.utf8Decode(value) catch {
                self.setError("Invalid UTF-8 in character class", 0);
                return error.InvalidEscapeSequence;
            };
            return .{ .cp = cp, .unicode = true };
        }
    }

    fn parseGroup(self: *Parser) ParserError!?*AstNode {
        _ = self.tokenizer.nextToken(); // consume '('

        const next_token = self.tokenizer.peek();

        if (next_token.type == .Question) {
            _ = self.tokenizer.nextToken(); // consume '?'
            const special = self.tokenizer.peek();

            // Comment: (?#comment)
            if (special.type == .Literal and special.value.len == 1 and special.value[0] == '#') {
                _ = self.tokenizer.nextToken(); // consume '#'
                // Skip everything until ')'
                while (true) {
                    const t = self.tokenizer.nextToken();
                    if (t.type == .RParen or t.type == .EOF) break;
                }
                // Return empty node (comment contributes nothing to match)
                return try self.createEmptyNode();
            }

            // Branch reset group: (?|...|...)
            if (special.type == .Pipe) {
                _ = self.tokenizer.nextToken(); // consume '|'
                // Save base counter; groups within each branch start from base+1
                const base = self.group_counter;
                try self.branch_reset_stack.append(self.allocator, base);
                const inner = try self.parseExpression() orelse {
                    self.setErrorAtToken("Empty branch reset group", self.tokenizer.peek());
                    return error.EmptyGroup;
                };
                _ = self.branch_reset_stack.pop();
                _ = self.tokenizer.expect(.RParen) catch {
                    self.setErrorAtToken("Unclosed branch reset group", self.tokenizer.peek());
                    return error.UnexpectedToken;
                };
                const node = try self.allocator.create(AstNode);
                node.* = .{ .type = .Group, .left = inner };
                return node;
            }

            // Conditional: (?(...)...)
            if (special.type == .LParen) {
                return try self.parseConditionalGroup();
            }

            // Subroutine call: (?1), (?2), ... or (?&name)
            if (special.type == .Literal and special.value.len >= 1) {
                if (try self.parseSubroutineCall(special)) |node| {
                    return node;
                }
            }

            _ = self.tokenizer.nextToken(); // consume special
            if (special.type == .Literal and special.value.len == 1) {
                switch (special.value[0]) {
                    ':' => return try self.parseGroupNode(.Group, null),
                    '=' => return try self.parseGroupNode(.AssertForward, null),
                    '!' => return try self.parseGroupNode(.AssertForwardNegative, null),
                    '<' => {
                        // Check if lookbehind (?<=...), (?<!...) or named capture group (?<name>...)
                        const next = self.tokenizer.peek();
                        if (next.type == .Literal and next.value.len == 1) {
                            if (next.value[0] == '=') {
                                _ = self.tokenizer.nextToken(); // consume '='
                                return try self.parseGroupNode(.AssertBackward, null);
                            } else if (next.value[0] == '!') {
                                _ = self.tokenizer.nextToken(); // consume '!'
                                return try self.parseGroupNode(.AssertBackwardNegative, null);
                            }
                        }
                        // Named capture group (?<name>...)
                        return try self.parseNamedGroup();
                    },
                    'P' => {
                        // Python-style named capture group (?P<name>...)
                        const next = self.tokenizer.peek();
                        if (next.type == .Literal and next.value.len == 1 and next.value[0] == '<') {
                            _ = self.tokenizer.nextToken(); // consume '<'
                            return try self.parseNamedGroup();
                        }
                        self.setErrorAtToken("Unexpected token", next);
                        return error.UnexpectedToken;
                    },
                    'i', 'm', 's', 'x' => {
                        return try self.parseInlineFlagGroup(special);
                    },
                    '>' => return try self.parseGroupNode(.AtomicGroup, null),
                    else => {
                        self.setErrorAtToken("Unexpected token in group", special);
                        return error.UnexpectedToken;
                    },
                }
            } else {
                return error.UnexpectedToken;
            }
        } else {
            // Ordinary capturing group
            self.group_counter += 1;
            const group_index = self.group_counter;
            return self.parseGroupNode(.Group, group_index);
        }
    }

    /// Parse conditional group: (?(n)yes|no) or (?(...)...)
    fn parseConditionalGroup(self: *Parser) ParserError!?*AstNode {
        _ = self.tokenizer.nextToken(); // consume '('
        const cond_token = self.tokenizer.peek();

        var cond_node: ?*AstNode = null;
        var group_idx: usize = 0;
        var is_group_condition = false;

        // Check for lookahead/lookbehind condition: (?=...), (?!...), (?<=...), (?<!...)
        if (cond_token.type == .Question) {
            _ = self.tokenizer.nextToken(); // consume '?'
            const look_token = self.tokenizer.peek();
            if (look_token.type == .Literal and look_token.value.len == 1) {
                const look_ch = look_token.value[0];
                if (look_ch == '=' or look_ch == '!') {
                    _ = self.tokenizer.nextToken(); // consume '=' or '!'
                    const inner = try self.parseExpression() orelse {
                        self.setErrorAtToken("Empty lookahead condition", self.tokenizer.peek());
                        return error.EmptyGroup;
                    };
                    _ = self.tokenizer.expect(.RParen) catch {
                        self.setErrorAtToken("Unclosed lookahead condition", self.tokenizer.peek());
                        return error.UnexpectedToken;
                    };
                    const assert_node = try self.allocator.create(AstNode);
                    assert_node.* = .{
                        .type = if (look_ch == '=') .AssertForward else .AssertForwardNegative,
                        .left = inner,
                    };
                    cond_node = assert_node;
                } else if (look_ch == '<') {
                    _ = self.tokenizer.nextToken(); // consume '<'
                    const next_after_lt = self.tokenizer.peek();
                    if (next_after_lt.type == .Literal and next_after_lt.value.len == 1) {
                        const lt_ch = next_after_lt.value[0];
                        if (lt_ch == '=' or lt_ch == '!') {
                            _ = self.tokenizer.nextToken(); // consume '=' or '!'
                            const inner = try self.parseExpression() orelse {
                                self.setErrorAtToken("Empty lookbehind condition", self.tokenizer.peek());
                                return error.EmptyGroup;
                            };
                            _ = self.tokenizer.expect(.RParen) catch {
                                self.setErrorAtToken("Unclosed lookbehind condition", self.tokenizer.peek());
                                return error.UnexpectedToken;
                            };
                            const assert_node = try self.allocator.create(AstNode);
                            assert_node.* = .{
                                .type = if (lt_ch == '=') .AssertBackward else .AssertBackwardNegative,
                                .left = inner,
                            };
                            cond_node = assert_node;
                        }
                    }
                }
            }
        }

        // If not a lookahead/lookbehind, try numeric group condition
        if (cond_node == null) {
            const num_token = self.tokenizer.nextToken();
            if (num_token.type == .Literal and num_token.value.len >= 1) {
                if (std.fmt.parseInt(usize, num_token.value, 10)) |n| {
                    group_idx = n;
                    is_group_condition = true;
                } else |_| {
                    self.setErrorAtToken("Expected capture group number or lookahead/lookbehind", num_token);
                    return error.UnexpectedToken;
                }
            } else if (num_token.type == .Backref and num_token.value.len >= 2) {
                if (std.fmt.parseInt(usize, num_token.value[1..], 10)) |n| {
                    group_idx = n;
                    is_group_condition = true;
                } else |_| {
                    self.setErrorAtToken("Expected capture group number", num_token);
                    return error.UnexpectedToken;
                }
            } else {
                self.setErrorAtToken("Expected capture group number or lookahead/lookbehind", num_token);
                return error.UnexpectedToken;
            }

            _ = self.tokenizer.expect(.RParen) catch {
                self.setErrorAtToken("Unclosed condition", self.tokenizer.peek());
                return error.UnexpectedToken;
            };
        }

        const yes_branch = try self.parseExpression() orelse {
            self.setErrorAtToken("Empty conditional branch", self.tokenizer.peek());
            return error.EmptyGroup;
        };

        var no_branch: ?*AstNode = null;
        const after_yes = self.tokenizer.peek();
        if (after_yes.type == .Pipe) {
            _ = self.tokenizer.nextToken(); // consume '|'
            no_branch = try self.parseExpression() orelse {
                self.setErrorAtToken("Empty conditional branch", self.tokenizer.peek());
                return error.EmptyGroup;
            };
        }

        _ = self.tokenizer.expect(.RParen) catch {
            self.setErrorAtToken("Unclosed conditional group", self.tokenizer.peek());
            return error.UnexpectedToken;
        };

        const node = try self.allocator.create(AstNode);
        node.* = .{
            .type = .Conditional,
            .value = if (is_group_condition) group_idx else null,
            .left = yes_branch,
            .right = no_branch,
            .condition = cond_node,
        };
        return node;
    }

    /// Parse inline flag group: (?i:...), (?m:...), (?s:...), (?x:...) or global (?i)
    fn parseInlineFlagGroup(self: *Parser, special: Token) ParserError!?*AstNode {
        var opts = RegexOptions{};
        var flag_bits: usize = 0;

        // Process the first flag character (already in `special`)
        switch (special.value[0]) {
            'i' => {
                opts.case_sensitive = false;
                flag_bits |= 1;
            },
            'm' => {
                opts.multiline = true;
                flag_bits |= 2;
            },
            's' => {
                opts.dot_matches_newline = true;
                flag_bits |= 4;
            },
            'x' => {
                opts.free_spacing = true;
                flag_bits |= 8;
            },
            else => unreachable,
        }

        // Process additional flag characters (e.g. (?im))
        while (true) {
            const next_flag = self.tokenizer.peek();
            if (next_flag.type == .Literal and next_flag.value.len == 1) {
                const ch = next_flag.value[0];
                if (ch == 'i' or ch == 'm' or ch == 's' or ch == 'x') {
                    _ = self.tokenizer.nextToken();
                    switch (ch) {
                        'i' => {
                            opts.case_sensitive = false;
                            flag_bits |= 1;
                        },
                        'm' => {
                            opts.multiline = true;
                            flag_bits |= 2;
                        },
                        's' => {
                            opts.dot_matches_newline = true;
                            flag_bits |= 4;
                        },
                        'x' => {
                            opts.free_spacing = true;
                            flag_bits |= 8;
                        },
                        else => unreachable,
                    }
                    continue;
                }
            }
            break;
        }

        const next = self.tokenizer.peek();
        if (next.type == .Literal and next.value.len == 1 and next.value[0] == ':') {
            // Scoped flag (?i:...)
            _ = self.tokenizer.nextToken(); // consume ':'
            const old_free_spacing = self.tokenizer.free_spacing;
            if (flag_bits & 8 != 0) {
                self.tokenizer.free_spacing = true;
                errdefer self.tokenizer.free_spacing = old_free_spacing;
            }
            const inner = try self.parseExpression() orelse {
                self.setErrorAtToken("Empty group", self.tokenizer.peek());
                return error.EmptyGroup;
            };
            _ = self.tokenizer.expect(.RParen) catch {
                self.setErrorAtToken("Unclosed group", self.tokenizer.peek());
                return error.UnexpectedToken;
            };
            if (flag_bits & 8 != 0) {
                self.tokenizer.free_spacing = old_free_spacing;
            }
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .type = .InlineFlag,
                .value = flag_bits,
                .left = inner,
                .options = opts,
            };
            return node;
        } else if (next.type == .RParen) {
            // Global flag (?i)
            _ = self.tokenizer.nextToken(); // consume ')'
            if (flag_bits & 8 != 0) {
                self.tokenizer.free_spacing = true;
            }
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .type = .InlineFlag,
                .value = flag_bits,
                .options = opts,
            };
            return node;
        } else {
            self.setErrorAtToken("Unexpected token: expected ':' or ')'", next);
            return error.UnexpectedToken;
        }
    }

    /// Parse subroutine call: (?1), (?2), ... or (?&name)
    fn parseSubroutineCall(self: *Parser, special: Token) ParserError!?*AstNode {
        var is_subroutine = false;
        var subroutine_group: usize = 0;

        // Check for (?N) — numeric subroutine call
        if (std.fmt.parseInt(usize, special.value, 10)) |n| {
            is_subroutine = true;
            subroutine_group = n;
            _ = self.tokenizer.nextToken(); // consume the number
        } else |_| {
            // Check for (?&name)
            if (special.value.len == 1 and special.value[0] == '&') {
                _ = self.tokenizer.nextToken(); // consume '&'
                var name_buf: [64]u8 = undefined;
                var name_len: usize = 0;
                while (true) {
                    const name_token = self.tokenizer.peek();
                    if (name_token.type == .Literal and name_token.value.len == 1) {
                        if (name_token.value[0] == ')') break;
                        if (name_len < name_buf.len) {
                            name_buf[name_len] = name_token.value[0];
                            name_len += 1;
                            _ = self.tokenizer.nextToken(); // consume char
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                if (name_len > 0) {
                    const name = name_buf[0..name_len];
                    if (self.group_names.get(name)) |n| {
                        is_subroutine = true;
                        subroutine_group = n;
                    }
                }
            }
        }

        if (is_subroutine) {
            _ = self.tokenizer.expect(.RParen) catch {
                self.setErrorAtToken("Unclosed subroutine call", self.tokenizer.peek());
                return error.UnexpectedToken;
            };
            const node = try self.allocator.create(AstNode);
            node.* = .{
                .type = .SubroutineCall,
                .value = subroutine_group,
            };
            return node;
        }
        return null;
    }

    fn parseNamedGroup(self: *Parser) ParserError!?*AstNode {
        // Parse name (?<name>... or (?P<name>...)
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;

        while (true) {
            const ch_token = self.tokenizer.peek();
            if (ch_token.type == .Literal and ch_token.value.len == 1) {
                const ch = ch_token.value[0];
                if (ch == '>') {
                    _ = self.tokenizer.nextToken(); // consume '>'
                    break;
                }
                if (name_len < name_buf.len) {
                    name_buf[name_len] = ch;
                    name_len += 1;
                    _ = self.tokenizer.nextToken();
                } else {
                    self.setErrorAtToken("Group name too long", ch_token);
                    return error.UnexpectedToken;
                }
            } else {
                self.setErrorAtToken("Unexpected token in group name", ch_token);
                return error.UnexpectedToken;
            }
        }

        const name = try self.allocator.dupe(u8, name_buf[0..name_len]);

        self.group_counter += 1;
        const group_index = self.group_counter;

        try self.group_names.put(name, group_index);

        const inner = try self.parseExpression() orelse {
            self.setErrorAtToken("Empty group", self.tokenizer.peek());
            return error.EmptyGroup;
        };

        _ = self.tokenizer.expect(.RParen) catch {
            self.setErrorAtToken("Unclosed group", self.tokenizer.peek());
            return error.UnexpectedToken;
        };

        const node = try self.allocator.create(AstNode);
        node.* = .{
            .type = .Group,
            .left = inner,
            .group_index = group_index,
            .group_name = name,
        };

        return node;
    }
};

pub const ParserError = error{
    UnexpectedToken,
    EmptyGroup,
    EmptyAlternative,
    InvalidCharClass,
    UnterminatedCharClass,
    InvalidQuantifier,
    InvalidCharacter,
    InvalidBackref,
    InvalidEscapeSequence,
    Overflow,
    OutOfMemory,
};

test "parser literal" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.Literal, ast.?.type);
    try std.testing.expectEqual(@as(u8, 'a'), ast.?.value.?);

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}

test "parser concat" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "ab");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.Concat, ast.?.type);
    try std.testing.expectEqual(.Literal, ast.?.left.?.type);
    try std.testing.expectEqual(.Literal, ast.?.right.?.type);

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}

test "parser alternate" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a|b");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.Alternate, ast.?.type);

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}

test "parser star" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a*");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.Star, ast.?.type);
    try std.testing.expectEqual(.Literal, ast.?.left.?.type);

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}

test "parser group" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "(ab)");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.Group, ast.?.type);
    try std.testing.expectEqual(@as(usize, 1), ast.?.group_index.?);

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}

test "parser char class" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "[a-z]");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.CharClass, ast.?.type);
    try std.testing.expect(ast.?.char_class != null);
    try std.testing.expect(ast.?.char_class.?.contains('a'));
    try std.testing.expect(ast.?.char_class.?.contains('z'));
    try std.testing.expect(!ast.?.char_class.?.contains('A'));

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}

test "parser complex" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "(a|b)*c");

    const ast = try parser.parse();
    try std.testing.expect(ast != null);
    try std.testing.expectEqual(.Concat, ast.?.type);

    ast.?.deinit(allocator);
    allocator.destroy(ast.?);
}
