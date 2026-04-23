const std = @import("std");
const Symbol = @import("symbol.zig").Symbol;
const TypedSymbol = @import("symbol.zig").TypedSymbol;
const Mutability = @import("symbol.zig").Mutability;
const types = @import("type.zig");
const Type = types.Type;

pub const ScopeMode = enum {
    module,
    container,
    local,
};

pub const Scope = struct {
    parent: ?*Scope,
    syms: std.StringHashMap(TypedSymbol),
    child_scopes: std.StringHashMap(*Scope),
    impls: std.AutoHashMap(u64, *types.Impl),
    allocator: std.mem.Allocator,
    mode: ScopeMode,
    
    pub fn init(allocator: std.mem.Allocator, mode: ScopeMode) Scope {
        return .{
            .parent = null,
            .syms = std.StringHashMap(TypedSymbol).init(allocator),
            .child_scopes = std.StringHashMap(*Scope).init(allocator),
            .impls = std.AutoHashMap(u64, *types.Impl).init(allocator),
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
            .child_scopes = std.StringHashMap(*Scope).init(self.allocator),
            .impls = std.AutoHashMap(u64, *types.Impl).init(self.allocator),
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
            .child_scopes = std.StringHashMap(*Scope).init(allocator),
            .impls = std.AutoHashMap(u64, *types.Impl).init(allocator),
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
    
    pub fn getPtr(self: *const Scope, key: []const u8) ?*TypedSymbol {
        const res = self.syms.getPtr(key);
        if (res) |r| return r;
        
        if (self.parent) |p| {
            return p.getPtr(key);
        }
        
        return null;
    }    
    
    pub fn set(self: *Scope, key: []const u8, symbol: Symbol, typ: *const Type, comptime_known: bool, mutability: Mutability) void {
        const typed_symbol = TypedSymbol{
            .symbol = symbol,
            .typ = typ,
            .comptime_known = comptime_known,
            .mutability = mutability,
        };
        
        self.syms.put(key, typed_symbol) catch unreachable;
    }
    
    pub fn setType(self: *Scope, key: []const u8, typ: *const Type) void {
        const symbol = self.syms.getPtr(key);
        
        if (symbol) |sym| {
            sym.typ = typ;
        }
        else {
            std.debug.panic("Scope doesn't have symbol `{s}`", .{key});
        }
    }
    
    pub fn setChildScope(self: *Scope, key: []const u8, child_scope: *Scope) void {
        self.child_scopes.put(key, child_scope) catch unreachable;
    }
    
    pub fn getChildScopeSymbol(self: *Scope, key: []const u8, item_key: []const u8) ?TypedSymbol {
        if (self.child_scopes.get(key)) |child_scope| {
            return child_scope.syms.get(item_key);
        }
        
        if (self.parent) |p| {
            return p.getChildScopeSymbol(key, item_key);
        }
        
        return null;
    }
    
    pub fn setTypedSymbol(self: *Scope, key: []const u8, typed_symbol: TypedSymbol) void {
        self.syms.put(key, typed_symbol) catch unreachable;
    }
    
    pub fn setImpl(self: *Scope, type_id: u64, impl: *types.Impl) void {
        self.impls.put(type_id, impl) catch unreachable;
    }
    
    pub fn getImplField(self: *Scope, type_id: u64, key: []const u8) ?*const types.TypeImplField {
        if (self.impls.get(type_id)) |impl| {
            if (impl.field_map.get(key)) |index| {
                return &impl.fields[index];
            }
        }
        
        if (self.parent) |parent| {
            return parent.getImplField(type_id, key);
        }
        
        return null;
    }
    
    pub fn getImplMethod(self: *Scope, type_id: u64, key: []const u8) ?*const types.TypeMethod {
        if (self.impls.get(type_id)) |impl| {
            if (impl.method_map.get(key)) |index| {
                return &impl.methods[index];
            }
        }
        
        if (self.parent) |parent| {
            return parent.getImplMethod(type_id, key);
        }
        
        return null;
    }
};
