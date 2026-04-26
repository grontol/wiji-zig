const std = @import("std");
const Type = @import("type.zig").Type;
const Token = @import("token.zig").Token;
const FileManager = @import("file_manager.zig");

pub const Symbol = struct {
    id: usize,
    text: []const u8,
    namespaces: []const []const u8,
    token: Token,
    parent: ?*Symbol,
    is_main_fn: bool = false,
};

pub const Mutability = enum {
    constant,
    immutable,
    mutable,
};

pub const TypedSymbol = struct {
    symbol: *Symbol,
    typ: *const Type,
    comptime_known: bool,
    mutability: Mutability,
};

pub const SymbolManager = struct {
    allocator: std.mem.Allocator,
    file_manager: *const FileManager,
    name_map: std.StringHashMap([]const u8),
    name_list: StringList,
    global_index: usize,
    usage_map: std.AutoHashMap(usize, std.ArrayList(?*Symbol)),
    namespaces: std.ArrayList([]const u8) = .empty,
    unnamed_index: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator, file_manager: *const FileManager) SymbolManager {
        return .{
            .allocator = allocator,
            .file_manager = file_manager,
            .name_map = std.StringHashMap([]const u8).init(allocator),
            .name_list = StringList.init(allocator),
            .usage_map = std.AutoHashMap(usize, std.ArrayList(?*Symbol)).init(allocator),
            .global_index = 0,
        };
    }
    
    pub fn createSymbol(self: *SymbolManager, name_token: Token, namespaced: bool, parent: ?*Symbol) *Symbol {
        const name = self.file_manager.getTokenText(name_token);
        const namespaces = if (namespaced) self.allocator.dupe([]const u8, self.namespaces.items) catch unreachable
        else &.{};
        
        const sym = self.allocator.create(Symbol) catch unreachable;
        sym.* = Symbol{
            .id = self.global_index,
            .text = self.createName(name),
            .token = name_token,
            .namespaces = namespaces,
            .parent = parent,
        };
        
        self.global_index += 1;
        
        return sym;
    }
    
    pub fn createUnnamedSymbol(self: *SymbolManager, prefix: []const u8, placeholder_token: Token, namespaced: bool, parent: ?*Symbol) *Symbol {
        const index = self.unnamed_index;
        self.unnamed_index += 1;
        
        const name = std.fmt.allocPrint(self.allocator, "_{s}_{}", .{prefix, index}) catch unreachable;
        const namespaces = if (namespaced) self.allocator.dupe([]const u8, self.namespaces.items) catch unreachable
        else &.{};
        
        const sym = self.allocator.create(Symbol) catch unreachable;
        sym.* = Symbol{
            .id = self.global_index,
            .text = name,
            .token = placeholder_token,
            .namespaces = namespaces,
            .parent = parent,
        };
        
        self.global_index += 1;
        
        return sym;
    }
    
    pub fn cloneSymbol(self: *SymbolManager, symbol: *const Symbol) *Symbol {
        const new_name = std.fmt.allocPrint(self.allocator, "{s}_{}", .{symbol.text, self.global_index}) catch unreachable;
        
        const sym = self.allocator.create(Symbol) catch unreachable;
        sym.* = symbol.*;
        
        sym.id = self.global_index;
        sym.text = new_name;
        
        self.global_index += 1;
        return sym;
    }
    
    pub fn pushNamespace(self: *SymbolManager, namespace: []const u8) void {
        self.namespaces.append(self.allocator, namespace) catch unreachable;
    }
    
    pub fn popNamespace(self: *SymbolManager) void {
        _ = self.namespaces.pop();
    }
    
    pub fn addUsage(self: *SymbolManager, symbol: *Symbol, parent_symbol: ?*Symbol) void {
        if (self.usage_map.getPtr(symbol.id)) |usage| {
            usage.append(self.allocator, if (parent_symbol) |s| s else null) catch unreachable;
        }
        else {
            var list = std.ArrayList(?*Symbol).empty;
            list.append(self.allocator, if (parent_symbol) |s| s else null) catch unreachable;
            
            self.usage_map.put(symbol.id, list) catch unreachable;
        }
    }
    
    pub fn getUsage(self: *const SymbolManager, symbol: *Symbol) usize {
        if (self.usage_map.get(symbol.id)) |usage| {
            return usage.items.len;
        }
        
        return 0;
    }
    
    pub fn removeUnusedSymbols(self: *SymbolManager) void {
        var has_removed = true;
        
        while (has_removed) {
            has_removed = false;
            var iter = self.usage_map.iterator();
            
            while (iter.next()) |entry| {
                var i: i64 = @as(i64, @intCast(entry.value_ptr.items.len)) - 1;
                
                while (i >= 0) : (i -= 1) {
                    var removed = false;
                    const index = @as(usize, @intCast(i));
                    
                    if (entry.value_ptr.items[index]) |s| {
                        var cur_s: ?*Symbol = s;
                        
                        while (cur_s) |cs| {                        
                            if (!cs.is_main_fn and self.getUsage(cs) == 0) {
                                removed = true;
                                break;
                            }
                            
                            cur_s = cs.parent;
                        }
                    }
                    
                    if (removed) {
                        _ = entry.value_ptr.orderedRemove(index);
                        has_removed = true;
                    }
                }            
            }
        }
    }
    
    fn createName(self: *SymbolManager, name: []const u8) []const u8 {
        const res = self.name_map.get(name);
        if (res) |r| {
            return r;
        }
        
        const new_name = self.name_list.append(name);
        self.name_map.put(name, new_name) catch unreachable;
        
        return new_name;
    }
};

const StringList = struct {
    const BUCKET_SIZE = 512 * 1024;
    
    allocator: std.mem.Allocator,
    first_bucket: *Bucket,
    cur_bucket: *Bucket,
    
    fn init(allocator: std.mem.Allocator) StringList {
        const first_bucket = createBucket(allocator);
        
        return .{
            .allocator = allocator,
            .first_bucket = first_bucket,
            .cur_bucket = first_bucket,
        };
    }
    
    fn append(self: *StringList, text: []const u8) []const u8 {
        std.debug.assert(text.len <= BUCKET_SIZE);
        
        if (self.cur_bucket.len + text.len > BUCKET_SIZE) {
            const new_bucket = createBucket(self.allocator);
            new_bucket.prev = self.cur_bucket;
            self.cur_bucket.next = new_bucket;
            self.cur_bucket = new_bucket;
        }
        
        const dest = self.cur_bucket.data[self.cur_bucket.len..self.cur_bucket.len + text.len];
        std.mem.copyForwards(u8, dest, text);
        self.cur_bucket.len += text.len;
        return dest;
    }
    
    fn createBucket(allocator: std.mem.Allocator) *Bucket {
        const bucket: *Bucket = allocator.create(Bucket) catch unreachable;
        bucket.* = .{
            .prev = null,
            .next = null,
            .data = allocator.alloc(u8, BUCKET_SIZE) catch unreachable,
        };
        
        return bucket;
    }
};

const Bucket = struct {
    prev: ?*Bucket,
    next: ?*Bucket,
    data: []u8,
    len: usize = 0,
};