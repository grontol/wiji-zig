const std = @import("std");

const tast = @import("tast.zig");
const types = @import("type.zig");
const Type = types.Type;
const TypeId = types.TypeId;
const Symbol = @import("symbol.zig").Symbol;

const dyn_array_append_macro =
\\#define DYN_ARRAY_APPEND(typ, arr, value) do {                                \
\\    if ((arr)->len + 1 > (arr)->cap) {                                        \
\\        size_t new_cap;                                                       \
\\        if ((arr)->cap == 0) new_cap = 16;                                    \
\\        else new_cap = (arr)->cap * 2;                                        \
\\                                                                              \
\\        while (new_cap < (arr)->len) new_cap *= 2;                            \
\\                                                                              \
\\        void* new_items;                                                      \
\\        if ((arr)->cap == 0) {                                                \
\\            new_items = malloc(new_cap * sizeof(typ));                        \
\\                                                                              \
\\            for (size_t a = 0; a < (arr)->len; a++) {                         \
\\                ((typ*)new_items)[a] = (arr)->ptr[a];                       \
\\            }                                                                 \
\\        }                                                                     \
\\        else {                                                                \
\\            new_items = realloc((arr)->ptr, new_cap * sizeof(typ));         \
\\        }                                                                     \
\\                                                                              \
\\        (arr)->ptr = new_items;                                             \
\\        (arr)->cap = new_cap;                                                 \
\\    }                                                                         \
\\                                                                              \
\\    (arr)->ptr[(arr)->len++] = value;                                       \
\\} while(0)
;

const Cgen = struct {
    allocator: std.mem.Allocator,
    header_src: std.ArrayList(u8) = .empty,
    typedef_src: std.ArrayList(u8) = .empty,
    builtin_src: std.ArrayList(u8) = .empty,
    var_src: std.ArrayList(u8) = .empty,
    fn_forward_src: std.ArrayList(u8) = .empty,
    fn_src: std.ArrayList(u8) = .empty,
    
    cur_src: *std.ArrayList(u8) = undefined,
    type_map: std.AutoHashMap(TypeId, []const u8),
    indent: usize = 0,
    hidden_var_index: usize = 0,
    generated_modules: std.AutoHashMap(usize, bool),
    
    dyn_array_append_generated: bool = false,
    
    fn init(allocator: std.mem.Allocator) Cgen {
        return Cgen{
            .allocator = allocator,
            .type_map = std.AutoHashMap(TypeId, []const u8).init(allocator),
            .generated_modules = std.AutoHashMap(usize, bool).init(allocator),
        };
    }
    
    inline fn setToHeader(self: *Cgen) void {
        self.cur_src = &self.header_src;
    }
    
    inline fn setToTypedef(self: *Cgen) void {
        self.cur_src = &self.typedef_src;
    }
    
    inline fn setToBuiltin(self: *Cgen) void {
        self.cur_src = &self.builtin_src;
    }
    
    inline fn setToVar(self: *Cgen) void {
        self.cur_src = &self.var_src;
    }
    
    inline fn setToFnForward(self: *Cgen) void {
        self.cur_src = &self.fn_forward_src;
    }
    
    inline fn setToFn(self: *Cgen) void {
        self.cur_src = &self.fn_src;
    }
    
    inline fn setToList(self: *Cgen, list: *std.ArrayList(u8)) void {
        self.cur_src = list;
    }
    
    inline fn write(self: *Cgen, comptime fmt: []const u8) void {
        self.writeArgs(fmt, .{});
    }
    
    inline fn writeArgs(self: *Cgen, comptime fmt: []const u8, args: anytype) void {
        self.cur_src.print(self.allocator, fmt, args) catch unreachable;
    }
    
    fn genDynArrayAppendMacro(self: *Cgen) void {
        if (self.dyn_array_append_generated) return;
        
        const cur_src = self.cur_src;
        
        self.setToBuiltin();        
        self.writeArgs("{s}", .{ dyn_array_append_macro });
        
        self.cur_src = cur_src;
        
        self.dyn_array_append_generated = true;
    }
    
    fn writeSymbol(self: *Cgen, symbol: Symbol) void {
        for (symbol.namespaces) |namespace| {
            self.writeArgs("{s}___", .{namespace});
        }
        
        self.writeArgs("{s}", .{symbol.text});
    }
    
    fn createHiddenVar(self: *Cgen, buffer: []u8) []const u8 {
        var ar = std.ArrayList(u8).initBuffer(buffer);
        ar.printAssumeCapacity("__XX_{}", .{self.hidden_var_index});
        self.hidden_var_index += 1;
        
        return ar.items;
    }
    
    fn writeIndent(self: *Cgen) void {
        for (0..self.indent * 4) |_| {
            self.write(" ");
        }
    }
    
    fn gen(self: *Cgen, module: *const tast.Module) []const u8 {
        var src = std.ArrayList(u8).empty;
        
        self.setToHeader();
        // self.write("#include <stdio.h>\n");
        self.write("#include <stdint.h>\n");
        self.write("#include <stdbool.h>\n");
        self.write("#include <stddef.h>\n");
        
        self.setToTypedef();
        self.write("typedef uint8_t  u8;\n");
        self.write("typedef uint16_t u16;\n");
        self.write("typedef uint32_t u32;\n");
        self.write("typedef uint64_t u64;\n");
        self.write("typedef int8_t   i8;\n");
        self.write("typedef int16_t  i16;\n");
        self.write("typedef int32_t  i32;\n");
        self.write("typedef int64_t  i64;\n");
        self.write("typedef float    f32;\n");
        self.write("typedef double   f64;\n");
        self.write("typedef const char* string;\n\n");
        
        self.genModule(module);
        
        src.print(self.allocator, "{s}\n", .{self.header_src.items}) catch unreachable;
        src.print(self.allocator, "{s}\n", .{self.typedef_src.items}) catch unreachable;
        src.print(self.allocator, "{s}\n", .{self.builtin_src.items}) catch unreachable;
        src.print(self.allocator, "{s}\n", .{self.var_src.items}) catch unreachable;
        src.print(self.allocator, "{s}\n", .{self.fn_forward_src.items}) catch unreachable;
        src.print(self.allocator, "{s}\n", .{self.fn_src.items}) catch unreachable;
        
        return src.items;
    }
    
    fn genModule(self: *Cgen, module: *const tast.Module) void {
        for (module.children) |ch| {
            if (!self.generated_modules.contains(ch.id)) {
                self.genModule(ch);
                self.generated_modules.put(ch.id, true) catch unreachable;
            }
        }
        
        self.setToVar();
        for (module.var_decls) |var_decl| {
            self.genVarDecl(&var_decl, true);
            
            if (var_decl.kind != .Const) {
                self.write(";");
            }
            
            self.write("\n");
        }
        
        for (module.fn_decls) |fn_decl| {
            self.genFnDecl(&fn_decl);
        }
    }
    
    fn genFnDecl(self: *Cgen, fn_decl: *const tast.FnDecl) void {
        var should_create_decl = true;
        var should_create_impl = true;
        
        if (fn_decl.is_extern) {
            // should_create_decl = !std.mem.eql(u8, fn_decl.name.text, "printf");
            should_create_impl = false;
        }
        else {
            should_create_decl = !std.mem.eql(u8, fn_decl.name.text, "main");
        }
        
        if (should_create_decl) {
            if (fn_decl.extern_name) |extern_name| {
                self.setToTypedef();
                self.writeArgs("#define ", .{});
                self.writeSymbol(fn_decl.name);
                self.writeArgs(" {s}\n", .{extern_name});
            }
            
            self.setToFnForward();
            
            self.genType(fn_decl.return_typ);
            self.write(" ");
            self.writeSymbol(fn_decl.name);
            self.writeArgs("(", .{});
            
            for (fn_decl.params, 0..) |param, i| {
                if (i > 0) {
                    self.write(", ");
                }
                
                if (param.is_variadic) {
                    self.write("...");
                }
                else {
                    self.genType(param.typ);
                    self.write(" ");
                    self.writeSymbol(param.name);
                }
            }
            
            self.write(");\n");
        }
        
        if (should_create_impl) {
            self.setToFn();
            
            self.genType(fn_decl.return_typ);
            self.write(" ");
            self.writeSymbol(fn_decl.name);
            self.writeArgs("(", .{});
            
            for (fn_decl.params, 0..) |param, i| {
                if (i > 0) {
                    self.write(", ");
                }
                
                self.genType(param.typ);
                self.write(" ");
                self.writeSymbol(param.name);
            }
            
            self.write(") ");
            
            if (fn_decl.body) |body| {
                self.genBlock(&body, false);
            }
            else {
                self.write("{{}}");
            }
            
            self.write("\n\n");
        }
    }
    
    fn genStmt(self: *Cgen, stmt: *const tast.Stmt, dont_create_block: bool) void {
        var has_semicolon = true;
        var has_newline = true;
        
        switch (stmt.*) {
            .var_decl   => |var_decl|  { self.genVarDecl(&var_decl, false); },
            .assignment => |ass|       { self.genAssignment(&ass); },
            .fn_call    => |fn_call|   { self.genFnCall(&fn_call); },
            .returns    => |ret|       { self.genReturn(&ret); },
            .iff        => |iff|       { self.genIf(&iff); has_semicolon = false; },
            .switc      => |switc|     { self.genSwitch(&switc); },
            .whil       => |whil|      { self.genWhile(&whil); has_semicolon = false; },
            .for_range  => |for_range| { self.genForRange(&for_range); has_semicolon = false; },
            .for_each   => |for_each|  { self.genForEach(&for_each); has_semicolon = false; },
            .block      => |block|     { self.genBlock(&block, dont_create_block); has_semicolon = false; has_newline = false; },
            .breaq      => |_|         { self.genBreak(); },
            
            else => {
                std.debug.panic("TODO: genStmt {s}", .{@tagName(stmt.*)});
            }
        }
        
        if (has_semicolon) {
            self.write(";");
        }
        
        if (has_newline) {
            self.write("\n");
        }
    }
    
    fn genBlock(self: *Cgen, block: *const tast.Block, dont_create_block: bool) void {
        if (!dont_create_block) {
            self.write("{{\n");
            self.indent += 1;
        }
        
        for (block.stmts, 0..) |stmt, i| {
            if (i > 0 or !dont_create_block) {
                self.writeIndent();
            }
            
            self.genStmt(&stmt, false);
        }
        
        if (!dont_create_block) {
            self.indent -= 1;
            self.writeIndent();
            self.write("}}");
        }
    }
    
    fn genBreak(self: *Cgen) void {
        self.write("break");
    }
    
    fn genVarDecl(self: *Cgen, decl: *const tast.VarDecl, is_top_level: bool) void {
        if (is_top_level and decl.kind == .Const) {
            std.debug.assert(decl.value != null);
            
            self.write("#define ");
            self.writeSymbol(decl.name);
            self.write(" ");
            self.genExpr(decl.value.?);
        }
        else {
            self.genType(decl.typ);
            self.write(" ");
            self.writeSymbol(decl.name);
            
            if (decl.value) |value| {
                self.write(" = ");
                self.genExpr(value);
            }
        }
    }
    
    fn genAssignment(self: *Cgen, ass: *const tast.Assignment) void {
        self.genExpr(ass.lhs);
        
        const op = switch (ass.op) {
            .eq       => "=",
            .plus_eq  => "+=",
            .minus_eq => "-=",
            .mul_eq   => "*=",
            .div_eq   => "/=",
            .mod_eq   => "%=",
        };
        
        self.writeArgs(" {s} ", .{op});
        self.genExpr(ass.rhs);
    }
    
    fn genFnCall(self: *Cgen, fn_call: *const tast.FnCall) void {
        if (fn_call.callee.value == .builtin) {
            self.genBuiltin(&fn_call.callee.value.builtin, fn_call.args);
        }
        else if (fn_call.callee.value == .struct_method) {
            const struct_typ = fn_call.callee.value.struct_method.struct_typ.value.@"struct";
            const method = struct_typ.methods[fn_call.callee.value.struct_method.method_index];
            
            self.writeSymbol(method.name);
            self.write("(");
            
            self.genExpr(fn_call.callee.value.struct_method.callee);
            
            for (fn_call.args) |arg| {
                self.write(", ");                
                self.genExpr(&arg);
            }
            
            self.write(")");
        }
        else if (fn_call.callee.value == .enum_method) {
            const enum_typ = fn_call.callee.value.enum_method.enum_typ.value.@"enum";
            const method = enum_typ.methods[fn_call.callee.value.enum_method.method_index];
            
            self.writeSymbol(method.name);
            self.write("(");
            
            self.genExpr(fn_call.callee.value.enum_method.callee);
            
            for (fn_call.args) |arg| {
                self.write(", ");                
                self.genExpr(&arg);
            }
            
            self.write(")");
        }
        else {
            self.genExpr(fn_call.callee);
            self.write("(");
            
            for (fn_call.args, 0..) |arg, i| {
                if (i > 0) {
                    self.write(", ");
                }
                
                self.genExpr(&arg);
            }
            
            self.write(")");
        }
    }
    
    fn genReturn(self: *Cgen, ret: *const tast.Return) void {
        self.write("return");
        
        if (ret.value) |value| {
            self.write(" ");
            self.genExpr(value);
        }
    }
    
    fn genIf(self: *Cgen, iff: *const tast.If) void {
        self.write("if (");
        self.genExpr(iff.condition);
        self.write(") {{\n");
        self.indent += 1;
        self.writeIndent();
        self.genStmt(iff.body, true);
        self.indent -= 1;
        self.writeIndent();
        self.write("}}");
        
        if (iff.else_stmt) |else_stmt| {
            self.write(" else {{\n");
            self.indent += 1;
            self.writeIndent();
            self.genStmt(else_stmt, true);
            self.indent -= 1;
            self.writeIndent();
            self.write("}}");
        }
    }
    
    fn genSwitch(self: *Cgen, switc: *const tast.Switch) void {
        self.write("switch (");
        self.genExpr(switc.expr);
        self.write(") {{\n");
        self.indent += 1;
        
        for (switc.cases) |case| {
            if (case.conditions.len > 0) {
                for (case.conditions) |cond| {
                    if (cond.value == .range) {
                        self.writeIndent();
                        self.write("case ");
                        self.genExpr(cond.value.range.lhs);
                        self.write(" ... ");
                        self.genExpr(cond.value.range.rhs);
                        
                        if (!cond.value.range.is_eq) {
                            self.write(" - 1");
                        }
                        
                        self.write(":\n");
                    }
                    else {
                        self.writeIndent();
                        self.write("case ");
                        self.genExpr(&cond);
                        self.write(":\n");
                    }
                }
                
                self.indent += 1;
                self.writeIndent();
                self.genStmt(case.body, true);
                
                if (!case.fallthrough) {
                    self.writeIndent();
                    self.write("break;\n");
                }
                
                self.indent -= 1;
            }
            else {
                self.writeIndent();
                self.write("default:\n");
                self.indent += 1;
                self.writeIndent();
                self.genStmt(case.body, true);
                
                if (!case.fallthrough) {
                    self.writeIndent();
                    self.write("break;\n");
                }
                
                self.indent -= 1;
            }
        }
        
        self.indent -= 1;
        self.writeIndent();
        self.write("}}");
    }
    
    fn genWhile(self: *Cgen, whil: *const tast.While) void {
        self.write("while (");
        self.genExpr(whil.condition);
        self.write(") {{\n");
        self.indent += 1;
        self.writeIndent();
        self.genStmt(whil.body, true);
        self.indent -= 1;
        self.writeIndent();
        self.write("}}");
    }
    
    fn genForRange(self: *Cgen, for_range: *const tast.ForRange) void {
        var var_name_buffer: [32]u8 = undefined;
        
        const var_name = blk: {
            if (for_range.item_var) |item_var| {
                break :blk item_var.text;
            }
            else {
                break :blk self.createHiddenVar(&var_name_buffer);
            }
        };
        
        self.writeArgs("for (int {s} = ", .{var_name});
        self.genExpr(for_range.start);
        self.writeArgs("; {s} < ", .{var_name});
        self.genExpr(for_range.end);
        self.writeArgs("; {s}++) ", .{var_name});
        
        self.write("{{\n");
        self.indent += 1;
        self.writeIndent();
        self.genStmt(for_range.body, true);
        self.indent -= 1;
        self.writeIndent();
        self.write("}}");
    }
    
    fn genForEach(self: *Cgen, for_each: *const tast.ForEach) void {        
        var index_var_buffer: [32]u8 = undefined;
        var iter_buffer: [32]u8 = undefined;
        
        const index_var_name = blk: {
            if (for_each.index_var) |index_var| {
                break :blk index_var.text;
            }
            else {
                break :blk self.createHiddenVar(&index_var_buffer);
            }
        };
        
        const iter_name = self.createHiddenVar(&iter_buffer);
        
        self.genType(for_each.iter.typ);
        self.writeArgs(" {s} = ", .{iter_name});
        self.genExpr(for_each.iter);
        self.write(";\n");
        
        self.writeIndent();
        
        switch (for_each.kind) {
            .array => self.writeArgs("for (int {[index_var]s} = 0; {[index_var]s} < {[iter_var]s}.len; {[index_var]s}++) ", .{
                .index_var = index_var_name, .iter_var = iter_name
            }),
            .string => self.writeArgs("for (int {[index_var]s} = 0; {[index_var]s} < strlen({[iter_var]s}); {[index_var]s}++) ", .{
                .index_var = index_var_name, .iter_var = iter_name
            }),
        }
        
        self.write("{{\n");
        self.indent += 1;
        
        if (for_each.item_var) |item_var| {
            self.writeIndent();
            self.genType(for_each.item_typ.?);
            self.writeArgs(" {s} = ", .{item_var.text,});
            
            if (for_each.is_reference) {
                self.write("&");
            }
            
            switch (for_each.kind) {
                .array  => self.writeArgs("{s}.ptr[{s}];\n", .{iter_name, index_var_name}),
                .string => self.writeArgs("{s}[{s}];\n", .{iter_name, index_var_name}),
            }
        }
        
        self.writeIndent();
        
        self.genStmt(for_each.body, true);
        
        self.indent -= 1;
        self.writeIndent();
        self.write("}}\n");
    }
    
    fn genExpr(self: *Cgen, expr: *const tast.Expr) void {
        switch (expr.value) {
            .identifier    => |ident|   { self.genIdentifier(&ident); },
            .literal       => |lit|     { self.genLiteral(&lit); },
            .unary         => |un|      { self.genUnary(&un); },
            .binary        => |bin|     { self.genBinary(&bin); },
            .fn_call       => |fn_call| { self.genFnCall(&fn_call); },
            .array_value   => |arr|     { self.genArrayValue(&arr, expr.typ); },
            .array_index   => |arr|     { self.genArrayIndex(&arr); },
            .struct_value  => |val|     { self.genStructValue(&val, expr.typ); },
            .struct_member => |mem|     { self.genStructMember(&mem); },
            .enum_value    => |val|     { self.genEnumValue(&val, expr.typ); },
            .cast          => |cast|    { self.genCast(&cast); },
            .referenc_of   => |refof|   { self.genReferenceOf(&refof); },
            .dereferenc_of => |derefof| { self.genDereferenceOf(&derefof); },
            .string_concat => |str_cat| { self.genStringConcat(&str_cat); },
            .builtin       => |builtin| { self.genBuiltin(&builtin, &.{}); },
            
            else => {
                std.debug.panic("TODO: genExpr {s}", .{@tagName(expr.value)});
            }
        }
    }
    
    fn genIdentifier(self: *Cgen, ident: *const tast.Identifier) void {
        self.writeSymbol(ident.name);
    }
    
    fn genLiteral(self: *Cgen, lit: *const tast.Literal) void {
        switch (lit.*) {
            .bool   => self.writeArgs("{}", .{lit.bool}),
            .int    => self.writeArgs("{}", .{lit.int}),
            .float  => self.writeArgs("{}", .{lit.float}),
            .string => self.writeArgs("\"{s}\"", .{lit.string}),
            .char   => {
                switch (lit.char) {
                    '\n' => self.write("'\\n'"),
                    else => self.writeArgs("'{c}'", .{lit.char}),
                }
            },
        }
    }
    
    fn genUnary(self: *Cgen, un: *const tast.Unary) void {
        const op = switch (un.op) {
            tast.UnaryOp.not   => "!",
            tast.UnaryOp.minus => "-",
        };
        
        self.writeArgs("{s}(", .{op});
        self.genExpr(un.expr);
        self.write(")");
    }
    
    fn genBinary(self: *Cgen, bin: *const tast.Binary) void {
        self.write("(");
        self.genExpr(bin.lhs);
        
        const op = switch (bin.op) {
            tast.Binop.add     => "+",
            tast.Binop.sub     => "-",
            tast.Binop.mul     => "*",
            tast.Binop.div     => "/",
            tast.Binop.mod     => "%",
            tast.Binop.gt      => ">",
            tast.Binop.gte     => ">=",
            tast.Binop.lt      => "<",
            tast.Binop.lte     => "<=",
            tast.Binop.eq_eq   => "==",
            tast.Binop.not_eq  => "!=",
            tast.Binop.or_     => "|",
            tast.Binop.or_or   => "||",
            tast.Binop.and_    => "&",
            tast.Binop.and_and => "&&",
        };
        
        self.writeArgs(" {s} ", .{op});
        self.genExpr(bin.rhs);
        self.write(")");
    }
    
    fn genArrayValue(self: *Cgen, arr: *const tast.ArrayValue, typ: *const Type) void {
        self.write("(");
        self.genType(typ);
        self.write("){{ .ptr = ");
        
        self.write("(");
        self.genType(typ.value.array.child);
        self.write("[]){{ ");
        
        for (arr.elems, 0..) |elem, i| {
            if (i > 0) {
                self.write(", ");
            }
            
            self.genExpr(&elem);
        }
        
        self.writeArgs("}}, .len = {} }}", .{arr.elems.len});
    }
    
    fn genArrayIndex(self: *Cgen, arr: *const tast.ArrayIndex) void {
        self.genExpr(arr.callee);
        
        if (!arr.is_raw_pointer) {
            if (arr.is_reference) {
                self.write("->");
            }
            else {
                self.write(".");
            }
            
            self.write("ptr");
        }
        
        self.write("[");
        self.genExpr(arr.index);
        self.write("]");
    }
    
    fn genBuiltin(self: *Cgen, builtin: *const tast.Builtin, args: []const tast.Expr) void {
        switch (builtin.*) {
            .array_len => {
                self.genExpr(builtin.array_len.arr);
                if (builtin.array_len.is_reference) {
                    self.write("->");
                }
                else {
                    self.write(".");
                }
                
                self.write("len");
            },
            .array_ptr => {
                self.genExpr(builtin.array_ptr.arr);
                if (builtin.array_ptr.is_reference) {
                    self.write("->");
                }
                else {
                    self.write(".");
                }
                
                self.write("ptr");
            },
            .dynarray_cap => {
                self.genExpr(builtin.dynarray_cap.arr);
                if (builtin.dynarray_cap.is_reference) {
                    self.write("->");
                }
                else {
                    self.write(".");
                }
                
                self.write("cap");
            },
            .dynarray_append => {
                self.genDynArrayAppendMacro();
                
                self.write("DYN_ARRAY_APPEND(");
                self.genType(builtin.dynarray_append.arr.typ.value.array.child);
                self.write(", ");
                
                if (!builtin.dynarray_append.is_reference) {
                    self.write("&");
                }
                
                self.genExpr(builtin.dynarray_append.arr);
                
                for (args) |arg| {
                    self.write(", ");
                    self.genExpr(&arg);
                }
                
                self.write(")");
            },
            .dynarray_to_array => {
                self.write("((");
                self.genType(builtin.dynarray_to_array.dest_typ);
                self.write("){{ .ptr = ");
                self.genExpr(builtin.dynarray_to_array.arr);
                self.write(".ptr, .len = ");
                self.genExpr(builtin.dynarray_to_array.arr);
                self.write(".len }})");
            },
        }
    }
    
    fn genStructValue(self: *Cgen, val: *const tast.StructValue, typ: *const Type) void {
        self.write("((");
        self.genType(typ);
        self.write(") {{ ");
        
        for (val.values, 0..) |value, i| {
            if (i > 0) {
                self.write(", ");
            }
            
            self.genExpr(&value);
        }
        
        self.write(" }})");
    }
    
    fn genStructMember(self: *Cgen, mem: *const tast.StructMember) void {
        self.genExpr(mem.callee);
        
        if (mem.callee.typ.value == .reference) {
            self.writeArgs("->{s}", .{mem.callee.typ.value.reference.child.value.@"struct".fields[mem.member_index].name.text});
        }
        else {
            self.writeArgs(".{s}", .{mem.callee.typ.value.@"struct".fields[mem.member_index].name.text});
        }
    }
    
    fn genEnumValue(self: *Cgen, val: *const tast.EnumValue, typ: *const Type) void {
        self.writeArgs("{s}_{s}", .{typ.value.@"enum".name.text, typ.value.@"enum".items[val.item_index].text});        
    }
    
    fn genCast(self: *Cgen, cast: *const tast.Cast) void {
        self.write("((");
        self.genType(cast.typ);
        self.write(")");
        self.genExpr(cast.value);
        self.write(")");
    }
    
    fn genReferenceOf(self: *Cgen, refof: *const tast.ReferenceOf) void {
        self.write("&");
        self.genExpr(refof.value);
    }
    
    fn genDereferenceOf(self: *Cgen, refof: *const tast.DereferenceOf) void {
        self.write("*(");
        self.genExpr(refof.value);
        self.write(")");
    }
    
    fn genStringConcat(self: *Cgen, str_cat: *const tast.StringConcat) void {
        self.genExpr(str_cat.lhs);
        self.write(" ");
        self.genExpr(str_cat.rhs);
    }
    
    fn genRepeat(self: *Cgen, repeat: *const tast.Repeat) void {
        _ = self;
        switch (repeat.expr.value) {
            .array_value => {
                
            },
            else => unreachable,
        }
    }
    
    fn genType(self: *Cgen, typ: *const Type) void {
        switch (typ.value) {
            .unknown,
            .bool,
            .string,
            .void => {
                typ.getText(self.cur_src, self.allocator);
                return;
            },
            .numeric => {
                if (typ.value.numeric == .usize) {
                    self.write("size_t");
                }
                else {
                    typ.getText(self.cur_src, self.allocator);
                }
                
                return;
            },
            .reference => {
                self.genType(typ.value.reference.child);
                self.write("*");
                return;
            },
            .pointer => {
                self.genType(typ.value.pointer.child);
                self.write("*");
                return;
            },
            .voidptr => {
                self.write("void*");
                return;
            },
            
            else => {},
        }
        
        const typ_str = self.type_map.get(typ.type_id);
        
        if (typ_str) |str| {
            self.writeArgs("{s}", .{str});
        }
        else {            
            switch (typ.value) {
                .array => {                    
                    const last_src = self.cur_src;
                    
                    var temp_child = std.ArrayList(u8).empty;
                    self.setToList(&temp_child);
                    self.genType(typ.value.array.child);
                    
                    var temp = std.ArrayList(u8).empty;
                    defer temp.clearAndFree(self.allocator);
                    self.setToList(&temp);
                    
                    if (typ.value.array.is_dyn) {
                        self.writeArgs("typedef struct {{ {[typ]s}* ptr; size_t len; size_t cap; }} {[typ]s}_dynarray;\n", .{ .typ = temp_child.items });
                    }
                    else {
                        self.writeArgs("typedef struct {{ {[typ]s}* ptr; size_t len; }} {[typ]s}_array;\n", .{ .typ = temp_child.items });
                    }
                    
                    self.setToTypedef();
                    self.writeArgs("{s}", .{temp.items});
                    self.cur_src = last_src;
                    
                    if (typ.value.array.is_dyn) {
                        temp_child.appendSlice(self.allocator, "_dynarray") catch unreachable;
                    }
                    else {
                        temp_child.appendSlice(self.allocator, "_array") catch unreachable;
                    }
                    
                    self.type_map.put(typ.type_id, temp_child.items) catch unreachable;
                    
                    self.writeArgs("{s}", .{temp_child.items});
                },
                
                .@"struct" => {
                    var struct_name = typ.value.@"struct".name.text;
                    
                    var temp = std.ArrayList(u8).empty;
                    defer temp.clearAndFree(self.allocator);
                    
                    const last_src = self.cur_src;
                    self.setToList(&temp);
                    
                    self.write("typedef struct {{ ");
                    
                    for (typ.value.@"struct".fields) |field| {
                        self.genType(field.typ);
                        self.writeArgs(" {s}; ", .{field.name.text});
                    }
                    
                    self.writeArgs("}} {s}", .{struct_name});
                    
                    if (typ.value.@"struct".type_params.len > 0) {
                        self.writeArgs("_{}", .{typ.type_id});
                    }
                    
                    self.writeArgs(";\n", .{});
                    
                    self.setToTypedef();
                    self.writeArgs("{s}", .{temp.items});
                    self.cur_src = last_src;
                    
                    if (typ.value.@"struct".type_params.len > 0) {
                        var struct_name_ar = std.ArrayList(u8).empty;
                        struct_name_ar.print(self.allocator, "{s}_{}", .{struct_name, typ.type_id}) catch unreachable;
                        struct_name = struct_name_ar.items;
                    }
                    
                    self.type_map.put(typ.type_id, struct_name) catch unreachable;
                    
                    self.writeArgs("{s}", .{struct_name});
                },
                
                .@"enum" => {
                    const enum_name = typ.value.@"enum".name.text;
                    var temp = std.ArrayList(u8).empty;
                    defer temp.clearAndFree(self.allocator);
                    
                    const last_src = self.cur_src;
                    self.setToList(&temp);
                    
                    self.write("typedef enum {{\n");
                    
                    for (typ.value.@"enum".items) |item| {
                        self.writeArgs("    {s}_{s},\n", .{enum_name, item.text});
                    }
                    
                    self.writeArgs("}} {s};\n", .{enum_name});
                    
                    self.setToTypedef();
                    self.writeArgs("{s}", .{temp.items});
                    self.cur_src = last_src;
                    
                    self.type_map.put(typ.type_id, enum_name) catch unreachable;
                    
                    self.writeArgs("{s}", .{enum_name});
                },
                
                .type_param => {
                    // std.debug.panic("Type param should be resolved at typechecking step : {s}", .{typ.getTextLeak(self.allocator)});
                    self.writeArgs("{s}", .{typ.getTextLeak(self.allocator)});
                },
                
                else => {
                    std.debug.panic("TODO: genType {s}", .{@tagName(typ.value)});
                }
            }
        }
    }
};

pub fn cGen(allocator: std.mem.Allocator, module: *const tast.Module) []const u8 {
    var cg = Cgen.init(allocator);
    return cg.gen(module);
}

pub fn cCompile(allocator: std.mem.Allocator, src: []const u8, execute: bool) !void {
    const cwd = std.fs.cwd();
    
    cwd.makeDir(".wiji-out") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    const out_dir = try cwd.openDir("./.wiji-out", .{});
    const file = try out_dir.createFile("out.c", .{});
    defer file.close();
    
    try file.writeAll(src);
    
    const compile_cmd = [_][]const u8{
        "cc",
        "-fdiagnostics-color=always",
        "./.wiji-out/out.c",
        "/home/grt/third/raylib-5.5_linux_amd64/lib/libraylib.a",
        "-lm",
        "-o",
        "./.wiji-out/out",
    };
    
    var compile_out: []const u8 = undefined;
    defer allocator.free(compile_out);
    const compile_success = try execAndWait(allocator, &compile_cmd, &compile_out);
    
    if (!compile_success) {
        std.debug.print("Error compiling c code:\n\n{s}", .{compile_out});
        return;
    }
    
    if (execute) {
        const run_cmd = [_][]const u8{
            "./.wiji-out/out",
        };
        
        _ = try execAndWaitStreaming(allocator, &run_cmd);
    }
}

fn execAndWait(allocator: std.mem.Allocator, cmd: []const []const u8, out: ?*[]const u8) !bool {
    var proc = std.process.Child.init(cmd, allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    try proc.spawn();
    
    if (out) |o| {
        var stdout = std.ArrayList(u8).empty;
        defer stdout.clearAndFree(allocator);
        var stderr = std.ArrayList(u8).empty;
        defer stderr.clearAndFree(allocator);
        
        try proc.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
        
        if (stderr.items.len > 0) {
            o.* = try allocator.dupe(u8, stderr.items);
        }
        else {
            o.* = try allocator.dupe(u8, stdout.items);
        }
    }
    
    const term = try proc.wait();
    
    switch (term) {
        .Exited => |code| {
            return code == 0;
        },
        else => { return false; }
    }
}

fn execAndWaitStreaming(allocator: std.mem.Allocator, cmd: []const []const u8) !bool {
    var proc = std.process.Child.init(cmd, allocator);
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;
    try proc.spawn();
    
    // var buffer: [1024]u8 = undefined;
    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    // const writer = &stdout_writer.interface;
    
    // while (true) {
    //     const bytes_read = try proc.stdout.?.read(&buffer);
    //     if (bytes_read == 0) break;
        
    //     writer.writeAll(buffer[0..bytes_read]) catch unreachable;
    //     // writer.print("{s}", .{buffer[0..bytes_read]}) catch unreachable;
    //     writer.flush() catch unreachable;
    // }    
    
    const term = try proc.wait();
    
    switch (term) {
        .Exited => |code| {
            return code == 0;
        },
        else => { return false; }
    }
}