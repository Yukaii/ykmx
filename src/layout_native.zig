const std = @import("std");
const layout = @import("layout.zig");

pub const NativeLayoutEngine = struct {
    pub fn init() layout.LayoutEngine {
        return .{
            .ctx = null,
            .compute_fn = compute,
            .deinit_fn = null,
        };
    }

    fn compute(
        _: ?*anyopaque,
        allocator: std.mem.Allocator,
        params: layout.LayoutParams,
    ) ![]layout.Rect {
        try layout.validateParams(params);
        if (params.window_count == 0) return allocator.alloc(layout.Rect, 0);

        return switch (params.layout) {
            .vertical_stack => computeVerticalStack(allocator, params),
            .horizontal_stack => computeHorizontalStack(allocator, params),
            .grid => computeGrid(allocator, params),
            .fullscreen => computeFullscreen(allocator, params),
        };
    }

    fn computeVerticalStack(allocator: std.mem.Allocator, params: layout.LayoutParams) ![]layout.Rect {
        const inner = try insetRect(params.screen, params.gap);
        const count: usize = @intCast(params.window_count);
        const rects = try allocator.alloc(layout.Rect, count);

        const master_n_u16 = @min(params.master_count, params.window_count);
        const master_n: usize = @intCast(master_n_u16);
        const stack_n: usize = count - master_n;

        if (stack_n == 0) {
            try splitVerticalInto(rects[0..count], inner, params.gap);
            return rects;
        }

        if (inner.width <= params.gap) return error.ScreenTooNarrow;

        const split_width: u16 = inner.width - params.gap;
        var master_width: u16 = @intCast((@as(u32, split_width) * params.master_ratio_permille) / 1000);

        if (master_width == 0) master_width = 1;
        if (master_width >= split_width) master_width = split_width - 1;

        const stack_width: u16 = split_width - master_width;

        const master_area = layout.Rect{ .x = inner.x, .y = inner.y, .width = master_width, .height = inner.height };
        const stack_area = layout.Rect{
            .x = inner.x + master_width + params.gap,
            .y = inner.y,
            .width = stack_width,
            .height = inner.height,
        };

        try splitVerticalInto(rects[0..master_n], master_area, params.gap);
        try splitVerticalInto(rects[master_n..count], stack_area, params.gap);
        return rects;
    }

    fn computeHorizontalStack(allocator: std.mem.Allocator, params: layout.LayoutParams) ![]layout.Rect {
        const inner = try insetRect(params.screen, params.gap);
        const count: usize = @intCast(params.window_count);
        const rects = try allocator.alloc(layout.Rect, count);

        const master_n_u16 = @min(params.master_count, params.window_count);
        const master_n: usize = @intCast(master_n_u16);
        const stack_n: usize = count - master_n;

        if (stack_n == 0) {
            try splitHorizontalInto(rects[0..count], inner, params.gap);
            return rects;
        }

        if (inner.height <= params.gap) return error.ScreenTooShort;

        const split_height: u16 = inner.height - params.gap;
        var master_height: u16 = @intCast((@as(u32, split_height) * params.master_ratio_permille) / 1000);

        if (master_height == 0) master_height = 1;
        if (master_height >= split_height) master_height = split_height - 1;

        const stack_height: u16 = split_height - master_height;

        const master_area = layout.Rect{ .x = inner.x, .y = inner.y, .width = inner.width, .height = master_height };
        const stack_area = layout.Rect{
            .x = inner.x,
            .y = inner.y + master_height + params.gap,
            .width = inner.width,
            .height = stack_height,
        };

        try splitHorizontalInto(rects[0..master_n], master_area, params.gap);
        try splitHorizontalInto(rects[master_n..count], stack_area, params.gap);
        return rects;
    }

    fn computeGrid(allocator: std.mem.Allocator, params: layout.LayoutParams) ![]layout.Rect {
        const inner = try insetRect(params.screen, params.gap);
        const count: usize = @intCast(params.window_count);
        const rects = try allocator.alloc(layout.Rect, count);

        const cols: usize = std.math.sqrt(count) + @intFromBool(std.math.sqrt(count) * std.math.sqrt(count) < count);
        const rows: usize = std.math.divCeil(usize, count, cols) catch unreachable;

        const cols_u16: u16 = @intCast(cols);
        const rows_u16: u16 = @intCast(rows);

        const gaps_w: u32 = @as(u32, params.gap) * @as(u32, if (cols_u16 > 0) cols_u16 - 1 else 0);
        const gaps_h: u32 = @as(u32, params.gap) * @as(u32, if (rows_u16 > 0) rows_u16 - 1 else 0);
        if (inner.width <= gaps_w or inner.height <= gaps_h) return error.ScreenTooSmallForGap;

        const avail_w: u32 = @as(u32, inner.width) - gaps_w;
        const avail_h: u32 = @as(u32, inner.height) - gaps_h;

        const base_w: u16 = @intCast(avail_w / cols_u16);
        const rem_w: u16 = @intCast(avail_w % cols_u16);
        const base_h: u16 = @intCast(avail_h / rows_u16);
        const rem_h: u16 = @intCast(avail_h % rows_u16);

        var idx: usize = 0;
        var r: usize = 0;
        var y = inner.y;
        while (r < rows and idx < count) : (r += 1) {
            const row_bonus: u16 = if (r < rem_h) 1 else 0;
            const h = base_h + row_bonus;

            var c_idx: usize = 0;
            var x = inner.x;
            while (c_idx < cols and idx < count) : (c_idx += 1) {
                const col_bonus: u16 = if (c_idx < rem_w) 1 else 0;
                const w = base_w + col_bonus;
                rects[idx] = .{ .x = x, .y = y, .width = w, .height = h };
                idx += 1;
                x += w;
                if (c_idx + 1 < cols) x += params.gap;
            }

            y += h;
            if (r + 1 < rows) y += params.gap;
        }

        return rects;
    }

    fn computeFullscreen(allocator: std.mem.Allocator, params: layout.LayoutParams) ![]layout.Rect {
        const inner = try insetRect(params.screen, params.gap);
        const count: usize = @intCast(params.window_count);
        const rects = try allocator.alloc(layout.Rect, count);

        for (rects, 0..) |*r, i| {
            if (i == params.focused_index) {
                r.* = inner;
            } else {
                r.* = .{ .x = inner.x, .y = inner.y, .width = 0, .height = 0 };
            }
        }
        return rects;
    }

    fn insetRect(r: layout.Rect, gap: u16) !layout.Rect {
        const gap_twice: u32 = @as(u32, gap) * 2;
        if (r.width <= gap_twice or r.height <= gap_twice) return error.ScreenTooSmallForGap;

        return .{
            .x = r.x + gap,
            .y = r.y + gap,
            .width = r.width - @as(u16, @intCast(gap_twice)),
            .height = r.height - @as(u16, @intCast(gap_twice)),
        };
    }

    fn splitVerticalInto(out: []layout.Rect, area: layout.Rect, gap: u16) !void {
        if (out.len == 0) return;

        const n_u16: u16 = @intCast(out.len);
        const gaps_total_u32 = @as(u32, gap) * @as(u32, n_u16 - 1);
        if (area.height <= gaps_total_u32) return error.ScreenTooShort;

        const rows_available_u32 = @as(u32, area.height) - gaps_total_u32;
        const base_h_u32 = rows_available_u32 / n_u16;
        const remainder_u16: u16 = @intCast(rows_available_u32 % n_u16);

        var y = area.y;
        for (out, 0..) |*slot, i| {
            const bonus: u16 = if (i < remainder_u16) 1 else 0;
            const h: u16 = @as(u16, @intCast(base_h_u32)) + bonus;
            slot.* = .{ .x = area.x, .y = y, .width = area.width, .height = h };
            y += h;
            if (i + 1 < out.len) y += gap;
        }
    }

    fn splitHorizontalInto(out: []layout.Rect, area: layout.Rect, gap: u16) !void {
        if (out.len == 0) return;

        const n_u16: u16 = @intCast(out.len);
        const gaps_total_u32 = @as(u32, gap) * @as(u32, n_u16 - 1);
        if (area.width <= gaps_total_u32) return error.ScreenTooNarrow;

        const cols_available_u32 = @as(u32, area.width) - gaps_total_u32;
        const base_w_u32 = cols_available_u32 / n_u16;
        const remainder_u16: u16 = @intCast(cols_available_u32 % n_u16);

        var x = area.x;
        for (out, 0..) |*slot, i| {
            const bonus: u16 = if (i < remainder_u16) 1 else 0;
            const w: u16 = @as(u16, @intCast(base_w_u32)) + bonus;
            slot.* = .{ .x = x, .y = area.y, .width = w, .height = area.height };
            x += w;
            if (i + 1 < out.len) x += gap;
        }
    }
};

test "vertical stack places one master and one stack pane" {
    const testing = std.testing;
    const engine = NativeLayoutEngine.init();

    const rects = try engine.compute(testing.allocator, .{
        .layout = .vertical_stack,
        .screen = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
        .window_count = 2,
        .master_count = 1,
        .master_ratio_permille = 600,
        .gap = 0,
    });
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(layout.Rect{ .x = 0, .y = 0, .width = 60, .height = 40 }, rects[0]);
    try testing.expectEqual(layout.Rect{ .x = 60, .y = 0, .width = 40, .height = 40 }, rects[1]);
}

test "horizontal stack puts master on top" {
    const testing = std.testing;
    const engine = NativeLayoutEngine.init();

    const rects = try engine.compute(testing.allocator, .{
        .layout = .horizontal_stack,
        .screen = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
        .window_count = 2,
        .master_count = 1,
        .master_ratio_permille = 500,
        .gap = 0,
    });
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(layout.Rect{ .x = 0, .y = 0, .width = 100, .height = 20 }, rects[0]);
    try testing.expectEqual(layout.Rect{ .x = 0, .y = 20, .width = 100, .height = 20 }, rects[1]);
}

test "grid layout creates near-square tiling" {
    const testing = std.testing;
    const engine = NativeLayoutEngine.init();

    const rects = try engine.compute(testing.allocator, .{
        .layout = .grid,
        .screen = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
        .window_count = 4,
        .gap = 0,
    });
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(usize, 4), rects.len);
    try testing.expectEqual(layout.Rect{ .x = 0, .y = 0, .width = 50, .height = 20 }, rects[0]);
    try testing.expectEqual(layout.Rect{ .x = 50, .y = 0, .width = 50, .height = 20 }, rects[1]);
    try testing.expectEqual(layout.Rect{ .x = 0, .y = 20, .width = 50, .height = 20 }, rects[2]);
}

test "fullscreen shows focused pane only" {
    const testing = std.testing;
    const engine = NativeLayoutEngine.init();

    const rects = try engine.compute(testing.allocator, .{
        .layout = .fullscreen,
        .screen = .{ .x = 0, .y = 0, .width = 80, .height = 24 },
        .window_count = 3,
        .focused_index = 1,
    });
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(u16, 0), rects[0].width);
    try testing.expectEqual(layout.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 }, rects[1]);
    try testing.expectEqual(@as(u16, 0), rects[2].width);
}
