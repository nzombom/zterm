const std = @import("std");
const config = @import("config.zig");
const Pty = @import("Pty.zig");
const display = @import("x.zig");
const font = @import("font.zig");
const char = @import("char.zig");
const Screen = @import("Screen.zig");

const log = @import("log.zig");
pub const std_options = std.Options{
	.log_level = .debug,
	.logFn = log.logFn,
};
const logger = std.log.scoped(.main);

const allocator = std.heap.smp_allocator;

var s: Screen = undefined;
var w: display.Window = undefined;

fn runScr() anyerror!void {
	const p = try Pty.init(allocator, "sh", &.{ "sh" });
	defer p.deinit(allocator);

	s = try Screen.init(allocator, 80, 60);
	defer s.deinit();

	while (true) {
		const c = p.readChar() catch break;
		s.putChar(c);
	}
}

pub fn main() anyerror!void {
	try font.init();
	defer font.deinit();
	try display.init();
	defer display.deinit();

	w = try display.Window.open(config.default_width,
		config.default_height);
	defer w.close();
	w.map();
	display.flush();

	const f = try display.DisplayFont.init(allocator, config.font, .gray);
	defer f.deinit();

	const scrThread = try std.Thread.spawn(.{}, runScr, .{});
	scrThread.detach();

	while (true) {
		const event = try display.waitEvent();
		switch (event.type) {
			.destroy => break,
			.expose => {
				s.prepareRedraw();
				try s.draw(display.Window.renderChar, .{ w, f });
				w.map();
				display.flush();
			},
			else => {},
		}
		display.flush();
	}
}
