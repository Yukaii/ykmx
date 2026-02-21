const std = @import("std");
const layout = @import("layout.zig");
const plugin_host = @import("plugin_host.zig");

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    hosts: std.ArrayListUnmanaged(plugin_host.PluginHost) = .{},

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PluginManager) void {
        for (self.hosts.items) |*host| host.deinit();
        self.hosts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn startAll(
        self: *PluginManager,
        maybe_plugin_dir: ?[]const u8,
        maybe_plugins_dir: ?[]const u8,
    ) !usize {
        if (maybe_plugin_dir) |plugin_dir| {
            try self.tryStartHost(plugin_dir);
        }
        if (maybe_plugins_dir) |plugins_dir| {
            try self.startFromPluginsDir(plugins_dir);
        }
        return self.hosts.items.len;
    }

    pub fn hasAny(self: *const PluginManager) bool {
        return self.hosts.items.len > 0;
    }

    pub fn emitStart(self: *PluginManager, layout_type: layout.LayoutType) void {
        for (self.hosts.items) |*host| {
            _ = host.emitStart(layout_type) catch {};
        }
    }

    pub fn emitLayoutChanged(self: *PluginManager, layout_type: layout.LayoutType) void {
        for (self.hosts.items) |*host| {
            _ = host.emitLayoutChanged(layout_type) catch {};
        }
    }

    pub fn emitStateChanged(self: *PluginManager, reason: []const u8, state: plugin_host.PluginHost.RuntimeState) void {
        for (self.hosts.items) |*host| {
            _ = host.emitStateChanged(reason, state) catch {};
        }
    }

    pub fn emitTick(self: *PluginManager, stats: plugin_host.PluginHost.TickStats, state: plugin_host.PluginHost.RuntimeState) void {
        for (self.hosts.items) |*host| {
            _ = host.emitTick(stats, state) catch {};
        }
    }

    pub fn emitShutdown(self: *PluginManager) void {
        for (self.hosts.items) |*host| {
            _ = host.emitShutdown() catch {};
        }
    }

    pub fn drainActions(self: *PluginManager, allocator: std.mem.Allocator) ![]plugin_host.PluginHost.Action {
        var merged = std.ArrayListUnmanaged(plugin_host.PluginHost.Action){};
        errdefer merged.deinit(allocator);

        for (self.hosts.items) |*host| {
            const actions = host.drainActions(allocator) catch continue;
            defer allocator.free(actions);
            try merged.appendSlice(allocator, actions);
        }

        return merged.toOwnedSlice(allocator);
    }

    fn startFromPluginsDir(self: *PluginManager, plugins_dir: []const u8) !void {
        var dir = std.fs.cwd().openDir(plugins_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var paths = std.ArrayListUnmanaged([]u8){};
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            const full = try std.fs.path.join(self.allocator, &.{ plugins_dir, entry.name });
            errdefer self.allocator.free(full);

            const index_ts = try std.fs.path.join(self.allocator, &.{ full, "index.ts" });
            defer self.allocator.free(index_ts);
            std.fs.cwd().access(index_ts, .{}) catch {
                self.allocator.free(full);
                continue;
            };
            try paths.append(self.allocator, full);
        }

        std.mem.sort([]u8, paths.items, {}, lessThanPath);
        for (paths.items) |path| {
            try self.tryStartHost(path);
        }
    }

    fn tryStartHost(self: *PluginManager, path: []const u8) !void {
        const host = plugin_host.PluginHost.start(self.allocator, path) catch return;
        try self.hosts.append(self.allocator, host);
    }

    fn lessThanPath(_: void, a: []u8, b: []u8) bool {
        return std.mem.lessThan(u8, a, b);
    }
};
