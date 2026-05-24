const std = @import("std");
const regex = @import("../root.zig");

// Henry Spencer / POSIX / PCRE-inspired character class correctness tests.

test "char class: simple range [a-z]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[a-z]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[a-z]", "m"));
    try std.testing.expect(try regex.isMatch(allocator, "[a-z]", "z"));
    try std.testing.expect(!try regex.isMatch(allocator, "[a-z]", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "[a-z]", "0"));
}

test "char class: uppercase range [A-Z]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[A-Z]", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "[A-Z]", "M"));
    try std.testing.expect(try regex.isMatch(allocator, "[A-Z]", "Z"));
    try std.testing.expect(!try regex.isMatch(allocator, "[A-Z]", "a"));
}

test "char class: digit range [0-9]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[0-9]", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "[0-9]", "5"));
    try std.testing.expect(try regex.isMatch(allocator, "[0-9]", "9"));
    try std.testing.expect(!try regex.isMatch(allocator, "[0-9]", "a"));
}

test "char class: negated [^a-z]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "[^a-z]", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "[^a-z]", "z"));
    try std.testing.expect(try regex.isMatch(allocator, "[^a-z]", "A"));
    try std.testing.expect(try regex.isMatch(allocator, "[^a-z]", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "[^a-z]", "!"));
}

test "char class: multiple ranges" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[a-zA-Z]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[a-zA-Z]", "Z"));
    try std.testing.expect(!try regex.isMatch(allocator, "[a-zA-Z]", "0"));
}

test "char class: shorthand \\d" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\d", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "\\d", "9"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\d", "a"));
}

test "char class: shorthand \\D" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "\\D", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "\\D", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "\\D", "!"));
}

test "char class: shorthand \\w" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\w", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "\\w", "Z"));
    try std.testing.expect(try regex.isMatch(allocator, "\\w", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "\\w", "_"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\w", "!"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\w", " "));
}

test "char class: shorthand \\W" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "\\W", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\W", "_"));
    try std.testing.expect(try regex.isMatch(allocator, "\\W", "!"));
    try std.testing.expect(try regex.isMatch(allocator, "\\W", " "));
}

test "char class: shorthand \\s" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "\\s", " "));
    try std.testing.expect(try regex.isMatch(allocator, "\\s", "\t"));
    try std.testing.expect(try regex.isMatch(allocator, "\\s", "\n"));
    try std.testing.expect(!try regex.isMatch(allocator, "\\s", "a"));
}

test "char class: shorthand \\S" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "\\S", " "));
    try std.testing.expect(try regex.isMatch(allocator, "\\S", "a"));
}

test "char class: single char class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[abc]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[abc]", "b"));
    try std.testing.expect(try regex.isMatch(allocator, "[abc]", "c"));
    try std.testing.expect(!try regex.isMatch(allocator, "[abc]", "d"));
}

test "char class: hyphen at end" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[abc-]", "-"));
    try std.testing.expect(try regex.isMatch(allocator, "[abc-]", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "[abc-]", "d"));
}

test "char class: dot inside class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[.]", "."));
    try std.testing.expect(!try regex.isMatch(allocator, "[.]", "a"));
}

test "char class: shorthand inside class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[\\d]", "5"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\d]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[\\w]", "_"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\w]", "!"));
    try std.testing.expect(try regex.isMatch(allocator, "[\\s]", "\t"));
    try std.testing.expect(!try regex.isMatch(allocator, "[\\s]", "a"));
}

test "char class: negated shorthand inside class" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "[\\D]", "5"));
    try std.testing.expect(try regex.isMatch(allocator, "[\\D]", "a"));
}

test "char class: POSIX [[:alpha:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:alpha:]]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:alpha:]]", "Z"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:alpha:]]", "5"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:alpha:]]", " "));
}

test "char class: POSIX [[:digit:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:digit:]]", "0"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:digit:]]", "9"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:digit:]]", "a"));
}

test "char class: POSIX [[:alnum:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:alnum:]]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:alnum:]]", "5"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:alnum:]]", " "));
}

test "char class: POSIX [[:space:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:space:]]", " "));
    try std.testing.expect(try regex.isMatch(allocator, "[[:space:]]", "\t"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:space:]]", "a"));
}

test "char class: POSIX [[:lower:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:lower:]]", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:lower:]]", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:lower:]]", "5"));
}

test "char class: POSIX [[:upper:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:upper:]]", "A"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:upper:]]", "a"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:upper:]]", "5"));
}

test "char class: POSIX [[:xdigit:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[[:xdigit:]]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:xdigit:]]", "F"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:xdigit:]]", "5"));
    try std.testing.expect(!try regex.isMatch(allocator, "[[:xdigit:]]", "g"));
}

test "char class: POSIX negated [[:^alpha:]]" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!try regex.isMatch(allocator, "[[:^alpha:]]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:^alpha:]]", "5"));
    try std.testing.expect(try regex.isMatch(allocator, "[[:^alpha:]]", " "));
}

test "char class: POSIX combined with range" {
    const allocator = std.testing.allocator;
    try std.testing.expect(try regex.isMatch(allocator, "[a-c[:digit:]]", "a"));
    try std.testing.expect(try regex.isMatch(allocator, "[a-c[:digit:]]", "5"));
    try std.testing.expect(!try regex.isMatch(allocator, "[a-c[:digit:]]", "z"));
}
