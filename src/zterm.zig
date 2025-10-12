const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");
const display = @import("display/x_xrender.zig");
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

pub fn main() !void {
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

	const pty = try Pty.init(allocator, "sh", &.{ "sh" }, "zterm");
	defer pty.deinit();

	var updated: i64 = undefined;
	var timeout: ?u64 = null;

	var parser: char.EscapeParser = .init();

	while (true) {
		const has_event = try display.pollEvent((&win)[0..1]);
		if (has_event) |event| switch (event) {
			.destroy => break,
			.resize => |resize| {
				try scr.resize(resize.width / df.face.width,
					resize.height / df.face.height);
				if (resize.redraw_required) scr.prepareRedraw();
				try scr.draw(display, &win, &df);
				win.draw();
				display.flush();
				timeout = null;
			},
			.key => |key| {
				if (key.event.down) {
					const str = key.event.toString();
					try pty.writeString(str.data[0..str.len]);
					startRedraw(&updated, &timeout);
				}
			},
			else => {},
		};

		const maybe_byte = pty.readByte() catch |err| switch (err) {
			error.EndOfStream => std.process.exit(0),
			else => return err,
		};
		if (maybe_byte) |b| if (parser.parse(b)) |t| try scr.putToken(t);
		startRedraw(&updated, &timeout);

		if (timeout != null) {
			if (std.time.milliTimestamp() - updated > timeout.?) {
				try scr.draw(display, &win, &df);
				win.draw();
				display.flush();
				timeout = null;
			}
		}
	}
}
