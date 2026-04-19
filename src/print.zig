const std = @import("std");
const Reporter = @import("reporter.zig");
const Chars = @import("lexer.zig").Chars;
const TokenSpan = @import("token.zig").TokenSpan;
const tast = @import("tast.zig");
const ast = @import("ast.zig");
const types = @import("type.zig");

pub fn createPrintParts(
    arena: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    reporter: *const Reporter,
    
    fmt: []const u8,
    args: []const tast.Expr,
    arg_asts: []const ast.Expr,
    span: TokenSpan,
) []const tast.PrintPart {
    var printer = FmtPrinter{
        .arena = arena,
        .temp_allocator = temp_allocator,
        .reporter = reporter,
        
        .chs = Chars.init(fmt),
        .args = args,
        .arg_asts = arg_asts,
        .span = span,
    };
    defer printer.deinit();
    
    printer.format();
    
    return arena.dupe(tast.PrintPart, printer.parts.items) catch unreachable;
}

pub const FmtPrinter = struct {
    arena: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    reporter: *const Reporter,
    
    chs: Chars,
    args: []const tast.Expr,
    arg_asts: []const ast.Expr,
    span: TokenSpan,
    
    parts: std.ArrayList(tast.PrintPart) = .empty,
    cur_str: std.ArrayList(u8) = .empty,
    inside_fmt: bool = false,
    arg_count: usize = 0,
    indent: usize = 0,
    
    fn deinit(self: *FmtPrinter) void {
        self.parts.deinit(self.temp_allocator);
        self.cur_str.deinit(self.temp_allocator);
    }
    
    fn getCurArg(self: *FmtPrinter, increment: bool) *const tast.Expr {
        if (self.args.len <= self.arg_count) {
            self.reporter.reportErrorAtSpan(self.span, "Not enough argument to `print` function", .{});
        }
        
        const res = &self.args[self.arg_count];
        
        if (increment) {
            self.arg_count += 1;
        }
        
        return res;
    }
    
    inline fn pushStringLit(self: *FmtPrinter, str: []const u8) void {
        self.parts.append(self.temp_allocator, .{.literal = str}) catch unreachable;
    }
    
    inline fn appendToCurStr(self: *FmtPrinter, str: []const u8) void {
        self.cur_str.appendSlice(self.temp_allocator, str) catch unreachable;
    }
    
    fn pushStringIfValid(self: *FmtPrinter) void {
        if (self.cur_str.items.len == 0) return;
        
        self.parts.append(self.temp_allocator, .{.literal = self.arena.dupe(u8, self.cur_str.items) catch unreachable}) catch unreachable;
        self.cur_str.clearRetainingCapacity();
    }
    
    fn pushValue(self: *FmtPrinter, fmt: tast.PrintFormat, expr: *const tast.Expr) void {
        self.parts.append(self.temp_allocator, .{.value = .{
            .format = fmt,
            .expr = expr,
        }}) catch unreachable;
    }
    
    fn pushStructValue(self: *FmtPrinter, struc: *const tast.Expr, pretty: bool) void {
        struc.typ.getText(&self.cur_str, self.temp_allocator);
        self.appendToCurStr(" {");
        self.indent += 1;
        
        if (pretty) {
            self.appendToCurStr("\\n");
            
            for (0..self.indent) |_| {
                self.appendToCurStr("    ");
            }
        }
        else {
            self.appendToCurStr(" ");
        }
        
        for (struc.typ.value.@"struct".fields, 0..) |field, i| {
            if (i > 0) {
                self.appendToCurStr(",");
                
                if (pretty) {
                    self.appendToCurStr("\\n");
                    
                    for (0..self.indent) |_| {
                        self.appendToCurStr("    ");
                    }
                }
                else {
                    self.appendToCurStr(" ");
                }
            }
            
            self.appendToCurStr(field.name.text);
            self.appendToCurStr(" = ");
            self.pushStringIfValid();
            
            const mem: tast.Expr = .{
                .typ = field.typ,
                .comptime_known = false,
                .mutability = .immutable,
                .value = .{ .struct_member = .{ .callee = struc, .member_index = i } }
            };
            
            self.pushValueByExpr(self.makeExprPointer(mem), pretty);
        }
        
        self.indent -= 1;
        
        if (pretty) {
            self.appendToCurStr("\\n");
            
            for (0..self.indent) |_| {
                self.appendToCurStr("    ");
            }
        }
        else {
            self.appendToCurStr(" ");
        }
        
        self.appendToCurStr("}");
        self.pushStringIfValid();
    }
    
    fn pushValueByExpr(self: *FmtPrinter, expr: *const tast.Expr, pretty: bool) void {
        switch (expr.typ.kind) {
            .numeric => {
                if (expr.typ.value.numeric.isFloat()) {
                    self.pushValue(.float, expr);
                }
                else {
                    self.pushValue(.int, expr);
                }
            },
            .string => {                
                self.pushValue(.string, expr);
            },
            .bool => {
                self.pushValue(.bool, expr);
            },
            .@"struct" => {
                self.pushStructValue(expr, pretty);
            },
            else => {
                std.debug.panic("TODO: print fmt {s}", .{@tagName(expr.typ.kind)});
            }
        }
    }
    
    fn pushValueByFormat(self: *FmtPrinter, fmt_str: u8, expr: *const tast.Expr, expr_span: TokenSpan) void {
        switch (fmt_str) {
            'c' => {
                if (!expr.typ.isNumericInt()) {
                    self.reporter.reportErrorAtSpan(expr_span, "Expected `int` type, but got `{s}`", .{
                        expr.typ.getTextLeak(self.arena),
                    });
                }
                
                self.pushValue(.char, expr);
            },
            '$' => {
                if (expr.typ.kind != .@"struct") {
                    self.reporter.reportErrorAtSpan(expr_span, "Expected `struct` type, but got `{s}`", .{
                        expr.typ.getTextLeak(self.arena),
                    });
                }
                
                self.pushStructValue(expr, true);
            },
            else => {
                self.reporter.reportErrorAtSpan(self.span, "Unknown print format `{c}`", .{fmt_str});
            },
        }
    }
    
    fn format(self: *FmtPrinter) void {        
        while (self.chs.hasNext()) {
            const c = self.chs.next();
            
            if (!self.inside_fmt) {
                if (c == '{') {
                    self.pushStringIfValid();
                    
                    if (self.chs.peek() == '}') {
                        _ = self.chs.next();
                        self.pushValueByExpr(self.getCurArg(true), false);
                    }
                    else if (self.chs.peek() == ':') {
                        _ = self.chs.next();
                        const fc = self.chs.next();
                        
                        if (fc == '}') {
                            self.reporter.reportErrorAtSpan(self.span, "Print format needed : `{{:<format>}}`", .{});
                        }
                        else if (self.chs.next() != '}') {
                            self.reporter.reportErrorAtSpan(self.span, "Expected print format close symbol `}}`", .{});
                        }
                        
                        const span = self.arg_asts[self.arg_count].span;
                        self.pushValueByFormat(fc, self.getCurArg(true), span);
                    }
                    else {
                        self.inside_fmt = true;
                    }
                }
                else {
                    self.cur_str.append(self.temp_allocator, c) catch unreachable;
                }
            }
            else {
                std.debug.panic("TODO: print fmt custom format", .{});
            }
        }
        
        self.pushStringIfValid();
        
        if (self.args.len > self.arg_count) {
            self.reporter.reportErrorAtSpan(self.span, "Excess argument to `print` function", .{});
        }
    }
    
    fn makeExprPointer(self: *FmtPrinter, expr: tast.Expr) *tast.Expr {
        const p = self.arena.create(tast.Expr) catch unreachable;
        p.* = expr;
        
        return p;
    }
};