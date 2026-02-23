const layout = @import("layout.zig");
const multiplexer = @import("multiplexer.zig");
const render_compositor = @import("render_compositor.zig");
const ghostty_vt = @import("ghostty-vt");
const runtime_cells = @import("runtime_cells.zig");
const runtime_render_types = @import("runtime_render_types.zig");

pub const BorderMask = struct {
    left: bool,
    right: bool,
    top: bool,
    bottom: bool,
};

pub const ContentInsets = struct {
    left: u16,
    right: u16,
    top: u16,
    bottom: u16,
};

pub const chrome_layer_none: u8 = 0;
pub const chrome_layer_active_border: u8 = 1;
pub const chrome_layer_inactive_border: u8 = 2;
pub const chrome_layer_active_title: u8 = 3;
pub const chrome_layer_inactive_title: u8 = 4;
pub const chrome_layer_active_buttons: u8 = 5;
pub const chrome_layer_inactive_buttons: u8 = 6;

const BorderConn = struct {
    pub const U: u8 = 1 << 0;
    pub const D: u8 = 1 << 1;
    pub const L: u8 = 1 << 2;
    pub const R: u8 = 1 << 3;
};

pub fn computeContentInsets(
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

pub fn computeBorderMask(rects: []const layout.Rect, idx: usize, r: layout.Rect, content: layout.Rect) BorderMask {
    _ = content;
    return .{
        .left = true,
        .top = true,
        .right = !hasNeighborOnRight(rects, idx, r),
        .bottom = !hasNeighborOnBottom(rects, idx, r),
    };
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

pub fn drawBorder(
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
        if (cellOwnedBy(idx, owner_idx, top_window_owner)) render_compositor.putCell(canvas, cols, x0 + 1, y0, marker);
    }
}

pub fn applyBorderGlyphs(
    canvas: []u21,
    conn: []const u8,
    cols: usize,
    rows: usize,
    glyphs: multiplexer.Multiplexer.BorderGlyphs,
    focus_marker: u8,
) void {
    _ = cols;
    _ = rows;
    var i: usize = 0;
    while (i < conn.len) : (i += 1) {
        const bits = conn[i];
        if (bits == 0) continue;
        const cp = glyphFromConn(bits, glyphs);
        if (cp == ' ' and canvas[i] == focus_marker) continue;
        canvas[i] = cp;
    }
}

pub fn drawPopupBorderDirect(
    canvas: []u21,
    cols: usize,
    rows: usize,
    r: layout.Rect,
    glyphs: multiplexer.Multiplexer.BorderGlyphs,
    focus_marker: ?u8,
) void {
    if (r.width < 2 or r.height < 2) return;
    const x0: usize = r.x;
    const y0: usize = r.y;
    const x1: usize = x0 + r.width - 1;
    const y1: usize = y0 + r.height - 1;
    if (x1 >= cols or y1 >= rows) return;

    render_compositor.putCell(canvas, cols, x0, y0, glyphs.corner_tl);
    render_compositor.putCell(canvas, cols, x1, y0, glyphs.corner_tr);
    render_compositor.putCell(canvas, cols, x0, y1, glyphs.corner_bl);
    render_compositor.putCell(canvas, cols, x1, y1, glyphs.corner_br);

    var x = x0 + 1;
    while (x < x1) : (x += 1) {
        render_compositor.putCell(canvas, cols, x, y0, glyphs.horizontal);
        render_compositor.putCell(canvas, cols, x, y1, glyphs.horizontal);
    }
    var y = y0 + 1;
    while (y < y1) : (y += 1) {
        render_compositor.putCell(canvas, cols, x0, y, glyphs.vertical);
        render_compositor.putCell(canvas, cols, x1, y, glyphs.vertical);
    }

    if (focus_marker) |m| {
        if (x0 + 1 < cols) render_compositor.putCell(canvas, cols, x0 + 1, y0, m);
    }
}

pub fn resolveChromeStyleAt(
    mux: *const multiplexer.Multiplexer,
    role: u8,
    panel_id: u32,
) ?ghostty_vt.Style {
    if (role == chrome_layer_none) return null;
    const styles = if (panel_id != 0) (mux.panelChromeStylesById(panel_id) orelse mux.chromeStyles()) else mux.chromeStyles();
    const base = switch (role) {
        chrome_layer_active_border => styles.active_border,
        chrome_layer_inactive_border => styles.inactive_border,
        chrome_layer_active_title => styles.active_title,
        chrome_layer_inactive_title => styles.inactive_title,
        chrome_layer_active_buttons => styles.active_buttons,
        chrome_layer_inactive_buttons => styles.inactive_buttons,
        else => null,
    };
    if (base) |style| return runtime_cells.enforceOpaquePanelChromeBg(style, panel_id);
    if (panel_id != 0) {
        var fallback: ghostty_vt.Style = .{};
        fallback.bg_color = .{ .palette = 0 };
        return fallback;
    }
    return null;
}

pub fn markLayerCell(
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

pub fn markBorderLayer(
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

pub fn markBorderLayerOwned(
    layer: []u8,
    panel_ids: []u32,
    cols: usize,
    rows: usize,
    r: layout.Rect,
    border: BorderMask,
    role: u8,
    owner_idx: usize,
    top_window_owner: []const i32,
    popup_opaque_cover: []const bool,
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
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x, y0, role, 0);
        }
    }
    if (border.bottom) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const idx = y1 * cols + x;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x, y1, role, 0);
        }
    }
    if (border.left) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            const idx = y * cols + x0;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x0, y, role, 0);
        }
    }
    if (border.right) {
        var y = y0;
        while (y <= y1) : (y += 1) {
            const idx = y * cols + x1;
            if (popup_opaque_cover[idx]) continue;
            if (top_window_owner[idx] == owner) markLayerCell(layer, panel_ids, cols, rows, x1, y, role, 0);
        }
    }
}

pub fn markTextLayer(
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

pub fn markTextOwnedMaskedLayer(
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

pub fn composeContentCells(
    comptime paneCellAtFn: anytype,
    mux: *multiplexer.Multiplexer,
    panes: []const runtime_render_types.PaneRenderRef,
    total_cols: usize,
    content_rows: usize,
    canvas: []const u21,
    border_conn: []const u8,
    chrome_layer: []const u8,
    chrome_panel_id: []const u32,
    popup_overlay: []const bool,
    popup_opaque_cover: []const bool,
    curr: []runtime_render_types.RuntimeRenderCell,
) void {
    var row: usize = 0;
    while (row < content_rows) : (row += 1) {
        const row_off = row * total_cols;
        const start = row * total_cols;
        var x: usize = 0;
        while (x < total_cols) : (x += 1) {
            if (popup_overlay[row_off + x]) {
                curr[row_off + x] = runtime_cells.plainCellFromCodepoint(canvas[start + x]);
                if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                    curr[row_off + x].style = s;
                    curr[row_off + x].styled = !s.default();
                }
                continue;
            }
            if (border_conn[row_off + x] != 0) {
                curr[row_off + x] = runtime_cells.plainCellFromCodepoint(canvas[start + x]);
                if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                    curr[row_off + x].style = s;
                    curr[row_off + x].styled = !s.default();
                }
                continue;
            }
            const pane_cell = paneCellAtFn(panes, x, row);
            if (pane_cell) |pc| {
                if (pc.skip_draw) {
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
                curr[row_off + x] = runtime_cells.plainCellFromCodepoint(canvas[start + x]);
            }
            if (resolveChromeStyleAt(mux, chrome_layer[row_off + x], chrome_panel_id[row_off + x])) |s| {
                curr[row_off + x].style = s;
                curr[row_off + x].styled = !s.default();
            }
            if (popup_opaque_cover[row_off + x]) {
                runtime_cells.enforceOpaqueRuntimeCellBg(&curr[row_off + x]);
            }
        }
    }
}
