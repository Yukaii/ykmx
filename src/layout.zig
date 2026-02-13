const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const LayoutType = enum {
    vertical_stack,
    horizontal_stack,
    grid,
    fullscreen,
};

pub const LayoutParams = struct {
    layout: LayoutType,
    screen: Rect,
    window_count: u16,
    focused_index: u16 = 0,
    master_count: u16 = 1,
    // 0..=1000 where 600 means 60% of the width for master area.
    master_ratio_permille: u16 = 600,
    gap: u16 = 0,
};

pub const ComputeFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    params: LayoutParams,
) anyerror![]Rect;

pub const DeinitFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
) void;

pub const LayoutEngine = struct {
    ctx: ?*anyopaque,
    compute_fn: ComputeFn,
    deinit_fn: ?DeinitFn = null,

    pub fn compute(
        self: LayoutEngine,
        allocator: std.mem.Allocator,
        params: LayoutParams,
    ) ![]Rect {
        return self.compute_fn(self.ctx, allocator, params);
    }

    pub fn deinit(self: LayoutEngine, allocator: std.mem.Allocator) void {
        if (self.deinit_fn) |f| f(self.ctx, allocator);
    }
};

pub fn validateParams(params: LayoutParams) !void {
    if (params.window_count == 0) return;
    if (params.master_ratio_permille > 1000) return error.InvalidMasterRatio;
    if (params.focused_index >= params.window_count) return error.InvalidFocusedIndex;
    if (params.screen.width == 0 or params.screen.height == 0) {
        return error.InvalidScreenSize;
    }
}
