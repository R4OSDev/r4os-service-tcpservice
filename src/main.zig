const r4os = @import("r4os");
const std = @import("std");
const network = r4os.network_family.common;
const transport = r4os.network_transport;

const service_name = "TCPSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const status_arg = "/STATUS";
const service_timeout_ms: u64 = 1000;
const service_register_wait_ticks: u32 = 450;
const long_request_ticks: u64 = 20;
const front_handles_max: usize = 16;
const listeners_max: usize = 4;
const pending_ops_max: usize = 8;
const pending_reserved_slots: usize = 1;
const pending_per_owner_max: u32 = 4;
const pending_per_handle_max: u32 = 1;
const pending_data_max: usize = if (r4os.abi.net_service_tcp_write_max > r4os.abi.net_service_tcp_read_max) r4os.abi.net_service_tcp_write_max else r4os.abi.net_service_tcp_read_max;
const pending_reply_payload_max: usize = @sizeOf(r4os.abi.NetServiceTcpResult) + r4os.abi.net_service_tcp_read_max;
const deferred_read_timeout_ms: u64 = 50;
const deferred_write_timeout_ms: u64 = 50;
const owner_mismatch_result: i32 = -4;

const FrontHandle = struct {
    v6_provider: u64 = 0,
    v6_socket: u64 = 0,
    v6_generation: u64 = 0,
    typed_listener: bool = false,
    typed_v4_listener: bool = false,
    typed_retiring: bool = false,
    typed_generation: u64 = 0,
    typed_owner: r4os.abi.ProgramProcessHandle = .{},
    typed_endpoint: r4os.abi.NetworkEndpoint = .{},
    used: bool = false,
    handle: u32 = 0,
    backend_handle: u32 = 0,
    owner_id: u32 = 0,
    conn_id: u32 = 0,
    generation: u32 = 0,
    // 0.56.5: != 0 => Accept-Reply war unzustellbar (Requester hat den
    // Request per Timeout gecancelt, reply() lieferte NOT_FOUND). Die
    // Verbindung wird NICHT gekillt, sondern unter ihrem Listen-Port
    // geparkt; der naechste Accept-Poll desselben Owners holt sie ohne
    // Backend-Roundtrip ab. Vorher riss der Cleanup die frisch
    // angenommene Client-Verbindung ab - unter TCPSVC-Last (Antwortzeit
    // > SSHD-Accept-Wait) toetete das JEDE eingehende Verbindung.
    parked_port: u16 = 0,
};

const Listener = struct {
    used: bool = false,
    port: u16 = 0,
    owner_id: u32 = 0,
};

const PendingKind = enum(u8) {
    none,
    read,
    write,
    accept,
    connect,
    close,
};

const PendingFinish = enum(u8) {
    completed,
    timeout,
    cancelled,
};

const PendingOperation = struct {
    typed: bool = false,
    network_request: r4os.abi.NetworkSocketRequest = .{},
    used: bool = false,
    kind: PendingKind = .none,
    request_id: u32 = 0,
    owner_id: u32 = 0,
    front_handle: u32 = 0,
    backend_handle: u32 = 0,
    generation: u32 = 0,
    conn_id: u32 = 0,
    op: u16 = 0,
    requested_bytes: u16 = 0,
    port: u16 = 0,
    start_ticks: u64 = 0,
    deadline_ticks: u64 = 0,
    reason: [32]u8 = .{0} ** 32,
    data: [pending_data_max]u8 = .{0} ** pending_data_max,
    reply: r4os.abi.NetServiceTcpResult = .{},
    reply_payload: [pending_reply_payload_max]u8 = .{0} ** pending_reply_payload_max,
};

const ServiceState = struct {
    provider: u64 = 0,
    next_typed_generation: u64 = 1,
    typed_count: u32 = 0,
    typed_sweep_tick: u64 = 0,
    transport_tick: u64 = 0,
    requests: u64 = 0,
    status_requests: u64 = 0,
    action_requests: u64 = 0,
    connect_requests: u64 = 0,
    write_requests: u64 = 0,
    read_requests: u64 = 0,
    close_requests: u64 = 0,
    listen_requests: u64 = 0,
    accept_requests: u64 = 0,
    poll_requests: u64 = 0,
    abort_requests: u64 = 0,
    bad_ops: u64 = 0,
    bad_requests: u64 = 0,
    backend_errors: u64 = 0,
    owner_mismatches: u64 = 0,
    cleanup_runs: u64 = 0,
    cleanup_handles: u64 = 0,
    cleanup_listeners: u64 = 0,
    reply_misses: u64 = 0,
    undelivered_handles: u64 = 0,
    parked_accepts: u64 = 0,
    unparked_accepts: u64 = 0,
    self_tests: u64 = 0,
    last_request_ticks: u64 = 0,
    max_request_ticks: u64 = 0,
    long_requests: u64 = 0,
    request_ticks_total: u64 = 0,
    next_typed_only_handle: u32 = std.math.maxInt(u32),
    next_generation: u32 = 1,
    handles: [front_handles_max]FrontHandle = .{FrontHandle{}} ** front_handles_max,
    listeners: [listeners_max]Listener = .{Listener{}} ** listeners_max,
    pending: [pending_ops_max]PendingOperation = .{PendingOperation{}} ** pending_ops_max,
    last_result: i32 = r4os.abi.tcp_result_no_connection,
    last_handle: u32 = 0,
    last_backend_handle: u32 = 0,
    last_port: u16 = 0,
    last_error: [32]u8 = .{0} ** 32,
    last_lifecycle_cause: u32 = r4os.abi.net_service_socket_lifecycle_unknown,
    lifecycle_closed: u64 = 0,
    lifecycle_reset: u64 = 0,
    lifecycle_timeout: u64 = 0,
    lifecycle_peer_gone: u64 = 0,
    lifecycle_local_abort: u64 = 0,
    lifecycle_local_close: u64 = 0,
    lifecycle_pending_close: u64 = 0,
    lifecycle_would_block: u64 = 0,
    lifecycle_bad_handle: u64 = 0,
    lifecycle_owner_mismatch: u64 = 0,
    readiness_samples: u64 = 0,
    readiness_readable: u64 = 0,
    readiness_writable: u64 = 0,
    readiness_would_block: u64 = 0,
    readiness_terminal: u64 = 0,
    last_readiness_handle: u32 = 0,
    last_pending_rx: u32 = 0,
    last_rx_window: u32 = 0,
    last_tx_window: u32 = 0,
    last_readiness_status: u32 = r4os.abi.net_service_status_idle,
    last_readiness_lifecycle: u32 = r4os.abi.net_service_socket_lifecycle_unknown,
    deferred_started: u64 = 0,
    deferred_read_started: u64 = 0,
    deferred_write_started: u64 = 0,
    deferred_accept_started: u64 = 0,
    deferred_completed: u64 = 0,
    deferred_timeouts: u64 = 0,
    deferred_cancelled: u64 = 0,
    deferred_late_replies: u64 = 0,
    deferred_busy: u64 = 0,
    deferred_owner_busy: u64 = 0,
    deferred_handle_busy: u64 = 0,
    deferred_reserved_busy: u64 = 0,
    deferred_blocked: u64 = 0,
    close_abort_fallbacks: u64 = 0,
    last_deferred_ticks: u64 = 0,
    max_deferred_ticks: u64 = 0,
    last_completion_ticks: u64 = 0,
    max_completion_ticks: u64 = 0,
    last_deferred_handle: u32 = 0,
    last_deferred_kind: PendingKind = .none,
    last_deferred_reason: [32]u8 = .{0} ** 32,
    last_blocked_owner: u32 = 0,
    last_blocked_handle: u32 = 0,
    last_blocked_kind: PendingKind = .none,
    last_blocked_reason: [32]u8 = .{0} ** 32,
    endpoint_queue_depth: u32 = 0,
    endpoint_queue_used: u32 = 0,
    endpoint_queue_high: u32 = 0,
    endpoint_busy: u64 = 0,
    endpoint_timeouts: u64 = 0,
    endpoint_cancellations: u64 = 0,
    tx_window_waits: u64 = 0,
    tx_window_zero: u64 = 0,
    tx_partial_writes: u64 = 0,
    tx_write_completions: u64 = 0,
    tx_write_timeouts: u64 = 0,
    tx_write_terminal: u64 = 0,
    tx_write_retransmits: u64 = 0,
    tx_performance_samples: u64 = 0,
    tx_wire_segments: u64 = 0,
    tx_wire_bytes: u64 = 0,
    last_outstanding_segments: u32 = 0,
    last_outstanding_bytes: u32 = 0,
    last_pure_ack_tx: u64 = 0,
    last_adapter_poll_rounds: u64 = 0,
    last_service_poll_requests: u64 = 0,
    last_service_poll_skips: u64 = 0,
    last_write_handle: u32 = 0,
    last_write_requested: u32 = 0,
    last_write_written: u32 = 0,
    last_write_window: u32 = 0,
    last_write_retransmits: u32 = 0,
    last_write_status: u32 = r4os.abi.net_service_status_idle,
    last_write_lifecycle: u32 = r4os.abi.net_service_socket_lifecycle_unknown,
};

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,
    dev: ?r4os.r4dev.Context = null,

    fn init(r4_app: *r4os.App2) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
            .dev = r4_app.devicesLowLevel(),
        };
    }
};

const TcpReply = struct {
    result: r4os.abi.NetServiceTcpResult,
    data: []const u8 = "",
};

const FrontLookup = struct {
    ok: bool = false,
    index: usize = 0,
    entry: FrontHandle = .{},
    result: i32 = r4os.abi.tcp_result_no_connection,
    last_error: []const u8 = "",
};

// Non-zero initializers keep R4X scratch buffers file-backed instead of BSS-only.
var service_payload_buffer: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var service_status_text: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var backend_response_buffer: [r4os.abi.ipc_max_message_size]u8 = .{0xA5} ** r4os.abi.ipc_max_message_size;
var backend_result_data: [r4os.abi.net_service_tcp_read_max]u8 = .{0xA5} ** r4os.abi.net_service_tcp_read_max;
var translated_payload: [r4os.abi.net_service_tcp_message_payload_max]u8 = .{0xA5} ** r4os.abi.net_service_tcp_message_payload_max;
var deadline_payload: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var service_reply_payload: [@sizeOf(r4os.abi.NetServiceTcpResult) + r4os.abi.net_service_tcp_read_max]u8 = .{0xA5} ** (@sizeOf(r4os.abi.NetServiceTcpResult) + r4os.abi.net_service_tcp_read_max);
var service_status_reply: r4os.abi.NetServiceTcpStatus = .{};
var service_result_reply: r4os.abi.NetServiceTcpResult = .{};
var selftest_status_response: [@sizeOf(r4os.abi.NetServiceTcpStatus)]u8 = .{0xA5} ** @sizeOf(r4os.abi.NetServiceTcpStatus);
var selftest_result_response: [@sizeOf(r4os.abi.NetServiceTcpResult)]u8 = .{0xA5} ** @sizeOf(r4os.abi.NetServiceTcpResult);

pub fn r4_app_main(r4_app: *r4os.App2) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(app.sys.argsRaw(), selftest_arg) catch return r4os.abi.service_api_result_invalid) return runSelfTest(&app);
    if (hasArg(app.sys.argsRaw(), ping_arg) catch return r4os.abi.service_api_result_invalid) return runPing(&app);
    if (hasArg(app.sys.argsRaw(), status_arg) catch return r4os.abi.service_api_result_invalid) return runStatusClient(&app);
    return runService(&app);
}

fn runService(app: *const App) i32 {
    if (!app.sys.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    const actual = app.sys.base.generation2 orelse return r4os.abi.err_no_group;
    const clock = r4os.inventory_reader.PlatformClock.fromContext2(actual) catch return r4os.abi.err_no_fn;
    var registration_budget = r4os.rpc_budget.Budget.fromTicks(clock.read, service_register_wait_ticks) catch |err| return r4os.rpc_budget.code(err);
    var last_register_rc: i32 = 0;
    while (handle == 0 and !app.sys.programShouldClose()) {
        _ = registration_budget.remainingTicks() catch |err| {
            if (err == error.TimedOut) break;
            return r4os.rpc_budget.code(err);
        };
        const rc = app.sys.serviceEndpointRegister(service_name, 0, &info);
        last_register_rc = rc;
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            app.sys.write("TCPSVC endpoint handle=");
            app.sys.printU64(@intCast(handle));
            app.sys.println("");
            break;
        }
        app.sys.sleepTicks(1);
    }
    if (handle == 0) {
        app.sys.write("TCPSVC endpoint registration failed rc=");
        app.sys.printI32(last_register_rc);
        app.sys.println("");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = ServiceState{ .provider = network.provider(app.sys) catch 0 };
    setLastError(&state, "ready");
    var service_loop = r4os.ServiceLoop.init(app.sys, handle, .{});
    while (true) {
        sweepNetworkOwners(app, &state);
        const pending_rc = processPending(app, handle, &state);
        if (pending_rc < 0) {
            cleanupService(app, handle, &state, "pending");
            _ = app.sys.serviceEndpointUnregister(handle);
            return pending_rc;
        }
        const deadline: ?u64 = if (pendingCount(&state) != 0) app.sys.ticks() +| 1 else networkSweepDeadline(app, &state);
        switch (service_loop.wait(deadline)) {
            .requests => |pending| {
                const rc = service_loop.drain(pending, handleLoopRequest, .{ app, handle, &state });
                if (rc >= 0) continue;
                cleanupService(app, handle, &state, "request");
                _ = app.sys.serviceEndpointUnregister(handle);
                return rc;
            },
            .deadline, .idle => {},
            .stop => break,
            .failure => |raw| {
                cleanupService(app, handle, &state, "endpoint");
                _ = app.sys.serviceEndpointUnregister(handle);
                return raw;
            },
        }
    }

    service_loop.report(service_name);
    cleanupService(app, handle, &state, "service-stop");
    _ = app.sys.serviceEndpointUnregister(handle);
    app.sys.println("TCPSVC stopped cleanly");
    return 0;
}

fn handleLoopRequest(app: *const App, handle: u32, state: *ServiceState) i32 {
    const request_start = app.sys.ticks();
    const rc = handleRequest(app, handle, state);
    recordRequestTicks(state, app.sys.ticks() - request_start);
    if (rc < 0) return rc;
    return processPending(app, handle, state);
}

fn handleRequest(app: *const App, handle: u32, state: *ServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceEndpointRecv(handle, &header, service_payload_buffer[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    const request = service_payload_buffer[0..payload_len];
    if (header.op >= r4os.abi.network_op_info and header.op <= r4os.abi.network_op_release) return replyNetwork(app, handle, header.request_id, state, header.client_id, header.op, request);
    return switch (header.op) {
        r4os.abi.net_service_op_status => replyTextStatus(app, handle, header.request_id, state, header.client_id),
        r4os.abi.net_service_op_tcp_status_result => replyStatusResult(app, handle, header.request_id, state, header.client_id),
        r4os.abi.net_service_op_tcp_connect,
        r4os.abi.net_service_op_tcp_write,
        r4os.abi.net_service_op_tcp_read,
        r4os.abi.net_service_op_tcp_close,
        r4os.abi.net_service_op_tcp_listen,
        r4os.abi.net_service_op_tcp_accept_read,
        r4os.abi.net_service_op_tcp_close_listen,
        r4os.abi.net_service_op_tcp_poll,
        r4os.abi.net_service_op_tcp_accept,
        => replyTextOperation(app, handle, header.request_id, state, header.client_id, resultOpForTextOp(header.op), request),
        r4os.abi.net_service_op_tcp_connect_result,
        r4os.abi.net_service_op_tcp_write_result,
        r4os.abi.net_service_op_tcp_read_result,
        r4os.abi.net_service_op_tcp_close_result,
        r4os.abi.net_service_op_tcp_listen_result,
        r4os.abi.net_service_op_tcp_accept_read_result,
        r4os.abi.net_service_op_tcp_close_listen_result,
        r4os.abi.net_service_op_tcp_poll_result,
        r4os.abi.net_service_op_tcp_accept_result,
        r4os.abi.net_service_op_tcp_abort_result,
        r4os.abi.net_service_op_tcp_accept_poll_result,
        => replyStructuredOperation(app, handle, header.request_id, state, header.client_id, header.op, request),
        else => {
            state.bad_ops +%= 1;
            return finishReply(state, app.sys.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP"));
        },
    };
}

fn recordRequestTicks(state: *ServiceState, ticks: u64) void {
    state.last_request_ticks = ticks;
    state.request_ticks_total +%= ticks;
    if (ticks > state.max_request_ticks) state.max_request_ticks = ticks;
    if (ticks >= long_request_ticks) state.long_requests +%= 1;
}

fn replyTextStatus(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32) i32 {
    state.status_requests +%= 1;
    service_status_reply = makeStatus(app, state, owner_id);
    var w = Writer{ .out = service_status_text[0..] };
    writeStatusText(&w, state, &service_status_reply);
    return finishReply(state, app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice()));
}

fn replyStatusResult(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32) i32 {
    state.status_requests +%= 1;
    service_status_reply = makeStatus(app, state, owner_id);
    const bytes: [*]const u8 = @ptrCast(&service_status_reply);
    return finishReply(state, app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.NetServiceTcpStatus)]));
}

fn replyTextOperation(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32, op: u16, request: []const u8) i32 {
    if (op == 0) {
        state.bad_ops +%= 1;
        return finishReply(state, app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_bad_op, "BADOP"));
    }
    const reply = performOperation(app, state, owner_id, op, request, null, backend_result_data[0..]);
    var buf: [512]u8 = .{0} ** 512;
    var w = Writer{ .out = buf[0..] };
    writeOperationText(&w, &reply.result, reply.data);
    return finishReply(state, app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, w.slice()));
}

fn replyStructuredOperation(app: *const App, handle: u32, request_id: u32, state: *ServiceState, owner_id: u32, op: u16, request: []const u8) i32 {
    const view = r4os.service_deadline.split(request);
    var reply = performOperation(app, state, owner_id, op, view.payload, view.deadline_tick, backend_result_data[0..]);
    if (op == r4os.abi.net_service_op_tcp_read_result and shouldDeferRead(&reply.result, view.payload)) {
        if (startDeferredRead(app, state, request_id, owner_id, view.payload, view.deadline_tick, &reply.result)) return 0;
    }
    if (op == r4os.abi.net_service_op_tcp_write_result and shouldDeferWrite(&reply.result, view.payload)) {
        if (startDeferredWrite(app, state, request_id, owner_id, view.payload, view.deadline_tick, &reply.result)) return 0;
    }
    if (shouldDeferAccept(op, &reply.result, view.payload)) {
        if (startDeferredAccept(app, state, request_id, owner_id, op, view.payload, view.deadline_tick, &reply.result)) return 0;
    }
    const send_rc = sendStructuredReply(app, handle, request_id, &reply.result, reply.data);
    if (send_rc != r4os.abi.service_api_result_ok) cleanupUndeliveredNewHandle(app, state, op, &reply.result);
    const reply_rc = finishReply(state, send_rc);
    if (reply_rc < 0) return reply_rc;
    if (reply.result.result == 0 and releasesFrontHandleOp(op) and view.payload.len >= 4) {
        const cancel_rc = cancelPendingForHandle(app, handle, state, owner_id, readLe32(view.payload, 0), "handle-closed");
        if (cancel_rc < 0) return cancel_rc;
    }
    return reply_rc;
}

fn finishReply(state: *ServiceState, rc: i32) i32 {
    if (rc == r4os.abi.service_api_result_not_found) {
        state.reply_misses +%= 1;
        setLastError(state, "reply-missing");
        return 0;
    }
    return rc;
}

fn cleanupUndeliveredNewHandle(app: *const App, state: *ServiceState, op: u16, result: *const r4os.abi.NetServiceTcpResult) void {
    if (!createsFrontHandleOp(op)) return;
    if (result.result != 0 or result.handle == 0) return;
    if ((result.flags & r4os.abi.net_service_tcp_flag_handle_valid) == 0) return;
    const lookup = resolveFrontHandleForRelease(state, result.handle);
    if (!lookup.ok) return;
    // 0.56.5: Unzustellbare ACCEPT-Replies parken statt killen (siehe
    // FrontHandle.parked_port). Nur wenn kein Listen-Port bekannt ist
    // (defensiv) oder es ein Connect war, wird wie bisher abgeraeumt.
    if (acceptFrontHandleOp(op) and result.port != 0) {
        state.handles[lookup.index].parked_port = result.port;
        state.parked_accepts +%= 1;
        state.undelivered_handles +%= 1;
        setLastError(state, "reply-parked");
        return;
    }
    closeBackendHandle(app, lookup.entry.backend_handle);
    releaseFrontHandleAt(state, lookup.index);
    state.cleanup_handles +%= 1;
    state.undelivered_handles +%= 1;
    setLastError(state, "reply-undelivered");
}

fn createsFrontHandleOp(op: u16) bool {
    return op == r4os.abi.net_service_op_tcp_connect_result or
        op == r4os.abi.net_service_op_tcp_accept_result or
        op == r4os.abi.net_service_op_tcp_accept_read_result or
        op == r4os.abi.net_service_op_tcp_accept_poll_result;
}

fn acceptFrontHandleOp(op: u16) bool {
    return op == r4os.abi.net_service_op_tcp_accept_result or
        op == r4os.abi.net_service_op_tcp_accept_read_result or
        op == r4os.abi.net_service_op_tcp_accept_poll_result;
}

fn sendStructuredReply(app: *const App, handle: u32, request_id: u32, result: *const r4os.abi.NetServiceTcpResult, data: []const u8) i32 {
    const payload = structuredReplyPayload(result, data);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, payload);
}

fn structuredReplyPayload(result: *const r4os.abi.NetServiceTcpResult, data: []const u8) []const u8 {
    return structuredReplyPayloadInto(&service_result_reply, service_reply_payload[0..], result, data);
}

fn structuredReplyPayloadInto(result_copy: *r4os.abi.NetServiceTcpResult, out: []u8, result: *const r4os.abi.NetServiceTcpResult, data: []const u8) []const u8 {
    result_copy.* = result.*;
    const result_bytes: [*]const u8 = @ptrCast(result_copy);
    @memcpy(out[0..@sizeOf(r4os.abi.NetServiceTcpResult)], result_bytes[0..@sizeOf(r4os.abi.NetServiceTcpResult)]);
    var data_len: usize = 0;
    if ((result_copy.flags & r4os.abi.net_service_tcp_flag_data) != 0 and result_copy.bytes != 0) {
        data_len = @min(@as(usize, @intCast(result_copy.bytes)), data.len);
        if (data_len != 0) @memcpy(out[@sizeOf(r4os.abi.NetServiceTcpResult) .. @sizeOf(r4os.abi.NetServiceTcpResult) + data_len], data[0..data_len]);
    }
    return out[0 .. @sizeOf(r4os.abi.NetServiceTcpResult) + data_len];
}

fn shouldDeferRead(result: *const r4os.abi.NetServiceTcpResult, request: []const u8) bool {
    if (request.len < 6) return false;
    if (readLe16(request, 4) == 0) return false;
    if (result.result != 0) return false;
    if ((result.flags & r4os.abi.net_service_tcp_flag_data) != 0 and result.bytes != 0) return false;
    return serviceStatusCode(result.flags) == r4os.abi.net_service_status_would_block or
        result.lifecycle_cause == r4os.abi.net_service_socket_lifecycle_would_block;
}

fn shouldDeferWrite(result: *const r4os.abi.NetServiceTcpResult, request: []const u8) bool {
    if (request.len <= 4) return false;
    if (request.len > r4os.abi.net_service_tcp_message_payload_max) return false;
    return isWriteWouldBlockResult(result);
}

fn startDeferredRead(app: *const App, state: *ServiceState, request_id: u32, owner_id: u32, request: []const u8, requested_deadline: ?u64, initial: *r4os.abi.NetServiceTcpResult) bool {
    if (requested_deadline == r4os.service_deadline.tcp_poll_tick) return false;
    const front_handle = readLe32(request, 0);
    const lookup = resolveLegacyFrontHandle(state, front_handle, owner_id);
    if (!lookup.ok) return false;
    const now = app.sys.ticks();
    const deadline = deferredDeadline(app, requested_deadline, deferred_read_timeout_ms);
    if (now >= deadline) {
        markDeferredTimeout(initial, front_handle, "read-deadline");
        return false;
    }
    if (pendingCountForHandle(state, front_handle, lookup.entry.generation) >= pending_per_handle_max) {
        state.deferred_handle_busy +%= 1;
        recordDeferredBlock(state, .read, owner_id, front_handle, "pending-handle");
        markDeferredWouldBlock(initial, front_handle, "pending-handle");
        return false;
    }
    if (pendingCountForOwner(state, owner_id) >= pending_per_owner_max) {
        state.deferred_owner_busy +%= 1;
        recordDeferredBlock(state, .read, owner_id, front_handle, "pending-owner");
        markDeferredWouldBlock(initial, front_handle, "pending-owner");
        return false;
    }
    if (pendingCount(state) >= pendingActiveLimit()) {
        state.deferred_reserved_busy +%= 1;
        recordDeferredBlock(state, .read, owner_id, front_handle, "pending-reserve");
        markDeferredWouldBlock(initial, front_handle, "pending-reserve");
        return false;
    }
    const slot = allocatePendingSlot(state) orelse {
        state.deferred_reserved_busy +%= 1;
        recordDeferredBlock(state, .read, owner_id, front_handle, "pending-full");
        markDeferredWouldBlock(initial, front_handle, "pending-full");
        return false;
    };
    state.pending[slot] = .{
        .used = true,
        .kind = .read,
        .request_id = request_id,
        .owner_id = owner_id,
        .front_handle = front_handle,
        .backend_handle = lookup.entry.backend_handle,
        .generation = lookup.entry.generation,
        .conn_id = lookup.entry.conn_id,
        .op = r4os.abi.net_service_op_tcp_read_result,
        .requested_bytes = readLe16(request, 4),
        .start_ticks = now,
        .deadline_ticks = deadline,
    };
    copyFixed(state.pending[slot].reason[0..], "read-would-block");
    state.deferred_started +%= 1;
    state.deferred_read_started +%= 1;
    setLastDeferred(state, .read, front_handle, "read-would-block", 0);
    return true;
}

fn startDeferredWrite(app: *const App, state: *ServiceState, request_id: u32, owner_id: u32, request: []const u8, requested_deadline: ?u64, initial: *r4os.abi.NetServiceTcpResult) bool {
    if (requested_deadline == r4os.service_deadline.tcp_poll_tick) return false;
    const front_handle = readLe32(request, 0);
    const payload = request[4..];
    if (payload.len == 0 or payload.len > pending_data_max) {
        markDeferredWouldBlock(initial, front_handle, "pending-too-large");
        return false;
    }
    const lookup = resolveLegacyFrontHandle(state, front_handle, owner_id);
    if (!lookup.ok) return false;
    const now = app.sys.ticks();
    const deadline = deferredDeadline(app, requested_deadline, deferred_write_timeout_ms);
    if (now >= deadline) {
        markDeferredTimeout(initial, front_handle, "write-deadline");
        return false;
    }
    if (pendingCountForHandle(state, front_handle, lookup.entry.generation) >= pending_per_handle_max) {
        state.deferred_handle_busy +%= 1;
        recordDeferredBlock(state, .write, owner_id, front_handle, "pending-handle");
        markDeferredWouldBlock(initial, front_handle, "pending-handle");
        return false;
    }
    if (pendingCountForOwner(state, owner_id) >= pending_per_owner_max) {
        state.deferred_owner_busy +%= 1;
        recordDeferredBlock(state, .write, owner_id, front_handle, "pending-owner");
        markDeferredWouldBlock(initial, front_handle, "pending-owner");
        return false;
    }
    if (pendingCount(state) >= pendingActiveLimit()) {
        state.deferred_reserved_busy +%= 1;
        recordDeferredBlock(state, .write, owner_id, front_handle, "pending-reserve");
        markDeferredWouldBlock(initial, front_handle, "pending-reserve");
        return false;
    }
    const slot = allocatePendingSlot(state) orelse {
        state.deferred_reserved_busy +%= 1;
        recordDeferredBlock(state, .write, owner_id, front_handle, "pending-full");
        markDeferredWouldBlock(initial, front_handle, "pending-full");
        return false;
    };
    state.pending[slot] = .{
        .used = true,
        .kind = .write,
        .request_id = request_id,
        .owner_id = owner_id,
        .front_handle = front_handle,
        .backend_handle = lookup.entry.backend_handle,
        .generation = lookup.entry.generation,
        .conn_id = lookup.entry.conn_id,
        .op = r4os.abi.net_service_op_tcp_write_result,
        .requested_bytes = @intCast(payload.len),
        .start_ticks = now,
        .deadline_ticks = deadline,
    };
    copyBytes(state.pending[slot].data[0..payload.len], payload);
    copyFixed(state.pending[slot].reason[0..], "tx-window");
    state.deferred_started +%= 1;
    state.deferred_write_started +%= 1;
    state.tx_window_waits +%= 1;
    setLastDeferred(state, .write, front_handle, "tx-window", 0);
    return true;
}

fn shouldDeferAccept(op: u16, result: *const r4os.abi.NetServiceTcpResult, request: []const u8) bool {
    if (op != r4os.abi.net_service_op_tcp_accept_poll_result or request.len < 2 or readLe16(request, 0) == 0) return false;
    if (result.result != 0 or result.handle != 0 or (result.flags & r4os.abi.net_service_tcp_flag_handle_valid) != 0) return false;
    return serviceStatusCode(result.flags) == r4os.abi.net_service_status_would_block or
        result.lifecycle_cause == r4os.abi.net_service_socket_lifecycle_would_block;
}

fn startDeferredAccept(app: *const App, state: *ServiceState, request_id: u32, owner_id: u32, op: u16, request: []const u8, requested_deadline: ?u64, initial: *r4os.abi.NetServiceTcpResult) bool {
    if (requested_deadline == r4os.service_deadline.tcp_poll_tick) return false;
    const deadline = requested_deadline orelse return false;
    const port = readLe16(request, 0);
    const now = app.sys.ticks();
    if (now >= deadline) {
        markDeferredTimeout(initial, 0, "accept-deadline");
        return false;
    }
    if (pendingAcceptForOwner(state, owner_id, port)) {
        state.deferred_handle_busy +%= 1;
        recordDeferredBlock(state, .accept, owner_id, 0, "pending-listener");
        markDeferredWouldBlock(initial, 0, "pending-listener");
        return false;
    }
    if (pendingCountForOwner(state, owner_id) >= pending_per_owner_max) {
        state.deferred_owner_busy +%= 1;
        recordDeferredBlock(state, .accept, owner_id, 0, "pending-owner");
        markDeferredWouldBlock(initial, 0, "pending-owner");
        return false;
    }
    if (pendingCount(state) >= pendingActiveLimit()) {
        state.deferred_reserved_busy +%= 1;
        recordDeferredBlock(state, .accept, owner_id, 0, "pending-reserve");
        markDeferredWouldBlock(initial, 0, "pending-reserve");
        return false;
    }
    const slot = allocatePendingSlot(state) orelse {
        state.deferred_reserved_busy +%= 1;
        recordDeferredBlock(state, .accept, owner_id, 0, "pending-full");
        markDeferredWouldBlock(initial, 0, "pending-full");
        return false;
    };
    state.pending[slot] = .{
        .used = true,
        .kind = .accept,
        .request_id = request_id,
        .owner_id = owner_id,
        .port = port,
        .op = op,
        .start_ticks = now,
        .deadline_ticks = deadline,
    };
    copyFixed(state.pending[slot].reason[0..], "accept-would-block");
    state.deferred_started +%= 1;
    state.deferred_accept_started +%= 1;
    setLastDeferred(state, .accept, 0, "accept-would-block", 0);
    return true;
}

fn processPending(app: *const App, endpoint_handle: u32, state: *ServiceState) i32 {
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (!state.pending[i].used) continue;
        const rc = switch (state.pending[i].kind) {
            .connect => processPendingNetworkConnect(app, endpoint_handle, state, i),
            .read => processPendingRead(app, endpoint_handle, state, i),
            .write => processPendingWrite(app, endpoint_handle, state, i),
            .accept => processPendingAccept(app, endpoint_handle, state, i),
            else => completePendingLocal(app, endpoint_handle, state, i, r4os.abi.net_service_result_bad_op, r4os.abi.net_service_status_cancelled, r4os.abi.net_service_socket_lifecycle_local_abort, 0, "pending-cancel", .cancelled),
        };
        if (rc < 0) return rc;
    }
    return 0;
}

fn processPendingAccept(app: *const App, endpoint_handle: u32, state: *ServiceState, index: usize) i32 {
    const pending = &state.pending[index];
    if (pendingExpired(app, pending)) {
        return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "operation-deadline", .timeout);
    }
    var request: [2]u8 = .{0} ** 2;
    writeLe16(request[0..], 0, pending.port);
    var reply = performAccept(app, state, pending.owner_id, pending.op, request[0..], pending.data[0..]);
    if (shouldDeferAccept(pending.op, &reply.result, request[0..])) {
        if (pendingExpired(app, pending)) {
            return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "accept-timeout", .timeout);
        }
        return 0;
    }
    if (reply.result.handle != 0 and (reply.result.flags & r4os.abi.net_service_tcp_flag_handle_valid) != 0) {
        pending.front_handle = reply.result.handle;
        const lookup = resolveFrontHandle(state, reply.result.handle, pending.owner_id);
        if (lookup.ok) {
            pending.backend_handle = lookup.entry.backend_handle;
            pending.generation = lookup.entry.generation;
            pending.conn_id = lookup.entry.conn_id;
        }
    }
    return completePendingReply(app, endpoint_handle, state, index, &reply.result, reply.data, "accept-complete", .completed);
}

fn processPendingRead(app: *const App, endpoint_handle: u32, state: *ServiceState, index: usize) i32 {
    const pending = &state.pending[index];
    if (pendingExpired(app, pending)) {
        return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "operation-deadline", .timeout);
    }
    const lookup = resolveFrontHandle(state, pending.front_handle, pending.owner_id);
    if (!lookup.ok or lookup.entry.generation != pending.generation or lookup.entry.backend_handle != pending.backend_handle) {
        return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.tcp_result_no_connection, r4os.abi.net_service_status_cancelled, r4os.abi.net_service_socket_lifecycle_bad_handle, 0, "pending-stale", .cancelled);
    }

    var poll_request: [4]u8 = .{0} ** 4;
    writeLe32(poll_request[0..], 0, pending.backend_handle);
    var poll = backendResult(app, r4os.abi.net_service_op_tcp_poll_result, poll_request[0..], pending.data[0..]) orelse {
        return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.net_service_result_bad_service, r4os.abi.net_service_status_failed, r4os.abi.net_service_socket_lifecycle_unknown, 0, "backend", .cancelled);
    };
    poll.result.handle = pending.front_handle;
    poll.result.conn_id = if (poll.result.conn_id != 0) poll.result.conn_id else pending.conn_id;
    poll.result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    noteReadiness(state, &poll.result);

    if (poll.result.pending_rx != 0) {
        var read_request: [6]u8 = .{0} ** 6;
        writeLe32(read_request[0..], 0, pending.backend_handle);
        writeLe16(read_request[0..], 4, pending.requested_bytes);
        var reply = backendResult(app, r4os.abi.net_service_op_tcp_read_result, read_request[0..], pending.data[0..]) orelse {
            return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.net_service_result_bad_service, r4os.abi.net_service_status_failed, r4os.abi.net_service_socket_lifecycle_unknown, 0, "backend", .cancelled);
        };
        if (shouldKeepPendingRead(&reply.result)) {
            if (pendingExpired(app, pending)) {
                return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "deferred-timeout", .timeout);
            }
            return 0;
        }
        return completePendingReply(app, endpoint_handle, state, index, &reply.result, reply.data, "read-complete", .completed);
    }

    if (tcpLifecycleTerminal(poll.result.lifecycle_cause)) {
        return completePendingFromPoll(app, endpoint_handle, state, index, &poll.result, "read-terminal");
    }

    if (pendingExpired(app, pending)) {
        return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "deferred-timeout", .timeout);
    }
    return 0;
}

fn processPendingWrite(app: *const App, endpoint_handle: u32, state: *ServiceState, index: usize) i32 {
    const pending = &state.pending[index];
    if (pendingExpired(app, pending)) {
        return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "operation-deadline", .timeout);
    }
    const lookup = resolveFrontHandle(state, pending.front_handle, pending.owner_id);
    if (!lookup.ok or lookup.entry.generation != pending.generation or lookup.entry.backend_handle != pending.backend_handle) {
        return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.tcp_result_no_connection, r4os.abi.net_service_status_cancelled, r4os.abi.net_service_socket_lifecycle_bad_handle, 0, "pending-stale", .cancelled);
    }

    var poll = pollBackendHandle(app, pending.backend_handle, pending.data[0..]) orelse {
        return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.net_service_result_bad_service, r4os.abi.net_service_status_failed, r4os.abi.net_service_socket_lifecycle_unknown, 0, "backend", .cancelled);
    };
    rewriteForFrontHandle(&poll.result, pending.front_handle, pending.conn_id);
    noteReadiness(state, &poll.result);

    if (tcpLifecycleTerminal(poll.result.lifecycle_cause)) {
        var out = poll.result;
        out.action = r4os.abi.net_service_tcp_action_write;
        if (out.result == 0) out.result = r4os.abi.tcp_result_no_connection;
        out.flags &= ~r4os.abi.net_service_tcp_flag_ok;
        out.flags = withServiceStatus(out.flags | r4os.abi.net_service_tcp_flag_lifecycle_valid, r4os.abi.net_service_status_failed);
        out.service_status = r4os.abi.net_service_status_failed;
        out.requested_bytes = pending.requested_bytes;
        if (spanZ(out.last_error[0..]).len == 0) copyFixed(out.last_error[0..], "write-terminal");
        return completePendingReply(app, endpoint_handle, state, index, &out, "", "write-terminal", .cancelled);
    }

    if (poll.result.tx_window == 0) {
        state.tx_window_zero +%= 1;
        if (pendingExpired(app, pending)) {
            state.tx_write_timeouts +%= 1;
            return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "tx-window-timeout", .timeout);
        }
        return 0;
    }

    const write_payload = writeBackendPayload(pending.backend_handle, pending.data[0..pending.requested_bytes]) orelse {
        return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.net_service_result_bad_request, r4os.abi.net_service_status_failed, r4os.abi.net_service_socket_lifecycle_bad_handle, 0, "too-large", .cancelled);
    };
    var reply = backendResult(app, r4os.abi.net_service_op_tcp_write_result, write_payload, pending.data[0..]) orelse {
        return completePendingLocal(app, endpoint_handle, state, index, r4os.abi.net_service_result_bad_service, r4os.abi.net_service_status_failed, r4os.abi.net_service_socket_lifecycle_unknown, 0, "backend", .cancelled);
    };
    rewriteForFrontHandle(&reply.result, pending.front_handle, pending.conn_id);
    reply.result.requested_bytes = pending.requested_bytes;
    if (isWriteWouldBlockResult(&reply.result)) {
        state.tx_window_zero +%= 1;
        if (pendingExpired(app, pending)) {
            state.tx_write_timeouts +%= 1;
            return completePendingLocal(app, endpoint_handle, state, index, 0, r4os.abi.net_service_status_timeout, r4os.abi.net_service_socket_lifecycle_timeout, r4os.abi.net_service_tcp_flag_timeout, "tx-window-timeout", .timeout);
        }
        return 0;
    }
    return completePendingReply(app, endpoint_handle, state, index, &reply.result, reply.data, "write-complete", .completed);
}

fn completePendingFromPoll(app: *const App, endpoint_handle: u32, state: *ServiceState, index: usize, poll: *const r4os.abi.NetServiceTcpResult, reason: []const u8) i32 {
    const pending = &state.pending[index];
    var out = poll.*;
    out.action = r4os.abi.net_service_tcp_action_read;
    out.handle = pending.front_handle;
    out.conn_id = if (out.conn_id != 0) out.conn_id else pending.conn_id;
    out.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    if (out.result == 0 and tcpLifecycleTerminal(out.lifecycle_cause)) {
        out.result = r4os.abi.tcp_result_no_connection;
        out.flags = withServiceStatus(out.flags, r4os.abi.net_service_status_failed);
        out.service_status = r4os.abi.net_service_status_failed;
    }
    if (spanZ(out.last_error[0..]).len == 0) copyFixed(out.last_error[0..], reason);
    return completePendingReply(app, endpoint_handle, state, index, &out, "", reason, .cancelled);
}

fn completePendingLocal(app: *const App, endpoint_handle: u32, state: *ServiceState, index: usize, result_code: i32, service_status: u32, lifecycle: u32, extra_flags: u32, reason: []const u8, finish: PendingFinish) i32 {
    const pending = &state.pending[index];
    var out = r4os.abi.NetServiceTcpResult{
        .action = actionForOp(pending.op),
        .result = result_code,
        .flags = withServiceStatus(extra_flags, service_status),
        .handle = pending.front_handle,
        .conn_id = pending.conn_id,
        .lifecycle_cause = lifecycle,
        .service_status = service_status,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .write_max = r4os.abi.net_service_tcp_write_max,
        .read_max = r4os.abi.net_service_tcp_read_max,
        .local_ip = localIp(app),
    };
    if (pending.front_handle != 0) out.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    if (lifecycle != r4os.abi.net_service_socket_lifecycle_unknown) out.flags |= r4os.abi.net_service_tcp_flag_lifecycle_valid;
    if (result_code == 0 and service_status != r4os.abi.net_service_status_failed and service_status != r4os.abi.net_service_status_cancelled) out.flags |= r4os.abi.net_service_tcp_flag_ok;
    copyFixed(out.last_error[0..], reason);
    recordTcpLifecycle(state, lifecycle);
    return completePendingReply(app, endpoint_handle, state, index, &out, "", reason, finish);
}

fn completePendingReply(app: *const App, endpoint_handle: u32, state: *ServiceState, index: usize, result: *const r4os.abi.NetServiceTcpResult, data: []const u8, reason: []const u8, finish: PendingFinish) i32 {
    const pending = &state.pending[index];
    var out = result.*;
    out.handle = pending.front_handle;
    out.conn_id = if (out.conn_id != 0) out.conn_id else pending.conn_id;
    if (pending.front_handle != 0) out.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    // Write progress has no response body and is independent of DATA.
    if (pending.kind != .write and (out.flags & r4os.abi.net_service_tcp_flag_data) == 0) out.bytes = 0;
    if (spanZ(out.last_error[0..]).len == 0) copyFixed(out.last_error[0..], reason);

    const kind = pending.kind;
    const front_handle = pending.front_handle;
    const requested_bytes = pending.requested_bytes;
    const request_id = pending.request_id;
    const start_ticks = pending.start_ticks;
    const op = pending.op;
    if (kind == .write) noteTxWriteResult(state, &out, requested_bytes);
    noteResult(state, &out);
    const payload = structuredReplyPayloadInto(&pending.reply, pending.reply_payload[0..], &out, data);
    const rc = app.sys.serviceEndpointReply(endpoint_handle, request_id, r4os.abi.service_api_result_ok, payload);
    if (rc != r4os.abi.service_api_result_ok) cleanupUndeliveredNewHandle(app, state, op, &out);
    const elapsed = app.sys.ticks() - start_ticks;
    state.pending[index] = .{};
    return finishPendingReply(state, rc, kind, front_handle, reason, elapsed, finish);
}

fn finishPendingReply(state: *ServiceState, rc: i32, kind: PendingKind, handle: u32, reason: []const u8, elapsed: u64, finish: PendingFinish) i32 {
    setLastDeferred(state, kind, handle, reason, elapsed);
    state.last_completion_ticks = elapsed;
    if (elapsed > state.max_completion_ticks) state.max_completion_ticks = elapsed;
    switch (finish) {
        .completed => {},
        .timeout => state.deferred_timeouts +%= 1,
        .cancelled => state.deferred_cancelled +%= 1,
    }
    if (rc == r4os.abi.service_api_result_not_found) {
        state.deferred_late_replies +%= 1;
        state.reply_misses +%= 1;
        setLastError(state, "deferred-late");
        return 0;
    }
    if (rc == r4os.abi.service_api_result_ok) state.deferred_completed +%= 1;
    return rc;
}

fn shouldKeepPendingRead(result: *const r4os.abi.NetServiceTcpResult) bool {
    if (result.result != 0) return false;
    if ((result.flags & r4os.abi.net_service_tcp_flag_data) != 0 and result.bytes != 0) return false;
    if (tcpLifecycleTerminal(result.lifecycle_cause)) return false;
    return serviceStatusCode(result.flags) == r4os.abi.net_service_status_would_block or
        result.lifecycle_cause == r4os.abi.net_service_socket_lifecycle_would_block;
}

fn pendingExpired(app: *const App, pending: *const PendingOperation) bool {
    return app.sys.ticks() >= pending.deadline_ticks;
}

fn allocatePendingSlot(state: *ServiceState) ?usize {
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (!state.pending[i].used) return i;
    }
    return null;
}

fn hasPendingForHandle(state: *const ServiceState, handle: u32, generation: u32) bool {
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (state.pending[i].used and state.pending[i].front_handle == handle and state.pending[i].generation == generation) return true;
    }
    return false;
}

fn pendingCountForHandle(state: *const ServiceState, handle: u32, generation: u32) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (state.pending[i].used and state.pending[i].front_handle == handle and state.pending[i].generation == generation) count += 1;
    }
    return count;
}

fn pendingCountForOwner(state: *const ServiceState, owner_id: u32) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (state.pending[i].used and ownerMatches(state.pending[i].owner_id, owner_id)) count += 1;
    }
    return count;
}

fn pendingAcceptForOwner(state: *const ServiceState, owner_id: u32, port: u16) bool {
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        const pending = state.pending[i];
        if (pending.used and pending.kind == .accept and pending.port == port and ownerMatches(pending.owner_id, owner_id)) return true;
    }
    return false;
}

fn pendingCount(state: *const ServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (state.pending[i].used) count += 1;
    }
    return count;
}

fn pendingActiveLimit() u32 {
    return @intCast(pending_ops_max - pending_reserved_slots);
}

fn recordDeferredBlock(state: *ServiceState, kind: PendingKind, owner_id: u32, handle: u32, reason: []const u8) void {
    state.deferred_busy +%= 1;
    state.deferred_blocked +%= 1;
    state.last_blocked_owner = owner_id;
    state.last_blocked_handle = handle;
    state.last_blocked_kind = kind;
    copyFixed(state.last_blocked_reason[0..], reason);
    setLastDeferred(state, kind, handle, reason, 0);
}

fn markDeferredWouldBlock(result: *r4os.abi.NetServiceTcpResult, handle: u32, reason: []const u8) void {
    result.result = 0;
    result.handle = handle;
    result.bytes = 0;
    result.flags &= ~r4os.abi.net_service_tcp_flag_data;
    result.flags &= ~r4os.abi.net_service_tcp_flag_ok;
    result.flags |= r4os.abi.net_service_tcp_flag_lifecycle_valid;
    if (handle != 0) result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    result.flags = withServiceStatus(result.flags, r4os.abi.net_service_status_would_block);
    result.service_status = r4os.abi.net_service_status_would_block;
    result.lifecycle_cause = r4os.abi.net_service_socket_lifecycle_would_block;
    copyFixed(result.last_error[0..], reason);
}

fn markDeferredTimeout(result: *r4os.abi.NetServiceTcpResult, handle: u32, reason: []const u8) void {
    result.result = 0;
    result.handle = handle;
    result.bytes = 0;
    result.flags &= ~(r4os.abi.net_service_tcp_flag_data | r4os.abi.net_service_tcp_flag_ok | r4os.abi.net_service_tcp_flag_handle_valid);
    result.flags |= r4os.abi.net_service_tcp_flag_timeout | r4os.abi.net_service_tcp_flag_lifecycle_valid;
    if (handle != 0) result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    result.flags = withServiceStatus(result.flags, r4os.abi.net_service_status_timeout);
    result.service_status = r4os.abi.net_service_status_timeout;
    result.lifecycle_cause = r4os.abi.net_service_socket_lifecycle_timeout;
    copyFixed(result.last_error[0..], reason);
}

fn deferredDeadline(app: *const App, requested: ?u64, fallback_ms: u64) u64 {
    if (requested) |deadline| return deadline;
    const ticks = app.sys.ticksFromMilliseconds(fallback_ms);
    return app.sys.ticks() +| (if (ticks == 0) 1 else ticks);
}

fn setLastDeferred(state: *ServiceState, kind: PendingKind, handle: u32, reason: []const u8, ticks: u64) void {
    state.last_deferred_kind = kind;
    state.last_deferred_handle = handle;
    state.last_deferred_ticks = ticks;
    if (ticks > state.max_deferred_ticks) state.max_deferred_ticks = ticks;
    copyFixed(state.last_deferred_reason[0..], reason);
}

// The deadline controls admission, not rollback of an effect already started.
// Zero is the explicit TCPSVC nonblocking sentinel; legacy missing suffixes
// retain their existing policy. Poll must never create a deferred operation.
fn deadlineAdmission(app: *const App, op: u16, deadline_tick: ?u64) ?TcpReply {
    const deadline = deadline_tick orelse return null;
    if (deadline == r4os.service_deadline.tcp_poll_tick) {
        if (op != r4os.abi.net_service_op_tcp_connect_result) return null;
        var out = r4os.abi.NetServiceTcpResult{ .action = actionForOp(op) };
        markDeferredWouldBlock(&out, 0, "connect-poll");
        return .{ .result = out };
    }
    if (deadline == r4os.service_deadline.forever_tick or app.sys.ticks() < deadline) return null;
    var out = r4os.abi.NetServiceTcpResult{ .action = actionForOp(op) };
    markDeferredTimeout(&out, 0, "operation-deadline");
    return .{ .result = out };
}

fn performOperation(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, deadline_tick: ?u64, data_out: []u8) TcpReply {
    state.action_requests +%= 1;
    if (deadlineAdmission(app, op, deadline_tick)) |reply| return reply;
    switch (op) {
        r4os.abi.net_service_op_tcp_connect_result => {
            state.connect_requests +%= 1;
            return performConnect(app, state, owner_id, op, request, deadline_tick, data_out);
        },
        r4os.abi.net_service_op_tcp_write_result => {
            state.write_requests +%= 1;
            return performWriteOperation(app, state, owner_id, op, request, data_out);
        },
        r4os.abi.net_service_op_tcp_read_result => {
            state.read_requests +%= 1;
            return performHandleOperation(app, state, owner_id, op, request, data_out, false);
        },
        r4os.abi.net_service_op_tcp_close_result => {
            state.close_requests +%= 1;
            return performCloseOperation(app, state, owner_id, op, request, data_out);
        },
        r4os.abi.net_service_op_tcp_abort_result => {
            state.abort_requests +%= 1;
            return performHandleOperation(app, state, owner_id, op, request, data_out, true);
        },
        r4os.abi.net_service_op_tcp_poll_result => {
            state.poll_requests +%= 1;
            return performHandleOperation(app, state, owner_id, op, request, data_out, false);
        },
        r4os.abi.net_service_op_tcp_listen_result => {
            state.listen_requests +%= 1;
            return performListen(app, state, owner_id, op, request, data_out);
        },
        r4os.abi.net_service_op_tcp_close_listen_result => {
            state.listen_requests +%= 1;
            return performCloseListen(app, state, owner_id, op, request, data_out);
        },
        r4os.abi.net_service_op_tcp_accept_result,
        r4os.abi.net_service_op_tcp_accept_read_result,
        r4os.abi.net_service_op_tcp_accept_poll_result,
        => {
            state.accept_requests +%= 1;
            return performAccept(app, state, owner_id, op, request, data_out);
        },
        else => return localError(app, state, op, 0, r4os.abi.net_service_result_bad_op, "bad-op"),
    }
}

fn performConnect(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, deadline_tick: ?u64, data_out: []u8) TcpReply {
    var reply = backendResultWithDeadline(app, op, request, deadline_tick, data_out) orelse return backendError(app, state, op, "backend");
    if (reply.result.result == 0 and (reply.result.flags & r4os.abi.net_service_tcp_flag_handle_valid) != 0) {
        const backend_handle = reply.result.handle;
        const front = allocateFrontHandle(state, owner_id, backend_handle, reply.result.conn_id) orelse {
            closeBackendHandle(app, backend_handle);
            return localError(app, state, op, 0, -2, "handle-full");
        };
        reply.result.handle = front;
        reply.result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
        state.last_handle = front;
        state.last_backend_handle = backend_handle;
    }
    noteResult(state, &reply.result);
    return reply;
}

fn performWriteOperation(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) TcpReply {
    if (request.len < 4) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    if (request.len > r4os.abi.net_service_tcp_message_payload_max) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "too-large");
    const front_handle = readLe32(request, 0);
    const lookup = resolveLegacyFrontHandle(state, front_handle, owner_id);
    if (!lookup.ok) return localError(app, state, op, front_handle, lookup.result, lookup.last_error);
    const requested_len = request.len - 4;
    if (requested_len > r4os.abi.net_service_tcp_write_max) return localError(app, state, op, front_handle, r4os.abi.net_service_result_bad_request, "too-large");
    state.last_handle = front_handle;
    state.last_backend_handle = lookup.entry.backend_handle;

    if (requested_len == 0) {
        var out = localWriteResult(app, front_handle, lookup.entry.conn_id, 0, 0, r4os.abi.net_service_status_ok, r4os.abi.net_service_socket_lifecycle_active, "empty-write");
        noteTxWriteResult(state, &out.result, 0);
        noteResult(state, &out.result);
        return out;
    }

    // Optimistic write: the kernel burst planner already owns the current
    // remote-window and catalog limits. A successful write therefore avoids
    // the historical readiness poll; only a real would-block result enters
    // the deferred poll path.
    const translated = writeBackendPayload(lookup.entry.backend_handle, request[4 .. 4 + requested_len]) orelse return localError(app, state, op, front_handle, r4os.abi.net_service_result_bad_request, "too-large");
    var reply = backendResult(app, op, translated, data_out) orelse return backendError(app, state, op, "backend");
    rewriteForFrontHandle(&reply.result, front_handle, lookup.entry.conn_id);
    reply.result.requested_bytes = @intCast(requested_len);
    if (isWriteWouldBlockResult(&reply.result)) {
        return writeWouldBlockReply(app, state, front_handle, lookup.entry.conn_id, @intCast(requested_len), &reply.result, "tx-window");
    }
    noteTxWriteResult(state, &reply.result, @intCast(requested_len));
    noteResult(state, &reply.result);
    return reply;
}

fn performHandleOperation(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8, release_on_success: bool) TcpReply {
    if (request.len < 4) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const front_handle = readLe32(request, 0);
    var lookup = resolveLegacyFrontHandle(state, front_handle, owner_id);
    if (!lookup.ok and release_on_success and lookup.result == owner_mismatch_result) {
        lookup = resolveFrontHandleForRelease(state, front_handle);
    }
    if (!lookup.ok) return localError(app, state, op, front_handle, lookup.result, lookup.last_error);
    const translated = translateHandlePayload(request, lookup.entry.backend_handle) orelse return localError(app, state, op, front_handle, r4os.abi.net_service_result_bad_request, "too-large");
    var reply = backendResult(app, op, translated, data_out) orelse {
        if (release_on_success) releaseFrontHandleAt(state, lookup.index);
        return backendError(app, state, op, "backend");
    };
    reply.result.handle = front_handle;
    reply.result.conn_id = if (reply.result.conn_id != 0) reply.result.conn_id else lookup.entry.conn_id;
    if (reply.result.result == 0 or release_on_success) reply.result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    if (release_on_success) {
        releaseFrontHandleAt(state, lookup.index);
    }
    state.last_handle = front_handle;
    state.last_backend_handle = lookup.entry.backend_handle;
    noteResult(state, &reply.result);
    return reply;
}

fn performCloseOperation(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) TcpReply {
    if (request.len < 4) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const front_handle = readLe32(request, 0);
    var lookup = resolveLegacyFrontHandle(state, front_handle, owner_id);
    if (!lookup.ok and lookup.result == owner_mismatch_result) {
        lookup = resolveFrontHandleForRelease(state, front_handle);
    }
    if (!lookup.ok) return localError(app, state, op, front_handle, lookup.result, lookup.last_error);
    const translated = translateHandlePayload(request, lookup.entry.backend_handle) orelse return localError(app, state, op, front_handle, r4os.abi.net_service_result_bad_request, "too-large");
    var reply = backendResult(app, r4os.abi.net_service_op_tcp_close_result, translated, data_out) orelse {
        state.close_abort_fallbacks +%= 1;
        closeBackendHandle(app, lookup.entry.backend_handle);
        releaseFrontHandleAt(state, lookup.index);
        return backendError(app, state, op, "close-backend");
    };

    if (reply.result.result != 0) {
        state.close_abort_fallbacks +%= 1;
        if (backendResult(app, r4os.abi.net_service_op_tcp_abort_result, translated, data_out)) |fallback| {
            if (fallback.result.result == 0) {
                reply = fallback;
                setTcpLifecycle(&reply.result, r4os.abi.net_service_socket_lifecycle_local_abort);
                copyFixed(reply.result.last_error[0..], "close-abort-fallback");
            }
        }
    }

    releaseFrontHandleAt(state, lookup.index);
    reply.result.action = r4os.abi.net_service_tcp_action_close;
    reply.result.handle = front_handle;
    reply.result.conn_id = if (reply.result.conn_id != 0) reply.result.conn_id else lookup.entry.conn_id;
    reply.result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    if (reply.result.result == 0) {
        reply.result.flags |= r4os.abi.net_service_tcp_flag_ok;
        reply.result.flags = withServiceStatus(reply.result.flags, r4os.abi.net_service_status_ok);
        reply.result.service_status = r4os.abi.net_service_status_ok;
    } else {
        reply.result.flags = withServiceStatus(reply.result.flags, r4os.abi.net_service_status_failed);
        reply.result.service_status = r4os.abi.net_service_status_failed;
    }
    state.last_handle = front_handle;
    state.last_backend_handle = lookup.entry.backend_handle;
    noteResult(state, &reply.result);
    return reply;
}

fn performListen(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) TcpReply {
    if (request.len < 2) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const port = readLe16(request, 0);
    state.last_port = port;
    if (port == 0) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-port");
    const registered = listenerForPort(state, port);
    if (registered) |idx| {
        if (!ownerMatches(state.listeners[idx].owner_id, owner_id)) return ownerMismatch(state, op, 0, port);
    }
    // Ownership can outlive the backend listener after a link change.
    // Kernel listen is idempotent while that listener still exists.
    var reply = backendResult(app, op, request, data_out) orelse return backendError(app, state, op, "backend");
    if (registered == null and reply.result.result == 0 and (reply.result.flags & r4os.abi.net_service_tcp_flag_listener) != 0) {
        if (!rememberListener(state, owner_id, port)) {
            _ = backendResult(app, r4os.abi.net_service_op_tcp_close_listen_result, request, data_out);
            return localError(app, state, op, 0, -2, "listener-full");
        }
    }
    noteResult(state, &reply.result);
    return reply;
}

fn performCloseListen(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) TcpReply {
    if (request.len < 2) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const port = readLe16(request, 0);
    state.last_port = port;
    if (port == 0) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-port");
    if (listenerForPort(state, port)) |idx| {
        if (!ownerMatches(state.listeners[idx].owner_id, owner_id)) return ownerMismatch(state, op, 0, port);
    }
    var reply = backendResult(app, op, request, data_out) orelse return backendError(app, state, op, "backend");
    if (reply.result.result == 0) releaseListener(state, port);
    noteResult(state, &reply.result);
    return reply;
}

fn performAccept(app: *const App, state: *ServiceState, owner_id: u32, op: u16, request: []const u8, data_out: []u8) TcpReply {
    if (request.len < 2) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-request");
    const port = readLe16(request, 0);
    state.last_port = port;
    if (port == 0) return localError(app, state, op, 0, r4os.abi.net_service_result_bad_request, "bad-port");
    if (listenerForPort(state, port)) |idx| {
        if (!ownerMatches(state.listeners[idx].owner_id, owner_id)) return ownerMismatch(state, op, 0, port);
    }
    // 0.56.5: Zuerst geparkte Accepts abholen (unzustellbare Accept-Replies,
    // siehe FrontHandle.parked_port) - ohne neuen Backend-Accept, damit die
    // Verbindung auch unter TCPSVC-Last sofort beim Owner ankommt. Tote
    // geparkte Verbindungen werden dabei abgeraeumt.
    if (takeParkedAccept(app, state, owner_id, op, port, data_out)) |parked| return parked;
    var reply = backendResult(app, op, request, data_out) orelse return backendError(app, state, op, "backend");
    if (reply.result.result == 0 and (reply.result.flags & r4os.abi.net_service_tcp_flag_handle_valid) != 0) {
        const backend_handle = reply.result.handle;
        const front = allocateFrontHandle(state, owner_id, backend_handle, reply.result.conn_id) orelse {
            closeBackendHandle(app, backend_handle);
            return localError(app, state, op, 0, -2, "handle-full");
        };
        reply.result.handle = front;
        reply.result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
        state.last_handle = front;
        state.last_backend_handle = backend_handle;
    }
    noteResult(state, &reply.result);
    return reply;
}

fn takeParkedAccept(app: *const App, state: *ServiceState, owner_id: u32, op: u16, port: u16, data_out: []u8) ?TcpReply {
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        const entry = state.handles[i];
        if (!entry.used or entry.parked_port != port) continue;
        if (!ownerMatches(entry.owner_id, owner_id)) continue;
        // Liveness pruefen: Client kann waehrend der Parkzeit aufgegeben haben.
        var poll = pollBackendHandle(app, entry.backend_handle, data_out) orelse {
            closeBackendHandle(app, entry.backend_handle);
            releaseFrontHandleAt(state, i);
            state.cleanup_handles +%= 1;
            continue;
        };
        if (poll.result.result != 0 or tcpLifecycleTerminal(poll.result.lifecycle_cause)) {
            closeBackendHandle(app, entry.backend_handle);
            releaseFrontHandleAt(state, i);
            state.cleanup_handles +%= 1;
            continue;
        }
        state.handles[i].parked_port = 0;
        state.unparked_accepts +%= 1;
        rewriteForFrontHandle(&poll.result, entry.handle, entry.conn_id);
        poll.result.action = actionForOp(op);
        poll.result.port = port;
        poll.result.flags |= r4os.abi.net_service_tcp_flag_ok;
        state.last_handle = entry.handle;
        state.last_backend_handle = entry.backend_handle;
        noteResult(state, &poll.result);
        return poll;
    }
    return null;
}

fn backendStatus(app: *const App, out: *r4os.abi.NetServiceTcpStatus) bool {
    const got = app.net.netServiceRequest(r4os.abi.ipc_channel_net_tcp, r4os.abi.net_service_op_tcp_status_result, 0x53564354, "", backend_response_buffer[0..]);
    if (got <= 0) return false;
    var status: i32 = 0;
    const payload = app.net.netServicePayload(backend_response_buffer[0..@as(usize, @intCast(got))], &status) orelse return false;
    if (status != r4os.abi.net_service_result_ok or payload.len < @sizeOf(r4os.abi.NetServiceTcpStatus)) return false;
    copyStruct(out, payload[0..@sizeOf(r4os.abi.NetServiceTcpStatus)]);
    return out.magic == r4os.abi.net_service_tcp_status_magic and out.version == r4os.abi.net_service_tcp_status_version;
}

fn backendResult(app: *const App, op: u16, request: []const u8, data_out: []u8) ?TcpReply {
    const got = app.net.netServiceRequest(r4os.abi.ipc_channel_net_tcp, op, 0x52564354, request, backend_response_buffer[0..]);
    if (got <= 0) return null;
    var status: i32 = 0;
    const payload = app.net.netServicePayload(backend_response_buffer[0..@as(usize, @intCast(got))], &status) orelse return null;
    if (status != r4os.abi.net_service_result_ok or payload.len < @sizeOf(r4os.abi.NetServiceTcpResult)) return null;
    var result = r4os.abi.NetServiceTcpResult{};
    copyStruct(&result, payload[0..@sizeOf(r4os.abi.NetServiceTcpResult)]);
    if (result.magic != r4os.abi.net_service_tcp_result_magic or result.version != r4os.abi.net_service_tcp_result_version) return null;
    var data_len: usize = 0;
    const available = payload[@sizeOf(r4os.abi.NetServiceTcpResult)..];
    if ((result.flags & r4os.abi.net_service_tcp_flag_data) != 0 and result.bytes != 0) {
        data_len = @intCast(result.bytes);
        if (data_len > available.len or data_len > data_out.len) return null;
        copyBytes(data_out[0..data_len], available[0..data_len]);
    }
    return .{ .result = result, .data = data_out[0..data_len] };
}

fn backendResultWithDeadline(app: *const App, op: u16, request: []const u8, deadline_tick: ?u64, data_out: []u8) ?TcpReply {
    const deadline = deadline_tick orelse return backendResult(app, op, request, data_out);
    const payload = r4os.service_deadline.append(deadline_payload[0..], request, deadline) orelse return null;
    return backendResult(app, op, payload, data_out);
}

fn pollBackendHandle(app: *const App, backend_handle: u32, data_out: []u8) ?TcpReply {
    var poll_request: [4]u8 = .{0} ** 4;
    writeLe32(poll_request[0..], 0, backend_handle);
    return backendResult(app, r4os.abi.net_service_op_tcp_poll_result, poll_request[0..], data_out);
}

fn writeBackendPayload(backend_handle: u32, data: []const u8) ?[]const u8 {
    if (data.len > r4os.abi.net_service_tcp_write_max or data.len + 4 > translated_payload.len) return null;
    writeLe32(translated_payload[0..], 0, backend_handle);
    if (data.len != 0) copyBytes(translated_payload[4 .. 4 + data.len], data);
    return translated_payload[0 .. 4 + data.len];
}

fn rewriteForFrontHandle(result: *r4os.abi.NetServiceTcpResult, front_handle: u32, conn_id: u32) void {
    result.handle = front_handle;
    result.conn_id = if (result.conn_id != 0) result.conn_id else conn_id;
    if (front_handle != 0) result.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
}

fn plannedWriteLength(requested_len: usize, tx_window: u32) usize {
    if (requested_len == 0 or tx_window == 0) return 0;
    return @min(@min(requested_len, r4os.abi.net_service_tcp_write_max), @as(usize, @intCast(tx_window)));
}

fn tcpPerformanceSnapshot(app: *const App) ?r4os.abi.TcpPerformanceInfo {
    var info: r4os.abi.TcpPerformanceInfo = .{};
    if (app.net.tcpPerformance(&info) <= 0) return null;
    return info;
}

fn refreshTcpPerformance(app: *const App, state: *ServiceState) void {
    const after = tcpPerformanceSnapshot(app) orelse return;
    state.tx_performance_samples +%= 1;
    state.tx_wire_segments = after.write_segments;
    state.tx_wire_bytes = after.write_completed_bytes;
    state.last_outstanding_segments = after.outstanding_segments;
    state.last_outstanding_bytes = after.outstanding_bytes;
    state.last_pure_ack_tx = after.pure_ack_tx;
    state.last_adapter_poll_rounds = after.adapter_poll_rounds;
    state.last_service_poll_requests = after.service_poll_requests;
    state.last_service_poll_skips = after.service_poll_skips;
}

fn isWriteWouldBlockResult(result: *const r4os.abi.NetServiceTcpResult) bool {
    if (result.result != 0) return false;
    if (result.bytes != 0) return false;
    if (tcpLifecycleTerminal(result.lifecycle_cause)) return false;
    return serviceStatusCode(result.flags) == r4os.abi.net_service_status_would_block or
        result.lifecycle_cause == r4os.abi.net_service_socket_lifecycle_would_block;
}

fn writeWouldBlockReply(app: *const App, state: *ServiceState, front_handle: u32, conn_id: u32, requested_len: u32, source: *const r4os.abi.NetServiceTcpResult, reason: []const u8) TcpReply {
    var out = source.*;
    out.action = r4os.abi.net_service_tcp_action_write;
    out.result = 0;
    out.bytes = 0;
    out.requested_bytes = requested_len;
    out.handle = front_handle;
    out.conn_id = if (out.conn_id != 0) out.conn_id else conn_id;
    out.flags &= ~(r4os.abi.net_service_tcp_flag_ok | r4os.abi.net_service_tcp_flag_data);
    out.flags |= r4os.abi.net_service_tcp_flag_handle_valid | r4os.abi.net_service_tcp_flag_lifecycle_valid;
    out.flags = withServiceStatus(out.flags, r4os.abi.net_service_status_would_block);
    out.service_status = r4os.abi.net_service_status_would_block;
    out.lifecycle_cause = r4os.abi.net_service_socket_lifecycle_would_block;
    out.message_payload_max = r4os.abi.net_service_tcp_message_payload_max;
    out.write_max = r4os.abi.net_service_tcp_write_max;
    out.read_max = r4os.abi.net_service_tcp_read_max;
    if (out.local_ip[0] == 0 and out.local_ip[1] == 0 and out.local_ip[2] == 0 and out.local_ip[3] == 0) out.local_ip = localIp(app);
    copyFixed(out.last_error[0..], reason);
    state.tx_window_zero +%= 1;
    noteTxWriteResult(state, &out, requested_len);
    noteResult(state, &out);
    return .{ .result = out };
}

fn localWriteResult(app: *const App, front_handle: u32, conn_id: u32, requested_len: u32, bytes: u32, status: u32, lifecycle: u32, reason: []const u8) TcpReply {
    var out = r4os.abi.NetServiceTcpResult{
        .action = r4os.abi.net_service_tcp_action_write,
        .result = 0,
        .flags = withServiceStatus(r4os.abi.net_service_tcp_flag_handle_valid, status),
        .handle = front_handle,
        .conn_id = conn_id,
        .bytes = bytes,
        .requested_bytes = requested_len,
        .lifecycle_cause = lifecycle,
        .service_status = status,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .write_max = r4os.abi.net_service_tcp_write_max,
        .read_max = r4os.abi.net_service_tcp_read_max,
        .local_ip = localIp(app),
    };
    if (status == r4os.abi.net_service_status_ok) out.flags |= r4os.abi.net_service_tcp_flag_ok;
    if (lifecycle != r4os.abi.net_service_socket_lifecycle_unknown) out.flags |= r4os.abi.net_service_tcp_flag_lifecycle_valid;
    copyFixed(out.last_error[0..], reason);
    return .{ .result = out };
}

fn backendError(app: *const App, state: *ServiceState, op: u16, label: []const u8) TcpReply {
    state.backend_errors +%= 1;
    return localError(app, state, op, 0, r4os.abi.net_service_result_bad_service, label);
}

fn localError(app: *const App, state: *ServiceState, op: u16, handle: u32, result_code: i32, reason: []const u8) TcpReply {
    state.bad_requests +%= 1;
    var out = r4os.abi.NetServiceTcpResult{
        .action = actionForOp(op),
        .result = result_code,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_failed),
        .handle = handle,
        .service_status = r4os.abi.net_service_status_failed,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .write_max = r4os.abi.net_service_tcp_write_max,
        .read_max = r4os.abi.net_service_tcp_read_max,
        .local_ip = localIp(app),
    };
    if (handle != 0) out.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    setTcpLifecycle(&out, lifecycleFromReason(reason));
    recordTcpLifecycle(state, out.lifecycle_cause);
    copyFixed(out.last_error[0..], reason);
    noteResult(state, &out);
    return .{ .result = out };
}

fn ownerMismatch(state: *ServiceState, op: u16, handle: u32, port: u16) TcpReply {
    state.owner_mismatches +%= 1;
    var out = r4os.abi.NetServiceTcpResult{
        .action = actionForOp(op),
        .result = owner_mismatch_result,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_failed),
        .handle = handle,
        .port = port,
        .local_port = port,
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_owner_mismatch,
        .service_status = r4os.abi.net_service_status_failed,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .write_max = r4os.abi.net_service_tcp_write_max,
        .read_max = r4os.abi.net_service_tcp_read_max,
    };
    if (handle != 0) out.flags |= r4os.abi.net_service_tcp_flag_handle_valid;
    if (port != 0) out.flags |= r4os.abi.net_service_tcp_flag_listener;
    out.flags |= r4os.abi.net_service_tcp_flag_lifecycle_valid;
    recordTcpLifecycle(state, out.lifecycle_cause);
    copyFixed(out.last_error[0..], "owner-mismatch");
    noteResult(state, &out);
    return .{ .result = out };
}

fn localOkListener(app: *const App, state: *ServiceState, op: u16, port: u16, reason: []const u8) TcpReply {
    _ = state;
    var out = r4os.abi.NetServiceTcpResult{
        .action = actionForOp(op),
        .result = 0,
        .flags = withServiceStatus(r4os.abi.net_service_tcp_flag_ok | r4os.abi.net_service_tcp_flag_listener, r4os.abi.net_service_status_ok),
        .port = port,
        .local_port = port,
        .local_ip = localIp(app),
        .active_listeners = 1,
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_listener,
        .service_status = r4os.abi.net_service_status_ok,
        .message_payload_max = r4os.abi.net_service_tcp_message_payload_max,
        .write_max = r4os.abi.net_service_tcp_write_max,
        .read_max = r4os.abi.net_service_tcp_read_max,
    };
    out.flags |= r4os.abi.net_service_tcp_flag_lifecycle_valid;
    copyFixed(out.last_error[0..], reason);
    return .{ .result = out };
}

fn makeStatus(app: *const App, state: *ServiceState, owner_id: u32) r4os.abi.NetServiceTcpStatus {
    refreshEndpointPressure(app, state);
    refreshTcpPerformance(app, state);
    var out = r4os.abi.NetServiceTcpStatus{};
    if (!backendStatus(app, &out)) {
        out.max_connections = 0;
        out.tcp_buffer_size = 0;
        copyFixed(out.last_error[0..], "backend");
    }
    const backend_handles = out.handle_count;
    const backend_listeners = out.active_listeners;
    out.request_owner_id = @intCast(@min(owner_id, 0xFFFF));
    out.owned_handles = frontOwnedHandleCount(state, owner_id);
    out.legacy_handles = @intCast(@min(backend_handles, 0xFFFF));
    out.handle_count = frontHandleCount(state);
    out.max_handles = front_handles_max;
    const local_listeners = listenerCount(state);
    out.active_listeners = if (backend_listeners > local_listeners) backend_listeners else local_listeners;
    out.message_payload_max = r4os.abi.net_service_tcp_message_payload_max;
    out.write_max = r4os.abi.net_service_tcp_write_max;
    out.read_max = r4os.abi.net_service_tcp_read_max;
    out.self_tests +%= state.self_tests;
    out.owner_mismatches +%= state.owner_mismatches;
    out.stale_handles_reaped +%= state.cleanup_handles;
    out.lifecycle_closed +%= state.lifecycle_closed;
    out.lifecycle_reset +%= state.lifecycle_reset;
    out.lifecycle_timeout +%= state.lifecycle_timeout;
    out.lifecycle_peer_gone +%= state.lifecycle_peer_gone;
    out.lifecycle_local_abort +%= state.lifecycle_local_abort;
    out.lifecycle_local_close +%= state.lifecycle_local_close;
    out.lifecycle_pending_close +%= state.lifecycle_pending_close;
    out.lifecycle_would_block +%= state.lifecycle_would_block;
    out.lifecycle_bad_handle +%= state.lifecycle_bad_handle;
    out.lifecycle_owner_mismatch +%= state.lifecycle_owner_mismatch;
    if (state.last_lifecycle_cause != r4os.abi.net_service_socket_lifecycle_unknown) {
        out.last_lifecycle_cause = state.last_lifecycle_cause;
        out.flags |= r4os.abi.net_service_tcp_status_flag_lifecycle_valid;
    }
    if (out.active_listeners != 0) out.flags |= r4os.abi.net_service_tcp_status_flag_listener_active;
    if (spanZ(state.last_error[0..]).len != 0) copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn refreshEndpointPressure(app: *const App, state: *ServiceState) void {
    if (!app.sys.hasFn("service_start")) return;
    var detail: r4os.abi.ServiceDetail = .{};
    const rc = app.sys.serviceDetailByName(service_name, &detail);
    if (rc != r4os.abi.service_api_result_ok) return;
    state.endpoint_queue_depth = detail.info.queue_depth;
    state.endpoint_queue_used = detail.info.queue_used;
    state.endpoint_queue_high = detail.info.queue_high_water;
    state.endpoint_busy = detail.info.busy_rejections;
    state.endpoint_timeouts = detail.info.timeouts;
    state.endpoint_cancellations = detail.info.cancellations;
}

fn writeStatusText(w: *Writer, state: *const ServiceState, status: *const r4os.abi.NetServiceTcpStatus) void {
    w.text("active=");
    w.num(status.active_connections);
    w.text("/");
    w.num(status.max_connections);
    w.text(" handles=");
    w.num(status.handle_count);
    w.text("/");
    w.num(status.max_handles);
    w.text(" owned=");
    w.num(status.owned_handles);
    w.text(" listen=");
    w.num(status.active_listeners);
    w.text(" requests=");
    w.num(state.requests);
    w.text(" req_ticks=");
    w.num(state.last_request_ticks);
    w.text("/");
    w.num(state.max_request_ticks);
    w.text(" long_req=");
    w.num(state.long_requests);
    w.text(" ops=status/");
    w.num(state.status_requests);
    w.text(",action/");
    w.num(state.action_requests);
    w.text(",connect/");
    w.num(state.connect_requests);
    w.text(",write/");
    w.num(state.write_requests);
    w.text(",read/");
    w.num(state.read_requests);
    w.text(",close/");
    w.num(state.close_requests);
    w.text(",listen/");
    w.num(state.listen_requests);
    w.text(",accept/");
    w.num(state.accept_requests);
    w.text(",poll/");
    w.num(state.poll_requests);
    w.text(",abort/");
    w.num(state.abort_requests);
    w.text(" session_handles=");
    w.num(status.handle_count);
    w.text(" session_cap=");
    w.num(status.max_handles);
    w.text(" reply_miss=");
    w.num(state.reply_misses);
    w.text(" undelivered=");
    w.num(state.undelivered_handles);
    w.text(" parked=");
    w.num(state.parked_accepts);
    w.text("/");
    w.num(state.unparked_accepts);
    w.text(" pending=active/");
    w.num(pendingCount(state));
    w.text(",cap/");
    w.num(state.pending.len);
    w.text(",started/");
    w.num(state.deferred_started);
    w.text(",read/");
    w.num(state.deferred_read_started);
    w.text(",write/");
    w.num(state.deferred_write_started);
    w.text(",done/");
    w.num(state.deferred_completed);
    w.text(",timeout/");
    w.num(state.deferred_timeouts);
    w.text(",late/");
    w.num(state.deferred_late_replies);
    w.text(",cancel/");
    w.num(state.deferred_cancelled);
    w.text(",busy/");
    w.num(state.deferred_busy);
    w.text(",last/");
    w.text(pendingKindName(state.last_deferred_kind));
    w.text(",handle/");
    w.num(state.last_deferred_handle);
    w.text(",ticks/");
    w.num(state.last_deferred_ticks);
    w.text(",max/");
    w.num(state.max_deferred_ticks);
    w.text(",reason/");
    w.text(spanZ(state.last_deferred_reason[0..]));
    w.text(" fair=owner_limit/");
    w.num(pending_per_owner_max);
    w.text(",handle_limit/");
    w.num(pending_per_handle_max);
    w.text(",active_limit/");
    w.num(pendingActiveLimit());
    w.text(",owner_busy/");
    w.num(state.deferred_owner_busy);
    w.text(",handle_busy/");
    w.num(state.deferred_handle_busy);
    w.text(",reserved_busy/");
    w.num(state.deferred_reserved_busy);
    w.text(",blocked/");
    w.num(state.deferred_blocked);
    w.text(",last_owner/");
    w.num(state.last_blocked_owner);
    w.text(",last_handle/");
    w.num(state.last_blocked_handle);
    w.text(",last_kind/");
    w.text(pendingKindName(state.last_blocked_kind));
    w.text(",last_reason/");
    w.text(spanZ(state.last_blocked_reason[0..]));
    w.text(" endpoint=used/");
    w.num(state.endpoint_queue_used);
    w.text(",depth/");
    w.num(state.endpoint_queue_depth);
    w.text(",high/");
    w.num(state.endpoint_queue_high);
    w.text(",busy/");
    w.num(state.endpoint_busy);
    w.text(",timeout/");
    w.num(state.endpoint_timeouts);
    w.text(",cancel/");
    w.num(state.endpoint_cancellations);
    w.text(",completion/");
    w.num(state.last_completion_ticks);
    w.text("/");
    w.num(state.max_completion_ticks);
    w.text(" txwait=waits/");
    w.num(state.tx_window_waits);
    w.text(",zero/");
    w.num(state.tx_window_zero);
    w.text(",partial/");
    w.num(state.tx_partial_writes);
    w.text(",done/");
    w.num(state.tx_write_completions);
    w.text(",timeout/");
    w.num(state.tx_write_timeouts);
    w.text(",terminal/");
    w.num(state.tx_write_terminal);
    w.text(",retx/");
    w.num(state.tx_write_retransmits);
    w.text(",wire_seg/");
    w.num(state.tx_wire_segments);
    w.text(",wire_bytes/");
    w.num(state.tx_wire_bytes);
    w.text(",out_seg/");
    w.num(state.last_outstanding_segments);
    w.text(",out_bytes/");
    w.num(state.last_outstanding_bytes);
    w.text(",pure_ack/");
    w.num(state.last_pure_ack_tx);
    w.text(",poll_rounds/");
    w.num(state.last_adapter_poll_rounds);
    w.text(",poll_skip/");
    w.num(state.last_service_poll_skips);
    w.text("/");
    w.num(state.last_service_poll_requests);
    w.text(",perf_samples/");
    w.num(state.tx_performance_samples);
    w.text(",handle/");
    w.num(state.last_write_handle);
    w.text(",req/");
    w.num(state.last_write_requested);
    w.text(",written/");
    w.num(state.last_write_written);
    w.text(",win/");
    w.num(state.last_write_window);
    w.text(",status/");
    w.text(serviceStatusCodeName(state.last_write_status));
    w.text(",life/");
    w.text(socketLifecycleName(state.last_write_lifecycle));
    w.text(" close_abort=");
    w.num(state.close_abort_fallbacks);
    w.text(" errors=backend/");
    w.num(state.backend_errors);
    w.text(",bad_req/");
    w.num(state.bad_requests);
    w.text(",bad_op/");
    w.num(state.bad_ops);
    w.text(",last_handle/");
    w.num(state.last_handle);
    w.text(",last_backend/");
    w.num(state.last_backend_handle);
    w.text(" tx=");
    w.num(status.data_tx);
    w.text(" rx=");
    w.num(status.data_rx);
    w.text(" retrans=");
    w.num(status.retransmits);
    w.text(" cleanup=");
    w.num(state.cleanup_runs);
    w.text("/");
    w.num(state.cleanup_handles);
    w.text("/");
    w.num(state.cleanup_listeners);
    w.text(" owner_mismatch=");
    w.num(state.owner_mismatches);
    w.text(" readiness=handle/");
    w.num(state.last_readiness_handle);
    w.text(",readable/");
    w.text(boolText(state.last_pending_rx != 0));
    w.text(",writable/");
    w.text(boolText(state.last_tx_window != 0));
    w.text(",rx/");
    w.num(state.last_pending_rx);
    w.text(",rxwin/");
    w.num(state.last_rx_window);
    w.text(",txwin/");
    w.num(state.last_tx_window);
    w.text(",status/");
    w.text(serviceStatusCodeName(state.last_readiness_status));
    w.text(",life/");
    w.text(socketLifecycleName(state.last_readiness_lifecycle));
    w.text(" readiness_counts=samples/");
    w.num(state.readiness_samples);
    w.text(",readable/");
    w.num(state.readiness_readable);
    w.text(",writable/");
    w.num(state.readiness_writable);
    w.text(",would_block/");
    w.num(state.readiness_would_block);
    w.text(",terminal/");
    w.num(state.readiness_terminal);
    w.text(" lifecycle=");
    w.text(socketLifecycleName(status.last_lifecycle_cause));
    w.text(" bad_handle=");
    w.num(status.lifecycle_bad_handle);
    w.text(" last=");
    w.text(spanZ(status.last_error[0..]));
}

fn writeOperationText(w: *Writer, result: *const r4os.abi.NetServiceTcpResult, data: []const u8) void {
    w.text("op=");
    w.text(actionName(result.action));
    w.text(" result=");
    w.text(if (result.result == 0 and (result.flags & r4os.abi.net_service_tcp_flag_ok) != 0) "ok" else "failed");
    w.text(" code=");
    w.signed(result.result);
    w.text(" status=");
    w.text(serviceStatusName(result.flags));
    if ((result.flags & r4os.abi.net_service_tcp_flag_handle_valid) != 0) {
        w.text(" handle=");
        w.num(result.handle);
    }
    if ((result.flags & r4os.abi.net_service_tcp_flag_listener) != 0 or result.port != 0) {
        w.text(" port=");
        w.num(result.port);
    }
    if (result.bytes != 0) {
        w.text(" bytes=");
        w.num(result.bytes);
    }
    if ((result.flags & r4os.abi.net_service_tcp_flag_lifecycle_valid) != 0 or result.lifecycle_cause != r4os.abi.net_service_socket_lifecycle_unknown) {
        w.text(" lifecycle=");
        w.text(socketLifecycleName(result.lifecycle_cause));
    }
    if (data.len != 0) {
        w.text(" data=");
        w.text(data);
    }
    w.text(" last=");
    w.text(spanZ(result.last_error[0..]));
}

fn allocateFrontHandle(state: *ServiceState, owner_id: u32, backend_handle: u32, conn_id: u32) ?u32 {
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (backend_handle != 0 and state.handles[i].used and state.handles[i].backend_handle == backend_handle and ownerMatches(state.handles[i].owner_id, owner_id)) return state.handles[i].handle;
    }
    i = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used) continue;
        // The kernel TCP handle is monotonic until exhaustion, including
        // across TCPSVC restarts. A fresh provider must not recycle a
        // service handle that an older remote worker can still present.
        // Legacy callers also return handles through a positive i32.
        const handle = if (backend_handle != 0) blk: {
            if (backend_handle > std.math.maxInt(i32)) return null;
            for (state.handles) |entry| {
                if (entry.used and entry.handle == backend_handle) return null;
            }
            break :blk backend_handle;
        } else nextTypedOnlyHandle(state) orelse return null;
        const generation = nextHandleGeneration(state);
        state.handles[i] = .{
            .used = true,
            .handle = handle,
            .backend_handle = backend_handle,
            .owner_id = owner_id,
            .conn_id = conn_id,
            .generation = generation,
        };
        return handle;
    }
    return null;
}

fn nextTypedOnlyHandle(state: *ServiceState) ?u32 {
    const handle = state.next_typed_only_handle;
    if (handle <= std.math.maxInt(i32)) return null;
    state.next_typed_only_handle -= 1;
    return handle;
}

fn nextHandleGeneration(state: *ServiceState) u32 {
    const generation = state.next_generation;
    state.next_generation +%= 1;
    if (state.next_generation == 0) state.next_generation = 1;
    return generation;
}

fn resolveFrontHandle(state: *ServiceState, handle: u32, owner_id: u32) FrontLookup {
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        const entry = state.handles[i];
        if (!entry.used or entry.handle != handle) continue;
        if (!ownerMatches(entry.owner_id, owner_id)) {
            state.owner_mismatches +%= 1;
            return .{ .result = owner_mismatch_result, .last_error = "owner-mismatch" };
        }
        return .{ .ok = true, .index = i, .entry = entry, .result = 0, .last_error = "" };
    }
    return .{ .result = r4os.abi.tcp_result_no_connection, .last_error = "no-connection" };
}

fn resolveFrontHandleForRelease(state: *ServiceState, handle: u32) FrontLookup {
    if (handle > std.math.maxInt(i32)) return .{ .result = r4os.abi.tcp_result_no_connection, .last_error = "no-connection" };
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        const entry = state.handles[i];
        if (!entry.used or entry.handle != handle or entry.typed_generation != 0) continue;
        return .{ .ok = true, .index = i, .entry = entry, .result = 0, .last_error = "" };
    }
    return .{ .result = r4os.abi.tcp_result_no_connection, .last_error = "no-connection" };
}

fn resolveLegacyFrontHandle(state: *ServiceState, handle: u32, owner_id: u32) FrontLookup {
    if (handle > std.math.maxInt(i32)) return .{ .result = r4os.abi.tcp_result_no_connection, .last_error = "no-connection" };
    const lookup = resolveFrontHandle(state, handle, owner_id);
    if (lookup.ok and lookup.entry.typed_generation != 0)
        return .{ .result = r4os.abi.tcp_result_no_connection, .last_error = "no-connection" };
    return lookup;
}

fn releaseFrontHandleAt(state: *ServiceState, index: usize) void {
    if (index >= state.handles.len) return;
    if (state.handles[index].typed_generation != 0) state.typed_count -= 1;
    state.handles[index] = .{};
}

fn translateHandlePayload(payload: []const u8, backend_handle: u32) ?[]const u8 {
    if (payload.len > translated_payload.len or payload.len < 4) return null;
    copyBytes(translated_payload[0..payload.len], payload);
    writeLe32(translated_payload[0..], 0, backend_handle);
    return translated_payload[0..payload.len];
}

fn rememberListener(state: *ServiceState, owner_id: u32, port: u16) bool {
    if (listenerForPort(state, port)) |idx| {
        state.listeners[idx].owner_id = owner_id;
        return true;
    }
    var i: usize = 0;
    while (i < state.listeners.len) : (i += 1) {
        if (state.listeners[i].used) continue;
        state.listeners[i] = .{ .used = true, .port = port, .owner_id = owner_id };
        return true;
    }
    return false;
}

fn listenerForPort(state: *const ServiceState, port: u16) ?usize {
    var i: usize = 0;
    while (i < state.listeners.len) : (i += 1) {
        if (state.listeners[i].used and state.listeners[i].port == port) return i;
    }
    return null;
}

fn releaseListener(state: *ServiceState, port: u16) void {
    if (listenerForPort(state, port)) |idx| state.listeners[idx] = .{};
}

fn cleanupService(app: *const App, endpoint_handle: u32, state: *ServiceState, reason: []const u8) void {
    state.cleanup_runs +%= 1;
    cancelAllPending(app, endpoint_handle, state, reason);
    var request4: [4]u8 = .{0} ** 4;
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (!state.handles[i].used) continue;
        if (state.handles[i].v6_provider != 0 or state.handles[i].typed_listener) {
            if (retireNetworkSocket(app, state, i)) releaseFrontHandleAt(state, i);
            continue;
        }
        writeLe32(request4[0..], 0, state.handles[i].backend_handle);
        _ = backendResult(app, r4os.abi.net_service_op_tcp_abort_result, request4[0..], backend_result_data[0..]);
        state.handles[i] = .{};
        state.cleanup_handles +%= 1;
    }

    var request2: [2]u8 = .{0} ** 2;
    i = 0;
    while (i < state.listeners.len) : (i += 1) {
        if (!state.listeners[i].used) continue;
        writeLe16(request2[0..], 0, state.listeners[i].port);
        _ = backendResult(app, r4os.abi.net_service_op_tcp_close_listen_result, request2[0..], backend_result_data[0..]);
        state.listeners[i] = .{};
        state.cleanup_listeners +%= 1;
    }
    setLastError(state, reason);
}

fn closeBackendHandle(app: *const App, backend_handle: u32) void {
    var request: [4]u8 = .{0} ** 4;
    writeLe32(request[0..], 0, backend_handle);
    _ = backendResult(app, r4os.abi.net_service_op_tcp_abort_result, request[0..], backend_result_data[0..]);
}

fn cancelAllPending(app: *const App, endpoint_handle: u32, state: *ServiceState, reason: []const u8) void {
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (!state.pending[i].used) continue;
        if (state.pending[i].typed) {
            _ = failNetworkConnect(app, endpoint_handle, state, i, r4os.abi.network_error_backend);
            continue;
        }
        _ = completePendingLocal(app, endpoint_handle, state, i, r4os.abi.tcp_result_no_connection, r4os.abi.net_service_status_cancelled, r4os.abi.net_service_socket_lifecycle_local_abort, 0, reason, .cancelled);
    }
}

fn cancelPendingForHandle(app: *const App, endpoint_handle: u32, state: *ServiceState, owner_id: u32, front_handle: u32, reason: []const u8) i32 {
    var i: usize = 0;
    while (i < state.pending.len) : (i += 1) {
        if (!state.pending[i].used) continue;
        if (state.pending[i].front_handle != front_handle or !ownerMatches(state.pending[i].owner_id, owner_id)) continue;
        const rc = completePendingLocal(app, endpoint_handle, state, i, r4os.abi.tcp_result_no_connection, r4os.abi.net_service_status_cancelled, r4os.abi.net_service_socket_lifecycle_local_abort, 0, reason, .cancelled);
        if (rc < 0) return rc;
    }
    return 0;
}

fn noteResult(state: *ServiceState, result: *const r4os.abi.NetServiceTcpResult) void {
    state.last_result = result.result;
    if (result.handle != 0) state.last_handle = result.handle;
    if (result.port != 0) state.last_port = result.port;
    const last = spanZ(result.last_error[0..]);
    if (last.len != 0) {
        copyFixed(state.last_error[0..], last);
    } else {
        copyFixed(state.last_error[0..], if (result.result == 0) serviceStatusName(result.flags) else "failed");
    }
    rememberTcpLifecycle(state, result.lifecycle_cause);
    noteReadiness(state, result);
}

fn noteTxWriteResult(state: *ServiceState, result: *const r4os.abi.NetServiceTcpResult, requested_bytes: u32) void {
    state.last_write_handle = result.handle;
    state.last_write_requested = requested_bytes;
    state.last_write_written = result.bytes;
    state.last_write_window = result.tx_window;
    state.last_write_retransmits = result.retransmits;
    state.last_write_status = serviceStatusCode(result.flags);
    state.last_write_lifecycle = result.lifecycle_cause;
    if (result.result == 0 and result.bytes != 0) {
        state.tx_write_completions +%= 1;
        if (requested_bytes != 0 and result.bytes < requested_bytes) state.tx_partial_writes +%= 1;
    }
    if (tcpLifecycleTerminal(result.lifecycle_cause)) state.tx_write_terminal +%= 1;
    if (result.retransmits != 0) state.tx_write_retransmits +%= 1;
}

fn noteReadiness(state: *ServiceState, result: *const r4os.abi.NetServiceTcpResult) void {
    const status = serviceStatusCode(result.flags);
    const lifecycle = result.lifecycle_cause;
    const has_readiness =
        result.action == r4os.abi.net_service_tcp_action_poll or
        result.pending_rx != 0 or
        result.rx_window != 0 or
        result.tx_window != 0 or
        status == r4os.abi.net_service_status_would_block or
        lifecycle != r4os.abi.net_service_socket_lifecycle_unknown;
    if (!has_readiness) return;

    state.readiness_samples +%= 1;
    state.last_readiness_handle = result.handle;
    state.last_pending_rx = result.pending_rx;
    state.last_rx_window = result.rx_window;
    state.last_tx_window = result.tx_window;
    state.last_readiness_status = status;
    state.last_readiness_lifecycle = lifecycle;
    if (result.pending_rx != 0) state.readiness_readable +%= 1;
    if (result.tx_window != 0) state.readiness_writable +%= 1;
    if (status == r4os.abi.net_service_status_would_block or lifecycle == r4os.abi.net_service_socket_lifecycle_would_block) state.readiness_would_block +%= 1;
    if (tcpLifecycleTerminal(lifecycle)) state.readiness_terminal +%= 1;
}

fn frontHandleCount(state: *const ServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used) count += 1;
    }
    return count;
}

fn frontOwnedHandleCount(state: *const ServiceState, owner_id: u32) u16 {
    var count: u16 = 0;
    var i: usize = 0;
    while (i < state.handles.len) : (i += 1) {
        if (state.handles[i].used and ownerMatches(state.handles[i].owner_id, owner_id)) count += 1;
    }
    return count;
}

fn listenerCount(state: *const ServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.listeners.len) : (i += 1) {
        if (state.listeners[i].used) count += 1;
    }
    return count;
}

fn ownerMatches(entry_owner: u32, request_owner: u32) bool {
    return entry_owner == 0 or request_owner == 0 or entry_owner == request_owner;
}

fn localIp(app: *const App) [4]u8 {
    var config = r4os.abi.NetConfigSnapshot{};
    if (app.net.netConfigGet(&config) == r4os.abi.net_config_ok) return config.local_ip;
    return .{0} ** 4;
}

fn resultOpForTextOp(op: u16) u16 {
    return switch (op) {
        r4os.abi.net_service_op_tcp_connect => r4os.abi.net_service_op_tcp_connect_result,
        r4os.abi.net_service_op_tcp_write => r4os.abi.net_service_op_tcp_write_result,
        r4os.abi.net_service_op_tcp_read => r4os.abi.net_service_op_tcp_read_result,
        r4os.abi.net_service_op_tcp_close => r4os.abi.net_service_op_tcp_close_result,
        r4os.abi.net_service_op_tcp_listen => r4os.abi.net_service_op_tcp_listen_result,
        r4os.abi.net_service_op_tcp_accept_read => r4os.abi.net_service_op_tcp_accept_read_result,
        r4os.abi.net_service_op_tcp_close_listen => r4os.abi.net_service_op_tcp_close_listen_result,
        r4os.abi.net_service_op_tcp_poll => r4os.abi.net_service_op_tcp_poll_result,
        r4os.abi.net_service_op_tcp_accept => r4os.abi.net_service_op_tcp_accept_result,
        else => 0,
    };
}

fn releasesFrontHandleOp(op: u16) bool {
    return op == r4os.abi.net_service_op_tcp_close_result or op == r4os.abi.net_service_op_tcp_abort_result;
}

fn actionForOp(op: u16) u16 {
    return switch (op) {
        r4os.abi.net_service_op_tcp_connect_result => r4os.abi.net_service_tcp_action_connect,
        r4os.abi.net_service_op_tcp_write_result => r4os.abi.net_service_tcp_action_write,
        r4os.abi.net_service_op_tcp_read_result => r4os.abi.net_service_tcp_action_read,
        r4os.abi.net_service_op_tcp_close_result => r4os.abi.net_service_tcp_action_close,
        r4os.abi.net_service_op_tcp_listen_result, r4os.abi.net_service_op_tcp_listen_retained_result => r4os.abi.net_service_tcp_action_listen,
        r4os.abi.net_service_op_tcp_accept_read_result => r4os.abi.net_service_tcp_action_accept_read,
        r4os.abi.net_service_op_tcp_close_listen_result => r4os.abi.net_service_tcp_action_close_listen,
        r4os.abi.net_service_op_tcp_poll_result => r4os.abi.net_service_tcp_action_poll,
        r4os.abi.net_service_op_tcp_accept_result => r4os.abi.net_service_tcp_action_accept,
        r4os.abi.net_service_op_tcp_abort_result => r4os.abi.net_service_tcp_action_abort,
        r4os.abi.net_service_op_tcp_accept_poll_result => r4os.abi.net_service_tcp_action_accept_poll,
        else => 0,
    };
}

fn actionName(action: u16) []const u8 {
    return switch (action) {
        r4os.abi.net_service_tcp_action_connect => "connect",
        r4os.abi.net_service_tcp_action_write => "write",
        r4os.abi.net_service_tcp_action_read => "read",
        r4os.abi.net_service_tcp_action_close => "close",
        r4os.abi.net_service_tcp_action_listen => "listen",
        r4os.abi.net_service_tcp_action_accept_read => "accept-read",
        r4os.abi.net_service_tcp_action_close_listen => "close-listen",
        r4os.abi.net_service_tcp_action_poll => "poll",
        r4os.abi.net_service_tcp_action_accept => "accept",
        r4os.abi.net_service_tcp_action_abort => "abort",
        r4os.abi.net_service_tcp_action_accept_poll => "accept-poll",
        else => "unknown",
    };
}

fn pendingKindName(kind: PendingKind) []const u8 {
    return switch (kind) {
        .none => "none",
        .read => "read",
        .write => "write",
        .accept => "accept",
        .connect => "connect",
        .close => "close",
    };
}

fn serviceStatusCode(flags: u32) u32 {
    return (flags & r4os.abi.net_service_status_mask) >> r4os.abi.net_service_status_shift;
}

fn serviceStatusName(flags: u32) []const u8 {
    return serviceStatusCodeName(serviceStatusCode(flags));
}

fn serviceStatusCodeName(code: u32) []const u8 {
    return switch (code) {
        r4os.abi.net_service_status_idle => "idle",
        r4os.abi.net_service_status_pending => "pending",
        r4os.abi.net_service_status_ok => "ok",
        r4os.abi.net_service_status_timeout => "timeout",
        r4os.abi.net_service_status_failed => "failed",
        r4os.abi.net_service_status_cancelled => "cancelled",
        r4os.abi.net_service_status_would_block => "would-block",
        else => "failed",
    };
}

fn withServiceStatus(flags: u32, status: u32) u32 {
    return (flags & ~r4os.abi.net_service_status_mask) | (status << r4os.abi.net_service_status_shift);
}

fn setTcpLifecycle(out: *r4os.abi.NetServiceTcpResult, cause: u32) void {
    if (cause == r4os.abi.net_service_socket_lifecycle_unknown) return;
    out.lifecycle_cause = cause;
    out.flags |= r4os.abi.net_service_tcp_flag_lifecycle_valid;
}

fn lifecycleFromReason(reason: []const u8) u32 {
    if (contains(reason, "owner-mismatch")) return r4os.abi.net_service_socket_lifecycle_owner_mismatch;
    if (contains(reason, "no-connection") or contains(reason, "bad-handle") or contains(reason, "handle-full")) return r4os.abi.net_service_socket_lifecycle_bad_handle;
    if (contains(reason, "would-block") or contains(reason, "poll-empty")) return r4os.abi.net_service_socket_lifecycle_would_block;
    if (contains(reason, "timeout")) return r4os.abi.net_service_socket_lifecycle_timeout;
    if (contains(reason, "abort")) return r4os.abi.net_service_socket_lifecycle_local_abort;
    if (contains(reason, "close")) return r4os.abi.net_service_socket_lifecycle_local_close;
    return r4os.abi.net_service_socket_lifecycle_unknown;
}

fn rememberTcpLifecycle(state: *ServiceState, cause: u32) void {
    if (cause == r4os.abi.net_service_socket_lifecycle_unknown) return;
    state.last_lifecycle_cause = cause;
}

fn recordTcpLifecycle(state: *ServiceState, cause: u32) void {
    rememberTcpLifecycle(state, cause);
    switch (cause) {
        r4os.abi.net_service_socket_lifecycle_closed => state.lifecycle_closed +%= 1,
        r4os.abi.net_service_socket_lifecycle_reset => state.lifecycle_reset +%= 1,
        r4os.abi.net_service_socket_lifecycle_timeout => state.lifecycle_timeout +%= 1,
        r4os.abi.net_service_socket_lifecycle_peer_gone => state.lifecycle_peer_gone +%= 1,
        r4os.abi.net_service_socket_lifecycle_local_abort => state.lifecycle_local_abort +%= 1,
        r4os.abi.net_service_socket_lifecycle_local_close => state.lifecycle_local_close +%= 1,
        r4os.abi.net_service_socket_lifecycle_pending_close => state.lifecycle_pending_close +%= 1,
        r4os.abi.net_service_socket_lifecycle_would_block => state.lifecycle_would_block +%= 1,
        r4os.abi.net_service_socket_lifecycle_bad_handle => state.lifecycle_bad_handle +%= 1,
        r4os.abi.net_service_socket_lifecycle_owner_mismatch => state.lifecycle_owner_mismatch +%= 1,
        else => {},
    }
}

fn socketLifecycleName(cause: u32) []const u8 {
    return switch (cause) {
        r4os.abi.net_service_socket_lifecycle_active => "active",
        r4os.abi.net_service_socket_lifecycle_closed => "closed",
        r4os.abi.net_service_socket_lifecycle_reset => "reset",
        r4os.abi.net_service_socket_lifecycle_timeout => "timeout",
        r4os.abi.net_service_socket_lifecycle_peer_gone => "peer-gone",
        r4os.abi.net_service_socket_lifecycle_local_abort => "local-abort",
        r4os.abi.net_service_socket_lifecycle_local_close => "local-close",
        r4os.abi.net_service_socket_lifecycle_pending_close => "pending-close",
        r4os.abi.net_service_socket_lifecycle_would_block => "would-block",
        r4os.abi.net_service_socket_lifecycle_bad_handle => "bad-handle",
        r4os.abi.net_service_socket_lifecycle_owner_mismatch => "owner-mismatch",
        r4os.abi.net_service_socket_lifecycle_listener => "listener",
        r4os.abi.net_service_socket_lifecycle_dropped => "dropped",
        else => "unknown",
    };
}

fn tcpLifecycleTerminal(cause: u32) bool {
    return switch (cause) {
        r4os.abi.net_service_socket_lifecycle_closed,
        r4os.abi.net_service_socket_lifecycle_reset,
        r4os.abi.net_service_socket_lifecycle_peer_gone,
        r4os.abi.net_service_socket_lifecycle_local_abort,
        r4os.abi.net_service_socket_lifecycle_local_close,
        r4os.abi.net_service_socket_lifecycle_bad_handle,
        r4os.abi.net_service_socket_lifecycle_owner_mismatch,
        r4os.abi.net_service_socket_lifecycle_dropped,
        => true,
        else => false,
    };
}

fn boolText(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn runPing(app: *const App) i32 {
    app.sys.println("TCPSVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) {
        app.sys.println("TCPSVC ping failed");
        return 1;
    }
    defer _ = app.sys.serviceClose(handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpStatus))) or header.status != r4os.abi.service_api_result_ok) {
        app.sys.println("TCPSVC ping failed");
        return 1;
    }
    var status = r4os.abi.NetServiceTcpStatus{};
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_tcp_status_magic or status.version != r4os.abi.net_service_tcp_status_version) {
        app.sys.println("TCPSVC ping failed");
        return 1;
    }
    app.sys.println("TCPSVC ping: OK");
    return 0;
}

fn runStatusClient(app: *const App) i32 {
    app.sys.println("TCPSVC status");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) {
        app.sys.println("TCPSVC status failed");
        return 1;
    }
    defer _ = app.sys.serviceClose(handle);

    var header: r4os.abi.ServiceMessageHeader = .{};
    var text_response: [r4os.abi.service_api_max_payload]u8 = .{0} ** r4os.abi.service_api_max_payload;
    const got = app.sys.serviceCall(handle, r4os.abi.net_service_op_status, "", &header, text_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (got <= 0 or header.status != r4os.abi.service_api_result_ok) {
        app.sys.println("TCPSVC status failed");
        return 1;
    }
    app.sys.write("TCPSVC status: ");
    app.sys.write(text_response[0..@intCast(got)]);
    app.sys.println("");
    return 0;
}

fn runSelfTest(app: *const App) i32 {
    app.sys.println("TCPSVC selftest");
    if (!app.sys.hasFn("service_start")) return fail(app, "manager-api");
    if (!app.sys.hasFn("service_call")) return fail(app, "service-api");
    if (!localContractSelfTest(app)) return fail(app, "local-contract");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "open");

    var header: r4os.abi.ServiceMessageHeader = .{};
    const status_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (status_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "status");
    var status = r4os.abi.NetServiceTcpStatus{};
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_tcp_status_magic or status.version != r4os.abi.net_service_tcp_status_version) return fail(app, "status-magic");
    if (status.max_handles != front_handles_max or status.write_max == 0 or status.read_max == 0) return fail(app, "status-limits");

    var text_response: [r4os.abi.service_api_max_payload]u8 = .{0} ** r4os.abi.service_api_max_payload;
    const text_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_status, "", &header, text_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (text_got <= 0 or header.status != r4os.abi.service_api_result_ok) return fail(app, "text-status");
    if (!contains(text_response[0..@intCast(text_got)], "handles=")) return fail(app, "text-handles");
    if (!contains(text_response[0..@intCast(text_got)], "readiness=")) return fail(app, "text-readiness");
    if (!contains(text_response[0..@intCast(text_got)], "pending=")) return fail(app, "text-pending");

    var small: [8]u8 = .{0} ** 8;
    const bad_op = app.sys.serviceCall(handle, 0xFFFF, "", &header, small[0..], app.sys.ticksFromMilliseconds(100));
    if (bad_op < 0 or header.status != r4os.abi.service_api_result_bad_op) return fail(app, "bad-op");

    const structured_port: u16 = 65042;
    var listen_request: [2]u8 = .{0} ** 2;
    writeLe16(listen_request[0..], 0, structured_port);
    const listen_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_listen_result, listen_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (listen_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "listen");
    var result = r4os.abi.NetServiceTcpResult{};
    copyStruct(&result, selftest_result_response[0..]);
    if (result.result != 0 or result.action != r4os.abi.net_service_tcp_action_listen or (result.flags & r4os.abi.net_service_tcp_flag_listener) == 0) return fail(app, "listen-result");

    const close_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_close_listen_result, listen_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (close_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "close-listen");
    copyStruct(&result, selftest_result_response[0..]);
    if (result.result != 0 or result.action != r4os.abi.net_service_tcp_action_close_listen) return fail(app, "close-listen-result");

    const restart_port: u16 = 65043;
    writeLe16(listen_request[0..], 0, restart_port);
    const restart_listen = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_listen_result, listen_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (restart_listen != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "restart-listen");
    copyStruct(&result, selftest_result_response[0..]);
    if (result.result != 0) return fail(app, "restart-listen-result");

    _ = app.sys.serviceClose(handle);
    var info: r4os.abi.ServiceInfo = .{};
    const restart = app.sys.serviceRestart(service_name, &info);
    if (restart != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running) return fail(app, "restart");
    if (!ensureRunningAndOpen(app, &handle)) return fail(app, "reopen");
    defer _ = app.sys.serviceClose(handle);

    const after_status = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_status_result, "", &header, selftest_status_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (after_status != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpStatus))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "after-status");
    copyStruct(&status, selftest_status_response[0..]);
    if (status.magic != r4os.abi.net_service_tcp_status_magic or
        status.version != r4os.abi.net_service_tcp_status_version or
        status.owned_handles != 0) return fail(app, "restart-cleanup");

    // Other services may already have re-registered their listeners. Probe
    // the port held by this self-test before the restart.
    const stale_listener = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_accept_poll_result, listen_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (stale_listener != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "restart-listener-probe");
    copyStruct(&result, selftest_result_response[0..]);
    if (result.result != r4os.abi.tcp_result_bad_state or result.conn_id != 0 or
        result.flags & r4os.abi.net_service_tcp_flag_handle_valid != 0) return fail(app, "restart-listener-retained");

    var abort_request: [4]u8 = .{0} ** 4;
    writeLe32(abort_request[0..], 0, 0xCAFE1709);
    const abort_got = app.sys.serviceCall(handle, r4os.abi.net_service_op_tcp_abort_result, abort_request[0..], &header, selftest_result_response[0..], app.sys.ticksFromMilliseconds(service_timeout_ms));
    if (abort_got != @as(i32, @intCast(@sizeOf(r4os.abi.NetServiceTcpResult))) or header.status != r4os.abi.service_api_result_ok) return fail(app, "abort");
    copyStruct(&result, selftest_result_response[0..]);
    if (result.result != r4os.abi.tcp_result_no_connection or result.action != r4os.abi.net_service_tcp_action_abort) return fail(app, "abort-result");

    app.sys.println("TCPSVC selftest: OK");
    return 0;
}

fn localContractFail(app: *const App, step: u32) bool {
    app.sys.write("TCPSVC local-contract fail step=");
    app.sys.printU64(@intCast(step));
    app.sys.println("");
    return false;
}

fn localContractSelfTest(app: *const App) bool {
    var state = ServiceState{};
    setLastError(&state, "selftest");
    const front = allocateFrontHandle(&state, 11, 41, 77) orelse return localContractFail(app, 1);
    if (front == 0 or frontHandleCount(&state) != 1 or frontOwnedHandleCount(&state, 11) != 1) return localContractFail(app, 2);
    if (resolveFrontHandle(&state, front, 22).result != owner_mismatch_result) return localContractFail(app, 3);
    const release_lookup = resolveFrontHandleForRelease(&state, front);
    if (!release_lookup.ok or release_lookup.entry.backend_handle != 41) return localContractFail(app, 4);
    const ok_lookup = resolveFrontHandle(&state, front, 11);
    if (!ok_lookup.ok or ok_lookup.entry.backend_handle != 41) return localContractFail(app, 5);
    const front_b = allocateFrontHandle(&state, 11, 42, 78) orelse return localContractFail(app, 6);
    const front_c = allocateFrontHandle(&state, 11, 43, 79) orelse return localContractFail(app, 7);
    const front_other = allocateFrontHandle(&state, 22, 44, 80) orelse return localContractFail(app, 8);
    const front_reserve = allocateFrontHandle(&state, 22, 45, 81) orelse return localContractFail(app, 9);
    var read_request: [6]u8 = .{0} ** 6;
    writeLe32(read_request[0..], 0, front);
    writeLe16(read_request[0..], 4, 16);
    var would_block = r4os.abi.NetServiceTcpResult{
        .action = r4os.abi.net_service_tcp_action_read,
        .result = 0,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_would_block),
        .handle = front,
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_would_block,
    };
    if (!shouldDeferRead(&would_block, read_request[0..])) return localContractFail(app, 10);
    if (!startDeferredRead(app, &state, 1234, 11, read_request[0..], null, &would_block)) return localContractFail(app, 11);
    if (pendingCount(&state) != 1 or !hasPendingForHandle(&state, front, ok_lookup.entry.generation)) return localContractFail(app, 12);
    if (startDeferredRead(app, &state, 1235, 11, read_request[0..], null, &would_block)) return localContractFail(app, 13);
    if (state.deferred_handle_busy == 0 or serviceStatusCode(would_block.flags) != r4os.abi.net_service_status_would_block) return localContractFail(app, 14);
    writeLe32(read_request[0..], 0, front_b);
    if (!startDeferredRead(app, &state, 1236, 11, read_request[0..], null, &would_block)) return localContractFail(app, 15);
    // 0.56.31-Triage: der Test war auf pending_per_owner_max=2 kalibriert;
    // seit der Erhoehung auf 4 wird hier bis zum echten Limit aufgefuellt.
    var fill_seq: u32 = 1240;
    while (pendingCountForOwner(&state, 11) < pending_per_owner_max) {
        const filler = allocateFrontHandle(&state, 11, 50 +% fill_seq, 90 +% fill_seq) orelse return localContractFail(app, 39);
        writeLe32(read_request[0..], 0, filler);
        if (!startDeferredRead(app, &state, fill_seq, 11, read_request[0..], null, &would_block)) return localContractFail(app, 40);
        fill_seq += 1;
    }
    if (pendingCountForOwner(&state, 11) != pending_per_owner_max) return localContractFail(app, 16);
    writeLe32(read_request[0..], 0, front_c);
    if (startDeferredRead(app, &state, 1237, 11, read_request[0..], null, &would_block)) return localContractFail(app, 17);
    if (state.deferred_owner_busy == 0 or !contains(spanZ(would_block.last_error[0..]), "owner")) return localContractFail(app, 18);
    writeLe32(read_request[0..], 0, front_other);
    if (!startDeferredRead(app, &state, 1238, 22, read_request[0..], null, &would_block)) return localContractFail(app, 19);
    // 0.56.31-Triage: das globale Aktiv-Limit ist unabhaengig vom
    // Owner-Limit gewachsen - mit weiteren Owner-22-Handles bis zum
    // pendingActiveLimit auffuellen, damit der Global-Busy-Fall greift.
    var fill22_seq: u32 = 1250;
    while (pendingCount(&state) < pendingActiveLimit() and pendingCountForOwner(&state, 22) < pending_per_owner_max) {
        const filler22 = allocateFrontHandle(&state, 22, 60 +% fill22_seq, 120 +% fill22_seq) orelse return localContractFail(app, 41);
        writeLe32(read_request[0..], 0, filler22);
        if (!startDeferredRead(app, &state, fill22_seq, 22, read_request[0..], null, &would_block)) return localContractFail(app, 42);
        fill22_seq += 1;
    }
    if (pendingCount(&state) != pendingActiveLimit()) return localContractFail(app, 20);
    writeLe32(read_request[0..], 0, front_reserve);
    if (startDeferredRead(app, &state, 1239, 22, read_request[0..], null, &would_block)) return localContractFail(app, 21);
    if (state.deferred_reserved_busy == 0 or state.deferred_blocked < 3) return localContractFail(app, 22);
    if (spanZ(state.pending[0].reason[0..]).len == 0 or state.pending[0].reply_payload.len != pending_reply_payload_max) return localContractFail(app, 23);
    const payload_result = r4os.abi.NetServiceTcpResult{
        .action = r4os.abi.net_service_tcp_action_read,
        .result = 0,
        .flags = withServiceStatus(r4os.abi.net_service_tcp_flag_data, r4os.abi.net_service_status_ok),
        .bytes = 3,
    };
    const payload = structuredReplyPayloadInto(&state.pending[0].reply, state.pending[0].reply_payload[0..], &payload_result, "abc");
    if (payload.len != @sizeOf(r4os.abi.NetServiceTcpResult) + 3) return localContractFail(app, 24);
    var pi: usize = 0;
    while (pi < state.pending.len) : (pi += 1) state.pending[pi] = .{};

    var write_request: [12]u8 = .{0} ** 12;
    writeLe32(write_request[0..], 0, front);
    copyBytes(write_request[4..], "write-ok");
    var write_block = r4os.abi.NetServiceTcpResult{
        .action = r4os.abi.net_service_tcp_action_write,
        .result = 0,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_would_block),
        .handle = front,
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_would_block,
    };
    if (!shouldDeferWrite(&write_block, write_request[0..])) return localContractFail(app, 25);
    if (!startDeferredWrite(app, &state, 1240, 11, write_request[0..], null, &write_block)) return localContractFail(app, 26);
    if (pendingCount(&state) != 1 or state.pending[0].kind != .write or state.pending[0].requested_bytes != 8) return localContractFail(app, 27);
    if (!contains(state.pending[0].data[0..8], "write-ok")) return localContractFail(app, 28);
    if (plannedWriteLength(64, 16) != 16 or plannedWriteLength(64, 0) != 0) return localContractFail(app, 29);
    const performance = tcpPerformanceSnapshot(app) orelse return localContractFail(app, 55);
    if (performance.local_mss != 1460) return localContractFail(app, 56);
    const full_write_segments = (r4os.abi.net_service_tcp_write_max + performance.local_mss - 1) / performance.local_mss;
    if (full_write_segments != 3) return localContractFail(app, 56);
    if (@as(u64, performance.catalog_capacity) * performance.local_mss < 65_535) return localContractFail(app, 57);
    if (performance.delayed_ack_ms == 0 or performance.delayed_ack_ms > 500) return localContractFail(app, 58);
    var write_done = r4os.abi.NetServiceTcpResult{
        .action = r4os.abi.net_service_tcp_action_write,
        .result = 0,
        .flags = withServiceStatus(r4os.abi.net_service_tcp_flag_ok | r4os.abi.net_service_tcp_flag_handle_valid, r4os.abi.net_service_status_ok),
        .handle = front,
        .bytes = 3,
        .requested_bytes = 8,
        .tx_window = 13,
        .retransmits = 1,
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_active,
    };
    noteTxWriteResult(&state, &write_done, 8);
    if (state.tx_partial_writes == 0 or state.tx_write_completions == 0 or state.tx_write_retransmits == 0) return localContractFail(app, 30);
    pi = 0;
    while (pi < state.pending.len) : (pi += 1) state.pending[pi] = .{};

    var accept_request: [2]u8 = .{0} ** 2;
    writeLe16(accept_request[0..], 0, 65044);
    var accept_block = r4os.abi.NetServiceTcpResult{
        .action = r4os.abi.net_service_tcp_action_accept,
        .result = 0,
        .flags = withServiceStatus(0, r4os.abi.net_service_status_would_block),
        .lifecycle_cause = r4os.abi.net_service_socket_lifecycle_would_block,
    };
    if (!shouldDeferAccept(r4os.abi.net_service_op_tcp_accept_poll_result, &accept_block, accept_request[0..])) return localContractFail(app, 43);
    const accept_deadline = app.sys.ticks() +| 10;
    if (!startDeferredAccept(app, &state, 1260, 11, r4os.abi.net_service_op_tcp_accept_poll_result, accept_request[0..], accept_deadline, &accept_block)) return localContractFail(app, 44);
    if (pendingCount(&state) != 1 or state.pending[0].kind != .accept or state.pending[0].port != 65044) return localContractFail(app, 45);
    if (startDeferredAccept(app, &state, 1261, 11, r4os.abi.net_service_op_tcp_accept_poll_result, accept_request[0..], accept_deadline, &accept_block)) return localContractFail(app, 46);
    pi = 0;
    while (pi < state.pending.len) : (pi += 1) state.pending[pi] = .{};
    var expired_accept = accept_block;
    if (startDeferredAccept(app, &state, 1262, 11, r4os.abi.net_service_op_tcp_accept_poll_result, accept_request[0..], app.sys.ticks(), &expired_accept)) return localContractFail(app, 47);
    if (serviceStatusCode(expired_accept.flags) != r4os.abi.net_service_status_timeout or (expired_accept.flags & r4os.abi.net_service_tcp_flag_timeout) == 0) return localContractFail(app, 48);

    var hi: usize = 0;
    while (hi < state.handles.len) : (hi += 1) state.handles[hi] = .{};
    if (frontHandleCount(&state) != 0) return localContractFail(app, 31);

    if (!rememberListener(&state, 11, 65044)) return localContractFail(app, 32);
    if (listenerCount(&state) != 1) return localContractFail(app, 33);
    releaseListener(&state, 65044);
    if (listenerCount(&state) != 0) return localContractFail(app, 34);

    var result = localOkListener(app, &state, r4os.abi.net_service_op_tcp_listen_result, 65045, "ok").result;
    if (result.magic != r4os.abi.net_service_tcp_result_magic or result.result != 0) return localContractFail(app, 35);
    if (serviceStatusCode(result.flags) != r4os.abi.net_service_status_ok) return localContractFail(app, 36);
    result = ownerMismatch(&state, r4os.abi.net_service_op_tcp_close_result, 9, 0).result;
    if (result.result != owner_mismatch_result or serviceStatusCode(result.flags) != r4os.abi.net_service_status_failed) return localContractFail(app, 37);

    service_status_reply = makeStatus(app, &state, 11);
    if (service_status_reply.magic != r4os.abi.net_service_tcp_status_magic or service_status_reply.max_handles != front_handles_max) return localContractFail(app, 38);

    var buf: [r4os.abi.service_api_max_payload]u8 = .{0} ** r4os.abi.service_api_max_payload;
    var w = Writer{ .out = buf[0..] };
    writeStatusText(&w, &state, &service_status_reply);
    return contains(w.slice(), "handles=") and contains(w.slice(), "readiness=") and contains(w.slice(), "pending=") and contains(w.slice(), "fair=") and contains(w.slice(), "endpoint=") and contains(w.slice(), "txwait=");
}

fn ensureRunningAndOpen(app: *const App, out_handle: *u32) bool {
    const actual = app.sys.base.generation2 orelse return false;
    const clock = r4os.inventory_reader.PlatformClock.fromContext2(actual) catch return false;
    var open_budget = r4os.rpc_budget.Budget.fromTicks(clock.read, 160) catch return false;
    var info: r4os.abi.ServiceInfo = .{};
    const status = app.sys.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = app.sys.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok) return false;
    }
    while (!app.sys.programShouldClose()) {
        _ = open_budget.remainingTicks() catch return false;
        const open_rc = app.sys.serviceOpen(service_name, &info);
        if (open_rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        app.sys.sleepTicks(1);
    }
    return false;
}

fn fail(app: *const App, label: []const u8) i32 {
    app.sys.write("TCPSVC selftest FAILED: ");
    app.sys.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) r4os.arguments.Error!bool {
    const raw = std.mem.span(args);
    var failure: r4os.arguments.Failure = .{};
    var cursor = try r4os.arguments.ArgCursor.init(raw, .{ .quotes = @intFromEnum(r4os.arguments.Quotes.none), .max_bytes = 256 }, &failure);
    while (try cursor.next()) |token| {
        if (std.ascii.eqlIgnoreCase(try token.bytes(raw), wanted)) return true;
    }
    return false;
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

fn readLe16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readLe32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn writeLe16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @truncate(value & 0x00FF);
    out[offset + 1] = @truncate(value >> 8);
}

fn writeLe32(out: []u8, offset: usize, value: u32) void {
    out[offset] = @truncate(value & 0x000000FF);
    out[offset + 1] = @truncate((value >> 8) & 0x000000FF);
    out[offset + 2] = @truncate((value >> 16) & 0x000000FF);
    out[offset + 3] = @truncate((value >> 24) & 0x000000FF);
}

fn copyStruct(out: anytype, data: []const u8) void {
    const out_bytes: [*]u8 = @ptrCast(out);
    const size = @sizeOf(@TypeOf(out.*));
    const len = @min(size, data.len);
    var i: usize = 0;
    while (i < len) : (i += 1) out_bytes[i] = data[i];
}

fn copyBytes(out: []u8, value: []const u8) void {
    var i: usize = 0;
    const len = @min(out.len, value.len);
    while (i < len) : (i += 1) out[i] = value[i];
}

fn copyFixed(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(out.len - 1, value.len);
    if (len != 0) copyBytes(out[0..len], value[0..len]);
}

fn setLastError(state: *ServiceState, value: []const u8) void {
    copyFixed(state.last_error[0..], value);
}

fn spanZ(data: []const u8) []const u8 {
    var len: usize = 0;
    while (len < data.len and data[len] != 0) : (len += 1) {}
    return data[0..len];
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

const Writer = struct {
    out: []u8,
    pos: usize = 0,

    fn text(self: *Writer, value: []const u8) void {
        if (self.pos >= self.out.len) return;
        const len = @min(value.len, self.out.len - self.pos);
        if (len != 0) copyBytes(self.out[self.pos .. self.pos + len], value[0..len]);
        self.pos += len;
    }

    fn num(self: *Writer, value: anytype) void {
        var buf: [32]u8 = undefined;
        var v: u64 = @intCast(value);
        var i: usize = buf.len;
        if (v == 0) {
            self.text("0");
            return;
        }
        while (v != 0 and i > 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
        self.text(buf[i..]);
    }

    fn signed(self: *Writer, value: i32) void {
        if (value < 0) {
            self.text("-");
            self.num(@as(u32, @intCast(-value)));
        } else {
            self.num(@as(u32, @intCast(value)));
        }
    }

    fn slice(self: *const Writer) []const u8 {
        return self.out[0..self.pos];
    }
};

fn replyNetwork(app: *const App, endpoint: u32, request_id: u32, state: *ServiceState, owner: u32, op: u16, payload: []const u8) i32 {
    return networkRequest(app, endpoint, request_id, state, owner, op, payload) catch |err|
        finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, network.code(err), ""));
}
fn networkRequest(app: *const App, endpoint: u32, request_id: u32, state: *ServiceState, owner: u32, op: u16, payload: []const u8) network.Error!i32 {
    const a = r4os.abi;
    if (state.provider == 0) return error.Backend;
    if (op == a.network_op_info) {
        if (payload.len != 0) return error.Invalid;
        var info: a.NetworkProviderInfo = .{ .provider = state.provider };
        if (network.backendInfo(app.net, a.ipc_channel_net_tcp)) |backend| {
            const required = a.network_cap_ipv4 | a.network_cap_tcp | a.network_cap_retained_terminal;
            if (backend.capabilities & required == required and backend.max_send != 0 and backend.max_recv != 0) {
                info.capabilities = required | (backend.capabilities & a.network_cap_listen);
                info.max_send = backend.max_send;
                info.max_recv = backend.max_recv;
            }
        }
        if (app.dev) |dev| {
            if (transport.providerInfo(dev, "net.tcp")) |backend| {
                const required = a.network_cap_ipv6 | a.network_cap_tcp | a.network_cap_listen | a.network_cap_retained_terminal;
                if (backend.capabilities & required == required and backend.max_send != 0 and backend.max_recv != 0) {
                    info.capabilities |= required;
                    if (info.capabilities & a.network_cap_ipv4 != 0) info.capabilities |= a.network_cap_dual_stack;
                    info.max_send = @max(info.max_send, backend.max_send);
                    info.max_recv = @max(info.max_recv, backend.max_recv);
                    info.interface_id = backend.interface_id;
                }
            } else |_| {}
        }
        return finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&info)));
    }
    if (op != a.network_op_connect and op != a.network_op_read and op != a.network_op_write and op != a.network_op_close and op != a.network_op_listen and op != a.network_op_accept) return error.UnsupportedPolicy;
    if (payload.len < @sizeOf(a.NetworkSocketRequest)) return error.Invalid;
    const req = try network.record(a.NetworkSocketRequest, payload[0..@sizeOf(a.NetworkSocketRequest)]);
    if (req.provider != state.provider) return error.ProviderChanged;
    const process = try network.owner(app.sys, owner);
    const data = payload[@sizeOf(a.NetworkSocketRequest)..];
    if (data.len != (if (op == a.network_op_write) req.bytes else @as(u32, 0))) return error.Invalid;
    try network.checkAttempt(app.sys, req.deadline);
    if (op == a.network_op_listen or op == a.network_op_connect and req.endpoint.address.family == 6) return networkCreate(app, endpoint, request_id, state, process, op, req);
    try network.policy(req.flags);
    if (op == a.network_op_connect) {
        const ip = try network.ipv4(req.endpoint, false);
        if (std.mem.allEqual(u8, &ip, 0) or req.socket != 0 or req.generation != 0 or req.bytes != 0) return error.Invalid;
        const backend = network.backendInfo(app.net, a.ipc_channel_net_tcp) orelse return error.Backend;
        const required = a.network_cap_ipv4 | a.network_cap_tcp | a.network_cap_retained_terminal;
        if (backend.capabilities & required != required or backend.max_send == 0 or backend.max_recv == 0) return error.Backend;
        if (state.next_typed_generation == 0) return error.Capacity;
        var free_front = false;
        for (state.handles) |entry| {
            if (!entry.used) {
                free_front = true;
                break;
            }
        }
        if (!free_front) return error.Capacity;
        const limit = try network.tickDeadline(app.sys, req.deadline);
        var bytes: [6]u8 = undefined;
        @memcpy(bytes[0..4], &ip);
        writeLe16(&bytes, 4, req.endpoint.port);
        const reply = backendResultWithDeadline(app, a.net_service_op_tcp_connect_retained_result, &bytes, limit, backend_result_data[0..]) orelse return error.Backend;
        if (reply.result.result != 0 or reply.result.handle == 0 or reply.result.conn_id == 0) {
            return if (reply.result.lifecycle_cause == a.net_service_socket_lifecycle_timeout) error.Timeout else error.Backend;
        }
        const front = allocateFrontHandle(state, owner, reply.result.handle, reply.result.conn_id) orelse {
            closeBackendHandle(app, reply.result.handle);
            return error.Capacity;
        };
        const lookup = resolveFrontHandle(state, front, owner);
        const generation = state.next_typed_generation;
        state.next_typed_generation = std.math.add(u64, generation, 1) catch 0;
        state.handles[lookup.index].typed_generation = generation;
        state.handles[lookup.index].typed_owner = process;
        state.typed_count += 1;
        state.handles[lookup.index].typed_endpoint = req.endpoint;
        const out: a.NetworkSocketResult = .{ .provider = state.provider, .socket = front, .generation = generation, .endpoint = req.endpoint, .state = a.network_state_ready };
        if (!network.ownerAlive(app.sys, process)) {
            if (closeTypedBackend(app, reply.result.handle)) releaseFrontHandleAt(state, lookup.index);
            return error.BadSocket;
        }
        const rc = app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out));
        if (rc != 0 and closeTypedBackend(app, reply.result.handle)) releaseFrontHandleAt(state, lookup.index);
        return finishReply(state, rc);
    }
    if (req.socket == 0 or req.socket > std.math.maxInt(u32) or req.generation == 0 or !std.mem.allEqual(u8, std.mem.asBytes(&req.endpoint), 0)) return error.Invalid;
    var index: ?usize = null;
    for (&state.handles, 0..) |entry, i| {
        if (entry.used and (!entry.typed_retiring or op == a.network_op_close) and entry.handle == req.socket and entry.typed_generation == req.generation and entry.owner_id == owner and entry.typed_owner.generation == process.generation) {
            index = i;
            break;
        }
    }
    const slot = index orelse return error.BadSocket;
    if (op == a.network_op_accept) return networkAccept(app, endpoint, request_id, state, slot, req);
    if (state.handles[slot].v6_provider != 0 or state.handles[slot].typed_listener) return networkTransfer(app, endpoint, request_id, state, slot, op, req, data);
    const entry = state.handles[slot];
    var out: a.NetworkSocketResult = .{ .provider = state.provider, .socket = req.socket, .generation = req.generation, .endpoint = entry.typed_endpoint, .state = a.network_state_ready };
    var input: [4096]u8 = undefined;
    writeLe32(&input, 0, entry.backend_handle);
    var body: []const u8 = "";
    if (op == a.network_op_close) {
        if (req.bytes != 0) return error.Invalid;
        const reply = backendResult(app, a.net_service_op_tcp_close_result, input[0..4], backend_result_data[0..]) orelse return error.Backend;
        if (reply.result.result < 0) return error.BadSocket;
        releaseFrontHandleAt(state, slot);
        out.state = a.network_state_local_closed;
    } else if (req.bytes != 0) {
        const reading = op == a.network_op_read;
        if (req.bytes > (if (reading) @as(u32, 4008) else @min(a.net_service_tcp_write_max, 3968))) return error.Capacity;
        var count: usize = 4;
        if (reading) {
            // The new reply has a smaller header than the private IPv4
            // NIPC reply. Accept the public capacity and return one bounded
            // backend prefix; the caller retains the remaining stream.
            writeLe16(&input, 4, @intCast(@min(req.bytes, a.net_service_tcp_read_max)));
            count = 6;
        } else {
            @memcpy(input[4..][0..data.len], data);
            count += data.len;
        }
        const reply = backendResult(app, if (reading) a.net_service_op_tcp_read_result else a.net_service_op_tcp_write_result, input[0..count], backend_result_data[0..]) orelse return error.Backend;
        if (reply.result.conn_id != 0 and reply.result.conn_id != entry.conn_id) return error.BadSocket;
        if (reply.result.result < 0) {
            if (!reading and reply.result.lifecycle_cause == a.net_service_socket_lifecycle_peer_gone) {
                out.state = a.network_state_local_closed;
                return finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out)));
            }
            return if (reply.result.lifecycle_cause == a.net_service_socket_lifecycle_reset) error.Reset else if (reply.result.lifecycle_cause == a.net_service_socket_lifecycle_bad_handle) error.BadSocket else error.Backend;
        }
        if (reply.result.bytes > req.bytes) return error.Backend;
        out.bytes = reply.result.bytes;
        out.original_bytes = out.bytes;
        if (out.bytes == 0) {
            out.state = switch (reply.result.lifecycle_cause) {
                a.net_service_socket_lifecycle_peer_gone => if (reading) a.network_state_eof else a.network_state_local_closed,
                a.net_service_socket_lifecycle_reset => a.network_state_reset,
                a.net_service_socket_lifecycle_would_block => a.network_state_would_block,
                else => return error.Backend,
            };
        }
        if (reading) {
            if (reply.data.len != out.bytes) return error.Backend;
            body = reply.data;
        }
    }
    var response: [4096]u8 = undefined;
    @memcpy(response[0..@sizeOf(a.NetworkSocketResult)], std.mem.asBytes(&out));
    @memcpy(response[@sizeOf(a.NetworkSocketResult)..][0..body.len], body);
    return finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, 0, response[0 .. @sizeOf(a.NetworkSocketResult) + body.len]));
}

// Poll only while new typed resources exist. Existing old-only service idle
// waits remain unbounded. No process registry borrow spans backend work.
fn sweepNetworkOwners(app: *const App, state: *ServiceState) void {
    tickNetworkTransport(app, state);
    if (state.typed_count == 0 or app.sys.ticks() < state.typed_sweep_tick) return;
    state.typed_sweep_tick = app.sys.ticks() +| app.sys.ticksFromMilliseconds(1000);
    for (&state.handles, 0..) |entry, i| {
        if (!entry.used or entry.typed_generation == 0 or !entry.typed_retiring and !network.ownerGone(app.sys, entry.typed_owner)) continue;
        if (entry.v6_provider != 0 or entry.typed_listener) {
            if (retireNetworkSocket(app, state, i)) releaseFrontHandleAt(state, i);
            continue;
        }
        var request: [4]u8 = undefined;
        writeLe32(&request, 0, entry.backend_handle);
        const reply = backendResult(app, r4os.abi.net_service_op_tcp_abort_result, &request, backend_result_data[0..]) orelse continue;
        // Uncertain transport failure retains this bounded front entry until
        // a later actual owner acknowledgement; it is no retirement proof.
        if (reply.result.result == 0) releaseFrontHandleAt(state, i);
    }
}

fn closeTypedBackend(app: *const App, backend_handle: u32) bool {
    var request: [4]u8 = undefined;
    writeLe32(&request, 0, backend_handle);
    const reply = backendResult(app, r4os.abi.net_service_op_tcp_abort_result, &request, backend_result_data[0..]) orelse return false;
    return reply.result.result == 0;
}

fn networkSweepDeadline(app: *const App, state: *const ServiceState) ?u64 {
    if (state.typed_count == 0) return null;
    // A missing logical frequency must not turn owner cleanup into a busy
    // poll loop. Without it, retain resources and check on ordinary requests.
    if (app.sys.ticksFromMilliseconds(1000) == 0) return null;
    for (state.handles) |entry| if (entry.used and entry.v6_provider != 0) return @min(state.typed_sweep_tick, state.transport_tick);
    return state.typed_sweep_tick;
}

fn markNetworkHandle(state: *ServiceState, slot: usize, owner: r4os.abi.ProgramProcessHandle, endpoint: r4os.abi.NetworkEndpoint) network.Error!void {
    if (state.next_typed_generation == 0) return error.Capacity;
    state.handles[slot].typed_generation = state.next_typed_generation;
    state.next_typed_generation = std.math.add(u64, state.next_typed_generation, 1) catch 0;
    state.handles[slot].typed_owner = owner;
    state.handles[slot].typed_endpoint = endpoint;
    state.typed_count += 1;
}
fn networkHasSpace(state: *const ServiceState) bool {
    if (state.next_typed_generation == 0) return false;
    for (state.handles) |entry| if (!entry.used) return true;
    return false;
}
fn networkCreate(app: *const App, endpoint: u32, request_id: u32, state: *ServiceState, owner: r4os.abi.ProgramProcessHandle, op: u16, req: r4os.abi.NetworkSocketRequest) network.Error!i32 {
    const a = r4os.abi;
    const listening = op == a.network_op_listen;
    const v6 = req.endpoint.address.family == 6;
    if (req.socket != 0 or req.generation != 0 or req.bytes != 0 or !network.endpointValid(req.endpoint)) return error.Invalid;
    if (req.endpoint.address.family != 4 and !v6) return error.UnsupportedFamily;
    if (req.flags != 0 and !(v6 and listening and req.flags == a.network_policy_dual_stack and transport.zero(req.endpoint.address) and req.endpoint.address.scope_id == 0)) return error.UnsupportedPolicy;
    if (!listening and req.deadline.kind == 0) return error.WouldBlock;
    if (!networkHasSpace(state)) return error.Capacity;
    if (!listening and (pendingCount(state) >= pendingActiveLimit() or pendingCountForOwner(state, owner.instance_id) >= pending_per_owner_max)) return error.Capacity;
    const pending_slot: ?usize = if (!listening) allocatePendingSlot(state) orelse return error.Capacity else null;
    const handle = allocateFrontHandle(state, owner.instance_id, 0, 0) orelse return error.Capacity;
    const lookup = resolveFrontHandle(state, handle, owner.instance_id);
    const entry = &state.handles[lookup.index];
    try markNetworkHandle(state, lookup.index, owner, req.endpoint);
    entry.typed_listener = listening;
    if (v6) {
        const dev = app.dev orelse {
            releaseFrontHandleAt(state, lookup.index);
            return error.UnsupportedFamily;
        };
        const info = transport.providerInfo(dev, "net.tcp") catch |err| {
            releaseFrontHandleAt(state, lookup.index);
            return err;
        };
        if (info.capabilities & a.network_cap_ipv6 == 0) {
            releaseFrontHandleAt(state, lookup.index);
            return error.UnsupportedFamily;
        }
        var response: [4096]u8 = undefined;
        var request = req;
        request.flags = 0;
        const reply = transport.broker(app.sys, dev, "net.tcp", info.provider, owner, op, request, "", &response) catch |err| {
            releaseFrontHandleAt(state, lookup.index);
            return err;
        };
        entry.v6_provider = info.provider;
        entry.v6_socket = reply.result.socket;
        entry.v6_generation = reply.result.generation;
        entry.typed_endpoint = reply.result.endpoint;
        if (entry.v6_socket == 0 or entry.v6_generation == 0) {
            entry.typed_retiring = true;
            return error.Backend;
        }
        if (!listening and reply.result.state != a.network_state_ready) {
            if (reply.result.state != a.network_state_would_block) {
                entry.typed_retiring = true;
                return if (reply.result.state == a.network_state_timeout) error.Timeout else error.Reset;
            }
            state.pending[pending_slot.?] = .{ .used = true, .typed = true, .kind = .connect, .request_id = request_id, .owner_id = owner.instance_id, .front_handle = handle, .generation = entry.generation, .network_request = req, .start_ticks = app.sys.ticks() };
            return 0;
        }
    } else {
        const ip = network.ipv4(req.endpoint, false) catch |err| {
            releaseFrontHandleAt(state, lookup.index);
            return err;
        };
        if (!std.mem.allEqual(u8, &ip, 0)) {
            releaseFrontHandleAt(state, lookup.index);
            return error.UnsupportedScope;
        }
    }
    if (listening and (!v6 or req.flags == a.network_policy_dual_stack)) {
        const port = entry.typed_endpoint.port;
        if (port == 0 or listenerForPort(state, port) != null) {
            if (retireNetworkSocket(app, state, lookup.index)) releaseFrontHandleAt(state, lookup.index);
            return error.Capacity;
        }
        var bytes: [2]u8 = undefined;
        writeLe16(&bytes, 0, port);
        const reply = performListen(app, state, owner.instance_id, a.net_service_op_tcp_listen_retained_result, &bytes, backend_result_data[0..]);
        if (reply.result.result != 0) {
            if (retireNetworkSocket(app, state, lookup.index)) releaseFrontHandleAt(state, lookup.index);
            return error.Capacity;
        }
        entry.typed_v4_listener = true;
    }
    const out: a.NetworkSocketResult = .{ .provider = state.provider, .socket = handle, .generation = entry.typed_generation, .endpoint = entry.typed_endpoint, .state = a.network_state_ready };
    const rc = app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out));
    if (rc != 0 and retireNetworkSocket(app, state, lookup.index)) releaseFrontHandleAt(state, lookup.index);
    return finishReply(state, rc);
}

fn failNetworkConnect(app: *const App, endpoint: u32, state: *ServiceState, index: usize, code: i32) i32 {
    const pending = state.pending[index];
    const lookup = resolveFrontHandle(state, pending.front_handle, pending.owner_id);
    if (lookup.ok and lookup.entry.generation == pending.generation) {
        state.handles[lookup.index].typed_retiring = true;
        if (retireNetworkSocket(app, state, lookup.index)) releaseFrontHandleAt(state, lookup.index);
    }
    state.pending[index] = .{};
    return finishReply(state, app.sys.serviceEndpointReply(endpoint, pending.request_id, code, ""));
}
fn processPendingNetworkConnect(app: *const App, endpoint: u32, state: *ServiceState, index: usize) i32 {
    const a = r4os.abi;
    const pending = &state.pending[index];
    if (!pending.typed) return failNetworkConnect(app, endpoint, state, index, a.network_error_invalid);
    const lookup = resolveFrontHandle(state, pending.front_handle, pending.owner_id);
    if (!lookup.ok or lookup.entry.generation != pending.generation or lookup.entry.typed_retiring) return failNetworkConnect(app, endpoint, state, index, a.network_error_bad_socket);
    const entry = &state.handles[lookup.index];
    network.checkAttempt(app.sys, pending.network_request.deadline) catch |err| return failNetworkConnect(app, endpoint, state, index, network.code(err));
    if (network.ownerGone(app.sys, entry.typed_owner)) return failNetworkConnect(app, endpoint, state, index, a.network_error_bad_socket);
    const dev = app.dev orelse return failNetworkConnect(app, endpoint, state, index, a.network_error_unsupported_family);
    var req = pending.network_request;
    req.socket = entry.v6_socket;
    req.generation = entry.v6_generation;
    var response: [4096]u8 = undefined;
    const reply = transport.broker(app.sys, dev, "net.tcp", entry.v6_provider, entry.typed_owner, a.network_op_connect, req, "", &response) catch |err| {
        if (err == error.WouldBlock) return 0;
        return failNetworkConnect(app, endpoint, state, index, network.code(err));
    };
    if (reply.result.state == a.network_state_would_block) return 0;
    if (reply.result.state != a.network_state_ready) return failNetworkConnect(app, endpoint, state, index, if (reply.result.state == a.network_state_timeout) a.network_error_timeout else a.network_error_reset);
    var out = reply.result;
    out.provider = state.provider;
    out.socket = entry.handle;
    out.generation = entry.typed_generation;
    const rc = app.sys.serviceEndpointReply(endpoint, pending.request_id, 0, std.mem.asBytes(&out));
    if (rc != 0 and retireNetworkSocket(app, state, lookup.index)) releaseFrontHandleAt(state, lookup.index);
    state.pending[index] = .{};
    return finishReply(state, rc);
}

fn tickNetworkTransport(app: *const App, state: *ServiceState) void {
    if (app.sys.ticks() < state.transport_tick) return;
    var active = false;
    for (state.handles) |entry| if (entry.used and entry.v6_provider != 0) {
        active = true;
        break;
    };
    if (!active) return;
    const ticks = app.sys.ticksFromMilliseconds(50);
    if (ticks == 0) return;
    state.transport_tick = app.sys.ticks() +| ticks;
    const dev = app.dev orelse return;
    const info = transport.providerInfo(dev, "net.tcp") catch return;
    const actual = app.sys.base.generation2 orelse return;
    const id = std.math.cast(u32, actual.raw.instance_id) orelse return;
    const owner = network.owner(app.sys, id) catch return;
    var response: [4096]u8 = undefined;
    _ = transport.broker(app.sys, dev, "net.tcp", info.provider, owner, r4os.abi.network_transport_op_tick, .{}, "", &response) catch return;
}

fn retireNetworkSocket(app: *const App, state: *ServiceState, slot: usize) bool {
    const a = r4os.abi;
    const entry = &state.handles[slot];
    entry.typed_retiring = true;
    if (entry.v6_socket != 0) {
        const dev = app.dev orelse return false;
        var response: [4096]u8 = undefined;
        const req: a.NetworkSocketRequest = .{ .socket = entry.v6_socket, .generation = entry.v6_generation };
        if (transport.broker(app.sys, dev, "net.tcp", entry.v6_provider, entry.typed_owner, a.network_op_close, req, "", &response)) |_| {
            entry.v6_socket = 0;
        } else |err| {
            if (err == error.BadSocket or err == error.ProviderChanged) entry.v6_socket = 0 else return false;
        }
    }
    if (entry.typed_v4_listener) {
        var bytes: [2]u8 = undefined;
        writeLe16(&bytes, 0, entry.typed_endpoint.port);
        const reply = performCloseListen(app, state, entry.owner_id, a.net_service_op_tcp_close_listen_result, &bytes, backend_result_data[0..]);
        if (reply.result.result != 0) return false;
        entry.typed_v4_listener = false;
    }
    if (entry.backend_handle != 0) {
        if (!closeTypedBackend(app, entry.backend_handle)) return false;
        entry.backend_handle = 0;
    }
    return true;
}

fn networkTransfer(app: *const App, endpoint: u32, request_id: u32, state: *ServiceState, slot: usize, op: u16, req: r4os.abi.NetworkSocketRequest, data: []const u8) network.Error!i32 {
    const a = r4os.abi;
    const entry = &state.handles[slot];
    if (op == a.network_op_close) {
        if (req.bytes != 0) return error.Invalid;
        const out: a.NetworkSocketResult = .{ .provider = state.provider, .socket = entry.handle, .generation = entry.typed_generation, .endpoint = entry.typed_endpoint, .state = a.network_state_local_closed };
        if (!retireNetworkSocket(app, state, slot)) return error.WouldBlock;
        releaseFrontHandleAt(state, slot);
        return finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out)));
    }
    if (entry.typed_listener or op != a.network_op_read and op != a.network_op_write) return error.BadSocket;
    const dev = app.dev orelse return error.UnsupportedFamily;
    var backend = req;
    backend.socket = entry.v6_socket;
    backend.generation = entry.v6_generation;
    var response: [4096]u8 = undefined;
    const reply = try transport.broker(app.sys, dev, "net.tcp", entry.v6_provider, entry.typed_owner, op, backend, data, &response);
    var out = reply.result;
    out.provider = state.provider;
    out.socket = entry.handle;
    out.generation = entry.typed_generation;
    @memcpy(response[0..@sizeOf(a.NetworkSocketResult)], std.mem.asBytes(&out));
    return finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, 0, response[0 .. @sizeOf(a.NetworkSocketResult) + reply.data.len]));
}

fn networkAccept(app: *const App, endpoint: u32, request_id: u32, state: *ServiceState, slot: usize, req: r4os.abi.NetworkSocketRequest) network.Error!i32 {
    const a = r4os.abi;
    const listener = state.handles[slot];
    if (!listener.typed_listener or req.bytes != 0) return error.BadSocket;
    if (!networkHasSpace(state)) return error.Capacity;
    var out: a.NetworkSocketResult = .{ .provider = state.provider, .socket = listener.handle, .generation = listener.typed_generation, .endpoint = listener.typed_endpoint, .state = a.network_state_would_block };
    if (listener.v6_provider != 0) {
        const dev = app.dev orelse return error.UnsupportedFamily;
        var backend = req;
        backend.socket = listener.v6_socket;
        backend.generation = listener.v6_generation;
        var response: [4096]u8 = undefined;
        if (transport.broker(app.sys, dev, "net.tcp", listener.v6_provider, listener.typed_owner, a.network_op_accept, backend, "", &response)) |reply| {
            const handle = allocateFrontHandle(state, listener.owner_id, 0, 0) orelse return error.Capacity;
            const lookup = resolveFrontHandle(state, handle, listener.owner_id);
            try markNetworkHandle(state, lookup.index, listener.typed_owner, reply.result.endpoint);
            const child = &state.handles[lookup.index];
            child.v6_provider = listener.v6_provider;
            child.v6_socket = reply.result.socket;
            child.v6_generation = reply.result.generation;
            out = reply.result;
            out.provider = state.provider;
            out.socket = handle;
            out.generation = child.typed_generation;
            const rc = app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out));
            if (rc != 0 and retireNetworkSocket(app, state, lookup.index)) releaseFrontHandleAt(state, lookup.index);
            return finishReply(state, rc);
        } else |err| if (err != error.WouldBlock) return err;
    }
    if (listener.typed_v4_listener) {
        var bytes: [2]u8 = undefined;
        writeLe16(&bytes, 0, listener.typed_endpoint.port);
        const reply = performAccept(app, state, listener.owner_id, a.net_service_op_tcp_accept_poll_result, &bytes, backend_result_data[0..]);
        if (reply.result.result != 0) return error.Backend;
        if (reply.result.handle != 0 and reply.result.flags & a.net_service_tcp_flag_handle_valid != 0) {
            const lookup = resolveFrontHandle(state, reply.result.handle, listener.owner_id);
            if (!lookup.ok) return error.Backend;
            const peer = network.v4Endpoint(reply.result.remote_ip, reply.result.remote_port);
            try markNetworkHandle(state, lookup.index, listener.typed_owner, peer);
            out.socket = reply.result.handle;
            out.generation = state.handles[lookup.index].typed_generation;
            out.endpoint = peer;
            out.state = a.network_state_ready;
            const rc = app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out));
            if (rc != 0 and closeTypedBackend(app, lookup.entry.backend_handle)) releaseFrontHandleAt(state, lookup.index);
            return finishReply(state, rc);
        }
    }
    return finishReply(state, app.sys.serviceEndpointReply(endpoint, request_id, 0, std.mem.asBytes(&out)));
}
