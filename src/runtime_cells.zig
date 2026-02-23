const ghostty_vt = @import("ghostty-vt");
const runtime_output = @import("runtime_output.zig");
const runtime_render_types = @import("runtime_render_types.zig");

const RuntimeRenderCell = runtime_render_types.RuntimeRenderCell;

pub fn plainCellFromCodepoint(cp: u21) RuntimeRenderCell {
    var cell: RuntimeRenderCell = .{
        .style = .{},
        .styled = false,
    };
    cell.text_len = @intCast(runtime_output.encodeCodepoint(cell.text[0..], cp));
    if (cell.text_len == 0) {
        cell.text[0] = '?';
        cell.text_len = 1;
    }
    return cell;
}

pub fn renderCellEqual(a: RuntimeRenderCell, b: RuntimeRenderCell) bool {
    if (a.text_len != b.text_len) return false;
    if (a.styled != b.styled) return false;
    if (a.styled and !a.style.eql(b.style)) return false;
    return std.mem.eql(u8, a.text[0..a.text_len], b.text[0..b.text_len]);
}

pub fn runtimeCellHasExplicitBg(cell: RuntimeRenderCell) bool {
    if (!cell.styled) return false;
    return switch (cell.style.bg_color) {
        .none => false,
        else => true,
    };
}

pub fn runtimeCellBgTag(cell: RuntimeRenderCell) u8 {
    if (!cell.styled) return 0;
    return switch (cell.style.bg_color) {
        .none => 0,
        .palette => 1,
        .rgb => 2,
    };
}

pub fn enforceOpaquePanelChromeBg(style: ghostty_vt.Style, panel_id: u32) ghostty_vt.Style {
    if (panel_id == 0) return style;
    var out = style;
    switch (out.bg_color) {
        .none => out.bg_color = .{ .palette = 0 },
        else => {},
    }
    return out;
}

pub fn enforceOpaqueRuntimeCellBg(cell: *RuntimeRenderCell) void {
    if (!cell.styled) {
        var s: ghostty_vt.Style = .{};
        s.bg_color = .{ .palette = 0 };
        cell.style = s;
        cell.styled = true;
        return;
    }
    switch (cell.style.bg_color) {
        .none => cell.style.bg_color = .{ .palette = 0 },
        else => {},
    }
}

pub fn isSafeRunCell(cell: RuntimeRenderCell) bool {
    if (cell.text_len == 1) {
        const ch = cell.text[0];
        return ch >= 0x20 and ch <= 0x7e;
    }
    if (cell.text_len == 3) {
        const bytes = cell.text[0..3];
        return std.mem.eql(u8, bytes, "│") or
            std.mem.eql(u8, bytes, "─") or
            std.mem.eql(u8, bytes, "┌") or
            std.mem.eql(u8, bytes, "┐") or
            std.mem.eql(u8, bytes, "└") or
            std.mem.eql(u8, bytes, "┘");
    }
    return false;
}

const std = @import("std");
