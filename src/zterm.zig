const std = @import("std");
const Pty = @import("Pty.zig");
const display = @import("x.zig");
const font = @import("font.zig");

const log = @import("log.zig");
pub const std_options = std.Options{
	.log_level = .debug,
	.logFn = log.logFn,
};

const allocator = std.heap.smp_allocator;

pub fn main() !void {
	try font.init();
	defer font.deinit();
	const f = try font.Face.load("monospace:size=24:style=italic");
	const idx = f.getCharGlyphIndex('B');
	const bitmap = try f.renderGlyph(allocator, idx);
	defer bitmap.free(allocator);
	std.log.debug("char 0x{x} {}x{}:",
		.{ 'B', bitmap.w, bitmap.h });
	var y: u16 = 0;
	while (y < bitmap.h) : (y += 1) {
		var x: u16 = 0;
		while (x < bitmap.w) : (x += 1) {
			const c: []const u8 = " .+:!&%#";
			std.debug.print("{0c}{0c}",
				.{ c[bitmap.data[y * bitmap.pitch + x] / 32] });
		}
		std.debug.print("\n", .{});
	}

	try display.init();
	const w = try display.Window.open();
	defer w.close();
	w.map();
	display.flush();

	while (true) {
		const e = try display.getEvent();
		if (e.type == display.Event.Type.destroy) break;
		display.flush();
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
