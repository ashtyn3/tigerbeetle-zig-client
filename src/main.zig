const std = @import("std");
const log = std.log.scoped("main");
const zli = @import("zli");
const tigerbeetle = @import("tb");
const cl = @import("./client.zig");

const assert = std.debug.assert;
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const cluster_id: u128 = 0;
    const addresses: []const u8 = "0.0.0.0:3000";
    var tb = try cl.TB_Client.init(allocator, addresses, cluster_id);
    // const d = [2]u128{ 4, 2 };
    // const q = tigerbeetle.vsr.stdx.comptime_slice(d, 2);
    const search = try tb.get_account_transfers(.{
        .account_id = 1,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .code = 0,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .limit = 1,
        .flags = .{
            .debits = true,
            .credits = true,
            .reversed = false,
        },
    });
    const ac_balances = try tb.get_account_balances(.{
        .account_id = 1,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .code = 0,
        .timestamp_min = 0,
        .timestamp_max = 0,
        .limit = 1,
        .flags = .{
            .debits = true,
            .credits = true,
            .reversed = false,
        },
    });
    std.log.info("{any}", .{search});
    std.log.info("{any}", .{ac_balances});
}
