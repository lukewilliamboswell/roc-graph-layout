///! Platform host that implements effectful functions for stdout, stderr, and stdin.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("roc_platform_abi.zig");

const Telemetry = struct {
    active: bool = false,
    started_ns: u64 = 0,
    lifetime_live: u64 = 0,
    live_start: u64 = 0,
    peak_live: u64 = 0,
    alloc_calls: u64 = 0,
    realloc_calls: u64 = 0,
    dealloc_calls: u64 = 0,
    requested: u64 = 0,
    released: u64 = 0,
    largest_request: u64 = 0,
};

var telemetry = Telemetry{};

pub const std_options: std.Options = .{
    .allow_stack_tracing = false,
};

/// Host environment. Embeds `abi.RocEnv` so the Roc runtime sees a pointer
/// to a standard `RocEnv` while hosted functions can recover the full
/// `HostEnv` via `@fieldParentPtr`.
const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{}),
    stdin_reader: std.Io.File.Reader,
    roc_env: abi.RocEnv,
};

/// Roc entrypoint exported by the app under `provides { "roc_main": main_for_host! }`.
extern fn roc_main(args: abi.RocList(abi.RocStr)) callconv(.c) i32;

/// Private RocHost used by host helpers and exported runtime symbols.
var g_roc_host: ?*abi.RocHost = null;

// OS-specific entry point handling (not exported during tests)
comptime {
    if (!builtin.is_test) {
        // Export main for all platforms
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (@import("builtin").os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return platform_main(@intCast(argc), argv);
}

fn stderrLineOk() abi.TryType0 {
    var result = std.mem.zeroes(abi.TryType0);
    result.tag = .Ok;
    return result;
}

fn stderrLineErr(err: anyerror, roc_host: *abi.RocHost) abi.TryType0 {
    var result = std.mem.zeroes(abi.TryType0);
    result.payload = .{ .err = abi.RocStr.fromSlice(@errorName(err), roc_host) };
    result.tag = .Err;
    return result;
}

fn stdinLineOk(line: abi.RocStr) abi.TryType4 {
    var result = std.mem.zeroes(abi.TryType4);
    result.payload = .{ .ok = line };
    result.tag = .Ok;
    return result;
}

fn stdinLineErr(err: anyerror, roc_host: *abi.RocHost) abi.TryType4 {
    var result = std.mem.zeroes(abi.TryType4);
    result.payload = .{ .err = abi.RocStr.fromSlice(@errorName(err), roc_host) };
    result.tag = .Err;
    return result;
}

fn stdoutLineOk() abi.TryType6 {
    var result = std.mem.zeroes(abi.TryType6);
    result.tag = .Ok;
    return result;
}

fn stdoutLineErr(err: anyerror, roc_host: *abi.RocHost) abi.TryType6 {
    var result = std.mem.zeroes(abi.TryType6);
    result.payload = .{ .err = abi.RocStr.fromSlice(@errorName(err), roc_host) };
    result.tag = .Err;
    return result;
}

/// Hosted function: Host.stderr_line!
fn hostedStderrLine(str: abi.RocStr) callconv(.c) abi.TryType0 {
    const roc_host = g_roc_host.?;
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, message) catch |err| return stderrLineErr(err, roc_host);
    stderr.writeStreamingAll(io, "\n") catch |err| return stderrLineErr(err, roc_host);
    return stderrLineOk();
}

/// Hosted function: Host.stdin_line!
fn hostedStdinLine() callconv(.c) abi.TryType4 {
    const roc_host = g_roc_host.?;
    const roc_env: *abi.RocEnv = @ptrCast(@alignCast(roc_host.env));
    const host: *HostEnv = @fieldParentPtr("roc_env", roc_env);
    var reader = &host.stdin_reader.interface;

    var line = while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return stdinLineErr(err, roc_host),
            error.StreamTooLong => {
                // Skip the overlong line so the next call starts fresh.
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.ReadFailed => return stdinLineErr(discard_err, roc_host),
                    error.EndOfStream => return stdinLineOk(abi.RocStr.empty()),
                };
                continue;
            },
        } orelse break &.{};

        break maybe_line;
    };

    // Trim trailing \r for Windows line endings
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }

    if (line.len == 0) {
        return stdinLineOk(abi.RocStr.empty());
    }

    return stdinLineOk(abi.RocStr.fromSlice(line[0..line.len], roc_host));
}

/// Hosted function: Host.stdout_line!
fn hostedStdoutLine(str: abi.RocStr) callconv(.c) abi.TryType6 {
    const roc_host = g_roc_host.?;
    var owned = str;
    defer owned.decref(roc_host);

    const message = owned.asSlice();
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, message) catch |err| return stdoutLineErr(err, roc_host);
    stdout.writeStreamingAll(io, "\n") catch |err| return stdoutLineErr(err, roc_host);
    return stdoutLineOk();
}

fn monotonicNs() u64 {
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    } else if (builtin.os.tag == .windows) {
        const k32 = struct {
            extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) std.os.windows.BOOL;
            extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) std.os.windows.BOOL;
        };
        var counter: i64 = undefined;
        var frequency: i64 = undefined;
        if (k32.QueryPerformanceCounter(&counter) == .FALSE or k32.QueryPerformanceFrequency(&frequency) == .FALSE) @trap();
        return @intCast(@divTrunc(@as(i128, counter) * std.time.ns_per_s, frequency));
    } else @compileError("unsupported benchmark clock");
}

fn requestedLength(ptr: *anyopaque, alignment: usize) usize {
    const storage = @max(alignment, @alignOf(usize));
    const total_ptr: *const usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    return total_ptr.* - storage;
}

fn noteAlloc(length: usize) void {
    telemetry.lifetime_live +|= length;
    if (telemetry.active) {
        telemetry.alloc_calls +|= 1;
        telemetry.requested +|= length;
        telemetry.largest_request = @max(telemetry.largest_request, length);
        telemetry.peak_live = @max(telemetry.peak_live, telemetry.lifetime_live);
    }
}

fn noteRelease(length: usize, is_realloc: bool) void {
    telemetry.lifetime_live -|= length;
    if (telemetry.active) {
        if (is_realloc) telemetry.realloc_calls +|= 1 else telemetry.dealloc_calls +|= 1;
        telemetry.released +|= length;
    }
}

fn hostedMeasureStart() callconv(.c) u8 {
    if (telemetry.active) @panic("nested benchmark measurement");
    telemetry.active = true;
    telemetry.started_ns = monotonicNs();
    telemetry.live_start = telemetry.lifetime_live;
    telemetry.peak_live = telemetry.lifetime_live;
    telemetry.alloc_calls = 0;
    telemetry.realloc_calls = 0;
    telemetry.dealloc_calls = 0;
    telemetry.requested = 0;
    telemetry.released = 0;
    telemetry.largest_request = 0;
    return 0;
}

fn hostedMeasureFinish(observation: u64) callconv(.c) abi.RocStr {
    if (!telemetry.active) @panic("benchmark finish without start");
    const elapsed = monotonicNs() - telemetry.started_ns;
    telemetry.active = false;
    var buffer: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buffer, "{{\"schema_version\":1,\"observation\":{d},\"elapsed_ns\":{d},\"alloc_calls\":{d},\"realloc_calls\":{d},\"dealloc_calls\":{d},\"bytes_requested\":{d},\"bytes_released\":{d},\"live_bytes_start\":{d},\"live_bytes_end\":{d},\"peak_live_bytes\":{d},\"peak_extra_bytes\":{d},\"largest_request_bytes\":{d}", .{ observation, elapsed, telemetry.alloc_calls, telemetry.realloc_calls, telemetry.dealloc_calls, telemetry.requested, telemetry.released, telemetry.live_start, telemetry.lifetime_live, telemetry.peak_live, telemetry.peak_live -| telemetry.live_start, telemetry.largest_request }) catch @panic("telemetry JSON overflow");
    return abi.RocStr.fromSlice(json, g_roc_host.?);
}

fn hostAlloc(length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const result = abi.DefaultAllocators.rocAlloc(g_roc_host.?, length, alignment);
    if (result != null) noteAlloc(length);
    return result;
}

fn hostDealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    noteRelease(requestedLength(ptr, alignment), false);
    abi.DefaultAllocators.rocDealloc(g_roc_host.?, ptr, alignment);
}

fn hostRealloc(ptr: *anyopaque, new_length: usize, alignment: usize) callconv(.c) ?*anyopaque {
    const old_length = requestedLength(ptr, alignment);
    const result = abi.DefaultAllocators.rocRealloc(g_roc_host.?, ptr, new_length, alignment);
    if (result != null) {
        noteRelease(old_length, true);
        telemetry.lifetime_live +|= new_length;
        if (telemetry.active) {
            telemetry.requested +|= new_length;
            telemetry.largest_request = @max(telemetry.largest_request, new_length);
            telemetry.peak_live = @max(telemetry.peak_live, telemetry.lifetime_live);
        }
    }
    return result;
}

fn hostDbg(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocDbg(g_roc_host.?, bytes, len);
}

fn hostExpectFailed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocExpectFailed(g_roc_host.?, bytes, len);
}

fn hostCrashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    abi.DefaultHandlers.rocCrashed(g_roc_host.?, bytes, len);
}

comptime {
    if (!builtin.is_test) {
        @export(&hostedStderrLine, .{ .name = "roc_stderr_line", .visibility = .hidden });
        @export(&hostedStdinLine, .{ .name = "roc_stdin_line", .visibility = .hidden });
        @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });
        @export(&hostedMeasureStart, .{ .name = "roc_measure_start", .visibility = .hidden });
        @export(&hostedMeasureFinish, .{ .name = "roc_measure_finish", .visibility = .hidden });

        @export(&hostAlloc, .{ .name = "roc_alloc", .visibility = .hidden });
        @export(&hostDealloc, .{ .name = "roc_dealloc", .visibility = .hidden });
        @export(&hostRealloc, .{ .name = "roc_realloc", .visibility = .hidden });
        @export(&hostDbg, .{ .name = "roc_dbg", .visibility = .hidden });
        @export(&hostExpectFailed, .{ .name = "roc_expect_failed", .visibility = .hidden });
        @export(&hostCrashed, .{ .name = "roc_crashed", .visibility = .hidden });
    }
}

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdin_buffer: [4096]u8 = undefined;

    var host_env = HostEnv{
        .gpa = std.heap.DebugAllocator(.{}){},
        .stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer),
        .roc_env = undefined,
    };
    host_env.roc_env = .{
        .allocator = host_env.gpa.allocator(),
        .roc_io = abi.RocIo.default(),
    };

    var roc_host = abi.makeRocHost(&host_env.roc_env);
    g_roc_host = &roc_host;

    // Build List(Str) from argc/argv
    std.log.debug("[HOST] Building args...", .{});
    const args_list = buildStrArgsList(argc, argv, &roc_host);
    std.log.debug("[HOST] args_list ptr=0x{x} len={d}", .{ @intFromPtr(args_list.elements_ptr), args_list.length });

    // Call the app's main! entrypoint - returns I32 exit code
    std.log.debug("[HOST] Calling roc_main...", .{});

    const exit_code = roc_main(args_list);
    std.log.debug("[HOST] Returned from roc, exit_code={d}", .{exit_code});

    if (telemetry.active) {
        std.log.err("benchmark process exited with an active measurement", .{});
        return 2;
    }

    // Check for memory leaks before returning
    const leak_status = host_env.gpa.deinit();
    if (leak_status == .leak) {
        std.log.err("\x1b[33mMemory leak detected!\x1b[0m", .{});
        std.process.exit(1);
    }

    return exit_code;
}

/// Build a RocList of RocStr from argc/argv
fn buildStrArgsList(argc: usize, argv: [*][*:0]u8, roc_host: *abi.RocHost) abi.RocList(abi.RocStr) {
    if (argc == 0) {
        return abi.RocList(abi.RocStr).empty();
    }

    const args_list = abi.RocList(abi.RocStr).allocate(argc, roc_host);
    const args_ptr: [*]abi.RocStr = args_list.elements_ptr.?;

    // Build each argument string
    for (0..argc) |i| {
        const arg_cstr = argv[i];
        const arg_len = std.mem.len(arg_cstr);
        args_ptr[i] = abi.RocStr.fromSlice(arg_cstr[0..arg_len], roc_host);
    }

    return args_list;
}
