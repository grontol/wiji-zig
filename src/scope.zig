const std = @import("std");
const Symbol = @import("symbol.zig").Symbol;
const TypedSymbol = @import("symbol.zig").TypedSymbol;
const Mutability = @import("symbol.zig").Mutability;
const Type = @import("type.zig").Type;

pub const ScopeMode = enum {
    module,
    container,
    local,
};

pub const Scope = struct {
    parent: ?*Scope,
    syms: std.StringHashMap(TypedSymbol),
    allocator: std.mem.Allocator,
    mode: ScopeMode,
    
    pub fn init(allocator: std.mem.Allocator, mode: ScopeMode) Scope {
        return .{
            .parent = null,
            .syms = std.StringHashMap(TypedSymbol).init(allocator),
            .allocator = allocator,
            .mode = mode,
        };
    }
    
    // pub fn deinit(self: *Scope) void {
    //     self.syms.deinit();
    // }
    
    pub fn inherit(self: *Scope) *Scope {
        const scope = self.allocator.create(Scope) catch unreachable;
        scope.* = .{
            .parent = self,
            .syms = std.StringHashMap(TypedSymbol).init(self.allocator),
            .allocator = self.allocator,
            .mode = self.mode,
        };
        
        return scope;
    }
    
    pub fn inheritWithMode(self: *Scope, mode: ScopeMode, allocator: std.mem.Allocator) *Scope {
        const scope = allocator.create(Scope) catch unreachable;
        scope.* = .{
            .parent = self,
            .syms = std.StringHashMap(TypedSymbol).init(allocator),
            .allocator = allocator,
            .mode = mode,
        };
        
        return scope;
    }
    
    pub fn has(self: *const Scope, key: []const u8) bool {
        return self.syms.contains(key) or (self.parent != null and self.parent.?.has(key));
    }
    
    pub fn hasSelf(self: *const Scope, key: []const u8) bool {
        return self.syms.contains(key);
    }
    
    pub fn get(self: *const Scope, key: []const u8) ?TypedSymbol {
        const res = self.syms.get(key);
        if (res) |r| return r;
        
        if (self.parent) |p| {
            return p.get(key);
        }
        
        return null;
    }
    
    pub fn set(self: *Scope, key: []const u8, symbol: Symbol, typ: *const Type, comptime_known: bool, mutability: Mutability) void {
        const typed_symbol = TypedSymbol{
            .symbol = symbol,
            .typ = typ,
            .child_symbols = null,
            .comptime_known = comptime_known,
            .mutability = mutability,
        };
        
        self.syms.put(key, typed_symbol) catch unreachable;
    }
    
    pub fn setChildSymbols(self: *Scope, key: []const u8, child_symbols: *std.StringHashMap(TypedSymbol)) void {
        const symbol = self.syms.getPtr(key);
        
        if (symbol) |sym| {
            sym.child_symbols = child_symbols;
        }
        else {
            std.debug.panic("Scope doesn't have symbol `{s}`", .{key});
        }
    }
    
    pub fn setTypedSymbol(self: *Scope, key: []const u8, typed_symbol: TypedSymbol) void {
        self.syms.put(key, typed_symbol) catch unreachable;
    }
    
    pub fn makeChildSymbols(self: *Scope, allocator: std.mem.Allocator) *std.StringHashMap(TypedSymbol) {
        const child_symbol = allocator.create(std.StringHashMap(TypedSymbol)) catch unreachable;
        child_symbol.* = self.syms.cloneWithAllocator(allocator) catch unreachable;
        
        return child_symbol;
    }
};
