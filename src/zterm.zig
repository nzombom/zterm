const std = @import("std");
const config = @import("config.zig");
const Pty = @import("Pty.zig");
const display = @import("x.zig");
const font = @import("font.zig");

const log = @import("log.zig");
pub const std_options = std.Options{
	.log_level = .debug,
	.logFn = log.logFn,
};
const logger = std.log.scoped(.main);

const allocator = std.heap.smp_allocator;

pub fn main() !void {
	try font.init();
	defer font.deinit();
	try display.init();
	defer display.deinit();

	const w = try display.Window.open(config.default_width,
		config.default_height);
	defer w.close();
	w.map();
	display.flush();

	const f = try display.DisplayFont.init(allocator, config.font, .gray);
	defer f.deinit();

	logger.info("rendering on every keypress...", .{});
	while (true) {
		const event = try display.getEvent();
		switch (event.type) {
			.destroy => break,
			.key => |e| {
				if (!e.down) continue;
				var t = try std.time.Timer.start();
				const str = "Hello World! ";
				var i: u32 = 0;
				while (i < 128 * 128) : (i += 1) {
					try w.renderChar(f, str[@mod(i, str.len)],
						@intCast(@mod(i, 128)), @intCast(@divFloor(i, 128)));
				}
				w.map();
				display.flush();
				logger.info("{}ms for {} glyphs",
					.{ t.read() / 1_000_000, 128 * 128 });
			},
			else => {},
		}
		display.flush();
	}

	const p = try Pty.init(allocator, "sh", &.{ "sh", "-c", "echo " });
	defer p.deinit(allocator);
	while (true) {
		std.debug.print("{x} ", .{ p.readChar() catch {
			std.debug.print("\n", .{}); break;
		} });
	}
}
