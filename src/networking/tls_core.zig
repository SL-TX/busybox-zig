//! Full TLS 1.2 handshake engine for ssl_client / ssl_server.
//!
//! Cipher suite: TLS_RSA_WITH_AES_128_CBC_SHA256 (0x003c). RSA key transport,
//! SHA-256 PRF, HMAC-SHA256 and AES-128-CBC with explicit per-record IVs.
//! Everything is pure Zig on top of the Task 12 primitives; no C and no
//! external TLS library is used.

const std = @import("std");
const linux = std.os.linux;
const bb = @import("libbb_zig");
const sha = bb.tls.sha;
const aes = bb.tls.aes;
const rsa = bb.tls.rsa;
const prf = bb.tls.prf;
const rec = bb.tls.record;
const cert = bb.tls.cert;

pub const suite: u16 = 0x003c;
pub const version: u16 = 0x0303;
pub const role = enum { client, server };

pub const Failure = error{
    ConnectionClosed,
    UnexpectedRecord,
    MalformedHandshake,
    BadCertificate,
    BadFinished,
    BadMac,
    UnsupportedCipher,
    WriteFailed,
    ReadFailed,
    OutOfMemory,
    InvalidKey,
    /// getrandom() failed or returned a short read. Never fall back to
    /// predictable bytes: randoms, premaster secrets and IVs all depend on it.
    RngFailed,
};

/// Injectable randomness source. `Retry` mirrors EINTR; `Failed` covers every
/// other errno. Returning fewer bytes than requested is treated as a hard
/// failure by `fillRandomWith` unless the source is called again for the rest.
pub const RandomFn = *const fn (buf: []u8) error{ Retry, Failed }!usize;

fn sysRandom(buf: []u8) error{ Retry, Failed }!usize {
    const rc = linux.getrandom(buf.ptr, buf.len, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INTR => error.Retry,
        else => error.Failed,
    };
}

/// Fill `buf` completely or fail. Short reads are looped, EINTR is retried,
/// every other error (and a zero-length progress report) is fatal.
pub fn fillRandomWith(buf: []u8, source: RandomFn) Failure!void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = source(buf[off..]) catch |e| switch (e) {
            error.Retry => continue,
            error.Failed => return error.RngFailed,
        };
        if (n == 0 or n > buf.len - off) return error.RngFailed;
        off += n;
    }
}

pub fn fillRandom(buf: []u8) Failure!void {
    return fillRandomWith(buf, sysRandom);
}

const Keys = struct {
    client_mac: [32]u8,
    server_mac: [32]u8,
    client_key: [16]u8,
    server_key: [16]u8,
    client_iv: [16]u8,
    server_iv: [16]u8,
};

pub const Conn = struct {
    a: std.mem.Allocator,
    ifd: linux.fd_t,
    ofd: linux.fd_t,
    side: role,
    last_errno: c_int = 0,

    transcript: std.ArrayList(u8) = .empty,
    hsbuf: std.ArrayList(u8) = .empty,
    rbuf: [16 * 1024]u8 = undefined,
    rpos: usize = 0,
    rlen: usize = 0,

    client_random: [32]u8 = undefined,
    server_random: [32]u8 = undefined,
    master: [48]u8 = undefined,
    pre_master: [48]u8 = undefined,
    keys: ?Keys = null,
    read_seq: u64 = 0,
    write_seq: u64 = 0,
    activated: bool = false,

    certs: []const []const u8 = &.{},
    privkey: ?rsa.PrivateKey = null,
    hostname: ?[]const u8 = null,
    renegotiation: bool = false,
    /// Injectable for the failure-path unit test; production uses getrandom.
    rng: RandomFn = sysRandom,

    pub fn init(a: std.mem.Allocator, ifd: linux.fd_t, ofd: linux.fd_t, side: role) Conn {
        return .{ .a = a, .ifd = ifd, .ofd = ofd, .side = side };
    }

    pub fn deinit(self: *Conn) void {
        self.transcript.deinit(self.a);
        self.hsbuf.deinit(self.a);
        if (self.privkey) |*k| k.deinit(self.a);
    }

    /// Public so the failure-injection unit test can exercise the exact
    /// production path. No deterministic fallback exists anywhere in TLS.
    pub fn random(self: *Conn, buf: []u8) Failure!void {
        try fillRandomWith(buf, self.rng);
    }

    // ------------------------------------------------------------- raw I/O

    fn readExact(self: *Conn, dest: []u8) Failure!void {
        var off: usize = 0;
        while (off < dest.len) {
            if (self.rpos == self.rlen) {
                const n = linux.read(self.ifd, &self.rbuf, self.rbuf.len);
                if (linux.errno(n) != .SUCCESS) {
                    self.last_errno = @intFromEnum(linux.errno(n));
                    return error.ReadFailed;
                }
                if (n == 0) return error.ConnectionClosed;
                self.rpos = 0;
                self.rlen = @intCast(n);
            }
            const take = @min(dest.len - off, self.rlen - self.rpos);
            @memcpy(dest[off .. off + take], self.rbuf[self.rpos .. self.rpos + take]);
            self.rpos += take;
            off += take;
        }
    }

    fn writeAllFd(fd: linux.fd_t, bytes: []const u8, self: *Conn) Failure!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = linux.write(fd, bytes[off..].ptr, bytes.len - off);
            if (linux.errno(n) != .SUCCESS) {
                self.last_errno = @intFromEnum(linux.errno(n));
                return error.WriteFailed;
            }
            if (n == 0) {
                self.last_errno = 5;
                return error.WriteFailed;
            }
            off += @intCast(n);
        }
    }

    const RawRecord = struct { ct: u8, frag: []u8 };

    fn readRecord(self: *Conn) Failure!RawRecord {
        var hdr: [5]u8 = undefined;
        try self.readExact(&hdr);
        if (hdr[0] != 20 and hdr[0] != 21 and hdr[0] != 22 and hdr[0] != 23)
            return error.UnexpectedRecord;
        const len = (@as(usize, hdr[3]) << 8) | hdr[4];
        if (len > 18 * 1024) return error.MalformedHandshake;
        const frag = try self.a.alloc(u8, len);
        errdefer self.a.free(frag);
        try self.readExact(frag);
        return .{ .ct = hdr[0], .frag = frag };
    }

    fn sendRawRecord(self: *Conn, ct: u8, frag: []const u8) Failure!void {
        var hdr: [5]u8 = undefined;
        hdr[0] = ct;
        hdr[1] = @truncate(version >> 8);
        hdr[2] = @truncate(version);
        hdr[3] = @truncate(frag.len >> 8);
        hdr[4] = @truncate(frag.len);
        try writeAllFd(self.ofd, &hdr, self);
        try writeAllFd(self.ofd, frag, self);
    }

    const Handshake = struct {
        kind: u8,
        body: []u8,
        encoded: []u8,
        fn deinit(self: *Handshake, a: std.mem.Allocator) void {
            a.free(self.body);
            a.free(self.encoded);
        }
    };

    fn readHandshake(self: *Conn) Failure!Handshake {
        while (true) {
            if (self.hsbuf.items.len >= 4) {
                const len = (@as(usize, self.hsbuf.items[1]) << 16) |
                    (@as(usize, self.hsbuf.items[2]) << 8) | self.hsbuf.items[3];
                if (self.hsbuf.items.len >= 4 + len) {
                    const kind = self.hsbuf.items[0];
                    const encoded = try self.a.dupe(u8, self.hsbuf.items[0 .. 4 + len]);
                    const body = try self.a.dupe(u8, self.hsbuf.items[4 .. 4 + len]);
                    try self.hsbuf.replaceRange(self.a, 0, 4 + len, &.{});
                    try self.transcript.appendSlice(self.a, encoded);
                    return .{ .kind = kind, .body = body, .encoded = encoded };
                }
            }
            const r = try self.readRecord();
            defer self.a.free(r.frag);
            if (r.ct != 22) return error.UnexpectedRecord;
            try self.hsbuf.appendSlice(self.a, r.frag);
        }
    }

    fn sendHandshake(self: *Conn, kind: u8, body: []const u8) Failure!void {
        const h = rec.makeHandshake(self.a, kind, body) catch return error.OutOfMemory;
        defer self.a.free(h);
        try self.transcript.appendSlice(self.a, h);
        try self.sendRawRecord(22, h);
    }

    // ------------------------------------------------------- crypto helpers

    fn hmacRecord(self: *Conn, key: []const u8, seq: u64, ct: u8, plain: []const u8, out: *[32]u8) Failure!void {
        var input = std.ArrayList(u8).empty;
        defer input.deinit(self.a);
        var be: [8]u8 = undefined;
        std.mem.writeInt(u64, &be, seq, .big);
        try input.appendSlice(self.a, &be);
        try input.append(self.a, ct);
        try input.append(self.a, @truncate(version >> 8));
        try input.append(self.a, @truncate(version));
        var l: [2]u8 = undefined;
        std.mem.writeInt(u16, &l, @intCast(plain.len), .big);
        try input.appendSlice(self.a, &l);
        try input.appendSlice(self.a, plain);
        sha.hmacSha256(key, input.items, out);
    }

    fn writeKey(self: *Conn) []const u8 {
        return if (self.side == .client) &self.keys.?.client_key else &self.keys.?.server_key;
    }
    fn readKey(self: *Conn) []const u8 {
        return if (self.side == .client) &self.keys.?.server_key else &self.keys.?.client_key;
    }
    fn writeMac(self: *Conn) []const u8 {
        return if (self.side == .client) &self.keys.?.client_mac else &self.keys.?.server_mac;
    }
    fn readMac(self: *Conn) []const u8 {
        return if (self.side == .client) &self.keys.?.server_mac else &self.keys.?.client_mac;
    }

    fn sendEncrypted(self: *Conn, ct: u8, plain: []const u8) Failure!void {
        var mac: [32]u8 = undefined;
        self.hmacRecord(self.writeMac(), self.write_seq, ct, plain, &mac) catch return error.OutOfMemory;
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.a);
        body.appendSlice(self.a, plain) catch return error.OutOfMemory;
        body.appendSlice(self.a, &mac) catch return error.OutOfMemory;
        var pad: usize = 16 - (body.items.len % 16);
        if (pad == 0) pad = 16;
        body.appendNTimes(self.a, @as(u8, @intCast(pad - 1)), pad) catch return error.OutOfMemory;
        var iv: [16]u8 = undefined;
        try self.random(&iv);
        const cipher = aes.cbcEncryptNoPad(self.a, self.writeKey(), iv, body.items) catch return error.OutOfMemory;
        defer self.a.free(cipher);
        var frag = std.ArrayList(u8).empty;
        defer frag.deinit(self.a);
        frag.appendSlice(self.a, &iv) catch return error.OutOfMemory;
        frag.appendSlice(self.a, cipher) catch return error.OutOfMemory;
        try self.sendRawRecord(ct, frag.items);
        self.write_seq += 1;
    }

    fn readEncrypted(self: *Conn, r: RawRecord) Failure![]u8 {
        if (r.frag.len < 32 or r.frag.len % 16 != 0) return error.MalformedHandshake;
        var iv: [16]u8 = undefined;
        @memcpy(&iv, r.frag[0..16]);
        const padded = aes.cbcDecryptNoPad(self.a, self.readKey(), iv, r.frag[16..]) catch return error.MalformedHandshake;
        defer self.a.free(padded);
        const pad: usize = padded[padded.len - 1] + 1;
        if (pad == 0 or pad > 16 or pad + 32 >= padded.len) return error.MalformedHandshake;
        for (padded[padded.len - pad ..]) |b| {
            if (b != pad - 1) return error.MalformedHandshake;
        }
        const content_len = padded.len - pad - 32;
        const plain = padded[0..content_len];
        var mac: [32]u8 = undefined;
        self.hmacRecord(self.readMac(), self.read_seq, r.ct, plain, &mac) catch return error.OutOfMemory;
        const received = padded[content_len .. content_len + 32];
        const got_mac: *const [32]u8 = @ptrCast(received.ptr);
        if (!std.crypto.timing_safe.eql([32]u8, mac, got_mac.*)) return error.BadMac;
        self.read_seq += 1;
        return self.a.dupe(u8, plain) catch return error.OutOfMemory;
    }

    fn deriveKeys(self: *Conn) Failure!void {
        var seed: [64]u8 = undefined;
        @memcpy(seed[0..32], &self.client_random);
        @memcpy(seed[32..64], &self.server_random);
        const master = prf.tlsPrfSha256(self.a, self.master_secret_bytes(), "master secret", &seed, 48) catch return error.OutOfMemory;
        defer self.a.free(master);
        @memcpy(&self.master, master);

        @memcpy(seed[0..32], &self.server_random);
        @memcpy(seed[32..64], &self.client_random);
        const block = prf.tlsPrfSha256(self.a, &self.master, "key expansion", &seed, 128) catch return error.OutOfMemory;
        defer self.a.free(block);
        var k = Keys{ .client_mac = undefined, .server_mac = undefined, .client_key = undefined, .server_key = undefined, .client_iv = undefined, .server_iv = undefined };
        @memcpy(&k.client_mac, block[0..32]);
        @memcpy(&k.server_mac, block[32..64]);
        @memcpy(&k.client_key, block[64..80]);
        @memcpy(&k.server_key, block[80..96]);
        @memcpy(&k.client_iv, block[96..112]);
        @memcpy(&k.server_iv, block[112..128]);
        self.keys = k;
    }

    // The pre-master secret is filled in by the handshake before deriveKeys.
    fn master_secret_bytes(self: *Conn) *[48]u8 {
        return &self.pre_master;
    }

    fn verifyData(self: *Conn, label: []const u8) Failure![12]u8 {
        var digest: [32]u8 = undefined;
        sha.sha256(self.transcript.items, &digest);
        const v = prf.tlsPrfSha256(self.a, &self.master, label, &digest, 12) catch return error.OutOfMemory;
        defer self.a.free(v);
        var out: [12]u8 = undefined;
        @memcpy(&out, v);
        return out;
    }

    fn sendFinished(self: *Conn, label: []const u8) Failure!void {
        const v = try self.verifyData(label);
        const h = rec.makeHandshake(self.a, rec.handshake_finished, &v) catch return error.OutOfMemory;
        defer self.a.free(h);
        try self.sendEncrypted(22, h);
        try self.transcript.appendSlice(self.a, h);
    }

    fn receiveFinished(self: *Conn, label: []const u8) Failure!void {
        // ChangeCipherSpec is unencrypted and resets the read sequence.
        while (true) {
            const r = try self.readRecord();
            defer self.a.free(r.frag);
            if (r.ct == 21) return error.ConnectionClosed;
            if (r.ct == 20) break;
            if (r.ct != 22) return error.UnexpectedRecord;
        }
        self.read_seq = 0;
        self.activated = true;
        const r = try self.readRecord();
        defer self.a.free(r.frag);
        if (r.ct != 22) return error.UnexpectedRecord;
        const plain = try self.readEncrypted(r);
        defer self.a.free(plain);
        const hs = rec.parseHandshake(plain) catch return error.MalformedHandshake;
        if (hs.msg_type != rec.handshake_finished or hs.body.len != 12) return error.MalformedHandshake;
        const expected = try self.verifyData(label);
        const got_verify: *const [12]u8 = @ptrCast(hs.body.ptr);
        if (!std.crypto.timing_safe.eql([12]u8, expected, got_verify.*)) return error.BadFinished;
        const encoded = plain[0 .. 4 + hs.body.len];
        try self.transcript.appendSlice(self.a, encoded);
    }

    // ------------------------------------------------------- client flow

    fn buildClientHello(self: *Conn) Failure![]u8 {
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.a);
        const ap = self.a;
        body.appendSlice(ap, &.{ @truncate(version >> 8), @truncate(version) }) catch return error.OutOfMemory;
        var cl_rand: [32]u8 = undefined;
        try self.random(&cl_rand);
        @memcpy(&self.client_random, &cl_rand);
        body.appendSlice(ap, &cl_rand) catch return error.OutOfMemory;
        body.append(ap, 0) catch return error.OutOfMemory; // empty session id
        body.appendSlice(ap, &.{ 0, 4, 0, 0xff, 0x00, 0x3c }) catch return error.OutOfMemory;
        body.appendSlice(ap, &.{ 1, 0 }) catch return error.OutOfMemory; // null compression

        var ext = std.ArrayList(u8).empty;
        defer ext.deinit(ap);
        if (self.hostname) |host| {
            var sni = std.ArrayList(u8).empty;
            defer sni.deinit(ap);
            sni.appendSlice(ap, &.{ @truncate((host.len + 3) >> 8), @truncate(host.len + 3), 0 }) catch return error.OutOfMemory;
            sni.appendSlice(ap, &.{ @truncate(host.len >> 8), @truncate(host.len) }) catch return error.OutOfMemory;
            sni.appendSlice(ap, host) catch return error.OutOfMemory;
            ext.appendSlice(ap, &.{ 0, 0 }) catch return error.OutOfMemory;
            ext.appendSlice(ap, &.{ @truncate(sni.items.len >> 8), @truncate(sni.items.len) }) catch return error.OutOfMemory;
            ext.appendSlice(ap, sni.items) catch return error.OutOfMemory;
        }
        // signature_algorithms: sha256+rsa (SHA-1 is rejected by OpenSSL 3
        // at SECLEVEL>=1, and this suite only needs SHA-256).
        ext.appendSlice(ap, &.{ 0, 13, 0, 4, 0, 2, 4, 1 }) catch return error.OutOfMemory;
        // SCSV in the cipher list covers RFC 5746; sending renegotiation_info
        // as well would be a protocol violation rejected by OpenSSL.
        body.appendSlice(ap, &.{ @truncate(ext.items.len >> 8), @truncate(ext.items.len) }) catch return error.OutOfMemory;
        body.appendSlice(ap, ext.items) catch return error.OutOfMemory;
        defer body.deinit(ap);
        return rec.makeHandshake(ap, rec.handshake_client_hello, body.items) catch return error.OutOfMemory;
    }

    fn parseServerHello(self: *Conn, body: []const u8) Failure!void {
        if (body.len < 35) return error.MalformedHandshake;
        if (std.mem.readInt(u16, body[0..2], .big) != version) return error.UnsupportedCipher;
        @memcpy(&self.server_random, body[2..34]);
        const sid_len = body[34];
        var p: usize = 35 + @as(usize, sid_len);
        if (body.len < p + 3) return error.MalformedHandshake;
        if (((@as(u16, body[p]) << 8) | body[p + 1]) != suite) return error.UnsupportedCipher;
        p += 3;
        if (body[p - 1] != 0) return error.UnsupportedCipher;
        if (body.len >= p + 2) {
            const ext_len = (@as(usize, body[p]) << 8) | body[p + 1];
            p += 2;
            if (p + ext_len > body.len) return error.MalformedHandshake;
            var e: usize = p;
            const end = p + ext_len;
            while (e + 4 <= end) {
                const typ = (@as(u16, body[e]) << 8) | body[e + 1];
                const elen = (@as(usize, body[e + 2]) << 8) | body[e + 3];
                if (typ == 0xff01) self.renegotiation = true;
                e += 4 + elen;
                if (e > end) return error.MalformedHandshake;
            }
        }
    }

    fn parseCertificate(self: *Conn, body: []const u8) Failure!void {
        if (body.len < 3) return error.MalformedHandshake;
        const total = (@as(usize, body[0]) << 16) | (@as(usize, body[1]) << 8) | body[2];
        if (total + 3 > body.len) return error.MalformedHandshake;
        var list = std.ArrayList([]const u8).empty;
        errdefer list.deinit(self.a);
        var p: usize = 3;
        const end = 3 + total;
        while (p + 3 <= end) {
            const len = (@as(usize, body[p]) << 16) | (@as(usize, body[p + 1]) << 8) | body[p + 2];
            p += 3;
            if (p + len > end) return error.MalformedHandshake;
            try list.append(self.a, try self.a.dupe(u8, body[p .. p + len]));
            p += len;
        }
        self.certs = try list.toOwnedSlice(self.a);
    }

    pub fn handshakeClient(self: *Conn) Failure!void {
        const hello = try self.buildClientHello();
        try self.sendRawRecord(22, hello);
        try self.transcript.appendSlice(self.a, hello);

        var got_hello = false;
        var got_done = false;
        while (!got_done) {
            const hs = try self.readHandshake();
            defer self.a.free(hs.body);
            defer self.a.free(hs.encoded);
            switch (hs.kind) {
                2 => {
                    try self.parseServerHello(hs.body);
                    got_hello = true;
                },
                11 => {
                    try self.parseCertificate(hs.body);
                    cert.verifyChain(self.a, self.certs, self.hostname) catch return error.BadCertificate;
                    if (self.certs.len == 0) return error.BadCertificate;
                },
                14 => got_done = true,
                else => return error.MalformedHandshake,
            }
        }
        if (!got_hello or self.certs.len == 0) return error.BadCertificate;

        const info = cert.extract(self.certs[0]) catch return error.BadCertificate;
        var pubkey = rsa.parsePublicKeyDer(self.a, info.spki) catch return error.BadCertificate;
        defer pubkey.deinit(self.a);

        var premaster: [48]u8 = undefined;
        premaster[0] = 3;
        premaster[1] = 3;
        try self.random(premaster[2..]);
        @memcpy(&self.pre_master, &premaster);

        const em = self.a.alloc(u8, pubkey.modulus.len) catch return error.OutOfMemory;
        defer self.a.free(em);
        em[0] = 0;
        em[1] = 2;
        var i: usize = 2;
        while (i < em.len - 49) : (i += 1) {
            var one: [1]u8 = undefined;
            while (true) {
                try self.random(&one);
                if (one[0] != 0) break;
            }
            em[i] = one[0];
        }
        em[i] = 0;
        i += 1;
        @memcpy(em[i .. i + 48], &premaster);
        const encrypted = rsa.powModFast(self.a, em, pubkey.exponent, pubkey.modulus) catch return error.InvalidKey;
        defer self.a.free(encrypted);
        var cke = std.ArrayList(u8).empty;
        defer cke.deinit(self.a);
        cke.append(self.a, @truncate(encrypted.len >> 8)) catch return error.OutOfMemory;
        cke.append(self.a, @truncate(encrypted.len)) catch return error.OutOfMemory;
        cke.appendSlice(self.a, encrypted) catch return error.OutOfMemory;
        try self.sendHandshake(16, cke.items);
        try self.deriveKeys();
        try self.sendRawRecord(20, &.{1});
        self.write_seq = 0;
        self.activated = true;
        try self.sendFinished("client finished");
        try self.receiveFinished("server finished");
    }

    // ------------------------------------------------------- server flow

    fn buildServerHello(self: *Conn) Failure!void {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.a);
        const ap = self.a;
        body.appendSlice(ap, &.{ @truncate(version >> 8), @truncate(version) }) catch return error.OutOfMemory;
        body.appendSlice(ap, &self.server_random) catch return error.OutOfMemory;
        body.append(ap, 0) catch return error.OutOfMemory;
        body.appendSlice(ap, &.{ @truncate(suite >> 8), @truncate(suite), 0 }) catch return error.OutOfMemory;
        if (self.renegotiation) {
            body.appendSlice(ap, &.{ 0, 5, 0xff, 0x01, 0, 1, 0 }) catch return error.OutOfMemory;
        }
        try self.sendHandshake(2, body.items);
    }

    fn sendCertificate(self: *Conn) Failure!void {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.a);
        var total: usize = 0;
        for (self.certs) |c| total += 3 + c.len;
        body.append(self.a, @truncate(total >> 16)) catch return error.OutOfMemory;
        body.append(self.a, @truncate(total >> 8)) catch return error.OutOfMemory;
        body.append(self.a, @truncate(total)) catch return error.OutOfMemory;
        for (self.certs) |c| {
            body.append(self.a, @truncate(c.len >> 16)) catch return error.OutOfMemory;
            body.append(self.a, @truncate(c.len >> 8)) catch return error.OutOfMemory;
            body.append(self.a, @truncate(c.len)) catch return error.OutOfMemory;
            body.appendSlice(self.a, c) catch return error.OutOfMemory;
        }
        try self.sendHandshake(11, body.items);
    }

    pub fn handshakeServer(self: *Conn) Failure!void {
        var hs = try self.readHandshake();
        defer hs.deinit(self.a);
        if (hs.kind != 1) return error.MalformedHandshake;
        try self.parseClientHelloExtensions(hs.body);
        // The ClientHello random is the first 32 bytes after the 2-byte version.
        if (hs.body.len < 34) return error.MalformedHandshake;
        @memcpy(&self.client_random, hs.body[2..34]);
        try self.random(&self.server_random);
        try self.buildServerHello();
        try self.sendCertificate();
        try self.sendHandshake(14, &.{});

        var cke = try self.readHandshake();
        defer cke.deinit(self.a);
        if (cke.kind != 16 or cke.body.len < 3) return error.MalformedHandshake;
        const ct_len = (@as(usize, cke.body[0]) << 8) | cke.body[1];
        if (ct_len + 2 != cke.body.len) return error.MalformedHandshake;
        if (self.privkey == null) return error.InvalidKey;
        const premaster = rsa.decryptPkcs1V15(self.a, self.privkey.?, cke.body[2..]) catch return error.InvalidKey;
        defer self.a.free(premaster);
        if (premaster.len != 48) return error.InvalidKey;
        @memcpy(&self.pre_master, premaster);

        try self.deriveKeys();
        try self.receiveFinished("client finished");
        try self.sendRawRecord(20, &.{1});
        self.write_seq = 0;
        try self.sendFinished("server finished");
    }

    fn parseClientHelloExtensions(self: *Conn, body: []const u8) Failure!void {
        if (body.len < 34) return error.MalformedHandshake;
        // cipher list starts after version(2)+random(32)+session id(1)
        var p: usize = 35;
        if (body.len < p + 2) return error.MalformedHandshake;
        const cslen = (@as(usize, body[p]) << 8) | body[p + 1];
        p += 2 + cslen;
        if (p + 1 > body.len) return error.MalformedHandshake;
        p += 1 + @as(usize, body[p]); // compression methods
        if (p + 2 > body.len) return error.MalformedHandshake;
        const extlen = (@as(usize, body[p]) << 8) | body[p + 1];
        p += 2;
        const end = @min(body.len, p + extlen);
        var found = false;
        while (p + 4 <= end) {
            const typ = (@as(u16, body[p]) << 8) | body[p + 1];
            const len = (@as(usize, body[p + 2]) << 8) | body[p + 3];
            if (typ == 0xff01 or typ == 0x00ff) found = true;
            p += 4 + len;
        }
        // SCSV appears in the cipher list, check it there too.
        if (!found) {
            var q: usize = 37;
            const csend = 37 + cslen;
            while (q + 1 < csend) : (q += 2) {
                if (((@as(u16, body[q]) << 8) | body[q + 1]) == 0x00ff) found = true;
            }
        }
        self.renegotiation = found;
    }

    // ---------------------------------------------------------- copy loop

    pub fn copyLoop(self: *Conn, exit_on_local_eof: bool) Failure!void {
        var stdin_open = true;
        var pfds = [_]std.posix.pollfd{
            .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.ifd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            pfds[0].fd = if (stdin_open) 0 else -1;
            pfds[0].revents = 0;
            pfds[1].revents = 0;
            _ = std.posix.poll(&pfds, -1) catch return error.ReadFailed;
            if (pfds[0].revents != 0) {
                const n = linux.read(0, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS) {
                    self.last_errno = @intFromEnum(linux.errno(n));
                    return error.ReadFailed;
                }
                if (n == 0) {
                    stdin_open = false;
                    if (exit_on_local_eof) break;
                } else {
                    try self.sendEncrypted(23, buf[0..@as(usize, n)]);
                }
            }
            if (pfds[1].revents != 0) {
                const r = try self.readRecord();
                defer self.a.free(r.frag);
                if (r.ct == 21) break;
                if (r.ct != 23) return error.UnexpectedRecord;
                const plain = try self.readEncrypted(r);
                defer self.a.free(plain);
                var off: usize = 0;
                while (off < plain.len) {
                    const w = linux.write(1, plain[off..].ptr, plain.len - off);
                    if (linux.errno(w) != .SUCCESS or w == 0) break;
                    off += @intCast(w);
                }
            }
        }
    }
};
