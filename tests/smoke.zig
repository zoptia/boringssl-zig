const std = @import("std");
const bssl = @import("boringssl");

pub fn main() !void {
    var buf: [32]u8 = undefined;
    if (bssl.c.RAND_bytes(&buf, buf.len) != 1) {
        std.debug.print("RAND_bytes failed\n", .{});
        return error.RandFailed;
    }
    std.debug.print("OK: libcrypto produced {d} random bytes\n", .{buf.len});
}
