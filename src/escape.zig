//! parse & handle control sequences
const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");
const Pty = @import("Pty.zig");
const Screen = @import("Screen.zig");

const logger = std.log.scoped(.escape);

pub const Error = Screen.Error;

/// a char or an escape sequence
pub const Token = union(enum) {
	char: char.Char,
	c1: enum(u8) {
		IND = 'D', NEL = 'E', RI = 'M',
		DCS = 'P', SOS = 'X',
		CSI = '[',
		ST = '\\',
		OSC = ']',
		DECSC = '7',
		DECRC = '8',
		_,
	},
	csi: struct {
		str: []u8,
		final: enum(u8) {
			ICH = '@',
			CUU = 'A', CUD = 'B', CUF = 'C', CUB = 'D',
			CNL = 'E', CPL = 'F',
			CHA = 'G', CUP = 'H', CHT = 'I',
			ED = 'J', EL = 'K',
			IL = 'L', DL = 'M',
			DCH = 'P',
			SU = 'S', SD = 'T',
			ECH = 'X',
			CBT = 'Z',
			DECSET = 'h', DECRST = 'l',
			SGR = 'm',
			DECSCUSR = 'q',
			SCOSC = 's', SCORC = 'u',
			_,
		},
	},
};

/// stores chars so data can be read one char at a time
pub const Parser = struct {
	allocator: std.mem.Allocator,
	u: char.Utf8Parser,
	/// what mode it's parsing in, as well as any associated data
	mode: union(enum) {
		char, c1,
		csi: std.ArrayList(u8),
	},

	pub fn init(allocator: std.mem.Allocator) Parser {
		return .{
			.allocator = allocator,
			.u = .init,
			.mode = .char,
		};
	}

	/// add one byte, returns a either the parsed token or null if the char was
	/// consumed. if token returned has a string the slice must be freed
	pub fn parse(p: *Parser, b: u8) Error!?Token {
		try switch (p.mode) {
			.char => {
				if (b == 0x1b) { p.mode = .c1; return null; }
				const m = p.u.parse(b);
				return if (m.c) |c| .{ .char = c } else null;
			},
			.c1 => {
				p.mode = .char;
				const seq: Token = .{ .c1 = @enumFromInt(b) };
				if (seq.c1 != .CSI) return seq;
				p.mode = .{ .csi = .empty };
				return null;
			},
			.csi => switch (b) {
				0x20...0x3f => {
					try p.mode.csi.append(p.allocator, b);
					return null;
				},
				0x40...0x7e => {
					const seq: Token = .{ .csi = .{
						.final = @enumFromInt(b),
						.str = try p.mode.csi.toOwnedSlice(p.allocator),
					} };
					p.mode = .char;
					return seq;
				},
				else => { p.mode = .char; return null; },
			},
		};
	}
};

/// one part of a csi format; char is some char that must be present, values is
/// a number of optional values or 0 for any number
const CsiStrPart = union(enum) { char: u8, values: u8 };
/// parse a csi string according to a format, return an array of CsiValue if
/// it matches or else null
fn parseCsi(
	comptime format: []const CsiStrPart,
	allocator: std.mem.Allocator,
	str: []const u8,
) Error!?[]?u16 {
	var ret: std.ArrayList(?u16) = .empty;
	var i: usize = 0;
	for (format) |f| switch (f) {
		.char => { if (str[i] != f.char) return null else i += 1; },
		.values => {
			var read: usize = 0;
			var value: ?u16 = null;
			loop: while (i < str.len and (f.values == 0 or read < f.values)) {
				switch (str[i]) {
					'0'...'9' => {
						if (value == null) value = 0;
						value.? *|= 10;
						value.? +|= str[i] - '0';
					},
					';', ':' => {
						try ret.append(allocator, value);
						read += 1;
						value = null;
					},
					else => { try ret.append(allocator, value); break :loop; },
				}
				i += 1;
			}
			if (f.values == 0) {
				if (value != null) try ret.append(allocator, value);
			}
			if (f.values > 0 and read < f.values) {
				try ret.append(allocator, value);
				try ret.appendNTimes(allocator, null, f.values - read - 1);
			}
		},
	};
	if (i < str.len) return null else return try ret.toOwnedSlice(allocator);
}

fn handleC1(scr: *Screen, t: Token) Error!void {
	switch (t.c1) {
		.IND => try scr.cursorDown(1, true),
		.NEL => {
			scr.cursor.x = 0;
			try scr.cursorDown(1, true);
		},
		.RI => try scr.cursorUp(1),
		.DCS => {},
		.SOS => {},
		.CSI => {},
		.ST => {},
		.OSC => {},
		.DECSC => scr.saved_cursor = scr.cursor,
		.DECRC => scr.cursor = scr.saved_cursor,
		_ => logger.debug("c1 code {any} not handled", .{ t.c1 }),
	}
}

fn handleCsi(scr: *Screen, pty: *const Pty, t: Token) Error!void {
	_ = pty;
	const csi = t.csi;
	switch (csi.final) {
		// these seqs are all single-arg so we lump them together
		.ICH, .CUU, .CUD, .CUF, .CUB,
		.CNL, .CPL, .CHA, .CHT,
		.IL, .DL, .DCH, .ED, .EL,
		.SU, .SD, .ECH, .CBT => |k| {
			const v_op = (try parseCsi(&.{ .{ .values = 1 } },
					scr.allocator, csi.str) orelse return)[0];
			switch (k) {
				.ICH => {
					const v = v_op orelse 1;
					const chars_moved = scr.width - scr.cursor.x -| v;
					const l = scr.lineAt(scr.cursor.y);
					const cx = scr.cursor.x;
					@memmove(l.c[cx..cx + chars_moved],
						l.c[scr.width - chars_moved..scr.width]);
					@memset(l.c[cx..cx + v], scr.empty_cell());
				},
				.CUU => try scr.cursorUp(v_op orelse 1),
				.CUD => try scr.cursorDown(v_op orelse 1, false),
				.CUF => try scr.cursorRight(v_op orelse 1, false),
				.CUB => try scr.cursorLeft(v_op orelse 1),
				.CNL => {
					try scr.cursorDown(v_op orelse 1, false);
					scr.cursor.x = 0;
				},
				.CPL => {
					try scr.cursorUp(v_op orelse 1);
					scr.cursor.x = 0;
				},
				.CHA => scr.cursor.x
					= @max((v_op orelse 1) - 1, scr.width - 1),
				.CHT => scr.cursor.x
					= @min((scr.cursor.x / 8 + (v_op orelse 1)) * 8,
						scr.width - 1),
				.IL => {
					logger.warn("used insert lines; maybe bug", .{});
					if (v_op == 0) return;
					const v = v_op orelse 1;
					for (0..scr.cursor.y - v) |i|
						@memcpy(scr.lineAt(i).c[0..scr.width],
							scr.lineAt(i + v).c[0..scr.width]);
					for (scr.cursor.y - v..scr.cursor.y) |i|
						@memset(scr.lineAt(i).c[0..scr.width],
							scr.empty_cell());
					scr.prepareRedraw();
				},
				.DL => {
					if (v_op == 0) return;
					const v = if (scr.cursor.y < v_op orelse 1)
						scr.cursor.y + 1 else v_op orelse 1;
					for (0..scr.cursor.y - v) |i| {
						const y = scr.cursor.y - v - 1 - i;
						@memcpy(scr.lineAt(y + v).c[0..scr.width],
							scr.lineAt(y).c[0..scr.width]);
					}
					for (0..v) |i| @memset(scr.lineAt(i).c[0..scr.width],
						scr.empty_cell());
					scr.prepareRedraw();
				},
				.ED, .EL => {
					const v = v_op orelse 0;
					const line_range, const scr_range = switch (v) {
						0 => .{
							.{ scr.cursor.x, scr.width },
							.{ @as(u16, 0), scr.cursor.y },
						},
						1 => .{
							.{ @as(u16, 0), scr.cursor.x + 1 },
							.{ scr.cursor.y + 1, scr.nLines() },
						},
						2 => .{
							.{ @as(u16, 0), scr.width },
							.{ @as(u16, 0), scr.nLines() },
						},
						else => return,
					};
					@memset(scr.lineAt(scr.cursor.y)
						.c[line_range[0]..line_range[1]], scr.empty_cell());
					scr.lineAt(scr.cursor.y).redraw = true;
					if (csi.final == .ED) for (scr_range[0]..scr_range[1]) |y| {
						@memset(scr.lineAt(y).c[0..scr.width],
							scr.empty_cell());
						scr.lineAt(y).redraw = true;
					};
				},
				.SU => scr.scroll(v_op orelse 1),
				.SD => scr.scroll(-@as(i17, v_op orelse 1)),
				.ECH => @memset(scr.lineAt(scr.cursor.y)
					.c[scr.cursor.x..@min(scr.width,
						scr.cursor.x + (v_op orelse 1))], scr.empty_cell()),
				.CBT => scr.cursor.x = @max((scr.cursor.x / 8
						- @as(i17, (v_op orelse 1))) * 8, 0),
				else => unreachable,
			}
		},
		.CUP => {
			const seq = try parseCsi(&.{ .{ .values = 2 } },
				scr.allocator, csi.str) orelse return;
			if (seq[1] orelse 1 > scr.width) {
				scr.cursor.x = scr.width - 1;
			} else {
				scr.cursor.x = (seq[1] orelse 1) - 1;
			}
			scr.lineAt(scr.cursor.y).redraw = true;
			if (seq[0] orelse 1 > scr.view_height) {
				scr.cursor.y = scr.view_bottom + scr.view_height - 1;
			} else {
				scr.cursor.y = scr.view_bottom + scr.view_height
					- (seq[0] orelse 1);
			}
			scr.lineAt(scr.cursor.y).redraw = true;
		},
		.DECSET, .DECRST => {},
		.SGR => {
			const seq = try parseCsi(&.{ .{ .values = 0 } },
				scr.allocator, csi.str) orelse return;
			for (seq) |part| switch (part orelse continue) {
				0 => scr.graphic = .{},
				1 => scr.graphic.attrs.intensity = .bold,
				2 => scr.graphic.attrs.intensity = .faint,
				3 => scr.graphic.attrs.italic = true,
				4 => scr.graphic.attrs.underline = true,
				5, 6 => scr.graphic.attrs.blink = true,
				7 => scr.graphic.attrs.reverse = true,
				9 => scr.graphic.attrs.strike = true,
				21, 22 => scr.graphic.attrs.intensity = .normal,
				23 => scr.graphic.attrs.italic = false,
				24 => scr.graphic.attrs.underline = false,
				25 => scr.graphic.attrs.blink = false,
				27 => scr.graphic.attrs.reverse = false,
				29 => scr.graphic.attrs.strike = false,
				30...37 => |sgr| {
					scr.graphic.color_types.fg = .four_bit;
					scr.graphic.colors.fg = @intCast(sgr - 30);
				},
				39 => scr.graphic.color_types.fg = .default,
				40...47 => |sgr| {
					scr.graphic.color_types.bg = .four_bit;
					scr.graphic.colors.bg = @intCast(sgr - 40);
				},
				49 => scr.graphic.color_types.bg = .default,
				90...97 => |sgr| {
					scr.graphic.color_types.fg = .four_bit;
					scr.graphic.colors.fg = @intCast(sgr - 90 + 8);
				},
				100...107 => |sgr| {
					scr.graphic.color_types.bg = .four_bit;
					scr.graphic.colors.bg = @intCast(sgr - 100 + 8);
				},
				else => {},
			};
		},
		.DECSCUSR => {},
		.SCOSC => scr.saved_cursor = scr.cursor,
		.SCORC => scr.cursor = scr.saved_cursor,
		_ => logger.debug("csi seq {any} unhandled", .{ csi.final }),
	}
}

/// handle an escape sequence, freeing all data if indicated
pub fn handleToken(scr: *Screen, pty: *const Pty, t: Token, free: bool) Error!void {
	scr.view_bottom = 0;
	switch (t) {
		.char => |c| try scr.putChar(c),
		.c1 => try handleC1(scr, t),
		.csi => |csi| {
			try handleCsi(scr, pty, t);
			if (free) scr.allocator.free(csi.str);
		},
	}
}
