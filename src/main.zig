const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
const layout_opentui = @import("layout_opentui.zig");
const multiplexer = @import("multiplexer.zig");
const signal_mod = @import("signal.zig");
const workspace = @import("workspace.zig");
const zmx = @import("zmx.zig");
const config = @import("config.zig");
const status = @import("status.zig");
const benchmark = @import("benchmark.zig");

const Terminal = ghostty_vt.Terminal;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("fcntl.h");
});

const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;

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
            try out.writeAll("ykwm 0.1.0-dev\n");
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
        if (std.mem.eql(u8, args[1], "--smoke-zmx")) {
            const session = if (args.len > 2) args[2] else "ykwm-smoke";
            const ok = try zmx.smokeAttachRoundTrip(alloc, session, "ykwm-zmx-smoke");
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

    try out.writeAll("ykwm phase-0: dual VT side-by-side compose\n\n");

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
        \\ykwm - experimental terminal multiplexer
        \\
        \\Usage:
        \\  ykwm                 Run interactive runtime loop
        \\  ykwm --poc           Run verbose development POC output
        \\  ykwm --benchmark [N] Run frame benchmark (default N=200)
        \\  ykwm --smoke-zmx [session]
        \\  ykwm --version
        \\  ykwm --help
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

    var mux = multiplexer.Multiplexer.init(allocator, pickLayoutEngine(cfg.layout_backend));
    defer mux.deinit();

    _ = try mux.createTab("main");
    try mux.workspace_mgr.setActiveLayoutDefaults(cfg.default_layout, cfg.master_count, cfg.master_ratio_permille, cfg.gap);
    _ = try mux.createShellWindow("shell-1");
    _ = try mux.createShellWindow("shell-2");

    var term = try RuntimeTerminal.enter();
    defer term.leave();

    var last_size = getTerminalSize();
    var last_content = contentRect(last_size);
    _ = mux.resizeActiveWindowsToLayout(last_content) catch {};

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.print(
        "ykwm runtime loop started (session={s})\r\n",
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

        if (tick_result.detach_requested) {
            _ = env.detachCurrentSession(allocator) catch {};
        }
        if (tick_result.should_shutdown) break;

        if (snap.sigwinch) force_redraw = true;
        if (force_redraw or tick_result.redraw) {
            try renderRuntimeFrame(out, allocator, &mux, size, content);
            try out.flush();
            force_redraw = false;
        }
    }
}

const RuntimeTerminal = struct {
    had_termios: bool = false,
    original_termios: c.struct_termios = undefined,
    original_flags: c_int = 0,

    fn enter() !RuntimeTerminal {
        var rt: RuntimeTerminal = .{};

        rt.original_flags = c.fcntl(c.STDIN_FILENO, c.F_GETFL, @as(c_int, 0));
        if (rt.original_flags >= 0) {
            _ = c.fcntl(c.STDIN_FILENO, c.F_SETFL, rt.original_flags | c.O_NONBLOCK);
        }

        var termios_state: c.struct_termios = undefined;
        if (c.tcgetattr(c.STDIN_FILENO, &termios_state) == 0) {
            rt.had_termios = true;
            rt.original_termios = termios_state;
            var raw = termios_state;
            raw.c_lflag &= ~@as(c_uint, @intCast(c.ECHO | c.ICANON));
            raw.c_iflag &= ~@as(c_uint, @intCast(c.IXON | c.ICRNL));
            raw.c_oflag &= ~@as(c_uint, @intCast(c.OPOST));
            raw.c_cc[c.VMIN] = 0;
            raw.c_cc[c.VTIME] = 0;
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
        }

        // Enter alternate screen and hide cursor.
        _ = c.write(c.STDOUT_FILENO, "\x1b[?1049h\x1b[?25l", 14);
        return rt;
    }

    fn leave(self: *RuntimeTerminal) void {
        // Show cursor and leave alternate screen.
        _ = c.write(c.STDOUT_FILENO, "\x1b[?25h\x1b[?1049l", 14);
        if (self.had_termios) {
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &self.original_termios);
        }
        if (self.original_flags >= 0) {
            _ = c.fcntl(c.STDIN_FILENO, c.F_SETFL, self.original_flags);
        }
    }
};

const RuntimeSize = struct {
    cols: u16,
    rows: u16,
};

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
    // Reserve two lines at bottom for tab + status bars.
    const usable_rows: u16 = if (size.rows > 3) size.rows - 2 else 1;
    return .{ .x = 0, .y = 0, .width = size.cols, .height = usable_rows };
}

fn readStdinNonBlocking(buf: []u8) !usize {
    return std.posix.read(c.STDIN_FILENO, buf);
}

fn renderRuntimeFrame(
    out: *std.Io.Writer,
    allocator: std.mem.Allocator,
    mux: *multiplexer.Multiplexer,
    size: RuntimeSize,
    content: layout.Rect,
) !void {
    const total_cols: usize = size.cols;
    const content_rows: usize = content.height;
    const canvas_len = total_cols * content_rows;
    var canvas = try allocator.alloc(u8, canvas_len);
    defer allocator.free(canvas);
    @memset(canvas, ' ');

    const rects = try mux.computeActiveLayout(content);
    defer allocator.free(rects);
    const tab = try mux.workspace_mgr.activeTab();
    const n = @min(rects.len, tab.windows.items.len);

    for (rects[0..n], 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        drawBorder(canvas, total_cols, content_rows, r, if (tab.focused_index == i) '*' else ' ');
        const inner_w = r.width - 2;
        const inner_h = r.height - 2;
        if (inner_w == 0 or inner_h == 0) continue;

        const title = tab.windows.items[i].title;
        drawText(canvas, total_cols, content_rows, r.x + 1, r.y, title, inner_w);

        const output = mux.windowOutput(tab.windows.items[i].id) catch "";
        try drawPaneOutput(allocator, canvas, total_cols, content_rows, r, output);
    }

    const tab_line = try status.renderTabBar(allocator, &mux.workspace_mgr);
    defer allocator.free(tab_line);
    const status_line = try status.renderStatusBarWithScroll(allocator, &mux.workspace_mgr, mux.focusedScrollOffset());
    defer allocator.free(status_line);

    try writeAllBlocking(out, "\x1b[2J");
    var row: usize = 0;
    while (row < content_rows) : (row += 1) {
        const start = row * total_cols;
        try writeFmtBlocking(out, "\x1b[{};1H", .{row + 1});
        try writeClippedLine(out, canvas[start .. start + total_cols], total_cols);
    }
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 1});
    try writeClippedLine(out, tab_line, total_cols);
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 2});
    try writeClippedLine(out, status_line, total_cols);
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 2});
}

fn drawBorder(canvas: []u8, cols: usize, rows: usize, r: layout.Rect, marker: u8) void {
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x1 >= cols or y1 >= rows) return;

    putCell(canvas, cols, x0, y0, '+');
    putCell(canvas, cols, x1, y0, '+');
    putCell(canvas, cols, x0, y1, '+');
    putCell(canvas, cols, x1, y1, '+');

    var x = x0 + 1;
    while (x < x1) : (x += 1) {
        putCell(canvas, cols, x, y0, '-');
        putCell(canvas, cols, x, y1, '-');
    }
    var y = y0 + 1;
    while (y < y1) : (y += 1) {
        putCell(canvas, cols, x0, y, '|');
        putCell(canvas, cols, x1, y, '|');
    }
    if (x0 + 1 < cols) putCell(canvas, cols, x0 + 1, y0, marker);
}

fn drawPaneOutput(
    allocator: std.mem.Allocator,
    canvas: []u8,
    cols: usize,
    rows: usize,
    r: layout.Rect,
    bytes: []const u8,
) !void {
    const inner_x: usize = r.x + 1;
    const inner_y: usize = r.y + 1;
    const inner_w: usize = r.width - 2;
    const inner_h: usize = r.height - 2;
    if (inner_w == 0 or inner_h == 0) return;

    const filtered = try filterPrintable(allocator, bytes);
    defer allocator.free(filtered);

    var total_lines: usize = 0;
    var count_it = std.mem.splitScalar(u8, filtered, '\n');
    while (count_it.next()) |_| total_lines += 1;
    const skip = total_lines -| inner_h;

    var line_idx: usize = 0;
    var draw_idx: usize = 0;
    var it = std.mem.splitScalar(u8, filtered, '\n');
    while (it.next()) |line| : (line_idx += 1) {
        if (line_idx < skip) continue;
        if (draw_idx >= inner_h) break;
        drawText(canvas, cols, rows, @intCast(inner_x), @intCast(inner_y + draw_idx), line, @intCast(inner_w));
        draw_idx += 1;
    }
}

fn filterPrintable(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (bytes) |b| {
        if (b == '\n' or b == '\t' or (b >= 32 and b < 127)) {
            try out.append(allocator, b);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn drawText(
    canvas: []u8,
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

fn putCell(canvas: []u8, cols: usize, x: usize, y: usize, ch: u8) void {
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

fn writeFmtBlocking(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    try writeAllBlocking(out, text);
}

fn pickLayoutEngine(backend: config.LayoutBackend) layout.LayoutEngine {
    return switch (backend) {
        .native => layout_native.NativeLayoutEngine.init(),
        .opentui => layout_opentui.OpenTUILayoutEngine.init(),
    };
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
    var wm = workspace.WorkspaceManager.init(alloc, pickLayoutEngine(cfg.layout_backend));
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
    var mux = multiplexer.Multiplexer.init(alloc, pickLayoutEngine(cfg.layout_backend));
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
    const status_line = try status.renderStatusBarWithScroll(alloc, &mux.workspace_mgr, focused_scroll);
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
