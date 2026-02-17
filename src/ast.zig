const std = @import("std");
const Token = @import("token.zig").Token;
const TokenSpan = @import("token.zig").TokenSpan;
const FileManager = @import("file_manager.zig");

pub const Module = struct {
    exprs: []const Expr,
};

pub const Identifier = struct {
    name: Token,
};

pub const Range = struct {
    lhs: *Expr,
    rhs: *Expr,
    is_eq: bool,
};

pub const Literal = struct {
    kind: LitKind,
    value: Token,
    
    pub fn create_expr(kind: LitKind, value: Token) Expr {
        return .{
            .span = TokenSpan.from_tokens(value, value),
            .value = .{
                .literal = .{
                    .kind = kind,
                    .value = value,
                },
            },
        };
    }
};

pub const ArrayValue = struct {
    elems: []const Expr,
};

pub const StructValueElem = struct {
    field_name: ?Token,
    value: Expr,
};

pub const StructValue = struct {
    struct_name: ?Token,
    elems: []const StructValueElem,
};

pub const VarDecl = struct {
    decl: Token,
    name: Token,
    typ: ?Type,
    value: ?*Expr,
};

pub const FnDecl = struct {
    is_extern: bool,
    is_public: bool,
    
    name: Token,
    params: []const FnParam,
    return_typ: ?Type,
    block: ?Block,
};

pub const FnParam = struct {
    is_variadic: bool,
    name: Token,
    typ: ?Type,
    default_value: ?*Expr,
};

pub const StructDecl = struct {
    is_public: bool,
    name: Token,
    fields: []const StructField,
    members: []const Expr,
};

pub const StructField = struct {
    name: Token,
    typ: ?Type,
    default_value: ?*Expr,
};

pub const Binary = struct {
    lhs: *Expr,
    rhs: *Expr,
    op: Token,
};

pub const FnCall = struct {
    callee: *Expr,
    args: []const Expr,
};

pub const MemberAccess = struct {
    callee: *Expr,
    member: Token,
};

pub const ArrayIndex = struct {
    callee: *Expr,
    index: *Expr,
};

pub const Block = struct {
    exprs: []const Expr,
    span: TokenSpan,
    
    pub fn toExpr(self: Block) Expr {
        return .{
            .value = .{
                .block = self,
            },
            .span = self.span,            
        };
    }
};

pub const For = struct {
    item_var: ?Token,
    index_var: ?Token,
    iter: *Expr,
    body: *Expr,
};

pub const While = struct {
    condition: *Expr,
    body: *Expr,
};

pub const If = struct {
    condition: *Expr,
    body: *Expr,
    else_expr: ?*Expr,
};

pub const Assignment = struct {
    lhs: *Expr,
    rhs: *Expr,
    op: Token,
};

pub const Intrinsic = struct {};
pub const Return = struct {};

pub const LitKind = enum {
    Int,
    IntBin,
    IntOct,
    IntHex,
    Float,
    String,
    Char,
    True,
    False,
};

pub const Kind = enum {
    identifier,
    range,
    literal,
    array_value,
    struct_value,
    
    var_decl,
    fn_decl,
    struct_decl,
    
    binary,
    fn_call,
    member_access,
    array_index,
    
    block,
    forr,
    whil,
    iff,
    
    assignment,
    intrinsic,
    returns,
};

pub const Expr = struct {
    span: TokenSpan,
    value: union(Kind) {
        identifier: Identifier,
        range: Range,
        literal: Literal,
        array_value: ArrayValue,
        struct_value: StructValue,
        
        var_decl: VarDecl,
        fn_decl: FnDecl,
        struct_decl: StructDecl,
        
        binary: Binary,
        fn_call: FnCall,
        member_access: MemberAccess,
        array_index: ArrayIndex,
        
        block: Block,
        forr: For,
        whil: While,
        iff: If,
        
        assignment: Assignment,
        intrinsic: Intrinsic,
        returns: Return,
    },
};

pub const TypeKind = enum {
    simple,
    array,
    reference,
    pointer,
    nullable,
    tuple,
    generic,
};

pub const Type = struct {
    value: union(TypeKind) {
        simple: struct {
            name: Token,
        },
        array: struct {
            child: *Type,
        },
        reference: struct {
            child: *Type,
        },
        pointer: struct {
            child: *Type,
        },
        nullable: struct {
            child: *Type,
        },
        tuple: struct {
            children: []const Type,
        },
        generic: struct {
            name: Token,
            children: []const Type,
        },
    },
    span: TokenSpan,
};

pub const Printer = struct {
    file_manager: *const FileManager,
    level: usize = 0,
    
    fn print(_: *const Printer, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }
    
    fn indent(self: *const Printer, level: usize) void {
        for (0..level * 4) |_| {
            self.print(" ", .{});
        }
    }
    
    fn indentCurrent(self: *const Printer) void {
        self.indent(self.level);
    }
    
    fn nl(self: *const Printer) void {
        self.print("\n", .{});
    }
    
    fn commaNl(self: *const Printer) void {
        self.print(",\n", .{});
    }
    
    fn tokenText(self: *const Printer, token: Token) []const u8 {
        const src = self.file_manager.getContent(token.loc.file_id);
        return src[token.loc.index..token.loc.index + token.loc.len];
    }
    
    fn blockBegin(self: *Printer, name: []const u8) void {
        self.print("{s} {{\n", .{name});
        self.level += 1;
    }
    
    fn blockEnd(self: *Printer) void {
        self.level -= 1;
        self.indent(self.level);
        self.print("}}", .{});
    }
    
    fn memberBegin(self: *const Printer, name: []const u8) void {
        self.indent(self.level);
        self.print("{s}: ", .{name});
    }
    
    fn memberEnd(self: *const Printer) void {
        self.print(",\n", .{});
    }
    
    fn memberWithValue(self: *const Printer, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.memberBegin(name);
        self.print(fmt, args);
        self.memberEnd();
    }
    
    fn arrayBegin(self: *Printer) void {
        self.print("[\n", .{});
        self.level += 1;
    }
    
    fn arrayEnd(self: *Printer) void {
        self.level -= 1;
        self.indent(self.level);
        self.print("]", .{});
    }
    
    fn arrayEmpty(self: *const Printer) void {
        self.print("[]", .{});
    }
    
    pub fn printModule(self: *Printer, module: *const Module) void {
        self.blockBegin("Module");
        self.memberBegin("exprs");
        self.arrayBegin();
        
        for (module.exprs) |expr| {
            self.indentCurrent();
            self.printExpr(&expr);
            self.commaNl();
        }
        
        self.arrayEnd();
        self.memberEnd();
        self.blockEnd();
        self.nl();
    }
    
    fn printExpr(self: *Printer, expr: *const Expr) void {
        switch (expr.value) {
            Kind.fn_decl => self.printFnDecl(&expr.value.fn_decl),
            Kind.fn_call => self.printFnCall(&expr.value.fn_call),
            Kind.identifier => self.printIdentifier(&expr.value.identifier),
            Kind.literal => self.printLiteral(&expr.value.literal),
            Kind.var_decl => self.printVarDecl(&expr.value.var_decl),
            Kind.assignment => self.printAssignment(&expr.value.assignment),
            Kind.binary => self.printBinary(&expr.value.binary),
            Kind.iff => self.printIf(&expr.value.iff),
            Kind.block => self.printBlock(&expr.value.block),
            Kind.forr => self.printFor(&expr.value.forr),
            Kind.range => self.printRange(&expr.value.range),
            Kind.array_value => self.printArrayValue(&expr.value.array_value),
            Kind.array_index => self.printArrayIndex(&expr.value.array_index),
            Kind.struct_decl => self.printStructDecl(&expr.value.struct_decl),
            Kind.struct_value => self.printStructValue(&expr.value.struct_value),
            Kind.member_access => self.printMemberAccess(&expr.value.member_access),
            
            else => {
                std.debug.panic("Not Implemented : print {s}", .{@tagName(expr.value)});
            }
        }
    }
    
    fn printFnDecl(self: *Printer, fn_decl: *const FnDecl) void {
        self.blockBegin("FnDecl");
        
        self.memberWithValue("name", "'{s}'", .{self.tokenText(fn_decl.name)});
        self.memberWithValue("is_extern", "{}", .{fn_decl.is_extern});
        self.memberWithValue("is_public", "{}", .{fn_decl.is_public});
        
        self.memberBegin("params");
        if (fn_decl.params.len > 0) {
            self.arrayBegin();
            
            for (fn_decl.params) |param| {
                self.indentCurrent();
                self.printFnParam(&param);
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        if (fn_decl.block) |block| {
            self.memberBegin("body");
            self.printBlock(&block);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printFnParam(self: *Printer, fn_param: *const FnParam) void {
        self.blockBegin("FnParam");
        
        self.memberWithValue("is_variadic", "{}", .{fn_param.is_variadic});
        self.memberWithValue("name", "'{s}'", .{self.tokenText(fn_param.name)});
        
        if (fn_param.typ) |typ| {
            self.memberBegin("type");
            self.printType(&typ);
            self.memberEnd();
        }
        
        if (fn_param.default_value) |def_value| {
            _ = def_value;
        }
        
        self.blockEnd();
    }
    
    fn printBlock(self: *Printer, block: *const Block) void {
        self.blockBegin("Block");
        
        self.memberBegin("exprs");
        if (block.exprs.len > 0) {
            self.arrayBegin();
            
            for (block.exprs) |expr| {
                self.indentCurrent();
                self.printExpr(&expr);
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printFor(self: *Printer, forr: *const For) void {
        self.blockBegin("For");
        
        if (forr.item_var) |v| {
            self.memberWithValue("item_var", "'{s}'", .{self.tokenText(v)});
        }
        
        if (forr.index_var) |v| {
            self.memberWithValue("index_var", "'{s}'", .{self.tokenText(v)});
        }
        
        self.memberBegin("iter");
        self.printExpr(forr.iter);
        self.memberEnd();
        
        self.memberBegin("body");
        self.printExpr(forr.body);
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printRange(self: *Printer, rng: *const Range) void {
        self.blockBegin("Range");
        
        self.memberBegin("lhs");
        self.printExpr(rng.lhs);
        self.memberEnd();
        
        self.memberBegin("rhs");
        self.printExpr(rng.rhs);
        self.memberEnd();
        
        self.memberWithValue("is_eq", "{}", .{rng.is_eq});
        
        self.blockEnd();
    }
    
    fn printArrayValue(self: *Printer, arr: *const ArrayValue) void {
        self.blockBegin("ArrayValue");
        
        self.memberBegin("elems");
        if (arr.elems.len > 0) {
            self.arrayBegin();
            
            for (arr.elems) |elem| {
                self.indentCurrent();
                self.printExpr(&elem);
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printArrayIndex(self: *Printer, index: *const ArrayIndex) void {
        self.blockBegin("ArrayIndex");
        
        self.memberBegin("callee");
        self.printExpr(index.callee);
        self.memberEnd();
        
        self.memberBegin("index");
        self.printExpr(index.index);
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printStructDecl(self: *Printer, decl: *const StructDecl) void {
        self.blockBegin("StructDecl");
        
        self.memberWithValue("is_public", "{}", .{decl.is_public});
        self.memberWithValue("name", "'{s}'", .{self.tokenText(decl.name)});
        
        self.memberBegin("fields");
        if (decl.fields.len > 0) {
            self.arrayBegin();
            
            for (decl.fields) |field| {
                self.indentCurrent();
                self.printStructField(&field);
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        self.memberBegin("members");
        if (decl.members.len > 0) {
            self.arrayBegin();
            
            for (decl.members) |member| {
                self.indentCurrent();
                self.printExpr(&member);
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printStructField(self: *Printer, field: *const StructField) void {
        self.blockBegin("StructField");
        
        self.memberWithValue("name", "'{s}'", .{self.tokenText(field.name)});
        
        if (field.typ) |typ| {
            self.memberBegin("type");
            self.printType(&typ);
            self.memberEnd();
        }
        
        if (field.default_value) |default_value| {
            self.memberBegin("type");
            self.printExpr(default_value);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printStructValue(self: *Printer, val: *const StructValue) void {
        self.blockBegin("StructValue");
        
        if (val.struct_name) |name| {
            self.memberWithValue("struct_name", "'{s}'", .{self.tokenText(name)});
        }
        
        self.memberBegin("elems");
        if (val.elems.len > 0) {
            self.arrayBegin();
            
            for (val.elems) |elem| {
                self.indentCurrent();
                self.blockBegin("StructValueElem");
                
                if (elem.field_name) |name| {
                    self.memberWithValue("field_name", "'{s}'", .{self.tokenText(name)});
                }
                
                self.memberBegin("value");
                self.printExpr(&elem.value);
                self.memberEnd();
                
                self.blockEnd();                
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printMemberAccess(self: *Printer, mem: *const MemberAccess) void {
        self.blockBegin("MemberAccess");
        
        self.memberBegin("calleee");
        self.printExpr(mem.callee);
        self.memberEnd();
        
        self.memberWithValue("member", "'{s}'", .{self.tokenText(mem.member)});
        
        self.blockEnd();
    }
    
    fn printVarDecl(self: *Printer, var_decl: *const VarDecl) void {
        self.blockBegin("VarDecl");
        
        self.memberWithValue("decl", "{s}", .{self.tokenText(var_decl.decl)});
        self.memberWithValue("name", "'{s}'", .{self.tokenText(var_decl.name)});
        
        if (var_decl.typ) |typ| {
            self.memberBegin("type");
            self.printType(&typ);
            self.memberEnd();
        }
        
        if (var_decl.value) |value| {
            self.memberBegin("value");
            self.printExpr(value);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printFnCall(self: *Printer, fn_call: *const FnCall) void {
        self.blockBegin("FnCall");
        
        self.memberBegin("callee");
        self.printExpr(fn_call.callee);
        self.memberEnd();
        
        self.memberBegin("args");
        if (fn_call.args.len > 0) {
            self.arrayBegin();
            
            for (fn_call.args) |arg| {
                self.indentCurrent();
                self.printExpr(&arg);
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printIdentifier(self: *Printer, ident: *const Identifier) void {
        self.print("Identifier('{s}')", .{self.tokenText(ident.name)});
    }
    
    fn printLiteral(self: *Printer, lit: *const Literal) void {
        self.print("Lit({s})", .{self.tokenText(lit.value)});
    }
    
    fn printAssignment(self: *Printer, ass: *const Assignment) void {
        self.blockBegin("Assignment");
        
        self.memberBegin("lhs");
        self.printExpr(ass.lhs);
        self.memberEnd();
        
        self.memberBegin("rhs");
        self.printExpr(ass.rhs);
        self.memberEnd();
        
        self.memberWithValue("op", "{s}", .{self.tokenText(ass.op)});
        
        self.blockEnd();
    }
    
    fn printBinary(self: *Printer, bin: *const Binary) void {
        self.blockBegin("Binary");
        
        self.memberWithValue("op", "{s}", .{self.tokenText(bin.op)});
        
        self.memberBegin("lhs");
        self.printExpr(bin.lhs);
        self.memberEnd();
        
        self.memberBegin("rhs");
        self.printExpr(bin.rhs);
        self.memberEnd();
        
        self.blockEnd();
    }
    
    fn printIf(self: *Printer, iff: *const If) void {
        self.blockBegin("If");
        
        self.memberBegin("condition");
        self.printExpr(iff.condition);
        self.memberEnd();
        
        self.memberBegin("body");
        self.printExpr(iff.body);
        self.memberEnd();
        
        if (iff.else_expr) |e| {
            self.memberBegin("else");
            self.printExpr(e);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printType(self: *Printer, typ: *const Type) void {
        switch (typ.value) {
            TypeKind.simple => {
                self.print("{s}", .{self.tokenText(typ.value.simple.name)});
            },
            TypeKind.array => {
                self.print("[]", .{});
                self.printType(typ.value.array.child);
            },
            TypeKind.pointer => {
                self.print("*", .{});
                self.printType(typ.value.pointer.child);
            },
            TypeKind.reference => {
                self.print("&", .{});
                self.printType(typ.value.reference.child);
            },
            TypeKind.nullable => {
                self.print("?", .{});
                self.printType(typ.value.nullable.child);
            },
            TypeKind.tuple => {
                self.print("(", .{});
                
                for (typ.value.tuple.children, 0..) |child, i| {
                    if (i > 0) {
                        self.print(", ", .{});
                    }
                    
                    self.printType(&child);
                }
                
                self.print(")", .{});
            },
            TypeKind.generic => {
                self.print("{s}", .{self.tokenText(typ.value.generic.name)});
                self.print("(", .{});
                
                for (typ.value.generic.children, 0..) |child, i| {
                    if (i > 0) {
                        self.print(", ", .{});
                    }
                    
                    self.printType(&child);
                }
                
                self.print(")", .{});
            },
        }
    }
};