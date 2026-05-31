const std = @import("std");

pub const RegexOptions = struct {
    case_sensitive: bool = true,
    multiline: bool = false,
    dot_matches_newline: bool = false,
    /// When true, whitespace and comments (# to end of line) are ignored.
    free_spacing: bool = false,
    /// Maximum number of execution steps before giving up (null = unlimited).
    /// Used to prevent catastrophic backtracking on pathological patterns.
    /// Default is 1_000_000 steps, which is enough for most practical patterns.
    max_steps: ?usize = 1_000_000,

    pub fn format(self: RegexOptions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("RegexOptions{{ .case_sensitive = {}, .multiline = {}, .dot_matches_newline = {}, .free_spacing = {}, .max_steps = {?} }}", .{
            self.case_sensitive,
            self.multiline,
            self.dot_matches_newline,
            self.free_spacing,
            self.max_steps,
        });
    }
};

/// Compressed snapshot of mutable regex flags (max_steps never changes at runtime).
pub const FlagsSnapshot = packed struct {
    case_sensitive: bool = true,
    multiline: bool = false,
    dot_matches_newline: bool = false,
    free_spacing: bool = false,
};

pub fn snapshotFlags(opts: RegexOptions) FlagsSnapshot {
    return .{
        .case_sensitive = opts.case_sensitive,
        .multiline = opts.multiline,
        .dot_matches_newline = opts.dot_matches_newline,
        .free_spacing = opts.free_spacing,
    };
}

pub fn applyFlagsSnapshot(fs: FlagsSnapshot, opts: *RegexOptions) void {
    opts.case_sensitive = fs.case_sensitive;
    opts.multiline = fs.multiline;
    opts.dot_matches_newline = fs.dot_matches_newline;
    opts.free_spacing = fs.free_spacing;
}
