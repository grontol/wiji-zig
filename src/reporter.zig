const std = @import("std");
const Token = @import("token.zig").Token;
const TokenSpan = @import("token.zig").TokenSpan;
const FileManager = @import("file_manager.zig");

file_manager: *FileManager,

const Self = @This();

pub fn init(file_manager: *FileManager) Self {
    return .{
        .file_manager = file_manager,
    };
}

pub fn reportErrorAtToken(self: Self, tok: Token, comptime msg: []const u8) noreturn {
    self.reportErrorAtTokenArgs(tok, msg, .{});
}

pub fn reportErrorAtTokenArgs(self: Self, token: Token, comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.debug.print("\n", .{});
    
    self.printFileLoc(token.loc.file_id, token.loc.line, token.loc.col);
    
    std.debug.panic("", .{});
}

pub fn reportErrorAfterToken(self: Self, tok: Token, comptime msg: []const u8) noreturn {
    self.reportErrorAtTokenArgs(tok, msg, .{});
}

pub fn reportErrorAfterTokenArgs(self: Self, token: Token, comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.debug.print("\n", .{});
    
    self.printFileLoc(token.loc.file_id, token.loc.line, token.loc.col);
    
    std.debug.panic("", .{});
}

pub fn reportErrorAtPos(self: Self, file_id: usize, line: usize, col: usize, index: usize, len: usize, comptime msg: []const u8) noreturn {
    self.reportErrorAtPosArgs(file_id, line, col, index, len, msg, .{});
}

pub fn reportErrorAtPosArgs(self: Self, file_id: usize, line: usize, col: usize, index: usize, len: usize, comptime msg: []const u8, args: anytype) noreturn {
    _ = index;
    _ = len;
    
    std.debug.print(msg, args);
    std.debug.print("\n", .{});
    
    self.printFileLoc(file_id, line, col);
    
    std.debug.panic("", .{});
}


pub fn reportErrorAtSpan(self: Self, span: TokenSpan, comptime msg: []const u8) noreturn {
    self.reportErrorAtSpanArgs(span, msg, .{});
}

pub fn reportErrorAtSpanArgs(self: Self, span: TokenSpan, comptime msg: []const u8, args: anytype) noreturn {
    std.debug.print(msg, args);
    std.debug.print("\n", .{});
    
    self.printFileLoc(span.file_id, span.line, span.col);
    
    std.debug.panic("", .{});
}

fn printFileLoc(self: Self, file_id: usize, line: usize, col: usize) void {
    const filename = self.file_manager.getFilename(file_id);
    std.debug.print("{s}:{d}:{d}\n", .{ filename, line, col });
}