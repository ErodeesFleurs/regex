const std = @import("std");
const regex = @import("../root.zig");

// Named capture groups
test "named capture group basic" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?<word>\\w+)");
    defer re.deinit();

    var result = try re.find("hello world");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("hello", r.getGroup("hello world", 0).?);
        try std.testing.expectEqualStrings("hello", r.getGroup("hello world", 1).?);
        try std.testing.expectEqualStrings("hello", re.getCaptureGroup(r.*, "hello world", "word").?);
    } else {
        try std.testing.expect(false);
    }
}

test "named capture group Python syntax" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?P<digit>\\d+)");
    defer re.deinit();

    var result = try re.find("abc123def");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("123", re.getCaptureGroup(r.*, "abc123def", "digit").?);
    } else {
        try std.testing.expect(false);
    }
}

test "named capture group multiple" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?<first>\\w+) (?<last>\\w+)");
    defer re.deinit();

    var result = try re.find("John Doe");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expect(r.matched);
        try std.testing.expectEqualStrings("John", re.getCaptureGroup(r.*, "John Doe", "first").?);
        try std.testing.expectEqualStrings("Doe", re.getCaptureGroup(r.*, "John Doe", "last").?);
    } else {
        try std.testing.expect(false);
    }
}

// Possessive quantifiers
test "possessive star" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a*+b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("aaab"));
    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(try re.isMatch("b"));
}

test "possessive plus" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a++b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("aaab"));
    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(!try re.isMatch("b"));
}

test "possessive question" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a?+b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("ab"));
    try std.testing.expect(try re.isMatch("b"));
    try std.testing.expect(!try re.isMatch("aab"));
}

test "possessive quantifier" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "a{2,3}+b");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("aab"));
    try std.testing.expect(try re.isMatch("aaab"));
    try std.testing.expect(!try re.isMatch("ab"));
}

test "possessive prevents backtracking" {
    const allocator = std.testing.allocator;
    // a*+b should not match "aaa" because a*+ consumes all 'a's and cannot backtrack
    var re = try regex.compile(allocator, "a*+b");
    defer re.deinit();

    try std.testing.expect(!try re.isMatch("aaa"));
}

// Replacement symbols
test "replacement $&" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "world");
    defer re.deinit();

    const result = try re.replace("hello world", "$&!");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world!", result);
}

test "replacement $`" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "world");
    defer re.deinit();

    const result = try re.replace("hello world", "[$`]");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello [hello ]", result);
}

test "replacement $'" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "world");
    defer re.deinit();

    const result = try re.replace("hello world!", "[$']");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello [!]!", result);
}

test "replacement $$" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "x");
    defer re.deinit();

    const result = try re.replace("axb", "$$");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a$b", result);
}

test "replacement named group" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?<name>\\w+)");
    defer re.deinit();

    const result = try re.replace("hello", "${name}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

// Named backreferences: \g<name> and \k<name>
test "named backref: \\g<name>" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?<word>\\w+) \\g<word>");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("hello hello"));
    try std.testing.expect(!try re.isMatch("hello world"));
}

test "named backref: \\k<name>" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?<word>\\w+) \\k<word>");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("test test"));
    try std.testing.expect(!try re.isMatch("test other"));
}

test "named backref: multiple groups" {
    const allocator = std.testing.allocator;
    var re = try regex.compile(allocator, "(?<a>\\w+)-(?<b>\\w+) \\g<b>-\\g<a>");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abc-def def-abc"));
    try std.testing.expect(!try re.isMatch("abc-def abc-def"));
}

// Relative backreferences: \g{-1}, \g{-2}
test "relative backref: \\g{-1}" {
    const allocator = std.testing.allocator;
    // \\g{-1} refers to the most recent capture group
    var re = try regex.compile(allocator, "(\\w+) \\g{-1}");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("hello hello"));
    try std.testing.expect(!try re.isMatch("hello world"));
}

test "relative backref: \\g{-2}" {
    const allocator = std.testing.allocator;
    // \\g{-2} refers to the second most recent capture group
    var re = try regex.compile(allocator, "(a)(b)(c) \\g{-2}");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("abc b"));
    try std.testing.expect(!try re.isMatch("abc c"));
}

test "relative backref: numeric \\g{1}" {
    const allocator = std.testing.allocator;
    // \\g{1} is equivalent to \\1
    var re = try regex.compile(allocator, "(\\w+) \\g{1}");
    defer re.deinit();

    try std.testing.expect(try re.isMatch("test test"));
    try std.testing.expect(!try re.isMatch("test other"));
}
