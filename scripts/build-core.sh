#!/usr/bin/env bash
# Builds astropng-core (the shared conversion pipeline, see
# third_party/astropng-core/VERSION for the pinned tag) and drops the static
# library where build.zig expects it
# (third_party/astropng-core/lib/libastropng_core.a). Requires a Rust
# toolchain (cargo) on PATH. Safe to re-run; re-clones/rebuilds only if the
# pinned tag or cached checkout changed.
#
# On macOS, builds both Apple Silicon and Intel and lipo-merges them into one
# universal static lib, matching xisf2png's own macOS-universal release step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag="$(cat "$repo_root/third_party/astropng-core/VERSION")"
cache_dir="${ASTROPNG_CORE_CACHE:-$HOME/.cache/astropng-core}/$tag"
lib_dir="$repo_root/third_party/astropng-core/lib"

if [[ ! -d "$cache_dir" ]]; then
    echo "Cloning astropng-core@$tag into $cache_dir"
    git clone --quiet --depth 1 --branch "$tag" \
        https://github.com/peterbuitho/astropng-core "$cache_dir"
fi

mkdir -p "$lib_dir"

if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Building astropng-core@$tag (release, universal macOS)"
    rustup target add x86_64-apple-darwin aarch64-apple-darwin
    (cd "$cache_dir" && cargo build --release --lib --target x86_64-apple-darwin)
    (cd "$cache_dir" && cargo build --release --lib --target aarch64-apple-darwin)
    lipo -create -output "$lib_dir/libastropng_core.a" \
        "$cache_dir/target/x86_64-apple-darwin/release/libastropng_core.a" \
        "$cache_dir/target/aarch64-apple-darwin/release/libastropng_core.a"
    lipo -info "$lib_dir/libastropng_core.a"
else
    target_dir="target"
    target_flag=""
    if [[ "${OS:-}" == "Windows_NT" || "${RUNNER_OS:-}" == "Windows" ]]; then
        # Zig's linker on Windows expects a GNU-style archive; rustup's
        # default target there is MSVC, which produces an incompatible
        # astropng_core.lib instead of libastropng_core.a.
        rustup target add x86_64-pc-windows-gnu
        target_flag="--target x86_64-pc-windows-gnu"
        target_dir="target/x86_64-pc-windows-gnu"
    fi
    echo "Building astropng-core@$tag (release)"
    # Word-splitting $target_flag is intentional (fixed, controlled value).
    (cd "$cache_dir" && cargo build --release --lib $target_flag)
    cp "$cache_dir/$target_dir/release/libastropng_core.a" "$lib_dir/"
fi

echo "Ready: $lib_dir/libastropng_core.a"
