const std = @import("std");
const r4os = @import("r4os");

const self_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SVCAPPD.R4X";
const service_name = "SVCAPPD";
const stall_service_name = "SVCSTALL";
const hold_arg = "/HOLD";
const endpoint_arg = "/ENDPOINT";
const stall_endpoint_arg = "/STALLENDPOINT";
const apitest_arg = "/APITEST";
const exit_arg = "/EXIT";
const lifecycle_timeout_ms: u64 = 10_000;
const op_echo: u16 = 1;
const op_status: u16 = 2;

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    var ctx = r4_app.system();
    const options = parseOptions(r4_app) catch {
        ctx.println("SVCAPPD invalid arguments");
        return 2;
    };
    if (options.exit_code) |exit_code| {
        ctx.write("SVCAPPD lifecycle exit=");
        ctx.printU64(exit_code);
        ctx.println("");
        return @intCast(exit_code);
    }
    if (options.stall) return holdService(r4_app, &ctx, true, true);
    if (options.hold) return holdService(r4_app, &ctx, false, options.endpoint);
    if (options.apitest) return runServiceApiTest(r4_app, &ctx);

    ctx.println("SVCAPPD");
    var ok = true;

    const class = ctx.programClass(self_path, .auto);
    if (class != @intFromEnum(r4os.abi.ProgramClass.service)) {
        ctx.write("SVCAPPD class failed: ");
        ctx.printI32(class);
        ctx.println("");
        ok = false;
    }

    var child: r4os.abi.ProgramProcessHandle = .{};
    const spawn_status = ctx.programSpawnHandle(self_path, hold_arg, .auto, &child);
    if (spawn_status != r4os.abi.program_handle_ok) {
        ctx.write("SVCAPPD spawn failed: ");
        ctx.printI32(spawn_status);
        ctx.println("");
        ok = false;
    } else {
        if (!waitServiceInstance(r4_app, child, 100)) {
            ctx.println("SVCAPPD service instance not visible");
            ok = false;
        }
        var status: r4os.abi.ProgramStatus = .{};
        ctx.programStatus(&status);
        ctx.write("SVCAPPD programstatus instances=");
        ctx.printU64(@intCast(status.instance_count));
        ctx.println("");
        if (ctx.programHandleKill(&child) != r4os.abi.program_handle_ok) {
            ctx.println("SVCAPPD kill failed");
            ok = false;
        }
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.programHandleWait(&child, ctx.ticksFromMilliseconds(lifecycle_timeout_ms), &completion) != r4os.abi.program_handle_ok or
            ctx.programHandleReap(&child, &completion) != r4os.abi.program_handle_ok)
        {
            ctx.println("SVCAPPD completion wait/reap failed");
            ok = false;
        }
        if (!waitInstanceGone(r4_app, child, 100)) {
            ctx.println("SVCAPPD service instance still active");
            ok = false;
        }
    }

    ctx.write("SVCAPPD result: ");
    ctx.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn holdService(app: *r4os.App2, ctx: *const r4os.r4sys.Context, stall_endpoint: bool, endpoint_enabled: bool) i32 {
    var endpoint: ?r4os.app_services.ServiceEndpoint = null;
    defer if (endpoint) |*value| {
        _ = value.unregister();
    };
    if (endpoint_enabled) {
        const services = app.services() orelse return 2;
        const clock = app.clock() catch return 2;
        var budget = r4os.rpc_budget.Budget.fromTicks(clock.read, 100) catch return 2;
        endpoint = switch (r4os.app_services.registerUntil(&services, if (stall_endpoint) stall_service_name else service_name, 0, &budget)) {
            .endpoint => |value| value,
            .failure => {
                ctx.println("SVCAPPD endpoint registration failed");
                return 2;
            },
        };
        ctx.write(if (stall_endpoint) "SVCAPPD stall endpoint handle=" else "SVCAPPD endpoint handle=");
        ctx.printU64(endpoint.?.raw);
        ctx.println("");
    }
    while (!app.shouldClose()) {
        if (!stall_endpoint) {
            if (endpoint) |*value| {
                switch (value.wait(.{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 200_000_000 })) {
                    .timed_out => {},
                    .failure => |code| {
                        if (app.shouldClose()) break;
                        return code;
                    },
                    .ready => {
                        const rc = handleServiceRequest(value);
                        if (rc < 0) return rc;
                    },
                }
                continue;
            }
        }
        // The deliberate STALL fixture must never receive or reply.
        ctx.sleepTicks(1);
    }
    return 0;
}

fn handleServiceRequest(endpoint: *r4os.app_services.ServiceEndpoint) i32 {
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const message = switch (endpoint.recv(&payload)) {
        .message => |value| value,
        .would_block => return 0,
        .failure => |code| return code,
    };
    if (message.header.op == op_echo) return endpoint.replyIfPending(message.header.request_id, r4os.abi.service_api_result_ok, payload[0..message.bytes]);
    if (message.header.op == op_status) return endpoint.replyIfPending(message.header.request_id, r4os.abi.service_api_result_ok, "OK");
    return endpoint.replyIfPending(message.header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
}

fn runServiceApiTest(app: *r4os.App2, ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("SVCAPPD service api");
    var ok = true;
    if (!ctx.hasFn("service_call")) {
        ctx.println("SVCAPPD service api unsupported");
        ok = false;
    }

    const services = app.services() orelse return 1;
    const clock = app.clock() catch return 1;
    var budget = r4os.rpc_budget.Budget.fromTicks(clock.read, 100) catch return 1;
    var connection = switch (r4os.app_services.openUntil(&services, service_name, &budget)) {
        .connection => |value| value,
        .failure => {
            ctx.println("SVCAPPD service api open failed");
            return 1;
        },
    };
    defer _ = connection.close();
    const info = connection.info;
    const handle = connection.raw;
    if (handle != 0) {
        if (info.state != r4os.abi.service_state_running or (info.flags & r4os.abi.service_api_flag_endpoint) == 0) {
            ctx.println("SVCAPPD service api status invalid");
            ok = false;
        }
        if ((info.flags & r4os.abi.service_api_flag_queue_backed) == 0 or info.queue_depth != r4os.abi.service_api_endpoint_queue_depth) {
            ctx.println("SVCAPPD service api queue contract invalid");
            ok = false;
        }
        var status_info: r4os.abi.ServiceInfo = .{};
        if (ctx.serviceStatus(service_name, &status_info) != r4os.abi.service_api_result_ok or status_info.handle != handle) {
            ctx.println("SVCAPPD service api status lookup failed");
            ok = false;
        }

        var response_header: r4os.abi.ServiceMessageHeader = .{};
        var response: [16]u8 = undefined;
        const echo_len = ctx.serviceCall(handle, op_echo, "PING", &response_header, response[0..], 100);
        if (echo_len != 4 or response_header.status != r4os.abi.service_api_result_ok or !bytesEq(response[0..4], "PING")) {
            ctx.write("SVCAPPD service api echo failed rc=");
            ctx.printI32(echo_len);
            ctx.write(" status=");
            ctx.printI32(response_header.status);
            ctx.println("");
            ok = false;
        }

        var tiny: [2]u8 = undefined;
        const small_rc = ctx.serviceCall(handle, op_echo, "PONG", &response_header, tiny[0..], 100);
        if (small_rc != r4os.abi.service_api_result_buffer_too_small) {
            ctx.write("SVCAPPD service api small response buffer failed rc=");
            ctx.printI32(small_rc);
            ctx.println("");
            ok = false;
        }

        const too_large: [r4os.abi.service_api_max_payload + 1]u8 = .{0} ** (r4os.abi.service_api_max_payload + 1);
        const large_rc = ctx.serviceCall(handle, op_echo, too_large[0..], &response_header, response[0..], 100);
        if (large_rc != r4os.abi.service_api_result_payload_too_large) {
            ctx.println("SVCAPPD service api oversize request failed");
            ok = false;
        }

        const bad_op_len = ctx.serviceCall(handle, 0x9999, "X", &response_header, response[0..], 100);
        if (bad_op_len <= 0 or response_header.status != r4os.abi.service_api_result_bad_op) {
            ctx.write("SVCAPPD service api bad op failed rc=");
            ctx.printI32(bad_op_len);
            ctx.write(" status=");
            ctx.printI32(response_header.status);
            ctx.println("");
            ok = false;
        }

        var unknown: r4os.abi.ServiceInfo = .{};
        if (ctx.serviceOpen("UNKNOWN-SVC", &unknown) != r4os.abi.service_api_result_not_found) {
            ctx.println("SVCAPPD service api unknown service failed");
            ok = false;
        }
        var queue_info: r4os.abi.ServiceInfo = .{};
        if (ctx.serviceStatus(service_name, &queue_info) != r4os.abi.service_api_result_ok or
            queue_info.queue_depth != r4os.abi.service_api_endpoint_queue_depth or
            queue_info.queue_high_water == 0 or
            queue_info.requests < 3 or
            queue_info.responses < 3 or
            queue_info.busy_rejections != 0)
        {
            ctx.println("SVCAPPD service api queue metrics failed");
            ok = false;
        }
    }

    ctx.write("SVCAPPD service api result: ");
    ctx.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn waitServiceInstance(app: *r4os.App2, handle: r4os.abi.ProgramProcessHandle, max_ticks: u32) bool {
    const ctx = app.system();
    const clock = app.clock() catch return false;
    var budget = r4os.rpc_budget.Budget.fromTicks(clock.read, max_ticks) catch return false;
    while (!app.shouldClose()) {
        var info: r4os.abi.ProgramInstanceInfo = .{};
        if (inventoryProgram(app, handle, &info, &budget) == 1 and
            info.task_id != 0 and info.role == @intFromEnum(r4os.abi.ProgramInstanceRole.background) and
            info.app_class == @intFromEnum(r4os.abi.ProgramInstanceClass.service) and
            info.state == @intFromEnum(r4os.abi.ProgramInstanceState.running) and info.window_id == -1 and
            info.flags & r4os.abi.ProgramInstanceFlag.terminal_mode == 0)
        {
            ctx.println("SVCAPPD instance role=background class=service hostless=ok");
            return true;
        }
        _ = budget.remainingTicks() catch return false;
        ctx.sleepTicks(1);
    }
    return false;
}

fn waitInstanceGone(app: *r4os.App2, handle: r4os.abi.ProgramProcessHandle, max_ticks: u32) bool {
    const ctx = app.system();
    const clock = app.clock() catch return false;
    var budget = r4os.rpc_budget.Budget.fromTicks(clock.read, max_ticks) catch return false;
    while (!app.shouldClose()) {
        var info: r4os.abi.ProgramInstanceInfo = .{};
        // Only a complete stable view can prove exact-generation absence.
        if (inventoryProgram(app, handle, &info, &budget) == 0) return true;
        _ = budget.remainingTicks() catch return false;
        ctx.sleepTicks(1);
    }
    return false;
}

fn inventoryProgram(app: *r4os.App2, handle: r4os.abi.ProgramProcessHandle, out: *r4os.abi.ProgramInstanceInfo, budget: *r4os.rpc_budget.Budget) i32 {
    out.* = .{};
    const allocator = app.allocator() orelse return -1;
    const provider = app.inventoryProvider(.full) catch return -1;
    var clock = app.clock() catch return -1;
    var capacity: u32 = 32;
    grow: while (true) {
        _ = budget.remainingTicks() catch return -1;
        const storage = allocator.alloc(r4os.abi.ProgramInstanceSnapshot, capacity) catch return -1;
        defer allocator.free(storage);
        var reader = r4os.inventory_reader.Reader.initAbsolute(.full, .{ .address = @intFromPtr(storage.ptr), .length = std.mem.sliceAsBytes(storage).len }, capacity, r4os.abi.program_inventory_page_max, provider, budget.deadline) catch return -1;
        defer budget.deadline = reader.deadline;
        while (true) {
            const progress = reader.step(app.shouldClose(), r4os.inventory_reader.PlatformClock.sample, &clock) catch return -1;
            switch (@as(r4os.inventory_reader.Status, @enumFromInt(progress.status))) {
                .complete => {
                    const match = reader.findExact(handle) catch return -1;
                    if (match.disposition == @intFromEnum(r4os.inventory_reader.Disposition.missing)) return 0;
                    if (match.disposition != @intFromEnum(r4os.inventory_reader.Disposition.found)) return -1;
                    out.* = (reader.fullView() catch return -1)[match.index].info;
                    return 1;
                },
                .initial, .more => {},
                .would_block => app.system().sleepTicks(1),
                .restart => {
                    _ = reader.restart() catch return -1;
                },
                .capacity => {
                    capacity = @max(progress.total, std.math.mul(u32, capacity, 2) catch return -1);
                    continue :grow;
                },
                else => return -1,
            }
        }
    }
}

const Options = struct { hold: bool = false, stall: bool = false, endpoint: bool = false, apitest: bool = false, exit_code: ?u32 = null };
fn parseOptions(app: *r4os.App2) !Options {
    var failure: r4os.arguments.Failure = .{};
    var cursor = try app.argCursor(.{ .quotes = 0, .max_bytes = 4096 }, &failure);
    var result: Options = .{};
    while (try cursor.next()) |token| {
        const value = try token.bytes(app.args());
        if (equalsIgnoreCase(value, hold_arg)) result.hold = true;
        if (equalsIgnoreCase(value, stall_endpoint_arg)) result.stall = true;
        if (equalsIgnoreCase(value, endpoint_arg)) result.endpoint = true;
        if (equalsIgnoreCase(value, apitest_arg)) result.apitest = true;
        if (equalsIgnoreCase(value, exit_arg)) {
            const number = (try cursor.next()) orelse return error.InvalidExit;
            const text = try number.bytes(app.args());
            if (text.len == 0) return error.InvalidExit;
            var n: u32 = 0;
            for (text) |ch| {
                if (ch < '0' or ch > '9') return error.InvalidExit;
                n = try std.math.mul(u32, n, 10);
                n = try std.math.add(u32, n, ch - '0');
                if (n > std.math.maxInt(i32)) return error.InvalidExit;
            }
            if (result.exit_code == null) result.exit_code = n;
        }
    }
    return result;
}

fn bytesEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}
