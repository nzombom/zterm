const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");
const display = @import("x.zig");
const font = @import("font.zig");
const Pty = @import("Pty.zig");
const Screen = @import("Screen.zig");

const log = @import("log.zig");
pub const std_options: std.Options = .{
	.log_level = .debug,
	.logFn = log.logFn,
};
const logger = std.log.scoped(.main);

const allocator = std.heap.smp_allocator;

fn startRedraw(updated: *i64, timeout: *?u64) void {
	const now = std.time.milliTimestamp();
	if (timeout.* != null) {
		const interval = @as(u64, @intCast(now - updated.*))
			/ config.min_latency;
		if (interval >= @as(u64, @intCast(timeout.*.?)) / config.min_latency
			and timeout.*.? < config.max_latency)
			timeout.*.? += config.min_latency;
	} else {
		timeout.* = config.min_latency;
		updated.* = now;
	}
}

pub fn main() anyerror!void {
	try font.init();
	defer font.deinit();
	try display.init();
	defer display.deinit();

	var df = try display.DisplayFont.init(allocator, config.font, .gray);
	defer df.deinit();
	var win = try display.Window.open(allocator,
		config.default_width * df.face.width,
		config.default_height * df.face.height);
	defer win.close();

	win.setResizeGrid(df.face.width, df.face.height);
	win.setTitle("zterm");
	try win.setClass("zterm", "zterm");
	win.draw();
	display.flush();

	var scr = try Screen.init(allocator,
		config.default_width,
		config.default_height);
	defer scr.deinit();

	var pty = try Pty.init("sh", &.{ "sh" });
	defer pty.deinit();

	var updated: i64 = undefined;
	var timeout: ?u64 = null;

	while (true) {
		const has_event = try display.pollEvent((&win)[0..1]);
		if (has_event) |event| switch (event.type) {
			.destroy => break,
			.resize => |resize| {
				try scr.resize(resize.width / df.face.width,
					resize.height / df.face.height);
				if (resize.redraw_required) scr.prepareRedraw();
				try scr.draw(&win, &df);
				win.draw();
				display.flush();
				timeout = null;
			},
			else => {},
		};

		if (try pty.readable()) {
			try scr.putChar(try pty.readChar());
			startRedraw(&updated, &timeout);
		}

		if (timeout != null) {
			if (std.time.milliTimestamp() - updated > timeout.?) {
				try scr.draw(&win, &df);
				win.draw();
				display.flush();
				timeout = null;
			}
		}
	}
}
