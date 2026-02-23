const std = @import("std");

pub fn not_implemented() noreturn {
    std.debug.panic("Not implemented", .{});
}

pub const StringBuilder = struct {
    allocator: std.mem.Allocator,
    
    
};