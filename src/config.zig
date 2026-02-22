const std = @import("std");
const layout = @import("layout.zig");

pub const LayoutBackend = enum {
    native,
    opentui,
    plugin,
};

pub const MouseMode = enum {
    hybrid,
    passthrough,
    compositor,
};

pub const Config = struct {
    pub const PluginSetting = struct {
        plugin_name: []u8,
        key: []u8,
        value: []u8,
    };

    source_path: ?[]u8 = null,
    layout_backend: LayoutBackend = .native,
    default_layout: layout.LayoutType = .vertical_stack,
    master_count: u16 = 1,
    master_ratio_permille: u16 = 600,
    gap: u16 = 0,
    show_tab_bar: bool = true,
    show_status_bar: bool = true,
    mouse_mode: MouseMode = .hybrid,
    plugins_enabled: bool = false,
    plugin_dir: ?[]u8 = null,
    plugins_dir: ?[]u8 = null,
    plugins_dirs: std.ArrayListUnmanaged([]u8) = .{},
    plugin_settings: std.ArrayListUnmanaged(PluginSetting) = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.source_path) |p| allocator.free(p);
        if (self.plugin_dir) |p| allocator.free(p);
        if (self.plugins_dir) |p| allocator.free(p);
        for (self.plugins_dirs.items) |p| allocator.free(p);
        self.plugins_dirs.deinit(allocator);
        for (self.plugin_settings.items) |s| {
            allocator.free(s.plugin_name);
            allocator.free(s.key);
            allocator.free(s.value);
        }
        self.plugin_settings.deinit(allocator);
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    var cfg = Config{};
    errdefer cfg.deinit(allocator);

    if (try discoverDefaultConfigPath(allocator)) |path| {
        defer allocator.free(path);
        try parseFile(allocator, &cfg, path);
    }

    return cfg;
}

pub fn parseFile(allocator: std.mem.Allocator, cfg: *Config, path: []const u8) !void {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(contents);

    if (cfg.source_path) |p| allocator.free(p);
    cfg.source_path = try allocator.dupe(u8, path);
    try parseContents(allocator, cfg, contents);
}

fn discoverDefaultConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    const xdg_config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (xdg_config_home) |v| allocator.free(v);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (home) |v| allocator.free(v);

    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    if (xdg_config_home) |xdg| {
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "ykmx", "config" }));
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "ykmx", "config.toml" }));
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "ykmx", "config.zig" }));
    }
    if (home) |h| {
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ h, ".config", "ykmx", "config" }));
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ h, ".config", "ykmx", "config.toml" }));
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ h, ".config", "ykmx", "config.zig" }));
    }

    for (paths.items) |p| {
        std.fs.cwd().access(p, .{}) catch continue;
        return try allocator.dupe(u8, p);
    }
    return null;
}

pub fn parseContents(allocator: std.mem.Allocator, cfg: *Config, contents: []const u8) !void {
    var pending_key: ?[]u8 = null;
    var pending_section: ?[]u8 = null;
    var pending_value = std.ArrayListUnmanaged(u8){};
    var section_plugin: ?[]u8 = null;
    defer {
        if (pending_key) |k| allocator.free(k);
        if (pending_section) |s| allocator.free(s);
        if (section_plugin) |s| allocator.free(s);
        pending_value.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (pending_key != null) {
            if (pending_value.items.len > 0) try pending_value.append(allocator, ' ');
            try pending_value.appendSlice(allocator, line);
            if (line[line.len - 1] == ']') {
                const key = pending_key.?;
                const section = pending_section;
                pending_key = null;
                pending_section = null;
                defer allocator.free(key);
                defer if (section) |s| allocator.free(s);
                const value = trimQuotes(std.mem.trim(u8, pending_value.items, " \t"));
                if (section) |plugin_name| {
                    try setPluginSetting(allocator, cfg, plugin_name, key, value);
                } else {
                    try applyKeyValue(allocator, cfg, key, value);
                }
                pending_value.clearRetainingCapacity();
            }
            continue;
        }

        if (line[0] == '[' and line[line.len - 1] == ']') {
            if (section_plugin) |old| allocator.free(old);
            section_plugin = null;

            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (std.mem.startsWith(u8, name, "plugin.")) {
                const plugin_name = std.mem.trim(u8, name["plugin.".len..], " \t");
                if (plugin_name.len > 0) {
                    section_plugin = try allocator.dupe(u8, plugin_name);
                }
            }
            continue;
        }

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const raw_value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        if (raw_value.len > 0 and raw_value[0] == '[' and raw_value[raw_value.len - 1] != ']') {
            pending_key = try allocator.dupe(u8, key);
            pending_section = if (section_plugin) |s| try allocator.dupe(u8, s) else null;
            try pending_value.appendSlice(allocator, raw_value);
            continue;
        }
        const value = trimQuotes(raw_value);
        if (section_plugin) |plugin_name| {
            try setPluginSetting(allocator, cfg, plugin_name, key, value);
        } else {
            try applyKeyValue(allocator, cfg, key, value);
        }
    }

    if (pending_key != null) return error.InvalidConfigLine;
}

fn setPluginSetting(
    allocator: std.mem.Allocator,
    cfg: *Config,
    plugin_name: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    for (cfg.plugin_settings.items) |*s| {
        if (!std.mem.eql(u8, s.plugin_name, plugin_name)) continue;
        if (!std.mem.eql(u8, s.key, key)) continue;
        allocator.free(s.value);
        s.value = try allocator.dupe(u8, value);
        return;
    }
    try cfg.plugin_settings.append(allocator, .{
        .plugin_name = try allocator.dupe(u8, plugin_name),
        .key = try allocator.dupe(u8, key),
        .value = try allocator.dupe(u8, value),
    });
}

fn applyKeyValue(allocator: std.mem.Allocator, cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "layout_backend")) {
        if (std.mem.eql(u8, value, "native")) cfg.layout_backend = .native else if (std.mem.eql(u8, value, "opentui")) cfg.layout_backend = .opentui else if (std.mem.eql(u8, value, "plugin")) cfg.layout_backend = .plugin else return error.InvalidLayoutBackend;
        return;
    }
    if (std.mem.eql(u8, key, "default_layout")) {
        cfg.default_layout = try parseLayoutType(value);
        return;
    }
    if (std.mem.eql(u8, key, "master_count")) {
        cfg.master_count = try std.fmt.parseInt(u16, value, 10);
        return;
    }
    if (std.mem.eql(u8, key, "master_ratio_permille")) {
        const ratio = try std.fmt.parseInt(u16, value, 10);
        if (ratio > 1000) return error.InvalidMasterRatio;
        cfg.master_ratio_permille = ratio;
        return;
    }
    if (std.mem.eql(u8, key, "gap")) {
        cfg.gap = try std.fmt.parseInt(u16, value, 10);
        return;
    }
    if (std.mem.eql(u8, key, "show_tab_bar")) {
        cfg.show_tab_bar = try parseBool(value);
        return;
    }
    if (std.mem.eql(u8, key, "show_status_bar")) {
        cfg.show_status_bar = try parseBool(value);
        return;
    }
    if (std.mem.eql(u8, key, "mouse_mode")) {
        cfg.mouse_mode = try parseMouseMode(value);
        return;
    }
    // Backward compatibility: legacy boolean knob.
    if (std.mem.eql(u8, key, "mouse_passthrough")) {
        cfg.mouse_mode = if (try parseBool(value)) .passthrough else .compositor;
        return;
    }
    if (std.mem.eql(u8, key, "plugins_enabled")) {
        cfg.plugins_enabled = try parseBool(value);
        return;
    }
    if (std.mem.eql(u8, key, "plugin_dir")) {
        if (cfg.plugin_dir) |p| allocator.free(p);
        cfg.plugin_dir = try allocator.dupe(u8, value);
        return;
    }
    if (std.mem.eql(u8, key, "plugins_dir")) {
        if (cfg.plugins_dir) |p| allocator.free(p);
        cfg.plugins_dir = try allocator.dupe(u8, value);
        return;
    }
    if (std.mem.eql(u8, key, "plugins_dirs")) {
        try setPluginsDirs(allocator, cfg, value);
        return;
    }
    // Unknown keys are ignored for forward compatibility.
}

fn setPluginsDirs(allocator: std.mem.Allocator, cfg: *Config, value: []const u8) !void {
    var parsed = std.ArrayListUnmanaged([]u8){};
    errdefer {
        for (parsed.items) |p| allocator.free(p);
        parsed.deinit(allocator);
    }

    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) {
        for (cfg.plugins_dirs.items) |p| allocator.free(p);
        cfg.plugins_dirs.clearRetainingCapacity();
        return;
    }

    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
        if (inner.len > 0) {
            var it = std.mem.splitScalar(u8, inner, ',');
            while (it.next()) |part_raw| {
                const part = trimQuotes(std.mem.trim(u8, part_raw, " \t"));
                if (part.len == 0) continue;
                try parsed.append(allocator, try allocator.dupe(u8, part));
            }
        }
    } else {
        var it = std.mem.splitScalar(u8, trimmed, ',');
        while (it.next()) |part_raw| {
            const part = trimQuotes(std.mem.trim(u8, part_raw, " \t"));
            if (part.len == 0) continue;
            try parsed.append(allocator, try allocator.dupe(u8, part));
        }
    }

    for (cfg.plugins_dirs.items) |p| allocator.free(p);
    cfg.plugins_dirs.deinit(allocator);
    cfg.plugins_dirs = parsed;
    parsed = .{};
}

fn parseLayoutType(value: []const u8) !layout.LayoutType {
    if (std.mem.eql(u8, value, "vertical_stack")) return .vertical_stack;
    if (std.mem.eql(u8, value, "horizontal_stack")) return .horizontal_stack;
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "paperwm")) return .paperwm;
    if (std.mem.eql(u8, value, "fullscreen")) return .fullscreen;
    return error.InvalidLayoutType;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBool;
}

fn parseMouseMode(value: []const u8) !MouseMode {
    if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
    if (std.mem.eql(u8, value, "passthrough")) return .passthrough;
    if (std.mem.eql(u8, value, "compositor")) return .compositor;
    return error.InvalidMouseMode;
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

test "config parser applies known keys" {
    const testing = std.testing;
    var cfg = Config{};
    defer cfg.deinit(testing.allocator);

    try parseContents(testing.allocator, &cfg,
        \\layout_backend=opentui
        \\default_layout=grid
        \\master_count=2
        \\master_ratio_permille=700
        \\gap=1
        \\show_tab_bar=false
        \\show_status_bar=true
        \\mouse_mode=compositor
        \\plugins_enabled=1
        \\plugin_dir=/tmp/ykmx-plugins
        \\plugins_dir=/tmp/ykmx-plugins.d
        \\plugins_dirs=["/tmp/plugins-a","/tmp/plugins-b"]
    );

    try testing.expectEqual(LayoutBackend.opentui, cfg.layout_backend);
    try testing.expectEqual(layout.LayoutType.grid, cfg.default_layout);
    try testing.expectEqual(@as(u16, 2), cfg.master_count);
    try testing.expectEqual(@as(u16, 700), cfg.master_ratio_permille);
    try testing.expectEqual(@as(u16, 1), cfg.gap);
    try testing.expect(!cfg.show_tab_bar);
    try testing.expect(cfg.show_status_bar);
    try testing.expectEqual(MouseMode.compositor, cfg.mouse_mode);
    try testing.expect(cfg.plugins_enabled);
    try testing.expectEqualStrings("/tmp/ykmx-plugins", cfg.plugin_dir.?);
    try testing.expectEqualStrings("/tmp/ykmx-plugins.d", cfg.plugins_dir.?);
    try testing.expectEqual(@as(usize, 2), cfg.plugins_dirs.items.len);
    try testing.expectEqualStrings("/tmp/plugins-a", cfg.plugins_dirs.items[0]);
    try testing.expectEqualStrings("/tmp/plugins-b", cfg.plugins_dirs.items[1]);
}

test "config parser accepts plugins_dirs csv" {
    const testing = std.testing;
    var cfg = Config{};
    defer cfg.deinit(testing.allocator);

    try parseContents(testing.allocator, &cfg, "plugins_dirs=/a,/b,/c\n");
    try testing.expectEqual(@as(usize, 3), cfg.plugins_dirs.items.len);
    try testing.expectEqualStrings("/a", cfg.plugins_dirs.items[0]);
    try testing.expectEqualStrings("/b", cfg.plugins_dirs.items[1]);
    try testing.expectEqualStrings("/c", cfg.plugins_dirs.items[2]);
}

test "config parser accepts multiline plugins_dirs array" {
    const testing = std.testing;
    var cfg = Config{};
    defer cfg.deinit(testing.allocator);

    try parseContents(testing.allocator, &cfg,
        \\plugins_dirs=[
        \\  "/x/a",
        \\  "/x/b",
        \\]
    );
    try testing.expectEqual(@as(usize, 2), cfg.plugins_dirs.items.len);
    try testing.expectEqualStrings("/x/a", cfg.plugins_dirs.items[0]);
    try testing.expectEqualStrings("/x/b", cfg.plugins_dirs.items[1]);
}

test "config parser supports per-plugin section settings" {
    const testing = std.testing;
    var cfg = Config{};
    defer cfg.deinit(testing.allocator);

    try parseContents(testing.allocator, &cfg,
        \\[plugin.sidebar-panel]
        \\side=right
        \\width=40
        \\[plugin.bottom-panel]
        \\height=12
    );
    try testing.expectEqual(@as(usize, 3), cfg.plugin_settings.items.len);

    var found_side = false;
    var found_width = false;
    var found_height = false;
    for (cfg.plugin_settings.items) |s| {
        if (std.mem.eql(u8, s.plugin_name, "sidebar-panel") and std.mem.eql(u8, s.key, "side") and std.mem.eql(u8, s.value, "right")) found_side = true;
        if (std.mem.eql(u8, s.plugin_name, "sidebar-panel") and std.mem.eql(u8, s.key, "width") and std.mem.eql(u8, s.value, "40")) found_width = true;
        if (std.mem.eql(u8, s.plugin_name, "bottom-panel") and std.mem.eql(u8, s.key, "height") and std.mem.eql(u8, s.value, "12")) found_height = true;
    }
    try testing.expect(found_side);
    try testing.expect(found_width);
    try testing.expect(found_height);
}

test "config parser accepts paperwm layout type" {
    const testing = std.testing;
    var cfg = Config{};
    defer cfg.deinit(testing.allocator);

    try parseContents(testing.allocator, &cfg, "default_layout=paperwm\n");
    try testing.expectEqual(layout.LayoutType.paperwm, cfg.default_layout);
}

test "config parser accepts plugin layout backend" {
    const testing = std.testing;
    var cfg = Config{};
    defer cfg.deinit(testing.allocator);

    try parseContents(testing.allocator, &cfg, "layout_backend=plugin\n");
    try testing.expectEqual(LayoutBackend.plugin, cfg.layout_backend);
}
