//! represents a buffer of chars
const Screen = @This();

const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");
const display = @import("x.zig");

const Error = error { OutOfMemory, NoLines };

allocator: std.mem.Allocator,
lines: std.Deque(Line),
w: u16,
cursor_x: u16, cursor_y: u16,

pub const Line = struct {
	/// buffer of chars (width should be stored just once in the parent object
	/// instead of with every line)
	c: [*]char.Char,
	/// whether this line requires redrawing (a char has changed, it has moved,
	/// etc.)
	redraw: bool,
};

fn dequePtr(T: type, deque: std.Deque(T), index: usize) *T {
	return &deque.buffer[buffer_index: {
		const head_len = deque.buffer.len - deque.head;
		if (index < head_len) break :buffer_index deque.head + index;
		break :buffer_index index - head_len;
	}];
}

pub fn init(allocator: std.mem.Allocator, w: u16, h: u16) Error!Screen {
	var s: Screen = .{
		.allocator = allocator,
		.lines = try .initCapacity(allocator, h),
		.w = w, .cursor_x = 0, .cursor_y = 0,
	};
	s.addLinesFront(h) catch unreachable;
	s.cursor_y -= 1;
	return s;
}

pub fn deinit(self: *Screen) void {
	self.removeLinesFront(@intCast(self.lines.len)) catch unreachable;
}

/// add n empty lines to the bottom of the screen
pub fn addLinesBack(self: *Screen, n: u16) Error!void {
	for (0..n) |_| {
		try self.lines.pushBack(self.allocator, .{
			.c = (try self.allocator.alloc(char.Char, self.w)).ptr,
			.redraw = true,
		});
		@memset(self.lines.at(self.lines.len - 1).c[0..self.w],
			char.null_char);
	}
}
/// add n empty lines to the top of the screen and move the cursor down
pub fn addLinesFront(self: *Screen, n: u16) Error!void {
	self.prepareRedraw();
	for (0..n) |_| {
		try self.lines.pushFront(self.allocator, .{
			.c = (try self.allocator.alloc(char.Char, self.w)).ptr,
			.redraw = true,
		});
		@memset(self.lines.at(0).c[0..self.w], char.null_char);
	}
	self.cursor_y += n;
}
/// remove n lines from the bottom of the screen
pub fn removeLinesBack(self: *Screen, n: u16) Error!void {
	for (0..n) |_| self.allocator.free((self.lines.popBack()
			orelse return error.NoLines).c[0..self.w]);
}
/// remove n lines from the top of the screen and move the cursor up
pub fn removeLinesFront(self: *Screen, n: u16) Error!void {
	self.prepareRedraw();
	for (0..n) |_| self.allocator.free((self.lines.popFront()
			orelse return error.NoLines).c[0..self.w]);
	self.cursor_y -= n;
}

/// resize the screen to w by h chars
pub fn resize(self: *Screen, w: u16, h: u16) Error!void {
	const prev_h = self.lines.len;
	if (h > prev_h) {
		self.addLinesFront(h - prev_h);
	} else if (h < prev_h) {
		self.removeLinesFront(prev_h - h);
	}

	if (w != self.w) {
		for (0..self.lines.len) |y| {
			dequePtr(Line, self.lines, y).*.c = (try
			self.allocator.realloc(self.lines.at(y).c[0..self.w], w)
		).ptr;
			if (w > self.w) @memset(self.lines.at(y)[self.w..w],
			char.null_char);
		}
		self.w = w;
	}
}

/// move the cursor down, scrolling if necessary
pub fn cursorDown(self: *Screen) Error!void {
	self.cursor_y += 1;
	if (self.cursor_y >= self.lines.len) {
		try self.addLinesBack(1);
		try self.removeLinesFront(1);
		self.cursor_y = @intCast(self.lines.len - 1);
	}
}
/// move the cursor up, scrolling if necessary
pub fn cursorUp(self: *Screen) Error!void {
	const scroll = self.cursor_y == 0;
	if (!scroll) self.cursor_y -= 1 else {
		try self.addLinesFront(1);
		try self.removeLinesBack(1);
		self.cursor_y = 0;
	}
}
/// move the cursor right, wrapping lines if necessary
pub fn cursorRight(self: *Screen) Error!void {
	self.cursor_x += 1;
	if (self.cursor_x >= self.w) {
		self.cursor_x = 0;
		try self.cursorDown();
	}
}
/// move the cursor left, wrapping lines if necessary
pub fn cursorLeft(self: *Screen) Error!void {
	const wrap = self.cursor_x == 0;
	if (!wrap) self.cursor_x -= 1 else {
		self.cursor_x = self.w - 1;
		try self.cursorUp();
	}
}

/// put a char under the cursor (TODO: this should handle esc seqs as well)
pub fn putChar(self: *Screen, c: char.Char) Error!void {
	if (char.toCode(c) == 0x0a) {
		try self.cursorDown();
		self.cursor_x = 0;
		return;
	}
	self.lines.at(self.cursor_y).c[self.cursor_x] = c;
	dequePtr(Line, self.lines, self.cursor_y).redraw = true;
	try self.cursorRight();
}

pub fn draw(
	self: *const Screen,
	window: display.Window,
	font: display.DisplayFont,
) display.Error!void {
	for (0..self.lines.len) |y| {
		if (!self.lines.at(y).redraw) continue;
		for (0..self.w, self.lines.at(y).c) |x, c| {
			try window.renderChar(font, c,
				@as(u16, @intCast(x)), @as(u16, @intCast(y)),
				config.background_color, config.foreground_color);
		}
		dequePtr(Line, self.lines, y).redraw = false;
	}

	// render the cursor (this will double-render that char but that was better
	// than checking the value for every run of the loop)
	try window.renderChar(font,
		self.lines.at(self.cursor_y).c[self.cursor_x],
		@as(u16, @intCast(self.cursor_x)),
		@as(u16, @intCast(self.cursor_y)),
		config.cursor_background_color orelse config.background_color,
		config.cursor_foreground_color orelse config.foreground_color);
}

/// set every line to requiring a redraw (should use this if window pixel
/// data is lost)
pub fn prepareRedraw(self: *Screen) void {
	for (0..self.lines.len) |y| dequePtr(Line, self.lines, y).redraw = true;
}
