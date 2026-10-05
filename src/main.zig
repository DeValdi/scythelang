const std = @import("std");
const Parser = @import("syntax/Parser.zig");

pub fn main(init: std.process.Init) !void {
    std.debug.print("Hello World!\n", .{});

    const allocator = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(allocator);
    _ = args.next();
    const path = args.next() orelse return error.MissingFile;

    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var parser = Parser{ .allocator = allocator, .reader = file.reader(io, buffer[0..]) };
    _ = try parser.parseTopLevel();
}
