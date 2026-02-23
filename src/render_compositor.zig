const std = @import("std");
const layout = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");

pub fn frameTotalRows(size: anytype) usize {
    return size.rows;
}

pub fn fallbackCursorRow(content_rows: usize, footer_rows: usize) usize {
    return if (footer_rows > 0)
        content_rows + footer_rows
    else if (content_rows > 0)
        content_rows
    else
        1;
}

pub fn collectVisiblePopupOrder(
    allocator: std.mem.Allocator,
    mux: *const multiplexer.Multiplexer,
) ![]usize {
    var visible_count: usize = 0;
    for (mux.popup_mgr.popups.items) |p| {
        if (p.visible) visible_count += 1;
    }

    const order = try allocator.alloc(usize, visible_count);
    var out_i: usize = 0;
    for (mux.popup_mgr.popups.items, 0..) |p, i| {
        if (!p.visible) continue;
        order[out_i] = i;
        out_i += 1;
    }

    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const key = order[i];
        const key_z = mux.popup_mgr.popups.items[key].z_index;
        var j = i;
        while (j > 0 and mux.popup_mgr.popups.items[order[j - 1]].z_index > key_z) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = key;
    }

    return order;
}

pub fn markPopupOverlay(mask: []bool, cols: usize, rows: usize, r: layout.Rect) void {
    if (r.width == 0 or r.height == 0) return;
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = @min(@as(usize, r.x + r.width), cols);
    const y1: usize = @min(@as(usize, r.y + r.height), rows);
    if (x0 >= x1 or y0 >= y1) return;

    var x: usize = x0;
    while (x < x1) : (x += 1) {
        mask[y0 * cols + x] = true;
        mask[(y1 - 1) * cols + x] = true;
    }
    var y: usize = y0;
    while (y < y1) : (y += 1) {
        mask[y * cols + x0] = true;
        mask[y * cols + (x1 - 1)] = true;
    }
}

pub fn markRectOverlay(mask: []bool, cols: usize, rows: usize, r: layout.Rect) void {
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
            mask[y * cols + x] = true;
        }
    }
}

pub fn clearBorderConnInsideRect(conn: []u8, cols: usize, rows: usize, r: layout.Rect) void {
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

pub fn clearCanvasRect(canvas: []u21, cols: usize, rows: usize, r: layout.Rect) void {
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

pub fn clearBorderConnRect(conn: []u8, cols: usize, rows: usize, r: layout.Rect) void {
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

pub fn clearChromeLayerRect(layer: []u8, panel_ids: []u32, cols: usize, rows: usize, r: layout.Rect) void {
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
            const idx = y * cols + x;
            layer[idx] = 0;
            panel_ids[idx] = 0;
        }
    }
}

pub fn drawText(
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

pub fn drawTextOwnedMasked(
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

pub fn putCell(canvas: []u21, cols: usize, x: usize, y: usize, ch: u21) void {
    canvas[y * cols + x] = ch;
}
