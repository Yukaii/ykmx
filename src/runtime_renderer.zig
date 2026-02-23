const layout = @import("layout.zig");

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
