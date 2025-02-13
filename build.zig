const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const monado_dep = b.dependency("monado", .{});
    const libmonado_inc = monado_dep.path("src/xrt/targets/libmonado");

    const translate_c = b.addTranslateC(.{
        .link_libc = true,
        .target = target,
        .optimize = optimize,
        .root_source_file = libmonado_inc.path(b, "monado.h"),
    });

    const translate_c_mod = translate_c.createModule();

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "libmonado_c", .module = translate_c_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "monado-task-switcher",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
