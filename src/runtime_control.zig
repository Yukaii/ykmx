const std = @import("std");
const layout = @import("layout.zig");
const layout_native = @import("layout_native.zig");
const multiplexer = @import("multiplexer.zig");
const input_mod = @import("input.zig");

const ControlCommand = struct {
    v: ?u8 = null,
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
    x: ?u16 = null,
    y: ?u16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    panel_id: ?u32 = null,
    visible: ?bool = null,
    command_name: ?[]const u8 = null,
    modal: ?bool = null,
    transparent_background: ?bool = null,
    show_border: ?bool = null,
    show_controls: ?bool = null,
    argv: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
};

pub fn applyControlCommandLine(mux: *multiplexer.Multiplexer, screen: layout.Rect, line: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(ControlCommand, arena.allocator(), line, .{}) catch return false;
    const cmd = parsed.value.command orelse return false;

    if (std.mem.eql(u8, cmd, "new_window")) {
        _ = try mux.createShellWindow("shell");
        _ = try mux.resizeActiveWindowsToLayout(screen);
        return true;
    }
    if (std.mem.eql(u8, cmd, "close_window")) {
        _ = mux.closeFocusedWindow() catch return false;
        _ = try mux.resizeActiveWindowsToLayout(screen);
        return true;
    }
    if (std.mem.eql(u8, cmd, "open_popup")) {
        const has_rect = parsed.value.x != null and parsed.value.y != null and parsed.value.width != null and parsed.value.height != null;
        const rect: layout.Rect = .{
            .x = parsed.value.x orelse 0,
            .y = parsed.value.y orelse 0,
            .width = parsed.value.width orelse 1,
            .height = parsed.value.height orelse 1,
        };
        if (parsed.value.argv) |argv| {
            if (argv.len > 0) {
                if (has_rect) {
                    _ = try mux.openCommandPopupRectInDir("popup-cmd", argv, screen, rect, true, true, parsed.value.cwd);
                } else {
                    _ = try mux.openCommandPopupInDir("popup-cmd", argv, screen, true, true, parsed.value.cwd);
                }
                return true;
            }
        }
        if (has_rect) {
            _ = try mux.openShellPopupRectStyledInDir(
                "popup-shell",
                screen,
                rect,
                true,
                .{},
                null,
                parsed.value.cwd,
            );
        } else {
            _ = try mux.openShellPopupOwnedInDir("popup-shell", screen, true, null, parsed.value.cwd);
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "open_panel_rect")) {
        const x = parsed.value.x orelse return false;
        const y = parsed.value.y orelse return false;
        const width = parsed.value.width orelse return false;
        const height = parsed.value.height orelse return false;
        _ = try mux.openShellPopupRectStyledInDir(
            "popup-shell",
            screen,
            .{ .x = x, .y = y, .width = width, .height = height },
            parsed.value.modal orelse false,
            .{
                .transparent_background = parsed.value.transparent_background orelse false,
                .show_border = parsed.value.show_border orelse true,
                .show_controls = parsed.value.show_controls orelse false,
            },
            null,
            parsed.value.cwd,
        );
        return true;
    }
    if (std.mem.eql(u8, cmd, "set_panel_visibility")) {
        const panel_id = parsed.value.panel_id orelse return false;
        const visible = parsed.value.visible orelse return false;
        return try mux.setPopupVisibilityByIdOwned(panel_id, visible, null);
    }
    if (std.mem.eql(u8, cmd, "dispatch_plugin_command")) {
        const command_name = parsed.value.command_name orelse return false;
        if (try mux.dispatchPluginNamedCommand(command_name)) return true;

        if (input_mod.parseCommandName(command_name)) |core_cmd| {
            const key = input_mod.defaultPrefixedKey(core_cmd) orelse return false;
            var seq = [_]u8{ mux.input_router.prefix_key, key };
            try mux.handleInputBytesWithScreen(screen, &seq);
            return true;
        }
        return false;
    }
    return false;
}

test "runtime_control dispatch_plugin_command executes core command names" {
    const testing = std.testing;
    var mux = multiplexer.Multiplexer.init(testing.allocator, layout_native.NativeLayoutEngine.init());
    defer mux.deinit();

    const screen: layout.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    _ = try mux.createTab("dev");
    _ = try mux.createCommandWindow("shell", &.{ "/bin/sh", "-c", "sleep 0.1" });

    const before = try mux.workspace_mgr.activeLayoutType();
    try testing.expectEqual(layout.LayoutType.vertical_stack, before);

    const changed = try applyControlCommandLine(
        &mux,
        screen,
        "{\"v\":1,\"command\":\"dispatch_plugin_command\",\"command_name\":\"cycle_layout\"}",
    );
    try testing.expect(changed);
    try testing.expectEqual(layout.LayoutType.horizontal_stack, try mux.workspace_mgr.activeLayoutType());
}
