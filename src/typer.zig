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
const SymbolManager = @import("symbol.zig").SymbolManager;
const FileManager = @import("file_manager.zig");

const Scope = struct {
    parent: ?*Scope,
    syms: std.StringHashMap(TypedSymbol),
    allocator: std.mem.Allocator,
    is_top_level: bool,
    
    fn init(allocator: std.mem.Allocator, is_top_level: bool) Scope {
        return .{
            .parent = null,
            .syms = std.StringHashMap(TypedSymbol).init(allocator),
            .allocator = allocator,
            .is_top_level = is_top_level,
        };
    }
    
    fn deinit(self: *Scope) void {
        self.syms.deinit();
    }
    
    fn inherit(self: *Scope) Scope {
        return .{
            .parent = self,
            .syms = std.StringHashMap(TypedSymbol).init(self.allocator),
            .allocator = self.allocator,
            .is_top_level = false,
        };
    }
    
    fn has(self: *const Scope, key: []const u8) bool {
        return self.syms.contains(key) or (self.parent != null and self.parent.?.has(key));
    }
    
    fn hasSelf(self: *const Scope, key: []const u8) bool {
        return self.syms.contains(key);
    }
    
    fn get(self: *const Scope, key: []const u8) ?TypedSymbol {
        const res = self.syms.get(key);
        if (res) |r| return r;
        
        if (self.parent) |p| {
            return p.get(key);
        }
        
        return null;
    }
    
    fn set(self: *Scope, key: []const u8, symbol: Symbol, typ: *const Type) void {
        const typed_symbol = TypedSymbol{
            .symbol = symbol,
            .typ = typ,
        };
        
        self.syms.put(key, typed_symbol) catch unreachable;
    }
    
    fn setTypedSymbol(self: *Scope, key: []const u8, typed_symbol: TypedSymbol) void {
        self.syms.put(key, typed_symbol) catch unreachable;
    }
};

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

const Typer = struct {
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    reporter: Reporter,
    file_manager: *const FileManager,
    type_manager: *TypeManager,
    symbol_manager: *SymbolManager,
    children: *const std.StringHashMap(*tast.Module),
    
    fn_decls: std.ArrayList(tast.FnDecl) = .empty,
    
    cur_fn: ?*tast.FnDecl = null,
    
    fn init(
        allocator: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        reporter: Reporter,
        file_manager: *const FileManager,
        type_manager: *TypeManager,
        symbol_manager: *SymbolManager,
        children: *const std.StringHashMap(*tast.Module),
    ) Typer {
        return .{
            .allocator = allocator,
            .temp_allocator = temp_allocator,
            .reporter = reporter,
            .file_manager = file_manager,
            .type_manager = type_manager,
            .symbol_manager = symbol_manager,
            .children = children,
        };
    }
    
    fn appendFnDecl(self: *Typer, fn_decl: tast.FnDecl) void {
        self.fn_decls.append(self.allocator, fn_decl) catch unreachable;
    }
    
    fn typeModule(self: *Typer, scope: *Scope, module: *const ast.Module, module_id: usize) tast.Module {
        self.fn_decls.clearAndFree(self.allocator);
        
        const stmts = self.typeStmts(scope, module.exprs);
        var var_decls = std.ArrayList(tast.VarDecl).initCapacity(self.allocator, stmts.len) catch unreachable;
        
        for (stmts) |stmt| {
            switch (stmt) {
                .noop => {},
                .var_decl => |var_decl| { var_decls.appendAssumeCapacity(var_decl); },
                else => {
                    std.debug.panic("UNREACHABLE: {s}", .{@tagName(stmt)});
                    
                    // Already checked at typeStmts
                    unreachable;
                }
            }
        }
        
        var public_symbols = std.StringHashMap(TypedSymbol).init(self.allocator);
        var iter = scope.syms.iterator();
        
        while (iter.next()) |entry| {
            public_symbols.put(entry.key_ptr.*, entry.value_ptr.*) catch unreachable;
        }
        
        var children = std.ArrayList(*tast.Module).initCapacity(self.allocator, self.children.count()) catch unreachable;
        var child_iter = self.children.iterator();
        
        while (child_iter.next()) |entry| {
            children.appendAssumeCapacity(entry.value_ptr.*);
        }
        
        return .{
            .id = module_id,
            .var_decls = var_decls.items,
            .fn_decls = self.fn_decls.items,
            .public_symbols = public_symbols,
            .children = children.items,
        };
    }
    
    fn typeStmts(self: *Typer, scope: *Scope, exprs: []const ast.Expr) []const tast.Stmt {
        var stmts = std.ArrayList(tast.Stmt).empty;
        
        var fn_decls = std.ArrayList(tast.FnDecl).empty;
        defer fn_decls.clearAndFree(self.temp_allocator);
        
        var fn_decl_indices = std.ArrayList(usize).empty;
        defer fn_decl_indices.clearAndFree(self.temp_allocator);
        
        for (exprs, 0..) |expr, i| {
            switch (expr.value) {
                ast.Kind.fn_decl => |fn_decl| {
                    fn_decls.append(self.temp_allocator, self.typeFnDecl(scope, &fn_decl)) catch unreachable;
                    fn_decl_indices.append(self.temp_allocator, i) catch unreachable;
                },
                ast.Kind.struct_decl => |struct_decl| {
                    self.typeStructDecl(scope, &struct_decl);
                },
                else => {}
            }
        }
        
        for (exprs) |expr| {
            switch (expr.value) {
                ast.Kind.fn_decl,
                ast.Kind.struct_decl => {},
                else => {
                    switch (expr.value) {
                        ast.Kind.var_decl => {},
                        ast.Kind.import => {},
                        
                        else => {
                            if (scope.is_top_level) {
                                self.reporter.reportErrorAtSpan(expr.span, "This kind of statement cannot be placed at top level");
                            }
                        },
                    }
                    
                    stmts.append(self.temp_allocator, self.typeStmt(scope, &expr)) catch unreachable;
                }
            }
        }
        
        for (fn_decls.items, fn_decl_indices.items) |*fn_decl, i| {
            if (exprs[i].value.fn_decl.body) |_| {
                if (fn_decl.is_extern) {
                    self.reporter.reportErrorAtSpan(exprs[i].span, "extern function cannot have a body");
                }
                
                self.typeFnDeclBody(scope, &exprs[i].value.fn_decl, fn_decl);
            }
            else {
                if (!fn_decl.is_extern) {
                    self.reporter.reportErrorAtSpan(exprs[i].span, "Non extern function must have a body");
                }
            }
        }
        
        self.fn_decls.appendSlice(self.allocator, fn_decls.items) catch unreachable;
        
        return self.collectAndFreeTempList(tast.Stmt, &stmts);
    }
    
    fn typeStmt(self: *Typer, scope: *Scope, stmt: *const ast.Expr) tast.Stmt {
        switch (stmt.value) {
            .var_decl   => |decl|   { return self.typeVarDecl(scope, &decl, stmt.span); },
            .assignment => |ass|    { return self.typeAssignment(scope, &ass); },
            .fn_call    => |call|   { return self.typeFnCallStmt(scope, &call, stmt.span); },
            .returns    => |ret|    { return self.typeReturn(scope, &ret, stmt.span); },
            .iff        => |iff|    { return self.typeIf(scope, &iff); },
            .whil       => |whil|   { return self.typeWhile(scope, &whil); },
            .forr       => |forr|   { return self.typeFor(scope, &forr); },
            .block      => |block|  { return self.typeBlockStmt(scope, &block); },
            .import     => |import| { return self.typeImport(scope, &import); },
            
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
    
    fn typeFnDecl(self: *Typer, scope: *Scope, fn_decl: *const ast.FnDecl) tast.FnDecl {
        const fn_name = self.getTokenText(fn_decl.name);
        
        if (scope.hasSelf(fn_name)) {
            self.reporter.reportErrorAtTokenArgs(fn_decl.name, "Symbol '{s}' is already defined", .{fn_name});
        }
        
        var params = std.ArrayList(tast.FnParam).initCapacity(self.allocator, fn_decl.params.len) catch unreachable;
        var param_types = std.ArrayList(*const Type).initCapacity(self.allocator, fn_decl.params.len) catch unreachable;
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
                        const expected_str = param_typ.getTextLeak(self.temp_allocator);
                        const actual_str = default_type.getTextLeak(self.temp_allocator);
                        
                        self.reporter.reportErrorAtSpanArgs(def_value.span, "Expected '{s}' but got '{s}'", .{expected_str, actual_str});
                    }
                }
                else if (has_default) {
                    self.reporter.reportErrorAtSpan(
                        TokenSpan.from_token_and_span(param.name, typ.span),
                        "Param with no default value cannot be placed after param with default value",
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
                    self.reporter.reportErrorAtToken(param.name, "Cannot have more that one variadic param");
                }
                
                is_variadic = true;
            }
            else if (is_variadic) {
                self.reporter.reportErrorAtToken(param.name, "Non variadic param cannot be placed after variadic param");
            }
            
            const symbol = self.symbol_manager.createSymbol(self.getTokenText(param.name));
            
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
        
        const fn_name_symbol = self.symbol_manager.createSymbol(fn_name);
        scope.set(
            fn_name, fn_name_symbol,
            self.type_manager.createFn(
                param_types.items,
                return_typ,
                is_variadic,
                false,
            )
        );
        
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
        var new_scope = scope.inherit();
        defer new_scope.deinit();
        
        for (forward_decl.params) |param| {
            new_scope.set(param.name.text, param.name, param.typ);
        }
        
        const parent_fn = self.cur_fn;
        self.cur_fn = forward_decl;
        
        forward_decl.body = self.typeBlock(&new_scope, &fn_decl_ast.body.?);
        
        if (forward_decl.return_typ.kind != types.TypeKind.void) {
            if (!doesAllPathHasReturn(&forward_decl.body.?)) {
                self.reporter.reportErrorAtSpan(fn_decl_ast.return_typ.?.span, "Not all path has return value");
            }
        }
        
        self.cur_fn = parent_fn;
    }
    
    fn typeBlockStmt(self: *Typer, scope: *Scope, block: *const ast.Block) tast.Stmt {
        return .{
            .block = self.typeBlock(scope, block),
        };
    }
    
    fn typeBlockExpr(self: *Typer, scope: *Scope, block: *const ast.Block, span: TokenSpan) tast.Expr {
        if (block.exprs.len == 0) {
            self.reporter.reportErrorAtSpan(span, "Block should have an expression");
        }
        
        // TODO: Handle edge cases like:
        // - Block with struct decl as last stmt
        // - Block with function decl as last stmt
        
        const stmts = self.typeStmts(scope, block.exprs);
        
        if (stmts.len == 0) {
            self.reporter.reportErrorAtSpan(span, "Struct or function declaration cannot be the only statement in a block expression");
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
            
            self.reporter.reportErrorAtSpan(last_stmt_span, "Statement cannot be used as expression");
        }
        
        return .{
            .typ = types.UNKNOWN,
            .value = .{.block = .{
                .stmts = stmts,
                .last_expr = last_expr,
            }},
        };
    }
    
    fn typeBlock(self: *Typer, scope: *Scope, block: *const ast.Block) tast.Block {
        return .{
            .stmts = self.typeStmts(scope, block.exprs),
        };
    }
    
    fn typeStructDecl(self: *Typer, scope: *Scope, decl: *const ast.StructDecl) void {
        const struct_name = self.getTokenText(decl.name);
        const struct_symbol = self.symbol_manager.createSymbol(struct_name);
        
        var fields = std.ArrayList(types.TypeStructField)
            .initCapacity(self.allocator, decl.fields.len) catch unreachable;
        
        for (decl.fields) |field| {
            const field_name_symbol = self.symbol_manager.createSymbol(self.getTokenText(field.name));
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
                        const expected_str = field_typ.getTextLeak(self.temp_allocator);
                        const actual_str = field_default_value.?.typ.getTextLeak(self.temp_allocator);
                        
                        self.reporter.reportErrorAtSpanArgs(def_value.span, "Expected '{s}' but got '{s}'", .{expected_str, actual_str});
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
            });
        }
        
        const struct_type = self.type_manager.createStruct(struct_symbol, fields.items);
        scope.set(struct_name, struct_symbol, struct_type);
        
        var child_scope = scope.inherit();
        defer child_scope.deinit();
        
        self.symbol_manager.pushNamespace(struct_symbol);
        // std.debug.panic("TODO: typeStructDecl members", .{});
        // _ = self.typeStmts(&child_scope, decl.members);
        self.symbol_manager.popNamespace();
    }
    
    fn typeVarDecl(self: *Typer, scope: *Scope, var_decl: *const ast.VarDecl, span: TokenSpan) tast.Stmt {
        const name = self.getTokenText(var_decl.name);
        var typ = types.UNKNOWN;
        var value: ?*tast.Expr = null;
        
        if (scope.hasSelf(name)) {
            self.reporter.reportErrorAtTokenArgs(var_decl.name, "Symbol '{s}' is already defined", .{name});
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
                    const from = value.?.typ.getTextLeak(self.temp_allocator);
                    const to = typ.getTextLeak(self.temp_allocator);
                    
                    self.reporter.reportErrorAtSpanArgs(decl_value.span, "Type '{s}' cannot be assigned to '{s}'", .{from, to});
                }
            }
        }
        else {
            switch (var_decl.decl.kind) {
                TokenKind.KeywordVar => {},
                TokenKind.KeywordVal,
                TokenKind.KeywordConst => {
                    self.reporter.reportErrorAtSpan(span, "Declaration with val or const should have a value");
                },
                else => unreachable,
            }
        }
        
        typ = typ.coerceIntoRuntime(self.type_manager);
        
        const name_symbol = self.symbol_manager.createSymbol(name);
        scope.set(name, name_symbol, typ);
        
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
                self.reporter.reportErrorAtSpan(ass.lhs.span, "Cannot assign to rvalue");
            }
        }
        
        if (!rhs.typ.canBeAssignedTo(lhs.typ)) {
            self.reporter.reportErrorAtSpanArgs(
                ass.rhs.span,
                "Type {s} cannot be assigned to {s}",
                .{
                    rhs.typ.getTextLeak(self.temp_allocator),
                    lhs.typ.getTextLeak(self.temp_allocator),
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
            .value = .{ .fn_call = tast_call },
        };
    }
    
    fn typeFnCall(self: *Typer, scope: *Scope, call: *const ast.FnCall, span: TokenSpan) tast.FnCall {
        const callee = self.makeExprPointer(self.typeExpr(scope, call.callee, types.UNKNOWN));
        
        if (callee.typ.kind != types.TypeKind.func) {
            self.reporter.reportErrorAtSpan(call.callee.span, "Cannot call something that is not a function");
        }
        
        const is_variadic = callee.typ.value.func.is_variadic;
        const param_types = callee.typ.value.func.params;
        const return_type = callee.typ.value.func.returns;
        
        if (is_variadic) {
            if (call.args.len < param_types.len - 1) {
                self.reporter.reportErrorAtSpanArgs(
                    span,
                    "Expected {} or more arguments but got {}",
                    .{ param_types.len - 1, call.args.len },
                );
            }
        }
        else {
            if (call.args.len != param_types.len) {
                self.reporter.reportErrorAtSpanArgs(
                    span,
                    "Expected {} arguments but got {}",
                    .{ param_types.len, call.args.len },
                );
            }
        }
        
        var typed_args = std.ArrayList(tast.Expr).initCapacity(self.allocator, call.args.len) catch unreachable;
        
        for (call.args, 0..) |arg, i| {
            const index = if (i < param_types.len) i else if (is_variadic) param_types.len - 1 else unreachable;
            
            const expr = self.typeExpr(scope, &arg, param_types[index]);
            typed_args.appendAssumeCapacity(expr);
            
            if (!expr.typ.canBeAssignedTo(param_types[index])) {
                self.reporter.reportErrorAtSpanArgs(
                    arg.span,
                    "Expected type {s} but got {s}",
                    .{
                        param_types[index].getTextLeak(self.temp_allocator),
                        expr.typ.getTextLeak(self.temp_allocator),
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
                    self.reporter.reportErrorAtSpan(span, "Cannot return a value from void function");
                }
                else {
                    value = self.makeExprPointer(self.typeExpr(scope, ret_value, cur_fn.return_typ));
                    
                    if (!value.?.typ.canBeAssignedTo(cur_fn.return_typ)) {
                        const expected_str = cur_fn.return_typ.getTextLeak(self.allocator);
                        const actual_str = value.?.typ.getTextLeak(self.allocator);
                        
                        self.reporter.reportErrorAtSpanArgs(
                            ret_value.span,
                            "Expected return value of type {s} but got {s}",
                            .{expected_str, actual_str},
                        );
                    }
                }
            }
            else if (cur_fn.return_typ.kind != types.TypeKind.void) {
                const expected_str = cur_fn.return_typ.getTextLeak(self.allocator);
                self.reporter.reportErrorAtSpanArgs(span, "Need a return value with type of {s}", .{expected_str});
            }
        }
        else {
            self.reporter.reportErrorAtSpan(span, "return must be inside a function");
        }
        
        return .{ .returns = .{ .value = value } };
    }
    
    fn typeIf(self: *Typer, scope: *Scope, iff: *const ast.If) tast.Stmt {
        const cond = self.makeExprPointer(self.typeExpr(scope, iff.condition, types.UNKNOWN));
        
        if (!cond.typ.canBeUsedAsCond()) {
            self.reporter.reportErrorAtSpanArgs(iff.condition.span, "Type {s} cannot be used as condition", .{cond.typ.getTextLeak(self.temp_allocator)});
        }
        
        var body: *tast.Stmt = undefined;
        
        if (iff.body.value == .block) {
            var new_scope = scope.inherit();
            defer new_scope.deinit();
            
            body = self.makeStmtPointer(self.typeBlockStmt(&new_scope, &iff.body.value.block));
        }
        else {
            body = self.makeStmtPointer(self.typeStmt(scope, iff.body));
        }
        
        var else_stmt: ?*tast.Stmt = null;
        
        if (iff.else_expr) |else_expr| {
            else_stmt = self.makeStmtPointer(self.typeStmt(scope, else_expr));
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
            self.reporter.reportErrorAtSpanArgs(iff.condition.span, "Type {s} cannot be used as condition", .{cond.typ.getTextLeak(self.temp_allocator)});
        }
        
        const true_expr = self.typeExpr(scope, iff.body, types.UNKNOWN);
        var typ = true_expr.typ;
        
        const false_expr = if (iff.else_expr) |else_expr| blk: {
            const expr = self.typeExpr(scope, else_expr, types.UNKNOWN);
            
            if (expr.typ.canBeCombinedWith(true_expr.typ)) {
                typ = typ.combinedWith(expr.typ);
            }
            else {
                self.reporter.reportErrorAtSpanArgs(
                    span,
                    "Cannot combine {s} and {s} as if expression",
                    .{
                        typ.getTextLeak(self.temp_allocator),
                        expr.typ.getTextLeak(self.temp_allocator),
                    },
                );
            }
            
            break :blk expr;
        }
        else {
            self.reporter.reportErrorAtSpan(span, "if as an expression must have an else expression");
        };
        
        return .{
            .typ = typ,
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
            self.reporter.reportErrorAtSpanArgs(whil.condition.span, "Type {s} cannot be used as condition", .{cond.typ.getTextLeak(self.temp_allocator)});
        }
        
        var body: *tast.Stmt = undefined;
        
        if (whil.body.value == .block) {
            var new_scope = scope.inherit();
            defer new_scope.deinit();
            
            body = self.makeStmtPointer(self.typeBlockStmt(&new_scope, &whil.body.value.block));
        }
        else {
            body = self.makeStmtPointer(self.typeStmt(scope, whil.body));
        }
        
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
            item_var = self.symbol_manager.createSymbol(self.getTokenText(v));
        }
        
        if (forr.index_var) |v| {
            index_var = self.symbol_manager.createSymbol(self.getTokenText(v));
        }
        
        const iter = self.typeExpr(scope, forr.iter, types.UNKNOWN);
        
        switch (iter.typ.kind) {
            .numeric,
            .range => {
                // For numeric and range iter, cannot crate index var
                // It will be confusing to distinguish between index and item, because they are both i32
                // And moreover, if iter is numeric or range that starts from 0, both the value of item and index
                // will be the same
                if (forr.index_var) |v| {
                    self.reporter.reportErrorAtToken(v, "For with int and range iter cannot have index");
                }
                
                var start: *tast.Expr = undefined;
                var end: *tast.Expr = undefined;
                
                if (iter.typ.kind == .numeric) {
                    if (!iter.typ.isNumericInt()) {
                        self.reporter.reportErrorAtSpan(
                            forr.iter.span,
                            "Only numeric int can be used as for iterator",
                        );
                    }
                    
                    if (iter.typ.canBeAssignedTo(types.I32)) {
                        start = self.makeExprPointer(.{
                            .typ = types.I32,
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
                        );
                    }
                }
                else {
                    start = iter.value.range.lhs;
                    end = iter.value.range.rhs;
                    
                    if (iter.value.range.is_eq) {
                        const one = self.makeExprPointer(.{
                            .typ = types.I32,
                            .value = .{.literal = .{ .int = 1 }},
                        });
                        
                        const bin = self.makeExprPointer(.{
                            .typ =  types.I32,
                            .value = .{.binary = .{
                                .lhs = end,
                                .rhs = one,
                                .op = .add,
                            }}
                        });
                        
                        end = bin;
                    }
                }
                
                var new_scope = scope.inherit();
                defer new_scope.deinit();
                
                if (item_var) |v| {
                    scope.set(v.text, v, types.I32);
                }
                
                const body = self.makeStmtPointer(self.typeStmt(&new_scope, forr.body));
                
                return tast.Stmt{.for_range = .{
                    .item_var = item_var,
                    .start = start,
                    .end = end,
                    .body = body,
                }};
            },
            .array => {
                var new_scope = scope.inherit();
                defer new_scope.deinit();
                
                if (item_var) |v| {
                    scope.set(v.text, v, iter.typ.value.array.child);
                }
                
                if (index_var) |v| {
                    scope.set(v.text, v, types.I32);
                }
                
                const body = self.makeStmtPointer(self.typeStmt(&new_scope, forr.body));
                
                return .{.for_each = .{
                    .item_var = item_var,
                    .index_var = index_var,
                    .item_typ = iter.typ.value.array.child,
                    .iter = self.makeExprPointer(iter),
                    .body = body,
                }};
            },
            
            else => {
                self.reporter.reportErrorAtSpanArgs(
                    forr.iter.span,
                    "Type {s} is not iterable",
                    .{iter.typ.getTextLeak(self.allocator)},
                );
            }
        }
        
        unreachable;
    }
    
    fn typeImport(self: *Typer, scope: *Scope, import: *const ast.Import) tast.Stmt {
        const path_with_quote = self.getTokenText(import.path);
        const path = path_with_quote[1..path_with_quote.len - 1];
        const module = self.children.get(path);
        
        if (module) |mod| {            
            var iter = mod.public_symbols.iterator();
            
            while (iter.next()) |entry| {
                scope.setTypedSymbol(entry.key_ptr.*, entry.value_ptr.*);
            }
            
            return .{
                .noop = {},
            };
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
            };
        }
        
        self.reporter.reportErrorAtTokenArgs(ident.name, "Unknown symbol '{s}'", .{name});
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
                    .typ = types.UNTYPED_INT,
                    .value = .{ .literal = .{ .int = value } },
                };
            },
            
            ast.LitKind.Float => {
                const text = self.getTokenText(lit.value);
                const value = std.fmt.parseFloat(f64, text) catch unreachable;
                
                return tast.Expr{
                    .typ = types.UNTYPED_FLOAT,
                    .value = .{ .literal = .{ .float = value } },
                };
            },
            
            ast.LitKind.String => {
                const text = self.getTokenText(lit.value);
                const value = self.allocator.dupe(u8, text[1..text.len - 1]) catch unreachable;
                
                return tast.Expr{
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
                    .typ = types.CHAR,
                    .value = .{ .literal = .{ .char = value } },
                };
            },
            
            ast.LitKind.True,
            ast.LitKind.False, => {
                return tast.Expr{
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
                    self.reporter.reportErrorAtSpan(un.expr.span, "Unary not (!) operand must be bool type");
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
                    self.reporter.reportErrorAtSpan(un.expr.span, "Unary minus (-) operand must be numeric type");
                }
            },
            
            else => {
                std.debug.panic("TODO: typeUnary {s}", .{@tagName(un.op.kind)});
            }
        }
        
        return .{
            .typ = typ,
            .value = .{.unary = .{
                .expr = self.makeExprPointer(expr),
                .op = op,
            }},
        };
    }
    
    fn typeBinary(self: *Typer, scope: *Scope, bin: *const ast.Binary, span: TokenSpan) tast.Expr {
        var lhs = self.typeExpr(scope, bin.lhs, types.UNKNOWN);
        
        const exp_typ = switch (lhs.typ.kind) {
            .struc,
            .enumm => lhs.typ,
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
                        else {
                            lhs = tast.Expr{
                                .typ = rhs.typ,
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
        else if (lhs.value == .array_value) {
            if (bin.op.kind == .MulMul) {
                if (rhs.value == .literal and rhs.value.literal == .int) {
                    const elems_len = lhs.value.array_value.elems.len;
                    const count = rhs.value.literal.int;
                    
                    var new_elems = std.ArrayList(tast.Expr).initCapacity(self.allocator, elems_len * count) catch unreachable;
                    
                    for (0..count) |_| {
                        for (lhs.value.array_value.elems) |elem| {
                            new_elems.appendAssumeCapacity(elem);
                        }
                    }
                    
                    return .{
                        .typ = lhs.typ,
                        .value = .{ .array_value = .{ .elems = new_elems.items } },
                    };
                }
                else {
                    self.reporter.reportErrorAtSpan(bin.rhs.span, "Repeat (**) operand must be an int literal");
                }
            }
            else if (bin.op.kind == .PlusPlus) {
                if (rhs.value == .array_value and rhs.typ.isSame(lhs.typ)) {
                    const l_elems_len = lhs.value.array_value.elems.len;
                    const r_elems_len = rhs.value.array_value.elems.len;
                    var new_elems = std.ArrayList(tast.Expr).initCapacity(self.allocator, l_elems_len + r_elems_len) catch unreachable;
                    
                    for (lhs.value.array_value.elems) |elem| {
                        new_elems.appendAssumeCapacity(elem);
                    }
                    
                    for (rhs.value.array_value.elems) |elem| {
                        new_elems.appendAssumeCapacity(elem);
                    }
                    
                    return .{
                        .typ = lhs.typ,
                        .value = .{ .array_value = .{ .elems = new_elems.items } },
                    };
                }
                else {
                    self.reporter.reportErrorAtSpan(bin.rhs.span, "Concat (++) operant must be an array with the same type");
                }
            }
        }
        
        if (need_explicit_cast) {
            self.reporter.reportErrorAtSpanArgs(
                span,
                "Need explicit cast in binary operation {s} for type {s} and {s}",
                .{
                    bin.op.kind.getBinopText(),
                    lhs.typ.getTextLeak(self.temp_allocator),
                    rhs.typ.getTextLeak(self.temp_allocator),
                },
            );
        }
        else if (!valid) {
            self.reporter.reportErrorAtTokenArgs(
                bin.op,
                "Invalid binary operation {s} for type {s} and {s}",
                .{
                    bin.op.kind.getBinopText(),
                    lhs.typ.getTextLeak(self.temp_allocator),
                    rhs.typ.getTextLeak(self.temp_allocator),
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
            .value = .{.binary = .{
                .lhs = self.makeExprPointer(lhs),
                .rhs = self.makeExprPointer(rhs),
                .op = binop,
            }},
        };
    }
    
    fn typeArrayValue(self: *Typer, scope: *Scope, arr: *const ast.ArrayValue, span: TokenSpan, exp_typ: *const Type) tast.Expr {
        var elem_typ = types.UNKNOWN;
        var elems = std.ArrayList(tast.Expr).initCapacity(self.allocator, arr.elems.len) catch unreachable;
        
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
                    self.reporter.reportErrorAtSpanArgs(
                        elem.span,
                        "Expected type {s} but got {s}",
                        .{
                            elem_typ.getTextLeak(self.allocator),
                            elem_expr.typ.getTextLeak(self.allocator),
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
            self.reporter.reportErrorAtSpanArgs(
                span,
                "Expected type {s} but got {s}",
                .{
                    exp_typ.getTextLeak(self.allocator),
                    typ.getTextLeak(self.allocator),
                }
            );
        }
        
        return .{
            .typ = typ,
            .value = .{ .array_value = .{ .elems = elems.items } },
        };
    }
    
    fn typeArrayIndex(self: *Typer, scope: *Scope, arr: *const ast.ArrayIndex) tast.Expr {
        const callee = self.makeExprPointer(self.typeExpr(scope, arr.callee, types.UNKNOWN));
        const index = self.makeExprPointer(self.typeExpr(scope, arr.index, types.UNKNOWN));
        
        if (callee.typ.kind != .array) {
            self.reporter.reportErrorAtSpan(arr.callee.span, "Not an array");
        }
        
        if (!index.typ.isNumericInt()) {
            self.reporter.reportErrorAtSpanArgs(
                arr.index.span,
                "Type {s} cannot be used as array index",
                .{index.typ.getTextLeak(self.temp_allocator)},
            );
        }
        
        return .{
            .typ = callee.typ.value.array.child,
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
            self.reporter.reportErrorAtSpanArgs(
                range.lhs.span,
                "Type {s} cannot be used as for range item. Must be an int",
                .{lhs.typ.getTextLeak(self.allocator)},
            );
        }
        
        if (!rhs.typ.canBeAssignedTo(types.I32)) {
            self.reporter.reportErrorAtSpanArgs(
                range.rhs.span,
                "Type {s} cannot be used as for range item. Must be an int",
                .{rhs.typ.getTextLeak(self.allocator)},
            );
        }
        
        return .{
            .typ = types.RANGE,
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
            .struc => {
                const struct_typ = callee.typ.value.struc;
                const member_text = self.getTokenText(mem.member);
                var exists = false;
                var typ: *const Type = undefined;
                var member_index: usize = undefined;
                
                for (struct_typ.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name.text, member_text)) {
                        exists = true;
                        typ = field.typ;
                        member_index = i;
                        
                        break;
                    }
                }
                
                if (!exists) {
                    self.reporter.reportErrorAtTokenArgs(
                        mem.member,
                        "Type {s} doesn't have member '{s}'",
                        .{
                            callee.typ.getTextLeak(self.allocator),
                            self.getTokenText(mem.member),
                        }
                    );
                }
                
                return .{
                    .typ = typ,
                    .value = .{.struct_member = .{
                        .callee = callee,
                        .member_index = member_index,
                    }},
                };
            },
            
            else => {
                self.reporter.reportErrorAtTokenArgs(
                    mem.member,
                    "Type {s} doesn't have member '{s}'",
                    .{
                        callee.typ.getTextLeak(self.allocator),
                        self.getTokenText(mem.member),
                    }
                );
            }
        }
    }
    
    fn typeArrayBuiltin(self: *Typer, scope: *Scope, ar: *tast.Expr, member: Token) tast.Expr {
        _ = scope;
        
        const member_text = self.getTokenText(member);
        const ar_typ = if (ar.typ.kind == .array) ar.typ.value.array else unreachable;
        
        if (std.mem.eql(u8, member_text, "len")) {
            const args = self.allocator.alloc(*const tast.Expr, 1) catch unreachable;
            args[0] = ar;
            
            return .{
                .typ = types.UNTYPED_INT,
                .value = .{.builtin = .{ .array_len = .{ .arr = ar } }}
            };
        }
        else if (ar_typ.is_dyn) {
            if (std.mem.eql(u8, member_text, "append")) {
                const param_types = self.allocator.alloc(*const Type, 1) catch unreachable;
                param_types[0] = ar_typ.child;
                
                return .{
                    .typ = self.type_manager.createFn(param_types, types.VOID, false, true),
                    .value = .{ .builtin = .{ .dynarray_append = .{ .arr = ar } } }
                };
            }
            else {
                self.reporter.reportErrorAtTokenArgs(
                    member,
                    "Type {s} doesn't have member '{s}'",
                    .{
                        ar.typ.getTextLeak(self.allocator),
                        self.getTokenText(member),
                    }
                );
            }
        }
        else {
            self.reporter.reportErrorAtTokenArgs(
                member,
                "Type {s} doesn't have member '{s}'",
                .{
                    ar.typ.getTextLeak(self.allocator),
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
                typ = symbol.typ;
            }
            else {
                self.reporter.reportErrorAtTokenArgs(struct_name, "Unknown identifier '{s}'", .{name_text});
            }
        }
        else if (exp_typ.kind != .unknown) {
            typ = exp_typ;
        }
        else {
            std.debug.panic("TODO: typeStructValue without struct name", .{});
        }
        
        if (typ.value != .struc) {
            self.reporter.reportErrorAtToken(val.struct_name.?, "Not a struct");
        }
        
        const FieldState = enum {
            unresolved,
            resolved,
            has_default,
        };
        
        const struct_typ = typ.value.struc;
        const field_len = struct_typ.fields.len;
        var field_states = self.temp_allocator.alloc(FieldState, field_len) catch unreachable;
        defer self.temp_allocator.free(field_states);
        var values = self.allocator.alloc(tast.Expr, field_len) catch unreachable;
        
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
                self.reporter.reportErrorAtSpan(val.elems[i].value.span, "Too many field");
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
                    self.reporter.reportErrorAtTokenArgs(
                        field_name_token,
                        "Unkown struct field '{s}'",
                        .{field_name},
                    );
                }
                
                // Placed here because it's impossible to have duplicate unless field has a name
                if (field_states[i] == .resolved) {
                    self.reporter.reportErrorAtTokenArgs(
                        field_name_token,
                        "Duplicate struct field '{s}'",
                        .{field_name},
                    );
                }
                
                field_index = index.?;
            }
            else {
                field_index = i;
            }
            
            field_states[i] = .resolved;
            values[i] = self.typeExpr(scope, &val.elems[i].value, struct_typ.fields[i].typ);
        }
        
        for (field_states, 0..) |field_state, i| {
            if (field_state == .unresolved) {
                self.reporter.reportErrorAtSpanArgs(
                    span,
                    "Missing struct field '{s}' with type of {s}",
                    .{
                        struct_typ.fields[i].name.text,
                        struct_typ.fields[i].typ.getTextLeak(self.allocator),
                    }
                );
            }
            else if (field_state == .has_default) {
                values[i] = @as(*tast.Expr, @alignCast(@ptrCast(struct_typ.fields[i].default_value.?))).*;
            }
        }
        
        return .{
            .typ = typ,
            .value = .{ .struct_value = .{ .values = values } },
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
                        result_type = sym.typ;
                    }
                    else {
                        self.reporter.reportErrorAtTokenArgs(typ.value.simple.name, "Unknown type '{s}'", .{typ_text});
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
        const p = self.allocator.create(tast.Stmt) catch unreachable;
        p.* = stmt;
        
        return p;
    }
    
    fn makeExprPointer(self: *Typer, expr: tast.Expr) *tast.Expr {
        const p = self.allocator.create(tast.Expr) catch unreachable;
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
            .value = .{.cast = .{
                .typ = expr.typ,
                .value = expr,
            }},
        });
    }
    
    fn collectAndFreeTempList(self: *Typer, comptime T: type, list: *std.ArrayList(T)) []const T {
        const res = self.allocator.dupe(T, list.items) catch unreachable;
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
    reporter: Reporter,
    file_manager: *const FileManager,
    symbol_manager: *SymbolManager,
    module: *const ast.Module,
    module_id: usize,
    children: *const std.StringHashMap(*tast.Module),
) tast.Module {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const temp_allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    
    var type_manager = TypeManager.init(arena, temp_allocator);
    defer type_manager.deinit();
    
    var typer = Typer.init(arena, temp_allocator, reporter, file_manager, &type_manager, symbol_manager, children);
    var scope = Scope.init(temp_allocator, true);
    defer scope.deinit();
    
    return typer.typeModule(&scope, module, module_id);
}