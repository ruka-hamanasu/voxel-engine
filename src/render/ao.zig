const std = @import("std");
const world_mod = @import("../world.zig");

const World = world_mod.World;

/// Minecraft per-vertex AO: both edge neighbors solid -> darkest (0),
/// else 3 minus the count of solid occluders (corner included).
fn aoLevel(side1: bool, side2: bool, corner: bool) u2 {
    if (side1 and side2) return 0;
    return 3 - @as(u2, @intFromBool(side1)) - @as(u2, @intFromBool(side2)) - @as(u2, @intFromBool(corner));
}

pub fn frac01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

/// AO level at fractional face position u between corners a and b.
/// Kept fractional: rounding to discrete levels here makes the stop
/// jump a whole level when the sample point crosses a rounding
/// boundary, which bands adjacent screen columns.
fn lerpLevel(a: u2, b: u2, u: f32) f32 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return fa + (fb - fa) * u;
}

/// AO level at (u, v) on a horizontal face, bilinear between the four
/// corner levels (m/p = -/+ along x then z).
fn bilerpLevel(mm: u2, pm: u2, mp: u2, pp: u2, u: f32, v: f32) f32 {
    const fmm: f32 = @floatFromInt(mm);
    const fpm: f32 = @floatFromInt(pm);
    const fmp: f32 = @floatFromInt(mp);
    const fpp: f32 = @floatFromInt(pp);
    const lo = fmm + (fpm - fmm) * u;
    const hi = fmp + (fpp - fmp) * u;
    return lo + (hi - lo) * v;
}

/// Borrows the cursor out of an optional (null = column outside the
/// world, treated as air).
pub fn optCursor(oc: *?world_mod.RunCursor) ?*const world_mod.RunCursor {
    if (oc.*) |*c| return c;
    return null;
}

fn peekSolid(oc: ?*const world_mod.RunCursor, y: i32) bool {
    const c = oc orelse return false;
    return c.peek(y) != 0;
}

/// {top, bottom} AO stops for the side face of voxel y, sampled at
/// lateral face position u. n is the air-side (previous DDA cell)
/// column; la/lb are the diagonal columns on either side of it. Corner
/// queries are skipped only when both edge neighbors are solid, where
/// the corner cannot affect the level.
pub fn sideAoStops(n: *const world_mod.RunCursor, la: ?*const world_mod.RunCursor, lb: ?*const world_mod.RunCursor, y: i32, u: f32) [2]f32 {
    const up = n.peek(y + 1) != 0;
    const dn = n.peek(y - 1) != 0;
    const sa = peekSolid(la, y);
    const sb = peekSolid(lb, y);
    const top_a = aoLevel(up, sa, if (up and sa) false else peekSolid(la, y + 1));
    const top_b = aoLevel(up, sb, if (up and sb) false else peekSolid(lb, y + 1));
    const bot_a = aoLevel(dn, sa, if (dn and sa) false else peekSolid(la, y - 1));
    const bot_b = aoLevel(dn, sb, if (dn and sb) false else peekSolid(lb, y - 1));
    return .{ lerpLevel(top_a, top_b, u), lerpLevel(bot_a, bot_b, u) };
}

fn solidW(world: *const World, x: i32, y: i32, z: i32) bool {
    return world.get(x, y, z) != 0;
}

/// {near, far} AO stops for a horizontal face of column (ix, iz),
/// sampled at hit positions (ua, va) and (ub, vb). yf is the height of
/// the air block in front of the face (above for top, below for
/// bottom). Rare enough (run boundaries only) that direct World.get
/// queries beat maintaining eight lockstep cursors.
pub fn faceAoStops(world: *const World, ix: i32, iz: i32, yf: i32, ua: f32, va: f32, ub: f32, vb: f32) [2]f32 {
    const xm = solidW(world, ix - 1, yf, iz);
    const xp = solidW(world, ix + 1, yf, iz);
    const zm = solidW(world, ix, yf, iz - 1);
    const zp = solidW(world, ix, yf, iz + 1);
    const l_mm = aoLevel(xm, zm, if (xm and zm) false else solidW(world, ix - 1, yf, iz - 1));
    const l_pm = aoLevel(xp, zm, if (xp and zm) false else solidW(world, ix + 1, yf, iz - 1));
    const l_mp = aoLevel(xm, zp, if (xm and zp) false else solidW(world, ix - 1, yf, iz + 1));
    const l_pp = aoLevel(xp, zp, if (xp and zp) false else solidW(world, ix + 1, yf, iz + 1));
    return .{ bilerpLevel(l_mm, l_pm, l_mp, l_pp, ua, va), bilerpLevel(l_mm, l_pm, l_mp, l_pp, ub, vb) };
}

test "face ao darkens toward a taller neighbor" {
    var world = try World.init(std.testing.allocator, 4, 16, 4);
    defer world.deinit();
    try world.fillBox(1, 0, 1, 2, 5, 2, 7);
    try world.fillBox(2, 0, 1, 3, 6, 2, 7);
    const open = faceAoStops(&world, 1, 1, 5, 0.1, 0.5, 0.1, 0.5);
    try std.testing.expectApproxEqAbs(2.9, open[0], 1e-6);
    const near = faceAoStops(&world, 1, 1, 5, 0.9, 0.5, 0.9, 0.5);
    try std.testing.expect(near[0] < 3);
    const diag = faceAoStops(&world, 1, 1, 5, 0.9, 0.9, 0.9, 0.9);
    try std.testing.expect(diag[0] < 3);
}

test "ao level truth table" {
    try std.testing.expectEqual(0, aoLevel(true, true, false));
    try std.testing.expectEqual(0, aoLevel(true, true, true));
    try std.testing.expectEqual(1, aoLevel(true, false, true));
    try std.testing.expectEqual(2, aoLevel(true, false, false));
    try std.testing.expectEqual(2, aoLevel(false, false, true));
    try std.testing.expectEqual(3, aoLevel(false, false, false));
}
