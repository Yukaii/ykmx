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

const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
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
        \\  ykwm                 Run the current POC flow
        \\  ykwm --benchmark [N] Run frame benchmark (default N=200)
        \\  ykwm --smoke-zmx [session]
        \\  ykwm --version
        \\  ykwm --help
        \\
    );
    try out.flush();
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
