//! utf-8 utilities

pub const ReadError = error { EndOfStream, ReadFailed };

const Char = [3]u8;

/// little-endian
pub const utf8_error: Char = .{ 0xfd, 0xff, 0x00 };

pub fn charCode(c: Char) u32 {
	return c[0] + (c[1] << 8) + (c[2] << 16);
}
pub fn charFromCode(c: u32) Char {
	return .{ @truncate(c), @truncate(c >> 8), @truncate(c >> 16) };
}

/// creates function for reading utf-8 given a type with member funcs
/// .readByte() and .returnByte();
pub fn readUtf8(T: type) fn (T) ReadError!Char {
	return struct { fn f(t: T) ReadError!Char {
		const b = try t.readByte();
		if (b < 0b10000000) return .{ b, 0, 0 };
		if (b < 0b11000000) return utf8_error;
		if (b == 0b11000000 or b == 0b11000001) return utf8_error;
		var c: u24 = 0;
		var cont: u8 = 0;
		if (b < 0b11100000) {
			cont = 1;
			c = b & 0b00011111;
		} else if (b < 0b11110000) {
			cont = 2;
			c = b & 0b00001111;
		} else if (b < 0b11111000) {
			cont = 3;
			c = b & 0b00000111;
		} else return utf8_error;
		while (cont > 0) : (cont -= 1) {
			const next = try t.readByte();
			if (next >> 6 != 0b10) {
				t.returnByte(next);
				return utf8_error;
			}
			c <<= 6;
			c += next & 0b00111111;
		}
		return charFromCode(c);
	} }.f;
}
