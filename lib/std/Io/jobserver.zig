pub const Server = switch (builtin.os.tag) {
    else => struct {
        sem_id: c_int,

        pub fn init(
            server: *Server,
            gpa: std.mem.Allocator,
            num_tokens: usize,
            env_map: *std.process.EnvMap,
        ) !void {
            _ = gpa;
            server.sem_id = createSemaphore();
            setSemaphore(server.sem_id, @intCast(num_tokens));
            var buf: [std.fmt.count("{d}", .{std.math.maxInt(c_int)})]u8 = undefined;
            try env_map.put(
                "JOBSERVER_SEMID",
                std.fmt.bufPrint(&buf, "{d}", .{server.sem_id}) catch unreachable,
            );
        }

        pub fn deinit(server: *Server, gpa: std.mem.Allocator) void {
            _ = gpa;
            server.* = undefined;
        }

        /// `semget(IPC_PRIVATE, 1, 0o777)`
        fn createSemaphore() c_int {
            const IPC_PRIVATE = 0;
            const res = std.os.linux.syscall3(.semget, IPC_PRIVATE, 1, 0o777);
            switch (std.posix.errno(res)) {
                .SUCCESS => {},
                else => |e| std.process.fatal("semget failed: {t}", .{e}),
            }
            return @intCast(res);
        }

        /// `semctl(sem_id, 0, SETVAL, n)`
        fn setSemaphore(sem_id: c_int, n: c_ulong) void {
            const SETVAL = 16;
            const res = std.os.linux.syscall4(.semctl, @intCast(sem_id), 0, SETVAL, n);
            switch (std.posix.errno(res)) {
                .SUCCESS => {},
                else => |e| std.process.fatal("semctl failed: {t}", .{e}),
            }
        }
    },
    .windows => struct {
        tokens: []Token,
        done: windows.HANDLE,
        thread: std.Thread,

        const Token = struct {
            handle: windows.HANDLE,
            iosb: windows.IO_STATUS_BLOCK,
        };

        var pipe_name_counter = std.atomic.Value(u32).init(1);

        pub fn init(
            server: *Server,
            gpa: std.mem.Allocator,
            num_tokens: usize,
            env_map: *std.process.EnvMap,
        ) !void {
            var pipe_path_buf: [128]u8 = undefined;
            const pipe_path = std.fmt.bufPrintSentinel(
                &pipe_path_buf,
                "\\\\.\\pipe\\zig-jobserver-{d}-{d}",
                .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
                0,
            ) catch unreachable;
            try env_map.put("JOBSERVER_NAMEDPIPE", pipe_path);

            var nt_path_buf: [128]u16 = undefined;
            const nt_path_len = std.unicode.wtf8ToWtf16Le(&nt_path_buf, pipe_path) catch unreachable;
            nt_path_buf[0..4].* = .{ '\\', '?', '?', '\\' };
            nt_path_buf[nt_path_len] = 0;
            const nt_path = nt_path_buf[0..nt_path_len :0];

            server.tokens = try gpa.alloc(Token, num_tokens);
            errdefer gpa.free(server.tokens);

            var tokens_len: usize = 0;
            errdefer for (server.tokens[0..tokens_len]) |token| {
                _ = windows.ntdll.NtClose(token.handle);
            };
            for (server.tokens) |*token| {
                token.* = .{
                    .handle = handle: {
                        var handle: windows.HANDLE = undefined;
                        var path: windows.UNICODE_STRING = .{
                            .Buffer = nt_path.ptr,
                            .Length = @intCast(@sizeOf(u16) * nt_path.len),
                            .MaximumLength = 0,
                        };
                        var iosb: windows.IO_STATUS_BLOCK = undefined;
                        switch (windows.ntdll.NtCreateNamedPipeFile(
                            &handle,
                            windows.GENERIC_READ | windows.SYNCHRONIZE,
                            &.{
                                .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
                                .RootDirectory = null,
                                .ObjectName = &path,
                                .Attributes = 0,
                                .SecurityDescriptor = null,
                                .SecurityQualityOfService = null,
                            },
                            &iosb,
                            windows.FILE_SHARE_WRITE,
                            windows.FILE_OPEN_IF,
                            0,
                            windows.FILE_PIPE_BYTE_STREAM_TYPE,
                            windows.FILE_PIPE_BYTE_STREAM_MODE,
                            windows.FILE_PIPE_QUEUE_OPERATION,
                            @intCast(num_tokens),
                            0,
                            0,
                            &((-120 * std.time.ns_per_s) / 100),
                        )) {
                            .SUCCESS => {},
                            else => |rc| return windows.unexpectedStatus(rc),
                        }
                        break :handle handle;
                    },
                    .iosb = .{ .u = .{ .Status = .SUCCESS }, .Information = 0 },
                };
                tokens_len += 1;
            }

            switch (windows.ntdll.NtCreateEvent(
                &server.done,
                windows.EVENT_ALL_ACCESS,
                null,
                .Notification,
                windows.FALSE,
            )) {
                .SUCCESS => {},
                else => |err| @panic(@tagName(err)),
            }
            errdefer _ = windows.ntdll.NtClose(server.done);

            var ready: std.Thread.ResetEvent = .unset;
            server.thread = try .spawn(.{}, run, .{ server, &ready });
            ready.wait();
        }

        pub fn deinit(server: *Server, gpa: std.mem.Allocator) void {
            _ = windows.ntdll.NtSetEvent(server.done, null);
            server.thread.join();
            _ = windows.ntdll.NtClose(server.done);
            for (server.tokens) |token| _ = windows.ntdll.NtClose(token.handle);
            gpa.free(server.tokens);
            server.* = undefined;
        }

        fn run(server: *Server, ready: *std.Thread.ResetEvent) void {
            for (server.tokens) |*token| waitForConnect(token, &token.iosb, 0);
            ready.set();
            while (true) switch (windows.ntdll.NtWaitForSingleObject(
                server.done,
                windows.TRUE,
                null,
            )) {
                windows.NTSTATUS.ABANDONED_WAIT_0 => unreachable, // not a mutex
                .USER_APC => continue,
                windows.NTSTATUS.WAIT_0 => return,
                .TIMEOUT => unreachable, // no timeout
                else => |err| @panic(@tagName(err)),
            };
        }

        fn waitForConnect(
            ctx: ?*anyopaque,
            iosb: *windows.IO_STATUS_BLOCK,
            _: windows.ULONG,
        ) callconv(.c) void {
            const token: *Token = @ptrCast(@alignCast(ctx));
            std.debug.assert(iosb.u.Status == .SUCCESS);
            windows.DeviceIoControl(token.handle, windows.FSCTL.PIPE.LISTEN, .{
                .apc_routine = &waitForBrokenPipe,
                .apc_context = token,
                .io_status_block = &token.iosb,
            }) catch |err| switch (err) {
                error.Pending => return,
                else => @panic(@errorName(err)),
            };
            switch (windows.ntdll.NtQueueApcThread(
                windows.GetCurrentThread(),
                &waitForBrokenPipe,
                token,
                null,
                null,
            )) {
                .SUCCESS => {},
                else => |err| @panic(@tagName(err)),
            }
        }

        fn waitForBrokenPipe(
            ctx: ?*anyopaque,
            iosb: *windows.IO_STATUS_BLOCK,
            _: windows.ULONG,
        ) callconv(.c) void {
            const token: *Token = @ptrCast(@alignCast(ctx));
            std.debug.assert(iosb.u.Status == .SUCCESS);
            var buf: [1]u8 = undefined;
            switch (windows.ntdll.NtReadFile(
                token.handle,
                null,
                &waitForDisconnect,
                token,
                &token.iosb,
                &buf,
                buf.len,
                null,
                null,
            )) {
                .SUCCESS => unreachable, // clients do not have write permissions
                .PENDING => return,
                .PIPE_BROKEN => {},
                else => |err| @panic(@tagName(err)),
            }
            switch (windows.ntdll.NtQueueApcThread(
                windows.GetCurrentThread(),
                &waitForConnect,
                token,
                &token.iosb,
                null,
            )) {
                .SUCCESS => {},
                else => |err| @panic(@tagName(err)),
            }
        }

        fn waitForDisconnect(
            ctx: ?*anyopaque,
            iosb: *windows.IO_STATUS_BLOCK,
            _: windows.ULONG,
        ) callconv(.c) void {
            const token: *Token = @ptrCast(@alignCast(ctx));
            std.debug.assert(iosb.u.Status == .PIPE_BROKEN);
            windows.DeviceIoControl(token.handle, windows.FSCTL.PIPE.DISCONNECT, .{
                .apc_routine = &waitForConnect,
                .apc_context = token,
                .io_status_block = &token.iosb,
            }) catch |err| switch (err) {
                error.Pending => return,
                else => @panic(@errorName(err)),
            };
            switch (windows.ntdll.NtQueueApcThread(
                windows.GetCurrentThread(),
                &waitForConnect,
                token,
                &token.iosb,
                null,
            )) {
                .SUCCESS => {},
                else => |err| @panic(@tagName(err)),
            }
        }
    },
};

pub const Client = switch (builtin.os.tag) {
    else => struct {
        sem_id: c_int,

        pub const Permit = struct {
            sem_id: c_int,

            pub fn release(permit: Permit) void {
                modifySemaphore(permit.sem_id, 1);
            }
        };

        pub fn init() !Client {
            return .{
                .sem_id = try std.fmt.parseInt(
                    c_int,
                    posix.getenv("JOBSERVER_SEMID") orelse return error.NoJobServer,
                    10,
                ),
            };
        }

        pub fn deinit(client: *Client) void {
            client.* = undefined;
        }

        pub fn acquire(client: Client) !Permit {
            modifySemaphore(client.sem_id, -1);
            return .{ .sem_id = client.sem_id };
        }

        /// `semop(sem_id, &.{.{ .sem_num = 0, .sem_op = delta, .sem_flg = SEM_UNDO }})`
        fn modifySemaphore(id: c_int, delta: c_short) void {
            // Defined by Linux in `include/uapi/linux/sem.h`.
            const sembuf = extern struct {
                sem_num: c_ushort,
                sem_op: c_short,
                sem_flg: c_short,
            };
            const SEM_UNDO = 0x1000;
            var buf: sembuf = .{
                .sem_num = 0,
                .sem_op = delta,
                .sem_flg = SEM_UNDO,
            };
            const res = std.os.linux.syscall3(.semop, @intCast(id), @intFromPtr(&buf), 1);
            switch (std.posix.errno(res)) {
                .SUCCESS => {},
                else => |e| std.process.fatal("semop failed: {t}", .{e}),
            }
        }
    },
    .windows => struct {
        pipe_device: windows.HANDLE,

        pub const Permit = struct {
            named_pipe_handle: windows.HANDLE,

            pub fn release(permit: Permit) void {
                windows.CloseHandle(permit.named_pipe_handle);
            }
        };

        pub fn init() !Client {
            var client: Client = .{
                .pipe_device = try windows.OpenFile(
                    std.unicode.wtf8ToWtf16LeStringLiteral("\\DosDevices\\pipe\\"),
                    .{
                        .access_mask = windows.SYNCHRONIZE | windows.FILE_READ_ATTRIBUTES,
                        .share_access = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
                        .creation = windows.FILE_OPEN,
                    },
                ),
            };
            errdefer client.deinit();
            return client;
        }

        pub fn deinit(client: *Client) void {
            _ = windows.ntdll.NtClose(client.pipe_device);
            client.* = undefined;
        }

        pub fn acquire(client: Client) !Permit {
            const path = std.process.getenvW(
                std.unicode.wtf8ToWtf16LeStringLiteral("JOBSERVER_NAMEDPIPE"),
            ) orelse return error.NoJobServer;
            var nt_path_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
            const nt_path = nt_path_buf[0..path.len];
            nt_path[0..4].* = .{ '\\', '?', '?', '\\' };
            @memcpy(nt_path[4..], path[4..]);
            const nt_basename = nt_path[std.mem.findLastAny(
                u16,
                nt_path,
                std.unicode.wtf8ToWtf16LeStringLiteral(
                    std.fs.path.sep_str_windows ++ std.fs.path.sep_str_posix,
                ),
            ).? + 1 ..];
            const handle = while (true) {
                break windows.OpenFile(nt_path, .{
                    .access_mask = windows.SYNCHRONIZE,
                    .creation = windows.FILE_OPEN,
                    .share_access = 0,
                }) catch |err| switch (err) {
                    error.NoDevice => {
                        const fpwfb: windows.FILE_PIPE_WAIT_FOR_BUFFER = .init(
                            nt_basename,
                            windows.FILE_PIPE_WAIT_FOR_BUFFER.WAIT_FOREVER,
                        );
                        try windows.DeviceIoControl(
                            client.pipe_device,
                            windows.FSCTL.PIPE.WAIT,
                            .{ .in = fpwfb.toBuffer() },
                        );
                        continue;
                    },
                    else => return err,
                };
            };
            return .{ .named_pipe_handle = handle };
        }
    },
};

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
