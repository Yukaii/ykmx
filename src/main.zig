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
const poc_output = @import("poc_output.zig");
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

const Terminal = ghostty_vt.Terminal;
const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;
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
const plainCellFromCodepoint = runtime_cells.plainCellFromCodepoint;
const renderCellEqual = runtime_cells.renderCellEqual;
const runtimeCellHasExplicitBg = runtime_cells.runtimeCellHasExplicitBg;
const runtimeCellBgTag = runtime_cells.runtimeCellBgTag;
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
        if (std.mem.eql(u8, args[1], "ctl")) {
            try runtime_cli.runControlCli(alloc, if (args.len > 2) args[2..] else &.{});
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

    try poc_output.printZmxAndSignalPOC(out, zmx_env);
    try poc_output.printConfigPOC(out, cfg);
    try poc_output.printWorkspacePOC(out, alloc, cfg);
    try poc_output.printMultiplexerPOC(out, alloc, cfg, &zmx_env);
    try poc_output.renderSideBySide(out, &left, &right);
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

const ControlPipe = struct {
    allocator: std.mem.Allocator,
    session_id: []u8,
    path: []u8,
    state_path: []u8,
    read_fd: c_int,
    write_fd: c_int,
    buf: std.ArrayListUnmanaged(u8) = .{},

    fn init(allocator: std.mem.Allocator, maybe_session_name: ?[]const u8) !ControlPipe {
        const raw_id = maybe_session_name orelse "standalone";
        const session_id = try sanitizeSessionId(allocator, raw_id);
        errdefer allocator.free(session_id);

        const path = try std.fmt.allocPrint(allocator, "/tmp/ykmx-{s}.ctl", .{session_id});
        errdefer allocator.free(path);
        const state_path = try std.fmt.allocPrint(allocator, "/tmp/ykmx-{s}.state", .{session_id});
        errdefer allocator.free(state_path);

        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);
        _ = c.unlink(c_path.ptr);
        if (c.mkfifo(c_path.ptr, 0o600) != 0) return error.ControlPipeCreateFailed;

        const read_fd = c.open(c_path.ptr, c.O_RDONLY | c.O_NONBLOCK);
        if (read_fd < 0) return error.ControlPipeOpenFailed;
        errdefer _ = c.close(read_fd);

        const write_fd = c.open(c_path.ptr, c.O_WRONLY | c.O_NONBLOCK);
        if (write_fd < 0) return error.ControlPipeOpenFailed;
        errdefer _ = c.close(write_fd);

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .path = path,
            .state_path = state_path,
            .read_fd = read_fd,
            .write_fd = write_fd,
        };
    }

    fn deinit(self: *ControlPipe) void {
        _ = c.close(self.read_fd);
        _ = c.close(self.write_fd);
        self.buf.deinit(self.allocator);
        if (self.path.len > 0) {
            if (self.allocator.dupeZ(u8, self.path)) |c_path| {
                _ = c.unlink(c_path.ptr);
                self.allocator.free(c_path);
            } else |_| {}
        }
        self.allocator.free(self.path);
        self.allocator.free(self.state_path);
        self.allocator.free(self.session_id);
        self.* = undefined;
    }

    fn exportEnv(self: *const ControlPipe) !void {
        const session_z = try self.allocator.dupeZ(u8, self.session_id);
        defer self.allocator.free(session_z);
        const path_z = try self.allocator.dupeZ(u8, self.path);
        defer self.allocator.free(path_z);
        const state_path_z = try self.allocator.dupeZ(u8, self.state_path);
        defer self.allocator.free(state_path_z);
        if (c.setenv("YKMX_SESSION_ID", session_z.ptr, 1) != 0) return error.SetEnvFailed;
        if (c.setenv("YKMX_CONTROL_PIPE", path_z.ptr, 1) != 0) return error.SetEnvFailed;
        if (c.setenv("YKMX_STATE_FILE", state_path_z.ptr, 1) != 0) return error.SetEnvFailed;
    }

    fn poll(self: *ControlPipe, mux: *multiplexer.Multiplexer, screen: layout.Rect) !bool {
        var changed = false;
        var scratch: [1024]u8 = undefined;
        while (true) {
            const n = c.read(self.read_fd, &scratch, scratch.len);
            if (n < 0) break;
            if (n == 0) break;
            try self.buf.appendSlice(self.allocator, scratch[0..@intCast(n)]);
        }

        while (std.mem.indexOfScalar(u8, self.buf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, self.buf.items[0..nl], " \t\r");
            if (line.len > 0) {
                changed = (try runtime_control.applyControlCommandLine(mux, screen, line)) or changed;
            }
            consumePrefix(&self.buf, nl + 1);
        }
        return changed;
    }

    fn writeState(self: *ControlPipe, mux: *multiplexer.Multiplexer, plugins: *plugin_manager.PluginManager, screen: layout.Rect) !void {
        var text = std.ArrayListUnmanaged(u8){};
        defer text.deinit(self.allocator);
        const w = text.writer(self.allocator);

        const layout_type = try mux.workspace_mgr.activeLayoutType();
        const tab_count = mux.workspace_mgr.tabCount();
        const active_tab_idx = mux.workspace_mgr.activeTabIndex() orelse 0;
        const focused_window_idx = mux.workspace_mgr.focusedWindowIndexActive() catch null;
        const focused_panel_id = mux.popup_mgr.focused_popup_id orelse 0;

        try w.print("session_id={s}\n", .{self.session_id});
        try w.print("layout={s}\n", .{@tagName(layout_type)});
        try w.print("active_tab_index={}\n", .{active_tab_idx});
        try w.print("tab_count={}\n", .{tab_count});
        try w.print("screen={}x{}\n", .{ screen.width, screen.height });
        try w.print("panel_count_visible={}\n", .{mux.popup_mgr.visibleCount()});
        try w.print("focused_panel_id={}\n", .{focused_panel_id});
        try w.print("plugin_hosts={}\n", .{plugins.hostCount()});

        const tab = try mux.workspace_mgr.activeTab();
        for (tab.windows.items, 0..) |win, i| {
            try w.print("window id={} focused={} minimized={} title=", .{
                win.id,
                @as(u8, @intFromBool(focused_window_idx != null and focused_window_idx.? == i)),
                @as(u8, @intFromBool(win.minimized)),
            });
            try writeQuotedString(w, win.title);
            try w.writeByte('\n');
        }

        for (mux.popup_mgr.popups.items) |p| {
            try w.print(
                "panel id={} visible={} focused={} modal={} owner=",
                .{
                    p.id,
                    @as(u8, @intFromBool(p.visible)),
                    @as(u8, @intFromBool(mux.popup_mgr.focused_popup_id != null and mux.popup_mgr.focused_popup_id.? == p.id)),
                    @as(u8, @intFromBool(p.modal)),
                },
            );
            try writeQuotedString(w, p.owner_plugin_name orelse "");
            try w.print(" rect={},{} {}x{} title=", .{ p.rect.x, p.rect.y, p.rect.width, p.rect.height });
            try writeQuotedString(w, p.title);
            try w.writeByte('\n');
        }

        for (plugins.loadReports()) |report| {
            try w.writeAll("plugin name=");
            try writeQuotedString(w, report.plugin_name);
            try w.writeAll(" status=");
            try w.writeAll(@tagName(report.status));
            try w.writeAll(" reason=");
            try writeQuotedString(w, report.reason);
            try w.writeAll(" path=");
            try writeQuotedString(w, report.path);
            try w.writeByte('\n');
        }

        const runtime_hosts = plugins.runtimeHosts(self.allocator) catch &[_]plugin_manager.PluginManager.RuntimeHost{};
        defer if (runtime_hosts.len > 0) self.allocator.free(runtime_hosts);
        for (runtime_hosts) |host| {
            try w.writeAll("plugin_runtime name=");
            try writeQuotedString(w, host.plugin_name);
            try w.print(" alive={} pending_actions={} reason=", .{
                @as(u8, @intFromBool(host.alive)),
                host.pending_actions,
            });
            try writeQuotedString(w, host.death_reason orelse "");
            try w.writeAll(" stderr_tail=");
            try writeQuotedString(w, host.stderr_tail);
            try w.writeByte('\n');
        }

        try mux.appendCommandStateLines(&text, self.allocator);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.state_path});
        defer self.allocator.free(tmp_path);
        var f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(text.items);
        try std.fs.cwd().rename(tmp_path, self.state_path);
    }
};

fn consumePrefix(buf: *std.ArrayListUnmanaged(u8), n: usize) void {
    const remaining = buf.items.len - n;
    if (remaining > 0) @memmove(buf.items[0..remaining], buf.items[n..]);
    buf.items.len = remaining;
}

fn writeQuotedString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...31 => try writer.print("\\u00{x:0>2}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

fn sanitizeSessionId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (raw) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        try out.append(allocator, if (ok) ch else '_');
    }
    if (out.items.len == 0) try out.append(allocator, 's');
    return out.toOwnedSlice(allocator);
}

const RuntimeSize = runtime_terminal.RuntimeSize;
const RuntimeRenderCell = runtime_render_types.RuntimeRenderCell;
const RuntimeFrameCache = runtime_render_types.RuntimeFrameCache;
const PaneRenderRef = runtime_render_types.PaneRenderRef;
const PaneRenderCell = runtime_render_types.PaneRenderCell;
const RuntimeVtState = runtime_vt.RuntimeVtState;

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
    try composeBaseWindows(
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

    try composePopups(
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
    repaintChromeAfterBorderPass(
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
    composeContentCells(
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
        logComposePopupSummary(
            mux.popup_mgr.popups.items,
            popup_order[0..popup_count],
            popup_count,
            mux.popup_mgr.focused_popup_id,
            total_cols,
            content_rows,
        );
        logComposeBgDebug(
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
        );
    }

    const footer_rows = total_rows - content_rows;
    composeFooterRows(
        curr,
        total_cols,
        content_rows,
        total_rows,
        footer_lines.minimized_line,
        footer_lines.tab_line,
        footer_lines.status_line,
    );
    try writeFrameToTerminal(
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

fn composeFooterRows(
    curr: []RuntimeRenderCell,
    total_cols: usize,
    content_rows: usize,
    total_rows: usize,
    minimized_line: []const u8,
    tab_line: []const u8,
    status_line: []const u8,
) void {
    const footer_rows = total_rows - content_rows;
    traceEvent(
        .render_footer,
        @intCast(total_cols),
        @intCast(total_rows),
        @intCast(content_rows),
        @intCast(footer_rows),
    );
    if (footer_rows > 0) {
        fillPlainLine(curr[content_rows * total_cols .. (content_rows + 1) * total_cols], minimized_line);
    }
    if (footer_rows > 1) {
        fillPlainLine(curr[(content_rows + 1) * total_cols .. (content_rows + 2) * total_cols], tab_line);
    }
    if (footer_rows > 2) {
        fillPlainLine(curr[(content_rows + 2) * total_cols .. (content_rows + 3) * total_cols], status_line);
    }
}

fn writeFrameToTerminal(
    out: *std.Io.Writer,
    frame_cache: *RuntimeFrameCache,
    curr: []const RuntimeRenderCell,
    resized: bool,
    total_cols: usize,
    content_rows: usize,
    footer_rows: usize,
    minimized_line: []const u8,
    tab_line: []const u8,
    status_line: []const u8,
) !void {
    if (resized) try writeAllBlocking(out, "\x1b[2J");

    try writeContentDiff(out, frame_cache, curr, resized, total_cols);
    try paintFooterBars(out, total_cols, content_rows, footer_rows, minimized_line, tab_line, status_line);
}

fn writeContentDiff(
    out: *std.Io.Writer,
    frame_cache: *RuntimeFrameCache,
    curr: []const RuntimeRenderCell,
    resized: bool,
    total_cols: usize,
) !void {
    var active_style: ?ghostty_vt.Style = null;
    var idx: usize = 0;
    while (idx < curr.len) : (idx += 1) {
        if (!resized and renderCellEqual(frame_cache.cells[idx], curr[idx])) continue;

        if (!isSafeRunCell(curr[idx])) {
            const y = idx / total_cols;
            const x = idx % total_cols;
            try writeFmtBlocking(out, "\x1b[{};{}H", .{ y + 1, x + 1 });
            try writeAllBlocking(out, "\x1b[0m");
            active_style = null;
            const new = curr[idx];
            if (!new.styled) {
                if (active_style != null) {
                    try writeAllBlocking(out, "\x1b[0m");
                    active_style = null;
                }
            } else if (active_style) |s| {
                if (!s.eql(new.style)) {
                    try writeAllBlocking(out, "\x1b[0m");
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
        try writeAllBlocking(out, "\x1b[0m");
        active_style = null;

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
                    try writeAllBlocking(out, "\x1b[0m");
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
}

fn paintFooterBars(
    out: *std.Io.Writer,
    total_cols: usize,
    content_rows: usize,
    footer_rows: usize,
    minimized_line: []const u8,
    tab_line: []const u8,
    status_line: []const u8,
) !void {
    try writeAllBlocking(out, "\x1b[0m");
    if (footer_rows > 0) {
        try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 1});
        try writeClippedLine(out, minimized_line, total_cols);
    }
    if (footer_rows > 1) {
        try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 2});
        try writeClippedLine(out, tab_line, total_cols);
    }
    if (footer_rows > 2) {
        try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 3});
        try writeClippedLine(out, status_line, total_cols);
    }
}

const BorderMask = runtime_renderer.BorderMask;
const ContentInsets = runtime_renderer.ContentInsets;
const computeBorderMask = runtime_renderer.computeBorderMask;
const computeContentInsets = runtime_renderer.computeContentInsets;

const chrome_layer_none: u8 = 0;
const chrome_layer_active_border: u8 = 1;
const chrome_layer_inactive_border: u8 = 2;
const chrome_layer_active_title: u8 = 3;
const chrome_layer_inactive_title: u8 = 4;
const chrome_layer_active_buttons: u8 = 5;
const chrome_layer_inactive_buttons: u8 = 6;

fn resolveChromeStyleAt(
    mux: *const multiplexer.Multiplexer,
    role: u8,
    panel_id: u32,
) ?ghostty_vt.Style {
    if (role == chrome_layer_none) return null;
    const styles = if (panel_id != 0) (mux.panelChromeStylesById(panel_id) orelse mux.chromeStyles()) else mux.chromeStyles();
    const base = switch (role) {
        chrome_layer_active_border => styles.active_border,
        chrome_layer_inactive_border => styles.inactive_border,
        chrome_layer_active_title => styles.active_title,
        chrome_layer_inactive_title => styles.inactive_title,
        chrome_layer_active_buttons => styles.active_buttons,
        chrome_layer_inactive_buttons => styles.inactive_buttons,
        else => null,
    };
    if (base) |style| return enforceOpaquePanelChromeBg(style, panel_id);
    if (panel_id != 0) {
        var fallback: ghostty_vt.Style = .{};
        fallback.bg_color = .{ .palette = 0 };
        return fallback;
    }
    return null;
}

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

fn composeBaseWindows(
    mux: *multiplexer.Multiplexer,
    vt_state: *RuntimeVtState,
    tab: anytype,
    rects: []const layout.Rect,
    content: layout.Rect,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    top_window_owner: []const i32,
    popup_overlay: []const bool,
    popup_opaque_cover: []const bool,
    panes: []PaneRenderRef,
    pane_count: *usize,
    focused_cursor_abs: anytype,
) !void {
    for (rects, 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects, i, r, content);
        const insets = computeContentInsets(rects, i, r, border);
        const is_active = tab.focused_index == i;
        drawBorder(canvas, border_conn, total_cols, content_rows, r, border, if (is_active) mux.focusMarker() else ' ', i, top_window_owner);
        markBorderLayerOwned(chrome_layer, chrome_panel_id, total_cols, content_rows, r, border, if (is_active) chrome_layer_active_border else chrome_layer_inactive_border, i, top_window_owner, popup_opaque_cover);
        const inner_x = r.x + insets.left;
        const inner_y = r.y + insets.top;
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        const inner_h = if (r.height > insets.top + insets.bottom) r.height - insets.top - insets.bottom else 0;
        if (inner_w == 0 or inner_h == 0) continue;
        renderOwnedWindowTitleBar(
            mux,
            tab.windows.items[i].title,
            r,
            inner_w,
            i,
            is_active,
            total_cols,
            content_rows,
            canvas,
            chrome_layer,
            chrome_panel_id,
            top_window_owner,
            popup_overlay,
        );

        const window_id = tab.windows.items[i].id;
        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        const pane_scroll_offset = mux.windowScrollOffset(window_id) orelse 0;
        panes[pane_count.*] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .scroll_offset = pane_scroll_offset,
            .scrollback = mux.scrollbackBuffer(window_id),
            .term = &wv.term,
        };
        pane_count.* += 1;

        if (tab.focused_index == i) {
            if (pane_scroll_offset > 0) {
                const sel_x = @min(mux.selectionCursorX(window_id), @as(usize, inner_w - 1));
                const sel_y = @min(mux.selectionCursorY(window_id, inner_h), @as(usize, inner_h - 1));
                focused_cursor_abs.* = .{
                    .row = @as(usize, inner_y) + sel_y + 1,
                    .col = @as(usize, inner_x) + sel_x + 1,
                };
            } else {
                const cursor = wv.term.screens.active.cursor;
                const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
                const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
                focused_cursor_abs.* = .{
                    .row = @as(usize, inner_y) + cy + 1,
                    .col = @as(usize, inner_x) + cx + 1,
                };
            }
        }
    }
}

fn composePopups(
    mux: *multiplexer.Multiplexer,
    vt_state: *RuntimeVtState,
    popup_order: []const usize,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    panes: []PaneRenderRef,
    pane_count: *usize,
    focused_cursor_abs: anytype,
) !void {
    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        const window_id = p.window_id orelse continue;
        if (window_id == 0) continue;
        if (p.rect.width < 2 or p.rect.height < 2) continue;

        const inner_h = renderPopupChrome(
            mux,
            p,
            total_cols,
            content_rows,
            canvas,
            border_conn,
            chrome_layer,
            chrome_panel_id,
            true,
        );
        const inner_x = p.rect.x + 1;
        const inner_y = p.rect.y + 1;
        const inner_w = p.rect.width - 2;
        if (inner_w == 0 or inner_h == 0) continue;
        render_compositor.clearBorderConnInsideRect(border_conn, total_cols, content_rows, p.rect);

        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        const pane_scroll_offset = mux.windowScrollOffset(window_id) orelse 0;
        panes[pane_count.*] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .scroll_offset = pane_scroll_offset,
            .scrollback = mux.scrollbackBuffer(window_id),
            .term = &wv.term,
        };
        pane_count.* += 1;

        if (mux.popup_mgr.focused_popup_id == p.id) {
            const cursor = wv.term.screens.active.cursor;
            const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
            const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
            focused_cursor_abs.* = .{
                .row = @as(usize, inner_y) + cy + 1,
                .col = @as(usize, inner_x) + cx + 1,
            };
        }
    }
}

fn repaintChromeAfterBorderPass(
    mux: *multiplexer.Multiplexer,
    tab: anytype,
    rects: []const layout.Rect,
    content: layout.Rect,
    popup_order: []const usize,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    top_window_owner: []const i32,
    popup_cover: []const bool,
) void {
    for (rects, 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects, i, r, content);
        const insets = computeContentInsets(rects, i, r, border);
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        if (inner_w == 0) continue;

        renderOwnedWindowTitleBar(
            mux,
            tab.windows.items[i].title,
            r,
            inner_w,
            i,
            tab.focused_index == i,
            total_cols,
            content_rows,
            canvas,
            null,
            null,
            top_window_owner,
            popup_cover,
        );
    }

    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        if (p.rect.width < 2 or p.rect.height < 2) continue;
        _ = renderPopupChrome(
            mux,
            p,
            total_cols,
            content_rows,
            canvas,
            border_conn,
            chrome_layer,
            chrome_panel_id,
            true,
        );
    }
}

fn renderOwnedWindowTitleBar(
    mux: *const multiplexer.Multiplexer,
    title: []const u8,
    r: layout.Rect,
    inner_w: u16,
    owner_idx: usize,
    is_active: bool,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    chrome_layer: ?[]u8,
    chrome_panel_id: ?[]u32,
    top_window_owner: []const i32,
    mask: []const bool,
) void {
    var controls_buf: [9]u8 = undefined;
    const control_chars = mux.windowControlChars();
    controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
    const controls = controls_buf[0..];
    const controls_w: u16 = @intCast(controls.len);
    const title_max = if (r.width >= 10 and inner_w > controls_w) inner_w - controls_w else inner_w;
    const title_role: u8 = if (is_active) chrome_layer_active_title else chrome_layer_inactive_title;
    const controls_role: u8 = if (is_active) chrome_layer_active_buttons else chrome_layer_inactive_buttons;

    const inner_x = r.x + 1;
    drawTextOwnedMasked(canvas, total_cols, content_rows, inner_x, r.y, title, title_max, owner_idx, top_window_owner, mask);
    if (chrome_layer) |layer| {
        if (chrome_panel_id) |panel_ids| {
            markTextOwnedMaskedLayer(layer, panel_ids, total_cols, content_rows, inner_x, r.y, title, title_max, owner_idx, top_window_owner, mask, title_role);
        }
    }

    if (r.width >= 10) {
        const controls_x: u16 = r.x + r.width - controls_w - 1;
        drawTextOwnedMasked(canvas, total_cols, content_rows, controls_x, r.y, controls, controls_w, owner_idx, top_window_owner, mask);
        if (chrome_layer) |layer| {
            if (chrome_panel_id) |panel_ids| {
                markTextOwnedMaskedLayer(layer, panel_ids, total_cols, content_rows, controls_x, r.y, controls, controls_w, owner_idx, top_window_owner, mask, controls_role);
            }
        }
    }
}

fn renderPopupChrome(
    mux: *const multiplexer.Multiplexer,
    p: anytype,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    clear_rect: bool,
) u16 {
    if (clear_rect) {
        render_compositor.clearCanvasRect(canvas, total_cols, content_rows, p.rect);
        render_compositor.clearBorderConnRect(border_conn, total_cols, content_rows, p.rect);
        render_compositor.clearChromeLayerRect(chrome_layer, chrome_panel_id, total_cols, content_rows, p.rect);
    }

    const panel_active = mux.popup_mgr.focused_popup_id == p.id;
    if (p.show_border) {
        drawPopupBorderDirect(
            canvas,
            total_cols,
            content_rows,
            p.rect,
            mux.borderGlyphs(),
            if (panel_active) mux.focusMarker() else null,
        );
        const popup_border: BorderMask = .{ .left = true, .right = true, .top = true, .bottom = true };
        markBorderLayer(
            chrome_layer,
            chrome_panel_id,
            total_cols,
            content_rows,
            p.rect,
            popup_border,
            if (panel_active) chrome_layer_active_border else chrome_layer_inactive_border,
            p.id,
        );
    }

    const inner_x = p.rect.x + 1;
    const inner_w = p.rect.width - 2;
    if (inner_w > 0) {
        drawText(canvas, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w);
        markTextLayer(
            chrome_layer,
            chrome_panel_id,
            total_cols,
            content_rows,
            inner_x,
            p.rect.y,
            p.title,
            inner_w,
            if (panel_active) chrome_layer_active_title else chrome_layer_inactive_title,
            p.id,
        );
        if (p.show_controls and p.rect.width >= 10) {
            var controls_buf: [9]u8 = undefined;
            const control_chars = mux.windowControlChars();
            controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
            const controls = controls_buf[0..];
            const controls_w: u16 = @intCast(controls.len);
            const controls_x: u16 = p.rect.x + p.rect.width - controls_w - 1;
            drawText(canvas, total_cols, content_rows, controls_x, p.rect.y, controls, controls_w);
            markTextLayer(
                chrome_layer,
                chrome_panel_id,
                total_cols,
                content_rows,
                controls_x,
                p.rect.y,
                controls,
                controls_w,
                if (panel_active) chrome_layer_active_buttons else chrome_layer_inactive_buttons,
                p.id,
            );
        }
    }

    return p.rect.height - 2;
}

fn composeContentCells(
    mux: *multiplexer.Multiplexer,
    panes: []const PaneRenderRef,
    total_cols: usize,
    content_rows: usize,
    canvas: []const u21,
    border_conn: []const u8,
    chrome_layer: []const u8,
    chrome_panel_id: []const u32,
    popup_overlay: []const bool,
    popup_opaque_cover: []const bool,
    curr: []RuntimeRenderCell,
) void {
    var row: usize = 0;
    while (row < content_rows) : (row += 1) {
        const row_off = row * total_cols;
        const start = row * total_cols;
        var x: usize = 0;
        while (x < total_cols) : (x += 1) {
            if (popup_overlay[row_off + x]) {
                curr[row_off + x] = plainCellFromCodepoint(canvas[start + x]);
                if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                    curr[row_off + x].style = s;
                    curr[row_off + x].styled = !s.default();
                }
                continue;
            }
            if (border_conn[row_off + x] != 0) {
                curr[row_off + x] = plainCellFromCodepoint(canvas[start + x]);
                if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                    curr[row_off + x].style = s;
                    curr[row_off + x].styled = !s.default();
                }
                continue;
            }
            const pane_cell = paneCellAt(panes, x, row);
            if (pane_cell) |pc| {
                if (pc.skip_draw) {
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
            if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                curr[row_off + x].style = s;
                curr[row_off + x].styled = !s.default();
            }
            if (popup_opaque_cover[row_off + x]) {
                enforceOpaqueRuntimeCellBg(&curr[row_off + x]);
            }
        }
    }
}

fn markLayerCell(
    layer: []u8,
    panel_ids: []u32,
    cols: usize,
    rows: usize,
    x: usize,
    y: usize,
    role: u8,
    panel_id: u32,
) void {
    if (x >= cols or y >= rows or role == chrome_layer_none) return;
    const idx = y * cols + x;
    layer[idx] = role;
    panel_ids[idx] = panel_id;
}

fn markBorderLayer(
    layer: []u8,
    panel_ids: []u32,
    cols: usize,
    rows: usize,
    r: layout.Rect,
    border: BorderMask,
    role: u8,
    panel_id: u32,
) void {
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x1 >= cols or y1 >= rows) return;

    if (border.top) {
        var x = x0;
        while (x <= x1) : (x += 1) markLayerCell(layer, panel_ids, cols, rows, x, y0, role, panel_id);
    }
    if (border.bottom) {
        var x = x0;
        while (x <= x1) : (x += 1) markLayerCell(layer, panel_ids, cols, rows, x, y1, role, panel_id);
    }
    if (border.left) {
        var y = y0;
        while (y <= y1) : (y += 1) markLayerCell(layer, panel_ids, cols, rows, x0, y, role, panel_id);
    }
    if (border.right) {
        var y = y0;
        while (y <= y1) : (y += 1) markLayerCell(layer, panel_ids, cols, rows, x1, y, role, panel_id);
    }
}

fn markBorderLayerOwned(
    layer: []u8,
    panel_ids: []u32,
    cols: usize,
    rows: usize,
    r: layout.Rect,
    border: BorderMask,
    role: u8,
    owner_idx: usize,
    top_window_owner: []const i32,
    popup_opaque_cover: []const bool,
) void {
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x1 >= cols or y1 >= rows) return;
    const owner: i32 = @intCast(owner_idx);

    if (border.top) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const idx = y0 * cols + x;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x, y0, role, 0);
        }
    }
    if (border.bottom) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const idx = y1 * cols + x;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x, y1, role, 0);
        }
    }
    if (border.left) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            const idx = y * cols + x0;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x0, y, role, 0);
        }
    }
    if (border.right) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            const idx = y * cols + x1;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x1, y, role, 0);
        }
    }
}

fn markTextLayer(
    layer: []u8,
    panel_ids: []u32,
    cols: usize,
    rows: usize,
    x_start: u16,
    y: u16,
    text: []const u8,
    max_w: u16,
    role: u8,
    panel_id: u32,
) void {
    if (y >= rows) return;
    var x: usize = x_start;
    const y_usize: usize = y;
    var i: usize = 0;
    while (i < text.len and i < max_w and x < cols) : (i += 1) {
        markLayerCell(layer, panel_ids, cols, rows, x, y_usize, role, panel_id);
        x += 1;
    }
}

fn markTextOwnedMaskedLayer(
    layer: []u8,
    panel_ids: []u32,
    cols: usize,
    rows: usize,
    x_start: u16,
    y: u16,
    text: []const u8,
    max_w: u16,
    owner_idx: usize,
    top_window_owner: []const i32,
    mask: []const bool,
    role: u8,
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
            markLayerCell(layer, panel_ids, cols, rows, x, y_usize, role, 0);
        }
        x += 1;
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

fn logComposePopupSummary(
    popups: anytype,
    popup_order: []const usize,
    popup_count: usize,
    focused_popup_id: ?u32,
    cols: usize,
    rows: usize,
) void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "ykmx compose-debug frame={} popups={} focused_popup={} canvas={}x{}\n",
        .{ g_compose_debug_frame, popup_count, focused_popup_id orelse 0, cols, rows },
    ) catch return;
    _ = c.write(c.STDERR_FILENO, hdr.ptr, hdr.len);

    var i: usize = 0;
    while (i < popup_count) : (i += 1) {
        const idx = popup_order[i];
        if (idx >= popups.len) continue;
        const p = popups[idx];
        var line_buf: [320]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "  popup#{}/{} id={} vis={} z={} rect=({},{} {}x{}) border={} controls={} transparent={}\n",
            .{
                i + 1,
                popup_count,
                p.id,
                @as(u8, @intFromBool(p.visible)),
                p.z_index,
                p.rect.x,
                p.rect.y,
                p.rect.width,
                p.rect.height,
                @as(u8, @intFromBool(p.show_border)),
                @as(u8, @intFromBool(p.show_controls)),
                @as(u8, @intFromBool(p.transparent_background)),
            },
        ) catch continue;
        _ = c.write(c.STDERR_FILENO, line.ptr, line.len);
    }
}

fn logComposeBgDebug(
    curr: []const RuntimeRenderCell,
    canvas: []const u21,
    cols: usize,
    rows: usize,
    popup_count: usize,
    popup_overlay: []const bool,
    popup_opaque_cover: []const bool,
    border_conn: []const u8,
    chrome_layer: []const u8,
    chrome_panel_id: []const u32,
) void {
    if (curr.len == 0 or popup_count == 0) return;
    var opaque_cells: usize = 0;
    var leak_cells: usize = 0;
    var sample_ids: [12]usize = undefined;
    var sample_count: usize = 0;

    var i: usize = 0;
    while (i < curr.len and i < popup_opaque_cover.len) : (i += 1) {
        if (!popup_opaque_cover[i]) continue;
        opaque_cells += 1;
        if (!runtimeCellHasExplicitBg(curr[i])) {
            leak_cells += 1;
            if (sample_count < sample_ids.len) {
                sample_ids[sample_count] = i;
                sample_count += 1;
            }
        }
    }

    const frame_no = g_compose_debug_frame;
    g_compose_debug_frame += 1;
    traceEvent(
        .compose_bg_leak,
        @intCast(popup_count),
        @intCast(leak_cells),
        @intCast(opaque_cells),
        @intCast(@min(frame_no, @as(u64, std.math.maxInt(i32)))),
    );

    // Log every leaking frame; also heartbeat every ~120 frames to confirm state.
    if (leak_cells == 0 and (frame_no % 120) != 0) return;

    var stderr_buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &stderr_buf,
        "ykmx compose-debug frame={} popups={} rows={} cols={} opaque_cells={} leak_cells={}\n",
        .{ frame_no, popup_count, rows, cols, opaque_cells, leak_cells },
    ) catch return;
    _ = c.write(c.STDERR_FILENO, prefix.ptr, prefix.len);

    var s: usize = 0;
    while (s < sample_count) : (s += 1) {
        const idx = sample_ids[s];
        const x = idx % cols;
        const y = idx / cols;
        const cell = curr[idx];
        const cp = if (idx < canvas.len) canvas[idx] else @as(u21, ' ');
        var sample_buf: [320]u8 = undefined;
        const line = std.fmt.bufPrint(
            &sample_buf,
            "  leak#{}/{} x={} y={} cp=U+{X:0>4} text_len={} styled={} bg_tag={} overlay={} opaque={} border_bits={} chrome_role={} panel_id={}\n",
            .{
                s + 1,
                sample_count,
                x,
                y,
                cp,
                cell.text_len,
                @as(u8, @intFromBool(cell.styled)),
                runtimeCellBgTag(cell),
                @as(u8, @intFromBool(idx < popup_overlay.len and popup_overlay[idx])),
                @as(u8, @intFromBool(idx < popup_opaque_cover.len and popup_opaque_cover[idx])),
                if (idx < border_conn.len) border_conn[idx] else 0,
                if (idx < chrome_layer.len) chrome_layer[idx] else 0,
                if (idx < chrome_panel_id.len) chrome_panel_id[idx] else 0,
            },
        ) catch continue;
        _ = c.write(c.STDERR_FILENO, line.ptr, line.len);
    }
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
