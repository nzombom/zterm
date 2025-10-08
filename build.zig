const std = @import("std");

pub fn build(b: *std.Build) void {
	const target_opts = b.standardTargetOptions(.{});
	const optimize_opts = b.standardOptimizeOption(.{});

	const exe = b.addExecutable(.{
		.name = "zterm",
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/zterm.zig"),
			.target = target_opts,
			.optimize = optimize_opts,
		}),
	});

	exe.linkLibC();
	exe.linkSystemLibrary("xcb");
	exe.linkSystemLibrary("xcb-render");
	exe.linkSystemLibrary("xcb-xkb");
	exe.linkSystemLibrary("xcb-render-util");
	exe.linkSystemLibrary("fontconfig");
	exe.linkSystemLibrary("freetype");

	b.installArtifact(exe);

	const run = b.addRunArtifact(exe);
	const run_step = b.step("run", "Run the program");
	run_step.dependOn(&run.step);
}
