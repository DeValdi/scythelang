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

fn restore(self: *Parser) ParseError!void {
    _ = self.frames.pop() orelse return error.NoMoreFrames;
    try self.reader.seekTo((self.frames.getLastOrNull() orelse return error.NoMoreFrames).pos);
}

fn merge(self: *Parser) ParseError!void {
    const last = self.frames.pop() orelse return error.NoMoreFrames;
    self.frames.items[self.frames.items.len - 1] = last;
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
    try self.save();
    parseChars(self, &buf) catch |err| switch (err) {
        error.EndOfStream => {
            try self.restore();
            return .{ .failure = "No '" ++ text ++ "'" };
        },
        else => return err,
    };
    if (std.mem.eql(u8, &buf, text)) {
        try self.merge();
        return .success;
    } else {
        try self.restore();
        return .{ .failure = "No '" ++ text ++ "'" };
    }
}

fn parseRange(self: *Parser, range: []const [2]u8, comptime collect: bool, limit: ?usize) ParseError!(if (collect) []u8 else usize) {
    var list = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (limit == null or (i < limit.?)) {
        try self.save();
        var c: u8 = undefined;
        self.parseChars((&c)[0..1]) catch |err| switch (err) {
            error.EndOfStream => {
                try self.restore();
                break;
            },
            else => return err,
        };
        const matches = for (range) |r| {
            if (c >= r[0] and c <= r[1]) {
                break true;
            }
        } else false;
        if (!matches) {
            try self.restore();
            break;
        }
        if (collect) {
            try list.append(self.gpa, c);
        }
        try self.merge();
        i += 1;
    }
    return if (collect) list.items else i;
}

fn parseSp(self: *Parser) ParseResult(void) {
    if ((try self.parseRange(&[_][2]u8{ .{ ' ', ' ' }, .{ '\t', '\t' } }, false, 1)) == 1) return .success;

    const dollar = &[_][2]u8{.{ '$', '$' }};

    try self.save();

    const comment_start = try self.parseRange(dollar, false, 1);
    if (comment_start == 0) {
        try self.restore();
        return .{ .failure = "No space / tab / comment start" };
    }

    _ = try self.parseRange(&[_][2]u8{ .{ 0, '$' - 1 }, .{ '$' + 1, 255 } }, false, null);

    const comment_end = try self.parseRange(dollar, false, 1);
    if (comment_end == 0) {
        try self.restore();
        return .{ .failure = "No comment end" };
    }

    try self.merge();
    return .success;
}

fn parseNl(self: *Parser) ParseResult(void) {
    return switch (try self.parseRange(&[_][2]u8{ .{ '\r', '\r' }, .{ '\n', '\n' } }, false, 1)) {
        1 => .success,
        else => .{ .failure = "No newline" },
    };
}

fn parseWs(self: *Parser) ParseResult(void) {
    return switch (try self.parseSp()) {
        .success => .success,
        .failure => switch (try self.parseNl()) {
            .success => .success,
            .failure => .{ .failure = "No space / newline" },
        },
    };
}

fn parseSep(self: *Parser) ParseResult(void) {
    while (true) if ((try self.parseWs()) == .failure) break;

    if ((try self.parseNl()) == .failure) return .{ .failure = "No newline in separator" };

    while (true) if ((try self.parseWs()) == .failure) break;

    return .success;
}

const keywords = [_][]const u8{
    "true",
    "false",
    "and",
    "or",
    "not",
    "fn",
    "extern",
    "import",
    "export",
    "break",
    "yield",
    "continue",
    "struct",
    "union",
    "enum",
    "smacro",
    "cmacro",
    "if",
    "elif",
    "else",
    "for",
    "return",
    "alias",
    "as",
    "unsigned",
    "char",
    "short",
    "int",
    "long",
    "float",
    "double",
    "void",
    "bool",
    "null",
};

fn parseValueName(self: *Parser) ParseResult([]u8) {
    const head = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ '_', '_' } }, true, 1);
    if (head.len == 0) return .{ .failure = "No value name start" };

    const rest = try self.parseRange(&[_][2]u8{ .{ 'a', 'z' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ '0', '9' } }, true, null);

    const combined = try std.mem.concat(self.gpa, u8, &.{ head, rest });
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw, combined)) return .{ .failure = "No non-keyword value name" };
    }

    return .{ .success = combined };
}

// fn invoke(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult(T) {
//     return @call(.auto, op, .{self} ++ args);
// }

// fn parseRepeated(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult([]T) {
//     var list = std.ArrayList(T).empty;
//     while (true) {
//         try self.save();
//         const elem = try self.invoke(op, args, T);
//         switch (elem) {
//             .success => |value| {
//                 try self.merge();
//                 try list.append(self.gpa, value);
//             },
//             .failure => {
//                 try self.discard();
//                 break;
//             },
//         }
//     }
//     return .{ .success = list.items };
// }

// fn parseOptional(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult(?T) {
//     self.save();
//     return switch (try self.invoke(op, args)) {
//         .success => |value| blk: {
//             self.merge();
//             break :blk value;
//         },
//         .failure => blk: {
//             self.discard();
//             break :blk null;
//         },
//     };
// }

// fn parseItem(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult(T) {
//     const result = try self.invoke(op, args, T);
//     if (result == .failure) {
//         return .{ .failure = result.failure };
//     }
//     _ = try self.parseWhitespace(0);
//     const comma = try self.parseLiteral(",");
//     if (comma == .failure) {
//         return .{ .failure = comma.failure };
//     }
//     _ = try self.parseWhitespace(0);
//     return result;
// }

// fn parseListed(self: *Parser, op: anytype, args: anytype, comptime T: type) ParseResult([]T) {
//     _ = try self.parseWhitespace(0);
//     const result = try self.parseRepeated(parseItem, .{ op, args, T }, T);
//     if (result == .failure) {
//         return .{ .failure = result.failure };
//     }
//     return result;
// }

fn parseUnion(self: *Parser, comptime T: type, comptime fns: []const *const anyopaque) ParseResult(T) {
    const ti = @typeInfo(T);
    if (ti != .@"union") @compileError("Not a union");

    inline for (0..fns.len) |i| {
        try self.save();
        const field = ti.@"union".fields[i];
        const @"fn": *const fn (*Parser) ParseResult(field.type) = @ptrCast(fns[i]);
        switch (try @"fn"(self)) {
            .success => |value| {
                try self.merge();
                return .{ .success = @unionInit(T, field.name, value) };
            },
            .failure => {
                try self.restore();
            },
        }
    }
    return .{ .failure = "No match for union type " ++ @typeName(T) };
}

pub fn parseAbstractSyntaxTree(self: *Parser) ParseResult(types.AbstractSyntaxTree) {
    try self.frames.append(self.gpa, .{});

    while (true) if ((try self.parseWs()) == .failure) break;

    var items = std.ArrayList(types.TopItem).empty;

    var item = try self.parseTopItem();
    if (item == .failure) return .{ .success = .{ .items = items.items } };
    try items.append(self.gpa, item.success);

    while (true) {
        while (true) if ((try self.parseSep()) == .failure) break;

        item = try self.parseTopItem();
        if (item == .failure) break;
        try items.append(self.gpa, item.success);
    }

    while (true) if ((try self.parseWs()) == .failure) break;

    std.debug.assert(self.frames.items.len == 1);
    return .{ .success = .{ .items = items.items } };
}

fn parseAliasStmt(self: *Parser) ParseResult(types.AliasStmt) {
    _ = self;
}

fn parseArrayLit(self: *Parser) ParseResult(types.ArrayLit) {
    _ = self;
}

fn parseArrayType(self: *Parser) ParseResult(types.ArrayType) {
    _ = self;
}

fn parseAssignStmt(self: *Parser) ParseResult(types.AssignStmt) {
    _ = self;
}

fn parseBinOp(self: *Parser) ParseResult(types.BinOp) {
    _ = self;
}

fn parseBlockStmt(self: *Parser) ParseResult(types.BlockStmt) {
    _ = self;
}

fn parseBoolLit(self: *Parser) ParseResult(types.BoolLit) {
    _ = self;
}

fn parseBranch(self: *Parser) ParseResult(types.Branch) {
    _ = self;
}

fn parseBreakStmt(self: *Parser) ParseResult(types.BreakStmt) {
    _ = self;
}

fn parseCast(self: *Parser) ParseResult(types.Cast) {
    _ = self;
}

fn parseCharLit(self: *Parser) ParseResult(types.CharLit) {
    _ = self;
}

fn parseContinueStmt(self: *Parser) ParseResult(types.ContinueStmt) {
    _ = self;
}

fn parseElseBranch(self: *Parser) ParseResult(types.ElseBranch) {
    _ = self;
}

fn parseEnumDefn(self: *Parser) ParseResult(types.EnumDefn) {
    _ = self;
}

fn parseEnumLit(self: *Parser) ParseResult(types.EnumLit) {
    _ = self;
}

fn parseEnumMember(self: *Parser) ParseResult(types.EnumMember) {
    _ = self;
}

fn parseExportStmt(self: *Parser) ParseResult(types.ExportStmt) {
    _ = self;
}

fn parseExpr(self: *Parser) ParseResult(types.Expr) {
    _ = self;
}

fn parseFloatLit(self: *Parser) ParseResult(types.FloatLit) {
    _ = self;
}

fn parseFnCall(self: *Parser) ParseResult(types.FnCall) {
    _ = self;
}

fn parseFnDecl(self: *Parser) ParseResult(types.FnDecl) {
    _ = self;
}

fn parseFnDefn(self: *Parser) ParseResult(types.FnDefn) {
    _ = self;
}

fn parseFnSig(self: *Parser) ParseResult(types.FnSig) {
    _ = self;
}

fn parseForStmt(self: *Parser) ParseResult(types.ForStmt) {
    _ = self;
}

fn parseGlobalVarDecl(self: *Parser) ParseResult(types.GlobalVarDecl) {
    _ = self;
}

fn parseIfStmt(self: *Parser) ParseResult(types.IfStmt) {
    _ = self;
}

fn parseImportStmt(self: *Parser) ParseResult(types.ImportStmt) {
    // "import", ws, {ws}, value_name, { ".", value_name }
    if ((try self.parseText("import")) == .failure) return .{ .failure = "No import keyword" };
    if ((try self.parseWs()) == .failure) return .{ .failure = "No whitespace" };
    while (true) if ((try self.parseWs()) == .failure) break;
    const first = try self.parseValueName();
    if (first == .failure) return .{ .failure = "No path root" };
    // std.debug.print("{s}\n", .{first.success});

    var path = std.ArrayList([]u8).empty;
    try path.append(self.gpa, first.success);

    while (true) {
        if ((try self.parseText(".")) == .failure) break;
        const elem = try self.parseValueName();
        if (elem == .failure) return .{ .failure = "No path element" };
        // std.debug.print("{s}\n", .{elem.success});
        try path.append(self.gpa, elem.success);
    }

    for (path.items, 0..) |elem, i| {
        std.debug.print("path[{d}] = '{s}'\n", .{ i, elem });
    }

    return .{ .success = .{ .path = path.items } };
}

fn parseIndex(self: *Parser) ParseResult(types.Index) {
    _ = self;
}

fn parseIntLit(self: *Parser) ParseResult(types.IntLit) {
    _ = self;
}

fn parseIntType(self: *Parser) ParseResult(types.IntType) {
    _ = self;
}

fn parseLambda(self: *Parser) ParseResult(types.Lambda) {
    _ = self;
}

fn parseLiteral(self: *Parser) ParseResult(types.Literal) {
    _ = self;
}

fn parseMacroDefn(self: *Parser) ParseResult(types.MacroDefn) {
    _ = self;
}

fn parseMember(self: *Parser) ParseResult(types.Member) {
    _ = self;
}

fn parsePointerType(self: *Parser) ParseResult(types.PointerType) {
    _ = self;
}

fn parsePrimary(self: *Parser) ParseResult(types.Primary) {
    _ = self;
}

fn parseReturnStmt(self: *Parser) ParseResult(types.ReturnStmt) {
    _ = self;
}

fn parseScope(self: *Parser) ParseResult(types.Scope) {
    _ = self;
}

fn parseStmt(self: *Parser) ParseResult(types.Stmt) {
    _ = self;
}

fn parseStringLit(self: *Parser) ParseResult(types.StringLit) {
    _ = self;
}

fn parseStructDefn(self: *Parser) ParseResult(types.StructDefn) {
    _ = self;
}

fn parseStructLit(self: *Parser) ParseResult(types.StructLit) {
    _ = self;
}

fn parseTopItem(self: *Parser) ParseResult(types.TopItem) {
    return try self.parseUnion(types.TopItem, &.{parseImportStmt});
}

fn parseType(self: *Parser) ParseResult(types.Type) {
    _ = self;
}

fn parseTypeDecl(self: *Parser) ParseResult(types.TypeDecl) {
    _ = self;
}

fn parseTypeDefn(self: *Parser) ParseResult(types.TypeDefn) {
    _ = self;
}

fn parseTypeRef(self: *Parser) ParseResult(types.TypeRef) {
    _ = self;
}

fn parseUnionDefn(self: *Parser) ParseResult(types.UnionDefn) {
    _ = self;
}

fn parseUnionLit(self: *Parser) ParseResult(types.UnionLit) {
    _ = self;
}

fn parseUnOp(self: *Parser) ParseResult(types.UnOp) {
    _ = self;
}

fn parseValueRef(self: *Parser) ParseResult(types.ValueRef) {
    _ = self;
}

fn parseVarDecl(self: *Parser) ParseResult(types.VarDecl) {
    _ = self;
}

fn parseVarDefn(self: *Parser) ParseResult(types.VarDefn) {
    _ = self;
}

fn parseYieldStmt(self: *Parser) ParseResult(types.YieldStmt) {
    _ = self;
}
