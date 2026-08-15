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
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;
const op_echo: u16 = 1;
const op_status: u16 = 2;

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = r4_app.system();
    if (argU32After(ctx.argsRaw(), exit_arg)) |exit_code| {
        ctx.write("SVCAPPD lifecycle exit=");
        ctx.printU64(exit_code);
        ctx.println("");
        return @intCast(exit_code);
    }
    if (hasArg(ctx.argsRaw(), stall_endpoint_arg)) return holdService(&ctx, true);
    if (hasArg(ctx.argsRaw(), hold_arg)) return holdService(&ctx, false);
    if (hasArg(ctx.argsRaw(), apitest_arg)) return runServiceApiTest(&ctx);

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
        const id = child.instance_id;
        if (!waitServiceInstance(&ctx, id, 100)) {
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
        if (!waitInstanceGone(&ctx, id, 100)) {
            ctx.println("SVCAPPD service instance still active");
            ok = false;
        }
    }

    ctx.write("SVCAPPD result: ");
    ctx.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn holdService(ctx: *const r4os.r4sys.Context, stall_endpoint: bool) i32 {
    const endpoint_enabled = stall_endpoint or hasArg(ctx.argsRaw(), endpoint_arg);
    const endpoint_name: [*:0]const u8 = if (stall_endpoint) stall_service_name else service_name;
    var handle: u32 = 0;
    if (endpoint_enabled) {
        var info: r4os.abi.ServiceInfo = .{};
        var tick: u32 = 0;
        while (tick < 100 and handle == 0) : (tick += 1) {
            const rc = ctx.serviceEndpointRegister(endpoint_name, 0, &info);
            if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
                handle = info.handle;
                ctx.write(if (stall_endpoint) "SVCAPPD stall endpoint handle=" else "SVCAPPD endpoint handle=");
                ctx.printU64(@intCast(handle));
                ctx.println("");
                break;
            }
            ctx.sleepTicks(1);
        }
        if (handle == 0) {
            ctx.println("SVCAPPD endpoint registration failed");
            return 2;
        }
    }
    while (!ctx.programShouldClose()) {
        if (handle != 0 and !stall_endpoint) {
            const poll = ctx.serviceEndpointPoll(handle);
            if (poll < 0) return poll;
            if (poll > 0) {
                const rc = handleServiceRequest(ctx, handle);
                if (rc < 0) return rc;
            }
        }
        ctx.sleepTicks(1);
    }
    if (handle != 0) _ = ctx.serviceEndpointUnregister(handle);
    return 0;
}

fn handleServiceRequest(ctx: *const r4os.r4sys.Context, handle: u32) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = ctx.serviceEndpointRecv(handle, &header, payload[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;
    const payload_len: usize = @intCast(got);
    if (header.op == op_echo) {
        return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_ok, payload[0..payload_len]);
    }
    if (header.op == op_status) {
        return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_ok, "OK");
    }
    return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
}

fn runServiceApiTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("SVCAPPD service api");
    var ok = true;
    if (!ctx.hasFn("service_call")) {
        ctx.println("SVCAPPD service api unsupported");
        ok = false;
    }

    var info: r4os.abi.ServiceInfo = .{};
    const handle = waitServiceOpen(ctx, &info, 100) orelse blk: {
        ctx.println("SVCAPPD service api open failed");
        ok = false;
        break :blk 0;
    };
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
        _ = ctx.serviceClose(handle);
    }

    ctx.write("SVCAPPD service api result: ");
    ctx.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn waitServiceOpen(ctx: *const r4os.r4sys.Context, info: *r4os.abi.ServiceInfo, max_ticks: u32) ?u32 {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const rc = ctx.serviceOpen(service_name, info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) return info.handle;
        ctx.sleepTicks(1);
    }
    const rc = ctx.serviceOpen(service_name, info);
    if (rc == r4os.abi.service_api_result_ok and info.handle != 0) return info.handle;
    return null;
}

fn waitServiceInstance(ctx: *const r4os.r4sys.Context, id: u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (serviceInstanceOk(ctx, id)) {
            ctx.println("SVCAPPD instance role=background class=service hostless=ok");
            return true;
        }
        ctx.sleepTicks(1);
    }
    if (serviceInstanceOk(ctx, id)) {
        ctx.println("SVCAPPD instance role=background class=service hostless=ok");
        return true;
    }
    return false;
}

fn serviceInstanceOk(ctx: *const r4os.r4sys.Context, id: u32) bool {
    var info: r4os.abi.ProgramInstanceInfo = .{};
    if (inventoryProgramById(ctx, id, &info) != 1) return false;
    return info.task_id != 0 and
        info.role == @intFromEnum(r4os.abi.ProgramInstanceRole.background) and
        info.app_class == @intFromEnum(r4os.abi.ProgramInstanceClass.service) and
        info.state == @intFromEnum(r4os.abi.ProgramInstanceState.running) and
        info.window_id == -1 and
        (info.flags & r4os.abi.ProgramInstanceFlag.terminal_mode) == 0;
}

fn waitInstanceGone(ctx: *const r4os.r4sys.Context, id: u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (!instanceExists(ctx, id)) return true;
        ctx.sleepTicks(1);
    }
    return !instanceExists(ctx, id);
}

fn instanceExists(ctx: *const r4os.r4sys.Context, id: u32) bool {
    var info: r4os.abi.ProgramInstanceInfo = .{};
    // An unavailable or continuously mutating snapshot must not be confused
    // with a confirmed removal.
    return inventoryProgramById(ctx, id, &info) != 0;
}

// 1 = found, 0 = stable snapshot confirms missing, -1 = unavailable/restart.
fn inventoryProgramById(ctx: *const r4os.r4sys.Context, id: u32, out: *r4os.abi.ProgramInstanceInfo) i32 {
    out.* = .{};
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &summary)) return -1;
        while (true) {
            var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramInstanceSnapshot = undefined;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readProgramInventoryPage(ctx, &cursor, entries[0..], &page)) return -1;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return -1;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.info.id == id) {
                    out.* = entry.info;
                    return 1;
                }
            }
            if (page.status == r4os.abi.program_inventory_status_complete) return 0;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return -1;
        }
    }
    return -1;
}

fn beginProgramInventory(
    ctx: *const r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    summary: *r4os.abi.ProgramInventorySummary,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        cursor.* = .{};
        summary.* = .{};
        const status = ctx.programInventoryBegin(cursor, summary);
        if (status == r4os.abi.program_handle_ok) return true;
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sleepTicks(1);
    }
    return false;
}

fn readProgramInventoryPage(
    ctx: *const r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramInstanceSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = ctx.programInventoryPrograms(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sleepTicks(1);
    }
    return false;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn argU32After(args: [*:0]const u8, wanted: []const u8) ?u32 {
    var offset: usize = 0;
    var matched = false;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        const token = args[start..offset];
        if (matched) {
            if (token.len == 0) return null;
            var value: u64 = 0;
            for (token) |ch| {
                if (ch < '0' or ch > '9') return null;
                value = value * 10 + (ch - '0');
                if (value > 0x7FFF_FFFF) return null;
            }
            return @intCast(value);
        }
        matched = equalsIgnoreCase(token, wanted);
    }
    return null;
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
