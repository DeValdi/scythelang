const std = @import("std");
const types = @import("../syntax/types.zig");

const Synthesizer = @This();

allocator: std.mem.Allocator,
initial_indent: usize,
indent_text: []const u8,
newline_text: []const u8,

type_section: Section,

const Section = struct {
    synth: *const Synthesizer,
    name: []const u8,
    content: std.ArrayList(u8) = .empty,

    fn init(synth: *const Synthesizer, name: []const u8) error{OutOfMemory}!Section {
        var section = Section{
            .synth = synth,
            .name = name,
        };
        try section.appendIndented("// BEGIN SECTION: ", 0);
        try section.appendRaw(name);
        try section.appendRaw(synth.newline_text);
        return section;
    }

    fn appendRaw(self: *@This(), data: []const u8) error{OutOfMemory}!void {
        try self.content.appendSlice(self.synth.allocator, data);
    }

    fn appendIndented(self: *@This(), data: []const u8, indent: usize) error{OutOfMemory}!void {
        for (0..self.synth.initial_indent + indent) |_| try self.content.appendSlice(self.synth.allocator, self.synth.indent_text);
        try self.appendRaw(data);
    }

    fn synthesize(self: *@This(), writer: *std.Io.Writer) error{ OutOfMemory, WriteFailed }!void {
        try self.appendIndented("// END SECTION: ", 0);
        try self.appendRaw(self.name);
        try self.appendRaw(self.synth.newline_text);
        try writer.writeAll(self.content.items);
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
    try self.type_section.appendIndented("typedef struct {", indent);
    try self.type_section.appendRaw(self.newline_text);

    for (defn.members) |*member| {
        try self.type_section.appendIndented("", indent + 1);
        try self.synthesizeType(&member.type);
        try self.type_section.appendRaw(" ");
        try self.type_section.appendRaw(member.name);
        try self.type_section.appendRaw(";");
        try self.type_section.appendRaw(self.newline_text);
    }

    try self.type_section.appendIndented("} ", indent);
    try self.type_section.appendRaw(defn.tag.name);
    try self.type_section.appendRaw(";");
    try self.type_section.appendRaw(self.newline_text);
}

fn synthesizeType(self: *@This(), @"type": *const types.Type) error{OutOfMemory}!void {
    switch (@"type".*) {
        .int => try self.type_section.appendRaw("int"),
        else => {},
    }
}
