# Astro2PNG

Batch-convert **XISF** (PixInsight) and **FITS** astronomical images to
**PNG**, optionally resized to 4K with the object's name and catalogue info
stamped in the corner. A pure-[Zig](https://ziglang.org) port of
[`xisf2png`](https://github.com/peterbuitho/xisf2png) — no C dependencies, no
runtime dependencies, cross-compiled to every desktop platform from one build.

Each image's full data range is linearly scaled to 0–255 (a plain min/max
stretch — no STF/MTF astronomical stretch). Only the first image in a file is
converted. Mono and RGB images are supported.

## Status

This is an in-progress port. What works today:

| Area | State |
| --- | --- |
| XISF reader (mono/RGB, UInt8/16/32/64, Float32/64, planar & interleaved, little/big-endian) | ✅ |
| XISF data location `attachment` / `embedded` / `inline` (base64, hex) | ✅ |
| XISF compression `zlib`, `lz4`, `lz4hc`, `zstd`, with/without byte-shuffle | ✅ |
| FITS reader (BITPIX 8/16/32/64/−32/−64, NAXIS 2 or 3, BZERO/BSCALE, ROWORDER) | ✅ |
| Linear min/max stretch to 8-bit | ✅ |
| PNG encode (adaptive filtering, zlib via Zig std) + decode | ✅ |
| WCS / coordinate parsing (plate solution and mount target, FOV estimate) | ✅ |
| CLI: folder scan, recursion, explicit file list, `--overwrite`, exit codes | ✅ |
| `--resize4k` / `--png-only` cover-and-crop to 3840×2160 | ✅ |
| TrueType glyph rasteriser (`cmap` 4/12, composites, `kern`) + corner stamp | ✅ (white text + drop shadow, two-line, auto-shrink) |
| `--filename` stamp (file-name stem / header `OBJECT`) | ✅ |
| SIMBAD / CDS Sesame online object lookup + Caldwell/nickname catalogues | ⬜ not ported yet — the stamp currently shows the file name or header `OBJECT`, never goes online |
| Desktop GUI | ⬜ not ported yet (see note below) |
| Windows Explorer / Linux desktop right-click integration | ⬜ not ported yet |

### Roadmap

1. ~~`ttf.zig` — TrueType rasteriser + corner stamp.~~ ✅
2. `catalog.zig` + `lookup.zig` — the Caldwell table, ~150 curated nicknames,
   and the CDS Sesame / SIMBAD TAP queries (HTTPS via `std.http.Client`, XML
   and TSV parsing already have a home in `xml.zig`).
3. Desktop GUI. Zig has no mature pure-Zig windowing + GPU stack, so the GUI
   will use one small C dependency (SDL or GLFW) under a Zig UI layer
   ([`dvui`](https://github.com/david-vanderson/dvui) is the leading
   candidate). The conversion engine (`src/root.zig`) is already GUI-ready.

## Build from source

Requires [Zig 0.16.0](https://ziglang.org/download/). No C toolchain, no
system libraries.

```
zig build                 # debug build -> zig-out/bin/astro2png
zig build -Doptimize=ReleaseFast
zig build run -- --help
zig build test            # unit tests
```

Cross-compile every release target into `zig-out/release/<triple>/`:

```
zig build release -Dversion=1.2.3
```

## Command line

```
astro2png [input_dir] [output_dir] [--recursive|-r] [--overwrite] [--resize4k] [--filename]
astro2png [input_dir] [output_dir] --png-only [--recursive|-r] [--overwrite] [--filename]
astro2png <file>... [output_dir] [--overwrite] [--resize4k] [--filename]
```

Every `.xisf`, `.fits`, `.fit` and `.fts` file found is converted. If
`input_dir` is omitted, the current folder is used. If `output_dir` is
omitted, PNGs are written next to their source files. Explicit files may be
given instead of a folder; `.png` files are only resized/stamped.

| Option              | Meaning |
| ------------------- | ------- |
| `-r`, `--recursive` | Recurse into subfolders; the output tree mirrors the input. |
| `--overwrite`       | Overwrite existing `.png` files (default: skip them). |
| `--resize4k`        | Scale each PNG (aspect kept) to cover 3840×2160, then centre-crop to exactly 3840×2160. (The object-name stamp is not drawn yet.) |
| `--filename`        | Stamp the plain file name: ignore the header `OBJECT`, never go online. Aliases: `--no-lookup`, `--offline`. |
| `--png-only`        | Skip XISF/FITS conversion: pick up existing `.png` files and only run the resize step (implies `--resize4k`). |
| `--font <file>`     | A `.ttf` / `.otf` font file for the stamp. Default: bundled DejaVu Sans Condensed Bold. |
| `-V`, `--version`   | Print the version. |
| `-h`, `--help`      | Show help. |

Per-file output lines: `OK <path>`, `SKIP <path>`, `ERROR <path>: <reason>`.
Exit code is `1` if any file failed, `2` for a usage error, `0` otherwise.

## Releases

Prebuilt binaries for Windows, macOS (Intel + Apple Silicon) and Linux
(x86-64 + ARM64) are attached to each
[GitHub Release](https://github.com/peterbuitho/Astro2PNG/releases), built by
[`.github/workflows/release.yml`](.github/workflows/release.yml). Because the
CLI is pure Zig, all six binaries are cross-compiled from a single Linux
runner. To cut a release, push a tag:

```
git tag v0.1.0
git push origin v0.1.0
```

## Credits

Port of [`xisf2png`](https://github.com/peterbuitho/xisf2png) by peterbuitho.
The bundled stamp font, DejaVu Sans Condensed Bold, keeps its own licence
([`assets/fonts/LICENSE-DejaVu.txt`](assets/fonts/LICENSE-DejaVu.txt)).
