//! multiple representations of chars, keys, tokens, etc

/// little-endian, represents a code point
/// (use this instead of a u21 for memory saving, as a u21 needs 4 bytes)
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
pub fn charToUtf8(c: Char) []const u8 {
	const code = toCode(c);
	return switch (code) {
		0x000000...0x00007f => &.{
			@truncate(code),
		},
		0x000080...0x0007ff => &.{
			@as(u5, @truncate(code >> 6)),
			@as(u6, @truncate(code)),
		},
		0x000800...0x00ffff => &.{
			@as(u4, @truncate(code >> 12)),
			@as(u6, @truncate(code >> 6)),
			@as(u6, @truncate(code)),
		},
		else => &.{
			@as(u3, @truncate(code >> 18)),
			@as(u6, @truncate(code >> 12)),
			@as(u6, @truncate(code >> 6)),
			@as(u6, @truncate(code)),
		},
	};
}

const Utf8Parser = struct {
	codepoint: u21,
	expected_len: u8,
	fn reset(p: *Utf8Parser) void { p.codepoint = 0; p.expected_len = 0; }
	fn codepointLength(codepoint: u21) u8 { return switch (codepoint) {
		0x000000...0x00007f => 1,
		0x000080...0x0007ff => 2,
		0x000800...0x00ffff => 3,
		else => 4,
	}; }
	fn parse(
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
				if (codepointLength(p.codepoint) < p.expected_len) {
					p.codepoint <<= 6;
					p.codepoint += @as(u6, @truncate(b));
					return .{};
				}
				const o = fromCode(p.codepoint);
				p.reset();
				return .{ .c = o };
			},
			// utf8 unused
			0b11000000...0b11000001 => return .{ .bad = true },
			// start of a length 2
			0b11000010...0b11011111 => {
				p.codepoint = @as(u5, @truncate(b));
				if (p.expected_len > 0) {
					p.expected_len = 2;
					return .{ .bad = true };
				}
				p.expected_len = 2;
				return .{};
			},
			// start of a length 3
			0b11100000...0b11101111 => {
				p.codepoint = @as(u4, @truncate(b));
				if (p.expected_len > 0) {
					p.expected_len = 3;
					return .{ .bad = true };
				}
				p.expected_len = 3;
				return .{};
			},
			// start of a length 4
			0b11110000...0b11110111 => {
				p.codepoint = @as(u3, @truncate(b));
				if (p.expected_len > 0) {
					p.expected_len = 4;
					return .{ .bad = true };
				}
				p.expected_len = 4;
				return .{};
			},
			// utf8 unused
			0b11111000...0b11111111 => return .{ .bad = true },
		}
	}
};

pub const EscapeSequence = union(enum) {
};

/// a Char or an EscapeSequence
pub const Token = union(enum) {
	c: Char,
	e: EscapeSequence,
};

/// stores chars so data can be read one char at a time
pub const EscapeParser = struct {
	u: Utf8Parser,

	pub fn init() EscapeParser {
		return .{ .u = .{ .codepoint = 0, .expected_len = 0 } };
	}

	/// add one byte, returns a either the parsed token or null if the char was
	/// consumed
	pub fn parse(p: *EscapeParser, b: u8) ?Token {
		const m = p.u.parse(b);
		return if (m.c) |c| .{ .c = c } else null;
	}
};

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
pub const Mods = packed struct {
	shift: bool, caps: bool, ctrl: bool, alt: bool, super: bool,
};
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
			.char => |c| if (e.mods.ctrl
				and toCode(c) >= 0x40 and toCode(c) < 0x80)
				&.{ c[0] % 0x20 } else charToUtf8(c),
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
