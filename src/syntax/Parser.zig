const std = @import("std");

fn ParseResult(comptime T: type) type {
    return union(enum) { success: T, failure: struct {
        reason: []const u8,
        line: u64 = 0,
    } };
}

allocator: std.mem.Allocator,
reader: std.Io.File.Reader,

checkpoints: std.ArrayList(u64) = .empty,
buffer: std.ArrayList(u8) = .empty,

fn save(self: *@This()) !void {
    try self.checkpoints.append(self.allocator, self.reader.logicalPos());
}

fn restore(self: *@This()) !void {
    const pos = self.checkpoints.pop();
    if (pos) |p| {
        try self.reader.seekTo(p);
    } else {
        unreachable;
    }
}

// fn parseLiteral(self: *@This(), literal: []const u8) !ParseResult(void) {
//     try self.save();
//     self.reader.interface.readSliceAll(self.nameBuffer[0..literal.len]) catch |err| {
//         if (err == .EndOfStream) {
//             try self.restore();
//             return false;
//         } else {
//             return err;
//         }
//     };
//     if (std.mem.eql(u8, self.nameBuffer[0..literal.len], literal)) {
//         return true;
//     } else {
//         try self.restore();
//         return false;
//     }
// }

fn parseRange(self: *@This(), comptime range: []const [2]u8) ![]const u8 {
    var buffer: std.ArrayList(u8) = .empty;
    while (true) {
        const c = self.reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const matches = for (range) |r| {
            if (c >= r[0] and c <= r[1]) break true;
        } else false;
        if (!matches) {
            try self.reader.seekBy(-1);
            break;
        }
        try buffer.append(self.allocator, c);
    }
    return buffer.items;
}

fn parseName(self: *@This()) !ParseResult([]const u8) {
    const first = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' } });
    if (first.len == 0) {
        return .{ .failure = .{ .reason = "Failed to parse name" } };
    }
    const rest = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ '0', '9' } });
    return .{ .success = try std.mem.concat(self.allocator, u8, &.{ first, rest }) };
}

fn consumeWhitespace(self: *@This()) !void {
    _ = try self.parseRange(&[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\r', '\r' }, .{ '\n', '\n' } });
}

pub fn parseTopLevel(self: *@This()) !ParseResult(void) {
    outer: while (true) {
        try self.consumeWhitespace();
        const result = try self.parseName();
        switch (result) {
            .success => |value| {
                std.debug.print("{s}\n", .{value});
            },
            .failure => |failure| {
                std.debug.print(
                    "parse failure: {s} at line {}\n",
                    .{ failure.reason, failure.line },
                );
                break :outer;
            },
        }
    }
    return ParseResult(void){ .success = {} };
}
