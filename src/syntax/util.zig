const std = @import("std");

pub fn dump(value: anytype) void {
    dumpIndent(value, 0);
}

fn indent(depth: usize) void {
    for (0..depth) |_| std.debug.print("  ", .{});
}

fn dumpIndent(value: anytype, depth: usize) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                indent(depth);
                std.debug.print("{s}:\n", .{field.name});
                dumpIndent(@field(value, field.name), depth + 1);
            }
        },

        .@"union" => |info| {
            if (info.tag_type) |Tag| {
                const tag = std.meta.activeTag(value);

                indent(depth);
                std.debug.print("{s}:\n", .{@tagName(tag)});

                inline for (info.fields) |field| {
                    if (tag == @field(Tag, field.name)) {
                        indent(depth + 1);
                        std.debug.print("payload ({s}):\n", .{field.name});
                        dumpIndent(@field(value, field.name), depth + 2);
                    }
                }
            } else {
                indent(depth);
                std.debug.print("(untagged union)\n", .{});
            }
        },

        .optional => {
            if (value) |v| {
                dumpIndent(v, depth);
            } else {
                indent(depth);
                std.debug.print("null\n", .{});
            }
        },

        .array => |info| {
            if (info.child == u8) {
                indent(depth);
                std.debug.print("\"{s}\"\n", .{value});
            } else {
                for (value, 0..) |item, i| {
                    indent(depth);
                    std.debug.print("[{d}]:\n", .{i});
                    dumpIndent(item, depth + 1);
                }
            }
        },

        .pointer => |info| {
            indent(depth);
            std.debug.print("pointer: size={s}, child={s}\n", .{
                @tagName(info.size),
                @typeName(info.child),
            });

            if (info.size == .one) {
                dumpIndent(value.*, depth);
            } else if (info.size == .slice) {
                if (info.child == u8) {
                    indent(depth);
                    std.debug.print("\"{s}\"\n", .{value});
                } else {
                    for (value, 0..) |item, i| {
                        indent(depth);
                        std.debug.print("[{d}]:\n", .{i});
                        dumpIndent(item, depth + 1);
                    }
                }
            } else {
                indent(depth);
                std.debug.print("{any}\n", .{value});
            }
        },

        else => {
            indent(depth);
            std.debug.print("{any}\n", .{value});
        },
    }
}
