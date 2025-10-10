//! utf-8 utilities

/// little-endian, represents a code point
/// (use this instead of a u21 for memory saving, as a u21 needs 4 bytes)
/// (actually not sure if this works because of alignment crap)
pub const Char = [3]u8;

pub const utf8_error: Char = .{ 0xfd, 0xff, 0x00 };

pub fn toCode(c: Char) u21 {
	return @as(u21, c[0]) + (@as(u21, c[1]) << 8) + (@as(u21, c[2]) << 16);
}
pub fn fromCode(c: u21) Char {
	return .{ @truncate(c), @truncate(c >> 8), @truncate(c >> 16) };
}

pub const null_char: Char = .{ 0, 0, 0 };

/// creates function for reading utf-8 given a type with member functions
/// .readByte() and .returnByte();
pub fn readUtf8(T: type) fn (*T) T.ReadError!Char {
	return struct { fn f(t: *T) T.ReadError!Char {
		const b = try t.readByte();
		var c: u21 = undefined;
		var cont: u2 = 0;
		switch (b) {
			0b00000000...0b01111111 => return .{ b, 0, 0 },
			0b10000000...0b10111111 => return utf8_error,
			0b11000000...0b11000001 => return utf8_error,
			0b11000010...0b11011111 => { cont = 1; c = b & 0b00011111; },
			0b11100000...0b11101111 => { cont = 2; c = b & 0b00001111; },
			0b11110000...0b11110111 => { cont = 3; c = b & 0b00000111; },
			0b11111000...0b11111111 => return utf8_error,
		}

		var i: u2 = 0;
		while (i < cont) : (i += 1) {
			const next = try t.readByte();
			if (next >> 6 != 0b10) { t.returnByte(next); return utf8_error; }
			c <<= 6;
			c += next & 0b00111111;
		}

		// avoid "overlong encodings" (error per wikipedia)
		if (c < @as(u21, switch (cont) {
			1 => 0x000080, 2 => 0x000800, 3 => 0x010000,
			else => unreachable,
			})) return utf8_error;
		// avoid surrogate pairs
		if (c > 0xD800 and c < 0xE000) return utf8_error;

		return fromCode(c);
	} }.f;
}

/// creeates function for writing utf-8 given a type with member function
/// .writeByte()
pub fn writeUtf8(T: type) fn (*T, Char) T.WriteError!void {
	return struct { fn f(t: *T, ch: Char) T.WriteError!void {
		const c = ch.toCode();
		switch (c) {
			0x000000...0x00007F => try t.writeByte(@truncate(c)),
			0x000080...0x0007FF => {
				try t.writeByte(0b11000000 + @as(u5, @truncate(c >> 6)));
				try t.writeByte(0b10000000 + @as(u6, @truncate(c)));
			},
			0x000800...0x00FFFF => {
				try t.writeByte(0b11100000 + @as(u4, @truncate(c >> 12)));
				try t.writeByte(0b10000000 + @as(u6, @truncate(c >> 6)));
				try t.writeByte(0b10000000 + @as(u6, @truncate(c)));
			},
			else => {
				try t.writeByte(0b11110000 + @as(u3, @truncate(c >> 18)));
				try t.writeByte(0b10000000 + @as(u6, @truncate(c >> 12)));
				try t.writeByte(0b10000000 + @as(u6, @truncate(c >> 6)));
				try t.writeByte(0b10000000 + @as(u6, @truncate(c)));
			}
		}
	} }.f;
}

pub const Key = union(enum) {
	pub const Control = enum {
		unknown,
		escape,
		enter, tab,
		backspace, delete,
		caps_lock,
		shift_l, shift_r,
		ctrl_l, ctrl_r,
		alt_l, alt_r,
		super_l, super_r,
		f_1, f_2, f_3, f_4, f_5, f_6, f_7, f_8, f_9, f_10, f_11, f_12,
		f_13, f_14, f_15, f_16, f_17, f_18, f_19, f_20, f_21, f_22, f_23, f_24,
		print_screen, scroll_lock, pause_break,
		insert,
		home, end,
		page_up, page_down,
		left, up, right, down,
	};

	char: Char, // 0x20 - 0x7e, 0x80 -
	control: Control,
};
pub const Mods = packed struct {
	shift: bool, caps: bool, ctrl: bool, alt: bool, super: bool,
};
pub const KeyInfo = struct {
	key: Key,
	mods: Mods,
};
