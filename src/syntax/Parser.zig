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

gpa: std.mem.Allocator,
reader: std.Io.File.Reader,

frames: std.ArrayList(ParseFrame) = .empty,
buffer: std.ArrayList(u8) = .empty,

fn save(self: *Parser) ParseError!void {
    const last = self.frames.getLastOrNull() orelse return error.NoMoreFrames;
    try self.frames.append(self.gpa, last);
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

fn parseRange(self: *Parser, range: []const [2]u8, comptime collect: bool) ParseResult(if (collect) []u8 else usize) {
    var list = std.ArrayList(u8).empty;
    var i: usize = 0;
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
        if (collect) {
            try list.append(self.gpa, c);
        } else {
            i += 1;
        }
    }
    return .{ .success = if (collect) list.items else i };
}

fn parseName(self: *Parser) ParseResult([]u8) {
    const head = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' } }, true);
    switch (head) {
        .success => {},
        .failure => return head,
    }
    if (head.success.len == 0) {
        return .{ .failure = "Failed to parse name" };
    }
    const rest = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ '0', '9' } }, true);
    switch (rest) {
        .success => {},
        .failure => return rest,
    }
    return .{ .success = try std.mem.concat(self.gpa, u8, &.{ head.success, rest.success }) };
}

fn parseWhitespace(self: *Parser, comptime min_length: usize) ParseResult(void) {
    const ws = (try self.parseRange(&[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\r', '\r' }, .{ '\n', '\n' } }, false)).success;
    if (ws < min_length) {
        return .{ .failure = "Failed to parse enough whitespace (" ++ std.fmt.comptimePrint("{}", .{min_length}) ++ ")" };
    }
    return .success;
}

fn invoke(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult(T) {
    return @call(.auto, op, .{self} ++ args);
}

fn parseRepeated(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult([]T) {
    var list = std.ArrayList(T).empty;
    while (true) {
        try self.save();
        const elem = try self.invoke(op, args, T);
        switch (elem) {
            .success => |value| {
                try self.merge();
                try list.append(self.gpa, value);
            },
            .failure => {
                try self.discard();
                break;
            },
        }
    }
    return .{ .success = list.items };
}

fn parseOptional(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult(?T) {
    self.save();
    return switch (try self.invoke(op, args)) {
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

fn parseItem(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult(T) {
    const result = try self.invoke(op, args, T);
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

fn parseListed(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult([]T) {
    _ = try self.parseWhitespace(0);
    const result = try self.parseRepeated(parseItem, .{ op, args, T }, T);
    switch (result) {
        .success => {},
        .failure => |value| return .{ .failure = value },
    }
    return result;
}

pub fn parseScript(self: *Parser) ParseResult(types.Script) {
    try self.frames.append(self.gpa, .{});

    outer: while (true) {
        const result = try self.parseListed(parseName, .{}, []u8);
        switch (result) {
            .success => |value| {
                for (value) |n| {
                    std.debug.print("|{s}", .{n});
                }
                std.debug.print("|\n", .{});
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
