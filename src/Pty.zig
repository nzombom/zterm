//! run a pseudoterm and provide basic i/o
const Pty = @This();

const std = @import("std");
const char = @import("char.zig");
const pty_h = @cImport(@cInclude("pty.h"));

pub const InitError = error { OutOfMemory, OpenFailed, ForkFailed };
pub const ReadError = error { EndOfStream, ReadFailed };
pub const WriteError = error { EndOfStream, WriteFailed };

m: std.fs.File,
/// object remembers one byte for utf-8 error handling. when a byte is supposed
/// to be a continuation but is not, the extra byte is stored here with
/// .returnByte()
byte: ?u8,

pub fn init(
	command: [*:0]const u8,
	argv: [*:null]const ?[*:0]const u8
) InitError!Pty {
	var fd: i32 = 0;
	const pid = pty_h.forkpty(&fd, null, null, null);
	switch (pid) {
		-1 => return InitError.OpenFailed,
		0 => {
			std.posix.execvpeZ(command, argv, std.c.environ)
				catch return InitError.ForkFailed;
			},
			else => {},
	}
	return .{ .m = .{ .handle = fd }, .byte = null };
}

pub fn deinit(pty: *const Pty) void {
	pty.m.close();
}

pub fn returnByte(pty: *Pty, b: u8) void { pty.byte = b; }

pub fn readable(pty: *const Pty) ReadError!bool {
	var c: i32 = undefined;
	if (std.c.ioctl(pty.m.handle, std.c.T.FIONREAD, &c) < 0)
		return error.ReadFailed;
	return c > 0;
}

pub fn readByte(pty: *Pty) ReadError!u8 {
	if (pty.byte != null) {
		const b = pty.byte;
		pty.byte = null;
		return b.?;
	}
	var c: u8 = undefined;
	if (pty.m.read((&c)[0..1]) catch |err| {
		if (err == std.posix.ReadError.InputOutput)
			return ReadError.EndOfStream
		else return ReadError.ReadFailed;
	} != 1) return ReadError.EndOfStream;
	return c;
}

pub const readChar = char.readUtf8(Pty);

pub fn writeByte(pty: *const Pty, c: u8) WriteError!void {
	if (pty.m.write((&c)[0..1]) catch |err| {
		if (err == std.posix.WriteError.InputOutput)
			return WriteError.EndOfStream
		else return WriteError.WriteFailed;
	} != 1) return WriteError.EndOfStream;
}

pub const writeChar = char.writeUtf8(Pty);
