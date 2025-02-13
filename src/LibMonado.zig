const std = @import("std");
const builtin = @import("builtin");

const c = @import("libmonado_c");

pub const Root = ?*c.mnd_root_t;

pub const ClientFlags = packed struct(u32) {
    primary_app: bool,
    session_active: bool,
    session_visible: bool,
    session_focused: bool,
    session_overlay: bool,
    io_active: bool,
    _padding: u26,
};

const log = std.log.scoped(.libmonado_loader);

pub const LibMonado = @This();

dynlib: std.DynLib,

mnd_api_get_version: *const @TypeOf(c.mnd_api_get_version),
mnd_root_create: *const @TypeOf(c.mnd_root_create),
mnd_root_destroy: *const @TypeOf(c.mnd_root_destroy),
mnd_root_update_client_list: *const @TypeOf(c.mnd_root_update_client_list),
mnd_root_get_number_clients: *const @TypeOf(c.mnd_root_get_number_clients),
mnd_root_get_client_id_at_index: *const @TypeOf(c.mnd_root_get_client_id_at_index),
mnd_root_get_client_name: *const @TypeOf(c.mnd_root_get_client_name),
mnd_root_get_client_state: *const @TypeOf(c.mnd_root_get_client_state),
mnd_root_set_client_primary: *const @TypeOf(c.mnd_root_set_client_primary),
mnd_root_set_client_focused: *const @TypeOf(c.mnd_root_set_client_focused),
mnd_root_toggle_client_io_active: *const @TypeOf(c.mnd_root_toggle_client_io_active),
mnd_root_get_device_count: *const @TypeOf(c.mnd_root_get_device_count),
mnd_root_get_device_info_bool: *const @TypeOf(c.mnd_root_get_device_info_bool),
mnd_root_get_device_info_i32: *const @TypeOf(c.mnd_root_get_device_info_i32),
mnd_root_get_device_info_u32: *const @TypeOf(c.mnd_root_get_device_info_u32),
mnd_root_get_device_info_float: *const @TypeOf(c.mnd_root_get_device_info_float),
mnd_root_get_device_info_string: *const @TypeOf(c.mnd_root_get_device_info_string),
mnd_root_get_device_info: *const @TypeOf(c.mnd_root_get_device_info),
mnd_root_get_device_from_role: *const @TypeOf(c.mnd_root_get_device_from_role),
mnd_root_recenter_local_spaces: *const @TypeOf(c.mnd_root_recenter_local_spaces),
mnd_root_get_reference_space_offset: *const @TypeOf(c.mnd_root_get_reference_space_offset),
mnd_root_set_reference_space_offset: *const @TypeOf(c.mnd_root_set_reference_space_offset),
mnd_root_get_tracking_origin_offset: *const @TypeOf(c.mnd_root_get_tracking_origin_offset),
mnd_root_set_tracking_origin_offset: *const @TypeOf(c.mnd_root_set_tracking_origin_offset),
mnd_root_get_tracking_origin_count: *const @TypeOf(c.mnd_root_get_tracking_origin_count),
mnd_root_get_tracking_origin_name: *const @TypeOf(c.mnd_root_get_tracking_origin_name),
mnd_root_get_device_battery_status: *const @TypeOf(c.mnd_root_get_device_battery_status),

const OpenXrRuntimeManifest = struct {
    pub const Runtime = struct {
        library_path: []const u8,
        name: ?[]const u8,
        MND_libmonado_path: ?[]const u8,
        // NOTE: add `functions` if you really need it, I don't care.
    };

    file_format_version: []const u8,
    runtime: Runtime,
};

pub fn handleResult(ret: c.mnd_result_t) !void {
    if (ret == c.MND_SUCCESS) return;

    return switch (ret) {
        -1 => error.InvalidVersion,
        -2 => error.InvalidValue,
        -3 => error.ConnectingFailed,
        -4 => error.OperationFailed,
        -5 => error.RecenteringNotSupported,
        -6 => error.InvalidProperty,
        -7 => error.InvalidOperation,
        else => error.UnknownError,
    };
}

pub fn load(arena: std.mem.Allocator) !LibMonado {
    const openxr_runtime_file = try findOpenXrRuntimeFile(arena, arena);
    defer openxr_runtime_file[1].close();

    log.debug("Found OpenXR runtime file at path {s}", .{openxr_runtime_file[0]});

    var buffered_reader = std.io.bufferedReader(openxr_runtime_file[1].reader());
    const reader = buffered_reader.reader();

    var json_reader = std.json.reader(arena, reader);

    const manifest = try std.json.parseFromTokenSourceLeaky(OpenXrRuntimeManifest, arena, &json_reader, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_first,
    });

    const libmonado_path = if (manifest.runtime.MND_libmonado_path) |relative_libmonado_path|
        try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(openxr_runtime_file[0]) orelse ".", relative_libmonado_path })
    else
        "libmonado.so";

    log.debug("Loading libmonado at path {s}", .{libmonado_path});
    var dynlib = try std.DynLib.open(libmonado_path);
    errdefer dynlib.close();

    const mnd_api_get_version = dynlib.lookup(*const @TypeOf(c.mnd_api_get_version), "mnd_api_get_version") orelse return error.MissingMonadoApiVersionFunction;

    var major: u32 = undefined;
    var minor: u32 = undefined;
    var patch: u32 = undefined;
    mnd_api_get_version(&major, &minor, &patch);

    // basic version check...
    if (c.MND_API_VERSION_MAJOR != major or minor < c.MND_API_VERSION_MINOR) return error.UnsupportedMonadoVersion;

    log.debug("Loading libmonado with version {d}.{d}.{d}", .{ major, minor, patch });

    var ret: LibMonado = undefined;
    ret.dynlib = dynlib;

    inline for (@typeInfo(LibMonado).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, "dynlib", field.name)) continue;

        @field(ret, field.name) = dynlib.lookup(field.type, field.name) orelse {
            log.err("Failed to load function pointer for function {s}", .{field.name});
            return error.FailedToLoadFnPtr;
        };
    }

    return ret;
}

pub fn deinit(self: *LibMonado) void {
    self.dynlib.close();
}

const FoundRuntimeFile = struct { []const u8, std.fs.File };

fn findOpenXrRuntimeFile(gpa: std.mem.Allocator, arena: std.mem.Allocator) !FoundRuntimeFile {
    var config_dirs_to_check: std.ArrayListUnmanaged(std.fs.Dir) = .empty;
    defer {
        for (config_dirs_to_check.items) |*dir| {
            dir.close();
        }

        config_dirs_to_check.deinit(arena);
    }

    if (try findConfigDir(arena)) |config_dir|
        try config_dirs_to_check.append(arena, config_dir);

    early_config_dir_return: {
        const config_dirs = std.process.getEnvVarOwned(arena, "XDG_CONFIG_DIRS") catch |err| {
            if (err == std.process.GetEnvVarOwnedError.EnvironmentVariableNotFound) {
                var fallback_dir = (try maybeOpenDir(std.fs.cwd(), "/etc/xdg")) orelse break :early_config_dir_return;
                errdefer fallback_dir.close();

                // Try to open and add the /etc/xdg path as a fallback
                try config_dirs_to_check.append(arena, fallback_dir);

                break :early_config_dir_return;
            }

            return err;
        };

        var dir_iter = std.mem.splitScalar(u8, config_dirs, ':');
        load_dirs_loop: while (dir_iter.next()) |raw_config_dir| {
            var loaded_dir = (try maybeOpenDir(std.fs.cwd(), raw_config_dir)) orelse continue :load_dirs_loop;
            errdefer loaded_dir.close();

            try config_dirs_to_check.append(arena, loaded_dir);
        }
    }

    for (config_dirs_to_check.items) |config_dir_to_check| {
        if (try checkDirForOpenXrRuntimeFile(gpa, arena, config_dir_to_check)) |runtime_file|
            return runtime_file;
    }

    return error.UnableToFindOpenXrRuntimeFile;
}

fn checkDirForOpenXrRuntimeFile(gpa: std.mem.Allocator, arena: std.mem.Allocator, basedir: std.fs.Dir) !?FoundRuntimeFile {
    const target_runtime_path = targetToRuntimePath(builtin.target);
    const targetless_runtime_path = "active_runtime.json";

    const major_api_version = "1";

    const subpath = try std.fs.path.join(arena, &.{ "openxr", major_api_version });
    defer arena.free(subpath);

    var runtimes_dir = (try maybeOpenDir(basedir, subpath)) orelse return null;
    defer runtimes_dir.close();

    var found_runtime_file: ?std.fs.File = runtimes_dir.openFile(target_runtime_path, .{}) catch |err| check_for_not_found: {
        if (err == std.fs.File.OpenError.FileNotFound) {
            log.warn("Failed to find arch-specific runtime in OpenXR config dir!", .{});
            break :check_for_not_found null;
        }

        return err;
    };
    var runtime_file_realpath = if (found_runtime_file != null) try runtimes_dir.realpathAlloc(gpa, target_runtime_path) else null;

    found_runtime_file = found_runtime_file orelse runtimes_dir.openFile(targetless_runtime_path, .{}) catch |err| check_for_not_found: {
        if (err == std.fs.File.OpenError.FileNotFound) {
            log.warn("Failed to find generic runtime in OpenXR config dir!", .{});
            break :check_for_not_found null;
        }

        return err;
    };
    runtime_file_realpath = runtime_file_realpath orelse try runtimes_dir.realpathAlloc(gpa, targetless_runtime_path);

    if (found_runtime_file == null) return null;

    return .{ runtime_file_realpath.?, found_runtime_file.? };
}

fn targetToRuntimePath(comptime target: std.Target) []const u8 {
    const arch = comptime (targetToOpenXrArch(target) catch @compileError("Unsupported arch " ++ @tagName(target.cpu.arch)));

    return "active_runtime." ++ arch ++ ".json";
}

fn targetToOpenXrArch(target: std.Target) ![]const u8 {
    return switch (target.cpu.arch) {
        .x86_64 => if (target.abi == .gnux32 or target.abi == .muslx32 or target.abi == .ilp32) "x32" else "x86_64",
        .x86 => "i686",
        .aarch64 => "aarch64",
        .mips64 => "mips64",
        .mips => "mips",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64el",
        .s390x => "s390x",
        .m68k => "m68k",
        .riscv64 => "riscv64",
        .sparc64 => "sparc64",
        else => return error.UnknownArch,
    };
}

fn findConfigDir(arena: std.mem.Allocator) !?std.fs.Dir {
    // If XDG_CONFIG_HOME is present, use that directly
    if (std.process.hasEnvVarConstant("XDG_CONFIG_HOME")) {
        const home_var = try std.process.getEnvVarOwned(arena, "XDG_CONFIG_HOME");
        defer arena.free(home_var);

        // If it opens, return it
        if (try maybeOpenDir(std.fs.cwd(), home_var)) |home_dir|
            return home_dir;
    }

    if (!std.process.hasEnvVarConstant("HOME")) {
        return error.MissingHomeEnvVar; // your system is probably fucked
    }

    const home_dir = try std.process.getEnvVarOwned(arena, "HOME");
    defer arena.free(home_dir);

    const path = try std.fs.path.join(arena, &.{ home_dir, ".config" });
    defer arena.free(path);

    return maybeOpenDir(std.fs.cwd(), path);
}

fn maybeOpenDir(root: std.fs.Dir, subpath: []const u8) !?std.fs.Dir {
    return root.openDir(subpath, .{}) catch |err| {
        if (err == std.fs.Dir.OpenError.FileNotFound) return null;

        return err;
    };
}
