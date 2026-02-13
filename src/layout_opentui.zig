const std = @import("std");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");

// Placeholder adapter for the Phase 0.5 OpenTUI layout spike.
// This keeps backend selection wiring available before full integration.
pub const OpenTUILayoutEngine = struct {
    pub fn init() layout.LayoutEngine {
        return .{
            .ctx = null,
            .compute_fn = compute,
            .deinit_fn = null,
        };
    }

    fn compute(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: layout.LayoutParams,
    ) ![]layout.Rect {
        return error.OpenTUINotIntegratedYet;
    }
};

fn assertParityOrSkip(
    allocator: std.mem.Allocator,
    params: layout.LayoutParams,
) !void {
    const native_engine = layout_native.NativeLayoutEngine.init();
    const opentui_engine = OpenTUILayoutEngine.init();

    const native_rects = try native_engine.compute(allocator, params);
    defer allocator.free(native_rects);

    const opentui_rects = opentui_engine.compute(allocator, params) catch |err| switch (err) {
        // Adapter is still a placeholder. Keep parity cases ready and skip until integrated.
        error.OpenTUINotIntegratedYet => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(opentui_rects);

    try std.testing.expectEqual(native_rects.len, opentui_rects.len);
    for (native_rects, opentui_rects) |lhs, rhs| {
        try std.testing.expectEqual(lhs, rhs);
    }
}

test "opentui parity: vertical stack golden cases" {
    const testing = std.testing;

    const cases = [_]layout.LayoutParams{
        // Single window.
        .{
            .layout = .vertical_stack,
            .screen = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
            .window_count = 1,
            .master_count = 1,
            .master_ratio_permille = 600,
            .gap = 0,
        },
        // Many windows.
        .{
            .layout = .vertical_stack,
            .screen = .{ .x = 0, .y = 0, .width = 120, .height = 45 },
            .window_count = 8,
            .master_count = 2,
            .master_ratio_permille = 550,
            .gap = 0,
        },
        // Tiny terminal geometry.
        .{
            .layout = .vertical_stack,
            .screen = .{ .x = 0, .y = 0, .width = 12, .height = 6 },
            .window_count = 3,
            .master_count = 1,
            .master_ratio_permille = 500,
            .gap = 0,
        },
        // Non-zero gaps.
        .{
            .layout = .vertical_stack,
            .screen = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
            .window_count = 4,
            .master_count = 1,
            .master_ratio_permille = 600,
            .gap = 1,
        },
        // Master count changes.
        .{
            .layout = .vertical_stack,
            .screen = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
            .window_count = 5,
            .master_count = 3,
            .master_ratio_permille = 600,
            .gap = 0,
        },
    };

    for (cases) |params| {
        try assertParityOrSkip(testing.allocator, params);
    }
}
