const std = @import("std");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const pty_mod = @import("pty.zig");
const input_mod = @import("input.zig");
const signal_mod = @import("signal.zig");
const popup_mod = @import("popup.zig");
const scrollback_mod = @import("scrollback.zig");

pub const Multiplexer = struct {
    pub const WindowChromeHit = struct {
        window_id: u32,
        window_index: usize,
        on_title_bar: bool,
        on_minimize_button: bool,
        on_maximize_button: bool,
        on_close_button: bool,
        on_minimized_toolbar: bool = false,
        on_restore_button: bool = false,
    };

    pub const MouseMode = enum {
        hybrid,
        passthrough,
        compositor,
    };

    const FocusDirection = enum {
        left,
        right,
        up,
        down,
    };

    const DaParseState = enum(u3) {
        idle,
        esc,
        csi_entry,
        csi_other,
        csi_6,
    };

    const DragState = struct {
        const Axis = enum {
            none,
            vertical,
            horizontal,
        };

        axis: Axis = .none,
    };

    allocator: std.mem.Allocator,
    workspace_mgr: workspace.WorkspaceManager,
    popup_mgr: popup_mod.PopupManager,
    ptys: std.AutoHashMapUnmanaged(u32, pty_mod.Pty) = .{},
    stdout_buffers: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u8)) = .{},
    scrollbacks: std.AutoHashMapUnmanaged(u32, scrollback_mod.ScrollbackBuffer) = .{},
    selection_cursor_x: std.AutoHashMapUnmanaged(u32, usize) = .{},
    selection_cursor_y: std.AutoHashMapUnmanaged(u32, usize) = .{},
    dirty_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    da_parse_states: std.AutoHashMapUnmanaged(u32, DaParseState) = .{},
    mouse_tracking_enabled: std.AutoHashMapUnmanaged(u32, void) = .{},
    input_router: input_mod.Router = .{},
    detach_requested: bool = false,
    sync_scroll_enabled: bool = false,
    sync_scroll_source_window_id: ?u32 = null,
    scrollback_query_mode: bool = false,
    scrollback_query_len: u16 = 0,
    scrollback_query_buf: [256]u8 = [_]u8{0} ** 256,
    scrollback_last_query_len: u16 = 0,
    scrollback_last_query_buf: [256]u8 = [_]u8{0} ** 256,
    scrollback_last_direction: scrollback_mod.SearchDirection = .backward,
    last_mouse_event: ?input_mod.MouseEvent = null,
    drag_state: DragState = .{},
    hybrid_forward_click_active: bool = false,
    mouse_mode: MouseMode = .hybrid,
    next_popup_window_id: u32 = 1_000_000,
    redraw_requested: bool = false,
    last_screen: ?layout.Rect = null,

    pub const TickResult = struct {
        reads: usize,
        resized: usize,
        popup_updates: usize,
        redraw: bool,
        should_shutdown: bool,
        detach_requested: bool,
    };

    pub const ReattachResult = struct {
        resized: usize,
        marked_dirty: usize,
        redraw: bool,
    };

    pub fn init(allocator: std.mem.Allocator, layout_engine: layout.LayoutEngine) Multiplexer {
        return .{
            .allocator = allocator,
            .workspace_mgr = workspace.WorkspaceManager.init(allocator, layout_engine),
            .popup_mgr = popup_mod.PopupManager.init(allocator),
        };
    }

    pub fn deinit(self: *Multiplexer) void {
        var it_ptys = self.ptys.iterator();
        while (it_ptys.next()) |entry| {
            var p = entry.value_ptr.*;
            p.deinitNoWait();
        }
        self.ptys.deinit(self.allocator);

        var it_buf = self.stdout_buffers.iterator();
        while (it_buf.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.stdout_buffers.deinit(self.allocator);

        var it_sb = self.scrollbacks.iterator();
        while (it_sb.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.scrollbacks.deinit(self.allocator);
        self.selection_cursor_x.deinit(self.allocator);
        self.selection_cursor_y.deinit(self.allocator);
        self.dirty_windows.deinit(self.allocator);
        self.da_parse_states.deinit(self.allocator);
        self.mouse_tracking_enabled.deinit(self.allocator);

        self.popup_mgr.deinit();
        self.workspace_mgr.deinit();
        self.* = undefined;
    }

    pub fn createTab(self: *Multiplexer, name: []const u8) !usize {
        return self.workspace_mgr.createTab(name);
    }

    pub fn switchTab(self: *Multiplexer, index: usize) !void {
        try self.workspace_mgr.switchTab(index);
    }

    pub fn setMouseMode(self: *Multiplexer, mode: MouseMode) void {
        self.mouse_mode = mode;
    }

    pub fn mouseMode(self: *const Multiplexer) MouseMode {
        return self.mouse_mode;
    }

    pub fn setMousePassthrough(self: *Multiplexer, enabled: bool) void {
        self.mouse_mode = if (enabled) .passthrough else .compositor;
    }

    pub fn mousePassthrough(self: *const Multiplexer) bool {
        return self.mouse_mode == .passthrough;
    }

    pub fn createShellWindow(self: *Multiplexer, title: []const u8) !u32 {
        const id = try self.workspace_mgr.addWindowToActive(title);
        var p = try pty_mod.Pty.spawnShell(self.allocator);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, id, p);
        try self.stdout_buffers.put(self.allocator, id, .{});
        try self.scrollbacks.put(self.allocator, id, scrollback_mod.ScrollbackBuffer.init(self.allocator, 10_000));
        try self.selection_cursor_x.put(self.allocator, id, 0);
        try self.selection_cursor_y.put(self.allocator, id, 0);
        try self.da_parse_states.put(self.allocator, id, .idle);
        _ = self.mouse_tracking_enabled.fetchRemove(id);
        return id;
    }

    pub fn createCommandWindow(self: *Multiplexer, title: []const u8, argv: []const []const u8) !u32 {
        const id = try self.workspace_mgr.addWindowToActive(title);
        var p = try pty_mod.Pty.spawnCommand(self.allocator, argv);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, id, p);
        try self.stdout_buffers.put(self.allocator, id, .{});
        try self.scrollbacks.put(self.allocator, id, scrollback_mod.ScrollbackBuffer.init(self.allocator, 10_000));
        try self.selection_cursor_x.put(self.allocator, id, 0);
        try self.selection_cursor_y.put(self.allocator, id, 0);
        try self.da_parse_states.put(self.allocator, id, .idle);
        _ = self.mouse_tracking_enabled.fetchRemove(id);
        return id;
    }

    pub fn computeActiveLayout(self: *Multiplexer, screen: layout.Rect) ![]layout.Rect {
        return self.workspace_mgr.computeActiveLayout(screen);
    }

    pub fn sendInputToFocused(self: *Multiplexer, bytes: []const u8) !void {
        const focused_id = try self.workspace_mgr.focusedWindowIdActive();
        try self.sendInputToWindow(focused_id, bytes);
    }

    fn sendInputToFocusedPopup(self: *Multiplexer, bytes: []const u8) !void {
        const focused_id = self.popup_mgr.focusedWindowId() orelse return error.NoFocusedPopup;
        try self.sendInputToWindow(focused_id, bytes);
    }

    pub fn handleInputBytes(self: *Multiplexer, bytes: []const u8) !void {
        return self.handleInputBytesWithScreen(null, bytes);
    }

    pub fn handleInputBytesWithScreen(
        self: *Multiplexer,
        screen: ?layout.Rect,
        bytes: []const u8,
    ) !void {
        if (screen) |s| self.last_screen = s;
        for (bytes) |b| {
            const ev = self.input_router.feedByte(b);
            switch (ev) {
                .forward => |c| {
                    if (self.handleScrollbackQueryByte(c, screen)) continue;
                    if (self.handleScrollbackNavForwardByte(c, screen)) continue;
                    var tmp = [_]u8{c};
                    if (self.popup_mgr.hasModalOpen()) {
                        self.sendInputToFocusedPopup(&tmp) catch |err| switch (err) {
                            error.NoFocusedPopup, error.UnknownWindow => {},
                            else => return err,
                        };
                    } else {
                        self.sendInputToFocused(&tmp) catch |err| switch (err) {
                            error.NoFocusedWindow, error.UnknownWindow => {},
                            else => return err,
                        };
                    }
                },
                .forward_sequence => |seq| {
                    if (self.handleScrollbackQuerySequence(seq.slice(), screen)) continue;
                    var consumed_mouse = false;
                    if (screen) |s| {
                        if (seq.mouse) |mouse| {
                            switch (self.mouse_mode) {
                                .compositor => {
                                    consumed_mouse = true;
                                    self.handleMouseFromEvent(s, mouse) catch |err| switch (err) {
                                        error.OutOfMemory => return err,
                                        else => {},
                                    };
                                },
                                .hybrid => {
                                    consumed_mouse = self.handleMouseHybrid(s, mouse) catch |err| switch (err) {
                                        error.OutOfMemory => return err,
                                        else => false,
                                    };
                                },
                                .passthrough => {},
                            }
                        }
                    }
                    if (!consumed_mouse) {
                        if (self.handleScrollbackNavSequence(seq.slice(), screen)) continue;
                        if (self.isFocusedScrolledBack()) continue;
                        if (self.popup_mgr.hasModalOpen()) {
                            self.sendInputToFocusedPopup(seq.slice()) catch |err| switch (err) {
                                error.NoFocusedPopup, error.UnknownWindow => {},
                                else => return err,
                            };
                        } else {
                            self.sendInputToFocused(seq.slice()) catch |err| switch (err) {
                                error.NoFocusedWindow, error.UnknownWindow => {},
                                else => return err,
                            };
                        }
                    }
                    if (seq.mouse) |mouse| self.last_mouse_event = mouse;
                },
                .command => |cmd| switch (cmd) {
                    .create_window => {
                        _ = try self.createShellWindow("shell");
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .close_window => {
                        _ = try self.closeFocusedWindow();
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .open_popup => {
                        if (self.popup_mgr.count() > 0) {
                            try self.closeFocusedPopup();
                        } else {
                            const s = screen orelse layout.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
                            _ = try self.openShellPopup("popup-shell", s, true);
                        }
                        self.requestRedraw();
                    },
                    .close_popup => {
                        try self.closeFocusedPopup();
                        self.requestRedraw();
                    },
                    .cycle_popup => {
                        self.popup_mgr.cycleFocus();
                        self.requestRedraw();
                    },
                    .new_tab => {
                        const n = self.workspace_mgr.tabCount();
                        var name_buf: [32]u8 = undefined;
                        const name = try std.fmt.bufPrint(&name_buf, "tab-{d}", .{n + 1});
                        const idx = try self.createTab(name);
                        try self.switchTab(idx);
                        _ = try self.createShellWindow("shell");
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .close_tab => {
                        self.closeActiveTab() catch |err| {
                            if (err != error.CannotCloseLastTab) return err;
                        };
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .next_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 0) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            try self.switchTab((current + 1) % n);
                            if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                    },
                    .prev_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 0) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            const prev = if (current == 0) n - 1 else current - 1;
                            try self.switchTab(prev);
                            if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                    },
                    .move_window_next_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 1) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            const dst = (current + 1) % n;
                            try self.workspace_mgr.moveFocusedWindowToTab(dst);
                            if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                    },
                    .next_window => {
                        try self.workspace_mgr.focusNextWindowActive();
                        if (self.sync_scroll_enabled) try self.propagateSyncScrollFromFocused(screen);
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .prev_window => {
                        try self.workspace_mgr.focusPrevWindowActive();
                        if (self.sync_scroll_enabled) try self.propagateSyncScrollFromFocused(screen);
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .focus_left => {
                        if (screen) |s| {
                            try self.focusDirectional(s, .left);
                        } else {
                            try self.workspace_mgr.focusPrevWindowActive();
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                        if (self.sync_scroll_enabled) try self.propagateSyncScrollFromFocused(screen);
                    },
                    .focus_down => {
                        if (screen) |s| {
                            try self.focusDirectional(s, .down);
                        } else {
                            try self.workspace_mgr.focusNextWindowActive();
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                        if (self.sync_scroll_enabled) try self.propagateSyncScrollFromFocused(screen);
                    },
                    .focus_up => {
                        if (screen) |s| {
                            try self.focusDirectional(s, .up);
                        } else {
                            try self.workspace_mgr.focusPrevWindowActive();
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                        if (self.sync_scroll_enabled) try self.propagateSyncScrollFromFocused(screen);
                    },
                    .focus_right => {
                        if (screen) |s| {
                            try self.focusDirectional(s, .right);
                        } else {
                            try self.workspace_mgr.focusNextWindowActive();
                            _ = try self.markActiveWindowsDirty();
                            self.requestRedraw();
                        }
                        if (self.sync_scroll_enabled) try self.propagateSyncScrollFromFocused(screen);
                    },
                    .zoom_to_master => {
                        _ = try self.workspace_mgr.zoomFocusedToMasterActive();
                        if (screen) |s| {
                            _ = try self.resizeActiveWindowsToLayout(s);
                        }
                        _ = try self.markActiveWindowsDirty();
                        self.requestRedraw();
                    },
                    .cycle_layout => {
                        _ = try self.workspace_mgr.cycleActiveLayout();
                        if (screen) |s| {
                            _ = try self.resizeActiveWindowsToLayout(s);
                        }
                        _ = try self.markActiveWindowsDirty();
                    },
                    .resize_master_shrink => {
                        const current = try self.workspace_mgr.activeMasterRatioPermille();
                        const next = if (current <= 100) 100 else current - 50;
                        try self.workspace_mgr.setActiveMasterRatioPermille(next);
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                    },
                    .resize_master_grow => {
                        const current = try self.workspace_mgr.activeMasterRatioPermille();
                        const next = if (current >= 900) 900 else current + 50;
                        try self.workspace_mgr.setActiveMasterRatioPermille(next);
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                    },
                    .master_count_increase => {
                        const current = try self.workspace_mgr.activeMasterCount();
                        try self.workspace_mgr.setActiveMasterCount(current + 1);
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                    },
                    .master_count_decrease => {
                        const current = try self.workspace_mgr.activeMasterCount();
                        try self.workspace_mgr.setActiveMasterCount(if (current <= 1) 1 else current - 1);
                        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
                        _ = try self.markActiveWindowsDirty();
                    },
                    .scroll_page_up => {
                        const lines: usize = if (screen) |s| s.height else 24;
                        self.scrollPageUpFocused(lines);
                    },
                    .scroll_page_down => {
                        const lines: usize = if (screen) |s| s.height else 24;
                        self.scrollPageDownFocused(lines);
                    },
                    .toggle_sync_scroll => {
                        try self.setVisibleScrollOffsetFromSource(screen, 0);
                        try self.setSyncScrollEnabled(!self.sync_scroll_enabled, screen);
                        self.requestRedraw();
                    },
                    .toggle_mouse_passthrough => {
                        self.mouse_mode = switch (self.mouse_mode) {
                            .hybrid => .passthrough,
                            .passthrough => .compositor,
                            .compositor => .hybrid,
                        };
                        self.requestRedraw();
                    },
                    .detach => {
                        self.detach_requested = true;
                    },
                },
                .noop => {},
            }
        }
    }

    pub fn resizeActiveWindowsToLayout(self: *Multiplexer, screen: layout.Rect) !usize {
        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);

        const tab = try self.workspace_mgr.activeTab();
        var resized: usize = 0;

        const n = @min(tab.windows.items.len, rects.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const w = tab.windows.items[i];
            const p = self.ptys.getPtr(w.id) orelse continue;
            const r = rects[i];
            if (r.width == 0 or r.height == 0) {
                // Hidden panes (e.g. fullscreen non-focused windows) keep their PTY alive
                // but are not resized to an invalid 0x0 geometry.
                continue;
            }
            const inner = contentSizeForRect(rects[0..n], i, r, screen);
            try p.resize(inner.rows, inner.cols);
            try self.markWindowDirty(w.id);
            resized += 1;
        }

        return resized;
    }

    pub fn pollOnce(self: *Multiplexer, timeout_ms: i32) !usize {
        var pollfds: std.ArrayListUnmanaged(posixPollFd()) = .{};
        defer pollfds.deinit(self.allocator);

        var ids: std.ArrayListUnmanaged(u32) = .{};
        defer ids.deinit(self.allocator);

        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            const w_id = entry.key_ptr.*;
            const p = entry.value_ptr;
            const out = p.stdoutFile() orelse continue;

            try ids.append(self.allocator, w_id);
            try pollfds.append(self.allocator, .{
                .fd = out.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
        }

        if (pollfds.items.len == 0) return 0;

        const ready = try std.posix.poll(pollfds.items, timeout_ms);
        if (ready == 0) return 0;

        var reads: usize = 0;
        var tmp: [4096]u8 = undefined;

        for (pollfds.items, 0..) |fd, i| {
            if ((fd.revents & std.posix.POLL.IN) == 0 and (fd.revents & std.posix.POLL.HUP) == 0) continue;

            const w_id = ids.items[i];
            const p = self.ptys.getPtr(w_id) orelse continue;
            const n = try p.readStdout(&tmp);
            if (n == 0) continue;

            const out_buf = self.stdout_buffers.getPtr(w_id) orelse return error.MissingOutputBuffer;
            try out_buf.appendSlice(self.allocator, tmp[0..n]);
            if (self.scrollbacks.getPtr(w_id)) |sb| {
                try sb.append(tmp[0..n]);
            }
            if (self.da_parse_states.getPtr(w_id)) |state| {
                const queries = countTerminalQueries(state, tmp[0..n]);
                var q: usize = 0;
                while (q < queries.da) : (q += 1) {
                    // Respond to primary DA query for fish compatibility checks.
                    try p.write("\x1b[?62;c");
                }
                q = 0;
                while (q < queries.cpr) : (q += 1) {
                    // Respond to CPR query (CSI 6n). Keep simple/stable for now.
                    try p.write("\x1b[1;1R");
                }
            }
            self.updateWindowMouseTrackingFromOutput(w_id, tmp[0..n]) catch {};
            try self.markWindowDirty(w_id);
            reads += 1;
        }

        return reads;
    }

    pub fn windowOutput(self: *Multiplexer, window_id: u32) ![]const u8 {
        const list = self.stdout_buffers.getPtr(window_id) orelse return error.UnknownWindow;
        return list.items;
    }

    pub fn clearWindowOutput(self: *Multiplexer, window_id: u32) !void {
        const list = self.stdout_buffers.getPtr(window_id) orelse return error.UnknownWindow;
        list.clearRetainingCapacity();
    }

    pub fn focusedWindowId(self: *Multiplexer) !u32 {
        return self.workspace_mgr.focusedWindowIdActive();
    }

    pub fn windowChromeHitAt(self: *Multiplexer, screen: layout.Rect, px: u16, py: u16) !?WindowChromeHit {
        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);

        const tab = try self.workspace_mgr.activeTab();
        const n = @min(rects.len, tab.windows.items.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = rects[i];
            if (r.width < 2 or r.height < 2) continue;

            const inside_x = px >= r.x and px < (r.x + r.width);
            const inside_y = py >= r.y and py < (r.y + r.height);
            if (!(inside_x and inside_y)) continue;

            const on_title_bar = py == r.y and px > r.x and px < (r.x + r.width - 1);
            // Controls render as "[_][+][x]" anchored to right border.
            // Symbol cells are at offsets: '_' => -9, '+' => -6, 'x' => -3.
            const on_close_button = on_title_bar and r.width >= 5 and px == (r.x + r.width - 3);
            const on_maximize_button = on_title_bar and r.width >= 8 and px == (r.x + r.width - 6);
            const on_minimize_button = on_title_bar and r.width >= 11 and px == (r.x + r.width - 9);

            return .{
                .window_id = tab.windows.items[i].id,
                .window_index = i,
                .on_title_bar = on_title_bar,
                .on_minimize_button = on_minimize_button,
                .on_maximize_button = on_maximize_button,
                .on_close_button = on_close_button,
            };
        }

        return null;
    }

    pub fn focusedPopupWindowId(self: *Multiplexer) ?u32 {
        return self.popup_mgr.focusedWindowId();
    }

    pub fn syncScrollEnabled(self: *const Multiplexer) bool {
        return self.sync_scroll_enabled;
    }

    pub fn minimizeFocusedWindow(self: *Multiplexer, screen: ?layout.Rect) !bool {
        _ = self.workspace_mgr.minimizeFocusedWindowActive() catch |err| switch (err) {
            error.NoFocusedWindow => return false,
            else => return err,
        };
        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
        _ = try self.markActiveWindowsDirty();
        self.requestRedraw();
        return true;
    }

    pub fn restoreAllMinimizedWindows(self: *Multiplexer, screen: ?layout.Rect) !usize {
        const restored = try self.workspace_mgr.restoreAllMinimizedActive();
        if (restored == 0) return 0;
        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
        _ = try self.markActiveWindowsDirty();
        self.requestRedraw();
        return restored;
    }

    pub fn restoreWindowById(self: *Multiplexer, window_id: u32, screen: ?layout.Rect) !bool {
        const restored = try self.workspace_mgr.restoreWindowByIdActive(window_id);
        if (!restored) return false;
        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
        _ = try self.markActiveWindowsDirty();
        self.requestRedraw();
        return true;
    }

    pub fn moveFocusedWindowToIndex(self: *Multiplexer, target_index: usize, screen: ?layout.Rect) !bool {
        self.workspace_mgr.moveFocusedWindowToIndexActive(target_index) catch |err| switch (err) {
            error.NoFocusedWindow => return false,
            else => return err,
        };
        if (screen) |s| _ = try self.resizeActiveWindowsToLayout(s);
        _ = try self.markActiveWindowsDirty();
        self.requestRedraw();
        return true;
    }

    pub fn windowScrollOffset(self: *Multiplexer, window_id: u32) ?usize {
        const sb = self.scrollbacks.getPtr(window_id) orelse return null;
        return sb.scroll_offset;
    }

    pub fn selectionCursorX(self: *Multiplexer, window_id: u32) usize {
        return self.selection_cursor_x.get(window_id) orelse 0;
    }

    pub fn selectionCursorY(self: *Multiplexer, window_id: u32, view_rows: usize) usize {
        if (view_rows == 0) return 0;
        const fallback = view_rows - 1;
        const y = self.selection_cursor_y.get(window_id) orelse fallback;
        return @min(y, fallback);
    }

    pub fn scrollbackBuffer(self: *Multiplexer, window_id: u32) ?*const scrollback_mod.ScrollbackBuffer {
        return self.scrollbacks.getPtr(window_id);
    }

    pub fn focusedScrollOffset(self: *Multiplexer) usize {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return 0;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return 0;
        return sb.scroll_offset;
    }

    pub fn scrollPageUpFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollPageUp(lines);
        self.sync_scroll_source_window_id = focused_id;
        if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(self.last_screen) catch {};
        self.requestRedraw();
    }

    pub fn scrollPageDownFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollPageDown(lines);
        self.sync_scroll_source_window_id = focused_id;
        if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(self.last_screen) catch {};
        self.requestRedraw();
    }

    pub fn scrollHalfPageUpFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollHalfPageUp(lines);
        self.sync_scroll_source_window_id = focused_id;
        if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(self.last_screen) catch {};
        self.requestRedraw();
    }

    pub fn scrollHalfPageDownFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollHalfPageDown(lines);
        self.sync_scroll_source_window_id = focused_id;
        if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(self.last_screen) catch {};
        self.requestRedraw();
    }

    pub fn searchFocusedScrollback(
        self: *Multiplexer,
        query: []const u8,
        direction: scrollback_mod.SearchDirection,
    ) ?scrollback_mod.SearchResult {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return null;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return null;
        const found = sb.search(query, direction) orelse return null;
        sb.jumpToLine(found.line_index);
        self.sync_scroll_source_window_id = focused_id;
        if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(self.last_screen) catch {};
        self.requestRedraw();
        return found;
    }

    fn setSyncScrollEnabled(self: *Multiplexer, enabled: bool, screen: ?layout.Rect) !void {
        self.sync_scroll_enabled = enabled;
        if (enabled) {
            const focused_id = self.workspace_mgr.focusedWindowIdActive() catch {
                self.sync_scroll_source_window_id = null;
                return;
            };
            self.sync_scroll_source_window_id = focused_id;
            try self.propagateSyncScrollFromFocused(screen);
        } else {
            self.sync_scroll_source_window_id = null;
        }
    }

    fn isFocusedScrolledBack(self: *Multiplexer) bool {
        const focused_id = if (self.popup_mgr.hasModalOpen())
            (self.popup_mgr.focusedWindowId() orelse return false)
        else
            (self.workspace_mgr.focusedWindowIdActive() catch return false);
        const sb = self.scrollbacks.getPtr(focused_id) orelse return false;
        return sb.scroll_offset > 0;
    }

    fn scrollNavArmed(self: *Multiplexer) bool {
        return self.sync_scroll_enabled or self.isFocusedScrolledBack();
    }

    fn handleScrollbackQueryByte(
        self: *Multiplexer,
        b: u8,
        screen: ?layout.Rect,
    ) bool {
        if (!self.scrollback_query_mode) return false;
        switch (b) {
            '\r', '\n' => {
                self.scrollback_query_mode = false;
                if (self.scrollback_query_len > 0) {
                    self.scrollback_last_query_len = self.scrollback_query_len;
                    @memcpy(
                        self.scrollback_last_query_buf[0..self.scrollback_last_query_len],
                        self.scrollback_query_buf[0..self.scrollback_query_len],
                    );
                    self.scrollback_last_direction = .backward;
                    _ = self.searchFocusedScrollback(self.scrollback_last_query_buf[0..self.scrollback_last_query_len], .backward);
                    if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(screen) catch {};
                }
                self.requestRedraw();
            },
            0x7f => { // backspace
                if (self.scrollback_query_len > 0) self.scrollback_query_len -= 1;
                self.requestRedraw();
            },
            0x03 => { // Ctrl+C cancel
                self.scrollback_query_mode = false;
                self.scrollback_query_len = 0;
                self.requestRedraw();
            },
            else => {
                if (b >= 0x20 and b <= 0x7e and self.scrollback_query_len < self.scrollback_query_buf.len) {
                    self.scrollback_query_buf[self.scrollback_query_len] = b;
                    self.scrollback_query_len += 1;
                    self.requestRedraw();
                }
            },
        }
        return true;
    }

    fn handleScrollbackQuerySequence(
        self: *Multiplexer,
        seq: []const u8,
        screen: ?layout.Rect,
    ) bool {
        _ = screen;
        if (!self.scrollback_query_mode) return false;
        if (std.mem.eql(u8, seq, "\x1b")) {
            self.scrollback_query_mode = false;
            self.scrollback_query_len = 0;
            self.requestRedraw();
            return true;
        }
        // Consume all sequences while typing query.
        return true;
    }

    fn handleScrollbackNavForwardByte(
        self: *Multiplexer,
        b: u8,
        screen: ?layout.Rect,
    ) bool {
        if (!self.scrollNavArmed()) return false;
        const lines: usize = if (screen) |s| @max(@as(usize, 1), s.height) else 24;
        switch (b) {
            'h' => self.moveSelectionCursorXFocused(-1),
            'l' => self.moveSelectionCursorXFocused(1),
            'k' => self.moveSelectionCursorYFocused(-1, lines),
            'j' => self.moveSelectionCursorYFocused(1, lines),
            0x15 => self.scrollPageUpFocused(lines), // Ctrl+U
            0x04 => self.scrollPageDownFocused(lines), // Ctrl+D
            'g' => self.scrollToTopFocused(screen),
            'G' => self.scrollToBottomFocused(screen),
            '0' => self.setSelectionCursorXFocused(0),
            '$' => self.setSelectionCursorXToLineEndFocused(lines),
            '/' => {
                self.scrollback_query_mode = true;
                self.scrollback_query_len = 0;
                self.requestRedraw();
            },
            'n' => {
                if (self.scrollback_last_query_len > 0) {
                    _ = self.searchFocusedScrollback(
                        self.scrollback_last_query_buf[0..self.scrollback_last_query_len],
                        self.scrollback_last_direction,
                    );
                    if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(screen) catch {};
                }
            },
            'N' => {
                if (self.scrollback_last_query_len > 0) {
                    const dir: scrollback_mod.SearchDirection = switch (self.scrollback_last_direction) {
                        .forward => .backward,
                        .backward => .forward,
                    };
                    _ = self.searchFocusedScrollback(
                        self.scrollback_last_query_buf[0..self.scrollback_last_query_len],
                        dir,
                    );
                    if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(screen) catch {};
                }
            },
            'q' => self.scrollToBottomFocused(screen),
            else => {},
        }
        // Scrollback/navigation mode is modal: consume all non-prefixed input.
        return true;
    }

    fn moveSelectionCursorXFocused(self: *Multiplexer, delta: i32) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const cur = self.selection_cursor_x.get(focused_id) orelse 0;
        const next: usize = if (delta < 0)
            (if (cur == 0) 0 else cur - 1)
        else
            cur + 1;
        self.selection_cursor_x.put(self.allocator, focused_id, next) catch return;
        self.requestRedraw();
    }

    fn setSelectionCursorXFocused(self: *Multiplexer, x: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        self.selection_cursor_x.put(self.allocator, focused_id, x) catch return;
        self.requestRedraw();
    }

    fn moveSelectionCursorYFocused(self: *Multiplexer, delta: i32, view_rows: usize) void {
        if (view_rows == 0) return;
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const cur = self.selectionCursorY(focused_id, view_rows);
        var next = cur;
        if (delta < 0) {
            if (cur > 0) {
                next = cur - 1;
            } else {
                self.scrollPageUpFocused(1);
                return;
            }
        } else if (delta > 0) {
            if (cur + 1 < view_rows) {
                next = cur + 1;
            } else {
                self.scrollPageDownFocused(1);
                return;
            }
        }
        self.selection_cursor_y.put(self.allocator, focused_id, next) catch return;
        self.requestRedraw();
    }

    fn setSelectionCursorXToLineEndFocused(self: *Multiplexer, view_rows: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        if (view_rows == 0 or sb.lines.items.len == 0) {
            self.setSelectionCursorXFocused(0);
            return;
        }

        const off = @min(sb.scroll_offset, sb.lines.items.len);
        const start = if (sb.lines.items.len > view_rows + off)
            sb.lines.items.len - view_rows - off
        else
            0;
        const y = self.selectionCursorY(focused_id, view_rows);
        const idx = start + y;
        if (idx >= sb.lines.items.len) {
            self.setSelectionCursorXFocused(0);
            return;
        }
        const line = sb.lines.items[idx];
        const end_x: usize = if (line.len == 0) 0 else line.len - 1;
        self.setSelectionCursorXFocused(end_x);
    }

    fn handleScrollbackNavSequence(
        self: *Multiplexer,
        seq: []const u8,
        screen: ?layout.Rect,
    ) bool {
        if (!self.scrollNavArmed()) return false;
        if (std.mem.eql(u8, seq, "\x1b")) {
            self.scrollToBottomFocused(screen);
            return true;
        }
        // Scrollback/navigation mode is modal: consume all sequences.
        return true;
    }

    fn scrollToTopFocused(self: *Multiplexer, screen: ?layout.Rect) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scroll_offset = sb.lines.items.len;
        self.sync_scroll_source_window_id = focused_id;
        if (self.sync_scroll_enabled) self.propagateSyncScrollFromFocused(screen) catch {};
        self.requestRedraw();
    }

    fn scrollToBottomFocused(self: *Multiplexer, screen: ?layout.Rect) void {
        if (self.sync_scroll_enabled) {
            self.setVisibleScrollOffsetFromSource(screen, 0) catch {};
        } else {
            const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
            const sb = self.scrollbacks.getPtr(focused_id) orelse return;
            sb.scroll_offset = 0;
            self.selection_cursor_y.put(self.allocator, focused_id, 0) catch {};
        }
        self.scrollback_query_mode = false;
        self.scrollback_query_len = 0;
        self.requestRedraw();
    }

    fn propagateSyncScrollFromFocused(self: *Multiplexer, screen: ?layout.Rect) !void {
        if (!self.sync_scroll_enabled) return;
        const source_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const source_sb = self.scrollbacks.getPtr(source_id) orelse return;
        try self.setVisibleScrollOffsetFromSource(screen, source_sb.scroll_offset);
        self.sync_scroll_source_window_id = source_id;
    }

    fn setVisibleScrollOffsetFromSource(self: *Multiplexer, screen: ?layout.Rect, offset: usize) !void {
        const tab = try self.workspace_mgr.activeTab();

        if (screen) |s| {
            const rects = try self.computeActiveLayout(s);
            defer self.allocator.free(rects);
            const n = @min(rects.len, tab.windows.items.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const r = rects[i];
                if (r.width == 0 or r.height == 0) continue;
                const window_id = tab.windows.items[i].id;
                if (self.scrollbacks.getPtr(window_id)) |sb| {
                    sb.scroll_offset = @min(offset, sb.lines.items.len);
                }
            }
            return;
        }

        // Fallback when no screen geometry is known: apply within active tab.
        for (tab.windows.items) |w| {
            if (self.scrollbacks.getPtr(w.id)) |sb| {
                sb.scroll_offset = @min(offset, sb.lines.items.len);
            }
        }
    }

    pub fn dirtyWindowIds(self: *Multiplexer, allocator: std.mem.Allocator) ![]u32 {
        var ids = try allocator.alloc(u32, self.dirty_windows.count());
        errdefer allocator.free(ids);

        var i: usize = 0;
        var it = self.dirty_windows.iterator();
        while (it.next()) |entry| : (i += 1) ids[i] = entry.key_ptr.*;
        return ids;
    }

    pub fn liveWindowIds(self: *Multiplexer, allocator: std.mem.Allocator) ![]u32 {
        var ids = try allocator.alloc(u32, self.ptys.count());
        errdefer allocator.free(ids);

        var i: usize = 0;
        var it = self.ptys.iterator();
        while (it.next()) |entry| : (i += 1) ids[i] = entry.key_ptr.*;
        return ids;
    }

    pub fn clearDirtyWindow(self: *Multiplexer, window_id: u32) void {
        _ = self.dirty_windows.fetchRemove(window_id);
    }

    pub fn clearAllDirty(self: *Multiplexer) void {
        self.dirty_windows.clearRetainingCapacity();
    }

    pub fn consumeDetachRequested(self: *Multiplexer) bool {
        const value = self.detach_requested;
        self.detach_requested = false;
        return value;
    }

    pub fn consumeLastMouseEvent(self: *Multiplexer) ?input_mod.MouseEvent {
        const value = self.last_mouse_event;
        self.last_mouse_event = null;
        return value;
    }

    pub fn tick(
        self: *Multiplexer,
        timeout_ms: i32,
        screen: layout.Rect,
        signals: signal_mod.Snapshot,
    ) !TickResult {
        self.last_screen = screen;
        const detach_requested = self.consumeDetachRequested();

        if (signals.sighup or signals.sigterm) {
            try self.gracefulShutdown();
            return .{
                .reads = 0,
                .resized = 0,
                .popup_updates = 0,
                .redraw = false,
                .should_shutdown = true,
                .detach_requested = detach_requested,
            };
        }

        var resized: usize = 0;
        var redraw = false;
        if (signals.sigwinch) {
            resized = try self.resizeActiveWindowsToLayout(screen);
            resized += try self.resizePopupWindows(screen);
            redraw = true;
        }

        const exited_windows = try self.reapExitedWindows();
        if (exited_windows > 0) redraw = true;

        // UI commands (tab/focus/layout changes) request redraw synchronously.
        // Avoid waiting on PTY poll timeout before presenting those updates.
        const poll_timeout_ms: i32 = if (self.redraw_requested) 0 else timeout_ms;
        const reads = try self.pollOnce(poll_timeout_ms);
        if (reads > 0) redraw = true;
        const popup_updates = try self.processPopupTick();
        if (popup_updates > 0) redraw = true;
        if (self.consumeRedrawRequested()) redraw = true;

        return .{
            .reads = reads,
            .resized = resized,
            .popup_updates = popup_updates,
            .redraw = redraw,
            .should_shutdown = false,
            .detach_requested = detach_requested,
        };
    }

    pub fn handleReattach(self: *Multiplexer, screen: layout.Rect) !ReattachResult {
        const resized = try self.resizeActiveWindowsToLayout(screen);
        const marked_dirty = try self.markActiveWindowsDirty();
        return .{
            .resized = resized,
            .marked_dirty = marked_dirty,
            .redraw = true,
        };
    }

    pub fn gracefulShutdown(self: *Multiplexer) !void {
        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            var p = entry.value_ptr.*;
            p.deinitNoWait();
        }
        self.ptys.clearRetainingCapacity();
        self.da_parse_states.clearRetainingCapacity();
        self.mouse_tracking_enabled.clearRetainingCapacity();
        self.selection_cursor_x.clearRetainingCapacity();
    }

    pub fn closeFocusedWindow(self: *Multiplexer) !u32 {
        const id = try self.workspace_mgr.closeFocusedWindowActive();
        if (self.ptys.getPtr(id)) |p| p.deinitNoWait();
        _ = self.ptys.fetchRemove(id);
        _ = self.da_parse_states.fetchRemove(id);
        _ = self.mouse_tracking_enabled.fetchRemove(id);

        if (self.stdout_buffers.getPtr(id)) |list| list.deinit(self.allocator);
        _ = self.stdout_buffers.fetchRemove(id);
        if (self.scrollbacks.getPtr(id)) |sb| sb.deinit();
        _ = self.scrollbacks.fetchRemove(id);
        _ = self.selection_cursor_x.fetchRemove(id);
        _ = self.selection_cursor_y.fetchRemove(id);
        _ = self.dirty_windows.fetchRemove(id);

        return id;
    }

    pub fn openCommandPopup(
        self: *Multiplexer,
        title: []const u8,
        argv: []const []const u8,
        screen: layout.Rect,
        modal: bool,
        auto_close: bool,
    ) !u32 {
        const popup_window_id = self.next_popup_window_id;
        self.next_popup_window_id += 1;

        const rect = centeredPopupRect(screen, 70, 60);
        var p = try pty_mod.Pty.spawnCommand(self.allocator, argv);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, popup_window_id, p);
        try self.stdout_buffers.put(self.allocator, popup_window_id, .{});
        try self.scrollbacks.put(self.allocator, popup_window_id, scrollback_mod.ScrollbackBuffer.init(self.allocator, 2_000));
        try self.selection_cursor_x.put(self.allocator, popup_window_id, 0);
        try self.selection_cursor_y.put(self.allocator, popup_window_id, 0);
        try self.da_parse_states.put(self.allocator, popup_window_id, .idle);

        const popup_inner_rows: u16 = if (rect.height > 2) rect.height - 2 else 1;
        const popup_inner_cols: u16 = if (rect.width > 2) rect.width - 2 else 1;
        if (self.ptys.getPtr(popup_window_id)) |pp| {
            try pp.resize(popup_inner_rows, popup_inner_cols);
        }

        const popup_id = try self.popup_mgr.create(.{
            .window_id = popup_window_id,
            .title = title,
            .rect = rect,
            .modal = modal,
            .auto_close = auto_close,
            .kind = .command,
            .animate = true,
        });
        try self.markWindowDirty(popup_window_id);
        return popup_id;
    }

    pub fn openShellPopup(
        self: *Multiplexer,
        title: []const u8,
        screen: layout.Rect,
        modal: bool,
    ) !u32 {
        const popup_window_id = self.next_popup_window_id;
        self.next_popup_window_id += 1;

        const rect = centeredPopupRect(screen, 70, 60);
        var p = try pty_mod.Pty.spawnShell(self.allocator);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, popup_window_id, p);
        try self.stdout_buffers.put(self.allocator, popup_window_id, .{});
        try self.scrollbacks.put(self.allocator, popup_window_id, scrollback_mod.ScrollbackBuffer.init(self.allocator, 2_000));
        try self.selection_cursor_x.put(self.allocator, popup_window_id, 0);
        try self.selection_cursor_y.put(self.allocator, popup_window_id, 0);
        try self.da_parse_states.put(self.allocator, popup_window_id, .idle);

        const popup_inner_rows: u16 = if (rect.height > 2) rect.height - 2 else 1;
        const popup_inner_cols: u16 = if (rect.width > 2) rect.width - 2 else 1;
        if (self.ptys.getPtr(popup_window_id)) |pp| {
            try pp.resize(popup_inner_rows, popup_inner_cols);
        }

        const popup_id = try self.popup_mgr.create(.{
            .window_id = popup_window_id,
            .title = title,
            .rect = rect,
            .modal = modal,
            .auto_close = false,
            .kind = .persistent,
            .animate = true,
        });
        try self.markWindowDirty(popup_window_id);
        return popup_id;
    }

    pub fn openFzfPopup(self: *Multiplexer, screen: layout.Rect, modal: bool) !u32 {
        const script =
            \\if command -v fzf >/dev/null 2>&1; then
            \\  printf 'one\ntwo\nthree\n' | fzf --height=100% --layout=reverse --prompt='ykwm> ' --filter='one' --select-1 --exit-0
            \\else
            \\  printf 'fzf not found on PATH\n'
            \\fi
        ;
        return self.openCommandPopup("fzf", &.{ "/bin/sh", "-c", script }, screen, modal, true);
    }

    pub fn openInteractivePopup(self: *Multiplexer, screen: layout.Rect, modal: bool) !u32 {
        const script =
            \\if command -v fzf >/dev/null 2>&1; then
            \\  printf 'one\ntwo\nthree\n' | fzf --height=100% --layout=reverse --prompt='ykwm> '
            \\else
            \\  printf 'fzf not found on PATH\n'
            \\  printf 'Press Enter to close...'
            \\  IFS= read -r _
            \\fi
        ;
        return self.openCommandPopup("popup", &.{ "/bin/sh", "-c", script }, screen, modal, true);
    }

    pub fn closeFocusedPopup(self: *Multiplexer) !void {
        const removed = self.popup_mgr.closeFocused() orelse self.popup_mgr.closeTopmost() orelse return;
        self.cleanupClosedPopup(removed);
        self.requestRedraw();
    }

    pub fn closeActiveTab(self: *Multiplexer) !void {
        const removed_ids = try self.workspace_mgr.closeActiveTab(self.allocator);
        defer self.allocator.free(removed_ids);

        for (removed_ids) |id| {
            if (self.ptys.getPtr(id)) |p| p.deinitNoWait();
            _ = self.ptys.fetchRemove(id);
            _ = self.da_parse_states.fetchRemove(id);
            _ = self.mouse_tracking_enabled.fetchRemove(id);
            if (self.stdout_buffers.getPtr(id)) |list| list.deinit(self.allocator);
            _ = self.stdout_buffers.fetchRemove(id);
            if (self.scrollbacks.getPtr(id)) |sb| sb.deinit();
            _ = self.scrollbacks.fetchRemove(id);
            _ = self.selection_cursor_x.fetchRemove(id);
            _ = self.selection_cursor_y.fetchRemove(id);
            _ = self.dirty_windows.fetchRemove(id);
        }
    }

    fn markWindowDirty(self: *Multiplexer, window_id: u32) !void {
        try self.dirty_windows.put(self.allocator, window_id, {});
    }

    fn sendInputToWindow(self: *Multiplexer, window_id: u32, bytes: []const u8) !void {
        const p = self.ptys.getPtr(window_id) orelse return error.UnknownWindow;
        p.write(bytes) catch {
            try self.handleWindowExit(window_id);
            return error.UnknownWindow;
        };
    }

    fn requestRedraw(self: *Multiplexer) void {
        self.redraw_requested = true;
    }

    fn consumeRedrawRequested(self: *Multiplexer) bool {
        const v = self.redraw_requested;
        self.redraw_requested = false;
        return v;
    }

    fn markActiveWindowsDirty(self: *Multiplexer) !usize {
        const tab = try self.workspace_mgr.activeTab();
        var marked: usize = 0;
        for (tab.windows.items) |w| {
            try self.markWindowDirty(w.id);
            marked += 1;
        }
        return marked;
    }

    fn windowHasMouseTracking(self: *const Multiplexer, window_id: u32) bool {
        return self.mouse_tracking_enabled.contains(window_id);
    }

    fn updateWindowMouseTrackingFromOutput(self: *Multiplexer, window_id: u32, bytes: []const u8) !void {
        var last_enable: ?usize = null;
        var last_disable: ?usize = null;

        const enable_tokens = [_][]const u8{
            "\x1b[?1000h",
            "\x1b[?1002h",
            "\x1b[?1003h",
            "\x1b[?1006h",
        };
        const disable_tokens = [_][]const u8{
            "\x1b[?1000l",
            "\x1b[?1002l",
            "\x1b[?1003l",
            "\x1b[?1006l",
        };

        for (enable_tokens) |tok| {
            if (std.mem.lastIndexOf(u8, bytes, tok)) |idx| {
                if (last_enable == null or idx > last_enable.?) last_enable = idx;
            }
        }
        for (disable_tokens) |tok| {
            if (std.mem.lastIndexOf(u8, bytes, tok)) |idx| {
                if (last_disable == null or idx > last_disable.?) last_disable = idx;
            }
        }

        const enabled_now = switch (last_enable != null or last_disable != null) {
            false => return,
            true => blk: {
                if (last_enable == null) break :blk false;
                if (last_disable == null) break :blk true;
                break :blk last_enable.? > last_disable.?;
            },
        };

        if (enabled_now) {
            try self.mouse_tracking_enabled.put(self.allocator, window_id, {});
        } else {
            _ = self.mouse_tracking_enabled.fetchRemove(window_id);
        }
    }

    fn handleMouseFromEvent(
        self: *Multiplexer,
        screen: layout.Rect,
        maybe_mouse: ?input_mod.MouseEvent,
    ) !void {
        const mouse = maybe_mouse orelse return;
        const px: u16 = if (mouse.x > 0) mouse.x - 1 else 0;
        const py: u16 = if (mouse.y > 0) mouse.y - 1 else 0;

        if (!mouse.pressed) {
            self.drag_state.axis = .none;
            return;
        }

        const motion = (mouse.button & 32) != 0;
        if (self.drag_state.axis != .none and (motion or mouse.button == 0)) {
            try self.applyDragResize(screen, px, py);
            return;
        }

        if (mouse.button != 0) return;

        // Start divider drag for active stack layout if click is on divider.
        if (try self.hitDividerForVerticalStack(screen, px, py)) {
            self.drag_state.axis = .vertical;
            return;
        }
        if (try self.hitDividerForHorizontalStack(screen, px, py)) {
            self.drag_state.axis = .horizontal;
            return;
        }

        // Otherwise it's a focus click.
        try self.applyClickFocus(screen, px, py);
    }

    fn handleMouseHybrid(
        self: *Multiplexer,
        screen: layout.Rect,
        mouse: input_mod.MouseEvent,
    ) !bool {
        const px: u16 = if (mouse.x > 0) mouse.x - 1 else 0;
        const py: u16 = if (mouse.y > 0) mouse.y - 1 else 0;
        const target_has_tracking = self.currentMouseForwardTargetHasTracking();

        // Never forward pointer events outside the tiled content area
        // (e.g. plugin-rendered toolbars/tabs/status lines).
        if (!pointInRect(px, py, screen)) {
            self.hybrid_forward_click_active = false;
            if (!mouse.pressed) self.drag_state.axis = .none;
            return true;
        }

        if (!mouse.pressed) {
            if (self.drag_state.axis != .none) {
                self.drag_state.axis = .none;
                return true;
            }
            if (self.hybrid_forward_click_active) {
                self.hybrid_forward_click_active = false;
                return false;
            }
            return !target_has_tracking;
        }

        const motion = (mouse.button & 32) != 0;
        if (self.drag_state.axis != .none and (motion or mouse.button == 0)) {
            try self.applyDragResize(screen, px, py);
            return true;
        }
        if (motion) return !target_has_tracking;
        if (mouse.button != 0) return !target_has_tracking;

        if (try self.hitDividerForVerticalStack(screen, px, py)) {
            self.drag_state.axis = .vertical;
            return true;
        }
        if (try self.hitDividerForHorizontalStack(screen, px, py)) {
            self.drag_state.axis = .horizontal;
            return true;
        }

        const pane_hit = try self.paneHitAt(screen, px, py);
        if (pane_hit) |hit| {
            const tab = try self.workspace_mgr.activeTab();
            const current_focus = tab.focused_index orelse 0;
            const target_id = tab.windows.items[hit.idx].id;
            try self.workspace_mgr.setFocusedWindowIndexActive(hit.idx);
            try self.markWindowDirty(target_id);
            self.requestRedraw();
            if (hit.on_border) {
                self.hybrid_forward_click_active = false;
                return true;
            }
            if (hit.idx != current_focus) {
                // First click into another pane switches focus only.
                self.hybrid_forward_click_active = false;
                return true;
            }
            // Content clicks are forwarded (for shell click-to-move), while
            // motion/non-left events remain gated by mouse-tracking capability.
            self.hybrid_forward_click_active = true;
            return false;
        }

        return false;
    }

    fn currentMouseForwardTargetHasTracking(self: *Multiplexer) bool {
        const target_id = if (self.popup_mgr.hasModalOpen())
            (self.popup_mgr.focusedWindowId() orelse return false)
        else
            (self.workspace_mgr.focusedWindowIdActive() catch return false);
        return self.windowHasMouseTracking(target_id);
    }

    const PaneHit = struct {
        idx: usize,
        on_border: bool,
    };

    fn paneHitAt(self: *Multiplexer, screen: layout.Rect, px: u16, py: u16) !?PaneHit {
        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);

        const tab = try self.workspace_mgr.activeTab();
        const n = @min(rects.len, tab.windows.items.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = rects[i];
            if (!pointInRect(px, py, r)) continue;
            const on_border = px == r.x or py == r.y or
                px + 1 == r.x + r.width or py + 1 == r.y + r.height;
            return PaneHit{ .idx = i, .on_border = on_border };
        }
        return null;
    }

    fn pointInRect(px: u16, py: u16, r: layout.Rect) bool {
        return px >= r.x and px < (r.x + r.width) and py >= r.y and py < (r.y + r.height);
    }

    fn applyClickFocus(
        self: *Multiplexer,
        screen: layout.Rect,
        px: u16,
        py: u16,
    ) !void {
        if (self.popup_mgr.count() > 0) {
            if (self.topmostPopupAt(px, py)) |popup_id| {
                if (self.popup_mgr.focusAndRaise(popup_id)) {
                    if (self.popup_mgr.focusedWindowId()) |wid| try self.markWindowDirty(wid);
                    self.requestRedraw();
                    return;
                }
            }
            if (self.popup_mgr.hasModalOpen()) return;
        }

        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);

        const tab = try self.workspace_mgr.activeTab();
        const n = @min(rects.len, tab.windows.items.len);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = rects[i];
            const inside_x = px >= r.x and px < (r.x + r.width);
            const inside_y = py >= r.y and py < (r.y + r.height);
            if (!(inside_x and inside_y)) continue;

            try self.workspace_mgr.setFocusedWindowIndexActive(i);
            try self.markWindowDirty(tab.windows.items[i].id);
            self.requestRedraw();
            return;
        }
    }

    fn topmostPopupAt(self: *const Multiplexer, px: u16, py: u16) ?u32 {
        var best_id: ?u32 = null;
        var best_z: u32 = 0;
        for (self.popup_mgr.popups.items) |p| {
            const inside_x = px >= p.rect.x and px < (p.rect.x + p.rect.width);
            const inside_y = py >= p.rect.y and py < (p.rect.y + p.rect.height);
            if (!(inside_x and inside_y)) continue;
            if (best_id == null or p.z_index >= best_z) {
                best_id = p.id;
                best_z = p.z_index;
            }
        }
        return best_id;
    }

    fn hitDividerForVerticalStack(self: *Multiplexer, screen: layout.Rect, px: u16, py: u16) !bool {
        if (try self.workspace_mgr.activeLayoutType() != .vertical_stack) return false;

        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);
        if (rects.len < 2) return false;

        // For vertical stack, master divider is at the right edge of pane 0.
        const divider_x = rects[0].x + rects[0].width;
        const in_y = py >= rects[0].y and py < (rects[0].y + rects[0].height);
        if (!in_y) return false;

        const lo = if (divider_x > 0) divider_x - 1 else divider_x;
        const hi = divider_x + 1;
        return px >= lo and px <= hi;
    }

    fn hitDividerForHorizontalStack(self: *Multiplexer, screen: layout.Rect, px: u16, py: u16) !bool {
        if (try self.workspace_mgr.activeLayoutType() != .horizontal_stack) return false;

        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);
        if (rects.len < 2) return false;

        // For horizontal stack, master divider is at the bottom edge of pane 0.
        const divider_y = rects[0].y + rects[0].height;
        const in_x = px >= rects[0].x and px < (rects[0].x + rects[0].width);
        if (!in_x) return false;

        const lo = if (divider_y > 0) divider_y - 1 else divider_y;
        const hi = divider_y + 1;
        return py >= lo and py <= hi;
    }

    fn applyDragResize(self: *Multiplexer, screen: layout.Rect, px: u16, py: u16) !void {
        const ratio_u32: u32 = switch (self.drag_state.axis) {
            .none => return,
            .vertical => blk: {
                if (screen.width == 0) return;
                const local_x = if (px > screen.x) px - screen.x else 0;
                break :blk (@as(u32, local_x) * 1000) / @as(u32, screen.width);
            },
            .horizontal => blk: {
                if (screen.height == 0) return;
                const local_y = if (py > screen.y) py - screen.y else 0;
                break :blk (@as(u32, local_y) * 1000) / @as(u32, screen.height);
            },
        };
        const clamped: u16 = @intCast(@max(@as(u32, 100), @min(@as(u32, 900), ratio_u32)));
        try self.workspace_mgr.setActiveMasterRatioPermille(clamped);
        _ = self.resizeActiveWindowsToLayout(screen) catch 0;
        self.requestRedraw();
    }

    fn focusDirectional(
        self: *Multiplexer,
        screen: layout.Rect,
        dir: FocusDirection,
    ) !void {
        const rects = try self.computeActiveLayout(screen);
        defer self.allocator.free(rects);

        const tab = try self.workspace_mgr.activeTab();
        const n = @min(rects.len, tab.windows.items.len);
        if (n == 0) return;
        const current = tab.focused_index orelse 0;
        if (current >= n) return;

        const cur = rects[current];
        const cur_cx = @as(i32, cur.x) + @divTrunc(@as(i32, cur.width), 2);
        const cur_cy = @as(i32, cur.y) + @divTrunc(@as(i32, cur.height), 2);

        var best_idx: ?usize = null;
        var best_score: i32 = std.math.maxInt(i32);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i == current) continue;
            const cand = rects[i];
            if (cand.width == 0 or cand.height == 0) continue;

            const cx = @as(i32, cand.x) + @divTrunc(@as(i32, cand.width), 2);
            const cy = @as(i32, cand.y) + @divTrunc(@as(i32, cand.height), 2);
            const dx = cx - cur_cx;
            const dy = cy - cur_cy;

            const primary: i32 = switch (dir) {
                .left => -dx,
                .right => dx,
                .up => -dy,
                .down => dy,
            };
            if (primary <= 0) continue;

            const secondary: i32 = switch (dir) {
                .left, .right => @intCast(@abs(dy)),
                .up, .down => @intCast(@abs(dx)),
            };
            const score = primary * 1000 + secondary;
            if (score < best_score) {
                best_score = score;
                best_idx = i;
            }
        }

        if (best_idx) |idx| {
            try self.workspace_mgr.setFocusedWindowIndexActive(idx);
            _ = try self.markActiveWindowsDirty();
            self.requestRedraw();
        }
    }

    const TerminalQueryCounts = struct {
        da: usize = 0,
        cpr: usize = 0,
    };

    fn countTerminalQueries(state: *DaParseState, bytes: []const u8) TerminalQueryCounts {
        var counts: TerminalQueryCounts = .{};
        for (bytes) |b| {
            switch (state.*) {
                .idle => {
                    if (b == 0x1b) state.* = .esc;
                },
                .esc => {
                    if (b == '[') {
                        state.* = .csi_entry;
                    } else if (b == 0x1b) {
                        state.* = .esc;
                    } else {
                        state.* = .idle;
                    }
                },
                .csi_entry => {
                    if (b == 'c') {
                        counts.da += 1;
                        state.* = .idle;
                    } else if (b == '6') {
                        state.* = .csi_6;
                    } else if (b >= 0x40 and b <= 0x7e) {
                        state.* = .idle;
                    } else if (b >= 0x20 and b <= 0x3f) {
                        // Any intermediate/parameter byte means this isn't plain CSI c / CSI 6n.
                        state.* = .csi_other;
                    } else {
                        state.* = .idle;
                    }
                },
                .csi_other => {
                    if (b >= 0x40 and b <= 0x7e) {
                        state.* = .idle;
                    } else {
                        // Keep consuming until we hit a final byte.
                    }
                },
                .csi_6 => {
                    if (b == 'n') {
                        counts.cpr += 1;
                        state.* = .idle;
                    } else if (b >= 0x40 and b <= 0x7e) {
                        state.* = .idle;
                    } else if (b >= 0x20 and b <= 0x3f) {
                        // Additional params/intermediates => not plain "CSI 6n".
                        state.* = .csi_other;
                    } else {
                        state.* = .idle;
                    }
                },
            }
        }
        return counts;
    }

    fn hasNeighborOnRight(rects: []const layout.Rect, idx: usize, r: layout.Rect) bool {
        for (rects, 0..) |other, j| {
            if (j == idx) continue;
            if (r.x + r.width != other.x) continue;
            const overlap_top = @max(r.y, other.y);
            const overlap_bottom = @min(r.y + r.height, other.y + other.height);
            if (overlap_bottom > overlap_top) return true;
        }
        return false;
    }

    fn hasNeighborOnBottom(rects: []const layout.Rect, idx: usize, r: layout.Rect) bool {
        for (rects, 0..) |other, j| {
            if (j == idx) continue;
            if (r.y + r.height != other.y) continue;
            const overlap_left = @max(r.x, other.x);
            const overlap_right = @min(r.x + r.width, other.x + other.width);
            if (overlap_right > overlap_left) return true;
        }
        return false;
    }

    fn contentSizeForRect(rects: []const layout.Rect, idx: usize, r: layout.Rect, screen: layout.Rect) struct { rows: u16, cols: u16 } {
        // Keep this consistent with renderer border policy:
        // left/top border always drawn, right/bottom drawn when no adjacent pane exists.
        if (r.width == 0 or r.height == 0) {
            return .{ .rows = 1, .cols = 1 };
        }

        const left_border: u16 = 1;
        const top_border: u16 = 1;
        _ = screen;
        const right_border: u16 = if (!hasNeighborOnRight(rects, idx, r)) 1 else 0;
        const bottom_border: u16 = if (!hasNeighborOnBottom(rects, idx, r)) 1 else 0;
        const cols_sub = left_border + right_border;
        const rows_sub = top_border + bottom_border;
        const cols = if (r.width > cols_sub) r.width - cols_sub else 1;
        const rows = if (r.height > rows_sub) r.height - rows_sub else 1;
        return .{
            .rows = @max(@as(u16, 1), rows),
            .cols = @max(@as(u16, 1), cols),
        };
    }

    fn posixPollFd() type {
        return std.posix.pollfd;
    }

    fn centeredPopupRect(screen: layout.Rect, width_percent: u8, height_percent: u8) layout.Rect {
        const w_u32 = (@as(u32, screen.width) * width_percent) / 100;
        const h_u32 = (@as(u32, screen.height) * height_percent) / 100;
        const w: u16 = @intCast(@max(@as(u32, 1), w_u32));
        const h: u16 = @intCast(@max(@as(u32, 1), h_u32));
        const x: u16 = screen.x + (screen.width - w) / 2;
        const y: u16 = screen.y + (screen.height - h) / 2;
        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    fn processPopupTick(self: *Multiplexer) !usize {
        var changed: usize = 0;
        changed += try self.reapExitedAutoClosePopups();

        const animated_closures = try self.popup_mgr.advanceAnimations(self.allocator);
        defer self.allocator.free(animated_closures);
        if (animated_closures.len > 0) changed += animated_closures.len;
        for (animated_closures) |removed| self.cleanupClosedPopup(removed);

        return changed;
    }

    fn reapExitedAutoClosePopups(self: *Multiplexer) !usize {
        var closing_ids = std.ArrayList(u32).empty;
        defer closing_ids.deinit(self.allocator);

        for (self.popup_mgr.popups.items) |p| {
            if (!p.auto_close) continue;
            const window_id = p.window_id orelse continue;
            const proc = self.ptys.getPtr(window_id) orelse continue;
            if (try proc.reapIfExited()) {
                try closing_ids.append(self.allocator, p.id);
            }
        }

        for (closing_ids.items) |popup_id| {
            _ = self.popup_mgr.startCloseAnimation(popup_id);
        }
        return closing_ids.items.len;
    }

    fn cleanupClosedPopup(self: *Multiplexer, removed: popup_mod.Popup) void {
        defer self.allocator.free(removed.title);

        if (removed.window_id) |window_id| {
            if (self.ptys.getPtr(window_id)) |p| p.deinitNoWait();
            _ = self.ptys.fetchRemove(window_id);
            _ = self.da_parse_states.fetchRemove(window_id);
            _ = self.mouse_tracking_enabled.fetchRemove(window_id);
            if (self.stdout_buffers.getPtr(window_id)) |list| list.deinit(self.allocator);
            _ = self.stdout_buffers.fetchRemove(window_id);
            if (self.scrollbacks.getPtr(window_id)) |sb| sb.deinit();
            _ = self.scrollbacks.fetchRemove(window_id);
            _ = self.selection_cursor_x.fetchRemove(window_id);
            _ = self.selection_cursor_y.fetchRemove(window_id);
            _ = self.dirty_windows.fetchRemove(window_id);
        }
    }

    fn cleanupWindowResources(self: *Multiplexer, window_id: u32) void {
        if (self.ptys.getPtr(window_id)) |p| p.deinitNoWait();
        _ = self.ptys.fetchRemove(window_id);
        _ = self.da_parse_states.fetchRemove(window_id);
        _ = self.mouse_tracking_enabled.fetchRemove(window_id);
        if (self.stdout_buffers.getPtr(window_id)) |list| list.deinit(self.allocator);
        _ = self.stdout_buffers.fetchRemove(window_id);
        if (self.scrollbacks.getPtr(window_id)) |sb| sb.deinit();
        _ = self.scrollbacks.fetchRemove(window_id);
        _ = self.selection_cursor_x.fetchRemove(window_id);
        _ = self.selection_cursor_y.fetchRemove(window_id);
        _ = self.dirty_windows.fetchRemove(window_id);
    }

    fn handleWindowExit(self: *Multiplexer, window_id: u32) !void {
        if (self.popup_mgr.closeByWindowId(window_id)) |removed| {
            self.cleanupClosedPopup(removed);
            try self.relayoutAfterTopologyChange();
            self.requestRedraw();
            return;
        }
        if (try self.workspace_mgr.closeWindowById(window_id)) {
            self.cleanupWindowResources(window_id);
            try self.relayoutAfterTopologyChange();
            self.requestRedraw();
        } else {
            self.cleanupWindowResources(window_id);
            self.requestRedraw();
        }
    }

    fn relayoutAfterTopologyChange(self: *Multiplexer) !void {
        const screen = self.last_screen orelse return;
        _ = self.resizeActiveWindowsToLayout(screen) catch 0;
        _ = self.resizePopupWindows(screen) catch 0;
        _ = try self.markActiveWindowsDirty();
    }

    fn reapExitedWindows(self: *Multiplexer) !usize {
        var exited = std.ArrayList(u32).empty;
        defer exited.deinit(self.allocator);

        var it = self.ptys.iterator();
        while (it.next()) |entry| {
            const window_id = entry.key_ptr.*;
            if (try entry.value_ptr.reapIfExited()) {
                try exited.append(self.allocator, window_id);
            }
        }

        for (exited.items) |window_id| {
            try self.handleWindowExit(window_id);
        }
        return exited.items.len;
    }

    fn resizePopupWindows(self: *Multiplexer, screen: layout.Rect) !usize {
        var resized: usize = 0;
        for (self.popup_mgr.popups.items) |*p| {
            p.rect = clampPopupRect(screen, p.rect);
            const window_id = p.window_id orelse continue;
            if (self.ptys.getPtr(window_id)) |proc| {
                const rows: u16 = if (p.rect.height > 2) p.rect.height - 2 else 1;
                const cols: u16 = if (p.rect.width > 2) p.rect.width - 2 else 1;
                try proc.resize(rows, cols);
                try self.markWindowDirty(window_id);
                resized += 1;
            }
        }
        return resized;
    }

    fn clampPopupRect(screen: layout.Rect, rect: layout.Rect) layout.Rect {
        var r = rect;
        const min_w: u16 = if (screen.width >= 3) 3 else screen.width;
        const min_h: u16 = if (screen.height >= 3) 3 else screen.height;
        const max_w: u16 = screen.width;
        const max_h: u16 = screen.height;
        if (r.width < min_w) r.width = min_w;
        if (r.height < min_h) r.height = min_h;
        if (r.width > max_w) r.width = max_w;
        if (r.height > max_h) r.height = max_h;

        const x_min = screen.x;
        const y_min = screen.y;
        const x_max = if (screen.width > r.width) screen.x + screen.width - r.width else screen.x;
        const y_max = if (screen.height > r.height) screen.y + screen.height - r.height else screen.y;
        if (r.x < x_min) r.x = x_min;
        if (r.y < y_min) r.y = y_min;
        if (r.x > x_max) r.x = x_max;
        if (r.y > y_max) r.y = y_max;
        return r;
    }
};

test "multiplexer routes command output to the owning window" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("echo", &.{ "/bin/sh", "-c", "printf 'mux-ok\\n'" });

    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(50);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "mux-ok") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "mux-ok") != null);
}

test "multiplexer propagates active layout size to ptys" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const resized = try mux.resizeActiveWindowsToLayout(.{ .x = 0, .y = 0, .width = 80, .height = 24 });
    try testing.expectEqual(@as(usize, 2), resized);
}

test "multiplexer forwards input to focused window pty" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    try mux.sendInputToFocused("ping\n");

    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(30);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "ping") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "ping") != null);
}

test "multiplexer handles prefix create-window command" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const before = try mux.workspace_mgr.activeWindowCount();
    try mux.handleInputBytes(&.{ 0x07, 'c' });
    const after = try mux.workspace_mgr.activeWindowCount();

    try testing.expectEqual(before + 1, after);
}

test "multiplexer tick handles sigwinch and reports redraw" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const result = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = true,
        .sighup = false,
        .sigterm = false,
    });

    try testing.expectEqual(@as(usize, 1), result.resized);
    try testing.expect(result.redraw);
    try testing.expect(!result.should_shutdown);
}

test "multiplexer tick handles sigterm shutdown" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const result = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = true,
    });

    try testing.expect(result.should_shutdown);
    try testing.expectEqual(@as(usize, 0), mux.ptys.count());
    try testing.expect(!result.detach_requested);
}

test "multiplexer close focused window command cleans up maps" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const before = try mux.workspace_mgr.activeWindowCount();
    const closed = try mux.closeFocusedWindow();
    const after = try mux.workspace_mgr.activeWindowCount();

    try testing.expectEqual(before - 1, after);
    try testing.expect(!mux.ptys.contains(closed));
    try testing.expect(!mux.stdout_buffers.contains(closed));
}

test "multiplexer detach command toggles detach request flag" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    try mux.handleInputBytes(&.{ 0x07, '\\' });
    try testing.expect(mux.consumeDetachRequested());
    try testing.expect(!mux.consumeDetachRequested());
}

test "multiplexer tick surfaces detach request" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    try mux.handleInputBytes(&.{ 0x07, '\\' });

    const result = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = false,
    });

    try testing.expect(result.detach_requested);
    try testing.expect(!mux.consumeDetachRequested());
}

test "multiplexer captures mouse metadata without forwarding to pane" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();
    mux.setMousePassthrough(false);

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    try mux.handleInputBytes("\x1b[<0;3;4M");

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[<0;3;4M") == null);

    const mouse = mux.consumeLastMouseEvent() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), mouse.button);
    try testing.expectEqual(@as(u16, 3), mouse.x);
    try testing.expectEqual(@as(u16, 4), mouse.y);
    try testing.expect(mouse.pressed);
}

test "multiplexer liveWindowIds includes windows from multiple tabs" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("a");
    const a_id = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createTab("b");
    const b_id = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const live = try mux.liveWindowIds(testing.allocator);
    defer testing.allocator.free(live);

    try testing.expect(live.len >= 2);
    var found_a = false;
    var found_b = false;
    for (live) |id| {
        if (id == a_id) found_a = true;
        if (id == b_id) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "multiplexer click-to-focus selects pane by mouse coordinates" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();
    mux.setMousePassthrough(false);

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("left", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("right", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try testing.expectEqual(@as(usize, 0), try mux.workspace_mgr.focusedWindowIndexActive());

    // Click near the right side in a 2-pane vertical layout.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;70;5M");
    try testing.expectEqual(@as(usize, 1), try mux.workspace_mgr.focusedWindowIndexActive());
}

test "multiplexer click focuses pane without forwarding mouse sequence" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();
    mux.setMousePassthrough(false);

    _ = try mux.createTab("dev");
    const left_id = try mux.createCommandWindow("left", &.{"/bin/cat"});
    const right_id = try mux.createCommandWindow("right", &.{"/bin/cat"});

    const click = "\x1b[<0;70;5M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, click);

    const left_out = try mux.windowOutput(left_id);
    const right_out = try mux.windowOutput(right_id);

    try testing.expect(std.mem.indexOf(u8, right_out, click) == null);
    try testing.expect(std.mem.indexOf(u8, left_out, click) == null);
}

test "multiplexer drag-resize updates master ratio for vertical stack" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();
    mux.setMousePassthrough(false);

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("left", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("right", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const before = try mux.workspace_mgr.activeMasterRatioPermille();

    // 1) Press on divider (near x ~ master split in 80 cols).
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;49;5M");
    // 2) Drag motion to the right (button 32 indicates motion).
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<32;70;5M");
    // 3) Release.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;70;5m");

    const after = try mux.workspace_mgr.activeMasterRatioPermille();
    try testing.expect(after != before);
    try testing.expect(after > before);
}

test "multiplexer drag-resize burst does not error" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();
    mux.setMousePassthrough(false);

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("left", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("right", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;49;5M");
    var x: usize = 20;
    while (x < 75) : (x += 1) {
        var seq_buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&seq_buf, "\x1b[<32;{};5M", .{x});
        try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);
    }
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;70;5m");
}

test "multiplexer drag-resize updates master ratio for horizontal stack" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();
    mux.setMousePassthrough(false);

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("top", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("bottom", &.{ "/bin/sh", "-c", "sleep 0.2" });
    try mux.workspace_mgr.setActiveLayout(.horizontal_stack);

    const before = try mux.workspace_mgr.activeMasterRatioPermille();

    // 1) Press on horizontal divider (near y ~ split in 24 rows).
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;20;13M");
    // 2) Drag motion downward.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<32;20;19M");
    // 3) Release.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;20;19m");

    const after = try mux.workspace_mgr.activeMasterRatioPermille();
    try testing.expect(after != before);
    try testing.expect(after > before);
}

test "multiplexer focus command requests redraw immediately" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, &.{ 0x07, 'J' });
    const t = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = false,
    });
    try testing.expect(t.redraw);
}

test "multiplexer mouse passthrough forwards sgr sequence to focused pane" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    mux.setMousePassthrough(true);

    const seq = "\x1b[<0;7;9M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);

    // Read loop to allow PTY echo to land.
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, seq) != null) break;
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, seq) != null);
}

test "multiplexer hybrid mode first click switches focus without forwarding" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const left_id = try mux.createCommandWindow("left", &.{"/bin/cat"});
    const right_id = try mux.createCommandWindow("right", &.{"/bin/cat"});
    mux.setMouseMode(.hybrid);

    // Click interior of right pane in a 2-pane vertical split.
    const seq = "\x1b[<0;70;5M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);

    try testing.expectEqual(@as(usize, 1), try mux.workspace_mgr.focusedWindowIndexActive());
    const left_out = try mux.windowOutput(left_id);
    const right_out = try mux.windowOutput(right_id);
    try testing.expect(std.mem.indexOf(u8, left_out, seq) == null);
    try testing.expect(std.mem.indexOf(u8, right_out, seq) == null);
}

test "multiplexer hybrid mode forwards click in already focused pane" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const right_id = try mux.createCommandWindow("right", &.{"/bin/cat"});
    mux.setMouseMode(.hybrid);

    // Single pane is focused by definition; click should be forwarded.
    const seq = "\x1b[<0;20;5M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);

    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const out_now = try mux.windowOutput(right_id);
        if (std.mem.indexOf(u8, out_now, seq) != null) break;
    }

    const out = try mux.windowOutput(right_id);
    try testing.expect(std.mem.indexOf(u8, out, seq) != null);
}

test "multiplexer hybrid mode forwards click when target enabled mouse tracking" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("left", &.{"/bin/cat"});
    const right_id = try mux.createCommandWindow("right", &.{ "/bin/sh", "-c", "printf '\\x1b[?1000h'; exec cat" });
    mux.setMouseMode(.hybrid);

    // Allow startup output to be read so mouse-enable sequence is detected.
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const out = try mux.windowOutput(right_id);
        if (std.mem.indexOf(u8, out, "\x1b[?1000h") != null) break;
    }

    const seq = "\x1b[<0;70;5M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);

    tries = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const out = try mux.windowOutput(right_id);
        if (std.mem.indexOf(u8, out, seq) != null) break;
    }

    try testing.expectEqual(@as(usize, 1), try mux.workspace_mgr.focusedWindowIndexActive());
    const right_out = try mux.windowOutput(right_id);
    try testing.expect(std.mem.indexOf(u8, right_out, seq) != null);
}

test "multiplexer hybrid mode does not forward motion when tracking is disabled" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    mux.setMouseMode(.hybrid);

    const seq = "\x1b[<32;20;10M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);
    _ = try mux.pollOnce(20);

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, seq) == null);
}

test "multiplexer hybrid mode keeps divider click in compositor path" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const left_id = try mux.createCommandWindow("left", &.{"/bin/cat"});
    const right_id = try mux.createCommandWindow("right", &.{"/bin/cat"});
    mux.setMouseMode(.hybrid);

    // Divider press in 80-col default split (~x=49).
    const seq = "\x1b[<0;49;5M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, seq);
    _ = try mux.pollOnce(20);

    const left_out = try mux.windowOutput(left_id);
    const right_out = try mux.windowOutput(right_id);
    try testing.expect(std.mem.indexOf(u8, left_out, seq) == null);
    try testing.expect(std.mem.indexOf(u8, right_out, seq) == null);
}

test "multiplexer tick does not block on poll after tab switch redraw request" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("a");
    _ = try mux.createCommandWindow("a-win", &.{ "/bin/sh", "-c", "sleep 0.5" });
    _ = try mux.createTab("b");
    _ = try mux.createCommandWindow("b-win", &.{ "/bin/sh", "-c", "sleep 0.5" });
    try mux.switchTab(0);

    // Trigger next-tab command, which requests immediate redraw.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, &.{ 0x07, ']' });

    const start = std.time.nanoTimestamp();
    const t = try mux.tick(200, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = false,
    });
    const elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start)) /
        @as(f64, @floatFromInt(std.time.ns_per_ms));

    try testing.expect(t.redraw);
    // Old behavior waited for poll timeout (~200ms). New behavior should be near-immediate.
    try testing.expect(elapsed_ms < 100.0);
}

test "multiplexer reattach path marks active windows dirty and requests redraw" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    mux.clearAllDirty();
    const result = try mux.handleReattach(.{ .x = 0, .y = 0, .width = 80, .height = 24 });

    try testing.expect(result.redraw);
    try testing.expectEqual(@as(usize, 2), result.resized);
    try testing.expectEqual(@as(usize, 2), result.marked_dirty);

    const dirty = try mux.dirtyWindowIds(testing.allocator);
    defer testing.allocator.free(dirty);
    try testing.expectEqual(@as(usize, 2), dirty.len);
}

test "multiplexer layout cycle command updates active layout" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    try testing.expectEqual(layout.LayoutType.vertical_stack, try mux.workspace_mgr.activeLayoutType());

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, &.{ 0x07, ' ' });
    try testing.expectEqual(layout.LayoutType.horizontal_stack, try mux.workspace_mgr.activeLayoutType());
}

test "multiplexer zoom-to-master command promotes focused pane" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const a = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });
    const c = try mux.createCommandWindow("c", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try mux.workspace_mgr.setFocusedWindowIndexActive(2);
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 100, .height = 30 }, &.{ 0x07, '\r' });

    try testing.expectEqual(@as(usize, 0), try mux.workspace_mgr.focusedWindowIndexActive());
    const tab = try mux.workspace_mgr.activeTab();
    try testing.expectEqual(c, tab.windows.items[0].id);
    try testing.expectEqual(a, tab.windows.items[2].id);
}

test "multiplexer new tab creates shell and redraws" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("main");
    _ = try mux.createCommandWindow("base", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, &.{ 0x07, 't' });

    try testing.expectEqual(@as(usize, 2), mux.workspace_mgr.tabCount());
    try testing.expectEqual(@as(usize, 1), try mux.workspace_mgr.activeWindowCount());

    const t = try mux.tick(0, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
        .sigwinch = false,
        .sighup = false,
        .sigterm = false,
    });
    try testing.expect(t.redraw);
}

test "multiplexer resize handles fullscreen hidden panes without crashing" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("c", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try mux.workspace_mgr.setFocusedWindowIndexActive(1);
    try mux.workspace_mgr.setActiveLayout(.fullscreen);

    const resized = try mux.resizeActiveWindowsToLayout(.{ .x = 0, .y = 0, .width = 100, .height = 30 });
    try testing.expectEqual(@as(usize, 1), resized);
}

test "multiplexer close active tab removes tab windows from pty maps" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_a = try mux.createCommandWindow("a", &.{ "/bin/sh", "-c", "sleep 0.2" });
    const win_b = try mux.createCommandWindow("b", &.{ "/bin/sh", "-c", "sleep 0.2" });

    _ = try mux.createTab("ops");
    try mux.switchTab(1);
    const win_c = try mux.createCommandWindow("c", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try mux.closeActiveTab();

    try testing.expectEqual(@as(usize, 1), mux.workspace_mgr.tabCount());
    try testing.expect(mux.ptys.contains(win_a));
    try testing.expect(mux.ptys.contains(win_b));
    try testing.expect(!mux.ptys.contains(win_c));
    try testing.expect(!mux.stdout_buffers.contains(win_c));
}

test "multiplexer opens and closes command popup" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const popup_id = try mux.openCommandPopup(
        "popup-cat",
        &.{"/bin/cat"},
        .{ .x = 0, .y = 0, .width = 100, .height = 30 },
        true,
        false,
    );
    _ = popup_id;

    try testing.expectEqual(@as(usize, 1), mux.popup_mgr.count());
    const popup_window_id = mux.focusedPopupWindowId() orelse return error.TestUnexpectedResult;
    try testing.expect(mux.ptys.contains(popup_window_id));

    try mux.closeFocusedPopup();
    var tries: usize = 0;
    while (tries < 8 and mux.popup_mgr.count() > 0) : (tries += 1) {
        _ = try mux.tick(0, .{ .x = 0, .y = 0, .width = 100, .height = 30 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
    }
    try testing.expectEqual(@as(usize, 0), mux.popup_mgr.count());
    try testing.expect(!mux.ptys.contains(popup_window_id));
}

test "multiplexer opens shell popup" {
    const testing = std.testing;
    var mux = Multiplexer.init(testing.allocator, layout.nativeEngine());
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("base", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const popup_id = try mux.openShellPopup("popup-shell", .{ .x = 0, .y = 0, .width = 80, .height = 24 }, true);
    _ = popup_id;

    try testing.expectEqual(@as(usize, 1), mux.popup_mgr.count());
    const popup_window_id = mux.focusedPopupWindowId() orelse return error.TestUnexpectedResult;
    try testing.expect(mux.ptys.contains(popup_window_id));
}

test "multiplexer Ctrl+G p toggles popup shell" {
    const testing = std.testing;
    var mux = Multiplexer.init(testing.allocator, layout.nativeEngine());
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("base", &.{ "/bin/sh", "-c", "sleep 0.2" });

    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 'p' });
    try testing.expectEqual(@as(usize, 1), mux.popup_mgr.count());

    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 'p' });
    try testing.expectEqual(@as(usize, 0), mux.popup_mgr.count());
}

test "multiplexer modal popup captures forwarded input" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const base_win = try mux.createCommandWindow("base-cat", &.{"/bin/cat"});
    _ = try mux.openCommandPopup(
        "popup-cat",
        &.{"/bin/cat"},
        .{ .x = 0, .y = 0, .width = 100, .height = 30 },
        true,
        false,
    );
    const popup_win = mux.focusedPopupWindowId() orelse return error.TestUnexpectedResult;

    try mux.handleInputBytes("to-popup\n");

    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(30);
        const out = try mux.windowOutput(popup_win);
        if (std.mem.indexOf(u8, out, "to-popup") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const popup_out = try mux.windowOutput(popup_win);
    const base_out = try mux.windowOutput(base_win);

    try testing.expect(std.mem.indexOf(u8, popup_out, "to-popup") != null);
    try testing.expect(std.mem.indexOf(u8, base_out, "to-popup") == null);
}

test "multiplexer fzf popup auto-close path cleans up exited popup window" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");

    _ = try mux.openFzfPopup(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, true);
    const popup_win = mux.focusedPopupWindowId() orelse return error.TestUnexpectedResult;
    try testing.expect(mux.ptys.contains(popup_win));

    var tries: usize = 0;
    while (tries < 50 and mux.popup_mgr.count() > 0) : (tries += 1) {
        _ = try mux.tick(20, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try testing.expectEqual(@as(usize, 0), mux.popup_mgr.count());
    try testing.expect(!mux.ptys.contains(popup_win));
}

test "multiplexer exited window is cleaned up without shutting down loop" {
    const testing = std.testing;
    var mux = Multiplexer.init(testing.allocator, layout.nativeEngine());
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("oneshot", &.{ "/bin/sh", "-c", "exit 0" });

    var tries: usize = 0;
    while (tries < 40 and mux.ptys.contains(win_id)) : (tries += 1) {
        const t = try mux.tick(10, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
        try testing.expect(!t.should_shutdown);
    }

    try testing.expect(!mux.ptys.contains(win_id));
}

test "multiplexer exited non-auto-close popup cleans up only popup" {
    const testing = std.testing;
    var mux = Multiplexer.init(testing.allocator, layout.nativeEngine());
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("base", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.openCommandPopup(
        "oneshot-popup",
        &.{ "/bin/sh", "-c", "exit 0" },
        .{ .x = 0, .y = 0, .width = 80, .height = 24 },
        true,
        false,
    );

    var tries: usize = 0;
    while (tries < 40 and mux.popup_mgr.count() > 0) : (tries += 1) {
        const t = try mux.tick(10, .{ .x = 0, .y = 0, .width = 80, .height = 24 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
        try testing.expect(!t.should_shutdown);
    }

    try testing.expectEqual(@as(usize, 0), mux.popup_mgr.count());
    try testing.expectEqual(@as(usize, 1), try mux.workspace_mgr.activeWindowCount());
}

test "multiplexer scroll commands adjust focused window scroll offset" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("echo-lines", &.{ "/bin/sh", "-c", "printf 'a\\nb\\nc\\nd\\n'" });

    var tries: usize = 0;
    while (tries < 30) : (tries += 1) {
        _ = try mux.pollOnce(20);
        if (mux.focusedScrollOffset() > 0 or tries > 5) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 12 }, &.{ 0x07, 'u' });
    try testing.expect(mux.focusedScrollOffset() > 0);

    const before_down = mux.focusedScrollOffset();
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 12 }, &.{ 0x07, 'd' });
    try testing.expect(mux.focusedScrollOffset() <= before_down);
}

test "multiplexer search jumps scroll offset to matched line" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("echo-search", &.{ "/bin/sh", "-c", "printf 'alpha\\nbeta\\ngamma\\n'" });

    var tries: usize = 0;
    while (tries < 30) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "gamma") != null) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const found = mux.searchFocusedScrollback("beta", .backward) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), found.line_index);
    try testing.expect(mux.focusedScrollOffset() > 0);
}

test "multiplexer sync-scroll toggles and propagates across visible panes" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const left_id = try mux.createCommandWindow("left", &.{"/bin/cat"});
    const right_id = try mux.createCommandWindow("right", &.{"/bin/cat"});

    const fixture =
        "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n";
    try mux.scrollbacks.getPtr(left_id).?.append(fixture);
    try mux.scrollbacks.getPtr(right_id).?.append(fixture);

    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 12 };
    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 's' });
    try testing.expect(mux.syncScrollEnabled());

    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 'u' });

    const left_off = mux.windowScrollOffset(left_id) orelse return error.TestUnexpectedResult;
    const right_off = mux.windowScrollOffset(right_id) orelse return error.TestUnexpectedResult;
    try testing.expect(left_off > 0);
    try testing.expectEqual(left_off, right_off);

    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 's' });
    try testing.expect(!mux.syncScrollEnabled());
    try testing.expectEqual(@as(usize, 0), mux.windowScrollOffset(left_id).?);
    try testing.expectEqual(@as(usize, 0), mux.windowScrollOffset(right_id).?);

    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 'J' });
    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 'u' });
    const left_after = mux.windowScrollOffset(left_id) orelse return error.TestUnexpectedResult;
    const right_after = mux.windowScrollOffset(right_id) orelse return error.TestUnexpectedResult;
    try testing.expect(left_after != right_after);
}

test "multiplexer sync-scroll respects tab boundaries" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const dev_a = try mux.createCommandWindow("dev-a", &.{"/bin/cat"});
    const dev_b = try mux.createCommandWindow("dev-b", &.{"/bin/cat"});
    _ = try mux.createTab("ops");
    try mux.switchTab(1);
    const ops_a = try mux.createCommandWindow("ops-a", &.{"/bin/cat"});
    try mux.switchTab(0);

    const fixture = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n";
    try mux.scrollbacks.getPtr(dev_a).?.append(fixture);
    try mux.scrollbacks.getPtr(dev_b).?.append(fixture);
    try mux.scrollbacks.getPtr(ops_a).?.append(fixture);

    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 12 };
    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 's' });
    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 'u' });

    const ops_before = mux.windowScrollOffset(ops_a) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), ops_before);

    try mux.switchTab(1);
    const ops_after = mux.windowScrollOffset(ops_a) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), ops_after);
}

test "multiplexer suppresses forwarded input while focused pane is scrolled back" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    const sb = mux.scrollbacks.getPtr(win_id) orelse return error.TestUnexpectedResult;
    try sb.append("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    sb.scrollPageUp(3);
    try testing.expect(sb.scroll_offset > 0);

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 12 }, "blocked\n");
    _ = try mux.pollOnce(20);
    const out_blocked = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out_blocked, "blocked") == null);

    // Return to live bottom view then input should flow again.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 12 }, &.{ 0x07, 'd' });
    try testing.expectEqual(@as(usize, 0), sb.scroll_offset);

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 12 }, "ok\n");
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const out_ok = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out_ok, "ok") != null) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    const out_ok = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out_ok, "ok") != null);
}

test "multiplexer scrollback navigation mode supports vim and ctrl paging keys" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    const sb = mux.scrollbacks.getPtr(win_id) orelse return error.TestUnexpectedResult;
    try sb.append("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n");
    sb.scrollPageUp(2);
    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 10 };

    const off0 = sb.scroll_offset;
    try mux.handleInputBytesWithScreen(screen, "k");
    const off1 = sb.scroll_offset;
    try testing.expect(off1 > off0);

    try mux.handleInputBytesWithScreen(screen, "j");
    const off2 = sb.scroll_offset;
    try testing.expect(off2 < off1);

    try mux.handleInputBytesWithScreen(screen, &.{0x15}); // Ctrl+U
    const off3 = sb.scroll_offset;
    try testing.expect(off3 > off2);

    try mux.handleInputBytesWithScreen(screen, &.{0x04}); // Ctrl+D
    const off4 = sb.scroll_offset;
    try testing.expect(off4 < off3);

    // Ensure these keys were not forwarded to the child process.
    _ = try mux.pollOnce(20);
    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "k") == null);
    try testing.expect(std.mem.indexOf(u8, out, "j") == null);
}

test "multiplexer sync-scroll accepts nav controls immediately at offset zero" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const a = try mux.createCommandWindow("a", &.{"/bin/cat"});
    const b = try mux.createCommandWindow("b", &.{"/bin/cat"});
    try mux.scrollbacks.getPtr(a).?.append("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    try mux.scrollbacks.getPtr(b).?.append("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");

    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 12 };
    try mux.handleInputBytesWithScreen(screen, &.{ 0x07, 's' }); // enable sync
    try testing.expect(mux.syncScrollEnabled());
    try testing.expectEqual(@as(usize, 0), mux.windowScrollOffset(a).?);
    try testing.expectEqual(@as(usize, 0), mux.windowScrollOffset(b).?);

    try mux.handleInputBytesWithScreen(screen, "k");
    try testing.expect(mux.windowScrollOffset(a).? > 0);
    try testing.expectEqual(mux.windowScrollOffset(a).?, mux.windowScrollOffset(b).?);

    // In nav mode, non-prefixed input is consumed (not forwarded).
    try mux.handleInputBytesWithScreen(screen, "xyz");
    _ = try mux.pollOnce(20);
    const out_a = try mux.windowOutput(a);
    try testing.expect(std.mem.indexOf(u8, out_a, "xyz") == null);
}

test "multiplexer nav mode supports g G slash n N q and Esc" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    const sb = mux.scrollbacks.getPtr(win_id) orelse return error.TestUnexpectedResult;
    try sb.append("alpha\nbeta\ngamma\nbeta-delta\nomega\n");

    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 10 };
    sb.scrollPageUp(1);
    const before = sb.scroll_offset;

    try mux.handleInputBytesWithScreen(screen, "g");
    try testing.expect(sb.scroll_offset >= before);

    try mux.handleInputBytesWithScreen(screen, "G");
    try testing.expectEqual(@as(usize, 0), sb.scroll_offset);

    sb.scrollPageUp(2);
    try mux.handleInputBytesWithScreen(screen, "/beta\r");
    try testing.expect(mux.focusedScrollOffset() > 0);

    const off_after_search = mux.focusedScrollOffset();
    try mux.handleInputBytesWithScreen(screen, "n");
    try testing.expect(mux.focusedScrollOffset() >= 0);
    try mux.handleInputBytesWithScreen(screen, "N");
    try testing.expect(mux.focusedScrollOffset() >= 0);
    try testing.expect(off_after_search >= 0);

    try mux.handleInputBytesWithScreen(screen, "q");
    try testing.expectEqual(@as(usize, 0), mux.focusedScrollOffset());

    sb.scrollPageUp(2);
    try mux.handleInputBytesWithScreen(screen, "\x1b");
    try testing.expectEqual(@as(usize, 0), mux.focusedScrollOffset());
}

test "multiplexer nav mode h l move selection cursor x and are not forwarded" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    const sb = mux.scrollbacks.getPtr(win_id) orelse return error.TestUnexpectedResult;
    try sb.append("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n");
    sb.scrollPageUp(2);

    const x0 = mux.selectionCursorX(win_id);
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 10 }, "l");
    try testing.expect(mux.selectionCursorX(win_id) > x0);

    const x1 = mux.selectionCursorX(win_id);
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 10 }, "h");
    try testing.expect(mux.selectionCursorX(win_id) < x1 or mux.selectionCursorX(win_id) == 0);

    _ = try mux.pollOnce(20);
    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "h") == null);
    try testing.expect(std.mem.indexOf(u8, out, "l") == null);
}

test "multiplexer nav mode k at top scrolls up while cursor stays in viewport" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    const sb = mux.scrollbacks.getPtr(win_id) orelse return error.TestUnexpectedResult;
    try sb.append("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n");
    sb.scrollPageUp(2);

    // Put selection cursor at visual top row.
    try mux.selection_cursor_y.put(testing.allocator, win_id, 0);
    const before = sb.scroll_offset;
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 10 }, "k");
    try testing.expect(sb.scroll_offset > before);
    try testing.expectEqual(@as(usize, 0), mux.selectionCursorY(win_id, 10));
}

test "multiplexer nav mode supports 0 and $ horizontal cursor jumps" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    const sb = mux.scrollbacks.getPtr(win_id) orelse return error.TestUnexpectedResult;
    try sb.append("abcde\nline-two\n");
    sb.scrollPageUp(1);

    try mux.selection_cursor_x.put(testing.allocator, win_id, 3);
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 10 }, "0");
    try testing.expectEqual(@as(usize, 0), mux.selectionCursorX(win_id));

    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 10 }, "$");
    try testing.expect(mux.selectionCursorX(win_id) > 0);
}

test "terminal query parser counts plain DA and CPR across chunk boundaries" {
    const testing = std.testing;
    var state: Multiplexer.DaParseState = .idle;

    var counts = Multiplexer.countTerminalQueries(&state, "\x1b[");
    try testing.expectEqual(@as(usize, 0), counts.da);
    try testing.expectEqual(@as(usize, 0), counts.cpr);
    try testing.expectEqual(Multiplexer.DaParseState.csi_entry, state);

    counts = Multiplexer.countTerminalQueries(&state, "c");
    try testing.expectEqual(@as(usize, 1), counts.da);
    try testing.expectEqual(@as(usize, 0), counts.cpr);
    try testing.expectEqual(Multiplexer.DaParseState.idle, state);

    counts = Multiplexer.countTerminalQueries(&state, "\x1b[6");
    try testing.expectEqual(@as(usize, 0), counts.da);
    try testing.expectEqual(@as(usize, 0), counts.cpr);
    try testing.expectEqual(Multiplexer.DaParseState.csi_6, state);

    counts = Multiplexer.countTerminalQueries(&state, "n");
    try testing.expectEqual(@as(usize, 0), counts.da);
    try testing.expectEqual(@as(usize, 1), counts.cpr);
    try testing.expectEqual(Multiplexer.DaParseState.idle, state);
}

test "terminal query parser ignores parameterized CSI c and non-plain CPR variants" {
    const testing = std.testing;
    var state: Multiplexer.DaParseState = .idle;

    // DA response-style sequence should not be counted as a new DA query.
    var counts = Multiplexer.countTerminalQueries(&state, "\x1b[?62;c");
    try testing.expectEqual(@as(usize, 0), counts.da);
    try testing.expectEqual(@as(usize, 0), counts.cpr);
    try testing.expectEqual(Multiplexer.DaParseState.idle, state);

    // Parameterized CPR forms should not be counted as plain "CSI 6n" query.
    counts = Multiplexer.countTerminalQueries(&state, "\x1b[16n\x1b[?6n");
    try testing.expectEqual(@as(usize, 0), counts.da);
    try testing.expectEqual(@as(usize, 0), counts.cpr);
    try testing.expectEqual(Multiplexer.DaParseState.idle, state);
}
