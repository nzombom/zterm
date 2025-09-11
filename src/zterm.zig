const std = @import("std");
const Pty = @import("Pty.zig");
const x = @import("x.zig");
const font = @import("font.zig");

pub fn main() !void {
	try font.init();
	defer font.deinit();
	try font.load("monospace");

	try x.init();
	const w = try x.Window.open();
	defer w.close();
	w.map();
	x.flush();

	while (true) {
		const e = try x.getEvent();
		std.debug.print("{}\n", .{ e });
		if (e.type == x.Event.Type.destroy) break;
		x.flush();
	}

	// var pty = try Pty.open("sh", &.{ "sh" });
	// defer pty.close();
	// while (true) {
		// const c = pty.read() catch |err| switch(err) {
			// Pty.ReadError.EndOfStream => return,
			// Pty.ReadError.ReadFailed => return err,
		// };
		// std.debug.print("{x}", .{ c });
	// }
}
