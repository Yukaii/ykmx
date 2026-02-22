const std = @import("std");
const layout = @import("layout.zig");
const input_mod = @import("input.zig");
const posix = std.posix;

pub const PluginHost = struct {
    pub const PluginConfigItem = struct {
        key: []u8,
        value: []u8,
    };
    pub const UiBarsView = struct {
        toolbar_line: []const u8,
        tab_line: []const u8,
        status_line: []const u8,
    };

    pub const RuntimeState = struct {
        layout: []const u8,
        window_count: usize,
        minimized_window_count: usize,
        visible_window_count: usize,
        panel_count: usize,
        focused_panel_id: u32,
        has_focused_panel: bool,
        focused_index: usize,
        focused_window_id: u32,
        has_focused_window: bool,
        tab_count: usize,
        active_tab_index: usize,
        has_active_tab: bool,
        master_count: u16,
        master_ratio_permille: u16,
        mouse_mode: []const u8,
        sync_scroll_enabled: bool,
        screen: layout.Rect,
    };

    pub const TickStats = struct {
        reads: usize,
        resized: usize,
        popup_updates: usize,
        redraw: bool,
        detach_requested: bool,
        sigwinch: bool,
        sighup: bool,
        sigterm: bool,
    };

    pub const Action = union(enum) {
        cycle_layout,
        set_layout: layout.LayoutType,
        set_master_ratio_permille: u16,
        request_redraw,
        minimize_focused_window,
        restore_all_minimized_windows,
        move_focused_window_to_index: usize,
        move_window_by_id_to_index: struct { window_id: u32, index: usize },
        close_focused_window,
        restore_window_by_id: u32,
        register_command: struct { command: input_mod.Command, enabled: bool },
        open_shell_panel,
        close_focused_panel,
        cycle_panel_focus,
        toggle_shell_panel,
        open_shell_panel_rect: struct {
            x: u16,
            y: u16,
            width: u16,
            height: u16,
            modal: bool,
            transparent_background: bool,
            show_border: bool,
            show_controls: bool,
        },
        close_panel_by_id: u32,
        focus_panel_by_id: u32,
        move_panel_by_id: struct { panel_id: u32, x: u16, y: u16 },
        resize_panel_by_id: struct { panel_id: u32, width: u16, height: u16 },
        set_panel_style_by_id: struct {
            panel_id: u32,
            transparent_background: bool,
            show_border: bool,
            show_controls: bool,
        },
    };

    pub const PointerEvent = struct {
        x: u16,
        y: u16,
        button: u16,
        pressed: bool,
        motion: bool,
    };

    pub const PointerHit = struct {
        window_id: u32,
        window_index: usize,
        on_title_bar: bool,
        on_minimize_button: bool,
        on_maximize_button: bool,
        on_close_button: bool,
        on_minimized_toolbar: bool,
        on_restore_button: bool,
        is_panel: bool,
        panel_id: u32,
        panel_rect: layout.Rect,
        on_panel_title_bar: bool,
        on_panel_close_button: bool,
        on_panel_resize_left: bool,
        on_panel_resize_right: bool,
        on_panel_resize_top: bool,
        on_panel_resize_bottom: bool,
        on_panel_body: bool,
    };

    allocator: std.mem.Allocator,
    child: std.process.Child,
    alive: bool = true,
    next_request_id: u64 = 1,
    read_buf: std.ArrayListUnmanaged(u8) = .{},
    pending_actions: std.ArrayListUnmanaged(Action) = .{},
    config_items: std.ArrayListUnmanaged(PluginConfigItem) = .{},
    ui_bars: ?UiBars = null,
    ui_dirty: bool = false,

    const LayoutRect = struct {
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    };

    const LayoutResponse = struct {
        v: ?u8 = null,
        id: ?u64 = null,
        fallback: ?bool = null,
        rects: ?[]LayoutRect = null,
    };

    const ActionEnvelope = struct {
        v: ?u8 = null,
        action: ?[]const u8 = null,
        layout: ?[]const u8 = null,
        command: ?[]const u8 = null,
        enabled: ?bool = null,
        value: ?u16 = null,
        index: ?usize = null,
        window_id: ?u32 = null,
        panel_id: ?u32 = null,
        x: ?u16 = null,
        y: ?u16 = null,
        width: ?u16 = null,
        height: ?u16 = null,
        modal: ?bool = null,
        transparent_background: ?bool = null,
        show_border: ?bool = null,
        show_controls: ?bool = null,
        toolbar_line: ?[]const u8 = null,
        tab_line: ?[]const u8 = null,
        status_line: ?[]const u8 = null,
    };

    const UiBars = struct {
        toolbar_line: []u8,
        tab_line: []u8,
        status_line: []u8,
    };

    pub fn start(allocator: std.mem.Allocator, plugin_dir: []const u8, config_items: []const PluginConfigItem) !PluginHost {
        const entry = try std.fs.path.join(allocator, &.{ plugin_dir, "index.ts" });
        defer allocator.free(entry);
        std.fs.cwd().access(entry, .{}) catch return error.PluginEntryNotFound;

        var argv = [_][]const u8{ "bun", "run", entry };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.cwd = plugin_dir;
        try child.spawn();

        if (child.stdout) |stdout_file| {
            try setNonBlocking(stdout_file.handle);
        }

        var host = PluginHost{
            .allocator = allocator,
            .child = child,
        };
        errdefer host.deinit();

        for (config_items) |item| {
            try host.config_items.append(allocator, .{
                .key = try allocator.dupe(u8, item.key),
                .value = try allocator.dupe(u8, item.value),
            });
        }
        return host;
    }

    pub fn deinit(self: *PluginHost) void {
        self.read_buf.deinit(self.allocator);
        self.pending_actions.deinit(self.allocator);
        for (self.config_items.items) |item| {
            self.allocator.free(item.key);
            self.allocator.free(item.value);
        }
        self.config_items.deinit(self.allocator);
        self.clearUiBars();
        if (self.alive) {
            _ = self.child.kill() catch {};
            self.alive = false;
        } else {
            _ = self.child.wait() catch {};
        }
        self.* = undefined;
    }

    pub fn emitStart(self: *PluginHost, layout_type: layout.LayoutType) !void {
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_start\",\"layout\":\"{s}\"}}\n",
            .{@tagName(layout_type)},
        );
        try self.emitLine(line);
        for (self.config_items.items) |item| {
            try self.emitPluginConfig(item.key, item.value);
        }
    }

    fn emitPluginConfig(self: *PluginHost, key: []const u8, value: []const u8) !void {
        var buf: [320]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_plugin_config\",\"key\":\"{s}\",\"value\":\"{s}\"}}\n",
            .{ key, value },
        );
        try self.emitLine(line);
    }

    pub fn emitLayoutChanged(self: *PluginHost, layout_type: layout.LayoutType) !void {
        var buf: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_layout_changed\",\"layout\":\"{s}\"}}\n",
            .{@tagName(layout_type)},
        );
        try self.emitLine(line);
    }

    pub fn emitShutdown(self: *PluginHost) !void {
        try self.emitLine("{\"v\":1,\"event\":\"on_shutdown\"}\n");
    }

    pub fn emitStateChanged(
        self: *PluginHost,
        reason: []const u8,
        state: RuntimeState,
    ) !void {
        var buf: [640]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_state_changed\",\"reason\":\"{s}\",\"state\":{{\"layout\":\"{s}\",\"window_count\":{},\"minimized_window_count\":{},\"visible_window_count\":{},\"panel_count\":{},\"focused_panel_id\":{},\"has_focused_panel\":{},\"focused_index\":{},\"focused_window_id\":{},\"has_focused_window\":{},\"tab_count\":{},\"active_tab_index\":{},\"has_active_tab\":{},\"master_count\":{},\"master_ratio_permille\":{},\"mouse_mode\":\"{s}\",\"sync_scroll_enabled\":{},\"screen\":{{\"x\":{},\"y\":{},\"width\":{},\"height\":{}}}}}}}\n",
            .{
                reason,
                state.layout,
                state.window_count,
                state.minimized_window_count,
                state.visible_window_count,
                state.panel_count,
                state.focused_panel_id,
                state.has_focused_panel,
                state.focused_index,
                state.focused_window_id,
                state.has_focused_window,
                state.tab_count,
                state.active_tab_index,
                state.has_active_tab,
                state.master_count,
                state.master_ratio_permille,
                state.mouse_mode,
                state.sync_scroll_enabled,
                state.screen.x,
                state.screen.y,
                state.screen.width,
                state.screen.height,
            },
        );
        try self.emitLine(line);
    }

    pub fn emitTick(self: *PluginHost, stats: TickStats, state: RuntimeState) !void {
        var buf: [768]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_tick\",\"stats\":{{\"reads\":{},\"resized\":{},\"popup_updates\":{},\"redraw\":{},\"detach_requested\":{},\"sigwinch\":{},\"sighup\":{},\"sigterm\":{}}},\"state\":{{\"layout\":\"{s}\",\"window_count\":{},\"minimized_window_count\":{},\"visible_window_count\":{},\"panel_count\":{},\"focused_panel_id\":{},\"has_focused_panel\":{},\"focused_index\":{},\"focused_window_id\":{},\"has_focused_window\":{},\"tab_count\":{},\"active_tab_index\":{},\"has_active_tab\":{},\"master_count\":{},\"master_ratio_permille\":{},\"mouse_mode\":\"{s}\",\"sync_scroll_enabled\":{},\"screen\":{{\"x\":{},\"y\":{},\"width\":{},\"height\":{}}}}}}}\n",
            .{
                stats.reads,
                stats.resized,
                stats.popup_updates,
                stats.redraw,
                stats.detach_requested,
                stats.sigwinch,
                stats.sighup,
                stats.sigterm,
                state.layout,
                state.window_count,
                state.minimized_window_count,
                state.visible_window_count,
                state.panel_count,
                state.focused_panel_id,
                state.has_focused_panel,
                state.focused_index,
                state.focused_window_id,
                state.has_focused_window,
                state.tab_count,
                state.active_tab_index,
                state.has_active_tab,
                state.master_count,
                state.master_ratio_permille,
                state.mouse_mode,
                state.sync_scroll_enabled,
                state.screen.x,
                state.screen.y,
                state.screen.width,
                state.screen.height,
            },
        );
        try self.emitLine(line);
    }

    pub fn emitPointer(self: *PluginHost, pointer: PointerEvent, hit: ?PointerHit) !void {
        var buf: [1024]u8 = undefined;
        const line = if (hit) |h|
            try std.fmt.bufPrint(
                &buf,
                "{{\"v\":1,\"event\":\"on_pointer\",\"pointer\":{{\"x\":{},\"y\":{},\"button\":{},\"pressed\":{},\"motion\":{}}},\"hit\":{{\"window_id\":{},\"window_index\":{},\"on_title_bar\":{},\"on_minimize_button\":{},\"on_maximize_button\":{},\"on_close_button\":{},\"on_minimized_toolbar\":{},\"on_restore_button\":{},\"is_panel\":{},\"panel_id\":{},\"panel_rect\":{{\"x\":{},\"y\":{},\"width\":{},\"height\":{}}},\"on_panel_title_bar\":{},\"on_panel_close_button\":{},\"on_panel_resize_left\":{},\"on_panel_resize_right\":{},\"on_panel_resize_top\":{},\"on_panel_resize_bottom\":{},\"on_panel_body\":{}}}}}\n",
                .{ pointer.x, pointer.y, pointer.button, pointer.pressed, pointer.motion, h.window_id, h.window_index, h.on_title_bar, h.on_minimize_button, h.on_maximize_button, h.on_close_button, h.on_minimized_toolbar, h.on_restore_button, h.is_panel, h.panel_id, h.panel_rect.x, h.panel_rect.y, h.panel_rect.width, h.panel_rect.height, h.on_panel_title_bar, h.on_panel_close_button, h.on_panel_resize_left, h.on_panel_resize_right, h.on_panel_resize_top, h.on_panel_resize_bottom, h.on_panel_body },
            )
        else
            try std.fmt.bufPrint(
                &buf,
                "{{\"v\":1,\"event\":\"on_pointer\",\"pointer\":{{\"x\":{},\"y\":{},\"button\":{},\"pressed\":{},\"motion\":{}}}}}\n",
                .{ pointer.x, pointer.y, pointer.button, pointer.pressed, pointer.motion },
            );
        try self.emitLine(line);
    }

    pub fn emitCommand(self: *PluginHost, cmd: input_mod.Command) !void {
        var buf: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "{{\"v\":1,\"event\":\"on_command\",\"command\":\"{s}\"}}\n",
            .{input_mod.commandName(cmd)},
        );
        try self.emitLine(line);
    }

    pub fn uiBars(self: *const PluginHost) ?UiBarsView {
        const ui = self.ui_bars orelse return null;
        return .{
            .toolbar_line = ui.toolbar_line,
            .tab_line = ui.tab_line,
            .status_line = ui.status_line,
        };
    }

    pub fn consumeUiDirty(self: *PluginHost) bool {
        const dirty = self.ui_dirty;
        self.ui_dirty = false;
        return dirty;
    }

    pub fn requestLayout(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        params: layout.LayoutParams,
        timeout_ms: u16,
    ) !?[]layout.Rect {
        if (!self.alive) return null;

        const req_id = self.next_request_id;
        self.next_request_id += 1;

        var req_line = std.ArrayListUnmanaged(u8){};
        defer req_line.deinit(allocator);
        const writer = req_line.writer(allocator);
        try writer.print(
            "{{\"v\":1,\"id\":{},\"event\":\"on_compute_layout\",\"params\":{{\"layout\":\"{s}\",\"screen\":{{\"x\":{},\"y\":{},\"width\":{},\"height\":{}}},\"window_count\":{},\"window_ids\":[",
            .{
                req_id,
                @tagName(params.layout),
                params.screen.x,
                params.screen.y,
                params.screen.width,
                params.screen.height,
                params.window_count,
            },
        );
        for (params.window_ids, 0..) |window_id, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{}", .{window_id});
        }
        try writer.print(
            "],\"focused_index\":{},\"master_count\":{},\"master_ratio_permille\":{},\"gap\":{}}}}}\n",
            .{
                params.focused_index,
                params.master_count,
                params.master_ratio_permille,
                params.gap,
            },
        );
        try self.emitLine(req_line.items);

        const start_ms = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start_ms < timeout_ms) {
            if (try self.tryReadMatchingResponse(allocator, req_id)) |rects| {
                return rects;
            }
            if (!self.alive) return null;
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        return null;
    }

    pub fn drainActions(self: *PluginHost, allocator: std.mem.Allocator) ![]Action {
        var matched: ?[]layout.Rect = null;
        try self.readAvailableStdout();
        try self.processBufferedLines(allocator, null, &matched);

        if (self.pending_actions.items.len == 0) return allocator.alloc(Action, 0);
        const out = try allocator.alloc(Action, self.pending_actions.items.len);
        @memcpy(out, self.pending_actions.items);
        self.pending_actions.clearRetainingCapacity();
        return out;
    }

    fn emitLine(self: *PluginHost, line: []const u8) !void {
        if (!self.alive) return;
        const stdin_file = self.child.stdin orelse {
            self.alive = false;
            return;
        };
        stdin_file.writeAll(line) catch |err| switch (err) {
            error.BrokenPipe, error.NotOpenForWriting => {
                self.alive = false;
                return;
            },
            else => return err,
        };
    }

    fn tryReadMatchingResponse(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        request_id: u64,
    ) !?[]layout.Rect {
        if (!self.alive) return null;
        try self.readAvailableStdout();
        var matched: ?[]layout.Rect = null;
        try self.processBufferedLines(allocator, request_id, &matched);
        return matched;
    }

    fn processBufferedLines(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        expected_request_id: ?u64,
        matched: *?[]layout.Rect,
    ) !void {
        while (std.mem.indexOfScalar(u8, self.read_buf.items, '\n')) |nl_idx| {
            const line = self.read_buf.items[0..nl_idx];
            if (expected_request_id) |request_id| {
                if (try self.parseLayoutResponseLine(allocator, request_id, line)) |rects| {
                    matched.* = rects;
                }
            }
            if (self.parseActionLine(allocator, line)) |action| {
                try self.pending_actions.append(self.allocator, action);
            }
            self.consumeReadBufPrefix(nl_idx + 1);
        }
    }

    fn parseLayoutResponseLine(
        self: *PluginHost,
        allocator: std.mem.Allocator,
        request_id: u64,
        line: []const u8,
    ) !?[]layout.Rect {
        _ = self;
        if (line.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(LayoutResponse, arena.allocator(), line, .{}) catch return null;
        const response = parsed.value;
        if (response.id == null or response.id.? != request_id) return null;
        if (response.fallback orelse false) return null;
        const in_rects = response.rects orelse return null;
        if (in_rects.len == 0) {
            const empty = try allocator.alloc(layout.Rect, 0);
            return @as(?[]layout.Rect, empty);
        }

        const rects = try allocator.alloc(layout.Rect, in_rects.len);
        for (in_rects, 0..) |r, i| {
            rects[i] = .{
                .x = r.x,
                .y = r.y,
                .width = r.width,
                .height = r.height,
            };
        }
        return rects;
    }

    fn parseActionLine(self: *PluginHost, allocator: std.mem.Allocator, line: []const u8) ?Action {
        if (line.len == 0) return null;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const parsed = std.json.parseFromSlice(ActionEnvelope, arena.allocator(), line, .{}) catch return null;
        const envelope = parsed.value;
        const action_name = envelope.action orelse return null;

        if (std.mem.eql(u8, action_name, "cycle_layout")) return .cycle_layout;
        if (std.mem.eql(u8, action_name, "set_layout")) {
            const layout_name = envelope.layout orelse return null;
            const layout_type = parseLayoutType(layout_name) orelse return null;
            return .{ .set_layout = layout_type };
        }
        if (std.mem.eql(u8, action_name, "set_master_ratio_permille")) {
            const value = envelope.value orelse return null;
            return .{ .set_master_ratio_permille = value };
        }
        if (std.mem.eql(u8, action_name, "request_redraw")) return .request_redraw;
        if (std.mem.eql(u8, action_name, "minimize_focused_window")) return .minimize_focused_window;
        if (std.mem.eql(u8, action_name, "restore_all_minimized_windows")) return .restore_all_minimized_windows;
        if (std.mem.eql(u8, action_name, "move_focused_window_to_index")) {
            const idx = envelope.index orelse return null;
            return .{ .move_focused_window_to_index = idx };
        }
        if (std.mem.eql(u8, action_name, "move_window_by_id_to_index")) {
            const idx = envelope.index orelse return null;
            const window_id = envelope.window_id orelse return null;
            return .{ .move_window_by_id_to_index = .{ .window_id = window_id, .index = idx } };
        }
        if (std.mem.eql(u8, action_name, "close_focused_window")) return .close_focused_window;
        if (std.mem.eql(u8, action_name, "restore_window_by_id")) {
            const window_id = envelope.window_id orelse return null;
            return .{ .restore_window_by_id = window_id };
        }
        if (std.mem.eql(u8, action_name, "register_command")) {
            const command_name = envelope.command orelse return null;
            const command = input_mod.parseCommandName(command_name) orelse return null;
            return .{ .register_command = .{
                .command = command,
                .enabled = envelope.enabled orelse true,
            } };
        }
        if (std.mem.eql(u8, action_name, "open_shell_panel")) return .open_shell_panel;
        if (std.mem.eql(u8, action_name, "close_focused_panel")) return .close_focused_panel;
        if (std.mem.eql(u8, action_name, "cycle_panel_focus")) return .cycle_panel_focus;
        if (std.mem.eql(u8, action_name, "toggle_shell_panel")) return .toggle_shell_panel;
        if (std.mem.eql(u8, action_name, "open_shell_panel_rect")) {
            const x = envelope.x orelse return null;
            const y = envelope.y orelse return null;
            const width = envelope.width orelse return null;
            const height = envelope.height orelse return null;
            return .{ .open_shell_panel_rect = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
                .modal = envelope.modal orelse true,
                .transparent_background = envelope.transparent_background orelse false,
                .show_border = envelope.show_border orelse true,
                .show_controls = envelope.show_controls orelse false,
            } };
        }
        if (std.mem.eql(u8, action_name, "close_panel_by_id")) {
            const panel_id = envelope.panel_id orelse return null;
            return .{ .close_panel_by_id = panel_id };
        }
        if (std.mem.eql(u8, action_name, "focus_panel_by_id")) {
            const panel_id = envelope.panel_id orelse return null;
            return .{ .focus_panel_by_id = panel_id };
        }
        if (std.mem.eql(u8, action_name, "move_panel_by_id")) {
            const panel_id = envelope.panel_id orelse return null;
            const x = envelope.x orelse return null;
            const y = envelope.y orelse return null;
            return .{ .move_panel_by_id = .{ .panel_id = panel_id, .x = x, .y = y } };
        }
        if (std.mem.eql(u8, action_name, "resize_panel_by_id")) {
            const panel_id = envelope.panel_id orelse return null;
            const width = envelope.width orelse return null;
            const height = envelope.height orelse return null;
            return .{ .resize_panel_by_id = .{ .panel_id = panel_id, .width = width, .height = height } };
        }
        if (std.mem.eql(u8, action_name, "set_panel_style_by_id")) {
            const panel_id = envelope.panel_id orelse return null;
            return .{ .set_panel_style_by_id = .{
                .panel_id = panel_id,
                .transparent_background = envelope.transparent_background orelse false,
                .show_border = envelope.show_border orelse true,
                .show_controls = envelope.show_controls orelse false,
            } };
        }
        if (std.mem.eql(u8, action_name, "set_ui_bars")) {
            const toolbar = envelope.toolbar_line orelse return null;
            const tab = envelope.tab_line orelse return null;
            const status = envelope.status_line orelse return null;
            self.setUiBars(toolbar, tab, status) catch {};
            return null;
        }
        if (std.mem.eql(u8, action_name, "clear_ui_bars")) {
            self.clearUiBars();
            self.ui_dirty = true;
            return null;
        }
        return null;
    }

    fn setUiBars(self: *PluginHost, toolbar: []const u8, tab: []const u8, status: []const u8) !void {
        self.clearUiBars();
        self.ui_bars = .{
            .toolbar_line = try self.allocator.dupe(u8, toolbar),
            .tab_line = try self.allocator.dupe(u8, tab),
            .status_line = try self.allocator.dupe(u8, status),
        };
        self.ui_dirty = true;
    }

    fn clearUiBars(self: *PluginHost) void {
        if (self.ui_bars) |bars| {
            self.allocator.free(bars.toolbar_line);
            self.allocator.free(bars.tab_line);
            self.allocator.free(bars.status_line);
            self.ui_bars = null;
        }
    }

    fn parseLayoutType(name: []const u8) ?layout.LayoutType {
        if (std.mem.eql(u8, name, "vertical_stack")) return .vertical_stack;
        if (std.mem.eql(u8, name, "horizontal_stack")) return .horizontal_stack;
        if (std.mem.eql(u8, name, "grid")) return .grid;
        if (std.mem.eql(u8, name, "paperwm")) return .paperwm;
        if (std.mem.eql(u8, name, "fullscreen")) return .fullscreen;
        return null;
    }

    fn readAvailableStdout(self: *PluginHost) !void {
        const stdout_file = self.child.stdout orelse {
            self.alive = false;
            return;
        };

        var scratch: [1024]u8 = undefined;
        while (true) {
            const n = stdout_file.read(&scratch) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) {
                self.alive = false;
                break;
            }
            try self.read_buf.appendSlice(self.allocator, scratch[0..n]);
        }
    }

    fn consumeReadBufPrefix(self: *PluginHost, n: usize) void {
        const remaining = self.read_buf.items.len - n;
        if (remaining > 0) {
            @memmove(self.read_buf.items[0..remaining], self.read_buf.items[n..]);
        }
        self.read_buf.items.len = remaining;
    }

    fn setNonBlocking(fd: posix.fd_t) !void {
        var flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        const nonblock_bits_u32: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        flags |= @as(usize, nonblock_bits_u32);
        _ = try posix.fcntl(fd, posix.F.SETFL, flags);
    }
};
