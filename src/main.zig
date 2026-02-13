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
    var vt_state = RuntimeVtState.init(allocator);
    defer vt_state.deinit();

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
            try renderRuntimeFrame(out, allocator, &mux, &vt_state, size, content);
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
            raw.c_lflag &= ~@as(c_uint, @intCast(c.ECHO | c.ICANON | c.ISIG));
            raw.c_iflag &= ~@as(c_uint, @intCast(c.IXON | c.ICRNL));
            raw.c_oflag &= ~@as(c_uint, @intCast(c.OPOST));
            raw.c_cc[c.VMIN] = 0;
            raw.c_cc[c.VTIME] = 0;
            _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw);
        }

        // Enter alternate screen, disable autowrap for compositor draws, hide cursor.
        _ = c.write(c.STDOUT_FILENO, "\x1b[?1049h\x1b[?7l\x1b[?25l", 20);
        return rt;
    }

    fn leave(self: *RuntimeTerminal) void {
        // Restore autowrap, show cursor, leave alternate screen.
        _ = c.write(c.STDOUT_FILENO, "\x1b[?7h\x1b[?25h\x1b[?1049l", 20);
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

const PaneRenderRef = struct {
    content_x: u16,
    content_y: u16,
    content_w: u16,
    content_h: u16,
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
                    .max_scrollback = 5000,
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

        if (wv.consumed_bytes > output.len) wv.consumed_bytes = 0;
        if (output.len > wv.consumed_bytes) {
            var stream = wv.term.vtStream();
            try stream.nextSlice(output[wv.consumed_bytes..]);
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
    vt_state: *RuntimeVtState,
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
    var active_ids = try allocator.alloc(u32, n);
    defer allocator.free(active_ids);
    var panes = try allocator.alloc(PaneRenderRef, n);
    defer allocator.free(panes);
    var pane_count: usize = 0;
    var focused_cursor_abs: ?struct { row: usize, col: usize } = null;

    for (rects[0..n], 0..) |r, i| {
        active_ids[i] = tab.windows.items[i].id;
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects[0..n], i, r, content);
        drawBorder(canvas, total_cols, content_rows, r, border, if (tab.focused_index == i) '*' else ' ');
        const inner_x = r.x + (if (border.left) @as(u16, 1) else @as(u16, 0));
        const inner_y = r.y + (if (border.top) @as(u16, 1) else @as(u16, 0));
        const inner_w = r.width - (if (border.left) @as(u16, 1) else @as(u16, 0)) - (if (border.right) @as(u16, 1) else @as(u16, 0));
        const inner_h = r.height - (if (border.top) @as(u16, 1) else @as(u16, 0)) - (if (border.bottom) @as(u16, 1) else @as(u16, 0));
        if (inner_w == 0 or inner_h == 0) continue;

        const title = tab.windows.items[i].title;
        drawText(canvas, total_cols, content_rows, inner_x, r.y, title, inner_w);

        const window_id = tab.windows.items[i].id;
        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        panes[pane_count] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .term = &wv.term,
        };
        pane_count += 1;

        if (tab.focused_index == i) {
            const cursor = wv.term.screens.active.cursor;
            const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
            const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
            focused_cursor_abs = .{
                .row = @as(usize, inner_y) + cy + 1,
                .col = @as(usize, inner_x) + cx + 1,
            };
        }
    }
    try vt_state.prune(active_ids);

    const tab_line = try status.renderTabBar(allocator, &mux.workspace_mgr);
    defer allocator.free(tab_line);
    const status_line = try status.renderStatusBarWithScroll(allocator, &mux.workspace_mgr, mux.focusedScrollOffset());
    defer allocator.free(status_line);

    try writeAllBlocking(out, "\x1b[2J");
    var row: usize = 0;
    while (row < content_rows) : (row += 1) {
        const start = row * total_cols;
        try writeFmtBlocking(out, "\x1b[{};1H", .{row + 1});
        try writeStyledRow(out, canvas[start .. start + total_cols], total_cols, row, panes[0..pane_count]);
    }
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 1});
    try writeAllBlocking(out, "\x1b[0m");
    try writeClippedLine(out, tab_line, total_cols);
    try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 2});
    try writeClippedLine(out, status_line, total_cols);
    if (focused_cursor_abs) |p| {
        try writeFmtBlocking(out, "\x1b[{};{}H", .{ p.row, p.col });
    } else {
        try writeFmtBlocking(out, "\x1b[{};1H", .{content_rows + 2});
    }
    try writeAllBlocking(out, "\x1b[?25h");
}

const BorderMask = struct {
    left: bool,
    right: bool,
    top: bool,
    bottom: bool,
};

fn computeBorderMask(rects: []const layout.Rect, idx: usize, r: layout.Rect, content: layout.Rect) BorderMask {
    _ = rects;
    _ = idx;
    return .{
        // Draw left/top for all panes; right/bottom only on container edge.
        // This keeps exactly one separator at shared boundaries.
        .left = true,
        .top = true,
        .right = (r.x + r.width == content.x + content.width),
        .bottom = (r.y + r.height == content.y + content.height),
    };
}

fn drawBorder(canvas: []u8, cols: usize, rows: usize, r: layout.Rect, border: BorderMask, marker: u8) void {
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x1 >= cols or y1 >= rows) return;

    if (border.left and border.top) putCell(canvas, cols, x0, y0, '+');
    if (border.right and border.top) putCell(canvas, cols, x1, y0, '+');
    if (border.left and border.bottom) putCell(canvas, cols, x0, y1, '+');
    if (border.right and border.bottom) putCell(canvas, cols, x1, y1, '+');

    if (border.top) {
        var x = x0 + 1;
        while (x < x1) : (x += 1) putCell(canvas, cols, x, y0, '-');
    }
    if (border.bottom) {
        var x = x0 + 1;
        while (x < x1) : (x += 1) putCell(canvas, cols, x, y1, '-');
    }
    if (border.left) {
        var y = y0 + 1;
        while (y < y1) : (y += 1) putCell(canvas, cols, x0, y, '|');
    }
    if (border.right) {
        var y = y0 + 1;
        while (y < y1) : (y += 1) putCell(canvas, cols, x1, y, '|');
    }
    if (border.top and x0 + 1 < cols) putCell(canvas, cols, x0 + 1, y0, marker);
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
    for (panes) |pane| {
        const inner_x0: usize = pane.content_x;
        const inner_y0: usize = pane.content_y;
        const inner_x1: usize = pane.content_x + pane.content_w;
        const inner_y1: usize = pane.content_y + pane.content_h;
        if (x < inner_x0 or x >= inner_x1 or y < inner_y0 or y >= inner_y1) continue;

        const local_x: usize = x - inner_x0;
        const local_y: usize = y - inner_y0;
        const maybe_cell = pane.term.screens.active.pages.getCell(.{
            .active = .{
                .x = @intCast(local_x),
                .y = @intCast(local_y),
            },
        }) orelse return .{
            .text = [_]u8{ ' ' } ++ ([_]u8{0} ** 31),
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
