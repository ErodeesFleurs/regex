const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;
const Tokenizer = @import("tokenizer.zig").Tokenizer;

pub const NodeType = enum {
    Literal, // 单个字符
    Concat, // 连接 (ab)
    Alternate, // 选择 (a|b)
    Star, // 零次或多次 (a*)
    Plus, // 一次或多次 (a+)
    Question,      // 零次或一次 (a?)
    Quantifier,    // {n,m} 量词
    Group,         // 捕获组 ((...))
    Any,           // 任意字符 (.)
    CharClass,     // 字符类 ([...])
    AssertStart,   // 开始锚点 (^)
    AssertEnd,     // 结束锚点 ($)
    AssertForward,      // 正向前瞻 (?=...)
    AssertForwardNegative, // 负向前瞻 (?!...)
    AssertBackward,     // 正向后顾 (?<=...)
    AssertBackwardNegative, // 负向后顾 (?<!...)
    Backref,       // 反向引用 \1, \2, ...
    WordBoundary,     // 单词边界 \b
    NotWordBoundary,  // 非单词边界 \B
    Empty,         // 空表达式
};

pub const AstNode = struct {
    type: NodeType,
    value: ?u8, // 用于 Literal
    left: ?*AstNode, // 左子树
    right: ?*AstNode, // 右子树
    char_class: ?CharClass, // 用于 CharClass
    group_index: ?usize, // 用于 Group
    char_class_transferred: bool = false, // char_class 是否已被转移到 bytecode

    pub fn deinit(self: *AstNode, allocator: std.mem.Allocator) void {
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
    
    ranges: std.ArrayList(CharRange),
    negated: bool,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, negated: bool) CharClass {
        return .{
            .ranges = .empty,
            .negated = negated,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *CharClass, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.ranges.deinit(self.allocator);
    }
    
    pub fn addRange(self: *CharClass, start: u8, end: u8) !void {
        try self.ranges.append(self.allocator, .{ .start = start, .end = end });
    }

    pub fn contains(self: CharClass, ch: u8) bool {
        for (self.ranges.items) |range| {
            if (ch >= range.start and ch <= range.end) {
                return !self.negated;
            }
        }
        return self.negated;
    }
};

pub const Parser = struct {
    tokenizer: Tokenizer,
    allocator: std.mem.Allocator,
    group_counter: usize,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
        return .{
            .tokenizer = Tokenizer.init(input),
            .allocator = allocator,
            .group_counter = 0,
        };
    }

    pub fn parse(self: *Parser) !?*AstNode {
        var node = try self.parseExpression();

        // 确保已经到达输入末尾
        const token = self.tokenizer.nextToken();
        if (token.type != .EOF) {
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

            _ = self.tokenizer.nextToken(); // 消费 '|'

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

        const token = self.tokenizer.peek();
        switch (token.type) {
            .Star => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Star,
                    .value = null,
                    .left = primary,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .Plus => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Plus,
                    .value = null,
                    .left = primary,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .Question => {
                _ = self.tokenizer.nextToken();
                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .type = .Question,
                    .value = null,
                    .left = primary,
                    .right = null,
                    .char_class = null,
                    .group_index = null,
                };
                return node;
            },
            .LBrace => {
                return try self.parseQuantifier(primary);
            },
            else => return primary,
        }
    }
    
    fn parseQuantifier(self: *Parser, primary: *AstNode) ParserError!?*AstNode {
        _ = self.tokenizer.nextToken(); // 消费 '{'
        
        // 解析最小值
        const min_token = self.tokenizer.nextToken();
        if (min_token.type != .Literal or min_token.value.len == 0 or !std.ascii.isDigit(min_token.value[0])) {
            return error.InvalidQuantifier;
        }
        const min = try std.fmt.parseInt(usize, min_token.value, 10);
        
        const next = self.tokenizer.peek();
        var max: ?usize = min;
        
        if (next.type == .Literal and next.value.len == 1 and next.value[0] == ',') {
            _ = self.tokenizer.nextToken(); // 消费 ','
            const after_comma = self.tokenizer.peek();
            if (after_comma.type == .RBrace) {
                // {n,} - 至少 n 次
                max = null;
            } else {
                // {n,m} - n 到 m 次
                const max_token = self.tokenizer.nextToken();
                if (max_token.type != .Literal or max_token.value.len == 0 or !std.ascii.isDigit(max_token.value[0])) {
                    return error.InvalidQuantifier;
                }
                max = try std.fmt.parseInt(usize, max_token.value, 10);
            }
        }
        
        _ = try self.tokenizer.expect(.RBrace);
        
        // 创建量词节点
        const node = try self.allocator.create(AstNode);
        node.* = .{
            .type = .Quantifier,
            .value = @intCast(min),
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

                // 处理转义序列的值
                var value: u8 = undefined;
                if (token.value.len == 2 and token.value[0] == '\\') {
                    value = switch (token.value[1]) {
                        't' => '\t',
                        'n' => '\n',
                        'r' => '\r',
                        '\\' => '\\',
                        else => token.value[1],
                    };
                } else {
                    value = token.value[0];
                }

                node.* = .{
                    .type = .Literal,
                    .value = value,
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
                    .value = @intCast(group_idx),
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
            else => return null,
        }
    }

    fn parseCharClass(self: *Parser) ParserError!?*AstNode {
        _ = self.tokenizer.expect(.LBracket) catch return error.InvalidCharClass;

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
                return error.UnterminatedCharClass;
            }

            _ = self.tokenizer.nextToken();

            var start: u8 = undefined;
            if (t.value.len == 2 and t.value[0] == '\\') {
                start = switch (t.value[1]) {
                    't' => '\t',
                    'n' => '\n',
                    'r' => '\r',
                    '\\' => '\\',
                    else => t.value[1],
                };
            } else {
                start = t.value[0];
            }

            // 检查是否是范围 (a-z)
            const next = self.tokenizer.peek();
            if (next.type == .Literal and next.value.len == 1 and next.value[0] == '-') {
                _ = self.tokenizer.nextToken(); // 消费 '-'

                const end_token = self.tokenizer.peek();
                if (end_token.type == .EOF or end_token.type == .RBracket) {
                    // '-' 在末尾，作为字面量
                    try cc.addRange(start, start);
                    try cc.addRange('-', '-');
                    continue;
                }

                _ = self.tokenizer.nextToken();
                var end: u8 = undefined;
                if (end_token.value.len == 2 and end_token.value[0] == '\\') {
                    end = switch (end_token.value[1]) {
                        't' => '\t',
                        'n' => '\n',
                        'r' => '\r',
                        '\\' => '\\',
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
        _ = self.tokenizer.nextToken(); // 消费 '('
        
        const next_token = self.tokenizer.peek();
        
        if (next_token.type == .Question) {
            _ = self.tokenizer.nextToken(); // 消费 '?'
            const special = self.tokenizer.nextToken();
            
            if (special.type == .Literal and special.value.len == 1) {
                switch (special.value[0]) {
                    ':' => {
                        // 非捕获组 (?:...)
                        const inner = try self.parseExpression() orelse {
                            return error.EmptyGroup;
                        };
                        _ = try self.tokenizer.expect(.RParen);
                        
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
                        // 正向前瞻 (?=...)
                        const inner = try self.parseExpression() orelse {
                            return error.EmptyGroup;
                        };
                        _ = try self.tokenizer.expect(.RParen);
                        
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
                        // 负向前瞻 (?!...)
                        const inner = try self.parseExpression() orelse {
                            return error.EmptyGroup;
                        };
                        _ = try self.tokenizer.expect(.RParen);
                        
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
                        // 检查是后顾断言 (?<=...), (?<!...) 还是命名捕获组 (?<name>...)
                        const next = self.tokenizer.peek();
                        if (next.type == .Literal and next.value.len == 1) {
                            if (next.value[0] == '=') {
                                // 正向后顾 (?<=...)
                                _ = self.tokenizer.nextToken(); // 消费 '='
                                const inner = try self.parseExpression() orelse {
                                    return error.EmptyGroup;
                                };
                                _ = try self.tokenizer.expect(.RParen);
                                
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
                                // 负向后顾 (?<!...)
                                _ = self.tokenizer.nextToken(); // 消费 '!'
                                const inner = try self.parseExpression() orelse {
                                    return error.EmptyGroup;
                                };
                                _ = try self.tokenizer.expect(.RParen);
                                
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
                        
                        // 命名捕获组 (?<name>...)
                        // 解析名称
                        var name_buf: [64]u8 = undefined;
                        var name_len: usize = 0;
                        
                        while (true) {
                            const ch_token = self.tokenizer.peek();
                            if (ch_token.type == .Literal and ch_token.value.len == 1) {
                                const ch = ch_token.value[0];
                                if (ch == '>') {
                                    _ = self.tokenizer.nextToken(); // 消费 '>'
                                    break;
                                }
                                if (name_len < name_buf.len) {
                                    name_buf[name_len] = ch;
                                    name_len += 1;
                                    _ = self.tokenizer.nextToken();
                                } else {
                                    return error.UnexpectedToken;
                                }
                            } else {
                                return error.UnexpectedToken;
                            }
                        }
                        
                        const name = try self.allocator.dupe(u8, name_buf[0..name_len]);
                        defer self.allocator.free(name);
                        
                        self.group_counter += 1;
                        const group_index = self.group_counter;
                        
                        const inner = try self.parseExpression() orelse {
                            return error.EmptyGroup;
                        };
                        
                        _ = try self.tokenizer.expect(.RParen);
                        
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
                    },
                    else => return error.UnexpectedToken,
                }
            } else {
                return error.UnexpectedToken;
            }
        } else {
            // 普通捕获组
            self.group_counter += 1;
            const group_index = self.group_counter;
            
            const inner = try self.parseExpression() orelse {
                return error.EmptyGroup;
            };
            
            _ = try self.tokenizer.expect(.RParen);
            
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
};

pub const ParserError = error{
    UnexpectedToken,
    EmptyGroup,
    EmptyAlternative,
    InvalidCharClass,
    UnterminatedCharClass,
    InvalidQuantifier,
    InvalidCharacter,
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
