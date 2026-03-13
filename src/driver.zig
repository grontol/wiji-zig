const std = @import("std");
const FileManager = @import("file_manager.zig");
const CompilerOptions = @import("options.zig");
const Reporter = @import("reporter.zig");
const SymbolManager = @import("symbol.zig").SymbolManager;
const TypeManager = @import("type.zig").TypeManager;
const Token = @import("token.zig").Token;
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const ast = @import("ast.zig");
const typer = @import("typer.zig");
const tast = @import("tast.zig");
const cgen = @import("cgen.zig");

const ModuleId = usize;

const Module = struct {
    name: []const u8,
    ast: ast.Module,
    typed: bool = false,
    tast: ?tast.Module = null,
    children: std.StringHashMap(ModuleId),
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    options: CompilerOptions,
    entry_dir: []const u8,
    file_manager: *FileManager,
    symbol_manager: *SymbolManager,
    type_manaager: *TypeManager,
    reporter: *Reporter,
    
    module_map: std.StringHashMap(ModuleId),
    modules: std.ArrayList(*Module),
    
    pub fn init(allocator: std.mem.Allocator, options: CompilerOptions) Driver {
        const file_manager = allocator.create(FileManager) catch unreachable;
        file_manager.* = FileManager.init(allocator);
        
        const symbol_manager = allocator.create(SymbolManager) catch unreachable;
        symbol_manager.* = SymbolManager.init(allocator, file_manager);
        
        const type_manager = allocator.create(TypeManager) catch unreachable;
        type_manager.* = TypeManager.init(allocator, allocator);
        
        const reporter = allocator.create(Reporter) catch unreachable;
        reporter.* = Reporter.init(file_manager, options);
        
        return .{
            .allocator = allocator,
            .options = options,
            .entry_dir = std.fs.path.dirname(options.entry_file) orelse "",
            .file_manager = file_manager,
            .symbol_manager = symbol_manager,
            .type_manaager = type_manager,
            .reporter = reporter,
            .module_map = std.StringHashMap(usize).init(allocator),
            .modules = .empty,
        };
    }
    
    pub fn run(self: *Driver) !void {
        const module_id = try self.loadModule(self.options.entry_file);
        const module = self.modules.items[module_id];
        
        self.typecheckModule(module_id);
        
        const tast_module = module.tast.?;
        
        if (self.options.emit_tast) {
            var tast_printer = tast.Printer.init(self.allocator);
            tast_printer.printModule(&tast_module);
            
            std.process.exit(0);
        }
        
        const c_source = cgen.cGen(self.allocator, &tast_module);
        
        if (self.options.emit_c) {
            std.debug.print("{s}\n", .{c_source});
            std.process.exit(0);
        }
        
        try cgen.cCompile(self.allocator, c_source, self.options.run);
    }
    
    fn loadModule(self: *Driver, path: []const u8) !ModuleId {
        const old_module_id = self.module_map.get(path);
        
        if (old_module_id) |id| {
            return id;
        }
        
        const file_index = self.file_manager.loadContent(path);
        const src = self.file_manager.getContent(file_index);
        
        const tokens = try lexer.tokenize(self.allocator, self.reporter, file_index, src);
        
        if (self.options.emit_token) {
            var buffer: [1024]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&buffer);
            const writer = &stdout_writer.interface;
            
            for (tokens) |token| {
                writer.print("- ", .{}) catch unreachable;
                token.print(writer, self.file_manager);
            }
            
            writer.flush() catch unreachable;
            std.process.exit(0);
        }
        
        const ast_module = parser.parse(self.allocator, self.file_manager, self.reporter, tokens);
        const module_id = self.modules.items.len;
        self.module_map.put(path, module_id) catch unreachable;
        
        // const module_name = std.fmt.allocPrint(self.allocator, "mod{}", .{module_id}) catch unreachable;
        const module_name = self.replacePathAsModuleName(path, module_id);
        const module = self.allocator.create(Module) catch unreachable;
        
        module.* = Module{
            .name = module_name,
            .ast = ast_module,
            .children = std.StringHashMap(ModuleId).init(self.allocator),
        };
        self.modules.append(self.allocator, module) catch unreachable;
        
        if (self.options.emit_ast) {
            var ast_printer = ast.Printer.init(self.allocator, self.file_manager);
            ast_printer.printModule(&ast_module);
            
            std.process.exit(0);
        }
        
        for (ast_module.imports) |import| {
            const path_str_with_quote = self.file_manager.getTokenText(import.path);
            const path_str = path_str_with_quote[1..path_str_with_quote.len - 1];
            const module_dir = std.fs.path.dirname(path) orelse "";
            const dir = std.fs.cwd().openDir(module_dir, .{}) catch unreachable;
            
            _ = dir.openFile(path_str, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        self.reporter.reportErrorAtToken(import.path, "Cannot import '{s}', file not found", .{path_str});
                    },
                    else => return err,
                }
            };
            
            const child_path = try std.fs.path.join(self.allocator, &[_][]const u8{
                module_dir,
                path_str,
            });
            
            module.children.put(path_str, try self.loadModule(child_path)) catch unreachable;
        }
        
        return module_id;
    }
    
    fn typecheckModule(self: *Driver, module_id: ModuleId) void {
        const module = self.modules.items[module_id];
        if (module.tast != null) return;
        
        module.typed = true;
        var iter = module.children.iterator();
        var tast_children = std.StringHashMap(*tast.Module).init(self.allocator);
        defer tast_children.clearAndFree();
        
        while (iter.next()) |entry| {
            self.typecheckModule(entry.value_ptr.*);
            tast_children.put(entry.key_ptr.*, &self.modules.items[entry.value_ptr.*].tast.?) catch unreachable;
        }
        
        module.tast = typer.typecheck(
            self.allocator,
            self.reporter,
            self.file_manager,
            self.symbol_manager,
            self.type_manaager,
            &module.ast,
            module_id,
            module.name,
            &tast_children,
        );
    }
    
    fn replacePathAsModuleName(self: *Driver, path: []const u8, module_id: ModuleId) []const u8 {
        const entry_dir_index = std.mem.indexOf(u8, path, self.entry_dir);
        const actual_path = if (entry_dir_index) |_| path[self.entry_dir.len..] else path;
        
        const extension_index = std.mem.lastIndexOf(u8, actual_path, ".");
        const actual_path_len = 1 + if (extension_index) |index| index else actual_path.len;
        
        var name_buffer: [1024]u8 = undefined;
        name_buffer[0] = '_';
        std.mem.copyForwards(u8, name_buffer[1..actual_path_len], actual_path[0..actual_path_len - 1]);
        
        const symbol_chars = ".-/\\:*?\"<>|";
        
        for (symbol_chars) |ch| {
            std.mem.replaceScalar(u8, &name_buffer, ch, '_');
        }
        
        const module_num = std.fmt.bufPrint(name_buffer[actual_path_len..], "_{}", .{module_id}) catch unreachable;
        const name = self.allocator.dupe(u8, name_buffer[0..actual_path_len + module_num.len]) catch unreachable;
        
        return name;
    }
};