const std = @import("std");

pub fn logFn(
	comptime level: std.log.Level,
	comptime scope: @Type(.enum_literal),
	comptime format: []const u8,
	args: anytype,
) void {
	const type_prefix = switch (level) {
		.debug => "[\x1b[1;34mdebug\x1b[m] ",
		.info => "[\x1b[1;36minfo\x1b[m] ",
		.warn => "[\x1b[1;33mwarn\x1b[m] ",
		.err => "[\x1b[1;31merr\x1b[m] ",
	};
	const colors = "123456";
	const scope_name = @tagName(scope);
	const color = scope_name[0] % 6;
	const scope_prefix = "(\x1b[9" ++ .{ colors[color] } ++ "m"
		++ @tagName(scope) ++ "\x1b[m): ";

	std.debug.lockStdErr();
	defer std.debug.unlockStdErr();
	std.debug.print(type_prefix ++ scope_prefix ++ format ++ "\n", args);
}
