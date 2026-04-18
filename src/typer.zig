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

const VarDeclData = struct {
    typ: *const Type,
    tast: tast.VarDecl,
    ast: *const ast.VarDecl,
    span: TokenSpan,
    scope: *Scope,
    symbol_id: usize,
    state: enum {
        unresolved,
        resolving,
        resolved,
    } = .unresolved,
};

const FnDeclData = struct {
    typ: *Type,
    tast: tast.FnDecl,
    ast: *const ast.FnDecl,
    span: TokenSpan,
    scope: *Scope,
    external_type_params: []const *const Type = &.{},
};

const StructDeclData = struct {
    typ: *Type,
    ast: *const ast.StructDecl,
    scope: *Scope,
    type_params: []const Symbol,
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
    
    var_decl_datas: std.ArrayList(VarDeclData) = .empty,
    fn_decl_datas: std.ArrayList(FnDeclData) = .empty,
    struct_decl_datas: std.ArrayList(StructDeclData) = .empty,
    enum_decl_datas: std.ArrayList(EnumDeclData) = .empty,
    
    cur_fn: ?*tast.FnDecl = null,
    cur_breakable: ?*tast.Stmt = null,
    cur_container_type: ?*const Type = null,
    
    generic_fn_decls: std.AutoHashMap(u64, *FnDeclData),
    generic_fn_monomorphized: std.AutoHashMap(u64, Symbol),
    fn_decls: std.ArrayList(tast.FnDecl) = .empty,
    
    generic_structs: std.AutoHashMap(u64, *const Type),
    
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
            
            .generic_fn_decls = std.AutoHashMap(u64, *FnDeclData).init(temp_allocator),
            .generic_fn_monomorphized = std.AutoHashMap(u64, Symbol).init(temp_allocator),
            
            .generic_structs = std.AutoHashMap(u64, *const Type).init(temp_allocator),
        };
    }
    
    fn deinit(self: *Typer) void {
        self.generic_fn_decls.deinit();
        self.generic_fn_monomorphized.deinit();
        self.generic_structs.deinit();
    }
    
    fn typeModule(self: *Typer, scope: *Scope, module: *const ast.Module, module_id: usize, module_name: []const u8) tast.Module {        
        self.symbol_manager.pushNamespace(module_name);
        self.typeDeclStmts(scope, module.exprs);
        _ = self.typeStmts(scope, module.exprs);
        self.symbol_manager.popNamespace();
        
        var public_symbols = std.StringHashMap(TypedSymbol).init(self.arena);
        {
            var iter = scope.syms.iterator();
            
            while (iter.next()) |entry| {
                public_symbols.put(entry.key_ptr.*, entry.value_ptr.*) catch unreachable;
            }
        }
        
        var children = std.ArrayList(*tast.Module).initCapacity(self.arena, self.children.count()) catch unreachable;
        var child_iter = self.children.iterator();
        
        while (child_iter.next()) |entry| {
            children.appendAssumeCapacity(entry.value_ptr.*);
        }
        
        // Registering struct field declarations
        for (self.struct_decl_datas.items) |struct_decl_data| {
            self.typeStructDeclFields(struct_decl_data.scope, struct_decl_data.ast, struct_decl_data.typ);
        }
        
        // After registering all the structs (including generic)
        // then we register generic struct field per generic instance
        {
            var iter = self.generic_structs.valueIterator();
            
            while (iter.next()) |typ| {
                typ.*.fillGenericStruct(self.type_manager);
            }
        }
        
        for (self.struct_decl_datas.items) |struct_decl_data| {
            struct_decl_data.typ.value.@"struct".calculate(struct_decl_data.typ, self.reporter);
        }
        
        for (self.struct_decl_datas.items) |struct_decl_data| {
            self.typeStructDeclMember(struct_decl_data.scope, struct_decl_data.ast, struct_decl_data.typ);
        }
        
        for (self.enum_decl_datas.items) |enum_decl_data| {
            self.typeEnumDeclMember(enum_decl_data.scope, enum_decl_data.ast, enum_decl_data.typ);
        }
        
        for (self.fn_decl_datas.items) |*decl| {
            if (decl.tast.isGeneric()) {
                self.generic_fn_decls.put(decl.typ.type_id, decl) catch unreachable;
            }
        }
        
        var var_decls = std.ArrayList(tast.VarDecl).empty;
        
        var var_decl_symbol_map = std.AutoHashMap(usize, usize).init(self.temp_allocator);
        defer var_decl_symbol_map.deinit();
        
        for (self.var_decl_datas.items, 0..) |*decl, i| {
            var_decl_symbol_map.put(decl.symbol_id, i) catch unreachable;
        }
        
        for (self.var_decl_datas.items) |*decl| {
            if (decl.state != .unresolved) continue;
            self.resolveVarDecl(decl, &var_decl_symbol_map, &var_decls);
        }
        
        for (self.fn_decl_datas.items) |*decl| {
            if (!decl.tast.isGeneric()) {
                if (decl.ast.body != null) {
                    self.typeFnDeclBody(decl.scope, decl.ast, &decl.tast);
                }
                
                self.fn_decls.append(self.temp_allocator, decl.tast) catch unreachable;
            }
        }
        
        var public_child_scopes = std.StringHashMap(*Scope).init(self.arena);
        {
            var iter = scope.child_scopes.iterator();
            
            while (iter.next()) |entry| {
                public_child_scopes.put(entry.key_ptr.*, entry.value_ptr.*) catch unreachable;
            }
        }
        
        self.var_decl_datas.deinit(self.temp_allocator);
        self.fn_decl_datas.deinit(self.temp_allocator);
        self.struct_decl_datas.deinit(self.temp_allocator);
        self.enum_decl_datas.deinit(self.temp_allocator);
        
        return .{
            .id = module_id,
            .var_decls = self.collectAndFreeTempList(tast.VarDecl, &var_decls),
            .fn_decls = self.collectAndFreeTempList(tast.FnDecl, &self.fn_decls),
            .public_symbols = public_symbols,
            .public_child_scopes = public_child_scopes,
            .children = children.items,
        };
    }
    
    fn typeDeclStmts(self: *Typer, scope: *Scope, exprs: []const ast.Expr) void {
        for (exprs, 0..) |expr, i| {
            switch (expr.value) {
                ast.Kind.import => |imp| {
                    self.typeImport(scope, &imp);
                },
                ast.Kind.struct_decl => {
                    self.struct_decl_datas.append(
                        self.temp_allocator,
                        self.typeStructDeclForward(scope, &exprs[i].value.struct_decl),
                    ) catch unreachable;
                },
                ast.Kind.enum_decl => {
                    self.enum_decl_datas.append(
                        self.temp_allocator,
                        self.typeEnumDecl(scope, &exprs[i].value.enum_decl),
                    ) catch unreachable;
                },
                else => {}
            }
        }
        
        for (exprs, 0..) |expr, i| {
            switch (expr.value) {
                ast.Kind.import,
                ast.Kind.struct_decl,
                ast.Kind.enum_decl => {},
                ast.Kind.var_decl => {
                    if (scope.mode == .module or scope.mode == .container) {
                        self.var_decl_datas.append(
                            self.temp_allocator,
                            self.typeVarDeclForward(scope, &exprs[i].value.var_decl, expr.span),
                        ) catch unreachable;
                    }
                },
                ast.Kind.fn_decl => {
                    const ast_fn_decl = &exprs[i].value.fn_decl;
                    const fn_decl_data = self.typeFnDeclForward(scope, ast_fn_decl, expr.span);
                    
                    self.fn_decl_datas.append(
                        self.temp_allocator,
                        fn_decl_data,
                    ) catch unreachable;
                    
                    if (ast_fn_decl.body) |body| {
                        self.typeDeclStmts(fn_decl_data.scope, body.exprs);
                    }
                },
                else => {}
            }
        }
    }
    
    fn typeStmts(self: *Typer, scope: *Scope, exprs: []const ast.Expr) []const tast.Stmt {
        var stmts = std.ArrayList(tast.Stmt).empty;
        
        for (exprs) |expr| {
            switch (expr.value) {
                ast.Kind.import,
                ast.Kind.fn_decl,
                ast.Kind.struct_decl,
                ast.Kind.enum_decl => {},
                ast.Kind.var_decl => |var_decl| {
                    if (scope.mode == .local) {
                        stmts.append(self.temp_allocator, self.typeVarDecl(scope, &var_decl, expr.span)) catch unreachable;
                    }
                },
                else => {
                    if (scope.mode == .module or scope.mode == .container) {
                        self.reporter.reportErrorAtSpan(expr.span, "This kind of statement cannot be placed inside a function", .{});
                    }
                    
                    stmts.append(self.temp_allocator, self.typeStmt(scope, &expr, false)) catch unreachable;
                }
            }
        }
        
        return self.collectAndFreeTempList(tast.Stmt, &stmts);
    }
    
    fn typeStmt(self: *Typer, scope: *Scope, stmt: *const ast.Expr, dont_create_new_scope: bool) tast.Stmt {
        switch (stmt.value) {
            .var_decl   => |decl|   { return self.typeVarDecl(scope, &decl, stmt.span); },
            .assignment => |ass|    { return self.typeAssignment(scope, &ass); },
            .fn_call    => |call|   { return self.typeFnCallStmt(scope, &call, stmt.span); },
            .returns    => |ret|    { return self.typeReturn(scope, &ret, stmt.span); },
            .iff        => |iff|    { return self.typeIf(scope, &iff); },
            .switc      => |switc|  { return self.typeSwitch(scope, &switc); },
            .whil       => |whil|   { return self.typeWhile(scope, &whil); },
            .forr       => |forr|   { return self.typeFor(scope, &forr); },
            .block      => |block|  { return self.typeBlockStmt(scope, &block, dont_create_new_scope); },
            .breaq      => |_|      { return self.typeBreak(stmt.span); },
            
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
    
    fn typeFnDeclForward(self: *Typer, scope: *Scope, fn_decl: *const ast.FnDecl, span: TokenSpan) FnDeclData {
        const fn_name = self.getTokenText(fn_decl.name);
        
        if (scope.hasSelf(fn_name)) {
            self.reporter.reportErrorAtToken(fn_decl.name, "Symbol `{s}` is already defined", .{fn_name});
        }
        
        var tast_params = std.ArrayList(tast.FnParam).initCapacity(self.arena, fn_decl.params.len) catch unreachable;
        var params = std.ArrayList(types.TypeFuncParam).initCapacity(self.arena, fn_decl.params.len) catch unreachable;
        var type_param_types = std.ArrayList(*Type).initCapacity(self.arena, fn_decl.type_params.len) catch unreachable;
        var has_default = false;
        var is_variadic = false;
        var return_typ = types.VOID;
        
        const new_scope = scope.inheritWithMode(.local, scope.allocator);
        var type_param_symbols: []Symbol = &.{};
        
        if (fn_decl.type_params.len > 0) {
            type_param_symbols = self.arena.alloc(Symbol, fn_decl.type_params.len) catch unreachable;
            
            for (fn_decl.type_params, 0..) |p, i| {
                const type_param_name = self.getTokenText(p);
                const type_param_symbol = self.symbol_manager.createSymbol(p, false);
                const type_param_typ = self.type_manager.createTypeParam(type_param_symbol, i);
                
                new_scope.set(type_param_name, type_param_symbol, type_param_typ, true, .constant);
                type_param_symbols[i] = type_param_symbol;
                
                type_param_types.appendAssumeCapacity(type_param_typ);
            }
        }
        
        for (fn_decl.params) |param| {
            var param_typ = types.UNKNOWN;
            var param_default_value: ?*tast.Expr = null;
            
            if (param.typ) |typ| {
                param_typ = self.typeType(new_scope, &typ);
                
                if (param.default_value) |def_value| {
                    has_default = true;
                    param_default_value = self.makeExprPointer(self.typeExpr(new_scope, def_value, param_typ));
                    
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
                param_default_value = self.makeExprPointer(self.typeExpr(new_scope, def_value, types.UNKNOWN));
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
            
            tast_params.appendAssumeCapacity(tast.FnParam{
                .name = symbol,
                .default_value = param_default_value,
                .typ = param_typ,
                .is_variadic = is_variadic,
            });
            
            params.appendAssumeCapacity(.{
                .typ = param_typ,
                .default_value = param_default_value,
            });
        }
        
        if (fn_decl.return_typ) |typ| {
            return_typ = self.typeType(new_scope, &typ);
        }
        
        const namespaced = if (fn_decl.is_extern or scope.mode == .module and std.mem.eql(u8, fn_name, "main")) false else true;
        const fn_name_symbol = self.symbol_manager.createSymbol(fn_decl.name, namespaced);
        const fn_typ = self.type_manager.createFn(
            fn_name_symbol,
            params.items,
            type_param_types.items,
            return_typ,
            is_variadic,
            false,
            fn_decl.type_params.len > 0,
        );
        
        scope.set(fn_name, fn_name_symbol, fn_typ, true, .constant);
        
        const tast_fn_decl: tast.FnDecl = .{
            .is_extern = fn_decl.is_extern,
            .extern_name = fn_decl.extern_name,
            .extern_abi = fn_decl.extern_abi,
            .is_public = fn_decl.is_public,
            .name = fn_name_symbol,
            .return_typ = return_typ,
            .params = tast_params.items,
            .type_params = type_param_symbols,
            .body = null,
        };
        
        return .{
            .typ = fn_typ,
            .tast = tast_fn_decl,
            .ast = fn_decl,
            .scope = new_scope,
            .span = span,
        };
    }
    
    fn typeFnDeclBody(self: *Typer, scope: *Scope, fn_decl_ast: *const ast.FnDecl, forward_decl: *tast.FnDecl) void {        
        for (forward_decl.params) |param| {
            scope.set(param.name.text, param.name, param.typ, false, .constant);
        }
        
        const parent_fn = self.cur_fn;
        self.cur_fn = forward_decl;
        
        std.debug.assert(fn_decl_ast.body != null);
        forward_decl.body = self.typeBlock(scope, &fn_decl_ast.body.?, true);
        
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
    
    fn typeBreak(self: *Typer, span: TokenSpan) tast.Stmt {
        if (self.cur_breakable) |_| {
            return .breaq;
        }
        else {
            self.reporter.reportErrorAtSpan(span, "`break` can only be placed inside `for` or `while` loop", .{});
        }
    }
    
    fn typeStructDeclForward(self: *Typer, scope: *Scope, decl: *const ast.StructDecl) StructDeclData {
        const struct_symbol = if (decl.name) |name| self.symbol_manager.createSymbol(name, true)
        else self.symbol_manager.createUnnamedSymbol("inline_struct", decl.struct_token, true);
        
        const struct_type = self.type_manager.createStructForward(struct_symbol);
        const struct_type_container = self.type_manager.createType(struct_type);
        
        scope.set(struct_symbol.text, struct_symbol, struct_type_container, true, .constant);       
        const new_scope = scope.inheritWithMode(.container, self.arena);
        
        var type_param_types = std.ArrayList(*Type).initCapacity(self.arena, decl.type_params.len) catch unreachable;
        var type_param_symbols: []Symbol = &.{};
        
        if (decl.type_params.len > 0) {
            type_param_symbols = self.arena.alloc(Symbol, decl.type_params.len) catch unreachable;
            
            for (decl.type_params, 0..) |p, i| {
                const type_param_name = self.getTokenText(p);
                const type_param_symbol = self.symbol_manager.createSymbol(p, false);
                const type_param_typ = self.type_manager.createTypeParam(type_param_symbol, i);
                
                new_scope.set(type_param_name, type_param_symbol, type_param_typ, true, .constant);
                type_param_symbols[i] = type_param_symbol;
                
                type_param_types.appendAssumeCapacity(type_param_typ);
            }
            
            struct_type.value.@"struct".type_params = type_param_types.items;
        }
        
        return .{
            .ast = decl,
            .typ = struct_type,
            .scope = new_scope,
            .type_params = type_param_symbols,
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
            
            if (field.using != null and field_typ.value != .@"struct") {
                self.reporter.reportErrorAtToken(field.using.?, "`using` can only be applied to field with type of `struct`", .{});
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
        std.debug.assert(struct_typ.value == .@"struct");
        
        self.symbol_manager.pushNamespace(struct_typ.value.@"struct".name.text);
        const cur_container_type = self.cur_container_type;
        self.cur_container_type = struct_typ;
        
        var methods = std.ArrayList(types.TypeMethod).empty;
        
        for (decl.members, 0..) |mem, i| {
            switch (mem.value) {
                .var_decl => {
                    const tast_var_decl = self.typeVarDeclForward(scope, &decl.members[i].value.var_decl, mem.span);
                    self.var_decl_datas.append(self.temp_allocator, tast_var_decl) catch unreachable;
                },
                .fn_decl => {
                    const fn_decl_data = self.typeFnDeclForward(scope, &decl.members[i].value.fn_decl, decl.members[i].span);
                    
                    if (fn_decl_data.typ.value.func.params.len > 0 and fn_decl_data.typ.value.func.params[0].typ.isSameOrSameReference(struct_typ)) {
                        methods.append(self.temp_allocator, .{
                            .name = fn_decl_data.tast.name,
                            .typ = fn_decl_data.typ,
                        }) catch unreachable;
                    }
                    
                    if (struct_typ.value.@"struct".type_params.len == 0) {
                        self.fn_decl_datas.append(self.temp_allocator, fn_decl_data) catch unreachable;
                    }
                    else {
                        const fn_decl_ptr = self.arena.create(FnDeclData) catch unreachable;
                        fn_decl_ptr.* = fn_decl_data;
                        fn_decl_ptr.*.external_type_params = struct_typ.value.@"struct".type_params;
                        
                        self.generic_fn_decls.put(fn_decl_data.typ.type_id, fn_decl_ptr) catch unreachable;
                    }
                },
                .struct_decl => {
                    self.struct_decl_datas.append(
                        self.temp_allocator,
                        self.typeStructDeclForward(scope, &decl.members[i].value.struct_decl),
                    ) catch unreachable;
                },
                .enum_decl => {
                    self.enum_decl_datas.append(
                        self.temp_allocator,
                        self.typeEnumDecl(scope, &decl.members[i].value.enum_decl),
                    ) catch unreachable;
                },
                
                else => {
                    self.reporter.reportErrorAtSpan(mem.span, "Invalid struct member", .{});
                }
            }
        }
        
        struct_typ.value.@"struct".setMethods(self.collectAndFreeTempList(types.TypeMethod, &methods));
        scope.parent.?.setChildScope(struct_typ.value.@"struct".name.text, scope);
        
        self.cur_container_type = cur_container_type;
        self.symbol_manager.popNamespace();
    }
    
    fn typeEnumDecl(self: *Typer, scope: *Scope, decl: *const ast.EnumDecl) EnumDeclData {
        const enum_symbol = if (decl.name) |name| self.symbol_manager.createSymbol(name, true)
        else self.symbol_manager.createUnnamedSymbol("inline_enum", decl.enum_token, true);
        
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
        scope.set(enum_symbol.text, enum_symbol, enum_type_container, true, .constant);        
        const new_scope = scope.inheritWithMode(.container, self.arena);
        
        return .{
            .typ = enum_type,
            .ast = decl,
            .scope = new_scope,
        };
    }
    
    fn typeEnumDeclMember(self: *Typer, scope: *Scope, decl: *const ast.EnumDecl, enum_typ: *Type) void {
        std.debug.assert(enum_typ.value == .@"enum");
        
        self.symbol_manager.pushNamespace(enum_typ.value.@"enum".name.text);
        const cur_container_type = self.cur_container_type;
        self.cur_container_type = enum_typ;
        
        var methods = std.ArrayList(types.TypeMethod).empty;
        
        for (decl.members, 0..) |mem, i| {
            switch (mem.value) {
                .var_decl => {
                    const tast_var_decl = self.typeVarDeclForward(scope, &decl.members[i].value.var_decl, mem.span);
                    self.var_decl_datas.append(self.temp_allocator, tast_var_decl) catch unreachable;
                },
                .fn_decl => {
                    const fn_decl_data = self.typeFnDeclForward(scope, &decl.members[i].value.fn_decl, decl.members[i].span);
                    
                    if (fn_decl_data.typ.value.func.params.len > 0 and fn_decl_data.typ.value.func.params[0].typ.isSameOrSameReference(enum_typ)) {
                        methods.append(self.temp_allocator, .{
                            .name = fn_decl_data.tast.name,
                            .typ = fn_decl_data.typ,
                        }) catch unreachable;
                    }
                    
                    self.fn_decl_datas.append(self.temp_allocator, fn_decl_data) catch unreachable;
                },
                
                else => {
                    self.reporter.reportErrorAtSpan(mem.span, "Invalid struct member", .{});
                }
            }
        }
        
        enum_typ.value.@"enum".methods = self.collectAndFreeTempList(types.TypeMethod, &methods);    
        scope.parent.?.setChildScope(enum_typ.value.@"enum".name.text, scope);
        
        self.cur_container_type = cur_container_type;
        self.symbol_manager.popNamespace();
    }
    
    fn typeVarDeclForward(self: *Typer, scope: *Scope, var_decl: *const ast.VarDecl, span: TokenSpan) VarDeclData {
        const name = self.getTokenText(var_decl.name);
        var typ = types.UNKNOWN;
        const value: ?*tast.Expr = null;
        
        if (scope.hasSelf(name)) {
            self.reporter.reportErrorAtToken(var_decl.name, "Identifier `{s}` is already defined", .{name});
        }
        
        if (var_decl.typ) |decl_typ| {
            typ = self.typeType(scope, &decl_typ);
        }
        
        const comptime_known = false;
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
        
        const tast_var_decl: tast.VarDecl = .{
            .kind = kind,
            .name = name_symbol,
            .typ = typ,
            .value = value,
        };
        
        return .{
            .typ = typ,
            .tast = tast_var_decl,
            .ast = var_decl,
            .span = span,
            .scope = scope,
            .symbol_id = name_symbol.id,
        };
    }
    
    fn typeVarDeclValue(self: *Typer, scope: *Scope, ast_decl: *const ast.VarDecl, tast_decl: *tast.VarDecl) void {
        if (ast_decl.value) |ast_value| {
            var value = self.makeExprPointer(self.typeExpr(scope, ast_value, tast_decl.typ));
            tast_decl.value = value;
            
            if (tast_decl.typ.kind == .unknown) {
                tast_decl.typ = value.typ;
            }
            else {
                if (value.typ.canBeAssignedTo(tast_decl.typ)) {
                    tast_decl.typ = value.typ.assignTo(tast_decl.typ);
                    value.typ = tast_decl.typ;
                }
                else {
                    const from = value.typ.getTextLeak(self.arena);
                    const to = tast_decl.typ.getTextLeak(self.arena);
                    
                    self.reporter.reportErrorAtSpan(ast_value.span, "Type `{s}` cannot be assigned to `{s}`", .{from, to});
                }
            }
            
            const sym = scope.getPtr(tast_decl.name.text);
            std.debug.assert(sym != null);
            
            sym.?.typ = tast_decl.typ;
            sym.?.comptime_known = ast_decl.decl.kind == .KeywordConst and value.comptime_known;
        }
    }
    
    fn resolveVarDecl(
        self: *Typer,
        var_decl_data: *VarDeclData,
        symbol_map: *const std.AutoHashMap(usize, usize),
        var_decls: *std.ArrayList(tast.VarDecl),
    ) void {
        if (var_decl_data.state == .resolved) return;
        
        if (var_decl_data.state == .resolving) {
            self.reporter.reportErrorAtSpan(var_decl_data.span, "Cyclic reference detected", .{});
        }
        
        var_decl_data.state = .resolving;
        
        var deps = std.ArrayList(usize).empty;
        defer deps.deinit(self.temp_allocator);
        
        if (var_decl_data.ast.value) |value| {
            self.collectSymbols(var_decl_data.scope, value, &deps, null);
        }
        
        if (deps.items.len > 0) {
            for (deps.items) |dep| {
                if (symbol_map.get(dep)) |index| {
                    self.resolveVarDecl(&self.var_decl_datas.items[index], symbol_map, var_decls);
                }
            }
        }
        
        var_decl_data.state = .resolved;
        self.typeVarDeclValue(var_decl_data.scope, var_decl_data.ast, &var_decl_data.tast);
        var_decls.append(self.temp_allocator, var_decl_data.tast) catch unreachable;
    }
    
    fn collectSymbols(self: *Typer, scope: *Scope, expr: *const ast.Expr, out: *std.ArrayList(usize), out_type: ?**const Type) void {
        switch (expr.value) {
            ast.Kind.literal => {},
            ast.Kind.identifier => |ident| {
                const name = self.getTokenText(ident.name);
                const symbol = scope.get(name);
                
                if (symbol) |sym| {
                    if (sym.typ.kind == .unknown) {
                        out.append(self.temp_allocator, sym.symbol.id) catch unreachable;
                    }
                    
                    if (out_type) |typ| {
                        typ.* = sym.typ;
                    }
                }
            },
            ast.Kind.binary => |bin| {
                self.collectSymbols(scope, bin.lhs, out, null);
                self.collectSymbols(scope, bin.rhs, out, null);
            },
            ast.Kind.array_value => |arr| {
                for (arr.elems) |elem| {
                    self.collectSymbols(scope, &elem, out, null);
                }
            },
            ast.Kind.struct_value => {
                for (expr.value.struct_value.elems) |elem| {
                    self.collectSymbols(scope, &elem.value, out, null);
                }
            },
            ast.Kind.member_access => {
                var typ: *const Type = undefined;
                self.collectSymbols(scope, expr.value.member_access.callee, out, &typ);
                
                if (typ.value == .typ) {
                    if (typ.value.typ.child.value == .@"struct") {
                        const struct_typ = typ.value.typ.child.value.@"struct";
                        const member_text = self.getTokenText(expr.value.member_access.member);
                        const symbol = scope.getChildScopeSymbol(struct_typ.name.text, member_text);
                        
                        if (symbol) |sym| {
                            if (sym.typ.kind == .unknown) {
                                out.append(self.temp_allocator, sym.symbol.id) catch unreachable;
                            }
                        }
                    }
                    else if (typ.value.typ.child.value == .@"enum") {
                        const enum_typ = typ.value.typ.child.value.@"enum";
                        const member_text = self.getTokenText(expr.value.member_access.member);
                        const symbol = scope.getChildScopeSymbol(enum_typ.name.text, member_text);
                        
                        if (symbol) |sym| {
                            if (sym.typ.kind == .unknown) {
                                out.append(self.temp_allocator, sym.symbol.id) catch unreachable;
                            }
                        }
                    }
                }
            },
            else => {
                std.debug.panic("TODO: collectSymbols {s}", .{@tagName(expr.value)});
            },
        }
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
        
        var is_lvalue = false;
        
        // Check if lhs is a lvalue
        switch (lhs.value) {
            .identifier,
            .array_index,
            .struct_member => {
                is_lvalue = true;
            },
            .builtin => {
                switch (lhs.value.builtin) {
                    .array_len,
                    .array_ptr,
                    .dynarray_cap => {
                        is_lvalue = true;
                    },
                    else => {}
                }
            },
            
            else => {}
        }
        
        if (!is_lvalue) {
            self.reporter.reportErrorAtSpan(ass.lhs.span, "Cannot assign to rvalue", .{});
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
        const params = callee.typ.value.func.params;
        const return_type = callee.typ.value.func.returns;
        const skip_param: usize = if (callee.value == .struct_method or callee.value == .enum_method) 1 else 0;
        var default_param_count: usize = 0;
        
        for (params) |param| {
            if (param.default_value) |_| {
                default_param_count += 1;
            }
        }
        
        if (is_variadic) {
            // TODO: Variadic function with default value?
            if (call.args.len < params.len - skip_param - default_param_count - 1) {
                self.reporter.reportErrorAtSpan(
                    span,
                    "Expected {} or more arguments but got {}",
                    .{ params.len - skip_param - 1, call.args.len },
                );
            }
        }
        else {
            if (default_param_count == 0) {
                if (call.args.len != params.len - skip_param) {
                    self.reporter.reportErrorAtSpan(
                        span,
                        "Expected {} arguments but got {}",
                        .{ params.len - skip_param, call.args.len },
                    );
                }
            }
            else {
                if (call.args.len < params.len - skip_param - default_param_count) {
                    self.reporter.reportErrorAtSpan(
                        span,
                        "Expected {} or more arguments but got {}",
                        .{ params.len - skip_param - default_param_count, call.args.len },
                    );
                }
                else if (call.args.len > params.len - skip_param) {
                    self.reporter.reportErrorAtSpan(
                        span,
                        "Expected {} or more arguments and no more than {} arguments but got {}",
                        .{ params.len - skip_param - default_param_count, params.len - skip_param, call.args.len },
                    );
                }
            }
        }
        
        const param_len = if (call.args.len > params.len) call.args.len else params.len - skip_param;
        var typed_args = std.ArrayList(tast.Expr).initCapacity(self.arena, param_len) catch unreachable;
        
        // Generic function
        if (callee.typ.value.func.type_params.len > 0) {
            const type_params = callee.typ.value.func.type_params;
            
            // Reset type_params for current function call
            for (type_params) |type_param| {
                type_param.value.type_param.resolved_typ = null;
            }
            
            for (call.args, 0..) |arg, i| {
                const index = if (i < params.len - skip_param) i + skip_param
                else if (is_variadic) params.len - skip_param - 1 else unreachable;
                
                const exp_typ = params[index].typ.collapseTypeParam(self.type_manager);
                
                const expr = self.typeExpr(scope, &arg, exp_typ);
                typed_args.appendAssumeCapacity(expr);
                
                if (!expr.typ.canBeAssignedToOrResolveGeneric(params[index].typ, self.type_manager)) {
                    self.reporter.reportErrorAtSpan(
                        arg.span,
                        "Expected type `{s}` but got `{s}`",
                        .{
                            params[index].typ.getTextLeak(self.arena),
                            expr.typ.getTextLeak(self.arena),
                        },
                    );
                }
            }
            
            var symbol: *Symbol = undefined;
            
            switch (callee.value) {
                .identifier => { symbol = &callee.value.identifier.name; },
                else => {
                    std.debug.panic("TODO: typeFnCall generic switch callee {s}", .{@tagName(callee.value)});
                }
            }
            
            var h = callee.typ.hash;
            
            for (callee.typ.value.func.type_params) |type_param| {
                std.debug.assert(type_param.value.type_param.resolved_typ != null);
                h = types.combineHash(h, type_param.value.type_param.resolved_typ.?.hash);
            }
            
            if (self.generic_fn_monomorphized.get(h)) |sym| {
                symbol.* = sym;
            }
            else {
                // If function is not monomorphized yet
                // - Clone the type params
                // - Set type param in scope with actual type
                // - Replace function decl param & return type with actual type
                // - Evaluate the function body
                // - Restore scope with original type params
                
                const type_param_copies = self.temp_allocator.dupe(*Type, type_params) catch unreachable;
                defer self.temp_allocator.free(type_param_copies);
                
                if (self.generic_fn_decls.get(callee.typ.type_id)) |fn_decl_data| {
                    for (type_param_copies) |type_param| {
                        fn_decl_data.scope.setType(type_param.value.type_param.name.text, type_param.value.type_param.resolved_typ.?);
                    }
                    
                    if (fn_decl_data.ast.body) |_| {
                        var monomorphized_tast = fn_decl_data.tast;
                        monomorphized_tast.name = self.symbol_manager.cloneSymbol(&monomorphized_tast.name);
                        monomorphized_tast.params = self.arena.dupe(tast.FnParam, monomorphized_tast.params) catch unreachable;
                        
                        for (monomorphized_tast.params) |*param| {
                            param.typ = param.typ.collapseTypeParam(self.type_manager);
                        }
                        
                        monomorphized_tast.return_typ = monomorphized_tast.return_typ.collapseTypeParam(self.type_manager);
                        
                        self.typeFnDeclBody(fn_decl_data.scope.inherit(), fn_decl_data.ast, &monomorphized_tast);
                        
                        self.fn_decls.append(self.temp_allocator, monomorphized_tast) catch unreachable;
                        self.generic_fn_monomorphized.put(h, monomorphized_tast.name) catch unreachable;
                        symbol.* = monomorphized_tast.name;
                    }
                    else {
                        self.reporter.reportErrorAtSpan(fn_decl_data.span, "Generic function should have a body", .{});
                    }
                
                    for (type_params) |type_param| {
                        fn_decl_data.scope.setType(type_param.value.type_param.name.text, type_param);
                    }
                }
                else {
                    std.debug.panic("No generic function with type_id : {}", .{callee.typ.type_id});
                }
            }
        }
        else {
            for (call.args, 0..) |arg, i| {
                const index = if (i < params.len - skip_param) i + skip_param
                else if (is_variadic) params.len - skip_param - 1 else unreachable;
                
                const expr = self.typeExpr(scope, &arg, params[index].typ);
                typed_args.appendAssumeCapacity(expr);
                
                if (!expr.typ.canBeAssignedTo(params[index].typ)) {
                    self.reporter.reportErrorAtSpan(
                        arg.span,
                        "Expected type `{s}` but got `{s}`",
                        .{
                            params[index].typ.getTextLeak(self.arena),
                            expr.typ.getTextLeak(self.arena),
                        },
                    );
                }
            }
            
            for (call.args.len..param_len) |i| {
                if (params[i + skip_param].default_value) |def_val| {
                    typed_args.appendAssumeCapacity(@as(*tast.Expr, @alignCast(@ptrCast(def_val))).*);
                }
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
    
    fn typeSwitch(self: *Typer, scope: *Scope, switc: *const ast.Switch) tast.Stmt {
        const expr = self.makeExprPointer(self.typeExpr(scope, switc.expr, types.UNKNOWN));
        var satisfied_enum_items: ?[]bool = null;
        
        switch (expr.typ.kind) {
            .@"enum" => {
                satisfied_enum_items = self.temp_allocator.alloc(bool, expr.typ.value.@"enum".items.len) catch unreachable;
                
                for (0..expr.typ.value.@"enum".items.len) |i| {
                    satisfied_enum_items.?[i] = false;
                }
            },
            .numeric => {},
            else => {
                self.reporter.reportErrorAtSpan(switc.expr.span, "Switch expression must be an enum or int, but got {s}", .{
                    expr.typ.getTextLeak(self.arena),
                });
            },
        }
        
        var cases = std.ArrayList(tast.SwitchCase).initCapacity(self.arena, switc.cases.len) catch unreachable;
        var has_else = false;
        
        for (switc.cases) |case| {
            if (case.conditions.len > 0) {
                var conditions = std.ArrayList(tast.Expr).initCapacity(self.arena, case.conditions.len) catch unreachable;
                
                for (case.conditions) |cond| {
                    const tast_cond = self.typeExpr(scope, &cond, expr.typ);
                    
                    if (!tast_cond.comptime_known) {
                        self.reporter.reportErrorAtSpan(cond.span, "Switch value must be known at compile time", .{});
                    }
                    
                    if (expr.typ.kind == .@"enum") {
                        if (!tast_cond.typ.isSame(expr.typ)) {
                            self.reporter.reportErrorAtSpan(cond.span, "Expected enum type `{s}`, but got `{s}`", .{
                                expr.typ.getTextLeak(self.arena),
                                tast_cond.typ.getTextLeak(self.arena),
                            });
                        }
                        
                        std.debug.assert(tast_cond.value == .enum_value);
                        
                        if (!satisfied_enum_items.?[tast_cond.value.enum_value.item_index]) {
                            satisfied_enum_items.?[tast_cond.value.enum_value.item_index] = true;
                        }
                        else {
                            self.reporter.reportErrorAtSpan(cond.span, "Duplicate enum value `{s}` in switch", .{
                                expr.typ.value.@"enum".items[tast_cond.value.enum_value.item_index].text,
                            });
                        }
                    }
                    // Numeric
                    else {
                        if (tast_cond.typ.kind == .range) {}
                        else if (!tast_cond.typ.canBeAssignedTo(expr.typ)) {
                            self.reporter.reportErrorAtSpan(cond.span, "Expected type `{s}`, but got `{s}`", .{
                                expr.typ.getTextLeak(self.arena),
                                tast_cond.typ.getTextLeak(self.arena),
                            });
                        }
                    }
                        
                    conditions.appendAssumeCapacity(tast_cond);
                }
                
                const body = self.makeStmtPointer(self.typeStmt(scope, case.body, false));
                
                cases.appendAssumeCapacity(.{
                    .conditions = conditions.items,
                    .body = body,
                    .fallthrough = case.fallthrough,
                });
            }
            else {
                has_else = true;
                
                const body = self.makeStmtPointer(self.typeStmt(scope, case.body, false));
                
                cases.appendAssumeCapacity(.{
                    .conditions = &.{},
                    .body = body,
                    .fallthrough = case.fallthrough,
                });
            }
        }
        
        if (!switc.partial and !has_else) {
            if (satisfied_enum_items) |sat| {
                for (sat, 0..) |b, i| {
                    if (!b) {
                        self.reporter.reportErrorAtSpan(switc.expr.span, "Unhandled enum value `{s}` in switch", .{
                            expr.typ.value.@"enum".items[i].text,
                        });
                    }
                }
            }
            else {
                self.reporter.reportErrorAtSpan(switc.expr.span, "Switch value must handle all cases. Add `else` case or `@partial` to make it non-exhaustive", .{});
            }
        }
        
        if (satisfied_enum_items) |sat| {
            self.temp_allocator.free(sat);
        }
        
        return .{.switc = .{
            .expr = expr,
            .cases = cases.items,
        }};
    }
    
    fn typeWhile(self: *Typer, scope: *Scope, whil: *const ast.While) tast.Stmt {
        const cond = self.makeExprPointer(self.typeExpr(scope, whil.condition, types.UNKNOWN));
        
        if (!cond.typ.canBeUsedAsCond()) {
            self.reporter.reportErrorAtSpan(whil.condition.span, "Type `{s}` cannot be used as condition", .{cond.typ.getTextLeak(self.arena)});
        }
        
        var body: tast.Stmt = .noop;
        var tast_whil: tast.Stmt = .{
            .whil = .{
                .condition = cond,
                .body = &body,
            },
        };
        
        const cur_breakable = self.cur_breakable;
        self.cur_breakable = &tast_whil;
        
        tast_whil.whil.body = self.makeStmtPointer(self.typeStmt(scope, whil.body, false));
        
        self.cur_breakable = cur_breakable;
        
        return tast_whil;
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
                
                if (forr.is_reference and iter.mutability == .constant) {
                    self.reporter.reportErrorAtSpan(forr.iter.span, "Cannot iterate constant variable by reference", .{});
                }
                
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
                    .kind = .array,
                    .item_var = item_var,
                    .index_var = index_var,
                    .item_typ = item_typ,
                    .is_reference = forr.is_reference,
                    .iter = self.makeExprPointer(iter),
                    .body = body,
                }};
            },
            .string => {
                const new_scope = scope.inherit();
                // defer new_scope.deinit();
                
                if (forr.is_reference and iter.mutability == .constant) {
                    self.reporter.reportErrorAtSpan(forr.iter.span, "Cannot iterate constant variable by reference", .{});
                }
                
                const item_typ = if (forr.is_reference) self.type_manager.createReference(types.U8)
                else types.U8;
                
                if (item_var) |v| {
                    scope.set(v.text, v, item_typ, false, .constant);
                }
                
                if (index_var) |v| {
                    scope.set(v.text, v, types.I32, false, .constant);
                }
                
                const body = self.makeStmtPointer(self.typeStmt(new_scope, forr.body, true));
                
                return .{.for_each = .{
                    .kind = .string,
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
            {
                var iter = mod.public_symbols.iterator();
                
                while (iter.next()) |entry| {
                    scope.setTypedSymbol(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
            
            {
                var iter = mod.public_child_scopes.iterator();
                
                while (iter.next()) |entry| {
                    scope.setChildScope(entry.key_ptr.*, entry.value_ptr.*);
                }
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
            ast.Kind.intrinsic     => return self.typeIntrinsic(scope, &expr.value.intrinsic),
            ast.Kind.generic       => return self.typeGeneric(scope, &expr.value.generic, expr.span),
            
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
                    .typ = types.U8,
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
        else if (lhs.typ.kind == .array) {            
            if (bin.op.kind == .MulMul) {
                if (!lhs.comptime_known) {
                    self.reporter.reportErrorAtSpan(bin.lhs.span, "Repeat (**) array operand must be compile time known", .{});
                }
                else if (lhs.value != .array_value) {
                    self.reporter.reportErrorAtSpan(bin.lhs.span, "Repeat (**) array operand must be array literal (right now)", .{});
                }
                else if (rhs.value == .literal and rhs.value.literal == .int) {
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
                        .comptime_known = true,
                        .mutability = .constant,
                        .value = .{ .array_value = .{ .elems = new_elems.items } },
                    };
                }
                else {
                    self.reporter.reportErrorAtSpan(bin.rhs.span, "Repeat (**) operand must be an int literal", .{});
                }
            }
            else if (bin.op.kind == .PlusPlus) {
                if (rhs.typ.kind == .array and rhs.typ.isSame(lhs.typ)) {
                    if (!lhs.comptime_known) {
                        self.reporter.reportErrorAtSpan(bin.lhs.span, "Concat (++) array operand must be compile time known", .{});
                    }
                    else if (!rhs.comptime_known) {
                        self.reporter.reportErrorAtSpan(bin.rhs.span, "Concat (++) array operand must be compile time known", .{});
                    }
                    
                    if (lhs.value != .array_value) {
                        self.reporter.reportErrorAtSpan(bin.lhs.span, "Concat (++) array operand must be array literal (right now)", .{});
                    }
                    
                    if (rhs.value != .array_value) {
                        self.reporter.reportErrorAtSpan(bin.rhs.span, "Concat (++) array operand must be array literal (right now)", .{});
                    }
                    
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
                        .comptime_known = true,
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
        else if (lhs.typ.kind == .pointer and rhs.typ.kind == .numeric and rhs.typ.value.numeric.isInt()) {
            switch (bin.op.kind) {
                .Plus,
                .Minus => {
                    valid = true;
                    typ = lhs.typ;
                },
                else => {},
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
            .comptime_known = true,
            .mutability = .constant,
            .value = .{ .array_value = .{ .elems = elems.items } },
        };
    }
    
    fn typeArrayIndex(self: *Typer, scope: *Scope, arr: *const ast.ArrayIndex) tast.Expr {
        const callee = self.makeExprPointer(self.typeExpr(scope, arr.callee, types.UNKNOWN));
        const index = self.makeExprPointer(self.typeExpr(scope, arr.index, types.UNKNOWN));
        var is_reference = false;
        var is_raw_pointer = false;
        var child_typ: *const Type = undefined;
        
        if (callee.typ.kind == .array) {
            child_typ = callee.typ.value.array.child;
        }
        else if (callee.typ.kind == .reference and callee.typ.value.reference.child.kind == .array) {
            is_reference = true;
            child_typ = callee.typ.value.reference.child.value.array.child;
        }
        else if (callee.typ.kind == .pointer) {
            is_raw_pointer = true;
            child_typ = callee.typ.value.pointer.child;
        }
        else if (callee.typ.kind == .voidptr) {
            is_raw_pointer = true;
            child_typ = types.U8;
        }
        else {
            self.reporter.reportErrorAtSpan(arr.callee.span, "Not an array", .{});
        }
        
        if (!index.typ.isNumericInt()) {
            self.reporter.reportErrorAtSpan(
                arr.index.span,
                "Type `{s}` cannot be used as array index",
                .{index.typ.getTextLeak(self.arena)},
            );
        }
        
        const mutability: Mutability =
            if (is_reference) .mutable
            else if (callee.mutability == .constant) .constant
            else .mutable;
        
        return .{
            .typ = child_typ,
            .mutability = mutability,
            .value = .{.array_index = .{
                .callee = callee,
                .index = index,
                .is_reference = is_reference,
                .is_raw_pointer = is_raw_pointer,
            }},
        };
    }
    
    fn typeRange(self: *Typer, scope: *Scope, range: *const ast.Range) tast.Expr {
        const lhs = self.makeExprPointer(self.typeExpr(scope, range.lhs, types.UNKNOWN));
        const rhs = self.makeExprPointer(self.typeExpr(scope, range.rhs, types.UNKNOWN));
        
        if (!lhs.typ.canBeAssignedTo(types.I32) and !lhs.typ.canBeAssignedTo(types.USize)) {
            self.reporter.reportErrorAtSpan(
                range.lhs.span,
                "Type `{s}` cannot be used as for range item. Must be an int",
                .{lhs.typ.getTextLeak(self.arena)},
            );
        }
        
        if (!rhs.typ.canBeAssignedTo(types.I32) and !lhs.typ.canBeAssignedTo(types.USize)) {
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
            .comptime_known = lhs.comptime_known and rhs.comptime_known,
        };
    }
    
    fn typeMemberAccess(self: *Typer, scope: *Scope, mem: *const ast.MemberAccess) tast.Expr {
        const callee = self.makeExprPointer(self.typeExpr(scope, mem.callee, types.UNKNOWN));
        
        switch (callee.typ.kind) {
            .array => {
                return self.typeArrayBuiltin(scope, callee, mem.member, false);
            },
            .@"struct" => {
                return self.typeStructMember(scope, callee, mem.member, false);
            },
            .@"enum" => {
                return self.typeEnumMember(scope, callee, mem.member, false);
            },
            .reference => {
                if (callee.typ.value.reference.child.kind == .array) {
                    return self.typeArrayBuiltin(scope, callee, mem.member, true);
                }
                else if (callee.typ.value.reference.child.kind == .@"struct") {
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
                        
                    if (method.typ.value.func.params[0].typ.value == .reference) {
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
                        if (method.typ.value.func.params[0].typ.value == .@"struct") {
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
        const member_text = self.getTokenText(member);
        const symbol = scope.getChildScopeSymbol(struct_typ.name.text, member_text);
        
        if (symbol) |sym| {
            return .{
                .typ = sym.typ,
                .mutability = sym.mutability,
                .comptime_known = sym.comptime_known,
                .value = .{.identifier = .{ .name = sym.symbol }},
            };
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
                    .comptime_known = true,
                };
            }
        }
        
        const symbol = scope.getChildScopeSymbol(enum_typ.value.@"enum".name.text, member_text);
        
        if (symbol) |sym| {
            return .{
                .typ = sym.typ,
                .comptime_known = sym.comptime_known,
                .mutability = sym.mutability,
                .value = .{.identifier = .{ .name = sym.symbol }},
            };
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
                
                if (method.typ.value.func.params[0].typ.value == .reference) {
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
                    if (method.typ.value.func.params[0].typ.value == .@"struct") {
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
    
    fn typeArrayBuiltin(self: *Typer, scope: *Scope, ar: *tast.Expr, member: Token, is_reference: bool) tast.Expr {
        _ = scope;
        
        const member_text = self.getTokenText(member);
        const ar_typ = 
        if (ar.typ.kind == .reference) ar.typ.value.reference.child.value.array
        else if (ar.typ.kind == .array) ar.typ.value.array
        else unreachable;
        
        if (std.mem.eql(u8, member_text, "len")) {
            return .{
                .typ = types.UNTYPED_INT,
                .mutability = .mutable,
                .value = .{.builtin = .{ .array_len = .{ .arr = ar, .is_reference = is_reference } }}
            };
        }
        else if (std.mem.eql(u8, member_text, "ptr")) {
            const typ = self.type_manager.createPointer(ar_typ.child);
            
            return .{
                .typ = typ,
                .mutability = .mutable,
                .value = .{.builtin = .{ .array_ptr = .{ .arr = ar, .is_reference = is_reference } }}
            };
        }
        else if (std.mem.eql(u8, member_text, "cap")) {
            return .{
                .typ = types.UNTYPED_INT,
                .mutability = .mutable,
                .value = .{.builtin = .{ .dynarray_cap = .{ .arr = ar, .is_reference = is_reference } }}
            };
        }
        else if (ar_typ.is_dyn) {
            if (std.mem.eql(u8, member_text, "append")) {
                const params = self.arena.alloc(types.TypeFuncParam, 1) catch unreachable;
                params[0] = .{ .typ = ar_typ.child, .default_value = null };
                
                return .{
                    .typ = self.type_manager.createFn(null, params, &.{}, types.VOID, false, true, false),
                    .mutability = .constant,
                    .value = .{ .builtin = .{ .dynarray_append = .{ .arr = ar, .is_reference = is_reference } } }
                };
            }
            else if (std.mem.eql(u8, member_text, "toArray")) {
                const typ = self.type_manager.createArray(ar_typ.child, false, null);
                
                return .{
                    .typ = self.type_manager.createFn(null, &.{}, &.{}, typ, false, true, false),
                    .mutability = .constant,
                    .value = .{ .builtin = .{ .dynarray_to_array = .{ .arr = ar, .is_reference = is_reference, .dest_typ = typ } } }
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
        
        var struct_typ: types.TypeStruct = undefined;
        
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
        else if (typ.value == .@"struct") {
            struct_typ = typ.value.@"struct";
        }
        else if (typ.value == .generic and typ.value.generic.base.value == .@"struct") {
            struct_typ = typ.value.generic.base.value.@"struct";
        }
        else {
            self.reporter.reportErrorAtSpan(span, "Expected type `{s}` but got a struct", .{typ.getTextLeak(self.arena)});
        }
        
        const FieldState = enum {
            unresolved,
            resolved,
            has_default,
        };
        
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
    
    fn typeIntrinsic(self: *Typer, scope: *Scope, intr: *const ast.Intrinsic) tast.Expr {
        const name = self.getTokenText(intr.name);
        
        if (std.mem.eql(u8, name, "typeOf")) {
            if (intr.args.len == 1) {
                const expr = self.typeExpr(scope, &intr.args[0], types.UNKNOWN);
                const typ_str = expr.typ.getTextLeak(self.arena);
                
                return .{
                    .typ = types.STRING,
                    .comptime_known = true,
                    .mutability = .constant,
                    .value = .{ .literal = .{ .string = typ_str } }
                };
            }
            else {
                self.reporter.reportErrorAtToken(intr.name, "@typeOf needs exactly 1 argument", .{});
            }            
        }
        else if (std.mem.eql(u8, name, "sizeOf")) {
            if (intr.args.len == 1) {
                const size = switch (intr.args[0].value) {
                    .identifier => blk: {
                        const text = self.getTokenText(intr.args[0].value.identifier.name);
                        
                        if (getTypeByText(text)) |t| { break :blk t.size; }
                        else {
                            break :blk self.typeExpr(scope, &intr.args[0], types.UNKNOWN).typ.size; 
                        }
                    },
                    else => self.typeExpr(scope, &intr.args[0], types.UNKNOWN).typ.size,
                };                
                
                return .{
                    .typ = types.UNTYPED_INT,
                    .comptime_known = true,
                    .mutability = .constant,
                    .value = .{ .literal = .{ .int = size } }
                };
            }
            else {
                self.reporter.reportErrorAtToken(intr.name, "@typeOf needs exactly 1 argument", .{});
            }            
        }
        else {
            self.reporter.reportErrorAtToken(intr.name, "Unknown intrinsic `{s}`", .{name});
        }
    }
    
    fn typeGeneric(self: *Typer, scope: *Scope, gen: *const ast.Generic, span: TokenSpan) tast.Expr {
        const callee = self.typeExpr(scope, gen.callee, types.UNKNOWN);
        
        var children = std.ArrayList(*const Type).initCapacity(self.arena, gen.children.len) catch unreachable;
                
        for (gen.children) |child| {
            children.appendAssumeCapacity(self.typeType(scope, &child));
        }
        
        switch (callee.typ.kind) {
            .typ => {
                if (callee.typ.value.typ.child.kind == .@"struct") {
                    if (gen.children.len != callee.typ.value.typ.child.value.@"struct".type_params.len) {
                        self.reporter.reportErrorAtSpan(
                            span,
                            "Expected {} generic parameter, but got {}",
                            .{
                                callee.typ.value.typ.child.value.@"struct".type_params.len,
                                gen.children.len,
                            }
                        );
                    }
                    
                    const generic_typ = self.type_manager.createGenericStruct(callee.typ.value.typ.child, children.items);
                    const container_typ = self.type_manager.createType(generic_typ);
                    
                    if (callee.typ.value.typ.child.value.@"struct".state == .done) {
                        generic_typ.fillGenericStruct(self.type_manager);
                    }
                    else {
                        self.generic_structs.put(generic_typ.type_id, generic_typ) catch unreachable;
                    }
                    
                    return .{
                        .value = .{ .typ = generic_typ },
                        .typ = container_typ,
                        .mutability = .constant,
                    };
                }
                else {
                    self.reporter.reportErrorAtSpan(span, "type `{s}` is not generic", .{callee.typ.getTextLeak(self.arena)});
                }
            },
            .type_param => {
                std.debug.panic("TODO: typeType nested generic", .{});
            },
            else => {
                self.reporter.reportErrorAtSpan(span, "`{s}` is not a type", .{callee.typ.getTextLeak(self.arena)});
            },
        }
    }
    
    fn typeType(self: *Typer, scope: *Scope, typ: *const ast.Type) *const Type {
        switch (typ.value) {
            ast.TypeKind.simple => {
                const typ_text = self.getTokenText(typ.value.simple.name);
                
                if (getTypeByText(typ_text)) |t| {
                    return t;
                }                
                else {
                    if (scope.get(typ_text)) |sym| {
                        switch (sym.typ.kind) {
                            .typ => {
                                if (sym.typ.value.typ.child.kind == .@"struct") {
                                    if (sym.typ.value.typ.child.value.@"struct".type_params.len > 0) {
                                        self.reporter.reportErrorAtToken(
                                            typ.value.simple.name,
                                            "Expected {} generic parameter, but none given",
                                            .{
                                                sym.typ.value.typ.child.value.@"struct".type_params.len,
                                            }
                                        );
                                    }
                                }
                                
                                return sym.typ.value.typ.child;
                            },
                            .type_param => {
                                return sym.typ;
                            },
                            else => {},
                        }
                        
                        self.reporter.reportErrorAtToken(typ.value.simple.name, "`{s}` is not a type", .{typ_text});
                    }
                    else {
                        self.reporter.reportErrorAtToken(typ.value.simple.name, "Unknown type `{s}`", .{typ_text});
                    }
                }
            },
            ast.TypeKind.generic => {
                var children = std.ArrayList(*const Type).initCapacity(self.arena, typ.value.generic.children.len) catch unreachable;
                
                for (typ.value.generic.children) |child| {
                    children.appendAssumeCapacity(self.typeType(scope, &child));
                }
                
                const base_text = self.getTokenText(typ.value.generic.base);
                
                if (scope.get(base_text)) |sym| {
                    switch (sym.typ.kind) {
                        .typ => {
                            if (sym.typ.value.typ.child.kind == .@"struct") {
                                if (typ.value.generic.children.len != sym.typ.value.typ.child.value.@"struct".type_params.len) {
                                    self.reporter.reportErrorAtToken(
                                        typ.value.generic.base,
                                        "Expected {} generic parameter, but got {}",
                                        .{
                                            sym.typ.value.typ.child.value.@"struct".type_params.len,
                                            typ.value.generic.children.len,
                                        }
                                    );
                                }
                                
                                const generic_typ = self.type_manager.createGenericStruct(sym.typ.value.typ.child, children.items);
                                
                                if (sym.typ.value.typ.child.value.@"struct".state == .done) {
                                    generic_typ.fillGenericStruct(self.type_manager);
                                }
                                else {
                                    self.generic_structs.put(generic_typ.type_id, generic_typ) catch unreachable;
                                }
                                
                                return generic_typ;
                            }
                            else {
                                self.reporter.reportErrorAtToken(typ.value.generic.base, "type `{s}` is not generic", .{base_text});
                            }
                        },
                        .type_param => {
                            std.debug.panic("TODO: typeType nested generic", .{});
                        },
                        else => {
                            self.reporter.reportErrorAtToken(typ.value.simple.name, "`{s}` is not a type", .{base_text});
                        },
                    }
                }
                else {
                    self.reporter.reportErrorAtToken(typ.value.simple.name, "Unknown type `{s}`", .{base_text});
                }
            },
            ast.TypeKind.array => {
                return self.type_manager.createArray(
                    self.typeType(scope, typ.value.array.child),
                    typ.value.array.is_dyn,
                    null
                );
            },
            ast.TypeKind.reference => {
                return self.type_manager.createReference(
                    self.typeType(scope, typ.value.reference.child)
                );
            },
            ast.TypeKind.pointer => {
                return self.type_manager.createPointer(
                    self.typeType(scope, typ.value.pointer.child)
                );
            },
            ast.TypeKind.inline_struct => {
                const struct_decl = &typ.value.inline_struct;
                
                const struct_decl_data = self.typeStructDeclForward(scope, struct_decl);
                self.typeStructDeclFields(struct_decl_data.scope, struct_decl_data.ast, struct_decl_data.typ);
                self.typeStructDeclMember(struct_decl_data.scope, struct_decl_data.ast, struct_decl_data.typ);
                
                return struct_decl_data.typ;
            },
            ast.TypeKind.inline_enum => {
                const enum_decl = &typ.value.inline_enum;
                
                const enum_decl_data = self.typeEnumDecl(scope, enum_decl);
                self.typeEnumDeclMember(enum_decl_data.scope, enum_decl_data.ast, enum_decl_data.typ);
                
                return enum_decl_data.typ;
            },
            ast.TypeKind.self => {
                if (self.cur_container_type) |container_typ| {
                    return container_typ;
                }
                else {
                    self.reporter.reportErrorAtSpan(typ.span, "`@Self` type can only be used inside containers (struct or enum)", .{});
                }
            },
            
            else => {
                std.debug.panic("TODO: typeType {s}", .{@tagName(typ.value)});
            }
        }
    }
    
    fn getTypeByText(typ_text: []const u8) ?*const Type {
        if (std.mem.eql(u8, typ_text, "u8"))         { return types.U8; }
        else if (std.mem.eql(u8, typ_text, "u16"))   { return types.U16; }
        else if (std.mem.eql(u8, typ_text, "u32"))   { return types.U32; }
        else if (std.mem.eql(u8, typ_text, "u64"))   { return types.U64; }
        else if (std.mem.eql(u8, typ_text, "usize")) { return types.USize; }
        else if (std.mem.eql(u8, typ_text, "i8"))    { return types.I8; }
        else if (std.mem.eql(u8, typ_text, "i16"))   { return types.I16; }
        else if (std.mem.eql(u8, typ_text, "i32"))   { return types.I32; }
        else if (std.mem.eql(u8, typ_text, "i64"))   { return types.I64; }
        else if (std.mem.eql(u8, typ_text, "f32"))   { return types.F32; }
        else if (std.mem.eql(u8, typ_text, "f64"))   { return types.F64; }
        
        else if (std.mem.eql(u8, typ_text, "bool"))   { return types.BOOL; }
        else if (std.mem.eql(u8, typ_text, "string")) { return types.STRING; }
        else if (std.mem.eql(u8, typ_text, "range"))  { return types.RANGE; }
        
        else if (std.mem.eql(u8, typ_text, "void"))    { return types.VOID; }
        else if (std.mem.eql(u8, typ_text, "any"))     { return types.ANY; }
        else if (std.mem.eql(u8, typ_text, "voidptr")) { return types.VOID_PTR; }
        else return null;
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
        list.deinit(self.temp_allocator);
        
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
    defer typer.deinit();
    var scope = Scope.init(arena, .module);
    // defer scope.deinit();
    
    return typer.typeModule(&scope, module, module_id, module_name);
}