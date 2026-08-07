const std = @import("std");
const world_mod = @import("../world.zig");

pub const Builder = struct {
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    dense: []u8,

    pub fn init(allocator: std.mem.Allocator, world: *world_mod.World) !Builder {
        return .{
            .allocator = allocator,
            .world = world,
            .dense = try allocator.alloc(u8, world.h),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.dense);
    }

    pub fn column(self: *Builder) []u8 {
        @memset(self.dense, 0);
        return self.dense;
    }

    pub fn emit(self: *Builder, x: usize, z: usize) !void {
        var runs: std.ArrayList(world_mod.MatRun) = .empty;
        errdefer runs.deinit(self.allocator);
        var y: usize = self.dense.len;
        while (y > 0) {
            y -= 1;
            const mat = self.dense[y];
            if (runs.items.len > 0) {
                const last = &runs.items[runs.items.len - 1];
                if (last.palette_id == mat and last.count < 255) {
                    last.count += 1;
                    continue;
                }
            }
            try runs.append(self.allocator, .{ .count = 1, .palette_id = mat });
        }
        const owned = try runs.toOwnedSlice(self.allocator);
        self.world.setColumnRuns(x, z, owned);
    }
};

test "emit run-encodes dense column" {
    const World = world_mod.World;
    var world = try World.init(std.testing.allocator, 4, 8, 4);
    defer world.deinit();
    var builder = try Builder.init(std.testing.allocator, &world);
    defer builder.deinit();

    const dense = builder.column();
    dense[0] = 1;
    dense[1] = 1;
    dense[2] = 5;
    try builder.emit(1, 2);

    const col = &world.columns[1 * 4 + 2];
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(world_mod.MatRun{ .count = 5, .palette_id = 0 }, col.runs[0]);
    try std.testing.expectEqual(world_mod.MatRun{ .count = 1, .palette_id = 5 }, col.runs[1]);
    try std.testing.expectEqual(world_mod.MatRun{ .count = 2, .palette_id = 1 }, col.runs[2]);
    try std.testing.expectEqual(5, world.get(1, 2, 2));
    try std.testing.expectEqual(1, world.get(1, 1, 2));
    try std.testing.expectEqual(0, world.get(1, 7, 2));
}
