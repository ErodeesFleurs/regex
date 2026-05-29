const std = @import("std");
const regex = @import("../root.zig");
const h = @import("helpers.zig");

test "unicode property: \\p{L} letter" {
    try h.expectMatch("\\p{L}", "a");
    try h.expectMatch("\\p{L}", "A");
    try h.expectNoMatch("\\p{L}", "1");
    try h.expectNoMatch("\\p{L}", "!");
    try h.expectNoMatch("\\p{L}", " ");
}

test "unicode property: \\p{Lu} uppercase" {
    try h.expectMatch("\\p{Lu}", "A");
    try h.expectNoMatch("\\p{Lu}", "a");
    try h.expectNoMatch("\\p{Lu}", "1");
}

test "unicode property: \\p{Ll} lowercase" {
    try h.expectMatch("\\p{Ll}", "a");
    try h.expectNoMatch("\\p{Ll}", "A");
    try h.expectNoMatch("\\p{Ll}", "1");
}

test "unicode property: \\p{N} number" {
    try h.expectMatch("\\p{N}", "0");
    try h.expectMatch("\\p{N}", "9");
    try h.expectNoMatch("\\p{N}", "a");
    try h.expectNoMatch("\\p{N}", " ");
}

test "unicode property: \\p{Nd} decimal digit" {
    try h.expectMatch("\\p{Nd}", "5");
    try h.expectNoMatch("\\p{Nd}", "a");
}

test "unicode property: \\p{P} punctuation" {
    try h.expectMatch("\\p{P}", "!");
    try h.expectMatch("\\p{P}", ",");
    try h.expectMatch("\\p{P}", ".");
    try h.expectNoMatch("\\p{P}", "a");
    try h.expectNoMatch("\\p{P}", "1");
}

test "unicode property: \\p{Ps} open punctuation" {
    try h.expectMatch("\\p{Ps}", "(");
    try h.expectMatch("\\p{Ps}", "[");
    try h.expectNoMatch("\\p{Ps}", ")");
}

test "unicode property: \\p{Pe} close punctuation" {
    try h.expectMatch("\\p{Pe}", ")");
    try h.expectMatch("\\p{Pe}", "]");
    try h.expectNoMatch("\\p{Pe}", "(");
}

test "unicode property: \\p{Z} separator" {
    try h.expectMatch("\\p{Z}", " ");
    try h.expectNoMatch("\\p{Z}", "a");
}

test "unicode property: \\p{C} control/format" {
    try h.expectMatch("\\p{Cc}", "\x01");
    try h.expectMatch("\\p{Cc}", "\x7F");
    try h.expectNoMatch("\\p{Cc}", "a");
}

test "unicode property: \\p{Sc} currency symbol" {
    try h.expectMatch("\\p{Sc}", "$");
    try h.expectMatch("\\p{Sc}", "\u{00A3}");
    try h.expectNoMatch("\\p{Sc}", "a");
}

test "unicode property: \\p{Sm} math symbol" {
    try h.expectMatch("\\p{Sm}", "+");
    try h.expectMatch("\\p{Sm}", "=");
    try h.expectNoMatch("\\p{Sm}", "a");
}

test "unicode property: \\p{Han} CJK" {
    try h.expectMatch("\\p{Han}", "中");
    try h.expectMatch("\\p{Han}", "文");
    try h.expectNoMatch("\\p{Han}", "a");
    try h.expectNoMatch("\\p{Han}", "1");
}

test "unicode property: \\p{Latin}" {
    try h.expectMatch("\\p{Latin}", "a");
    try h.expectMatch("\\p{Latin}", "Z");
    try h.expectNoMatch("\\p{Latin}", "中");
    try h.expectNoMatch("\\p{Latin}", "1");
}

test "unicode property: \\P{L} not letter" {
    try h.expectNoMatch("\\P{L}", "a");
    try h.expectNoMatch("\\P{L}", "A");
    try h.expectMatch("\\P{L}", "1");
    try h.expectMatch("\\P{L}", "!");
}

test "unicode property: quantifier" {
    try h.expectMatch("\\p{L}+", "abc");
    try h.expectMatch("\\p{N}+", "123");
    try h.expectNoMatch("\\p{L}+", "123");
}

test "unicode property: alternation" {
    try h.expectMatch("\\p{L}|\\p{N}", "a");
    try h.expectMatch("\\p{L}|\\p{N}", "1");
}

test "unicode property: \\p{Greek}" {
    try h.expectMatch("\\p{Greek}", "α");
    try h.expectMatch("\\p{Greek}", "Ω");
    try h.expectNoMatch("\\p{Greek}", "a");
    try h.expectNoMatch("\\p{Greek}", "1");
}

test "unicode property: \\p{Cyrillic}" {
    try h.expectMatch("\\p{Cyrillic}", "а");
    try h.expectMatch("\\p{Cyrillic}", "Я");
    try h.expectNoMatch("\\p{Cyrillic}", "a");
    try h.expectNoMatch("\\p{Cyrillic}", "1");
}

test "unicode property: \\p{Arabic}" {
    try h.expectMatch("\\p{Arabic}", "ا");
    try h.expectMatch("\\p{Arabic}", "ب");
    try h.expectNoMatch("\\p{Arabic}", "a");
    try h.expectNoMatch("\\p{Arabic}", "1");
}

test "unicode property: \\p{Hebrew}" {
    try h.expectMatch("\\p{Hebrew}", "א");
    try h.expectMatch("\\p{Hebrew}", "ת");
    try h.expectNoMatch("\\p{Hebrew}", "a");
    try h.expectNoMatch("\\p{Hebrew}", "1");
}

test "unicode property: \\p{Armenian}" {
    try h.expectMatch("\\p{Armenian}", "Ա");
    try h.expectMatch("\\p{Armenian}", "ֆ");
    try h.expectNoMatch("\\p{Armenian}", "a");
    try h.expectNoMatch("\\p{Armenian}", "1");
}

test "unicode property: \\p{Georgian}" {
    try h.expectMatch("\\p{Georgian}", "ა");
    try h.expectMatch("\\p{Georgian}", "ჰ");
    try h.expectNoMatch("\\p{Georgian}", "a");
    try h.expectNoMatch("\\p{Georgian}", "1");
}

test "unicode property: \\p{Thai}" {
    try h.expectMatch("\\p{Thai}", "ก");
    try h.expectMatch("\\p{Thai}", "ฮ");
    try h.expectNoMatch("\\p{Thai}", "a");
    try h.expectNoMatch("\\p{Thai}", "1");
}

test "unicode property: \\p{Devanagari}" {
    try h.expectMatch("\\p{Devanagari}", "अ");
    try h.expectMatch("\\p{Devanagari}", "ह");
    try h.expectNoMatch("\\p{Devanagari}", "a");
    try h.expectNoMatch("\\p{Devanagari}", "1");
}

test "unicode property: \\p{Hiragana}" {
    try h.expectMatch("\\p{Hiragana}", "あ");
    try h.expectMatch("\\p{Hiragana}", "ん");
    try h.expectNoMatch("\\p{Hiragana}", "a");
    try h.expectNoMatch("\\p{Hiragana}", "1");
}

test "unicode property: \\p{Katakana}" {
    try h.expectMatch("\\p{Katakana}", "ア");
    try h.expectMatch("\\p{Katakana}", "ン");
    try h.expectNoMatch("\\p{Katakana}", "a");
    try h.expectNoMatch("\\p{Katakana}", "1");
}

test "unicode property: \\p{Hangul}" {
    try h.expectMatch("\\p{Hangul}", "가");
    try h.expectMatch("\\p{Hangul}", "힣");
    try h.expectNoMatch("\\p{Hangul}", "a");
    try h.expectNoMatch("\\p{Hangul}", "1");
}

test "unicode property in char class: \\p{L}" {
    try h.expectMatch("[\\p{L}]", "a");
    try h.expectMatch("[\\p{L}]", "A");
    try h.expectMatch("[\\p{L}]", "中");
    try h.expectNoMatch("[\\p{L}]", "1");
    try h.expectNoMatch("[\\p{L}]", "!");
}

test "unicode property in char class: \\p{N} and \\p{L}" {
    try h.expectMatch("[\\p{L}\\p{N}]", "a");
    try h.expectMatch("[\\p{L}\\p{N}]", "5");
    try h.expectMatch("[\\p{L}\\p{N}]", "中");
    try h.expectNoMatch("[\\p{L}\\p{N}]", "!");
}

test "unicode property in char class: negated class" {
    try h.expectNoMatch("[^\\p{L}]", "a");
    try h.expectNoMatch("[^\\p{L}]", "中");
    try h.expectMatch("[^\\p{L}]", "1");
    try h.expectMatch("[^\\p{L}]", "!");
}

test "unicode property in char class: \\P{L} (negated property)" {
    try h.expectNoMatch("[\\P{L}]", "a");
    try h.expectNoMatch("[\\P{L}]", "中");
    try h.expectMatch("[\\P{L}]", "1");
    try h.expectMatch("[\\P{L}]", "!");
}

test "unicode property in char class: mixed with ranges" {
    try h.expectMatch("[a-z\\p{L}]", "a");
    try h.expectMatch("[a-z\\p{L}]", "中");
    try h.expectNoMatch("[a-z\\p{L}]", "1");
}

test "unicode property in char class: \\p{Han}" {
    try h.expectMatch("[\\p{Han}]", "中");
    try h.expectMatch("[\\p{Han}]", "文");
    try h.expectNoMatch("[\\p{Han}]", "a");
    try h.expectNoMatch("[\\p{Han}]", "1");
}
