const std = @import("std");
const world_mod = @import("world.zig");
const camera_mod = @import("camera.zig");

const World = world_mod.World;
const Camera = camera_mod.Camera;

pub const hfov: f32 = std.math.pi / 2.0;
pub const max_dist: f32 = 48.0;

const Face = enum(u2) { top, bottom, x_side, z_side };
const face_factor = [4]f32{ 1.0, 0.5, 0.8, 0.6 };

const Span = struct { y0: u16, y1: u16 };

pub const SpanList = struct {
    pub const max_spans = 8;

    spans: [max_spans]Span = undefined,
    len: usize = 0,

    pub fn initFull(h: u16) SpanList {
        var list: SpanList = .{};
        list.spans[0] = .{ .y0 = 0, .y1 = h };
        list.len = 1;
        return list;
    }

    pub fn isEmpty(self: *const SpanList) bool {
        return self.len == 0;
    }

    pub fn subtract(self: *SpanList, a: u16, b: u16) void {
        if (a >= b) return;
        var i: usize = 0;
        while (i < self.len) {
            const s = self.spans[i];
            if (b <= s.y0 or a >= s.y1) {
                i += 1;
                continue;
            }
            if (a <= s.y0 and b >= s.y1) {
                std.mem.copyForwards(Span, self.spans[i .. self.len - 1], self.spans[i + 1 .. self.len]);
                self.len -= 1;
                continue;
            }
            if (a <= s.y0) {
                self.spans[i].y0 = b;
                i += 1;
                continue;
            }
            if (b >= s.y1) {
                self.spans[i].y1 = a;
                i += 1;
                continue;
            }
            if (self.len == max_spans) {
                self.spans[i].y1 = a;
                i += 1;
                continue;
            }
            std.mem.copyBackwards(Span, self.spans[i + 2 .. self.len + 1], self.spans[i + 1 .. self.len]);
            self.spans[i] = .{ .y0 = s.y0, .y1 = a };
            self.spans[i + 1] = .{ .y0 = b, .y1 = s.y1 };
            self.len += 1;
            return;
        }
    }
};

fn shade(mat: u8, face: Face) u32 {
    const c = world_mod.palette[mat];
    const factor = face_factor[@intFromEnum(face)];
    const r: u32 = @intFromFloat(@as(f32, @floatFromInt((c >> 16) & 0xff)) * factor);
    const g: u32 = @intFromFloat(@as(f32, @floatFromInt((c >> 8) & 0xff)) * factor);
    const b: u32 = @intFromFloat(@as(f32, @floatFromInt(c & 0xff)) * factor);
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

fn skyColor(row: usize, height: usize) u32 {
    const t = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(height));
    const r: u32 = @intFromFloat(88.0 + (196.0 - 88.0) * t);
    const g: u32 = @intFromFloat(118.0 + (214.0 - 118.0) * t);
    const b: u32 = @intFromFloat(186.0 + (234.0 - 186.0) * t);
    return 0xff000000 | (r << 16) | (g << 8) | b;
}

pub fn render(fb: []u32, width: usize, height: usize, world: *const World, cam: Camera) void {
    const wf: f32 = @floatFromInt(width);
    const f = (wf * 0.5) / @tan(hfov * 0.5);
    const fwd = cam.forward();
    const rgt = cam.right();

    for (0..width) |sx| {
        const hx = (@as(f32, @floatFromInt(sx)) + 0.5 - wf * 0.5) / f;
        const dx = fwd[0] + rgt[0] * hx;
        const dz = fwd[1] + rgt[1] * hx;
        renderColumn(fb, height, world, cam, f, sx, dx, dz);
    }
}

fn renderColumn(fb: []u32, height: usize, world: *const World, cam: Camera, f: f32, sx: usize, dx: f32, dz: f32) void {
    var free = SpanList.initFull(@intCast(height));

    var ix: i32 = @intFromFloat(@floor(cam.x));
    var iz: i32 = @intFromFloat(@floor(cam.z));
    const step_x: i32 = if (dx > 0) 1 else -1;
    const step_z: i32 = if (dz > 0) 1 else -1;
    const inf = std.math.inf(f32);
    const t_delta_x: f32 = if (dx != 0) @abs(1.0 / dx) else inf;
    const t_delta_z: f32 = if (dz != 0) @abs(1.0 / dz) else inf;
    var t_max_x: f32 = if (dx > 0)
        (@floor(cam.x) + 1.0 - cam.x) / dx
    else if (dx < 0)
        (@floor(cam.x) - cam.x) / dx
    else
        inf;
    var t_max_z: f32 = if (dz > 0)
        (@floor(cam.z) + 1.0 - cam.z) / dz
    else if (dz < 0)
        (@floor(cam.z) - cam.z) / dz
    else
        inf;

    var t0: f32 = 0;
    var axis: Face = .x_side;

    while (t0 < max_dist and !free.isEmpty()) {
        const t1 = @min(@min(t_max_x, t_max_z), max_dist);
        processCell(fb, height, sx, world, ix, iz, cam.y, f, t0, t1, axis, &free);
        if (t_max_x < t_max_z) {
            t0 = t_max_x;
            t_max_x += t_delta_x;
            ix += step_x;
            axis = .x_side;
        } else {
            t0 = t_max_z;
            t_max_z += t_delta_z;
            iz += step_z;
            axis = .z_side;
        }
    }

    for (free.spans[0..free.len]) |s| {
        for (s.y0..s.y1) |row| {
            fb[sx * height + row] = skyColor(row, height);
        }
    }
}

fn proj(h_world: f32, t: f32, height: usize, cam_y: f32, f: f32) f32 {
    return @as(f32, @floatFromInt(height)) * 0.5 - (h_world - cam_y) * f / t;
}

fn claim(fb: []u32, height: usize, sx: usize, free: *SpanList, r0: f32, r1: f32, color: u32) void {
    if (free.isEmpty() or !(r1 > r0)) return;
    var i: usize = 0;
    while (i < free.len) : (i += 1) {
        const s = free.spans[i];
        const a = @max(r0, @as(f32, @floatFromInt(s.y0)));
        const b = @min(r1, @as(f32, @floatFromInt(s.y1)));
        if (!(b > a)) continue;
        const ia: u16 = @intFromFloat(@ceil(a));
        const ib: u16 = @intFromFloat(@ceil(b));
        if (ib <= ia) continue;
        for (ia..ib) |row| {
            fb[sx * height + row] = color;
        }
        free.subtract(ia, ib);
    }
}

fn processCell(fb: []u32, height: usize, sx: usize, world: *const World, ix: i32, iz: i32, cam_y: f32, f: f32, t0_in: f32, t1: f32, axis: Face, free: *SpanList) void {
    if (free.isEmpty()) return;
    const t0 = @max(t0_in, 1e-4);
    const hf: f32 = @floatFromInt(height);
    const s_max = hf * 0.5 / f;
    const h_hi = cam_y + @max(s_max * t0, s_max * t1);
    const h_lo = cam_y - @max(s_max * t0, s_max * t1);
    const y_lo: i32 = @max(@as(i32, @intFromFloat(@floor(h_lo))), 0);
    const y_hi: i32 = @min(@as(i32, @intFromFloat(@floor(h_hi))), @as(i32, @intCast(world.h)) - 1);
    if (y_lo > y_hi) return;

    var y: i32 = y_lo;
    while (y <= y_hi) : (y += 1) {
        const mat = world.get(ix, y, iz);
        if (mat == 0) continue;
        const yf: f32 = @floatFromInt(y);
        claim(fb, height, sx, free, proj(yf + 1, t0, height, cam_y, f), proj(yf, t0, height, cam_y, f), shade(mat, axis));
        claim(fb, height, sx, free, proj(yf, t0, height, cam_y, f), proj(yf, t1, height, cam_y, f), shade(mat, .bottom));
        if (free.isEmpty()) return;
    }

    y = y_hi;
    while (y >= y_lo) : (y -= 1) {
        const mat = world.get(ix, y, iz);
        if (mat == 0) continue;
        const yf: f32 = @floatFromInt(y);
        claim(fb, height, sx, free, proj(yf + 1, t1, height, cam_y, f), proj(yf + 1, t0, height, cam_y, f), shade(mat, .top));
        if (free.isEmpty()) return;
    }
}

pub fn transpose(dst: []u32, src: []const u32, width: usize, height: usize) void {
    for (0..width) |x| {
        for (0..height) |y| {
            dst[y * width + x] = src[x * height + y];
        }
    }
}

pub fn writePpm(io: std.Io, allocator: std.mem.Allocator, path: []const u8, pixels: []const u32, width: usize, height: usize) !void {
    const header = try std.fmt.allocPrint(allocator, "P6\n{} {}\n255\n", .{ width, height });
    defer allocator.free(header);
    const body = try allocator.alloc(u8, header.len + width * height * 3);
    defer allocator.free(body);
    @memcpy(body[0..header.len], header);
    for (pixels, 0..) |p, i| {
        body[header.len + i * 3 + 0] = @truncate(p >> 16);
        body[header.len + i * 3 + 1] = @truncate(p >> 8);
        body[header.len + i * 3 + 2] = @truncate(p);
    }
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = body });
}

test "span subtract splits and trims" {
    var list = SpanList.initFull(100);
    list.subtract(40, 60);
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqual(Span{ .y0 = 0, .y1 = 40 }, list.spans[0]);
    try std.testing.expectEqual(Span{ .y0 = 60, .y1 = 100 }, list.spans[1]);

    list.subtract(10, 20);
    try std.testing.expectEqual(3, list.len);
    try std.testing.expectEqual(Span{ .y0 = 0, .y1 = 10 }, list.spans[0]);
    try std.testing.expectEqual(Span{ .y0 = 20, .y1 = 40 }, list.spans[1]);

    list.subtract(0, 10);
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqual(Span{ .y0 = 20, .y1 = 40 }, list.spans[0]);

    list.subtract(90, 200);
    try std.testing.expectEqual(Span{ .y0 = 60, .y1 = 90 }, list.spans[1]);

    list.subtract(20, 40);
    try std.testing.expectEqual(1, list.len);

    list.subtract(0, 100);
    try std.testing.expect(list.isEmpty());

    list.subtract(0, 100);
    try std.testing.expect(list.isEmpty());
}
