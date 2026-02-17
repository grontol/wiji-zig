const std = @import("std");
const Token = @import("token.zig").Token;
const TokenSpan = @import("token.zig").TokenSpan;
const TokenKind = @import("token.zig").TokenKind;
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
    
    break :blk res;
};

const TokenStream = struct {
    reporter: Reporter,
    tokens: []const Token,
    eof_token: Token,
    current_index: usize,
    mark_index: usize,
    
    fn init(reporter: Reporter, tokens: []const Token) TokenStream {
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
            self.reporter.reportErrorAtTokenArgs(next_token, "Expected `{s}` but got `{s}`", .{
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
        
        var buffer = [_]u8{0} ** 1024;
        var str = std.ArrayList(u8).initBuffer(&buffer);
        
        for (kinds, 0..) |kind, i| {
            if (i > 0) {
                str.appendSliceAssumeCapacity(" | ");
            }
            
            str.appendSliceAssumeCapacity(@tagName(kind));
        }
        
        self.reporter.reportErrorAtTokenArgs(peek_token, "Expected `{s}` but got `{s}`", .{
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
    reporter: Reporter,
    ts: TokenStream,
    
    fn init(allocator: std.mem.Allocator, temp_allocator: std.mem.Allocator, reporter: Reporter, tokens: []const Token) Parser {
        return .{
            .allocator = allocator,
            .temp_allocator = temp_allocator,
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
                TokenKind.KeywordFn => res = true,
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
                TokenKind.KeywordStruct => res = true,
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
        };
    }
    
    fn parseExpr(self: *Parser) ast.Expr {
        var expr = self.parsePrimaryExpr();
        
        if (self.ts.peek().kind.is_assignment()) {
            const op_token = self.ts.next();
            const rhs = self.parseExpr();
            
            expr = ast.Expr{
                .value = .{ .assignment = .{
                    .lhs = self.makeExprPointer(expr),
                    .rhs = self.makeExprPointer(rhs),
                    .op = op_token,
                } },
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
        
        return expr;
    }
    
    fn parsePrimaryExpr(self: *Parser) ast.Expr {
        const kind = self.ts.peek().kind;
        var expr: ast.Expr = undefined;
        
        switch (kind) {
            TokenKind.IntLit,
            TokenKind.IntBinLit,
            TokenKind.IntOctLit,
            TokenKind.IntHexLit,
            TokenKind.FloatLit,
            TokenKind.StringLit,
            TokenKind.CharLit,
            TokenKind.Identifier,
            TokenKind.TrueLit,
            TokenKind.FalseLit => {
                switch (kind) {
                    TokenKind.IntLit    => { expr = ast.Literal.create_expr(ast.LitKind.Int, self.ts.next()); },
                    TokenKind.IntBinLit => { expr = ast.Literal.create_expr(ast.LitKind.IntBin, self.ts.next()); },
                    TokenKind.IntOctLit => { expr = ast.Literal.create_expr(ast.LitKind.IntOct, self.ts.next()); },
                    TokenKind.IntHexLit => { expr = ast.Literal.create_expr(ast.LitKind.IntHex, self.ts.next()); },
                    TokenKind.FloatLit  => { expr = ast.Literal.create_expr(ast.LitKind.Float, self.ts.next()); },
                    TokenKind.StringLit => { expr = ast.Literal.create_expr(ast.LitKind.String, self.ts.next()); },
                    TokenKind.CharLit   => { expr = ast.Literal.create_expr(ast.LitKind.Char, self.ts.next()); },
                    TokenKind.TrueLit   => { expr = ast.Literal.create_expr(ast.LitKind.True, self.ts.next()); },
                    TokenKind.FalseLit  => { expr = ast.Literal.create_expr(ast.LitKind.False, self.ts.next()); },
                    
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
                        TokenKind.DotDot => expr = self.parseRange(expr),
                        TokenKind.OpenSqBracket => expr = self.parseArrayIndex(expr),
                        else => break,
                    }
                }
            },
            
            TokenKind.KeywordFn => expr = self.parseFnDecl(),
            TokenKind.KeywordStruct => expr = self.parseStructDecl(),
            TokenKind.KeywordPub => {
                if (self.hasFnNext()) {
                    expr = self.parseFnDecl();
                }
                else if (self.hasStructNext()) {
                    expr = self.parseStructDecl();
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.peekN(2), "Invalid pub modifier");
                }
            },
            TokenKind.KeywordExtern => {
                if (self.hasFnNext()) {
                    expr = self.parseFnDecl();
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.peekN(1), "Invalid extern modifier");
                }
            },
            TokenKind.KeywordFor => expr = self.parseFor(),
            TokenKind.KeywordWhile => expr = self.parseWhile(),
            TokenKind.KeywordIf => expr = self.parseIf(),
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
                else if (self.ts.peekN(2).kind == .OpenParen) {
                    std.debug.panic("TODO: Parse tuple value", .{});
                }
                else {
                    self.reporter.reportErrorAtToken(self.ts.next(), "Invalid dot");
                }
            },
            TokenKind.At => std.debug.panic("TODO: Parse intrinsic", .{}),
            TokenKind.KeywordReturn => std.debug.panic("TODO: Parse return", .{}),
            
            else => {
                std.debug.panic("Not Implemented : parsePrimaryExpr {s}", .{@tagName(kind)});
            },
        }
        
        return expr;
    }
    
    fn parseFnDecl(self: *Parser) ast.Expr {
        var extern_token: ?Token = null;
        var public_token: ?Token = null;
        
        if (self.ts.peek().kind == .KeywordExtern) {
            extern_token = self.ts.next();
        }
        
        if (self.ts.peek().kind == .KeywordPub) {
            public_token = self.ts.next();
        }
        
        const fn_token = self.ts.nextExpect(.KeywordFn);
        const name_token = self.ts.nextExpect(.Identifier);
        _ = self.ts.nextExpect(.OpenParen);
        
        var params: std.ArrayList(ast.FnParam) = .empty;
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseParen) {
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma");
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
                self.reporter.reportErrorAtToken(param_name_token, "Expected type or default value");
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
        
        var block: ?ast.Block = null;
        
        if (self.ts.peek().kind == .OpenCurlyBracket) {
            block = self.parseBlock();
        }
        
        const start_token = extern_token orelse public_token orelse fn_token;
        
        const span = if (block) |b| TokenSpan.from_token_and_span(start_token, b.span)
        else TokenSpan.from_tokens(start_token, close_paren_token);
        
        return ast.Expr{
            .value = .{
                .fn_decl = .{
                    .is_extern = extern_token != null,
                    .is_public = public_token != null,
                    .name = name_token,
                    .params = self.collectAndFreeTempList(ast.FnParam, &params),
                    .return_typ = null,
                    .block = block,
                },
            },
            .span = span,
        };
    }
    
    fn parseStructDecl(self: *Parser) ast.Expr {
        var pub_token: ?Token = null;
        
        if (self.ts.peek().kind == .KeywordPub) {
            pub_token = self.ts.next();
        }
        
        const struct_token = self.ts.nextExpect(.KeywordStruct);
        const name_token = self.ts.nextExpect(.Identifier);
        
        _ = self.ts.nextExpect(.OpenCurlyBracket);
        
        var fields = std.ArrayList(ast.StructField).empty;
        var members = std.ArrayList(ast.Expr).empty;
        var has_comma = true;
        var fields_done = false;
        
        while (self.ts.hasNext()) {
            switch (self.ts.peek().kind) {
                TokenKind.CloseCurlyBracket => break,
                TokenKind.KeywordFn,
                TokenKind.KeywordStruct => fields_done = true,
                TokenKind.KeywordPub => {
                    if (self.hasFnNext() or self.hasStructNext()) {
                        fields_done = true;
                    }
                    else {
                        self.reporter.reportErrorAtToken(self.ts.peekN(2), "Invalid pub modifier");
                    }
                },
                
                else => {}
            }
            
            if (!fields_done) {
                if (!has_comma and !self.ts.peek().has_nl_before) {
                    self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma or newline");
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
                    self.reporter.reportErrorAtToken(field_name_token, "Expected type or default value");
                }
                
                fields.append(self.temp_allocator, ast.StructField{
                    .name = field_name_token,
                    .typ = field_typ,
                    .default_value = field_default_value,
                }) catch unreachable;
                
                if (self.ts.peek().kind == .Comma) {
                    _ = self.ts.next();
                    has_comma = true;
                }
                else {
                    has_comma = false;
                }
            }
            else {
                const expr = self.parseExpr();
                
                // Only function & struct declaration allowed inside struct
                switch (expr.value) {
                    ast.Kind.fn_decl,
                    ast.Kind.struct_decl => {},
                    else => {
                        self.reporter.reportErrorAtSpan(expr.span, "Only function & struct declaration allowed inside struct");
                    }
                }
                
                members.append(self.temp_allocator, expr) catch unreachable;
            }
        }
        
        const close_bracket_token = self.ts.nextExpect(.CloseCurlyBracket);
        
        return .{
            .span = TokenSpan.from_tokens(pub_token orelse struct_token, close_bracket_token),
            .value = .{.struct_decl = .{
                .is_public = pub_token != null,
                .name = name_token,
                .fields = self.collectAndFreeTempList(ast.StructField, &fields),
                .members = self.collectAndFreeTempList(ast.Expr, &members),
            }},
        };
    }
    
    fn parseVarDecl(self: *Parser) ast.Expr {
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
            self.reporter.reportErrorAtToken(name_token, "Variable should have a type or value");
        }
        
        return .{
            .value = .{ .var_decl = .{
                .decl = decl_token,
                .name = name_token,
                .typ = typ,
                .value = value,
            } },
            .span = TokenSpan.from_tokens(decl_token, decl_token),
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
        
        // If format is not like above, then it must be
        //     for <expr> {}
        //
        
        const iter = self.makeExprPointer(self.parseExpr());
        const body = self.makeExprPointer(self.parseExpr());
        
        return .{
            .value = .{.forr = .{
                .item_var = item_var_token,
                .index_var = index_var_token,
                .iter = iter,
                .body = body,
            }},
            .span = TokenSpan.from_token_and_span(for_token, body.span),
        };
    }
    
    fn parseWhile(_: *Parser) ast.Expr {
        std.debug.panic("TODO: parseWhile", .{});
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
    
    fn parseFnCall(self: *Parser, callee: ast.Expr) ast.Expr {
        const open_paren_token = self.ts.nextExpect(.OpenParen);
        
        var args: std.ArrayList(ast.Expr) = .empty;
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseParen) {
            if (!has_comma) {
                self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma");
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
        _ = self.ts.nextExpect(.DotDot);
        var is_eq = false;
        
        if (self.ts.peek().kind == .Eq) {
            _ = self.ts.next();
            is_eq = true;
        }
        
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
    
    fn parseArrayValue(self: *Parser) ast.Expr {
        const dot_token = self.ts.nextExpect(.Dot);
        var elems = std.ArrayList(ast.Expr).empty;
        
        _ = self.ts.nextExpect(.OpenSqBracket);
        var has_comma = true;
        
        while (self.ts.peek().kind != .CloseSqBracket) {
            if (!has_comma) {
                self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma");
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
                self.reporter.reportErrorAfterToken(self.ts.current(), "Expected comma");
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
                            self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma");
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
                                .name = name_token,
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
                _ = self.ts.nextExpect(.CloseSqBracket);
                
                const child: *ast.Type = self.makeTypePointer(self.parseType());
                
                typ = ast.Type{
                    .value = .{
                        .array = .{
                            .child = child,
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
                        self.reporter.reportErrorAtToken(self.ts.current(), "Expected comma");
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
            
            else => {
                self.reporter.reportErrorAtTokenArgs(self.ts.next(), "Expected type but got {s}", .{@tagName(self.ts.current().kind)});
            }
        }
        
        return typ;
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
};

pub fn parse(allocator: std.mem.Allocator, reporter: Reporter, tokens: []const Token) ast.Module {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const temp_allocator = gpa.allocator();
    
    var parser = Parser.init(allocator, temp_allocator, reporter, tokens);
    return parser.parseModule();
}