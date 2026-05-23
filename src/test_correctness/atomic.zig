const std = @import("std");
const regex = @import("../root.zig");

fn t(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8, expect_match: bool) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
    const m = try re.isMatch(input);
    try std.testing.expectEqual(expect_match, m);
}

fn find(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8, expect_start: ?usize, expect_end: ?usize) !void {
    var re = try regex.compile(allocator, pattern);
    defer re.deinit();
    var result = try re.find(input);
    if (result) |*r| {
        defer r.deinit();
        if (expect_start == null) {
            try std.testing.expect(!r.matched);
        } else {
            try std.testing.expect(r.matched);
            try std.testing.expectEqual(expect_start.?, r.start);
            try std.testing.expectEqual(expect_end.?, r.end);
        }
    } else {
        if (expect_start != null) {
            try std.testing.expect(false);
        }
    }
}

// Atomic group should prevent backtracking into the group
// a(?>bc|b)c should NOT match "abc" because "bc" consumes both chars,
// then the trailing c fails, and backtracking cannot re-enter the atomic group
test "atomic group prevents backtracking" {
    const allocator = std.testing.allocator;

    // Without atomic group: a(bc|b)c matches "abc" via bc
    try t(allocator, "a(bc|b)c", "abc", true);

    // With atomic group: a(?>bc|b)c does NOT match "abc"
    // because atomic group matches "bc", then c fails, cannot backtrack to try "b"
    try t(allocator, "a(?>bc|b)c", "abc", false);
}

// Atomic group with single option still works normally
test "atomic group single branch" {
    const allocator = std.testing.allocator;

    try t(allocator, "(?>ab)", "ab", true);
    try t(allocator, "(?>ab)", "ac", false);
}

// Nested atomic groups
test "nested atomic groups" {
    const allocator = std.testing.allocator;

    try t(allocator, "(?>(?>ab))", "ab", true);
}

// Atomic group with quantifier
test "atomic group with quantifier" {
    const allocator = std.testing.allocator;

    // (?>\w+)\s should match "abc " but not backtrack to shorter match
    try t(allocator, "(?>\\w+)\\s", "abc ", true);
    try t(allocator, "(?>\\w+)\\s", "abc", false);
}

// find() with atomic group
test "atomic group find" {
    const allocator = std.testing.allocator;

    try find(allocator, "(?>ab)", "xab", 1, 3);
    try find(allocator, "(?>ab)", "xac", null, null);
}
