const std = @import("std");
const world_mod = @import("world.zig");

/// Emissive palette animation (milestone 10): pulse the crystals'
/// brightness per frame from the accumulated render time. Only rgb is
/// rewritten — the emissive flag never changes, so the flood's seed set
/// is stable and no relight is triggered; the cast light pulses for
/// free because the renderer's applyGlow looks the tint color up from
/// the palette per frame.
///
/// Every pulse is (1 - cos)-shaped, so t = 0 is the identity for all
/// three materials and headless baselines stay byte-identical; the
/// stagger comes from distinct frequencies that drift out of phase.
const pulse_freq = [3]f32{ 1.1, 1.7, 2.3 };
const pulse_amp: f32 = 0.35;
const pulse_mats = [3]u8{ 9, 10, 11 };

pub fn updatePalette(time_s: f64) void {
    const t: f32 = @floatCast(time_s);
    inline for (pulse_mats, pulse_freq) |m, w| {
        const f = 1.0 - pulse_amp * (1.0 - @cos(t * w)) * 0.5;
        world_mod.palette[m].rgb = scaleRgb(world_mod.default_palette[m].rgb, f);
    }
}

fn scaleRgb(c: u32, f: f32) u32 {
    var out: u32 = 0;
    inline for (0..3) |k| {
        const sh: u5 = @intCast((2 - k) * 8);
        const ch: u32 = @intFromFloat(@min(@as(f32, @floatFromInt((c >> sh) & 0xff)) * f, 255.0));
        out |= ch << sh;
    }
    return out;
}

test "t=0 is the identity; pulses stay within bounds" {
    updatePalette(0);
    for (pulse_mats) |m| {
        try std.testing.expectEqual(world_mod.default_palette[m].rgb, world_mod.palette[m].rgb);
    }
    var t: f64 = 0.13;
    while (t < 40) : (t += 0.13) {
        updatePalette(t);
        for (pulse_mats) |m| {
            const animated = world_mod.palette[m].rgb;
            const base = world_mod.default_palette[m].rgb;
            inline for (0..3) |k| {
                const sh: u5 = @intCast((2 - k) * 8);
                const a = (animated >> sh) & 0xff;
                const b = (base >> sh) & 0xff;
                try std.testing.expect(a <= b);
                try std.testing.expect(@as(f32, @floatFromInt(a)) >= @as(f32, @floatFromInt(b)) * (1.0 - pulse_amp) - 1.0);
            }
        }
    }
    world_mod.palette = world_mod.default_palette;
}
