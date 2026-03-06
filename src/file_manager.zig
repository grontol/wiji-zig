const std = @import("std");
const Token = @import("token.zig").Token;

allocator: std.mem.Allocator,
file_index_map: std.StringHashMap(usize),
src_list: std.ArrayList([]const u8),
filename_list: std.ArrayList([]const u8),

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .file_index_map = std.StringHashMap(usize).init(allocator),
        .src_list = .empty,
        .filename_list = .empty,
    };
}

pub fn getContent(self: *const Self, index: usize) []const u8 {
    return self.src_list.items[index];
}

pub fn getFilename(self: *const Self, index: usize) []const u8 {
    return self.filename_list.items[index];
}

pub fn getTokenText(self: *const Self, token: Token) []const u8 {
    const src = self.getContent(token.loc.file_id);
    return src[token.loc.index..token.loc.index + token.loc.len];
}

pub fn loadContent(self: *Self, filename: []const u8) usize {
    if (self.file_index_map.get(filename)) |index| {
        return index;
    }
    
    const cwd = std.fs.cwd();
    
    const file = cwd.openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Cannot open file: {s}. File not found\n", .{filename});
            std.process.exit(1);
        },
        else => unreachable,
    };
    defer file.close();
    
    const stat = file.stat() catch unreachable;
    const file_size: usize = @intCast(stat.size);
    
    const index = self.src_list.items.len;
    const content: []u8 = file.readToEndAlloc(self.allocator, file_size) catch unreachable;
    
    self.file_index_map.put(filename, index) catch unreachable;
    self.src_list.append(self.allocator, content) catch unreachable;
    self.filename_list.append(self.allocator, filename) catch unreachable;
    
    return index;
}