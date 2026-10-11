const std = @import("std");
const types = @import("types.zig");

const Parser = @This();

const ParseFrame = struct {
    start: u64 = 0,
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

fn ParseCombiner(comptime TArg0: type, comptime TArg1: type, comptime TRes: type) type {
    return struct {
        const Arg0Type = TArg0;
        const Arg1Type = TArg1;
        const ResType = TRes;
        combine: *const fn (parser: *Parser, arg0: TArg0, arg1: TArg1) ParseError!TRes,
    };
}

fn ParseOp(comptime TArg: type, comptime TRes: type) type {
    return struct {
        const ArgType = TArg;
        const ResType = TRes;

        func: switch (TArg) {
            void => *const fn (*Parser) ParseResult(TRes),
            else => *const fn (*Parser, TArg) ParseResult(TRes),
        },
        arg: TArg = undefined,

        pub fn parse(self: @This(), parser: *Parser) ParseResult(TRes) {
            return switch (TArg) {
                void => self.func(parser),
                else => self.func(parser, self.arg),
            };
        }

        fn repeated(self: @This()) ParseOp(@TypeOf(self), []TRes) {
            return ParseOp(@TypeOf(self), []TRes){
                .func = struct {
                    fn func(parser: *Parser, arg: TArg) ParseResult([]TRes) {
                        var list = std.ArrayList(TRes).empty;
                        while (true) {
                            const elem = try arg.parse(parser);
                            switch (elem) {
                                .success => |value| try list.append(parser.allocator, value),
                                .failure => break,
                            }
                        }
                        return .{ .success = list.items };
                    }
                }.func,
                .arg = self,
            };
        }

        fn optional(self: @This()) ParseOp(@TypeOf(self), ?TRes) {
            return ParseOp(@TypeOf(self), ?TRes){
                .func = struct {
                    fn func(parser: *Parser, arg: TArg) ParseResult(?TRes) {
                        return .{
                            .success = switch (try arg.parse(parser)) {
                                .success => |value| value,
                                .failure => null,
                            },
                        };
                    }
                }.func,
                .arg = self,
            };
        }

        fn TBoth(comptime TInner0: type, comptime TInner1: type) type {
            return struct {
                inner0: TInner0,
                inner1: TInner1,
            };
        }

        fn prefixed(self: @This(), other: anytype) ParseOp(
            TBoth(
                @TypeOf(other),
                @TypeOf(self),
            ),
            TRes,
        ) {
            return ParseOp(TBoth(@TypeOf(other), @TypeOf(self)), TRes){
                .func = struct {
                    fn func(parser: *Parser, arg: TBoth(@TypeOf(other), @TypeOf(self))) ParseResult(TRes) {
                        const result0 = try arg.inner0.parse(parser);
                        return switch (result0) {
                            .success => arg.inner1.parse(parser),
                            .failure => |reason| .{ .failure = reason },
                        };
                    }
                }.func,
                .arg = .{
                    .inner0 = other,
                    .inner1 = self,
                },
            };
        }

        fn suffixed(self: @This(), other: anytype) ParseOp(
            TBoth(
                @TypeOf(self),
                @TypeOf(other),
            ),
            TRes,
        ) {
            return ParseOp(TBoth(@TypeOf(self), @TypeOf(other)), TRes){
                .func = struct {
                    fn func(parser: *Parser, arg: TBoth(@TypeOf(self), @TypeOf(other))) ParseResult(TRes) {
                        const result0 = try arg.inner0.parse(parser);
                        return switch (result0) {
                            .success => {
                                const result1 = try arg.inner1.parse(parser);
                                return switch (result1) {
                                    .success => result0,
                                    .failure => |reason| .{ .failure = reason },
                                };
                            },
                            .failure => result0,
                        };
                    }
                }.func,
                .arg = .{
                    .inner0 = self,
                    .inner1 = other,
                },
            };
        }

        fn TOp(comptime TInner0: type, comptime TInner1: type, comptime TResComb: type) type {
            return struct {
                inner0: TInner0,
                inner1: TInner1,
                combiner: ParseCombiner(TInner0, TInner1, TResComb),
            };
        }

        fn andThen(self: @This(), other: anytype, combiner: anytype) ParseOp(
            TOp(
                TRes,
                other.ResType,
                combiner.ResType,
            ),
            combiner.ResType,
        ) {
            return ParseOp(TOp(TRes, other.ResType, combiner.ResType), combiner.ResType){
                .func = struct {
                    fn func(parser: *Parser, arg: TOp(TRes, other.ResType, combiner.ResType)) ParseResult(combiner.ResType) {
                        const result0 = try arg.inner0.parse(parser);
                        return switch (result0) {
                            .success => |value0| {
                                const result1 = try arg.inner1.parse(parser);
                                return switch (result1) {
                                    .success => |value1| .{ .success = try arg.combiner(parser, value0, value1) },
                                    .failure => |reason| .{ .failure = reason },
                                };
                            },
                            .failure => |reason| .{ .failure = reason },
                        };
                    }
                }.func,
                .arg = .{
                    .inner0 = self,
                    .inner1 = other,
                    .combiner = combiner,
                },
            };
        }

        fn listed(self: @This()) void {
            const ws = ParseOp(usize, void){
                .func = parseWhitespace,
                .arg = 0,
            };

            var elem0 = self.suffixed(ws);

            // const rep = elem.suffixed(ParseOp([]const [2]u8, []const u8){
            //     .func = parseRange,
            //     .arg = &[_][2]u8{.{ ',', ',' }},
            // }).repeated();

            //     const joined = rep.andThen(TRes, elem, []TRes, struct {
            //         fn combiner(p: *Parser, a: []TRes, b: TRes) ParseError![]TRes {
            //             const extended = try p.allocator.alloc(TRes, a.len + 1);
            //             extended[a.len] = b;
            //             return extended;
            //         }
            //     }.combiner);

            return;
        }
    };
}

allocator: std.mem.Allocator,
reader: std.Io.File.Reader,

frames: std.ArrayList(ParseFrame) = .empty,
buffer: std.ArrayList(u8) = .empty,

fn save(self: *Parser) ParseError!void {
    const last = self.frames.getLastOrNull() orelse return error.NoMoreFrames;
    try self.frames.append(self.allocator, .{
        .start = self.reader.logicalPos(),
        .line = last.line,
        .col = last.col,
    });
}

fn restore(self: *Parser) ParseError!void {
    const frame = self.frames.pop();
    if (frame) |p| {
        try self.reader.seekTo(p);
    } else {
        return error.NoMoreFrames;
    }
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
    last_ptr.start += dst.len;
    last_ptr.line = line;
    last_ptr.col = col;
}

fn parseLiteral(self: *Parser, lit: []const u8) ParseResult(void) {
    var buf: []u8 = self.allocator.alloc(u8, lit.len);
    try parseChars(self, &buf);
    if (std.mem.eql(u8, &buf, lit)) {
        return .success;
    } else {
        return .{
            .failure = "Expected literal '" ++ lit ++ "'",
        };
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

fn parseWhitespace(self: *Parser, min_length: usize) ParseResult(void) {
    const ws = (try self.parseRange(&[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' }, .{ '\r', '\r' }, .{ '\n', '\n' } })).success;
    if (ws.len < min_length) {
        return .{ .failure = "Failed to parse enough whitespace" };
    }
    return .success;
}

pub fn parseScript(self: *Parser) ParseResult(types.Script) {
    try self.frames.append(self.allocator, .{});

    outer: while (true) {
        _ = try self.parseWhitespace(0);
        const result = try (ParseOp(void, []const u8){
            .func = parseName,
        }).listed().parse(self);
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
    }

    return .{ .success = undefined };
}
