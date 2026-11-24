const std = @import("std");
const crypt = @import("libbb_zig").crypto.pw_encrypt;

test "pw_encrypt MD5 $1$ vector (openssl)" {
    const a = std.testing.allocator;
    const out = try crypt.encrypt(a, "password", "$1$12345678");
    defer a.free(out);
    try std.testing.expectEqualStrings("$1$12345678$o2n/JiO/h5VviOInWJ4OQ/", out);
}

test "pw_encrypt SHA-256 $5$ vectors (openssl / reference cryptpw)" {
    const a = std.testing.allocator;
    const cases = [_]struct { salt: []const u8, want: []const u8 }{
        .{ .salt = "$5$ab", .want = "$5$ab$qeQJSoyiYLyCNJ4nhnpINuEqxziLz7BmT6ldjwrEtl9" },
        .{ .salt = "$5$salthere", .want = "$5$salthere$kYKJyvQMGlGUqaJlpHM/qSys6SpdWvcoQfQlzohoYT3" },
        .{ .salt = "$5$abcdefghijklmnop", .want = "$5$abcdefghijklmnop$ieyonWfl7MR75BuN79Fkt2PqhPI43TsNZYGUObDGVI/" },
        .{ .salt = "$5$rounds=1000$salt", .want = "$5$rounds=1000$salt$p.wiWs2zrZ7irikO2AL64QDIJo00A3KDq2xWHpLJGgB" },
    };
    for (cases) |c| {
        const out = try crypt.encrypt(a, "password", c.salt);
        defer a.free(out);
        try std.testing.expectEqualStrings(c.want, out);
    }
}

test "pw_encrypt SHA-512 $6$ vectors (openssl / reference cryptpw)" {
    const a = std.testing.allocator;
    const cases = [_]struct { salt: []const u8, want: []const u8 }{
        .{ .salt = "$6$ab", .want = "$6$ab$WfYjcVtm04.lEYV07CdYGA5G9xet7/eU/m3ApNyi7sD.pE7qFDG1ek7dRQpI2KCf9ESl1WoIH04x.DMDvmIed1" },
        .{ .salt = "$6$salthere", .want = "$6$salthere$7C3en9sNMwQR1yfxLwUENNIQDKikbaU/g7h343idoMRwr2nA0oaC1d4r8vBRfi5Mu.2EHZknHCURhQfjyJ6qt/" },
        .{ .salt = "$6$rounds=10000$salt", .want = "$6$rounds=10000$salt$dE5fLfpn2uXfkz.eouwYK/BjrHRu.piovQPjwlE06fDJHwMlg2l.IqEBUIfWBzf7YPXOAddB3FM7rnXHHKVNt." },
    };
    for (cases) |c| {
        const out = try crypt.encrypt(a, "password", c.salt);
        defer a.free(out);
        try std.testing.expectEqualStrings(c.want, out);
    }
}

test "pw_encrypt DES two-character salt" {
    const a = std.testing.allocator;
    const out = try crypt.encrypt(a, "password", "ab");
    defer a.free(out);
    try std.testing.expectEqualStrings("abJnggxhB/yWI", out);
}

test "pw_encrypt matches uses constant-time comparison" {
    const a = std.testing.allocator;
    try std.testing.expect(try crypt.matches(a, "password", "$5$salthere$kYKJyvQMGlGUqaJlpHM/qSys6SpdWvcoQfQlzohoYT3"));
    try std.testing.expect(!(try crypt.matches(a, "wrong", "$5$salthere$kYKJyvQMGlGUqaJlpHM/qSys6SpdWvcoQfQlzohoYT3")));
    try std.testing.expect(try crypt.matches(a, "password", "$1$12345678$o2n/JiO/h5VviOInWJ4OQ/"));
    try std.testing.expect(!(try crypt.matches(a, "wrong", "$1$12345678$o2n/JiO/h5VviOInWJ4OQ/")));
    try std.testing.expect(!(try crypt.matches(a, "password", "not a hash")));
}

test "pw_encrypt matches verifies traditional DES hashes" {
    const a = std.testing.allocator;
    // crypt(3) uses only the first two characters of a traditional salt, so
    // a full 13-byte DES hash is a valid salt for verification/encryption.
    const cases = [_]struct { hashed: []const u8 }{
        .{ .hashed = "abJnggxhB/yWI" },
        .{ .hashed = "sa3tHJ3/KuYvI" },
    };
    for (cases) |c| {
        try std.testing.expect(try crypt.matches(a, "password", c.hashed));
        try std.testing.expect(!(try crypt.matches(a, "wrong", c.hashed)));

        const recomputed = try crypt.encrypt(a, "password", c.hashed);
        defer a.free(recomputed);
        try std.testing.expectEqualStrings(c.hashed, recomputed);
    }
}

test "pw_encrypt rejects unsupported and malformed salts" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedAlgorithm, crypt.encrypt(a, "password", "$y$j9T$abcdefghijklmnopqrstuv"));
    try std.testing.expectError(error.UnsupportedAlgorithm, crypt.encrypt(a, "password", "$2a$10$abcdefghijklmnopqrstuv"));
    try std.testing.expectError(error.InvalidSalt, crypt.encrypt(a, "password", ""));
    try std.testing.expectError(error.InvalidSalt, crypt.encrypt(a, "password", "$5$"));
    try std.testing.expectError(error.InvalidSalt, crypt.encrypt(a, "password", "$1$"));
    try std.testing.expectError(error.InvalidSalt, crypt.encrypt(a, "password", "x"));
}
