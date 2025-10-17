//! run a pseudoterm and provide basic i/o
const Pty = @This();

const std = @import("std");
const char = @import("char.zig");
const pty_h = @cImport(@cInclude("pty.h"));

pub const Error = error { OutOfMemory, InitFailed, IOFailed, EndOfStream };

/// handle to the pty
m: std.fs.File,

pub fn init(
	allocator: std.mem.Allocator,
	command: [*:0]const u8,
	argv: [*:null]const ?[*:0]const u8,
	terminfo_name: []const u8,
) Error!Pty {
	var fd: i32 = 0;
	const pid = pty_h.forkpty(&fd, null, null, null);
	switch (pid) {
		-1 => return error.InitFailed,
		0 => {
			var env_map = std.process.getEnvMap(allocator)
				catch return error.OutOfMemory;
			try env_map.put("TERM", terminfo_name);
			std.posix.execvpeZ(command, argv,
				try std.process.createEnvironFromMap(allocator, &env_map, .{}))
				catch return error.InitFailed;
		},
		else => {
			_ = std.posix.fcntl(fd, std.posix.F.SETFL,
				@intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true, }))))
				catch return error.InitFailed;
			return .{ .m = .{ .handle = fd } };
		},
	}
}
pub fn deinit(pty: *const Pty) void { pty.m.close(); }

pub fn getTermios(pty: *const Pty) std.posix.termios {
	return std.posix.tcgetattr(pty.m.handle) catch unreachable;
}
pub fn putTermios(pty: *const Pty, termios: std.posix.termios) void {
	std.posix.tcsetattr(pty.m.handle, ._, termios);
}

pub fn setScreenSize(pty: *const Pty, w: u16, h: u16) void {
	_ = std.os.linux.ioctl(pty.m.handle, std.os.linux.T.IOCSWINSZ,
		@intFromPtr(&std.posix.winsize{
			.row = h, .col = w,
			.xpixel = 0, .ypixel = 0
		}));
}

pub fn readByte(pty: *const Pty) Error!?u8 {
	var c: u8 = undefined;
	if (pty.m.read((&c)[0..1]) catch |err| switch (err) {
		error.InputOutput => return error.EndOfStream,
		error.WouldBlock => return null,
		else => return error.IOFailed,
	} != 1) return error.EndOfStream;
	return c;
}

pub fn writeByte(pty: *const Pty, c: u8) Error!void {
	if (pty.m.write((&c)[0..1]) catch |err| switch (err) {
		error.InputOutput => return error.EndOfStream,
		else => return error.IOFailed,
	} != 1) return error.EndOfStream;
}

pub fn writeString(pty: *const Pty, str: []const u8) Error!void {
	for (str) |b| try pty.writeByte(b);
}
