const std = @import("std");

const ParserError = error{};

reader: std.Io.File.Reader,
checkpoints: std.Deque(u64),
buffer: u8[1024],

fn save(self: @This()) error{OutOfMemory}!void {
    try self.checkpoints.pushFront(std.heap.page_allocator, self.reader.logicalPos());
}

fn restore(self: @This()) error{ NoCheckpoint, SeekError }!void {
    const pos = self.checkpoints.popFront();
    if (pos) |p| {
        try self.reader.seekTo(p);
    } else {
        return error.NoCheckpoint;
    }
}

fn parseLiteral(self: @This(), lit: []const u8) !bool {
    try self.save();
    self.reader.interface.readSliceAll(self.buffer[0..lit.len]) catch |err| {
        if (err == std.io.Error.EndOfStream) {
            try self.restore();
            return false;
        } else {
            return err;
        }
    };
    if (std.mem.eql(u8, self.buffer[0..lit.len], lit)) {
        return true;
    } else {
        try self.restore();
        return false;
    }
}

fn parseName(self: @This()) !?[]const u8 {
    try self.save();
    self.buffer[0] = self.reader.interface.takeByte() catch |err| {
        if (err == std.io.Error.EndOfStream) {
            try self.restore();
            return null;
        } else {
            return err;
        }
    };
    if (!std.ascii.isAlphabetic(self.buffer[0]) and self.buffer[0] != '_') {
        try self.restore();
        return null;
    }
    var i = 1;
    while (true) : ({
        if (!std.ascii.isAlphanumeric(self.buffer[i]) and self.buffer[i] != '_') break;
        i += 1;
    }) {
        self.buffer[i] = self.reader.interface.takeByte() catch |err| {
            if (err == std.io.Error.EndOfStream) {
                break;
            } else {
                return err;
            }
        };
    }
    return self.buffer[0..i];
}
