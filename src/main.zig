const std = @import("std");
const c = @cImport({
    @cInclude("nk_config.h");
    @cInclude("SDL.h");
    @cInclude("nuklear.h");
    @cInclude("nuklear_sdl_renderer.h");
});
const Input = @import("camera.zig").Input;
const render = @import("render.zig");
const gen = @import("gen.zig");
const lighting = @import("lighting.zig");

const render_w = 480;
const render_h = 270;
const window_w = 960;
const window_h = 540;

var framebuffer: [render_w * render_h]u32 = undefined;
var staging: [render_w * render_h]u32 = undefined;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    var headless_path: ?[]const u8 = null;
    var opts: gen.Options = .{};
    var generator: gen.Generator = .terrain;
    var cam_override: ?[4]f32 = null;
    var bench_frames: u32 = 0;
    var fog_density: ?f32 = null;
    var light_enabled = true;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--headless")) {
            i += 1;
            if (i >= args.len) return error.MissingHeadlessPath;
            headless_path = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingSeedValue;
            opts.seed = try std.fmt.parseInt(u64, std.mem.span(args[i]), 10);
        } else if (std.mem.eql(u8, arg, "--gen")) {
            i += 1;
            if (i >= args.len) return error.MissingGeneratorName;
            generator = std.meta.stringToEnum(gen.Generator, std.mem.span(args[i])) orelse return error.UnknownGenerator;
        } else if (std.mem.eql(u8, arg, "--cam")) {
            i += 1;
            if (i >= args.len) return error.MissingCamValue;
            var parts = std.mem.splitScalar(u8, std.mem.span(args[i]), ',');
            var vals: [4]f32 = undefined;
            for (&vals) |*v| {
                const part = parts.next() orelse return error.BadCamValue;
                v.* = try std.fmt.parseFloat(f32, part);
            }
            cam_override = vals;
        } else if (std.mem.eql(u8, arg, "--bench")) {
            i += 1;
            if (i >= args.len) return error.MissingBenchValue;
            bench_frames = try std.fmt.parseInt(u32, std.mem.span(args[i]), 10);
        } else if (std.mem.eql(u8, arg, "--fog")) {
            i += 1;
            if (i >= args.len) return error.MissingFogValue;
            fog_density = try std.fmt.parseFloat(f32, std.mem.span(args[i]));
        } else if (std.mem.eql(u8, arg, "--light")) {
            i += 1;
            if (i >= args.len) return error.MissingLightValue;
            light_enabled = (try std.fmt.parseInt(u8, std.mem.span(args[i]), 10)) != 0;
        }
    }

    const allocator = init.gpa;
    var result = try gen.generate(generator, allocator, opts);
    defer result.deinit(allocator);
    const world = &result.world;
    var cam = result.spawn;
    if (cam_override) |v| cam = .{ .x = v[0], .y = v[1], .z = v[2], .yaw = v[3] };
    render.rebuildShadeLut();
    var rparams: render.RenderParams = .{};
    if (fog_density) |d| rparams.fog_density = d;

    var flood_stats: lighting.Stats = .{};
    var flood_ms: f64 = 0;
    if (light_enabled) {
        const fstart = std.Io.Clock.Timestamp.now(init.io, .awake);
        flood_stats = try lighting.floodAll(world, allocator, .{});
        flood_ms = @as(f64, @floatFromInt(fstart.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.nanoseconds)) / 1e6;
    }

    if (bench_frames > 0) {
        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
        for (0..bench_frames) |_| {
            render.render(&framebuffer, render_w, render_h, world, cam, rparams);
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
        render.render(&framebuffer, render_w, render_h, world, cam, rparams);
        render.transpose(&staging, &framebuffer, render_w, render_h);
        try render.writePpm(init.io, allocator, path, &staging, render_w, render_h);
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
        window_w,
        window_h,
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
        render_w,
        render_h,
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

    const freq: f64 = @floatFromInt(c.SDL_GetPerformanceFrequency());
    var last_counter = c.SDL_GetPerformanceCounter();
    var time_s: f64 = 0;
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
                    }
                },
                c.SDL_MOUSEMOTION => {
                    if (mouse_captured) mouse_dx += @floatFromInt(event.motion.xrel);
                },
                c.SDL_MOUSEBUTTONDOWN => {
                    if (!mouse_captured) {
                        _ = c.SDL_SetRelativeMouseMode(c.SDL_TRUE);
                        mouse_captured = true;
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
        cam.update(input, @floatCast(dt), world.w, world.h, world.d);

        rparams.time_s = time_s;
        render.render(&framebuffer, render_w, render_h, world, cam, rparams);
        render.transpose(&staging, &framebuffer, render_w, render_h);

        if (c.SDL_UpdateTexture(texture, null, &staging, render_w * 4) != 0) {
            std.log.err("SDL_UpdateTexture: {s}", .{c.SDL_GetError()});
            return error.SdlTextureUpdateFailed;
        }
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);

        drawFpsOverlay(ctx, fps);
        c.nk_sdl_render(c.NK_ANTI_ALIASING_ON);

        c.SDL_RenderPresent(renderer);
        frame +%= 1;
    }
}

fn drawFpsOverlay(ctx: ?*c.nk_context, fps: f64) void {
    const w: f32 = 110;
    const h: f32 = 36;
    const bounds: c.struct_nk_rect = .{ .x = window_w - w - 8, .y = 8, .w = w, .h = h };
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
    _ = @import("world.zig");
    _ = @import("camera.zig");
}
