const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const multiplexer = @import("multiplexer.zig");

const Terminal = ghostty_vt.Terminal;
const RUNTIME_VT_MAX_SCROLLBACK: usize = 20_000;

pub const RuntimeVtState = struct {
    const WindowVt = struct {
        term: Terminal,
        consumed_bytes: usize = 0,
        cols: u16,
        rows: u16,
        stream_tail: [256]u8 = [_]u8{0} ** 256,
        stream_tail_len: u16 = 0,
    };

    allocator: std.mem.Allocator,
    windows: std.AutoHashMapUnmanaged(u32, WindowVt) = .{},

    pub fn init(allocator: std.mem.Allocator) RuntimeVtState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RuntimeVtState) void {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.term.deinit(self.allocator);
        }
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn syncWindow(
        self: *RuntimeVtState,
        window_id: u32,
        cols: u16,
        rows: u16,
        output: []const u8,
    ) !*WindowVt {
        const safe_cols: u16 = @max(@as(u16, 1), cols);
        const safe_rows: u16 = @max(@as(u16, 1), rows);

        const gop = try self.windows.getOrPut(self.allocator, window_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .term = try Terminal.init(self.allocator, .{
                    .rows = safe_rows,
                    .cols = safe_cols,
                    .max_scrollback = RUNTIME_VT_MAX_SCROLLBACK,
                }),
                .consumed_bytes = 0,
                .cols = safe_cols,
                .rows = safe_rows,
            };
        }

        var wv = gop.value_ptr;
        if (wv.cols != safe_cols or wv.rows != safe_rows) {
            try wv.term.resize(self.allocator, safe_cols, safe_rows);
            wv.cols = safe_cols;
            wv.rows = safe_rows;
        }

        if (wv.consumed_bytes > output.len) {
            wv.consumed_bytes = 0;
            wv.stream_tail_len = 0;
        }
        if (output.len > wv.consumed_bytes) {
            const delta = output[wv.consumed_bytes..];
            const tail_len: usize = wv.stream_tail_len;
            var merged = try self.allocator.alloc(u8, tail_len + delta.len);
            defer self.allocator.free(merged);
            if (tail_len > 0) @memcpy(merged[0..tail_len], wv.stream_tail[0..tail_len]);
            @memcpy(merged[tail_len..], delta);

            const ansi_safe = ansiSafePrefixLen(merged);
            const split = utf8SafePrefixLen(merged[0..ansi_safe]);
            if (split > 0) {
                var stream = wv.term.vtStream();
                const sanitized = try stripUnsupportedXtwinops(self.allocator, merged[0..split]);
                defer if (sanitized) |owned| self.allocator.free(owned);
                try stream.nextSlice(if (sanitized) |owned| owned else merged[0..split]);
            }

            const rem = merged[split..];
            wv.stream_tail_len = @intCast(@min(rem.len, wv.stream_tail.len));
            if (wv.stream_tail_len > 0) {
                @memcpy(wv.stream_tail[0..wv.stream_tail_len], rem[0..wv.stream_tail_len]);
            }
            wv.consumed_bytes = output.len;
        }

        return wv;
    }

    pub fn prune(self: *RuntimeVtState, active_ids: []const u32) !void {
        var to_remove = std.ArrayList(u32).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            var keep = false;
            for (active_ids) |aid| {
                if (aid == id) {
                    keep = true;
                    break;
                }
            }
            if (!keep) try to_remove.append(self.allocator, id);
        }

        for (to_remove.items) |id| {
            if (self.windows.getPtr(id)) |wv| {
                wv.term.deinit(self.allocator);
            }
            _ = self.windows.fetchRemove(id);
        }
    }

    pub fn syncKnownWindow(self: *RuntimeVtState, window_id: u32, output: []const u8) !bool {
        const wv = self.windows.getPtr(window_id) orelse return false;
        const cols = wv.cols;
        const rows = wv.rows;
        _ = try self.syncWindow(window_id, cols, rows, output);
        return true;
    }
};

pub fn warmKnownDirtyWindowVtState(
    allocator: std.mem.Allocator,
    mux: *multiplexer.Multiplexer,
    vt_state: *RuntimeVtState,
) !void {
    const dirty = try mux.dirtyWindowIds(allocator);
    defer allocator.free(dirty);

    for (dirty) |window_id| {
        const output = mux.windowOutput(window_id) catch {
            mux.clearDirtyWindow(window_id);
            continue;
        };
        _ = try vt_state.syncKnownWindow(window_id, output);
        mux.clearDirtyWindow(window_id);
    }
}

fn stripUnsupportedXtwinops(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, input, "\x1b[22") == null and std.mem.indexOf(u8, input, "\x1b[23") == null) {
        return null;
    }

    var out = std.ArrayListUnmanaged(u8){};
    defer if (out.items.len == 0) out.deinit(allocator);

    var i: usize = 0;
    var changed = false;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 2 < input.len and input[i + 1] == '[') {
            var j = i + 2;
            while (j < input.len and ((input[j] >= '0' and input[j] <= '9') or input[j] == ';')) : (j += 1) {}
            if (j < input.len and input[j] == 't') {
                if (parseFirstCsiParam(input[i + 2 .. j])) |first| {
                    if (first == 22 or first == 23) {
                        changed = true;
                        i = j + 1;
                        continue;
                    }
                }
                try out.appendSlice(allocator, input[i .. j + 1]);
                i = j + 1;
                continue;
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    if (!changed) {
        out.deinit(allocator);
        return null;
    }

    const owned = try out.toOwnedSlice(allocator);
    return @as(?[]u8, owned);
}

fn parseFirstCsiParam(params: []const u8) ?u16 {
    if (params.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u16, params[0..end], 10) catch null;
}

fn utf8SafePrefixLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var i = bytes.len;
    var cont: usize = 0;
    while (i > 0 and cont < 3 and isUtf8ContinuationByte(bytes[i - 1])) : (cont += 1) {
        i -= 1;
    }

    const lead_idx: usize = if (i > 0) i - 1 else return bytes.len - cont;
    const lead = bytes[lead_idx];
    const expected = utf8ExpectedLenFromLead(lead) orelse return bytes.len;
    const have = bytes.len - lead_idx;
    if (have < expected) return lead_idx;
    return bytes.len;
}

fn ansiSafePrefixLen(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0x1b) {
            if (i + 1 >= bytes.len) return i;
            const n = bytes[i + 1];
            if (n == '[') {
                var j = i + 2;
                while (j < bytes.len and !isCsiFinalByte(bytes[j])) : (j += 1) {}
                if (j >= bytes.len) return i;
                i = j + 1;
                continue;
            }
            i += 1;
            continue;
        }

        if (b == 0x9b) {
            var j = i + 1;
            while (j < bytes.len and !isCsiFinalByte(bytes[j])) : (j += 1) {}
            if (j >= bytes.len) return i;
            i = j + 1;
            continue;
        }
        i += 1;
    }
    return bytes.len;
}

fn isCsiFinalByte(b: u8) bool {
    return b >= '@' and b <= '~';
}

fn isUtf8ContinuationByte(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

fn utf8ExpectedLenFromLead(b: u8) ?usize {
    if ((b & 0b1000_0000) == 0) return 1;
    if ((b & 0b1110_0000) == 0b1100_0000) return 2;
    if ((b & 0b1111_0000) == 0b1110_0000) return 3;
    if ((b & 0b1111_1000) == 0b1111_0000) return 4;
    return null;
}
