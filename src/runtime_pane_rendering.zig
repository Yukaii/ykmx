const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const runtime_output = @import("runtime_output.zig");
const runtime_render_types = @import("runtime_render_types.zig");

const RuntimeRenderCell = runtime_render_types.RuntimeRenderCell;
const PaneRenderRef = runtime_render_types.PaneRenderRef;
const PaneRenderCell = runtime_render_types.PaneRenderCell;

pub fn writeStyle(out: *std.Io.Writer, style: ghostty_vt.Style) !void {
    var buf: [160]u8 = undefined;
    const sgr = try std.fmt.bufPrint(&buf, "{f}", .{style.formatterVt()});
    try runtime_output.writeAllBlocking(out, sgr);
}

pub fn fillPlainLine(dst: []RuntimeRenderCell, line: []const u8) void {
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

pub fn writeStyledRow(
    out: *std.Io.Writer,
    canvas_row: []const u8,
    total_cols: usize,
    row: usize,
    panes: []const PaneRenderRef,
) !void {
    var active_style: ?ghostty_vt.Style = null;
    var x: usize = 0;
    while (x < total_cols) : (x += 1) {
        try runtime_output.writeFmtBlocking(out, "\x1b[{};{}H", .{ row + 1, x + 1 });
        const pane_cell = paneCellAt(panes, x, row);
        if (pane_cell) |pc| {
            if (pc.skip_draw) continue;
            if (pc.style.default()) {
                if (active_style != null) {
                    try runtime_output.writeAllBlocking(out, "\x1b[0m");
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
            try runtime_output.writeAllBlocking(out, pc.text[0..pc.text_len]);
            continue;
        }

        if (active_style != null) {
            try runtime_output.writeAllBlocking(out, "\x1b[0m");
            active_style = null;
        }
        try runtime_output.writeByteBlocking(out, canvas_row[x]);
    }
    if (active_style != null) try runtime_output.writeAllBlocking(out, "\x1b[0m");
}

pub fn paneCellAt(
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
                        return .{ .text = [_]u8{ch} ++ ([_]u8{0} ** 31), .text_len = 1, .style = .{} };
                    }
                }
            }
            return .{ .text = [_]u8{' '} ++ ([_]u8{0} ** 31), .text_len = 1, .style = .{} };
        }

        const off = @min(pane.scroll_offset, total_rows);
        const start_screen_row: usize = if (total_rows > active_rows + off)
            total_rows - active_rows - off
        else
            0;
        const source_y = start_screen_row + local_y;
        if (source_y > std.math.maxInt(u32)) {
            return .{ .text = [_]u8{' '} ++ ([_]u8{0} ** 31), .text_len = 1, .style = .{} };
        }
        const maybe_cell = pane.term.screens.active.pages.getCell(.{ .screen = .{ .x = @intCast(local_x), .y = @intCast(source_y) } }) orelse {
            return .{ .text = [_]u8{' '} ++ ([_]u8{0} ** 31), .text_len = 1, .style = .{} };
        };

        if (maybe_cell.cell.wide == .spacer_tail) {
            return .{ .style = .{}, .skip_draw = true };
        }

        const cp_raw = maybe_cell.cell.codepoint();
        const cp: u21 = if (cp_raw >= 32) cp_raw else ' ';
        var rendered: PaneRenderCell = .{ .style = .{} };
        rendered.text_len = @intCast(runtime_output.encodeCodepoint(rendered.text[0..], cp));
        if (rendered.text_len == 0) {
            rendered.text[0] = '?';
            rendered.text_len = 1;
        }
        if (maybe_cell.cell.content_tag == .codepoint_grapheme) {
            if (maybe_cell.node.data.lookupGrapheme(maybe_cell.cell)) |extra_cps| {
                for (extra_cps) |extra_cp_raw| {
                    const extra_cp: u21 = if (extra_cp_raw >= 32) extra_cp_raw else ' ';
                    const used = rendered.text_len;
                    const wrote = runtime_output.encodeCodepoint(rendered.text[used..], extra_cp);
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
