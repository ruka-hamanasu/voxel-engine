# Portability: vendored SDL2 + pinned old glibc

Goal: one self-contained Linux binary that runs on any desktop distro
without worrying about system library versions.

## Approach

- SDL2 2.32.4 is **vendored** (hash-pinned dep in `build.zig.zon`),
  compiled from source with zig cc and **linked statically** into
  `voxel_engine` (build glue: `build/sdl.zig`, config:
  `build/config/SDL_config.h`). SDL2's zlib license permits static
  linking as-is.
- The binary stays **dynamic against glibc**, and release builds pin an
  old version floor:

  ```
  zig build -Dtarget=x86_64-linux-gnu.2.28 -Doptimize=ReleaseSafe
  ```

  glibc is forward-compatible, so the binary runs on any distro with
  glibc >= 2.28 (Debian 10+, Ubuntu 18.10+, Fedora 29+, ~2018 on).
  Verified: the binary's highest required symbol version is GLIBC_2.28,
  and `ldd` shows only libc/libm/libpthread/libdl (all glibc).
- X11 support uses SDL's **runtime dynamic loading**: SDL dlopens
  libX11/libXext/libXcursor/libXi/libXfixes/libXrandr/libXss at startup
  (`SDL_VIDEO_DRIVER_X11_DYNAMIC*` in the config) and uses whatever the
  host has — the binary neither links nor bundles any X11 library, and
  doesn't care about the host's X11 versions. Only the X11 **headers**
  are needed at compile time; they come from header-only zon deps
  (xorgproto, libX11, libXext, libXcursor, libXfixes, libXi, libXrandr,
  libXrender, libXScrnSaver) — nothing from them is compiled.
  Two generated headers are written by the build glue: SDL_revision.h
  and X11/XlibConf.h (normally configure outputs).

## Why not fully static musl?

A fully static binary cannot dlopen, so X11/Wayland support would
require vendoring and statically linking the entire X11 and Wayland
client stacks (~10 packages, plus pregenerated wayland protocol code).
That remains an option if musl distros (Alpine, Void-musl) or pre-2018
glibc ever matter; the vendored-SDL infrastructure extends to it. For a
desktop GUI app the glibc floor is nearly always a non-issue, since the
target systems need a full X11/Wayland stack installed anyway.

## SDL config decisions (`build/config/SDL_config.h`)

Derived from SDL 2.32.4's cmake-configured output for this platform,
then trimmed:

- Video: X11 only, all extensions dlopened. Wayland/KMSDRM/offscreen
  disabled (Wayland is cheap to add later in this model: header-only
  wayland + libxkbcommon deps plus pregenerated protocol code; runtime
  stays dlopen).
- Audio, joystick, haptic, hidapi, sensor disabled (the app uses video,
  events, timers); dummy drivers fill the subsystem stubs.
- dbus/ibus/fcitx/udev/evdev/libsamplerate removed — they need system
  headers at compile time and are unused without audio/joystick/KMSDRM.
  Consequence: X11 text input uses plain XIM (libX11), no ibus/fcitx.
- `HAVE_STRLCPY/STRLCAT/WCSLCPY/WCSLCAT` removed — glibc only gained
  these in 2.38, which would break the 2.28 floor; SDL falls back to
  its own implementations. When bumping SDL versions, re-check the
  generated config for libc functions newer than the pinned floor.
- dynapi stays on (SDL forbids `-DSDL_DYNAMIC_API=0`; the jump table
  works fine statically linked).

## Bumping the glibc floor or SDL version

- Floor: change the `-Dtarget=x86_64-linux-gnu.NN` in the release
  command; check with `readelf -V` that the highest GLIBC_ symbol
  matches.
- SDL: bump the `sdl2` dep URL/hash, regenerate the file list from a
  cmake configure of the new version (with the same options used in
  `build/sdl.zig`'s comment history), and re-derive the config the same
  way (cmake configure on a glibc machine, then trim per above).
