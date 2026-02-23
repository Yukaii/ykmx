const std = @import("std");
const runtime_cells = @import("runtime_cells.zig");
const runtime_render_types = @import("runtime_render_types.zig");

const c = @cImport({
    @cInclude("unistd.h");
});

pub const BgLeakResult = struct {
    frame_no: u64,
    opaque_cells: usize,
    leak_cells: usize,
};

pub fn logComposePopupSummary(
    frame_no: u64,
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
        .{ frame_no, popup_count, focused_popup_id orelse 0, cols, rows },
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

pub fn logComposeBgDebug(
    curr: []const runtime_render_types.RuntimeRenderCell,
    canvas: []const u21,
    cols: usize,
    rows: usize,
    popup_count: usize,
    popup_overlay: []const bool,
    popup_opaque_cover: []const bool,
    border_conn: []const u8,
    chrome_layer: []const u8,
    chrome_panel_id: []const u32,
    frame_counter: *u64,
) BgLeakResult {
    if (curr.len == 0 or popup_count == 0) {
        return .{ .frame_no = frame_counter.*, .opaque_cells = 0, .leak_cells = 0 };
    }

    var opaque_cells: usize = 0;
    var leak_cells: usize = 0;
    var sample_ids: [12]usize = undefined;
    var sample_count: usize = 0;

    var i: usize = 0;
    while (i < curr.len and i < popup_opaque_cover.len) : (i += 1) {
        if (!popup_opaque_cover[i]) continue;
        opaque_cells += 1;
        if (!runtime_cells.runtimeCellHasExplicitBg(curr[i])) {
            leak_cells += 1;
            if (sample_count < sample_ids.len) {
                sample_ids[sample_count] = i;
                sample_count += 1;
            }
        }
    }

    const frame_no = frame_counter.*;
    frame_counter.* += 1;

    if (leak_cells == 0 and (frame_no % 120) != 0) {
        return .{ .frame_no = frame_no, .opaque_cells = opaque_cells, .leak_cells = leak_cells };
    }

    var stderr_buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &stderr_buf,
        "ykmx compose-debug frame={} popups={} rows={} cols={} opaque_cells={} leak_cells={}\n",
        .{ frame_no, popup_count, rows, cols, opaque_cells, leak_cells },
    ) catch return .{ .frame_no = frame_no, .opaque_cells = opaque_cells, .leak_cells = leak_cells };
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
                runtime_cells.runtimeCellBgTag(cell),
                @as(u8, @intFromBool(idx < popup_overlay.len and popup_overlay[idx])),
                @as(u8, @intFromBool(idx < popup_opaque_cover.len and popup_opaque_cover[idx])),
                if (idx < border_conn.len) border_conn[idx] else 0,
                if (idx < chrome_layer.len) chrome_layer[idx] else 0,
                if (idx < chrome_panel_id.len) chrome_panel_id[idx] else 0,
            },
        ) catch continue;
        _ = c.write(c.STDERR_FILENO, line.ptr, line.len);
    }

    return .{ .frame_no = frame_no, .opaque_cells = opaque_cells, .leak_cells = leak_cells };
}
