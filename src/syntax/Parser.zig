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

fn parseText(self: *Parser, comptime text: []const u8) ParseResult(void) {
    var buf: [text.len]u8 = undefined;
    try parseChars(self, &buf);
    if (std.mem.eql(u8, &buf, text)) {
        return .success;
    } else {
        return .{ .failure = "Expected '" ++ text ++ "'" };
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

pub fn parseAbstractSyntaxTree(self: *Parser) ParseResult(types.AbstractSyntaxTree) {
    try self.frames.append(self.gpa, .{});
    return switch (self.parseLi)
}

fn parseAliasStmt(self: *Parser) ParseResult(types.AliasStmt) {}

fn parseArrayLit(self: *Parser) ParseResult(types.ArrayLit) {}

fn parseArrayType(self: *Parser) ParseResult(types.ArrayType) {}

fn parseAssignStmt(self: *Parser) ParseResult(types.AssignStmt) {}

fn parseBinOp(self: *Parser) ParseResult(types.BinOp) {}

fn parseBlockStmt(self: *Parser) ParseResult(types.BlockStmt) {}

fn parseBoolLit(self: *Parser) ParseResult(types.BoolLit) {}

fn parseBranch(self: *Parser) ParseResult(types.Branch) {}

fn parseBreakStmt(self: *Parser) ParseResult(types.BreakStmt) {}

fn parseCast(self: *Parser) ParseResult(types.Cast) {}

fn parseCharLit(self: *Parser) ParseResult(types.CharLit) {}

fn parseContinueStmt(self: *Parser) ParseResult(types.ContinueStmt) {}

fn parseElseBranch(self: *Parser) ParseResult(types.ElseBranch) {}

fn parseEnumDefn(self: *Parser) ParseResult(types.EnumDefn) {}

fn parseEnumLit(self: *Parser) ParseResult(types.EnumLit) {}

fn parseEnumMember(self: *Parser) ParseResult(types.EnumMember) {}

fn parseExportStmt(self: *Parser) ParseResult(types.ExportStmt) {}

fn parseExpr(self: *Parser) ParseResult(types.Expr) {}

fn parseFloatLit(self: *Parser) ParseResult(types.FloatLit) {}

fn parseFnCall(self: *Parser) ParseResult(types.FnCall) {}

fn parseFnDecl(self: *Parser) ParseResult(types.FnDecl) {}

fn parseFnDefn(self: *Parser) ParseResult(types.FnDefn) {}

fn parseFnSig(self: *Parser) ParseResult(types.FnSig) {}

fn parseForStmt(self: *Parser) ParseResult(types.ForStmt) {}

fn parseGlobalVarDecl(self: *Parser) ParseResult(types.GlobalVarDecl) {}

fn parseIfStmt(self: *Parser) ParseResult(types.IfStmt) {}

fn parseImportStmt(self: *Parser) ParseResult(types.ImportStmt) {}

fn parseIndex(self: *Parser) ParseResult(types.Index) {}

fn parseIntLit(self: *Parser) ParseResult(types.IntLit) {}

fn parseIntType(self: *Parser) ParseResult(types.IntType) {}

fn parseLambda(self: *Parser) ParseResult(types.Lambda) {}

fn parseLiteral(self: *Parser) ParseResult(types.Literal) {}

fn parseMacroDefn(self: *Parser) ParseResult(types.MacroDefn) {}

fn parseMember(self: *Parser) ParseResult(types.Member) {}

fn parsePointerType(self: *Parser) ParseResult(types.PointerType) {}

fn parsePrimary(self: *Parser) ParseResult(types.Primary) {}

fn parseReturnStmt(self: *Parser) ParseResult(types.ReturnStmt) {}

fn parseScope(self: *Parser) ParseResult(types.Scope) {}

fn parseStmt(self: *Parser) ParseResult(types.Stmt) {}

fn parseStringLit(self: *Parser) ParseResult(types.StringLit) {}

fn parseStructDefn(self: *Parser) ParseResult(types.StructDefn) {}

fn parseStructLit(self: *Parser) ParseResult(types.StructLit) {}

fn parseTopItem(self: *Parser) ParseResult(types.TopItem) {}

fn parseType(self: *Parser) ParseResult(types.Type) {}

fn parseTypeDecl(self: *Parser) ParseResult(types.TypeDecl) {}

fn parseTypeDefn(self: *Parser) ParseResult(types.TypeDefn) {}

fn parseTypeRef(self: *Parser) ParseResult(types.TypeRef) {}

fn parseUnionDefn(self: *Parser) ParseResult(types.UnionDefn) {}

fn parseUnionLit(self: *Parser) ParseResult(types.UnionLit) {}

fn parseUnOp(self: *Parser) ParseResult(types.UnOp) {}

fn parseValueRef(self: *Parser) ParseResult(types.ValueRef) {}

fn parseVarDecl(self: *Parser) ParseResult(types.VarDecl) {}

fn parseVarDefn(self: *Parser) ParseResult(types.VarDefn) {}

fn parseYieldStmt(self: *Parser) ParseResult(types.YieldStmt) {}
