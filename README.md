# Astro2PNG

Batch-convert **XISF** (PixInsight) and **FITS** astronomical images to
**PNG**, optionally resized to 4K with the object's name and catalogue info
stamped in the corner. A [Zig](https://ziglang.org) CLI/GUI on top of
[`astropng-core`](https://github.com/peterbuitho/astropng-core) — see
[Architecture](#architecture) — a shared conversion pipeline also used by
this program's Rust/Go/Scala ports.

Each image's full data range is linearly scaled to 0–255 (a plain min/max
stretch — no STF/MTF astronomical stretch). Only the first image in a file is
converted. Mono and RGB images are supported.

## Status

Feature parity with the original for both the CLI and the GUI (all format
parsing, stretch, resize/stamp, lookup and catalogue logic now lives in
`astropng-core`, not in this repo). Not yet ported: the single-instance file
hand-off and the optional user names file.

## Architecture

The conversion pipeline (XISF/FITS parsing, stretch, resize/stamp, WCS,
SIMBAD lookup, batch orchestration) lives in
[`astropng-core`](https://github.com/peterbuitho/astropng-core), a Rust
library shared with this program's Rust/Go/Scala ports. `src/batch.zig` is a
thin FFI wrapper around its C ABI, using Zig's built-in C header translator
(`@cImport`) directly on the vendored header — see
`third_party/astropng-core/VERSION` for the pinned version and
`scripts/build-core.sh` for how it's built. `src/cli.zig` and `src/gui/` are
unaware of the swap; they only ever called `batch.zig`'s public API.

## Build from source

Requires [Zig 0.16.0](https://ziglang.org/download/) and a
[Rust toolchain](https://rustup.rs) (to build `astropng-core`).

```
bash scripts/build-core.sh   # builds third_party/astropng-core/lib/libastropng_core.a
zig build                    # debug build -> zig-out/bin/astro2png
zig build -Doptimize=ReleaseFast
zig build run -- --help
zig build test                # unit tests
```

The desktop GUI is opt-in (it links SDL3, built from source as a lazy
dependency — no system SDL needed):

```
zig build -Dgui           # -> zig-out/bin/astro2png-gui
zig build run-gui
```

On Linux the GUI build needs a few X11/Wayland/GL development headers
(`libx11-dev libxext-dev libwayland-dev libxkbcommon-dev libgl1-mesa-dev` on
Debian/Ubuntu).

## Command line

```
astro2png [input_dir] [output_dir] [--recursive|-r] [--overwrite] [--resize4k] [--filename] [-j N]
astro2png [input_dir] [output_dir] --png-only [--recursive|-r] [--overwrite] [--filename]
astro2png <file>... [output_dir] [--overwrite] [--resize4k] [--filename]
```

Every `.xisf`, `.fits`, `.fit` and `.fts` file found is converted. If
`input_dir` is omitted, the current folder is used. If `output_dir` is
omitted, PNGs are written next to their source files. Explicit files may be
given instead of a folder; `.png` files are only resized/stamped.

Files are converted **in parallel** (one worker per CPU, capped at 8,
override with `-j`) by `astropng-core`. The online object lookup is
serialised behind a shared cache, so a folder of 300 subs of one target still
costs only one or two SIMBAD requests. Progress is printed in completion
order.

| Option              | Meaning |
| ------------------- | ------- |
| `-r`, `--recursive` | Recurse into subfolders; the output tree mirrors the input. |
| `--overwrite`       | Overwrite existing `.png` files (default: skip them). |
| `--resize4k`        | Scale each PNG (aspect kept) to cover 3840×2160, centre-crop to exactly 3840×2160, and stamp the object name bottom-right — identified from the header `OBJECT`, a catalogue id in the file name (`M31`, `NGC_7000`, `Sh2-155`, …) and/or the image coordinates, resolved via CDS Sesame / SIMBAD and cross-checked. Falls back to the file name offline. |
| `--filename`        | Stamp the plain file name: ignore the header `OBJECT`, never go online. Aliases: `--no-lookup`, `--offline`. |
| `--png-only`        | Skip XISF/FITS conversion: pick up existing `.png` files and only run the resize step (implies `--resize4k`). |
| `--font <file>`     | A `.ttf` / `.otf` font file for the stamp. Default: bundled DejaVu Sans Condensed Bold. |
| `-j`, `--concurrency N` | Convert `N` files in parallel. Default: number of CPUs, capped at 8. |
| `-V`, `--version`   | Print the version. |
| `-h`, `--help`      | Show help. |

Per-file output lines: `OK <path>`, `SKIP <path>`, `ERROR <path>: <reason>`.
Exit code is `1` if any file failed, `2` for a usage error, `0` otherwise.

## Releases

Prebuilt binaries for Windows, Linux (x86-64 + ARM64) and macOS are attached
to each [GitHub Release](https://github.com/peterbuitho/Astro2PNG/releases),
built natively per target by
[`.github/workflows/release.yml`](.github/workflows/release.yml) (native
builds are required now that both the CLI and GUI link `astropng-core` as a
native library). To cut a release, push a tag:

```
git tag v0.1.0
git push origin v0.1.0
```

## Credits

Port of [`xisf2png`](https://github.com/peterbuitho/xisf2png) by peterbuitho.
The bundled stamp font, DejaVu Sans Condensed Bold, is embedded in
`astropng-core`; its licence is in
[`astropng-core/assets/fonts/LICENSE-DejaVu.txt`](https://github.com/peterbuitho/astropng-core/blob/main/assets/fonts/LICENSE-DejaVu.txt).
