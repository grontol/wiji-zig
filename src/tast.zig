const std = @import("std");
const types = @import("type.zig");
const Symbol = @import("symbol.zig").Symbol;
const Type = types.Type;

pub const Module = struct {
    fn_decls: []const FnDecl,
};

pub const Block = struct {
    stmts: []const Stmt,
};

pub const VarDecl = struct {
    name: Symbol,
    value: ?*Expr,
    typ: *const Type,
};

pub const Assignment = struct {
    lhs: *Expr,
    rhs: *Expr,
    op: enum {
        eq,
        plus_eq,
        minus_eq,
        mul_eq,
        div_eq,
        mod_eq,
    },
};

pub const FnParam = struct {
    name: Symbol,
    default_value: ?*Expr,
    typ: *const Type,
};

pub const FnDecl = struct {
    is_extern: bool,
    is_public: bool,
    name: Symbol,
    params: []const FnParam,
    return_typ: *const Type,
    body: ?Block,
};

pub const FnCall = struct {
    callee: *Expr,
    args: []const Expr,
    return_typ: *const Type,
};

pub const If = struct {
    condition: *Expr,
    body: *Block,
    else_stmt: ?*Stmt,
};

pub const Return = struct {
    value: ?*Expr,
};

pub const Identifier = struct {
    name: Symbol,
};

pub const LiteralKind = enum {
    int,
    float,
    string,
    char,
    bool,
};

pub const Literal = union(LiteralKind) {
    int: u64,
    float: f64,
    string: []const u8,
    char: u8,
    bool: bool,
};

pub const StmtKind = enum {
    module,
    block,
    var_decl,
    assignment,
    fn_call,
    iff,
    for_range,
    whil,
    returns,
};

pub const Stmt = union(StmtKind) {
    module: Module,
    block: Block,
    var_decl: VarDecl,
    assignment: Assignment,
    fn_call: FnCall,
    iff: If,
    for_range,
    whil,
    returns: Return,
};

pub const ExprKind = enum {
    identifier,
    literal,
    binary,
    fn_call,
    range,
    array_value,
    array_index,
    struct_value,
    struct_member,
    cast,
};

pub const Expr = struct {
    value: union(ExprKind) {
        identifier: Identifier,
        literal: Literal,
        binary,
        fn_call,
        range,
        array_value,
        array_index,
        struct_value,
        struct_member,
        cast,
    },
    typ: *const Type,
};

pub const Printer = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,
    temp_text: std.ArrayList(u8) = .empty,
    
    level: usize = 0,
    
    pub fn init() Printer {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        
        return .{
            .gpa = gpa,
            .allocator = gpa.allocator(),
        };
    }
    
    fn print(_: *const Printer, comptime fmt: []const u8, args: anytype) void {
        std.debug.print(fmt, args);
    }
    
    fn getTypeText(self: *Printer, typ: *const Type) []const u8 {
        self.temp_text.clearRetainingCapacity();
        
        typ.getText(&self.temp_text, self.allocator);
        
        return self.temp_text.items;
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
        self.memberBegin("fn_decls");
        self.arrayBegin();
        
        for (module.fn_decls) |fn_decl| {
            self.indentCurrent();
            self.printFnDecl(&fn_decl);
            self.commaNl();
        }
        
        self.arrayEnd();
        self.memberEnd();
        self.blockEnd();
        self.nl();
    }
    
    fn printFnDecl(self: *Printer, fn_decl: *const FnDecl) void {
        self.blockBegin("FnDecl");
        
        self.memberWithValue("is_extern", "{}", .{fn_decl.is_extern});
        self.memberWithValue("is_public", "{}", .{fn_decl.is_public});
        self.memberWithValue("name", "'{s}'", .{fn_decl.name.text});
        
        self.memberBegin("params");
        if (fn_decl.params.len > 0) {
            self.arrayBegin();
            
            for (fn_decl.params) |param| {
                self.indentCurrent();
                self.blockBegin("FnParam");
                
                self.memberWithValue("name", "'{s}'", .{param.name.text});
                self.memberWithValue("type", "{s}", .{self.getTypeText(param.typ)});
                
                if (param.default_value) |param_def_value| {
                    self.memberBegin("default_value");
                    self.printExpr(param_def_value);
                    self.memberEnd();
                }
                
                self.blockEnd();
                self.commaNl();
            }
            
            self.arrayEnd();
        }
        else {
            self.arrayEmpty();
        }
        self.memberEnd();
        
        if (fn_decl.body) |body| {
            self.memberBegin("body");
            self.printBlock(&body);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printBlock(self: *Printer, block: *const Block) void {
        self.blockBegin("Block");
        
        self.memberBegin("stmts");
        if (block.stmts.len > 0) {
            self.arrayBegin();
            
            for (block.stmts) |stmt| {
                self.indentCurrent();
                self.printStmt(&stmt);
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
    
    fn printStmt(self: *Printer, stmt: *const Stmt) void {
        switch (stmt.*) {
            StmtKind.var_decl => { self.printVarDecl(&stmt.var_decl); },
            StmtKind.returns => { self.printReturn(&stmt.returns); },
            else => {
                std.debug.panic("TODO: printStmt {s}", .{@tagName(stmt.*)});
            }
        }
    }
    
    fn printVarDecl(self: *Printer, var_decl: *const VarDecl) void {
        self.blockBegin("VarDecl");
        
        self.memberWithValue("name", "'{s}'", .{var_decl.name.text});
        self.memberWithValue("type", "{s}", .{self.getTypeText(var_decl.typ)});
        
        if (var_decl.value) |value| {
            self.memberBegin("value");
            self.printExpr(value);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printReturn(self: *Printer, ret: *const Return) void {
        self.blockBegin("Return");
        
        if (ret.value) |value| {
            self.memberBegin("value");
            self.printExpr(value);
            self.memberEnd();
        }
        
        self.blockEnd();
    }
    
    fn printExpr(self: *Printer, expr: *const Expr) void {
        self.print("<{s}>", .{self.getTypeText(expr.typ)});
        
        switch (expr.value) {
            .literal => |lit| { self.printLiteral(&lit); },
            .identifier => |ident| { self.print("Identifier('{s}')", .{ident.name.text}); },
            else => {
                std.debug.panic("TODO: printExpr {s}", .{@tagName(expr.value)});
            }
        }
    }
    
    fn printLiteral(self: *Printer, lit: *const Literal) void {
        switch (lit.*) {
            .int => |v| { self.print("{}", .{v}); },
            .float => |v| { self.print("{}", .{v}); },
            .string => |v| { self.print("\"{s}\"", .{v}); },
            .char => |v| {
                const ch = switch (v) {
                    '\n' => "\\n",
                    '\r' => "\\r",
                    '\t' => "\\t",
                    '\'' => "\\'",
                    '\\' => "\\\\",
                    else => &.{v},
                };
                
                self.print("'{s}'", .{ch});
            },
            .bool => |v| { self.print("{}", .{v}); },
        }
    }
};