const std = @import("std");

pub const Stdout = struct {
    buffer: [4096]u8 = undefined,
    writer: std.fs.File.Writer,

    pub fn init(self: *Stdout) void {
        self.writer = getStdoutFile().writer(&self.buffer);
    }

    pub fn out(self: *Stdout) *@TypeOf(self.writer.interface) {
        return &self.writer.interface;
    }
};

fn getStdoutFile() std.fs.File {
    if (@hasDecl(std.fs.File, "stdout")) {
        return std.fs.File.stdout();
    }
    if (@hasDecl(std, "io") and @hasDecl(std.io, "getStdOut")) {
        return std.io.getStdOut();
    }
    @compileError("No supported stdout API found in this Zig stdlib version");
}
