const std = @import("std");
const c = @cImport({
    @cInclude("nk_config.h");
    @cInclude("SDL.h");
    @cInclude("nuklear.h");
    @cInclude("nuklear_sdl_renderer.h");
});
const Input = @import("camera.zig").Input;
const World = @import("world.zig").World;
const Camera = @import("camera.zig").Camera;
const Player = @import("player.zig").Player;
const render = @import("render.zig");
const gen = @import("gen.zig");
const lighting = @import("lighting.zig");
const lod_mod = @import("lod.zig");
const anim = @import("anim.zig");
const clap = @import("clap");

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit.
        \\    --headless <PATH> Render one frame to a PPM file at PATH and exit (no window).
        \\    --seed <u64>      World generation seed.
        \\    --gen <GEN>       World generator: terrain.
        \\    --cam <CAM>       Camera override as "x,y,z,yaw".
        \\    --bench <u32>     Render N frames and report ms/frame.
        \\    --fog <f32>       Fog density override.
        \\    --fogcut <f32>    Fog cutoff distance override.
        \\    --lod <f32>       LOD switch distance (default 64; 0 disables the coarse world).
        \\    --lod2 <f32>      Second LOD switch distance, quarter-resolution world (default 0 = disabled).
        \\    --detail <f32>    Per-voxel shading detail distance (default 48; 0 = full detail everywhere).
        \\    --atten <u8>      Light attenuation.
        \\    --no-light        Disable lighting.
        \\    --no-anim         Disable palette animation.
        \\    --time <f64>      Animation time in seconds.
        \\    --width <usize>   Render width (default 480).
        \\    --height <usize>  Render height (default 270).
        \\    --scale <u32>     Window scale factor vs render resolution (default 2).
        \\    --world-w <usize> World width in columns (default 384).
        \\    --world-h <usize> World height in voxels (default 128, max 65535).
        \\    --world-d <usize> World depth in columns (default 384).
        \\
    );

    const parsers = comptime .{
        .PATH = clap.parsers.string,
        .GEN = clap.parsers.enumeration(gen.Generator),
        .CAM = clap.parsers.string,
        .u8 = clap.parsers.int(u8, 10),
        .u32 = clap.parsers.int(u32, 10),
        .u64 = clap.parsers.int(u64, 10),
        .usize = clap.parsers.int(usize, 10),
        .f32 = clap.parsers.float(f32),
        .f64 = clap.parsers.float(f64),
    };

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(init.io, .stdout(), clap.Help, &params, .{});

    var opts: gen.Options = .{};
    var cam_override: ?[4]f32 = null;
    if (res.args.cam) |cam_str| {
        var parts = std.mem.splitScalar(u8, cam_str, ',');
        var vals: [4]f32 = undefined;
        for (&vals) |*v| {
            const part = parts.next() orelse return error.BadCamValue;
            v.* = try std.fmt.parseFloat(f32, part);
        }
        cam_override = vals;
    }
    if (res.args.seed) |seed| opts.seed = seed;
    if (res.args.@"world-w") |w| opts.w = w;
    if (res.args.@"world-h") |h| opts.h = h;
    if (res.args.@"world-d") |d| opts.d = d;
    if (opts.w == 0 or opts.h == 0 or opts.d == 0 or opts.h > 65535)
        return error.BadWorldSize;
    const generator = res.args.gen orelse .terrain;
    const headless_path = res.args.headless;
    const bench_frames = res.args.bench orelse 0;
    var light_params: lighting.Params = .{};
    if (res.args.atten) |atten| light_params.attenuation = atten;
    const light_enabled = res.args.@"no-light" == 0;
    const anim_enabled = res.args.@"no-anim" == 0;
    var time_s = res.args.time orelse 0;
    const render_w = res.args.width orelse 480;
    const render_h = res.args.height orelse 270;
    if (render_w == 0 or render_h == 0 or render_h > render.max_sky_height)
        return error.BadResolution;
    const scale = res.args.scale orelse 2;
    if (scale == 0) return error.BadResolution;
    const window_w = std.math.mul(usize, render_w, scale) catch return error.BadResolution;
    const window_h = std.math.mul(usize, render_h, scale) catch return error.BadResolution;
    if (window_w > std.math.maxInt(c_int) or window_h > std.math.maxInt(c_int))
        return error.BadResolution;

    const allocator = init.gpa;
    const framebuffer = try allocator.alloc(u32, render_w * render_h);
    defer allocator.free(framebuffer);
    const staging = try allocator.alloc(u32, render_w * render_h);
    defer allocator.free(staging);
    var result = try gen.generate(generator, allocator, opts);
    defer result.deinit(allocator);
    const world = &result.world;
    var cam = result.spawn;
    if (cam_override) |v| cam = .{ .x = v[0], .y = v[1], .z = v[2], .yaw = v[3] };
    render.rebuildShadeLut();
    var rparams: render.RenderParams = .{};
    rparams.light = light_enabled;
    if (res.args.fog) |d| rparams.fog_density = d;
    if (res.args.fogcut) |co| rparams.fog_cutoff = co;
    if (res.args.lod) |ld| rparams.lod_dist = ld;
    if (res.args.lod2) |ld2| rparams.lod2_dist = ld2;
    if (res.args.detail) |dd| rparams.detail_dist = dd;

    // Half-resolution far-field world (milestone 14 follow-up): built
    // once here, incrementally rebuilt from dirty regions on edits. The
    // quarter-resolution level-2 world (--lod2) builds from level 1.
    var lod_world: ?World = if (rparams.lod_dist > 0) try lod_mod.build(allocator, world) else null;
    defer if (lod_world) |*lw| lw.deinit();
    const lod: ?*const World = if (lod_world) |*lw| lw else null;
    var lod2_world: ?World = if (rparams.lod2_dist > rparams.lod_dist)
        if (lod_world) |*lw| try lod_mod.build(allocator, lw) else null
    else
        null;
    defer if (lod2_world) |*lw| lw.deinit();
    const lod2: ?*const World = if (lod2_world) |*lw| lw else null;

    var flood_stats: lighting.Stats = .{};
    var flood_ms: f64 = 0;
    if (light_enabled) {
        const fstart = std.Io.Clock.Timestamp.now(init.io, .awake);
        flood_stats = try lighting.floodAll(world, allocator, light_params);
        flood_ms = @as(f64, @floatFromInt(fstart.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds)) / 1e6;
        if (lod_world) |*lw| _ = try lighting.floodAll(lw, allocator, light_params);
        if (lod2_world) |*lw| _ = try lighting.floodAll(lw, allocator, light_params);
    }
    // Generation's dirty extents are fully covered by the initial flood.
    _ = world.takeDirty();

    if (anim_enabled) {
        anim.updatePalette(time_s);
        render.rebuildShadeLut();
    }

    if (bench_frames > 0) {
        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
        for (0..bench_frames) |_| {
            render.render(framebuffer, render_w, render_h, world, lod, lod2, cam, rparams);
            std.mem.doNotOptimizeAway(framebuffer[0]);
        }
        const ns: f64 = @floatFromInt(start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds);
        std.debug.print("bench: {} frames, {d:.3} ms/frame\n", .{ bench_frames, ns / 1e6 / @as(f64, @floatFromInt(bench_frames)) });
        if (headless_path == null) return;
    }

    if (headless_path) |path| {
        for (result.landmarks) |lm| std.log.debug("landmark ({}, {}, {})", .{ lm.x, lm.y, lm.z });
        std.log.debug("spawn ({d:.1}, {d:.1}, {d:.1}) yaw {d:.2}", .{ cam.x, cam.y, cam.z, cam.yaw });
        std.log.debug("flood: {} columns, {} runs, {d:.2} ms", .{ flood_stats.lit_columns, flood_stats.runs, flood_ms });
        render.render(framebuffer, render_w, render_h, world, lod, lod2, cam, rparams);
        render.transpose(staging, framebuffer, render_w, render_h);
        try render.writePpm(init.io, allocator, path, staging, render_w, render_h);
        return;
    }

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL_Init: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "voxel-engine",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        @intCast(window_w),
        @intCast(window_h),
        c.SDL_WINDOW_SHOWN,
    ) orelse {
        std.log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(
        window,
        -1,
        c.SDL_RENDERER_SOFTWARE | c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse {
        std.log.err("SDL_CreateRenderer: {s}", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ARGB8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(render_w),
        @intCast(render_h),
    ) orelse {
        std.log.err("SDL_CreateTexture: {s}", .{c.SDL_GetError()});
        return error.SdlTextureFailed;
    };
    defer c.SDL_DestroyTexture(texture);

    const ctx = c.nk_sdl_init(window, renderer);
    var atlas: ?*c.nk_font_atlas = null;
    c.nk_sdl_font_stash_begin(&atlas);
    c.nk_sdl_font_stash_end();
    defer c.nk_sdl_shutdown();

    _ = c.SDL_SetRelativeMouseMode(c.SDL_TRUE);
    var mouse_captured = true;
    var mouse_dx: f32 = 0;
    var place_mat: u8 = 9;
    const pick_dist: f32 = 32.0;

    var player = Player.fromCamera(cam);
    player.unstick(world);
    cam = player.camera();

    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    var last_counter = c.SDL_GetPerformanceCounter();
    var fps: f64 = 0;
    var frame: u32 = 0;
    var running = true;

    while (running) {
        c.nk_input_begin(ctx);
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            _ = c.nk_sdl_handle_event(&event);
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) {
                        if (mouse_captured) {
                            _ = c.SDL_SetRelativeMouseMode(c.SDL_FALSE);
                            mouse_captured = false;
                        } else {
                            running = false;
                        }
                    } else if (event.key.keysym.sym == c.SDLK_l) {
                        rparams.light = !rparams.light;
                        std.log.info("light {s}", .{if (rparams.light) "on" else "off"});
                    } else if (event.key.keysym.sym == c.SDLK_g) {
                        player.mode = if (player.mode == .walk) .fly else .walk;
                        player.vy = 0;
                        std.log.info("mode {s}", .{@tagName(player.mode)});
                    } else if (event.key.keysym.sym == c.SDLK_n) {
                        player.noclip = !player.noclip;
                        if (!player.noclip) player.unstick(world);
                        std.log.info("noclip {s}", .{if (player.noclip) "on" else "off"});
                    } else if (event.key.keysym.sym == c.SDLK_TAB) {
                        mouse_captured = !mouse_captured;
                        _ = c.SDL_SetRelativeMouseMode(if (mouse_captured) c.SDL_TRUE else c.SDL_FALSE);
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (mouse_captured) mouse_dx += @floatFromInt(event.motion.xrel);
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    // Captured: pick through the screen-center
                    // crosshair. Uncaptured: pick through the cursor
                    // pixel (window coords scaled to render resolution)
                    // — clicking never re-captures; Tab toggles that.
                    const left = event.button.button == c.SDL_BUTTON_LEFT;
                    const right = event.button.button == c.SDL_BUTTON_RIGHT;
                    if (left or right) {
                        var sx: f32 = @floatFromInt(render_w / 2);
                        var sy: f32 = @floatFromInt(render_h / 2);
                        if (!mouse_captured) {
                            sx = @as(f32, @floatFromInt(event.button.x)) * @as(f32, @floatFromInt(render_w)) / @as(f32, @floatFromInt(window_w));
                            sy = @as(f32, @floatFromInt(event.button.y)) * @as(f32, @floatFromInt(render_h)) / @as(f32, @floatFromInt(window_h));
                        }
                        if (pickPixel(world, cam, sx, sy, render_w, render_h, pick_dist)) |pick| {
                            if (left) {
                                try world.set(pick.hit[0], pick.hit[1], pick.hit[2], 0);
                            } else if (pick.place) |p| {
                                if (!player.overlapsVoxel(p[0], p[1], p[2])) {
                                    try world.set(p[0], p[1], p[2], place_mat);
                                    place_mat = if (place_mat == 11) 9 else place_mat + 1;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
        c.nk_input_end(ctx);

        const now_counter = c.SDL_GetPerformanceCounter();
        const dt = @as(f64, @floatFromInt(now_counter - last_counter)) / freq;
        last_counter = now_counter;
        time_s += dt;
        if (dt > 0) {
            const instant = 1.0 / dt;
            fps = if (frame == 0) instant else fps * 0.95 + instant * 0.05;
        }

        const keys = c.SDL_GetKeyboardState(null);
        var input: Input = .{ .mouse_dx = mouse_dx };
        mouse_dx = 0;
        if (keys[c.SDL_SCANCODE_W] != 0) input.forward += 1;
        if (keys[c.SDL_SCANCODE_S] != 0) input.forward -= 1;
        if (keys[c.SDL_SCANCODE_D] != 0) input.strafe += 1;
        if (keys[c.SDL_SCANCODE_A] != 0) input.strafe -= 1;
        if (keys[c.SDL_SCANCODE_SPACE] != 0) input.vertical += 1;
        if (keys[c.SDL_SCANCODE_LCTRL] != 0) input.vertical -= 1;
        input.boost = keys[c.SDL_SCANCODE_LSHIFT] != 0;
        player.update(world, input, @floatCast(dt));
        cam = player.camera();

        if (world.takeDirty()) |r| {
            if (lod_world) |*lw| {
                try lod_mod.rebuildRegion(allocator, world, lw, r);
                if (light_enabled) {
                    _ = try lighting.relight(lw, allocator, lod_mod.coarseRegion(lw, r), light_params);
                }
                if (lod2_world) |*lw2| {
                    const r1 = lod_mod.coarseRegion(lw, r);
                    try lod_mod.rebuildRegion(allocator, lw, lw2, r1);
                    if (light_enabled) {
                        _ = try lighting.relight(lw2, allocator, lod_mod.coarseRegion(lw2, r1), light_params);
                    }
                }
            }
            if (light_enabled) {
                const rstart = std.Io.Clock.Timestamp.now(init.io, .awake);
                const rstats = try lighting.relight(world, allocator, r, light_params);
                const rms = @as(f64, @floatFromInt(rstart.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds)) / 1e6;
                std.log.info("relight: {} columns, {} runs, {d:.2} ms", .{ rstats.lit_columns, rstats.runs, rms });
            }
        }
        if (anim_enabled) {
            anim.updatePalette(time_s);
            render.rebuildShadeLut();
        }

        rparams.time_s = time_s;
        render.render(framebuffer, render_w, render_h, world, lod, lod2, cam, rparams);
        render.transpose(staging, framebuffer, render_w, render_h);

        if (c.SDL_UpdateTexture(texture, null, staging.ptr, @intCast(render_w * 4)) != 0) {
            std.log.err("SDL_UpdateTexture: {s}", .{c.SDL_GetError()});
            return error.SdlTextureUpdateFailed;
        }
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);

        drawFpsOverlay(ctx, fps, window_w);
        c.nk_sdl_render(c.NK_ANTI_ALIASING_ON);

        if (mouse_captured) drawCrosshair(renderer, window_w, window_h);

        c.SDL_RenderPresent(renderer);
        frame +%= 1;
    }
}

const PickResult = struct { hit: [3]usize, place: ?[3]usize };

/// Pixel-accurate voxel picking (milestone 10): with a yaw-only camera
/// every screen pixel maps to a ray with a fixed vertical slope (rowAt
/// inverted: y = cam_y + (h/2 - row) * t / f), so the march reuses the
/// renderer's XZ DDA and tests each cell's height interval with
/// first/lastSolidInColumn — anything visible is clickable, including
/// ground below the horizon and ceilings above. Placement prefers the
/// previous XZ cell at the boundary height for side-face entries and
/// the voxel above/below the hit for top/bottom-face entries (ray
/// crosses the face plane inside the hit column); only air cells are
/// offered.
fn pickPixel(world: *const World, cam: Camera, sx: f32, sy: f32, width: usize, height: usize, max_t: f32) ?PickResult {
    const wf: f32 = @floatFromInt(width);
    const hf: f32 = @floatFromInt(height);
    const f = (wf * 0.5) / @tan(render.hfov * 0.5);
    const hx = (sx - wf * 0.5) / f;
    const fwd = cam.forward();
    const rgt = cam.right();
    const dx = fwd[0] + rgt[0] * hx;
    const dz = fwd[1] + rgt[1] * hx;
    const slope = (hf * 0.5 - sy) / f; // world y per unit XZ distance
    const wh: i32 = @intCast(world.h);
    const whf: f32 = @floatFromInt(wh);

    var dda = render.DdaIterator.init(cam.x, cam.z, dx, dz, max_t);
    while (dda.t0 < max_t) {
        const ya = cam.y + slope * dda.t0;
        const yb = cam.y + slope * dda.t1();
        // Ray receding outside the world's height: nothing more to hit.
        if ((slope >= 0 and @min(ya, yb) >= whf) or (slope <= 0 and @max(ya, yb) < 0)) break;
        const y_lo: i32 = @max(@as(i32, @intFromFloat(@floor(@min(ya, yb)))), 0);
        const y_hi: i32 = @min(@as(i32, @intFromFloat(@floor(@max(ya, yb)))), wh - 1);
        if (y_lo <= y_hi) {
            const hy: ?i32 = if (slope > 0)
                world.lastSolidInColumn(dda.ix, dda.iz, y_lo, y_hi)
            else
                world.firstSolidInColumn(dda.ix, dda.iz, y_lo, y_hi);
            if (hy) |hit_y| {
                var side: ?[3]usize = null;
                if (dda.has_prev) {
                    const piy: i32 = @intFromFloat(@floor(ya));
                    if (piy >= 0 and piy < wh and world.get(dda.px, piy, dda.pz) == 0)
                        side = .{ @intCast(dda.px), @intCast(piy), @intCast(dda.pz) };
                }
                var vert: ?[3]usize = null;
                if (slope != 0) {
                    const vy: i32 = if (slope < 0) hit_y + 1 else hit_y - 1;
                    if (vy >= 0 and vy < wh and world.get(dda.ix, vy, dda.iz) == 0)
                        vert = .{ @intCast(dda.ix), @intCast(vy), @intCast(dda.iz) };
                }
                var place: ?[3]usize = null;
                if (slope != 0) {
                    const plane_y: f32 = if (slope < 0) @floatFromInt(hit_y + 1) else @floatFromInt(hit_y);
                    const t_plane = (plane_y - cam.y) / slope;
                    place = if (t_plane <= dda.t0) side orelse vert else vert orelse side;
                } else {
                    place = side;
                }
                return .{ .hit = .{ @intCast(dda.ix), @intCast(hit_y), @intCast(dda.iz) }, .place = place };
            }
        }
        dda.advance();
    }
    return null;
}

/// Center crosshair marking the captured-mouse pick point.
fn drawCrosshair(renderer: ?*c.SDL_Renderer, window_w: usize, window_h: usize) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    const cx: c_int = @intCast(window_w / 2);
    const cy: c_int = @intCast(window_h / 2);
    const horiz: c.SDL_Rect = .{ .x = cx - 5, .y = cy - 1, .w = 11, .h = 3 };
    const vert: c.SDL_Rect = .{ .x = cx - 1, .y = cy - 5, .w = 3, .h = 11 };
    _ = c.SDL_RenderFillRect(renderer, &horiz);
    _ = c.SDL_RenderFillRect(renderer, &vert);
}

fn drawFpsOverlay(ctx: ?*c.nk_context, fps: f64, window_w: usize) void {
    const w: f32 = 110;
    const h: f32 = 36;
    const bounds: c.struct_nk_rect = .{ .x = @as(f32, @floatFromInt(window_w)) - w - 8, .y = 8, .w = w, .h = h };
    const flags = c.NK_WINDOW_NO_SCROLLBAR | c.NK_WINDOW_NO_INPUT;

    if (c.nk_begin(ctx, "fps", bounds, flags) != 0) {
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.1} fps", .{fps}) catch "? fps";
        c.nk_layout_row_dynamic(ctx, 22, 1);
        c.nk_label(ctx, text.ptr, c.NK_TEXT_CENTERED);
    }
    c.nk_end(ctx);
}

test {
    _ = render;
    _ = gen;
    _ = lighting;
    _ = anim;
    _ = @import("world.zig");
    _ = @import("camera.zig");
    _ = @import("player.zig");
}

test "pickPixel hits the voxel under the pixel" {
    const world_mod = @import("world.zig");
    var world = try world_mod.World.init(std.testing.allocator, 8, 8, 8);
    defer world.deinit();
    try world.fillBox(5, 2, 2, 6, 4, 3, 1); // wall at x=5, y 2..3, z=2
    try world.fillBox(0, 0, 0, 8, 1, 8, 1); // floor at y=0
    try world.fillBox(5, 6, 2, 6, 7, 3, 1); // ceiling voxel (5,6,2)
    const cam: Camera = .{ .x = 1.5, .y = 2.5, .z = 2.5, .yaw = 0 };
    // 8x8 "screen": f = 4, center pixel (4,4) is the horizontal ray.

    // Center pixel: horizontal hit on the wall, side placement.
    const wall = pickPixel(&world, cam, 4.0, 4.0, 8, 8, 16.0).?;
    try std.testing.expectEqual([3]usize{ 5, 2, 2 }, wall.hit);
    try std.testing.expectEqual([3]usize{ 4, 2, 2 }, wall.place.?);

    // Bottom row: steep down-ray hits the floor, placement on top.
    const floor_pick = pickPixel(&world, cam, 4.0, 8.0, 8, 8, 16.0).?;
    try std.testing.expectEqual(@as(usize, 0), floor_pick.hit[1]);
    try std.testing.expectEqual(@as(usize, 1), floor_pick.place.?[1]);

    // sy 0.5 (slope 0.875): up-ray meets the ceiling voxel's bottom
    // face inside its column, placement below it.
    const ceil = pickPixel(&world, cam, 4.0, 0.5, 8, 8, 16.0).?;
    try std.testing.expectEqual([3]usize{ 5, 6, 2 }, ceil.hit);
    try std.testing.expectEqual([3]usize{ 5, 5, 2 }, ceil.place.?);

    // Nothing within range.
    try std.testing.expectEqual(@as(?PickResult, null), pickPixel(&world, cam, 4.0, 4.0, 8, 8, 2.0));
    // Looking back at open air: no hit.
    try std.testing.expectEqual(@as(?PickResult, null), pickPixel(&world, .{ .x = 1.5, .y = 2.5, .z = 2.5, .yaw = std.math.pi }, 4.0, 4.0, 8, 8, 16.0));
}
