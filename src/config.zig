const std = @import("std");
const layout = @import("layout.zig");

pub const LayoutBackend = enum {
    native,
    opentui,
};

pub const MouseMode = enum {
    hybrid,
    passthrough,
    compositor,
};

pub const Config = struct {
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

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.source_path) |p| allocator.free(p);
        if (self.plugin_dir) |p| allocator.free(p);
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    var cfg = Config{};

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
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "ykwm", "config" }));
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "ykwm", "config.zig" }));
    }
    if (home) |h| {
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ h, ".config", "ykwm", "config" }));
        try paths.append(allocator, try std.fs.path.join(allocator, &.{ h, ".config", "ykwm", "config.zig" }));
    }

    for (paths.items) |p| {
        std.fs.cwd().access(p, .{}) catch continue;
        return try allocator.dupe(u8, p);
    }
    return null;
}

pub fn parseContents(allocator: std.mem.Allocator, cfg: *Config, contents: []const u8) !void {
    _ = allocator;

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        const raw_value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        const value = trimQuotes(raw_value);
        try applyKeyValue(cfg, key, value);
    }
}

fn applyKeyValue(cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "layout_backend")) {
        if (std.mem.eql(u8, value, "native")) cfg.layout_backend = .native else if (std.mem.eql(u8, value, "opentui")) cfg.layout_backend = .opentui else return error.InvalidLayoutBackend;
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
    // Unknown keys are ignored for forward compatibility.
}

fn parseLayoutType(value: []const u8) !layout.LayoutType {
    if (std.mem.eql(u8, value, "vertical_stack")) return .vertical_stack;
    if (std.mem.eql(u8, value, "horizontal_stack")) return .horizontal_stack;
    if (std.mem.eql(u8, value, "grid")) return .grid;
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
}
