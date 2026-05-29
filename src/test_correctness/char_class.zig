const std = @import("std");
const regex = @import("../root.zig");
const h = @import("helpers.zig");

// Henry Spencer / POSIX / PCRE-inspired character class correctness tests.

test "char class: simple range [a-z]" {
    try h.expectMatch("[a-z]", "a");
    try h.expectMatch("[a-z]", "m");
    try h.expectMatch("[a-z]", "z");
    try h.expectNoMatch("[a-z]", "A");
    try h.expectNoMatch("[a-z]", "0");
}

test "char class: uppercase range [A-Z]" {
    try h.expectMatch("[A-Z]", "A");
    try h.expectMatch("[A-Z]", "M");
    try h.expectMatch("[A-Z]", "Z");
    try h.expectNoMatch("[A-Z]", "a");
}

test "char class: digit range [0-9]" {
    try h.expectMatch("[0-9]", "0");
    try h.expectMatch("[0-9]", "5");
    try h.expectMatch("[0-9]", "9");
    try h.expectNoMatch("[0-9]", "a");
}

test "char class: negated [^a-z]" {
    try h.expectNoMatch("[^a-z]", "a");
    try h.expectNoMatch("[^a-z]", "z");
    try h.expectMatch("[^a-z]", "A");
    try h.expectMatch("[^a-z]", "0");
    try h.expectMatch("[^a-z]", "!");
}

test "char class: multiple ranges" {
    try h.expectMatch("[a-zA-Z]", "a");
    try h.expectMatch("[a-zA-Z]", "Z");
    try h.expectNoMatch("[a-zA-Z]", "0");
}

test "char class: shorthand \\d" {
    try h.expectMatch("\\d", "0");
    try h.expectMatch("\\d", "9");
    try h.expectNoMatch("\\d", "a");
}

test "char class: shorthand \\D" {
    try h.expectNoMatch("\\D", "0");
    try h.expectMatch("\\D", "a");
    try h.expectMatch("\\D", "!");
}

test "char class: shorthand \\w" {
    try h.expectMatch("\\w", "a");
    try h.expectMatch("\\w", "Z");
    try h.expectMatch("\\w", "0");
    try h.expectMatch("\\w", "_");
    try h.expectNoMatch("\\w", "!");
    try h.expectNoMatch("\\w", " ");
}

test "char class: shorthand \\W" {
    try h.expectNoMatch("\\W", "a");
    try h.expectNoMatch("\\W", "_");
    try h.expectMatch("\\W", "!");
    try h.expectMatch("\\W", " ");
}

test "char class: shorthand \\s" {
    try h.expectMatch("\\s", " ");
    try h.expectMatch("\\s", "\t");
    try h.expectMatch("\\s", "\n");
    try h.expectNoMatch("\\s", "a");
}

test "char class: shorthand \\S" {
    try h.expectNoMatch("\\S", " ");
    try h.expectMatch("\\S", "a");
}

test "char class: single char class" {
    try h.expectMatch("[abc]", "a");
    try h.expectMatch("[abc]", "b");
    try h.expectMatch("[abc]", "c");
    try h.expectNoMatch("[abc]", "d");
}

test "char class: hyphen at end" {
    try h.expectMatch("[abc-]", "-");
    try h.expectMatch("[abc-]", "a");
    try h.expectNoMatch("[abc-]", "d");
}

test "char class: dot inside class" {
    try h.expectMatch("[.]", ".");
    try h.expectNoMatch("[.]", "a");
}

test "char class: shorthand inside class" {
    try h.expectMatch("[\\d]", "5");
    try h.expectNoMatch("[\\d]", "a");
    try h.expectMatch("[\\w]", "_");
    try h.expectNoMatch("[\\w]", "!");
    try h.expectMatch("[\\s]", "\t");
    try h.expectNoMatch("[\\s]", "a");
}

test "char class: negated shorthand inside class" {
    try h.expectNoMatch("[\\D]", "5");
    try h.expectMatch("[\\D]", "a");
}

test "char class: POSIX [[:alpha:]]" {
    try h.expectMatch("[[:alpha:]]", "a");
    try h.expectMatch("[[:alpha:]]", "Z");
    try h.expectNoMatch("[[:alpha:]]", "5");
    try h.expectNoMatch("[[:alpha:]]", " ");
}

test "char class: POSIX [[:digit:]]" {
    try h.expectMatch("[[:digit:]]", "0");
    try h.expectMatch("[[:digit:]]", "9");
    try h.expectNoMatch("[[:digit:]]", "a");
}

test "char class: POSIX [[:alnum:]]" {
    try h.expectMatch("[[:alnum:]]", "a");
    try h.expectMatch("[[:alnum:]]", "5");
    try h.expectNoMatch("[[:alnum:]]", " ");
}

test "char class: POSIX [[:space:]]" {
    try h.expectMatch("[[:space:]]", " ");
    try h.expectMatch("[[:space:]]", "\t");
    try h.expectNoMatch("[[:space:]]", "a");
}

test "char class: POSIX [[:lower:]]" {
    try h.expectMatch("[[:lower:]]", "a");
    try h.expectNoMatch("[[:lower:]]", "A");
    try h.expectNoMatch("[[:lower:]]", "5");
}

test "char class: POSIX [[:upper:]]" {
    try h.expectMatch("[[:upper:]]", "A");
    try h.expectNoMatch("[[:upper:]]", "a");
    try h.expectNoMatch("[[:upper:]]", "5");
}

test "char class: POSIX [[:xdigit:]]" {
    try h.expectMatch("[[:xdigit:]]", "a");
    try h.expectMatch("[[:xdigit:]]", "F");
    try h.expectMatch("[[:xdigit:]]", "5");
    try h.expectNoMatch("[[:xdigit:]]", "g");
}

test "char class: POSIX negated [[:^alpha:]]" {
    try h.expectNoMatch("[[:^alpha:]]", "a");
    try h.expectMatch("[[:^alpha:]]", "5");
    try h.expectMatch("[[:^alpha:]]", " ");
}

test "char class: POSIX combined with range" {
    try h.expectMatch("[a-c[:digit:]]", "a");
    try h.expectMatch("[a-c[:digit:]]", "5");
    try h.expectNoMatch("[a-c[:digit:]]", "z");
}

test "char class: Unicode range with \\u{}" {
    // Cyrillic range: \\u{0400}-\\u{04FF}
    try h.expectMatch("[\\u{0400}-\\u{04FF}]", "а");
    try h.expectMatch("[\\u{0400}-\\u{04FF}]", "Я");
    try h.expectNoMatch("[\\u{0400}-\\u{04FF}]", "a");
}

test "char class: Unicode range with \\x{}" {
    // Latin Extended-A range: \\u{0100}-\\u{017F}
    try h.expectMatch("[\\x{0100}-\\x{017F}]", "Ā");
    try h.expectMatch("[\\x{0100}-\\x{017F}]", "ſ");
    try h.expectNoMatch("[\\x{0100}-\\x{017F}]", "a");
}

test "char class: mixed ASCII and Unicode range" {
    // a-z plus Cyrillic
    try h.expectMatch("[a-z\\u{0400}-\\u{04FF}]", "a");
    try h.expectMatch("[a-z\\u{0400}-\\u{04FF}]", "я");
    try h.expectNoMatch("[a-z\\u{0400}-\\u{04FF}]", "1");
}

test "char class: Unicode literal character" {
    // Direct multi-byte UTF-8 character in class
    try h.expectMatch("[中]", "中");
    try h.expectNoMatch("[中]", "a");
}
