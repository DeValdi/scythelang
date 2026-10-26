const std = @import("std");
const types = @import("types.zig");

const Parser = @This();

// ---------------------------------------------------------------------------
// Design
//
// The whole input is in memory (`source`), so the parser state is just one
// integer: `pos`, the index of the next unread byte. Line and column are not
// tracked while parsing; they are computed from `pos` only when an error is
// reported (see lineCol()).
//
// Backtracking:
//   const start = self.pos;   // remember
//   ...
//   self.pos = start;         // forget what was consumed
//   There is no frame stack to keep balanced.
//
// Failure contract:
//   A parse function that fails (returns false / null / `.failure`) leaves
//   `pos` exactly where it found it, so any function can be used inside an
//   optional or a repetition without cleanup.
//
// Ownership:
//   Names and other text in the AST are slices of `source` (no copies), so
//   the AST is only valid while `source` is alive. Slices that hold AST nodes
//   (e.g. the list of top items, an import path) are allocated with `gpa` and
//   owned by the caller. The same goes for the message of a `.failure` result
//   of parseAbstractSyntaxTree().
//
// Error reporting:
//   `.failure` carries a static message. To still be able to say *where*
//   something went wrong, functions that have already committed to a rule
//   (e.g. we saw `import`, so a name must follow) call noteFailure(), which
//   remembers the failure that got furthest into the input.
// ---------------------------------------------------------------------------

const ParseError = error{OutOfMemory};

fn ParseResult(comptime T: type) type {
    return ParseError!union(enum) {
        success: T,
        failure: []const u8,
    };
}

const ParseFailure = struct {
    pos: usize,
    msg: []const u8,
};

gpa: std.mem.Allocator,
source: []const u8,
pos: usize = 0,
furthest: ?ParseFailure = null,

pub fn init(gpa: std.mem.Allocator, source: []const u8) Parser {
    return .{ .gpa = gpa, .source = source };
}

fn noteFailure(self: *Parser, msg: []const u8) void {
    if (self.furthest) |f| {
        if (self.pos <= f.pos) return;
    }
    self.furthest = .{ .pos = self.pos, .msg = msg };
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
                self.noteFailure("Unterminated comment (a comment must end with '$' on the same line)");
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

fn parseSep(self: *Parser) bool {
    const start = self.pos;
    while (self.parseSp()) {}
    if (!self.parseNl()) {
        self.noteFailure("Expected a newline between top-level items");
        self.pos = start;
        return false;
    }
    self.skipWs();
    return true;
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
            .failure => self.pos = start, // superfluous
        }
    }

    const msg = "No match for union type " ++ @typeName(T);
    self.noteFailure(msg);
    return .{ .failure = msg };
}

fn describeFailure(self: *Parser) ParseError![]const u8 {
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
    for (items.items) |item| switch (item) {
        .import_stmt => |imp| self.gpa.free(imp.path),
        else => {},
    };
    items.deinit(self.gpa);
}

pub fn parseAbstractSyntaxTree(self: *Parser) ParseResult(types.AbstractSyntaxTree) {
    self.pos = 0;
    self.furthest = null;

    var items = std.ArrayList(types.TopItem).empty;
    errdefer self.discardItems(&items);

    self.skipWs();

    var first = true;
    while (true) {
        if (!first and !self.parseSep()) break;
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
    // ws includes newlines, so the path may start on a later line than `import`.
    const start = self.pos;

    if (!self.parseText("import")) return .{ .failure = "No import keyword" };

    // From here on we have seen `import`, so anything wrong is worth reporting.
    if (!self.parseWs()) {
        self.noteFailure("Expected whitespace after 'import'");
        self.pos = start;
        return .{ .failure = "No whitespace after 'import'" };
    }
    self.skipWs();

    var path = std.ArrayList([]const u8).empty;
    errdefer path.deinit(self.gpa);

    const first = self.parseValueName() orelse {
        self.noteFailure("Expected a module name after 'import'");
        self.pos = start;
        return .{ .failure = "No path root" };
    };
    try path.append(self.gpa, first);

    while (self.parseText(".")) {
        const elem = self.parseValueName() orelse {
            self.noteFailure("Expected a name after '.' in import path");
            self.pos = start;
            path.deinit(self.gpa);
            return .{ .failure = "No path element" };
        };
        try path.append(self.gpa, elem);
    }

    return .{ .success = .{ .path = try path.toOwnedSlice(self.gpa) } };
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
    return try self.parseUnion(types.TopItem, .{
        .{ "import_stmt", parseImportStmt },
    });
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

// ---------------------------------------------------------------------------
// Tests. They run under std.testing.allocator, so any leak (or double free)
// on a success path *or* a failure path fails the test.
// ---------------------------------------------------------------------------

/// Parses `source` and returns every top item's import path joined with '.'
/// (caller frees each string and the slice), or the error message (caller frees).
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
    // ...but the dots of the path allow no whitespace at all.
    try expectErr("import a\n.b\n", "line 2, column 1: " ++ no_match);
    try expectErr("import a .b\n", "line 1, column 10: Expected a newline between top-level items");
}

test "comments are single-line" {
    try expectOk("$one$ import a", &.{"a"});
    try expectOk("import $c$ a", &.{"a"});
    try expectOk("import $$ a", &.{"a"}); // an empty comment is fine
    try expectOk("import a $c$\nimport b", &.{ "a", "b" });
    try expectOk("import a $c$\r\n$d$\r\nimport b", &.{ "a", "b" });
    try expectOk("import a $é — ünïcode, and more$\nimport b", &.{ "a", "b" });
    // Error positions after a comment are still right.
    try expectErr("import a\n$c$ foo", "line 2, column 5: " ++ no_match);
}

test "a comment cannot span lines" {
    const msg = "Unterminated comment (a comment must end with '$' on the same line)";
    try expectErr("$one\ntwo$ import a", "line 1, column 1: " ++ msg);
    try expectErr("import $one\ntwo$ a", "line 1, column 8: " ++ msg);
    try expectErr("import a $multi\nline$\nimport b", "line 1, column 10: " ++ msg);
    try expectErr("import a $c\r\nd$\nimport b", "line 1, column 10: " ++ msg);
    // A lone '\r' is a line break character too.
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
    try expectOk("import a\n\n\n  $c$\n\t\nimport b", &.{ "a", "b" }); // blank lines and comment-only lines
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
    // `ws` includes newlines, so the name may be on the next line.
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
    // Fail the n-th allocation for every n until the parse succeeds.
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
    // And the same on the failure path (the message itself is allocated).
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
