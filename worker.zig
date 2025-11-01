pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var threaded: std.Io.Threaded = .init(arena);
    defer threaded.deinit();
    const io = threaded.io();

    const args = try std.process.argsAlloc(arena);
    const proc_num_str = args[1];
    const proc_num = try std.fmt.parseInt(usize, proc_num_str, 10);

    var client: Client = try .init();
    defer client.deinit();

    // Give threads a variable work time, 400--800ms.
    var rng: std.Random.DefaultPrng = .init(0);
    const r = rng.random();
    const work_0: std.Io.Duration = .fromMilliseconds(r.intRangeAtMost(u32, 400, 800));
    const work_1: std.Io.Duration = .fromMilliseconds(r.intRangeAtMost(u32, 400, 800));
    const work_2: std.Io.Duration = .fromMilliseconds(r.intRangeAtMost(u32, 400, 800));
    const work_3: std.Io.Duration = .fromMilliseconds(r.intRangeAtMost(u32, 400, 800));

    var f0 = try io.concurrent(worker, .{ io, &client, proc_num, 0, &work_0 });
    defer f0.cancel(io) catch {};
    var f1 = try io.concurrent(worker, .{ io, &client, proc_num, 1, &work_1 });
    defer f1.cancel(io) catch {};
    var f2 = try io.concurrent(worker, .{ io, &client, proc_num, 2, &work_2 });
    defer f2.cancel(io) catch {};
    var f3 = try io.concurrent(worker, .{ io, &client, proc_num, 3, &work_3 });
    defer f3.cancel(io) catch {};

    try f0.await(io);
    try f1.await(io);
    try f2.await(io);
    try f3.await(io);
}

fn worker(io: std.Io, client: *Client, proc_num: usize, thread_num: usize, work: *const std.Io.Duration) !void {
    const permit = try client.acquire();
    defer permit.release();

    std.log.info("start {d}:{d}", .{ proc_num, thread_num });
    defer std.log.info("stop {d}:{d}", .{ proc_num, thread_num });

    // All the threads do work for some amount of time...
    try io.sleep(work.*, .awake);

    if (thread_num == 3) {
        // But the code running on thread 3 ends up crashing!
        std.log.info("CRASH {d}", .{proc_num});
        std.posix.exit(1);
    }
}

const Client = std.Io.jobserver.Client;
const std = @import("std");
