const std = @import("std");

pub fn logFn(
	comptime level: std.log.Level,
	comptime scope: @Type(.enum_literal),
	comptime format: []const u8,
	args: anytype,
) void {
	const type_prefix = switch (level) {
		.debug => "[\x1b[1;34mdebug\x1b[0m] ",
		.info => "[\x1b[1;36minfo\x1b[0m] ",
		.warn => "[\x1b[1;33mwarn\x1b[0m] ",
		.err => "[\x1b[1;31merr\x1b[0m] ",
	};
	const scope_prefix = "(" ++ @tagName(scope) ++ "): ";

	std.debug.lockStdErr();
	defer std.debug.unlockStdErr();
	std.debug.print(type_prefix ++ scope_prefix ++ format ++ "\n", args);
}
