const std = @import("std");
const char = @import("char.zig");

const ScreenError = error { OutOfMemory };

pub const Screen = struct {
	allocator: std.mem.Allocator,
	lines: [*][*]char.Char,
	w: u16, h: u16,
	cx: u16, cy: u16,

	pub fn init(
		allocator: std.mem.Allocator,
		w: u16, h: u16
	) ScreenError!Screen {
		const s = Screen{
			.allocator = allocator,
			.lines = (try allocator.alloc([*]char.Char, h)).ptr,
			.w = w, .h = h,
			.cx = 0, .cy = 0,
		};
		for (0..h) |i| {
			s.lines[i] = (try allocator.alloc(char.Char, w)).ptr;
			@memset(s.lines[i][0..w], char.null_char);
		}
		return s;
	}
	pub fn deinit(self: Screen) void {
		for (0..self.h, self.lines) |_, line|
			self.allocator.free(line[0..self.w]);
		self.allocator.free(self.lines[0..self.h]);
	}

	pub fn resize(self: *Screen, w: u16, h: u16) ScreenError!void {
		const allocator = self.allocator;
		if (h > self.h) {
			self.lines = (try allocator.realloc(self.lines[0..self.h], h)).ptr;
			for (self.h..h, self.lines) |i, line| {
				self.lines[i] = (try allocator.alloc(char.Char, w)).ptr;
				@memset(line[i][0..w], char.null_char);
			}
		} else if (h < self.h) {
			for (h..self.h, self.lines) |_, line|
				allocator.free(line[0..w]);
			self.lines = (try allocator.realloc(self.lines[0..self.h], h)).ptr;
		}
		self.h = h;

		if (w != self.w) for (0..h, self.lines) |i, line| {
			self.lines[i] = (try allocator.realloc(line[0..self.w], w)).ptr;
			if (w > self.w) @memset(line[self.w..w], char.null_char);
		};
		self.w = w;
	}

	/// put a char under the cursor (TODO: this should handle esc seqs as well)
	pub fn putChar(self: *Screen, c: char.Char) void {
		self.lines[self.cy][self.cx] = c;
		self.cx += 1;
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
		for (0..self.h, self.lines) |y, line| for (0..self.w, line) |x, ch| {
			const c = char.toCode(ch);
			if (c == 0) continue;
			try @call(.auto, drawFunc, drawArgs ++ .{
				c,
				@as(u16, @intCast(x)),
				@as(u16, @intCast(y)),
			});
		};
	}
};

