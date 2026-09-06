//! LZ4 block-format decompression (no frame header) — what XISF uses for its
//! `lz4` and `lz4hc` codecs. Both compress to the same block format, so one
//! decoder handles both.

const std = @import("std");

pub const Error = error{ Lz4Corrupt, Lz4OutputMismatch };

/// Decompress an LZ4 block into a freshly allocated buffer of exactly
/// `uncompressed_size` bytes.
pub fn decompressBlock(gpa: std.mem.Allocator, src: []const u8, uncompressed_size: usize) (Error || error{OutOfMemory})![]u8 {
    const out = try gpa.alloc(u8, uncompressed_size);
    errdefer gpa.free(out);
    try decompressBlockInto(src, out);
    return out;
}

pub fn decompressBlockInto(src: []const u8, dst: []u8) Error!void {
    var sp: usize = 0;
    var dp: usize = 0;

    while (sp < src.len) {
        const token = src[sp];
        sp += 1;

        // Literals.
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            while (true) {
                if (sp >= src.len) return error.Lz4Corrupt;
                const b = src[sp];
                sp += 1;
                lit_len += b;
                if (b != 255) break;
            }
        }
        if (sp + lit_len > src.len) return error.Lz4Corrupt;
        if (dp + lit_len > dst.len) return error.Lz4Corrupt;
        @memcpy(dst[dp .. dp + lit_len], src[sp .. sp + lit_len]);
        sp += lit_len;
        dp += lit_len;

        // The last sequence contains only literals; the match section is absent.
        if (sp == src.len) break;
        if (sp + 2 > src.len) return error.Lz4Corrupt;

        const offset: usize = @as(usize, src[sp]) | (@as(usize, src[sp + 1]) << 8);
        sp += 2;
        if (offset == 0 or offset > dp) return error.Lz4Corrupt;

        var match_len: usize = token & 0x0f;
        if (match_len == 15) {
            while (true) {
                if (sp >= src.len) return error.Lz4Corrupt;
                const b = src[sp];
                sp += 1;
                match_len += b;
                if (b != 255) break;
            }
        }
        match_len += 4; // minmatch

        if (dp + match_len > dst.len) return error.Lz4Corrupt;
        // Overlapping copy: must be byte-by-byte when offset < match_len.
        var m: usize = 0;
        const from = dp - offset;
        while (m < match_len) : (m += 1) {
            dst[dp + m] = dst[from + m];
        }
        dp += match_len;
    }

    if (dp != dst.len) return error.Lz4OutputMismatch;
}

const testing = std.testing;

test "round trip a known block" {
    // "abcabcabcabc\n" — literal "abc\n" won't cover; use a simple hand block.
    // Block: token 0x40 => 4 literals, no match at end.
    const src = [_]u8{ 0x40, 'a', 'b', 'c', 'd' };
    var dst: [4]u8 = undefined;
    try decompressBlockInto(&src, &dst);
    try testing.expectEqualStrings("abcd", &dst);
}

test "overlap copy" {
    // 1 literal 'a', then match offset=1 len=4 (token low nibble = 0 => 4).
    const src = [_]u8{ 0x10, 'a', 0x01, 0x00 };
    var dst: [5]u8 = undefined;
    try decompressBlockInto(&src, &dst);
    try testing.expectEqualStrings("aaaaa", &dst);
}
