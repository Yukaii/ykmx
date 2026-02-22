const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
const layout_opentui = @import("layout_opentui.zig");
const layout_plugin = @import("layout_plugin.zig");
const multiplexer = @import("multiplexer.zig");
const signal_mod = @import("signal.zig");
const workspace = @import("workspace.zig");
const zmx = @import("zmx.zig");
const config = @import("config.zig");
const status = @import("status.zig");
const benchmark = @import("benchmark.zig");
const scrollback_mod = @import("scrollback.zig");
const plugin_host = @import("plugin_host.zig");
const plugin_manager = @import("plugin_manager.zig");

const Terminal = ghostty_vt.Terminal;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("fcntl.h");
});

const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;
const RUNTIME_VT_MAX_SCROLLBACK: usize = 20_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    var run_poc = false;
    if (args.len == 1) {
        try runRuntimeLoop(alloc);
        return;
    }
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            try printHelp();
            return;
        }
        if (std.mem.eql(u8, args[1], "--version")) {
            var buf: [128]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            const out = &w.interface;
            try out.writeAll("ykmx 0.1.0-dev\n");
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, args[1], "--benchmark")) {
            const frames: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 200;
            const result = try benchmark.run(alloc, frames);
            var buf: [512]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            const out = &w.interface;
            try out.print(
                "benchmark: frames={} avg_ms={d:.3} p95_ms={d:.3} max_ms={d:.3}\n",
                .{ result.frames, result.avg_ms, result.p95_ms, result.max_ms },
            );
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, args[1], "--benchmark-layout")) {
            const iterations: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 500;
            const result = try benchmark.runLayoutChurn(alloc, iterations);

            var buf: [768]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            const out = &w.interface;

            try out.print(
                "layout_benchmark backend={s} iterations={} avg_ms={d:.3} p95_ms={d:.3} max_ms={d:.3}\n",
                .{
                    result.native.backend,
                    result.native.iterations,
                    result.native.avg_ms,
                    result.native.p95_ms,
                    result.native.max_ms,
                },
            );

            if (result.opentui) |op| {
                try out.print(
                    "layout_benchmark backend={s} iterations={} avg_ms={d:.3} p95_ms={d:.3} max_ms={d:.3}\n",
                    .{ op.backend, op.iterations, op.avg_ms, op.p95_ms, op.max_ms },
                );
            } else {
                try out.writeAll("layout_benchmark backend=opentui status=unavailable (OpenTUINotIntegratedYet)\n");
            }

            try out.flush();
            return;
        }
        if (std.mem.eql(u8, args[1], "--smoke-zmx")) {
            const session = if (args.len > 2) args[2] else "ykmx-smoke";
            const ok = try zmx.smokeAttachRoundTrip(alloc, session, "ykmx-zmx-smoke");
            var buf: [256]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            const out = &w.interface;
            try out.print("zmx_smoke_ok={}\n", .{ok});
            try out.flush();
            return;
        }
        if (std.mem.eql(u8, args[1], "--poc")) {
            run_poc = true;
        } else {
            try printHelp();
            return;
        }
    }

    if (!run_poc) {
        try runRuntimeLoop(alloc);
        return;
    }

    var cfg = try config.load(alloc);
    defer cfg.deinit(alloc);

    signal_mod.installHandlers();
    var zmx_env = try zmx.detect(alloc);
    defer zmx_env.deinit(alloc);

    var left = try Terminal.init(alloc, .{
        .rows = POC_ROWS,
        .cols = POC_COLS,
        .max_scrollback = 1000,
    });
    defer left.deinit(alloc);

    var right = try Terminal.init(alloc, .{
        .rows = POC_ROWS,
        .cols = POC_COLS,
        .max_scrollback = 1000,
    });
    defer right.deinit(alloc);

    var left_stream = left.vtStream();
    var right_stream = right.vtStream();

    try left_stream.nextSlice(
        "\x1b[1;34mLEFT\x1b[0m window\r\n" ++
            "line 1: hello from left\r\n" ++
            "line 2: \x1b[31mred\x1b[0m + \x1b[32mgreen\x1b[0m\r\n" ++
            "line 3: unicode -> lambda\r\n",
    );
    try right_stream.nextSlice(
        "\x1b[1;35mRIGHT\x1b[0m window\r\n" ++
            "line 1: hello from right\r\n" ++
            "line 2: \x1b[33myellow\x1b[0m text\r\n" ++
            "line 3: box -> [--]\r\n",
    );

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &out_writer.interface;

    try out.writeAll("ykmx phase-0: dual VT side-by-side compose\n\n");

    // Proves we can inspect each VT screen state (active screen + cursor).
    try out.print("left cursor: x={} y={}\n", .{ left.screens.active.cursor.x, left.screens.active.cursor.y });
    try out.print("right cursor: x={} y={}\n\n", .{ right.screens.active.cursor.x, right.screens.active.cursor.y });

    try printZmxAndSignalPOC(out, zmx_env);
    try printConfigPOC(out, cfg);
    try printWorkspacePOC(out, alloc, cfg);
    try printMultiplexerPOC(out, alloc, cfg, &zmx_env);
    try renderSideBySide(out, &left, &right);
    try out.flush();
}

fn printHelp() !void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.writeAll(
        \\ykmx - experimental terminal multiplexer
        \\
        \\Usage:
        \\  ykmx                 Run interactive runtime loop
        \\  ykmx --poc           Run verbose development POC output
        \\  ykmx --benchmark [N] Run frame benchmark (default N=200)
        \\  ykmx --benchmark-layout [N]
        \\                      Run layout churn benchmark (default N=500)
        \\  ykmx --smoke-zmx [session]
        \\  ykmx --version
        \\  ykmx --help
        \\
    );
    try out.flush();
}

fn runRuntimeLoop(allocator: std.mem.Allocator) !void {
    signal_mod.installHandlers();
    var env = try zmx.detect(allocator);
    defer env.deinit(allocator);
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);

    var plugins = plugin_manager.PluginManager.init(allocator);
    defer plugins.deinit();
    if (cfg.plugins_enabled) {
        var plugin_options = try allocator.alloc(plugin_manager.PluginManager.PluginOption, cfg.plugin_settings.items.len);
        defer allocator.free(plugin_options);
        for (cfg.plugin_settings.items, 0..) |s, i| {
            plugin_options[i] = .{
                .plugin_name = s.plugin_name,
                .key = s.key,
                .value = s.value,
            };
        }
        _ = plugins.startAll(cfg.plugin_dir, cfg.plugins_dir, cfg.plugins_dirs.items, plugin_options) catch 0;
    }

    var mux = multiplexer.Multiplexer.init(allocator, try pickLayoutEngineRuntime(allocator, cfg, &plugins));
    defer mux.deinit();
    mux.setMouseMode(switch (cfg.mouse_mode) {
        .hybrid => .hybrid,
        .passthrough => .passthrough,
        .compositor => .compositor,
    });
    mux.setPrefixPanelToggleKeys(cfg.key_toggle_sidebar_panel, cfg.key_toggle_bottom_panel);
    for (cfg.plugin_keybindings.items) |kb| {
        mux.setPluginPrefixedKeybinding(kb.key, kb.command_name) catch {};
    }

    _ = try mux.createTab("main");
    try mux.workspace_mgr.setActiveLayoutDefaults(cfg.default_layout, cfg.master_count, cfg.master_ratio_permille, cfg.gap);
    _ = try mux.createShellWindow("shell-1");
    _ = try mux.createShellWindow("shell-2");
    if (plugins.hasAny()) plugins.emitStart(try mux.workspace_mgr.activeLayoutType());
    var last_layout = try mux.workspace_mgr.activeLayoutType();

    var term = try RuntimeTerminal.enter();
    defer term.leave();
    var vt_state = RuntimeVtState.init(allocator);
    defer vt_state.deinit();
    var frame_cache = RuntimeFrameCache.init(allocator);
    defer frame_cache.deinit();

    var last_size = getTerminalSize();
    var last_content = contentRect(last_size);
    _ = mux.resizeActiveWindowsToLayout(last_content) catch {};
    var last_plugin_state = try collectPluginRuntimeState(&mux, last_content);
    if (plugins.hasAny()) plugins.emitStateChanged("start", last_plugin_state);

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.print(
        "ykmx runtime loop started (session={s})\r\n",
        .{env.session_name orelse "(none)"},
    );
    try out.flush();

    var force_redraw = true;
    var input_buf: [1024]u8 = undefined;
    while (true) {
        const size = getTerminalSize();
        const content = contentRect(size);
        if (size.cols != last_size.cols or size.rows != last_size.rows or
            content.width != last_content.width or content.height != last_content.height)
        {
            _ = mux.resizeActiveWindowsToLayout(content) catch {};
            force_redraw = true;
            last_size = size;
            last_content = content;
        }

        while (true) {
            const n = readStdinNonBlocking(&input_buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) break;
            try mux.handleInputBytesWithScreen(content, input_buf[0..n]);
        }

        const snap = signal_mod.drain();
        const tick_result = try mux.tick(30, content, snap);
        const current_layout = try mux.workspace_mgr.activeLayoutType();
        if (current_layout != last_layout) {
            if (plugins.hasAny()) plugins.emitLayoutChanged(current_layout);
            last_layout = current_layout;
        }
        if (plugins.hasAny()) {
            while (mux.consumeLastMouseEvent()) |mouse| {
                const px: u16 = if (mouse.x > 0) mouse.x - 1 else 0;
                const py: u16 = if (mouse.y > 0) mouse.y - 1 else 0;
                const popup_hit = mux.popupChromeHitAt(px, py);
                const hit = if (popup_hit == null) (mux.windowChromeHitAt(content, px, py) catch null) else null;
                const toolbar_hit = minimizedToolbarHitAt(&mux.workspace_mgr, content, px, py);
                plugins.emitPointer(
                    .{
                        .x = px,
                        .y = py,
                        .button = mouse.button,
                        .pressed = mouse.pressed,
                        .motion = (mouse.button & 32) != 0,
                    },
                    if (popup_hit) |ph| .{
                        .window_id = ph.window_id,
                        .window_index = 0,
                        .on_title_bar = false,
                        .on_minimize_button = false,
                        .on_maximize_button = false,
                        .on_close_button = false,
                        .on_minimized_toolbar = false,
                        .on_restore_button = false,
                        .is_panel = true,
                        .panel_id = ph.popup_id,
                        .panel_rect = ph.rect,
                        .on_panel_title_bar = ph.on_title_bar,
                        .on_panel_close_button = ph.on_close_button,
                        .on_panel_resize_left = ph.on_resize_left,
                        .on_panel_resize_right = ph.on_resize_right,
                        .on_panel_resize_top = ph.on_resize_top,
                        .on_panel_resize_bottom = ph.on_resize_bottom,
                        .on_panel_body = ph.on_body,
                    } else if (hit) |h| .{
                        .window_id = h.window_id,
                        .window_index = h.window_index,
                        .on_title_bar = h.on_title_bar,
                        .on_minimize_button = h.on_minimize_button,
                        .on_maximize_button = h.on_maximize_button,
                        .on_close_button = h.on_close_button,
                        .on_minimized_toolbar = false,
                        .on_restore_button = false,
                        .is_panel = false,
                        .panel_id = 0,
                        .panel_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                        .on_panel_title_bar = false,
                        .on_panel_close_button = false,
                        .on_panel_resize_left = false,
                        .on_panel_resize_right = false,
                        .on_panel_resize_top = false,
                        .on_panel_resize_bottom = false,
                        .on_panel_body = false,
                    } else if (toolbar_hit) |th| .{
                        .window_id = th.window_id,
                        .window_index = th.window_index,
                        .on_title_bar = false,
                        .on_minimize_button = false,
                        .on_maximize_button = false,
                        .on_close_button = false,
                        .on_minimized_toolbar = true,
                        .on_restore_button = true,
                        .is_panel = false,
                        .panel_id = 0,
                        .panel_rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
                        .on_panel_title_bar = false,
                        .on_panel_close_button = false,
                        .on_panel_resize_left = false,
                        .on_panel_resize_right = false,
                        .on_panel_resize_top = false,
                        .on_panel_resize_bottom = false,
                        .on_panel_body = false,
                    } else null,
                );
            }
            while (mux.consumeOldestPendingPluginCommand()) |cmd| {
                plugins.emitCommand(cmd);
            }
            while (mux.consumeOldestPendingPluginCommandName()) |owned_name| {
                defer allocator.free(owned_name);
                plugins.emitCommandName(owned_name);
            }
        }
        if (plugins.hasAny()) {
            const actions = plugins.drainActions(allocator) catch null;
            if (actions) |owned| {
                defer {
                    for (owned) |*action| plugin_host.PluginHost.deinitActionPayload(allocator, action);
                    allocator.free(owned);
                }
                var changed = false;
                for (owned) |action| {
                    changed = (try applyPluginAction(&mux, content, action)) or changed;
                }
                if (changed) force_redraw = true;
            }
            if (plugins.consumeUiDirtyAny()) force_redraw = true;
        }

        const current_plugin_state = try collectPluginRuntimeState(&mux, content);
        if (plugins.hasAny()) {
            if (!pluginRuntimeStateEql(last_plugin_state, current_plugin_state)) {
                const reason = detectStateChangeReason(last_plugin_state, current_plugin_state);
                plugins.emitStateChanged(reason, current_plugin_state);
                last_plugin_state = current_plugin_state;
            }

            const should_emit_tick = tick_result.reads > 0 or tick_result.resized > 0 or tick_result.popup_updates > 0 or tick_result.redraw or tick_result.detach_requested or snap.sigwinch or snap.sighup or snap.sigterm;
            if (should_emit_tick) {
                plugins.emitTick(.{
                    .reads = tick_result.reads,
                    .resized = tick_result.resized,
                    .popup_updates = tick_result.popup_updates,
                    .redraw = tick_result.redraw,
                    .detach_requested = tick_result.detach_requested,
                    .sigwinch = snap.sigwinch,
                    .sighup = snap.sighup,
                    .sigterm = snap.sigterm,
                }, current_plugin_state);
            }
        } else {
            last_plugin_state = current_plugin_state;
        }

        // Keep known VT instances warm even when their tab is inactive.
        // This amortizes parse work and reduces tab-switch spikes for long buffers.
        try warmKnownDirtyWindowVtState(allocator, &mux, &vt_state);

        if (tick_result.detach_requested) {
            _ = env.detachCurrentSession(allocator) catch {};
        }
        if (tick_result.should_shutdown) break;

        if (snap.sigwinch) force_redraw = true;
        if (force_redraw or tick_result.redraw) {
            try renderRuntimeFrame(out, allocator, &mux, &vt_state, &frame_cache, size, content, if (plugins.hasAny()) plugins.uiBars() else null);
            try out.flush();
            force_redraw = false;
        }
    }
    if (plugins.hasAny()) plugins.emitShutdown();
}

fn collectPluginRuntimeState(
    mux: *multiplexer.Multiplexer,
    screen: layout.Rect,
) !plugin_host.PluginHost.RuntimeState {
    const layout_type = try mux.workspace_mgr.activeLayoutType();
    const tab = try mux.workspace_mgr.activeTab();
    const window_count = tab.windows.items.len;
    var minimized_count: usize = 0;
    for (tab.windows.items) |w| {
        if (w.minimized) minimized_count += 1;
    }
    const focus_idx = mux.workspace_mgr.focusedWindowIndexActive() catch null;
    const focus_id = mux.workspace_mgr.focusedWindowIdActive() catch null;
    const focused_panel_id = mux.popup_mgr.focused_popup_id orelse 0;
    const master_count = try mux.workspace_mgr.activeMasterCount();
    const master_ratio = try mux.workspace_mgr.activeMasterRatioPermille();
    const active_tab_idx = mux.workspace_mgr.activeTabIndex();

    return .{
        .layout = @tagName(layout_type),
        .window_count = window_count,
        .minimized_window_count = minimized_count,
        .visible_window_count = window_count - minimized_count,
        .panel_count = mux.popup_mgr.count(),
        .focused_panel_id = focused_panel_id,
        .has_focused_panel = mux.popup_mgr.focused_popup_id != null,
        .focused_index = focus_idx orelse 0,
        .focused_window_id = focus_id orelse 0,
        .has_focused_window = focus_idx != null,
        .tab_count = mux.workspace_mgr.tabCount(),
        .active_tab_index = active_tab_idx orelse 0,
        .has_active_tab = active_tab_idx != null,
        .master_count = master_count,
        .master_ratio_permille = master_ratio,
        .mouse_mode = @tagName(mux.mouseMode()),
        .sync_scroll_enabled = mux.syncScrollEnabled(),
        .screen = screen,
    };
}

fn pluginRuntimeStateEql(
    a: plugin_host.PluginHost.RuntimeState,
    b: plugin_host.PluginHost.RuntimeState,
) bool {
    return std.mem.eql(u8, a.layout, b.layout) and
        a.window_count == b.window_count and
        a.minimized_window_count == b.minimized_window_count and
        a.visible_window_count == b.visible_window_count and
        a.panel_count == b.panel_count and
        a.focused_panel_id == b.focused_panel_id and
        a.has_focused_panel == b.has_focused_panel and
        a.focused_index == b.focused_index and
        a.focused_window_id == b.focused_window_id and
        a.has_focused_window == b.has_focused_window and
        a.tab_count == b.tab_count and
        a.active_tab_index == b.active_tab_index and
        a.has_active_tab == b.has_active_tab and
        a.master_count == b.master_count and
        a.master_ratio_permille == b.master_ratio_permille and
        std.mem.eql(u8, a.mouse_mode, b.mouse_mode) and
        a.sync_scroll_enabled == b.sync_scroll_enabled and
        std.meta.eql(a.screen, b.screen);
}

fn detectStateChangeReason(
    prev: plugin_host.PluginHost.RuntimeState,
    next: plugin_host.PluginHost.RuntimeState,
) []const u8 {
    if (!std.mem.eql(u8, prev.layout, next.layout)) return "layout";
    if (prev.window_count != next.window_count) return "window_count";
    if (prev.minimized_window_count != next.minimized_window_count or prev.visible_window_count != next.visible_window_count) return "window_count";
    if (prev.panel_count != next.panel_count or prev.focused_panel_id != next.focused_panel_id or prev.has_focused_panel != next.has_focused_panel) return "focus";
    if (prev.focused_index != next.focused_index or prev.focused_window_id != next.focused_window_id or prev.has_focused_window != next.has_focused_window) return "focus";
    if (prev.tab_count != next.tab_count or prev.active_tab_index != next.active_tab_index or prev.has_active_tab != next.has_active_tab) return "tab";
    if (prev.master_count != next.master_count or prev.master_ratio_permille != next.master_ratio_permille) return "master";
    if (!std.mem.eql(u8, prev.mouse_mode, next.mouse_mode)) return "mouse_mode";
    if (prev.sync_scroll_enabled != next.sync_scroll_enabled) return "sync_scroll";
    if (!std.meta.eql(prev.screen, next.screen)) return "screen";
    return "state";
}

fn applyPluginAction(
    mux: *multiplexer.Multiplexer,
    screen: layout.Rect,
    action: plugin_host.PluginHost.Action,
) !bool {
    switch (action) {
        .cycle_layout => {
            _ = try mux.workspace_mgr.cycleActiveLayout();
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .set_layout => |layout_type| {
            try mux.workspace_mgr.setActiveLayout(layout_type);
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .set_master_ratio_permille => |value| {
            const clamped: u16 = @intCast(@max(@as(u32, 100), @min(@as(u32, 900), value)));
            try mux.workspace_mgr.setActiveMasterRatioPermille(clamped);
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .request_redraw => {
            return true;
        },
        .minimize_focused_window => {
            return try mux.minimizeFocusedWindow(screen);
        },
        .restore_all_minimized_windows => {
            return (try mux.restoreAllMinimizedWindows(screen)) > 0;
        },
        .move_focused_window_to_index => |index| {
            return try mux.moveFocusedWindowToIndex(index, screen);
        },
        .move_window_by_id_to_index => |payload| {
            return try mux.moveWindowByIdToIndex(payload.window_id, payload.index, screen);
        },
        .close_focused_window => {
            _ = mux.closeFocusedWindow() catch |err| switch (err) {
                error.NoFocusedWindow => return false,
                else => return err,
            };
            _ = try mux.resizeActiveWindowsToLayout(screen);
            return true;
        },
        .restore_window_by_id => |window_id| {
            return try mux.restoreWindowById(window_id, screen);
        },
        .register_command => |payload| {
            try mux.setPluginCommandOverride(payload.command, payload.enabled);
            return false;
        },
        .register_command_name => |payload| {
            try mux.setPluginNamedCommandOverride(payload.command_name, payload.enabled);
            return false;
        },
        .open_shell_panel => {
            _ = try mux.openShellPopup("popup-shell", screen, true);
            return true;
        },
        .close_focused_panel => {
            try mux.closeFocusedPopup();
            return true;
        },
        .cycle_panel_focus => {
            mux.popup_mgr.cycleFocus();
            return true;
        },
        .toggle_shell_panel => {
            if (mux.popup_mgr.count() > 0) {
                try mux.closeFocusedPopup();
            } else {
                _ = try mux.openShellPopup("popup-shell", screen, true);
            }
            return true;
        },
        .open_shell_panel_rect => |payload| {
            _ = try mux.openShellPopupRectStyled(
                "popup-shell",
                screen,
                .{
                    .x = payload.x,
                    .y = payload.y,
                    .width = payload.width,
                    .height = payload.height,
                },
                payload.modal,
                .{
                    .transparent_background = payload.transparent_background,
                    .show_border = payload.show_border,
                    .show_controls = payload.show_controls,
                },
            );
            return true;
        },
        .close_panel_by_id => |panel_id| {
            return try mux.closePopupById(panel_id);
        },
        .focus_panel_by_id => |panel_id| {
            return try mux.focusPopupById(panel_id);
        },
        .move_panel_by_id => |payload| {
            return try mux.movePopupById(payload.panel_id, payload.x, payload.y, screen);
        },
        .resize_panel_by_id => |payload| {
            return try mux.resizePopupById(payload.panel_id, payload.width, payload.height, screen);
        },
        .set_panel_style_by_id => |payload| {
            return try mux.setPopupStyleById(payload.panel_id, .{
                .transparent_background = payload.transparent_background,
                .show_border = payload.show_border,
                .show_controls = payload.show_controls,
            }, screen);
        },
    }
}

const RuntimeTerminal = struct {
    had_termios: bool = false,
    original_termios: c.struct_termios = undefined,
    original_stdin_flags: c_int = 0,
    original_stdout_flags: c_int = 0,

    fn enter() !RuntimeTerminal {
        var rt: RuntimeTerminal = .{};

        rt.original_stdin_flags = c.fcntl(c.STDIN_FILENO, c.F_GETFL, @as(c_int, 0));
        if (rt.original_stdin_flags >= 0) {
            _ = c.fcntl(c.STDIN_FILENO, c.F_SETFL, rt.original_stdin_flags | c.O_NONBLOCK);
        }

        // Force compositor output path to blocking writes so VT control sequences
        // are not fragmented under backpressure (can render as literal "236m", etc).
        rt.original_stdout_flags = c.fcntl(c.STDOUT_FILENO, c.F_GETFL, @as(c_int, 0));
        if (rt.original_stdout_flags >= 0) {
            _ = c.fcntl(c.STDOUT_FILENO, c.F_SETFL, rt.original_stdout_flags & ~@as(c_int, c.O_NONBLOCK));
        }

        var termios_state: c.struct_termios = undefined;
        if (c.tcgetattr(c.STDIN_FILENO, &termios_state) == 0) {
            rt.had_termios = true;
            rt.original_termios = termios_state;
            var raw = termios_state;
            raw.c_lflag &= ~@as(c_uint, @intCast(c.ECHO | c.ICANON | c.ISIG));
            raw.c_iflag &= ~@as(c_uint, @intCast(c.IXON | c.ICRNL));
            raw.c_oflag &= ~@as(c_uint, @intCast(c.OPOST));
            raw.c_cc[c.VMIN] = 0;
            raw.c_cc[c.VTIME] = 0;
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
        }

        // Enter alternate screen, enable mouse reporting (click/drag/all-motion + SGR), disable autowrap, hide cursor.
        const enter_seq = "\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[?25l";
        _ = c.write(c.STDOUT_FILENO, enter_seq, enter_seq.len);
        return rt;
    }

    fn leave(self: *RuntimeTerminal) void {
        // Disable mouse reporting, restore autowrap, show cursor, leave alternate screen.
        const leave_seq = "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l\x1b[?7h\x1b[?25h\x1b[?1049l";
        _ = c.write(c.STDOUT_FILENO, leave_seq, leave_seq.len);
        if (self.had_termios) {
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &self.original_termios);
        }
        if (self.original_stdin_flags >= 0) {
            _ = c.fcntl(c.STDIN_FILENO, c.F_SETFL, self.original_stdin_flags);
        }
        if (self.original_stdout_flags >= 0) {
            _ = c.fcntl(c.STDOUT_FILENO, c.F_SETFL, self.original_stdout_flags);
        }
    }
};

const RuntimeSize = struct {
    cols: u16,
    rows: u16,
};

const RuntimeRenderCell = struct {
    text: [32]u8 = [_]u8{' '} ++ ([_]u8{0} ** 31),
    text_len: u8 = 1,
    style: ghostty_vt.Style = .{},
    styled: bool = false,
};

const RuntimeFrameCache = struct {
    allocator: std.mem.Allocator,
    cols: usize = 0,
    rows: usize = 0,
    cells: []RuntimeRenderCell = &.{},

    fn init(allocator: std.mem.Allocator) RuntimeFrameCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RuntimeFrameCache) void {
        if (self.cells.len > 0) self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn ensureSize(self: *RuntimeFrameCache, cols: usize, rows: usize) !bool {
        if (self.cols == cols and self.rows == rows and self.cells.len == cols * rows) return false;
        if (self.cells.len > 0) self.allocator.free(self.cells);
        self.cols = cols;
        self.rows = rows;
        self.cells = try self.allocator.alloc(RuntimeRenderCell, cols * rows);
        for (self.cells) |*cell| cell.* = .{};
        return true;
    }
};

const PaneRenderRef = struct {
    content_x: u16,
    content_y: u16,
    content_w: u16,
    content_h: u16,
    scroll_offset: usize = 0,
    scrollback: ?*const scrollback_mod.ScrollbackBuffer = null,
    term: *Terminal,
};

const PaneRenderCell = struct {
    text: [32]u8 = [_]u8{0} ** 32,
    text_len: u8 = 0,
    style: ghostty_vt.Style,
    skip_draw: bool = false,
};

const RuntimeVtState = struct {
    const WindowVt = struct {
        term: Terminal,
        consumed_bytes: usize = 0,
        cols: u16,
        rows: u16,
        stream_tail: [256]u8 = [_]u8{0} ** 256,
        stream_tail_len: u16 = 0,
    };

    allocator: std.mem.Allocator,
    windows: std.AutoHashMapUnmanaged(u32, WindowVt) = .{},

    fn init(allocator: std.mem.Allocator) RuntimeVtState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RuntimeVtState) void {
        var it = self.windows.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.term.deinit(self.allocator);
        }
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    fn syncWindow(
        self: *RuntimeVtState,
        window_id: u32,
        cols: u16,
        rows: u16,
        output: []const u8,
    ) !*WindowVt {
        const safe_cols: u16 = @max(@as(u16, 1), cols);
        const safe_rows: u16 = @max(@as(u16, 1), rows);

        const gop = try self.windows.getOrPut(self.allocator, window_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .term = try Terminal.init(self.allocator, .{
                    .rows = safe_rows,
                    .cols = safe_cols,
                    // Keep VT history deeper than logical scrollback so
                    // styled rendering stays available through normal scrollback.
                    .max_scrollback = RUNTIME_VT_MAX_SCROLLBACK,
                }),
                .consumed_bytes = 0,
                .cols = safe_cols,
                .rows = safe_rows,
            };
        }

        var wv = gop.value_ptr;
        if (wv.cols != safe_cols or wv.rows != safe_rows) {
            try wv.term.resize(self.allocator, safe_cols, safe_rows);
            wv.cols = safe_cols;
            wv.rows = safe_rows;
        }

        if (wv.consumed_bytes > output.len) {
            wv.consumed_bytes = 0;
            wv.stream_tail_len = 0;
        }
        if (output.len > wv.consumed_bytes) {
            const delta = output[wv.consumed_bytes..];
            const tail_len: usize = wv.stream_tail_len;
            var merged = try self.allocator.alloc(u8, tail_len + delta.len);
            defer self.allocator.free(merged);
            if (tail_len > 0) @memcpy(merged[0..tail_len], wv.stream_tail[0..tail_len]);
            @memcpy(merged[tail_len..], delta);

            const ansi_safe = ansiSafePrefixLen(merged);
            const split = utf8SafePrefixLen(merged[0..ansi_safe]);
            if (split > 0) {
                var stream = wv.term.vtStream();
                const sanitized = try stripUnsupportedXtwinops(self.allocator, merged[0..split]);
                defer if (sanitized) |owned| self.allocator.free(owned);
                try stream.nextSlice(if (sanitized) |owned| owned else merged[0..split]);
            }

            const rem = merged[split..];
            wv.stream_tail_len = @intCast(@min(rem.len, wv.stream_tail.len));
            if (wv.stream_tail_len > 0) {
                @memcpy(wv.stream_tail[0..wv.stream_tail_len], rem[0..wv.stream_tail_len]);
            }
            wv.consumed_bytes = output.len;
        }

        return wv;
    }

    fn prune(self: *RuntimeVtState, active_ids: []const u32) !void {
        var to_remove = std.ArrayList(u32).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.windows.iterator();
        while (it.next()) |entry| {
            const id = entry.key_ptr.*;
            var keep = false;
            for (active_ids) |aid| {
                if (aid == id) {
                    keep = true;
                    break;
                }
            }
            if (!keep) try to_remove.append(self.allocator, id);
        }

        for (to_remove.items) |id| {
            if (self.windows.getPtr(id)) |wv| {
                wv.term.deinit(self.allocator);
            }
            _ = self.windows.fetchRemove(id);
        }
    }

    fn syncKnownWindow(self: *RuntimeVtState, window_id: u32, output: []const u8) !bool {
        const wv = self.windows.getPtr(window_id) orelse return false;
        const cols = wv.cols;
        const rows = wv.rows;
        _ = try self.syncWindow(window_id, cols, rows, output);
        return true;
    }
};

fn stripUnsupportedXtwinops(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    // ghostty-vt logs noisy warnings for CSI 22/23 t with extra parameters.
    // These title stack operations are not relevant for pane compositing here.
    if (std.mem.indexOf(u8, input, "\x1b[22") == null and std.mem.indexOf(u8, input, "\x1b[23") == null) {
        return null;
    }

    var out = std.ArrayListUnmanaged(u8){};
    defer if (out.items.len == 0) out.deinit(allocator);

    var i: usize = 0;
    var changed = false;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 2 < input.len and input[i + 1] == '[') {
            var j = i + 2;
            while (j < input.len and ((input[j] >= '0' and input[j] <= '9') or input[j] == ';')) : (j += 1) {}
            if (j < input.len and input[j] == 't') {
                if (parseFirstCsiParam(input[i + 2 .. j])) |first| {
                    if (first == 22 or first == 23) {
                        changed = true;
                        i = j + 1;
                        continue;
                    }
                }
                try out.appendSlice(allocator, input[i .. j + 1]);
                i = j + 1;
                continue;
            }
        }

        try out.append(allocator, input[i]);
        i += 1;
    }

    if (!changed) {
        out.deinit(allocator);
        return null;
    }

    const owned = try out.toOwnedSlice(allocator);
    return @as(?[]u8, owned);
}

fn parseFirstCsiParam(params: []const u8) ?u16 {
    if (params.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u16, params[0..end], 10) catch null;
}

fn utf8SafePrefixLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var i = bytes.len;
    var cont: usize = 0;
    while (i > 0 and cont < 3 and isUtf8ContinuationByte(bytes[i - 1])) : (cont += 1) {
        i -= 1;
    }

    const lead_idx: usize = if (i > 0) i - 1 else return bytes.len - cont;
    const lead = bytes[lead_idx];
    const expected = utf8ExpectedLenFromLead(lead) orelse return bytes.len;
    const have = bytes.len - lead_idx;
    if (have < expected) return lead_idx;
    return bytes.len;
}

fn ansiSafePrefixLen(bytes: []const u8) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0x1b) {
            if (i + 1 >= bytes.len) return i;
            const n = bytes[i + 1];
            if (n == '[') {
                var j = i + 2;
                while (j < bytes.len and !isCsiFinalByte(bytes[j])) : (j += 1) {}
                if (j >= bytes.len) return i;
                i = j + 1;
                continue;
            }
            // For non-CSI escapes (OSC/DCS/etc), avoid blocking parser progress:
            // pass through and rely on downstream VT parser state.
            i += 1;
            continue;
        }

        // C1 control forms (single-byte CSI/OSC/DCS/ST)
        if (b == 0x9b) {
            var j = i + 1;
            while (j < bytes.len and !isCsiFinalByte(bytes[j])) : (j += 1) {}
            if (j >= bytes.len) return i;
            i = j + 1;
            continue;
        }
        i += 1;
    }
    return bytes.len;
}

fn isCsiFinalByte(b: u8) bool {
    return b >= '@' and b <= '~';
}

fn isUtf8ContinuationByte(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

fn utf8ExpectedLenFromLead(b: u8) ?usize {
    if ((b & 0b1000_0000) == 0) return 1;
    if ((b & 0b1110_0000) == 0b1100_0000) return 2;
    if ((b & 0b1111_0000) == 0b1110_0000) return 3;
    if ((b & 0b1111_1000) == 0b1111_0000) return 4;
    return null;
}

fn getTerminalSize() RuntimeSize {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) == 0) {
        const cols: u16 = if (ws.ws_col > 0) @intCast(ws.ws_col) else 80;
        const rows: u16 = if (ws.ws_row > 0) @intCast(ws.ws_row) else 24;
        return .{ .cols = cols, .rows = rows };
    }
    return .{ .cols = 80, .rows = 24 };
}

fn contentRect(size: RuntimeSize) layout.Rect {
    // Reserve three lines at bottom for minimized-toolbar + tab + status bars.
    const usable_rows: u16 = if (size.rows > 4) size.rows - 3 else 1;
    return .{ .x = 0, .y = 0, .width = size.cols, .height = usable_rows };
}

fn readStdinNonBlocking(buf: []u8) !usize {
    return std.posix.read(c.STDIN_FILENO, buf);
}

fn warmKnownDirtyWindowVtState(
    allocator: std.mem.Allocator,
    mux: *multiplexer.Multiplexer,
    vt_state: *RuntimeVtState,
) !void {
    const dirty = try mux.dirtyWindowIds(allocator);
    defer allocator.free(dirty);

    for (dirty) |window_id| {
        const output = mux.windowOutput(window_id) catch {
            mux.clearDirtyWindow(window_id);
            continue;
        };
        _ = try vt_state.syncKnownWindow(window_id, output);
        mux.clearDirtyWindow(window_id);
    }
}

fn renderRuntimeFrame(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    mux: *multiplexer.Multiplexer,
    vt_state: *RuntimeVtState,
    frame_cache: *RuntimeFrameCache,
    size: RuntimeSize,
    content: layout.Rect,
    plugin_ui_bars: ?plugin_host.PluginHost.UiBarsView,
) !void {
    const total_cols: usize = size.cols;
    const content_rows: usize = content.height;
    const total_rows: usize = content_rows + 3;
    const canvas_len = total_cols * content_rows;
    const canvas = try allocator.alloc(u21, canvas_len);
    defer allocator.free(canvas);
    @memset(canvas, ' ');
    const border_conn = try allocator.alloc(u8, canvas_len);
    defer allocator.free(border_conn);
    @memset(border_conn, 0);
    const popup_overlay = try allocator.alloc(bool, canvas_len);
    defer allocator.free(popup_overlay);
    @memset(popup_overlay, false);
    const popup_cover = try allocator.alloc(bool, canvas_len);
    defer allocator.free(popup_cover);
    @memset(popup_cover, false);
    const top_window_owner = try allocator.alloc(i32, canvas_len);
    defer allocator.free(top_window_owner);
    @memset(top_window_owner, -1);

    const rects = try mux.computeActiveLayout(content);
    defer allocator.free(rects);
    const tab = try mux.workspace_mgr.activeTab();
    const n = @min(rects.len, tab.windows.items.len);
    const popup_count = mux.popup_mgr.count();
    var panes = try allocator.alloc(PaneRenderRef, n + popup_count);
    defer allocator.free(panes);
    var pane_count: usize = 0;
    var focused_cursor_abs: ?struct { row: usize, col: usize } = null;

    for (rects[0..n], 0..) |r, i| {
        if (r.width == 0 or r.height == 0) continue;
        var yy: usize = r.y;
        const y_end: usize = @min(@as(usize, r.y + r.height), content_rows);
        while (yy < y_end) : (yy += 1) {
            var xx: usize = r.x;
            const x_end: usize = @min(@as(usize, r.x + r.width), total_cols);
            while (xx < x_end) : (xx += 1) {
                top_window_owner[yy * total_cols + xx] = @intCast(i);
            }
        }
    }

    for (rects[0..n], 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects[0..n], i, r, content);
        const insets = computeContentInsets(rects[0..n], i, r, border);
        drawBorder(canvas, border_conn, total_cols, content_rows, r, border, if (tab.focused_index == i) '*' else ' ', i, top_window_owner);
        const inner_x = r.x + insets.left;
        const inner_y = r.y + insets.top;
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        const inner_h = if (r.height > insets.top + insets.bottom) r.height - insets.top - insets.bottom else 0;
        if (inner_w == 0 or inner_h == 0) continue;

        const title = tab.windows.items[i].title;
        const controls = "[_][+][x]";
        const controls_w: u16 = @intCast(controls.len);
        const title_max = if (r.width >= 10 and inner_w > controls_w) inner_w - controls_w else inner_w;
        drawTextOwnedMasked(canvas, total_cols, content_rows, inner_x, r.y, title, title_max, i, top_window_owner, popup_overlay);
        if (r.width >= 10) {
            const controls_x: u16 = r.x + r.width - controls_w - 1;
            drawTextOwnedMasked(canvas, total_cols, content_rows, controls_x, r.y, controls, controls_w, i, top_window_owner, popup_overlay);
        }

        const window_id = tab.windows.items[i].id;
        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        const pane_scroll_offset = mux.windowScrollOffset(window_id) orelse 0;
        panes[pane_count] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .scroll_offset = pane_scroll_offset,
            .scrollback = mux.scrollbackBuffer(window_id),
            .term = &wv.term,
        };
        pane_count += 1;

        if (tab.focused_index == i) {
            if (pane_scroll_offset > 0) {
                // In scrollback view, render a local selection cursor anchor
                // instead of the live app cursor.
                const sel_x = @min(mux.selectionCursorX(window_id), @as(usize, inner_w - 1));
                const sel_y = @min(mux.selectionCursorY(window_id, inner_h), @as(usize, inner_h - 1));
                focused_cursor_abs = .{
                    .row = @as(usize, inner_y) + sel_y + 1,
                    .col = @as(usize, inner_x) + sel_x + 1,
                };
            } else {
                const cursor = wv.term.screens.active.cursor;
                const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
                const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
                focused_cursor_abs = .{
                    .row = @as(usize, inner_y) + cy + 1,
                    .col = @as(usize, inner_x) + cx + 1,
                };
            }
        }
    }

    var popup_order = try allocator.alloc(usize, mux.popup_mgr.popups.items.len);
    defer allocator.free(popup_order);
    for (popup_order, 0..) |*slot, i| slot.* = i;
    var po_i: usize = 1;
    while (po_i < popup_order.len) : (po_i += 1) {
        const key = popup_order[po_i];
        const key_z = mux.popup_mgr.popups.items[key].z_index;
        var j = po_i;
        while (j > 0 and mux.popup_mgr.popups.items[popup_order[j - 1]].z_index > key_z) : (j -= 1) {
            popup_order[j] = popup_order[j - 1];
        }
        popup_order[j] = key;
    }

    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        const window_id = p.window_id orelse continue;
        if (window_id == 0) continue;
        if (p.rect.width < 2 or p.rect.height < 2) continue;

        // Hard clear any previously composed base chrome/text under this panel.
        // This prevents underlying pane controls from leaking onto panel borders.
        clearCanvasRect(canvas, total_cols, content_rows, p.rect);
        // Also clear preexisting border connectivity in the panel rect so edge
        // intersections don't synthesize mixed glyphs like '┬' from underneath.
        clearBorderConnRect(border_conn, total_cols, content_rows, p.rect);
        const popup_border: BorderMask = .{ .left = true, .right = true, .top = true, .bottom = true };
        drawBorder(canvas, border_conn, total_cols, content_rows, p.rect, popup_border, if (mux.popup_mgr.focused_popup_id == p.id) '*' else ' ', null, null);

        const inner_x = p.rect.x + 1;
        const inner_y = p.rect.y + 1;
        const inner_w = p.rect.width - 2;
        const inner_h = p.rect.height - 2;
        if (inner_w == 0 or inner_h == 0) continue;

        drawText(canvas, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w);
        markPopupOverlay(popup_overlay, total_cols, content_rows, p.rect);
        markRectOverlay(popup_cover, total_cols, content_rows, p.rect);
        // Popup interiors are opaque: suppress any precomputed base-pane border
        // connectors under the popup content area so they never bleed through.
        clearBorderConnInsideRect(border_conn, total_cols, content_rows, p.rect);

        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        const pane_scroll_offset = mux.windowScrollOffset(window_id) orelse 0;
        panes[pane_count] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .scroll_offset = pane_scroll_offset,
            .scrollback = mux.scrollbackBuffer(window_id),
            .term = &wv.term,
        };
        pane_count += 1;

        if (mux.popup_mgr.focused_popup_id == p.id) {
            const cursor = wv.term.screens.active.cursor;
            const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
            const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
            focused_cursor_abs = .{
                .row = @as(usize, inner_y) + cy + 1,
                .col = @as(usize, inner_x) + cx + 1,
            };
        }
    }
    applyBorderGlyphs(canvas, border_conn, total_cols, content_rows);

    // Border glyph synthesis can overwrite titlebar text/chrome because both share
    // the top border row. Repaint chrome after border pass.
    for (rects[0..n], 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects[0..n], i, r, content);
        const insets = computeContentInsets(rects[0..n], i, r, border);
        const inner_x = r.x + insets.left;
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        if (inner_w == 0) continue;

        const title = tab.windows.items[i].title;
        const controls = "[_][+][x]";
        const controls_w: u16 = @intCast(controls.len);
        const title_max = if (r.width >= 10 and inner_w > controls_w) inner_w - controls_w else inner_w;
        drawTextOwnedMasked(canvas, total_cols, content_rows, inner_x, r.y, title, title_max, i, top_window_owner, popup_cover);
        if (r.width >= 10) {
            const controls_x: u16 = r.x + r.width - controls_w - 1;
            drawTextOwnedMasked(canvas, total_cols, content_rows, controls_x, r.y, controls, controls_w, i, top_window_owner, popup_cover);
        }
    }
    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        if (p.rect.width < 2 or p.rect.height < 2) continue;
        const inner_x = p.rect.x + 1;
        const inner_w = p.rect.width - 2;
        if (inner_w == 0) continue;
        drawText(canvas, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w);
    }

    const live_ids = try mux.liveWindowIds(allocator);
    defer allocator.free(live_ids);
    try vt_state.prune(live_ids);

    var owned_minimized_line: ?[]u8 = null;
    defer if (owned_minimized_line) |line| allocator.free(line);
    var owned_tab_line: ?[]u8 = null;
    defer if (owned_tab_line) |line| allocator.free(line);
    var owned_status_line: ?[]u8 = null;
    defer if (owned_status_line) |line| allocator.free(line);

    const minimized_line: []const u8 = if (plugin_ui_bars) |ui| blk: {
        if (ui.toolbar_line.len > 0) break :blk ui.toolbar_line;
        owned_minimized_line = try renderMinimizedToolbarLine(allocator, &mux.workspace_mgr);
        break :blk owned_minimized_line.?;
    } else blk: {
        owned_minimized_line = try renderMinimizedToolbarLine(allocator, &mux.workspace_mgr);
        break :blk owned_minimized_line.?;
    };
    const tab_line: []const u8 = if (plugin_ui_bars) |ui| blk: {
        if (ui.tab_line.len > 0) break :blk ui.tab_line;
        owned_tab_line = try status.renderTabBar(allocator, &mux.workspace_mgr);
        break :blk owned_tab_line.?;
    } else blk: {
        owned_tab_line = try status.renderTabBar(allocator, &mux.workspace_mgr);
        break :blk owned_tab_line.?;
    };
    const status_line: []const u8 = if (plugin_ui_bars) |ui| blk: {
        if (ui.status_line.len > 0) break :blk ui.status_line;
        owned_status_line = try status.renderStatusBarWithScrollAndSync(
            allocator,
            &mux.workspace_mgr,
            mux.focusedScrollOffset(),
            mux.syncScrollEnabled(),
        );
        break :blk owned_status_line.?;
    } else blk: {
        owned_status_line = try status.renderStatusBarWithScrollAndSync(
            allocator,
            &mux.workspace_mgr,
            mux.focusedScrollOffset(),
            mux.syncScrollEnabled(),
        );
        break :blk owned_status_line.?;
    };

    const resized = try frame_cache.ensureSize(total_cols, total_rows);
    if (resized) try writeAllBlocking(out, "\x1b[2J");

    var curr = try allocator.alloc(RuntimeRenderCell, total_cols * total_rows);
    defer allocator.free(curr);
    for (curr) |*cell| cell.* = .{};

    var row: usize = 0;
    while (row < content_rows) : (row += 1) {
        const row_off = row * total_cols;
        const start = row * total_cols;
        var x: usize = 0;
        while (x < total_cols) : (x += 1) {
            // Border/chrome cells always win compositor layering so overlapped
            // panes don't paint content over visible frame edges/titles.
            if (border_conn[row_off + x] != 0) {
                curr[row_off + x] = plainCellFromCodepoint(canvas[start + x]);
                continue;
            }
            if (popup_overlay[row_off + x]) {
                curr[row_off + x] = plainCellFromCodepoint(canvas[start + x]);
                continue;
            }
            const pane_cell = paneCellAt(panes[0..pane_count], x, row);
            if (pane_cell) |pc| {
                if (pc.skip_draw) {
                    // Explicitly clear spacer-tail cells to avoid stale glyph artifacts
                    // when wide/grapheme content changes near borders.
                    curr[row_off + x] = .{
                        .text = [_]u8{' '} ++ ([_]u8{0} ** 31),
                        .text_len = 1,
                        .style = .{},
                        .styled = false,
                    };
                } else {
                    curr[row_off + x] = .{
                        .text = pc.text,
                        .text_len = pc.text_len,
                        .style = pc.style,
                        .styled = !pc.style.default(),
                    };
                }
            } else {
                curr[row_off + x] = plainCellFromCodepoint(canvas[start + x]);
            }
        }
    }

    fillPlainLine(curr[content_rows * total_cols .. (content_rows + 1) * total_cols], minimized_line);
    fillPlainLine(curr[(content_rows + 1) * total_cols .. (content_rows + 2) * total_cols], tab_line);
    fillPlainLine(curr[(content_rows + 2) * total_cols .. (content_rows + 3) * total_cols], status_line);

    var active_style: ?ghostty_vt.Style = null;
    var idx: usize = 0;
    while (idx < curr.len) : (idx += 1) {
        if (!resized and renderCellEqual(frame_cache.cells[idx], curr[idx])) continue;

        if (!isSafeRunCell(curr[idx])) {
            const y = idx / total_cols;
            const x = idx % total_cols;
            try writeFmtBlocking(out, "\x1b[{};{}H", .{ y + 1, x + 1 });
            const new = curr[idx];
            if (!new.styled) {
                if (active_style != null) {
                    try writeAllBlocking(out, "\x1b[0m");
                    active_style = null;
                }
            } else if (active_style) |s| {
                if (!s.eql(new.style)) {
                    try writeStyle(out, new.style);
                    active_style = new.style;
                }
            } else {
                try writeStyle(out, new.style);
                active_style = new.style;
            }
            try writeAllBlocking(out, new.text[0..new.text_len]);
            continue;
        }

        const y_row = idx / total_cols;
        const row_end = (y_row + 1) * total_cols;
        const run_start = idx;
        var run_end = idx + 1;
        while (run_end < row_end) : (run_end += 1) {
            if (!isSafeRunCell(curr[run_end])) break;
            if (!resized and renderCellEqual(frame_cache.cells[run_end], curr[run_end])) break;
        }

        const x0 = run_start % total_cols;
        try writeFmtBlocking(out, "\x1b[{};{}H", .{ y_row + 1, x0 + 1 });

        var j = run_start;
        while (j < run_end) : (j += 1) {
            const new = curr[j];
            if (!new.styled) {
                if (active_style != null) {
                    try writeAllBlocking(out, "\x1b[0m");
                    active_style = null;
                }
            } else if (active_style) |s| {
                if (!s.eql(new.style)) {
                    try writeStyle(out, new.style);
                    active_style = new.style;
                }
            } else {
                try writeStyle(out, new.style);
                active_style = new.style;
            }
            try writeAllBlocking(out, new.text[0..new.text_len]);
        }

        idx = run_end - 1;
    }
    if (active_style != null) try writeAllBlocking(out, "\x1b[0m");

    // Footer bars are informational UI chrome; always paint them last to avoid
    // transient corruption from incremental pane diff writes during focus churn.
    try writeAllBlocking(out, "\x1b[0m");
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 1});
    try writeClippedLine(out, minimized_line, total_cols);
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 2});
    try writeClippedLine(out, tab_line, total_cols);
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 3});
    try writeClippedLine(out, status_line, total_cols);

    @memcpy(frame_cache.cells, curr);

    if (focused_cursor_abs) |p| {
        try writeFmtBlocking(out, "\x1b[{};{}H", .{ p.row, p.col });
    } else {
        try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 3});
    }
    try writeAllBlocking(out, "\x1b[?25h");
}

const BorderMask = struct {
    left: bool,
    right: bool,
    top: bool,
    bottom: bool,
};

const ContentInsets = struct {
    left: u16,
    right: u16,
    top: u16,
    bottom: u16,
};

const BorderConn = struct {
    const U: u8 = 1 << 0;
    const D: u8 = 1 << 1;
    const L: u8 = 1 << 2;
    const R: u8 = 1 << 3;
};

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

fn computeContentInsets(
    rects: []const layout.Rect,
    idx: usize,
    r: layout.Rect,
    border: BorderMask,
) ContentInsets {
    _ = rects;
    _ = idx;
    _ = r;
    return .{
        .left = if (border.left) 1 else 0,
        .top = if (border.top) 1 else 0,
        .right = if (border.right) 1 else 0,
        .bottom = if (border.bottom) 1 else 0,
    };
}

fn computeBorderMask(rects: []const layout.Rect, idx: usize, r: layout.Rect, content: layout.Rect) BorderMask {
    _ = content;
    return .{
        // Draw left/top for all panes; right/bottom only on container edge.
        // This keeps exactly one separator at shared boundaries.
        .left = true,
        .top = true,
        // Close pane borders for ragged layouts when there is no adjacent pane.
        .right = !hasNeighborOnRight(rects, idx, r),
        .bottom = !hasNeighborOnBottom(rects, idx, r),
    };
}

fn drawBorder(
    canvas: []u21,
    border_conn: []u8,
    cols: usize,
    rows: usize,
    r: layout.Rect,
    border: BorderMask,
    marker: u8,
    owner_idx: ?usize,
    top_window_owner: ?[]const i32,
) void {
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x1 >= cols or y1 >= rows) return;

    if (border.left and border.top) addBorderConnOwned(border_conn, cols, rows, x0, y0, BorderConn.D | BorderConn.R, owner_idx, top_window_owner);
    if (border.right and border.top) addBorderConnOwned(border_conn, cols, rows, x1, y0, BorderConn.D | BorderConn.L, owner_idx, top_window_owner);
    if (border.left and border.bottom) addBorderConnOwned(border_conn, cols, rows, x0, y1, BorderConn.U | BorderConn.R, owner_idx, top_window_owner);
    if (border.right and border.bottom) addBorderConnOwned(border_conn, cols, rows, x1, y1, BorderConn.U | BorderConn.L, owner_idx, top_window_owner);

    if (border.top) {
        var x = x0 + 1;
        while (x < x1) : (x += 1) addBorderConnOwned(border_conn, cols, rows, x, y0, BorderConn.L | BorderConn.R, owner_idx, top_window_owner);
    }
    if (border.bottom) {
        var x = x0 + 1;
        while (x < x1) : (x += 1) addBorderConnOwned(border_conn, cols, rows, x, y1, BorderConn.L | BorderConn.R, owner_idx, top_window_owner);
    }
    if (border.left) {
        var y = y0 + 1;
        while (y < y1) : (y += 1) addBorderConnOwned(border_conn, cols, rows, x0, y, BorderConn.U | BorderConn.D, owner_idx, top_window_owner);
    }
    if (border.right) {
        var y = y0 + 1;
        while (y < y1) : (y += 1) addBorderConnOwned(border_conn, cols, rows, x1, y, BorderConn.U | BorderConn.D, owner_idx, top_window_owner);
    }
    if (border.top and x0 + 1 < cols) {
        const idx = y0 * cols + (x0 + 1);
        if (cellOwnedBy(idx, owner_idx, top_window_owner)) putCell(canvas, cols, x0 + 1, y0, marker);
    }
}

fn addBorderConn(conn: []u8, cols: usize, rows: usize, x: usize, y: usize, bits: u8) void {
    if (x >= cols or y >= rows) return;
    conn[y * cols + x] |= bits;
}

fn addBorderConnOwned(
    conn: []u8,
    cols: usize,
    rows: usize,
    x: usize,
    y: usize,
    bits: u8,
    owner_idx: ?usize,
    top_window_owner: ?[]const i32,
) void {
    if (x >= cols or y >= rows) return;
    const idx = y * cols + x;
    if (!cellOwnedBy(idx, owner_idx, top_window_owner)) return;
    conn[idx] |= bits;
}

fn cellOwnedBy(idx: usize, owner_idx: ?usize, top_window_owner: ?[]const i32) bool {
    const owner = owner_idx orelse return true;
    const owners = top_window_owner orelse return true;
    return owners[idx] == @as(i32, @intCast(owner));
}

fn glyphFromConn(bits: u8) u21 {
    return switch (bits) {
        BorderConn.L | BorderConn.R => '─',
        BorderConn.U | BorderConn.D => '│',
        BorderConn.D | BorderConn.R => '┌',
        BorderConn.D | BorderConn.L => '┐',
        BorderConn.U | BorderConn.R => '└',
        BorderConn.U | BorderConn.L => '┘',
        BorderConn.L | BorderConn.R | BorderConn.D => '┬',
        BorderConn.L | BorderConn.R | BorderConn.U => '┴',
        BorderConn.U | BorderConn.D | BorderConn.R => '├',
        BorderConn.U | BorderConn.D | BorderConn.L => '┤',
        BorderConn.U | BorderConn.D | BorderConn.L | BorderConn.R => '┼',
        else => ' ',
    };
}

fn applyBorderGlyphs(canvas: []u21, conn: []const u8, cols: usize, rows: usize) void {
    _ = rows;
    var i: usize = 0;
    while (i < conn.len) : (i += 1) {
        const bits = conn[i];
        if (bits == 0) continue;
        // Keep focus marker on top border.
        if (canvas[i] == '*') continue;
        canvas[i] = glyphFromConn(bits);
    }
    _ = cols;
}

fn markPopupOverlay(
    overlay: []bool,
    cols: usize,
    rows: usize,
    r: layout.Rect,
) void {
    if (r.width < 2 or r.height < 2) return;
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x0 >= cols or y0 >= rows) return;
    if (x1 >= cols or y1 >= rows) return;

    var x = x0;
    while (x <= x1) : (x += 1) {
        overlay[y0 * cols + x] = true;
        overlay[y1 * cols + x] = true;
    }
    var y = y0;
    while (y <= y1) : (y += 1) {
        overlay[y * cols + x0] = true;
        overlay[y * cols + x1] = true;
    }
}

fn markRectOverlay(
    overlay: []bool,
    cols: usize,
    rows: usize,
    r: layout.Rect,
) void {
    if (r.width == 0 or r.height == 0) return;
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = @min(@as(usize, r.x + r.width), cols);
    const y1: usize = @min(@as(usize, r.y + r.height), rows);
    if (x0 >= x1 or y0 >= y1) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            overlay[y * cols + x] = true;
        }
    }
}

fn clearBorderConnInsideRect(
    conn: []u8,
    cols: usize,
    rows: usize,
    r: layout.Rect,
) void {
    if (r.width < 3 or r.height < 3) return;
    const x0: usize = r.x + 1;
    const y0: usize = r.y + 1;
    const x1: usize = r.x + r.width - 1;
    const y1: usize = r.y + r.height - 1;
    if (x0 >= cols or y0 >= rows) return;
    if (x1 > cols or y1 > rows) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            conn[y * cols + x] = 0;
        }
    }
}

fn clearCanvasRect(
    canvas: []u21,
    cols: usize,
    rows: usize,
    r: layout.Rect,
) void {
    if (r.width == 0 or r.height == 0) return;
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = @min(@as(usize, r.x + r.width), cols);
    const y1: usize = @min(@as(usize, r.y + r.height), rows);
    if (x0 >= x1 or y0 >= y1) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            canvas[y * cols + x] = ' ';
        }
    }
}

fn clearBorderConnRect(
    conn: []u8,
    cols: usize,
    rows: usize,
    r: layout.Rect,
) void {
    if (r.width == 0 or r.height == 0) return;
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = @min(@as(usize, r.x + r.width), cols);
    const y1: usize = @min(@as(usize, r.y + r.height), rows);
    if (x0 >= x1 or y0 >= y1) return;

    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            conn[y * cols + x] = 0;
        }
    }
}

fn writeStyledRow(
    out: *std.Io.Writer,
    canvas_row: []const u8,
    total_cols: usize,
    row: usize,
    panes: []const PaneRenderRef,
) !void {
    var active_style: ?ghostty_vt.Style = null;
    var x: usize = 0;
    while (x < total_cols) : (x += 1) {
        // Column-lock each cell write to avoid cursor drift/autowrap artifacts
        // from ambiguous glyph widths in host terminal font rendering.
        try writeFmtBlocking(out, "\x1b[{};{}H", .{ row + 1, x + 1 });
        const pane_cell = paneCellAt(panes, x, row);
        if (pane_cell) |pc| {
            if (pc.skip_draw) continue;
            if (pc.style.default()) {
                if (active_style != null) {
                    try writeAllBlocking(out, "\x1b[0m");
                    active_style = null;
                }
            } else if (active_style) |current| {
                if (!current.eql(pc.style)) {
                    try writeStyle(out, pc.style);
                    active_style = pc.style;
                }
            } else {
                try writeStyle(out, pc.style);
                active_style = pc.style;
            }
            try writeAllBlocking(out, pc.text[0..pc.text_len]);
            continue;
        }

        if (active_style != null) {
            try writeAllBlocking(out, "\x1b[0m");
            active_style = null;
        }
        try writeByteBlocking(out, canvas_row[x]);
    }
    if (active_style != null) try writeAllBlocking(out, "\x1b[0m");
}

fn fillPlainLine(dst: []RuntimeRenderCell, line: []const u8) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        const ch: u8 = if (i < line.len) line[i] else ' ';
        dst[i] = .{
            .text = [_]u8{ch} ++ ([_]u8{0} ** 31),
            .text_len = 1,
            .style = .{},
            .styled = false,
        };
    }
}

fn renderMinimizedToolbarLine(allocator: std.mem.Allocator, wm: *workspace.WorkspaceManager) ![]u8 {
    var list = std.ArrayListUnmanaged(u8){};
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, "min: ");
    const tab = wm.activeTab() catch return list.toOwnedSlice(allocator);
    for (tab.windows.items) |w| {
        if (!w.minimized) continue;
        try list.appendSlice(allocator, "[");
        try list.writer(allocator).print("{d}:{s}", .{ w.id, w.title });
        try list.appendSlice(allocator, "] ");
    }
    return list.toOwnedSlice(allocator);
}

fn minimizedToolbarHitAt(
    wm: *workspace.WorkspaceManager,
    content: layout.Rect,
    px: u16,
    py: u16,
) ?struct { window_id: u32, window_index: usize } {
    if (py != content.y + content.height) return null;
    const tab = wm.activeTab() catch return null;

    var x: u16 = 5; // "min: "
    for (tab.windows.items, 0..) |w, i| {
        if (!w.minimized) continue;

        var id_buf: [16]u8 = undefined;
        const id_txt = std.fmt.bufPrint(&id_buf, "{d}", .{w.id}) catch continue;
        const seg_w: u16 = @intCast(1 + id_txt.len + 1 + w.title.len + 2); // [id:title] + trailing space
        const start = x;
        const end = x + seg_w;
        if (px >= start and px < end) return .{ .window_id = w.id, .window_index = i };
        x = end;
    }
    return null;
}

fn plainCellFromCodepoint(cp: u21) RuntimeRenderCell {
    var cell: RuntimeRenderCell = .{
        .style = .{},
        .styled = false,
    };
    cell.text_len = @intCast(encodeCodepoint(cell.text[0..], cp));
    if (cell.text_len == 0) {
        cell.text[0] = '?';
        cell.text_len = 1;
    }
    return cell;
}

fn renderCellEqual(a: RuntimeRenderCell, b: RuntimeRenderCell) bool {
    if (a.text_len != b.text_len) return false;
    if (a.styled != b.styled) return false;
    if (a.styled and !a.style.eql(b.style)) return false;
    return std.mem.eql(u8, a.text[0..a.text_len], b.text[0..b.text_len]);
}

fn isSafeRunCell(cell: RuntimeRenderCell) bool {
    if (cell.text_len == 1) {
        const ch = cell.text[0];
        return ch >= 0x20 and ch <= 0x7e;
    }
    if (cell.text_len == 3) {
        const bytes = cell.text[0..3];
        return std.mem.eql(u8, bytes, "│") or
            std.mem.eql(u8, bytes, "─") or
            std.mem.eql(u8, bytes, "┌") or
            std.mem.eql(u8, bytes, "┐") or
            std.mem.eql(u8, bytes, "└") or
            std.mem.eql(u8, bytes, "┘");
    }
    return false;
}

fn writeStyle(out: *std.Io.Writer, style: ghostty_vt.Style) !void {
    var buf: [160]u8 = undefined;
    const sgr = try std.fmt.bufPrint(&buf, "{f}", .{style.formatterVt()});
    try writeAllBlocking(out, sgr);
}

fn paneCellAt(
    panes: []const PaneRenderRef,
    x: usize,
    y: usize,
) ?PaneRenderCell {
    var i: usize = panes.len;
    while (i > 0) {
        i -= 1;
        const pane = panes[i];
        const inner_x0: usize = pane.content_x;
        const inner_y0: usize = pane.content_y;
        const inner_x1: usize = pane.content_x + pane.content_w;
        const inner_y1: usize = pane.content_y + pane.content_h;
        if (x < inner_x0 or x >= inner_x1 or y < inner_y0 or y >= inner_y1) continue;

        const local_x: usize = x - inner_x0;
        const local_y: usize = y - inner_y0;

        const pages = pane.term.screens.active.pages;
        const total_rows: usize = pages.total_rows;
        const active_rows: usize = pages.rows;
        const vt_max_off: usize = if (total_rows > active_rows) total_rows - active_rows else 0;
        // If requested offset is deeper than VT can address, fall back to
        // line-based scrollback (plain text, no VT styling) for stable deep history.
        if (pane.scroll_offset > vt_max_off) {
            if (pane.scrollback) |sb| {
                const lines = sb.lines.items;
                if (lines.len > 0) {
                    const view_rows: usize = pane.content_h;
                    const off = @min(pane.scroll_offset, lines.len);
                    const start = if (lines.len > view_rows + off)
                        lines.len - view_rows - off
                    else
                        0;
                    const idx = start + local_y;
                    if (idx < lines.len) {
                        const line = lines[idx];
                        const ch: u8 = if (local_x < line.len) line[local_x] else ' ';
                        return .{
                            .text = [_]u8{ch} ++ ([_]u8{0} ** 31),
                            .text_len = 1,
                            .style = .{},
                        };
                    }
                }
            }
            return .{
                .text = [_]u8{' '} ++ ([_]u8{0} ** 31),
                .text_len = 1,
                .style = .{},
            };
        }

        const off = @min(pane.scroll_offset, total_rows);
        const start_screen_row: usize = if (total_rows > active_rows + off)
            total_rows - active_rows - off
        else
            0;
        const source_y = start_screen_row + local_y;
        if (source_y > std.math.maxInt(u32)) return .{
            .text = [_]u8{' '} ++ ([_]u8{0} ** 31),
            .text_len = 1,
            .style = .{},
        };
        const maybe_cell = pane.term.screens.active.pages.getCell(.{
            .screen = .{
                .x = @intCast(local_x),
                .y = @intCast(source_y),
            },
        }) orelse return .{
            .text = [_]u8{' '} ++ ([_]u8{0} ** 31),
            .text_len = 1,
            .style = .{},
        };

        if (maybe_cell.cell.wide == .spacer_tail) {
            return .{
                .style = .{},
                .skip_draw = true,
            };
        }

        const cp_raw = maybe_cell.cell.codepoint();
        const cp: u21 = if (cp_raw >= 32) cp_raw else ' ';
        var rendered: PaneRenderCell = .{
            .style = .{},
        };
        rendered.text_len = @intCast(encodeCodepoint(rendered.text[0..], cp));
        if (rendered.text_len == 0) {
            rendered.text[0] = '?';
            rendered.text_len = 1;
        }
        if (maybe_cell.cell.content_tag == .codepoint_grapheme) {
            if (maybe_cell.node.data.lookupGrapheme(maybe_cell.cell)) |extra_cps| {
                for (extra_cps) |extra_cp_raw| {
                    const extra_cp: u21 = if (extra_cp_raw >= 32) extra_cp_raw else ' ';
                    const used = rendered.text_len;
                    const wrote = encodeCodepoint(rendered.text[used..], extra_cp);
                    if (wrote == 0) break;
                    const total = @as(usize, used) + wrote;
                    rendered.text_len = @intCast(@min(total, rendered.text.len));
                    if (total >= rendered.text.len) break;
                }
            }
        }
        var style: ghostty_vt.Style = if (maybe_cell.cell.style_id == 0)
            .{}
        else
            maybe_cell.node.data.styles.get(maybe_cell.node.data.memory, maybe_cell.cell.style_id).*;

        switch (maybe_cell.cell.content_tag) {
            .bg_color_palette => style.bg_color = .{ .palette = maybe_cell.cell.content.color_palette },
            .bg_color_rgb => style.bg_color = .{ .rgb = .{
                .r = maybe_cell.cell.content.color_rgb.r,
                .g = maybe_cell.cell.content.color_rgb.g,
                .b = maybe_cell.cell.content.color_rgb.b,
            } },
            else => {},
        }
        rendered.style = style;
        return rendered;
    }
    return null;
}

fn drawText(
    canvas: []u21,
    cols: usize,
    rows: usize,
    x_start: u16,
    y: u16,
    text: []const u8,
    max_w: u16,
) void {
    if (y >= rows) return;
    var x: usize = x_start;
    const y_usize: usize = y;
    var i: usize = 0;
    while (i < text.len and i < max_w and x < cols) : (i += 1) {
        putCell(canvas, cols, x, y_usize, text[i]);
        x += 1;
    }
}

fn drawTextOwned(
    canvas: []u21,
    cols: usize,
    rows: usize,
    x_start: u16,
    y: u16,
    text: []const u8,
    max_w: u16,
    owner_idx: usize,
    top_window_owner: []const i32,
) void {
    if (y >= rows) return;
    var x: usize = x_start;
    const y_usize: usize = y;
    var i: usize = 0;
    while (i < text.len and i < max_w and x < cols) : (i += 1) {
        const idx = y_usize * cols + x;
        if (top_window_owner[idx] == @as(i32, @intCast(owner_idx))) {
            putCell(canvas, cols, x, y_usize, text[i]);
        }
        x += 1;
    }
}

fn drawTextOwnedMasked(
    canvas: []u21,
    cols: usize,
    rows: usize,
    x_start: u16,
    y: u16,
    text: []const u8,
    max_w: u16,
    owner_idx: usize,
    top_window_owner: []const i32,
    mask: []const bool,
) void {
    if (y >= rows) return;
    var x: usize = x_start;
    const y_usize: usize = y;
    var i: usize = 0;
    while (i < text.len and i < max_w and x < cols) : (i += 1) {
        const idx = y_usize * cols + x;
        if (mask[idx]) {
            x += 1;
            continue;
        }
        if (top_window_owner[idx] == @as(i32, @intCast(owner_idx))) {
            putCell(canvas, cols, x, y_usize, text[i]);
        }
        x += 1;
    }
}

fn putCell(canvas: []u21, cols: usize, x: usize, y: usize, ch: u21) void {
    canvas[y * cols + x] = ch;
}

fn writeClippedLine(out: *std.Io.Writer, line: []const u8, max_cols: usize) !void {
    const clipped_len = @min(line.len, max_cols);
    try writeAllBlocking(out, line[0..clipped_len]);
    if (clipped_len < max_cols) {
        var i: usize = clipped_len;
        while (i < max_cols) : (i += 1) try writeByteBlocking(out, ' ');
    }
}

fn writeAllBlocking(out: *std.Io.Writer, bytes: []const u8) !void {
    var written: usize = 0;
    var retries: usize = 0;
    while (written < bytes.len) {
        const n = out.write(bytes[written..]) catch |err| switch (err) {
            error.WriteFailed => {
                retries += 1;
                if (retries > 2000) return err;
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        retries = 0;
        written += n;
    }
}

fn writeByteBlocking(out: *std.Io.Writer, b: u8) !void {
    var one = [1]u8{b};
    try writeAllBlocking(out, &one);
}

fn writeCodepointBlocking(out: *std.Io.Writer, cp: u21) !void {
    var scratch: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &scratch) catch {
        return writeByteBlocking(out, '?');
    };
    try writeAllBlocking(out, scratch[0..n]);
}

fn encodeCodepoint(dst: []u8, cp: u21) usize {
    var scratch: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &scratch) catch return 0;
    if (dst.len < n) return 0;
    @memcpy(dst[0..n], scratch[0..n]);
    return n;
}

fn writeFmtBlocking(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAllBlocking(out, text);
}

fn pickLayoutEngine(allocator: std.mem.Allocator, cfg: config.Config) !layout.LayoutEngine {
    return switch (cfg.layout_backend) {
        .native => layout_native.NativeLayoutEngine.init(),
        // Temporary fallback while OpenTUI adapter compute() is not integrated yet.
        .opentui => layout_native.NativeLayoutEngine.init(),
        .plugin => blk: {
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

fn pickLayoutEngineRuntime(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    plugins: *plugin_manager.PluginManager,
) !layout.LayoutEngine {
    return switch (cfg.layout_backend) {
        .plugin => blk: {
            if (plugins.hasAny()) {
                break :blk try layout_plugin.PluginManagerLayoutEngine.init(allocator, plugins);
            }
            break :blk try pickLayoutEngine(allocator, cfg);
        },
        else => pickLayoutEngine(allocator, cfg),
    };
}

fn findFirstPluginSubdir(allocator: std.mem.Allocator, plugins_dir: []const u8) !?[]u8 {
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

fn printZmxAndSignalPOC(writer: *std.Io.Writer, env: zmx.Env) !void {
    try writer.writeAll("zmx(signal+env integration scaffold):\n");
    try writer.print("  in_session={}\n", .{env.in_session});
    try writer.print("  session={s}\n", .{env.session_name orelse "(none)"});
    try writer.print("  socket_dir={s}\n", .{env.socket_dir orelse "(none)"});

    const snap = signal_mod.drain();
    try writer.print(
        "  signals(sigwinch={}, sighup={}, sigterm={})\n\n",
        .{ snap.sigwinch, snap.sighup, snap.sigterm },
    );
}

fn printConfigPOC(writer: *std.Io.Writer, cfg: config.Config) !void {
    try writer.writeAll("config(startup):\n");
    try writer.print("  source={s}\n", .{cfg.source_path orelse "(defaults)"});
    try writer.print("  backend={s}\n", .{@tagName(cfg.layout_backend)});
    try writer.print("  default_layout={s}\n", .{@tagName(cfg.default_layout)});
    try writer.print("  plugins_enabled={}\n\n", .{cfg.plugins_enabled});
}

fn printWorkspacePOC(writer: *std.Io.Writer, alloc: std.mem.Allocator, cfg: config.Config) !void {
    var wm = workspace.WorkspaceManager.init(alloc, try pickLayoutEngine(alloc, cfg));
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.createTab("ops");
    try wm.setActiveLayoutDefaults(cfg.default_layout, cfg.master_count, cfg.master_ratio_permille, cfg.gap);

    _ = try wm.addWindowToActive("shell-1");
    _ = try wm.addWindowToActive("shell-2");
    _ = try wm.addWindowToActive("shell-3");

    const dev_rects = try wm.computeActiveLayout(.{ .x = 0, .y = 0, .width = 72, .height = 12 });
    defer alloc.free(dev_rects);

    try writer.writeAll("workspace(active=dev, layout=native.vertical_stack):\n");
    for (dev_rects, 0..) |r, i| {
        try writer.print("  pane {}: x={} y={} w={} h={}\n", .{ i, r.x, r.y, r.width, r.height });
    }

    try wm.moveFocusedWindowToTab(1);
    try wm.switchTab(1);

    const ops_rects = try wm.computeActiveLayout(.{ .x = 0, .y = 0, .width = 72, .height = 12 });
    defer alloc.free(ops_rects);

    try writer.writeAll("workspace(active=ops, after move-focused-window):\n");
    for (ops_rects, 0..) |r, i| {
        try writer.print("  pane {}: x={} y={} w={} h={}\n", .{ i, r.x, r.y, r.width, r.height });
    }
    const rendered = try status.render(alloc, &wm);
    defer {
        var tmp = rendered;
        tmp.deinit(alloc);
    }
    try writer.print("  tabs: {s}\n", .{rendered.tab_bar});
    try writer.print("  status: {s}\n", .{rendered.status_bar});
    try writer.writeByte('\n');
}

fn printMultiplexerPOC(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    cfg: config.Config,
    zmx_env: *const zmx.Env,
) !void {
    var mux = multiplexer.Multiplexer.init(alloc, try pickLayoutEngine(alloc, cfg));
    defer mux.deinit();

    _ = try mux.createTab("dev");
    try mux.workspace_mgr.setActiveLayoutDefaults(cfg.default_layout, cfg.master_count, cfg.master_ratio_permille, cfg.gap);
    const win_id = try mux.createCommandWindow("cat", &.{"/bin/cat"});
    const resized = try mux.resizeActiveWindowsToLayout(.{ .x = 0, .y = 0, .width = 72, .height = 12 });
    const reattach = try mux.handleReattach(.{ .x = 0, .y = 0, .width = 72, .height = 12 });
    try mux.handleInputBytes("hello-from-input-layer\n");
    var detach_invoked = false;
    var detach_ok = false;

    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        const tick_result = try mux.tick(30, .{ .x = 0, .y = 0, .width = 72, .height = 12 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
        if (tick_result.detach_requested) {
            detach_invoked = true;
            detach_ok = zmx_env.detachCurrentSession(alloc) catch false;
        }
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "hello-from-input-layer") != null) break;
        if (tick_result.should_shutdown) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    const focused = try mux.focusedWindowId();
    const dirty = try mux.dirtyWindowIds(alloc);
    defer alloc.free(dirty);
    mux.scrollPageUpFocused(10);
    mux.scrollHalfPageDownFocused(10);
    const found = mux.searchFocusedScrollback("hello-from-input-layer", .backward) != null;
    const focused_scroll = mux.focusedScrollOffset();
    const status_line = try status.renderStatusBarWithScrollAndSync(
        alloc,
        &mux.workspace_mgr,
        focused_scroll,
        mux.syncScrollEnabled(),
    );
    defer alloc.free(status_line);

    _ = try mux.openFzfPopup(.{ .x = 0, .y = 0, .width = 72, .height = 12 }, true);
    var popup_ticks: usize = 0;
    while (popup_ticks < 20 and mux.popup_mgr.count() > 0) : (popup_ticks += 1) {
        _ = try mux.tick(10, .{ .x = 0, .y = 0, .width = 72, .height = 12 }, .{
            .sigwinch = false,
            .sighup = false,
            .sigterm = false,
        });
    }

    try writer.writeAll("multiplexer(poll-route):\n");
    try writer.print("  win {} bytes={}\n", .{ win_id, out.len });
    try writer.print("  resized_windows={}\n", .{resized});
    try writer.print("  reattach(resized={}, dirty={}, redraw={})\n", .{
        reattach.resized,
        reattach.marked_dirty,
        reattach.redraw,
    });
    try writer.print("  focused_window={}\n", .{focused});
    try writer.print("  dirty_windows={}\n", .{dirty.len});
    try writer.print("  scroll_search_found={}\n", .{found});
    try writer.print("  status_with_scroll: {s}\n", .{status_line});
    try writer.print("  detach_invoked={} detach_ok={}\n", .{ detach_invoked, detach_ok });
    try writer.print("  popup_fzf_remaining={}\n", .{mux.popup_mgr.count()});
    if (out.len > 0) {
        try writer.print("  sample: {s}", .{out});
    }
    try writer.writeByte('\n');
    try writer.writeByte('\n');
}

fn renderSideBySide(writer: *std.Io.Writer, left: *Terminal, right: *Terminal) !void {
    const left_screen = left.screens.active;
    const right_screen = right.screens.active;

    var row: usize = 0;
    while (row < POC_ROWS) : (row += 1) {
        try writeRowAsText(writer, left_screen, row);
        try writer.writeAll(" | ");
        try writeRowAsText(writer, right_screen, row);
        try writer.writeByte('\n');
    }
}

fn writeRowAsText(writer: *std.Io.Writer, screen: *ghostty_vt.Screen, row: usize) !void {
    var col: usize = 0;
    while (col < POC_COLS) : (col += 1) {
        const page_cell = screen.pages.getCell(.{
            .active = .{
                .x = @intCast(col),
                .y = @intCast(row),
            },
        }) orelse {
            try writer.writeByte(' ');
            continue;
        };
        const term_cell = page_cell.cell;
        const cp: u21 = if (term_cell.codepoint() == 0) ' ' else term_cell.codepoint();

        var scratch: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &scratch);
        try writer.writeAll(scratch[0..n]);
    }
}

test "workspace layout POC returns panes" {
    const testing = std.testing;
    var wm = workspace.WorkspaceManager.init(testing.allocator, layout_native.NativeLayoutEngine.init());
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.addWindowToActive("shell-1");
    _ = try wm.addWindowToActive("shell-2");

    const rects = try wm.computeActiveLayout(.{ .x = 0, .y = 0, .width = 72, .height = 12 });
    defer testing.allocator.free(rects);

    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(@as(u16, 43), rects[0].width);
    try testing.expectEqual(@as(u16, 29), rects[1].width);
}

test "composition helpers mark and clear panel coverage correctly" {
    const testing = std.testing;
    const cols: usize = 12;
    const rows: usize = 6;
    const len = cols * rows;

    const overlay = try testing.allocator.alloc(bool, len);
    defer testing.allocator.free(overlay);
    @memset(overlay, false);

    const r: layout.Rect = .{ .x = 2, .y = 1, .width = 4, .height = 3 };
    markRectOverlay(overlay, cols, rows, r);
    try testing.expect(overlay[1 * cols + 2]);
    try testing.expect(overlay[3 * cols + 5]);
    try testing.expect(!overlay[0]);

    const conn = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(conn);
    @memset(conn, 0x0f);
    clearBorderConnRect(conn, cols, rows, r);
    try testing.expectEqual(@as(u8, 0), conn[1 * cols + 2]);
    try testing.expectEqual(@as(u8, 0), conn[3 * cols + 5]);
    try testing.expectEqual(@as(u8, 0x0f), conn[0]);
}
