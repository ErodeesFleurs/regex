const std = @import("std");
const regex = @import("../root.zig");

// Lazy quantifier correctness tests.

test "lazy: star *?" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a*?", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.getGroup("aaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "lazy: plus +?" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a+?", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("a", r.getGroup("aaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "lazy: question ??" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a??", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.getGroup("aaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "lazy: range {1,3}?" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a{1,3}?", "aaaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("a", r.getGroup("aaaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "greedy: star *" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a*", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("aaa", r.getGroup("aaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "greedy: plus +" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a+", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("aaa", r.getGroup("aaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "greedy: question ?" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a?", "aaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("a", r.getGroup("aaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}

test "greedy: range {1,3}" {
    const allocator = std.testing.allocator;
    var result = try regex.find(allocator, "a{1,3}", "aaaa");
    if (result) |*r| {
        defer r.deinit();
        try std.testing.expectEqualStrings("aaa", r.getGroup("aaaa", 0).?);
    } else {
        try std.testing.expect(false);
    }
}
