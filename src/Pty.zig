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
byte: *?u8,

pub fn init(
	allocator: std.mem.Allocator,
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
	const m: std.fs.File = .{ .handle = fd };
	const b = try allocator.create(?u8);
	b.* = null;
	return .{ .m = m, .byte = b };
}

pub fn deinit(self: Pty, allocator: std.mem.Allocator) void {
	allocator.destroy(self.byte);
	self.m.close();
}

pub fn returnByte(self: Pty, b: u8) void { self.byte.* = b; }

pub fn readable(self: Pty) ReadError!bool {
	var c: i32 = undefined;
	if (std.c.ioctl(self.m.handle, std.c.T.FIONREAD, &c) < 0)
		return error.ReadFailed;
	return c > 0;
}

pub fn readByte(self: Pty) ReadError!u8 {
	if (self.byte.* != null) {
		const b = self.byte.*;
		self.byte.* = null;
		return b.?;
	}
	var c: u8 = undefined;
	if (self.m.read((&c)[0..1]) catch |err| {
		if (err == std.posix.ReadError.InputOutput)
			return ReadError.EndOfStream
		else return ReadError.ReadFailed;
	} != 1) return ReadError.EndOfStream;
	return c;
}

pub const readChar = char.readUtf8(Pty);

pub fn writeByte(self: Pty, c: u8) WriteError!void {
	if (self.m.write((&c)[0..1]) catch |err| {
		if (err == std.posix.WriteError.InputOutput)
			return WriteError.EndOfStream
		else return WriteError.WriteFailed;
	} != 1) return WriteError.EndOfStream;
}

pub const writeChar = char.writeUtf8(Pty);
