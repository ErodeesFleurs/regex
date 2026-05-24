// Correctness test suite.
// Imports all sub-modules so their tests are discovered by `zig build test`.

comptime {
    _ = @import("literal.zig");
    _ = @import("char_class.zig");
    _ = @import("quantifier.zig");
    _ = @import("group.zig");
    _ = @import("anchor.zig");
    _ = @import("lookahead.zig");
    _ = @import("complex.zig");
    _ = @import("word_boundary.zig");
    _ = @import("replace_split.zig");
    _ = @import("options.zig");
    _ = @import("stress.zig");
    _ = @import("absolute_anchor.zig");
    _ = @import("escapes.zig");
    _ = @import("lazy.zig");
    _ = @import("atomic.zig");
    _ = @import("named_possessive.zig");
    _ = @import("findall_replaceall.zig");
    _ = @import("unicode_property.zig");
    _ = @import("backtracking.zig");
    _ = @import("boundary.zig");
    _ = @import("grapheme_cluster.zig");
    _ = @import("conditional.zig");
}
