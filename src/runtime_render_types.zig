const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const scrollback_mod = @import("scrollback.zig");

const Terminal = ghostty_vt.Terminal;

pub const RuntimeRenderCell = struct {
    text: [32]u8 = [_]u8{' '} ++ ([_]u8{0} ** 31),
    text_len: u8 = 1,
    style: ghostty_vt.Style = .{},
    styled: bool = false,
};

pub const RuntimeFrameCache = struct {
    allocator: std.mem.Allocator,
    cols: usize = 0,
    rows: usize = 0,
    cells: []RuntimeRenderCell = &.{},

    pub fn init(allocator: std.mem.Allocator) RuntimeFrameCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RuntimeFrameCache) void {
        if (self.cells.len > 0) self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn ensureSize(self: *RuntimeFrameCache, cols: usize, rows: usize) !bool {
        if (self.cols == cols and self.rows == rows and self.cells.len == cols * rows) return false;
        if (self.cells.len > 0) self.allocator.free(self.cells);
        self.cols = cols;
        self.rows = rows;
        self.cells = try self.allocator.alloc(RuntimeRenderCell, cols * rows);
        for (self.cells) |*cell| cell.* = .{};
        return true;
    }
};

pub const PaneRenderRef = struct {
    content_x: u16,
    content_y: u16,
    content_w: u16,
    content_h: u16,
    scroll_offset: usize = 0,
    scrollback: ?*const scrollback_mod.ScrollbackBuffer = null,
    term: *Terminal,
};

pub const PaneRenderCell = struct {
    text: [32]u8 = [_]u8{0} ** 32,
    text_len: u8 = 0,
    style: ghostty_vt.Style,
    skip_draw: bool = false,
};
