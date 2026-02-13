const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const layout_native = @import("layout_native.zig");
const multiplexer = @import("multiplexer.zig");
const workspace = @import("workspace.zig");

const Terminal = ghostty_vt.Terminal;

const POC_ROWS: u16 = 12;
const POC_COLS: u16 = 36;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

    try printWorkspacePOC(out, alloc);
    try printMultiplexerPOC(out, alloc);
    try renderSideBySide(out, &left, &right);
    try out.flush();
}

fn printWorkspacePOC(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    var wm = workspace.WorkspaceManager.init(alloc, layout_native.NativeLayoutEngine.init());
    defer wm.deinit();

    _ = try wm.createTab("dev");
    _ = try wm.createTab("ops");

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
    try writer.writeByte('\n');
}

fn printMultiplexerPOC(writer: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    var mux = multiplexer.Multiplexer.init(alloc, layout_native.NativeLayoutEngine.init());
    defer mux.deinit();

    _ = try mux.createTab("dev");
    const win_id = try mux.createCommandWindow("cmd", &.{ "/bin/sh", "-c", "printf 'hello-from-multiplexer\\n'" });

    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        _ = try mux.pollOnce(30);
        const out = try mux.windowOutput(win_id);
        if (std.mem.indexOf(u8, out, "hello-from-multiplexer") != null) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const out = try mux.windowOutput(win_id);
    try writer.writeAll("multiplexer(poll-route):\n");
    try writer.print("  win {} bytes={}\n", .{ win_id, out.len });
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
