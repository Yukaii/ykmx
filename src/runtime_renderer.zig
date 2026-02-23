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

pub fn composeBaseWindows(
    mux: *multiplexer.Multiplexer,
    vt_state: anytype,
    tab: anytype,
    rects: []const layout.Rect,
    content: layout.Rect,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    top_window_owner: []const i32,
    popup_overlay: []const bool,
    popup_opaque_cover: []const bool,
    panes: []runtime_render_types.PaneRenderRef,
    pane_count: *usize,
    focused_cursor_abs: anytype,
) !void {
    for (rects, 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects, i, r, content);
        const insets = computeContentInsets(rects, i, r, border);
        const is_active = tab.focused_index == i;
        drawBorder(canvas, border_conn, total_cols, content_rows, r, border, if (is_active) mux.focusMarker() else ' ', i, top_window_owner);
        markBorderLayerOwned(chrome_layer, chrome_panel_id, total_cols, content_rows, r, border, if (is_active) chrome_layer_active_border else chrome_layer_inactive_border, i, top_window_owner, popup_opaque_cover);
        const inner_x = r.x + insets.left;
        const inner_y = r.y + insets.top;
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        const inner_h = if (r.height > insets.top + insets.bottom) r.height - insets.top - insets.bottom else 0;
        if (inner_w == 0 or inner_h == 0) continue;
        renderOwnedWindowTitleBar(
            mux,
            tab.windows.items[i].title,
            r,
            inner_w,
            i,
            is_active,
            total_cols,
            content_rows,
            canvas,
            chrome_layer,
            chrome_panel_id,
            top_window_owner,
            popup_overlay,
        );

        const window_id = tab.windows.items[i].id;
        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        const pane_scroll_offset = mux.windowScrollOffset(window_id) orelse 0;
        panes[pane_count.*] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .scroll_offset = pane_scroll_offset,
            .scrollback = mux.scrollbackBuffer(window_id),
            .term = &wv.term,
        };
        pane_count.* += 1;

        if (tab.focused_index == i) {
            if (pane_scroll_offset > 0) {
                const sel_x = @min(mux.selectionCursorX(window_id), @as(usize, inner_w - 1));
                const sel_y = @min(mux.selectionCursorY(window_id, inner_h), @as(usize, inner_h - 1));
                focused_cursor_abs.* = .{
                    .row = @as(usize, inner_y) + sel_y + 1,
                    .col = @as(usize, inner_x) + sel_x + 1,
                };
            } else {
                const cursor = wv.term.screens.active.cursor;
                const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
                const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
                focused_cursor_abs.* = .{
                    .row = @as(usize, inner_y) + cy + 1,
                    .col = @as(usize, inner_x) + cx + 1,
                };
            }
        }
    }
}

pub fn composePopups(
    mux: *multiplexer.Multiplexer,
    vt_state: anytype,
    popup_order: []const usize,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    panes: []runtime_render_types.PaneRenderRef,
    pane_count: *usize,
    focused_cursor_abs: anytype,
) !void {
    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        const window_id = p.window_id orelse continue;
        if (window_id == 0) continue;
        if (p.rect.width < 2 or p.rect.height < 2) continue;

        const inner_h = renderPopupChrome(
            mux,
            p,
            total_cols,
            content_rows,
            canvas,
            border_conn,
            chrome_layer,
            chrome_panel_id,
            true,
        );
        const inner_x = p.rect.x + 1;
        const inner_y = p.rect.y + 1;
        const inner_w = p.rect.width - 2;
        if (inner_w == 0 or inner_h == 0) continue;
        render_compositor.clearBorderConnInsideRect(border_conn, total_cols, content_rows, p.rect);

        const output = mux.windowOutput(window_id) catch "";
        const wv = try vt_state.syncWindow(window_id, inner_w, inner_h, output);
        const pane_scroll_offset = mux.windowScrollOffset(window_id) orelse 0;
        panes[pane_count.*] = .{
            .content_x = inner_x,
            .content_y = inner_y,
            .content_w = inner_w,
            .content_h = inner_h,
            .scroll_offset = pane_scroll_offset,
            .scrollback = mux.scrollbackBuffer(window_id),
            .term = &wv.term,
        };
        pane_count.* += 1;

        if (mux.popup_mgr.focused_popup_id == p.id) {
            const cursor = wv.term.screens.active.cursor;
            const cx: usize = @min(@as(usize, @intCast(cursor.x)), @as(usize, inner_w - 1));
            const cy: usize = @min(@as(usize, @intCast(cursor.y)), @as(usize, inner_h - 1));
            focused_cursor_abs.* = .{
                .row = @as(usize, inner_y) + cy + 1,
                .col = @as(usize, inner_x) + cx + 1,
            };
        }
    }
}

pub fn repaintChromeAfterBorderPass(
    mux: *multiplexer.Multiplexer,
    tab: anytype,
    rects: []const layout.Rect,
    content: layout.Rect,
    popup_order: []const usize,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    top_window_owner: []const i32,
    popup_cover: []const bool,
) void {
    for (rects, 0..) |r, i| {
        if (r.width < 2 or r.height < 2) continue;
        const border = computeBorderMask(rects, i, r, content);
        const insets = computeContentInsets(rects, i, r, border);
        const inner_w = if (r.width > insets.left + insets.right) r.width - insets.left - insets.right else 0;
        if (inner_w == 0) continue;

        renderOwnedWindowTitleBar(
            mux,
            tab.windows.items[i].title,
            r,
            inner_w,
            i,
            tab.focused_index == i,
            total_cols,
            content_rows,
            canvas,
            null,
            null,
            top_window_owner,
            popup_cover,
        );
    }

    for (popup_order) |popup_idx| {
        const p = mux.popup_mgr.popups.items[popup_idx];
        if (p.rect.width < 2 or p.rect.height < 2) continue;
        _ = renderPopupChrome(
            mux,
            p,
            total_cols,
            content_rows,
            canvas,
            border_conn,
            chrome_layer,
            chrome_panel_id,
            true,
        );
    }
}

pub fn renderOwnedWindowTitleBar(
    mux: *const multiplexer.Multiplexer,
    title: []const u8,
    r: layout.Rect,
    inner_w: u16,
    owner_idx: usize,
    is_active: bool,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    chrome_layer: ?[]u8,
    chrome_panel_id: ?[]u32,
    top_window_owner: []const i32,
    mask: []const bool,
) void {
    var controls_buf: [9]u8 = undefined;
    const control_chars = mux.windowControlChars();
    controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
    const controls = controls_buf[0..];
    const controls_w: u16 = @intCast(controls.len);
    const title_max = if (r.width >= 10 and inner_w > controls_w) inner_w - controls_w else inner_w;
    const title_role: u8 = if (is_active) chrome_layer_active_title else chrome_layer_inactive_title;
    const controls_role: u8 = if (is_active) chrome_layer_active_buttons else chrome_layer_inactive_buttons;

    const inner_x = r.x + 1;
    render_compositor.drawTextOwnedMasked(canvas, total_cols, content_rows, inner_x, r.y, title, title_max, owner_idx, top_window_owner, mask);
    if (chrome_layer) |layer| {
        if (chrome_panel_id) |panel_ids| {
            markTextOwnedMaskedLayer(layer, panel_ids, total_cols, content_rows, inner_x, r.y, title, title_max, owner_idx, top_window_owner, mask, title_role);
        }
    }

    if (r.width >= 10) {
        const controls_x: u16 = r.x + r.width - controls_w - 1;
        render_compositor.drawTextOwnedMasked(canvas, total_cols, content_rows, controls_x, r.y, controls, controls_w, owner_idx, top_window_owner, mask);
        if (chrome_layer) |layer| {
            if (chrome_panel_id) |panel_ids| {
                markTextOwnedMaskedLayer(layer, panel_ids, total_cols, content_rows, controls_x, r.y, controls, controls_w, owner_idx, top_window_owner, mask, controls_role);
            }
        }
    }
}

pub fn renderPopupChrome(
    mux: *const multiplexer.Multiplexer,
    p: anytype,
    total_cols: usize,
    content_rows: usize,
    canvas: []u21,
    border_conn: []u8,
    chrome_layer: []u8,
    chrome_panel_id: []u32,
    clear_rect: bool,
) u16 {
    if (clear_rect) {
        render_compositor.clearCanvasRect(canvas, total_cols, content_rows, p.rect);
        render_compositor.clearBorderConnRect(border_conn, total_cols, content_rows, p.rect);
        render_compositor.clearChromeLayerRect(chrome_layer, chrome_panel_id, total_cols, content_rows, p.rect);
    }

    const panel_active = mux.popup_mgr.focused_popup_id == p.id;
    if (p.show_border) {
        drawPopupBorderDirect(
            canvas,
            total_cols,
            content_rows,
            p.rect,
            mux.borderGlyphs(),
            if (panel_active) mux.focusMarker() else null,
        );
        const popup_border: BorderMask = .{ .left = true, .right = true, .top = true, .bottom = true };
        markBorderLayer(
            chrome_layer,
            chrome_panel_id,
            total_cols,
            content_rows,
            p.rect,
            popup_border,
            if (panel_active) chrome_layer_active_border else chrome_layer_inactive_border,
            p.id,
        );
    }

    const inner_x = p.rect.x + 1;
    const inner_w = p.rect.width - 2;
    if (inner_w > 0) {
        render_compositor.drawText(canvas, total_cols, content_rows, inner_x, p.rect.y, p.title, inner_w);
        markTextLayer(
            chrome_layer,
            chrome_panel_id,
            total_cols,
            content_rows,
            inner_x,
            p.rect.y,
            p.title,
            inner_w,
            if (panel_active) chrome_layer_active_title else chrome_layer_inactive_title,
            p.id,
        );
        if (p.show_controls and p.rect.width >= 10) {
            var controls_buf: [9]u8 = undefined;
            const control_chars = mux.windowControlChars();
            controls_buf = .{ '[', control_chars.minimize, ']', '[', control_chars.maximize, ']', '[', control_chars.close, ']' };
            const controls = controls_buf[0..];
            const controls_w: u16 = @intCast(controls.len);
            const controls_x: u16 = p.rect.x + p.rect.width - controls_w - 1;
            render_compositor.drawText(canvas, total_cols, content_rows, controls_x, p.rect.y, controls, controls_w);
            markTextLayer(
                chrome_layer,
                chrome_panel_id,
                total_cols,
                content_rows,
                controls_x,
                p.rect.y,
                controls,
                controls_w,
                if (panel_active) chrome_layer_active_buttons else chrome_layer_inactive_buttons,
                p.id,
            );
        }
    }

    return p.rect.height - 2;
}
