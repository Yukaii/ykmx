const std = @import("std");
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
