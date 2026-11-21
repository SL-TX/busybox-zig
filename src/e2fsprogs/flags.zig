//! ext2 file-attribute flag rendering (e2fsprogs/e2fs_lib.c).

const std = @import("std");

pub const Bit = struct { value: u32, short: u8, long: []const u8 };

pub const bits = [_]Bit{
    .{ .value = 0x00000001, .short = 's', .long = "Secure_Deletion" },
    .{ .value = 0x00000002, .short = 'u', .long = "Undelete" },
    .{ .value = 0x00000008, .short = 'S', .long = "Synchronous_Updates" },
    .{ .value = 0x00010000, .short = 'D', .long = "Synchronous_Directory_Updates" },
    .{ .value = 0x00000010, .short = 'i', .long = "Immutable" },
    .{ .value = 0x00000020, .short = 'a', .long = "Append_Only" },
    .{ .value = 0x00000040, .short = 'd', .long = "No_Dump" },
    .{ .value = 0x00000080, .short = 'A', .long = "No_Atime" },
    .{ .value = 0x00000004, .short = 'c', .long = "Compression_Requested" },
    .{ .value = 0x00000800, .short = 'E', .long = "Encrypted" },
    .{ .value = 0x00004000, .short = 'j', .long = "Journaled_Data" },
    .{ .value = 0x00001000, .short = 'I', .long = "Indexed_directory" },
    .{ .value = 0x00008000, .short = 't', .long = "No_Tailmerging" },
    .{ .value = 0x00020000, .short = 'T', .long = "Top_of_Directory_Hierarchies" },
    .{ .value = 0x00080000, .short = 'e', .long = "Extents" },
    .{ .value = 0x00800000, .short = 'C', .long = "No_COW" },
    .{ .value = 0x40000000, .short = 'F', .long = "Casefold" },
    .{ .value = 0x10000000, .short = 'N', .long = "Inline_Data" },
    .{ .value = 0x20000000, .short = 'P', .long = "Project_Hierarchy" },
    .{ .value = 0x00100000, .short = 'V', .long = "Verity" },
};

pub fn render(flags: u32, buf: []u8) []const u8 {
    for (bits, 0..) |b, i| buf[i] = if ((flags & b.value) != 0) b.short else '-';
    return buf[0..bits.len];
}

pub fn renderLong(flags: u32, buf: []u8) []const u8 {
    var pos: usize = 0;
    var first = true;
    for (bits) |b| {
        if ((flags & b.value) == 0) continue;
        if (!first) {
            @memcpy(buf[pos..][0..2], ", ");
            pos += 2;
        }
        @memcpy(buf[pos..][0..b.long.len], b.long);
        pos += b.long.len;
        first = false;
    }
    if (first) {
        @memcpy(buf[0..3], "---");
        return buf[0..3];
    }
    return buf[0..pos];
}
