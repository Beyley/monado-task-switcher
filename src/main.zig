const std = @import("std");

const LibMonado = @import("LibMonado.zig");

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer if (gpa_impl.deinit() == .leak) @panic("MEMORY LEAK");

    const gpa = gpa_impl.allocator();

    var libmonado = load_libmonado: {
        var load_arena_impl: std.heap.ArenaAllocator = .init(gpa);
        defer load_arena_impl.deinit();

        break :load_libmonado try LibMonado.load(load_arena_impl.allocator());
    };
    defer libmonado.deinit();
}
