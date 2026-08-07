# Single-Pass Column Lighting (Zipper Merge)

Source: Gemini discussion captured in
`Has anyone made a software ray-casting renderer for a Minecraft-like game_ - Google Search.html`
(final exchanges, ~3:37–3:51 PM). This document distills the algorithm; see
"Relationship to PLAN.md" at the end for how it maps onto the actual engine
design.

## Problem

Per-voxel 3D flood-fill lighting produces smooth gradients (15, 14, 13, ...),
giving nearly every voxel a unique light value. That destroys run-length
compression: long material runs can no longer be grouped, memory balloons, and
the column render loop degenerates into processing dozens of 1-voxel runs.

The fix is to **separate the thing being lit (geometry) from the light hitting
it**, storing each as its own compressed 1D stream per column, and merging
them at render time.

## Data structures

Each (x, z) column owns two independent, top-to-bottom sorted RLE streams:

```c
typedef struct {
    uint8_t count;       // voxels tall
    uint8_t material_id; // index into palette/profile table
} MaterialRun;

typedef struct {
    uint8_t count;
    uint8_t light_color; // e.g. packed: 4 bits intensity, 4 bits color ID
} LightRun;

typedef struct { uint16_t run_count; MaterialRun *runs; } RLE_Column;
typedef struct { uint16_t run_count; LightRun    *runs; } Light_Column;
```

The light stream's run boundaries **do not** align with the material stream's.
Light pools around emissive sources in broad zones, so a 256-tall column's
vertical light profile compresses to a handful of intervals:

```
[Light Stream - 256 blocks tall]
-> { count: 120, light: PITCH_BLACK  }   (sky/roof zone)
-> { count: 10,  light: DIM_PINK     }   (approaching the sign)
-> { count: 20,  light: INTENSE_PINK }   (next to the neon sign)
-> { count: 15,  light: DIM_PINK     }   (falloff below)
-> { count: 91,  light: PITCH_BLACK  }   (ground/alley floor)
```

A 100-block concrete wall stays a single pristine material run regardless of
how many light zones cross it.

## Why one pass suffices

An earlier two-pass design scanned both streams into a temporary array of
`RenderSpan` structs (Pass 1), then blitted them (Pass 2). That temporary
array is unnecessary: **both streams are sorted in the same direction
(top to bottom), so they can be advanced concurrently like a zipper.** Segment
generation, screen projection, and pixel blitting fuse into a single loop that
processes whichever run terminates first, keeping all state in registers.

## The single-pass core loop

```c
int mat_y_cursor = 255;              // world Y of current stream positions
int lit_y_cursor = 255;
int mat_idx = 0, lit_idx = 0;

RLE_Column  *mat_col = &chunk->material_columns[ray_x][ray_z];
Light_Column *lit_col = &chunk->light_columns[ray_x][ray_z];

MaterialRun current_mat = mat_col->runs[0];
LightRun    current_lit = lit_col->runs[0];

while (mat_y_cursor > 0 && lit_y_cursor > 0) {
    // 1. Segment top = higher of the two cursor positions
    int seg_top = min(mat_y_cursor, lit_y_cursor);

    // 2. Segment bottom = higher of the two run bottoms
    //    (i.e. whichever run terminates first)
    int mat_bottom = mat_y_cursor - current_mat.count;
    int lit_bottom = lit_y_cursor - current_lit.count;
    int seg_bottom = max(mat_bottom, lit_bottom);

    // 3. If the active geometry is solid, shade and blit immediately
    if (current_mat.type != VOXEL_AIR) {
        int screen_top    = screen_center_y + (seg_top    - camera_y) * scale;
        int screen_bottom = screen_center_y + (seg_bottom - camera_y) * scale;
        screen_top    = clamp(screen_top, 0, screen_height - 1);
        screen_bottom = clamp(screen_bottom, 0, screen_height - 1);

        if (ClipToVisible1DSpans(screen_x, &screen_top, &screen_bottom)) {
            // Final color computed ONCE per uniform segment
            uint32_t color = VoxelPalette[current_mat.type];
            if (current_lit.light_color != COLOR_BLACK)
                color = BlendWithGlow(color, current_lit.light_color);
            color = ApplyFaceShading(color, hit_axis);
            color = ApplyFog(color, distance);

            // Inner blit: flat register-to-memory fill, no branches/lookups
            uint32_t *dest = &screen_buffer[screen_x][screen_top * pitch];
            for (int p = 0; p < screen_bottom - screen_top; p++) {
                *dest = color;
                dest += pitch;
            }
        }
    }

    // 4. Advance whichever run(s) ended at the segment bottom
    if (mat_bottom >= seg_bottom) {
        mat_y_cursor = mat_bottom;
        if (++mat_idx < mat_col->run_count)
            current_mat = mat_col->runs[mat_idx];
    }
    if (lit_bottom >= seg_bottom) {
        lit_y_cursor = lit_bottom;
        if (++lit_idx < lit_col->run_count)
            current_lit = lit_col->runs[lit_idx];
    }
}
```

## Properties

- **No temporary allocation.** The two-pass design wrote merged spans to RAM
  and read them straight back; the zipper keeps all tracking state in local
  variables/registers.
- **Branch efficiency.** The merge/step logic runs only a handful of times
  per screen column (~5–10 iterations for a complex building). The bulk of CPU
  time sits in the uninterrupted inner blit.
- **Air is free.** When the material run is air, all projection, clipping, and
  blending is skipped; only the cursors advance.
- **Vertical falloff is real.** A window beside a neon sign and a window far
  below it land in different `LightRun` intervals and are shaded differently,
  while both world data and light data stay RLE-compressed.
- **Fog scattering composes cleanly.** A per-column ambient fog color (from a
  pre-calculated 2D fog-glow map, looked up at the ray's hit point and scaled
  by distance) is computed once before the vertical loop and passed into
  `ApplyFog`, so the inner blit is untouched.

## Adoption in PLAN.md

PLAN.md now adopts this algorithm directly:

1. **Material stream:** columns store `{count, palette_id}` RLE runs
   top-to-bottom — no occupancy bitmap, no random access to voxels. Renderer
   bands, shadow rays, and sky-light defaults all operate on vertical
   intervals via overlap scans.
2. **Light stream:** lazy `{count, color_id, intensity}` RLE runs, allocated
   only where values deviate from the material-derived default (full sky
   light above the topmost solid run, dark below).
3. **Sampling:** the plan's air-cell light sampling is removed; light applies
   to the column's own voxels, exactly as in the zipper loop above.
4. **Light format:** single colored light channel per the discussion. The run
   carries a `color_id` (small light-color palette) plus a `u8` intensity —
   kept wider than the discussion's 4-bit example because the plan's 3–6 m
   attenuation radius at 10 cm voxel scale needs ~30–60 steps.

Plan-specific pieces layered on top of the discussion: sky-light seeding
with a free downward fast-path, incremental clear-then-reflood edits, the
Model B directional sun march (interval-tested against material runs), fake
AO, and distance fog. Runs use `u8` counts as in the discussion — runs
longer than 255 voxels are split into consecutive identical runs — and all
run fields are `u8`, so the structs (2 B material, 3 B light) have alignment
1, zero padding, and maximum cache density.

Note: the pseudocode above writes the inner blit strided (`dest += pitch`).
PLAN.md instead stores the framebuffer column-major (rotated 90°), so the
blit is a sequential fill and rotation happens once per frame at
presentation — the merge/step logic is unaffected.
