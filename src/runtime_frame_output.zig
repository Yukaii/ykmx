const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const runtime_output = @import("runtime_output.zig");
const runtime_render_types = @import("runtime_render_types.zig");
const runtime_cells = @import("runtime_cells.zig");
const runtime_pane_rendering = @import("runtime_pane_rendering.zig");

const RuntimeRenderCell = runtime_render_types.RuntimeRenderCell;
const RuntimeFrameCache = runtime_render_types.RuntimeFrameCache;
const writeClippedLine = runtime_output.writeClippedLine;
const writeAllBlocking = runtime_output.writeAllBlocking;
const writeFmtBlocking = runtime_output.writeFmtBlocking;
const renderCellEqual = runtime_cells.renderCellEqual;
const isSafeRunCell = runtime_cells.isSafeRunCell;
const fillPlainLine = runtime_pane_rendering.fillPlainLine;
const writeStyle = runtime_pane_rendering.writeStyle;

pub fn composeFooterRows(
    curr: []RuntimeRenderCell,
    total_cols: usize,
    content_rows: usize,
    total_rows: usize,
    minimized_line: []const u8,
    tab_line: []const u8,
    status_line: []const u8,
) void {
    const footer_rows = total_rows - content_rows;
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

pub fn writeFrameToTerminal(
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
