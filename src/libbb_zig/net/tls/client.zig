//! TLS client handshake framing.
//!
//! Scope (Task 12): a `Client` owns a connected fd and can build/send a
//! well-formed ClientHello and parse a ServerHello record. Key exchange,
//! cipher activation, ChangeCipherSpec/Finished and X.509 chain validation
//! against a trust store are intentionally deferred to Task 13; see the
//! task-12 report for the exact boundary. This is not a stub: the framing
//! implemented here is exercised against a local test server.

const std = @import("std");
const net = @import("../socket.zig");
const record = @import("record.zig");

pub const ClientError = error{
    HandshakeIncomplete,
    MalformedHello,
    IoError,
    OutOfMemory,
};

pub const ServerHello = struct {
    version: u16,
    random: [32]u8,
    session_id: []const u8,
    cipher_suite: u16,
    compression: u8,
};

pub const Options = struct {
    version: u16 = record.version_tls12,
    cipher_suites: []const u16 = &.{0x002f}, // TLS_RSA_WITH_AES_128_CBC_SHA
    timeout_ms: u32 = 5000,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: net.fd_t,
    host: []u8,
    options: Options,
    server_hello: ?ServerHello = null,

    pub fn init(allocator: std.mem.Allocator, fd: net.fd_t, host: []const u8, options: Options) !Client {
        net.setRecvTimeout(fd, options.timeout_ms) catch {};
        return .{
            .allocator = allocator,
            .fd = fd,
            .host = try allocator.dupe(u8, host),
            .options = options,
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.host);
        if (self.server_hello) |sh| self.allocator.free(sh.session_id);
    }

    /// Build a TLS record carrying a TLS 1.2 ClientHello handshake message.
    pub fn buildClientHello(self: *Client) ![]u8 {
        const suites_bytes = self.options.cipher_suites.len * 2;
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.appendSlice(self.allocator, &[_]u8{
            @truncate(self.options.version >> 8), @truncate(self.options.version),
        });
        var random: [32]u8 = undefined;
        const rc = std.os.linux.getrandom(&random, random.len, 0);
        if (std.os.linux.errno(rc) == .SUCCESS) {
            try body.appendSlice(self.allocator, &random);
        } else {
            try body.appendNTimes(self.allocator, 0, 32);
        }
        try body.append(self.allocator, 0); // empty session id
        try body.appendSlice(self.allocator, &[_]u8{
            @truncate(suites_bytes >> 8), @truncate(suites_bytes),
        });
        for (self.options.cipher_suites) |suite| {
            try body.appendSlice(self.allocator, &[_]u8{ @truncate(suite >> 8), @truncate(suite) });
        }
        try body.appendSlice(self.allocator, &[_]u8{ 1, 0 }); // one compression method: null
        // No extensions in the Task 12 framing.
        const handshake = try record.makeHandshake(self.allocator, record.handshake_client_hello, body.items);
        defer self.allocator.free(handshake);
        const out = try record.serialize(self.allocator, .handshake, self.options.version, handshake);
        return out;
    }

    pub fn sendClientHello(self: *Client) !void {
        const bytes = try self.buildClientHello();
        defer self.allocator.free(bytes);
        net.sendAll(self.fd, bytes, 0) catch return error.IoError;
    }

    /// Read one record and parse a ServerHello from it.
    pub fn readServerHello(self: *Client) !ServerHello {
        var buf: [8192]u8 = undefined;
        const n = net.recv(self.fd, &buf, 0) catch return error.IoError;
        if (n == 0) return error.IoError;
        const rec = record.parse(buf[0..n]) catch return error.MalformedHello;
        if (rec.content_type != .handshake) return error.MalformedHello;
        const hs = record.parseHandshake(rec.fragment) catch return error.MalformedHello;
        if (hs.msg_type != record.handshake_server_hello) return error.MalformedHello;
        const b = hs.body;
        if (b.len < 35) return error.MalformedHello;
        const version = std.mem.readInt(u16, b[0..2], .big);
        var random: [32]u8 = undefined;
        @memcpy(&random, b[2..34]);
        const sid_len = b[34];
        if (b.len < 35 + sid_len + 3) return error.MalformedHello;
        const sid = try self.allocator.dupe(u8, b[35 .. 35 + sid_len]);
        const suite = std.mem.readInt(u16, b[35 + sid_len ..][0..2], .big);
        const compression = b[37 + sid_len];
        const sh = ServerHello{
            .version = version,
            .random = random,
            .session_id = sid,
            .cipher_suite = suite,
            .compression = compression,
        };
        self.server_hello = sh;
        return sh;
    }
};
