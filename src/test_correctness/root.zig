// Correctness test suite.
// Imports all sub-modules so their tests are discovered by `zig build test`.

pub const literal = @import("literal.zig");
pub const char_class = @import("char_class.zig");
pub const quantifier = @import("quantifier.zig");
pub const group = @import("group.zig");
pub const anchor = @import("anchor.zig");
pub const lookahead = @import("lookahead.zig");
pub const complex = @import("complex.zig");
pub const word_boundary = @import("word_boundary.zig");
pub const replace_split = @import("replace_split.zig");
pub const options = @import("options.zig");
pub const stress = @import("stress.zig");
