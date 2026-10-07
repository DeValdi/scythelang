const std = @import("std");
const types = @import("types.zig");

const Parser = @This();

fn ParseResult(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: []const u8,
    };
}

fn ParseOp(options: struct { TRes: type, TArg0: type = void, TArg1: type = void }) type {
    return union(enum) { no_arg: fn (parser: Parser) options.TRes, one_arg: struct {
        func: fn (parser: Parser, arg: options.TArg0) options.TRes,
        arg: options.TArg0,

        pub fn invoke(self: *@This(), parser: Parser) options.TRes {
            return self.func(parser, self.arg);
        }
    }, two_arg: struct {
        func: fn (parser: Parser, arg0: options.TArg0, arg1: options.TArg1) options.TRes,
        arg0: options.Targ0,
        arg1: options.TArg1,

        pub fn invoke(self: *@This(), parser: Parser) options.TRes {
            return self.func(parser, self.arg0, self.arg1);
        }
    } };
}

const ParseFrame = struct {
    start: u64 = 0,
    line: u64 = 1,
    col: u64 = 1,
};

allocator: std.mem.Allocator,
reader: std.Io.File.Reader,

frames: std.ArrayList(ParseFrame) = .empty,
buffer: std.ArrayList(u8) = .empty,

fn save(self: *Parser) !void {
    const last = self.frames.getLastOrNull() orelse return error.NoMoreFrames;
    try self.frames.append(self.allocator, .{
        .start = self.reader.logicalPos(),
        .line = last.line,
        .col = last.col,
    });
}

fn restore(self: *Parser) !void {
    const frame = self.frames.pop();
    if (frame) |p| {
        try self.reader.seekTo(p);
    } else {
        return error.NoMoreFrames;
    }
}

// fn parseLiteral(self: *Parser, literal: []const u8) !ParseResult(void) {
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

fn parseRange(self: *Parser, comptime range: []const [2]u8) ![]const u8 {
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
    const last_ptr = &self.frames.items[self.frames.items.len - 1];
    var line = last_ptr.line;
    var col = last_ptr.col;
    for (buffer.items) |c| {
        switch (c) {
            '\r' => {},
            '\n' => {
                line += 1;
                col = 1;
            },
            else => col += 1,
        }
    }
    std.debug.print("line: {}, col: {}\n", .{ line, col });
    last_ptr.line = line;
    last_ptr.col = col;
    return buffer.items;
}

fn parseName(self: *Parser) !ParseResult([]const u8) {
    const first = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' } });
    if (first.len == 0) {
        return .{ .failure = "Failed to parse name" };
    }
    const rest = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ '0', '9' } });
    return .{ .success = try std.mem.concat(self.allocator, u8, &.{ first, rest }) };
}

fn consumeWhitespace(self: *Parser) !ParseResult(void) {
    const ws = try self.parseRange(&[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\r', '\r' }, .{ '\n', '\n' } });
    if (ws.len == 0) {
        return .{ .failure = "Failed to parse whitespace" };
    }
    return .success;
}

pub fn parseScript(self: *Parser) !ParseResult(types.Script) {
    try self.frames.append(self.allocator, .{});
    outer: while (true) {
        _ = try self.consumeWhitespace();
        const result = try self.parseName();
        switch (result) {
            .success => |value| {
                std.debug.print("{s}\n", .{value});
            },
            .failure => |failure| {
                const last_frame = self.frames.getLastOrNull() orelse return error.NoMoreFrames;
                std.debug.print(
                    "Parse failure: {s} at line {}, column {}\n",
                    .{ failure, last_frame.line, last_frame.col },
                );
                break :outer;
            },
        }
    }
    return .{ .success = undefined };
}
