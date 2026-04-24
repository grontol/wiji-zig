const std = @import("std");

const Reporter = @import("reporter.zig");
const Token = @import("token.zig").Token;
const TokenKind = @import("token.zig").TokenKind;

pub const Chars = struct {
    src: []const u8,
    index: usize,
    
    pub fn init(src: []const u8) Chars {
        return .{
            .src = src,
            .index = 0,
        };
    }
    
    pub fn hasNext(self: *Chars) bool {
        return self.index < self.src.len;
    }
    
    pub fn next(self: *Chars) u8 {
        self.index += 1;
        
        if (self.index - 1 >= self.src.len) return 0;
        return self.src[self.index - 1];
    }
    
    pub fn peek(self: *const Chars) u8 {
        if (self.index >= self.src.len) return 0;
        return self.src[self.index];
    }
    
    pub fn peekN(self: *const Chars, n: usize) u8 {
        if (self.index + n - 1 >= self.src.len) return 0;
        return self.src[self.index + n - 1];
    }
    
    pub fn nextUntilSeparateToken(self: *Chars) usize {
        var ch = self.peek();
        
        while (ch > 0) : (ch = self.peek()) {
            if (isAlphanumeric(ch) or ch == '_') { _ = self.next(); }
            else { break; }
        }
        
        return self.index;
    }
    
    pub fn nextNumericUntilSeparateToken(self: *Chars) usize {
        var ch = self.peek();
        
        while (ch > 0) : (ch = self.peek()) {
            if (isNumeric(ch) or ch == '_') { _ = self.next(); }
            else { break; }
        }
        
        return self.index;
    }
    
    pub fn nextNumericBinUntilSeparateToken(self: *Chars) usize {
        var ch = self.peek();
        
        while (ch > 0) : (ch = self.peek()) {
            if (ch == '0' or ch == '1' or ch == '_') { _ = self.next(); }
            else { break; }
        }
        
        return self.index;
    }
    
    pub fn nextNumericOctUntilSeparateToken(self: *Chars) usize {
        var ch = self.peek();
        
        while (ch > 0) : (ch = self.peek()) {
            if ((ch >= '0' and ch <= '7') or ch == '_') { _ = self.next(); }
            else { break; }
        }
        
        return self.index;
    }
    
    pub fn nextNumericHexUntilSeparateToken(self: *Chars) usize {
        var ch = self.peek();
        
        while (ch > 0) : (ch = self.peek()) {
            if (isNumericHex(ch) or ch == '_') { _ = self.next(); }
            else { break; }
        }
        
        return self.index;
    }
    
    pub fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }
    
    pub fn isNumeric(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }
    
    pub fn isNumericHex(ch: u8) bool {
        return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
    }
    
    pub fn isAlphanumeric(ch: u8) bool {
        return isAlpha(ch) or isNumeric(ch);
    }
};

const Lexer = struct {
    allocator: std.mem.Allocator,
    file_id: usize,
    
    chs: Chars,
    tokens: std.ArrayList(Token),
    reporter: *const Reporter,
    
    line: usize = 1,
    col: usize = 1,
    has_nl_before: bool = false,
    
    fn init(allocator: std.mem.Allocator, reporter: *const Reporter, file_id: usize, src: []const u8) !Lexer {
        return .{
            .allocator = allocator,
            .file_id = file_id,
            .chs = Chars.init(src),
            .tokens = .empty,
            .reporter = reporter,
        };
    }
    
    fn tokenizeIdentOrKeyword(self: *Lexer) void {
        const start = self.chs.index - 1;
        const end = self.chs.nextUntilSeparateToken();
        const text = self.chs.src[start..end];
        
        if (std.mem.eql(u8, text, "fn"))             { self.pushToken(TokenKind.KeywordFn, start, end); }
        else if (std.mem.eql(u8, text, "for"))       { self.pushToken(TokenKind.KeywordFor, start, end); }
        else if (std.mem.eql(u8, text, "while"))     { self.pushToken(TokenKind.KeywordWhile, start, end); }
        else if (std.mem.eql(u8, text, "break"))     { self.pushToken(TokenKind.KeywordBreak, start, end); }
        else if (std.mem.eql(u8, text, "in"))        { self.pushToken(TokenKind.KeywordIn, start, end); }
        else if (std.mem.eql(u8, text, "if"))        { self.pushToken(TokenKind.KeywordIf, start, end); }
        else if (std.mem.eql(u8, text, "else"))      { self.pushToken(TokenKind.KeywordElse, start, end); }
        else if (std.mem.eql(u8, text, "switch"))    { self.pushToken(TokenKind.KeywordSwitch, start, end); }
        else if (std.mem.eql(u8, text, "pub"))       { self.pushToken(TokenKind.KeywordPub, start, end); }
        else if (std.mem.eql(u8, text, "struct"))    { self.pushToken(TokenKind.KeywordStruct, start, end); }
        else if (std.mem.eql(u8, text, "enum"))      { self.pushToken(TokenKind.KeywordEnum, start, end); }
        else if (std.mem.eql(u8, text, "interface")) { self.pushToken(TokenKind.KeywordInterface, start, end); }
        else if (std.mem.eql(u8, text, "import"))    { self.pushToken(TokenKind.KeywordImport, start, end); }
        else if (std.mem.eql(u8, text, "as"))        { self.pushToken(TokenKind.KeywordAs, start, end); }
        else if (std.mem.eql(u8, text, "val"))       { self.pushToken(TokenKind.KeywordVal, start, end); }
        else if (std.mem.eql(u8, text, "var"))       { self.pushToken(TokenKind.KeywordVar, start, end); }
        else if (std.mem.eql(u8, text, "const"))     { self.pushToken(TokenKind.KeywordConst, start, end); }
        else if (std.mem.eql(u8, text, "extern"))    { self.pushToken(TokenKind.KeywordExtern, start, end); }
        else if (std.mem.eql(u8, text, "return"))    { self.pushToken(TokenKind.KeywordReturn, start, end); }
        else if (std.mem.eql(u8, text, "continue"))  { self.pushToken(TokenKind.KeywordContinue, start, end); }
        else if (std.mem.eql(u8, text, "true"))      { self.pushToken(TokenKind.TrueLit, start, end); }
        else if (std.mem.eql(u8, text, "false"))     { self.pushToken(TokenKind.FalseLit, start, end); }
        else if (std.mem.eql(u8, text, "dyn"))       { self.pushToken(TokenKind.KeywordDyn, start, end); }
        else if (std.mem.eql(u8, text, "using"))     { self.pushToken(TokenKind.KeywordUsing, start, end); }
        else if (std.mem.eql(u8, text, "impl"))      { self.pushToken(TokenKind.KeywordImpl, start, end); }
        else                                         { self.pushToken(TokenKind.Identifier, start, end); }
    }
    
    fn tokenizeNumber(self: *Lexer) void {
        const start = self.chs.index - 1;
        const ch = self.chs.src[self.chs.index - 1];
        var kind = TokenKind.IntLit;
        
        if (ch == '0') {
            switch (self.chs.peek()) {
                'B', 'b' => {
                    _ = self.chs.next();
                    kind = .IntBinLit;
                },
                
                'O', 'o' => {
                    _ = self.chs.next();
                    kind = .IntOctLit;
                },
                
                'X', 'x' => {
                    _ = self.chs.next();
                    kind = .IntHexLit;
                },
                
                else => {}
            }
        }
        
        var end: usize = 0;
        
        switch (kind) {
            TokenKind.IntLit    => end = self.chs.nextNumericUntilSeparateToken(),
            TokenKind.IntBinLit => end = self.chs.nextNumericBinUntilSeparateToken(),
            TokenKind.IntOctLit => end = self.chs.nextNumericOctUntilSeparateToken(),
            TokenKind.IntHexLit => end = self.chs.nextNumericHexUntilSeparateToken(),
            
            else => @panic("Unreachable"),
        }
        
        if (self.chs.peek() == '.' and self.chs.peekN(2) != '.') {
            _ = self.chs.next();
            
            end = self.chs.nextNumericUntilSeparateToken();
            
            if (kind == .IntLit) {
                kind = .FloatLit;
            }
            else {
                const token: Token = .{
                    .kind = kind,
                    .loc = .{
                        .file_id = self.file_id,
                        .start = start,
                        .end = end,
                        .line = self.line,
                        .col = self.col,
                    },
                    .has_nl_before = self.has_nl_before,
                };
                
                self.reporter.reportErrorAtToken(token, "Invalid float literal", .{});
            }
        }
        
        self.pushToken(kind, start, end);
    }
    
    fn tokenizeDivOrComment(self: *Lexer) void {
        const start = self.chs.index - 1;
        
        // Single line comment
        if (self.chs.peek() == '/') {
            var ch = self.chs.next();
            
            while (ch > 0) : (ch = self.chs.next()) {
                if (ch == '\n') {
                    self.line += 1;
                    self.col = 1;
                    break;
                }
            }
        }
        // Multi line comment
        else if (self.chs.peek() == '*') {
            _ = self.chs.next();
            
            var closed = false;
            var ch = self.chs.next();
            
            while (ch > 0): (ch = self.chs.next()) {
                if (ch == '*' and self.chs.peek() == '/') {
                    _ = self.chs.next();
                    closed = true;
                    break;
                }
                else if (ch == '\n') {
                    self.line += 1;
                    self.col = 1;
                }
            }
            
            if (!closed) {
                self.reporter.reportErrorAtPos(self.file_id, self.line, self.col, start, self.chs.index, "Unclosed comment", .{});
            }
        }
        else {
            self.pushTokenMaybeTwo('=', .Div, .DivEq, start);
        }
    }
    
    fn tokenizeStringLit(self: *Lexer) void {
        const start = self.chs.index - 1;
        var end = start + 1;
        var closed = false;
        var ch = self.chs.next();
        
        while (ch > 0) : (ch = self.chs.next()) {
            end += 1;
            
            if (ch == '"') {
                closed = true;
                break;
            }
            else if (ch == '\n') {
                self.reporter.reportErrorAtPos(self.file_id, self.line, self.col, start, end - start, "Unclosed string literal", .{});
            }
        }
        
        if (closed) {
            if (self.chs.peek() == 'c') {
                _ = self.chs.next();
                self.pushToken(.CstringLit, start, end + 1);
            }
            else {
                self.pushToken(.StringLit, start, end);
            }
        }
        else {
            self.reporter.reportErrorAtPos(self.file_id, self.line, self.col, start, end - start, "Unclosed string literal", .{});
        }
    }
    
    fn tokenizeCharLit(self: *Lexer) void {
        const start = self.chs.index - 1;
        var end = start + 1;
        var ch = self.chs.next();
        end += 1;
        
        if (ch == '\\') {
            switch (self.chs.next()) {
                'n', 'r', 't', '\'', '"', '\\' => {
                    end += 1;
                },
                
                else => {
                    self.reporter.reportErrorAtPos(self.file_id, self.line, self.col, start + 1, 2, "Invalid char escape", .{});
                }
            }
        }
        else if (ch == '\'') {
            self.reporter.reportErrorAtPos(self.file_id, self.line, self.col, start, 2, "Invalid char literal", .{});
        }
        
        const should_be_close_quote = self.chs.next();
        
        if (should_be_close_quote == '\'') {
            self.pushToken(.CharLit, start, end + 1);
        }
        else {
            while (ch > 0) : (ch = self.chs.next()) {
                end += 1;
                
                if (ch == '\'') {
                    break;
                }
            }
            
            self.reporter.reportErrorAtPos(self.file_id, self.line, self.col, start, end - start + 1, "Invalid char literal", .{});
        }
    }
    
    fn pushToken(self: *Lexer, kind: TokenKind, start: usize, end: usize) void {
        self.tokens.append(self.allocator, .{
            .kind = kind,
            .loc = .{
                .file_id = self.file_id,
                .start = start,
                .end = end,
                .line = self.line,
                .col = self.col,
            },
            .has_nl_before = self.has_nl_before,
        }) catch {};
        
        self.has_nl_before = false;
        self.col += end - start;
    }
    
    fn pushTokenOne(self: *Lexer, kind: TokenKind, index: usize) void {
        self.pushToken(kind, index, index + 1);
    }
    
    fn pushTokenMaybeTwo(self: *Lexer, next: u8, kind_one: TokenKind, kind_two: TokenKind, index: usize) void {
        const ch = self.chs.peek();
        
        if (ch == next) {
            _ = self.chs.next();
            self.pushToken(kind_two, index, index + 2);
        }
        else {
            self.pushToken(kind_one, index, index + 1);
        }
    }
    
    fn pushTokenMaybeTwoMulti(self: *Lexer, nexts: []const u8, kind_one: TokenKind, kind_twos: []const TokenKind, index: usize) void {
        std.debug.assert(nexts.len == kind_twos.len);
        
        const ch = self.chs.peek();
        
        for (0..nexts.len) |i| {
            if (ch == nexts[i]) {
                _ = self.chs.next();
                self.pushToken(kind_twos[i], index, index + 2);
                
                return;
            }
        }
        
        self.pushToken(kind_one, index, index + 1);
    }
    
    fn pushTokenMaybeThree(
        self: *Lexer,
        next2: u8, next3: u8,
        kind_one: TokenKind, kind_two: TokenKind, kind_three: TokenKind,
        index: usize,
    ) void {
        const ch2 = self.chs.peek();
        
        if (ch2 == next2) {
            const ch3 = self.chs.peekN(2);
            
            if (ch3 == next3) {
                _ = self.chs.next();
                _ = self.chs.next();
                self.pushToken(kind_three, index, index + 3);
            }
            else {
                _ = self.chs.next();
                self.pushToken(kind_two, index, index + 2);
            }
        }
        else {
            self.pushToken(kind_one, index, index + 1);
        }
    }
};

pub fn tokenize(allocator: std.mem.Allocator, reporter: *const Reporter, file_id: usize, src: []const u8) ![]Token {
    var lexer = try Lexer.init(allocator, reporter, file_id, src);
    var ch: u8 = lexer.chs.next();
    
    while (ch > 0) {
        const i = lexer.chs.index - 1;
        
        switch (ch) {
            '\n' => {
                lexer.line += 1;
                lexer.col = 1;
                lexer.has_nl_before = true;
            },
            ' ' => {
                lexer.col += 1;
            },
            
            '_',
            'A'...'Z',
            'a'...'z'   => lexer.tokenizeIdentOrKeyword(),
            '0'...'9'   => lexer.tokenizeNumber(),
            
            '/'         => lexer.tokenizeDivOrComment(),
            
            '"'         => lexer.tokenizeStringLit(),
            '\''        => lexer.tokenizeCharLit(),
            
            '('         => lexer.pushTokenOne(.OpenParen, i),
            ')'         => lexer.pushTokenOne(.CloseParen, i),
            '{'         => lexer.pushTokenOne(.OpenCurlyBracket, i),
            '}'         => lexer.pushTokenOne(.CloseCurlyBracket, i),
            '['         => lexer.pushTokenOne(.OpenSqBracket, i),
            ']'         => lexer.pushTokenOne(.CloseSqBracket, i),
            ','         => lexer.pushTokenOne(.Comma, i),
            ';'         => lexer.pushTokenOne(.Semicolon, i),
            '?'         => lexer.pushTokenOne(.QMark, i),
            '@'         => lexer.pushTokenOne(.At, i),
            
            ':'         => lexer.pushTokenMaybeTwo(':', .Colon, .ColonColon, i),
            '-'         => lexer.pushTokenMaybeTwo('=', .Minus, .MinusEq, i),
            '%'         => lexer.pushTokenMaybeTwo('=', .Mod, .ModEq, i),
            '^'         => lexer.pushTokenMaybeTwo('=', .Xor, .XorEq, i),
            '<'         => lexer.pushTokenMaybeTwo('=', .Lt, .Lte, i),
            '>'         => lexer.pushTokenMaybeTwo('=', .Gt, .Gte, i),
            '!'         => lexer.pushTokenMaybeTwo('=', .Not, .NotEq, i),
            '|'         => lexer.pushTokenMaybeTwo('|', .Or, .OrOr, i),
            '&'         => lexer.pushTokenMaybeTwo('&', .And, .AndAnd, i),
            '='         => lexer.pushTokenMaybeTwoMulti(&.{'=', '>'}, .Eq, &.{.EqEq, .Arrow}, i),
            
            '.'         => lexer.pushTokenMaybeThree('.', '.', .Dot, .DotDot, .DotDotDot, i),
            
            '+' => {
                const peek = lexer.chs.peek();
                
                if (peek == '=') {
                    _ = lexer.chs.next();
                    lexer.pushToken(.PlusEq, i, i + 2);
                }
                else if (peek == '+') {
                    _ = lexer.chs.next();
                    lexer.pushToken(.PlusPlus, i, i + 2);
                }
                else {
                    lexer.pushToken(.Plus, i, i + 1);
                }
            },
            
            '*' => {
                const peek = lexer.chs.peek();
                
                if (peek == '=') {
                    _ = lexer.chs.next();
                    lexer.pushToken(.MulEq, i, i + 2);
                }
                else if (peek == '*') {
                    _ = lexer.chs.next();
                    lexer.pushToken(.MulMul, i, i + 2);
                }
                else {
                    lexer.pushToken(.Mul, i, i + 1);
                }
            },
            
            else => {
                reporter.reportErrorAtPos(file_id, lexer.line, lexer.col, i, 1, "Unknown character '{c}'", .{ ch });
            },
        }
        
        ch = lexer.chs.next();
    }
    
    return lexer.tokens.items;
}