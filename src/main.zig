const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
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
const input_mod = @import("input.zig");
const render_compositor = @import("render_compositor.zig");
const runtime_layout = @import("runtime_layout.zig");
const runtime_vt = @import("runtime_vt.zig");
const runtime_terminal = @import("runtime_terminal.zig");
const runtime_footer = @import("runtime_footer.zig");
const runtime_plugin_state = @import("runtime_plugin_state.zig");
const runtime_output = @import("runtime_output.zig");
const runtime_control = @import("runtime_control.zig");
const runtime_plugin_actions = @import("runtime_plugin_actions.zig");
const runtime_renderer = @import("runtime_renderer.zig");
const runtime_cli = @import("runtime_cli.zig");
const runtime_render_types = @import("runtime_render_types.zig");
const runtime_cells = @import("runtime_cells.zig");
const runtime_control_pipe = @import("runtime_control_pipe.zig");
const runtime_pane_rendering = @import("runtime_pane_rendering.zig");
const runtime_compose_debug = @import("runtime_compose_debug.zig");
const runtime_frame_output = @import("runtime_frame_output.zig");

const writeClippedLine = runtime_output.writeClippedLine;
const writeAllBlocking = runtime_output.writeAllBlocking;
const writeByteBlocking = runtime_output.writeByteBlocking;
const writeCodepointBlocking = runtime_output.writeCodepointBlocking;
const encodeCodepoint = runtime_output.encodeCodepoint;
const writeFmtBlocking = runtime_output.writeFmtBlocking;
const drawText = render_compositor.drawText;
const drawTextOwnedMasked = render_compositor.drawTextOwnedMasked;
const putCell = render_compositor.putCell;
const drawBorder = runtime_renderer.drawBorder;
const applyBorderGlyphs = runtime_renderer.applyBorderGlyphs;
const drawPopupBorderDirect = runtime_renderer.drawPopupBorderDirect;
const resolveChromeStyleAt = runtime_renderer.resolveChromeStyleAt;
const markLayerCell = runtime_renderer.markLayerCell;
const markBorderLayer = runtime_renderer.markBorderLayer;
const markBorderLayerOwned = runtime_renderer.markBorderLayerOwned;
const markTextLayer = runtime_renderer.markTextLayer;
const markTextOwnedMaskedLayer = runtime_renderer.markTextOwnedMaskedLayer;
const chrome_layer_none = runtime_renderer.chrome_layer_none;
const chrome_layer_active_border = runtime_renderer.chrome_layer_active_border;
const chrome_layer_inactive_border = runtime_renderer.chrome_layer_inactive_border;
const chrome_layer_active_title = runtime_renderer.chrome_layer_active_title;
const chrome_layer_inactive_title = runtime_renderer.chrome_layer_inactive_title;
const chrome_layer_active_buttons = runtime_renderer.chrome_layer_active_buttons;
const chrome_layer_inactive_buttons = runtime_renderer.chrome_layer_inactive_buttons;
const plainCellFromCodepoint = runtime_cells.plainCellFromCodepoint;
const renderCellEqual = runtime_cells.renderCellEqual;
const enforceOpaquePanelChromeBg = runtime_cells.enforceOpaquePanelChromeBg;
const enforceOpaqueRuntimeCellBg = runtime_cells.enforceOpaqueRuntimeCellBg;
const isSafeRunCell = runtime_cells.isSafeRunCell;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
});

const DebugTag = enum(u8) {
    loop_size_change,
    tick_result,
    render_begin,
    render_footer,
    plugin_request_redraw,
    compose_bg_leak,
};

const DebugTrace = struct {
    const Entry = struct {
        seq: u64,
        tag: DebugTag,
        a: i32,
        b: i32,
        c: i32,
        d: i32,
    };

    const capacity: usize = 128;

    entries: [capacity]Entry = undefined,
    next: usize = 0,
    len: usize = 0,
    seq: u64 = 0,

    fn push(self: *DebugTrace, tag: DebugTag, a: i32, b: i32, c_val: i32, d: i32) void {
        self.entries[self.next] = .{
            .seq = self.seq,
            .tag = tag,
            .a = a,
            .b = b,
            .c = c_val,
            .d = d,
        };
        self.seq += 1;
        self.next = (self.next + 1) % capacity;
        if (self.len < capacity) self.len += 1;
    }

    fn dump(self: *const DebugTrace) void {
        const header = "ykmx crash trace (latest events):\n";
        _ = c.write(c.STDERR_FILENO, header.ptr, header.len);
        if (self.len == 0) {
            const none = "  (empty)\n";
            _ = c.write(c.STDERR_FILENO, none.ptr, none.len);
            return;
        }

        const start = if (self.len == capacity) self.next else 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (start + i) % capacity;
            const e = self.entries[idx];
            var line_buf: [192]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "  #{d} {s} a={d} b={d} c={d} d={d}\n",
                .{ e.seq, debugTagName(e.tag), e.a, e.b, e.c, e.d },
            ) catch continue;
            _ = c.write(c.STDERR_FILENO, line.ptr, line.len);
        }
    }
};

var g_debug_trace: DebugTrace = .{};
var g_compose_debug_frame: u64 = 0;
var g_compose_debug_tick: u64 = 0;

fn traceEvent(tag: DebugTag, a: i32, b: i32, c_val: i32, d: i32) void {
    g_debug_trace.push(tag, a, b, c_val, d);
}

fn tracePluginRequestRedraw(screen: layout.Rect) void {
    traceEvent(.plugin_request_redraw, @intCast(screen.width), @intCast(screen.height), 0, 0);
}

fn debugTagName(tag: DebugTag) []const u8 {
    return switch (tag) {
        .loop_size_change => "loop_size_change",
        .tick_result => "tick_result",
        .render_begin => "render_begin",
        .render_footer => "render_footer",
        .plugin_request_redraw => "plugin_request_redraw",
        .compose_bg_leak => "compose_bg_leak",
    };
}

fn panicWithTrace(msg: []const u8, first_trace_addr: ?usize) noreturn {
    g_debug_trace.dump();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const panic = std.debug.FullPanic(panicWithTrace);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
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
        if (std.mem.eql(u8, args[1], "ctl")) {
            try runtime_cli.runControlCli(alloc, if (args.len > 2) args[2..] else &.{});
            return;
        }
        try printHelp();
        return;
    }

    try runRuntimeLoop(alloc);
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
        \\  ykmx --benchmark [N] Run frame benchmark (default N=200)
        \\  ykmx --benchmark-layout [N]
        \\                      Run layout churn benchmark (default N=500)
        \\  ykmx --smoke-zmx [session]
        \\  ykmx ctl <command> [args]
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
    var control = try ControlPipe.init(allocator, env.session_name);
    defer control.deinit();
    control.exportEnv() catch {};
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);
    const compose_debug_enabled = readEnvFlag(allocator, "YKMX_DEBUG_COMPOSE");

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

    var mux = multiplexer.Multiplexer.init(allocator, try runtime_layout.pickLayoutEngineRuntime(allocator, cfg, &plugins));
    defer mux.deinit();
    mux.setMouseMode(switch (cfg.mouse_mode) {
        .hybrid => .hybrid,
        .passthrough => .passthrough,
        .compositor => .compositor,
    });
    mux.setLayoutCycleLocked(cfg.layout_backend == .plugin and plugins.hasAny());
    mux.setPrefixPanelToggleKeys(cfg.key_toggle_sidebar_panel, cfg.key_toggle_bottom_panel);
    for (cfg.plugin_keybindings.items) |kb| {
        mux.setPluginPrefixedKeybinding(kb.key, kb.command_name) catch {};
    }

    _ = try mux.createTab("main");
    try mux.workspace_mgr.setActiveLayoutDefaults(cfg.default_layout, cfg.master_count, cfg.master_ratio_permille, cfg.gap);
    _ = try mux.createShellWindow("shell-1");
    if (plugins.hasAny()) plugins.emitStart(try mux.workspace_mgr.activeLayoutType());
    var last_layout = try mux.workspace_mgr.activeLayoutType();

    var term = try runtime_terminal.RuntimeTerminal.enter();
    defer term.leave();
    var vt_state = RuntimeVtState.init(allocator);
    defer vt_state.deinit();
    var frame_cache = RuntimeFrameCache.init(allocator);
    defer frame_cache.deinit();

    var last_size = runtime_terminal.getTerminalSize();
    var last_content = runtime_terminal.contentRect(last_size);
    _ = mux.resizeActiveWindowsToLayout(last_content) catch {};
    var last_plugin_state = try runtime_plugin_state.collectPluginRuntimeState(&mux, last_content);
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
        const size = runtime_terminal.getTerminalSize();
        const content = runtime_terminal.contentRect(size);
        if (size.cols != last_size.cols or size.rows != last_size.rows or
            content.width != last_content.width or content.height != last_content.height)
        {
            traceEvent(
                .loop_size_change,
                @intCast(size.cols),
                @intCast(size.rows),
                @intCast(content.width),
                @intCast(content.height),
            );
            _ = mux.resizeActiveWindowsToLayout(content) catch {};
            force_redraw = true;
            last_size = size;
            last_content = content;
        }

        while (true) {
            const n = runtime_terminal.readStdinNonBlocking(&input_buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) break;
            try mux.handleInputBytesWithScreen(content, input_buf[0..n]);
        }
        try mux.flushPendingInputTimeouts();

        const snap = signal_mod.drain();
        const tick_result = try mux.tick(30, content, snap);
        if (compose_debug_enabled and (g_compose_debug_tick % 30) == 0) {
            logComposeTickSummary(&mux, content);
        }
        g_compose_debug_tick += 1;
        traceEvent(
            .tick_result,
            @intCast(tick_result.reads),
            @intCast(tick_result.resized),
            @intCast(tick_result.popup_updates),
            @intFromBool(tick_result.redraw),
        );
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
                const toolbar_hit = runtime_footer.minimizedToolbarHitAt(&mux.workspace_mgr, content, px, py);
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
                    for (owned) |*sourced| plugin_host.PluginHost.deinitActionPayload(allocator, &sourced.action);
                    allocator.free(owned);
                }
                var changed = false;
                for (owned) |sourced| {
                    changed = (try runtime_plugin_actions.applyPluginAction(&mux, content, sourced.plugin_name, sourced.action, &tracePluginRequestRedraw)) or changed;
                }
                if (changed) force_redraw = true;
            }
            if (plugins.consumeUiDirtyAny()) force_redraw = true;
        }

        if (try control.poll(&mux, content)) force_redraw = true;
        control.writeState(&mux, &plugins, content) catch {};

        const current_plugin_state = try runtime_plugin_state.collectPluginRuntimeState(&mux, content);
        if (plugins.hasAny()) {
            if (!runtime_plugin_state.pluginRuntimeStateEql(last_plugin_state, current_plugin_state)) {
                const reason = runtime_plugin_state.detectStateChangeReason(last_plugin_state, current_plugin_state);
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
        try runtime_vt.warmKnownDirtyWindowVtState(allocator, &mux, &vt_state);

        if (tick_result.detach_requested) {
            _ = env.detachCurrentSession(allocator) catch {};
        }
        if (tick_result.should_shutdown) break;

        if (snap.sigwinch) force_redraw = true;
        if (force_redraw or tick_result.redraw) {
            traceEvent(
                .render_begin,
                @intCast(size.cols),
                @intCast(size.rows),
                @intCast(content.width),
                @intCast(content.height),
            );
            try renderRuntimeFrame(out, allocator, &mux, &vt_state, &frame_cache, size, content, if (plugins.hasAny()) plugins.uiBars() else null, compose_debug_enabled);
            try out.flush();
            force_redraw = false;
        }
    }
    if (plugins.hasAny()) plugins.emitShutdown();
}

fn readEnvFlag(allocator: std.mem.Allocator, name: []const u8) bool {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(raw);
    const v = std.mem.trim(u8, raw, " \t\r\n");
    if (v.len == 0) return false;
    if (std.mem.eql(u8, v, "0")) return false;
    if (std.ascii.eqlIgnoreCase(v, "false")) return false;
    if (std.ascii.eqlIgnoreCase(v, "off")) return false;
    if (std.ascii.eqlIgnoreCase(v, "no")) return false;
    return true;
}

fn logComposeTickSummary(mux: *multiplexer.Multiplexer, content: layout.Rect) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "ykmx compose-debug tick={} visible_popups={} focused_popup={} screen={}x{}\n",
        .{
            g_compose_debug_tick,
            mux.popup_mgr.visibleCount(),
            mux.popup_mgr.focused_popup_id orelse 0,
            content.width,
            content.height,
        },
    ) catch return;
    _ = c.write(c.STDERR_FILENO, line.ptr, line.len);
}

const RuntimeSize = runtime_terminal.RuntimeSize;
const RuntimeRenderCell = runtime_render_types.RuntimeRenderCell;
const RuntimeFrameCache = runtime_render_types.RuntimeFrameCache;
const PaneRenderRef = runtime_render_types.PaneRenderRef;
const PaneRenderCell = runtime_render_types.PaneRenderCell;
const RuntimeVtState = runtime_vt.RuntimeVtState;
const ControlPipe = runtime_control_pipe.ControlPipe;
const paneCellAt = runtime_pane_rendering.paneCellAt;

fn renderRuntimeFrame(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    mux: *multiplexer.Multiplexer,
    vt_state: *RuntimeVtState,
    frame_cache: *RuntimeFrameCache,
    size: RuntimeSize,
    content: layout.Rect,
    plugin_ui_bars: ?plugin_host.PluginHost.UiBarsView,
    compose_debug_enabled: bool,
) !void {
    const total_cols: usize = size.cols;
    const content_rows: usize = content.height;
    const total_rows: usize = render_compositor.frameTotalRows(size);
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
    const popup_opaque_cover = try allocator.alloc(bool, canvas_len);
    defer allocator.free(popup_opaque_cover);
    @memset(popup_opaque_cover, false);
    const top_window_owner = try allocator.alloc(i32, canvas_len);
    defer allocator.free(top_window_owner);
    @memset(top_window_owner, -1);
    const chrome_layer = try allocator.alloc(u8, canvas_len);
    defer allocator.free(chrome_layer);
    @memset(chrome_layer, 0);
    const chrome_panel_id = try allocator.alloc(u32, canvas_len);
    defer allocator.free(chrome_panel_id);
    @memset(chrome_panel_id, 0);

    const rects = try mux.computeActiveLayout(content);
    defer allocator.free(rects);
    const tab = try mux.workspace_mgr.activeTab();
    const n = @min(rects.len, tab.windows.items.len);
    const popup_capacity = mux.popup_mgr.count();
    var panes = try allocator.alloc(PaneRenderRef, n + popup_capacity);
    defer allocator.free(panes);
    var pane_count: usize = 0;
    var focused_cursor_abs: ?struct { row: usize, col: usize } = null;

    const popup_order = try render_compositor.collectVisiblePopupOrder(allocator, mux);
    defer allocator.free(popup_order);
    const popup_count = popup_order.len;
    markPopupMasks(
        mux,
        popup_order,
        total_cols,
        content_rows,
        popup_overlay,
        popup_cover,
        popup_opaque_cover,
    );

    assignTopWindowOwners(rects[0..n], total_cols, content_rows, top_window_owner);
    try runtime_renderer.composeBaseWindows(
        mux,
        vt_state,
        tab,
        rects[0..n],
        content,
        total_cols,
        content_rows,
        canvas,
        border_conn,
        chrome_layer,
        chrome_panel_id,
        top_window_owner,
        popup_overlay,
        popup_opaque_cover,
        panes,
        &pane_count,
        &focused_cursor_abs,
    );

    try runtime_renderer.composePopups(
        mux,
        vt_state,
        popup_order,
        total_cols,
        content_rows,
        canvas,
        border_conn,
        chrome_layer,
        chrome_panel_id,
        panes,
        &pane_count,
        &focused_cursor_abs,
    );
    applyBorderGlyphs(canvas, border_conn, total_cols, content_rows, mux.borderGlyphs(), mux.focusMarker());
    runtime_renderer.repaintChromeAfterBorderPass(
        mux,
        tab,
        rects[0..n],
        content,
        popup_order,
        total_cols,
        content_rows,
        canvas,
        border_conn,
        chrome_layer,
        chrome_panel_id,
        top_window_owner,
        popup_cover,
    );

    const live_ids = try mux.liveWindowIds(allocator);
    defer allocator.free(live_ids);
    try vt_state.prune(live_ids);

    const footer_lines = try runtime_footer.resolveFooterLines(allocator, mux, plugin_ui_bars);
    defer footer_lines.deinit(allocator);

    const resized = try frame_cache.ensureSize(total_cols, total_rows);

    const curr = try allocator.alloc(RuntimeRenderCell, total_cols * total_rows);
    defer allocator.free(curr);
    for (curr) |*cell| cell.* = .{};
    runtime_renderer.composeContentCells(
        paneCellAt,
        mux,
        panes[0..pane_count],
        total_cols,
        content_rows,
        canvas,
        border_conn,
        chrome_layer,
        chrome_panel_id,
        popup_overlay,
        popup_opaque_cover,
        curr,
    );
    if (compose_debug_enabled and popup_count > 0) {
        runtime_compose_debug.logComposePopupSummary(
            g_compose_debug_frame,
            mux.popup_mgr.popups.items,
            popup_order[0..popup_count],
            popup_count,
            mux.popup_mgr.focused_popup_id,
            total_cols,
            content_rows,
        );
        const bg = runtime_compose_debug.logComposeBgDebug(
            curr,
            canvas,
            total_cols,
            content_rows,
            popup_count,
            popup_overlay,
            popup_opaque_cover,
            border_conn,
            chrome_layer,
            chrome_panel_id,
            &g_compose_debug_frame,
        );
        traceEvent(
            .compose_bg_leak,
            @intCast(popup_count),
            @intCast(bg.leak_cells),
            @intCast(bg.opaque_cells),
            @intCast(@min(bg.frame_no, @as(u64, std.math.maxInt(i32)))),
        );
    }

    const footer_rows = total_rows - content_rows;
    traceEvent(
        .render_footer,
        @intCast(total_cols),
        @intCast(total_rows),
        @intCast(content_rows),
        @intCast(footer_rows),
    );
    runtime_frame_output.composeFooterRows(
        curr,
        total_cols,
        content_rows,
        total_rows,
        footer_lines.minimized_line,
        footer_lines.tab_line,
        footer_lines.status_line,
    );
    try runtime_frame_output.writeFrameToTerminal(
        out,
        frame_cache,
        curr,
        resized,
        total_cols,
        content_rows,
        footer_rows,
        footer_lines.minimized_line,
        footer_lines.tab_line,
        footer_lines.status_line,
    );

    @memcpy(frame_cache.cells, curr);

    if (focused_cursor_abs) |p| {
        try writeFmtBlocking(out, "\x1b[{};{}H", .{ p.row, p.col });
    } else {
        try writeFmtBlocking(out, "\x1b[{};1H", .{render_compositor.fallbackCursorRow(content_rows, footer_rows)});
    }
    try writeAllBlocking(out, "\x1b[?25h");
}

const BorderMask = runtime_renderer.BorderMask;
const ContentInsets = runtime_renderer.ContentInsets;
const computeBorderMask = runtime_renderer.computeBorderMask;
const computeContentInsets = runtime_renderer.computeContentInsets;

fn markPopupMasks(
    mux: *const multiplexer.Multiplexer,
    popup_order: []const usize,
    cols: usize,
    rows: usize,
    popup_overlay: []bool,
    popup_cover: []bool,
    popup_opaque_cover: []bool,
) void {
    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        render_compositor.markPopupOverlay(popup_overlay, cols, rows, p.rect);
        render_compositor.markRectOverlay(popup_cover, cols, rows, p.rect);
        if (!p.transparent_background) {
            render_compositor.markRectOverlay(popup_opaque_cover, cols, rows, p.rect);
        }
    }
}

fn assignTopWindowOwners(
    rects: []const layout.Rect,
    cols: usize,
    rows: usize,
    top_window_owner: []i32,
) void {
    for (rects, 0..) |r, i| {
        if (r.width == 0 or r.height == 0) continue;
        var yy: usize = r.y;
        const y_end: usize = @min(@as(usize, r.y + r.height), rows);
        while (yy < y_end) : (yy += 1) {
            var xx: usize = r.x;
            const x_end: usize = @min(@as(usize, r.x + r.width), cols);
            while (xx < x_end) : (xx += 1) {
                top_window_owner[yy * cols + xx] = @intCast(i);
            }
        }
    }
}

test "workspace layout returns panes" {
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
    render_compositor.markRectOverlay(overlay, cols, rows, r);
    try testing.expect(overlay[1 * cols + 2]);
    try testing.expect(overlay[3 * cols + 5]);
    try testing.expect(!overlay[0]);

    const conn = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(conn);
    @memset(conn, 0x0f);
    render_compositor.clearBorderConnRect(conn, cols, rows, r);
    try testing.expectEqual(@as(u8, 0), conn[1 * cols + 2]);
    try testing.expectEqual(@as(u8, 0), conn[3 * cols + 5]);
    try testing.expectEqual(@as(u8, 0x0f), conn[0]);
}

test "contentRect never overflows total terminal rows" {
    const testing = std.testing;

    const tiny = runtime_terminal.contentRect(.{ .cols = 80, .rows = 1 });
    try testing.expectEqual(@as(u16, 1), tiny.height);

    const short = runtime_terminal.contentRect(.{ .cols = 80, .rows = 3 });
    try testing.expectEqual(@as(u16, 3), short.height);

    const normal = runtime_terminal.contentRect(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(@as(u16, 21), normal.height);
}

test "frame row math stays within terminal after resize extremes" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), render_compositor.frameTotalRows(.{ .cols = 80, .rows = 1 }));
    try testing.expectEqual(@as(usize, 3), render_compositor.frameTotalRows(.{ .cols = 80, .rows = 3 }));
    try testing.expectEqual(@as(usize, 24), render_compositor.frameTotalRows(.{ .cols = 80, .rows = 24 }));

    // No footer rows visible (tiny terminal): keep cursor on last visible content row.
    try testing.expectEqual(@as(usize, 1), render_compositor.fallbackCursorRow(1, 0));
    try testing.expectEqual(@as(usize, 3), render_compositor.fallbackCursorRow(3, 0));

    // Footer rows visible: place cursor at the final visible row.
    try testing.expectEqual(@as(usize, 24), render_compositor.fallbackCursorRow(21, 3));

    // Degenerate safety.
    try testing.expectEqual(@as(usize, 1), render_compositor.fallbackCursorRow(0, 0));
}
