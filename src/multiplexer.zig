const std = @import("std");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");
const pty_mod = @import("pty.zig");
const input_mod = @import("input.zig");
const signal_mod = @import("signal.zig");
const popup_mod = @import("popup.zig");
const scrollback_mod = @import("scrollback.zig");

pub const Multiplexer = struct {
    const DaParseState = enum(u2) {
        idle,
        esc,
        csi,
    };

    const DragState = struct {
        resizing_master: bool = false,
    };

    allocator: std.mem.Allocator,
    workspace_mgr: workspace.WorkspaceManager,
    popup_mgr: popup_mod.PopupManager,
    ptys: std.AutoHashMapUnmanaged(u32, pty_mod.Pty) = .{},
    stdout_buffers: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u8)) = .{},
    scrollbacks: std.AutoHashMapUnmanaged(u32, scrollback_mod.ScrollbackBuffer) = .{},
    dirty_windows: std.AutoHashMapUnmanaged(u32, void) = .{},
    da_parse_states: std.AutoHashMapUnmanaged(u32, DaParseState) = .{},
    input_router: input_mod.Router = .{},
    detach_requested: bool = false,
    last_mouse_event: ?input_mod.MouseEvent = null,
    drag_state: DragState = .{},
    next_popup_window_id: u32 = 1_000_000,

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
            p.deinit();
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
        self.dirty_windows.deinit(self.allocator);
        self.da_parse_states.deinit(self.allocator);

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

    pub fn createShellWindow(self: *Multiplexer, title: []const u8) !u32 {
        const id = try self.workspace_mgr.addWindowToActive(title);
        var p = try pty_mod.Pty.spawnShell(self.allocator);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, id, p);
        try self.stdout_buffers.put(self.allocator, id, .{});
        try self.scrollbacks.put(self.allocator, id, scrollback_mod.ScrollbackBuffer.init(self.allocator, 10_000));
        try self.da_parse_states.put(self.allocator, id, .idle);
        return id;
    }

    pub fn createCommandWindow(self: *Multiplexer, title: []const u8, argv: []const []const u8) !u32 {
        const id = try self.workspace_mgr.addWindowToActive(title);
        var p = try pty_mod.Pty.spawnCommand(self.allocator, argv);
        errdefer p.deinit();

        try self.ptys.put(self.allocator, id, p);
        try self.stdout_buffers.put(self.allocator, id, .{});
        try self.scrollbacks.put(self.allocator, id, scrollback_mod.ScrollbackBuffer.init(self.allocator, 10_000));
        try self.da_parse_states.put(self.allocator, id, .idle);
        return id;
    }

    pub fn computeActiveLayout(self: *Multiplexer, screen: layout.Rect) ![]layout.Rect {
        return self.workspace_mgr.computeActiveLayout(screen);
    }

    pub fn sendInputToFocused(self: *Multiplexer, bytes: []const u8) !void {
        const focused_id = try self.workspace_mgr.focusedWindowIdActive();
        const p = self.ptys.getPtr(focused_id) orelse return error.UnknownWindow;
        try p.write(bytes);
    }

    fn sendInputToFocusedPopup(self: *Multiplexer, bytes: []const u8) !void {
        const focused_id = self.popup_mgr.focusedWindowId() orelse return error.NoFocusedPopup;
        const p = self.ptys.getPtr(focused_id) orelse return error.UnknownWindow;
        try p.write(bytes);
    }

    pub fn handleInputBytes(self: *Multiplexer, bytes: []const u8) !void {
        return self.handleInputBytesWithScreen(null, bytes);
    }

    pub fn handleInputBytesWithScreen(
        self: *Multiplexer,
        screen: ?layout.Rect,
        bytes: []const u8,
    ) !void {
        for (bytes) |b| {
            const ev = self.input_router.feedByte(b);
            switch (ev) {
                .forward => |c| {
                    var tmp = [_]u8{c};
                    if (self.popup_mgr.hasModalOpen()) {
                        try self.sendInputToFocusedPopup(&tmp);
                    } else {
                        try self.sendInputToFocused(&tmp);
                    }
                },
                .forward_sequence => |seq| {
                    if (screen) |s| {
                        try self.handleMouseFromEvent(s, seq.mouse);
                    }
                    if (self.popup_mgr.hasModalOpen()) {
                        try self.sendInputToFocusedPopup(seq.slice());
                    } else {
                        try self.sendInputToFocused(seq.slice());
                    }
                    if (seq.mouse) |mouse| self.last_mouse_event = mouse;
                },
                .command => |cmd| switch (cmd) {
                    .create_window => {
                        _ = try self.createShellWindow("shell");
                    },
                    .close_window => {
                        _ = try self.closeFocusedWindow();
                    },
                    .open_popup => {
                        const s = screen orelse layout.Rect{ .x = 0, .y = 0, .width = 80, .height = 24 };
                        _ = try self.openFzfPopup(s, true);
                    },
                    .close_popup => {
                        try self.closeFocusedPopup();
                    },
                    .cycle_popup => {
                        self.popup_mgr.cycleFocus();
                    },
                    .new_tab => {
                        const n = self.workspace_mgr.tabCount();
                        var name_buf: [32]u8 = undefined;
                        const name = try std.fmt.bufPrint(&name_buf, "tab-{d}", .{n + 1});
                        const idx = try self.createTab(name);
                        try self.switchTab(idx);
                    },
                    .close_tab => {
                        self.closeActiveTab() catch |err| {
                            if (err != error.CannotCloseLastTab) return err;
                        };
                    },
                    .next_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 0) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            try self.switchTab((current + 1) % n);
                        }
                    },
                    .prev_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 0) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            const prev = if (current == 0) n - 1 else current - 1;
                            try self.switchTab(prev);
                        }
                    },
                    .move_window_next_tab => {
                        const n = self.workspace_mgr.tabCount();
                        if (n > 1) {
                            const current = self.workspace_mgr.activeTabIndex() orelse 0;
                            const dst = (current + 1) % n;
                            try self.workspace_mgr.moveFocusedWindowToTab(dst);
                        }
                    },
                    .next_window => try self.workspace_mgr.focusNextWindowActive(),
                    .prev_window => try self.workspace_mgr.focusPrevWindowActive(),
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
            const inner = contentSizeForRect(r, screen);
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
                const da_queries = countPrimaryDaQueries(state, tmp[0..n]);
                var q: usize = 0;
                while (q < da_queries) : (q += 1) {
                    // Respond to primary DA query for fish compatibility checks.
                    try p.write("\x1b[?62;c");
                }
            }
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

    pub fn focusedPopupWindowId(self: *Multiplexer) ?u32 {
        return self.popup_mgr.focusedWindowId();
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
    }

    pub fn scrollPageDownFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollPageDown(lines);
    }

    pub fn scrollHalfPageUpFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollHalfPageUp(lines);
    }

    pub fn scrollHalfPageDownFocused(self: *Multiplexer, lines: usize) void {
        const focused_id = self.workspace_mgr.focusedWindowIdActive() catch return;
        const sb = self.scrollbacks.getPtr(focused_id) orelse return;
        sb.scrollHalfPageDown(lines);
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
        return found;
    }

    pub fn dirtyWindowIds(self: *Multiplexer, allocator: std.mem.Allocator) ![]u32 {
        var ids = try allocator.alloc(u32, self.dirty_windows.count());
        errdefer allocator.free(ids);

        var i: usize = 0;
        var it = self.dirty_windows.iterator();
        while (it.next()) |entry| : (i += 1) ids[i] = entry.key_ptr.*;
        return ids;
    }

    pub fn clearDirtyWindow(self: *Multiplexer, window_id: u32) void {
        _ = self.dirty_windows.swapRemove(window_id);
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
            redraw = true;
        }

        const reads = try self.pollOnce(timeout_ms);
        if (reads > 0) redraw = true;
        const popup_updates = try self.processPopupTick();
        if (popup_updates > 0) redraw = true;

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
            _ = p.terminate() catch {};
            _ = p.wait() catch {};
            p.deinit();
        }
        self.ptys.clearRetainingCapacity();
        self.da_parse_states.clearRetainingCapacity();
    }

    pub fn closeFocusedWindow(self: *Multiplexer) !u32 {
        const id = try self.workspace_mgr.closeFocusedWindowActive();
        if (self.ptys.getPtr(id)) |p| p.deinit();
        _ = self.ptys.fetchRemove(id);
        _ = self.da_parse_states.fetchRemove(id);

        if (self.stdout_buffers.getPtr(id)) |list| list.deinit(self.allocator);
        _ = self.stdout_buffers.fetchRemove(id);
        if (self.scrollbacks.getPtr(id)) |sb| sb.deinit();
        _ = self.scrollbacks.fetchRemove(id);
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
        try self.da_parse_states.put(self.allocator, popup_window_id, .idle);

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

    pub fn closeFocusedPopup(self: *Multiplexer) !void {
        if (self.popup_mgr.startCloseAnimationFocused()) return;
        const removed = self.popup_mgr.closeFocused() orelse return;
        self.cleanupClosedPopup(removed);
    }

    pub fn closeActiveTab(self: *Multiplexer) !void {
        const removed_ids = try self.workspace_mgr.closeActiveTab(self.allocator);
        defer self.allocator.free(removed_ids);

        for (removed_ids) |id| {
            if (self.ptys.getPtr(id)) |p| p.deinit();
            _ = self.ptys.fetchRemove(id);
            _ = self.da_parse_states.fetchRemove(id);
            if (self.stdout_buffers.getPtr(id)) |list| list.deinit(self.allocator);
            _ = self.stdout_buffers.fetchRemove(id);
            if (self.scrollbacks.getPtr(id)) |sb| sb.deinit();
            _ = self.scrollbacks.fetchRemove(id);
            _ = self.dirty_windows.fetchRemove(id);
        }
    }

    fn markWindowDirty(self: *Multiplexer, window_id: u32) !void {
        try self.dirty_windows.put(self.allocator, window_id, {});
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

    fn handleMouseFromEvent(
        self: *Multiplexer,
        screen: layout.Rect,
        maybe_mouse: ?input_mod.MouseEvent,
    ) !void {
        const mouse = maybe_mouse orelse return;
        const px: u16 = if (mouse.x > 0) mouse.x - 1 else 0;
        const py: u16 = if (mouse.y > 0) mouse.y - 1 else 0;

        if (!mouse.pressed) {
            self.drag_state.resizing_master = false;
            return;
        }

        const motion = (mouse.button & 32) != 0;
        if (self.drag_state.resizing_master and motion) {
            try self.applyDragResize(screen, px);
            return;
        }

        if (mouse.button != 0) return;

        // Start divider drag for vertical stack if click is on divider.
        if (try self.hitDividerForVerticalStack(screen, px, py)) {
            self.drag_state.resizing_master = true;
            return;
        }

        // Otherwise it's a focus click.
        try self.applyClickFocus(screen, px, py);
    }

    fn applyClickFocus(
        self: *Multiplexer,
        screen: layout.Rect,
        px: u16,
        py: u16,
    ) !void {
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
            return;
        }
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

    fn applyDragResize(self: *Multiplexer, screen: layout.Rect, px: u16) !void {
        if (screen.width == 0) return;

        const local_x = if (px > screen.x) px - screen.x else 0;
        const ratio_u32 = (@as(u32, local_x) * 1000) / @as(u32, screen.width);
        const clamped: u16 = @intCast(@max(@as(u32, 100), @min(@as(u32, 900), ratio_u32)));
        try self.workspace_mgr.setActiveMasterRatioPermille(clamped);
        _ = try self.resizeActiveWindowsToLayout(screen);
    }

    fn countPrimaryDaQueries(state: *DaParseState, bytes: []const u8) usize {
        var count: usize = 0;
        for (bytes) |b| {
            switch (state.*) {
                .idle => {
                    if (b == 0x1b) state.* = .esc;
                },
                .esc => {
                    if (b == '[') {
                        state.* = .csi;
                    } else if (b == 0x1b) {
                        state.* = .esc;
                    } else {
                        state.* = .idle;
                    }
                },
                .csi => {
                    if (b == 'c') {
                        count += 1;
                        state.* = .idle;
                    } else if (b >= 0x40 and b <= 0x7e) {
                        state.* = .idle;
                    } else {
                        // Parameter/intermediate bytes (0x20-0x3f); keep parsing.
                    }
                },
            }
        }
        return count;
    }

    fn contentSizeForRect(r: layout.Rect, screen: layout.Rect) struct { rows: u16, cols: u16 } {
        // Keep this consistent with renderer border policy:
        // left/top border always drawn, right/bottom only on outer edge.
        const left_border: u16 = 1;
        const top_border: u16 = 1;
        const right_border: u16 = if (r.x + r.width == screen.x + screen.width) 1 else 0;
        const bottom_border: u16 = if (r.y + r.height == screen.y + screen.height) 1 else 0;

        const cols = r.width - left_border - right_border;
        const rows = r.height - top_border - bottom_border;
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
            if (self.ptys.getPtr(window_id)) |p| p.deinit();
            _ = self.ptys.fetchRemove(window_id);
            _ = self.da_parse_states.fetchRemove(window_id);
            if (self.stdout_buffers.getPtr(window_id)) |list| list.deinit(self.allocator);
            _ = self.stdout_buffers.fetchRemove(window_id);
            if (self.scrollbacks.getPtr(window_id)) |sb| sb.deinit();
            _ = self.scrollbacks.fetchRemove(window_id);
            _ = self.dirty_windows.fetchRemove(window_id);
        }
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

test "multiplexer forwards csi sequence and captures mouse metadata" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});

    try mux.handleInputBytes("\x1b[<0;3;4M");

    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(30);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "\x1b[<0;3;4M") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[<0;3;4M") != null);

    const mouse = mux.consumeLastMouseEvent() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 0), mouse.button);
    try testing.expectEqual(@as(u16, 3), mouse.x);
    try testing.expectEqual(@as(u16, 4), mouse.y);
    try testing.expect(mouse.pressed);
}

test "multiplexer click-to-focus selects pane by mouse coordinates" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("left", &.{ "/bin/sh", "-c", "sleep 0.2" });
    _ = try mux.createCommandWindow("right", &.{ "/bin/sh", "-c", "sleep 0.2" });

    try testing.expectEqual(@as(usize, 0), try mux.workspace_mgr.focusedWindowIndexActive());

    // Click near the right side in a 2-pane vertical layout.
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, "\x1b[<0;70;5M");
    try testing.expectEqual(@as(usize, 1), try mux.workspace_mgr.focusedWindowIndexActive());
}

test "multiplexer click forwards mouse sequence to newly focused pane" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const left_id = try mux.createCommandWindow("left", &.{"/bin/cat"});
    const right_id = try mux.createCommandWindow("right", &.{"/bin/cat"});

    const click = "\x1b[<0;70;5M";
    try mux.handleInputBytesWithScreen(.{ .x = 0, .y = 0, .width = 80, .height = 24 }, click);

    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        _ = try mux.pollOnce(20);
        const right_out = try mux.windowOutput(right_id);
        if (std.mem.indexOf(u8, right_out, click) != null) break;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const left_out = try mux.windowOutput(left_id);
    const right_out = try mux.windowOutput(right_id);

    try testing.expect(std.mem.indexOf(u8, right_out, click) != null);
    try testing.expect(std.mem.indexOf(u8, left_out, click) == null);
}

test "multiplexer drag-resize updates master ratio for vertical stack" {
    const testing = std.testing;
    const engine = @import("layout_native.zig").NativeLayoutEngine.init();

    var mux = Multiplexer.init(testing.allocator, engine);
    defer mux.deinit();

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
