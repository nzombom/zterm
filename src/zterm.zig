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
	const f = try font.Face.load("monospace:size=12");
	const bitmap_A = try f.renderGlyph(allocator, f.getCharGlyphIndex('A'),
		font.PixelMode.gray);
	defer bitmap_A.free(allocator);
	const bitmap_a = try f.renderGlyph(allocator, f.getCharGlyphIndex('a'),
		font.PixelMode.gray);
	defer bitmap_a.free(allocator);

	try display.init();
	const w = try display.Window.open(config.default_width,
		config.default_height);
	defer w.close();
	w.map();
	display.flush();

	while (true) {
		const e = try display.getEvent();
		switch (e.type) {
			.destroy => break,
			.expose => {
				w.renderBitmap(bitmap_A, 48, 48);
				w.renderBitmap(bitmap_a, 48 + 8, 48);
				w.map();
				display.flush();
			},
			else => {},
		}
		display.flush();
	}
}
