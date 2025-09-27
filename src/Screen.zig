//! represents a buffer of chars
const Screen = @This();

const std = @import("std");
const char = @import("char.zig");

const ScreenError = error { OutOfMemory, NoLines };

allocator: std.mem.Allocator,
lines: std.Deque(Line),
w: u16,
cursor_x: u16, cursor_y: u16,

/// Line does not include info about width since that is stored just once
/// in the parent Screen object, instead of with every Line
pub const Line = struct { c: [*]char.Char, redraw: bool };

fn dequePtr(T: type, deque: std.Deque(T), index: usize) *T {
	return &deque.buffer[buffer_index: {
		const head_len = deque.buffer.len - deque.head;
		if (index < head_len) break :buffer_index deque.head + index;
		break :buffer_index index - head_len;
	}];
}

pub fn init(
	allocator: std.mem.Allocator,
	w: u16, h: u16
) ScreenError!Screen {
	var s = Screen{
		.allocator = allocator,
		.lines = try .initCapacity(allocator, h),
		.w = w, .cursor_x = 0, .cursor_y = 0,
	};
	s.addLinesBack(h) catch unreachable;
	return s;
}

pub fn deinit(self: *Screen) void {
	self.removeLinesBack(@intCast(self.lines.len)) catch unreachable;
}

/// add n empty lines to the bottom of the screen
pub fn addLinesBack(self: *Screen, n: u16) ScreenError!void {
	for (0..n) |i| {
		try self.lines.pushBack(self.allocator, .{
			.c = (try self.allocator.alloc(char.Char, self.w)).ptr,
			.redraw = false,
		});
		@memset(self.lines.at(i).c[0..self.w], char.null_char);
	}
}

/// add n empty lines to the top of the screen
pub fn addLinesFront(self: *Screen, n: u16) ScreenError!void {
	for (0..n) |i| {
		try self.lines.pushBack(self.allocator, .{
			.c = (try self.allocator.alloc(char.Char, self.w)).ptr,
			.redraw = false,
		});
		@memset(self.lines.at(i).c[0..self.w], char.null_char);
	}
}

/// remove n lines from the bottom of the screen
pub fn removeLinesBack(self: *Screen, n: u16) ScreenError!void {
	for (0..n) |_| self.allocator.free((self.lines.popBack()
			orelse return error.NoLines).c[0..self.w]);
}

/// remove n lines from the top of the screen
pub fn removeLinesFront(self: *Screen, n: u16) ScreenError!void {
	for (0..n) |_| self.allocator.free((self.lines.popFront()
			orelse return error.NoLines).c[0..self.w]);
}

/// resize the screen to w by h chars
pub fn resize(self: *Screen, w: u16, h: u16) ScreenError!void {
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

/// put a char under the cursor (TODO: this should handle esc seqs as well)
pub fn putChar(self: *Screen, c: char.Char) void {
	self.lines.at(self.cursor_y).c[self.cursor_x] = c;
	dequePtr(Line, self.lines, self.cursor_y).redraw = true;
	self.cursor_x += 1;
	if (self.cursor_x > self.w) {
		self.cursor_x = 0;
		self.cursor_y += 1;
	}
}

/// types here are a bit clunky, basically drawArgs is a tuple of the args
/// for drawFunc, excluding the last 3, which are called in the function.
/// the return type is the same as that of drawFunc
pub fn draw(
	self: Screen,
	drawFunc: anytype,
	drawArgs: t: {
		var args = @typeInfo(std.meta.ArgsTuple(@TypeOf(drawFunc)))
			.@"struct";
		args.fields = args.fields[0 .. args.fields.len - 3];
		break :t @Type(.{ .@"struct" = args });
	},
	) (@typeInfo(@TypeOf(drawFunc)).@"fn".return_type orelse void) {
	for (0..self.lines.len) |y| {
		if (!self.lines.at(y).redraw) continue;
		for (0..self.w, self.lines.at(y).c) |x, ch| {
			const c = char.toCode(ch);
			if (c == 0) continue;
			try @call(.auto, drawFunc, drawArgs ++ .{
				c, @as(u16, @intCast(x)), @as(u16, @intCast(y)),
			});
		}
		dequePtr(Line, self.lines, y).redraw = false;
	}
}

/// set every line to requiring a redraw (should use this if window pixel
/// data is lost)
pub fn prepareRedraw(self: *Screen) void {
	for (0..self.lines.len) |y| dequePtr(Line, self.lines, y).redraw = true;
}
