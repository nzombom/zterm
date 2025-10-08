//! represents a buffer of chars
const Screen = @This();

const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");

const logger = std.log.scoped(.screen);

pub const Error = error { OutOfMemory };

allocator: std.mem.Allocator,
/// lines are stored bottom-to-top
lines: []Line,
/// the index of the current bottom line (between 0 and scr.lines.len)
bottom: u16,
/// the number of lines above the bottom that have been allocated
scrollback: u16,
/// the height of the screen viewport
view_height: u16,
/// the bottom of the screen viewport
view_bottom: u16,
/// the width of each line
width: u16,
/// cursor x position, from the left
cursor_x: u16,
/// cusror y position, from the bottom
cursor_y: u16,

pub const Line = struct {
	/// buffer of chars (width should be stored just once in the parent object
	/// instead of with every line)
	c: [*]char.Char,
	/// whether this line requires redrawing (a char has changed, it has moved)
	redraw: bool,
};

/// get a line at an index
pub fn lineAt(scr: *const Screen, index: i17) *Line {
	return &scr.lines[@intCast(@mod((scr.bottom + index),
		@as(u16, @intCast(scr.lines.len))))];
}

/// initialize a screen with viewport size and no scrollback
pub fn init(
	allocator: std.mem.Allocator,
	width: u16, view_height: u16,
) Error!Screen {
	var scr: Screen = .{
		.allocator = allocator,
		.lines = try allocator.alloc(Line, config.max_scrollback),
		.bottom = 0, .scrollback = 0,
		.view_height = view_height, .view_bottom = 0,
		.width = width,
		.cursor_x = 0, .cursor_y = 0,
	};
	try scr.addLines(config.max_scrollback);
	return scr;
}

pub fn deinit(scr: *Screen) void {
	for (0..scr.scrollback) |i|
		scr.allocator.free(scr.lineAt(@intCast(i)).c[0..scr.width]);
}

/// add n empty lines to the bottom of the screen
pub fn addLines(scr: *Screen, n: u16) Error!void {
	if (n > 0) scr.prepareRedraw();
	for (0..n) |_| {
		scr.bottom = if (scr.bottom == 0)
			@intCast(scr.lines.len - 1) else scr.bottom - 1;
		if (scr.scrollback < scr.lines.len) {
			scr.lines[scr.bottom] = .{
				.c = (try scr.allocator.alloc(char.Char, scr.width)).ptr,
				.redraw = true,
			};
			scr.scrollback += 1;
		}
		@memset(scr.lines[scr.bottom].c[0..scr.width], char.null_char);
	}
}

/// resize the screen viewport
pub fn resize(scr: *Screen, width: u16, view_height: u16) Error!void {
	scr.view_height = view_height;

	if (width != scr.width) {
		for (0..scr.scrollback) |y_usize| {
			const y: i17 = @intCast(y_usize);
			const l = scr.lineAt(y);
			l.c = (try scr.allocator.realloc(l.c[0..scr.width], width)).ptr;
			if (width > scr.width) {
				@memset(l.c[scr.width..width], char.null_char);
				l.redraw = true;
			}
		}
		scr.width = width;
		scr.cursor_x = @min(scr.cursor_x, scr.width);
	}
}

/// move the cursor down, scrolling if necessary and scroll is true
pub fn cursorDown(scr: *Screen, scroll: bool) Error!void {
	if (scr.cursor_y > 0) scr.cursor_y -= 1 else if (scroll) {
		try scr.addLines(1);
		scr.cursor_y = 0;
	}
}
/// move the cursor up
pub fn cursorUp(scr: *Screen) Error!void {
	if (scr.cursor_y < scr.view_height) scr.cursor_y += 1;
}
/// move the cursor right, wrapping lines if necessary and wrap is true
pub fn cursorRight(scr: *Screen, wrap: bool) Error!void {
	if (scr.cursor_x < scr.width) scr.cursor_x += 1 else if (wrap) {
		scr.cursor_x = 0;
		try scr.cursorDown(true);
	}
}
/// move the cursor left
pub fn cursorLeft(scr: *Screen) Error!void {
	if (scr.cursor_x > 0) scr.cursor_x -= 1;
}

/// put a char under the cursor (TODO: this should handle esc seqs as well)
pub fn putChar(scr: *Screen, c: char.Char) Error!void {
	if (char.toCode(c) == 0x0a) {
		try scr.cursorDown(true);
		return;
	}
	scr.lineAt(scr.cursor_y).c[scr.cursor_x] = c;
	scr.lineAt(scr.cursor_y).redraw = true;
	try scr.cursorRight(true);
}

/// set every line to requiring a redraw (should use this if window pixel
/// data is lost)
pub fn prepareRedraw(scr: *Screen) void {
	for (0..scr.lines.len) |y| scr.lineAt(@intCast(y)).redraw = true;
}

/// draws the characters to the display; takes in the implementation of display
pub fn draw(
	scr: *const Screen,
	display: type,
	win: *display.Window, df: *display.DisplayFont,
) display.Error!void {
	for (0..scr.view_height) |y_usize| {
		const y: i17 = @intCast(y_usize);
		if (!scr.lineAt(y).redraw) continue;
		if (y > scr.scrollback) continue;
		for (0..scr.width, scr.lineAt(y).c) |x, c|
			try win.renderChar(df, c, @intCast(x), @intCast(y),
				config.background_color, config.foreground_color);
		scr.lineAt(y).redraw = false;
	}

	// render the cursor (this will double-render that char but that was better
	// than checking the value for every run of the loop)
	try win.renderChar(df, scr.lineAt(scr.cursor_y).c[scr.cursor_x],
		scr.cursor_x, scr.cursor_y,
		config.cursor_background_color orelse config.background_color,
		config.cursor_foreground_color orelse config.foreground_color);
}
