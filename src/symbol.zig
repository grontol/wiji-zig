const std = @import("std");
const Type = @import("type.zig").Type;

pub const Symbol = struct {
    id: usize,
    text: []const u8,
};

pub const TypedSymbol = struct {
    symbol: Symbol,
    typ: *const Type,
};

pub const SymbolManager = struct {
    allocator: std.mem.Allocator,
    name_map: std.StringHashMap([]const u8),
    name_list: StringList,
    global_index: usize,
    
    pub fn init(allocator: std.mem.Allocator) SymbolManager {
        return .{
            .allocator = allocator,
            .name_map = std.StringHashMap([]const u8).init(allocator),
            .name_list = StringList.init(allocator),
            .global_index = 0,
        };
    }
    
    pub fn createSymbol(self: *SymbolManager, name: []const u8) Symbol {
        const saved_name = blk: {
            const res = self.name_map.get(name);
            if (res) |r| {
                break :blk r;
            }
            
            const new_name = self.name_list.append(name);
            self.name_map.put(name, new_name) catch unreachable;
            
            break :blk new_name;
        };
        
        const sym = Symbol{
            .id = self.global_index,
            .text = saved_name,
        };
        
        self.global_index += 1;
        
        return sym;
    }
    
    pub fn pushNamespace(self: *SymbolManager, namespace: Symbol) void {
        _ = self;
        _ = namespace;
    }
    
    pub fn popNamespace(self: *SymbolManager) void {
        _ = self;
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