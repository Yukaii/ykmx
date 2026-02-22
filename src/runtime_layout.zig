const std = @import("std");
const config = @import("config.zig");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
const layout_opentui = @import("layout_opentui.zig");
const layout_plugin = @import("layout_plugin.zig");
const plugin_manager = @import("plugin_manager.zig");

pub fn pickLayoutEngine(allocator: std.mem.Allocator, cfg: config.Config) !layout.LayoutEngine {
    return switch (cfg.layout_backend) {
        .native => layout_native.NativeLayoutEngine.init(),
        .opentui => layout_opentui.OpenTUILayoutEngine.init(),
        .plugin => blk: {
            if (cfg.layout_plugin) |plugin_dir| {
                break :blk layout_plugin.PluginLayoutEngine.init(allocator, plugin_dir) catch layout_native.NativeLayoutEngine.init();
            }
            if (cfg.plugin_dir) |plugin_dir| {
                break :blk layout_plugin.PluginLayoutEngine.init(allocator, plugin_dir) catch layout_native.NativeLayoutEngine.init();
            }
            for (cfg.plugins_dirs.items) |plugins_dir| {
                const first = try findFirstPluginSubdir(allocator, plugins_dir);
                defer if (first) |p| allocator.free(p);
                if (first) |path| {
                    break :blk layout_plugin.PluginLayoutEngine.init(allocator, path) catch layout_native.NativeLayoutEngine.init();
                }
            }
            if (cfg.plugins_dir) |plugins_dir| {
                const first = try findFirstPluginSubdir(allocator, plugins_dir);
                defer if (first) |p| allocator.free(p);
                if (first) |path| {
                    break :blk layout_plugin.PluginLayoutEngine.init(allocator, path) catch layout_native.NativeLayoutEngine.init();
                }
            }
            break :blk layout_native.NativeLayoutEngine.init();
        },
    };
}

pub fn pickLayoutEngineRuntime(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    plugins: *plugin_manager.PluginManager,
) !layout.LayoutEngine {
    return switch (cfg.layout_backend) {
        .plugin => blk: {
            if (plugins.hasAny()) {
                break :blk try layout_plugin.PluginManagerLayoutEngine.init(allocator, plugins, cfg.layout_plugin);
            }
            break :blk try pickLayoutEngine(allocator, cfg);
        },
        else => pickLayoutEngine(allocator, cfg),
    };
}

pub fn findFirstPluginSubdir(allocator: std.mem.Allocator, plugins_dir: []const u8) !?[]u8 {
    const direct_index = try std.fs.path.join(allocator, &.{ plugins_dir, "index.ts" });
    defer allocator.free(direct_index);
    if (std.fs.cwd().access(direct_index, .{})) |_| {
        return try allocator.dupe(u8, plugins_dir);
    } else |_| {}

    var dir = std.fs.cwd().openDir(plugins_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var candidates = std.ArrayListUnmanaged([]u8){};
    defer {
        for (candidates.items) |p| allocator.free(p);
        candidates.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(allocator, &.{ plugins_dir, entry.name });
        errdefer allocator.free(full);
        const index_ts = try std.fs.path.join(allocator, &.{ full, "index.ts" });
        defer allocator.free(index_ts);
        std.fs.cwd().access(index_ts, .{}) catch {
            allocator.free(full);
            continue;
        };
        try candidates.append(allocator, full);
    }

    if (candidates.items.len == 0) return null;
    std.mem.sort([]u8, candidates.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return try allocator.dupe(u8, candidates.items[0]);
}
