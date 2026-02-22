const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const workspace = @import("workspace.zig");
const multiplexer = @import("multiplexer.zig");
const config = @import("config.zig");
const zmx = @import("zmx.zig");
const signal_mod = @import("signal.zig");
const status = @import("status.zig");
const runtime_layout = @import("runtime_layout.zig");

const Terminal = ghostty_vt.Terminal;
const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;

pub fn printZmxAndSignalPOC(writer: *std.Io.Writer, env: zmx.Env) !void {
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

pub fn printConfigPOC(writer: *std.Io.Writer, cfg: config.Config) !void {
    try writer.writeAll("config(startup):\n");
    try writer.print("  source={s}\n", .{cfg.source_path orelse "(defaults)"});
    try writer.print("  backend={s}\n", .{@tagName(cfg.layout_backend)});
    try writer.print("  default_layout={s}\n", .{@tagName(cfg.default_layout)});
    try writer.print("  layout_plugin={s}\n", .{cfg.layout_plugin orelse "(auto)"});
    try writer.print("  plugins_enabled={}\n\n", .{cfg.plugins_enabled});
}

pub fn printWorkspacePOC(writer: *std.Io.Writer, alloc: std.mem.Allocator, cfg: config.Config) !void {
    var wm = workspace.WorkspaceManager.init(alloc, try runtime_layout.pickLayoutEngine(alloc, cfg));
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

pub fn printMultiplexerPOC(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    cfg: config.Config,
    zmx_env: *const zmx.Env,
) !void {
    var mux = multiplexer.Multiplexer.init(alloc, try runtime_layout.pickLayoutEngine(alloc, cfg));
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

pub fn renderSideBySide(writer: *std.Io.Writer, left: *Terminal, right: *Terminal) !void {
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
