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

pub fn main() !void {
    var args = std.process.args();
    const options = CompilerOptions.parse(&args);
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var file_manager = FileManager.init(allocator);
    
    const file_index = file_manager.loadContent(options.entry_file);
    const src = file_manager.getContent(file_index);
    
    const reporter = Reporter.init(&file_manager, options);
    
    const tokens = try lexer.tokenize(allocator, reporter, file_index, src);
    
    if (options.emit_token) {
        for (tokens) |token| {
            std.debug.print("- ", .{});
            token.print(&file_manager);
        }
        
        return;
    }
    
    const ast_module = parser.parse(allocator, reporter, tokens);
    
    if (options.emit_ast) {
        var ast_printer: ast.Printer = .{ .file_manager = &file_manager };
        ast_printer.printModule(&ast_module);
        
        return;
    }
    
    var symbol_manager = SymbolManager.init(allocator);
    
    if (options.emit_tast) {
        const tast_module = typer.typecheck(allocator, reporter, &file_manager, &symbol_manager, &ast_module);
        var tast_printer = tast.Printer.init(allocator);
        tast_printer.printModule(&tast_module);
    }
}