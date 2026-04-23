const std = @import("std");

const ANSI_RED =    "\x1b[0;31m";
const ANSI_GREEN =  "\x1b[0;32m";
const ANSI_YELLOW = "\x1b[0;33m";
const ANSI_GRAY =   "\x1b[0;37m";
const ANSI_WHITE =  "\x1b[0;97m";
const ANSI_RESET =  "\x1b[0m";

const TestKind = enum {
    lexer,
    parser,
    typer,
    run_output,
};

const TestEntry = struct {
    kind: TestKind,
    path: []const u8,
};

const TestResult = enum {
    success,
    failed,
    skipped,
};

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const wijic_path = args.next().?;
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    var entries: std.ArrayList(TestEntry) = .empty;
    
    try collectTest(allocator, "tests/1_lexer", .lexer, &entries);
    try collectTest(allocator, "tests/2_parser", .parser, &entries);
    try collectTest(allocator, "tests/3_typer", .typer, &entries);
    try collectTest(allocator, "tests/6_run", .run_output, &entries);
    
    std.mem.sort(TestEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: TestEntry, b: TestEntry) bool {
            var a_iter = std.mem.splitAny(u8, a.path, "_/");
            var b_iter = std.mem.splitAny(u8, b.path, "_/");
            
            while (a_iter.next()) |a_part| {
                if (b_iter.next()) |b_part| {
                    const a_num: ?usize = std.fmt.parseInt(usize, a_part, 10) catch null;
                    const b_num: ?usize = std.fmt.parseInt(usize, b_part, 10) catch null;
                    
                    if (a_num != null and b_num != null) {
                        if (a_num.? < b_num.?) {
                            return true;
                        }
                        else if (a_num.? > b_num.?) {
                            return false;
                        }
                    }
                    else {
                        switch(std.mem.order(u8, a_part, b_part)) {
                            .lt => return true,
                            .gt => return false,
                            else => {},
                        }
                    }
                }
            }
            
            std.debug.print("\n", .{});
            
            return false;
        }
    }.lessThan);
    
    var test_number_width: usize = 1;
    var test_len = entries.items.len;
    
    while (test_len >= 10) {
        test_len /= 10;
        test_number_width += 1;
    }
    
    var success_count: usize = 0;
    var failed_count: usize = 0;
    var skipped_count: usize = 0;
    
    for (entries.items, 1..) |entry, i| {
        std.debug.print("{[i]: >[width]}/{[total]} {[path]s}", .{
            .i = i,
            .width = test_number_width,
            .total = entries.items.len,
            .path = entry.path
        });
        
        const res = try runTest(allocator, wijic_path, entry);
        
        switch (res) {
            .success => {
                std.debug.print(ANSI_GREEN ++ " [OK]\n" ++ ANSI_RESET, .{});
                success_count += 1;
            },
            .failed => {
                std.debug.print(ANSI_RED ++ "\nat:\n{s}:0\n" ++ ANSI_RESET, .{entry.path});
                failed_count += 1;
            },
            .skipped => {
                std.debug.print(ANSI_YELLOW ++ " [SKIPPED]\n" ++ ANSI_RESET, .{});
                skipped_count += 1;
            },
        }
    }
    
    if (failed_count > 0) {
        std.debug.print(ANSI_RED ++ "\n------------------------\n", .{});
        std.debug.print("{} failed test(s)\n", .{failed_count});
        std.debug.print("------------------------\n" ++ ANSI_RESET, .{});
    }
    else if (skipped_count > 0) {
        std.debug.print(ANSI_GREEN ++ "\n------------------------\n", .{});
        std.debug.print("{} test(s) pass {} test(s) skipped\n", .{success_count, skipped_count});
        std.debug.print("------------------------\n" ++ ANSI_RESET, .{});
    }
    else {
        std.debug.print(ANSI_GREEN ++ "\n------------------------\n", .{});
        std.debug.print("All {} test(s) pass\n", .{success_count});
        std.debug.print("------------------------\n" ++ ANSI_RESET, .{});
    }
}

fn collectTest(allocator: std.mem.Allocator, dir_path: []const u8, kind: TestKind, out: *std.ArrayList(TestEntry)) !void {
    const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            const path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.path });
            
            try out.append(allocator, .{
                .kind = kind,
                .path = path,
            });
        }
    }
}

fn runTest(allocator: std.mem.Allocator, exe_path: []const u8, entry: TestEntry) !TestResult {
    var expected: []const u8 = undefined;
    defer allocator.free(expected);
    var skipped = false;
    
    getTestInfo(allocator, entry.path, &expected, &skipped);
    
    if (skipped) {
        return .skipped;
    }
    
    var cmd = std.ArrayList([]const u8).empty;
    defer cmd.clearAndFree(allocator);
    
    try cmd.append(allocator, exe_path);
    try cmd.append(allocator, entry.path);
    
    switch (entry.kind) {
        .lexer      => { try cmd.appendSlice(allocator, &[_][]const u8{"--emit", "token"}); },
        .parser     => { try cmd.appendSlice(allocator, &[_][]const u8{"--emit", "ast"}); },
        .typer      => { try cmd.appendSlice(allocator, &[_][]const u8{"--emit", "tast"}); },
        .run_output => { try cmd.appendSlice(allocator, &[_][]const u8{"--run"}); },
    }
    
    try cmd.appendSlice(allocator, &[_][]const u8{"--err", "minimal"});
    
    var proc = std.process.Child.init(cmd.items, allocator);
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    try proc.spawn();
    
    var stdout = std.ArrayList(u8).empty;
    defer stdout.clearAndFree(allocator);
    var stderr = std.ArrayList(u8).empty;
    defer stderr.clearAndFree(allocator);
    
    try proc.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);
    _ = try proc.wait();
    
    if (std.mem.eql(u8, stdout.items, expected)) {
        return .success;
    }
    else {        
        std.debug.print(ANSI_RED ++ "\n\nExpected:\n{s}", .{if (expected.len > 0) expected else "\n"});
        std.debug.print("\nActual:\n{s}" ++ ANSI_RESET, .{stdout.items});
        
        return .failed;
    }
}

fn getTestInfo(allocator: std.mem.Allocator, path: []const u8, out: *[]const u8, skipped: *bool) void {
    _ = skipped;
    
    const file = std.fs.cwd().openFile(path, .{}) catch unreachable;
    defer file.close();
    
    const stat = file.stat() catch unreachable;
    const file_size: usize = @intCast(stat.size);
    
    const content: []u8 = file.readToEndAlloc(allocator, file_size) catch unreachable;
    defer allocator.free(content);
    
    if (std.mem.indexOf(u8, content, "/***\n")) |start_index| {
        const out_include_end = content[start_index + 5..];
        
        if (std.mem.indexOf(u8, out_include_end, "***/")) |end_index| {
            const out_clean = out_include_end[0..end_index];
            out.* = allocator.dupe(u8, out_clean) catch unreachable;
        }
        else {
            std.debug.panic("Test output is not closed", .{});
        }
    }
    else {
        out.* = "";
    }
}