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
/// cusror y position, from the bottom of the buffer
cursor_y: u16,

pub const Line = struct {
	/// buffer of chars (width should be stored just once in the parent object
	/// instead of with every line)
	c: [*]char.Char,
	/// whether this line requires redrawing (a char has changed, it has moved)
	redraw: bool,
};

/// get the index of a line
pub fn bufferIndex(scr: *const Screen, index: i17) u16 {
	return @intCast(@mod((scr.bottom + index),
			@as(u16, @intCast(scr.lines.len))));
}
/// get a line at an index
pub fn lineAt(scr: *const Screen, index: i17) *Line {
	return &scr.lines[scr.bufferIndex(index)];
}

/// validate all values because things might become screwed up
pub fn validate(scr: *Screen) Error!void {
	if (scr.bottom >= scr.lines.len) return error.Bad;
	if (scr.scrollback > scr.lines.len)
		scr.scrollback = @intCast(scr.lines.len);
	if (scr.scrollback == 0) try scr.addLines(1);
	if (scr.view_bottom >= scr.scrollback) scr.view_bottom = scr.scrollback - 1;
	if (scr.view_height == 0) return error.Bad;
	if (scr.cursor_y >= scr.scrollback) scr.cursor_y = scr.scrollback - 1;
	if (scr.cursor_x >= scr.width) scr.cursor_x = scr.width - 1;
}

/// initialize a screen with viewport size and config max scrollback
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
	try scr.addLines(1);
	return scr;
}

pub fn deinit(scr: *Screen) void {
	for (0..scr.scrollback) |i|
		scr.allocator.free(scr.lineAt(@intCast(i)).c[0..scr.width]);
	scr.allocator.free(scr.lines);
}

/// add n empty lines to the bottom of the buffer
pub fn addLines(scr: *Screen, n: u16) Error!void {
	// allocate new lines if required
	const need_alloc = @min(n, scr.lines.len - scr.scrollback);
	for (0..need_alloc) |i| { scr.lineAt(-@as(i17, @intCast(i)) - 1).* = .{
		.c = (try scr.allocator.alloc(char.Char, scr.width)).ptr,
		.redraw = true,
	}; }
	scr.scrollback += need_alloc;

	// clear all the lines & scroll down
	for (0..n) |i| @memset(scr.lineAt(-@as(i17, @intCast(i)) - 1)
		.c[0..scr.width], char.null_char);
	scr.bottom = scr.bufferIndex(-@as(i17, @intCast(n)));

	if (n > 0) scr.prepareRedraw();
}

/// resize the screen viewport
pub fn resize(scr: *Screen, width: u16, view_height: u16) Error!void {
	scr.view_height = view_height;

	if (width == scr.width) return;
	// resize every line to a new width
	for (0..scr.scrollback) |y| {
		const l = scr.lineAt(@intCast(y));
		l.c = (try scr.allocator.realloc(l.c[0..scr.width], width)).ptr;
		if (width > scr.width) {
			@memset(l.c[scr.width..width], char.null_char);
			l.redraw = true;
		}
	}
	scr.width = width;
	scr.cursor_x = @min(scr.cursor_x, scr.width);
}

pub fn scrollToCursor(scr: *Screen) void {
	const view_top = scr.view_bottom + scr.view_height;
	if (scr.cursor_y < scr.view_bottom) scr.view_bottom = scr.cursor_y
	else if (scr.cursor_y >= view_top) scr.view_bottom
		= scr.cursor_y - scr.view_height;
}

/// move the cursor down n lines, scrolling if specified
pub fn cursorDown(scr: *Screen, n: u16, scroll: bool) Error!void {
	scr.lineAt(scr.cursor_y).redraw = true;
	const scroll_amount = n -| scr.cursor_y;
	scr.cursor_y -|= n;
	if (scroll and scroll_amount > 0) {
		try scr.addLines(scroll_amount);
		scr.cursor_y = 0;
		scr.prepareRedraw();
	}
	scr.lineAt(scr.cursor_y).redraw = true;
}
/// move the cursor up, unbounded to the viewport if specified but never adding
/// new lines to the buffer
pub fn cursorUp(scr: *Screen, n: u16, unbounded: bool) Error!void {
	scr.lineAt(scr.cursor_y).redraw = true;
	const max_height = if (unbounded) scr.scrollback
		else @min(scr.view_bottom + scr.view_height, scr.scrollback) - 1;
	scr.cursor_y += @min(n, max_height - scr.cursor_y);
	scr.lineAt(scr.cursor_y).redraw = true;
}

/// move the cursor n chars right, wrapping lines if specified
pub fn cursorRight(scr: *Screen, n: u16, wrap: bool) Error!void {
	scr.lineAt(scr.cursor_y).redraw = true;
	const moved: u16 = scr.cursor_x + n;
	if (moved < scr.width) scr.cursor_x = moved else {
		if (wrap) {
			scr.cursor_x = moved % scr.width;
			try scr.cursorDown(moved / scr.width, true);
		} else scr.cursor_x = scr.width - 1;
	}
}
/// move the cursor left (never wraps or does anything special but has the same
/// function signature as the rest)
pub fn cursorLeft(scr: *Screen, n: u16, _: bool) Error!void {
	scr.lineAt(scr.cursor_y).redraw = true;
	scr.cursor_x -|= n;
}

fn putChar(scr: *Screen, c: char.Char) Error!void {
	switch (char.toCode(c)) {
		0x07 => logger.info("beep!", .{}),
		0x08 => try scr.cursorLeft(1, false),
		0x09 => try scr.cursorRight(8 - scr.cursor_x % 8, false),
		0x0a => try scr.cursorDown(1, true),
		0x0b => try scr.cursorDown(1, true),
		0x0d => scr.cursor_x = 0,
		else => {
			scr.lineAt(scr.cursor_y).c[scr.cursor_x] = c;
			scr.lineAt(scr.cursor_y).redraw = true;
			try scr.cursorRight(1, true);
		}
	}
}

/// put a csi, never frees anything
fn putCsi(scr: *Screen, t: char.Token) Error!void {
	const csi = t.csi;
	switch (csi.final) {
		// these seqs are all single-arg default 1 so we lump them
		// together with v as the arg
		.ICH, .CUU, .CUD, .CUF, .CUB,
		.CNL, .CPL, .CHA, .CHT, .IL, .DL, .DCH => |k| {
			logger.info("{}", .{ csi.final });
			const v = (try char.parseCsi("?", scr.allocator, csi.str)
				orelse return)[0].@"?" orelse 1;
			switch (k) {
				.ICH => {
					const chars_moved = scr.width - scr.cursor_x -| v;
					const l = scr.lineAt(scr.cursor_y);
					const cx = scr.cursor_x;
					@memmove(l.c[cx..cx + chars_moved],
						l.c[scr.width - chars_moved..scr.width]);
					@memset(l.c[cx..cx + v], char.null_char);
				},
				.CUU => try scr.cursorUp(v, false),
				.CUD => try scr.cursorDown(v, false),
				.CUF => try scr.cursorRight(v, false),
				.CUB => try scr.cursorLeft(v, false),
				.CNL => {
					try scr.cursorDown(v, false);
					scr.cursor_x = 0;
				},
				.CPL => {
					try scr.cursorUp(v, false);
					scr.cursor_x = 0;
				},
				.CHA => scr.cursor_x = @max(v - 1, scr.width - 1),
				.CHT => scr.cursor_x
					= @min((scr.cursor_x / 8 + v) * 8, scr.width - 1),
				.IL => {
					try scr.addLines(v);
					const temp = try scr.allocator.alloc(Line, v);
					defer scr.allocator.free(temp);
					for (0..v) |y| temp[y] = scr.lineAt(@intCast(y)).*;
					for (v..scr.cursor_y + v) |y|
						scr.lineAt(@intCast(y - v)).*
							= scr.lineAt(@intCast(y)).*;
					for (0..v) |i|
						scr.lineAt(@intCast(scr.cursor_y + i)).* = temp[i];
					scr.cursor_y += v;
				},
				.DL => {
					const real_v = if (scr.cursor_y < v) scr.cursor_y + 1 else v;
					scr.prepareRedraw();
					for (scr.cursor_y + 1 - real_v..scr.cursor_y + 1) |y|
						scr.allocator.free(scr.lineAt(@intCast(y))
							.c[0..scr.width]);
					for (0..scr.cursor_y + 1 - real_v) |i| {
						const y: i17 = scr.cursor_y - real_v
							- @as(i17, @intCast(i));
						scr.lineAt(y + real_v).* = scr.lineAt(y).*;
					}
					scr.bottom += real_v;
					scr.bottom %= @intCast(scr.lines.len);
					scr.scrollback -|= real_v;
					scr.cursor_y -|= real_v;
				},
				else => unreachable,
			}
		},
		.CUP => {
			const seq = try char.parseCsi("?;?", scr.allocator, csi.str)
				orelse (try char.parseCsi("?", scr.allocator, csi.str)
					orelse return) ++ [1]char.CsiUnion{ .{ .@"?" = 1 } };
			if (seq[1].@"?" orelse 1 > scr.width) {
				scr.cursor_x = scr.width - 1;
			} else {
				scr.cursor_x = seq[1].@"?" orelse 1;
			}
			if (seq[0].@"?" orelse 1 > scr.view_height) {
				scr.cursor_y = scr.view_bottom + scr.view_height - 1;
			} else {
				scr.cursor_y = scr.view_bottom + (seq[0].@"?" orelse 1);
			}
		},
		.ED, .EL => {
			const v = (try char.parseCsi("?", scr.allocator, csi.str)
				orelse return)[0].@"?" orelse 0;
			const line_range, const scr_range = switch (v) {
				0 => .{
					.{ scr.cursor_x, scr.width },
					.{ @as(u16, 0), scr.cursor_y },
				},
				1 => .{
					.{ @as(u16, 0), scr.cursor_x + 1 },
					.{ scr.cursor_y + 1, scr.scrollback },
				},
				2 => .{
					.{ @as(u16, 0), scr.width },
					.{ @as(u16, 0), scr.scrollback },
				},
				else => return,
			};
			@memset(scr.lineAt(scr.cursor_y).c[line_range[0]..line_range[1]],
				char.null_char);
			scr.lineAt(scr.cursor_y).redraw = true;
			if (csi.final == .ED) for (scr_range[0]..scr_range[1]) |y| {
				@memset(scr.lineAt(@intCast(y)).c[0..scr.width],
					char.null_char);
				scr.lineAt(@intCast(y)).redraw = true;
			};
		},
		else => logger.debug("csi seq {any} unhandled", .{ csi.final }),
	}
}

/// put a token under the cursor; if free is true it also frees any strings
/// associated with the token using the screen's allocator
pub fn putToken(scr: *Screen, t: char.Token, free: bool) Error!void {
	scr.view_bottom = 0;
	switch (t) {
		.char => |c| try scr.putChar(c),
		.c1 => |c1| switch (c1) {
			else => logger.debug("c1 code {any} not handled", .{ c1 }),
		},
		.csi => |csi| {
			try scr.putCsi(t);
			if (free) scr.allocator.free(csi.str);
		},
	}
}

/// set every visible line to requiring a redraw (should use this if window
/// pixel data is lost)
pub fn prepareRedraw(scr: *Screen) void {
	for (scr.view_bottom..scr.view_bottom + scr.view_height)
		|y| scr.lineAt(@intCast(y)).redraw = true;
}

/// draws the characters to the display; takes in the implementation of display
pub fn draw(
	scr: *const Screen,
	display: type,
	win: *display.Window, df: *display.DisplayFont,
) display.Error!void {
	const top_line = @min(scr.view_bottom + scr.view_height, scr.scrollback);
	for (scr.view_bottom..top_line, 0..) |y, line_idx| {
		if (!scr.lineAt(@intCast(y)).redraw) continue;
		for (0..scr.width, scr.lineAt(@intCast(y)).c) |x, c|
			try win.renderChar(df, c, @intCast(x), @intCast(line_idx),
				config.background_color, config.foreground_color);
		scr.lineAt(@intCast(y)).redraw = false;
	}

	// render the cursor (this will double-render that char but that was better
	// than checking the value for every run of the loop)
	if (scr.cursor_y >= scr.view_bottom and scr.cursor_y < top_line)
		try win.renderChar(df, scr.lineAt(scr.cursor_y).c[scr.cursor_x],
			scr.cursor_x, scr.cursor_y - scr.view_bottom,
			config.cursor_background_color orelse config.background_color,
			config.cursor_foreground_color orelse config.foreground_color);
}
