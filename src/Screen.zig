//! represents a buffer of chars
const Screen = @This();

const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");
const display = @import("x.zig");

const logger = std.log.scoped(.screen);

const Error = error { OutOfMemory };

allocator: std.mem.Allocator,
/// lines are stored bottom-to-top because that is how it should work imo
lines: std.Deque(Line),
width: u16,
cursor_x: u16,
/// cursor y is from the bottom (0 is the bottom line)
cursor_y: u16,

pub const Line = struct {
	/// buffer of chars (width should be stored just once in the parent object
	/// instead of with every line)
	c: [*]char.Char,
	/// whether this line requires redrawing (a char has changed, it has moved)
	redraw: bool,
};

fn dequePtr(T: type, deque: std.Deque(T), index: usize) *T {
	return &deque.buffer[buffer_index: {
		const head_len = deque.buffer.len - deque.head;
		if (index < head_len) break :buffer_index deque.head + index;
		break :buffer_index index - head_len;
	}];
}

pub fn init(
	allocator: std.mem.Allocator,
	width: u16, height: u16,
) Error!Screen {
	var scr: Screen = .{
		.allocator = allocator,
		.lines = try .initCapacity(allocator, height),
		.width = width, .cursor_x = 0, .cursor_y = 0,
	};
	try scr.addLinesTop(height);
	return scr;
}

pub fn deinit(scr: *Screen) void {
	scr.removeLinesTop(@intCast(scr.lines.len));
}

/// add n empty lines to the top of the screen
pub fn addLinesTop(scr: *Screen, n: u16) Error!void {
	for (0..n) |_| {
		try scr.lines.pushBack(scr.allocator, .{
			.c = (try scr.allocator.alloc(char.Char, scr.width)).ptr,
			.redraw = true,
		});
		@memset(scr.lines.at(scr.lines.len - 1).c[0..scr.width],
			char.null_char);
	}
}
/// add n empty lines to the bottom of the screen & move the cursor up
pub fn addLinesBottom(scr: *Screen, n: u16) Error!void {
	scr.prepareRedraw();
	for (0..n) |_| {
		try scr.lines.pushFront(scr.allocator, .{
			.c = (try scr.allocator.alloc(char.Char, scr.width)).ptr,
			.redraw = true,
		});
		@memset(scr.lines.at(0).c[0..scr.width], char.null_char);
	}
	scr.cursor_y += n;
}
/// remove n lines from the top of the screen
pub fn removeLinesTop(scr: *Screen, n: u16) void {
	for (0..n) |_| scr.allocator.free((scr.lines.popBack()
			orelse unreachable).c[0..scr.width]);
}
/// remove n lines from the bottom of the screen & move the cursor down
pub fn removeLinesBottom(scr: *Screen, n: u16) void {
	scr.prepareRedraw();
	for (0..n) |_| scr.allocator.free((scr.lines.popFront()
			orelse unreachable).c[0..scr.width]);
	scr.cursor_y -= n;
}

/// resize the screen to w by h chars
pub fn resize(scr: *Screen, width: u16, height: u16) Error!void {
	const prev_h = scr.lines.len;
	if (height > prev_h) {
		try scr.addLinesTop(@intCast(height - prev_h));
	} else if (height < prev_h) {
		scr.removeLinesTop(@intCast(prev_h - height));
	}

	if (width != scr.width) {
		for (0..scr.lines.len) |y| {
			dequePtr(Line, scr.lines, y).*.c = (try scr.allocator.realloc(
					scr.lines.at(y).c[0..scr.width], width)).ptr;
			if (width > scr.width) {
				@memset(scr.lines.at(y).c[scr.width..width], char.null_char);
				dequePtr(Line, scr.lines, y).*.redraw = true;
			}
		}
		scr.width = width;
	}
}

/// move the cursor down, scrolling if necessary
pub fn cursorDown(scr: *Screen) Error!void {
	const scroll = scr.cursor_y == 0;
	if (!scroll) scr.cursor_y -= 1 else {
		try scr.addLinesBottom(1);
		scr.removeLinesTop(1);
		scr.cursor_y = 0;
	}
}
/// move the cursor up, scrolling if necessary
pub fn cursorUp(scr: *Screen) Error!void {
	scr.cursor_y += 1;
	if (scr.cursor_y >= scr.lines.len) {
		try scr.addLinesTop(1);
		scr.removeLinesBottom(1);
		scr.cursor_y = scr.lines.len - 1;
	}
}
/// move the cursor right, wrapping lines if necessary
pub fn cursorRight(scr: *Screen) Error!void {
	scr.cursor_x += 1;
	if (scr.cursor_x >= scr.width) {
		scr.cursor_x = 0;
		try scr.cursorDown();
	}
}
/// move the cursor left, wrapping lines if necessary
pub fn cursorLeft(scr: *Screen) Error!void {
	const wrap = scr.cursor_x == 0;
	if (!wrap) scr.cursor_x -= 1 else {
		scr.cursor_x = scr.width - 1;
		try scr.cursorUp();
	}
}

/// put a char under the cursor (TODO: this should handle esc seqs as well)
pub fn putChar(scr: *Screen, c: char.Char) Error!void {
	if (char.toCode(c) == 0x0a) {
		try scr.cursorDown();
		scr.cursor_x = 0;
		return;
	}
	scr.lines.at(scr.cursor_y).c[scr.cursor_x] = c;
	dequePtr(Line, scr.lines, scr.cursor_y).redraw = true;
	try scr.cursorRight();
}

var draws: u32 = 0;
pub fn draw(
	scr: *const Screen,
	win: *display.Window, df: *display.DisplayFont,
) display.Error!void {
	for (0..scr.lines.len) |y| {
		if (!scr.lines.at(y).redraw) continue;
		for (0..scr.width, scr.lines.at(y).c) |x, c| {
			draws += 1;
			try win.renderChar(df, c, @intCast(x), @intCast(y),
				config.background_color, config.foreground_color);
		}
		dequePtr(Line, scr.lines, y).redraw = false;
	}

	// render the cursor (this will double-render that char but that was better
	// than checking the value for every run of the loop)
	try win.renderChar(df, scr.lines.at(scr.cursor_y).c[scr.cursor_x],
		scr.cursor_x, scr.cursor_y,
		config.cursor_background_color orelse config.background_color,
		config.cursor_foreground_color orelse config.foreground_color);
}

/// set every line to requiring a redraw (should use this if window pixel
/// data is lost)
pub fn prepareRedraw(scr: *Screen) void {
	for (0..scr.lines.len) |y| dequePtr(Line, scr.lines, y).redraw = true;
}
