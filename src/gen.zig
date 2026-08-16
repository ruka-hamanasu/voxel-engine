const std = @import("std");
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;

pub const Options = struct {
    seed: u64 = 1337,
    w: usize = 384,
    h: usize = 256,
    d: usize = 384,
};

pub const Landmark = struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const Result = struct {
    world: World,
    spawn: Camera,
    landmarks: []Landmark,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.landmarks);
        self.world.deinit();
    }
};

pub const Generator = enum {
    terrain,
};

pub fn generate(kind: Generator, allocator: std.mem.Allocator, opts: Options) !Result {
    return switch (kind) {
        .terrain => @import("gen/terrain.zig").generate(allocator, opts),
    };
}

const terrain = @import("gen/terrain.zig");

/// One far-impostor cell (plans/DISTANCE.md D3): conservative top
/// height (fine voxels) + one dominant material for a cell-sized XZ
/// footprint. Synthesis is per-generator behind the facade below, so
/// the impostor grid (src/impostor.zig) stays generator-agnostic.
pub const ImpostorCell = struct { top_y: u16, mat: u8 };

/// Generator context for impostor synthesis.
pub const ImpostorCtx = union(Generator) {
    terrain: *const terrain.Ctx,
};

/// Per-tile impostor synthesis state (terrain: the tile's arch tops).
pub const ImpostorTile = union(Generator) {
    terrain: terrain.ImpostorTile,
};

/// Begin impostor synthesis of the tile covering [x0, x0+extent) x
/// [z0, z0+extent) fine voxels. bounds = the bounded world's XZ
/// extent, null when unbounded. arches = false skips the arch fold-in
/// (levels whose cells make arches sub-pixel; the region scans
/// dominate synthesis cost).
pub fn impostorBeginTile(ctx: ImpostorCtx, bounds: ?[2]usize, x0: i32, z0: i32, extent: i32, arches: bool, allocator: std.mem.Allocator) !ImpostorTile {
    return switch (ctx) {
        .terrain => |tc| .{ .terrain = try terrain.ImpostorTile.init(tc, bounds, x0, z0, extent, arches, allocator) },
    };
}

pub fn impostorEndTile(tile: *ImpostorTile, allocator: std.mem.Allocator) void {
    switch (tile.*) {
        .terrain => |*t| t.deinit(allocator),
    }
}

pub fn impostorCell(ctx: ImpostorCtx, tile: *const ImpostorTile, x0: i32, z0: i32, size: u32) ImpostorCell {
    return switch (ctx) {
        .terrain => |tc| terrain.impostorCell(tc, &tile.terrain, x0, z0, size),
    };
}

test "facade dispatch generates a world" {
    var result = try generate(.terrain, std.testing.allocator, .{ .seed = 3, .w = 48, .h = 32, .d = 48 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.world.get(0, 0, 0) != 0);
    try std.testing.expect(result.spawn.y > 0);
    try std.testing.expect(result.spawn.y < @as(f32, @floatFromInt(result.world.h)));
}
