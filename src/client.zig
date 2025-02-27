const std = @import("std");
const tigerbeetle = @import("tb");
const stdx = tigerbeetle.vsr.stdx;
const assert = std.debug.assert;
const tb_client = tigerbeetle.vsr.tb_client;
const vsr = tigerbeetle.vsr;
const constants = vsr.constants;
const IO = vsr.io.IO;
const Storage = vsr.storage.StorageType(IO);
const StateMachine = vsr.state_machine.StateMachineType(
    Storage,
    constants.state_machine_config,
);

const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

fn RequestReply(comptime request_size_max: comptime_int) type {
    return struct {
        tb_context: usize,
        tb_packet: *tb_client.Packet,
        timestamp: u64,
        result: ?[request_size_max]u8,
        result_len: u32,
    };
}

fn RequestContextType(comptime request_size_max: comptime_int) type {
    return struct {
        const RequestContext = @This();

        completion: *Completion,
        packet: tb_client.Packet,
        sent_data: [request_size_max]u8 = undefined,
        sent_data_size: u32,
        reply: ?RequestReply(request_size_max) = null,

        pub fn on_complete(
            tb_context: usize,
            tb_packet: *tb_client.Packet,
            timestamp: u64,
            result_ptr: ?[*]const u8,
            result_len: u32,
        ) callconv(.C) void {
            const self: *RequestContext = @ptrCast(@alignCast(tb_packet.*.user_data.?));

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
                    stdx.copy_disjoint(.inexact, u8, &writable, readable[0..result_len]);
                    break :blk writable;
                } else null,
                .result_len = result_len,
            };
        }
    };
}

const Completion = struct {
    pending: bool,
    mutex: Mutex = .{},
    cond: Condition = .{},

    pub fn complete(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        assert(self.pending == true);
        self.pending = false;
        self.cond.signal();
    }

    pub fn wait_pending(self: *Completion) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.pending == true) {
            self.cond.wait(&self.mutex);
        }
    }
};

pub const TB_Client = struct {
    client: *tb_client.ClientInterface,
    allocator: std.mem.Allocator,

    const Self = @This();
    const concurrency_max: u32 = constants.client_request_queue_max * 2;

    const FullRequestContext = RequestContextType(tigerbeetle.vsr.constants.message_body_size_max);

    pub fn init(allocator: std.mem.Allocator, addresses: []const u8, cluster: u128) !Self {
        var interface: *tb_client.ClientInterface = try allocator.create(tb_client.ClientInterface);
        _ = &interface;
        var self = Self{ .allocator = allocator, .client = interface };
        tb_client.init(allocator, interface, cluster, addresses, @intCast(@intFromPtr(&self)), FullRequestContext.on_complete) catch |err| {
            std.log.err("{}", .{err});
        };
        return self;
    }
    pub fn parse_result(self: *Self, comptime operation: StateMachine.Operation, result: []u8, result_len: u32) ![]StateMachine.ResultType(operation) {
        const res = StateMachine.ResultType(operation);
        var result_fixed_bytes = std.ArrayList(u8).init(self.allocator);
        try result_fixed_bytes.appendSlice(result);
        result_fixed_bytes.shrinkAndFree(result_len);
        const item_slice = try result_fixed_bytes.toOwnedSlice();
        const result_final: []res = try self.allocator.alloc(res, result_len / @sizeOf(res));
        const result_inter = std.mem.bytesAsSlice(res, item_slice);
        @memcpy(result_final, result_inter);
        return result_final;
    }
    fn as_bytes(self: *Self, comptime operation: StateMachine.Operation, data: anytype) ![]u8 {
        assert(@TypeOf(data) == StateMachine.EventType(operation));
        var args = std.ArrayList(u8).init(self.allocator);
        inline for (@typeInfo(@TypeOf(data)).Struct.fields) |object_tree_field| {
            const unwrapped_field = @field(data, object_tree_field.name);
            try args.appendSlice(std.mem.asBytes(&unwrapped_field));
        }
        return args.toOwnedSlice();
    }
    fn serialize_query_slice(self: *Self, comptime operation: StateMachine.Operation, data: []StateMachine.EventType(operation)) ![]u8 {
        assert(StateMachine.event_is_slice(operation));
        var args = std.ArrayList(u8).init(self.allocator);

        for (0..data.len) |i| {
            const item = data[i];
            assert(@TypeOf(item) == StateMachine.EventType(operation));
            if (operation == .lookup_accounts or operation == .lookup_transfers) {
                var num: [16]u8 = .{0} ** 16;
                std.mem.writeInt(u128, &num, item, .little);
                try args.appendSlice(&num);
                continue;
            }
            try args.appendSlice(try self.as_bytes(operation, item));
        }
        return args.toOwnedSlice();
    }
    fn serialize_query(self: *Self, comptime operation: StateMachine.Operation, data: StateMachine.EventType(operation)) ![]u8 {
        assert(!StateMachine.event_is_slice(operation));
        var args = std.ArrayList(u8).init(self.allocator);
        try args.appendSlice(try self.as_bytes(operation, data));
        return args.toOwnedSlice();
    }
    pub fn create_accounts(self: *Self, data: []StateMachine.EventType(.create_accounts)) !?[]StateMachine.ResultType(.create_accounts) {
        const data_bytes = try self.serialize_query_slice(.create_accounts, data);
        const raw_reply = try self.raw_req(.create_accounts, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.create_accounts, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn create_transfers(self: *Self, data: []StateMachine.EventType(.create_transfers)) !?[]StateMachine.ResultType(.create_transfers) {
        const data_bytes = try self.serialize_query_slice(.create_transfers, data);
        const raw_reply = try self.raw_req(.create_transfers, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.create_transfers, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn lookup_accounts(self: *Self, data: []StateMachine.EventType(.lookup_accounts)) !?[]StateMachine.ResultType(.lookup_accounts) {
        const data_bytes = try self.serialize_query_slice(.lookup_accounts, data);
        const raw_reply = try self.raw_req(.lookup_accounts, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.lookup_accounts, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn lookup_transfers(self: *Self, data: []StateMachine.EventType(.lookup_transfers)) !?[]StateMachine.ResultType(.lookup_transfers) {
        const data_bytes = try self.serialize_query_slice(.lookup_transfers, data);
        const raw_reply = try self.raw_req(.lookup_transfers, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.lookup_transfers, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn query_accounts(self: *Self, data: []StateMachine.EventType(.query_accounts)) !?[]StateMachine.ResultType(.query_accounts) {
        const data_bytes = try self.serialize_query_slice(.query_accounts, data);
        const raw_reply = try self.raw_req(.query_accounts, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.query_accounts, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn query_transfers(self: *Self, data: []StateMachine.EventType(.query_transfers)) !?[]StateMachine.ResultType(.query_transfers) {
        const data_bytes = try self.serialize_query_slice(.query_transfers, data);
        const raw_reply = try self.raw_req(.query_transfers, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.query_transfers, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn get_account_transfers(self: *Self, data: StateMachine.EventType(.get_account_transfers)) !?[]StateMachine.ResultType(.get_account_transfers) {
        const data_bytes = try self.serialize_query(.get_account_transfers, data);
        const raw_reply = try self.raw_req(.get_account_transfers, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.get_account_transfers, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    pub fn get_account_balances(self: *Self, data: StateMachine.EventType(.get_account_balances)) !?[]StateMachine.ResultType(.get_account_balances) {
        const data_bytes = try self.serialize_query(.get_account_balances, data);
        const raw_reply = try self.raw_req(.get_account_balances, data_bytes);
        if (raw_reply) |raw| {
            if (raw.result) |res| {
                const new_slice: []const u8 = res[0..];
                return try self.parse_result(.get_account_balances, @constCast(new_slice), raw.result_len);
            }
        }
        return null;
    }
    fn raw_req(self: *Self, op: StateMachine.Operation, data: []u8) !?RequestReply(tigerbeetle.vsr.constants.message_body_size_max) {
        var completion = Completion{ .pending = true };
        var request = FullRequestContext{
            .packet = undefined,
            .completion = &completion,
            .sent_data_size = @intCast(data.len),
        };

        const packet = &request.packet;
        packet.operation = @intFromEnum(op);
        packet.data = @ptrCast(data);
        packet.data_size = @intCast(data.len);
        packet.user_data = &request;
        packet.user_tag = 0;
        packet.status = .ok;
        try self.client.submit(packet);
        completion.wait_pending();

        return request.reply;
    }
};
