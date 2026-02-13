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
            else => error.UnsupportedLayout,
        };
    }

    fn computeVerticalStack(
        allocator: std.mem.Allocator,
        params: layout.LayoutParams,
    ) ![]layout.Rect {
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

        const master_area = layout.Rect{
            .x = inner.x,
            .y = inner.y,
            .width = master_width,
            .height = inner.height,
        };
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

    fn splitVerticalInto(
        out: []layout.Rect,
        area: layout.Rect,
        gap: u16,
    ) !void {
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
            slot.* = .{
                .x = area.x,
                .y = y,
                .width = area.width,
                .height = h,
            };
            y += h;
            if (i + 1 < out.len) y += gap;
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

test "vertical stack splits stack area vertically with gaps" {
    const testing = std.testing;
    const engine = NativeLayoutEngine.init();

    const rects = try engine.compute(testing.allocator, .{
        .layout = .vertical_stack,
        .screen = .{ .x = 0, .y = 0, .width = 80, .height = 24 },
        .window_count = 4,
        .master_count = 1,
        .master_ratio_permille = 500,
        .gap = 1,
    });
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(usize, 4), rects.len);
    try testing.expectEqual(layout.Rect{ .x = 1, .y = 1, .width = 38, .height = 22 }, rects[0]);

    // Stack pane should consume remaining width and be split in 3 rows with 1-cell gaps.
    try testing.expectEqual(@as(u16, 40), rects[1].x);
    try testing.expectEqual(@as(u16, 39), rects[1].width);
    try testing.expectEqual(@as(u16, 7), rects[1].height);
    try testing.expectEqual(@as(u16, 9), rects[2].y);
    try testing.expectEqual(@as(u16, 17), rects[3].y);
}
