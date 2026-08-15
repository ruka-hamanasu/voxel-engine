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

test "facade dispatch generates a world" {
    var result = try generate(.terrain, std.testing.allocator, .{ .seed = 3, .w = 48, .h = 32, .d = 48 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.world.get(0, 0, 0) != 0);
    try std.testing.expect(result.spawn.y > 0);
    try std.testing.expect(result.spawn.y < @as(f32, @floatFromInt(result.world.h)));
}
