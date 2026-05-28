const std = @import("std");

pub const TokenType = enum {
    // Literal character
    Literal,
    
    // Metacharacters
    Dot,           // .
    Star,          // *
    Plus,          // +
    Question,      // ?
    Pipe,          // |
    
    // Grouping
    LParen,        // (
    RParen,        // )
    
    // Anchors
    Caret,         // ^
    Dollar,        // $
    AssertStringStart,       // \A
    AssertStringEnd,         // \z
    AssertStringEndAllowNewline, // \Z
    AssertMatchStart,        // \G
    
    // Escape sequences
    Backslash,     // \
    
    // Special character classes
    Digit,         // \d
    NotDigit,      // \D
    Word,          // \w
    NotWord,       // \W
    Whitespace,    // \s
    NotWhitespace, // \S
    HorizontalWhitespace,    // \h
    NotHorizontalWhitespace, // \H
    
    // Word boundaries
    WordBoundary,     // \b
    NotWordBoundary,  // \B
    
    // Backreferences
    Backref,       // \1, \2, ...
    NamedBackref,  // \g<name>, \k<name>
    
    // Unicode properties
    UnicodeProperty,     // \p{...}
    NotUnicodeProperty,  // \P{...}
    
    // Quantifiers
    LBrace,        // {
    RBrace,        // }
    Comma,         // ,
    
    // Character classes
    LBracket,      // [
    RBracket,      // ]
    
    // Grapheme cluster
    GraphemeCluster,  // \X

    // Newline sequence
    Newline,          // \R

    // Reset match start
    ResetMatchStart,  // \K

    // Not newline
    NotNewline,       // \N

    // Not vertical whitespace
    NotVerticalWhitespace, // \V

    // Other
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
    literal_quote_mode: bool,
    free_spacing: bool,
    char_class_depth: usize,

    pub fn init(input: []const u8) Tokenizer {
        return .{
            .input = input,
            .position = 0,
            .literal_quote_mode = false,
            .free_spacing = false,
            .char_class_depth = 0,
        };
    }

    fn makeToken(self: *Tokenizer, token_type: TokenType, start_pos: usize) Token {
        return .{
            .type = token_type,
            .value = self.input[start_pos..self.position],
            .position = start_pos,
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

        // In literal quote mode, all characters are literals until \E
        if (self.literal_quote_mode) {
            const ch = self.input[self.position];
            self.position += 1;

            // Check for \E to end quote mode
            if (ch == '\\' and self.position < self.input.len and self.input[self.position] == 'E') {
                self.literal_quote_mode = false;
                self.position += 1;
                return self.nextToken();
            }

            return .{
                .type = .Literal,
                .value = self.input[self.position - 1..self.position],
                .position = self.position - 1,
            };
        }

        // In free-spacing mode, skip whitespace and comments outside character classes
        if (self.free_spacing and self.char_class_depth == 0) {
            while (self.position < self.input.len) {
                const c = self.input[self.position];
                if (std.ascii.isWhitespace(c)) {
                    self.position += 1;
                    continue;
                }
                if (c == '#') {
                    // Skip comment to end of line
                    while (self.position < self.input.len and self.input[self.position] != '\n') {
                        self.position += 1;
                    }
                    continue;
                }
                break;
            }
        }

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

        // Process escape sequences
        if (ch == '\\' and self.position < self.input.len) {
            const next_ch = self.input[self.position];

                // Hex escape: \xNN or \x{hhhh}
                if (next_ch == 'x') {
                    if (self.position + 1 < self.input.len and self.input[self.position + 1] == '{') {
                        // \x{hhhh} format
                        var hex_end = self.position + 2;
                        while (hex_end < self.input.len and std.ascii.isHex(self.input[hex_end])) {
                            hex_end += 1;
                        }
                        if (hex_end < self.input.len and self.input[hex_end] == '}' and hex_end > self.position + 2) {
                            self.position = hex_end + 1;
                            return .{
                                .type = .Literal,
                                .value = self.input[start_pos..self.position],
                                .position = start_pos,
                            };
                        }
                        return .{ .type = .Invalid, .value = self.input[start_pos..self.position + 1], .position = start_pos };
                    }
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

            // Unicode escape: \uNNNN or \u{hhhh}
            if (next_ch == 'u') {
                if (self.position + 1 < self.input.len and self.input[self.position + 1] == '{') {
                    // \u{hhhh} format
                    var hex_end = self.position + 2;
                    while (hex_end < self.input.len and std.ascii.isHex(self.input[hex_end])) {
                        hex_end += 1;
                    }
                    if (hex_end < self.input.len and self.input[hex_end] == '}' and hex_end > self.position + 2) {
                        self.position = hex_end + 1;
                        return .{
                            .type = .Literal,
                            .value = self.input[start_pos..self.position],
                            .position = start_pos,
                        };
                    }
                    return .{ .type = .Invalid, .value = self.input[start_pos..self.position + 1], .position = start_pos };
                }
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

            // Control character: \cX where X is any character
            if (next_ch == 'c' and self.position < self.input.len) {
                self.position += 1; // consume control character
                return .{
                    .type = .Literal,
                    .value = self.input[start_pos..self.position],
                    .position = start_pos,
                };
            }

            // Null character: \0
            if (next_ch == '0') {
                return .{
                    .type = .Literal,
                    .value = self.input[start_pos..self.position],
                    .position = start_pos,
                };
            }

            // Octal escape: \o{NNN}
            if (next_ch == 'o') {
                if (self.position < self.input.len and self.input[self.position] == '{') {
                    const oct_start = self.position + 1;
                    var oct_end = oct_start;
                    while (oct_end < self.input.len and std.ascii.isDigit(self.input[oct_end]) and self.input[oct_end] < '8') {
                        oct_end += 1;
                    }
                    if (oct_end < self.input.len and self.input[oct_end] == '}' and oct_end > oct_start) {
                        self.position = oct_end + 1;
                        return .{
                            .type = .Literal,
                            .value = self.input[start_pos..self.position],
                            .position = start_pos,
                        };
                    }
                }
                return .{ .type = .Invalid, .value = self.input[start_pos..self.position + 1], .position = start_pos };
            }

            // Unicode named escape: \N{U+HHHH} or \N{U+HHHHHH}
            if (next_ch == 'N') {
                if (self.position < self.input.len and self.input[self.position] == '{') {
                    const name_start = self.position + 1;
                    var name_end = name_start;
                    while (name_end < self.input.len and self.input[name_end] != '}') {
                        name_end += 1;
                    }
                    if (name_end < self.input.len and self.input[name_end] == '}' and name_end > name_start) {
                        const name = self.input[name_start..name_end];
                        if (name.len >= 3 and name[0] == 'U' and name[1] == '+') {
                            const hex = name[2..];
                            var valid_hex = true;
                            for (hex) |h| {
                                if (!std.ascii.isHex(h)) {
                                    valid_hex = false;
                                    break;
                                }
                            }
                            if (valid_hex) {
                                self.position = name_end + 1;
                                return .{
                                    .type = .Literal,
                                    .value = self.input[start_pos..self.position],
                                    .position = start_pos,
                                };
                            }
                        }
                    }
                }
                // Not a \N{U+...} escape: treat as \N (not newline)
                return .{ .type = .NotNewline, .value = self.input[start_pos..self.position], .position = start_pos };
            }

            // Unicode property: \p{...} or \P{...}
            if (next_ch == 'p' or next_ch == 'P') {
                if (self.position < self.input.len and self.input[self.position] == '{') {
                    const prop_start = self.position + 1;
                    var prop_end = prop_start;
                    while (prop_end < self.input.len and self.input[prop_end] != '}') {
                        prop_end += 1;
                    }
                    if (prop_end < self.input.len and self.input[prop_end] == '}') {
                        self.position = prop_end + 1;
                        return .{
                            .type = if (next_ch == 'p') .UnicodeProperty else .NotUnicodeProperty,
                            .value = self.input[start_pos..self.position],
                            .position = start_pos,
                        };
                    }
                }
            }

            // Named backreference: \g<name>, \k<name>, \g{-1}, \g{+1}, \g{name}
            if (next_ch == 'g' or next_ch == 'k') {
                if (self.position < self.input.len and self.input[self.position] == '<') {
                    const name_start = self.position + 1;
                    var name_end = name_start;
                    while (name_end < self.input.len and self.input[name_end] != '>') {
                        name_end += 1;
                    }
                    if (name_end < self.input.len and self.input[name_end] == '>' and name_end > name_start) {
                        self.position = name_end + 1;
                        return .{
                            .type = .NamedBackref,
                            .value = self.input[start_pos..self.position],
                            .position = start_pos,
                        };
                    }
                } else if (self.position < self.input.len and self.input[self.position] == '{') {
                    // \g{...} format (relative/absolute numeric or braced name)
                    const content_start = self.position + 1;
                    var content_end = content_start;
                    while (content_end < self.input.len and self.input[content_end] != '}') {
                        content_end += 1;
                    }
                    if (content_end < self.input.len and self.input[content_end] == '}' and content_end > content_start) {
                        self.position = content_end + 1;
                        return .{
                            .type = .NamedBackref,
                            .value = self.input[start_pos..self.position],
                            .position = start_pos,
                        };
                    }
                }
            }

            // Grapheme cluster: \X
            if (next_ch == 'X') {
                return .{
                    .type = .GraphemeCluster,
                    .value = self.input[start_pos..self.position],
                    .position = start_pos,
                };
            }

            // Literal quote: \Q
            if (next_ch == 'Q') {
                self.literal_quote_mode = true;
                return self.nextToken();
            }

            const token_type: TokenType = switch (next_ch) {
                'd' => .Digit,
                'D' => .NotDigit,
                'w' => .Word,
                'W' => .NotWord,
                's' => .Whitespace,
                'S' => .NotWhitespace,
                'h' => .HorizontalWhitespace,
                'H' => .NotHorizontalWhitespace,
                'b' => .WordBoundary,
                'B' => .NotWordBoundary,
                'A' => .AssertStringStart,
                'z' => .AssertStringEnd,
                'Z' => .AssertStringEndAllowNewline,
                'G' => .AssertMatchStart,
                'R' => .Newline,
                'K' => .ResetMatchStart,
                'N' => .NotNewline,
                'V' => .NotVerticalWhitespace,
                't', 'n', 'r', 'a', 'e', 'f', 'v', '0', 'c' => .Literal,
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
            // ',' is a literal in regex (only has special meaning in quantifier {n,m})
            '[' => blk: {
                self.char_class_depth += 1;
                break :blk .LBracket;
            },
            ']' => blk: {
                if (self.char_class_depth > 0) {
                    self.char_class_depth -= 1;
                }
                break :blk .RBracket;
            },
            else => .Literal,
        };

        // For multi-byte UTF-8 literal characters, advance to the end of the character
        if (token_type == .Literal and ch >= 128) {
            if (std.unicode.utf8ByteSequenceLength(ch)) |len| {
                if (start_pos + len <= self.input.len) {
                    self.position = start_pos + len;
                }
            } else |_| {
                // Invalid UTF-8, keep as single byte
            }
        }

        return .{
            .type = token_type,
            .value = self.input[start_pos..self.position],
            .position = start_pos,
        };
    }
    
    pub fn peek(self: *Tokenizer) Token {
        const saved_pos = self.position;
        const saved_quote_mode = self.literal_quote_mode;
        const token = self.nextToken();
        self.position = saved_pos;
        self.literal_quote_mode = saved_quote_mode;
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

// Error types
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

test "tokenizer literal quote" {
    var tokenizer = Tokenizer.init("\\Qa.b*c\\E+");
    
    const t1 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t1.type);
    try std.testing.expectEqualStrings("a", t1.value);
    
    const t2 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t2.type);
    try std.testing.expectEqualStrings(".", t2.value);
    
    const t3 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t3.type);
    try std.testing.expectEqualStrings("b", t3.value);
    
    const t4 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t4.type);
    try std.testing.expectEqualStrings("*", t4.value);
    
    const t5 = tokenizer.nextToken();
    try std.testing.expectEqual(.Literal, t5.type);
    try std.testing.expectEqualStrings("c", t5.value);
    
    const t6 = tokenizer.nextToken();
    try std.testing.expectEqual(.Plus, t6.type);
}

test "tokenizer literal quote with empty content" {
    var tokenizer = Tokenizer.init("\\Q\\E+");
    
    const t1 = tokenizer.nextToken();
    try std.testing.expectEqual(.Plus, t1.type);
}
