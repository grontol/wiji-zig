const std = @import("std");

const FileManager = @import("file_manager.zig");
const CompilerOptions = @import("options.zig");
const Reporter = @import("reporter.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const tast = @import("tast.zig");
const typer = @import("typer.zig");
const SymbolManager = @import("symbol.zig").SymbolManager;
const TypeManager = @import("type.zig").TypeManager;
const cgen = @import("cgen.zig");
const Driver = @import("driver.zig").Driver;

pub fn main() !void {    
    var args = std.process.args();    
    const options = CompilerOptions.parse(&args);
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var driver = Driver.init(allocator, options);
    try driver.run();
}

// pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
//     std.debug.print("PANIC {s}\n", .{msg});
//     _ = stack_trace;
//     _ = addr;
    
//     // std.debug.defaultPanic(msg, addr);
    
//     std.process.exit(1);
// }