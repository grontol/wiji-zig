const std = @import("std");
const FileManager = @import("file_manager.zig");

const TAG_KEYWORD    = 0x0001;
const TAG_DIRECTIVE  = 0x0002;
const TAG_SYMBOL     = 0x0003;
const TAG_ASSIGNMENT = 0x0004;
const TAG_BINOP      = 0x0005;
const TAG_LITERAL    = 0x0006;
const TAG_OTHER      = 0x0007;

pub const TokenKind = enum(u16) {
    None,
    Unknown,
    
    KeywordFn = TAG_KEYWORD << 8,
    KeywordFor,
    KeywordWhile,
    KeywordBreak,
    KeywordIn,
    KeywordIf,
    KeywordElse,
    KeywordSwitch,
    KeywordPub,
    KeywordStruct,
    KeywordEnum,
    KeywordInterface,
    KeywordImport,
    KeywordAs,
    KeywordVal,
    KeywordVar,
    KeywordConst,
    KeywordExtern,
    KeywordReturn,
    KeywordContinue,
    KeywordDyn,
    KeywordUsing,
    KeywordImpl,
    
    OpenParen = TAG_SYMBOL << 8,
    CloseParen,
    OpenCurlyBracket,
    CloseCurlyBracket,
    OpenSqBracket,
    CloseSqBracket,
    Comma,
    Dot,
    DotDot,
    DotDotDot,
    Colon,
    ColonColon,
    Semicolon,
    QMark,
    At,
    Arrow,
    
    Eq = TAG_ASSIGNMENT << 8,
    PlusEq,
    MinusEq,
    MulEq,
    DivEq,
    ModEq,
    XorEq,
    
    Plus = TAG_BINOP << 8,
    PlusPlus,
    Minus,
    Mul,
    MulMul,
    Div,
    Mod,
    Xor,
    Gt,
    Gte,
    Lt,
    Lte,
    EqEq,
    Not,
    NotEq,
    Or,
    OrOr,
    And,
    AndAnd,
    
    IntLit = TAG_LITERAL << 8,
    IntBinLit,
    IntOctLit,
    IntHexLit,
    FloatLit,
    StringLit,
    CstringLit,
    CharLit,
    TrueLit,
    FalseLit,
    
    Identifier = TAG_OTHER << 8,
    
    pub fn is_assignment(self: TokenKind) bool {
        return @intFromEnum(self) >> 8 == TAG_ASSIGNMENT;
    }
    
    pub fn is_binop(self: TokenKind) bool {
        return @intFromEnum(self) >> 8 == TAG_BINOP;
    }
    
    pub fn getBinopText(self: TokenKind) []const u8 {
        switch (self) {
            .Plus     => { return "+"; },
            .Minus    => { return "-"; },
            .Mul      => { return "*"; },
            .MulMul   => { return "**"; },
            .Div      => { return "/"; },
            .Mod      => { return "%"; },
            .Xor      => { return "^"; },
            .Gt       => { return ">"; },
            .Gte      => { return ">="; },
            .Lt       => { return "<"; },
            .Lte      => { return "<="; },
            .EqEq     => { return "=="; },
            .Not      => { return "!"; },
            .NotEq    => { return "!="; },
            .Or       => { return "|"; },
            .OrOr     => { return "||"; },
            .And      => { return "&"; },
            .AndAnd   => { return "&&"; },
            .PlusPlus => { return "++"; },
            
            else    => { return "???"; },
        }
    }
};

pub const TokenLoc = struct {
    file_id: usize,
    index: usize,
    len: usize,
    line: usize,
    col: usize,
};

pub const Token = struct {
    kind: TokenKind,
    loc: TokenLoc,
    has_nl_before: bool,
    
    pub fn default() Token {
        return .{
            .kind = .None,
            .loc = .{
                .file_id = 0,
                .index = 0,
                .len = 0,
                .line = 0,
                .col = 0,
            },
            .has_nl_before = false,
        };
    }
    
    pub fn print(self: Token, writer: *std.Io.Writer, file_manager: *const FileManager) void {
        const filename = file_manager.getFilename(self.loc.file_id);
        const src = file_manager.getContent(self.loc.file_id);
        
        writer.print("{s}:{d}:{d} => {s} '{s}'\n", .{
            filename,
            self.loc.line,
            self.loc.col,
            @tagName(self.kind),
            src[self.loc.index..(self.loc.index + self.loc.len)],
        }) catch unreachable;
    }
};

pub const TokenSpan = struct {
    file_id: usize,
    start: usize,
    end: usize,
    line: usize,
    col: usize,
    
    pub fn from_token(token: Token) TokenSpan {
        return .{
            .file_id = token.loc.file_id,
            .start = token.loc.index,
            .end = token.loc.index + token.loc.len,
            .line = token.loc.line,
            .col = token.loc.col,
        };
    }
    
    pub fn from_tokens(start: Token, end: Token) TokenSpan {
        return .{
            .file_id = start.loc.file_id,
            .start = start.loc.index,
            .end = end.loc.index + end.loc.len,
            .line = start.loc.line,
            .col = start.loc.col,
        };
    }
    
    pub fn from_token_and_span(token: Token, end: TokenSpan) TokenSpan {
        return .{
            .file_id = token.loc.file_id,
            .start = token.loc.index,
            .end = end.end,
            .line = token.loc.line,
            .col = token.loc.col,
        };
    }
    
    pub fn from_span_and_token(start: TokenSpan, end: Token) TokenSpan {
        return .{
            .file_id = start.file_id,
            .start = start.start,
            .end = end.loc.index + end.loc.len,
            .line = start.line,
            .col = start.col,
        };
    }
    
    pub fn from_spans(start: TokenSpan, end: TokenSpan) TokenSpan {
        return .{
            .file_id = start.file_id,
            .start = start.start,
            .end = end.end,
            .line = start.line,
            .col = start.col,
        };
    }
};