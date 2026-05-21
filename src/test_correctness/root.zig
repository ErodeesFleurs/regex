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
}
