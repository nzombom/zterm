//! provides display functions using x11

const std = @import("std");
const config = @import("config.zig");
const font = @import("font.zig");
const xcb = @cImport({
	@cInclude("xcb/xcb.h");
	@cInclude("xcb/render.h");
	@cInclude("xcb/xcb_renderutil.h");
});

const logger = std.log.scoped(.display);

var connection: *xcb.xcb_connection_t = undefined;
var screen: *xcb.xcb_screen_t = undefined;
var render_formats: [3]*xcb.xcb_render_pictforminfo_t = undefined;

pub const DisplayError = error { InitFailed, DoesNotExist };
pub const WindowError = error { OpenFailed };
pub const FontError = error { OutOfMemory, OpenFailed, RenderFailed };

fn checkXcb(req: xcb.xcb_void_cookie_t, err: anytype) @TypeOf(err)!void {
	const e = xcb.xcb_request_check(connection, req);
	if (e != null) {
		logger.err("xcb error {} {}:{}", .{
			e.*.error_code, e.*.major_code, e.*.minor_code,
		});
		std.c.free(e);
		return err;
	}
}

pub fn init() DisplayError!void {
	var screen_n: i32 = undefined;
	connection = xcb.xcb_connect(null, &screen_n)
		orelse return DisplayError.InitFailed;
	const setup = xcb.xcb_get_setup(connection);
	var screen_iter = xcb.xcb_setup_roots_iterator(setup);
	var i: u32 = 0;
	while (i < screen_n) : (i += 1) {
		xcb.xcb_screen_next(&screen_iter);
	}
	screen = screen_iter.data;

	const formats_query = xcb.xcb_render_util_query_formats(connection);
	render_formats = .{
		xcb.xcb_render_util_find_standard_format(
			formats_query, xcb.XCB_PICT_STANDARD_A_1),
		xcb.xcb_render_util_find_standard_format(
			formats_query, xcb.XCB_PICT_STANDARD_A_8),
		xcb.xcb_render_util_find_standard_format(
			formats_query, xcb.XCB_PICT_STANDARD_RGB_24),
	};
}
pub fn deinit() void { xcb.xcb_disconnect(connection); }
pub fn flush() void { _ = xcb.xcb_flush(connection); }

const PreparedBitmap = struct {
	// if bitmap is zero-size
	// then pixmap and picture are not guaranteed to exist
	pixmap: xcb.xcb_pixmap_t,
	picture: xcb.xcb_render_picture_t,
	bitmap: font.Bitmap,

	pub fn init(
		allocator: std.mem.Allocator, bitmap: font.Bitmap,
	) PreparedBitmap {
		if (bitmap.w == 0 or bitmap.h == 0) return .{
			.pixmap = 0, .picture = 0, .bitmap = bitmap,
		};

		const prepared = PreparedBitmap{
			.pixmap = xcb.xcb_generate_id(connection),
			.picture = xcb.xcb_generate_id(connection),
			.bitmap = bitmap,
		};

		_ = xcb.xcb_create_pixmap(connection, bitmap.mode.bitSize(),
			prepared.pixmap, screen.root, bitmap.w, bitmap.h);
		const gc = xcb.xcb_generate_id(connection);
		_ = xcb.xcb_create_gc(connection, gc, prepared.pixmap, 0, null);
		_ = xcb.xcb_put_image(connection, xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
			prepared.pixmap, gc, bitmap.w, bitmap.h, 0, 0,
			0, bitmap.mode.bitSize(), bitmap.pitch * bitmap.h,
			bitmap.data.ptr);
		_ = xcb.xcb_render_create_picture(connection, prepared.picture,
			prepared.pixmap, render_formats[@intFromEnum(bitmap.mode)].id,
			0, null);
		flush();
		bitmap.deinit(allocator);

		return prepared;
	}

	pub fn deinit(self: PreparedBitmap) void {
		_ = xcb.xcb_render_free_picture(connection, self.picture);
		_ = xcb.xcb_free_pixmap(connection, self.pixmap);
	}
};
const GlyphSet = std.AutoArrayHashMap(u32, PreparedBitmap);

pub const DisplayFont = struct {
	allocator: std.mem.Allocator,
	gs: *GlyphSet,
	face: font.Face,
	mode: font.PixelMode,

	pub fn init(
		allocator: std.mem.Allocator,
		name: [:0]const u8, mode: font.PixelMode,
	) FontError!DisplayFont {
		const dpi_x = @as(f32, @floatFromInt(screen.width_in_pixels)) /
			(@as(f32, @floatFromInt(screen.width_in_millimeters)) / 25.4);

		const gs = try allocator.create(GlyphSet);
		gs.* = GlyphSet.init(allocator);
		return .{
			.allocator = allocator,
			.gs = gs,
			.face = font.Face.init(name, @intFromFloat(dpi_x))
				catch return error.OpenFailed,
			.mode = mode,
		};
	}
	pub fn deinit(self: DisplayFont) void {
		var it = self.gs.iterator();
		while (it.next()) |g| g.value_ptr.deinit();
		self.gs.deinit();
		self.allocator.destroy(self.gs);
		self.face.deinit();
	}

	pub fn getGlyphFromChar(
		self: DisplayFont, c: u32
	) FontError!PreparedBitmap {
		return self.gs.get(c) orelse {
			const g = PreparedBitmap.init(self.allocator,
				self.face.renderGlyph(self.allocator,
					self.face.getCharGlyphIndex(c), self.mode)
				catch return error.RenderFailed);
			try self.gs.put(c, g);
			return g;
		};
	}
};

fn xcbrColorFromHex(c: u32) xcb.xcb_render_color_t { return .{
	.alpha = @as(u16, @intCast(c >> 24)) * 256,
	.red = @as(u16, @intCast((c >> 16) % 256)) * 256,
	.green = @as(u16, @intCast((c >> 8) % 256)) * 256,
	.blue = @as(u16, @intCast(c % 256)) * 256,
}; }

pub const WindowID = xcb.xcb_window_t;
pub const Window = struct {
	id: WindowID,
	picture: xcb.xcb_render_picture_t,
	pen_pixmap: xcb.xcb_pixmap_t,
	pen: xcb.xcb_render_picture_t,

	pub fn open(width: u16, height: u16) WindowError!Window {
		const w = Window{
			.id = xcb.xcb_generate_id(connection),
			.picture = xcb.xcb_generate_id(connection),
			.pen = xcb.xcb_generate_id(connection),
			.pen_pixmap = xcb.xcb_generate_id(connection),
		};

		// create the window
		var value_buffer: [8]u8 = undefined;
		var values: ?*[8]u8 = &value_buffer;
		const value_mask = xcb.XCB_CW_BACK_PIXEL
			| xcb.XCB_CW_EVENT_MASK;
		_ = xcb.xcb_create_window_value_list_serialize(&values, value_mask, &.{
			.background_pixel = config.background_color,
			.event_mask = xcb.XCB_EVENT_MASK_EXPOSURE
				| xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY
				| xcb.XCB_EVENT_MASK_KEY_PRESS
				| xcb.XCB_EVENT_MASK_KEY_RELEASE,
		});
		try checkXcb(xcb.xcb_create_window_checked(connection, 24,
			w.id, screen.*.root, 0, 0, width, height,
			0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.*.root_visual,
			value_mask, values), error.OpenFailed);

		// create the xrender picture
		try checkXcb(xcb.xcb_render_create_picture(connection,
			w.picture, w.id, render_formats[2].id, 0, null), error.OpenFailed);

		// create the pen & set the color
		_ = xcb.xcb_create_pixmap(connection, 24, w.pen_pixmap, w.id, 1, 1);
		_ = xcb.xcb_render_create_picture(connection,
			w.pen, w.pen_pixmap, render_formats[2].id,
			xcb.XCB_RENDER_CP_REPEAT, &xcb.XCB_RENDER_REPEAT_NORMAL);
		_ = xcb.xcb_render_fill_rectangles(connection,
			xcb.XCB_RENDER_PICT_OP_SRC, w.pen,
			xcbrColorFromHex(config.foreground_color),
			1, &.{ .x = 0, .y = 0, .width = 1, .height = 1 });

		return w;
	}
	pub fn close(self: Window) void {
		_ = xcb.xcb_render_free_picture(connection, self.pen);
		_ = xcb.xcb_free_pixmap(connection, self.pen_pixmap);
		_ = xcb.xcb_destroy_window(connection, self.id);
	}

	pub fn map(self: Window) void {
		_ = xcb.xcb_map_window(connection, self.id);
	}

	fn renderBitmap(
		self: Window, bitmap: PreparedBitmap, x: i16, y: i16,
	) void {
		if (bitmap.bitmap.w == 0 or bitmap.bitmap.h == 0) return;
		_ = xcb.xcb_render_composite(connection, xcb.XCB_RENDER_PICT_OP_OVER,
			self.pen, bitmap.picture, self.picture,
			0, 0, 0, 0, x + bitmap.bitmap.x, y + bitmap.bitmap.y,
			bitmap.bitmap.w, bitmap.bitmap.h);
	}

	pub fn renderChar(
		self: Window, df: DisplayFont, c: u32, cx: u16, cy: u16,
	) FontError!void {
		_ = xcb.xcb_render_fill_rectangles(connection,
			xcb.XCB_RENDER_PICT_OP_SRC, self.picture,
			xcbrColorFromHex(config.background_color), 1, &.{
				.x = @intCast(cx * df.face.width),
				.y = @intCast(cy * df.face.height),
				.width = @intCast(df.face.width),
				.height = @intCast(df.face.height),
			});
		self.renderBitmap(try df.getGlyphFromChar(c),
			@intCast(cx * df.face.width), @intCast((cy + 1) * df.face.height));
	}
};

pub const Event = struct {
	pub const Type = union(enum) {
		unknown,
		err,
		destroy,
		expose,
		resize: struct { w: u16, h: u16 },
		key: struct { down: bool, code: u16 },
	};
	type: Type,
	w_id: ?WindowID,
};

inline fn castEvent(T: type, e: *xcb.xcb_generic_event_t) *T {
	return @as(*T, @ptrCast(e));
}

pub fn getEvent() DisplayError!Event {
	var event: *xcb.xcb_generic_event_t = undefined;
	event = xcb.xcb_wait_for_event(connection)
		orelse return error.DoesNotExist;
	switch (event.response_type) {
		0 => {
			const err = castEvent(xcb.xcb_generic_error_t, event);
			logger.err("xcb error {} {}:{}", .{
				err.*.error_code, err.*.major_code, err.*.minor_code,
			});
			return Event { .type = .err, .w_id = null };
		},
		xcb.XCB_DESTROY_NOTIFY => return Event{
			.type = .destroy,
			.w_id = castEvent(xcb.xcb_destroy_notify_event_t, event).window,
		},
		xcb.XCB_EXPOSE => return Event{
			.type = .expose,
			.w_id = castEvent(xcb.xcb_expose_event_t, event).window,
		},
		xcb.XCB_CONFIGURE_NOTIFY => return .{
			.type = .{ .resize = .{
				.w = castEvent(xcb.xcb_configure_notify_event_t, event).width,
				.h = castEvent(xcb.xcb_configure_notify_event_t, event).height,
			} },
			.w_id = castEvent(xcb.xcb_configure_notify_event_t, event).window,
		},
		xcb.XCB_KEY_PRESS => return Event{
			.type = .{ .key = .{
				.down = true,
				.code = castEvent(xcb.xcb_key_press_event_t, event).detail,
			} },
			.w_id = castEvent(xcb.xcb_key_press_event_t, event).event,
		},
		xcb.XCB_KEY_RELEASE => return Event{
			.type = .{ .key = .{
				.down = false,
				.code = castEvent(xcb.xcb_key_release_event_t, event).detail,
			} },
			.w_id = castEvent(xcb.xcb_key_release_event_t, event).event,
		},
		else => return Event{ .type = .unknown, .w_id = null },
	}
}
