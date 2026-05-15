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
