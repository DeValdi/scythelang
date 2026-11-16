const std = @import("std");
const Parser = @import("syntax/Parser.zig");
const Synthesizer = @import("synthesis/Synthesizer.zig");
const util = @import("syntax/util.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    const source = try stdin.interface.allocRemaining(gpa, .unlimited);

    var parser = Parser.init(gpa, source);

    const ast = try parser.parseAbstractSyntaxTree();
    switch (ast) {
        .success => |value| util.dump(value),
        .failure => |value| {
            std.debug.print("error: {s}\n", .{value});
            std.process.exit(1);
        },
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const synth = try Synthesizer.init(gpa, 0, "   ", "\n");
    try synth.synthesize(stdout, &ast.success);

    try stdout.flush();
}

test "trivial pass" {
    _ = Parser; // pulls in the tests of Parser.zig
    try std.testing.expect(true);
}
