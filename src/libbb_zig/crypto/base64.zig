//! RFC 4648 base64 codec used by libbb (base64 applet, httpd, login helpers).
//! Invalid characters and bad padding are reported as errors, never panics.

const std = @import("std");

const Encoder = std.base64.standard.Encoder;
const Decoder = std.base64.standard.Decoder;

pub fn encodedLen(data_len: usize) usize {
    return Encoder.calcSize(data_len);
}

pub fn encode(a: std.mem.Allocator, data: []const u8) ![]u8 {
    const out = try a.alloc(u8, encodedLen(data.len));
    errdefer a.free(out);
    _ = Encoder.encode(out, data);
    return out;
}

/// Exact decoded length; returns an error on impossible input lengths.
pub fn decodedLen(text: []const u8) !usize {
    return Decoder.calcSizeForSlice(text);
}

pub fn decode(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const n = try decodedLen(text);
    const out = try a.alloc(u8, n);
    errdefer a.free(out);
    try Decoder.decode(out, text);
    return out;
}
