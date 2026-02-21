const std = @import("std");
const layout = @import("layout.zig");

pub const PluginHost = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    alive: bool = true,

    pub fn start(allocator: std.mem.Allocator, plugin_dir: []const u8) !PluginHost {
        const entry = try std.fs.path.join(allocator, &.{ plugin_dir, "index.ts" });
        defer allocator.free(entry);
        std.fs.cwd().access(entry, .{}) catch return error.PluginEntryNotFound;

        var argv = [_][]const u8{ "bun", "run", entry };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.cwd = plugin_dir;
        try child.spawn();

        return .{
            .allocator = allocator,
            .child = child,
            .alive = true,
        };
    }

    pub fn deinit(self: *PluginHost) void {
        if (self.alive) {
            _ = self.child.kill() catch {};
            self.alive = false;
        } else {
            _ = self.child.wait() catch {};
        }
        self.* = undefined;
    }

    pub fn emitStart(self: *PluginHost, layout_type: layout.LayoutType) !void {
        try self.emitLine(try std.fmt.allocPrint(
            self.allocator,
            "{{\"v\":1,\"event\":\"on_start\",\"layout\":\"{s}\"}}\n",
            .{@tagName(layout_type)},
        ));
    }

    pub fn emitLayoutChanged(self: *PluginHost, layout_type: layout.LayoutType) !void {
        try self.emitLine(try std.fmt.allocPrint(
            self.allocator,
            "{{\"v\":1,\"event\":\"on_layout_changed\",\"layout\":\"{s}\"}}\n",
            .{@tagName(layout_type)},
        ));
    }

    pub fn emitShutdown(self: *PluginHost) !void {
        try self.emitLine(try std.fmt.allocPrint(
            self.allocator,
            "{\"v\":1,\"event\":\"on_shutdown\"}\n",
            .{},
        ));
    }

    fn emitLine(self: *PluginHost, line: []u8) !void {
        defer self.allocator.free(line);
        if (!self.alive) return;
        const stdin_file = self.child.stdin orelse {
            self.alive = false;
            return;
        };
        stdin_file.writeAll(line) catch |err| switch (err) {
            error.BrokenPipe, error.NotOpenForWriting => {
                self.alive = false;
                return;
            },
            else => return err,
        };
    }
};
