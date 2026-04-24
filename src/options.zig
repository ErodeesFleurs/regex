const std = @import("std");

pub const RegexOptions = struct {
    case_sensitive: bool = true,
    multiline: bool = false,
    dot_matches_newline: bool = false,
    
    pub fn format(self: RegexOptions, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("RegexOptions{{ .case_sensitive = {}, .multiline = {}, .dot_matches_newline = {} }}", .{
            self.case_sensitive,
            self.multiline,
            self.dot_matches_newline,
        });
    }
};
