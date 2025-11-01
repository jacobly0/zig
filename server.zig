pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const num_tokens = 2; // for a simple example. in reality, set this to the core count or something.

    var env = try std.process.getEnvMap(arena);
    var server: Server = undefined;
    try server.init(arena, num_tokens, &env);
    defer server.deinit(arena);

    var children: [8]std.process.Child = undefined;
    for (&children, 0..) |*c, child_num| {
        const child_num_str = try std.fmt.allocPrint(arena, "{d}", .{child_num});
        const argv = try arena.dupe([]const u8, &.{ switch (builtin.os.tag) {
            else => "./worker",
            .windows => ".\\worker.exe",
        }, child_num_str });
        c.* = .init(argv, arena);
        c.env_map = &env;
    }

    std.log.info("Spawning {d} workers ({d} available job tokens)", .{ children.len, num_tokens });
    for (&children) |*c| try c.spawn();
    for (&children) |*c| _ = try c.wait();
    std.log.info("All {d} workers exited", .{children.len});
}

const builtin = @import("builtin");
const Server = std.Io.jobserver.Server;
const std = @import("std");
