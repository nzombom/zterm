//! run a pseudoterm and provide basic i/o
const Pty = @This();

const std = @import("std");
const pty_h = @cImport(@cInclude("pty.h"));

pub const InitError = error { OpenFailed, ForkFailed };
pub const ReadError = error { EndOfStream, ReadFailed };
pub const WriteError = error { EndOfStream, WriteFailed };

m: std.fs.File,

pub fn open(command: [*:0]const u8,
	argv: [*:null]const ?[*:0]const u8) InitError!Pty {
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
	const m = std.fs.File{ .handle = fd };
	return Pty{ .m = m };
}
pub fn close(self: *Pty) void {
	self.m.close();
}

pub fn read(self: *Pty) ReadError!u8 {
	var c: u8 = undefined;
	if (self.m.read((&c)[0..1]) catch |err| {
		if (err == std.posix.ReadError.InputOutput)
			return ReadError.EndOfStream
		else return ReadError.ReadFailed;
	} != 1) return ReadError.EndOfStream;
	return c;
}
pub fn readStr(self: *Pty, n: u8) ReadError![]u8 {
	var c: [256]u8 = undefined;
	if (self.m.read(c[0..n]) catch |err| {
		if (err == std.posix.ReadError.InputOutput)
			return ReadError.EndOfStream
		else return ReadError.ReadFailed;
	} != n) return ReadError.EndOfStream;
	return c;
}

pub fn write(self: *Pty, c: u8) WriteError!void {
	if (self.m.write((&c)[0..1]) catch |err| {
		if (err == std.posix.WriteError.InputOutput)
			return WriteError.EndOfStream
		else return WriteError.WriteFailed;
	} != 1) return WriteError.EndOfStream;
}
pub fn writeStr(self: *Pty, c: []u8) WriteError!void {
	if (self.m.write(c) catch |err| {
		if (err == std.posix.WriteError.InputOutput)
			return WriteError.EndOfStream
		else return WriteError.WriteFailed;
	} != c.len) return WriteError.EndOfStream;
}
