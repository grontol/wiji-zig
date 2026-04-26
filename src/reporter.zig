const std = @import("std");
const Token = @import("token.zig").Token;
const TokenSpan = @import("token.zig").TokenSpan;
const FileManager = @import("file_manager.zig");
const CompilerOptions = @import("options.zig");

const ANSI_RED    = "\x1b[0;31m";
const ANSI_GREEN  = "\x1b[0;32m";
const ANSI_YELLOW = "\x1b[0;33m";
const ANSI_BLUE   = "\x1b[0;34m";
const ANSI_GRAY   = "\x1b[0;2m";
const ANSI_WHITE  = "\x1b[0;97m";
const ANSI_RESET  = "\x1b[0m";

const DiagnosticKind = enum {
    err,
    warn,
    note,
    info,
    
    fn text(self: @This()) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .note => "note",
            .info => "info",
        };
    }
    
    fn color(self: @This()) []const u8 {
        return switch (self) {
            .err => ANSI_RED,
            .warn => ANSI_YELLOW,
            .note => ANSI_BLUE,
            .info => ANSI_WHITE,
        };
    }
};

const Diagnostic = struct {
    loc: TokenSpan,
    msg: []const u8,
};

allocator: std.mem.Allocator,
file_manager: *FileManager,
compiler_options: CompilerOptions,
diagnostics: std.ArrayList(Diagnostic) = .empty,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, file_manager: *FileManager, compiler_options: CompilerOptions) Self {
    return .{
        .allocator = allocator,
        .file_manager = file_manager,
        .compiler_options = compiler_options,
    };
}

pub fn addDiagnostic(self: *Self, kind: DiagnosticKind, loc: TokenSpan, comptime msg: []const u8, args: anytype) void {
    var text = std.ArrayList(u8).empty;
    text.print(self.allocator, "{s}{s}: ", .{kind.color(), kind.text()}) catch unreachable;
    text.print(self.allocator, msg, args) catch unreachable;
    text.print(self.allocator, ANSI_RESET, .{}) catch unreachable;
    
    self.diagnostics.append(self.allocator, .{
        .loc = loc,
        .msg = text.items,
    }) catch unreachable;
}

pub fn reportErrorAtToken(self: *const Self, token: Token, comptime msg: []const u8, args: anytype) noreturn {
    self.printFileLoc(
        token.loc.file_id,
        token.loc.line,
        token.loc.col,
        token.loc.start,
        token.loc.end,
        msg,
        args,
    );
}

pub fn reportErrorAfterToken(self: *const Self, token: Token, comptime msg: []const u8, args: anytype) noreturn {
    self.printFileLoc(
        token.loc.file_id,
        token.loc.line,
        token.loc.col,
        token.loc.start,
        token.loc.end,
        msg,
        args,
    );
}

pub fn reportErrorAtPos(self: *const Self, file_id: usize, line: usize, col: usize, index: usize, len: usize, comptime msg: []const u8, args: anytype) noreturn {
    self.printFileLoc(file_id, line, col, index, index + len, msg, args);
}

pub fn reportErrorAtSpan(self: *const Self, span: TokenSpan, comptime msg: []const u8, args: anytype) noreturn {
    self.printFileLoc(span.file_id, span.line, span.col, span.start, span.end, msg, args);
}

fn printDiagnostics(self: *const Self, writer: *std.Io.Writer) void {    
    for (self.diagnostics.items) |d| {
        const filename = self.file_manager.getFilename(d.loc.file_id);
        writer.print("{s}:{d}:{d}:\n{s}\n", .{ filename, d.loc.line, d.loc.col, d.msg }) catch {};
    }
    
    writer.flush() catch {};
}

fn printFileLoc(self: *const Self, file_id: usize, line: usize, col: usize, start: usize, end: usize, comptime msg: []const u8, args: anytype) noreturn {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    const filename = self.file_manager.getFilename(file_id);
    
    switch (self.compiler_options.err_mode) {
        .dev => {
            writer.print("{s}:{d}:{d}:\n" ++ ANSI_RED, .{ filename, line, col }) catch {};
            writer.print("error: ", .{}) catch {};
            writer.print(msg, args) catch {};
            writer.print(ANSI_RESET ++ "\n", .{}) catch {};
            writer.flush() catch {};
            
            const src = self.file_manager.getContent(file_id);
            printSource(writer, src, line, start, end);
            self.printDiagnostics(writer);
            
            std.debug.panic("", .{});
        },
        .normal => {
            writer.print("{s}:{d}:{d}:\n" ++ ANSI_RED, .{ filename, line, col }) catch {};
            writer.print("error: ", .{}) catch {};
            writer.print(msg, args) catch {};
            writer.print(ANSI_RESET ++ "\n", .{}) catch {};
            writer.flush() catch {};
            
            const src = self.file_manager.getContent(file_id);
            printSource(writer, src, line, start, end);
            self.printDiagnostics(writer);
            
            std.process.exit(0);
        },
        .minimal => {
            writer.print(msg, args) catch {};
            writer.print("\n", .{}) catch {};
            writer.flush() catch {};
            std.process.exit(0);
        },
    }
}

fn printSource(writer: *std.io.Writer, src: []const u8, line: usize, start: usize, end: usize) void {
    writer.writeByte('\n') catch {};
    
    var start_index = start;
    var new_line_before_count: usize = 0;
    
    {
        var i: i32 = if (start > 0) @intCast(start - 1) else 0;
        
        while (i >= 0) : (i -= 1) {
            if (i == 0 or src[@intCast(i)] == '\n') {
                new_line_before_count += 1;
                
                if (i == 0) {
                    start_index = 0;
                    break;
                }
            }
            
            if (new_line_before_count >= 3) break;
            start_index -= 1;
        }
    }
    
    var end_index = end;
    var new_line_after_count: usize = 0;
    
    for (end..src.len) |i| {
        if (src[i] == '\n') {
            new_line_after_count += 1;
        }
        
        if (new_line_after_count >= 3) break;
        end_index += 1;
    }
    
    var cur_line = line - new_line_before_count + 1;
    var last_line = line + new_line_after_count;
    var line_width: usize = 1;
    
    while (last_line >= 10) {
        last_line /= 10;
        line_width += 1;
    }
    
    var last_line_start_index: usize = 0;
    var has_error = false;
    
    for (start_index..end_index) |i| {
        if (i == 0 or src[i - 1] == '\n') {
            writer.print(ANSI_GRAY ++ "{[line]: >[width]}  | " ++ ANSI_RESET, .{
                .line = cur_line,
                .width = line_width,
            }) catch {};
            cur_line += 1;
        }
        
        writer.writeByte(src[i]) catch {};
        
        if (src[i] == '\n') {
            last_line_start_index = i + 1;
            has_error = false;
        }
        
        if (!has_error and i >= start and i < end) {
            has_error = true;
        }
        
        if (has_error and (i == end_index - 1 or src[i + 1] == '\n')) {
            writer.writeByte('\n') catch {};
            
            for (0..line_width + 4) |_| {
                writer.writeByte(' ') catch {};
            }
            
            writer.print(ANSI_RED, .{}) catch {};
            
            {
                var j = last_line_start_index;
                while (j <= i) : (j += 1) {
                    if (j >= start and j < end) {
                        writer.writeByte('^') catch {};
                    }
                    else {
                        writer.writeByte(' ') catch {};
                    }
                }
            }
        }
    }
    
    writer.print(ANSI_RESET ++ "\n\n", .{}) catch {};
    writer.flush() catch {};
}