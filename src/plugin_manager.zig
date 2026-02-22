const std = @import("std");
const layout = @import("layout.zig");
const input_mod = @import("input.zig");
const plugin_host = @import("plugin_host.zig");

pub const PluginManager = struct {
    pub const PluginOption = struct {
        plugin_name: []const u8,
        key: []const u8,
        value: []const u8,
    };

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
        plugins_dirs: []const []const u8,
        plugin_options: []const PluginOption,
    ) !usize {
        if (maybe_plugin_dir) |plugin_dir| {
            const plugin_name = std.fs.path.basename(plugin_dir);
            try self.tryStartHost(plugin_dir, plugin_name, plugin_options);
        }
        if (maybe_plugins_dir) |plugins_dir| {
            try self.startFromPluginPath(plugins_dir, plugin_options);
        }
        for (plugins_dirs) |plugins_dir| {
            try self.startFromPluginPath(plugins_dir, plugin_options);
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

    pub fn emitPointer(self: *PluginManager, pointer: plugin_host.PluginHost.PointerEvent, hit: ?plugin_host.PluginHost.PointerHit) void {
        for (self.hosts.items) |*host| {
            _ = host.emitPointer(pointer, hit) catch {};
        }
    }

    pub fn emitCommand(self: *PluginManager, cmd: input_mod.Command) void {
        for (self.hosts.items) |*host| {
            _ = host.emitCommand(cmd) catch {};
        }
    }

    pub fn emitCommandName(self: *PluginManager, command_name: []const u8) void {
        for (self.hosts.items) |*host| {
            _ = host.emitCommandName(command_name) catch {};
        }
    }

    pub fn uiBars(self: *PluginManager) ?plugin_host.PluginHost.UiBarsView {
        var selected: ?plugin_host.PluginHost.UiBarsView = null;
        for (self.hosts.items) |*host| {
            if (host.uiBars()) |ui| selected = ui;
        }
        return selected;
    }

    pub fn consumeUiDirtyAny(self: *PluginManager) bool {
        var dirty = false;
        for (self.hosts.items) |*host| {
            dirty = host.consumeUiDirty() or dirty;
        }
        return dirty;
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

    pub fn requestLayout(self: *PluginManager, allocator: std.mem.Allocator, params: layout.LayoutParams, timeout_ms: u16) !?[]layout.Rect {
        for (self.hosts.items) |*host| {
            const maybe = host.requestLayout(allocator, params, timeout_ms) catch continue;
            if (maybe) |rects| return rects;
        }
        return null;
    }

    fn startFromPluginPath(self: *PluginManager, path: []const u8, plugin_options: []const PluginOption) !void {
        if (isPluginDir(self.allocator, path)) {
            const plugin_name = std.fs.path.basename(path);
            try self.tryStartHost(path, plugin_name, plugin_options);
            return;
        }
        try self.startFromPluginsDir(path, plugin_options);
    }

    fn startFromPluginsDir(self: *PluginManager, plugins_dir: []const u8, plugin_options: []const PluginOption) !void {
        var dir = std.fs.cwd().openDir(plugins_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var candidates = std.ArrayListUnmanaged(PluginCandidate){};
        defer {
            for (candidates.items) |cnd| {
                self.allocator.free(cnd.path);
                self.allocator.free(cnd.plugin_name);
            }
            candidates.deinit(self.allocator);
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

            const manifest = try self.readPluginManifest(full);
            if (!manifest.enabled) {
                self.allocator.free(full);
                continue;
            }
            try candidates.append(self.allocator, .{
                .path = full,
                .plugin_name = try self.allocator.dupe(u8, entry.name),
                .order = manifest.order,
            });
        }

        std.mem.sort(PluginCandidate, candidates.items, {}, lessThanCandidate);
        for (candidates.items) |candidate| {
            try self.tryStartHost(candidate.path, candidate.plugin_name, plugin_options);
        }
    }

    fn tryStartHost(self: *PluginManager, path: []const u8, plugin_name: []const u8, plugin_options: []const PluginOption) !void {
        var host_options = std.ArrayListUnmanaged(plugin_host.PluginHost.PluginConfigItem){};
        defer {
            for (host_options.items) |item| {
                self.allocator.free(item.key);
                self.allocator.free(item.value);
            }
            host_options.deinit(self.allocator);
        }
        for (plugin_options) |opt| {
            if (!std.mem.eql(u8, opt.plugin_name, plugin_name)) continue;
            try host_options.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, opt.key),
                .value = try self.allocator.dupe(u8, opt.value),
            });
        }
        const host = plugin_host.PluginHost.start(self.allocator, path, host_options.items) catch return;
        try self.hosts.append(self.allocator, host);
    }

    fn isPluginDir(allocator: std.mem.Allocator, path: []const u8) bool {
        const index_ts = std.fs.path.join(allocator, &.{ path, "index.ts" }) catch return false;
        defer allocator.free(index_ts);
        std.fs.cwd().access(index_ts, .{}) catch return false;
        return true;
    }

    const PluginManifest = struct {
        enabled: bool = true,
        order: i32 = 0,
    };

    const PluginCandidate = struct {
        path: []u8,
        plugin_name: []u8,
        order: i32,
    };

    fn readPluginManifest(self: *PluginManager, plugin_dir: []const u8) !PluginManifest {
        const manifest_path = try std.fs.path.join(self.allocator, &.{ plugin_dir, "plugin.toml" });
        defer self.allocator.free(manifest_path);

        const contents = std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 128 * 1024) catch return .{};
        defer self.allocator.free(contents);

        return parsePluginManifestContents(contents) catch .{};
    }

    fn parsePluginManifestContents(contents: []const u8) !PluginManifest {
        var manifest: PluginManifest = .{};
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            const value = trimQuotes(std.mem.trim(u8, line[eq_idx + 1 ..], " \t"));

            if (std.mem.eql(u8, key, "enabled")) {
                manifest.enabled = parseBool(value) catch manifest.enabled;
            } else if (std.mem.eql(u8, key, "order")) {
                manifest.order = std.fmt.parseInt(i32, value, 10) catch manifest.order;
            }
        }
        return manifest;
    }

    fn parseBool(value: []const u8) !bool {
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
        return error.InvalidBool;
    }

    fn trimQuotes(value: []const u8) []const u8 {
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return value[1 .. value.len - 1];
        }
        return value;
    }

    fn lessThanCandidate(_: void, a: PluginCandidate, b: PluginCandidate) bool {
        if (a.order != b.order) return a.order < b.order;
        return std.mem.lessThan(u8, a.plugin_name, b.plugin_name);
    }
};

test "plugin manifest parser reads enabled and order" {
    const testing = std.testing;
    const parsed = try PluginManager.parsePluginManifestContents(
        \\enabled=false
        \\order=7
        \\name="example"
    );
    try testing.expect(!parsed.enabled);
    try testing.expectEqual(@as(i32, 7), parsed.order);
}

test "plugin manifest parser defaults on invalid values" {
    const testing = std.testing;
    const parsed = try PluginManager.parsePluginManifestContents(
        \\enabled=maybe
        \\order=abc
    );
    try testing.expect(parsed.enabled);
    try testing.expectEqual(@as(i32, 0), parsed.order);
}
