const std = @import("std");

pub const palette = [_]u32{
    0x000000, // 0: air (unused)
    0x8c8c91, // 1: stone
    0xa5503c, // 2: brick
    0xc8b482, // 3: sand
    0x5aa050, // 4: grass
    0x506ec8, // 5: blue
    0xdcdcd7, // 6: marble
};

pub const World = struct {
    w: usize,
    h: usize,
    d: usize,
    voxels: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: usize, h: usize, d: usize) !World {
        const voxels = try allocator.alloc(u8, w * h * d);
        @memset(voxels, 0);
        return .{ .w = w, .h = h, .d = d, .voxels = voxels, .allocator = allocator };
    }

    pub fn deinit(self: *World) void {
        self.allocator.free(self.voxels);
    }

    fn index(self: *const World, x: usize, y: usize, z: usize) usize {
        return (x * self.d + z) * self.h + y;
    }

    pub fn get(self: *const World, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or y < 0 or z < 0) return 0;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        const uz: usize = @intCast(z);
        if (ux >= self.w or uy >= self.h or uz >= self.d) return 0;
        return self.voxels[self.index(ux, uy, uz)];
    }

    pub fn set(self: *World, x: usize, y: usize, z: usize, mat: u8) void {
        if (x >= self.w or y >= self.h or z >= self.d) return;
        self.voxels[self.index(x, y, z)] = mat;
    }

    pub fn fillBox(self: *World, x0: usize, y0: usize, z0: usize, x1: usize, y1: usize, z1: usize, mat: u8) void {
        const xa = @min(x0, self.w);
        const ya = @min(y0, self.h);
        const za = @min(z0, self.d);
        const xb = @min(x1, self.w);
        const yb = @min(y1, self.h);
        const zb = @min(z1, self.d);
        for (xa..xb) |x| {
            for (za..zb) |z| {
                @memset(self.voxels[self.index(x, ya, z)..self.index(x, yb, z)], mat);
            }
        }
    }

    pub fn buildDemoRoom(allocator: std.mem.Allocator) !World {
        var world = try World.init(allocator, 32, 16, 32);
        world.fillBox(4, 0, 4, 28, 1, 28, 1); // floor
        world.fillBox(4, 1, 4, 5, 10, 28, 2); // x=4 wall
        world.fillBox(27, 1, 4, 28, 10, 28, 2); // x=27 wall
        world.fillBox(4, 1, 4, 28, 10, 5, 2); // z=4 wall
        world.fillBox(4, 1, 27, 28, 10, 28, 2); // z=27 wall
        world.fillBox(19, 1, 27, 23, 5, 28, 0); // arch opening, lower
        world.fillBox(20, 5, 27, 22, 7, 28, 0); // arch opening, stepped top
        world.fillBox(11, 1, 15, 14, 9, 17, 6); // marble pillar
        world.fillBox(8, 1, 20, 10, 3, 22, 5); // blue block
        world.fillBox(21, 1, 8, 23, 2, 10, 4); // green block
        world.fillBox(9, 1, 9, 10, 2, 10, 3); // sand block
        return world;
    }
};

test "fillBox and get" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    world.fillBox(1, 1, 1, 3, 3, 3, 5);
    try std.testing.expectEqual(5, world.get(2, 2, 2));
    try std.testing.expectEqual(5, world.get(1, 1, 1));
    try std.testing.expectEqual(0, world.get(3, 2, 2));
    try std.testing.expectEqual(0, world.get(-1, 2, 2));
    try std.testing.expectEqual(0, world.get(2, 100, 2));
    world.fillBox(2, 2, 2, 3, 3, 3, 0);
    try std.testing.expectEqual(0, world.get(2, 2, 2));
}
