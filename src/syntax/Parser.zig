const std = @import("std");
const types = @import("types.zig");

const Parser = @This();

const ParseFrame = struct {
    pos: u64 = 0,
    line: u64 = 1,
    col: u64 = 1,
};

const ParseError = error{
    NoMoreFrames,
    Canceled,
    AccessDenied,
    Unexpected,
    EndOfStream,
    Unseekable,
    ReadFailed,
    OutOfMemory,
};

fn ParseResult(comptime T: type) type {
    return ParseError!union(enum) {
        success: T,
        failure: []const u8,
    };
}

allocator: std.mem.Allocator,
reader: std.Io.File.Reader,

frames: std.ArrayList(ParseFrame) = .empty,
buffer: std.ArrayList(u8) = .empty,

fn save(self: *Parser) ParseError!void {
    const last = self.frames.getLastOrNull() orelse return error.NoMoreFrames;
    try self.frames.append(self.allocator, last);
}

fn discard(self: *Parser) ParseError!void {
    _ = self.frames.pop() orelse return error.NoMoreFrames;
    try self.reader.seekTo((self.frames.getLastOrNull() orelse return error.NoMoreFrames).pos);
}

fn merge(self: *Parser) ParseError!void {
    const last = self.frames.pop() orelse return error.NoMoreFrames;
    self.frames.items[self.frames.items.len - 1].pos = last.pos;
}

fn parseChars(self: *Parser, dst: []u8) ParseError!void {
    try self.reader.interface.readSliceAll(dst);

    const last_ptr = &self.frames.items[self.frames.items.len - 1];
    var line = last_ptr.line;
    var col = last_ptr.col;

    for (dst) |c| {
        switch (c) {
            '\r' => {},
            '\n' => {
                line += 1;
                col = 1;
            },
            else => col += 1,
        }
    }

    // std.debug.print("line: {}, col: {}\n", .{ line, col });
    last_ptr.pos += dst.len;
    last_ptr.line = line;
    last_ptr.col = col;
}

fn parseLiteral(self: *Parser, comptime lit: []const u8) ParseResult(void) {
    var buf: [lit.len]u8 = undefined;
    try parseChars(self, &buf);
    if (std.mem.eql(u8, &buf, lit)) {
        return .success;
    } else {
        return .{ .failure = "Expected literal '" ++ lit ++ "'" };
    }
}

fn parseRange(self: *Parser, range: []const [2]u8) ParseResult([]const u8) {
    var buffer: std.ArrayList(u8) = .empty;
    while (true) {
        var c: u8 = undefined;
        self.parseChars((&c)[0..1]) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const matches = for (range) |r| {
            if (c >= r[0] and c <= r[1]) {
                break true;
            }
        } else false;
        if (!matches) {
            try self.reader.seekBy(-1);
            break;
        }
        try buffer.append(self.allocator, c);
    }
    return .{ .success = buffer.items };
}

fn parseName(self: *Parser) ParseResult([]const u8) {
    const first = (try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' } })).success;
    if (first.len == 0) {
        return .{ .failure = "Failed to parse name" };
    }
    const rest = (try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ '0', '9' } })).success;
    return .{ .success = try std.mem.concat(self.allocator, u8, &.{ first, rest }) };
}

fn parseWhitespace(self: *Parser, comptime min_length: usize) ParseResult(void) {
    const ws = (try self.parseRange(&[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\r', '\r' }, .{ '\n', '\n' } })).success;
    if (ws.len < min_length) {
        return .{ .failure = "Failed to parse enough whitespace (" ++ std.fmt.comptimePrint("{}", .{min_length}) ++ ")" };
    }
    return .success;
}

fn OpResultType(op: anytype) type {
    return @typeInfo(@TypeOf(op)).@"fn".return_type.?;
}

fn OpSuccessType(op: anytype) type {
    return @typeInfo(@typeInfo(OpResultType(op)).error_union.payload).@"union".fields[0].type;
}

fn invoke(self: *Parser, op: anytype, arg: anytype) OpResultType(op) {
    return switch (@typeInfo(@TypeOf(op)).@"fn".params.len) {
        1 => op(self),
        2 => op(self, arg),
        else => @compileError("Can only handle 0-1 args for now."),
    };
}

fn parseRepeated(self: *Parser, op: anytype, arg: anytype) ParseResult([]OpSuccessType(op)) {
    var list = std.ArrayList(OpSuccessType(op)).empty;
    while (true) {
        try self.save();
        const elem = try self.invoke(op, arg);
        switch (elem) {
            .success => |value| {
                try self.merge();
                try list.append(self.allocator, value);
            },
            .failure => {
                try self.discard();
                break;
            },
        }
    }
    return .{ .success = list.items };
}

fn parseOptional(self: *Parser, op: anytype, arg: anytype) ParseResult(?OpSuccessType(op)) {
    self.save();
    return switch (try self.invoke(op, arg)) {
        .success => |value| blk: {
            self.merge();
            break :blk value;
        },
        .failure => blk: {
            self.discard();
            break :blk null;
        },
    };
}

fn parseItem(self: *Parser, op: anytype, arg: anytype) ParseResult(OpSuccessType(op)) {
    const result = try self.invoke(op, arg);
    switch (result) {
        .success => {},
        .failure => |value| return .{ .failure = value },
    }
    _ = try self.parseWhitespace(0);
    switch (try self.parseLiteral(",")) {
        .success => {},
        .failure => |value| return .{ .failure = value },
    }
    _ = try self.parseWhitespace(0);
    return result;
}

fn parseListed(self: *Parser, op: anytype, arg: anytype) ParseResult([]OpSuccessType(op)) {
    _ = try self.parseWhitespace(0);
    const result = self.parseRepeated(parseItem, arg);
    switch (result) {
        .success => {},
        .failure => |value| return .{ .failure = value },
    }
    return result;
}

pub fn parseScript(self: *Parser) ParseResult(types.Script) {
    try self.frames.append(self.allocator, .{});

    outer: while (true) {
        const result = try self.parseListed(parseName, .{});
        switch (result) {
            .success => |value| {
                for (value) |name| {
                    std.debug.print("{s} ", .{name});
                }
                std.debug.print("\n", .{});
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
        const ws = try self.parseWhitespace(1);
        switch (ws) {
            .success => {},
            .failure => break,
        }
    }

    return .{ .success = undefined };
}
