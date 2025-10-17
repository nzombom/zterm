//! multiple representations of chars, keys, tokens, etc
const std = @import("std");

const logger = std.log.scoped(.char);

pub const Error = error { OutOfMemory };

/// little-endian, represents a code point. 8-bit aligned
pub const Char = [3]u8;
pub const null_char: Char = .{ 0, 0, 0 };
pub const utf8_error: Char = .{ 0xfd, 0xff, 0x00 };

pub fn toCode(c: Char) u21 {
	return @as(u21, c[0]) + (@as(u21, c[1]) << 8) + (@as(u21, c[2]) << 16);
}
pub fn fromCode(c: u21) Char {
	return .{ @truncate(c), @truncate(c >> 8), @truncate(c >> 16) };
}
/// converts a char to its utf8 representation
pub fn charToUtf8(c: Char) struct { len: u8, data: [4]u8 } {
	const code = toCode(c);
	return switch (code) {
		0x000000...0x00007f => .{ .len = 1, .data = .{
			@truncate(code),
			undefined, undefined, undefined,
		} },
		0x000080...0x0007ff => .{ .len = 2, .data = .{
			@as(u5, @truncate(code >> 6)),
			@as(u6, @truncate(code)),
			undefined, undefined,
		} },
		0x000800...0x00ffff => .{ .len = 3, .data = .{
			@as(u4, @truncate(code >> 12)),
			@as(u6, @truncate(code >> 6)),
			@as(u6, @truncate(code)),
			undefined,
		} },
		else => .{ .len = 4, .data = .{
			@as(u3, @truncate(code >> 18)),
			@as(u6, @truncate(code >> 12)),
			@as(u6, @truncate(code >> 6)),
			@as(u6, @truncate(code)),
		} },
	};
}

/// byte-by-byte iterator on utf8
pub const Utf8Parser = struct {
	codepoint: u21,
	current_len: u8,
	expected_len: u8,

	pub const init: Utf8Parser = .{
		.codepoint = 0,
		.current_len = 0,
		.expected_len = 0
	};

	pub fn reset(p: *Utf8Parser) void { p.* = init; }

	pub fn parse(
		p: *Utf8Parser, b: u8
	) struct { bad: bool = false, c: ?Char = null } {
		switch (b) {
			// ascii byte; fail if utf8 expected
			0b00000000...0b01111111 => {
				if (p.expected_len > 0) {
					p.reset();
					return .{ .bad = true, .c = fromCode(b) };
				}
				return .{ .c = fromCode(b) };
			},
			// utf8 continuation byte; fail if not currently in utf8
			0b10000000...0b10111111 => {
				if (p.expected_len == 0) return .{ .bad = true };
				if (p.current_len < p.expected_len) {
					p.codepoint <<= 6;
					p.codepoint += @as(u6, @truncate(b));
					p.current_len += 1;
				}
				if (p.current_len >= p.expected_len) {
					const o = fromCode(p.codepoint);
					p.reset();
					return .{ .c = o };
				}
			},
			// utf8 unused
			0b11000000...0b11000001 => return .{ .bad = true },
			// start of a length 2
			0b11000010...0b11011111 => {
				p.codepoint = @as(u5, @truncate(b));
				p.current_len = 1;
				if (p.expected_len > 0) {
					p.expected_len = 2;
					return .{ .bad = true };
				}
				p.expected_len = 2;
			},
			// start of a length 3
			0b11100000...0b11101111 => {
				p.codepoint = @as(u4, @truncate(b));
				p.current_len = 1;
				if (p.expected_len > 0) {
					p.expected_len = 3;
					return .{ .bad = true };
				}
				p.expected_len = 3;
			},
			// start of a length 4
			0b11110000...0b11110111 => {
				p.codepoint = @as(u3, @truncate(b));
				p.current_len = 1;
				if (p.expected_len > 0) {
					p.expected_len = 4;
					return .{ .bad = true };
				}
				p.expected_len = 4;
			},
			// utf8 unused
			0b11111000...0b11111111 => return .{ .bad = true },
		}
		return .{};
	}
};

/// a keysym
pub const Key = union(enum) {
	pub const Control = enum {
		unknown,
		caps_lock,
		shift_l, shift_r,
		ctrl_l, ctrl_r,
		alt_l, alt_r,
		super_l, super_r,
		f_1, f_2, f_3, f_4, f_5, f_6, f_7, f_8, f_9, f_10, f_11, f_12,
		print_screen, scroll_lock, pause_break,
		insert,
		home, end,
		page_up, page_down,
		left, up, right, down,
	};

	/// char can also be an ASCII C0 control code (e.g. backspace)
	char: Char,
	control: Control,

};
/// the mods pressed with a key
pub const Mods = packed struct {
	shift: bool, caps: bool, ctrl: bool, alt: bool, super: bool,
};
/// the platform-independent part of a key event
pub const KeyEvent = struct {
	down: bool,
	key: Key,
	mods: Mods,

	pub fn toString(e: KeyEvent) struct { len: u8, data: [8]u8 } {
		var bytes: [8]u8 = undefined;
		var bytes_idx: u8 = 0;
		if (e.mods.alt) {
			bytes[bytes_idx] = '\x1b';
			bytes_idx += 1;
		}
		const key_seq = switch (e.key) {
			.char => |c| v: {
				if (e.mods.ctrl and toCode(c) >= 0x40 and toCode(c) < 0x80) {
					break :v &.{ c[0] % 0x20 };
				} else {
					const c8 = charToUtf8(c);
					break :v c8.data[0..c8.len];
				}
			},
			.control => |control| switch (control) {
				.f_1 => "\x1b[11~", .f_2 => "\x1b[12~",
				.f_3 => "\x1b[13~", .f_4 => "\x1b[14~",
				.f_5 => "\x1b[15~", .f_6 => "\x1b[17~",
				.f_7 => "\x1b[18~", .f_8 => "\x1b[19~",
				.f_9 => "\x1b[20~", .f_10 => "\x1b[21~",
				.f_11 => "\x1b[23~", .f_12 => "\x1b[24~",
				.insert => "\x1b[2~",
				.home => "\x1b[H", .end => "\x1b[F",
				.page_up => "\x1b[5~", .page_down => "\x1b[6~",
				.left => "\x1b[D", .up => "\x1b[A",
				.right => "\x1b[C", .down => "\x1b[B",
				else => "",
			},
		};
		@memcpy(bytes[bytes_idx..bytes_idx + key_seq.len], key_seq);
		bytes_idx += @intCast(key_seq.len);
		return .{ .len = bytes_idx, .data = bytes };
	}
};
