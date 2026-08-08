const std = @import("std");

pub const palette = [_]u32{
    0x000000, // 0: air (unused)
    0x8c8c91, // 1: stone
    0xa5503c, // 2: brick
    0xc8b482, // 3: sand
    0x5aa050, // 4: grass
    0x506ec8, // 5: blue
    0xdcdcd7, // 6: marble
    0x7d5a38, // 7: dirt
    0x4a4a52, // 8: dark stone
    0x46e6e6, // 9: crystal cyan
    0xe646c8, // 10: crystal magenta
    0xf0a53c, // 11: crystal amber
};

pub const MatRun = struct {
    count: u8,
    palette_id: u8,
};

pub const Column = struct {
    runs: []MatRun,
};

pub const RunCursor = struct {
    runs: []const MatRun,
    idx: usize,
    lo: i32,
    hi: i32,

    pub fn init(runs: []const MatRun, h: i32, y: i32) RunCursor {
        var idx: usize = 0;
        var hi: i32 = h - 1;
        var lo: i32 = hi - @as(i32, runs[0].count) + 1;
        while (y < lo) {
            idx += 1;
            hi = lo - 1;
            lo = hi - @as(i32, runs[idx].count) + 1;
        }
        return .{ .runs = runs, .idx = idx, .lo = lo, .hi = hi };
    }

    pub fn mat(self: *const RunCursor) u8 {
        return self.runs[self.idx].palette_id;
    }

    /// Material at y without moving the cursor; y must be within one
    /// voxel of the current run ([lo-1, hi+1], i.e. y +/- 1 queries land
    /// on adjacent runs, which is all AO neighbor sampling needs).
    /// Out-of-world heights read as air, matching World.get.
    pub fn peek(self: *const RunCursor, y: i32) u8 {
        std.debug.assert(y >= self.lo - 1 and y <= self.hi + 1);
        if (y >= self.lo and y <= self.hi) return self.runs[self.idx].palette_id;
        if (y > self.hi) {
            if (self.idx == 0) return 0;
            return self.runs[self.idx - 1].palette_id;
        }
        if (self.idx + 1 >= self.runs.len) return 0;
        return self.runs[self.idx + 1].palette_id;
    }

    pub fn up(self: *RunCursor) void {
        self.idx -= 1;
        self.lo = self.hi + 1;
        self.hi = self.lo + @as(i32, self.runs[self.idx].count) - 1;
    }

    pub fn down(self: *RunCursor) void {
        self.idx += 1;
        self.hi = self.lo - 1;
        self.lo = self.hi - @as(i32, self.runs[self.idx].count) + 1;
    }
};

pub const World = struct {
    w: usize,
    h: usize,
    d: usize,
    columns: []Column,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, w: usize, h: usize, d: usize) !World {
        var world: World = .{
            .w = w,
            .h = h,
            .d = d,
            .columns = try allocator.alloc(Column, w * d),
            .allocator = allocator,
        };
        var initialized: usize = 0;
        errdefer {
            for (world.columns[0..initialized]) |col| allocator.free(col.runs);
            allocator.free(world.columns);
        }
        for (world.columns, 0..) |*col, i| {
            col.runs = try allocUniformRuns(allocator, h, 0);
            initialized = i + 1;
        }
        return world;
    }

    pub fn deinit(self: *World) void {
        for (self.columns) |col| self.allocator.free(col.runs);
        self.allocator.free(self.columns);
    }

    fn allocUniformRuns(allocator: std.mem.Allocator, h: usize, mat: u8) ![]MatRun {
        const n = (h + 254) / 255;
        const runs = try allocator.alloc(MatRun, n);
        var remaining: usize = h;
        for (runs) |*run| {
            const count: u8 = @intCast(@min(remaining, 255));
            run.* = .{ .count = count, .palette_id = mat };
            remaining -= count;
        }
        return runs;
    }

    pub fn columnAt(self: *const World, x: i32, z: i32) ?*const Column {
        if (x < 0 or z < 0) return null;
        const ux: usize = @intCast(x);
        const uz: usize = @intCast(z);
        if (ux >= self.w or uz >= self.d) return null;
        return &self.columns[ux * self.d + uz];
    }

    pub fn setColumnRuns(self: *World, x: usize, z: usize, runs: []MatRun) void {
        std.debug.assert(x < self.w and z < self.d);
        const col = &self.columns[x * self.d + z];
        self.allocator.free(col.runs);
        col.runs = runs;
    }

    pub fn get(self: *const World, x: i32, y: i32, z: i32) u8 {
        if (y < 0) return 0;
        const uy: usize = @intCast(y);
        if (uy >= self.h) return 0;
        const col = self.columnAt(x, z) orelse return 0;
        var depth: usize = self.h - 1 - uy;
        for (col.runs) |run| {
            if (depth < run.count) return run.palette_id;
            depth -= run.count;
        }
        return 0;
    }

    fn setRange(self: *World, col: *Column, d0: usize, d1: usize, mat: u8) !void {
        var out: std.ArrayList(MatRun) = .empty;
        errdefer out.deinit(self.allocator);

        var pos: usize = 0;
        for (col.runs) |run| {
            const start = pos;
            const end = pos + run.count;
            pos = end;
            try appendRun(&out, self.allocator, run.palette_id, @min(end, d0) -| start);
            try appendRun(&out, self.allocator, mat, @min(end, d1) -| @max(start, d0));
            try appendRun(&out, self.allocator, run.palette_id, end -| @max(start, d1));
        }

        const new_runs = try out.toOwnedSlice(self.allocator);
        self.allocator.free(col.runs);
        col.runs = new_runs;
    }

    fn appendRun(out: *std.ArrayList(MatRun), allocator: std.mem.Allocator, mat: u8, count: usize) !void {
        var remaining = count;
        while (remaining > 0) {
            if (out.items.len > 0) {
                const last = &out.items[out.items.len - 1];
                if (last.palette_id == mat and last.count < 255) {
                    const add: u8 = @intCast(@min(remaining, 255 - @as(usize, last.count)));
                    last.count += add;
                    remaining -= add;
                    continue;
                }
            }
            const chunk: u8 = @intCast(@min(remaining, 255));
            try out.append(allocator, .{ .count = chunk, .palette_id = mat });
            remaining -= chunk;
        }
    }

    pub fn set(self: *World, x: usize, y: usize, z: usize, mat: u8) !void {
        if (x >= self.w or y >= self.h or z >= self.d) return;
        const depth = self.h - 1 - y;
        try self.setRange(&self.columns[x * self.d + z], depth, depth + 1, mat);
    }

    pub fn fillBox(self: *World, x0: usize, y0: usize, z0: usize, x1: usize, y1: usize, z1: usize, mat: u8) !void {
        const xa = @min(x0, self.w);
        const ya = @min(y0, self.h);
        const za = @min(z0, self.d);
        const xb = @min(x1, self.w);
        const yb = @min(y1, self.h);
        const zb = @min(z1, self.d);
        if (xa >= xb or ya >= yb or za >= zb) return;
        for (xa..xb) |x| {
            for (za..zb) |z| {
                try self.setRange(&self.columns[x * self.d + z], self.h - yb, self.h - ya, mat);
            }
        }
    }

    pub fn buildDemoRoom(allocator: std.mem.Allocator) !World {
        var world = try World.init(allocator, 32, 16, 32);
        errdefer world.deinit();
        try world.fillBox(4, 0, 4, 28, 1, 28, 1); // floor
        try world.fillBox(4, 1, 4, 5, 10, 28, 2); // x=4 wall
        try world.fillBox(27, 1, 4, 28, 10, 28, 2); // x=27 wall
        try world.fillBox(4, 1, 4, 28, 10, 5, 2); // z=4 wall
        try world.fillBox(4, 1, 27, 28, 10, 28, 2); // z=27 wall
        try world.fillBox(19, 1, 27, 23, 5, 28, 0); // arch opening, lower
        try world.fillBox(20, 5, 27, 22, 7, 28, 0); // arch opening, stepped top
        try world.fillBox(11, 1, 15, 14, 9, 17, 6); // marble pillar
        try world.fillBox(8, 1, 20, 10, 3, 22, 5); // blue block
        try world.fillBox(21, 1, 8, 23, 2, 10, 4); // green block
        try world.fillBox(9, 1, 9, 10, 2, 10, 3); // sand block
        return world;
    }
};

fn expectCoverage(world: *const World, x: i32, z: i32) !void {
    const col = world.columnAt(x, z).?;
    var total: usize = 0;
    for (col.runs, 0..) |run, i| {
        try std.testing.expect(run.count > 0);
        if (i > 0) try std.testing.expect(run.palette_id != col.runs[i - 1].palette_id or col.runs[i - 1].count == 255);
        total += run.count;
    }
    try std.testing.expectEqual(world.h, total);
}

test "fillBox and get" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    try world.fillBox(1, 1, 1, 3, 3, 3, 5);
    try std.testing.expectEqual(5, world.get(2, 2, 2));
    try std.testing.expectEqual(5, world.get(1, 1, 1));
    try std.testing.expectEqual(0, world.get(3, 2, 2));
    try std.testing.expectEqual(0, world.get(-1, 2, 2));
    try std.testing.expectEqual(0, world.get(2, 100, 2));
    try world.fillBox(2, 2, 2, 3, 3, 3, 0);
    try std.testing.expectEqual(0, world.get(2, 2, 2));
    for (0..8) |x| {
        for (0..8) |z| {
            try expectCoverage(&world, @intCast(x), @intCast(z));
        }
    }
}

test "set splits and merges runs" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    const col = &world.columns[2 * 8 + 2];
    try std.testing.expectEqual(1, col.runs.len);

    try world.set(2, 2, 2, 5);
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(MatRun{ .count = 5, .palette_id = 0 }, col.runs[0]);
    try std.testing.expectEqual(MatRun{ .count = 1, .palette_id = 5 }, col.runs[1]);
    try std.testing.expectEqual(MatRun{ .count = 2, .palette_id = 0 }, col.runs[2]);

    try world.set(2, 3, 2, 5);
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(MatRun{ .count = 4, .palette_id = 0 }, col.runs[0]);
    try std.testing.expectEqual(MatRun{ .count = 2, .palette_id = 5 }, col.runs[1]);

    try world.set(2, 2, 2, 0);
    try world.set(2, 3, 2, 0);
    try std.testing.expectEqual(1, col.runs.len);
    try std.testing.expectEqual(MatRun{ .count = 8, .palette_id = 0 }, col.runs[0]);
}

test "runs split at 255" {
    var world = try World.init(std.testing.allocator, 1, 600, 1);
    defer world.deinit();
    const col = &world.columns[0];
    try std.testing.expectEqual(3, col.runs.len);
    try std.testing.expectEqual(255, col.runs[0].count);
    try std.testing.expectEqual(255, col.runs[1].count);
    try std.testing.expectEqual(90, col.runs[2].count);

    try world.fillBox(0, 0, 0, 1, 600, 1, 7);
    try std.testing.expectEqual(3, col.runs.len);
    for (col.runs) |run| try std.testing.expectEqual(7, run.palette_id);
    try expectCoverage(&world, 0, 0);

    try world.set(0, 255, 0, 3);
    try std.testing.expectEqual(3, world.get(0, 255, 0));
    try expectCoverage(&world, 0, 0);
}

test "run cursor peeks adjacent voxels" {
    var world = try World.init(std.testing.allocator, 1, 16, 1);
    defer world.deinit();
    try world.fillBox(0, 3, 0, 1, 7, 1, 5);
    const col = &world.columns[0];

    const cur = RunCursor.init(col.runs, 16, 5);
    try std.testing.expectEqual(5, cur.peek(5));
    try std.testing.expectEqual(5, cur.peek(6));
    try std.testing.expectEqual(0, cur.peek(7));
    try std.testing.expectEqual(5, cur.peek(4));
    try std.testing.expectEqual(0, cur.peek(2));

    const top = RunCursor.init(col.runs, 16, 15);
    try std.testing.expectEqual(0, top.peek(16));
    try std.testing.expectEqual(0, top.peek(15));

    const bottom = RunCursor.init(col.runs, 16, 0);
    try std.testing.expectEqual(0, bottom.peek(0));
    try std.testing.expectEqual(0, bottom.peek(-1));
}

test "run cursor walks both directions" {
    var world = try World.init(std.testing.allocator, 1, 16, 1);
    defer world.deinit();
    try world.fillBox(0, 3, 0, 1, 7, 1, 5);
    const col = &world.columns[0];

    var y: i32 = 0;
    var cur = RunCursor.init(col.runs, 16, 0);
    while (y < 16) : (y += 1) {
        const expected: u8 = if (y >= 3 and y < 7) 5 else 0;
        try std.testing.expectEqual(expected, cur.mat());
        try std.testing.expect(y >= cur.lo and y <= cur.hi);
        if (y < 15 and y == cur.hi) cur.up();
    }

    y = 15;
    cur = RunCursor.init(col.runs, 16, 15);
    while (y >= 0) : (y -= 1) {
        const expected: u8 = if (y >= 3 and y < 7) 5 else 0;
        try std.testing.expectEqual(expected, cur.mat());
        if (y > 0 and y == cur.lo) cur.down();
    }
}
