const std = @import("std");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
const plugin_host = @import("plugin_host.zig");
const plugin_manager = @import("plugin_manager.zig");

pub const PluginLayoutEngine = struct {
    const Context = struct {
        host: plugin_host.PluginHost,
        fallback: layout.LayoutEngine,
        last_layout: ?layout.LayoutType = null,
    };

    pub fn init(allocator: std.mem.Allocator, plugin_dir: []const u8) !layout.LayoutEngine {
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        const plugin_name = std.fs.path.basename(plugin_dir);
        ctx.* = .{
            .host = try plugin_host.PluginHost.start(allocator, plugin_dir, plugin_name, null, &.{}),
            .fallback = layout_native.NativeLayoutEngine.init(),
        };

        return .{
            .ctx = ctx,
            .compute_fn = compute,
            .deinit_fn = deinit,
        };
    }

    fn compute(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        params: layout.LayoutParams,
    ) ![]layout.Rect {
        const ctx = @as(*Context, @ptrCast(@alignCast(ctx_ptr orelse return error.InvalidPluginLayoutContext)));

        if (ctx.last_layout == null) {
            _ = ctx.host.emitStart(params.layout) catch {};
            ctx.last_layout = params.layout;
        } else if (ctx.last_layout.? != params.layout) {
            _ = ctx.host.emitLayoutChanged(params.layout) catch {};
            ctx.last_layout = params.layout;
        }

        if (try ctx.host.requestLayout(allocator, params, 12)) |plugin_rects| {
            if (plugin_rects.len == params.window_count) return plugin_rects;
            allocator.free(plugin_rects);
        }

        return ctx.fallback.compute(allocator, params);
    }

    fn deinit(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator) void {
        const ctx = @as(*Context, @ptrCast(@alignCast(ctx_ptr orelse return)));
        _ = ctx.host.emitShutdown() catch {};
        ctx.host.deinit();
        ctx.fallback.deinit(allocator);
        allocator.destroy(ctx);
    }
};

pub const PluginManagerLayoutEngine = struct {
    const Context = struct {
        manager: *plugin_manager.PluginManager,
        fallback: layout.LayoutEngine,
        preferred_layout_plugin: ?[]u8 = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        manager: *plugin_manager.PluginManager,
        preferred_layout_plugin: ?[]const u8,
    ) !layout.LayoutEngine {
        const ctx = try allocator.create(Context);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .manager = manager,
            .fallback = layout_native.NativeLayoutEngine.init(),
            .preferred_layout_plugin = if (preferred_layout_plugin) |name| try allocator.dupe(u8, name) else null,
        };

        return .{
            .ctx = ctx,
            .compute_fn = compute,
            .deinit_fn = deinit,
        };
    }

    fn compute(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        params: layout.LayoutParams,
    ) ![]layout.Rect {
        const ctx = @as(*Context, @ptrCast(@alignCast(ctx_ptr orelse return error.InvalidPluginLayoutContext)));
        if (try ctx.manager.requestLayout(allocator, params, 12, ctx.preferred_layout_plugin)) |plugin_rects| {
            if (plugin_rects.len == params.window_count) return plugin_rects;
            allocator.free(plugin_rects);
        }
        return ctx.fallback.compute(allocator, params);
    }

    fn deinit(ctx_ptr: ?*anyopaque, allocator: std.mem.Allocator) void {
        const ctx = @as(*Context, @ptrCast(@alignCast(ctx_ptr orelse return)));
        if (ctx.preferred_layout_plugin) |name| allocator.free(name);
        ctx.fallback.deinit(allocator);
        allocator.destroy(ctx);
    }
};
