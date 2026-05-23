const std = @import("std");
const regex = @import("../root.zig");

test "unicode property: \\p{L} letter" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{L}", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{L}", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{L}", "1"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{L}", "!"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{L}", " "));
}

test "unicode property: \\p{Lu} uppercase" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Lu}", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Lu}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Lu}", "1"));
}

test "unicode property: \\p{Ll} lowercase" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Ll}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Ll}", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Ll}", "1"));
}

test "unicode property: \\p{N} number" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{N}", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{N}", "9"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{N}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{N}", " "));
}

test "unicode property: \\p{Nd} decimal digit" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Nd}", "5"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Nd}", "a"));
}

test "unicode property: \\p{P} punctuation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{P}", "!"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{P}", ","));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{P}", "."));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{P}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{P}", "1"));
}

test "unicode property: \\p{Ps} open punctuation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Ps}", "("));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Ps}", "["));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Ps}", ")"));
}

test "unicode property: \\p{Pe} close punctuation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Pe}", ")"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Pe}", "]"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Pe}", "("));
}

test "unicode property: \\p{Z} separator" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Z}", " "));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Z}", "a"));
}

test "unicode property: \\p{C} control/format" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Cc}", "\x01"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Cc}", "\x7F"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Cc}", "a"));
}

test "unicode property: \\p{Sc} currency symbol" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Sc}", "$"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Sc}", "\u{00A3}"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Sc}", "a"));
}

test "unicode property: \\p{Sm} math symbol" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Sm}", "+"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Sm}", "="));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Sm}", "a"));
}

test "unicode property: \\p{Han} CJK" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Han}", "中"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Han}", "文"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Han}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Han}", "1"));
}

test "unicode property: \\p{Latin}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Latin}", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Latin}", "Z"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Latin}", "中"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Latin}", "1"));
}

test "unicode property: \\P{L} not letter" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "\\P{L}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\P{L}", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "\\P{L}", "1"));
    try std.testing.expect(try regex.isMatch(allocator, "\\P{L}", "!"));
}

test "unicode property: quantifier" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{L}+", "abc"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{N}+", "123"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{L}+", "123"));
}

test "unicode property: alternation" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{L}|\\p{N}", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{L}|\\p{N}", "1"));
}

test "unicode property: \\p{Greek}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Greek}", "α"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Greek}", "Ω"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Greek}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Greek}", "1"));
}

test "unicode property: \\p{Cyrillic}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Cyrillic}", "а"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Cyrillic}", "Я"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Cyrillic}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Cyrillic}", "1"));
}

test "unicode property: \\p{Arabic}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Arabic}", "ا"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Arabic}", "ب"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Arabic}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Arabic}", "1"));
}

test "unicode property: \\p{Hebrew}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Hebrew}", "א"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Hebrew}", "ת"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Hebrew}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Hebrew}", "1"));
}

test "unicode property: \\p{Armenian}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Armenian}", "Ա"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Armenian}", "ֆ"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Armenian}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Armenian}", "1"));
}

test "unicode property: \\p{Georgian}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Georgian}", "ა"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Georgian}", "ჰ"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Georgian}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Georgian}", "1"));
}

test "unicode property: \\p{Thai}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Thai}", "ก"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Thai}", "ฮ"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Thai}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Thai}", "1"));
}

test "unicode property: \\p{Devanagari}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Devanagari}", "अ"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Devanagari}", "ह"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Devanagari}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Devanagari}", "1"));
}

test "unicode property: \\p{Hiragana}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Hiragana}", "あ"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Hiragana}", "ん"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Hiragana}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Hiragana}", "1"));
}

test "unicode property: \\p{Katakana}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Katakana}", "ア"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Katakana}", "ン"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Katakana}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Katakana}", "1"));
}

test "unicode property: \\p{Hangul}" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Hangul}", "가"));
    try std.testing.expect(try regex.isMatch(allocator, "\\p{Hangul}", "힣"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Hangul}", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\p{Hangul}", "1"));
}
