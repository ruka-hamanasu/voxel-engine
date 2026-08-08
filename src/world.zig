const std = @import("std");

/// emissive: 0 = normal shaded material; nonzero = emissive intensity
/// (rendered full-bright, seeds the milestone-9 light flood).
pub const PaletteEntry = struct {
    rgb: u32,
    emissive: u8,
};

pub const default_palette = [_]PaletteEntry{
    .{ .rgb = 0x000000, .emissive = 0 }, // 0: air (unused)
    .{ .rgb = 0x8c8c91, .emissive = 0 }, // 1: stone
    .{ .rgb = 0xa5503c, .emissive = 0 }, // 2: brick
    .{ .rgb = 0xc8b482, .emissive = 0 }, // 3: sand
    .{ .rgb = 0x5aa050, .emissive = 0 }, // 4: grass
    .{ .rgb = 0x506ec8, .emissive = 0 }, // 5: blue
    .{ .rgb = 0xdcdcd7, .emissive = 0 }, // 6: marble
    .{ .rgb = 0x7d5a38, .emissive = 0 }, // 7: dirt
    .{ .rgb = 0x4a4a52, .emissive = 0 }, // 8: dark stone
    .{ .rgb = 0x46e6e6, .emissive = 255 }, // 9: crystal cyan
    .{ .rgb = 0xe646c8, .emissive = 255 }, // 10: crystal magenta
    .{ .rgb = 0xf0a53c, .emissive = 255 }, // 11: crystal amber
};

/// Runtime-mutable (milestone 10 animates entries); call
/// render.rebuildShadeLut() after changing it.
pub var palette = default_palette;

pub const MatRun = struct {
    count: u8,
    palette_id: u8,
};

pub const LightRun = struct {
    count: u8,
    color_id: u8,
    intensity: u8,
};

pub const Column = struct {
    runs: []MatRun,
    /// Explicit light deviations; null = default derived from the
    /// material runs (full sky light above the topmost solid run, dark
    /// below). When present, the runs cover y in
    /// (light_base_y - total_count, light_base_y] top-to-bottom; the
    /// default applies outside that span. Freed back to null when it
    /// holds no deviations.
    light: ?[]LightRun = null,
    light_base_y: u16 = 0,
};

/// Topmost solid voxel y in the column, or null when fully air. Backs
/// milestone 11's sky-light defaults.
pub fn topSolidY(col: *const Column, h: i32) ?i32 {
    var hi: i32 = h - 1;
    for (col.runs) |run| {
        if (run.palette_id != 0) return hi;
        hi -= run.count;
    }
    return null;
}

/// Cursor walking a top-to-bottom run stream; generic over the run
/// type so material and light streams share the walk logic. mat() and
/// peek() are material-specific (0 = air).
pub fn CursorFor(comptime R: type) type {
    return struct {
        const Self = @This();

        runs: []const R,
        idx: usize,
        lo: i32,
        hi: i32,

        pub fn init(runs: []const R, h: i32, y: i32) Self {
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

        pub fn mat(self: *const Self) u8 {
            if (R != MatRun) @compileError("mat() requires a MatRun cursor");
            return self.runs[self.idx].palette_id;
        }

        /// Material at y without moving the cursor; y must be within one
        /// voxel of the current run ([lo-1, hi+1], i.e. y +/- 1 queries land
        /// on adjacent runs, which is all AO neighbor sampling needs).
        /// Out-of-world heights read as air, matching World.get.
        pub fn peek(self: *const Self, y: i32) u8 {
            if (R != MatRun) @compileError("peek() requires a MatRun cursor");
            std.debug.assert(y >= self.lo - 1 and y <= self.hi + 1);
            if (y >= self.lo and y <= self.hi) return self.runs[self.idx].palette_id;
            if (y > self.hi) {
                if (self.idx == 0) return 0;
                return self.runs[self.idx - 1].palette_id;
            }
            if (self.idx + 1 >= self.runs.len) return 0;
            return self.runs[self.idx + 1].palette_id;
        }

        pub fn up(self: *Self) void {
            self.idx -= 1;
            self.lo = self.hi + 1;
            self.hi = self.lo + @as(i32, self.runs[self.idx].count) - 1;
        }

        pub fn down(self: *Self) void {
            self.idx += 1;
            self.hi = self.lo - 1;
            self.lo = self.hi - @as(i32, self.runs[self.idx].count) + 1;
        }
    };
}

pub const RunCursor = CursorFor(MatRun);
pub const LightCursor = CursorFor(LightRun);

pub const Region = struct {
    x0: usize,
    y0: usize,
    z0: usize,
    x1: usize,
    y1: usize,
    z1: usize,
};

pub const World = struct {
    w: usize,
    h: usize,
    d: usize,
    columns: []Column,
    allocator: std.mem.Allocator,
    /// Bounding box (half-open) of everything touched by set/fillBox
    /// since the last takeDirty; consumed by milestone 10's relight.
    dirty: ?Region = null,

    fn markDirty(self: *World, r: Region) void {
        if (self.dirty) |*cur| {
            cur.* = .{
                .x0 = @min(cur.x0, r.x0),
                .y0 = @min(cur.y0, r.y0),
                .z0 = @min(cur.z0, r.z0),
                .x1 = @max(cur.x1, r.x1),
                .y1 = @max(cur.y1, r.y1),
                .z1 = @max(cur.z1, r.z1),
            };
        } else {
            self.dirty = r;
        }
    }

    pub fn takeDirty(self: *World) ?Region {
        const r = self.dirty;
        self.dirty = null;
        return r;
    }

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
            for (world.columns[0..initialized]) |col| {
                allocator.free(col.runs);
                if (col.light) |l| allocator.free(l);
            }
            allocator.free(world.columns);
        }
        for (world.columns, 0..) |*col, i| {
            col.* = .{ .runs = try allocUniformRuns(allocator, h, 0) };
            initialized = i + 1;
        }
        return world;
    }

    pub fn deinit(self: *World) void {
        for (self.columns) |col| {
            self.allocator.free(col.runs);
            if (col.light) |l| self.allocator.free(l);
        }
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
        if (col.light) |l| self.allocator.free(l);
        col.* = .{ .runs = runs };
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

    /// Topmost solid y within [y_lo, y_hi], or null when the column has
    /// no solid voxel in the interval. Pure interval-overlap scan over
    /// the material runs; exists for the sun shadow march (milestone
    /// 12). The renderer deliberately does NOT call it as a per-cell
    /// fast reject — that cost ~5% in double run scans.
    pub fn firstSolidInColumn(self: *const World, ix: i32, iz: i32, y_lo: i32, y_hi: i32) ?i32 {
        const col = self.columnAt(ix, iz) orelse return null;
        var hi: i32 = @intCast(self.h - 1);
        for (col.runs) |run| {
            const lo = hi - @as(i32, run.count) + 1;
            if (run.palette_id != 0 and lo <= y_hi and hi >= y_lo)
                return @min(hi, y_hi);
            hi = lo - 1;
        }
        return null;
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
        const xc = @min(x, self.w - 1);
        const yc = @min(y, self.h - 1);
        const zc = @min(z, self.d - 1);
        const depth = self.h - 1 - yc;
        try self.setRange(&self.columns[xc * self.d + zc], depth, depth + 1, mat);
        self.markDirty(.{ .x0 = xc, .y0 = yc, .z0 = zc, .x1 = xc + 1, .y1 = yc + 1, .z1 = zc + 1 });
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
        self.markDirty(.{ .x0 = xa, .y0 = ya, .z0 = za, .x1 = xb, .y1 = yb, .z1 = zb });
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
    if (col.light) |runs| {
        var ltotal: usize = 0;
        for (runs, 0..) |run, i| {
            try std.testing.expect(run.count > 0);
            if (i > 0) try std.testing.expect(
                run.color_id != runs[i - 1].color_id or run.intensity != runs[i - 1].intensity or runs[i - 1].count == 255,
            );
            ltotal += run.count;
        }
        try std.testing.expect(ltotal <= world.h);
        try std.testing.expect(col.light_base_y < world.h);
    }
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

test "set clamps out-of-bounds and edits record dirty extents" {
    var world = try World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    try std.testing.expectEqual(null, world.dirty);

    try world.set(20, 20, 20, 5);
    try std.testing.expectEqual(5, world.get(7, 7, 7));
    try std.testing.expectEqual(Region{ .x0 = 7, .y0 = 7, .z0 = 7, .x1 = 8, .y1 = 8, .z1 = 8 }, world.dirty.?);

    try world.fillBox(1, 2, 3, 4, 5, 6, 7);
    try std.testing.expectEqual(Region{ .x0 = 1, .y0 = 2, .z0 = 3, .x1 = 8, .y1 = 8, .z1 = 8 }, world.dirty.?);

    const r = world.takeDirty().?;
    try std.testing.expectEqual(@as(usize, 1), r.x0);
    try std.testing.expectEqual(null, world.dirty);
    try std.testing.expectEqual(null, world.takeDirty());
}

test "topSolidY finds the topmost solid voxel" {
    var world = try World.init(std.testing.allocator, 1, 16, 1);
    defer world.deinit();
    const col = &world.columns[0];
    try std.testing.expectEqual(null, topSolidY(col, 16));
    try world.fillBox(0, 3, 0, 1, 7, 1, 5);
    try std.testing.expectEqual(6, topSolidY(col, 16));
    try world.set(0, 12, 0, 4);
    try std.testing.expectEqual(12, topSolidY(col, 16));
}

test "light stream storage lifecycle" {
    const allocator = std.testing.allocator;
    var world = try World.init(allocator, 2, 16, 2);
    defer world.deinit();
    for (world.columns) |col| try std.testing.expect(col.light == null);

    const col = &world.columns[1 * 2 + 1];
    const runs = try allocator.alloc(LightRun, 2);
    runs[0] = .{ .count = 4, .color_id = 1, .intensity = 200 };
    runs[1] = .{ .count = 3, .color_id = 1, .intensity = 120 };
    col.light = runs;
    col.light_base_y = 9;
    try expectCoverage(&world, 1, 1);

    var cur = LightCursor.init(col.light.?, 10, 9);
    try std.testing.expectEqual(9, cur.hi);
    try std.testing.expectEqual(6, cur.lo);
    try std.testing.expectEqual(200, cur.runs[cur.idx].intensity);
    cur.down();
    try std.testing.expectEqual(5, cur.hi);
    try std.testing.expectEqual(120, cur.runs[cur.idx].intensity);

    // Replacing the material runs drops the stale light stream.
    const fresh = try World.allocUniformRuns(allocator, 16, 0);
    world.setColumnRuns(1, 1, fresh);
    try std.testing.expect(col.light == null);
    try std.testing.expectEqual(@as(u16, 0), col.light_base_y);
}

test "firstSolidInColumn finds interval overlap" {
    var world = try World.init(std.testing.allocator, 2, 16, 2);
    defer world.deinit();
    try world.fillBox(1, 3, 1, 2, 7, 2, 5);
    try std.testing.expectEqual(null, world.firstSolidInColumn(0, 0, 0, 15));
    try std.testing.expectEqual(null, world.firstSolidInColumn(1, 1, 7, 15));
    try std.testing.expectEqual(null, world.firstSolidInColumn(1, 1, 0, 2));
    try std.testing.expectEqual(6, world.firstSolidInColumn(1, 1, 0, 15));
    try std.testing.expectEqual(5, world.firstSolidInColumn(1, 1, 4, 5));
    try std.testing.expectEqual(4, world.firstSolidInColumn(1, 1, 4, 4));
    try std.testing.expectEqual(null, world.firstSolidInColumn(-3, 1, 0, 15));
    try std.testing.expectEqual(null, world.firstSolidInColumn(1, 1, 8, 2));
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
