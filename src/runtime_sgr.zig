const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn parseSgrStyleSpec(spec_raw: []const u8) !ghostty_vt.Style {
    var style: ghostty_vt.Style = .{};
    var spec = std.mem.trim(u8, spec_raw, " \t\r\n");
    if (spec.len == 0) return style;
    if (std.mem.startsWith(u8, spec, "\x1b[") and std.mem.endsWith(u8, spec, "m") and spec.len >= 3) {
        spec = spec[2 .. spec.len - 1];
    } else if (std.mem.endsWith(u8, spec, "m") and spec.len >= 2) {
        spec = spec[0 .. spec.len - 1];
    }
    if (spec.len == 0) return style;

    var codes = std.ArrayListUnmanaged(u16){};
    defer codes.deinit(std.heap.page_allocator);
    var it = std.mem.splitScalar(u8, spec, ';');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        const code: u16 = if (part.len == 0) 0 else (std.fmt.parseInt(u16, part, 10) catch continue);
        try codes.append(std.heap.page_allocator, code);
    }

    var i: usize = 0;
    while (i < codes.items.len) : (i += 1) {
        const code = codes.items[i];
        switch (code) {
            0 => style = .{},
            1 => style.flags.bold = true,
            2 => style.flags.faint = true,
            3 => style.flags.italic = true,
            4 => style.flags.underline = .single,
            5 => style.flags.blink = true,
            7 => style.flags.inverse = true,
            8 => style.flags.invisible = true,
            9 => style.flags.strikethrough = true,
            21 => style.flags.underline = .double,
            22 => {
                style.flags.bold = false;
                style.flags.faint = false;
            },
            23 => style.flags.italic = false,
            24 => style.flags.underline = .none,
            25 => style.flags.blink = false,
            27 => style.flags.inverse = false,
            28 => style.flags.invisible = false,
            29 => style.flags.strikethrough = false,
            30...37 => style.fg_color = .{ .palette = @intCast(code - 30) },
            39 => style.fg_color = .none,
            40...47 => style.bg_color = .{ .palette = @intCast(code - 40) },
            49 => style.bg_color = .none,
            90...97 => style.fg_color = .{ .palette = @intCast(8 + code - 90) },
            100...107 => style.bg_color = .{ .palette = @intCast(8 + code - 100) },
            38, 48, 58 => {
                if (i + 1 >= codes.items.len) continue;
                const mode = codes.items[i + 1];
                if (mode == 5 and i + 2 < codes.items.len) {
                    const v: u8 = @intCast(@min(codes.items[i + 2], 255));
                    switch (code) {
                        38 => style.fg_color = .{ .palette = v },
                        48 => style.bg_color = .{ .palette = v },
                        58 => style.underline_color = .{ .palette = v },
                        else => {},
                    }
                    i += 2;
                } else if (mode == 2 and i + 4 < codes.items.len) {
                    const r: u8 = @intCast(@min(codes.items[i + 2], 255));
                    const g: u8 = @intCast(@min(codes.items[i + 3], 255));
                    const b: u8 = @intCast(@min(codes.items[i + 4], 255));
                    switch (code) {
                        38 => style.fg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } },
                        48 => style.bg_color = .{ .rgb = .{ .r = r, .g = g, .b = b } },
                        58 => style.underline_color = .{ .rgb = .{ .r = r, .g = g, .b = b } },
                        else => {},
                    }
                    i += 4;
                }
            },
            59 => style.underline_color = .none,
            else => {},
        }
    }
    return style;
}
