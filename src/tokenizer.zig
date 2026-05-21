const std = @import("std");

pub const TokenType = enum {
    // 字面量字符
    Literal,
    
    // 元字符
    Dot,           // .
    Star,          // *
    Plus,          // +
    Question,      // ?
    Pipe,          // |
    
    // 分组
    LParen,        // (
    RParen,        // )
    
    // 锚点
    Caret,         // ^
    Dollar,        // $
    AssertStringStart,       // \A
    AssertStringEnd,         // \z
    AssertStringEndAllowNewline, // \Z
    
    // 转义序列
    Backslash,     // \
    
    // 特殊字符类
    Digit,         // \d
    NotDigit,      // \D
    Word,          // \w
    NotWord,       // \W
    Whitespace,    // \s
    NotWhitespace, // \S
    
    // 单词边界
    WordBoundary,     // \b
    NotWordBoundary,  // \B
    
    // 反向引用
    Backref,       // \1, \2, ...
    
    // 量词
    LBrace,        // {
    RBrace,        // }
    Comma,         // ,
    
    // 字符类
    LBracket,      // [
    RBracket,      // ]
    
    // 其他
    EOF,
    Invalid,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    position: usize,
    
    pub fn format(self: Token, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("Token{{ .type = {s}, .value = \"{s}\", .position = {} }}", .{
            @tagName(self.type),
            self.value,
            self.position,
        });
    }
};

pub const Tokenizer = struct {
    input: []const u8,
    position: usize,
    
    pub fn init(input: []const u8) Tokenizer {
        return .{
            .input = input,
            .position = 0,
        };
    }
    
    pub fn nextToken(self: *Tokenizer) Token {
        if (self.position >= self.input.len) {
            return .{
                .type = .EOF,
                .value = "",
                .position = self.position,
            };
        }
        
        const start_pos = self.position;
        const ch = self.input[self.position];
        self.position += 1;
        
        // 处理转义序列
        if (ch == '\\' and self.position < self.input.len) {
            const next_ch = self.input[self.position];

                // 十六进制转义: \xNN
                if (next_ch == 'x') {
                    if (self.position + 2 < self.input.len and
                        std.ascii.isHex(self.input[self.position + 1]) and
                        std.ascii.isHex(self.input[self.position + 2]))
                {
                    self.position += 3;
                    return .{
                        .type = .Literal,
                        .value = self.input[start_pos..self.position],
                        .position = start_pos,
                    };
                }
                return .{ .type = .Invalid, .value = self.input[start_pos..self.position + 1], .position = start_pos };
            }

            // Unicode 转义: \uNNNN
            if (next_ch == 'u') {
                    if (self.position + 4 < self.input.len and
                    std.ascii.isHex(self.input[self.position + 1]) and
                    std.ascii.isHex(self.input[self.position + 2]) and
                    std.ascii.isHex(self.input[self.position + 3]) and
                    std.ascii.isHex(self.input[self.position + 4]))
                {
                    self.position += 5;
                    return .{
                        .type = .Literal,
                        .value = self.input[start_pos..self.position],
                        .position = start_pos,
                    };
                }
                return .{ .type = .Invalid, .value = self.input[start_pos..self.position + 1], .position = start_pos };
            }

            self.position += 1;

            const token_type: TokenType = switch (next_ch) {
                'd' => .Digit,
                'D' => .NotDigit,
                'w' => .Word,
                'W' => .NotWord,
                's' => .Whitespace,
                'S' => .NotWhitespace,
                'b' => .WordBoundary,
                'B' => .NotWordBoundary,
                'A' => .AssertStringStart,
                'z' => .AssertStringEnd,
                'Z' => .AssertStringEndAllowNewline,
                't' => .Literal,
                'n' => .Literal,
                'r' => .Literal,
                '\\' => .Literal,
                '.', '*', '+', '?', '|', '(', ')', '[', ']', '{', '}', '^', '$' => .Literal,
                '1'...'9' => .Backref,
                else => .Invalid,
            };

            return .{
                .type = token_type,
                .value = self.input[start_pos..self.position],
                .position = start_pos,
            };
        }
        
        const token_type: TokenType = switch (ch) {
            '.' => .Dot,
            '*' => .Star,
            '+' => .Plus,
            '?' => .Question,
            '|' => .Pipe,
            '(' => .LParen,
            ')' => .RParen,
            '^' => .Caret,
            '$' => .Dollar,
            '\\' => .Backslash,
            '{' => .LBrace,
            '}' => .RBrace,
            // ',' 在正则表达式中是字面量（仅在量词 {n,m} 中有特殊含义）
            '[' => .LBracket,
            ']' => .RBracket,
            else => .Literal,
        };
        
        return .{
            .type = token_type,
            .value = self.input[start_pos..self.position],
            .position = start_pos,
        };
    }
    
    pub fn peek(self: *Tokenizer) Token {
        const saved_pos = self.position;
        const token = self.nextToken();
        self.position = saved_pos;
        return token;
    }
    
    pub fn expect(self: *Tokenizer, expected: TokenType) !Token {
        const token = self.nextToken();
        if (token.type != expected) {
            return error.UnexpectedToken;
        }
        return token;
    }
};

// 错误类型
pub const TokenizerError = error{
    UnexpectedToken,
    InvalidEscapeSequence,
    UnterminatedGroup,
};

test "tokenizer basic" {
    var tokenizer = Tokenizer.init("a*b|c");
    
    const t1 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t1.type);
    try std.testing.expectEqualStrings("a", t1.value);
    
    const t2 = tokenizer.nextToken();
    try std.testing.expectEqual(.Star, t2.type);
    
    const t3 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t3.type);
    try std.testing.expectEqualStrings("b", t3.value);
    
    const t4 = tokenizer.nextToken();
    try std.testing.expectEqual(.Pipe, t4.type);
    
    const t5 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t5.type);
    try std.testing.expectEqualStrings("c", t5.value);
    
    const t6 = tokenizer.nextToken();
    try std.testing.expectEqual(.EOF, t6.type);
}

test "tokenizer escape sequences" {
    var tokenizer = Tokenizer.init("\\d\\w\\s");
    
    const t1 = tokenizer.nextToken();
    try std.testing.expectEqual(.Digit, t1.type);
    
    const t2 = tokenizer.nextToken();
    try std.testing.expectEqual(.Word, t2.type);
    
    const t3 = tokenizer.nextToken();
    try std.testing.expectEqual(.Whitespace, t3.type);
}

test "tokenizer special chars as literals" {
    var tokenizer = Tokenizer.init("\\.\\*\\+");
    
    const t1 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t1.type);
    try std.testing.expectEqualStrings("\\.", t1.value);
    
    const t2 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t2.type);
    try std.testing.expectEqualStrings("\\*", t2.value);
}
