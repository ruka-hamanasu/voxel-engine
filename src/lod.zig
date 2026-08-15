const std = @import("std");
const world_mod = @import("world.zig");

const World = world_mod.World;

/// Half-resolution world for the far-field march: coarse voxel
/// (cx, yc, cz) covers fine voxels x in {2cx, 2cx+1} etc. and is solid
/// iff any of the (up to) 8 fine voxels is solid — a conservative
/// overestimate, so distant silhouettes can only grow by up to one
/// fine voxel, an error the fog curve hides past lod_dist. Material is
/// the highest solid fine voxel's, which keeps terrain tops and
/// rooftops reading correctly. The coarse world is a plain World, so
/// masks, macro cells, the light flood, and the renderer's per-cell
/// machinery all work on it unchanged.

/// Coarse grid extent covering fine extent n (odd n: the last coarse
/// cell pairs its second fine voxel with air).
fn coarse(n: usize) usize {
    return (n + 1) / 2;
}

/// Rebuild one coarse column from the fine world's current runs.
/// dense scratch must hold coarse(fine.h) bytes. Non-resident coarse
/// columns are skipped (streaming: edits only reach resident fine
/// chunks, whose covering coarse chunks are always resident too — the
/// coarse disc contains the fine disc — so this never fires in
/// practice; it guards the invariant).
fn rebuildColumn(lod: *World, fine: *const World, cx: i32, cz: i32, dense: []u8) !void {
    if (lod.columnAt(cx, cz) == null) return;
    @memset(dense, 0);
    const lh = coarse(fine.h);
    const x0 = 2 * cx;
    const z0 = 2 * cz;
    const x1 = if (fine.w) |w| @min(x0 + 2, @as(i32, @intCast(w))) else x0 + 2;
    const z1 = if (fine.d) |d| @min(z0 + 2, @as(i32, @intCast(d))) else z0 + 2;
    var yc: usize = 0;
    while (yc < lh) : (yc += 1) {
        // Highest solid fine voxel wins: check the upper fine layer
        // first, then the lower.
        const yf_hi = @min(2 * yc + 1, fine.h - 1);
        const yf_lo = 2 * yc;
        var yf = yf_hi + 1;
        while (yf > yf_lo) {
            yf -= 1;
            var x = x0;
            while (x < x1) : (x += 1) {
                var z = z0;
                while (z < z1) : (z += 1) {
                    if (fine.solidAt(x, @intCast(yf), z)) {
                        dense[yc] = fine.get(x, @intCast(yf), z);
                        break;
                    }
                } else continue;
                break;
            }
            if (dense[yc] != 0) break;
        }
    }
    // Run-encode top-to-bottom (same rule as gen.Builder.emit).
    var runs: std.ArrayList(world_mod.MatRun) = .empty;
    errdefer runs.deinit(lod.allocator);
    var y: usize = lh;
    while (y > 0) {
        y -= 1;
        const mat = dense[y];
        if (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            if (last.palette_id == mat and last.count < 255) {
                last.count += 1;
                continue;
            }
        }
        try runs.append(lod.allocator, .{ .count = 1, .palette_id = mat });
    }
    // Keep the old light runs: the caller always follows with a
    // coarse relight, whose stale-clear pass needs them to find chains
    // orphaned by removed content (e.g. a dug-out crystal).
    lod.setColumnRunsKeepLight(cx, cz, try runs.toOwnedSlice(lod.allocator));
}

/// Build the coarse world for a bounded fine world.
pub fn build(allocator: std.mem.Allocator, fine: *const World) !World {
    var lod = try World.init(allocator, coarse(fine.w.?), coarse(fine.h), coarse(fine.d.?));
    errdefer lod.deinit();
    const dense = try allocator.alloc(u8, coarse(fine.h));
    defer allocator.free(dense);
    for (0..lod.w.?) |cx| {
        for (0..lod.d.?) |cz| {
            try rebuildColumn(&lod, fine, @intCast(cx), @intCast(cz), dense);
        }
    }
    return lod;
}

/// Fine-coords dirty region -> rebuild the overlapping coarse columns.
/// Unbounded worlds pass through without clamping; coarse columns
/// whose fine footprint is not resident read air there (callers only
/// fire this for regions covered by resident fine chunks).
pub fn rebuildRegion(allocator: std.mem.Allocator, fine: *const World, lod: *World, r: world_mod.Region) !void {
    const dense = try allocator.alloc(u8, coarse(fine.h));
    defer allocator.free(dense);
    const cx0 = @divFloor(r.x0, 2);
    const cz0 = @divFloor(r.z0, 2);
    const cx1 = if (lod.w) |w| @min(@divFloor(r.x1 + 1, 2), @as(i32, @intCast(w))) else @divFloor(r.x1 + 1, 2);
    const cz1 = if (lod.d) |d| @min(@divFloor(r.z1 + 1, 2), @as(i32, @intCast(d))) else @divFloor(r.z1 + 1, 2);
    var cx = cx0;
    while (cx < cx1) : (cx += 1) {
        var cz = cz0;
        while (cz < cz1) : (cz += 1) {
            try rebuildColumn(lod, fine, cx, cz, dense);
        }
    }
}

/// The coarse-coords region covering a fine-coords dirty region (for
/// the coarse relight after a rebuild).
pub fn coarseRegion(lod: *const World, r: world_mod.Region) world_mod.Region {
    const x1 = @divFloor(r.x1 + 1, 2);
    const y1 = @divFloor(r.y1 + 1, 2);
    const z1 = @divFloor(r.z1 + 1, 2);
    return .{
        .x0 = @divFloor(r.x0, 2),
        .y0 = @divFloor(r.y0, 2),
        .z0 = @divFloor(r.z0, 2),
        .x1 = if (lod.w) |w| @min(x1, @as(i32, @intCast(w))) else x1,
        .y1 = @min(y1, @as(i32, @intCast(lod.h))),
        .z1 = if (lod.d) |d| @min(z1, @as(i32, @intCast(d))) else z1,
    };
}

test "coarse column is a conservative, top-material downsample" {
    var fine = try World.init(std.testing.allocator, 4, 8, 4);
    defer fine.deinit();
    // Column (2,1): solid 0..2 (mat 1), gap, solid 5 (mat 7).
    try fine.fillBox(2, 0, 1, 3, 3, 2, 1);
    try fine.fillBox(2, 5, 1, 3, 6, 2, 7);
    // Column (3,1): single solid at 3 (mat 4) — pairs with (2,1).
    try fine.fillBox(3, 3, 1, 4, 4, 2, 4);

    var lod = try build(std.testing.allocator, &fine);
    defer lod.deinit();
    // Coarse column (1,0): yc0 from fine y0-1 -> mat 1; yc1 from y2-3
    // -> y3 (col x=3, mat 4) is highest; yc2 from y4-5 -> y5 mat 7.
    try std.testing.expectEqual(@as(u8, 1), lod.get(1, 0, 0));
    try std.testing.expectEqual(@as(u8, 4), lod.get(1, 1, 0));
    try std.testing.expectEqual(@as(u8, 7), lod.get(1, 2, 0));
    try std.testing.expectEqual(@as(u8, 0), lod.get(1, 3, 0));

    // Edit the fine world and rebuild the region.
    try fine.fillBox(2, 5, 1, 3, 6, 2, 0);
    const r = fine.takeDirty().?;
    try rebuildRegion(std.testing.allocator, &fine, &lod, r);
    try std.testing.expectEqual(@as(u8, 0), lod.get(1, 2, 0));
    try std.testing.expectEqual(@as(u8, 4), lod.get(1, 1, 0));
}
