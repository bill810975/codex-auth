const std = @import("std");

pub const Stdout = struct {
    writer: std.fs.File.Writer,

    pub fn init(self: *Stdout) void {
        self.writer = getStdoutFile().writer();
    }

    pub fn out(self: *Stdout) std.io.AnyWriter {
        return self.writer.any();
    }
};

fn getStdoutFile() std.fs.File {
    if (@hasDecl(std.fs.File, "stdout")) {
        return std.io.getStdOut();
    }
    if (@hasDecl(std, "io") and @hasDecl(std.io, "getStdOut")) {
        return std.io.getStdOut();
    }
    @compileError("No supported stdout API found in this Zig stdlib version");
}
