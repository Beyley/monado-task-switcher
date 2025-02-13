const std = @import("std");
const log = std.log;

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

    var root: LibMonado.Root = undefined;
    try LibMonado.handleResult(libmonado.mnd_root_create(&root));
    defer libmonado.mnd_root_destroy(&root);

    try LibMonado.handleResult(libmonado.mnd_root_update_client_list(root));

    var num_clients: u32 = undefined;
    try LibMonado.handleResult(libmonado.mnd_root_get_number_clients(root, &num_clients));

    log.info("Found {d} clients", .{num_clients});

    const Client = struct { name: [:0]const u8, id: u32, state: LibMonado.ClientFlags };

    var primary_clients: std.ArrayListUnmanaged(Client) = .empty;
    defer {
        for (primary_clients.items) |client| {
            gpa.free(client.name);
        }
        primary_clients.deinit(gpa);
    }

    // load and cache all client info
    for (0..num_clients) |client_idx| {
        var client_id: u32 = undefined;
        try LibMonado.handleResult(libmonado.mnd_root_get_client_id_at_index(root, @intCast(client_idx), &client_id));

        var name_ptr: ?[*:0]const u8 = undefined;
        try LibMonado.handleResult(libmonado.mnd_root_get_client_name(root, client_id, @ptrCast(&name_ptr)));

        var state_flags: u32 = undefined;
        try LibMonado.handleResult(libmonado.mnd_root_get_client_state(root, client_id, &state_flags));

        const state: LibMonado.ClientFlags = @bitCast(state_flags);

        // Skip clients without an active session or that are overlays
        if (!state.session_active or state.session_overlay) continue;

        const name = try gpa.dupeZ(u8, std.mem.span(name_ptr.?));
        errdefer gpa.free(name);

        try primary_clients.append(gpa, .{ .id = client_id, .name = name, .state = @bitCast(state_flags) });
        log.debug("Found connected client {s} ({d}), with state {}", .{ name, client_id, state });
    }

    // we have no work to do..
    if (primary_clients.items.len < 2) {
        log.info("Found <2 non-overlay apps, nothing to do...", .{});
        return;
    }

    var primary_session_idx: ?usize = null;

    // try to find the currently primary session
    for (primary_clients.items, 0..) |client, idx| {
        if (client.state.primary_app) {
            primary_session_idx = idx;
            break;
        }
    }

    // calculate the idx of the new primary client, just selecting the second(yes i know) client if we couldnt find an active client..
    const new_primary_session_idx = ((primary_session_idx orelse 0) + 1) % primary_clients.items.len;

    const new_primary_client = primary_clients.items[new_primary_session_idx];

    log.info("Setting {s} as the new primary client!", .{new_primary_client.name});

    // set it as primary
    try LibMonado.handleResult(libmonado.mnd_root_set_client_primary(root, new_primary_client.id));
}
