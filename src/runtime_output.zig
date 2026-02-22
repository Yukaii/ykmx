const std = @import("std");

pub fn writeClippedLine(out: *std.Io.Writer, line: []const u8, max_cols: usize) !void {
    const clipped_len = @min(line.len, max_cols);
    try writeAllBlocking(out, line[0..clipped_len]);
    if (clipped_len < max_cols) {
        var i: usize = clipped_len;
        while (i < max_cols) : (i += 1) try writeByteBlocking(out, ' ');
    }
}

pub fn writeAllBlocking(out: *std.Io.Writer, bytes: []const u8) !void {
    var written: usize = 0;
    var retries: usize = 0;
    while (written < bytes.len) {
        const n = out.write(bytes[written..]) catch |err| switch (err) {
            error.WriteFailed => {
                retries += 1;
                if (retries > 2000) return err;
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        retries = 0;
        written += n;
    }
}

pub fn writeByteBlocking(out: *std.Io.Writer, b: u8) !void {
    var one = [1]u8{b};
    try writeAllBlocking(out, &one);
}

pub fn writeCodepointBlocking(out: *std.Io.Writer, cp: u21) !void {
    var scratch: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &scratch) catch {
        return writeByteBlocking(out, '?');
    };
    try writeAllBlocking(out, scratch[0..n]);
}

pub fn encodeCodepoint(dst: []u8, cp: u21) usize {
    var scratch: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &scratch) catch return 0;
    if (dst.len < n) return 0;
    @memcpy(dst[0..n], scratch[0..n]);
    return n;
}

pub fn writeFmtBlocking(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAllBlocking(out, text);
}
