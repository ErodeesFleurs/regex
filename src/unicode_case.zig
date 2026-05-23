const std = @import("std");

/// Fold a Unicode codepoint to its case-insensitive form (simple case folding).
/// Returns the folded codepoint(s) in the provided buffer.
/// Most characters fold to a single codepoint, but some (like 'ß') fold to multiple.
/// Returns the number of codepoints written.
pub fn foldCase(cp: u21, out: *[4]u21) usize {
    // ASCII fast path
    if (cp <= 0x7F) {
        if (cp >= 'A' and cp <= 'Z') {
            out[0] = cp + 0x20;
            return 1;
        }
        out[0] = cp;
        return 1;
    }

    // Latin-1 Supplement (U+0080 - U+00FF)
    if (cp >= 0x00C0 and cp <= 0x00D6) {
        out[0] = cp + 0x20;
        return 1;
    }
    if (cp >= 0x00D8 and cp <= 0x00DE) {
        out[0] = cp + 0x20;
        return 1;
    }
    if (cp == 0x00DF) {
        // ß -> ss
        out[0] = 's';
        out[1] = 's';
        return 2;
    }
    // 0x00E0 - 0x00F6: already lowercase, no change
    // 0x00F8 - 0x00FE: already lowercase, no change
    // 0x00FF (ÿ): lowercase, no change

    // Latin Extended-A (U+0100 - U+017F)
    // Pattern: even = uppercase, odd = lowercase
    if (cp >= 0x0100 and cp <= 0x0137) {
        if (cp % 2 == 0) {
            out[0] = cp + 1; // uppercase -> lowercase
            return 1;
        }
        out[0] = cp; // already lowercase
        return 1;
    }
    if (cp == 0x0138) {
        out[0] = cp;
        return 1;
    }
    // Pattern: odd = uppercase, even = lowercase
    if (cp >= 0x0139 and cp <= 0x0148) {
        if (cp % 2 == 1) {
            out[0] = cp + 1; // uppercase -> lowercase
            return 1;
        }
        out[0] = cp; // already lowercase
        return 1;
    }
    if (cp == 0x0149) {
        out[0] = cp;
        return 1;
    }
    // Pattern: even = uppercase, odd = lowercase
    if (cp >= 0x014A and cp <= 0x0177) {
        if (cp % 2 == 0) {
            out[0] = cp + 1; // uppercase -> lowercase
            return 1;
        }
        out[0] = cp; // already lowercase
        return 1;
    }
    if (cp == 0x0178) {
        out[0] = 0x00FF; // Ÿ -> ÿ
        return 1;
    }
    // Pattern: odd = uppercase, even = lowercase
    if (cp >= 0x0179 and cp <= 0x017E) {
        if (cp % 2 == 1) {
            out[0] = cp + 1; // uppercase -> lowercase
            return 1;
        }
        out[0] = cp; // already lowercase
        return 1;
    }
    if (cp == 0x017F) {
        out[0] = 's'; // long s -> s
        return 1;
    }

    // Latin Extended-B (U+0180 - U+024F)
    // Only map uppercase -> lowercase
    if (cp == 0x0180) { out[0] = cp; return 1; }
    if (cp == 0x0181) { out[0] = 0x0253; return 1; }
    if (cp == 0x0182) { out[0] = 0x0183; return 1; }
    if (cp == 0x0183) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x0184) { out[0] = 0x0185; return 1; }
    if (cp == 0x0185) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x0186) { out[0] = 0x0254; return 1; }
    if (cp == 0x0187) { out[0] = 0x0188; return 1; }
    if (cp == 0x0188) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x0189) { out[0] = 0x0256; return 1; }
    if (cp == 0x018A) { out[0] = 0x0257; return 1; }
    if (cp == 0x018B) { out[0] = 0x018C; return 1; }
    if (cp == 0x018C) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x018D) { out[0] = cp; return 1; }
    if (cp == 0x018E) { out[0] = 0x01DD; return 1; }
    if (cp == 0x018F) { out[0] = 0x0259; return 1; }
    if (cp == 0x0190) { out[0] = 0x025B; return 1; }
    if (cp == 0x0191) { out[0] = 0x0192; return 1; }
    if (cp == 0x0192) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x0193) { out[0] = 0x0260; return 1; }
    if (cp == 0x0194) { out[0] = 0x0263; return 1; }
    if (cp == 0x0195) { out[0] = cp; return 1; }
    if (cp == 0x0196) { out[0] = 0x0269; return 1; }
    if (cp == 0x0197) { out[0] = 0x0268; return 1; }
    if (cp == 0x0198) { out[0] = 0x0199; return 1; }
    if (cp == 0x0199) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x019A) { out[0] = cp; return 1; }
    if (cp == 0x019B) { out[0] = cp; return 1; }
    if (cp == 0x019C) { out[0] = 0x026F; return 1; }
    if (cp == 0x019D) { out[0] = 0x0272; return 1; }
    if (cp == 0x019E) { out[0] = cp; return 1; }
    if (cp == 0x019F) { out[0] = 0x0275; return 1; }
    if (cp >= 0x01A0 and cp <= 0x01A5) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp == 0x01A6) { out[0] = 0x0280; return 1; }
    if (cp == 0x01A7) { out[0] = 0x01A8; return 1; }
    if (cp == 0x01A8) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01A9) { out[0] = 0x0283; return 1; }
    if (cp == 0x01AA) { out[0] = cp; return 1; }
    if (cp == 0x01AB) { out[0] = cp; return 1; }
    if (cp == 0x01AC) { out[0] = 0x01AD; return 1; }
    if (cp == 0x01AD) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01AE) { out[0] = 0x0288; return 1; }
    if (cp == 0x01AF) { out[0] = 0x01B0; return 1; }
    if (cp == 0x01B0) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01B1) { out[0] = 0x028A; return 1; }
    if (cp == 0x01B2) { out[0] = 0x028B; return 1; }
    if (cp == 0x01B3) { out[0] = 0x01B4; return 1; }
    if (cp == 0x01B4) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01B5) { out[0] = 0x01B6; return 1; }
    if (cp == 0x01B6) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01B7) { out[0] = 0x0292; return 1; }
    if (cp == 0x01B8) { out[0] = 0x01B9; return 1; }
    if (cp == 0x01B9) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01BA) { out[0] = cp; return 1; }
    if (cp == 0x01BB) { out[0] = cp; return 1; }
    if (cp == 0x01BC) { out[0] = 0x01BD; return 1; }
    if (cp == 0x01BD) { out[0] = cp; return 1; } // lowercase
    if (cp >= 0x01BE and cp <= 0x01BF) { out[0] = cp; return 1; }
    if (cp == 0x01C0) { out[0] = cp; return 1; }
    if (cp == 0x01C1) { out[0] = cp; return 1; }
    if (cp == 0x01C2) { out[0] = cp; return 1; }
    if (cp == 0x01C3) { out[0] = cp; return 1; }
    if (cp >= 0x01C4 and cp <= 0x01CC) {
        // Titlecase/Uppercase -> lowercase
        switch (cp) {
            0x01C4 => { out[0] = 0x01C6; return 1; },
            0x01C5 => { out[0] = 0x01C6; return 1; },
            0x01C7 => { out[0] = 0x01C9; return 1; },
            0x01C8 => { out[0] = 0x01C9; return 1; },
            0x01CA => { out[0] = 0x01CC; return 1; },
            0x01CB => { out[0] = 0x01CC; return 1; },
            else => { out[0] = cp; return 1; }, // lowercase
        }
    }
    if (cp >= 0x01CD and cp <= 0x01DC) {
        if (cp % 2 == 1) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp == 0x01DD) { out[0] = cp; return 1; } // lowercase
    if (cp >= 0x01DE and cp <= 0x01EF) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp == 0x01F0) { out[0] = cp; return 1; }
    if (cp == 0x01F1) { out[0] = 0x01F3; return 1; }
    if (cp == 0x01F2) { out[0] = 0x01F3; return 1; }
    if (cp == 0x01F3) { out[0] = cp; return 1; } // lowercase
    if (cp == 0x01F4) { out[0] = 0x01F5; return 1; }
    if (cp == 0x01F5) { out[0] = cp; return 1; } // lowercase
    if (cp >= 0x01F6 and cp <= 0x01F8) { out[0] = cp; return 1; }
    if (cp >= 0x01F9 and cp <= 0x021F) {
        if (cp % 2 == 1) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp == 0x0220) { out[0] = cp; return 1; }
    if (cp >= 0x0222 and cp <= 0x0233) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp >= 0x0234 and cp <= 0x023F) { out[0] = cp; return 1; }
    if (cp >= 0x0240 and cp <= 0x024F) {
        switch (cp) {
            0x0241 => { out[0] = 0x0242; return 1; },
            0x0243 => { out[0] = 0x0180; return 1; },
            0x0244 => { out[0] = 0x0289; return 1; },
            0x0245 => { out[0] = 0x028C; return 1; },
            else => { out[0] = cp; return 1; },
        }
    }

    // Greek (U+0391 - U+03A1, U+03A3 - U+03AB: uppercase)
    // (U+03B1 - U+03C1, U+03C3 - U+03CB: lowercase)
    if (cp >= 0x0391 and cp <= 0x03A1) {
        out[0] = cp + 0x20;
        return 1;
    }
    if (cp >= 0x03A3 and cp <= 0x03AB) {
        out[0] = cp + 0x20;
        return 1;
    }
    // lowercase Greek: no change
    if (cp >= 0x03B1 and cp <= 0x03C1) {
        out[0] = cp;
        return 1;
    }
    if (cp >= 0x03C3 and cp <= 0x03CB) {
        out[0] = cp;
        return 1;
    }
    if (cp == 0x03CC or cp == 0x03CD or cp == 0x03CE) {
        out[0] = cp;
        return 1;
    }
    if (cp == 0x03CF) { out[0] = 0x03D7; return 1; }
    if (cp == 0x03D0) { out[0] = 0x03B2; return 1; }
    if (cp == 0x03D1) { out[0] = 0x03B8; return 1; }
    if (cp == 0x03D5) { out[0] = 0x03C6; return 1; }
    if (cp == 0x03D6) { out[0] = 0x03C0; return 1; }
    if (cp == 0x03D7) { out[0] = cp; return 1; } // lowercase
    if (cp >= 0x03D8 and cp <= 0x03EF) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp >= 0x03F0 and cp <= 0x03F4) {
        switch (cp) {
            0x03F0 => { out[0] = 0x03BA; return 1; },
            0x03F1 => { out[0] = 0x03C1; return 1; },
            0x03F2 => { out[0] = 0x03F3; return 1; },
            0x03F3 => { out[0] = cp; return 1; }, // lowercase
            0x03F4 => { out[0] = 0x03B8; return 1; },
            else => { out[0] = cp; return 1; },
        }
    }
    if (cp == 0x03F5) { out[0] = 0x03B5; return 1; }

    // Cyrillic (U+0410 - U+042F: uppercase, U+0430 - U+044F: lowercase)
    if (cp >= 0x0410 and cp <= 0x042F) {
        out[0] = cp + 0x20;
        return 1;
    }
    if (cp >= 0x0430 and cp <= 0x044F) {
        out[0] = cp;
        return 1;
    }
    if (cp >= 0x0450 and cp <= 0x045F) {
        out[0] = cp; // lowercase
        return 1;
    }
    if (cp >= 0x0460 and cp <= 0x0481) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp >= 0x048A and cp <= 0x04BF) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp == 0x04C0) { out[0] = 0x04CF; return 1; }
    if (cp >= 0x04C1 and cp <= 0x04CE) {
        if (cp % 2 == 1) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }
    if (cp == 0x04CF) { out[0] = cp; return 1; } // lowercase
    if (cp >= 0x04D0 and cp <= 0x04FF) {
        if (cp % 2 == 0) { out[0] = cp + 1; return 1; } // uppercase -> lowercase
        out[0] = cp; return 1; // lowercase
    }

    // Armenian (U+0531 - U+0556: uppercase, U+0561 - U+0586: lowercase)
    if (cp >= 0x0531 and cp <= 0x0556) {
        out[0] = cp + 0x30;
        return 1;
    }
    if (cp >= 0x0561 and cp <= 0x0586) {
        out[0] = cp;
        return 1;
    }

    // Georgian (U+10A0 - U+10C5: uppercase, U+10D0 - U+10F0: lowercase)
    if (cp >= 0x10A0 and cp <= 0x10C5) {
        out[0] = cp + 0x1C60;
        return 1;
    }
    if (cp >= 0x10D0 and cp <= 0x10F0) {
        out[0] = cp;
        return 1;
    }

    // Fullwidth Latin (U+FF21 - U+FF3A: uppercase, U+FF41 - U+FF5A: lowercase)
    if (cp >= 0xFF21 and cp <= 0xFF3A) {
        out[0] = cp + 0x20;
        return 1;
    }
    if (cp >= 0xFF41 and cp <= 0xFF5A) {
        out[0] = cp;
        return 1;
    }

    // Default: no folding
    out[0] = cp;
    return 1;
}

/// Check if two codepoints are case-insensitively equal.
pub fn caseInsensitiveEqual(a: u21, b: u21) bool {
    if (a == b) return true;
    var folded_a: [4]u21 = undefined;
    var folded_b: [4]u21 = undefined;
    const count_a = foldCase(a, &folded_a);
    const count_b = foldCase(b, &folded_b);
    if (count_a != count_b) return false;
    for (0..count_a) |i| {
        if (folded_a[i] != folded_b[i]) return false;
    }
    return true;
}

/// Compare two UTF-8 strings case-insensitively using Unicode simple case folding.
/// Returns true if they are case-insensitively equal.
pub fn unicodeEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    var a_i: usize = 0;
    var b_i: usize = 0;
    while (a_i < a.len and b_i < b.len) {
        const a_len = std.unicode.utf8ByteSequenceLength(a[a_i]) catch return false;
        const b_len = std.unicode.utf8ByteSequenceLength(b[b_i]) catch return false;
        if (a_i + a_len > a.len or b_i + b_len > b.len) return false;
        const a_cp = std.unicode.utf8Decode(a[a_i..a_i + a_len]) catch return false;
        const b_cp = std.unicode.utf8Decode(b[b_i..b_i + b_len]) catch return false;
        if (!caseInsensitiveEqual(a_cp, b_cp)) return false;
        a_i += a_len;
        b_i += b_len;
    }
    return a_i == a.len and b_i == b.len;
}

test "foldCase ASCII" {
    var buf: [4]u21 = undefined;
    try std.testing.expectEqual(1, foldCase('A', &buf));
    try std.testing.expectEqual('a', buf[0]);
    try std.testing.expectEqual(1, foldCase('a', &buf));
    try std.testing.expectEqual('a', buf[0]);
    try std.testing.expectEqual(1, foldCase('Z', &buf));
    try std.testing.expectEqual('z', buf[0]);
}

test "foldCase Latin-1" {
    var buf: [4]u21 = undefined;
    try std.testing.expectEqual(1, foldCase(0x00C0, &buf)); // À
    try std.testing.expectEqual(0x00E0, buf[0]); // à
    try std.testing.expectEqual(2, foldCase(0x00DF, &buf)); // ß
    try std.testing.expectEqual('s', buf[0]);
    try std.testing.expectEqual('s', buf[1]);
    try std.testing.expectEqual(1, foldCase(0x00E0, &buf)); // à (already lowercase)
    try std.testing.expectEqual(0x00E0, buf[0]);
}

test "foldCase Greek" {
    var buf: [4]u21 = undefined;
    try std.testing.expectEqual(1, foldCase(0x0391, &buf)); // Α
    try std.testing.expectEqual(0x03B1, buf[0]); // α
    try std.testing.expectEqual(1, foldCase(0x03B1, &buf)); // α (already lowercase)
    try std.testing.expectEqual(0x03B1, buf[0]);
}

test "foldCase Cyrillic" {
    var buf: [4]u21 = undefined;
    try std.testing.expectEqual(1, foldCase(0x0410, &buf)); // А
    try std.testing.expectEqual(0x0430, buf[0]); // а
    try std.testing.expectEqual(1, foldCase(0x0430, &buf)); // а (already lowercase)
    try std.testing.expectEqual(0x0430, buf[0]);
}

test "caseInsensitiveEqual" {
    try std.testing.expect(caseInsensitiveEqual('A', 'a'));
    try std.testing.expect(caseInsensitiveEqual('a', 'A'));
    try std.testing.expect(!caseInsensitiveEqual('A', 'B'));
    try std.testing.expect(caseInsensitiveEqual(0x00C0, 0x00E0)); // À ↔ à
    try std.testing.expect(caseInsensitiveEqual(0x0391, 0x03B1)); // Α ↔ α
}

test "unicodeEqlIgnoreCase" {
    try std.testing.expect(unicodeEqlIgnoreCase("Hello", "hello"));
    try std.testing.expect(unicodeEqlIgnoreCase("café", "CAFÉ"));
    try std.testing.expect(unicodeEqlIgnoreCase("Straße", "straße"));
    try std.testing.expect(!unicodeEqlIgnoreCase("hello", "world"));
}
