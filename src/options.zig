const std = @import("std");

pub const RegexOptions = struct {
    case_sensitive: bool = true,
    multiline: bool = false,
    dot_matches_newline: bool = false,
    /// Maximum number of execution steps before giving up (null = unlimited).
    /// Used to prevent catastrophic backtracking on pathological patterns.
    /// Default is 1_000_000 steps, which is enough for most practical patterns.
    max_steps: ?usize = 1_000_000,

    pub fn format(self: RegexOptions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("RegexOptions{{ .case_sensitive = {}, .multiline = {}, .dot_matches_newline = {}, .max_steps = {?} }}", .{
            self.case_sensitive,
            self.multiline,
            self.dot_matches_newline,
            self.max_steps,
        });
    }
};
