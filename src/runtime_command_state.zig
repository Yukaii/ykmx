const std = @import("std");

const CommandStateLine = struct {
    name: []const u8,
    source: []const u8,
    plugin_override: bool,
    prefixed_keys: []const u8,
};

pub fn renderCommandListJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    content: []const u8,
    jsonl: bool,
) !void {
    if (!jsonl) try out.append(allocator, '[');
    var first = true;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const cmd = parseCommandStateLine(line) orelse continue;
        if (!first) {
            if (jsonl) {
                try out.append(allocator, '\n');
            } else {
                try out.append(allocator, ',');
            }
        }
        first = false;
        try out.append(allocator, '{');
        try out.appendSlice(allocator, "\"name\":");
        try appendJsonString(out, allocator, cmd.name);
        try out.appendSlice(allocator, ",\"source\":");
        try appendJsonString(out, allocator, cmd.source);
        try out.appendSlice(allocator, ",\"plugin_override\":");
        try out.appendSlice(allocator, if (cmd.plugin_override) "true" else "false");
        try out.appendSlice(allocator, ",\"prefixed_keys\":[");
        if (!std.mem.eql(u8, cmd.prefixed_keys, "-")) {
            var keys = std.mem.splitScalar(u8, cmd.prefixed_keys, ',');
            var first_key = true;
            while (keys.next()) |key| {
                if (key.len == 0) continue;
                if (!first_key) try out.append(allocator, ',');
                first_key = false;
                try appendJsonString(out, allocator, key);
            }
        }
        try out.appendSlice(allocator, "]}");
    }
    if (!jsonl) try out.append(allocator, ']');
}

fn parseCommandStateLine(line: []const u8) ?CommandStateLine {
    if (!std.mem.startsWith(u8, line, "command ")) return null;
    var name: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var plugin_override: ?bool = null;
    var prefixed_keys: ?[]const u8 = null;

    var parts = std.mem.splitScalar(u8, line["command ".len..], ' ');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.startsWith(u8, part, "name=")) {
            name = part["name=".len..];
        } else if (std.mem.startsWith(u8, part, "source=")) {
            source = part["source=".len..];
        } else if (std.mem.startsWith(u8, part, "plugin_override=")) {
            const raw = part["plugin_override=".len..];
            if (std.mem.eql(u8, raw, "1")) plugin_override = true else if (std.mem.eql(u8, raw, "0")) plugin_override = false;
        } else if (std.mem.startsWith(u8, part, "prefixed_keys=")) {
            prefixed_keys = part["prefixed_keys=".len..];
        }
    }

    if (name == null or source == null or plugin_override == null or prefixed_keys == null) return null;
    return .{
        .name = name.?,
        .source = source.?,
        .plugin_override = plugin_override.?,
        .prefixed_keys = prefixed_keys.?,
    };
}

fn appendJsonString(
    out: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    s: []const u8,
) !void {
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...31 => try out.writer(allocator).print("\\u00{x:0>2}", .{ch}),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}
