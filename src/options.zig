const std = @import("std");

pub const ErrMode = enum {
    normal,
    minimal,
};

entry_file: []const u8,
emit_token: bool = false,
emit_ast: bool = false,
emit_tast: bool = false,
emit_c: bool = false,
run: bool = false,
err_mode: ErrMode = .normal,

const CompilerOptions = @This();

pub fn parse(args: *std.process.ArgIterator) CompilerOptions {
    const program_name = args.next().?;
    const entry_file = args.next().?;
    
    var opt = CompilerOptions{
        .entry_file = entry_file,
    };
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--run")) {
            opt.run = true;
        }
        else if (std.mem.eql(u8, arg, "--emit")) {
            if (args.next()) |sub_arg| {
                if (std.mem.eql(u8, sub_arg, "token")) {
                    opt.emit_token = true;
                }
                else if (std.mem.eql(u8, sub_arg, "ast")) {
                    opt.emit_ast = true;
                }
                else if (std.mem.eql(u8, sub_arg, "tast")) {
                    opt.emit_tast = true;
                }
                else if (std.mem.eql(u8, sub_arg, "c")) {
                    opt.emit_c = true;
                }
                else {
                    showUsage(program_name, "Invalid --emit argument");
                }
            }
            else {
                showUsage(program_name, "--emit needs an argument");
            }
        }
        else if (std.mem.eql(u8, arg, "-err")) {
            if (args.next()) |sub_arg| {
                if (std.mem.eql(u8, sub_arg, "normal")) {
                    opt.err_mode = .normal;
                }
                else if (std.mem.eql(u8, sub_arg, "minimal")) {
                    opt.err_mode = .minimal;
                }
                else {
                    showUsage(program_name, "Invalid --err argument");
                }
            }
            else {
                showUsage(program_name, "--err needs an argument");
            }
        }
    }
    
    return opt;
}

fn showUsage(program_name: []const u8, comptime fmt: []const u8) noreturn {
    showUsageArgs(program_name, fmt, .{});
}

fn showUsageArgs(program_name: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    _ = program_name;
    std.debug.print(fmt, args);
    std.process.exit(1);
}