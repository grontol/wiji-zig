const std = @import("std");
const Token = @import("token.zig").Token;
const TokenSpan = @import("token.zig").TokenSpan;
const TokenKind = @import("token.zig").TokenKind;
const FileManager = @import("file_manager.zig");
const Reporter = @import("reporter.zig");
const ast = @import("ast.zig");

const precedence_map = blk: {
    var res = std.EnumMap(TokenKind, usize){};
    res.put(.OrOr, 3);
    res.put(.AndAnd, 3);
    res.put(.Gt, 9);
    res.put(.Gte, 9);
    res.put(.Lt, 9);
    res.put(.Lte, 9);
    res.put(.EqEq, 9);
    res.put(.NotEq, 9);
    res.put(.Plus, 11);
    res.put(.Minus, 11);
    res.put(.Mod, 12);
    res.put(.Mul, 12);
    res.put(.Div, 12);
    
    res.put(.PlusPlus, 100);
    res.put(.MulMul, 101);
    
    break :blk res;
};

const TokenStream = struct {
    reporter: *const Reporter,
    tokens: []const Token,
    eof_token: Token,
    current_index: usize,
    mark_index: usize,
    
    fn init(reporter: *const Reporter, tokens: []const Token) TokenStream {
        return .{
            .reporter = reporter,
            .tokens = tokens,
            .eof_token = Token.default(),
            .current_index = 0,
            .mark_index = 0,
        };
    }
    
    fn hasNext(self: *const TokenStream) bool {
        return self.current_index < self.tokens.len;
    }
    
    fn next(self: *TokenStream) Token {
        if (self.hasNext()) {
            self.current_index += 1;
            return self.tokens[self.current_index - 1];
        }
        else {
            self.current_index += 1;
            return self.eof_token;
        }
    }
    
    fn peek(self: *const TokenStream) Token {
        return self.peekN(1);
    }
    
    fn peekN(self: *const TokenStream, n: usize) Token {
        if (self.current_index + n < 0 or self.current_index + n - 1 >= self.tokens.len) {
            return self.eof_token;
        }
        else {
            return self.tokens[self.current_index + n - 1];
        }
    }
    
    fn nextExpect(self: *TokenStream, kind: TokenKind) Token {
        if (self.peek().kind == kind) {
            return self.next();
        }
        else {
            const next_token = self.next();
            self.reporter.reportErrorAtToken(next_token, "Expected `{s}` but got `{s}`", .{
                @tagName(kind),
                @tagName(next_token.kind),
            });
        }
    }
    
    fn nextExpectAny(self: *TokenStream, kinds: []const TokenKind) Token {
        const peek_token = self.peek();
        
        for (kinds) |kind| {
            if (peek_token.kind == kind) {
                return self.next();
            }
        }
        
        // No need to free. Will exit anyway
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        var str = std.ArrayList(u8).empty;
        
        for (kinds, 0..) |kind, i| {
            if (i > 0) {
                str.appendSlice(allocator, " | ") catch unreachable;
            }
            
            str.appendSlice(allocator, @tagName(kind)) catch unreachable;
        }
        
        self.reporter.reportErrorAtToken(peek_token, "Expected `{s}` but got `{s}`", .{
            str.items,
            @tagName(peek_token.kind),
        });
    }
    
    fn current(self: *const TokenStream) Token {
        if (self.current_index == 0) {
            return self.eof_token;
        }
        
        return self.peekN(0);
    }
    
    fn mark(self: *TokenStream) void {
        self.mark_index = self.current_index;
    }
    
    fn restore(self: *TokenStream) void {
        self.current_index = self.mark_index;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    file_manager: *const FileManager,
    reporter: *const Reporter,
    ts: TokenStream,
    
    imports: std.ArrayList(ast.Import) = .empty,
    
    fn init(
        allocator: std.mem.Allocator,
        temp_allocator: std.mem.Allocator,
        file_manager: *const FileManager,
        reporter: *const Reporter,
        tokens: []const Token,
    ) Parser {
        return .{
            .allocator = allocator,
            .temp_allocator = temp_allocator,
            .file_manager = file_manager,
            .reporter = reporter,
            .ts = TokenStream.init(reporter, tokens),
        };
    }
    
    fn hasFnNext(self: *Parser) bool {
        var res = false;
        self.ts.mark();
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.KeywordExtern,
                TokenKind.KeywordPub => _ = self.ts.next(),
                TokenKind.KeywordFn => {
                    res = true;
                    break;
                },
                else => break,
            }
        }
        
        self.ts.restore();
        
        return res;
    }
    
    fn hasVarDeclNext(self: *Parser) bool {
        var res = false;
        self.ts.mark();
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.KeywordPub => _ = self.ts.next(),
                TokenKind.KeywordVal,
                TokenKind.KeywordVar,
                TokenKind.KeywordConst => {
                    res = true;
                    break;
                },
                else => break,
            }
        }
        
        self.ts.restore();
        
        return res;
    }
    
    fn hasStructNext(self: *Parser) bool {
        var res = false;
        self.ts.mark();
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.KeywordPub => _ = self.ts.next(),
                TokenKind.KeywordStruct => {
                    res = true;
                    break;
                },
                else => break,
            }
        }
        
        self.ts.restore();
        
        return res;
    }
    
    fn hasEnumNext(self: *Parser) bool {
        var res = false;
        self.ts.mark();
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.KeywordPub => _ = self.ts.next(),
                TokenKind.KeywordEnum => {
                    res = true;
                    break;
                },
                else => break,
            }
        }
        
        self.ts.restore();
        
        return res;
    }
    
    fn hasImplNext(self: *Parser) bool {
        var res = false;
        self.ts.mark();
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.KeywordPub => _ = self.ts.next(),
                TokenKind.KeywordImpl => {
                    res = true;
                    break;
                },
                else => break,
            }
        }
        
        self.ts.restore();
        
        return res;
    }
    
    fn parseModule(self: *Parser) ast.Module {
        var exprs: std.ArrayList(ast.Expr) = .empty;
        
        while (self.ts.hasNext()) {
            const expr = self.parseExpr();
            exprs.append(self.temp_allocator, expr) catch unreachable;
        }
        
        return .{
            .exprs = self.collectAndFreeTempList(ast.Expr, &exprs),
            .imports = self.imports.items,
        };
    }
    
    fn parseExpr(self: *Parser) ast.Expr {
        var expr = self.parsePrimaryExpr();
        
        if (self.ts.peek().kind.is_assignment()) {
            const op_token = self.ts.next();
            const rhs = self.parseExpr();
            
            expr = ast.Expr{
                .value = .{.assignment = .{
                    .lhs = self.makeExprPointer(expr),
                    .rhs = self.makeExprPointer(rhs),
                    .op = op_token,
                }},
                .span = TokenSpan.from_spans(expr.span, rhs.span),
            };
        }
        else if (self.ts.peek().kind.is_binop()) {
            var exprs = std.ArrayList(ast.Expr).empty;
            var ops = std.ArrayList(Token).empty;
            
            exprs.append(self.temp_allocator, expr) catch unreachable;
            
            while (self.ts.peek().kind.is_binop()) {
                const op = self.ts.next();
                const rhs = self.parsePrimaryExpr();
                
                ops.append(self.temp_allocator, op) catch unreachable;
                exprs.append(self.temp_allocator, rhs) catch unreachable;
            }
            
            while (exprs.items.len > 1) {
                var index: usize = 0;
                
                for (0..ops.items.len - 1) |i| {
                    const l_prec = precedence_map.get(ops.items[i].kind).?;
                    const r_prec = precedence_map.get(ops.items[i + 1].kind).?;
                    
                    if (l_prec >= r_prec) {
                        index = i;
                        break;
                    }
                    else {
                        index = i + 1;
                    }
                }
                
                const lhs = exprs.orderedRemove(index);
                const rhs = exprs.orderedRemove(index);
                const op = ops.orderedRemove(index);
                
                const new_expr: ast.Expr = .{
                    .value = .{.binary = .{
                        .lhs = self.makeExprPointer(lhs),
                        .rhs = self.makeExprPointer(rhs),
                        .op = op,
                    }},
                    .span = TokenSpan.from_spans(lhs.span, rhs.span),
                };
                
                exprs.insert(self.temp_allocator, index, new_expr) catch unreachable;
            }
            
            expr = exprs.items[0];
            exprs.clearAndFree(self.temp_allocator);
            ops.clearAndFree(self.temp_allocator);
        }
        // else if (self.ts.peek().kind == .DotDot) {
        //     expr = self.parseRange(expr);
        // }
        // else if (self.ts.peek().kind == .KeywordAs) {
        //     expr = self.parseCast(expr);
        // }
        
        return expr;
    }
    
    fn parsePrimaryExpr(self: *Parser) ast.Expr {
        const token = self.ts.peek();
        var expr: ast.Expr = undefined;
        
        switch (token.kind) {
            TokenKind.IntLit,
            TokenKind.IntBinLit,
            TokenKind.IntOctLit,
            TokenKind.IntHexLit,
            TokenKind.FloatLit,
            TokenKind.StringLit,
            TokenKind.CstringLit,
            TokenKind.CharLit,
            TokenKind.Identifier,
            TokenKind.TrueLit,
            TokenKind.FalseLit => {
                switch (token.kind) {
                    TokenKind.IntLit     => { expr = ast.Literal.create_expr(ast.LitKind.Int, self.ts.next()); },
                    TokenKind.IntBinLit  => { expr = ast.Literal.create_expr(ast.LitKind.IntBin, self.ts.next()); },
                    TokenKind.IntOctLit  => { expr = ast.Literal.create_expr(ast.LitKind.IntOct, self.ts.next()); },
                    TokenKind.IntHexLit  => { expr = ast.Literal.create_expr(ast.LitKind.IntHex, self.ts.next()); },
                    TokenKind.FloatLit   => { expr = ast.Literal.create_expr(ast.LitKind.Float, self.ts.next()); },
                    TokenKind.StringLit  => { expr = ast.Literal.create_expr(ast.LitKind.String, self.ts.next()); },
                    TokenKind.CstringLit => { expr = ast.Literal.create_expr(ast.LitKind.Cstring, self.ts.next()); },
                    TokenKind.CharLit    => { expr = ast.Literal.create_expr(ast.LitKind.Char, self.ts.next()); },
                    TokenKind.TrueLit    => { expr = ast.Literal.create_expr(ast.LitKind.True, self.ts.next()); },
                    TokenKind.FalseLit   => { expr = ast.Literal.create_expr(ast.LitKind.False, self.ts.next()); },
                    
                    TokenKind.Identifier => {
                        if (self.ts.peekN(2).kind == .Dot and self.ts.peekN(3).kind == .OpenCurlyBracket) {
                            expr = self.parseStructValue();
                        }
                        else {
                            const name_token = self.ts.next();
                            
                            expr = ast.Expr{
                                .value = .{
                                    .identifier = .{
                                        .name = name_token,
                                    }
                                },
                                .span = TokenSpan.from_token(name_token),
                            };
                        }
                    },
                    
                    else => unreachable,
                }
                
                while (self.ts.hasNext()) {
                    switch (self.ts.peek().kind) {
                        TokenKind.OpenParen => {
                            if (!self.ts.peek().has_nl_before) {
                                expr = self.parseFnCall(expr);
                            }
                            else {
                                break;
                            }
                        },
                        TokenKind.Dot => expr = self.parseMemberAccess(expr),
                        TokenKind.OpenSqBracket => expr = self.parseArrayIndex(expr),
                        TokenKind.Lt => {
                            const ex = self.tryParseGeneric(expr);
                            
                            if (ex) |e| {
                                expr = e;
                            }
                            else {
                                break;
                            }
                        },
                        else => break,
                    }
                }
            },
            
            TokenKind.KeywordFn => expr = self.parseFnDecl(null, false),
            TokenKind.KeywordStruct => expr = self.parseStructDecl(),
            TokenKind.KeywordEnum => expr = self.parseEnumDecl(),
            TokenKind.KeywordImpl => expr = self.parseImplDecl(),
            TokenKind.KeywordPub => {
                if (self.hasFnNext()) {
                    expr = self.parseFnDecl(null, false);
                }
                else if (self.hasVarDeclNext()) {
                    expr = self.parseVarDecl();
                }
                else if (self.hasStructNext()) {
                    expr = self.parseStructDecl();
                }
                else if (self.hasEnumNext()) {
                    expr = self.parseEnumDecl();
                }
                else if (self.hasImplNext()) {
                    expr = self.parseImplDecl();
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.peekN(2), "Invalid pub modifier", .{});
                }
            },
            TokenKind.KeywordExtern => {
                const extern_token = self.ts.peek();
                const extern_ = self.parseExtern();
                
                if (self.hasFnNext()) {
                    expr = self.parseFnDecl(extern_, false);
                }
                else {
                    self.reporter.reportErrorAtToken(extern_token, "extern modifier can only be applied to function", .{});
                }
            },
            TokenKind.KeywordFor => expr = self.parseFor(),
            TokenKind.KeywordWhile => expr = self.parseWhile(),
            TokenKind.KeywordBreak => expr = self.parseBreak(),
            TokenKind.KeywordIf => expr = self.parseIf(),
            TokenKind.KeywordSwitch => expr = self.parseSwitch(),
            TokenKind.KeywordVal,
            TokenKind.KeywordVar,
            TokenKind.KeywordConst => expr = self.parseVarDecl(),
            TokenKind.OpenCurlyBracket => expr = self.parseBlock().toExpr(),
            TokenKind.OpenParen => {
                _ = self.ts.next();
                expr = self.parseExpr();
                _ = self.ts.nextExpect(.CloseParen);
            },
            TokenKind.Dot => {
                if (self.ts.peekN(2).kind == .OpenCurlyBracket) {
                    expr = self.parseStructValue();
                }
                else if (self.ts.peekN(2).kind == .OpenSqBracket) {
                    expr = self.parseArrayValue();
                }
                else if (self.ts.peekN(2).kind == .Identifier) {
                    expr = self.parseEnumValue();
                }
                else if (self.ts.peekN(2).kind == .OpenParen) {
                    std.debug.panic("TODO: Parse tuple value", .{});
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.next(), "Invalid dot", .{});
                }
            },
            TokenKind.At => {
                const peek2 = self.ts.peekN(2);
                
                if (std.mem.eql(u8, self.getTokenText(peek2), "builtin")) {
                    _ = self.ts.next();
                    _ = self.ts.next();
                    
                    if (self.hasFnNext()) {
                        expr = self.parseFnDecl(null, true);
                    }
                    else {
                        self.reporter.reportErrorAtToken(peek2, "@builtin modifier can only be applied to function", .{});
                    }
                }
                else {
                    expr = self.parseIntinsic();
                }
            },
            TokenKind.KeywordReturn => { expr = self.parseReturn(); },
            TokenKind.KeywordContinue => { expr = self.parseContinue(); },
            TokenKind.Not,
            TokenKind.Minus => { expr = self.parseUnary(); },
            TokenKind.And => { expr = self.parseAddressOf(); },
            TokenKind.KeywordImport => { expr = self.parseImport(); },
            
            TokenKind.Semicolon => {
                self.reporter.reportErrorAtToken(self.ts.next(), "The languange doesn't use semicolon, please remove it", .{});
            },
            
            else => {
                self.reporter.reportErrorAtToken(token, "Unexpected token `{s}`", .{self.getTokenText(token)});
            },
        }
        
        switch (self.ts.peek().kind) {
            TokenKind.DotDot,
            TokenKind.DotDotDot => expr = self.parseRange(expr),
            TokenKind.KeywordAs => expr = self.parseCast(expr),
            else => {}
        }
        
        return expr;
    }
    
    fn parseFnDecl(self: *Parser, extern_: ?ast.Extern, builtin: bool) ast.Expr {
        var extern_name: ?[]const u8 = null;
        var extern_abi: ?[]const u8 = null;        
        var public_token: ?Token = null;
        
        if (extern_) |ext| {
            if (ext.name) |name| {
                const name_text = self.getTokenText(name);
                const name_without_quote = name_text[1..name_text.len - 1];
                extern_name = self.allocator.dupe(u8, name_without_quote) catch unreachable;
            }
            
            if (ext.abi) |abi| {
                const abi_text = self.getTokenText(abi);
                const abi_without_quote = abi_text[1..abi_text.len - 1];
                extern_abi = self.allocator.dupe(u8, abi_without_quote) catch unreachable;
            }
        }
        
        if (self.ts.peek().kind == .KeywordPub) {
            public_token = self.ts.next();
        }
        
        const fn_token = self.ts.nextExpect(.KeywordFn);
        const name_token = self.ts.nextExpect(.Identifier);
        var type_params: std.ArrayList(Token) = .empty;
        
        if (self.ts.peek().kind == .Lt) {
            _ = self.ts.next();
            
            if (self.ts.peek().kind == .Gt) {
                self.reporter.reportErrorAtSpan(
                    TokenSpan.from_tokens(self.ts.current(), self.ts.next()),
                    "Expected at least 1 type param",
                    .{}
                );
            }
            
            var has_comma = true;
            
            while (self.ts.hasNext()) {
                if (self.ts.peek().kind == .Gt) {
                    _ = self.ts.next();
                    break;
                }
                
                if (!has_comma) {
                    self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
                }
                
                type_params.append(self.temp_allocator, self.ts.nextExpect(.Identifier)) catch unreachable;
                
                if (self.ts.peek().kind == .Comma) {
                    _ = self.ts.next();
                    has_comma = true;
                }
                else {
                    has_comma = false;
                }
            }
        }
        
        _ = self.ts.nextExpect(.OpenParen);
        
        var params: std.ArrayList(ast.FnParam) = .empty;
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseParen) {
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
            }
            
            var is_variadic = false;
            
            if (self.ts.peek().kind == .DotDotDot) {
                _ = self.ts.next();
                is_variadic = true;
            }
            
            const param_name_token = self.ts.nextExpect(.Identifier);
            var param_type: ?ast.Type = null;
            var param_default_value: ?*ast.Expr = null;
            
            if (self.ts.peek().kind == .Colon) {
                _ = self.ts.next();
                param_type = self.parseType();
            }
            
            if (self.ts.peek().kind == .Eq) {
                _ = self.ts.next();
                param_default_value = self.makeExprPointer(self.parseExpr());
            }
            
            if (param_type == null and param_default_value == null) {
                self.reporter.reportErrorAtToken(param_name_token, "Expected type or default value", .{});
            }
            
            params.append(self.temp_allocator, ast.FnParam{
                .is_variadic = is_variadic,
                .name = param_name_token,
                .typ = param_type,
                .default_value = param_default_value,
            }) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        const close_paren_token = self.ts.nextExpect(.CloseParen);
        
        var return_typ: ?ast.Type = null;
        if (self.ts.peek().kind == .Colon) {
            _ = self.ts.next();
            return_typ = self.parseType();
        }
        
        var body: ?ast.Block = null;
        if (self.ts.peek().kind == .OpenCurlyBracket) {
            body = self.parseBlock();
        }
        
        if (body != null) {
            if (extern_ != null) {
                self.reporter.reportErrorAtToken(name_token, "extern function cannot have a body", .{});
            }
            else if (builtin) {
                self.reporter.reportErrorAtToken(name_token, "builtin function cannot have a body", .{});
            }
        }
        
        const start_token = public_token orelse fn_token;
        
        const span = if (extern_) |ext| blk: {
            break :blk if (body) |b| TokenSpan.from_spans(ext.span, b.span)
            else TokenSpan.from_span_and_token(ext.span, close_paren_token);
        }
        else blk: {
            break :blk if (body) |b| TokenSpan.from_token_and_span(start_token, b.span)
            else TokenSpan.from_tokens(start_token, close_paren_token);
        };
        
        return ast.Expr{
            .value = .{
                .fn_decl = .{
                    .is_extern = extern_ != null,
                    .is_builtin = builtin,
                    .extern_name = extern_name,
                    .extern_abi = extern_abi,
                    .is_public = public_token != null,
                    .name = name_token,
                    .params = self.collectAndFreeTempList(ast.FnParam, &params),
                    .type_params = self.collectAndFreeTempList(Token, &type_params),
                    .return_typ = return_typ,
                    .body = body,
                },
            },
            .span = span,
        };
    }
    
    fn parseReturn(self: *Parser) ast.Expr {
        const return_token = self.ts.nextExpect(.KeywordReturn);
        var value: ?*ast.Expr = null;
        
        if (!self.ts.peek().has_nl_before) {
            value = self.makeExprPointer(self.parseExpr());
        }
        
        return .{
            .span = if (value) |v| TokenSpan.from_token_and_span(return_token, v.span) else TokenSpan.from_token(return_token),
            .value = .{.returns = .{
                .value = value,
            }},
        };
    }
    
    fn parseContinue(self: *Parser) ast.Expr {
        const continue_token = self.ts.nextExpect(.KeywordContinue);
        
        return .{
            .span = TokenSpan.from_token(continue_token),
            .value = .continues,
        };
    }
    
    fn parseStructDecl(self: *Parser) ast.Expr {
        var pub_token: ?Token = null;
        
        if (self.ts.peek().kind == .KeywordPub) {
            pub_token = self.ts.next();
        }
        
        const struct_token = self.ts.nextExpect(.KeywordStruct);
        
        var name_token: ?Token = null;
        
        if (self.ts.peek().kind == .Identifier) {
            name_token = self.ts.next();
        }
        
        var type_params = std.ArrayList(Token).empty;
        
        if (self.ts.peek().kind == .Lt) {
            _ = self.ts.next();
            
            if (self.ts.peek().kind == .Gt) {
                self.reporter.reportErrorAtSpan(
                    TokenSpan.from_tokens(self.ts.current(), self.ts.next()),
                    "Expected at least 1 type param",
                    .{}
                );
            }
            
            var has_comma = true;
            
            while (self.ts.hasNext()) {
                if (self.ts.peek().kind == .Gt) {
                    _ = self.ts.next();
                    break;
                }
                
                if (!has_comma) {
                    self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
                }
                
                type_params.append(self.temp_allocator, self.ts.nextExpect(.Identifier)) catch unreachable;
                
                if (self.ts.peek().kind == .Comma) {
                    _ = self.ts.next();
                    has_comma = true;
                }
                else {
                    has_comma = false;
                }
            }
        }
        
        _ = self.ts.nextExpect(.OpenCurlyBracket);
        
        var fields = std.ArrayList(ast.StructField).empty;
        var members = std.ArrayList(ast.Expr).empty;
        
        while (self.ts.hasNext()) {
            var is_field = false;
            
            switch (self.ts.peek().kind) {
                TokenKind.CloseCurlyBracket => break,
                TokenKind.KeywordUsing => {
                    if (self.ts.peekN(2).kind == .Identifier and (self.ts.peekN(3).kind == .Colon or self.ts.peekN(3).kind == .Eq)) {
                        is_field = true;
                    }
                    else {
                        self.reporter.reportErrorAtToken(self.ts.peek(), "`using` must be followed by field declaration", .{});
                    }
                },
                TokenKind.Identifier => {
                    if (self.ts.peekN(2).kind == .Colon or self.ts.peekN(2).kind == .Eq) {
                        is_field = true;                        
                    }
                },
                else => {}
            }
            
            if (is_field) {
                var using_token: ?Token = null;
                    
                if (self.ts.peek().kind == .KeywordUsing) {
                    using_token = self.ts.next();
                }
                
                const field_name_token = self.ts.nextExpect(.Identifier);
                var field_typ: ?ast.Type = null;
                var field_default_value: ?*ast.Expr = null;
                
                if (self.ts.peek().kind == .Colon) {
                    _ = self.ts.next();
                    field_typ = self.parseType();
                }
                
                if (self.ts.peek().kind == .Eq) {
                    _ = self.ts.next();
                    field_default_value = self.makeExprPointer(self.parseExpr());
                }
                
                if (field_typ == null and field_default_value == null) {
                    self.reporter.reportErrorAtToken(field_name_token, "Expected type or default value", .{});
                }
                
                fields.append(self.temp_allocator, ast.StructField{
                    .name = field_name_token,
                    .typ = field_typ,
                    .default_value = field_default_value,
                    .using = using_token,
                }) catch unreachable;
                
                if (self.ts.peek().kind == .Comma) {
                    _ = self.ts.next();
                }
            }
            else {
                members.append(self.temp_allocator, self.parseContainerMember()) catch unreachable;
            }
        }
        
        const close_bracket_token = self.ts.nextExpect(.CloseCurlyBracket);
        
        return .{
            .span = TokenSpan.from_tokens(pub_token orelse struct_token, close_bracket_token),
            .value = .{.struct_decl = .{
                .is_public = pub_token != null,
                .name = name_token,
                .type_params = self.collectAndFreeTempList(Token, &type_params),
                .struct_token = struct_token,
                .fields = self.collectAndFreeTempList(ast.StructField, &fields),
                .members = self.collectAndFreeTempList(ast.Expr, &members),
            }},
        };
    }
    
    fn parseEnumDecl(self: *Parser) ast.Expr {
        var pub_token: ?Token = null;
        
        if (self.ts.peek().kind == .KeywordPub) {
            pub_token = self.ts.next();
        }
        
        const enum_token = self.ts.nextExpect(.KeywordEnum);
        
        var name_token: ?Token = null;
        
        if (self.ts.peek().kind == .Identifier) {
            name_token = self.ts.nextExpect(.Identifier);
        }
        
        _ = self.ts.nextExpect(.OpenCurlyBracket);
        
        var items = std.ArrayList(Token).empty;
        var members = std.ArrayList(ast.Expr).empty;
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.CloseCurlyBracket => break,
                TokenKind.Identifier => {
                    items.append(self.temp_allocator, self.ts.nextExpect(.Identifier)) catch unreachable;
                
                    if (self.ts.peek().kind == .Comma) {
                        _ = self.ts.next();
                    }
                    else {
                        self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma", .{});
                    }
                },
                else => {
                    members.append(self.temp_allocator, self.parseContainerMember()) catch unreachable;
                }
            }
        }
        
        const close_curly_token = self.ts.nextExpect(.CloseCurlyBracket);
        
        return .{
            .span = TokenSpan.from_tokens(pub_token orelse enum_token, close_curly_token),
            .value = .{.enum_decl = .{
                .is_public = pub_token != null,
                .name = name_token,
                .enum_token = enum_token,
                .items = self.collectAndFreeTempList(Token, &items),
                .members = self.collectAndFreeTempList(ast.Expr, &members),
            }},
        };
    }
    
    fn parseImplDecl(self: *Parser) ast.Expr {
        var pub_token: ?Token = null;
        
        if (self.ts.peek().kind == .KeywordPub) {
            pub_token = self.ts.next();
        }
        
        const impl_token = self.ts.nextExpect(.KeywordImpl);
        const typ = self.parseType();
        
        _ = self.ts.nextExpect(.OpenCurlyBracket);
        
        var fields = std.ArrayList(ast.ImplField).empty;
        var members = std.ArrayList(ast.Expr).empty;
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.CloseCurlyBracket => break,
                TokenKind.Identifier => {
                    if (self.ts.peekN(2).kind == .Colon) {
                        const field_name_token = self.ts.nextExpect(.Identifier);
                        _ = self.ts.nextExpect(.Colon);
                        const field_typ = self.parseType();
                        
                        fields.append(self.temp_allocator, ast.ImplField{
                            .name = field_name_token,
                            .typ = field_typ,
                        }) catch unreachable;
                        
                        if (self.ts.peek().kind == .Comma) {
                            _ = self.ts.next();
                        }
                    }
                },
                else => {
                    members.append(self.temp_allocator, self.parseContainerMember()) catch unreachable;
                }
            }
        }
        
        const close_curly_token = self.ts.nextExpect(.CloseCurlyBracket);
        
        return .{
            .span = TokenSpan.from_tokens(pub_token orelse impl_token, close_curly_token),
            .value = .{.impl_decl = .{
                .is_public = pub_token != null,
                .fields = self.collectAndFreeTempList(ast.ImplField, &fields),
                .members = self.collectAndFreeTempList(ast.Expr, &members),
                .typ = typ,
            }},
        };
    }
    
    fn parseContainerMember(self: *Parser) ast.Expr {
        const Mode = enum {
            unknown,
            field,
            var_decl,
            fn_decl,
            struct_decl,
        };
        
        var mode = Mode.unknown;
        
        switch (self.ts.peek().kind) {
            TokenKind.KeywordVar,
            TokenKind.KeywordVal,
            TokenKind.KeywordConst => mode = .var_decl,
            TokenKind.KeywordFn => mode = .fn_decl,
            TokenKind.KeywordStruct => mode = .struct_decl,
            TokenKind.KeywordPub => {
                if (self.hasVarDeclNext()) {
                    mode = .var_decl;
                }
                else if (self.hasFnNext()) {
                    mode = .fn_decl;
                }
                else if (self.hasStructNext()) {
                    mode = .struct_decl;
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.peekN(2), "Invalid pub modifier", .{});
                }
            },
            TokenKind.KeywordUsing => {
                if (self.ts.peekN(2).kind == .Identifier and (self.ts.peekN(3).kind == .Colon or self.ts.peekN(3).kind == .Eq)) {
                    mode = .field;
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.peek(), "`using` must be followed by field declaration", .{});
                }
            },            
            else => {
                mode = .unknown;                    
            }
        }
        
        switch (mode) {
            .unknown => {
                self.reporter.reportErrorAtToken(self.ts.peek(), "Only fields, variable, function & struct declaration are allowed inside struct", .{});
            },
            else => {
                const expr = self.parseExpr();
            
                // Only var_decl, function & struct declaration allowed inside struct
                switch (expr.value) {
                    ast.Kind.var_decl,
                    ast.Kind.fn_decl,
                    ast.Kind.struct_decl => {},
                    else => {
                        self.reporter.reportErrorAtSpan(expr.span, "Only fields, variable, function & struct declaration are allowed inside struct", .{});
                    }
                }
                
                return expr;
            },
        }
    }
    
    fn parseVarDecl(self: *Parser) ast.Expr {
        var pub_token: ?Token = null;
        
        if (self.ts.peek().kind == .KeywordPub) {
            pub_token = self.ts.next();
        }
        
        const decl_token = self.ts.nextExpectAny(&[_]TokenKind{ .KeywordVal, .KeywordVar, .KeywordConst });
        const name_token = self.ts.nextExpect(.Identifier);
        var typ: ?ast.Type = null;
        var value: ?*ast.Expr = null;
        
        if (self.ts.peek().kind == .Colon) {
            _ = self.ts.next();
            typ = self.parseType();
        }
        
        if (self.ts.peek().kind == .Eq) {
            _ = self.ts.next();
            value = self.makeExprPointer(self.parseExpr());
        }
        
        if (typ == null and value == null) {
            self.reporter.reportErrorAtToken(name_token, "Variable should have a type or value", .{});
        }
        
        const span: TokenSpan = if (value) |v| TokenSpan.from_token_and_span(pub_token orelse decl_token, v.span)
        else if (typ) |t| TokenSpan.from_token_and_span(pub_token orelse decl_token, t.span)
        else TokenSpan.from_tokens(pub_token orelse decl_token, name_token);
        
        return .{
            .value = .{ .var_decl = .{
                .is_public = pub_token != null,
                .decl = decl_token,
                .name = name_token,
                .typ = typ,
                .value = value,
            } },
            .span = span,
        };
    }
    
    fn parseBlock(self: *Parser) ast.Block {
        const open_curly_token = self.ts.nextExpect(.OpenCurlyBracket);
        var exprs: std.ArrayList(ast.Expr) = .empty;
        
        while (self.ts.hasNext()) {
            if (self.ts.peek().kind == .CloseCurlyBracket) break;
            
            exprs.append(self.temp_allocator, self.parseExpr()) catch unreachable;
        }
        
        const close_curly_token = self.ts.nextExpect(.CloseCurlyBracket);
        
        return ast.Block{
            .exprs = self.collectAndFreeTempList(ast.Expr, &exprs),
            .span = TokenSpan.from_tokens(open_curly_token, close_curly_token),
        };
    }
    
    fn parseFor(self: *Parser) ast.Expr {
        const for_token = self.ts.nextExpect(.KeywordFor);
        var item_var_token: ?Token = null;
        var index_var_token: ?Token = null;
        var is_reference = false;
        
        // If for format is
        //     for a in x {}
        // or
        //     for a, i in x {}
        //
        if (self.ts.peek().kind == .Identifier and (self.ts.peekN(2).kind == .Comma or self.ts.peekN(2).kind == .KeywordIn)) {
            item_var_token = self.ts.next();
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                index_var_token = self.ts.nextExpect(.Identifier);
            }
            
            _ = self.ts.nextExpect(.KeywordIn);
        }
        // If for format is
        //     for &a in x {}
        // or
        //     for &a, i in x {}
        //
        else if (self.ts.peek().kind == .And and self.ts.peekN(2).kind == .Identifier and (self.ts.peekN(3).kind == .Comma or self.ts.peekN(3).kind == .KeywordIn)) {
            _ = self.ts.next();
            is_reference = true;
            item_var_token = self.ts.next();
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                index_var_token = self.ts.nextExpect(.Identifier);
            }
            
            _ = self.ts.nextExpect(.KeywordIn);
        }
        
        // If format is not like above, then it must be
        //     for <expr> {}
        //
        
        const iter = self.makeExprPointer(self.parseExpr());
        var reversed = false;
        
        if (self.ts.peek().kind == .At) {
            const token = self.ts.peekN(2);
            
            if (std.mem.eql(u8, self.getTokenText(token), "reversed")) {
                reversed = true;
                _ = self.ts.next();
                _ = self.ts.next();
            }
            else {
                self.reporter.reportErrorAtToken(token, "Invalid modifier {s}", .{self.getTokenText(token)});
            }
        }
        
        const body = self.makeExprPointer(self.parseExpr());
        
        return .{
            .value = .{.forr = .{
                .item_var = item_var_token,
                .index_var = index_var_token,
                .is_reference = is_reference,
                .iter = iter,
                .body = body,
                .reversed = reversed,
            }},
            .span = TokenSpan.from_token_and_span(for_token, body.span),
        };
    }
    
    fn parseWhile(self: *Parser) ast.Expr {
        const while_token = self.ts.nextExpect(.KeywordWhile);
        
        const cond = self.makeExprPointer(self.parseExpr());
        const body = self.makeExprPointer(self.parseExpr());
        
        return .{
            .span = TokenSpan.from_token_and_span(while_token, body.span),
            .value = .{.whil = .{
                .condition = cond,
                .body = body
            }},
        };
    }
    
    fn parseBreak(self: *Parser) ast.Expr {
        const break_token = self.ts.nextExpect(.KeywordBreak);
        
        return .{
            .span = TokenSpan.from_token(break_token),
            .value = .breaq,
        };
    }
    
    fn parseIf(self: *Parser) ast.Expr {
        const if_token = self.ts.nextExpect(.KeywordIf);
        const condition = self.makeExprPointer(self.parseExpr());
        const body = self.makeExprPointer(self.parseExpr());
        var else_expr: ?*ast.Expr = null;
        
        if (self.ts.peek().kind == .KeywordElse) {
            _ = self.ts.next();
            else_expr = self.makeExprPointer(self.parseExpr());
        }
        
        return .{
            .value = .{.iff = .{
                .condition = condition,
                .body = body,
                .else_expr = else_expr
            }},
            .span = TokenSpan.from_token_and_span(if_token, if (else_expr) |e| e.span else body.span),
        };
    }
    
    fn parseSwitch(self: *Parser) ast.Expr {
        const switch_token = self.ts.nextExpect(.KeywordSwitch);
        const expr = self.makeExprPointer(self.parseExpr());
        var partial = false;
        
        if (self.ts.peek().kind == .At) {
            const at_token = self.ts.next();
            const token = self.ts.next();
            
            if (token.kind == .Identifier and std.mem.eql(u8, self.getTokenText(token), "partial")) {
                partial = true;
            }
            else {
                self.reporter.reportErrorAtToken(at_token, "Invalid `@` modifier", .{});
            }
        }
        
        _ = self.ts.nextExpect(.OpenCurlyBracket);
        
        var cases = std.ArrayList(ast.SwitchCase).empty;
        var has_else = false;
        var has_comma = true;
        
        while (self.ts.hasNext()) {
            if (self.ts.peek().kind == .CloseCurlyBracket) break;
            
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
            }
            
            var conditions = std.ArrayList(ast.Expr).empty;
            var fallthrough = false;
            
            switch (self.ts.peek().kind) {
                TokenKind.KeywordElse => {
                    if (has_else) {
                        self.reporter.reportErrorAtToken(self.ts.next(), "Multiple else in switch", .{});
                    }
                    
                    _ = self.ts.next();
                    has_else = true;
                },
                else => {
                    while (self.ts.hasNext()) {
                        conditions.append(self.temp_allocator, self.parseExpr()) catch unreachable;
                        
                        if (self.ts.peek().kind == .Comma) {
                            _ = self.ts.next();
                        }
                        else {
                            break;
                        }
                    }
                },
            }
            
            if (self.ts.peek().kind == .At) {
                const at_token = self.ts.next();
                const token = self.ts.next();
                
                if (token.kind == .Identifier and std.mem.eql(u8, self.getTokenText(token), "fallthrough")) {
                    fallthrough = true;
                }
                else {
                    self.reporter.reportErrorAtToken(at_token, "Invalid `@` modifier", .{});
                }
            }
            
            _ = self.ts.nextExpect(.Arrow);
            const body = self.makeExprPointer(self.parseExpr());
            
            cases.append(self.temp_allocator, .{
                .conditions = self.collectAndFreeTempList(ast.Expr, &conditions),
                .body = body,
                .fallthrough = fallthrough,
            }) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        _ = self.ts.nextExpect(.CloseCurlyBracket);
        
        return .{
            .span = TokenSpan.from_token(switch_token),
            .value = .{.switc = .{
                .expr = expr,
                .cases = self.collectAndFreeTempList(ast.SwitchCase, &cases),
                .partial = partial,
            }},
        };
    }
    
    fn parseUnary(self: *Parser) ast.Expr {
        const op = self.ts.next();
        
        switch (op.kind) {
            .Not,
            .Minus => {},
            
            else => { std.debug.panic("Invalid unary operator {s}", .{@tagName(op.kind)}); },
        }
        
        const expr = self.makeExprPointer(self.parsePrimaryExpr());
        
        return .{
            .span = TokenSpan.from_token_and_span(op, expr.span),
            .value = .{.unary = .{
                .expr = expr,
                .op = op,
            }},
        };
    }
    
    fn parseFnCall(self: *Parser, callee: ast.Expr) ast.Expr {
        const open_paren_token = self.ts.nextExpect(.OpenParen);
        
        var args: std.ArrayList(ast.Expr) = .empty;
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseParen) {
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
            }
            
            args.append(self.temp_allocator, self.parseExpr()) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        const close_paren_token = self.ts.nextExpect(.CloseParen);
        
        return ast.Expr{
            .value = .{ .fn_call = .{
                .callee = self.makeExprPointer(callee),
                .args = self.collectAndFreeTempList(ast.Expr, &args),
            } },
            .span = TokenSpan.from_tokens(open_paren_token, close_paren_token),
        };
    }
    
    fn parseRange(self: *Parser, lhs: ast.Expr) ast.Expr {
        const op_token = self.ts.nextExpectAny(&.{ TokenKind.DotDot, TokenKind.DotDotDot });
        
        const is_eq = op_token.kind == .DotDotDot;        
        const rhs = self.parseExpr();
        
        return .{
            .value = .{.range = .{
                .lhs = self.makeExprPointer(lhs),
                .rhs = self.makeExprPointer(rhs),
                .is_eq = is_eq,
            }},
            .span = TokenSpan.from_spans(lhs.span, rhs.span),
        };
    }
    
    fn parseMemberAccess(self: *Parser, callee: ast.Expr) ast.Expr {
        _ = self.ts.nextExpect(.Dot);
        const member_token = self.ts.nextExpect(.Identifier);
        
        return .{
            .span = TokenSpan.from_span_and_token(callee.span, member_token),
            .value = .{.member_access = .{
                .callee = self.makeExprPointer(callee),
                .member = member_token,
            }},
        };
    }
    
    fn parseArrayIndex(self: *Parser, callee: ast.Expr) ast.Expr {
        _ = self.ts.nextExpect(.OpenSqBracket);
        const index = self.makeExprPointer(self.parseExpr());
        const close_bracket_token = self.ts.nextExpect(.CloseSqBracket);
        
        return .{
            .value = .{.array_index = .{
                .callee = self.makeExprPointer(callee),
                .index = index,
            }},
            .span = TokenSpan.from_span_and_token(callee.span, close_bracket_token),
        };
    }
    
    fn tryParseGeneric(self: *Parser, callee: ast.Expr) ?ast.Expr {        
        switch (callee.value) {
            .identifier,
            .member_access => {},
            else => {
                return null;
            }
        }
        
        self.ts.mark();
        
        var opening_count: i32 = 0;
        
        while (self.ts.hasNext()) {
            switch (self.ts.next().kind) {
                .Lt => {
                    opening_count += 1;
                },
                .Gt => {
                    opening_count -= 1;
                },
                .Identifier,
                .Comma => {},
                else => {
                    self.ts.restore();
                    return null;
                }
            }
            
            if (opening_count == 0) break;
        }
        
        self.ts.restore();
        
        _ = self.ts.nextExpect(.Lt);
               
        var children: std.ArrayList(ast.Type) = .empty;
        var has_comma = true;
        
        while (self.ts.hasNext()) {
            if (self.ts.peek().kind == .Gt) break;
            
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
            }
            
            children.append(self.temp_allocator, self.parseType()) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        // Gt (>)
        const gt_token = self.ts.next();
        
        return .{
            .span = TokenSpan.from_span_and_token(callee.span, gt_token),
            .value = .{.generic = .{
                .callee = self.makeExprPointer(callee),
                .children = self.collectAndFreeTempList(ast.Type, &children),
            }}
        };
    }
    
    fn parseArrayValue(self: *Parser) ast.Expr {
        const dot_token = self.ts.nextExpect(.Dot);
        var elems = std.ArrayList(ast.Expr).empty;
        
        _ = self.ts.nextExpect(.OpenSqBracket);
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseSqBracket) {
            if (!has_comma) {
                self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma", .{});
            }
            
            elems.append(self.temp_allocator, self.parseExpr()) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        const close_bracket_token = self.ts.next();
        
        return .{
            .value = .{.array_value = .{ .elems = self.collectAndFreeTempList(ast.Expr, &elems) }},
            .span = TokenSpan.from_tokens(dot_token, close_bracket_token),
        };
    }
    
    fn parseStructValue(self: *Parser) ast.Expr {
        var struct_name_token: ?Token = null;
        var elems = std.ArrayList(ast.StructValueElem).empty;
        
        if (self.ts.peek().kind == .Identifier) {
            struct_name_token = self.ts.next();
        }
        
        const dot_token = self.ts.nextExpect(.Dot);
        _ = self.ts.nextExpect(.OpenCurlyBracket);
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseCurlyBracket) {
            if (!has_comma) {
                self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma", .{});
            }
            
            // Struct field initialization can be named or unnamed
            // Example of named fields :
            //
            //   Foo.{
            //       bar = 12,
            //       baz = 45.3,
            //   }
            //
            // Example of unnamed fields :
            //
            //   Vec2.{ 11, 12 }
            //
            // The order of unnamed fields must follow the order of member in
            // struct initialization.
            // This is useful for struct with few (and obvious) members
            //
            var field_name_token: ?Token = null;
            
            if (self.ts.peek().kind == .Identifier and self.ts.peekN(2).kind == .Eq) {
                field_name_token = self.ts.next();
                _ = self.ts.next();
            }
            
            elems.append(self.temp_allocator, ast.StructValueElem{
                .field_name = field_name_token,
                .value = self.parseExpr(),
            }) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        const close_bracket_token = self.ts.nextExpect(.CloseCurlyBracket);
        
        return .{
            .span = TokenSpan.from_tokens(struct_name_token orelse dot_token, close_bracket_token),
            .value = .{.struct_value = .{
                .struct_name = struct_name_token,
                .elems = self.collectAndFreeTempList(ast.StructValueElem, &elems),
            }},
        };
    }
    
    fn parseEnumValue(self: *Parser) ast.Expr {
        var enum_name_token: ?Token = null;
        
        if (self.ts.peek().kind == .Identifier) {
            enum_name_token = self.ts.next();
        }
        
        const dot_token = self.ts.nextExpect(.Dot);
        const item_token = self.ts.nextExpect(.Identifier);
        
        return .{
            .span = TokenSpan.from_tokens(enum_name_token orelse dot_token, item_token),
            .value = .{ .enum_value = .{ .item = item_token } },
        };
    }
    
    fn parseExtern(self: *Parser) ast.Extern {
        const extern_token = self.ts.nextExpect(.KeywordExtern);
        var close_token: ?Token = null;
        
        var name: ?Token = null;
        var abi: ?Token = null;
        
        if (self.ts.peek().kind == .OpenParen) {
            _ = self.ts.next();
            
            var has_comma = true;
            
            while (self.ts.hasNext()) {
                if (self.ts.peek().kind == .CloseParen) {
                    close_token = self.ts.next();
                    break;
                }
                
                if (!has_comma) {
                    self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma", .{});
                }
                
                const ident = self.ts.nextExpect(.Identifier);
                const text = self.getTokenText(ident);
                
                if (std.mem.eql(u8, text, "name")) {
                    _ = self.ts.nextExpect(.Eq);
                    name = self.ts.nextExpect(.StringLit);
                }
                else if (std.mem.eql(u8, text, "abi")) {
                    _ = self.ts.nextExpect(.Eq);
                    abi = self.ts.nextExpect(.StringLit);
                }
                
                if (self.ts.peek().kind == .Comma) {
                    _ = self.ts.next();
                    has_comma = true;
                }
                else {
                    has_comma = false;
                }
            }
        }
        
        return .{
            .name = name,
            .abi = abi,
            .span = TokenSpan.from_tokens(extern_token, close_token orelse extern_token),
        };
    }
    
    fn parseAddressOf(self: *Parser) ast.Expr {
        const and_token = self.ts.nextExpect(.And);
        const value = self.parseExpr();
        
        return .{
            .span = TokenSpan.from_token_and_span(and_token, value.span),
            .value = .{.address_of = .{
                .value = self.makeExprPointer(value),
            }},
        };
    }
    
    fn parseCast(self: *Parser, expr: ast.Expr) ast.Expr {
        _ = self.ts.nextExpect(.KeywordAs);
        const typ = self.parseType();
        
        return .{
            .span = TokenSpan.from_spans(expr.span, typ.span),
            .value = .{.cast = .{
                .typ = typ,
                .value = self.makeExprPointer(expr),
            }},
        };
    }
    
    fn parseIntinsic(self: *Parser) ast.Expr {
        const at_token = self.ts.nextExpect(.At);
        const name_token = self.ts.nextExpect(.Identifier);
        
        var args: std.ArrayList(ast.Expr) = .empty;
        var has_comma = true;
        
        _ = self.ts.nextExpect(.OpenParen);
        
        while (self.ts.peek().kind != .CloseParen) {
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
            }
            
            args.append(self.temp_allocator, self.parseExpr()) catch unreachable;
            
            if (self.ts.peek().kind == .Comma) {
                _ = self.ts.next();
                has_comma = true;
            }
            else {
                has_comma = false;
            }
        }
        
        const close_paren_token = self.ts.nextExpect(.CloseParen);
        
        return ast.Expr{
            .value = .{ .intrinsic = .{
                .name = name_token,
                .args = self.collectAndFreeTempList(ast.Expr, &args),
            } },
            .span = TokenSpan.from_tokens(at_token, close_paren_token),
        };
    }
    
    fn parseType(self: *Parser) ast.Type {
        var typ: ast.Type = undefined;
        
        switch (self.ts.peek().kind) {
            TokenKind.Identifier => {
                // Generic
                if (self.ts.peekN(2).kind == .Lt) {
                    const name_token = self.ts.next();
                    _ = self.ts.next();
                    
                    var children: std.ArrayList(ast.Type) = .empty;
                    var has_comma = true;
                    
                    while (self.ts.hasNext()) {
                        if (self.ts.peek().kind == .Gt) break;
                        
                        if (!has_comma) {
                            self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
                        }
                        
                        children.append(self.temp_allocator, self.parseType()) catch unreachable;
                        
                        if (self.ts.peek().kind == .Comma) {
                            _ = self.ts.next();
                            has_comma = true;
                        }
                        else {
                            has_comma = false;
                        }
                    }
                    
                    // Gt (>)
                    const gt_token = self.ts.next();
                    
                    typ = ast.Type{
                        .value = .{
                            .generic = .{
                                .base = name_token,
                                .children = self.collectAndFreeTempList(ast.Type, &children),
                            }
                        },
                        .span = TokenSpan.from_tokens(name_token, gt_token),
                    };
                }
                else {
                    const name_token = self.ts.next();
                    
                    typ = ast.Type{
                        .value = .{
                            .simple = .{
                                .name = name_token,
                            },
                        },
                        .span = TokenSpan.from_token(name_token),
                    };
                }
            },
            TokenKind.OpenSqBracket => {
                const open_sq_token = self.ts.next();
                
                const is_dyn = if (self.ts.peek().kind == .KeywordDyn) blk: {
                    _ = self.ts.next();
                    break :blk true;
                } else false;
                
                _ = self.ts.nextExpect(.CloseSqBracket);
                
                const child: *ast.Type = self.makeTypePointer(self.parseType());
                
                typ = ast.Type{
                    .value = .{
                        .array = .{
                            .child = child,
                            .is_dyn = is_dyn,
                        },
                    },
                    .span = TokenSpan.from_token_and_span(open_sq_token, child.span),
                };
            },
            TokenKind.And => {
                const ref_token = self.ts.next();
                
                const child: *ast.Type = self.makeTypePointer(self.parseType());
                
                typ = ast.Type{
                    .value = .{
                        .reference = .{
                            .child = child,
                        },
                    },
                    .span = TokenSpan.from_token_and_span(ref_token, child.span),
                };
            },
            TokenKind.Mul => {
                const pointer_token = self.ts.next();
                
                const child: *ast.Type = self.makeTypePointer(self.parseType());
                
                typ = ast.Type{
                    .value = .{
                        .pointer = .{
                            .child = child,
                        },
                    },
                    .span = TokenSpan.from_token_and_span(pointer_token, child.span),
                };
            },
            TokenKind.QMark => {
                const qmark_token = self.ts.next();
                
                const child: *ast.Type = self.makeTypePointer(self.parseType());
                
                typ = ast.Type{
                    .value = .{
                        .nullable = .{
                            .child = child,
                        },
                    },
                    .span = TokenSpan.from_token_and_span(qmark_token, child.span),
                };
            },
            TokenKind.OpenParen => {
                // Open paren
                const oparen_token = self.ts.next();
                
                var children: std.ArrayList(ast.Type) = .empty;
                var has_comma = true;
                
                while (self.ts.hasNext()) {
                    if (self.ts.peek().kind == .CloseParen) break;
                    
                    if (!has_comma) {
                        self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
                    }
                    
                    children.append(self.temp_allocator, self.parseType()) catch unreachable;
                    
                    if (self.ts.peek().kind == .Comma) {
                        _ = self.ts.next();
                        has_comma = true;
                    }
                    else {
                        has_comma = false;
                    }
                }
                
                // Open paren
                const cparen_token = self.ts.next();
                
                typ = ast.Type{
                    .value = .{
                        .tuple = .{
                            .children = self.collectAndFreeTempList(ast.Type, &children),
                        }
                    },
                    .span = TokenSpan.from_tokens(oparen_token, cparen_token),
                };
            },
            TokenKind.KeywordStruct => {
                const struct_decl = self.parseStructDecl();
                
                typ = ast.Type{
                    .span = struct_decl.span,
                    .value = .{ .inline_struct = struct_decl.value.struct_decl, },
                };
            },
            TokenKind.KeywordEnum => {
                const enum_decl = self.parseEnumDecl();
                
                typ = ast.Type{
                    .span = enum_decl.span,
                    .value = .{ .inline_enum = enum_decl.value.enum_decl, }
                };
            },
            TokenKind.At => {
                if (self.ts.peekN(2).kind == .Identifier) {
                    const at_token = self.ts.next();
                    const name = self.ts.next();
                    
                    if (std.mem.eql(u8, self.getTokenText(name), "Self")) {
                        typ = ast.Type{
                            .span = TokenSpan.from_tokens(at_token, name),
                            .value = .self,
                        };
                    }
                    else {
                        self.reporter.reportErrorAtToken(name, "Invalid intrinsic type. Only `@Self` is supported, it refers to the containing type (struct or enum).", .{});
                    }
                }
            },
            
            else => {
                self.reporter.reportErrorAtToken(self.ts.next(), "Expected type but got {s}", .{@tagName(self.ts.current().kind)});
            }
        }
        
        return typ;
    }
    
    fn parseImport(self: *Parser) ast.Expr {
        const import_token = self.ts.nextExpect(.KeywordImport);
        const path = self.ts.nextExpect(.StringLit);
        
        var symbols: ?[]const Token = null;
        var close_bracket_token: ?Token = null;
        var as: ?Token = null;
        
        if (self.ts.peek().kind == .OpenCurlyBracket) {
            _ = self.ts.next();
            var tokens = std.ArrayList(Token).empty;
            var has_comma = true;
            
            while (self.ts.peek().kind != .CloseCurlyBracket) {
                if (!has_comma) {
                    self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma", .{});
                }
                
                tokens.append(self.temp_allocator, self.ts.nextExpect(.Identifier)) catch unreachable;
                
                if (self.ts.peek().kind == .Comma) {
                    _ = self.ts.next();
                    has_comma = true;
                }
                else {
                    has_comma = false;
                }
            }
            
            close_bracket_token = self.ts.nextExpect(.CloseCurlyBracket);
            
            symbols = self.collectAndFreeTempList(Token, &tokens);
        }
        
        if (self.ts.peek().kind == .KeywordAs) {
            _ = self.ts.next();
            as = self.ts.nextExpect(.Identifier);
        }
        
        const import: ast.Import = .{
            .path = path,
            .symbols = symbols,
            .as = as,
        };
        
        self.imports.append(self.allocator, import) catch unreachable;
        
        return .{
            .span = TokenSpan.from_tokens(import_token, as orelse close_bracket_token orelse path),
            .value = .{.import = import},
        };
    }
    
    fn makeExprPointer(self: *Parser, expr: ast.Expr) *ast.Expr {
        const p = self.allocator.create(ast.Expr) catch unreachable;
        p.* = expr;
        
        return p;
    }
    
    fn makeTypePointer(self: *Parser, typ: ast.Type) *ast.Type {
        const p = self.allocator.create(ast.Type) catch unreachable;
        p.* = typ;
        
        return p;
    }
    
    fn collectAndFreeTempList(self: *Parser, comptime T: type, list: *std.ArrayList(T)) []const T {
        const res = self.allocator.dupe(T, list.items) catch unreachable;
        list.clearAndFree(self.temp_allocator);
        
        return res;
    }
    
    fn getTokenText(self: *Parser, token: Token) []const u8 {
        const src = self.file_manager.getContent(token.loc.file_id);
        return src[token.loc.start..token.loc.end];
    }
};

pub fn parse(allocator: std.mem.Allocator, file_manager: *const FileManager, reporter: *const Reporter, tokens: []const Token) ast.Module {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const temp_allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);
    
    var parser = Parser.init(allocator, temp_allocator, file_manager, reporter, tokens);
    return parser.parseModule();
}