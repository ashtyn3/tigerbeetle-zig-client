const std = @import("std");
const log = std.log.scoped("main");
const zli = @import("zli");
const tb = @import("tb");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const assert = std.debug.assert;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

fn base_handler(ctx: *const Context, _: void) !Respond {
    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    return ctx.response.apply(.{ .status = .OK, .mime = http.Mime.TEXT, .body = "hi" });
}

fn serve(allocator: std.mem.Allocator) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var router = try Router.init(allocator, &.{Route.init("/").all({}, base_handler).layer()}, .{});
    defer router.deinit(allocator);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(rt.allocator, .{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, p.socket);
            }
        }.entry,
    );
}
pub fn parse_addresses(
    raw: []const u8,
    out_buffer: *std.BoundedArray(std.net.Address, 32),
) ![]std.net.Address {
    const address_count = std.mem.count(u8, raw, ",") + 1;
    if (address_count > out_buffer.len) return error.AddressLimitExceeded;

    var index: usize = 0;
    var comma_iterator = std.mem.split(u8, raw, ",");
    while (comma_iterator.next()) |raw_address| : (index += 1) {
        assert(index < out_buffer.len);
        if (raw_address.len == 0) return error.AddressHasTrailingComma;
        out_buffer.set(index, try parse_address_and_port(raw_address));
    }
    assert(index == address_count);

    return out_buffer.slice()[0..address_count];
}

pub fn parse_address_and_port(string: []const u8) !std.net.Address {
    assert(string.len > 0);

    if (std.mem.lastIndexOfAny(u8, string, ":.]")) |split| {
        if (string[split] == ':') {
            return parse_address(
                string[0..split],
                std.fmt.parseUnsigned(u16, string[split + 1 ..], 10) catch |err| switch (err) {
                    error.Overflow => return error.PortOverflow,
                    error.InvalidCharacter => return error.PortInvalid,
                },
            );
        } else {
            return parse_address(string, 3030);
        }
    } else {
        return std.net.Address.parseIp4(
            "0.0.0.0:3030",
            std.fmt.parseUnsigned(u16, string, 10) catch |err| switch (err) {
                error.Overflow => return error.PortOverflow,
                error.InvalidCharacter => return error.AddressInvalid,
            },
        ) catch unreachable;
    }
}

fn parse_address(string: []const u8, port: u16) !std.net.Address {
    if (string.len == 0) return error.AddressInvalid;
    if (string[string.len - 1] == ':') return error.AddressHasMoreThanOneColon;

    if (string[0] == '[' and string[string.len - 1] == ']') {
        return std.net.Address.parseIp6(string[1 .. string.len - 1], port) catch {
            return error.AddressInvalid;
        };
    } else {
        return std.net.Address.parseIp4(string, port) catch return error.AddressInvalid;
    }
}
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const Completion = struct {
    pending: usize,
    mutex: Mutex = .{},
    cond: Condition = .{},

    pub fn complete(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        assert(self.pending > 0);
        self.pending -= 1;
        self.cond.signal();
    }

    pub fn wait_pending(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending > 0)
            self.cond.wait(&self.mutex);
    }
};
fn RequestContextType(comptime request_size_max: comptime_int) type {
    return struct {
        const RequestContext = @This();

        completion: *Completion,
        packet: tb.Packet,
        sent_data: [request_size_max]u8 = undefined,
        sent_data_size: u32,
        reply: ?struct {
            tb_context: usize,
            tb_packet: *tb.Packet,
            timestamp: u64,
            result: ?[request_size_max]u8,
            result_len: u32,
        } = null,

        pub fn on_complete(
            tb_context: usize,
            tb_packet: *tb.Packet,
            timestamp: u64,
            result_ptr: ?[*]const u8,
            result_len: u32,
        ) callconv(.C) void {
            var self: *RequestContext = @ptrCast(@alignCast(tb_packet.*.user_data.?));
            defer self.completion.complete();

            self.reply = .{
                .tb_context = tb_context,
                .tb_packet = tb_packet,
                .timestamp = timestamp,
                .result = if (result_ptr != null and result_len > 0) blk: {
                    // Copy the message's body to the context buffer:
                    assert(result_len <= request_size_max);
                    var writable: [request_size_max]u8 = undefined;
                    const readable: [*]const u8 = @ptrCast(result_ptr.?);
                    tb.vsr.stdx.copy_disjoint(.inexact, u8, &writable, readable[0..result_len]);
                    break :blk writable;
                } else null,
                .result_len = result_len,
            };
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var arg_iterator = try std.process.argsWithAllocator(allocator);
    defer arg_iterator.deinit();
    // const stdout = std.io.getStdOut();
    // const out_stream = stdout.writer();

    const App = union(enum) {
        ls,
        start: struct {
            addresses: []const u8,
            pub const help =
                \\ Command: start --addresses=<addresses>
                \\
                \\ Options:
                \\
                \\  --addresses=<addresses>     
                \\      Addresses of services
                \\
                \\  -h, --help      
                \\      Displays this help message then exits
            ;
        },
        pub const help =
            \\ Usage: app [command] [options]
            \\
            \\ Commands:
            \\  start              
            \\      Start mesh service
            \\
            \\ General Options:
            \\  -h, --help      
            \\      Displays this help message then exits
        ;
    };
    var client_out: tb.vsr.tb_client.ClientInterface = undefined;
    const cluster_id: u128 = 0;
    const tb_context: usize = 0;
    try tb.vsr.tb_client.init(allocator, &client_out, cluster_id, tb_context, RequestContextType(0).on_complete);
    _ = zli.parse(&arg_iterator, App);
    // switch (res) {
    //     .start => |data| {
    //         var addresses = try std.BoundedArray(std.net.Address, 32).init(32);
    //         // try out_stream.print("{}", .{addresses.slice().len});
    //         _ = try parse_addresses(data.addresses, &addresses);
    //         try serve(allocator);
    //     },
    //     .ls => {
    //         unreachable;
    //     },
    // }
}
