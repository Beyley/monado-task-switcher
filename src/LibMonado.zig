const std = @import("std");
const builtin = @import("builtin");

const c = @import("libmonado_c");

const log = std.log.scoped(.libmonado_loader);

pub const LibMonado = @This();

dynlib: std.DynLib,

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

    return .{
        .dynlib = dynlib,
    };
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
