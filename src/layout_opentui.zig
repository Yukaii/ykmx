const std = @import("std");
const layout = @import("layout.zig");

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
