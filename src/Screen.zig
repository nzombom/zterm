//! represents a buffer of chars
const Screen = @This();

const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");

const logger = std.log.scoped(.screen);

pub const Error = error { OutOfMemory, Bad };

allocator: std.mem.Allocator,
/// lines are stored bottom-to-top
lines: []Line,
/// the index of the current bottom line (between 0 and scr.nLines())
bottom: u16,
/// the height of the screen viewport
view_height: u16,
/// the bottom of the screen viewport
view_bottom: u16,
/// the width of each line
width: u16,

/// cursor position
cursor: Pos,
/// saved cursor position
saved_cursor: Pos,

graphic: Graphic,

/// graphic attributes (8-bit aligned)
pub const Graphic = struct {
	const ColorType = enum(u2) { default, four_bit };

	attrs: packed struct(u7) {
		intensity: enum(u2) { normal, bold, faint } = .normal,
		underline: bool = false,
		italic: bool = false,
		blink: bool = false,
		reverse: bool = false,
		strike: bool = false,
	} = .{},
	colors: packed struct(u8) { fg: u4 = 7, bg: u4 = 7 } = .{},
	color_types: packed struct(u5) {
		fg: ColorType = .default,
		bg: ColorType = .default,
		cursor: bool = false,
	} = .{},
};

/// one cell of the grid
pub const Cell = struct {
	char: char.Char,
	graphic: Graphic,
};

/// a position from the left & from the bottom
const Pos = struct { x: u16, y: u16 };

pub const Line = struct {
	/// buffer of cells (width should be stored just once in the parent object
	/// instead of with every line)
	c: [*]Cell,
	/// whether this line requires redrawing (a char has changed, it has moved)
	redraw: bool,
};

/// return scr.lines.len as a u16 since that's such a common pattern
pub fn nLines(scr: *const Screen) u16 { return @intCast(scr.lines.len); }

/// get the index of a line
pub fn bufferIndex(scr: *const Screen, index: anytype) u16 {
	return @intCast(@mod((scr.bottom + index), scr.nLines()));
}
/// get a line at an index
pub fn lineAt(scr: *const Screen, index: anytype) *Line {
	return &scr.lines[scr.bufferIndex(index)];
}

/// validate all values because things might become screwed up
pub fn validate(scr: *Screen) Error!void {
	if (scr.bottom >= scr.nLines()) return error.Bad;
	if (scr.view_bottom >= scr.nLines()) scr.view_bottom = scr.nLines() - 1;
	if (scr.view_height == 0) return error.Bad;
	if (scr.cursor.y >= scr.nLines()) scr.cursor.y = scr.nLines() - 1;
	if (scr.cursor.x >= scr.width) scr.cursor.x = scr.width - 1;
}

pub fn empty_cell(scr: *const Screen) Cell {
	return .{
		.char = char.null_char, .graphic = scr.graphic,
	};
}

/// initialize a screen with viewport size and config max scrollback
pub fn init(
	allocator: std.mem.Allocator,
	width: u16, view_height: u16,
	scrollback: u16,
) Error!Screen {
	var scr: Screen = .{
		.allocator = allocator,
		.lines = try allocator.alloc(Line, scrollback),
		.bottom = 0,
		.view_bottom = 0,
		.view_height = view_height,
		.width = width,
		.cursor = .{ .x = 0, .y = 0 },
		.saved_cursor = .{ .x = 0, .y = 0 },
		.graphic = .{},
	};
	for (scr.lines) |*l| {
		l.* = .{
			.c = (try allocator.alloc(Cell, scr.width)).ptr,
			.redraw = true,
		};
		@memset(l.c[0..scr.width], scr.empty_cell());
	}
	logger.debug("initialized screen: {}x{} view, {} lines total",
		.{ width, view_height, scrollback });
	return scr;
}

pub fn deinit(scr: *Screen) void {
	for (scr.lines) |*l| scr.allocator.free(l.c[0..scr.width]);
	scr.allocator.free(scr.lines);
}

pub fn scroll(scr: *Screen, n: i17) void {
	scr.view_bottom = if (n > 0)
		@min(scr.nLines() - 1, scr.view_bottom +| @as(u16, @intCast(n)))
		else scr.view_bottom -| @as(u16, @intCast(-n));
}

/// add n empty lines to the bottom of the buffer
pub fn addLines(scr: *Screen, n: u16) void {
	scr.bottom = scr.bufferIndex(-@as(i17, n));
	for (0..n) |i| @memset(scr.lineAt(i).c[0..scr.width], scr.empty_cell());
	if (n > 0) scr.prepareRedraw();
}

/// resize the screen viewport
pub fn resize(scr: *Screen, width: u16, view_height: u16) Error!void {
	scr.view_height = view_height;

	if (width == scr.width) return;
	// resize every line to a new width
	for (scr.lines) |*l| {
		l.c = (try scr.allocator.realloc(l.c[0..scr.width], width)).ptr;
		if (width > scr.width) {
			@memset(l.c[scr.width..width], scr.empty_cell());
			l.redraw = true;
		}
	}
	scr.width = width;
	scr.cursor.x = @min(scr.cursor.x, scr.width);
}

pub fn scrollToCursor(scr: *Screen) void {
	const view_top = scr.view_bottom + scr.view_height;
	if (scr.cursor.y < scr.view_bottom) scr.view_bottom = scr.cursor.y
	else if (scr.cursor.y >= view_top) scr.view_bottom
		= scr.cursor.y - scr.view_height;
}

/// move the cursor down n lines, adding lines if specified
pub fn cursorDown(scr: *Screen, n: u16, add: bool) Error!void {
	scr.lineAt(scr.cursor.y).redraw = true;
	const add_count = n -| scr.cursor.y;
	scr.cursor.y -|= n;
	if (add and add_count > 0) {
		scr.addLines(add_count);
		scr.cursor.y = 0;
		scr.prepareRedraw();
	}
	scr.lineAt(scr.cursor.y).redraw = true;
}
/// move the cursor up
pub fn cursorUp(scr: *Screen, n: u16) Error!void {
	scr.lineAt(scr.cursor.y).redraw = true;
	scr.cursor.y += @min(n, scr.nLines() - scr.cursor.y);
	scr.lineAt(scr.cursor.y).redraw = true;
}

/// move the cursor n chars right, wrapping lines if specified
pub fn cursorRight(scr: *Screen, n: u16, wrap: bool) Error!void {
	scr.lineAt(scr.cursor.y).redraw = true;
	const moved: u16 = scr.cursor.x + n;
	if (moved < scr.width) scr.cursor.x = moved else {
		if (wrap) {
			scr.cursor.x = moved % scr.width;
			try scr.cursorDown(moved / scr.width, true);
		} else scr.cursor.x = scr.width - 1;
	}
}
/// move the cursor left
pub fn cursorLeft(scr: *Screen, n: u16) Error!void {
	scr.lineAt(scr.cursor.y).redraw = true;
	scr.cursor.x -|= n;
}

pub fn putChar(scr: *Screen, c: char.Char) Error!void {
	switch (char.toCode(c)) {
		0x07 => logger.info("beep!", .{}),
		0x08 => try scr.cursorLeft(1),
		0x09 => try scr.cursorRight(8 - scr.cursor.x % 8, false),
		0x0a, 0x0b => try scr.cursorDown(1, true),
		0x0d => scr.cursor.x = 0,
		else => {
			scr.lineAt(scr.cursor.y).c[scr.cursor.x] = .{
				.char = c, .graphic = scr.graphic,
			};
			scr.lineAt(scr.cursor.y).redraw = true;
			try scr.cursorRight(1, true);
		}
	}
}

/// set every visible line to requiring a redraw (should use this if window
/// pixel data is lost)
pub fn prepareRedraw(scr: *Screen) void {
	for (scr.view_bottom..scr.view_bottom + scr.view_height) |y|
		scr.lineAt(y).redraw = true;
}

/// draws the characters to the display; takes in the implementation of display
pub fn draw(
	scr: *const Screen,
	display: type,
	win: *display.Window, df: *display.DisplayFont,
) display.Error!void {
	const top_line = scr.view_bottom + scr.view_height;
	for (scr.view_bottom..top_line, 0..) |scr_y, display_y| {
		if (!scr.lineAt(scr_y).redraw) continue;
		for (0..scr.width, scr.lineAt(scr_y).c) |x, cell| {
			var c = cell;
			if (x == scr.cursor.x and scr_y == scr.cursor.y) {
				c.graphic.color_types.cursor = true;
			}
			try win.renderChar(df, c, @intCast(x), @intCast(display_y));
		}
		scr.lineAt(scr_y).redraw = false;
	}
}
