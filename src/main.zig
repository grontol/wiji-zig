const std = @import("std");

const FileManager = @import("file_manager.zig");
const Reporter = @import("reporter.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const tast = @import("tast.zig");
const typer = @import("typer.zig");
const SymbolManager = @import("symbol.zig").SymbolManager;
const TypeManager = @import("type.zig").TypeManager;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var file_manager = FileManager.init(allocator);
    
    const file_index = file_manager.loadContent("examples/main.m");
    const src = file_manager.getContent(file_index);
    
    const reporter = Reporter.init(&file_manager);
    
    std.debug.print("----- LEXER -----\n\n", .{});
    const tokens = try lexer.tokenize(allocator, reporter, file_index, src);
    for (tokens) |token| {
        std.debug.print("- ", .{});
        token.print(&file_manager);
    }
    
    std.debug.print("\n----- PARSER -----\n\n", .{});
    const ast_module = parser.parse(allocator, reporter, tokens);
    
    var ast_printer: ast.Printer = .{ .file_manager = &file_manager };
    ast_printer.printModule(&ast_module);
    
    std.debug.print("\n----- TYPER -----\n\n", .{});
    var symbol_manager = SymbolManager.init(allocator);
    
    const tast_module = typer.typecheck(allocator, reporter, &file_manager, &symbol_manager, &ast_module);
    var tast_printer = tast.Printer.init();
    tast_printer.printModule(&tast_module);
}