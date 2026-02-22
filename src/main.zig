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
const input_mod = @import("input.zig");

const Terminal = ghostty_vt.Terminal;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("stdlib.h");
});

const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;
const RUNTIME_VT_MAX_SCROLLBACK: usize = 20_000;

const DebugTag = enum(u8) {
    loop_size_change,
    tick_result,
    render_begin,
    render_footer,
    plugin_request_redraw,
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

fn traceEvent(tag: DebugTag, a: i32, b: i32, c_val: i32, d: i32) void {
    g_debug_trace.push(tag, a, b, c_val, d);
}

fn debugTagName(tag: DebugTag) []const u8 {
    return switch (tag) {
        .loop_size_change => "loop_size_change",
        .tick_result => "tick_result",
        .render_begin => "render_begin",
        .render_footer => "render_footer",
        .plugin_request_redraw => "plugin_request_redraw",
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
            try runControlCli(alloc, if (args.len > 2) args[2..] else &.{});
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
            const n = readStdinNonBlocking(&input_buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) break;
            try mux.handleInputBytesWithScreen(content, input_buf[0..n]);
        }
        try mux.flushPendingInputTimeouts();

        const snap = signal_mod.drain();
        const tick_result = try mux.tick(30, content, snap);
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
                    for (owned) |*sourced| plugin_host.PluginHost.deinitActionPayload(allocator, &sourced.action);
                    allocator.free(owned);
                }
                var changed = false;
                for (owned) |sourced| {
                    changed = (try applyPluginAction(&mux, content, sourced.plugin_name, sourced.action)) or changed;
                }
                if (changed) force_redraw = true;
            }
            if (plugins.consumeUiDirtyAny()) force_redraw = true;
        }

        if (try control.poll(&mux, content)) force_redraw = true;
        control.writeState(&mux, &plugins, content) catch {};

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
            traceEvent(
                .render_begin,
                @intCast(size.cols),
                @intCast(size.rows),
                @intCast(content.width),
                @intCast(content.height),
            );
            try renderRuntimeFrame(out, allocator, &mux, &vt_state, &frame_cache, size, content, if (plugins.hasAny()) plugins.uiBars() else null);
            try out.flush();
            force_redraw = false;
        }
    }
    if (plugins.hasAny()) plugins.emitShutdown();
}

const ControlCommand = struct {
    v: ?u8 = null,
    command: ?[]const u8 = null,
    command_name: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    x: ?u16 = null,
    y: ?u16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    modal: ?bool = null,
    transparent_background: ?bool = null,
    show_border: ?bool = null,
    show_controls: ?bool = null,
    panel_id: ?u32 = null,
    visible: ?bool = null,
    cwd: ?[]const u8 = null,
};

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
                changed = (try applyControlCommandLine(mux, screen, line)) or changed;
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

fn appendJsonString(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...31 => try out.writer(allocator).print("\\u00{x:0>2}", .{ch}),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
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

fn applyControlCommandLine(mux: *multiplexer.Multiplexer, screen: layout.Rect, line: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(ControlCommand, arena.allocator(), line, .{}) catch return false;
    const cmd = parsed.value.command orelse return false;

    if (std.mem.eql(u8, cmd, "new_window")) {
        _ = try mux.createShellWindow("shell");
        _ = try mux.resizeActiveWindowsToLayout(screen);
        return true;
    }
    if (std.mem.eql(u8, cmd, "close_window")) {
        _ = mux.closeFocusedWindow() catch return false;
        _ = try mux.resizeActiveWindowsToLayout(screen);
        return true;
    }
    if (std.mem.eql(u8, cmd, "open_popup")) {
        const has_rect = parsed.value.x != null and parsed.value.y != null and parsed.value.width != null and parsed.value.height != null;
        const rect: layout.Rect = .{
            .x = parsed.value.x orelse 0,
            .y = parsed.value.y orelse 0,
            .width = parsed.value.width orelse 1,
            .height = parsed.value.height orelse 1,
        };
        if (parsed.value.argv) |argv| {
            if (argv.len > 0) {
                if (has_rect) {
                    _ = try mux.openCommandPopupRectInDir("popup-cmd", argv, screen, rect, true, true, parsed.value.cwd);
                } else {
                    _ = try mux.openCommandPopupInDir("popup-cmd", argv, screen, true, true, parsed.value.cwd);
                }
                return true;
            }
        }
        if (has_rect) {
            _ = try mux.openShellPopupRectStyledInDir(
                "popup-shell",
                screen,
                rect,
                true,
                .{},
                null,
                parsed.value.cwd,
            );
        } else {
            _ = try mux.openShellPopupOwnedInDir("popup-shell", screen, true, null, parsed.value.cwd);
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "open_panel_rect")) {
        const x = parsed.value.x orelse return false;
        const y = parsed.value.y orelse return false;
        const width = parsed.value.width orelse return false;
        const height = parsed.value.height orelse return false;
        _ = try mux.openShellPopupRectStyledInDir(
            "popup-shell",
            screen,
            .{ .x = x, .y = y, .width = width, .height = height },
            parsed.value.modal orelse false,
            .{
                .transparent_background = parsed.value.transparent_background orelse false,
                .show_border = parsed.value.show_border orelse true,
                .show_controls = parsed.value.show_controls orelse false,
            },
            null,
            parsed.value.cwd,
        );
        return true;
    }
    if (std.mem.eql(u8, cmd, "set_panel_visibility")) {
        const panel_id = parsed.value.panel_id orelse return false;
        const visible = parsed.value.visible orelse return false;
        return try mux.setPopupVisibilityByIdOwned(panel_id, visible, null);
    }
    if (std.mem.eql(u8, cmd, "dispatch_plugin_command")) {
        const command_name = parsed.value.command_name orelse return false;
        return try mux.dispatchPluginNamedCommand(command_name);
    }
    return false;
}

fn runControlCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help")) {
        var buf: [1024]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const out = &w.interface;
        try out.writeAll(
            \\ykmx ctl usage:
            \\  ykmx ctl new-window
            \\  ykmx ctl close-window
            \\  ykmx ctl open-popup [--cwd <path>] [--x N --y N --width N --height N] [--] <program> [args...]
            \\  ykmx ctl open-panel x y width height [--cwd <path>]
            \\  ykmx ctl hide-panel <panel_id>
            \\  ykmx ctl show-panel <panel_id>
            \\  ykmx ctl status
            \\  ykmx ctl list-windows
            \\  ykmx ctl list-panels
            \\  ykmx ctl list-plugins
            \\  ykmx ctl list-commands [--format text|json|jsonl]
            \\  ykmx ctl command <name>
            \\  ykmx ctl json '<json>'
            \\
            \\Uses $YKMX_CONTROL_PIPE (actions) and $YKMX_STATE_FILE (listing).
            \\
        );
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, args[0], "status") or std.mem.eql(u8, args[0], "list-windows") or std.mem.eql(u8, args[0], "list-panels") or std.mem.eql(u8, args[0], "list-plugins") or std.mem.eql(u8, args[0], "list-commands")) {
        const state_path = resolveStatePathForCli(allocator) catch |err| switch (err) {
            error.MissingControlPipeEnv => return writeControlEnvHint(),
            else => return err,
        };
        defer allocator.free(state_path);
        const content = try std.fs.cwd().readFileAlloc(allocator, state_path, 1024 * 1024);
        defer allocator.free(content);

        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        const out = &w.interface;

        if (std.mem.eql(u8, args[0], "status")) {
            try out.writeAll(content);
        } else if (std.mem.eql(u8, args[0], "list-commands")) {
            var format: []const u8 = "text";
            if (args.len >= 2) {
                if (std.mem.eql(u8, args[1], "--json")) {
                    format = "json";
                } else if (std.mem.eql(u8, args[1], "--format")) {
                    if (args.len < 3) return error.InvalidControlArgs;
                    format = args[2];
                } else {
                    return error.InvalidControlArgs;
                }
            }

            if (std.mem.eql(u8, format, "text")) {
                var it = std.mem.splitScalar(u8, content, '\n');
                while (it.next()) |line| {
                    if (!std.mem.startsWith(u8, line, "command ")) continue;
                    try out.writeAll(line);
                    try out.writeByte('\n');
                }
            } else if (std.mem.eql(u8, format, "json")) {
                var json = std.ArrayListUnmanaged(u8){};
                defer json.deinit(allocator);
                try renderCommandListJson(allocator, &json, content, false);
                try out.writeAll(json.items);
                try out.writeByte('\n');
            } else if (std.mem.eql(u8, format, "jsonl")) {
                var jsonl = std.ArrayListUnmanaged(u8){};
                defer jsonl.deinit(allocator);
                try renderCommandListJson(allocator, &jsonl, content, true);
                try out.writeAll(jsonl.items);
                if (jsonl.items.len == 0 or jsonl.items[jsonl.items.len - 1] != '\n') {
                    try out.writeByte('\n');
                }
            } else {
                return error.InvalidControlArgs;
            }
        } else {
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                if (std.mem.eql(u8, args[0], "list-windows")) {
                    if (!std.mem.startsWith(u8, line, "window ")) continue;
                } else if (std.mem.eql(u8, args[0], "list-plugins")) {
                    if (!std.mem.startsWith(u8, line, "plugin ")) {
                        if (!std.mem.startsWith(u8, line, "plugin_runtime ")) continue;
                    }
                } else {
                    if (!std.mem.startsWith(u8, line, "panel ")) continue;
                }
                try out.writeAll(line);
                try out.writeByte('\n');
            }
        }
        try out.flush();
        return;
    }

    const pipe_path = std.process.getEnvVarOwned(allocator, "YKMX_CONTROL_PIPE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return writeControlEnvHint(),
        else => return err,
    };
    defer allocator.free(pipe_path);
    const pipe_z = try allocator.dupeZ(u8, pipe_path);
    defer allocator.free(pipe_z);

    var line = std.ArrayListUnmanaged(u8){};
    defer line.deinit(allocator);

    if (std.mem.eql(u8, args[0], "json")) {
        if (args.len < 2) return error.InvalidControlArgs;
        try line.appendSlice(allocator, args[1]);
    } else if (std.mem.eql(u8, args[0], "new-window")) {
        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"new_window\"}");
    } else if (std.mem.eql(u8, args[0], "close-window")) {
        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"close_window\"}");
    } else if (std.mem.eql(u8, args[0], "open-popup")) {
        var cwd: ?[]const u8 = null;
        var x: ?u16 = null;
        var y: ?u16 = null;
        var width: ?u16 = null;
        var height: ?u16 = null;
        var i: usize = 1;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cwd")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                cwd = args[i + 1];
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--x")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                x = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--y")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                y = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--width")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                width = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--height")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                height = try std.fmt.parseInt(u16, args[i + 1], 10);
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, args[i], "--")) {
                i += 1;
                break;
            }
            break;
        }
        const argv = args[i..];
        const has_any_rect = x != null or y != null or width != null or height != null;
        if (has_any_rect and !(x != null and y != null and width != null and height != null)) {
            return error.InvalidControlArgs;
        }

        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"open_popup\"");
        if (cwd) |dir| {
            try line.appendSlice(allocator, ",\"cwd\":");
            try appendJsonString(&line, allocator, dir);
        }
        if (x) |value| try line.writer(allocator).print(",\"x\":{}", .{value});
        if (y) |value| try line.writer(allocator).print(",\"y\":{}", .{value});
        if (width) |value| try line.writer(allocator).print(",\"width\":{}", .{value});
        if (height) |value| try line.writer(allocator).print(",\"height\":{}", .{value});
        if (argv.len > 0) {
            try line.appendSlice(allocator, ",\"argv\":[");
            for (argv, 0..) |arg, j| {
                if (j > 0) try line.append(allocator, ',');
                try appendJsonString(&line, allocator, arg);
            }
            try line.append(allocator, ']');
        }
        try line.append(allocator, '}');
    } else if (std.mem.eql(u8, args[0], "open-panel")) {
        if (args.len < 5) return error.InvalidControlArgs;
        const x = try std.fmt.parseInt(u16, args[1], 10);
        const y = try std.fmt.parseInt(u16, args[2], 10);
        const width = try std.fmt.parseInt(u16, args[3], 10);
        const height = try std.fmt.parseInt(u16, args[4], 10);

        var cwd: ?[]const u8 = null;
        var i: usize = 5;
        while (i < args.len) {
            if (std.mem.eql(u8, args[i], "--cwd")) {
                if (i + 1 >= args.len) return error.InvalidControlArgs;
                cwd = args[i + 1];
                i += 2;
                continue;
            }
            return error.InvalidControlArgs;
        }

        try line.appendSlice(allocator, "{\"v\":1,\"command\":\"open_panel_rect\",");
        try line.writer(allocator).print("\"x\":{},\"y\":{},\"width\":{},\"height\":{},\"modal\":false", .{
            x,
            y,
            width,
            height,
        });
        if (cwd) |dir| {
            try line.appendSlice(allocator, ",\"cwd\":");
            try appendJsonString(&line, allocator, dir);
        }
        try line.append(allocator, '}');
    } else if (std.mem.eql(u8, args[0], "hide-panel")) {
        if (args.len < 2) return error.InvalidControlArgs;
        try line.writer(allocator).print(
            "{{\"v\":1,\"command\":\"set_panel_visibility\",\"panel_id\":{},\"visible\":false}}",
            .{try std.fmt.parseInt(u32, args[1], 10)},
        );
    } else if (std.mem.eql(u8, args[0], "show-panel")) {
        if (args.len < 2) return error.InvalidControlArgs;
        try line.writer(allocator).print(
            "{{\"v\":1,\"command\":\"set_panel_visibility\",\"panel_id\":{},\"visible\":true}}",
            .{try std.fmt.parseInt(u32, args[1], 10)},
        );
    } else if (std.mem.eql(u8, args[0], "command")) {
        if (args.len < 2) return error.InvalidControlArgs;
        if (!input_mod.isValidCommandName(args[1])) return error.InvalidControlArgs;
        try line.writer(allocator).print(
            "{{\"v\":1,\"command\":\"dispatch_plugin_command\",\"command_name\":\"{s}\"}}",
            .{args[1]},
        );
    } else {
        return error.InvalidControlArgs;
    }
    try line.append(allocator, '\n');

    const fd = c.open(pipe_z.ptr, c.O_WRONLY);
    if (fd < 0) return error.ControlPipeOpenFailed;
    defer _ = c.close(fd);
    _ = c.write(fd, line.items.ptr, line.items.len);
}

fn writeControlEnvHint() !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const err_out = &w.interface;
    try err_out.writeAll("ykmx ctl requires a running ykmx session shell (missing YKMX_CONTROL_PIPE/YKMX_STATE_FILE).\n");
    try err_out.flush();
}

fn resolveStatePathForCli(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "YKMX_STATE_FILE")) |state_path| {
        return state_path;
    } else |_| {}

    const pipe_path = std.process.getEnvVarOwned(allocator, "YKMX_CONTROL_PIPE") catch return error.MissingControlPipeEnv;
    defer allocator.free(pipe_path);

    if (std.mem.endsWith(u8, pipe_path, ".ctl")) {
        return std.fmt.allocPrint(allocator, "{s}.state", .{pipe_path[0 .. pipe_path.len - 4]});
    }
    return std.fmt.allocPrint(allocator, "{s}.state", .{pipe_path});
}

const CommandStateLine = struct {
    name: []const u8,
    source: []const u8,
    plugin_override: bool,
    prefixed_keys: []const u8,
};

fn parseCommandStateLine(line: []const u8) ?CommandStateLine {
    if (!std.mem.startsWith(u8, line, "command ")) return null;
    var name: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var plugin_override: ?bool = null;
    var prefixed_keys: ?[]const u8 = null;

    var parts = std.mem.splitScalar(u8, line["command ".len..], ' ');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.startsWith(u8, part, "name=")) {
            name = part["name=".len..];
        } else if (std.mem.startsWith(u8, part, "source=")) {
            source = part["source=".len..];
        } else if (std.mem.startsWith(u8, part, "plugin_override=")) {
            const raw = part["plugin_override=".len..];
            if (std.mem.eql(u8, raw, "1")) plugin_override = true else if (std.mem.eql(u8, raw, "0")) plugin_override = false;
        } else if (std.mem.startsWith(u8, part, "prefixed_keys=")) {
            prefixed_keys = part["prefixed_keys=".len..];
        }
    }

    if (name == null or source == null or plugin_override == null or prefixed_keys == null) return null;
    return .{
        .name = name.?,
        .source = source.?,
        .plugin_override = plugin_override.?,
        .prefixed_keys = prefixed_keys.?,
    };
}

fn renderCommandListJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    content: []const u8,
    jsonl: bool,
) !void {
    if (!jsonl) try out.append(allocator, '[');
    var first = true;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const cmd = parseCommandStateLine(line) orelse continue;
        if (!first) {
            if (jsonl) {
                try out.append(allocator, '\n');
            } else {
                try out.append(allocator, ',');
            }
        }
        first = false;
        try out.append(allocator, '{');
        try out.appendSlice(allocator, "\"name\":");
        try appendJsonString(out, allocator, cmd.name);
        try out.appendSlice(allocator, ",\"source\":");
        try appendJsonString(out, allocator, cmd.source);
        try out.appendSlice(allocator, ",\"plugin_override\":");
        try out.appendSlice(allocator, if (cmd.plugin_override) "true" else "false");
        try out.appendSlice(allocator, ",\"prefixed_keys\":[");
        if (!std.mem.eql(u8, cmd.prefixed_keys, "-")) {
            var keys = std.mem.splitScalar(u8, cmd.prefixed_keys, ',');
            var first_key = true;
            while (keys.next()) |key| {
                if (key.len == 0) continue;
                if (!first_key) try out.append(allocator, ',');
                first_key = false;
                try appendJsonString(out, allocator, key);
            }
        }
        try out.appendSlice(allocator, "]}");
    }
    if (!jsonl) try out.append(allocator, ']');
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
        .panel_count = mux.popup_mgr.visibleCount(),
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
    plugin_name: []const u8,
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
            traceEvent(.plugin_request_redraw, @intCast(screen.width), @intCast(screen.height), 0, 0);
            _ = try mux.resizeActiveWindowsToLayout(screen);
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
            _ = try mux.openShellPopupOwned("popup-shell", screen, true, plugin_name);
            return true;
        },
        .close_focused_panel => {
            return try mux.closeFocusedPopupOwned(plugin_name);
        },
        .cycle_panel_focus => {
            return mux.cyclePopupFocusOwned(plugin_name);
        },
        .toggle_shell_panel => {
            if (try mux.closeFocusedPopupOwned(plugin_name)) {
                return true;
            } else {
                _ = try mux.openShellPopupOwned("popup-shell", screen, true, plugin_name);
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
                plugin_name,
            );
            return true;
        },
        .close_panel_by_id => |panel_id| {
            return try mux.closePopupByIdOwned(panel_id, plugin_name);
        },
        .focus_panel_by_id => |panel_id| {
            return try mux.focusPopupByIdOwned(panel_id, plugin_name);
        },
        .move_panel_by_id => |payload| {
            return try mux.movePopupByIdOwned(payload.panel_id, payload.x, payload.y, screen, plugin_name);
        },
        .resize_panel_by_id => |payload| {
            return try mux.resizePopupByIdOwned(payload.panel_id, payload.width, payload.height, screen, plugin_name);
        },
        .set_panel_visibility_by_id => |payload| {
            return try mux.setPopupVisibilityByIdOwned(payload.panel_id, payload.visible, plugin_name);
        },
        .set_panel_style_by_id => |payload| {
            return try mux.setPopupStyleByIdOwned(payload.panel_id, .{
                .transparent_background = payload.transparent_background,
                .show_border = payload.show_border,
                .show_controls = payload.show_controls,
            }, screen, plugin_name);
        },
        .set_chrome_theme => |payload| {
            mux.applyChromeTheme(.{
                .window_minimize_char = payload.window_minimize_char,
                .window_maximize_char = payload.window_maximize_char,
                .window_close_char = payload.window_close_char,
                .focus_marker = payload.focus_marker,
                .border_horizontal = payload.border_horizontal,
                .border_vertical = payload.border_vertical,
                .border_corner_tl = payload.border_corner_tl,
                .border_corner_tr = payload.border_corner_tr,
                .border_corner_bl = payload.border_corner_bl,
                .border_corner_br = payload.border_corner_br,
                .border_tee_top = payload.border_tee_top,
                .border_tee_bottom = payload.border_tee_bottom,
                .border_tee_left = payload.border_tee_left,
                .border_tee_right = payload.border_tee_right,
                .border_cross = payload.border_cross,
            });
            return true;
        },
        .reset_chrome_theme => {
            mux.resetChromeTheme();
            return true;
        },
        .set_chrome_style => |payload| {
            mux.applyChromeStyle(.{
                .active_title = if (payload.active_title_sgr) |s| try parseSgrStyleSpec(s) else null,
                .inactive_title = if (payload.inactive_title_sgr) |s| try parseSgrStyleSpec(s) else null,
                .active_border = if (payload.active_border_sgr) |s| try parseSgrStyleSpec(s) else null,
                .inactive_border = if (payload.inactive_border_sgr) |s| try parseSgrStyleSpec(s) else null,
                .active_buttons = if (payload.active_buttons_sgr) |s| try parseSgrStyleSpec(s) else null,
                .inactive_buttons = if (payload.inactive_buttons_sgr) |s| try parseSgrStyleSpec(s) else null,
            });
            return true;
        },
        .set_panel_chrome_style_by_id => |payload| {
            return try mux.setPanelChromeStyleByIdOwned(
                payload.panel_id,
                payload.reset,
                .{
                    .active_title = if (payload.active_title_sgr) |s| try parseSgrStyleSpec(s) else null,
                    .inactive_title = if (payload.inactive_title_sgr) |s| try parseSgrStyleSpec(s) else null,
                    .active_border = if (payload.active_border_sgr) |s| try parseSgrStyleSpec(s) else null,
                    .inactive_border = if (payload.inactive_border_sgr) |s| try parseSgrStyleSpec(s) else null,
                    .active_buttons = if (payload.active_buttons_sgr) |s| try parseSgrStyleSpec(s) else null,
                    .inactive_buttons = if (payload.inactive_buttons_sgr) |s| try parseSgrStyleSpec(s) else null,
                },
                plugin_name,
            );
        },
    }
}

fn parseSgrStyleSpec(spec_raw: []const u8) !ghostty_vt.Style {
    var style: ghostty_vt.Style = .{};
    var spec = std.mem.trim(u8, spec_raw, " \t\r\n");
    if (spec.len == 0) return style;
    if (std.mem.startsWith(u8, spec, "\x1b[") and std.mem.endsWith(u8, spec, "m") and spec.len >= 3) {
        spec = spec[2 .. spec.len - 1];
    } else if (std.mem.endsWith(u8, spec, "m") and spec.len >= 2) {
        spec = spec[0 .. spec.len - 1];
    }
    if (spec.len == 0) return style;

    var codes = std.ArrayListUnmanaged(u16){};
    defer codes.deinit(std.heap.page_allocator);
    var it = std.mem.splitScalar(u8, spec, ';');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        const code: u16 = if (part.len == 0) 0 else (std.fmt.parseInt(u16, part, 10) catch continue);
        try codes.append(std.heap.page_allocator, code);
    }

    var i: usize = 0;
    while (i < codes.items.len) : (i += 1) {
        const code = codes.items[i];
        switch (code) {
            0 => style = .{},
            1 => style.flags.bold = true,
            2 => style.flags.faint = true,
            3 => style.flags.italic = true,
            4 => style.flags.underline = .single,
            5 => style.flags.blink = true,
            7 => style.flags.inverse = true,
            8 => style.flags.invisible = true,
            9 => style.flags.strikethrough = true,
            21 => style.flags.underline = .double,
            22 => {
                style.flags.bold = false;
                style.flags.faint = false;
            },
            23 => style.flags.italic = false,
            24 => style.flags.underline = .none,
            25 => style.flags.blink = false,
            27 => style.flags.inverse = false,
            28 => style.flags.invisible = false,
            29 => style.flags.strikethrough = false,
            30...37 => style.fg_color = .{ .palette = @intCast(code - 30) },
            39 => style.fg_color = .none,
            40...47 => style.bg_color = .{ .palette = @intCast(code - 40) },
            49 => style.bg_color = .none,
            90...97 => style.fg_color = .{ .palette = @intCast(8 + code - 90) },
            100...107 => style.bg_color = .{ .palette = @intCast(8 + code - 100) },
            38, 48, 58 => {
                if (i + 1 >= codes.items.len) continue;
                const mode = codes.items[i + 1];
                if (mode == 5 and i + 2 < codes.items.len) {
                    const v: u8 = @intCast(@min(codes.items[i + 2], 255));
                    switch (code) {
                        38 => style.fg_color = .{ .palette = v },
                        48 => style.bg_color = .{ .palette = v },
                        58 => style.underline_color = .{ .palette = v },
                        else => {},
                    }
                    i += 2;
                } else if (mode == 2 and i + 4 < codes.items.len) {
                    const r: u8 = @intCast(@min(codes.items[i + 2], 255));
                    const g: u8 = @intCast(@min(codes.items[i + 3], 255));
                    const b: u8 = @intCast(@min(codes.items[i + 4], 255));
                    switch (code) {
                        38 => style.fg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } },
                        48 => style.bg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } },
                        58 => style.underline_color = .{ .rgb = .{ .r = r, .g = g, .b = b } },
                        else => {},
                    }
                    i += 4;
                }
            },
            59 => style.underline_color = .none,
            else => {},
        }
    }
    return style;
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
    // Prefer reserving 3 footer lines (toolbar/tab/status), but on very short
    // terminals skip footer reservation to keep indexing safe.
    const usable_rows: u16 = if (size.rows > 3) size.rows - 3 else size.rows;
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
        const is_active = tab.focused_index == i;
        drawBorder(canvas, border_conn, total_cols, content_rows, r, border, if (is_active) mux.focusMarker() else ' ', i, top_window_owner);
        markBorderLayerOwned(chrome_layer, chrome_panel_id, total_cols, content_rows, r, border, if (is_active) chrome_layer_active_border else chrome_layer_inactive_border, i, top_window_owner);
        const inner_x = r.x + insets.left;
        const inner_y = r.y + insets.top;
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        const inner_h = if (r.height > insets.top + insets.bottom) r.height - insets.top - insets.bottom else 0;
        if (inner_w == 0 or inner_h == 0) continue;

        const title = tab.windows.items[i].title;
        var controls_buf: [9]u8 = undefined;
        const control_chars = mux.windowControlChars();
        controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
        const controls = controls_buf[0..];
        const controls_w: u16 = @intCast(controls.len);
        const title_max = if (r.width >= 10 and inner_w > controls_w) inner_w - controls_w else inner_w;
        drawTextOwnedMasked(canvas, total_cols, content_rows, inner_x, r.y, title, title_max, i, top_window_owner, popup_overlay);
        markTextOwnedMaskedLayer(chrome_layer, chrome_panel_id, total_cols, content_rows, inner_x, r.y, title, title_max, i, top_window_owner, popup_overlay, if (is_active) chrome_layer_active_title else chrome_layer_inactive_title);
        if (r.width >= 10) {
            const controls_x: u16 = r.x + r.width - controls_w - 1;
            drawTextOwnedMasked(canvas, total_cols, content_rows, controls_x, r.y, controls, controls_w, i, top_window_owner, popup_overlay);
            markTextOwnedMaskedLayer(chrome_layer, chrome_panel_id, total_cols, content_rows, controls_x, r.y, controls, controls_w, i, top_window_owner, popup_overlay, if (is_active) chrome_layer_active_buttons else chrome_layer_inactive_buttons);
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
    var popup_count: usize = 0;
    for (mux.popup_mgr.popups.items, 0..) |p, i| {
        if (!p.visible) continue;
        popup_order[popup_count] = i;
        popup_count += 1;
    }
    var po_i: usize = 1;
    while (po_i < popup_count) : (po_i += 1) {
        const key = popup_order[po_i];
        const key_z = mux.popup_mgr.popups.items[key].z_index;
        var j = po_i;
        while (j > 0 and mux.popup_mgr.popups.items[popup_order[j - 1]].z_index > key_z) : (j -= 1) {
            popup_order[j] = popup_order[j - 1];
        }
        popup_order[j] = key;
    }

    for (popup_order[0..popup_count]) |popup_idx| {
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
        const panel_active = mux.popup_mgr.focused_popup_id == p.id;
        drawBorder(canvas, border_conn, total_cols, content_rows, p.rect, popup_border, if (panel_active) mux.focusMarker() else ' ', null, null);
        markBorderLayer(chrome_layer, chrome_panel_id, total_cols, content_rows, p.rect, popup_border, if (panel_active) chrome_layer_active_border else chrome_layer_inactive_border, p.id);

        const inner_x = p.rect.x + 1;
        const inner_y = p.rect.y + 1;
        const inner_w = p.rect.width - 2;
        const inner_h = p.rect.height - 2;
        if (inner_w == 0 or inner_h == 0) continue;

        drawText(canvas, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w);
        markTextLayer(chrome_layer, chrome_panel_id, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w, if (panel_active) chrome_layer_active_title else chrome_layer_inactive_title, p.id);
        if (p.show_controls and p.rect.width >= 10) {
            var controls_buf: [9]u8 = undefined;
            const control_chars = mux.windowControlChars();
            controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
            const controls = controls_buf[0..];
            const controls_w: u16 = @intCast(controls.len);
            const controls_x: u16 = p.rect.x + p.rect.width - controls_w - 1;
            drawText(canvas, total_cols, content_rows, controls_x, p.rect.y, controls, controls_w);
            markTextLayer(chrome_layer, chrome_panel_id, total_cols, content_rows, controls_x, p.rect.y, controls, controls_w, if (panel_active) chrome_layer_active_buttons else chrome_layer_inactive_buttons, p.id);
        }
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
    applyBorderGlyphs(canvas, border_conn, total_cols, content_rows, mux.borderGlyphs(), mux.focusMarker());

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
        var controls_buf: [9]u8 = undefined;
        const control_chars = mux.windowControlChars();
        controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
        const controls = controls_buf[0..];
        const controls_w: u16 = @intCast(controls.len);
        const title_max = if (r.width >= 10 and inner_w > controls_w) inner_w - controls_w else inner_w;
        drawTextOwnedMasked(canvas, total_cols, content_rows, inner_x, r.y, title, title_max, i, top_window_owner, popup_cover);
        if (r.width >= 10) {
            const controls_x: u16 = r.x + r.width - controls_w - 1;
            drawTextOwnedMasked(canvas, total_cols, content_rows, controls_x, r.y, controls, controls_w, i, top_window_owner, popup_cover);
        }
    }
    for (popup_order[0..popup_count]) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        if (p.rect.width < 2 or p.rect.height < 2) continue;
        const inner_x = p.rect.x + 1;
        const inner_w = p.rect.width - 2;
        if (inner_w == 0) continue;
        drawText(canvas, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w);
        if (p.show_controls and p.rect.width >= 10) {
            var controls_buf: [9]u8 = undefined;
            const control_chars = mux.windowControlChars();
            controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
            const controls = controls_buf[0..];
            const controls_w: u16 = @intCast(controls.len);
            const controls_x: u16 = p.rect.x + p.rect.width - controls_w - 1;
            drawText(canvas, total_cols, content_rows, controls_x, p.rect.y, controls, controls_w);
        }
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
                if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                    curr[row_off + x].style = s;
                    curr[row_off + x].styled = !s.default();
                }
                continue;
            }
            if (popup_overlay[row_off + x]) {
                curr[row_off + x] = plainCellFromCodepoint(canvas[start + x]);
                if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                    curr[row_off + x].style = s;
                    curr[row_off + x].styled = !s.default();
                }
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
            if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                curr[row_off + x].style = s;
                curr[row_off + x].styled = !s.default();
            }
        }
    }

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
    return switch (role) {
        chrome_layer_active_border => styles.active_border,
        chrome_layer_inactive_border => styles.inactive_border,
        chrome_layer_active_title => styles.active_title,
        chrome_layer_inactive_title => styles.inactive_title,
        chrome_layer_active_buttons => styles.active_buttons,
        chrome_layer_inactive_buttons => styles.inactive_buttons,
        else => null,
    };
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
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x, y0, role, 0);
        }
    }
    if (border.bottom) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const idx = y1 * cols + x;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x, y1, role, 0);
        }
    }
    if (border.left) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            const idx = y * cols + x0;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x0, y, role, 0);
        }
    }
    if (border.right) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            const idx = y * cols + x1;
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

fn glyphFromConn(bits: u8, glyphs: multiplexer.Multiplexer.BorderGlyphs) u21 {
    return switch (bits) {
        BorderConn.L | BorderConn.R => glyphs.horizontal,
        BorderConn.U | BorderConn.D => glyphs.vertical,
        BorderConn.D | BorderConn.R => glyphs.corner_tl,
        BorderConn.D | BorderConn.L => glyphs.corner_tr,
        BorderConn.U | BorderConn.R => glyphs.corner_bl,
        BorderConn.U | BorderConn.L => glyphs.corner_br,
        BorderConn.L | BorderConn.R | BorderConn.D => glyphs.tee_top,
        BorderConn.L | BorderConn.R | BorderConn.U => glyphs.tee_bottom,
        BorderConn.U | BorderConn.D | BorderConn.R => glyphs.tee_left,
        BorderConn.U | BorderConn.D | BorderConn.L => glyphs.tee_right,
        BorderConn.U | BorderConn.D | BorderConn.L | BorderConn.R => glyphs.cross,
        else => ' ',
    };
}

fn applyBorderGlyphs(
    canvas: []u21,
    conn: []const u8,
    cols: usize,
    rows: usize,
    glyphs: multiplexer.Multiplexer.BorderGlyphs,
    focus_marker: u8,
) void {
    _ = rows;
    var i: usize = 0;
    while (i < conn.len) : (i += 1) {
        const bits = conn[i];
        if (bits == 0) continue;
        // Keep focus marker on top border.
        if (canvas[i] == @as(u21, focus_marker)) continue;
        canvas[i] = glyphFromConn(bits, glyphs);
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
                break :blk try layout_plugin.PluginManagerLayoutEngine.init(allocator, plugins, cfg.layout_plugin);
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
    try writer.print("  layout_plugin={s}\n", .{cfg.layout_plugin orelse "(auto)"});
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

test "contentRect never overflows total terminal rows" {
    const testing = std.testing;

    const tiny = contentRect(.{ .cols = 80, .rows = 1 });
    try testing.expectEqual(@as(u16, 1), tiny.height);

    const short = contentRect(.{ .cols = 80, .rows = 3 });
    try testing.expectEqual(@as(u16, 3), short.height);

    const normal = contentRect(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(@as(u16, 21), normal.height);
}
