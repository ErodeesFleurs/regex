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
    Question,      // zero or one (a?)
    Quantifier,    // {n,m} quantifier
    LazyStar,      // lazy zero or more (a*?)
    LazyPlus,      // lazy one or more (a+?)
    LazyQuestion,  // lazy zero or one (a??)
    LazyQuantifier, // lazy {n,m} quantifier
    PossessiveStar,     // possessive zero or more (a*+)
    PossessivePlus,     // possessive one or more (a++)
    PossessiveQuestion, // possessive zero or one (a?+)
    PossessiveQuantifier, // possessive {n,m} quantifier
    Group,         // capturing group ((...))
    Any,           // any character (.)
    CharClass,     // character class ([...])
    AssertStart,   // start anchor (^)
    AssertEnd,     // end anchor ($)
    AssertStringStart,       // \A
    AssertStringEnd,         // \z
    AssertStringEndAllowNewline, // \Z
    AssertForward,      // positive lookahead (?=...)
    AssertForwardNegative, // negative lookahead (?!...)
    AssertBackward,     // positive lookbehind (?<=...)
    AssertBackwardNegative, // negative lookbehind (?<!...)
    InlineFlag,    // inline flag (?i:...)
    AtomicGroup,   // atomic group (?>...)
    Backref,       // backreference \1, \2, ...
    WordBoundary,     // word boundary \b
    NotWordBoundary,  // non-word boundary \B
    UnicodeProperty,     // Unicode property \p{...}
    NotUnicodeProperty,  // negated Unicode property \P{...}
    GraphemeCluster,     // grapheme cluster \X
    Conditional,   // conditional (?(n)yes|no)
    Empty,         // empty expression
};

pub const AstNode = struct {
    type: NodeType,
    value: ?usize, // for Literal (char cast), Quantifier (min), Backref (group_idx)
    left: ?*AstNode, // left subtree
    right: ?*AstNode, // right subtree
    char_class: ?CharClass, // for CharClass
    group_index: ?usize, // for Group
    group_name: ?[]const u8 = null, // for named capturing group
    options: ?RegexOptions = null, // for InlineFlag
    char_class_transferred: bool = false, // whether char_class has been transferred to bytecode
    unicode_property: ?[]const u8 = null, // for UnicodeProperty
    unicode_negated: bool = false, // for UnicodeProperty

    pub fn deinit(self: *AstNode, allocator: std.mem.Allocator) void {
        if (self.group_name) |name| {
            allocator.free(name);
        }
        if (self.unicode_property) |prop| {
            allocator.free(prop);
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
                cc.deinit(allocator);
            }
        }
    }
};

pub const CharClass = struct {
    pub const CharRange = struct {
        start: u8,
        end: u8,
    };

    pub const UnicodePropEntry = struct {
        name: []const u8,
        negated: bool,
    };

    ranges: std.ArrayList(CharRange),
    posix_classes: std.ArrayList([]const u8),
    unicode_properties: std.ArrayList(UnicodePropEntry),
    negated: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, negated: bool) CharClass {
        return .{
            .ranges = .empty,
            .posix_classes = .empty,
            .unicode_properties = .empty,
            .negated = negated,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CharClass, allocator: std.mem.Allocator) void {
        _ = allocator;
        for (self.posix_classes.items) |name| {
            self.allocator.free(name);
        }
        self.posix_classes.deinit(self.allocator);
        for (self.unicode_properties.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.unicode_properties.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
    }

    pub fn addRange(self: *CharClass, start: u8, end: u8) !void {
        try self.ranges.append(self.allocator, .{ .start = start, .end = end });
    }

    pub fn addPosixClass(self: *CharClass, name: []const u8) !void {
        const copy = try self.allocator.dupe(u8, name);
        try self.posix_classes.append(self.allocator, copy);
    }

    pub fn addUnicodeProperty(self: *CharClass, name: []const u8, negated_prop: bool) !void {
        const copy = try self.allocator.dupe(u8, name);
        try self.unicode_properties.append(self.allocator, .{ .name = copy, .negated = negated_prop });
    }

    pub fn contains(self: CharClass, ch: u8) bool {
        for (self.ranges.items) |range| {
            if (ch >= range.start and ch <= range.end) {
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
    const result = blk: {
        if (std.mem.eql(u8, class_name, "alpha")) {
            break :blk std.ascii.isAlphabetic(ch);
        } else if (std.mem.eql(u8, class_name, "alnum")) {
            break :blk std.ascii.isAlphanumeric(ch);
        } else if (std.mem.eql(u8, class_name, "ascii")) {
            break :blk ch < 128;
        } else if (std.mem.eql(u8, class_name, "blank")) {
            break :blk ch == ' ' or ch == '\t';
        } else if (std.mem.eql(u8, class_name, "cntrl")) {
            break :blk ch < 0x20 or ch == 0x7F;
        } else if (std.mem.eql(u8, class_name, "digit")) {
            break :blk std.ascii.isDigit(ch);
        } else if (std.mem.eql(u8, class_name, "graph")) {
            break :blk ch >= 0x21 and ch <= 0x7E;
        } else if (std.mem.eql(u8, class_name, "lower")) {
            break :blk std.ascii.isLower(ch);
        } else if (std.mem.eql(u8, class_name, "print")) {
            break :blk ch >= 0x20 and ch <= 0x7E;
        } else if (std.mem.eql(u8, class_name, "punct")) {
            break :blk std.ascii.isPunctuation(ch);
        } else if (std.mem.eql(u8, class_name, "space")) {
            break :blk ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0C' or ch == '\x0B';
        } else if (std.mem.eql(u8, class_name, "upper")) {
            break :blk std.ascii.isUpper(ch);
        } else if (std.mem.eql(u8, class_name, "word")) {
            break :blk std.ascii.isAlphanumeric(ch) or ch == '_';
        } else if (std.mem.eql(u8, class_name, "xdigit")) {
            break :blk std.ascii.isHex(ch);
        }
        break :blk false;
    };
    return if (negated) !result else result;
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

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .tokenizer = Tokenizer.init(input),
            .allocator = allocator,
            .group_counter = 0,
            .group_names = std.StringHashMap(usize).init(allocator),
            .last_error = null,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.group_names.deinit();
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
            node = try self.allocator.create(AstNode);
            node.?.* = .{
                .type = .Empty,
                .value = null,
                .left = null,
                .right = null,
                .char_class = null,
                .group_index = null,
            };
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

            var right = try self.parseTerm();
            if (right == null) {
                right = try self.allocator.create(AstNode);
                right.?.* = .{
                    .type = .Empty,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
            }

            const node = try self.allocator.create(AstNode);
            node.* = .{
                .type = .Alternate,
                .value = null,
                .left = left,
                .right = right,
                .char_class = null,
                .group_index = null,
            };

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
            node.* = .{
                .type = .Concat,
                .value = null,
                .left = left,
                .right = right,
                .char_class = null,
                .group_index = null,
            };

            left = node;
        }

        return left;
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
                const next = self.tokenizer.peek().type;
                const node = try self.allocator.create(AstNode);
                if (next == .Question) {
                    _ = self.tokenizer.nextToken();
                    node.* = .{ .type = .LazyStar, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                } else if (next == .Plus) {
                    _ = self.tokenizer.nextToken();
                    node.* = .{ .type = .PossessiveStar, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                } else {
                    node.* = .{ .type = .Star, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                }
                return node;
            },
            .Plus => {
                _ = self.tokenizer.nextToken();
                const next = self.tokenizer.peek().type;
                const node = try self.allocator.create(AstNode);
                if (next == .Question) {
                    _ = self.tokenizer.nextToken();
                    node.* = .{ .type = .LazyPlus, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                } else if (next == .Plus) {
                    _ = self.tokenizer.nextToken();
                    node.* = .{ .type = .PossessivePlus, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                } else {
                    node.* = .{ .type = .Plus, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                }
                return node;
            },
            .Question => {
                _ = self.tokenizer.nextToken();
                const next = self.tokenizer.peek().type;
                const node = try self.allocator.create(AstNode);
                if (next == .Question) {
                    _ = self.tokenizer.nextToken();
                    node.* = .{ .type = .LazyQuestion, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                } else if (next == .Plus) {
                    _ = self.tokenizer.nextToken();
                    node.* = .{ .type = .PossessiveQuestion, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                } else {
                    node.* = .{ .type = .Question, .value = null, .left = primary, .right = null, .char_class = null, .group_index = null };
                }
                return node;
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
            .right = null,
            .char_class = null,
            .group_index = max,
        };
        return node;
    }

    // primary = literal | '.' | '(' expression ')' | '[' char_class ']'
    fn parsePrimary(self: *Parser) ParserError!?*AstNode {
        const token = self.tokenizer.peek();

        switch (token.type) {
            .Literal => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);

                // Process escape sequence value
                var value: usize = undefined;
                if (token.value.len >= 2 and token.value[0] == '\\') {
                    value = switch (token.value[1]) {
                        't' => '\t',
                        'n' => '\n',
                        'r' => '\r',
                        'a' => '\x07',
                        'e' => '\x1B',
                        'f' => '\x0C',
                        'v' => '\x0B',
                        '\\' => '\\',
                        'x' => blk: {
                            if (token.value.len >= 4 and token.value[2] == '{') {
                                // \x{hhhh} - variable-length hex
                                const hex = token.value[3 .. token.value.len - 1];
                                break :blk std.fmt.parseInt(u21, hex, 16) catch token.value[1];
                            } else {
                                // \xNN - two-digit hex
                                const hex = token.value[2..];
                                break :blk std.fmt.parseInt(u8, hex, 16) catch token.value[1];
                            }
                        },
                        'u' => blk: {
                            // \uNNNN - four-digit hex
                            const hex = token.value[2..];
                            break :blk std.fmt.parseInt(u16, hex, 16) catch token.value[1];
                        },
                        'c' => blk: {
                            // \cX - control character
                            if (token.value.len >= 3) {
                                const ctrl_ch = token.value[2];
                                break :blk ctrl_ch & 0x1F;
                            }
                            break :blk 0;
                        },
                        '0' => 0,
                        'o' => blk: {
                            // \o{NNN} - octal escape
                            if (token.value.len >= 4 and token.value[2] == '{') {
                                const oct = token.value[3 .. token.value.len - 1];
                                break :blk std.fmt.parseInt(u21, oct, 8) catch token.value[1];
                            }
                            break :blk token.value[1];
                        },
                        'N' => blk: {
                            // \N{U+HHHH} - Unicode code point
                            if (token.value.len >= 6 and token.value[2] == '{' and token.value[3] == 'U' and token.value[4] == '+') {
                                const hex = token.value[5 .. token.value.len - 1];
                                break :blk std.fmt.parseInt(u21, hex, 16) catch token.value[1];
                            }
                            break :blk token.value[1];
                        },
                        else => token.value[1],
                    };
                } else {
                    if (token.value.len == 1) {
                        value = token.value[0];
                    } else {
                        // Multi-byte UTF-8 character
                        value = std.unicode.utf8Decode(token.value) catch token.value[0];
                    }
                }

                node.* = .{
                    .type = .Literal,
                    .value = @intCast(value),
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .Dot => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Any,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .Digit, .NotDigit, .Word, .NotWord, .Whitespace, .NotWhitespace => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                const negated = switch (token.type) {
                    .NotDigit, .NotWord, .NotWhitespace => true,
                    else => false,
                };
                var cc = CharClass.init(self.allocator, negated);

                switch (token.type) {
                    .Digit, .NotDigit => try cc.addRange('0', '9'),
                    .Word, .NotWord => {
                        try cc.addRange('a', 'z');
                        try cc.addRange('A', 'Z');
                        try cc.addRange('0', '9');
                        try cc.addRange('_', '_');
                    },
                    .Whitespace, .NotWhitespace => {
                        try cc.addRange('\t', '\t');
                        try cc.addRange(' ', ' ');
                        try cc.addRange('\n', '\n');
                        try cc.addRange('\r', '\r');
                    },
                    else => unreachable,
                }

                node.* = .{
                    .type = .CharClass,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = cc,
                    .group_index = null,
                };
                return node;
            },
            .WordBoundary, .NotWordBoundary => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = switch (token.type) {
                        .WordBoundary => .WordBoundary,
                        .NotWordBoundary => .NotWordBoundary,
                        else => unreachable,
                    },
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .UnicodeProperty, .NotUnicodeProperty => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                // Extract property name: \p{prop} or \P{prop}
                const prop_name = token.value[3..token.value.len - 1]; // skip \p{ and }
                const prop_copy = try self.allocator.dupe(u8, prop_name);
                node.* = .{
                    .type = switch (token.type) {
                        .UnicodeProperty => .UnicodeProperty,
                        .NotUnicodeProperty => .NotUnicodeProperty,
                        else => unreachable,
                    },
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
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
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .NamedBackref => {
                _ = self.tokenizer.nextToken();
                // token.value is like "\g<name>" or "\k<name>"
                // Extract name between < and >
                const name_start = std.mem.indexOf(u8, token.value, "<") orelse {
                    self.setErrorAtToken("Invalid named backreference syntax", token);
                    return error.InvalidBackref;
                };
                const name_end = std.mem.lastIndexOf(u8, token.value, ">") orelse {
                    self.setErrorAtToken("Invalid named backreference syntax", token);
                    return error.InvalidBackref;
                };
                const name = token.value[name_start + 1 .. name_end];
                const group_idx = self.group_names.get(name) orelse {
                    self.setErrorAtToken("Unknown named capture group", token);
                    return error.InvalidBackref;
                };
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Backref,
                    .value = group_idx,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .GraphemeCluster => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .GraphemeCluster,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .Caret => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .AssertStart,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .Dollar => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .AssertEnd,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .AssertStringStart => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .AssertStringStart,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .AssertStringEnd => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .AssertStringEnd,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .AssertStringEndAllowNewline => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .AssertStringEndAllowNewline,
                    .value = null,
                    .left = null,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
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
        errdefer cc.deinit(self.allocator);

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
                const prop_name = t.value[3..t.value.len - 1]; // skip \p{ and }
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
                    const name_start: usize = self.tokenizer.position;
                    var name_end: usize = name_start;
                    var found_end = false;
                    while (self.tokenizer.position < self.tokenizer.input.len) {
                        const ch = self.tokenizer.input[self.tokenizer.position];
                        if (ch == ':' and self.tokenizer.position + 1 < self.tokenizer.input.len and self.tokenizer.input[self.tokenizer.position + 1] == ']') {
                            found_end = true;
                            name_end = self.tokenizer.position;
                            // Consume ':]'
                            self.tokenizer.position += 2;
                            break;
                        }
                        self.tokenizer.position += 1;
                    }

                    if (found_end and name_end > name_start) {
                        const name = self.tokenizer.input[name_start..name_end];
                        if (name.len > 0 and name[0] == '^') {
                            // Negated POSIX class: add with ^ prefix for isPosixClass to handle
                            try cc.addPosixClass(name);
                        } else {
                            try cc.addPosixClass(name);
                        }
                        continue;
                    } else {
                        // Not a valid POSIX class, rewind and treat ':' and '[' as literal chars
                        self.tokenizer.position = name_start;
                        // Fall through to normal literal handling for ':' and '['
                    }
                }
            }

            // Process shorthand escape sequences inside char class (\d, \w, \s, etc.)
            if (t.value.len == 2 and t.value[0] == '\\') {
                const shorthand_handled = switch (t.value[1]) {
                    'd' => blk: {
                        try cc.addRange('0', '9');
                        break :blk true;
                    },
                    'D' => blk: {
                        try cc.addRange(0, '/' - 1);
                        try cc.addRange(':' , 255);
                        break :blk true;
                    },
                    'w' => blk: {
                        try cc.addRange('a', 'z');
                        try cc.addRange('A', 'Z');
                        try cc.addRange('0', '9');
                        try cc.addRange('_', '_');
                        break :blk true;
                    },
                    'W' => blk: {
                        try cc.addRange(0, '0' - 1);
                        try cc.addRange('9' + 1, 'A' - 1);
                        try cc.addRange('Z' + 1, '_' - 1);
                        try cc.addRange('_' + 1, 'a' - 1);
                        try cc.addRange('z' + 1, 255);
                        break :blk true;
                    },
                    's' => blk: {
                        try cc.addRange('\t', '\t');
                        try cc.addRange(' ', ' ');
                        try cc.addRange('\n', '\n');
                        try cc.addRange('\r', '\r');
                        break :blk true;
                    },
                    'S' => blk: {
                        try cc.addRange(0, '\t' - 1);
                        try cc.addRange('\t' + 1, '\n' - 1);
                        try cc.addRange('\n' + 1, '\r' - 1);
                        try cc.addRange('\r' + 1, ' ' - 1);
                        try cc.addRange(' ' + 1, 255);
                        break :blk true;
                    },
                    else => false,
                };
                if (shorthand_handled) {
                    // shorthand handled, skip range check
                    continue;
                }
            }

            var start: u8 = undefined;
            if (t.value.len >= 2 and t.value[0] == '\\') {
                start = switch (t.value[1]) {
                't' => '\t',
                        'n' => '\n',
                        'r' => '\r',
                        'a' => '\x07',
                        'e' => '\x1B',
                        'f' => '\x0C',
                        'v' => '\x0B',
                        '\\' => '\\',
                    'x' => std.fmt.parseInt(u8, t.value[2..], 16) catch t.value[1],
                    'u' => @truncate(std.fmt.parseInt(u16, t.value[2..], 16) catch t.value[1]),
                    else => t.value[1],
                };
            } else {
                start = t.value[0];
            }

            // Check if it's a range (a-z)
            const next = self.tokenizer.peek();
            if (next.type == .Literal and next.value.len == 1 and next.value[0] == '-') {
                _ = self.tokenizer.nextToken(); // consume '-'

                const end_token = self.tokenizer.peek();
                if (end_token.type == .EOF or end_token.type == .RBracket) {
                    // '-' at the end, treat as literal
                    try cc.addRange(start, start);
                    try cc.addRange('-', '-');
                    continue;
                }

                _ = self.tokenizer.nextToken();
                var end: u8 = undefined;
                if (end_token.value.len >= 2 and end_token.value[0] == '\\') {
                    end = switch (end_token.value[1]) {
                        't' => '\t',
                        'n' => '\n',
                        'r' => '\r',
                        '\\' => '\\',
                        'x' => std.fmt.parseInt(u8, end_token.value[2..], 16) catch end_token.value[1],
                        'u' => @truncate(std.fmt.parseInt(u16, end_token.value[2..], 16) catch end_token.value[1]),
                        else => end_token.value[1],
                    };
                } else {
                    end = end_token.value[0];
                }

                try cc.addRange(start, end);
            } else {
                try cc.addRange(start, start);
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

    fn parseGroup(self: *Parser) ParserError!?*AstNode {
        _ = self.tokenizer.nextToken(); // consume '('
        
        const next_token = self.tokenizer.peek();
        
        if (next_token.type == .Question) {
            _ = self.tokenizer.nextToken(); // consume '?'
            const special = self.tokenizer.peek();

            // Conditional: (?(...)...)
            if (special.type == .LParen) {
                _ = self.tokenizer.nextToken(); // consume '('
                const cond_token = self.tokenizer.nextToken();
                var group_idx: usize = 0;
                var has_condition = false;

                if (cond_token.type == .Literal and cond_token.value.len >= 1) {
                    // Try to parse as number
                    if (std.fmt.parseInt(usize, cond_token.value, 10)) |n| {
                        group_idx = n;
                        has_condition = true;
                    } else |_| {
                        // Could be named group: (?(<name>)...)
                        // For now, only support numeric
                        self.setErrorAtToken("Expected capture group number", cond_token);
                        return error.UnexpectedToken;
                    }
                } else if (cond_token.type == .Backref and cond_token.value.len >= 2) {
                    // Backref token like \1
                    if (std.fmt.parseInt(usize, cond_token.value[1..], 10)) |n| {
                        group_idx = n;
                        has_condition = true;
                    } else |_| {
                        self.setErrorAtToken("Expected capture group number", cond_token);
                        return error.UnexpectedToken;
                    }
                }

                _ = self.tokenizer.expect(.RParen) catch {
                    self.setErrorAtToken("Unclosed condition", self.tokenizer.peek());
                    return error.UnexpectedToken;
                };

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
                    .value = group_idx,
                    .left = yes_branch,
                    .right = no_branch,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            }

            _ = self.tokenizer.nextToken(); // consume special
            if (special.type == .Literal and special.value.len == 1) {
                switch (special.value[0]) {
                    ':' => {
                        // Non-capturing group (?:...)
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
                            .value = null,
                            .left = inner,
                            .right = null,
                            .char_class = null,
                            .group_index = null,
                        };
                        return node;
                    },
                    '=' => {
                        // Positive lookahead (?=...)
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
                            .type = .AssertForward,
                            .value = null,
                            .left = inner,
                            .right = null,
                            .char_class = null,
                            .group_index = null,
                        };
                        return node;
                    },
                    '!' => {
                        // Negative lookahead (?!...)
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
                            .type = .AssertForwardNegative,
                            .value = null,
                            .left = inner,
                            .right = null,
                            .char_class = null,
                            .group_index = null,
                        };
                        return node;
                    },
                    '<' => {
                        // Check if lookbehind (?<=...), (?<!...) or named capture group (?<name>...)
                        const next = self.tokenizer.peek();
                        if (next.type == .Literal and next.value.len == 1) {
                            if (next.value[0] == '=') {
                                // Positive lookbehind (?<=...)
                                _ = self.tokenizer.nextToken(); // consume '='
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
                                    .type = .AssertBackward,
                                    .value = null,
                                    .left = inner,
                                    .right = null,
                                    .char_class = null,
                                    .group_index = null,
                                };
                                return node;
                            } else if (next.value[0] == '!') {
                                // Negative lookbehind (?<!...)
                                _ = self.tokenizer.nextToken(); // consume '!'
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
                                    .type = .AssertBackwardNegative,
                                    .value = null,
                                    .left = inner,
                                    .right = null,
                                    .char_class = null,
                                    .group_index = null,
                                };
                                return node;
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
                    'i', 'm', 's' => {
                        // Inline flag (?i:...), (?m:...), (?s:...) or global (?i), (?m), (?s)
                        var opts = RegexOptions{};
                        var flag_bits: usize = 0;

                        // Process the first flag character (already in `special`)
                        switch (special.value[0]) {
                            'i' => { opts.case_sensitive = false; flag_bits |= 1; },
                            'm' => { opts.multiline = true; flag_bits |= 2; },
                            's' => { opts.dot_matches_newline = true; flag_bits |= 4; },
                            else => unreachable,
                        }

                        // Process additional flag characters (e.g. (?im))
                        while (true) {
                            const next_flag = self.tokenizer.peek();
                            if (next_flag.type == .Literal and next_flag.value.len == 1) {
                                const ch = next_flag.value[0];
                                if (ch == 'i' or ch == 'm' or ch == 's') {
                                    _ = self.tokenizer.nextToken();
                                    switch (ch) {
                                        'i' => { opts.case_sensitive = false; flag_bits |= 1; },
                                        'm' => { opts.multiline = true; flag_bits |= 2; },
                                        's' => { opts.dot_matches_newline = true; flag_bits |= 4; },
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
                                .type = .InlineFlag,
                                .value = flag_bits,
                                .left = inner,
                                .right = null,
                                .char_class = null,
                                .group_index = null,
                                .options = opts,
                            };
                            return node;
                        } else if (next.type == .RParen) {
                            // Global flag (?i)
                            _ = self.tokenizer.nextToken(); // consume ')'
                            const node = try self.allocator.create(AstNode);
                            node.* = .{
                                .type = .InlineFlag,
                                .value = flag_bits,
                                .left = null,
                                .right = null,
                                .char_class = null,
                                .group_index = null,
                                .options = opts,
                            };
                            return node;
                        } else {
                            self.setErrorAtToken("Unexpected token: expected ':' or ')'", next);
                            return error.UnexpectedToken;
                        }
                    },
                    '>' => {
                        // Atomic group (?>...)
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
                            .type = .AtomicGroup,
                            .value = null,
                            .left = inner,
                            .right = null,
                            .char_class = null,
                            .group_index = null,
                        };
                        return node;
                    },
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
            node.* = .{
                .type = .Group,
                .value = null,
                .left = inner,
                .right = null,
                .char_class = null,
                .group_index = group_index,
            };
            return node;
        }
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
            .value = null,
            .left = inner,
            .right = null,
            .char_class = null,
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
