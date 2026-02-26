const std = @import("std");
const Symbol = @import("symbol.zig").Symbol;

const TYPE_FLAG_INT       = (1 << (8 + 0));
const TYPE_FLAG_UNSIGNED  = (1 << (8 + 1));
const TYPE_FLAG_FLOAT     = (1 << (8 + 2));
const TYPE_FLAG_UNTYPED   = (1 << (8 + 3));

pub const NumericKind = enum(u16) {
    i8 = TYPE_FLAG_INT,
    i16,
    i32,
    i64,
    
    u8 = TYPE_FLAG_INT | TYPE_FLAG_UNSIGNED,
    u16,
    u32,
    u64,
    
    f32 = TYPE_FLAG_FLOAT,
    f64,
    
    untyped_int     = TYPE_FLAG_INT   | TYPE_FLAG_UNTYPED,
    untyped_float   = TYPE_FLAG_FLOAT | TYPE_FLAG_UNTYPED,
    
    pub fn isInt(self: NumericKind) bool {
        return @intFromEnum(self) & TYPE_FLAG_INT != 0;
    }
    
    pub fn isFloat(self: NumericKind) bool {
        return @intFromEnum(self) & TYPE_FLAG_FLOAT != 0;
    }
    
    pub fn isUntyped(self: NumericKind) bool {
        return @intFromEnum(self) & TYPE_FLAG_UNTYPED != 0;
    }
    
    pub fn isUnsigned(self: NumericKind) bool {
        return @intFromEnum(self) & TYPE_FLAG_UNSIGNED != 0;
    }
};

pub const TypeKind = enum {
    unknown,
    void,
    numeric,
    string,
    char,
    bool,
    enumm,
    any,
    range,
    
    func,
    array,
    struc,
    reference,
    pointer,
    nullable,
    tuple,
    generic,
};

pub const TypeFunc = struct {
    params: []const *const Type,
    returns: *const Type,
    is_variadic: bool,
};

pub const TypeArray = struct {
    child: *const Type,
    len: usize,
    sized: bool,
};

pub const TypeStructField = struct {
    name: Symbol,
    typ: *const Type,
    offset: usize,
    default_value: ?*anyopaque,
};

pub const TypeStruct = struct {
    name: Symbol,
    fields: []const TypeStructField,
};

pub const Type = struct {
    kind: TypeKind,
    value: union(TypeKind) {
        unknown,
        void,
        numeric: NumericKind,
        string,
        char,
        bool,
        enumm,
        any,
        range,
        func: TypeFunc,
        array: TypeArray,
        struc: TypeStruct,
        reference: struct {
            child: *const Type,
        },
        pointer: struct {
            child: *const Type,
        },
        nullable: struct {
            child: *const Type,
        },
        tuple: struct {
            childen: []const *const Type,
        },
        generic: struct {
            childen: []const *const Type,
        },
    },
    size: u16,
    alignment: u16,
    type_id: u64,
    hash: u64,
    
    pub fn canBeAssignedTo(self: *const Type, other: *const Type) bool {
        if (other.value == TypeKind.any) return true;
        if (self.isSame(other)) return true;
        if (self.kind != other.kind) return false;
        
        switch (self.kind) {
            TypeKind.numeric => {
                if (self.value.numeric == other.value.numeric) return true;
                
                // NOTE: Untyped int can be assigned to all numeric type
                if (self.value.numeric == NumericKind.untyped_int) {
                    return true;
                }
                // NOTE: Untyped float can be assigned to f32 & f64
                else if (self.value.numeric == NumericKind.untyped_float) {
                    switch (other.value.numeric) {
                        NumericKind.f32,
                        NumericKind.f64 => return true,
                        else => return false,
                    }
                }
                
                // TODO: Check for numeric coercion
                return false;
            },
            
            TypeKind.string,
            TypeKind.char => { return true; },
            TypeKind.array => {
                return self.value.array.child.isSame(other.value.array.child);
            },
            
            else => {
                std.debug.panic("TODO: Type.canBeAssignedTo {s}", .{@tagName(self.kind)});
            },
        }
        
        return true;
    }
    
    pub fn canBeUsedAsCond(self: *const Type) bool {
        switch (self.kind) {
            TypeKind.bool,
            TypeKind.numeric,
            TypeKind.char => return true,
            
            else => return false,
        }
    }
    
    pub fn canBeCombinedWith(self: *const Type, other: *const Type) bool {
        return self.isSame(other);
    }
    
    pub fn isSame(self: *const Type, other: *const Type) bool {
        if (self.type_id == other.type_id) return true;
        if (self.kind != other.kind) return false;
        
        switch (self.value) {
            TypeKind.bool,
            TypeKind.char,
            TypeKind.range,
            TypeKind.any,
            TypeKind.string,
            TypeKind.void,
            TypeKind.unknown => { return true; },
            
            TypeKind.numeric => {
                return self.value.numeric == other.value.numeric;
            },
            TypeKind.array => {
                return self.value.array.child.isSame(other.value.array.child);
            },
            TypeKind.func => {
                if (!self.value.func.returns.isSame(other.value.func.returns)) return false;
                if (self.value.func.params.len != other.value.func.params.len) return false;
                
                for (0..self.value.func.params.len) |i| {
                    if (!self.value.func.params[i].isSame(other.value.func.params[i])) return false;
                }
                
                return true;
            },
            else => {
                std.debug.panic("TODO: Type.isSame {s}", .{@tagName(self.value)});
            }
        }
    }
    
    pub fn coerceIntoRuntime(self: *const Type) *const Type {
        switch (self.value) {
            TypeKind.numeric => {
                switch (self.value.numeric) {
                    NumericKind.untyped_int => return &I32,
                    NumericKind.untyped_float => return &F32,
                    else => return self,
                }
            },
            else => {
                return self;
            },
        }
    }
    
    pub fn assignTo(self: *const Type, to: *const Type) *const Type {
        // TODO: Convert type do destination type
        // For example: const x: []u32 = .[1, 2, 3]
        // The type should be sized array
        
        _ = to;
        return self;
    }
    
    pub fn combinedWith(self: *const Type, other: *const Type) *const Type {
        _ = self;
        
        return other;
    }
    
    pub fn getTextLeak(self: *const Type, allocator: std.mem.Allocator) []const u8 {
        var str = std.ArrayList(u8).empty;
        self.getText(&str, allocator);
        return str.items;
    }
    
    pub fn getText(self: *const Type, out: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
        switch (self.value) {
            TypeKind.unknown => { out.appendSlice(allocator, "unknown") catch unreachable; },
            TypeKind.void    => { out.appendSlice(allocator, "void") catch unreachable; },
            TypeKind.string  => { out.appendSlice(allocator, "string") catch unreachable; },
            TypeKind.char    => { out.appendSlice(allocator, "char") catch unreachable; },
            TypeKind.bool    => { out.appendSlice(allocator, "bool") catch unreachable; },
            TypeKind.any     => { out.appendSlice(allocator, "any") catch unreachable; },
            TypeKind.range   => { out.appendSlice(allocator, "range") catch unreachable; },
            TypeKind.numeric => {
                switch (self.value.numeric) {
                    NumericKind.u8            => { out.appendSlice(allocator, "u8") catch unreachable; },
                    NumericKind.u16           => { out.appendSlice(allocator, "u16") catch unreachable; },
                    NumericKind.u32           => { out.appendSlice(allocator, "u32") catch unreachable; },
                    NumericKind.u64           => { out.appendSlice(allocator, "u64") catch unreachable; },
                    NumericKind.i8            => { out.appendSlice(allocator, "i8") catch unreachable; },
                    NumericKind.i16           => { out.appendSlice(allocator, "i16") catch unreachable; },
                    NumericKind.i32           => { out.appendSlice(allocator, "i32") catch unreachable; },
                    NumericKind.i64           => { out.appendSlice(allocator, "i64") catch unreachable; },
                    NumericKind.f32           => { out.appendSlice(allocator, "f32") catch unreachable; },
                    NumericKind.f64           => { out.appendSlice(allocator, "f64") catch unreachable; },
                    NumericKind.untyped_int   => { out.appendSlice(allocator, "int") catch unreachable; },
                    NumericKind.untyped_float => { out.appendSlice(allocator, "float") catch unreachable; },
                }
            },
            
            TypeKind.array => {
                out.appendSlice(allocator, "[") catch unreachable;
                
                if (self.value.array.sized) {
                    out.print(allocator, "{}", .{self.value.array.len}) catch unreachable;
                }
                
                out.appendSlice(allocator, "]") catch unreachable;
                self.value.array.child.getText(out, allocator);
            },
            
            TypeKind.func => {
                out.appendSlice(allocator, "fn(") catch unreachable;
                
                for (self.value.func.params, 0..) |param, i| {
                    if (i > 0) {
                        out.appendSlice(allocator, ", ") catch unreachable;
                    }
                    
                    param.getText(out, allocator);
                }
                
                out.appendSlice(allocator, "): ") catch unreachable;
                self.value.func.returns.getText(out, allocator);
            },
            
            TypeKind.struc => {
                out.print(allocator, "{s}", .{self.value.struc.name.text}) catch unreachable;
            },
            
            else => {
                std.debug.panic("TODO: Type.getText {s}", .{@tagName(self.value)});
            }
        }
    }
};

pub const UNKNOWN       = Type{ .size = 0,  .alignment = 0, .type_id = 0,  .hash = 0,  .kind = .unknown, .value = .unknown };
pub const VOID          = Type{ .size = 0,  .alignment = 0, .type_id = 1,  .hash = 1,  .kind = .void,    .value = .void };
pub const U8            = Type{ .size = 1,  .alignment = 1, .type_id = 2,  .hash = 2,  .kind = .numeric, .value = .{ .numeric = .u8 } };
pub const U16           = Type{ .size = 2,  .alignment = 2, .type_id = 3,  .hash = 3,  .kind = .numeric, .value = .{ .numeric = .u16 } };
pub const U32           = Type{ .size = 3,  .alignment = 3, .type_id = 4,  .hash = 4,  .kind = .numeric, .value = .{ .numeric = .u32 } };
pub const U64           = Type{ .size = 4,  .alignment = 4, .type_id = 5,  .hash = 5,  .kind = .numeric, .value = .{ .numeric = .u64 } };
pub const I8            = Type{ .size = 1,  .alignment = 1, .type_id = 6,  .hash = 6,  .kind = .numeric, .value = .{ .numeric = .i8 } };
pub const I16           = Type{ .size = 2,  .alignment = 2, .type_id = 7,  .hash = 7,  .kind = .numeric, .value = .{ .numeric = .i16 } };
pub const I32           = Type{ .size = 3,  .alignment = 3, .type_id = 8,  .hash = 8,  .kind = .numeric, .value = .{ .numeric = .i32 } };
pub const I64           = Type{ .size = 4,  .alignment = 4, .type_id = 9,  .hash = 9,  .kind = .numeric, .value = .{ .numeric = .i64 } };
pub const F32           = Type{ .size = 4,  .alignment = 4, .type_id = 10, .hash = 10, .kind = .numeric, .value = .{ .numeric = .f32 } };
pub const F64           = Type{ .size = 8,  .alignment = 8, .type_id = 11, .hash = 11, .kind = .numeric, .value = .{ .numeric = .f64 } };
pub const UNTYPED_INT   = Type{ .size = 8,  .alignment = 8, .type_id = 12, .hash = 12, .kind = .numeric, .value = .{ .numeric = .untyped_int } };
pub const UNTYPED_FLOAT = Type{ .size = 8,  .alignment = 8, .type_id = 13, .hash = 13, .kind = .numeric, .value = .{ .numeric = .untyped_float } };
pub const STRING        = Type{ .size = 16, .alignment = 8, .type_id = 14, .hash = 14, .kind = .string,  .value = .string };
pub const CHAR          = Type{ .size = 1,  .alignment = 1, .type_id = 15, .hash = 15, .kind = .char,    .value = .char };
pub const BOOL          = Type{ .size = 1,  .alignment = 1, .type_id = 16, .hash = 16, .kind = .bool,    .value = .bool };
pub const RANGE         = Type{ .size = 8,  .alignment = 4, .type_id = 17, .hash = 17, .kind = .range,   .value = .range };
pub const ANY           = Type{ .size = 8,  .alignment = 8, .type_id = 18, .hash = 18, .kind = .any,     .value = .any };

pub const TypeManager = struct {
    arena: std.mem.Allocator,
    temp_allocator: std.mem.Allocator,
    cur_index: usize = 64,
    type_map: TypeHashMap(),
    
    pub fn init(arena: std.mem.Allocator, temp_allocator: std.mem.Allocator) TypeManager {
        return .{
            .arena = arena,
            .temp_allocator = temp_allocator,
            .type_map = TypeHashMap().init(temp_allocator),
        };
    }
    
    pub fn deinit(self: *TypeManager) void {
        self.type_map.deinit();
    }
    
    pub fn createArray(self: *TypeManager, child: *const Type, len: ?usize) *const Type {
        var h = combineHash(@intFromEnum(TypeKind.array), child.hash);
        h = combineHash(h, if (len != null) 1 else 0);
        h = combineHash(h, if (len) |l| l else 0);
        
        const typ = Type{
            .kind = .array,
            .size = if (len) |l| @intCast(child.size * l) else 0,
            .alignment = child.alignment,
            .type_id = self.cur_index,
            .hash = h,
            .value = .{.array = .{
                .child = child,
                .len = len orelse 0,
                .sized = len != null,
            }},
        };
        
        const typ_ptr = self.type_map.get(typ);
        
        if (typ_ptr) |ptr| {
            return ptr;
        }
        else {
            const new_typ_ptr = self.arena.create(Type) catch unreachable;
            new_typ_ptr.* = typ;
            self.cur_index += 1;
            
            return new_typ_ptr;
        }
    }
    
    pub fn createReference(self: *TypeManager, child: *const Type) *const Type {
        const typ = Type{
            .kind = .reference,
            .size = 8,
            .alignment = child.alignment,
            .type_id = self.cur_index,
            .hash = combineHash(@intFromEnum(TypeKind.reference), child.hash),
            .value = .{.reference = .{
                .child = child,
            }},
        };
        
        const typ_ptr = self.type_map.get(typ);
        
        if (typ_ptr) |ptr| {
            return ptr;
        }
        else {
            const new_typ_ptr = self.arena.create(Type) catch unreachable;
            new_typ_ptr.* = typ;
            self.cur_index += 1;
            
            self.type_map.put(typ, new_typ_ptr) catch unreachable;
            
            return new_typ_ptr;
        }
    }
    
    pub fn createFn(self: *TypeManager, params: []const *const Type, return_typ: *const Type, is_variadic: bool) *const Type {
        var h = combineHash(@intFromEnum(TypeKind.func), params.len);
        for (params) |param| { h = combineHash(h, param.hash); }
        h = combineHash(h, if (is_variadic) 1 else 0);
        h = combineHash(h, return_typ.hash);
        
        const typ = Type{
            .kind = .func,
            .size = 8,
            .alignment = 8,
            .type_id = self.cur_index,
            .hash = h,
            .value = .{.func = .{
                .params = params,
                .returns = return_typ,
                .is_variadic = is_variadic,
            }},
        };
        
        const typ_ptr = self.type_map.get(typ);
        
        if (typ_ptr) |ptr| {
            return ptr;
        }
        else {
            const new_typ_ptr = self.arena.create(Type) catch unreachable;
            new_typ_ptr.* = typ;            
            self.cur_index += 1;
            
            return new_typ_ptr;
        }
    }
    
    pub fn createStruct(self: *TypeManager, name: Symbol, fields: []TypeStructField) *const Type {
        var h = combineHash(@intFromEnum(TypeKind.struc), fields.len);
        var size: u16 = 0;
        var alignment: u16 = 0;
        
        for (fields) |*field| {
            h = combineHash(h, field.typ.hash);
            
            const field_size = field.typ.size;
            
            if (size % field_size > 0) {
                size += field_size - (size % field_size);
            }
            
            field.offset = size;
            
            if (field_size > alignment) {
                alignment = field_size;
            }
            
            size += field_size;
        }
        
        if (size % alignment > 0) {
            size += alignment - (size % alignment);
        }
        
        const typ = Type{
            .kind = .struc,
            .size = size,
            .alignment = alignment,
            .type_id = self.cur_index,
            .hash = h,
            .value = .{.struc = .{
                .name = name,
                .fields = fields,
            }},
        };
        
        const typ_ptr = self.type_map.get(typ);
        
        if (typ_ptr) |ptr| {
            return ptr;
        }
        else {
            const new_typ_ptr = self.arena.create(Type) catch unreachable;
            new_typ_ptr.* = typ;
            self.cur_index += 1;
            
            return new_typ_ptr;
        }
    }
};

fn TypeHashMap() type {
    const Context = struct {        
        pub fn hash(_: @This(), key: Type) u64 {
            return key.hash;
        }
        
        pub fn eql(_: @This(), a: Type, b: Type) bool {
            return a.isSame(&b);
        }
    };
    
    return std.HashMap(Type, *const Type, Context, std.hash_map.default_max_load_percentage);
}

fn combineHash(a: u64, b: u64) u64 {
    var x = a ^ b;
    x ^= x >> 32;
    x *%= 0xd6e8feb86659fd93;
    x ^= x >> 32;
    x *%= 0xd6e8feb86659fd93;
    x ^= x >> 32;
    
    return x;
}