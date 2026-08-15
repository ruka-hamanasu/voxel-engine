const std = @import("std");
const world_mod = @import("../world.zig");

/// Dense-tile generation scratch (plans/STREAMING.md phase 0): generation
/// fills a tw x td x h tile of dense voxels, stamps cross-tile features
/// (arches) into it, then run-encodes every column. Column-major
/// layout ((lx*td + lz)*h + y) matches the world's column order.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    tw: usize,
    td: usize,
    dense: []u8,

    pub fn init(allocator: std.mem.Allocator, world: *world_mod.World, tw: usize, td: usize) !Builder {
        std.debug.assert(tw > 0 and td > 0);
        return .{
            .allocator = allocator,
            .world = world,
            .tw = tw,
            .td = td,
            .dense = try allocator.alloc(u8, tw * td * world.h),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.dense);
    }

    /// Raw dense scratch of one tile column (no clearing), for the
    /// feature-stamp pass between fill and encode.
    pub fn at(self: *Builder, lx: usize, lz: usize) []u8 {
        const h = self.world.h;
        return self.dense[(lx * self.td + lz) * h ..][0..h];
    }

    /// Zeroed dense scratch of one tile column, for column generation.
    pub fn column(self: *Builder, lx: usize, lz: usize) []u8 {
        const col = self.at(lx, lz);
        @memset(col, 0);
        return col;
    }

    /// Run-encode tile column (lx, lz) into world column (x, z).
    /// keep_light preserves the column's light runs (chunk loads write
    /// terrain over the pre-gen flood; see chunk.loadChunk).
    pub fn emit(self: *Builder, x: i32, z: i32, lx: usize, lz: usize, keep_light: bool) !void {
        return encodeDenseColumn(self.world, x, z, self.at(lx, lz), keep_light);
    }
};

/// Run-encode a dense column into world column (x, z). keep_light
/// preserves the column's light runs (chunk loads write terrain over
/// the pre-gen flood; see chunk.loadChunk).
pub fn encodeDenseColumn(world: *world_mod.World, x: i32, z: i32, dense: []const u8, keep_light: bool) !void {
    var runs: std.ArrayList(world_mod.MatRun) = .empty;
    errdefer runs.deinit(world.allocator);
    var y: usize = dense.len;
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
        try runs.append(world.allocator, .{ .count = 1, .palette_id = mat });
    }
    const owned = try runs.toOwnedSlice(world.allocator);
    if (keep_light)
        world.setColumnRunsKeepLight(x, z, owned)
    else
        world.setColumnRuns(x, z, owned);
}

test "emit run-encodes dense column" {
    const World = world_mod.World;
    var world = try World.init(std.testing.allocator, 4, 8, 4);
    defer world.deinit();
    var builder = try Builder.init(std.testing.allocator, &world, 4, 4);
    defer builder.deinit();

    const dense = builder.column(1, 2);
    dense[0] = 1;
    dense[1] = 1;
    dense[2] = 5;
    try builder.emit(1, 2, 1, 2, false);

    const col = world.columnAtMut(1, 2).?;
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(world_mod.MatRun{ .count = 5, .palette_id = 0 }, col.runs[0]);
    try std.testing.expectEqual(world_mod.MatRun{ .count = 1, .palette_id = 5 }, col.runs[1]);
    try std.testing.expectEqual(world_mod.MatRun{ .count = 2, .palette_id = 1 }, col.runs[2]);
    try std.testing.expectEqual(5, world.get(1, 2, 2));
    try std.testing.expectEqual(1, world.get(1, 1, 2));
    try std.testing.expectEqual(0, world.get(1, 7, 2));
}
