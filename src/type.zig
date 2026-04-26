const std = @import("std");
const Token = @import("token.zig").Token;
const Symbol = @import("symbol.zig").Symbol;
const Reporter = @import("reporter.zig");

pub const UNKNOWN       = &Type{ .size = 0,  .alignment = 0, .type_id = 0,  .hash = 0,  .kind = .unknown, .value = .unknown };
pub const VOID          = &Type{ .size = 0,  .alignment = 0, .type_id = 1,  .hash = 1,  .kind = .void,    .value = .void };
pub const U8            = &Type{ .size = 1,  .alignment = 1, .type_id = 2,  .hash = 2,  .kind = .numeric, .value = .{ .numeric = .u8 } };
pub const U16           = &Type{ .size = 2,  .alignment = 2, .type_id = 3,  .hash = 3,  .kind = .numeric, .value = .{ .numeric = .u16 } };
pub const U32           = &Type{ .size = 4,  .alignment = 4, .type_id = 4,  .hash = 4,  .kind = .numeric, .value = .{ .numeric = .u32 } };
pub const U64           = &Type{ .size = 8,  .alignment = 8, .type_id = 5,  .hash = 5,  .kind = .numeric, .value = .{ .numeric = .u64 } };
pub const USize         = &Type{ .size = 8,  .alignment = 8, .type_id = 6,  .hash = 6,  .kind = .numeric, .value = .{ .numeric = .usize } };
pub const I8            = &Type{ .size = 1,  .alignment = 1, .type_id = 7,  .hash = 6,  .kind = .numeric, .value = .{ .numeric = .i8 } };
pub const I16           = &Type{ .size = 2,  .alignment = 2, .type_id = 8,  .hash = 7,  .kind = .numeric, .value = .{ .numeric = .i16 } };
pub const I32           = &Type{ .size = 4,  .alignment = 4, .type_id = 9,  .hash = 8,  .kind = .numeric, .value = .{ .numeric = .i32 } };
pub const I64           = &Type{ .size = 8,  .alignment = 8, .type_id = 10, .hash = 9,  .kind = .numeric, .value = .{ .numeric = .i64 } };
pub const F32           = &Type{ .size = 4,  .alignment = 4, .type_id = 11, .hash = 11, .kind = .numeric, .value = .{ .numeric = .f32 } };
pub const F64           = &Type{ .size = 8,  .alignment = 8, .type_id = 12, .hash = 12, .kind = .numeric, .value = .{ .numeric = .f64 } };
pub const UNTYPED_INT   = &Type{ .size = 8,  .alignment = 8, .type_id = 13, .hash = 13, .kind = .numeric, .value = .{ .numeric = .untyped_int } };
pub const UNTYPED_FLOAT = &Type{ .size = 8,  .alignment = 8, .type_id = 14, .hash = 14, .kind = .numeric, .value = .{ .numeric = .untyped_float } };
pub const CHAR          = &Type{ .size = 1,  .alignment = 1, .type_id = 15, .hash = 15, .kind = .numeric, .value = .{ .numeric = .char } };
pub const STRING        = &Type{ .size = 16, .alignment = 8, .type_id = 16, .hash = 16, .kind = .string,  .value = .string };
pub const CSTRING       = &Type{ .size = 8,  .alignment = 8, .type_id = 17, .hash = 17, .kind = .cstring, .value = .cstring };
pub const BOOL          = &Type{ .size = 1,  .alignment = 1, .type_id = 18, .hash = 18, .kind = .bool,    .value = .bool };
pub const RANGE         = &Type{ .size = 8,  .alignment = 4, .type_id = 19, .hash = 19, .kind = .range,   .value = .range };
pub const ANY           = &Type{ .size = 8,  .alignment = 8, .type_id = 20, .hash = 20, .kind = .any,     .value = .any };
pub const UNKNOWN_ENUM  = &Type{ .size = 0,  .alignment = 0, .type_id = 21, .hash = 21, .kind = .unknown_enum, .value = .unknown_enum };
pub const TYPE_PARAM    = &Type{ .size = 0,  .alignment = 0, .type_id = 22, .hash = 22, .kind = .type_param, .value = .type_param };
pub const VOID_PTR      = &Type{ .size = 8,  .alignment = 8, .type_id = 23, .hash = 23, .kind = .voidptr, .value = .voidptr };
pub const NULL          = &Type{ .size = 8,  .alignment = 8, .type_id = 24, .hash = 24, .kind = .null, .value = .null };

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
    usize,
    char,
    
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
    type_param,
    unknown_enum,
    void,
    numeric,
    string,
    cstring,
    bool,
    @"enum",
    any,
    range,
    
    func,
    array,
    @"struct",
    reference,
    pointer,
    nullable,
    tuple,
    generic,
    typ,
    voidptr,
    null,
};

pub const TypeFuncParam = struct {
    typ: *const Type,
    default_value: ?*anyopaque,
};

pub const TypeFunc = struct {
    name: ?*Symbol,
    params: []const TypeFuncParam,
    type_params: []const *Type,
    returns: *const Type,
    is_variadic: bool,
    is_builtin: bool,
    is_generic: bool,
};

pub const TypeArray = struct {
    child: *const Type,
    len: usize,
    sized: bool,
    is_dyn: bool,
};

pub const TypeStructField = struct {
    name: *Symbol,
    typ: *const Type,
    offset: usize,
    default_value: ?*anyopaque,
    is_using: bool,
};

pub const TypeMethod = struct {
    name: *Symbol,
    typ: *const Type,
};

pub const TypeStruct = struct {
    name: *Symbol,
    field_map: std.StringHashMap(usize),
    method_map: std.StringHashMap(usize),
    generic_base: ?*const Type,
    type_params: []const *const Type,
    fields: []TypeStructField,
    methods: []const TypeMethod,
    state: enum {
        unresolved,
        calculating,
        done,
    },
    
    pub fn setFields(self: *TypeStruct, fields: []TypeStructField) void {
        for (fields, 0..) |field, i| {
            self.field_map.put(field.name.text, i) catch unreachable;
        }
        
        self.fields = fields;
    }
    
    pub fn setMethods(self: *TypeStruct, methods: []const TypeMethod) void {
        for (methods, 0..) |method, i| {
            self.method_map.put(method.name.text, i) catch unreachable;
        }
        
        self.methods = methods;
    }
    
    pub fn calculate(self: *TypeStruct, typ: *Type, reporter: *const Reporter) void {
        self.state = .calculating;
        
        var size: u16 = 0;
        var alignment: u16 = 0;
        
        for (self.fields) |*field| {
            if (field.typ.value == .@"struct") {
                const child_typ_ptr: *Type = @constCast(field.typ);
                const child_struct_ptr: *TypeStruct = @constCast(&field.typ.value.@"struct");
                
                if (child_struct_ptr.state == .calculating) {
                    reporter.reportErrorAtToken(
                        field.name.token,
                        "Recursive struct field requires indirection. Consider using a reference `&{s}`",
                        .{field.typ.value.@"struct".name.text}
                    );
                }
                
                child_struct_ptr.calculate(child_typ_ptr, reporter);
            }
            
            const field_size = field.typ.size;
            
            if (field_size > 0 and size % field_size > 0) {
                size += field_size - (size % field_size);
            }
            
            field.offset = size;
            
            if (field_size > alignment) {
                alignment = field_size;
            }
            
            size += field_size;
        }
        
        if (alignment > 0 and size % alignment > 0) {
            size += alignment - (size % alignment);
        }
        
        typ.size = size;
        typ.alignment = alignment;
        
        self.state = .done;
    }
};

pub const TypeEnum = struct {
    name: *Symbol,
    items: []const *Symbol,
    methods: []const TypeMethod,
};

pub const TypeImplField = struct {
    name: *Symbol,
    typ: *const Type,
};

pub const Impl = struct {
    field_map: std.StringHashMap(usize),
    fields: []const TypeImplField,
    method_map: std.StringHashMap(usize),
    methods: []const TypeMethod,
    
    pub fn init(allocator: std.mem.Allocator, fields: []const TypeImplField, methods: []const TypeMethod) Impl {
        var field_map = std.StringHashMap(usize).init(allocator);
        
        for (fields, 0..) |field, i| {
            field_map.put(field.name.text, i) catch unreachable;
        }
        
        var method_map = std.StringHashMap(usize).init(allocator);
        
        for (methods, 0..) |method, i| {
            method_map.put(method.name.text, i) catch unreachable;
        }
        
        return .{
            .field_map = field_map,
            .fields = fields,
            .method_map = method_map,
            .methods = methods,
        };
    }
};

pub const TypeId = u64;

pub const Type = struct {
    kind: TypeKind,
    value: union(TypeKind) {
        unknown,
        type_param: struct {
            name: *Symbol,
            index: usize,
            resolved_typ: ?*const Type = null,
        },
        unknown_enum,
        void,
        numeric: NumericKind,
        string,
        cstring,
        bool,
        @"enum": TypeEnum,
        any,
        range,
        func: TypeFunc,
        array: TypeArray,
        @"struct": TypeStruct,
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
            base: *const Type,
            children: []const *const Type,
        },
        typ: struct {
            child: *const Type,
        },
        voidptr,
        null,
    },
    size: u16,
    alignment: u16,
    type_id: TypeId,
    hash: u64,
    
    pub fn canBeAssignedTo(self: *const Type, other: *const Type) bool {
        if (other.value == TypeKind.any) return true;
        if (self.value == TypeKind.unknown) return true;
        if (other.value == TypeKind.unknown) return true;
        if (self.isSame(other)) return true;
        if (self.kind == .voidptr and other.kind == .pointer or self.kind == .pointer and other.kind == .voidptr) return true;
        if (self.kind == .cstring and other.kind == .pointer and other.value.pointer.child.isChar()) return true;
        if (self.kind == .null and other.kind == .nullable) return true;
        if (other.kind == .nullable and self.isSame(other.value.nullable.child)) return true;
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
                else if (self.value.numeric.isInt()) {
                    if (other.value.numeric.isInt()) {
                        if (other.value.numeric.isUntyped()) {
                            return true;
                        }
                        else {
                            if (self.value.numeric.isUnsigned() == other.value.numeric.isUnsigned()) {
                                return other.size >= self.size;
                            }
                            else if (self.value.numeric.isUnsigned() == !other.value.numeric.isUnsigned()) {
                                return other.size >= self.size * 2;
                            }
                            else {
                                return other.size * 2 >= self.size;
                            }
                            
                            return true;
                        }
                    }
                }
                else if (self.value.numeric.isFloat()) {
                    if (other.value.numeric.isFloat() and other.value.numeric.isUntyped()) {
                        return true;
                    }
                }
                
                // TODO: Check for numeric coercion
                return false;
            },
            
            TypeKind.string,
            TypeKind.array => {
                if (self.value.array.child.kind == .unknown) return true;
                
                return self.value.array.child.canBeAssignedTo(other.value.array.child);
            },
            TypeKind.@"enum" => { return false; },
            TypeKind.@"struct" => { return false; },
            TypeKind.reference => {
                return self.value.reference.child.canBeAssignedTo(other.value.reference.child);
            },
            TypeKind.pointer => {
                return self.value.pointer.child.canBeAssignedTo(other.value.pointer.child);
            },
            
            else => {
                std.debug.panic("TODO: Type.canBeAssignedTo {s}", .{@tagName(self.kind)});
            },
        }
        
        return true;
    }
    
    pub fn canBeAssignedToOrResolveGeneric(self: *const Type, other: *const Type, type_manager: *TypeManager) bool {
        if (self.canBeAssignedTo(other)) return true;
        
        if (other.kind == .type_param) {
            if (other.value.type_param.resolved_typ) |resolved_typ| {
                return self.canBeAssignedTo(resolved_typ);
            }
            else {
                const other_non_const: *Type = @constCast(other);
                other_non_const.value.type_param.resolved_typ = self.coerceIntoRuntime(type_manager);
                return true;
            }
        }
        
        if (self.kind != other.kind) return false;
        
        switch (self.kind) {
            .reference => {
                return self.value.reference.child.canBeAssignedToOrResolveGeneric(other.value.reference.child, type_manager);
            },
            .array => {
                return self.value.array.child.canBeAssignedToOrResolveGeneric(other.value.array.child, type_manager);
            },
            .@"struct" => {
                if (self.value.@"struct".name.id == other.value.@"struct".name.id) {
                    std.debug.assert(self.value.@"struct".type_params.len == other.value.@"struct".type_params.len);
                    
                    for (self.value.@"struct".type_params, 0..) |p, i| {
                        if (!p.canBeAssignedToOrResolveGeneric(other.value.@"struct".type_params[i], type_manager)) {
                            return false;
                        }
                    }
                    
                    return true;
                }
            },
            else => {
                std.debug.panic("TODO: canBeAssignedToOrResolveGeneric {s}", .{@tagName(self.kind)});
            }
        }
        
        return false;
    }
    
    pub fn resolveGeneric(self: *const Type, generic_map: std.AutoHashMap(usize, *const Type), type_manager: *TypeManager) ?*const Type {
        switch (self.kind) {
            .numeric => {
                return self;
            },
            .type_param => {
                if (generic_map.get(self.value.type_param.name.id)) |typ| {
                    return typ;
                }
                else {
                    return null;
                }
            },
            .reference => {
                type_manager.createReference(self.value.reference.child.resolveGeneric(generic_map, type_manager));
            },
            .array => {
                type_manager.createArray(
                    self.value.array.child.resolveGeneric(generic_map, type_manager),
                    self.value.array.is_dyn,
                    self.value.array.len,
                );
            },
            else => {
                std.debug.panic("TODO: resolveGeneric {s}", .{@tagName(self.kind)});
            }
        }
    }
    
    pub fn canBeUsedAsCond(self: *const Type) bool {
        switch (self.kind) {
            TypeKind.bool,
            TypeKind.numeric => return true,
            
            else => return false,
        }
    }
    
    pub fn canBeCombinedWith(self: *const Type, other: *const Type) bool {
        return self.isSame(other);
    }
    
    pub fn canBeCastTo(self: *const Type, other: *const Type) bool {
        if ((self.kind == .numeric or self.kind == .voidptr)
            and (other.kind == .numeric or other.kind == .voidptr)) return true;
        
        if (self.kind == .voidptr and other.kind == .pointer) return true;
        
        if (self.kind == .pointer and self.value.pointer.child.kind == .numeric
            and self.value.pointer.child.value.numeric == .u8
            and other.kind == .string) return true;
        
        if (self.kind == .array and self.value.array.is_dyn
            and other.kind == .array
            and self.value.array.child.isSame(other.value.array.child)) return true;
        
        return false;
    }
    
    pub fn isSame(self: *const Type, other: *const Type) bool {
        return self.isSameInternal(other, false);
    }
    
    fn isSameInternal(self: *const Type, other: *const Type, ignore_type_id: bool) bool {
        if (!ignore_type_id and self.type_id == other.type_id) return true;
        if (self.kind != other.kind) return false;
        
        switch (self.value) {
            TypeKind.bool,
            TypeKind.range,
            TypeKind.any,
            TypeKind.string,
            TypeKind.void,
            TypeKind.unknown => { return true; },
            TypeKind.@"enum" => { return false; },
            
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
                    if (!self.value.func.params[i].typ.isSame(other.value.func.params[i].typ)) return false;
                }
                
                return true;
            },
            TypeKind.reference => {
                return self.value.reference.child.isSame(other.value.reference.child);
            },
            TypeKind.pointer => {
                return self.value.pointer.child.isSame(other.value.pointer.child);
            },
            TypeKind.nullable => {
                return self.value.nullable.child.isSame(other.value.nullable.child);
            },
            TypeKind.@"struct" => {
                if (self.value.@"struct".generic_base != null and other.value.@"struct".generic_base != null) {                    
                    if (self.value.@"struct".generic_base.?.type_id != other.value.@"struct".generic_base.?.type_id) return false;
                    if (self.value.@"struct".type_params.len != other.value.@"struct".type_params.len) return false;
                    
                    for (0..self.value.@"struct".type_params.len) |i| {
                        if (!self.value.@"struct".type_params[i].isSame(other.value.@"struct".type_params[i])) return false;
                    }
                    
                    return true;
                }
                
                return false;
            },
            TypeKind.type_param => return self.type_id == other.type_id,
            TypeKind.typ => {
                return self.value.typ.child.isSame(other.value.typ.child);
            },
            else => {
                std.debug.panic("TODO: Type.isSame {s}", .{@tagName(self.value)});
            }
        }
    }
    
    pub fn isSameOrSameReference(self: *const Type, other: *const Type) bool {
        if (self.isSame(other)) return true;
        if (self.value == .reference) return self.value.reference.child.isSame(other);
        return false;
    }
    
    pub fn coerceIntoRuntime(self: *const Type, type_manager: *TypeManager) *const Type {
        switch (self.value) {
            TypeKind.numeric => {
                switch (self.value.numeric) {
                    NumericKind.untyped_int => return I32,
                    NumericKind.untyped_float => return F32,
                    else => return self,
                }
            },
            TypeKind.array => {
                return type_manager.createArray(
                    self.value.array.child.coerceIntoRuntime(type_manager),
                    self.value.array.is_dyn,
                    self.value.array.len,
                );
            },
            else => {
                return self;
            },
        }
    }
    
    pub fn assignTo(self: *const Type, to: *const Type, type_manager: *TypeManager) *const Type {
        // TODO: Convert type do destination type
        // For example: const x: []u32 = .[1, 2, 3]
        // The type should be sized array
        
        if (self.kind == .array and to.kind == .array) {
            if (self.value.array.child.type_id != to.value.array.child.type_id) {
                return type_manager.createArray(to.value.array.child, to.value.array.is_dyn, to.value.array.len);
            }
        }
        
        return to;
    }
    
    pub fn combinedWith(self: *const Type, other: *const Type) *const Type {
        _ = self;
        
        return other;
    }
    
    pub fn collapseTypeParam(self: *const Type, type_manager: *TypeManager) *const Type {
        switch (self.kind) {
            .unknown,
            .unknown_enum,
            .void,
            .numeric,
            .string,
            .cstring,
            .bool,
            .@"enum",
            .any,
            .range,
            .func,
            .voidptr,
            .null => {
                return self;
            },
            .@"struct" => {
                if (self.value.@"struct".generic_base != null and self.value.@"struct".type_params.len > 0) {
                    var all_resolved = true;
                    var already_collapsed = true;
                    
                    for (self.value.@"struct".type_params) |p| {
                        if (p.kind == .type_param) {
                            already_collapsed = false;
                            
                            if (p.value.type_param.resolved_typ == null) {
                                all_resolved = false;
                                break;
                            }
                        }                        
                    }
                    
                    if (all_resolved) {
                        const type_params: []const *const Type = if (already_collapsed) self.value.@"struct".type_params else blk: {
                            // MEMORY: Masak allocate terus
                            var type_params = type_manager.arena.alloc(*const Type, self.value.@"struct".type_params.len) catch unreachable;
                            
                            for (0..type_params.len) |i| {
                                type_params[i] = self.value.@"struct".type_params[i].collapseTypeParam(type_manager);
                            }
                            
                            break :blk type_params;
                        };
                        
                        return type_manager.createGenericStruct(self.value.@"struct".generic_base.?, type_params);
                    }
                }
                
                return self;
            },
            .reference => {                
                return type_manager.createReference(self.value.reference.child.collapseTypeParam(type_manager));
            },
            .array => {
                return type_manager.createArray(self.value.array.child.collapseTypeParam(type_manager), self.value.array.is_dyn, self.value.array.len);
            },
            .pointer => {
                return type_manager.createPointer(self.value.pointer.child.collapseTypeParam(type_manager));
            },
            .nullable => {
                std.debug.panic("TODO: collapseTypeParam nullable", .{});
            },
            .tuple => {
                std.debug.panic("TODO: collapseTypeParam tuple", .{});
            },
            .generic => {
                std.debug.panic("TODO: collapseTypeParam generic", .{});
            },
            .typ => {
                std.debug.panic("TODO: collapseTypeParam typ", .{});
            },
            .type_param => {
                if (self.value.type_param.resolved_typ) |res| {
                    return res;
                }
                else {
                    return self;
                }
            },
        }
    }
    
    pub fn fillGenericStruct(self: *const Type, type_manager: *TypeManager) void {
        std.debug.assert(self.kind == .@"struct" and self.value.@"struct".generic_base != null);
        
        const base_struct_typ = self.value.@"struct".generic_base.?.value.@"struct";
        const struct_typ: *TypeStruct = @constCast(&self.value.@"struct");
            
        for (base_struct_typ.type_params) |base_type_param| {
            const ptr: *Type = @constCast(base_type_param);
            ptr.value.type_param.resolved_typ = struct_typ.type_params[base_type_param.value.type_param.index];
        }
        
        var fields = type_manager.arena.alloc(TypeStructField, base_struct_typ.fields.len) catch unreachable;
        for (base_struct_typ.fields, 0..) |field, i| {
            fields[i] = field;
            fields[i].typ = fields[i].typ.collapseTypeParam(type_manager);
        }
        
        struct_typ.fields = fields;
        struct_typ.field_map = base_struct_typ.field_map;
    }
    
    pub fn isNumericInt(self: *const Type) bool {
        return self.kind == .numeric and self.value.numeric.isInt();
    }
    
    pub fn isChar(self: *const Type) bool {
        return self.kind == .numeric and self.value.numeric == .u8;
    }
    
    pub fn isConstable(self: *const Type) bool {
        switch (self.kind) {
            TypeKind.numeric,
            TypeKind.bool,
            TypeKind.@"enum",
            TypeKind.cstring,
            TypeKind.void,
            TypeKind.voidptr => {
                return true;
            },
            else => {
                return false;
            }
        }
    }
    
    pub fn getTextLeak(self: *const Type, allocator: std.mem.Allocator) []const u8 {
        var str = std.ArrayList(u8).empty;
        self.getText(&str, allocator);
        return str.items;
    }
    
    pub fn getText(self: *const Type, out: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
        switch (self.value) {
            TypeKind.unknown      => { out.appendSlice(allocator, "unknown") catch unreachable; },
            TypeKind.unknown_enum => { out.appendSlice(allocator, "unknown_enum") catch unreachable; },
            TypeKind.void         => { out.appendSlice(allocator, "void") catch unreachable; },
            TypeKind.string       => { out.appendSlice(allocator, "string") catch unreachable; },
            TypeKind.cstring      => { out.appendSlice(allocator, "cstring") catch unreachable; },
            TypeKind.bool         => { out.appendSlice(allocator, "bool") catch unreachable; },
            TypeKind.any          => { out.appendSlice(allocator, "any") catch unreachable; },
            TypeKind.range        => { out.appendSlice(allocator, "range") catch unreachable; },
            TypeKind.voidptr      => { out.appendSlice(allocator, "voidptr") catch unreachable; },
            TypeKind.null         => { out.appendSlice(allocator, "null") catch unreachable; },
            TypeKind.numeric      => {
                switch (self.value.numeric) {
                    NumericKind.u8            => { out.appendSlice(allocator, "u8") catch unreachable; },
                    NumericKind.u16           => { out.appendSlice(allocator, "u16") catch unreachable; },
                    NumericKind.u32           => { out.appendSlice(allocator, "u32") catch unreachable; },
                    NumericKind.u64           => { out.appendSlice(allocator, "u64") catch unreachable; },
                    NumericKind.usize         => { out.appendSlice(allocator, "usize") catch unreachable; },
                    NumericKind.char          => { out.appendSlice(allocator, "char") catch unreachable; },
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
                
                if (self.value.array.is_dyn) {
                    out.print(allocator, "dyn", .{}) catch unreachable;
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
                    
                    if (self.value.func.is_variadic and i == self.value.func.params.len - 1) {
                        out.appendSlice(allocator, "...") catch unreachable;
                    }
                    
                    param.typ.getText(out, allocator);
                }
                
                out.appendSlice(allocator, "): ") catch unreachable;
                self.value.func.returns.getText(out, allocator);
            },
            
            TypeKind.@"struct" => {
                out.print(allocator, "{s}", .{self.value.@"struct".name.text}) catch unreachable;
                
                if (self.value.@"struct".type_params.len > 0) {
                    out.print(allocator, "<", .{}) catch unreachable;
                    
                    for (self.value.@"struct".type_params, 0..) |p, i| {
                        if (i > 0) {
                            out.print(allocator, ", ", .{}) catch unreachable;
                        }
                        
                        p.getText(out, allocator);
                    }
                    
                    out.print(allocator, ">", .{}) catch unreachable;
                }
            },
            
            TypeKind.@"enum" => {
                out.print(allocator, "{s}", .{self.value.@"enum".name.text}) catch unreachable;
            },
            
            TypeKind.reference => {
                out.appendSlice(allocator, "&") catch unreachable;
                self.value.reference.child.getText(out, allocator);
            },
            
            TypeKind.pointer => {
                out.appendSlice(allocator, "*") catch unreachable;
                self.value.pointer.child.getText(out, allocator);
            },
            
            TypeKind.nullable => {
                out.appendSlice(allocator, "?") catch unreachable;
                self.value.nullable.child.getText(out, allocator);
            },
            
            TypeKind.generic => {
                self.value.generic.base.getText(out, allocator);
                out.append(allocator, '<') catch unreachable;
                
                for (self.value.generic.children, 0..) |child, i| {
                    if (i > 0) {
                        out.appendSlice(allocator, ", ") catch unreachable;
                    }
                    
                    child.getText(out, allocator);
                }
                
                out.append(allocator, '>') catch unreachable;
            },
            
            TypeKind.typ => {
                out.print(allocator, "type({s}:", .{@tagName(self.value.typ.child.value)}) catch unreachable;
                self.value.typ.child.getText(out, allocator);
                out.appendSlice(allocator, ")") catch unreachable;
            },
            
            TypeKind.type_param => {
                if (self.value.type_param.resolved_typ) |typ| {
                    out.print(allocator, "type_param(", .{}) catch unreachable;
                    typ.getText(out, allocator);
                    out.print(allocator, ")", .{}) catch unreachable;
                }
                else {
                    out.print(allocator, "{s}", .{self.value.type_param.name.text}) catch unreachable;
                }
            },
            
            else => {
                std.debug.panic("TODO: Type.getText {s}", .{@tagName(self.value)});
            }
        }
    }
};

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
    
    pub fn createArray(self: *TypeManager, child: *const Type, is_dyn: bool, len: ?usize) *const Type {
        _ = len;
        
        var h = combineHash(@intFromEnum(TypeKind.array), child.hash);
        h = combineHash(h, if (is_dyn) 1 else 0);
        // h = combineHash(h, if (len != null) 1 else 0);
        // h = combineHash(h, if (len) |l| l else 0);
        
        const typ = Type{
            .kind = .array,
            .size = 16,//if (len) |l| @intCast(child.size * l) else 0,
            .alignment = child.alignment,
            .type_id = self.cur_index,
            .hash = h,
            .value = .{.array = .{
                .child = child,
                .is_dyn = is_dyn,
                .len = 0,//len orelse 0,
                .sized = false,//len != null,
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
    
    pub fn createPointer(self: *TypeManager, child: *const Type) *const Type {
        const typ = Type{
            .kind = .pointer,
            .size = 8,
            .alignment = child.alignment,
            .type_id = self.cur_index,
            .hash = combineHash(@intFromEnum(TypeKind.pointer), child.hash),
            .value = .{.pointer = .{
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
    
    pub fn createNullable(self: *TypeManager, child: *const Type) *const Type {
        const typ = Type{
            .kind = .nullable,
            .size = 8,
            .alignment = 8,
            .type_id = self.cur_index,
            .hash = combineHash(@intFromEnum(TypeKind.nullable), child.hash),
            .value = .{.nullable = .{
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
    
    pub fn createFn(
        self: *TypeManager,
        name: ?*Symbol,
        params: []const TypeFuncParam,
        type_params: []const *Type,
        return_typ: *const Type,
        is_variadic: bool,
        is_builtin: bool,
        is_generic: bool,
    ) *Type {
        var h = combineHash(@intFromEnum(TypeKind.func), params.len);
        for (params) |param| { h = combineHash(h, param.typ.hash); }
        h = combineHash(h, if (is_variadic) 1 else 0);
        h = combineHash(h, return_typ.hash);
        
        const typ = Type{
            .kind = .func,
            .size = 8,
            .alignment = 8,
            .type_id = self.cur_index,
            .hash = h,
            .value = .{.func = .{
                .name = name,
                .params = params,
                .type_params = type_params,
                .returns = return_typ,
                .is_variadic = is_variadic,
                .is_builtin = is_builtin,
                .is_generic = is_generic,
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
    
    pub fn createStructForward(self: *TypeManager, name: *Symbol) *Type {
        const typ = Type{
            .kind = .@"struct",
            .size = 0,
            .alignment = 0,
            .type_id = self.cur_index,
            .hash = self.cur_index,
            .value = .{.@"struct" = .{
                .generic_base = null,
                .name = name,
                .field_map = .init(self.arena),
                .method_map = .init(self.arena),
                .type_params = &.{},
                .fields = &.{},
                .methods = &.{},
                .state = .unresolved,
            }},
        };
        
        const new_typ_ptr = self.arena.create(Type) catch unreachable;
        new_typ_ptr.* = typ;
        self.cur_index += 1;
        
        return new_typ_ptr;
    }
    
    pub fn createEnum(self: *TypeManager, name: *Symbol, items: []*Symbol, methods: []const TypeMethod) *Type {
        const typ = Type{
            .kind = .@"enum",
            .size = 8,
            .alignment = 8,
            .type_id = self.cur_index,
            .hash = self.cur_index,
            .value = .{.@"enum" = .{
                .name = name,
                .items = items,
                .methods = methods,
            }},
        };
        
        const new_typ_ptr = self.arena.create(Type) catch unreachable;
        new_typ_ptr.* = typ;
        self.cur_index += 1;
        
        self.type_map.put(typ, new_typ_ptr) catch unreachable;
        
        return new_typ_ptr;
    }
    
    pub fn createGenericStruct(self: *TypeManager, base: *const Type, children: []const *const Type) *Type {
        std.debug.assert(base.value == .@"struct");
        
        var h = base.hash;
        for (children) |child| {
            h = combineHash(h, child.hash);
        }
        
        const typ = Type{
            .kind = .@"struct",
            .size = 0,
            .alignment = 0,
            .type_id = self.cur_index,
            .hash = h,
            .value = .{.@"struct" = .{
                .generic_base = base,
                .name = base.value.@"struct".name,
                .field_map = base.value.@"struct".field_map,
                .method_map = base.value.@"struct".method_map,
                .type_params = children,
                .fields = &.{},
                .methods = &.{},
                .state = .unresolved,
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
    
    pub fn createType(self: *TypeManager, child: *const Type) *const Type {
        const typ = Type{
            .kind = .typ,
            .size = 8,
            .alignment = 8,
            .type_id = self.cur_index,
            .hash = combineHash(@intFromEnum(TypeKind.typ), child.hash),
            .value = .{.typ = .{
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
    
    pub fn createTypeParam(self: *TypeManager, name: *Symbol, index: usize) *Type {
        const typ = Type{
            .kind = .type_param,
            .size = 0,
            .alignment = 0,
            .type_id = self.cur_index,
            .hash = combineHash(@intFromEnum(TypeKind.type_param), index),
            .value = .{.type_param = .{
                .name = name,
                .index = index,
            }},
        };
        
        const new_typ_ptr = self.arena.create(Type) catch unreachable;
        new_typ_ptr.* = typ;
        self.cur_index += 1;
        
        self.type_map.put(typ, new_typ_ptr) catch unreachable;
        
        return new_typ_ptr;
    }
};

fn TypeHashMap() type {
    const Context = struct {        
        pub fn hash(_: @This(), key: Type) u64 {
            return key.hash;
        }
        
        pub fn eql(_: @This(), a: Type, b: Type) bool {
            return a.isSameInternal(&b, true);
        }
    };
    
    return std.HashMap(Type, *Type, Context, std.hash_map.default_max_load_percentage);
}

pub fn combineHash(a: u64, b: u64) u64 {
    var x = a ^ b;
    x ^= x >> 32;
    x *%= 0xd6e8feb86659fd93;
    x ^= x >> 32;
    x *%= 0xd6e8feb86659fd93;
    x ^= x >> 32;
    
    return x;
}

fn combineHashWithString(a: u64, s: []const u8) u64 {
    return std.hash.Wyhash.hash(a, s);
}