const std = @import("std");
const types = @import("types.zig");

const Parser = @This();

const AllocError = std.mem.Allocator.Error;

// Most parse functions are written as a *body* returning
// `BodyError!types.Foo` and turned into `parseFoo` by `rule()`. In a body a
// failed sub-parse is the error `error.NoMatch`, so `errdefer` frees everything
// built so far on failure *and* on out-of-memory; `rule()` turns the error back
// into a `.failure` and restores `pos`.
const BodyError = error{NoMatch} || AllocError;

fn ParseResult(comptime T: type) type {
    return AllocError!union(enum) {
        success: T,
        failure: []const u8,
    };
}

const ErrorRank = enum { normal, fallback };

const ErrorCandidate = struct {
    pos: usize,
    msg: []const u8,
    rank: ErrorRank,
};

gpa: std.mem.Allocator,
source: []const u8,
pos: usize = 0,
furthest: ?ErrorCandidate = null,

pub fn init(gpa: std.mem.Allocator, source: []const u8) Parser {
    return .{ .gpa = gpa, .source = source };
}

/// Does a message at `pos` beat the current best one?
fn outranks(self: *const Parser) bool {
    const f = self.furthest orelse return true;
    if (self.pos != f.pos) return self.pos > f.pos;
    return f.rank == .fallback;
}

/// Offers `msg`, positioned at `pos`, as the message for a failed parse: it is
/// reported if it is the furthest one offered (the first among equals). A
/// `.fallback` offer only counts when nothing else has been offered at that
/// position, and the latest fallback wins among fallbacks.
fn proposeError(self: *Parser, msg: []const u8, rank: ErrorRank) void {
    if (self.outranks()) self.furthest = .{ .pos = self.pos, .msg = msg, .rank = rank };
}

fn lineCol(self: *const Parser, pos: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    for (self.source[0..pos]) |c| switch (c) {
        '\r' => {},
        '\n' => {
            line += 1;
            col = 1;
        },
        else => col += 1,
    };
    return .{ .line = line, .col = col };
}

fn parseText(self: *Parser, comptime text: []const u8) bool {
    if (!std.mem.startsWith(u8, self.source[self.pos..], text)) return false;
    self.pos += text.len;
    return true;
}

fn parseSp(self: *Parser) bool {
    if (self.pos >= self.source.len) return false;
    switch (self.source[self.pos]) {
        ' ', '\t' => {
            self.pos += 1;
            return true;
        },
        '$' => {
            const body = self.source[self.pos + 1 ..];
            const end = std.mem.indexOfAny(u8, body, "$\r\n");
            if (end == null or body[end.?] != '$') {
                self.proposeError("Unterminated comment (a comment must end with '$' on the same line)", .normal);
                return false;
            }
            self.pos += end.? + 2;
            return true;
        },
        else => return false,
    }
}

fn parseNl(self: *Parser) bool {
    return self.parseText("\n") or self.parseText("\r\n");
}

fn parseWs(self: *Parser) bool {
    return self.parseSp() or self.parseNl();
}

fn skipWs(self: *Parser) void {
    while (self.parseWs()) {}
}

fn parseSep(self: *Parser, comptime msg: []const u8) bool {
    const start = self.pos;
    while (self.parseSp()) {}
    if (!self.parseNl()) {
        self.proposeError(msg, .normal);
        self.pos = start;
        return false;
    }
    self.skipWs();
    return true;
}

fn skipSp(self: *Parser) void {
    while (self.parseSp()) {}
}

/// ws, {ws}
fn requireWs(self: *Parser) bool {
    if (!self.parseWs()) return false;
    self.skipWs();
    return true;
}

fn isIdentChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => false,
    };
}

fn peekByte(self: *const Parser) ?u8 {
    return if (self.pos < self.source.len) self.source[self.pos] else null;
}

/// Like parseText, but the text must not continue as an identifier.
fn parseKeyword(self: *Parser, comptime kw: []const u8) bool {
    const rest = self.source[self.pos..];
    if (!std.mem.startsWith(u8, rest, kw)) return false;
    if (rest.len > kw.len and isIdentChar(rest[kw.len])) return false;
    self.pos += kw.len;
    return true;
}

fn voidRule(comptime matches: anytype, comptime text: []const u8, comptime msg: []const u8) fn (*Parser) ParseResult(void) {
    return struct {
        fn parse(self: *Parser) ParseResult(void) {
            if (matches(self, text)) return .{ .success = {} };
            return .{ .failure = msg };
        }
    }.parse;
}

/// Parse functions for `void` payloads, so that tokens go through the same
/// `require` / `optional` / `parseUnion` plumbing as everything else.
fn keyword(comptime kw: []const u8) fn (*Parser) ParseResult(void) {
    return voidRule(parseKeyword, kw, "Expected '" ++ kw ++ "'");
}

fn token(comptime text: []const u8) fn (*Parser) ParseResult(void) {
    return voidRule(parseText, text, "Expected '" ++ text ++ "'");
}

/// `requireWs` as a parse function; the failure names what must come before.
fn whitespace(comptime after: []const u8) fn (*Parser) ParseResult(void) {
    return struct {
        fn parse(self: *Parser) ParseResult(void) {
            if (self.requireWs()) return .{ .success = {} };
            return .{ .failure = "Expected whitespace after " ++ after };
        }
    }.parse;
}

/// A lexical function returning `?[]const u8` as a parse function.
fn nameParser(comptime what: []const u8, comptime lex: fn (*Parser) ?[]const u8) fn (*Parser) ParseResult([]const u8) {
    return struct {
        fn parse(self: *Parser) ParseResult([]const u8) {
            if (lex(self)) |name| return .{ .success = name };
            return .{ .failure = "No " ++ what };
        }
    }.parse;
}

/// type_name = upper, rest
fn parseTypeName(self: *Parser) ?[]const u8 {
    const src = self.source;
    const start = self.pos;
    if (start >= src.len or src[start] < 'A' or src[start] > 'Z') return null;
    var end = start + 1;
    while (end < src.len and isIdentChar(src[end])) end += 1;
    self.pos = end;
    return src[start..end];
}

const typeNameItem = nameParser("type name", parseTypeName);

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

fn parseValueName(self: *Parser) ?[]const u8 {
    const src = self.source;
    const start = self.pos;
    if (start >= src.len) return null;
    switch (src[start]) {
        'a'...'z', '_' => {},
        else => return null,
    }

    var end = start + 1;
    while (end < src.len) : (end += 1) {
        switch (src[end]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
            else => break,
        }
    }

    const name = src[start..end];
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw, name)) return null;
    }
    self.pos = end;
    return name;
}

const valueNameItem = nameParser("value name", parseValueName);

/// The payload type of a `ParseResult`-returning parse function.
fn Result(comptime f: anytype) type {
    const Ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return @FieldType(@typeInfo(Ret).error_union.payload, "success");
}

/// Turns a body into a parse function: failure restores `pos` and becomes a
/// `.failure`; running out of memory stays an error.
fn rule(comptime T: type, comptime body: fn (*Parser) BodyError!T) fn (*Parser) ParseResult(T) {
    return struct {
        fn parse(self: *Parser) ParseResult(T) {
            const start = self.pos;
            return if (body(self)) |value|
                .{ .success = value }
            else |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.NoMatch => blk: {
                    self.pos = start;
                    break :blk .{ .failure = "No match for " ++ @typeName(T) };
                },
            };
        }
    }.parse;
}

/// Required sub-parse; failure becomes `error.NoMatch`. `note` says which error
/// to propose: `null` none (for speculative parses), `.own` the sub-parser's own
/// failure message, or a string.
fn require(self: *Parser, comptime f: anytype, comptime note: anytype) BodyError!Result(f) {
    switch (try f(self)) {
        .success => |value| return value,
        .failure => |own| {
            if (@TypeOf(note) == @TypeOf(null)) {} else if (@TypeOf(note) == @TypeOf(.own) and note == .own) {
                self.proposeError(own, .normal);
            } else self.proposeError(note, .normal);
            return error.NoMatch;
        },
    }
}

/// Optional sub-parse: failure is `null` (and leaves `pos` alone).
fn optional(self: *Parser, comptime f: anytype) AllocError!?Result(f) {
    switch (try f(self)) {
        .success => |value| return value,
        .failure => return null,
    }
}

fn box(self: *Parser, value: anytype) AllocError!*@TypeOf(value) {
    const ptr = try self.gpa.create(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

/// Frees an AST value (or fragment) that was produced by this parser: owned
/// slices and boxes recursively; names and other text are borrowed from
/// `source` and are left alone.
fn freeNode(gpa: std.mem.Allocator, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => inline for (std.meta.fields(@TypeOf(value))) |field| freeNode(gpa, @field(value, field.name)),
        .@"union" => switch (value) {
            inline else => |payload| freeNode(gpa, payload),
        },
        .optional => if (value) |inner| freeNode(gpa, inner),
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) return;
                if (info.child != []const u8) for (value) |item| freeNode(gpa, item);
                gpa.free(value);
            },
            .one => {
                freeNode(gpa, value.*);
                gpa.destroy(value);
            },
            else => {},
        },
        else => {},
    }
}

fn release(self: *Parser, value: anytype) void {
    freeNode(self.gpa, value);
}

fn requireBox(self: *Parser, comptime f: anytype, comptime note: anytype) BodyError!*Result(f) {
    const value = try self.require(f, note);
    errdefer self.release(value);
    return try self.box(value);
}

fn optionalBox(self: *Parser, comptime f: anytype) AllocError!?*Result(f) {
    const value = (try self.optional(f)) orelse return null;
    errdefer self.release(value);
    return try self.box(value);
}

fn dropList(self: *Parser, list: anytype) void {
    for (list.items) |item| freeNode(self.gpa, item);
    list.deinit(self.gpa);
}

/// `{ws}, [ item, { {ws}, ",", {ws}, item }, [ {ws}, "," ], {ws} ]`
fn parseMany(self: *Parser, comptime parseItem: anytype) BodyError![]Result(parseItem) {
    const Item = Result(parseItem);
    var list = std.ArrayList(Item).empty;
    errdefer self.dropList(&list);

    self.skipWs();
    try list.ensureUnusedCapacity(self.gpa, 1);
    if (try self.optional(parseItem)) |first| {
        list.appendAssumeCapacity(first);
        while (true) {
            const before = self.pos;
            self.skipWs();
            if (!self.parseText(",")) {
                self.pos = before;
                break;
            }
            self.skipWs();
            try list.ensureUnusedCapacity(self.gpa, 1);
            const next = (try self.optional(parseItem)) orelse break; // trailing comma
            list.appendAssumeCapacity(next);
        }
    }
    self.skipWs();
    return try list.toOwnedSlice(self.gpa);
}

fn Params(comptime Item: type) type {
    return struct { items: []Item, variadic: bool };
}

/// After the "(": `{ws}, [ { item, {ws}, ",", {ws} }, ( item | "..." ), [ {ws}, "," ], {ws} ], ")"`
fn parseParams(self: *Parser, comptime parseItem: anytype) BodyError!Params(Result(parseItem)) {
    var list = std.ArrayList(Result(parseItem)).empty;
    errdefer self.dropList(&list);
    var variadic = false;

    self.skipWs();
    while (true) {
        try list.ensureUnusedCapacity(self.gpa, 1);
        if (try self.optional(parseItem)) |item| {
            list.appendAssumeCapacity(item);
        } else {
            variadic = self.parseText("...");
            if (!variadic) break;
        }
        const before = self.pos;
        self.skipWs();
        if (!self.parseText(",")) {
            self.pos = before;
            break;
        }
        self.skipWs();
        if (variadic) break;
    }
    self.skipWs();
    try self.require(token(")"), .own);
    return .{ .items = try list.toOwnedSlice(self.gpa), .variadic = variadic };
}

/// `"<", {ws}, item, { {ws}, ",", {ws}, item }, [ {ws}, "," ], {ws}, ">"`
fn parseAngleList(self: *Parser, comptime parseItem: anytype) BodyError![]Result(parseItem) {
    const Item = Result(parseItem);
    if (!self.parseText("<")) return error.NoMatch;
    var list = std.ArrayList(Item).empty;
    errdefer self.dropList(&list);

    self.skipWs();
    while (true) {
        try list.ensureUnusedCapacity(self.gpa, 1);
        list.appendAssumeCapacity(try self.require(parseItem, null));
        const before = self.pos;
        self.skipWs();
        if (!self.parseText(",")) {
            self.pos = before;
            break;
        }
        self.skipWs();
        if (self.peekByte() == '>') break; // trailing comma
    }
    self.skipWs();
    try self.require(token(">"), null);
    return try list.toOwnedSlice(self.gpa);
}

fn parseUnion(self: *Parser, comptime T: type, comptime alternatives: anytype) ParseResult(T) {
    if (@typeInfo(T) != .@"union") @compileError("Not a union");

    const start = self.pos;
    inline for (alternatives) |alt| {
        const name = alt[0];
        const f = alt[1];
        if (@typeInfo(@TypeOf(f)).@"fn".return_type.? != ParseResult(@FieldType(T, name)))
            @compileError("Parse function for '" ++ name ++ "' does not return ParseResult of the field's type");

        switch (try f(self)) {
            .success => |value| return .{ .success = @unionInit(T, name, value) },
            .failure => self.pos = start,
        }
    }

    const msg = "No match for union type " ++ @typeName(T);
    self.proposeError(msg, .fallback);
    return .{ .failure = msg };
}

fn describeFailure(self: *Parser) AllocError![]const u8 {
    var at = self.pos;
    var msg: []const u8 = "Unexpected input";
    if (self.furthest) |f| {
        if (f.pos >= self.pos) {
            at = f.pos;
            msg = f.msg;
        }
    }
    const lc = self.lineCol(at);
    return std.fmt.allocPrint(self.gpa, "line {d}, column {d}: {s}", .{ lc.line, lc.col, msg });
}

fn discardItems(self: *Parser, items: *std.ArrayList(types.TopItem)) void {
    self.dropList(items);
}

fn parseImportStmt(self: *Parser) ParseResult(types.ImportStmt) {
    const start = self.pos;

    if (!self.parseText("import")) return .{ .failure = "No import keyword" };

    if (!self.parseWs()) {
        self.proposeError("Expected whitespace after 'import'", .normal);
        self.pos = start;
        return .{ .failure = "No whitespace after 'import'" };
    }
    self.skipWs();

    var path = std.ArrayList([]const u8).empty;
    errdefer path.deinit(self.gpa);

    const first = self.parseValueName() orelse {
        self.proposeError("Expected a module name after 'import'", .normal);
        self.pos = start;
        return .{ .failure = "No path root" };
    };
    try path.append(self.gpa, first);

    while (self.parseText(".")) {
        const elem = self.parseValueName() orelse {
            self.proposeError("Expected a name after '.' in import path", .normal);
            self.pos = start;
            path.deinit(self.gpa);
            return .{ .failure = "No path element" };
        };
        try path.append(self.gpa, elem);
    }

    return .{ .success = .{ .path = try path.toOwnedSlice(self.gpa) } };
}

/// const_name = upper, { upper | digit | "_" }
fn parseConstName(self: *Parser) ?[]const u8 {
    const src = self.source;
    const start = self.pos;
    if (start >= src.len or src[start] < 'A' or src[start] > 'Z') return null;
    var end = start + 1;
    while (end < src.len) : (end += 1) {
        switch (src[end]) {
            'A'...'Z', '0'...'9', '_' => {},
            else => break,
        }
    }
    self.pos = end;
    return src[start..end];
}

fn compArgsDecl(self: *Parser) BodyError![]const []const u8 {
    return try self.parseAngleList(typeNameItem);
}

/// comp_args_decl = "<", {ws}, type_name, { ... }, ">"
const parseCompArgsDecl = rule([]const []const u8, compArgsDecl);

fn parseIntType(self: *Parser) ParseResult(types.IntType) {
    const start = self.pos;
    var unsigned = false;
    if (self.parseKeyword("unsigned")) {
        if (!self.requireWs()) {
            self.pos = start;
            return .{ .failure = "No integer type" };
        }
        unsigned = true;
    }

    if (self.parseKeyword("long")) {
        const after_long = self.pos;
        if (self.requireWs() and self.parseKeyword("long")) {
            return .{ .success = if (unsigned) .ulonglong else .longlong };
        }
        self.pos = after_long;
        return .{ .success = if (unsigned) .ulong else .long };
    }
    if (self.parseKeyword("char")) return .{ .success = if (unsigned) .uchar else .char };
    if (self.parseKeyword("short")) return .{ .success = if (unsigned) .ushort else .short };
    if (self.parseKeyword("int")) return .{ .success = if (unsigned) .uint else .int };

    self.pos = start;
    return .{ .failure = "No integer type" };
}

const parseTypeRef = rule(types.TypeRef, typeRef);

fn pointerType(self: *Parser) BodyError!types.PointerType {
    try self.require(token("*"), null);
    self.skipWs();
    if (try self.optionalBox(parseType)) |pointee| return .{ .type = pointee };
    if (self.parseValueName()) |name| return .{ .@"fn" = name };
    self.proposeError("Expected a type or a function name after '*'", .normal);
    return error.NoMatch;
}

const parsePointerType = rule(types.PointerType, pointerType);

/// Binary operators from lowest to highest precedence (expr_0 .. expr_9).
const bin_ops = [_][]const []const u8{
    &.{"or"},
    &.{"and"},
    &.{"|"},
    &.{"^"},
    &.{"&"},
    &.{ "==", "!=" },
    &.{ "<=", ">=", "<", ">" },
    &.{ "<<", ">>" },
    &.{ "+", "-" },
    &.{ "*", "/", "%" },
};

fn matchOp(self: *Parser, comptime ops: []const []const u8) ?[]const u8 {
    inline for (ops) |op| {
        if (std.mem.startsWith(u8, self.source[self.pos..], op)) {
            const start = self.pos;
            self.pos += op.len;
            return self.source[start..self.pos];
        }
    }
    return null;
}

fn isDec(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return isDec(c) or (c >= 'A' and c <= 'F'); // no lowercase letters by design
}

fn isBin(c: u8) bool {
    return c == '0' or c == '1';
}

fn isOct(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// digit, { ["_"], digit }; returns the index after the last digit.
fn scanDigits(src: []const u8, start: usize, comptime isDigit: fn (u8) bool) ?usize {
    if (start >= src.len or !isDigit(src[start])) return null;
    var i = start + 1;
    while (i < src.len) {
        if (isDigit(src[i])) {
            i += 1;
        } else if (src[i] == '_' and i + 1 < src.len and isDigit(src[i + 1])) {
            i += 2;
        } else break;
    }
    return i;
}

fn scanInt(src: []const u8, start: usize) ?usize {
    if (start + 2 <= src.len and src[start] == '0') {
        const prefixed = switch (src[start + 1]) {
            'x' => scanDigits(src, start + 2, isHex),
            'b' => scanDigits(src, start + 2, isBin),
            'o' => scanDigits(src, start + 2, isOct),
            else => null,
        };
        if (prefixed) |end| return end;
    }
    return scanDigits(src, start, isDec);
}

/// The value is the digits (with any 0x / 0b / 0o prefix and underscores); the
/// suffix only determines the type.
fn parseIntLit(self: *Parser) ParseResult(types.IntLit) {
    const src = self.source;
    const start = self.pos;
    var i = scanInt(src, start) orelse return .{ .failure = "No integer literal" };
    const value = src[start..i];

    const unsigned = i < src.len and src[i] == 'u';
    if (unsigned) i += 1;

    var kind: enum { int, char, short, long, longlong } = .int;
    if (i < src.len) switch (src[i]) {
        'c' => {
            kind = .char;
            i += 1;
        },
        's' => {
            kind = .short;
            i += 1;
        },
        'l' => if (i + 1 < src.len and src[i + 1] == 'l') {
            kind = .longlong;
            i += 2;
        } else {
            kind = .long;
            i += 1;
        },
        else => {},
    };

    const int_type: types.IntType = switch (kind) {
        .int => if (unsigned) .uint else .int,
        .char => if (unsigned) .uchar else .char,
        .short => if (unsigned) .ushort else .short,
        .long => if (unsigned) .ulong else .long,
        .longlong => if (unsigned) .ulonglong else .longlong,
    };
    self.pos = i;
    return .{ .success = .{ .type = int_type, .value = value } };
}

/// The value excludes the mandatory `f` / `d` suffix.
fn parseFloatLit(self: *Parser) ParseResult(types.FloatLit) {
    const src = self.source;
    const start = self.pos;
    const fail: ParseResult(types.FloatLit) = .{ .failure = "No float literal" };

    const int_end = scanDigits(src, start, isDec) orelse return fail;
    if (int_end >= src.len or src[int_end] != '.') return fail;
    const frac_end = scanDigits(src, int_end + 1, isDec) orelse return fail;

    var i = frac_end;
    if (i < src.len and src[i] == 'e') {
        var j = i + 1;
        if (j < src.len and (src[j] == '+' or src[j] == '-')) j += 1;
        if (scanDigits(src, j, isDec)) |exp_end| i = exp_end;
    }
    if (i >= src.len) return fail;
    const float_type: @FieldType(types.FloatLit, "type") = switch (src[i]) {
        'f' => .float,
        'd' => .double,
        else => return fail,
    };
    self.pos = i + 1;
    return .{ .success = .{ .type = float_type, .value = src[start..i] } };
}

fn parseBoolLit(self: *Parser) ParseResult(types.BoolLit) {
    const start = self.pos;
    if (self.parseKeyword("true") or self.parseKeyword("false")) {
        return .{ .success = .{ .value = self.source[start..self.pos] } };
    }
    return .{ .failure = "No boolean literal" };
}

fn stringLit(self: *Parser) BodyError!types.StringLit {
    const src = self.source;
    const start = self.pos;
    try self.require(token("\""), null);

    var i = self.pos;
    while (i < src.len) switch (src[i]) {
        '"' => {
            self.pos = i + 1;
            return .{ .value = src[start + 1 .. i] };
        },
        '\\' => {
            if (i + 1 >= src.len or !isEscapeChar(src[i + 1])) {
                self.pos = i;
                self.proposeError("Invalid escape sequence in string literal", .normal);
                return error.NoMatch;
            }
            i += 2;
        },
        else => i += 1,
    };
    self.pos = src.len;
    self.proposeError("Unterminated string literal", .normal);
    return error.NoMatch;
}

/// The value is the raw text between the quotes (escape sequences unprocessed).
const parseStringLit = rule(types.StringLit, stringLit);

fn isEscapeChar(c: u8) bool {
    return switch (c) {
        '\\', 'n', 'r', 't', '0', '"', '\'' => true,
        else => false,
    };
}

fn charLit(self: *Parser) BodyError!types.CharLit {
    const src = self.source;
    const start = self.pos;
    try self.require(token("'"), null);

    var i = self.pos;
    if (i < src.len and src[i] == '\\') {
        if (i + 1 >= src.len or !isEscapeChar(src[i + 1])) {
            self.pos = i;
            self.proposeError("Invalid escape sequence in character literal", .normal);
            return error.NoMatch;
        }
        i += 2;
    } else if (i < src.len and src[i] != '\'') {
        i += 1;
    } else return error.NoMatch; // empty

    if (i >= src.len or src[i] != '\'') {
        self.pos = i;
        self.proposeError("Unterminated character literal", .normal);
        return error.NoMatch;
    }
    self.pos = i + 1;
    return .{ .value = src[start + 1 .. i] };
}

/// The value is the raw text between the quotes.
const parseCharLit = rule(types.CharLit, charLit);

fn parseEnumLit(self: *Parser) ParseResult(types.EnumLit) {
    const start = self.pos;
    const namespace = self.parseTypeName() orelse return .{ .failure = "No enum literal" };
    if (self.parseText("::")) {
        if (self.parseConstName()) |value| {
            return .{ .success = .{ .namespace = namespace, .value = value } };
        }
    }
    self.pos = start;
    return .{ .failure = "No enum literal" };
}

fn arrayLit(self: *Parser) BodyError!types.ArrayLit {
    try self.require(token("{"), null);
    const values = try self.parseMany(parseExpr);
    errdefer self.release(values);
    try self.require(token("}"), null);
    return .{ .values = values };
}

const parseArrayLit = rule(types.ArrayLit, arrayLit);

fn varDefn(self: *Parser) BodyError!types.VarDefn {
    const name = self.parseValueName() orelse return error.NoMatch;
    self.skipWs();
    try self.require(token("="), null);
    if (self.peekByte() == '=') return error.NoMatch; // `==`, not a definition
    self.skipWs();
    const value = try self.require(parseExpr, null);
    return .{ .name = name, .value = value };
}

const parseVarDefn = rule(types.VarDefn, varDefn);

fn structLit(self: *Parser) BodyError!types.StructLit {
    const tag = try self.require(parseTypeRef, null);
    errdefer self.release(tag);
    self.skipWs();
    try self.require(token("{"), null);
    const members = try self.parseMany(parseVarDefn);
    errdefer self.release(members);
    try self.require(token("}"), null);
    return .{ .tag = tag, .members = members };
}

const parseStructLit = rule(types.StructLit, structLit);

fn unionLit(self: *Parser) BodyError!types.UnionLit {
    const tag = try self.require(parseTypeRef, null);
    errdefer self.release(tag);
    self.skipWs();
    try self.require(token("."), null);
    self.skipWs();
    const member_name = self.parseValueName() orelse return error.NoMatch;
    self.skipWs();
    try self.require(token("{"), null);
    self.skipWs();
    const value = try self.requireBox(parseExpr, null);
    errdefer self.release(value);
    self.skipWs();
    try self.require(token("}"), null);
    return .{ .tag = tag, .member = member_name, .value = value };
}

const parseUnionLit = rule(types.UnionLit, unionLit);

fn parseLiteral(self: *Parser) ParseResult(types.Literal) {
    // float before int: `1.5f` must not be read as the int `1`
    return try self.parseUnion(types.Literal, .{
        .{ "float", parseFloatLit },
        .{ "int", parseIntLit },
        .{ "bool", parseBoolLit },
        .{ "array", parseArrayLit },
        .{ "struct", parseStructLit },
        .{ "union", parseUnionLit },
        .{ "enum", parseEnumLit },
        .{ "string", parseStringLit },
        .{ "char", parseCharLit },
        .{ "null", keyword("null") },
    });
}

fn valueRef(self: *Parser) BodyError!types.ValueRef {
    const name = self.parseValueName() orelse return error.NoMatch;
    const comp_args = (try self.optional(parseCompArgsDefn)) orelse try self.gpa.alloc(types.Type, 0);
    return .{ .name = name, .comp_args = comp_args };
}

const parseValueRef = rule(types.ValueRef, valueRef);

fn parenExpr(self: *Parser) BodyError!*types.Expr {
    try self.require(token("("), null);
    self.skipWs();
    const inner = try self.requireBox(parseExpr, null);
    errdefer self.release(inner);
    self.skipWs();
    try self.require(token(")"), .own);
    return inner;
}

const parseExprParen = rule(*types.Expr, parenExpr);

fn varDecl(self: *Parser) BodyError!types.VarDecl {
    const name = self.parseValueName() orelse return error.NoMatch;
    self.skipWs();
    try self.require(token(":"), null);
    self.skipWs();
    const ty = try self.require(parseType, null);
    return .{ .name = name, .type = ty };
}

const parseVarDecl = rule(types.VarDecl, varDecl);

fn fnSig(self: *Parser) BodyError!types.FnSig {
    try self.require(token("("), null);
    const params = try self.parseParams(parseVarDecl);
    errdefer self.release(params.items);

    // [{ws}, type]
    const before_ret = self.pos;
    self.skipWs();
    const ret_type = try self.optionalBox(parseType);
    errdefer if (ret_type) |ret| self.release(ret);
    if (ret_type == null) self.pos = before_ret;

    return .{ .args = params.items, .variadic = params.variadic, .ret_type = ret_type };
}

/// "(", {ws}, [ { var_decl, {ws}, ",", {ws} }, ( var_decl | "..." ), [ {ws}, "," ], {ws} ], ")", [{ws}, type]
const parseFnSig = rule(types.FnSig, fnSig);

/// A parse function for an expression whose outermost node is `tag`; the
/// expression is parsed at the precedence level of `parseLevel`.
fn outermost(comptime tag: std.meta.Tag(types.Expr), comptime parseLevel: fn (*Parser) BodyError!types.Expr) fn (*Parser) ParseResult(@FieldType(types.Expr, @tagName(tag))) {
    const T = @FieldType(types.Expr, @tagName(tag));
    return rule(T, struct {
        fn body(self: *Parser) BodyError!T {
            const e = try parseLevel(self);
            if (e == tag) return @field(e, @tagName(tag));
            self.release(e);
            return error.NoMatch;
        }
    }.body);
}

/// fn_call = primary, { postfix }, {sp}, "(", many_expr, ")" (the last postfix
/// of an expr_12 is the call)
const parseFnCall = outermost(.fn_call, exprPostfix);

fn blockStmt(self: *Parser) BodyError!types.BlockStmt {
    if (self.peekByte() != '{') return error.NoMatch;
    return .{ .scope = try self.bracedScope() };
}

const parseBlockStmt = rule(types.BlockStmt, blockStmt);

/// expr_11 on its own (the target of an assignment).
const parseExprUnary = rule(types.Expr, exprUnary);

fn assignStmt(self: *Parser) BodyError!types.AssignStmt {
    const target = try self.require(parseExprUnary, null);
    errdefer self.release(target);
    self.skipWs();
    try self.require(token("="), null);
    if (self.peekByte() == '=') return error.NoMatch;
    self.skipWs();
    const value = try self.require(parseExpr, null);
    return .{ .target = target, .value = value };
}

/// expr_11, {ws}, "=", {ws}, expr
const parseAssignStmt = rule(types.AssignStmt, assignStmt);

fn branch(self: *Parser) BodyError!types.Branch {
    var var_defn: ?types.VarDefn = null;
    errdefer if (var_defn) |d| self.release(d);

    const save = self.pos;
    if (try self.optional(parseVarDefn)) |d| {
        self.skipWs();
        if (self.parseText(";")) {
            self.skipWs();
            var_defn = d;
        } else {
            self.release(d);
            self.pos = save;
        }
    }

    const cond = try self.require(parseExpr, "Expected a condition");
    errdefer self.release(cond);
    self.skipWs();
    const body = try self.bracedScope();
    return .{ .var_defn = var_defn, .expr = cond, .scope = body };
}

/// What follows `if` / `elif` and its whitespace:
/// [var_defn, {ws}, ";", {ws}], expr, {ws}, "{", scope, "}"
const parseBranch = rule(types.Branch, branch);

fn elseBranch(self: *Parser) BodyError!types.ElseBranch {
    var var_defn: ?types.VarDefn = null;
    errdefer if (var_defn) |d| self.release(d);

    const save = self.pos;
    if (self.requireWs()) {
        if (try self.optional(parseVarDefn)) |d| {
            self.skipWs();
            if (self.parseText(";")) {
                var_defn = d;
            } else {
                self.release(d);
            }
        }
    }
    if (var_defn == null) self.pos = save;

    self.skipWs();
    const body = try self.bracedScope();
    return .{ .var_defn = var_defn, .scope = body };
}

/// What follows `else`: [ws, {ws}, var_defn, {ws}, ";"], {ws}, "{", scope, "}"
const parseBranchElse = rule(types.ElseBranch, elseBranch);

fn ifStmt(self: *Parser) BodyError!types.IfStmt {
    if (!self.parseKeyword("if")) return error.NoMatch;
    try self.require(whitespace("'if'"), .own);
    const if_branch = try self.require(parseBranch, null);
    errdefer self.release(if_branch);

    var elifs = std.ArrayList(types.Branch).empty;
    errdefer self.dropList(&elifs);
    while (true) {
        const before = self.pos;
        self.skipWs();
        if (!self.parseKeyword("elif")) {
            self.pos = before;
            break;
        }
        try self.require(whitespace("'elif'"), .own);
        try elifs.ensureUnusedCapacity(self.gpa, 1);
        elifs.appendAssumeCapacity(try self.require(parseBranch, null));
    }

    var else_branch: ?types.ElseBranch = null;
    errdefer if (else_branch) |e| self.release(e);
    {
        const before = self.pos;
        self.skipWs();
        if (self.parseKeyword("else")) {
            else_branch = try self.require(parseBranchElse, null);
        } else {
            self.pos = before;
        }
    }

    return .{
        .@"if" = if_branch,
        .elif = try elifs.toOwnedSlice(self.gpa),
        .@"else" = else_branch,
    };
}

const parseIfStmt = rule(types.IfStmt, ifStmt);

fn forStmt(self: *Parser) BodyError!types.ForStmt {
    if (!self.parseKeyword("for")) return error.NoMatch;
    try self.require(whitespace("'for'"), .own);
    const var_defn = try self.require(parseVarDefn, "Expected a variable definition after 'for'");
    errdefer self.release(var_defn);
    self.skipWs();
    try self.require(token(";"), .own);
    self.skipWs();
    const cond = try self.require(parseExpr, "Expected a loop condition");
    errdefer self.release(cond);
    self.skipWs();
    try self.require(token(";"), .own);
    self.skipWs();
    const stmt = try self.requireBox(parseStmt, null);
    errdefer self.release(stmt);
    self.skipWs();
    const body = try self.bracedScope();
    return .{ .var_defn = var_defn, .expr = cond, .stmt = stmt, .scope = body };
}

const parseForStmt = rule(types.ForStmt, forStmt);

/// kw, [sp, {sp}, expr]; the optional expression is the struct's only field.
fn jumpStmt(comptime T: type, comptime kw: []const u8) fn (*Parser) ParseResult(T) {
    return rule(T, struct {
        fn body(self: *Parser) BodyError!T {
            if (!self.parseKeyword(kw)) return error.NoMatch;
            const save = self.pos;
            var result: T = undefined;
            const field = @typeInfo(T).@"struct".fields[0].name;
            @field(result, field) = null;
            if (self.parseSp()) {
                self.skipSp();
                if (try self.optional(parseExpr)) |e| {
                    @field(result, field) = e;
                } else self.pos = save;
            } else self.pos = save;
            return result;
        }
    }.body);
}

const parseReturnStmt = jumpStmt(types.ReturnStmt, "return");

const parseBreakStmt = jumpStmt(types.BreakStmt, "break");

const parseContinueStmt = jumpStmt(types.ContinueStmt, "continue");

const parseYieldStmt = jumpStmt(types.YieldStmt, "yield");

fn parseStmt(self: *Parser) ParseResult(types.Stmt) {
    return try self.parseUnion(types.Stmt, .{
        // a `{` can only start a block here, so try it first
        .{ "block_stmt", parseBlockStmt },
        .{ "var_decl", parseVarDecl },
        .{ "assign_stmt", parseAssignStmt },
        .{ "if_stmt", parseIfStmt },
        .{ "for_stmt", parseForStmt },
        .{ "return_stmt", parseReturnStmt },
        .{ "break_stmt", parseBreakStmt },
        .{ "continue_stmt", parseContinueStmt },
        .{ "yield_stmt", parseYieldStmt },
        .{ "fn_call", parseFnCall },
    });
}

/// {ws}, [ stmt, { sep, stmt }, {ws} ]
fn scopeBody(self: *Parser) BodyError!types.Scope {
    var stmts = std.ArrayList(types.Stmt).empty;
    errdefer self.dropList(&stmts);

    self.skipWs();
    try stmts.ensureUnusedCapacity(self.gpa, 1);
    if (try self.optional(parseStmt)) |first| {
        stmts.appendAssumeCapacity(first);
        while (true) {
            const before = self.pos;
            if (!self.parseSep("Expected a newline between statements")) break;
            try stmts.ensureUnusedCapacity(self.gpa, 1);
            const next = (try self.optional(parseStmt)) orelse {
                self.pos = before;
                break;
            };
            stmts.appendAssumeCapacity(next);
        }
        self.skipWs();
    }
    return .{ .stmts = try stmts.toOwnedSlice(self.gpa) };
}

const parseScope = rule(types.Scope, scopeBody);

/// "{", scope, "}"
fn bracedScope(self: *Parser) BodyError!types.Scope {
    try self.require(token("{"), .own);
    const scope = try self.require(parseScope, null);
    errdefer self.release(scope);
    try self.require(token("}"), .own);
    return scope;
}

fn lambda(self: *Parser) BodyError!types.Lambda {
    if (!self.parseKeyword("fn")) return error.NoMatch;
    self.skipWs();
    const sig = try self.require(parseFnSig, "Expected a parameter list after 'fn'");
    errdefer self.release(sig);
    self.skipWs();
    const scope = try self.bracedScope();
    return .{ .sig = sig, .scope = scope };
}

const parseLambda = rule(types.Lambda, lambda);

fn parsePrimary(self: *Parser) ParseResult(types.Primary) {
    return try self.parseUnion(types.Primary, .{
        .{ "literal", parseLiteral },
        .{ "value_ref", parseValueRef },
        .{ "expr", parseExprParen },
        .{ "lambda", parseLambda },
    });
}

/// expr_12 = primary, { postfix }
fn exprPostfix(self: *Parser) BodyError!types.Expr {
    var e: types.Expr = .{ .primary = try self.require(parsePrimary, null) };
    errdefer self.release(e);

    while (true) {
        const save = self.pos;

        // ({ws}, ".", {ws}, value_name)
        self.skipWs();
        if (self.parseText(".")) {
            self.skipWs();
            if (self.parseValueName()) |name| {
                const base = try self.box(e);
                e = .{ .member = .{ .base = base, .name = name } };
                continue;
            }
        }
        self.pos = save;

        // ({sp}, "[", {ws}, expr, {ws}, "]")
        self.skipSp();
        if (self.parseText("[")) {
            self.skipWs();
            if (try self.optional(parseExpr)) |offset| {
                self.skipWs();
                if (self.parseText("]")) {
                    const offset_box = self.box(offset) catch |err| {
                        self.release(offset);
                        return err;
                    };
                    const base = self.box(e) catch |err| {
                        self.release(offset_box);
                        return err;
                    };
                    e = .{ .index = .{ .base = base, .offset = offset_box } };
                    continue;
                }
                self.proposeError("Expected ']'", .normal);
                self.release(offset);
            }
        }
        self.pos = save;

        // ({sp}, "(", many_expr, ")")
        self.skipSp();
        if (self.parseText("(")) {
            const args = try self.parseMany(parseExpr);
            if (self.parseText(")")) {
                const callee = self.box(e) catch |err| {
                    self.release(args);
                    return err;
                };
                e = .{ .fn_call = .{ .callee = callee, .dynm_args = args } };
                continue;
            }
            self.proposeError("Expected ')'", .normal);
            self.release(args);
        }
        self.pos = save;
        break;
    }
    return e;
}

/// expr_11 = { ("&" | "*" | ("not", ws) | "~" | "+" | "-"), {ws} }, expr_12
fn exprUnary(self: *Parser) BodyError!types.Expr {
    const src = self.source;
    var ops = std.ArrayList([]const u8).empty;
    defer ops.deinit(self.gpa);

    while (true) {
        const op_start = self.pos;
        if (self.pos < src.len) switch (src[self.pos]) {
            '&', '*', '~', '+', '-' => {
                self.pos += 1;
                try ops.append(self.gpa, src[op_start..self.pos]);
                self.skipWs();
                continue;
            },
            else => {},
        };
        if (self.parseKeyword("not")) {
            if (self.requireWs()) {
                try ops.append(self.gpa, src[op_start .. op_start + 3]);
                continue;
            }
            self.pos = op_start;
        }
        break;
    }

    var e = try self.exprPostfix();
    errdefer self.release(e);

    var i = ops.items.len;
    while (i > 0) {
        i -= 1;
        const inner = try self.box(e);
        e = .{ .un_op = .{ .op = ops.items[i], .expr = inner } };
    }
    return e;
}

/// expr_10 = expr_11, { ws, {ws}, "as", ws, {ws}, type }
fn exprCast(self: *Parser) BodyError!types.Expr {
    var lhs = try self.exprUnary();
    errdefer self.release(lhs);

    while (true) {
        const save = self.pos;
        if (!self.requireWs() or !self.parseKeyword("as") or !self.requireWs()) {
            self.pos = save;
            break;
        }
        const ty = self.require(parseType, null) catch |err| switch (err) {
            error.NoMatch => {
                self.pos = save;
                break;
            },
            else => |e| return e,
        };
        const lhs_box = self.box(lhs) catch |err| {
            self.release(ty);
            return err;
        };
        lhs = .{ .cast = .{ .expr = lhs_box, .type = ty } };
    }
    return lhs;
}

fn operand(self: *Parser, comptime level: usize) BodyError!types.Expr {
    return if (level + 1 < bin_ops.len) self.exprBin(level + 1) else self.exprCast();
}

/// expr_N = expr_N+1, { ws, {ws}, op, ws, {ws}, expr_N+1 }  (left associative)
fn exprBin(self: *Parser, comptime level: usize) BodyError!types.Expr {
    var lhs = try self.operand(level);
    errdefer self.release(lhs);

    while (true) {
        const save = self.pos;
        if (!self.requireWs()) break;
        const op = self.matchOp(bin_ops[level]) orelse {
            self.pos = save;
            break;
        };
        if (!self.requireWs()) {
            self.pos = save;
            break;
        }
        const rhs = self.operand(level) catch |err| switch (err) {
            error.NoMatch => {
                self.pos = save;
                break;
            },
            else => |e| return e,
        };
        const rhs_box = self.box(rhs) catch |err| {
            self.release(rhs);
            return err;
        };
        const lhs_box = self.box(lhs) catch |err| {
            self.release(rhs_box);
            return err;
        };
        lhs = .{ .bin_op = .{ .op = op, .expr0 = lhs_box, .expr1 = rhs_box } };
    }
    return lhs;
}

fn exprLevel0(self: *Parser) BodyError!types.Expr {
    return self.exprBin(0);
}

const parseExpr = rule(types.Expr, exprLevel0);

fn arrayType(self: *Parser) BodyError!types.ArrayType {
    try self.require(token("["), null);
    self.skipWs();
    const len = try self.requireBox(parseExpr, null);
    errdefer self.release(len);
    self.skipWs();
    try self.require(token("]"), .own);
    self.skipWs();
    const elem = try self.requireBox(parseType, null);
    return .{ .len = len, .type = elem };
}

const parseArrayType = rule(types.ArrayType, arrayType);

fn fnType(self: *Parser) BodyError!types.FnSig {
    if (!self.parseKeyword("fn")) return error.NoMatch;
    self.skipWs();
    return try self.require(parseFnSig, "Expected a parameter list after 'fn'");
}

/// "fn", {ws}, fn_sig
const parseFnType = rule(types.FnSig, fnType);

fn parseType(self: *Parser) ParseResult(types.Type) {
    return try self.parseUnion(types.Type, .{
        .{ "int", parseIntType },
        .{ "float", keyword("float") },
        .{ "double", keyword("double") },
        .{ "void", keyword("void") },
        .{ "bool", keyword("bool") },
        .{ "named", parseTypeRef },
        .{ "pointer", parsePointerType },
        .{ "array", parseArrayType },
        .{ "fn", parseFnType },
    });
}

fn compArgsDefn(self: *Parser) BodyError![]types.Type {
    return try self.parseAngleList(parseType);
}

/// comp_args_defn = "<", {ws}, type, { ... }, ">"
const parseCompArgsDefn = rule([]types.Type, compArgsDefn);

fn typeRef(self: *Parser) BodyError!types.TypeRef {
    const name = self.parseTypeName() orelse return error.NoMatch;
    const comp_args = (try self.optional(parseCompArgsDefn)) orelse try self.gpa.alloc(types.Type, 0);
    return .{ .name = name, .comp_args = comp_args };
}

fn typeDecl(self: *Parser) BodyError!types.TypeDecl {
    const name = self.parseTypeName() orelse return error.NoMatch;
    const before = self.pos;
    self.skipWs();
    const comp_args = (try self.optional(parseCompArgsDecl)) orelse blk: {
        self.pos = before;
        break :blk &.{};
    };
    return .{ .name = name, .comp_args = comp_args };
}

const parseTypeDecl = rule(types.TypeDecl, typeDecl);

const parseBinOp = outermost(.bin_op, exprLevel0);

const parseUnOp = outermost(.un_op, exprUnary);

const parseCast = outermost(.cast, exprCast);

const parseMember = outermost(.member, exprPostfix);

const parseIndex = outermost(.index, exprPostfix);

fn globalVarDecl(self: *Parser) BodyError!types.GlobalVarDecl {
    var is_extern = false;
    if (self.parseKeyword("extern")) {
        if (!self.requireWs()) return error.NoMatch;
        is_extern = true;
    }
    const decl = try self.require(parseVarDecl, null);
    return .{ .is_extern = is_extern, .var_decl = decl };
}

const parseGlobalVarDecl = rule(types.GlobalVarDecl, globalVarDecl);

fn fnDecl(self: *Parser) BodyError!types.FnDecl {
    if (!self.parseKeyword("fn")) return error.NoMatch;
    try self.require(whitespace("'fn'"), .own);
    const name = self.parseValueName() orelse {
        self.proposeError("Expected a function name after 'fn'", .normal);
        return error.NoMatch;
    };

    const before = self.pos;
    self.skipWs();
    const comp_args = (try self.optional(parseCompArgsDecl)) orelse blk: {
        self.pos = before;
        break :blk &.{};
    };
    errdefer self.release(comp_args);

    self.skipWs();
    const sig = try self.require(parseFnSig, "Expected a parameter list");
    return .{ .name = name, .comp_args = comp_args, .sig = sig };
}

/// "fn", ws, {ws}, value_name, [{ws}, comp_args_decl], {ws}, fn_sig
const parseFnDecl = rule(types.FnDecl, fnDecl);

fn externFnDecl(self: *Parser) BodyError!types.FnDecl {
    if (!self.parseKeyword("extern")) return error.NoMatch;
    if (!self.requireWs()) return error.NoMatch;
    return try self.require(parseFnDecl, null);
}

/// "extern", ws, {ws}, fn_decl
const parseFnDeclExtern = rule(types.FnDecl, externFnDecl);

fn fnDefn(self: *Parser) BodyError!types.FnDefn {
    const decl = try self.require(parseFnDecl, null);
    errdefer self.release(decl);
    self.skipWs();
    const scope = try self.bracedScope();
    return .{ .name = decl.name, .comp_args = decl.comp_args, .sig = decl.sig, .scope = scope };
}

const parseFnDefn = rule(types.FnDefn, fnDefn);

/// kw, ws, {ws}, type_decl, {ws}, "{", many_var_decl, "}"
fn aggregate(comptime T: type, comptime kw: []const u8) fn (*Parser) ParseResult(T) {
    return rule(T, struct {
        fn body(self: *Parser) BodyError!T {
            if (!self.parseKeyword(kw)) return error.NoMatch;
            try self.require(whitespace("'" ++ kw ++ "'"), .own);
            const tag = try self.require(parseTypeDecl, "Expected a type name after '" ++ kw ++ "'");
            errdefer self.release(tag);
            self.skipWs();
            try self.require(token("{"), .own);
            const members = try self.parseMany(parseVarDecl);
            errdefer self.release(members);
            try self.require(token("}"), .own);
            return .{ .tag = tag, .members = members };
        }
    }.body);
}

const parseStructDefn = aggregate(types.StructDefn, "struct");

const parseUnionDefn = aggregate(types.UnionDefn, "union");

fn enumMember(self: *Parser) BodyError!types.EnumMember {
    const name = self.parseConstName() orelse return error.NoMatch;
    var value: ?types.Expr = null;
    const before = self.pos;
    self.skipWs();
    if (self.parseText("=") and self.peekByte() != '=') {
        self.skipWs();
        value = try self.require(parseExpr, "Expected a value after '='");
    } else {
        self.pos = before;
    }
    return .{ .name = name, .value = value };
}

/// const_name, [ {ws}, "=", {ws}, expr ]
const parseEnumMember = rule(types.EnumMember, enumMember);

fn enumDefn(self: *Parser) BodyError!types.EnumDefn {
    if (!self.parseKeyword("enum")) return error.NoMatch;
    try self.require(whitespace("'enum'"), .own);
    const tag = try self.require(parseTypeDecl, "Expected a type name after 'enum'");
    errdefer self.release(tag);
    self.skipWs();
    try self.require(token("{"), .own);
    const members = try self.parseMany(parseEnumMember);
    errdefer self.release(members);
    try self.require(token("}"), .own);
    return .{ .tag = tag, .members = members };
}

const parseEnumDefn = rule(types.EnumDefn, enumDefn);

fn parseTypeDefn(self: *Parser) ParseResult(types.TypeDefn) {
    return try self.parseUnion(types.TypeDefn, .{
        .{ "struct", parseStructDefn },
        .{ "union", parseUnionDefn },
        .{ "enum", parseEnumDefn },
    });
}

fn aliasStmt(self: *Parser) BodyError!types.AliasStmt {
    if (!self.parseKeyword("alias")) return error.NoMatch;
    try self.require(whitespace("'alias'"), .own);
    const name = try self.require(parseTypeDecl, "Expected a type name after 'alias'");
    errdefer self.release(name);
    self.skipWs();
    try self.require(token("="), .own);
    self.skipWs();
    const ty = try self.require(parseType, "Expected a type after '='");
    return .{ .name = name, .type = ty };
}

const parseAliasStmt = rule(types.AliasStmt, aliasStmt);

/// The index of the `}` that closes a macro body starting at `pos`.
fn scanMacroBody(self: *const Parser) ?usize {
    const src = self.source;
    var depth: usize = 1;
    var i = self.pos;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '\\' => {
                if (i + 1 >= src.len) return null;
                i += 1;
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn macroDefn(self: *Parser) BodyError!types.MacroDefn {
    const kind: @FieldType(types.MacroDefn, "kind") = if (self.parseKeyword("smacro"))
        .smacro
    else if (self.parseKeyword("cmacro"))
        .cmacro
    else
        return error.NoMatch;

    try self.require(whitespace("the macro keyword"), .own);
    const name = self.parseValueName() orelse {
        self.proposeError("Expected a macro name", .normal);
        return error.NoMatch;
    };
    self.skipWs();
    try self.require(token("("), .own);
    self.skipWs();

    const params = try self.parseParams(valueNameItem);
    errdefer self.release(params.items);
    self.skipWs();
    try self.require(token("{"), .own);

    const body_start = self.pos;
    const body_end = self.scanMacroBody() orelse {
        self.proposeError("Unterminated macro body", .normal);
        return error.NoMatch;
    };
    self.pos = body_end + 1;
    return .{
        .kind = kind,
        .name = name,
        .args = params.items,
        .variadic = params.variadic,
        .body = self.source[body_start..body_end],
    };
}

/// The body is the raw text between the outer braces.
const parseMacroDefn = rule(types.MacroDefn, macroDefn);

fn parseExportSymbol(self: *Parser) ?[]const u8 {
    return self.parseValueName() orelse self.parseTypeName();
}

/// Does the rest of the line end here (so that a following `,` still belongs
/// to the list)? Used to tell `export a,` + next item from `export a, b`.
fn atEndOfLine(self: *Parser) bool {
    const save = self.pos;
    defer self.pos = save;
    self.skipSp();
    return switch (self.peekByte() orelse return true) {
        '\n', '\r', ',' => true,
        else => false,
    };
}

fn exportStmt(self: *Parser) BodyError!types.ExportStmt {
    if (!self.parseKeyword("export")) return error.NoMatch;
    try self.require(whitespace("'export'"), .own);

    var symbols = std.ArrayList([]const u8).empty;
    errdefer symbols.deinit(self.gpa);
    try symbols.ensureUnusedCapacity(self.gpa, 1);
    symbols.appendAssumeCapacity(self.parseExportSymbol() orelse {
        self.proposeError("Expected a name to export", .normal);
        return error.NoMatch;
    });

    while (true) {
        const before = self.pos;
        self.skipWs();
        if (!self.parseText(",")) {
            self.pos = before;
            break;
        }
        const after_comma = self.pos;
        self.skipWs();
        try symbols.ensureUnusedCapacity(self.gpa, 1);
        // A trailing comma is allowed, so a name on the next line that starts
        // a new item (`x = 1`, `f: int`, ...) is not part of this export.
        const symbol = self.parseExportSymbol() orelse {
            self.pos = after_comma;
            break;
        };
        if (!self.atEndOfLine()) {
            self.pos = after_comma;
            break;
        }
        symbols.appendAssumeCapacity(symbol);
    }
    return .{ .symbols = try symbols.toOwnedSlice(self.gpa) };
}

const parseExportStmt = rule(types.ExportStmt, exportStmt);

fn parseTopItem(self: *Parser) ParseResult(types.TopItem) {
    return try self.parseUnion(types.TopItem, .{
        .{ "import_stmt", parseImportStmt },
        .{ "macro_defn", parseMacroDefn },
        .{ "type_defn", parseTypeDefn },
        .{ "alias_stmt", parseAliasStmt },
        .{ "var_decl", parseGlobalVarDecl },
        .{ "fn_decl", parseFnDeclExtern },
        .{ "var_defn", parseVarDefn },
        .{ "fn_defn", parseFnDefn },
        .{ "export_stmt", parseExportStmt },
    });
}

/// Frees an AST returned by parseAbstractSyntaxTree().
pub fn freeAst(gpa: std.mem.Allocator, ast: types.AbstractSyntaxTree) void {
    freeNode(gpa, ast);
}

pub fn parseAbstractSyntaxTree(self: *Parser) ParseResult(types.AbstractSyntaxTree) {
    self.pos = 0;
    self.furthest = null;

    var items = std.ArrayList(types.TopItem).empty;
    errdefer self.discardItems(&items);

    self.skipWs();

    var first = true;
    while (true) {
        if (!first and !self.parseSep("Expected a newline between top-level items")) break;
        try items.ensureUnusedCapacity(self.gpa, 1);
        const item = try self.parseTopItem();
        if (item == .failure) break;
        items.appendAssumeCapacity(item.success);
        first = false;
    }

    self.skipWs();

    if (self.pos != self.source.len) {
        const msg = try self.describeFailure();
        self.discardItems(&items);
        return .{ .failure = msg };
    }

    return .{ .success = .{ .items = try items.toOwnedSlice(self.gpa) } };
}

const Outcome = union(enum) {
    ok: []const []const u8,
    err: []const u8,
};

fn parseSource(source: []const u8) !Outcome {
    const gpa = std.testing.allocator;
    var parser = Parser.init(gpa, source);

    switch (try parser.parseAbstractSyntaxTree()) {
        .success => |ast| {
            defer gpa.free(ast.items);
            var out = std.ArrayList([]const u8).empty;
            errdefer {
                for (out.items) |p| gpa.free(p);
                out.deinit(gpa);
            }
            for (ast.items) |item| {
                const path = item.import_stmt.path;
                defer gpa.free(path);
                try out.append(gpa, try std.mem.join(gpa, ".", path));
            }
            return .{ .ok = try out.toOwnedSlice(gpa) };
        },
        .failure => |msg| return .{ .err = msg },
    }
}

fn expectOk(source: []const u8, expected: []const []const u8) !void {
    switch (try parseSource(source)) {
        .ok => |paths| {
            defer {
                for (paths) |p| std.testing.allocator.free(p);
                std.testing.allocator.free(paths);
            }
            try std.testing.expectEqual(expected.len, paths.len);
            for (expected, paths) |e, a| try std.testing.expectEqualStrings(e, a);
        },
        .err => |msg| {
            defer std.testing.allocator.free(msg);
            std.debug.print("unexpected error: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectErr(source: []const u8, expected: []const u8) !void {
    switch (try parseSource(source)) {
        .ok => |paths| {
            for (paths) |p| std.testing.allocator.free(p);
            std.testing.allocator.free(paths);
            return error.TestUnexpectedResult;
        },
        .err => |msg| {
            defer std.testing.allocator.free(msg);
            try std.testing.expectEqualStrings(expected, msg);
        },
    }
}

const no_match = "No match for union type " ++ @typeName(types.TopItem);

test "empty and whitespace-only input" {
    try expectOk("", &.{});
    try expectOk("  \n\t\n $comment$ \n", &.{});
}

test "imports: single, dotted, several" {
    try expectOk("import a", &.{"a"});
    try expectOk("import a.b.c\n", &.{"a.b.c"});
    try expectOk("import a.b\nimport c\n", &.{ "a.b", "c" });
}

test "imports: whitespace, comments, blank lines, CRLF" {
    try expectOk("import   a", &.{"a"});
    try expectOk("import $c$ a", &.{"a"});
    try expectOk("import a $x$\n\n   import b.c  \n", &.{ "a", "b.c" });
    try expectOk("import a.b\r\nimport c\r\n", &.{ "a.b", "c" });
    try expectOk("import _x1.y_2", &.{"_x1.y_2"});
}

test "newlines inside an import are whitespace" {
    try expectOk("import\n  a.b", &.{"a.b"});
    try expectOk("import \r\n\r\n\ta", &.{"a"});
    try expectOk("import\n$c$\n a\nimport b", &.{ "a", "b" });
    try expectErr("import a\n.b\n", "line 2, column 1: " ++ no_match);
    try expectErr("import a .b\n", "line 1, column 10: Expected a newline between top-level items");
}

test "comments are single-line" {
    try expectOk("$one$ import a", &.{"a"});
    try expectOk("import $c$ a", &.{"a"});
    try expectOk("import $$ a", &.{"a"});
    try expectOk("import a $c$\nimport b", &.{ "a", "b" });
    try expectOk("import a $c$\r\n$d$\r\nimport b", &.{ "a", "b" });
    try expectOk("import a $é — ünïcode, and more$\nimport b", &.{ "a", "b" });
    try expectErr("import a\n$c$ foo", "line 2, column 5: " ++ no_match);
}

test "a comment cannot span lines" {
    const msg = "Unterminated comment (a comment must end with '$' on the same line)";
    try expectErr("$one\ntwo$ import a", "line 1, column 1: " ++ msg);
    try expectErr("import $one\ntwo$ a", "line 1, column 8: " ++ msg);
    try expectErr("import a $multi\nline$\nimport b", "line 1, column 10: " ++ msg);
    try expectErr("import a $c\r\nd$\nimport b", "line 1, column 10: " ++ msg);
    try expectErr("$a\rb$", "line 1, column 1: " ++ msg);
}

test "unterminated comment" {
    const msg = "Unterminated comment (a comment must end with '$' on the same line)";
    try expectErr("import a $oops\n", "line 1, column 10: " ++ msg);
    try expectErr("import a $oops", "line 1, column 10: " ++ msg);
    try expectErr("$", "line 1, column 1: " ++ msg);
    try expectErr("import $x\n a", "line 1, column 8: " ++ msg);
}

test "separator: newline, then any amount of whitespace" {
    try expectOk("import a\nimport b", &.{ "a", "b" });
    try expectOk("import a   $c$   \n   import b", &.{ "a", "b" });
    try expectOk("import a\n\n\n  $c$\n\t\nimport b", &.{ "a", "b" });
    try expectErr("import a   $c$   import b", "line 1, column 18: Expected a newline between top-level items");
}

test "items must be separated by a newline" {
    try expectErr("import a import b\n", "line 1, column 10: Expected a newline between top-level items");
    try expectErr("import a\rimport b\n", "line 1, column 9: Expected a newline between top-level items");
}

test "trailing garbage is an error with a position" {
    try expectErr("foo bar", "line 1, column 1: " ++ no_match);
    try expectErr("import a\nbogus\n", "line 2, column 1: " ++ no_match);
}

test "malformed imports are reported" {
    try expectErr("import", "line 1, column 7: Expected whitespace after 'import'");
    try expectErr("important\n", "line 1, column 7: Expected whitespace after 'import'");
    try expectErr("import \n", "line 2, column 1: Expected a module name after 'import'");
    try expectErr("import fn\n", "line 1, column 8: Expected a module name after 'import'");
    try expectErr("import a.\n", "line 1, column 10: Expected a name after '.' in import path");
    try expectErr("import a. b\n", "line 1, column 10: Expected a name after '.' in import path");
    try expectErr("import A\n", "line 1, column 8: Expected a module name after 'import'");
}

test "keyword names are not value names" {
    try expectOk("import fnx", &.{"fnx"});
    try expectOk("import int_", &.{"int_"});
    try expectErr("import import\n", "line 1, column 8: Expected a module name after 'import'");
}

test "bytes outside ASCII outside of comments are rejected, not crashed on" {
    try expectErr("import \xff\n", "line 1, column 8: Expected a module name after 'import'");
    try expectErr("\x00", "line 1, column 1: " ++ no_match);
}

test "names are slices of the input, not copies" {
    const source = "import abc.def";
    var parser = Parser.init(std.testing.allocator, source);
    const ast = (try parser.parseAbstractSyntaxTree()).success;
    defer std.testing.allocator.free(ast.items);
    const path = ast.items[0].import_stmt.path;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(source.ptr + 7, path[0].ptr);
    try std.testing.expectEqual(source.ptr + 11, path[1].ptr);
}

test "a parser can be reused" {
    var parser = Parser.init(std.testing.allocator, "import a\nimport b");
    for (0..2) |_| {
        const ast = (try parser.parseAbstractSyntaxTree()).success;
        defer std.testing.allocator.free(ast.items);
        try std.testing.expectEqual(@as(usize, 2), ast.items.len);
        for (ast.items) |item| std.testing.allocator.free(item.import_stmt.path);
    }
}

test "large input" {
    var src = std.ArrayList(u8).empty;
    defer src.deinit(std.testing.allocator);
    var expected = std.ArrayList([]const u8).empty;
    defer expected.deinit(std.testing.allocator);
    for (0..2000) |_| {
        try src.appendSlice(std.testing.allocator, "import some_module.sub_module $c$\n");
        try expected.append(std.testing.allocator, "some_module.sub_module");
    }
    try expectOk(src.items, expected.items);
}

test "out of memory does not leak or double free" {
    const source = "import a.b\nimport c.d.e\nimport f";
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var parser = Parser.init(failing.allocator(), source);
        if (parser.parseAbstractSyntaxTree()) |result| {
            const ast = result.success;
            for (ast.items) |item| failing.allocator().free(item.import_stmt.path);
            failing.allocator().free(ast.items);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
    fail_index = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var parser = Parser.init(failing.allocator(), "import a\nimport b.\n");
        if (parser.parseAbstractSyntaxTree()) |result| {
            failing.allocator().free(result.failure);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

// ---------------------------------------------------------------------------
// Tests for the rest of the grammar.
// ---------------------------------------------------------------------------

const sample =
    \\$ a sample program touching every rule $
    \\import std.io
    \\import util
    \\
    \\smacro max(a, b) { ((a) > (b) ? (a) : (b)) }
    \\cmacro log(fmt, ...) { printf("{%s}\n", fmt); { nested \} } }
    \\
    \\struct Point {
    \\    x: int,
    \\    y: int,
    \\}
    \\struct Pair<A, B> { first: A, second: B }
    \\union Value { i: long long, f: double, s: *char, p: *Point }
    \\enum Color { RED, GREEN = 2, BLUE = 1 + 3, }
    \\
    \\alias Byte = unsigned char
    \\alias List<T> = [8]*T
    \\alias Callback = fn (x: int, ...) int
    \\
    \\extern errno: int
    \\extern fn printf(fmt: *char, ...) int
    \\counter: unsigned long long
    \\limit = 0x1F_FFu + 1_000ll
    \\origin = Point { x = 0, y = 0, }
    \\colors = { Color::RED, Color::GREEN, }
    \\pi = 3.14e-2d
    \\greeting = "hi \"there\"\n"
    \\letter = 'a'
    \\nothing = null
    \\
    \\fn add(a: int, b: int) int {
    \\    return a + b
    \\}
    \\
    \\fn generic<T, U>(p: *T, n: [4]U, f: fn (k: int) void) *T {
    \\    x: int
    \\    x = 1 + 2 * 3 - 4 / 2 % 3
    \\    y = (x << 2 | 1) & 0b101 ^ 7 as int
    \\    flag = not x == 3 and true or false
    \\    *p = -x
    \\    p.field[2](x, y,).next = &x
    \\    v = Value.i { 5 }
    \\    w = fn (a: int) int { return a }
    \\    z = max<int>(x, y) as *char
    \\    if a = f(x); a > 0 {
    \\        return a
    \\    } elif b = 2; b < 0 {
    \\        yield
    \\    } elif x {
    \\    } else c = 3; {
    \\        break 2
    \\    }
    \\    if x { continue }
    \\    else { return }
    \\    for i = 0; i < 10; i = i + 1 {
    \\        printf("%d", i)
    \\        { inner: int }
    \\    }
    \\    return $c$ x
    \\}
    \\
    \\export add, Point, counter,
    \\export generic
;

fn parseOwned(gpa: std.mem.Allocator, source: []const u8) !types.AbstractSyntaxTree {
    var parser = Parser.init(gpa, source);
    switch (try parser.parseAbstractSyntaxTree()) {
        .success => |ast| return ast,
        .failure => |msg| {
            defer gpa.free(msg);
            std.debug.print("unexpected error: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFailureMsg(source: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    var parser = Parser.init(gpa, source);
    switch (try parser.parseAbstractSyntaxTree()) {
        .success => |ast| {
            freeAst(gpa, ast);
            return error.TestUnexpectedResult;
        },
        .failure => |msg| {
            defer gpa.free(msg);
            try std.testing.expectEqualStrings(expected, msg);
        },
    }
}

test "sample program parses" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    const items = ast.items;
    try std.testing.expectEqual(@as(usize, 25), items.len);
    try std.testing.expectEqual(.import_stmt, std.meta.activeTag(items[0]));
    try std.testing.expectEqual(.macro_defn, std.meta.activeTag(items[2]));
    try std.testing.expectEqual(.type_defn, std.meta.activeTag(items[4]));
    try std.testing.expectEqual(.alias_stmt, std.meta.activeTag(items[9]));
    try std.testing.expectEqual(.var_decl, std.meta.activeTag(items[11]));
    try std.testing.expectEqual(.fn_decl, std.meta.activeTag(items[12]));
    try std.testing.expectEqual(.var_decl, std.meta.activeTag(items[13]));
    try std.testing.expectEqual(.var_defn, std.meta.activeTag(items[15]));
    try std.testing.expectEqual(.fn_defn, std.meta.activeTag(items[22]));
    try std.testing.expectEqual(.export_stmt, std.meta.activeTag(items[23]));
}

test "macros keep their raw body" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    const m = ast.items[2].macro_defn;
    try std.testing.expectEqual(.smacro, m.kind);
    try std.testing.expectEqualStrings("max", m.name);
    try std.testing.expectEqual(@as(usize, 2), m.args.len);
    try std.testing.expect(!m.variadic);
    try std.testing.expectEqualStrings(" ((a) > (b) ? (a) : (b)) ", m.body);

    const c = ast.items[3].macro_defn;
    try std.testing.expectEqual(.cmacro, c.kind);
    try std.testing.expect(c.variadic);
    try std.testing.expectEqual(@as(usize, 1), c.args.len);
    try std.testing.expectEqualStrings(" printf(\"{%s}\\n\", fmt); { nested \\} } ", c.body);
}

test "type definitions" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    const point = ast.items[4].type_defn.@"struct";
    try std.testing.expectEqualStrings("Point", point.tag.name);
    try std.testing.expectEqual(@as(usize, 2), point.members.len);

    const pair = ast.items[5].type_defn.@"struct";
    try std.testing.expectEqual(@as(usize, 2), pair.tag.comp_args.len);
    try std.testing.expectEqualStrings("B", pair.tag.comp_args[1]);

    const value = ast.items[6].type_defn.@"union";
    try std.testing.expectEqual(.longlong, value.members[0].type.int);
    try std.testing.expectEqual(.double, std.meta.activeTag(value.members[1].type));
    try std.testing.expect(value.members[2].type.pointer == .type);

    const color = ast.items[7].type_defn.@"enum";
    try std.testing.expectEqual(@as(usize, 3), color.members.len);
    try std.testing.expect(color.members[0].value == null);
    try std.testing.expectEqualStrings("2", color.members[1].value.?.primary.literal.int.value);
    try std.testing.expectEqualStrings("+", color.members[2].value.?.bin_op.op);
}

test "aliases and types" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    try std.testing.expectEqual(.uchar, ast.items[8].alias_stmt.type.int);
    const list = ast.items[9].alias_stmt;
    try std.testing.expectEqualStrings("List", list.name.name);
    try std.testing.expectEqual(.array, std.meta.activeTag(list.type));
    const cb = ast.items[10].alias_stmt.type.@"fn";
    try std.testing.expect(cb.variadic);
    try std.testing.expectEqual(@as(usize, 1), cb.args.len);
    try std.testing.expectEqual(.int, cb.ret_type.?.int);
    try std.testing.expectEqual(.ulonglong, ast.items[13].var_decl.var_decl.type.int);
}

test "globals and literals" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    try std.testing.expect(ast.items[11].var_decl.is_extern);
    try std.testing.expect(!ast.items[13].var_decl.is_extern);
    try std.testing.expect(ast.items[12].fn_decl.sig.variadic);

    const limit = ast.items[14].var_defn.value.bin_op;
    try std.testing.expectEqualStrings("+", limit.op);
    const lhs = limit.expr0.primary.literal.int;
    try std.testing.expectEqual(.uint, lhs.type);
    try std.testing.expectEqualStrings("0x1F_FF", lhs.value);
    try std.testing.expectEqual(.longlong, limit.expr1.primary.literal.int.type);

    const origin = ast.items[15].var_defn.value.primary.literal.@"struct";
    try std.testing.expectEqualStrings("Point", origin.tag.name);
    try std.testing.expectEqual(@as(usize, 2), origin.members.len);

    const colors = ast.items[16].var_defn.value.primary.literal.array;
    try std.testing.expectEqualStrings("GREEN", colors.values[1].primary.literal.@"enum".value);

    const pi = ast.items[17].var_defn.value.primary.literal.float;
    try std.testing.expectEqual(.double, pi.type);
    try std.testing.expectEqualStrings("3.14e-2", pi.value);
    try std.testing.expectEqualStrings("hi \\\"there\\\"\\n", ast.items[18].var_defn.value.primary.literal.string.value);
    try std.testing.expectEqualStrings("a", ast.items[19].var_defn.value.primary.literal.char.value);
    try std.testing.expect(ast.items[20].var_defn.value.primary.literal == .null);
}

test "functions and statements" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    const add = ast.items[21].fn_defn;
    try std.testing.expectEqualStrings("add", add.name);
    try std.testing.expectEqual(@as(usize, 2), add.sig.args.len);
    try std.testing.expectEqual(@as(usize, 1), add.scope.stmts.len);
    try std.testing.expectEqualStrings("+", add.scope.stmts[0].return_stmt.value.?.bin_op.op);

    const g = ast.items[22].fn_defn;
    try std.testing.expectEqual(@as(usize, 2), g.comp_args.len);
    try std.testing.expect(g.sig.ret_type != null);
    const stmts = g.scope.stmts;
    try std.testing.expectEqual(.var_decl, std.meta.activeTag(stmts[0]));
    try std.testing.expectEqual(.assign_stmt, std.meta.activeTag(stmts[1]));

    // precedence: 1 + 2 * 3 - 4 / 2 % 3  ==  (1 + (2 * 3)) - ((4 / 2) % 3)
    const sum = stmts[1].assign_stmt.value.bin_op;
    try std.testing.expectEqualStrings("-", sum.op);
    try std.testing.expectEqualStrings("+", sum.expr0.bin_op.op);
    try std.testing.expectEqualStrings("*", sum.expr0.bin_op.expr1.bin_op.op);
    try std.testing.expectEqualStrings("%", sum.expr1.bin_op.op);

    // `x << 2 | 1` etc. end up under `^`, with a cast binding tighter than `^`
    const y = stmts[2].assign_stmt.value.bin_op;
    try std.testing.expectEqualStrings("^", y.op);
    try std.testing.expectEqualStrings("&", y.expr0.bin_op.op);
    try std.testing.expectEqual(.cast, std.meta.activeTag(y.expr1.*));

    // `not x == 3 and true or false`: not binds tighter than ==
    const flag = stmts[3].assign_stmt.value.bin_op;
    try std.testing.expectEqualStrings("or", flag.op);
    try std.testing.expectEqualStrings("and", flag.expr0.bin_op.op);
    const eq = flag.expr0.bin_op.expr0.bin_op;
    try std.testing.expectEqualStrings("==", eq.op);
    try std.testing.expectEqualStrings("not", eq.expr0.un_op.op);

    // *p = -x
    try std.testing.expectEqualStrings("*", stmts[4].assign_stmt.target.un_op.op);
    try std.testing.expectEqualStrings("-", stmts[4].assign_stmt.value.un_op.op);

    // p.field[2](x, y,).next = &x
    const target = stmts[5].assign_stmt.target.member;
    try std.testing.expectEqualStrings("next", target.name);
    const call = target.base.fn_call;
    try std.testing.expectEqual(@as(usize, 2), call.dynm_args.len);
    try std.testing.expectEqual(.index, std.meta.activeTag(call.callee.*));
    try std.testing.expectEqualStrings("&", stmts[5].assign_stmt.value.un_op.op);

    // v = Value.i { 5 };  w = fn ...;  z = max<int>(x, y) as *char
    try std.testing.expectEqualStrings("i", stmts[6].assign_stmt.value.primary.literal.@"union".member);
    try std.testing.expectEqual(.lambda, std.meta.activeTag(stmts[7].assign_stmt.value.primary));
    const z = stmts[8].assign_stmt.value.cast;
    try std.testing.expectEqual(.pointer, std.meta.activeTag(z.type));
    const max_call = z.expr.fn_call;
    try std.testing.expectEqual(@as(usize, 1), max_call.callee.primary.value_ref.comp_args.len);
}

test "if, for and jump statements" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    const stmts = ast.items[22].fn_defn.scope.stmts;
    const first_if = stmts[9].if_stmt;
    try std.testing.expect(first_if.@"if".var_defn != null);
    try std.testing.expectEqualStrings("a", first_if.@"if".var_defn.?.name);
    try std.testing.expectEqual(@as(usize, 2), first_if.elif.len);
    try std.testing.expect(first_if.elif[0].var_defn != null);
    try std.testing.expect(first_if.elif[1].var_defn == null);
    try std.testing.expect(first_if.elif[1].scope.stmts.len == 0);
    try std.testing.expect(first_if.@"else".?.var_defn != null);
    try std.testing.expectEqualStrings("2", first_if.@"else".?.scope.stmts[0].break_stmt.index.?.primary.literal.int.value);
    try std.testing.expect(first_if.elif[0].scope.stmts[0].yield_stmt.value == null);

    const second_if = stmts[10].if_stmt;
    try std.testing.expectEqual(.continue_stmt, std.meta.activeTag(second_if.@"if".scope.stmts[0]));
    try std.testing.expect(second_if.@"else".?.scope.stmts[0].return_stmt.value == null);

    const loop = stmts[11].for_stmt;
    try std.testing.expectEqualStrings("i", loop.var_defn.name);
    try std.testing.expectEqualStrings("<", loop.expr.bin_op.op);
    try std.testing.expectEqual(.assign_stmt, std.meta.activeTag(loop.stmt.*));
    try std.testing.expectEqual(.fn_call, std.meta.activeTag(loop.scope.stmts[0]));
    try std.testing.expectEqual(.block_stmt, std.meta.activeTag(loop.scope.stmts[1]));

    try std.testing.expectEqualStrings("x", stmts[12].return_stmt.value.?.primary.value_ref.name);
}

test "exports and trailing commas" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, sample);
    defer freeAst(gpa, ast);

    const first = ast.items[23].export_stmt;
    try std.testing.expectEqual(@as(usize, 3), first.symbols.len);
    try std.testing.expectEqualStrings("Point", first.symbols[1]);
    try std.testing.expectEqualStrings("generic", ast.items[24].export_stmt.symbols[0]);

    // a trailing comma must not swallow the next item
    const src = "export a,\nb = 1\nexport c, d\n";
    const ast2 = try parseOwned(gpa, src);
    defer freeAst(gpa, ast2);
    try std.testing.expectEqual(@as(usize, 3), ast2.items.len);
    try std.testing.expectEqual(@as(usize, 1), ast2.items[0].export_stmt.symbols.len);
    try std.testing.expectEqual(.var_defn, std.meta.activeTag(ast2.items[1]));
    try std.testing.expectEqual(@as(usize, 2), ast2.items[2].export_stmt.symbols.len);
}

test "binary operators need whitespace, unary ones do not" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, "a = b - c\nd = b - -c\n");
    defer freeAst(gpa, ast);
    try std.testing.expectEqual(@as(usize, 2), ast.items.len);
    try std.testing.expectEqualStrings("-", ast.items[1].var_defn.value.bin_op.expr1.un_op.op);
    // `b-c` and `b -c` have no whitespace on both sides: not a binary operation
    try expectFailureMsg("d = b -c\n", "line 1, column 7: Expected a newline between top-level items");
    try expectFailureMsg("d = b-c\n", "line 1, column 6: Expected a newline between top-level items");
}

test "integer and float literal forms" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa,
        \\a = 1
        \\b = 2c
        \\c = 3us
        \\d = 4l
        \\e = 5ull
        \\f = 0b1010_1
        \\g = 0o777
        \\h = 1.5f
        \\i = 2.0e+3d
    );
    defer freeAst(gpa, ast);
    const expected = [_]types.IntType{ .int, .char, .ushort, .long, .ulonglong, .int, .int };
    for (expected, 0..) |t, i| {
        try std.testing.expectEqual(t, ast.items[i].var_defn.value.primary.literal.int.type);
    }
    try std.testing.expectEqualStrings("0o777", ast.items[6].var_defn.value.primary.literal.int.value);
    try std.testing.expectEqual(.float, ast.items[7].var_defn.value.primary.literal.float.type);
    try std.testing.expectEqualStrings("2.0e+3", ast.items[8].var_defn.value.primary.literal.float.value);
}

test "comments and newlines inside expressions" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa,
        \\x = a $one$ +
        \\    b
        \\y = obj
        \\    .field
        \\z = f(
        \\    1,
        \\    2,
        \\)
    );
    defer freeAst(gpa, ast);
    try std.testing.expectEqual(@as(usize, 3), ast.items.len);
    try std.testing.expectEqualStrings("+", ast.items[0].var_defn.value.bin_op.op);
    try std.testing.expectEqualStrings("field", ast.items[1].var_defn.value.member.name);
    try std.testing.expectEqual(@as(usize, 2), ast.items[2].var_defn.value.fn_call.dynm_args.len);
}

test "syntax errors have positions" {
    try expectFailureMsg("struct Point {\n    x: int\n", "line 3, column 1: Expected '}'");
    try expectFailureMsg("enum { A }\n", "line 1, column 6: Expected a type name after 'enum'");
    try expectFailureMsg("alias Foo int\n", "line 1, column 11: Expected '='");
    try expectFailureMsg("x = \"abc\n", "line 2, column 1: Unterminated string literal");
    try expectFailureMsg("x = \"a\\qb\"\n", "line 1, column 7: Invalid escape sequence in string literal");
    try expectFailureMsg("smacro m() { oops\n", "line 1, column 13: Unterminated macro body");
    try expectFailureMsg("fn f() {\n    x = 1 y = 2\n}\n", "line 2, column 11: Expected a newline between statements");
    try expectFailureMsg("fn f() { g(1, 2 }\n", "line 1, column 17: Expected ')'");
}

test "keywords are not names" {
    const gpa = std.testing.allocator;
    const ast = try parseOwned(gpa, "iffy = 1\nreturned = notable\nfunction = elsewhere\n");
    defer freeAst(gpa, ast);
    try std.testing.expectEqual(@as(usize, 3), ast.items.len);
    try expectFailureMsg("if = 1\n", "line 1, column 1: " ++ no_match);
}

test "expression-shape parsers" {
    // These each parse an expression whose outermost node is the named one.
    const gpa = std.testing.allocator;
    {
        var p = Parser.init(gpa, "a + b * c");
        const r = (try p.parseBinOp()).success;
        defer freeNode(gpa, r);
        try std.testing.expectEqualStrings("+", r.op);
    }
    {
        var p = Parser.init(gpa, "-a");
        const r = (try p.parseUnOp()).success;
        defer freeNode(gpa, r);
        try std.testing.expectEqualStrings("-", r.op);
    }
    {
        var p = Parser.init(gpa, "a as long");
        const r = (try p.parseCast()).success;
        defer freeNode(gpa, r);
        try std.testing.expectEqual(.long, r.type.int);
    }
    {
        var p = Parser.init(gpa, "a.b.c");
        const r = (try p.parseMember()).success;
        defer freeNode(gpa, r);
        try std.testing.expectEqualStrings("c", r.name);
    }
    {
        var p = Parser.init(gpa, "a[1]");
        const r = (try p.parseIndex()).success;
        defer freeNode(gpa, r);
        try std.testing.expectEqual(.primary, std.meta.activeTag(r.base.*));
    }
    {
        var p = Parser.init(gpa, "f(1)(2)");
        const r = (try p.parseFnCall()).success;
        defer freeNode(gpa, r);
        try std.testing.expectEqual(.fn_call, std.meta.activeTag(r.callee.*));
    }
    {
        // wrong shape: failure, position unchanged, nothing leaked
        var p = Parser.init(gpa, "a + b");
        try std.testing.expect((try p.parseMember()) == .failure);
        try std.testing.expectEqual(@as(usize, 0), p.pos);
    }
}

test "the sample survives out-of-memory at every allocation" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var parser = Parser.init(failing.allocator(), sample);
        if (parser.parseAbstractSyntaxTree()) |result| {
            freeAst(failing.allocator(), result.success);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
    // and on a failing parse, where partially built items must be freed
    const broken = sample ++ "\nfn oops( {\n";
    fail_index = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var parser = Parser.init(failing.allocator(), broken);
        if (parser.parseAbstractSyntaxTree()) |result| {
            failing.allocator().free(result.failure);
            break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
