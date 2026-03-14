const std = @import("std");

const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;
const TokenSpan = @import("token.zig").TokenSpan;
const ast = @import("ast.zig");
const types = @import("type.zig");
const tast = @import("tast.zig");
const Type = types.Type;
const TypeManager = types.TypeManager;
const Reporter = @import("reporter.zig");
const Symbol = @import("symbol.zig").Symbol;
const TypedSymbol = @import("symbol.zig").TypedSymbol;
const Mutability = @import("symbol.zig").Mutability;
const SymbolManager = @import("symbol.zig").SymbolManager;
const FileManager = @import("file_manager.zig");
const Scope =@import("scope.zig").Scope;

fn doesAllPathHasReturn(block: *const tast.Block) bool {
    for (block.stmts) |stmt| {
        if (doesStmtHasReturn(&stmt)) {
            return true;
        }
    }
    
    return false;
}

fn doesStmtHasReturn(stmt: *const tast.Stmt) bool {
    switch (stmt.*) {
        .returns => { return true; },
        .block => |block| {
            if (doesAllPathHasReturn(&block)) {
                return true;
            }
        },
        .iff => |iff| {
            if (iff.else_stmt == null) return false;
            if (!doesStmtHasReturn(iff.body)) return false;
            if (!doesStmtHasReturn(iff.else_stmt.?)) return false;
            
            return true;
        },
        else => {},
    }
    
    return false;
}

const FnDeclData = struct {
    tast: tast.FnDecl,
    ast: *const ast.FnDecl,
    span: TokenSpan,
    scope: *Scope,
};

const StructDeclData = struct {
    typ: *Type,
    ast: *const ast.StructDecl,
    scope: *Scope,
};

const EnumDeclData = struct {
    typ: *Type,
    ast: *const ast.EnumDecl,
    scope: *Scope,
};

const Typer = struct {
    arena: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    reporter: *const Reporter,
    file_manager: *const FileManager,
    type_manager: *TypeManager,
    symbol_manager: *SymbolManager,
    children: *const std.StringHashMap(*tast.Module),
    
    var_decls: std.ArrayList(tast.VarDecl) = .empty,
    fn_decls: std.ArrayList(FnDeclData) = .empty,
    
    cur_fn: ?*tast.FnDecl = null,
    
    fn init(
        arena: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        reporter: *const Reporter,
        file_manager: *const FileManager,
        type_manager: *TypeManager,
        symbol_manager: *SymbolManager,
        children: *const std.StringHashMap(*tast.Module),
    ) Typer {
        return .{
            .arena = arena,
            .temp_allocator = temp_allocator,
            .reporter = reporter,
            .file_manager = file_manager,
            .type_manager = type_manager,
            .symbol_manager = symbol_manager,
            .children = children,
        };
    }
    
    fn typeModule(self: *Typer, scope: *Scope, module: *const ast.Module, module_id: usize, module_name: []const u8) tast.Module {
        self.symbol_manager.pushNamespace(module_name);
        const stmts = self.typeStmts(scope, module.exprs);
        self.symbol_manager.popNamespace();
        
        for (stmts) |stmt| {
            switch (stmt) {
                .noop => {},
                .var_decl => |var_decl| { self.var_decls.append(self.arena, var_decl) catch unreachable; },
                else => {
                    std.debug.panic("UNREACHABLE: {s}", .{@tagName(stmt)});
                    
                    // Already checked at typeStmts
                    unreachable;
                }
            }
        }
        
        var public_symbols = std.StringHashMap(TypedSymbol).init(self.arena);
        var iter = scope.syms.iterator();
        
        while (iter.next()) |entry| {
            public_symbols.put(entry.key_ptr.*, entry.value_ptr.*) catch unreachable;
        }
        
        var children = std.ArrayList(*tast.Module).initCapacity(self.arena, self.children.count()) catch unreachable;
        var child_iter = self.children.iterator();
        
        while (child_iter.next()) |entry| {
            children.appendAssumeCapacity(entry.value_ptr.*);
        }
        
        var fn_decls = self.arena.alloc(tast.FnDecl, self.fn_decls.items.len) catch unreachable;
        
        for (self.fn_decls.items, 0..) |*decl, i| {
            if (decl.ast.body != null) {
                self.typeFnDeclBody(decl.scope, decl.ast, &decl.tast);
            }
            
            fn_decls[i] = decl.tast;
        }
        
        self.fn_decls.clearAndFree(self.temp_allocator);
        
        return .{
            .id = module_id,
            .var_decls = self.var_decls.items,
            .fn_decls = fn_decls,
            .public_symbols = public_symbols,
            .children = children.items,
        };
    }
    
    fn typeStmts(self: *Typer, scope: *Scope, exprs: []const ast.Expr) []const tast.Stmt {
        var stmts = std.ArrayList(tast.Stmt).empty;
        
        var fn_decl_datas = std.ArrayList(FnDeclData).empty;
        defer fn_decl_datas.clearAndFree(self.temp_allocator);
        
        var struct_decl_datas = std.ArrayList(StructDeclData).empty;
        defer struct_decl_datas.clearAndFree(self.temp_allocator);
        
        var enum_decl_datas = std.ArrayList(EnumDeclData).empty;
        defer enum_decl_datas.clearAndFree(self.temp_allocator);
        
        for (exprs, 0..) |expr, i| {
            switch (expr.value) {
                ast.Kind.import => |imp| {
                    self.typeImport(scope, &imp);
                },
                ast.Kind.fn_decl => |fn_decl| {
                    fn_decl_datas.append(self.temp_allocator, .{
                        .tast = self.typeFnDeclForward(scope, &fn_decl, null),
                        .ast = &exprs[i].value.fn_decl,
                        .span = expr.span,
                        .scope = scope,
                    }) catch unreachable;
                },
                ast.Kind.struct_decl => {
                    struct_decl_datas.append(
                        self.temp_allocator,
                        self.typeStructDeclForward(scope, &exprs[i].value.struct_decl),
                    ) catch unreachable;
                },
                ast.Kind.enum_decl => {
                    enum_decl_datas.append(
                        self.temp_allocator,
                        self.typeEnumDecl(scope, &exprs[i].value.enum_decl),
                    ) catch unreachable;
                },
                else => {}
            }
        }
        
        for (struct_decl_datas.items) |struct_decl_data| {
            self.typeStructDeclFields(struct_decl_data.scope, struct_decl_data.ast, struct_decl_data.typ);
        }
        
        for (exprs) |expr| {
            switch (expr.value) {
                ast.Kind.import,
                ast.Kind.fn_decl,
                ast.Kind.struct_decl,
                ast.Kind.enum_decl => {},
                else => {
                    const stmt = self.typeStmt(scope, &expr, false);
                    
                    switch (expr.value) {
                        ast.Kind.var_decl => {},
                        ast.Kind.import => {},
                        
                        else => {
                            if (scope.mode == .module) {
                                self.reporter.reportErrorAtSpan(expr.span, "This kind of statement cannot be placed at top level", .{});
                            }
                        },
                    }
                    
                    stmts.append(self.temp_allocator, stmt) catch unreachable;
                }
            }
        }
        
        for (struct_decl_datas.items) |struct_decl_data| {
            self.typeStructDeclMember(struct_decl_data.scope, struct_decl_data.ast, struct_decl_data.typ);
        }
        
        for (enum_decl_datas.items) |enum_decl_data| {
            self.typeEnumDeclMember(enum_decl_data.scope, enum_decl_data.ast, enum_decl_data.typ);
        }
        
        // Calculate structs size & alignment
        for (struct_decl_datas.items) |struct_decl_data| {
            struct_decl_data.typ.value.@"struct".calculate(self.reporter);
        }
        
        for (fn_decl_datas.items) |*fn_decl_data| {
            if (fn_decl_data.ast.body) |_| {
                if (fn_decl_data.tast.is_extern) {
                    self.reporter.reportErrorAtSpan(fn_decl_data.span, "extern function cannot have a body", .{});
                }
            }
            else {
                if (!fn_decl_data.tast.is_extern) {
                    self.reporter.reportErrorAtSpan(fn_decl_data.span, "Non extern function must have a body", .{});
                }
            }
        }
        
        self.fn_decls.appendSlice(self.temp_allocator, fn_decl_datas.items) catch unreachable;
        
        return self.collectAndFreeTempList(tast.Stmt, &stmts);
    }
    
    fn typeStmt(self: *Typer, scope: *Scope, stmt: *const ast.Expr, dont_create_new_scope: bool) tast.Stmt {
        switch (stmt.value) {
            .var_decl   => |decl|   { return self.typeVarDecl(scope, &decl, stmt.span); },
            .assignment => |ass|    { return self.typeAssignment(scope, &ass); },
            .fn_call    => |call|   { return self.typeFnCallStmt(scope, &call, stmt.span); },
            .returns    => |ret|    { return self.typeReturn(scope, &ret, stmt.span); },
            .iff        => |iff|    { return self.typeIf(scope, &iff); },
            .whil       => |whil|   { return self.typeWhile(scope, &whil); },
            .forr       => |forr|   { return self.typeFor(scope, &forr); },
            .block      => |block|  { return self.typeBlockStmt(scope, &block, dont_create_new_scope); },
            
            else => {
                if (stmt.canBeUsedAsExpr()) {
                    return .{
                        .expr = self.typeExpr(scope, stmt, types.UNKNOWN),
                    };
                }
                
                std.debug.panic("TODO: typeStmt {s}", .{@tagName(stmt.value)});
            }
        }
    }
    
    fn typeFnDeclForward(self: *Typer, scope: *Scope, fn_decl: *const ast.FnDecl, out_typ: ?**const Type) tast.FnDecl {
        const fn_name = self.getTokenText(fn_decl.name);
        
        if (scope.hasSelf(fn_name)) {
            self.reporter.reportErrorAtToken(fn_decl.name, "Symbol `{s}` is already defined", .{fn_name});
        }
        
        var params = std.ArrayList(tast.FnParam).initCapacity(self.arena, fn_decl.params.len) catch unreachable;
        var param_types = std.ArrayList(*const Type).initCapacity(self.arena, fn_decl.params.len) catch unreachable;
        var has_default = false;
        var is_variadic = false;
        var return_typ = types.VOID;
        
        for (fn_decl.params) |param| {
            var param_typ = types.UNKNOWN;
            var param_default_value: ?*tast.Expr = null;
            
            if (param.typ) |typ| {
                param_typ = self.typeType(scope, &typ);
                
                if (param.default_value) |def_value| {
                    has_default = true;
                    param_default_value = self.makeExprPointer(self.typeExpr(scope, def_value, param_typ));
                    
                    const default_type = param_default_value.?.typ;
                    
                    if (!default_type.canBeAssignedTo(param_typ)) {
                        const expected_str = param_typ.getTextLeak(self.arena);
                        const actual_str = default_type.getTextLeak(self.arena);
                        
                        self.reporter.reportErrorAtSpan(def_value.span, "Expected `{s}` but got `{s}`", .{expected_str, actual_str});
                    }
                }
                else if (has_default) {
                    self.reporter.reportErrorAtSpan(
                        TokenSpan.from_token_and_span(param.name, typ.span),
                        "Param with no default value cannot be placed after param with default value",
                        .{}
                    );
                }
            }
            else if (param.default_value) |def_value| {
                has_default = true;
                param_default_value = self.makeExprPointer(self.typeExpr(scope, def_value, types.UNKNOWN));
                param_typ = param_default_value.?.typ.coerceIntoRuntime(self.type_manager);
            }
            else {
                // Should not be allowed in parsing
                unreachable;
            }
            
            if (param.is_variadic) {
                if (is_variadic) {
                    self.reporter.reportErrorAtToken(param.name, "Cannot have more that one variadic param", .{});
                }
                
                is_variadic = true;
            }
            else if (is_variadic) {
                self.reporter.reportErrorAtToken(param.name, "Non variadic param cannot be placed after variadic param", .{});
            }
            
            const symbol = self.symbol_manager.createSymbol(param.name, false);
            
            params.appendAssumeCapacity(tast.FnParam{
                .name = symbol,
                .default_value = param_default_value,
                .typ = param_typ,
            });
            
            param_types.appendAssumeCapacity(param_typ);
        }
        
        if (fn_decl.return_typ) |typ| {
            return_typ = self.typeType(scope, &typ);
        }
        
        const namespaced = if (fn_decl.is_extern or scope.mode == .module and std.mem.eql(u8, fn_name, "main")) false else true;
        const fn_name_symbol = self.symbol_manager.createSymbol(fn_decl.name, namespaced);
        const fn_typ = self.type_manager.createFn(
            param_types.items,
            return_typ,
            is_variadic,
            false,
        );
        
        scope.set(fn_name, fn_name_symbol, fn_typ, true, .constant);
        
        if (out_typ) |typ| {
            typ.* = fn_typ;
        }
        
        return .{
            .is_extern = fn_decl.is_extern,
            .extern_name = fn_decl.extern_name,
            .extern_abi = fn_decl.extern_abi,
            .is_public = fn_decl.is_public,
            .name = fn_name_symbol,
            .return_typ = return_typ,
            .params = params.items,
            .body = null,
        };
    }
    
    fn typeFnDeclBody(self: *Typer, scope: *Scope, fn_decl_ast: *const ast.FnDecl, forward_decl: *tast.FnDecl) void {        
        var new_scope = scope.inheritWithMode(.local, scope.allocator);
        
        for (forward_decl.params) |param| {
            new_scope.set(param.name.text, param.name, param.typ, false, .constant);
        }
        
        const parent_fn = self.cur_fn;
        self.cur_fn = forward_decl;
        
        std.debug.assert(fn_decl_ast.body != null);
        forward_decl.body = self.typeBlock(new_scope, &fn_decl_ast.body.?, true);
        
        if (forward_decl.return_typ.kind != types.TypeKind.void) {
            if (!doesAllPathHasReturn(&forward_decl.body.?)) {
                self.reporter.reportErrorAtSpan(fn_decl_ast.return_typ.?.span, "Function must have return value in all paths", .{});
            }
        }
        
        self.cur_fn = parent_fn;
    }
    
    fn typeBlockStmt(self: *Typer, scope: *Scope, block: *const ast.Block, dont_create_new_scope: bool) tast.Stmt {
        return .{
            .block = self.typeBlock(scope, block, dont_create_new_scope),
        };
    }
    
    fn typeBlockExpr(self: *Typer, scope: *Scope, block: *const ast.Block, span: TokenSpan) tast.Expr {
        if (block.exprs.len == 0) {
            self.reporter.reportErrorAtSpan(span, "Block should have an expression", .{});
        }
        
        // TODO: Handle edge cases like:
        // - Block with struct decl as last stmt
        // - Block with function decl as last stmt
        
        const stmts = self.typeStmts(scope, block.exprs);
        
        if (stmts.len == 0) {
            self.reporter.reportErrorAtSpan(span, "Struct or function declaration cannot be the only statement in a block expression", .{});
        }
        
        const last_stmt = stmts[stmts.len - 1];
        var last_expr: *tast.Expr = undefined;
        
        if (last_stmt.canBeUsedAsExpr()) {
            last_expr = self.makeExprPointer(last_stmt.transformToExpr());
        }
        else {
            var i: i32 = @intCast(block.exprs.len - 1);
            var last_stmt_span: TokenSpan = undefined;
            
            while (i >= 0) : (i -= 1) {
                switch (block.exprs[@intCast(i)].value) {
                    .fn_decl,
                    .struct_decl => {},
                    else => {
                        last_stmt_span = block.exprs[@intCast(i)].span;
                    },
                }
            }
            
            self.reporter.reportErrorAtSpan(last_stmt_span, "Statement cannot be used as expression", .{});
        }
        
        return .{
            .typ = types.UNKNOWN,
            .mutability = .constant,
            .value = .{.block = .{
                .stmts = stmts,
                .last_expr = last_expr,
            }},
        };
    }
    
    fn typeBlock(self: *Typer, scope: *Scope, block: *const ast.Block, dont_create_new_scope: bool) tast.Block {
        const new_scope: *Scope = if (dont_create_new_scope) scope else scope.inherit();        
        const stmts = self.typeStmts(new_scope, block.exprs);
        
        return .{
            .stmts = stmts,
        };
    }
    
    fn typeStructDeclForward(self: *Typer, scope: *Scope, decl: *const ast.StructDecl) StructDeclData {
        const struct_name = self.getTokenText(decl.name);
        const struct_symbol = self.symbol_manager.createSymbol(decl.name, true);
        
        const struct_type = self.type_manager.createStructForward(struct_symbol);
        const struct_type_container = self.type_manager.createType(struct_type);
        
        scope.set(struct_name, struct_symbol, struct_type_container, true, .constant);
        const new_scope = scope.inheritWithMode(.container, self.arena);
        
        return .{
            .ast = decl,
            .typ = struct_type,
            .scope = new_scope,
        };
    }
    
    fn typeStructDeclFields(self: *Typer, scope: *Scope, decl: *const ast.StructDecl, struct_typ: *Type) void {
        std.debug.assert(struct_typ.value == .@"struct");
        
        var fields = std.ArrayList(types.TypeStructField).initCapacity(self.arena, decl.fields.len) catch unreachable;
        
        for (decl.fields) |field| {
            const field_name_symbol = self.symbol_manager.createSymbol(field.name, false);
            var field_typ: *const Type = undefined;
            var field_default_value: ?*tast.Expr = null;
            var has_type = false;
            
            if (field.typ) |typ| {
                field_typ = self.typeType(scope, &typ);
                has_type = true;
            }
            
            if (field.default_value) |def_value| {
                field_default_value = self.makeExprPointer(self.typeExpr(scope, def_value, if (has_type) field_typ else types.UNKNOWN));
                
                if (has_type) {
                    if (!field_default_value.?.typ.canBeAssignedTo(field_typ)) {
                        const expected_str = field_typ.getTextLeak(self.arena);
                        const actual_str = field_default_value.?.typ.getTextLeak(self.arena);
                        
                        self.reporter.reportErrorAtSpan(def_value.span, "Expected `{s}` but got `{s}`", .{expected_str, actual_str});
                    }
                }
                else {
                    field_typ = field_default_value.?.typ.coerceIntoRuntime(self.type_manager);
                }
            }
            
            if (field.typ == null and field.default_value == null) {
                unreachable;
            }
            
            fields.appendAssumeCapacity(types.TypeStructField{
                .name = field_name_symbol,
                .typ = field_typ,
                .default_value = field_default_value,
                .offset = 0,
                .is_using = field.using != null,
            });
        }
        
        struct_typ.value.@"struct".setFields(fields.items);
    }
    
    fn typeStructDeclMember(self: *Typer, scope: *Scope, decl: *const ast.StructDecl, struct_typ: *Type) void {
        self.symbol_manager.pushNamespace(self.getTokenText(decl.name));
        
        var methods = std.ArrayList(types.TypeMethod).empty;
        var fn_decl_datas = std.ArrayList(FnDeclData).empty;
        
        for (decl.members, 0..) |mem, i| {
            switch (mem.value) {
                .var_decl => |var_decl| {
                    const tast_var_decl = self.typeVarDecl(scope, &var_decl, mem.span);
                    std.debug.assert(tast_var_decl == .var_decl);
                    
                    self.var_decls.append(self.arena, tast_var_decl.var_decl) catch unreachable;
                },
                .fn_decl => |fn_decl| {
                    var fn_typ: *const Type = undefined;
                    const tast_fn_decl = self.typeFnDeclForward(scope, &fn_decl, &fn_typ);
                    
                    if (fn_typ.value.func.params.len > 0 and fn_typ.value.func.params[0].isSameOrSameReference(struct_typ)) {
                        methods.append(self.temp_allocator, .{
                            .name = tast_fn_decl.name,
                            .typ = fn_typ,
                        }) catch unreachable;
                    }
                    
                    fn_decl_datas.append(self.temp_allocator, .{
                        .tast = tast_fn_decl,
                        .ast = &decl.members[i].value.fn_decl,
                        .span = mem.span,
                        .scope = scope,
                    }) catch unreachable;
                },
                
                else => {
                    self.reporter.reportErrorAtSpan(mem.span, "Invalid struct member", .{});
                }
            }
        }
        
        struct_typ.value.@"struct".setMethods(self.collectAndFreeTempList(types.TypeMethod, &methods));
        self.fn_decls.appendSlice(self.temp_allocator, self.collectAndFreeTempList(FnDeclData, &fn_decl_datas)) catch unreachable;
        scope.parent.?.setChildSymbols(struct_typ.value.@"struct".name.text, scope.makeChildSymbols(self.arena));
        
        self.symbol_manager.popNamespace();
    }
    
    fn typeEnumDecl(self: *Typer, scope: *Scope, decl: *const ast.EnumDecl) EnumDeclData {
        const enum_name = self.getTokenText(decl.name);
        const enum_symbol = self.symbol_manager.createSymbol(decl.name, true);
        
        var items = std.ArrayList(Symbol).initCapacity(self.arena, decl.items.len) catch unreachable;
            
        for (decl.items) |item| {
            const item_name_symbol = self.symbol_manager.createSymbol(item, false);
            items.appendAssumeCapacity(item_name_symbol);
        }
        
        const enum_type = self.type_manager.createEnum(
            enum_symbol,
            items.items,
            &.{},
        );
        
        const enum_type_container = self.type_manager.createType(enum_type);
        scope.set(enum_name, enum_symbol, enum_type_container, true, .constant);
        const new_scope = scope.inheritWithMode(.container, self.arena);
        
        return .{
            .typ = enum_type,
            .ast = decl,
            .scope = new_scope,
        };
    }
    
    fn typeEnumDeclMember(self: *Typer, scope: *Scope, decl: *const ast.EnumDecl, enum_typ: *Type) void {
        self.symbol_manager.pushNamespace(self.getTokenText(decl.name));
        
        var methods = std.ArrayList(types.TypeMethod).empty;
        var fn_decl_datas = std.ArrayList(FnDeclData).empty;
        
        for (decl.members, 0..) |mem, i| {
            switch (mem.value) {
                .var_decl => |var_decl| {
                    const tast_var_decl = self.typeVarDecl(scope, &var_decl, mem.span);
                    std.debug.assert(tast_var_decl == .var_decl);
                    
                    self.var_decls.append(self.arena, tast_var_decl.var_decl) catch unreachable;
                },
                .fn_decl => |fn_decl| {
                    var fn_typ: *const Type = undefined;
                    const tast_fn_decl = self.typeFnDeclForward(scope, &fn_decl, &fn_typ);
                    
                    if (fn_typ.value.func.params.len > 0 and fn_typ.value.func.params[0].isSameOrSameReference(enum_typ)) {
                        methods.append(self.temp_allocator, .{
                            .name = tast_fn_decl.name,
                            .typ = fn_typ,
                        }) catch unreachable;
                    }
                    
                    fn_decl_datas.append(self.temp_allocator, .{
                        .tast = tast_fn_decl,
                        .ast = &decl.members[i].value.fn_decl,
                        .span = mem.span,
                        .scope = scope,
                    }) catch unreachable;
                },
                
                else => {
                    self.reporter.reportErrorAtSpan(mem.span, "Invalid struct member", .{});
                }
            }
        }
        
        enum_typ.value.@"enum".methods = self.collectAndFreeTempList(types.TypeMethod, &methods);        
        self.fn_decls.appendSlice(self.temp_allocator, self.collectAndFreeTempList(FnDeclData, &fn_decl_datas)) catch unreachable;
        scope.parent.?.setChildSymbols(enum_typ.value.@"enum".name.text, scope.makeChildSymbols(self.arena));
        
        self.symbol_manager.popNamespace();
    }
    
    fn typeVarDecl(self: *Typer, scope: *Scope, var_decl: *const ast.VarDecl, span: TokenSpan) tast.Stmt {
        const name = self.getTokenText(var_decl.name);
        var typ = types.UNKNOWN;
        var value: ?*tast.Expr = null;
        
        if (scope.hasSelf(name)) {
            self.reporter.reportErrorAtToken(var_decl.name, "Identifier `{s}` is already defined", .{name});
        }
        
        if (var_decl.typ) |decl_typ| {
            typ = self.typeType(scope, &decl_typ);
        }
        
        if (var_decl.value) |decl_value| {
            value = self.makeExprPointer(self.typeExpr(scope, decl_value, typ));
            
            if (typ.kind == types.TypeKind.unknown) {
                typ = value.?.typ;
            }
            else {
                if (value.?.typ.canBeAssignedTo(typ)) {
                    typ = value.?.typ.assignTo(typ);
                    value.?.typ = typ;
                }
                else {
                    const from = value.?.typ.getTextLeak(self.arena);
                    const to = typ.getTextLeak(self.arena);
                    
                    self.reporter.reportErrorAtSpan(decl_value.span, "Type `{s}` cannot be assigned to `{s}`", .{from, to});
                }
            }
        }
        else {
            switch (var_decl.decl.kind) {
                TokenKind.KeywordVar => {},
                TokenKind.KeywordVal,
                TokenKind.KeywordConst => {
                    self.reporter.reportErrorAtSpan(span, "Declaration with val or const should have a value", .{});
                },
                else => unreachable,
            }
        }
        
        typ = typ.coerceIntoRuntime(self.type_manager);
        
        const comptime_known = var_decl.decl.kind == .KeywordConst and value.?.comptime_known;
        const mutability: Mutability = switch (var_decl.decl.kind) {
            .KeywordConst => .constant,
            .KeywordVal => .immutable,
            .KeywordVar => .mutable,
            else => unreachable,
        };
        
        const name_symbol = self.symbol_manager.createSymbol(var_decl.name, scope.mode != .local);
        scope.set(name, name_symbol, typ, comptime_known, mutability);
        
        const kind: tast.VarDeclKind = switch (var_decl.decl.kind) {
            TokenKind.KeywordVal   => .Val,
            TokenKind.KeywordVar   => .Var,
            TokenKind.KeywordConst => .Const,
            else => unreachable,
        };
        
        return .{
            .var_decl = .{
                .kind = kind,
                .name = name_symbol,
                .typ = typ,
                .value = value,
            },
        };
    }
    
    fn typeAssignment(self: *Typer, scope: *Scope, ass: *const ast.Assignment) tast.Stmt {
        const lhs = self.makeExprPointer(self.typeExpr(scope, ass.lhs, types.UNKNOWN));
        const rhs = self.makeExprPointer(self.typeExpr(scope, ass.rhs, lhs.typ));
        
        // Check if lhs is a lvalue
        switch (lhs.value) {
            .identifier,
            .array_index,
            .struct_member => {},
            
            else => {
                self.reporter.reportErrorAtSpan(ass.lhs.span, "Cannot assign to rvalue", .{});
            }
        }
        
        switch (lhs.mutability) {
            .constant => {
                self.reporter.reportErrorAtSpan(ass.lhs.span, "Cannot assign to constant", .{});
            },
            .immutable => {
                self.reporter.reportErrorAtSpan(ass.lhs.span, "Cannot assign to imuutable variable", .{});
            },
            .mutable => {},
        }
        
        if (!rhs.typ.canBeAssignedTo(lhs.typ)) {
            self.reporter.reportErrorAtSpan(
                ass.rhs.span,
                "Type `{s}` cannot be assigned to `{s}`",
                .{
                    rhs.typ.getTextLeak(self.arena),
                    lhs.typ.getTextLeak(self.arena),
                }
            );
        }
        
        const op: tast.AssignmentOp = switch (ass.op.kind) {
            TokenKind.Eq      => .eq,
            TokenKind.PlusEq  => .plus_eq,
            TokenKind.MinusEq => .minus_eq,
            TokenKind.MulEq   => .mul_eq,
            TokenKind.DivEq   => .div_eq,
            TokenKind.ModEq   => .mod_eq,
            
            else => unreachable,
        };
        
        return .{.assignment = .{
            .lhs = lhs,
            .rhs = rhs,
            .op = op,
        }};
    }
    
    fn typeFnCallStmt(self: *Typer, scope: *Scope, call: *const ast.FnCall, span: TokenSpan) tast.Stmt {
        return .{
            .fn_call = self.typeFnCall(scope, call, span),
        };
    }
    
    fn typeFnCallExpr(self: *Typer, scope: *Scope, call: *const ast.FnCall, span: TokenSpan) tast.Expr {
        const tast_call = self.typeFnCall(scope, call, span);
        
        return .{
            .typ = tast_call.return_typ,
            .mutability = .constant,
            .value = .{ .fn_call = tast_call },
        };
    }
    
    fn typeFnCall(self: *Typer, scope: *Scope, call: *const ast.FnCall, span: TokenSpan) tast.FnCall {
        const callee = self.makeExprPointer(self.typeExpr(scope, call.callee, types.UNKNOWN));
        
        if (callee.typ.kind != types.TypeKind.func) {
            self.reporter.reportErrorAtSpan(call.callee.span, "Cannot call something that is not a function", .{});
        }
        
        const is_variadic = callee.typ.value.func.is_variadic;
        const param_types = callee.typ.value.func.params;
        const return_type = callee.typ.value.func.returns;
        const skip_param: usize = if (callee.value == .struct_method or callee.value == .enum_method) 1 else 0;
        
        if (is_variadic) {
            if (call.args.len < param_types.len - skip_param - 1) {
                self.reporter.reportErrorAtSpan(
                    span,
                    "Expected {} or more arguments but got {}",
                    .{ param_types.len - skip_param - 1, call.args.len },
                );
            }
        }
        else {
            if (call.args.len != param_types.len - skip_param) {
                self.reporter.reportErrorAtSpan(
                    span,
                    "Expected {} arguments but got {}",
                    .{ param_types.len - skip_param, call.args.len },
                );
            }
        }
        
        var typed_args = std.ArrayList(tast.Expr).initCapacity(self.arena, call.args.len) catch unreachable;
        
        for (call.args, 0..) |arg, i| {
            const index = if (i < param_types.len - skip_param) i + skip_param
            else if (is_variadic) param_types.len - skip_param - 1 else unreachable;
            
            const expr = self.typeExpr(scope, &arg, param_types[index]);
            typed_args.appendAssumeCapacity(expr);
            
            if (!expr.typ.canBeAssignedTo(param_types[index])) {
                self.reporter.reportErrorAtSpan(
                    arg.span,
                    "Expected type `{s}` but got `{s}`",
                    .{
                        param_types[index].getTextLeak(self.arena),
                        expr.typ.getTextLeak(self.arena),
                    },
                );
            }
        }
        
        return .{
            .callee = callee,
            .args = typed_args.items,
            .return_typ = return_type,
        };
    }
    
    fn typeReturn(self: *Typer, scope: *Scope, ret: *const ast.Return, span: TokenSpan) tast.Stmt {
        var value: ?*tast.Expr = null;
        
        if (self.cur_fn) |cur_fn| {
            if (ret.value) |ret_value| {
                if (cur_fn.return_typ.kind == types.TypeKind.void) {
                    self.reporter.reportErrorAtSpan(span, "Cannot return a value from void function", .{});
                }
                else {
                    value = self.makeExprPointer(self.typeExpr(scope, ret_value, cur_fn.return_typ));
                    
                    if (!value.?.typ.canBeAssignedTo(cur_fn.return_typ)) {
                        const expected_str = cur_fn.return_typ.getTextLeak(self.arena);
                        const actual_str = value.?.typ.getTextLeak(self.arena);
                        
                        self.reporter.reportErrorAtSpan(
                            ret_value.span,
                            "Expected return value of type `{s}` but got `{s}`",
                            .{expected_str, actual_str},
                        );
                    }
                }
            }
            else if (cur_fn.return_typ.kind != types.TypeKind.void) {
                const expected_str = cur_fn.return_typ.getTextLeak(self.arena);
                self.reporter.reportErrorAtSpan(span, "Need a return value with type of `{s}`", .{expected_str});
            }
        }
        else {
            self.reporter.reportErrorAtSpan(span, "return must be inside a function", .{});
        }
        
        return .{ .returns = .{ .value = value } };
    }
    
    fn typeIf(self: *Typer, scope: *Scope, iff: *const ast.If) tast.Stmt {
        const cond = self.makeExprPointer(self.typeExpr(scope, iff.condition, types.UNKNOWN));
        
        if (!cond.typ.canBeUsedAsCond()) {
            self.reporter.reportErrorAtSpan(iff.condition.span, "Type `{s}` cannot be used as condition", .{cond.typ.getTextLeak(self.arena)});
        }
        
        const body = self.makeStmtPointer(self.typeStmt(scope, iff.body, false));
        
        var else_stmt: ?*tast.Stmt = null;
        
        if (iff.else_expr) |else_expr| {
            else_stmt = self.makeStmtPointer(self.typeStmt(scope, else_expr, false));
        }
        
        return .{
            .iff = .{
                .condition = cond,
                .body = body,
                .else_stmt = else_stmt,
            }
        };
    }
    
    fn typeIfExpr(self: *Typer, scope: *Scope, iff: *const ast.If, span: TokenSpan) tast.Expr {
        const cond = self.makeExprPointer(self.typeExpr(scope, iff.condition, types.UNKNOWN));
        
        if (!cond.typ.canBeUsedAsCond()) {
            self.reporter.reportErrorAtSpan(iff.condition.span, "Type `{s}` cannot be used as condition", .{cond.typ.getTextLeak(self.arena)});
        }
        
        const true_expr = self.typeExpr(scope, iff.body, types.UNKNOWN);
        var typ = true_expr.typ;
        
        const false_expr = if (iff.else_expr) |else_expr| blk: {
            const expr = self.typeExpr(scope, else_expr, types.UNKNOWN);
            
            if (expr.typ.canBeCombinedWith(true_expr.typ)) {
                typ = typ.combinedWith(expr.typ);
            }
            else {
                self.reporter.reportErrorAtSpan(
                    span,
                    "Cannot combine `{s}` and `{s}` as if expression",
                    .{
                        typ.getTextLeak(self.arena),
                        expr.typ.getTextLeak(self.arena),
                    },
                );
            }
            
            break :blk expr;
        }
        else {
            self.reporter.reportErrorAtSpan(span, "if as an expression must have an else expression", .{});
        };
        
        return .{
            .typ = typ,
            .mutability = .constant,
            .value = .{.iff = .{
                .condition = cond,
                .true_expr = self.makeExprPointer(true_expr),
                .false_expr = self.makeExprPointer(false_expr),
            }},
        };
    }
    
    fn typeWhile(self: *Typer, scope: *Scope, whil: *const ast.While) tast.Stmt {
        const cond = self.makeExprPointer(self.typeExpr(scope, whil.condition, types.UNKNOWN));
        
        if (!cond.typ.canBeUsedAsCond()) {
            self.reporter.reportErrorAtSpan(whil.condition.span, "Type `{s}` cannot be used as condition", .{cond.typ.getTextLeak(self.arena)});
        }
        
        const body = self.makeStmtPointer(self.typeStmt(scope, whil.body, false));
        
        return .{
            .whil = .{
                .condition = cond,
                .body = body,
            },
        };
    }
    
    fn typeFor(self: *Typer, scope: *Scope, forr: *const ast.For) tast.Stmt {
        var item_var: ?Symbol = null;
        var index_var: ?Symbol = null;
        
        if (forr.item_var) |v| {
            item_var = self.symbol_manager.createSymbol(v, false);
        }
        
        if (forr.index_var) |v| {
            index_var = self.symbol_manager.createSymbol(v, false);
        }
        
        const iter = self.typeExpr(scope, forr.iter, types.UNKNOWN);
        
        switch (iter.typ.kind) {
            .numeric,
            .range => {
                if (forr.is_reference) {
                    self.reporter.reportErrorAtToken(forr.item_var.?, "The item in for loop with int and range iter cannot be a reference", .{});
                }
                
                // For numeric and range iter, cannot create index var
                // It will be confusing to distinguish between index and item, because they are both i32
                // And moreover, if iter is numeric or range that starts from 0, both the value of item and index
                // will be the same
                if (forr.index_var) |v| {
                    self.reporter.reportErrorAtToken(v, "For with int and range iter cannot have index", .{});
                }
                
                var start: *tast.Expr = undefined;
                var end: *tast.Expr = undefined;
                
                if (iter.typ.kind == .numeric) {
                    if (!iter.typ.isNumericInt()) {
                        self.reporter.reportErrorAtSpan(
                            forr.iter.span,
                            "Only numeric int can be used as for iterator",
                            .{}
                        );
                    }
                    
                    if (iter.typ.canBeAssignedTo(types.I32)) {
                        start = self.makeExprPointer(.{
                            .typ = types.I32,
                            .mutability = .constant,
                            .value = .{ .literal = .{ .int = 0 } },
                        });
                        
                        if (iter.typ.coerceIntoRuntime(self.type_manager).isSame(types.I32)) {
                            end = self.makeExprPointer(iter);
                        }
                        else {
                            end = self.makeMaybeCast(self.makeExprPointer(iter), types.I32);
                        }
                    }
                    else {
                        self.reporter.reportErrorAtSpan(
                            forr.iter.span,
                            "Only numeric int can be used as for iterator",
                            .{}
                        );
                    }
                }
                else {
                    start = iter.value.range.lhs;
                    end = iter.value.range.rhs;
                    
                    if (iter.value.range.is_eq) {
                        const one = self.makeExprPointer(.{
                            .typ = types.I32,
                            .mutability = .constant,
                            .value = .{.literal = .{ .int = 1 }},
                        });
                        
                        const bin = self.makeExprPointer(.{
                            .typ =  types.I32,
                            .mutability = .constant,
                            .value = .{.binary = .{
                                .lhs = end,
                                .rhs = one,
                                .op = .add,
                            }}
                        });
                        
                        end = bin;
                    }
                }
                
                const new_scope = scope.inherit();
                // defer new_scope.deinit();
                
                if (item_var) |v| {
                    scope.set(v.text, v, types.I32, false, .constant);
                }
                
                const body = self.makeStmtPointer(self.typeStmt(new_scope, forr.body, true));
                
                return tast.Stmt{.for_range = .{
                    .item_var = item_var,
                    .start = start,
                    .end = end,
                    .body = body,
                }};
            },
            .array => {
                const new_scope = scope.inherit();
                // defer new_scope.deinit();
                
                const item_typ = if (forr.is_reference) self.type_manager.createReference(iter.typ.value.array.child)
                else iter.typ.value.array.child;
                
                if (item_var) |v| {
                    scope.set(v.text, v, item_typ, false, .constant);
                }
                
                if (index_var) |v| {
                    scope.set(v.text, v, types.I32, false, .constant);
                }
                
                const body = self.makeStmtPointer(self.typeStmt(new_scope, forr.body, true));
                
                return .{.for_each = .{
                    .item_var = item_var,
                    .index_var = index_var,
                    .item_typ = item_typ,
                    .is_reference = forr.is_reference,
                    .iter = self.makeExprPointer(iter),
                    .body = body,
                }};
            },
            
            else => {
                self.reporter.reportErrorAtSpan(
                    forr.iter.span,
                    "Type `{s}` is not iterable",
                    .{iter.typ.getTextLeak(self.arena)},
                );
            }
        }
        
        unreachable;
    }
    
    fn typeImport(self: *Typer, scope: *Scope, import: *const ast.Import) void {
        const path_with_quote = self.getTokenText(import.path);
        const path = path_with_quote[1..path_with_quote.len - 1];
        const module = self.children.get(path);
        
        if (module) |mod| {            
            var iter = mod.public_symbols.iterator();
            
            while (iter.next()) |entry| {
                scope.setTypedSymbol(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        else {
            std.debug.panic("UNREACHABLE: Module should be loaded", .{});
        }
    }
    
    fn typeExpr(self: *Typer, scope: *Scope, expr: *const ast.Expr, exp_typ: *const Type) tast.Expr {
        switch (expr.value) {
            ast.Kind.identifier    => return self.typeIdentifier(scope, &expr.value.identifier),
            ast.Kind.literal       => return self.typeLiteral(scope, &expr.value.literal),
            ast.Kind.fn_call       => return self.typeFnCallExpr(scope, &expr.value.fn_call, expr.span),
            ast.Kind.unary         => return self.typeUnary(scope, &expr.value.unary),
            ast.Kind.binary        => return self.typeBinary(scope, &expr.value.binary, expr.span),
            ast.Kind.iff           => return self.typeIfExpr(scope, &expr.value.iff, expr.span),
            ast.Kind.block         => return self.typeBlockExpr(scope, &expr.value.block, expr.span),
            ast.Kind.array_value   => return self.typeArrayValue(scope, &expr.value.array_value, expr.span, exp_typ),
            ast.Kind.array_index   => return self.typeArrayIndex(scope, &expr.value.array_index),
            ast.Kind.range         => return self.typeRange(scope, &expr.value.range),
            ast.Kind.member_access => return self.typeMemberAccess(scope, &expr.value.member_access),
            ast.Kind.struct_value  => return self.typeStructValue(scope, &expr.value.struct_value, expr.span, exp_typ),
            ast.Kind.enum_value    => return self.typeEnumValue(scope, &expr.value.enum_value, expr.span, exp_typ),
            ast.Kind.address_of    => return self.typeAddressOf(scope, &expr.value.address_of, exp_typ),
            ast.Kind.cast          => return self.typeCast(scope, &expr.value.cast, expr.span),
            
            else => {
                std.debug.panic("TODO: typeExpr {s}", .{@tagName(expr.value)});
            }
        }
    }
    
    fn typeIdentifier(self: *Typer, scope: *Scope, ident: *const ast.Identifier) tast.Expr {
        const name = self.getTokenText(ident.name);
        const typed_symbol = scope.get(name);
        
        if (typed_symbol) |sym| {
            return .{
                .value = .{ .identifier = .{ .name = sym.symbol } },
                .typ = sym.typ,
                .comptime_known = sym.comptime_known,
                .mutability = sym.mutability,
            };
        }
        
        self.reporter.reportErrorAtToken(ident.name, "Unknown identifier `{s}`", .{name});
    }
    
    fn typeLiteral(self: *Typer, scope: *Scope, lit: *const ast.Literal) tast.Expr {
        _ = scope;
        
        switch (lit.kind) {
            ast.LitKind.IntBin,
            ast.LitKind.Int,
            ast.LitKind.IntOct,
            ast.LitKind.IntHex => {
                var value: u64 = undefined;
                const text = self.getTokenText(lit.value);
                
                switch (lit.kind) {
                    ast.LitKind.IntBin => {
                        value = std.fmt.parseInt(u64, text[2..], 2) catch unreachable;
                    },
                    ast.LitKind.Int => {
                        value = std.fmt.parseInt(u64, text, 10) catch unreachable;
                    },
                    ast.LitKind.IntOct => {
                        value = std.fmt.parseInt(u64, text[2..], 8) catch unreachable;
                    },
                    ast.LitKind.IntHex => {
                        value = std.fmt.parseInt(u64, text[2..], 16) catch unreachable;
                    },
                    else => unreachable,
                }
                
                return tast.Expr{
                    .comptime_known = true,
                    .mutability = .constant,
                    .typ = types.UNTYPED_INT,
                    .value = .{ .literal = .{ .int = value } },
                };
            },
            
            ast.LitKind.Float => {
                const text = self.getTokenText(lit.value);
                const value = std.fmt.parseFloat(f64, text) catch unreachable;
                
                return tast.Expr{
                    .comptime_known = true,
                    .mutability = .constant,
                    .typ = types.UNTYPED_FLOAT,
                    .value = .{ .literal = .{ .float = value } },
                };
            },
            
            ast.LitKind.String => {
                const text = self.getTokenText(lit.value);
                const value = self.arena.dupe(u8, text[1..text.len - 1]) catch unreachable;
                
                return tast.Expr{
                    .comptime_known = true,
                    .mutability = .constant,
                    .typ = types.STRING,
                    .value = .{ .literal = .{ .string = value } },
                };
            },
            
            ast.LitKind.Char => {
                const text = self.getTokenText(lit.value);
                const chs = text[1..text.len - 1];
                
                var value: u8 = undefined;
                
                if (chs[0] == '\\') {
                    switch (chs[1]) {
                        'n' => value = '\n',
                        'r' => value = '\r',
                        't' => value = '\t',
                        '\'' => value = '\'',
                        '"' => value = '"',
                        '\\' => value = '\\',
                        
                        else => unreachable,
                    }
                }
                else {
                    value = chs[0];
                }
                
                return tast.Expr{
                    .comptime_known = true,
                    .mutability = .constant,
                    .typ = types.CHAR,
                    .value = .{ .literal = .{ .char = value } },
                };
            },
            
            ast.LitKind.True,
            ast.LitKind.False, => {
                return tast.Expr{
                    .comptime_known = true,
                    .mutability = .constant,
                    .typ = types.BOOL,
                    .value = .{ .literal = .{ .bool = lit.kind == ast.LitKind.True } },
                };
            },
        }
    }
    
    fn typeUnary(self: *Typer, scope: *Scope, un: *const ast.Unary) tast.Expr {
        const expr = self.typeExpr(scope, un.expr, types.UNKNOWN);
        var op: tast.UnaryOp = undefined;
        var typ: *const Type = undefined;
        
        switch (un.op.kind) {
            .Not => {
                if (expr.typ.kind == .bool) {
                    op = .not;
                    typ = types.BOOL;
                }
                else {
                    self.reporter.reportErrorAtSpan(un.expr.span, "Unary not (!) operand must be bool type", .{});
                }
            },
            .Minus => {
                if (expr.typ.kind == .numeric) {
                    op = .minus;
                    
                    const numeric = expr.typ.value.numeric;
                    
                    if (numeric.isUnsigned()) {
                        typ = switch (numeric) {
                            .u8  => types.I8,
                            .u16 => types.I16,
                            .u32 => types.I32,
                            .u64 => types.I64,
                            
                            else => unreachable,
                        };
                    }
                    else {
                        typ = expr.typ;
                    }
                }
                else {
                    self.reporter.reportErrorAtSpan(un.expr.span, "Unary minus (-) operand must be numeric type", .{});
                }
            },
            
            else => {
                std.debug.panic("TODO: typeUnary {s}", .{@tagName(un.op.kind)});
            }
        }
        
        return .{
            .typ = typ,
            .mutability = .constant,
            .value = .{.unary = .{
                .expr = self.makeExprPointer(expr),
                .op = op,
            }},
        };
    }
    
    fn typeBinary(self: *Typer, scope: *Scope, bin: *const ast.Binary, span: TokenSpan) tast.Expr {
        var lhs = self.typeExpr(scope, bin.lhs, types.UNKNOWN);
        
        const exp_typ = switch (lhs.typ.kind) {
            .@"struct",
            .@"enum" => lhs.typ,
            else => types.UNKNOWN,
        };
        
        var rhs = self.typeExpr(scope, bin.rhs, exp_typ);
        
        var valid = false;
        var need_explicit_cast = false;
        var typ: *const Type = undefined;
        
        // All numeric   -> +, -, *, /, >, >=, <, <=, ==, !=
        // Integer       -> %, |, &
        // Bool          -> &, &&, |, ||
        
        if (lhs.typ.kind == .numeric and rhs.typ.kind == .numeric) {
            var need_to_check = false;
        
            switch (bin.op.kind) {
                .Mod,
                .Or,
                .And => {
                    // Noop
                    // Not valid if one of the operand is float
                    if (lhs.typ.value.numeric.isFloat() or rhs.typ.value.numeric.isFloat()) {}
                    else {
                        need_to_check = true;
                    }
                },
                .Plus,
                .Minus,
                .Mul,
                .Div,
                .Gt,
                .Gte,
                .Lt,
                .Lte,
                .EqEq,
                .NotEq => {
                    need_to_check = true;
                },
                else => {},
            }
            
            if (need_to_check) {
                const lhs_kind = lhs.typ.value.numeric;
                const rhs_kind = rhs.typ.value.numeric;
                
                if (lhs_kind == rhs_kind) {
                    typ = lhs.typ;
                    valid = true;
                }
                else {
                    const l_is_untyped = lhs_kind.isUntyped();
                    const r_is_untyped = rhs_kind.isUntyped();
                    
                    const l_is_int = lhs_kind.isInt();
                    const r_is_int = rhs_kind.isInt();
                    
                    const l_is_float = lhs_kind.isFloat();
                    const r_is_float = rhs_kind.isFloat();
                    
                    // If both is untyped
                    // One of them is untyped float and one of them is untyped int
                    // The resulting type is untyped float by casting the untyped int into untyped float
                    if (l_is_untyped and r_is_untyped) {
                        // If lhs is a float, cast rhs into float
                        if (l_is_float) {
                            rhs = tast.Expr{
                                .typ = lhs.typ,
                                .mutability = .constant,
                                .value = .{.cast = .{
                                    .typ = lhs.typ,
                                    .value = self.makeExprPointer(rhs),
                                }}
                            };
                            
                            typ = lhs.typ;
                        }
                        // If rhs is a float, cast lhs into float
                        // rhs should be a float here, because lhs is not float and rhs is not the same as lhs
                        // (already checked above)
                        else if (r_is_float) {
                            lhs = tast.Expr{
                                .typ = rhs.typ,
                                .mutability = .constant,
                                .value = .{.cast = .{
                                    .typ = rhs.typ,
                                    .value = self.makeExprPointer(lhs),
                                }}
                            };
                            
                            typ = rhs.typ;
                        }
                        
                        valid = true;
                    }
                    else if (l_is_untyped) {
                        // If both is int or both is float
                        // The resulting type is the untyped one, in this case is rhs
                        // Or, if lhs is untyped int and rhs is float
                        // Allow implicit cast
                        if (l_is_int == r_is_int or r_is_float) {
                            if (r_is_float) {
                                lhs = tast.Expr{
                                    .typ = rhs.typ,
                                    .mutability = .constant,
                                    .value = .{.cast = .{
                                        .typ = rhs.typ,
                                        .value = self.makeExprPointer(lhs),
                                    }}
                                };
                            }
                            
                            typ = rhs.typ;
                            valid = true;
                        }
                        else {
                            need_explicit_cast = true;
                        }
                    }
                    else if (r_is_untyped) {
                        // If both is int or both is float
                        // The resulting type is the untyped one, in this case is lhs
                        // Or, if rhs is untyped int and lhs is float
                        // Allow implicit cast
                        if (l_is_int == r_is_int or l_is_float) {
                            if (l_is_float) {
                                rhs = tast.Expr{
                                    .typ = lhs.typ,
                                    .mutability = .constant,
                                    .value = .{.cast = .{
                                        .typ = lhs.typ,
                                        .value = self.makeExprPointer(rhs),
                                    }}
                                };
                            }
                            
                            typ = lhs.typ;
                            valid = true;
                        }
                        else {
                            need_explicit_cast = true;
                        }
                    }
                    else {
                        need_explicit_cast = true;
                    }
                }
                
                switch (bin.op.kind) {
                    .Gt,
                    .Gte,
                    .Lt,
                    .Lte,
                    .EqEq,
                    .NotEq => {
                        typ = types.BOOL;
                    },
                    else => {},
                }
            }
        }
        else if (lhs.typ.kind == .bool and rhs.typ.kind == .bool) {
            switch (bin.op.kind) {
                .AndAnd,
                .OrOr => {
                    valid = true;
                    typ = types.BOOL;
                },
                else => {},
            }
        }
        else if (lhs.typ.kind == .@"enum" and rhs.typ.kind == .@"enum") {
            if (lhs.typ.type_id == rhs.typ.type_id) {
                switch (bin.op.kind) {
                    .EqEq,
                    .NotEq => {
                        valid = true;
                        typ = types.BOOL;
                    },
                    else => {
                        self.reporter.reportErrorAtSpan(
                            span,
                            "Only `==` and `!=` binary operation is supported for enum",
                            .{},
                        );
                    }
                }
            }
            else {
                self.reporter.reportErrorAtSpan(
                    span,
                    "Invalid binary operation for enum `{s}` and `{s}`",
                    .{
                        lhs.typ.value.@"enum".name.text,
                        rhs.typ.value.@"enum".name.text,
                    },
                );
            }
        }
        else if (lhs.value == .array_value) {
            if (bin.op.kind == .MulMul) {
                if (rhs.value == .literal and rhs.value.literal == .int) {
                    const elems_len = lhs.value.array_value.elems.len;
                    const count = rhs.value.literal.int;
                    
                    var new_elems = std.ArrayList(tast.Expr).initCapacity(self.arena, elems_len * count) catch unreachable;
                    
                    for (0..count) |_| {
                        for (lhs.value.array_value.elems) |elem| {
                            new_elems.appendAssumeCapacity(elem);
                        }
                    }
                    
                    return .{
                        .typ = lhs.typ,
                        .mutability = .constant,
                        .value = .{ .array_value = .{ .elems = new_elems.items } },
                    };
                }
                else {
                    self.reporter.reportErrorAtSpan(bin.rhs.span, "Repeat (**) operand must be an int literal", .{});
                }
            }
            else if (bin.op.kind == .PlusPlus) {
                if (rhs.value == .array_value and rhs.typ.isSame(lhs.typ)) {
                    const l_elems_len = lhs.value.array_value.elems.len;
                    const r_elems_len = rhs.value.array_value.elems.len;
                    var new_elems = std.ArrayList(tast.Expr).initCapacity(self.arena, l_elems_len + r_elems_len) catch unreachable;
                    
                    for (lhs.value.array_value.elems) |elem| {
                        new_elems.appendAssumeCapacity(elem);
                    }
                    
                    for (rhs.value.array_value.elems) |elem| {
                        new_elems.appendAssumeCapacity(elem);
                    }
                    
                    return .{
                        .typ = lhs.typ,
                        .mutability = .constant,
                        .value = .{ .array_value = .{ .elems = new_elems.items } },
                    };
                }
                else {
                    self.reporter.reportErrorAtSpan(bin.rhs.span, "Concat (++) operand must be an array with the same type", .{});
                }
            }
        }
        else if (lhs.typ.kind == .string and rhs.typ.kind == .string) {
            switch (bin.op.kind) {
                .PlusPlus => {
                    if (lhs.comptime_known and rhs.comptime_known) {
                        return .{
                            .comptime_known = true,
                            .mutability = .constant,
                            .typ = types.STRING,
                            .value = .{.string_concat = .{
                                .lhs = self.makeExprPointer(lhs),
                                .rhs = self.makeExprPointer(rhs),
                            }},
                        };
                    }
                    else {
                        self.reporter.reportErrorAtToken(bin.op, "The operands for concat (++) operation must be known at compile time", .{});
                    }
                },
                else => {}
            }
        }
        
        if (need_explicit_cast) {
            self.reporter.reportErrorAtSpan(
                span,
                "Need explicit cast in binary operation `{s}` for type `{s}` and `{s}`",
                .{
                    bin.op.kind.getBinopText(),
                    lhs.typ.getTextLeak(self.arena),
                    rhs.typ.getTextLeak(self.arena),
                },
            );
        }
        else if (!valid) {
            self.reporter.reportErrorAtToken(
                bin.op,
                "Invalid binary operation `{s}` for type `{s}` and `{s}`",
                .{
                    bin.op.kind.getBinopText(),
                    lhs.typ.getTextLeak(self.arena),
                    rhs.typ.getTextLeak(self.arena),
                },
            );
        }
        
        const binop: tast.Binop = switch (bin.op.kind) {
            .Plus => .add,
            .Minus =>.sub,
            .Mul => .mul,
            .Div => .div,
            .Mod => .mod,
            .Gt => .gt,
            .Gte => .gte,
            .Lt => .lt,
            .Lte => .lte,
            .EqEq => .eq_eq,
            .NotEq => .not_eq,
            .Or => .or_,
            .OrOr => .or_or,
            .And => .and_,
            .AndAnd => .and_and,
            else => std.debug.panic("Unreachable binop {s}", .{@tagName(bin.op.kind)}),
        };
        
        return .{
            .typ = typ,
            .mutability = .constant,
            .value = .{.binary = .{
                .lhs = self.makeExprPointer(lhs),
                .rhs = self.makeExprPointer(rhs),
                .op = binop,
            }},
        };
    }
    
    fn typeArrayValue(self: *Typer, scope: *Scope, arr: *const ast.ArrayValue, span: TokenSpan, exp_typ: *const Type) tast.Expr {
        var elem_typ = types.UNKNOWN;
        var elems = std.ArrayList(tast.Expr).initCapacity(self.arena, arr.elems.len) catch unreachable;
        
        const exp_elem_typ = if (exp_typ.kind == .array) exp_typ.value.array.child
        else types.UNKNOWN;
        
        const is_dyn = if (exp_typ.kind == .array) exp_typ.value.array.is_dyn
        else false;
        
        for (arr.elems, 0..) |elem, i| {
            const elem_expr = self.typeExpr(scope, &elem, exp_elem_typ);
            
            if (i == 0) {
                elem_typ = elem_expr.typ;
            }
            else {
                if (elem_expr.typ.canBeCombinedWith(elem_typ)) {
                    elem_typ = elem_typ.combinedWith(elem_expr.typ);
                }
                else {
                    self.reporter.reportErrorAtSpan(
                        elem.span,
                        "Expected type `{s}` but got `{s}`",
                        .{
                            elem_typ.getTextLeak(self.arena),
                            elem_expr.typ.getTextLeak(self.arena),
                        }
                    );
                }
            }
            
            elems.appendAssumeCapacity(elem_expr);
        }
        
        // elem_typ = elem_typ.coerceIntoRuntime(self.type_manager);
        var typ = self.type_manager.createArray(elem_typ, is_dyn, elems.items.len);
        
        if (exp_typ.kind == .unknown) {
            typ = typ.coerceIntoRuntime(self.type_manager);
        }
        else if (typ.canBeAssignedTo(exp_typ)) {
            typ = typ.assignTo(exp_typ);
        }
        else {
            self.reporter.reportErrorAtSpan(
                span,
                "Expected type `{s}` but got `{s}`",
                .{
                    exp_typ.getTextLeak(self.arena),
                    typ.getTextLeak(self.arena),
                }
            );
        }
        
        return .{
            .typ = typ,
            .mutability = .constant,
            .value = .{ .array_value = .{ .elems = elems.items } },
        };
    }
    
    fn typeArrayIndex(self: *Typer, scope: *Scope, arr: *const ast.ArrayIndex) tast.Expr {
        const callee = self.makeExprPointer(self.typeExpr(scope, arr.callee, types.UNKNOWN));
        const index = self.makeExprPointer(self.typeExpr(scope, arr.index, types.UNKNOWN));
        
        if (callee.typ.kind != .array) {
            self.reporter.reportErrorAtSpan(arr.callee.span, "Not an array", .{});
        }
        
        if (!index.typ.isNumericInt()) {
            self.reporter.reportErrorAtSpan(
                arr.index.span,
                "Type `{s}` cannot be used as array index",
                .{index.typ.getTextLeak(self.arena)},
            );
        }
        
        const mutability: Mutability = if (callee.mutability == .constant) .constant else .mutable;
        
        return .{
            .typ = callee.typ.value.array.child,
            .mutability = mutability,
            .value = .{.array_index = .{
                .callee = callee,
                .index = index,
            }},
        };
    }
    
    fn typeRange(self: *Typer, scope: *Scope, range: *const ast.Range) tast.Expr {
        const lhs = self.makeExprPointer(self.typeExpr(scope, range.lhs, types.UNKNOWN));
        const rhs = self.makeExprPointer(self.typeExpr(scope, range.rhs, types.UNKNOWN));
        
        if (!lhs.typ.canBeAssignedTo(types.I32)) {
            self.reporter.reportErrorAtSpan(
                range.lhs.span,
                "Type `{s}` cannot be used as for range item. Must be an int",
                .{lhs.typ.getTextLeak(self.arena)},
            );
        }
        
        if (!rhs.typ.canBeAssignedTo(types.I32)) {
            self.reporter.reportErrorAtSpan(
                range.rhs.span,
                "Type `{s}` cannot be used as for range item. Must be an int",
                .{rhs.typ.getTextLeak(self.arena)},
            );
        }
        
        return .{
            .typ = types.RANGE,
            .mutability = .constant,
            .value = .{ .range = .{
                .lhs = lhs,
                .rhs = rhs,
                .is_eq = range.is_eq,
            }},
        };
    }
    
    fn typeMemberAccess(self: *Typer, scope: *Scope, mem: *const ast.MemberAccess) tast.Expr {
        const callee = self.makeExprPointer(self.typeExpr(scope, mem.callee, types.UNKNOWN));
        
        switch (callee.typ.kind) {
            .array => {
                return self.typeArrayBuiltin(scope, callee, mem.member);
            },
            .@"struct" => {
                return self.typeStructMember(scope, callee, mem.member, false);
            },
            .@"enum" => {
                return self.typeEnumMember(scope, callee, mem.member, false);
            },
            .reference => {
                if (callee.typ.value.reference.child.kind == .@"struct") {
                    return self.typeStructMember(scope, callee, mem.member, true);
                }
                else if (callee.typ.value.reference.child.kind == .@"enum") {
                    return self.typeEnumMember(scope, callee, mem.member, true);
                }
            },
            .typ => {
                switch (callee.typ.value.typ.child.value) {
                    .@"enum" => {
                        return self.typeEnumItem(scope, callee.typ.value.typ.child, mem.member);
                    },
                    .@"struct" => |struct_typ| {
                        return self.typeStructStaticMember(scope, &struct_typ, mem.member);
                    },
                    else => {},
                }
            },
            else => {}
        }
        
        self.reporter.reportErrorAtToken(
            mem.member,
            "Type `{s}` doesn't have member `{s}`",
            .{
                callee.typ.getTextLeak(self.arena),
                self.getTokenText(mem.member),
            }
        );
    }
    
    fn typeStructMember(self: *Typer, scope: *Scope, callee: *tast.Expr, member: Token, is_reference: bool) tast.Expr {
        _ = scope;
        
        const callee_typ = if (is_reference) callee.typ.value.reference.child else callee.typ;
        const member_text = self.getTokenText(member);
        
        const Inner = struct {
            fn allocateCallee(typer: *Typer, callee_: *tast.Expr, should_allocate: bool) *tast.Expr {
                if (should_allocate) {
                    return typer.makeExprPointer(callee_.*);
                }
                
                return callee_;
            }
            
            fn typeStructMemberInner(
                typer: *Typer,
                callee_typ_: *const Type,
                callee_: *tast.Expr,
                member_text_: []const u8,
                should_allocate: bool,
                is_reference_: bool,
            ) ?tast.Expr {
                const struct_typ = callee_typ_.value.@"struct";
                
                if (struct_typ.field_map.get(member_text_)) |index| {
                    return .{
                        .typ = struct_typ.fields[index].typ,
                        .mutability = if (is_reference_) .mutable else if (callee_.mutability == .constant) .constant else .mutable,
                        .value = .{.struct_member = .{
                            .callee = allocateCallee(typer, callee_, should_allocate),
                            .member_index = index,
                        }},
                    };
                }
                
                if (struct_typ.method_map.get(member_text_)) |index| {
                    const method = struct_typ.methods[index];
                    var actual_callee = allocateCallee(typer, callee_, should_allocate);
                        
                    if (method.typ.value.func.params[0].value == .reference) {
                        if (callee_.typ.value == .@"struct") {
                            const reference_typ = typer.type_manager.createReference(callee_.typ);
                            
                            actual_callee = typer.makeExprPointer(.{
                                .value = .{
                                    .referenc_of = .{
                                        .value = actual_callee,
                                        .typ = reference_typ,
                                    }
                                },
                                .typ = reference_typ,
                                .mutability = .constant,
                            });
                        }
                    }
                    else if (callee_.typ.value == .reference) {
                        if (method.typ.value.func.params[0].value == .@"struct") {
                            actual_callee = typer.makeExprPointer(.{
                                .value = .{
                                    .dereferenc_of = .{
                                        .value = actual_callee,
                                        .typ = callee_.typ.value.reference.child,
                                    }
                                },
                                .typ = callee_.typ.value.reference.child,
                                .mutability = .constant,
                            });
                        }
                    }
                    
                    return .{
                        .typ = method.typ,
                        .value = .{.struct_method = .{
                            .callee = actual_callee,
                            .method_index = index,
                            .struct_typ = callee_typ_,
                        }},
                        .mutability = .constant,
                    };
                }
                
                for (struct_typ.fields, 0..) |field, i| {
                    if (field.is_using and field.typ.value == .@"struct") {
                        var member_callee: tast.Expr = .{
                            .typ = field.typ,
                            .mutability = callee_.mutability,
                            .comptime_known = callee_.comptime_known,
                            .value = .{.struct_member = .{
                                .callee = allocateCallee(typer, callee_, should_allocate),
                                .member_index = i,
                            }},
                        };
                        
                        if (typeStructMemberInner(typer, field.typ, &member_callee, member_text_, true, is_reference_)) |expr| {
                            return expr;
                        }
                    }
                }
                
                return null;
            }
        };
        
        if (Inner.typeStructMemberInner(self, callee_typ, callee, member_text, false, is_reference)) |expr| {
            return expr;
        }
        
        self.reporter.reportErrorAtToken(
            member,
            "Type `{s}` doesn't have member `{s}`",
            .{
                callee.typ.getTextLeak(self.arena),
                member_text,
            }
        );
    }
    
    fn typeStructStaticMember(self: *Typer, scope: *Scope, struct_typ: *const types.TypeStruct, member: Token) tast.Expr {
        const struct_symbol = scope.get(struct_typ.name.text);
        std.debug.assert(struct_symbol != null and struct_symbol.?.typ.value == .typ and struct_symbol.?.typ.value.typ.child.value == .@"struct");
        
        const member_text = self.getTokenText(member);
        
        if (struct_symbol.?.child_symbols) |child_symbols| {
            const symbol = child_symbols.get(member_text);
            
            if (symbol) |sym| {
                return .{
                    .typ = sym.typ,
                    .mutability = sym.mutability,
                    .comptime_known = sym.comptime_known,
                    .value = .{.identifier = .{ .name = sym.symbol }},
                };
            }
        }
        
        self.reporter.reportErrorAtToken(
            member,
            "Struct `{s}` doesn't have member `{s}`",
            .{
                struct_typ.name.text,
                member_text,
            },
        );
    }
    
    fn typeEnumValue(self: *Typer, scope: *Scope, val: *const ast.EnumValue, span: TokenSpan, exp_typ: *const Type) tast.Expr {
        _ = span;
        
        if (exp_typ.value != .@"enum") {
            // self.reporter.reportErrorAtSpan(span, "Unknown enum value", .{});
            return .{
                .typ = types.UNKNOWN_ENUM,
                .mutability = .constant,
                .value = .invalid,
            };
        }
        
        return self.typeEnumItem(scope, exp_typ, val.item);
    }
    
    fn typeEnumItem(self: *Typer, scope: *Scope, enum_typ: *const Type, member: Token) tast.Expr {
        const member_text = self.getTokenText(member);
        
        std.debug.assert(enum_typ.value == .@"enum");
        
        for (enum_typ.value.@"enum".items, 0..) |item, i| {
            if (std.mem.eql(u8, member_text, item.text)) {
                return .{
                    .typ = enum_typ,
                    .mutability = .constant,
                    .value = .{.enum_value = .{ .item_index = i }},
                };
            }
        }
        
        const enum_symbol = scope.get(enum_typ.value.@"enum".name.text);
        std.debug.assert(enum_symbol != null and enum_symbol.?.typ.value == .typ and enum_symbol.?.typ.value.typ.child.value == .@"enum");
        
        if (enum_symbol.?.child_symbols) |child_symbols| {
            const symbol = child_symbols.get(member_text);
            
            if (symbol) |sym| {
                return .{
                    .typ = sym.typ,
                    .comptime_known = sym.comptime_known,
                    .mutability = sym.mutability,
                    .value = .{.identifier = .{ .name = sym.symbol }},
                };
            }
        }
        
        self.reporter.reportErrorAtToken(
            member,
            "Enum `{s}` doesn't have item or member `{s}`",
            .{
                enum_typ.value.@"enum".name.text,
                member_text,
            }
        );
    }
    
    fn typeEnumMember(self: *Typer, scope: *Scope, callee: *tast.Expr, member: Token, is_reference: bool) tast.Expr {
        _ = scope;
        
        const callee_typ = if (is_reference) callee.typ.value.reference.child else callee.typ;
        const enum_typ = callee_typ.value.@"enum";
        const member_text = self.getTokenText(member);
        
        for (enum_typ.methods, 0..) |method, i| {
            if (std.mem.eql(u8, method.name.text, member_text)) {
                var actual_callee = callee;
                
                if (method.typ.value.func.params[0].value == .reference) {
                    if (callee.typ.value == .@"struct") {
                        const reference_typ = self.type_manager.createReference(callee.typ);
                        
                        actual_callee = self.makeExprPointer(.{
                            .value = .{
                                .referenc_of = .{
                                    .value = callee,
                                    .typ = reference_typ,
                                }
                            },
                            .typ = reference_typ,
                            .mutability = .constant,
                        });
                    }
                }
                else if (callee.typ.value == .reference) {
                    if (method.typ.value.func.params[0].value == .@"struct") {
                        actual_callee = self.makeExprPointer(.{
                            .value = .{
                                .dereferenc_of = .{
                                    .value = callee,
                                    .typ = callee.typ.value.reference.child,
                                }
                            },
                            .typ = callee.typ.value.reference.child,
                            .mutability = .constant,
                        });
                    }
                }
                
                return .{
                    .typ = method.typ,
                    .mutability = .constant,
                    .value = .{.enum_method = .{
                        .callee = actual_callee,
                        .method_index = i,
                        .enum_typ = callee_typ,
                    }},
                };
            }
        }
        
        self.reporter.reportErrorAtToken(
            member,
            "Type `{s}` doesn't have member `{s}`",
            .{
                callee.typ.getTextLeak(self.arena),
                member_text,
            }
        );
    }
    
    fn typeArrayBuiltin(self: *Typer, scope: *Scope, ar: *tast.Expr, member: Token) tast.Expr {
        _ = scope;
        
        const member_text = self.getTokenText(member);
        const ar_typ = if (ar.typ.kind == .array) ar.typ.value.array else unreachable;
        
        if (std.mem.eql(u8, member_text, "len")) {
            const args = self.arena.alloc(*const tast.Expr, 1) catch unreachable;
            args[0] = ar;
            
            return .{
                .typ = types.UNTYPED_INT,
                .mutability = .constant,
                .value = .{.builtin = .{ .array_len = .{ .arr = ar } }}
            };
        }
        else if (ar_typ.is_dyn) {
            if (std.mem.eql(u8, member_text, "append")) {
                const param_types = self.arena.alloc(*const Type, 1) catch unreachable;
                param_types[0] = ar_typ.child;
                
                return .{
                    .typ = self.type_manager.createFn(param_types, types.VOID, false, true),
                    .mutability = .constant,
                    .value = .{ .builtin = .{ .dynarray_append = .{ .arr = ar } } }
                };
            }
            else {
                self.reporter.reportErrorAtToken(
                    member,
                    "Type `{s}` doesn't have member `{s}`",
                    .{
                        ar.typ.getTextLeak(self.arena),
                        self.getTokenText(member),
                    }
                );
            }
        }
        else {
            self.reporter.reportErrorAtToken(
                member,
                "Type `{s}` doesn't have member `{s}`",
                .{
                    ar.typ.getTextLeak(self.arena),
                    self.getTokenText(member),
                }
            );
        }
    }
    
    fn typeStructValue(self: *Typer, scope: *Scope, val: *const ast.StructValue, span: TokenSpan, exp_typ: *const Type) tast.Expr {
        var typ: *const Type = undefined;
        
        if (val.struct_name) |struct_name| {
            const name_text = self.getTokenText(struct_name);
            const struct_symbol = scope.get(name_text);
            
            if (struct_symbol) |symbol| {
                if (symbol.typ.value != .typ or symbol.typ.value.typ.child.value != .@"struct") {
                    self.reporter.reportErrorAtToken(struct_name, "Not a struct", .{});
                }
                
                typ = symbol.typ.value.typ.child;
            }
            else {
                self.reporter.reportErrorAtToken(struct_name, "Unknown identifier `{s}`", .{name_text});
            }
        }
        else if (exp_typ.kind == .unknown) {
            self.reporter.reportErrorAtSpan(span, "Unkown struct type", .{});
        }
        else {
            typ = exp_typ;
        }
        
        if (typ.value == .reference and typ.value.reference.child.value == .@"struct") {
            self.reporter.reportErrorAtSpan(
                span,
                "Expected type `{s}` but got `{s}`",
                .{
                    typ.getTextLeak(self.arena),
                    typ.value.reference.child.getTextLeak(self.arena)
                }
            );
        }
        else if (typ.value != .@"struct") {
            self.reporter.reportErrorAtSpan(span, "Expected type `{s}` but got a struct", .{typ.getTextLeak(self.arena)});
        }
        
        const FieldState = enum {
            unresolved,
            resolved,
            has_default,
        };
        
        const struct_typ = typ.value.@"struct";
        const field_len = struct_typ.fields.len;
        var field_states = self.temp_allocator.alloc(FieldState, field_len) catch unreachable;
        defer self.temp_allocator.free(field_states);
        var values = self.arena.alloc(tast.Expr, field_len) catch unreachable;
        
        for (0..field_len) |i| {
            if (struct_typ.fields[i].default_value != null) {
                field_states[i] = .has_default;
            }
            else {
                field_states[i] = .unresolved;
            }
        }
        
        for (0..val.elems.len) |i| {
            if (i >= field_len) {
                self.reporter.reportErrorAtSpan(val.elems[i].value.span, "Too many field", .{});
            }
            
            var field_index: usize = undefined;
            
            if (val.elems[i].field_name) |field_name_token| {
                const field_name = self.getTokenText(field_name_token);
                var index: ?usize = null;
                
                for (struct_typ.fields, 0..) |struct_field, struct_field_index| {
                    if (std.mem.eql(u8, struct_field.name.text, field_name)) {
                        index = struct_field_index;
                        break;
                    }
                }
                
                if (index == null) {
                    self.reporter.reportErrorAtToken(
                        field_name_token,
                        "Unkown struct field `{s}`",
                        .{field_name},
                    );
                }
                
                // Placed here because it's impossible to have duplicate unless field has a name
                if (field_states[index.?] == .resolved) {
                    self.reporter.reportErrorAtToken(
                        field_name_token,
                        "Duplicate struct field `{s}`",
                        .{field_name},
                    );
                }
                
                field_index = index.?;
            }
            else {
                field_index = i;
            }
            
            field_states[field_index] = .resolved;
            values[field_index] = self.typeExpr(scope, &val.elems[i].value, struct_typ.fields[field_index].typ);
            
            if (!values[field_index].typ.canBeAssignedTo(struct_typ.fields[field_index].typ)) {
                self.reporter.reportErrorAtSpan(
                    val.elems[i].value.span,
                    "Expected type `{s}` but got `{s}`",
                    .{
                        struct_typ.fields[i].typ.getTextLeak(self.arena),
                        values[i].typ.getTextLeak(self.arena),
                    }
                );
            }
        }
        
        for (field_states, 0..) |field_state, i| {
            if (field_state == .unresolved) {
                self.reporter.reportErrorAtSpan(
                    span,
                    "Missing struct field `{s}` with type of `{s}`",
                    .{
                        struct_typ.fields[i].name.text,
                        struct_typ.fields[i].typ.getTextLeak(self.arena),
                    }
                );
            }
            else if (field_state == .has_default) {
                values[i] = @as(*tast.Expr, @alignCast(@ptrCast(struct_typ.fields[i].default_value.?))).*;
            }
        }
        
        return .{
            .typ = typ,
            .mutability = .constant,
            .value = .{ .struct_value = .{ .values = values } },
        };
    }
    
    fn typeAddressOf(self: *Typer, scope: *Scope, addr: *const ast.AddressOf, exp_typ: *const Type) tast.Expr {
        const child_typ = if (exp_typ.value == .reference) exp_typ.value.reference.child else types.UNKNOWN;
        const value = self.typeExpr(scope, addr.value, child_typ);
        
        return .{
            .typ = self.type_manager.createReference(value.typ),
            .mutability = .constant,
            .value = .{.referenc_of = .{
                .typ = value.typ,
                .value = self.makeExprPointer(value),
            }},
        };
    }
    
    fn typeCast(self: *Typer, scope: *Scope, cast: *const ast.Cast, span: TokenSpan) tast.Expr {
        const expr = self.typeExpr(scope, cast.value, types.UNKNOWN);
        const typ = self.typeType(scope, &cast.typ);
        
        if (!expr.typ.canBeCastTo(typ)) {
            self.reporter.reportErrorAtSpan(
                span,
                "Cannot cast `{s}` to `{s}`",
                .{
                    expr.typ.getTextLeak(self.arena),
                    typ.getTextLeak(self.arena),
                }
            );
        }
        
        return .{
            .typ = typ,
            .mutability = .constant,
            .value = .{.cast = .{
                .value = self.makeExprPointer(expr),
                .typ = typ,
            }},
        };
    }
    
    fn typeType(self: *Typer, scope: *Scope, typ: *const ast.Type) *const Type {
        var result_type: *const Type = undefined;
        
        switch (typ.value) {
            ast.TypeKind.simple => {
                const typ_text = self.getTokenText(typ.value.simple.name);
                
                if (std.mem.eql(u8, typ_text, "u8"))       { result_type = types.U8; }
                else if (std.mem.eql(u8, typ_text, "u16")) { result_type = types.U16; }
                else if (std.mem.eql(u8, typ_text, "u32")) { result_type = types.U32; }
                else if (std.mem.eql(u8, typ_text, "u64")) { result_type = types.U64; }
                else if (std.mem.eql(u8, typ_text, "i8"))  { result_type = types.I8; }
                else if (std.mem.eql(u8, typ_text, "i16")) { result_type = types.I16; }
                else if (std.mem.eql(u8, typ_text, "i32")) { result_type = types.I32; }
                else if (std.mem.eql(u8, typ_text, "i64")) { result_type = types.I64; }
                else if (std.mem.eql(u8, typ_text, "f32")) { result_type = types.F32; }
                else if (std.mem.eql(u8, typ_text, "f64")) { result_type = types.F64; }
                
                else if (std.mem.eql(u8, typ_text, "bool"))   { result_type = types.BOOL; }
                else if (std.mem.eql(u8, typ_text, "char"))   { result_type = types.CHAR; }
                else if (std.mem.eql(u8, typ_text, "string")) { result_type = types.STRING; }
                else if (std.mem.eql(u8, typ_text, "range"))  { result_type = types.RANGE; }
                
                else if (std.mem.eql(u8, typ_text, "void"))   { result_type = types.VOID; }
                else if (std.mem.eql(u8, typ_text, "any"))    { result_type = types.ANY; }
                
                else {
                    const symbol = scope.get(typ_text);
                    
                    if (symbol) |sym| {
                        if (sym.typ.kind != .typ) {
                            self.reporter.reportErrorAtToken(typ.value.simple.name, "`{s}` is not a type", .{typ_text});
                        }
                        
                        result_type = sym.typ.value.typ.child;
                    }
                    else {
                        self.reporter.reportErrorAtToken(typ.value.simple.name, "Unknown type `{s}`", .{typ_text});
                    }
                }
            },
            ast.TypeKind.array => {
                result_type = self.type_manager.createArray(
                    self.typeType(scope, typ.value.array.child),
                    typ.value.array.is_dyn,
                    null
                );
            },
            ast.TypeKind.reference => {
                result_type = self.type_manager.createReference(
                    self.typeType(scope, typ.value.reference.child)
                );
            },
            
            else => {
                std.debug.panic("TODO: typeType {s}", .{@tagName(typ.value)});
            }
        }
        
        return result_type;
    }
    
    fn makeStmtPointer(self: *Typer, stmt: tast.Stmt) *tast.Stmt {
        const p = self.arena.create(tast.Stmt) catch unreachable;
        p.* = stmt;
        
        return p;
    }
    
    fn makeExprPointer(self: *Typer, expr: tast.Expr) *tast.Expr {
        const p = self.arena.create(tast.Expr) catch unreachable;
        p.* = expr;
        
        return p;
    }
    
    fn makeMaybeCast(self: *Typer, expr: *tast.Expr, into: *const Type) *tast.Expr {
        if (expr.typ.isSame(into)) return expr;
        
        if (expr.typ.kind == .numeric and into.kind == .numeric) {
            if (expr.typ.value.numeric.isUntyped() and expr.typ.value.numeric.isInt() and into.value.numeric.isInt()) {
                expr.typ = into;
                return expr;
            }
        }
        
        return self.makeExprPointer(.{
            .typ = into,
            .mutability = .constant,
            .value = .{.cast = .{
                .typ = expr.typ,
                .value = expr,
            }},
        });
    }
    
    fn collectAndFreeTempList(self: *Typer, comptime T: type, list: *std.ArrayList(T)) []const T {
        const res = self.arena.dupe(T, list.items) catch unreachable;
        list.clearAndFree(self.temp_allocator);
        
        return res;
    }
    
    fn getTokenText(self: *Typer, token: Token) []const u8 {
        const src = self.file_manager.getContent(token.loc.file_id);
        return src[token.loc.index..token.loc.index + token.loc.len];
    }
};

pub fn typecheck(
    arena: std.mem.Allocator,
    reporter: *const Reporter,
    file_manager: *const FileManager,
    symbol_manager: *SymbolManager,
    type_manager: *TypeManager,
    module: *const ast.Module,
    module_id: usize,
    module_name: []const u8,
    children: *const std.StringHashMap(*tast.Module),
) tast.Module {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const temp_allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    
    var typer = Typer.init(arena, temp_allocator, reporter, file_manager, type_manager, symbol_manager, children);
    var scope = Scope.init(arena, .module);
    // defer scope.deinit();
    
    return typer.typeModule(&scope, module, module_id, module_name);
}