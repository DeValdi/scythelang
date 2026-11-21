const std = @import("std");
const types = @import("../syntax/types.zig");

const Synthesizer = @This();

allocator: std.mem.Allocator,
initial_indent: usize,
indent_text: []const u8,
newline_text: []const u8,

type_section: Section,
lambda_section: Section,
macro_section: Section,

history: std.BufSet,

lambda_ctr: usize = 0,

const Section = struct {
    synth: *const Synthesizer,
    name: []const u8,
    content: std.ArrayList(u8) = .empty,

    fn init(synth: *const Synthesizer, name: []const u8) error{OutOfMemory}!Section {
        var section = Section{
            .synth = synth,
            .name = name,
        };
        try section.append("// BEGIN SECTION: {s}{s}", .{ name, synth.newline_text }, 0);
        return section;
    }

    fn append(self: *@This(), comptime fmt: []const u8, args: anytype, indent: usize) error{OutOfMemory}!void {
        for (0..self.synth.initial_indent + indent) |_| try self.content.appendSlice(self.synth.allocator, self.synth.indent_text);
        try self.content.print(self.synth.allocator, fmt, args);
    }

    fn synthesize(self: *@This(), writer: *std.Io.Writer) error{ OutOfMemory, WriteFailed }!void {
        try self.append("// END SECTION: {s}{s}", .{ self.name, self.synth.newline_text }, 0);
        try writer.writeAll(self.content.items);
    }
};

const ScopeInfo = struct {
    is_macro: bool,
    num_scopes: usize = 0,
    last_is_loop: bool = false,

    fn inc(self: *const @This(), is_loop: bool) ScopeInfo {
        return .{
            .is_macro = self.is_macro,
            .num_scopes = self.num_scopes + 1,
            .last_is_loop = is_loop,
        };
    }
};

pub fn init(allocator: std.mem.Allocator, initialIndent: usize, indentText: []const u8, newLineText: []const u8) error{OutOfMemory}!*Synthesizer {
    const synth = try allocator.create(Synthesizer);
    synth.* = .{
        .allocator = allocator,
        .initial_indent = initialIndent,
        .indent_text = indentText,
        .newline_text = newLineText,

        .type_section = try Section.init(synth, "Types"),
        .lambda_section = try Section.init(synth, "Lambdas"),
        .macro_section = try Section.init(synth, "Macros"),

        .history = std.BufSet.init(allocator),
    };
    return synth;
}

pub fn synthesize(self: *@This(), writer: *std.Io.Writer, ast: *const types.AbstractSyntaxTree) error{ OutOfMemory, WriteFailed }!void {
    for (ast.items) |*item| try self.synthesizeTopItem(item, 1);
    try self.type_section.synthesize(writer);
}

fn synthesizeTopItem(self: *@This(), item: *const types.TopItem, indent: usize) error{OutOfMemory}!void {
    switch (item.*) {
        .type_defn => |*value| try self.synthesizeTypeDefn(value, indent),
        else => {},
    }
}

fn synthesizeTypeDefn(self: *@This(), defn: *const types.TypeDefn, indent: usize) error{OutOfMemory}!void {
    switch (defn.*) {
        .@"struct" => |*value| try self.synthesizeStructDefn(value, indent),
        else => {},
    }
}

fn synthesizeStructDefn(self: *@This(), defn: *const types.StructDefn, indent: usize) error{OutOfMemory}!void {
    try self.type_section.append("typedef struct {{{s}", .{self.newline_text}, indent);

    for (defn.members) |*member| {
        try self.type_section.append("", .{}, indent + 1);
        try self.synthesizeType(&member.type, &self.type_section);
        try self.type_section.append(" {s};{s}", .{ member.name, self.newline_text }, 0);
    }

    try self.type_section.append("}} {s};{s}", .{ defn.tag.name, self.newline_text }, indent);
}

fn synthesizeFnSig(self: *@This(), sig: *const types.FnSig, name: []const u8, section: *Section) error{OutOfMemory}!void {
    try self.synthesizeType(if (sig.ret_type) |ret_type| ret_type else &.void, section);
    try section.append(" {s}(", .{name}, 0);
    for (sig.args, 0..) |*a, i| {
        if (i > 0) {
            try section.append(", ", .{}, 0);
        }
        try self.synthesizeType(&a.type, section);
        try section.append(" {s}", .{a.name}, 0);
    }
    if (sig.variadic) {
        if (sig.args.len > 0) {
            try section.append(", ", .{}, 0);
        }
        try section.append("...", .{}, 0);
    }
    try section.append(")", .{}, 0);
}

fn synthesizeType(self: *@This(), @"type": *const types.Type, section: *Section) error{OutOfMemory}!void {
    switch (@"type".*) {
        .int => |*int_type| try self.synthesizeInt(int_type, section),
        .float => try section.append("float", .{}, 0),
        .double => try section.append("double", .{}, 0),
        .void => try section.append("void", .{}, 0),
        .bool => try section.append("bool", .{}, 0),
        .named => |*type_ref| {
            try section.append("{s}", .{type_ref.name}, 0);
            for (type_ref.comp_args) |*t| {
                try section.append("$", .{}, 0);
                try self.synthesizeType(t, section);
            }
        },
        .pointer => |*ptr_type| {
            try section.append("typeof(", .{}, 0);
            switch (ptr_type.*) {
                .@"fn" => |fn_name| {
                    try section.append("{s}$State", .{fn_name}, 0);
                },
                .type => |t| {
                    try self.synthesizeType(t, section);
                },
            }
            try section.append(" *)", .{}, 0);
        },
        .array => |*arr_type| {
            try section.append("typeof(", .{}, 0);
            try self.synthesizeType(arr_type.type, section);
            try section.append("[", .{}, 0);
            try self.synthesizeExpr(arr_type.len, section);
            try section.append("])", .{}, 0);
        },
        .@"fn" => |*fn_sig| {
            try self.synthesizeFnSig(fn_sig, "", section);
        },
    }
}

fn synthesizeInt(self: *@This(), @"type": *const types.IntType, section: *Section) error{OutOfMemory}!void {
    _ = self;
    const type_name = switch (@"type".*) {
        .char => "char",
        .short => "short",
        .int => "int",
        .long => "long",
        .longlong => "long long",
        .uchar => "unsigned char",
        .ushort => "unsigned short",
        .uint => "unsigned int",
        .ulong => "unsigned long",
        .ulonglong => "unsigned long long",
    };
    try section.append("{s}", .{type_name}, 0);
}

fn synthesizeExpr(self: *@This(), expr: *const types.Expr, section: *Section) error{OutOfMemory}!void {
    switch (expr.*) {
        .primary => |*primary| {
            switch (primary.*) {
                .literal => |*lit| {
                    switch (lit.*) {
                        .int => |*int_lit| {
                            var needs_cast = true;
                            switch (int_lit.type) {
                                .char => {
                                    try section.append("(char)(", .{}, 0);
                                },
                                .short => {
                                    try section.append("(short)(", .{}, 0);
                                },
                                .uchar => {
                                    try section.append("(unsigned char)(", .{}, 0);
                                },
                                .ushort => {
                                    try section.append("(unsigned short)(", .{}, 0);
                                },
                                else => {
                                    needs_cast = false;
                                },
                            }
                            try section.append("{s}", .{int_lit.value}, 0);
                            switch (int_lit.type) {
                                .uchar, .ushort, .uint, .ulong, .ulonglong => {
                                    try section.append("u", .{}, 0);
                                },
                                else => {},
                            }
                            switch (int_lit.type) {
                                .long, .ulong => {
                                    try section.append("l", .{}, 0);
                                },
                                .longlong, .ulonglong => {
                                    try section.append("ll", .{}, 0);
                                },
                                else => {},
                            }
                            if (needs_cast) {
                                try section.append(")", .{}, 0);
                            }
                        },
                        .float => |*float_lit| {
                            try section.append("{s}{s}", .{
                                float_lit.value,
                                switch (float_lit.type) {
                                    .float => "f",
                                    .double => "d",
                                },
                            }, 0);
                        },
                        .bool => |*bool_lit| {
                            try section.append("{s}", .{bool_lit.value}, 0);
                        },
                        .array => |*arr_lit| {
                            try section.append("{{ ", .{}, 0);
                            for (arr_lit.values, 0..) |*v, i| {
                                if (i > 0) {
                                    try section.append(", ", .{}, 0);
                                }
                                try self.synthesizeExpr(v, section);
                            }
                        },
                        .@"struct" => |*struct_lit| {
                            try section.append("({s}", .{struct_lit.tag.name}, 0);
                            if (struct_lit.tag.comp_args.len > 0) {
                                for (struct_lit.tag.comp_args) |*a| {
                                    try section.append("$", .{}, 0);
                                    try self.synthesizeType(a, section);
                                }
                            }
                            try section.append("{{ ", .{}, 0);
                            for (struct_lit.members, 0..) |*m, i| {
                                if (i > 0) {
                                    try section.append(", ", .{}, 0);
                                }
                                try section.append(".{s} = ", .{m.name}, 0);
                                try self.synthesizeExpr(&m.value, section);
                            }
                            try section.append(" }}", .{}, 0);
                        },
                        .@"union" => |union_lit| {
                            try section.append("({s}", .{union_lit.tag.name}, 0);
                            if (union_lit.tag.comp_args.len > 0) {
                                for (union_lit.tag.comp_args) |*a| {
                                    try section.append("$", .{}, 0);
                                    try self.synthesizeType(a, section);
                                }
                            }
                            try section.append("{{ .{s} = ", .{union_lit.member}, 0);
                            try self.synthesizeExpr(union_lit.value, section);
                            try section.append(" }}", .{}, 0);
                        },
                        .@"enum" => |enum_lit| {
                            try section.append("{s}${s}", .{ enum_lit.namespace, enum_lit.value }, 0);
                        },
                        .string => |str_lit| {
                            try section.append("\"{s}\"", .{str_lit.value}, 0);
                        },
                        .char => |chr_lit| {
                            try section.append("'{s}'", .{chr_lit.value}, 0);
                        },
                        .null => {
                            try section.append("nullptr", .{}, 0);
                        },
                    }
                },
                .value_ref => |*ref| {
                    try section.append("{s}", .{ref.name}, 0);
                    for (ref.comp_args) |*a| {
                        try section.append("$", .{}, 0);
                        try self.synthesizeType(a, section);
                    }
                },
                .expr => |inner| {
                    try section.append("(", .{}, 0);
                    try self.synthesizeExpr(inner, section);
                    try section.append(")", .{}, 0);
                },
                .lambda => |*lambda| {
                    const fn_name = try std.fmt.allocPrint(self.allocator, "$Lambda{d}", .{self.lambda_ctr});
                    self.lambda_ctr += 1;
                    try section.append("{s}", .{fn_name}, 0);
                    try self.synthesizeFnDefn(&.{
                        .name = fn_name,
                        .comp_args = &.{},
                        .sig = lambda.sig,
                        .scope = lambda.scope,
                    }, &self.lambda_section);
                },
            }
        },
        .un_op => |*un_op| {
            try section.append("{s}", .{un_op.op}, 0);
            try self.synthesizeExpr(un_op.expr, section);
        },
        .bin_op => |*bin_op| {
            try self.synthesizeExpr(bin_op.expr0, section);
            try section.append(" {s} ", .{bin_op.op}, 0);
            try self.synthesizeExpr(bin_op.expr1, section);
        },
        .cast => |*cast| {
            try section.append("(", .{}, 0);
            try self.synthesizeType(&cast.type, section);
            try section.append(")(", .{}, 0);
            try self.synthesizeExpr(cast.expr, section);
            try section.append(")", .{}, 0);
        },
        .member => |*member| {
            try self.synthesizeExpr(member.base, section);
            try section.append(".{s}", .{member.name}, 0);
        },
        .index => |*index| {
            try self.synthesizeExpr(index.base, section);
            try section.append("[", .{}, 0);
            try self.synthesizeExpr(index.offset, section);
            try section.append("]", .{}, 0);
        },
        .fn_call => |*fn_call| {
            try self.synthesizeExpr(fn_call.callee, section);
            try section.append("(", .{}, 0);
            for (fn_call.dynm_args, 0..) |*a, i| {
                if (i > 0) {
                    try section.append(", ", .{}, 0);
                }
                try self.synthesizeExpr(a, section);
            }
        },
    }
}

fn synthesizeFnDefn(self: *@This(), fn_defn: *const types.FnDefn, section: *Section) error{OutOfMemory}!void {
    if (fn_defn.comp_args.len == 0) {
        try section.append("static ", .{}, 0);
        try self.synthesizeFnSig(&fn_defn.sig, fn_defn.name, section);
        try section.append(" {{{s}", .{self.newline_text}, 0);
        try self.synthesizeScope(&fn_defn.scope, .{ .is_macro = false }, 1, section);
        try section.append("}}{s}", .{self.newline_text}, 0);
    } else {
        try self.macro_section.append("#define {s}(", .{fn_defn.name}, 0);
        for (fn_defn.comp_args, 0..) |a, i| {
            if (i > 0) {
                try self.macro_section.append(", ", .{}, 0);
            }
            try self.macro_section.append("{s}", .{a}, 0);
        }
        try self.macro_section.append(")\\{s}", .{self.newline_text}, 0);
        try self.synthesizeScope(&fn_defn.scope, .{ .is_macro = true }, 1, &self.macro_section);
        try self.macro_section.append("{s}", .{self.newline_text}, 0);
    }
}

fn synthesizeScope(self: *@This(), scope: *const types.Scope, scopes: ScopeInfo, indent: usize, section: *Section) error{OutOfMemory}!void {
    for (scope.stmts) |*stmt| {
        try section.append("", .{}, indent);
        switch (stmt.*) {
            .assign_stmt => |*assign_stmt| {
                try self.synthesizeExpr(&assign_stmt.target, section);
                try section.append(" = ", .{}, 0);
                try self.synthesizeExpr(&assign_stmt.value, section);
                try section.append(";{s}", .{self.newline_text}, 0);
            },
            .block_stmt => |*block_stmt| {
                try section.append("{{{s}", .{self.newline_text}, indent);
                try self.synthesizeScope(&block_stmt.scope, scopes.inc(false), indent + 1, section);
                try section.append("}}{s}", .{self.newline_text}, indent);
            },
            .break_stmt => |*break_stmt| {
                try self.synthesizeJump("break", &break_stmt.index, scopes, indent, section);
            },
            .continue_stmt => |*continue_stmt| {
                try self.synthesizeJump("continue", &continue_stmt.index, scopes, indent, section);
            },
            .fn_call => |*fn_call| {
                _ = fn_call;
            },
            else => {},
        }
    }
}

fn synthesizeJump(self: *@This(), comptime stmt: []const u8, index_expr: *const ?types.Expr, scopes: ScopeInfo, indent: usize, section: *Section) error{OutOfMemory}!void {
    if (index_expr.*) |*index| {
        try section.append("switch (", .{}, indent);
        try self.synthesizeExpr(index, section);
        try section.append(") {{{s}", .{self.newline_text}, 0);
        for (0..scopes.num_scopes) |i| {
            try section.append("case  {d}: goto $" ++ stmt ++ "${d};{s}", .{ 1 + i, i, self.newline_text }, indent + 1);
            try section.append("case -{d}: goto $" ++ stmt ++ "${d};{s}", .{ 1 + i, scopes.num_scopes - (1 + i), self.newline_text }, indent + 1);
        }
        try section.append("}}{s}", .{self.newline_text}, indent);
        try section.append(stmt ++ ";{s}", .{self.newline_text}, indent);
    } else {
        try section.append("goto $" ++ stmt ++ "${d};{s}", .{ scopes.num_scopes - 1, self.newline_text }, indent);
    }
}
