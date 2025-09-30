//! provides display functions using x11

const std = @import("std");
const config = @import("config.zig");
const char = @import("char.zig");
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

pub const Error = error {
	OutOfMemory,
	InitFailed, ConnectionClosed,
	WindowOpenFailed, FontOpenFailed, RenderGlyphFailed,
	WindowNotFound,
};

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

pub fn init() Error!void {
	var screen_n: i32 = undefined;
	connection = xcb.xcb_connect(null, &screen_n)
		orelse return Error.InitFailed;
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

	logger.debug("established xcb connection on screen {}", .{ screen_n });
}
pub fn deinit() void { xcb.xcb_disconnect(connection); }
pub fn flush() void { _ = xcb.xcb_flush(connection); }

const PreparedBitmap = struct {
	bitmap: font.Bitmap,

	// if bitmap is zero-size
	// then pixmap and picture are not guaranteed to exist
	/// opaque
	pixmap: xcb.xcb_pixmap_t,
	/// opaque
	picture: xcb.xcb_render_picture_t,

	fn init(
		allocator: std.mem.Allocator, bitmap: font.Bitmap,
	) PreparedBitmap {
		if (bitmap.w == 0 or bitmap.h == 0) return .{
			.pixmap = 0, .picture = 0, .bitmap = bitmap,
		};

		const prepared: PreparedBitmap = .{
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

	fn deinit(prepared: PreparedBitmap) void {
		_ = xcb.xcb_render_free_picture(connection, prepared.picture);
		_ = xcb.xcb_free_pixmap(connection, prepared.pixmap);
	}
};

const GlyphSet = std.AutoArrayHashMapUnmanaged(u32, PreparedBitmap);

pub const DisplayFont = struct {
	allocator: std.mem.Allocator,
	face: font.Face,
	mode: font.PixelMode,
	/// opaque
	gs: GlyphSet,

	pub fn init(
		allocator: std.mem.Allocator,
		name: [:0]const u8, mode: font.PixelMode,
	) Error!DisplayFont {
		const dpi_x = @as(f32, @floatFromInt(screen.width_in_pixels)) /
			(@as(f32, @floatFromInt(screen.width_in_millimeters)) / 25.4);

		const df: DisplayFont = .{
			.allocator = allocator,
			.face = font.Face.init(name, @intFromFloat(dpi_x))
				catch return error.FontOpenFailed,
			.mode = mode,
			.gs = .empty,
		};
		return df;
	}

	pub fn deinit(df: *DisplayFont) void {
		var it = df.gs.iterator();
		while (it.next()) |g| g.value_ptr.deinit();
		df.gs.deinit(df.allocator);
		df.face.deinit();
	}

	fn getGlyphFromChar(
		df: *DisplayFont, c: char.Char,
	) Error!PreparedBitmap {
		const code = char.toCode(c);
		return df.gs.get(code) orelse {
			const g = PreparedBitmap.init(df.allocator,
				df.face.renderGlyph(df.allocator,
					df.face.getCharGlyphIndex(code), df.mode)
				catch return error.RenderGlyphFailed);
			try df.gs.put(df.allocator, code, g);
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
	allocator: std.mem.Allocator,
	id: WindowID,
	width: u16, height: u16,
	/// opaque
	gc: xcb.xcb_gcontext_t,
	/// opaque
	pixmap: struct {
		id: xcb.xcb_pixmap_t,
		width: u16, height: u16,
	},
	/// opaque
	picture: xcb.xcb_render_picture_t,
	/// opaque
	colors: ColorMap,

	const Color = struct {
		pixmap: xcb.xcb_pixmap_t,
		picture: xcb.xcb_render_picture_t,
	};

	const ColorMap = std.AutoArrayHashMapUnmanaged(u32, Color);

	pub fn open(
		allocator: std.mem.Allocator,
		width: u16, height: u16,
	) Error!Window {
		var win: Window = .{
			.allocator = allocator,
			.id = xcb.xcb_generate_id(connection),
			.width = width, .height = height,
			.gc = xcb.xcb_generate_id(connection),
			.pixmap = .{
				.id = xcb.xcb_generate_id(connection),
				.width = width, .height = height,
			},
			.picture = xcb.xcb_generate_id(connection),
			.colors = .empty,
		};

		var value_buffer: [16]u8 = undefined;
		var values: ?*[16]u8 = &value_buffer;
		const value_mask = xcb.XCB_CW_BACK_PIXEL
			| xcb.XCB_CW_EVENT_MASK
			| xcb.XCB_CW_BIT_GRAVITY;
		_ = xcb.xcb_create_window_value_list_serialize(&values, value_mask, &.{
			.background_pixel = config.background_color,
			.event_mask = xcb.XCB_EVENT_MASK_EXPOSURE
				| xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY
				| xcb.XCB_EVENT_MASK_KEY_PRESS
				| xcb.XCB_EVENT_MASK_KEY_RELEASE,
			.bit_gravity = xcb.XCB_GRAVITY_NORTH_WEST,
		});
		try checkXcb(xcb.xcb_create_window_checked(connection, 24,
				win.id, screen.*.root, 0, 0, width, height,
				0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.*.root_visual,
				value_mask, values), error.WindowOpenFailed);
		try checkXcb(xcb.xcb_create_gc_checked(connection, win.gc, win.id,
				0, null), error.WindowOpenFailed);
		try checkXcb(xcb.xcb_create_pixmap_checked(connection, 24,
				win.pixmap.id, win.id, width, height), error.WindowOpenFailed);
		try checkXcb(xcb.xcb_render_create_picture_checked(connection,
				win.picture, win.pixmap.id, render_formats[2].id, 0, null),
			error.WindowOpenFailed);
		_ = xcb.xcb_render_composite(connection, xcb.XCB_RENDER_PICT_OP_SRC,
			(try win.getColor(config.background_color)).picture,
			0, win.picture, 0, 0, 0, 0, 0, 0, width, height);

		return win;
	}

	pub fn close(win: *Window) void {
		var it = win.colors.iterator();
		while (it.next()) |c| {
			_ = xcb.xcb_free_pixmap(connection, c.value_ptr.pixmap);
			_ = xcb.xcb_render_free_picture(connection, c.value_ptr.picture);
		}
		win.colors.deinit(win.allocator);
		_ = xcb.xcb_render_free_picture(connection, win.picture);
		_ = xcb.xcb_free_pixmap(connection, win.pixmap.id);
		_ = xcb.xcb_destroy_window(connection, win.id);
	}

	/// returns whether a redraw is required
	fn resize(win: *Window, width: u16, height: u16) Error!bool {
		win.width, win.height = .{ width, height };
		if (width > win.pixmap.width or height > win.pixmap.height) {
			// resizing the pixmap is required
			const new_width, const new_height = .{
				if (width > win.pixmap.width)
					width + width / 2 else win.pixmap.width,
				if (height > win.pixmap.height)
					height + height / 2 else win.pixmap.height,
			};
			_ = xcb.xcb_render_free_picture(connection, win.picture);
			_ = xcb.xcb_free_pixmap(connection, win.pixmap.id);
			_ = xcb.xcb_create_pixmap_checked(connection, 24,
				win.pixmap.id, win.id, new_width, new_height);
			win.pixmap.width, win.pixmap.height = .{ new_width, new_height };
			_ = xcb.xcb_render_create_picture(connection,
				win.picture, win.pixmap.id, render_formats[2].id, 0, null);
			_ = xcb.xcb_render_composite(connection, xcb.XCB_RENDER_PICT_OP_SRC,
				(try win.getColor(config.background_color)).picture,
				0, win.picture, 0, 0, 0, 0, 0, 0, new_width, new_height);
			return true;
		} else return false;
	}

	/// put the window to the screen
	pub fn draw(win: *const Window) void {
		_ = xcb.xcb_copy_area(connection, win.pixmap.id, win.id, win.gc,
			0, @intCast(win.pixmap.height - win.height),
			0, 0, win.width, win.height);
		_ = xcb.xcb_map_window(connection, win.id);
	}

	fn renderBitmap(
		win: *const Window, prepared: PreparedBitmap,
		x: i16, y: i16, color: Color,
	) void {
		if (prepared.bitmap.w == 0 or prepared.bitmap.h == 0) return;
		_ = xcb.xcb_render_composite(connection, xcb.XCB_RENDER_PICT_OP_OVER,
			color.picture, prepared.picture, win.picture,
			0, 0, 0, 0, x + prepared.bitmap.x, y + prepared.bitmap.y,
			prepared.bitmap.w, prepared.bitmap.h);
	}

	/// render a char at cell (cx, cy) where cy = 0 at the BOTTOM
	pub fn renderChar(
		win: *Window, df: *DisplayFont,
		c: char.Char, cx: u16, cy: u16, bg: u32, fg: u32,
	) Error!void {
		const y_pos = win.pixmap.height - df.face.height * (cy + 1);
		_ = xcb.xcb_render_composite(connection, xcb.XCB_RENDER_PICT_OP_SRC,
			(try win.getColor(bg)).picture, 0, win.picture, 0, 0, 0, 0,
			@intCast(cx * df.face.width), @intCast(y_pos),
			@intCast(df.face.width), @intCast(df.face.height));
		if (std.meta.eql(c, char.null_char)) return;
		win.renderBitmap(try df.getGlyphFromChar(c),
			@intCast(cx * df.face.width),
			@intCast(y_pos + df.face.baseline),
			try win.getColor(fg));
	}

	fn getColor(win: *Window, hex: u32) Error!Color {
		return win.colors.get(hex) orelse {
			const c: Color = .{
				.pixmap = xcb.xcb_generate_id(connection),
				.picture = xcb.xcb_generate_id(connection),
			};
			_ = xcb.xcb_create_pixmap(connection, 24, c.pixmap, win.id, 1, 1);
			_ = xcb.xcb_render_create_picture(connection,
				c.picture, c.pixmap, render_formats[2].id,
				xcb.XCB_RENDER_CP_REPEAT, &xcb.XCB_RENDER_REPEAT_NORMAL);
			_ = xcb.xcb_render_fill_rectangles(connection,
				xcb.XCB_RENDER_PICT_OP_SRC, c.picture,
				xcbrColorFromHex(hex),
				1, &.{ .x = 0, .y = 0, .width = 1, .height = 1 });
			try win.colors.put(win.allocator, hex, c);
			return c;
		};
	}

	/// set the title of the window. title does not need to be null-terminated
	pub fn setTitle(win: *const Window, title: []const u8) void {
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING,
			8, @intCast(title.len), title.ptr);
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, xcb.XCB_ATOM_WM_ICON_NAME, xcb.XCB_ATOM_STRING,
			8, @intCast(title.len), title.ptr);
	}
	/// sets the class of the window; should be two strings, null-separated
	pub fn setClass(
		win: *const Window, class_i: []const u8, class_g: []const u8,
	) Error!void {
		const class = try win.allocator.alloc(u8,
			class_i.len + 1 + class_g.len);
		defer win.allocator.free(class);
		@memcpy(class[0..class_i.len], class_i);
		class[class_i.len] = '\x00';
		@memcpy(class[class_i.len + 1 .. class.len], class_g);
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, xcb.XCB_ATOM_WM_CLASS, xcb.XCB_ATOM_STRING,
			8, @intCast(class.len), class.ptr);
	}
	/// set the resize grid of the window
	pub fn setResizeGrid(win: *const Window, width: u16, height: u16) void {
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, xcb.XCB_ATOM_WM_NORMAL_HINTS, xcb.XCB_ATOM_WM_SIZE_HINTS,
			32, 18, &[18]i32{
				0b0101010000,		// flags
				0, 0, 0, 0,			// pad
				width, height,		// min w & h
				0, 0,				// max w & h
				width, height,		// w & h inc
				0, 0, 0, 0,			// min & max aspect
				0, 0,				// base w & h
				0,					// gravity
			});
	}
};

pub const Event = struct {
	pub const Type = union(enum) {
		/// just ignore these events
		unknown,
		/// the window was destroyed
		destroy,
		/// the window was resized
		resize: struct { width: u16, height: u16, redraw_required: bool },
		/// a key was pressed/released
		key: struct { down: bool, code: u16 },
	};
	type: Type,
	w_id: ?WindowID,
};

pub const unknown_event: Event = .{ .type = .unknown, .w_id = null };

inline fn castEvent(T: type, e: *xcb.xcb_generic_event_t) *T {
	return @as(*T, @ptrCast(e));
}

fn handleXcbEvent(
	xcb_event: *xcb.xcb_generic_event_t,
	windows: []Window,
) Error!Event { switch (xcb_event.response_type) {
		0 => {
			const event =
				castEvent(xcb.xcb_generic_error_t, xcb_event);
			logger.err("xcb error {} {}:{}", .{
				event.*.error_code, event.*.major_code, event.*.minor_code,
			});
			return unknown_event;
		},
		xcb.XCB_DESTROY_NOTIFY => {
			const event =
				castEvent(xcb.xcb_destroy_notify_event_t, xcb_event);
			return .{ .type = .destroy, .w_id = event.window };
		},
		xcb.XCB_EXPOSE => {
			const event =
				castEvent(xcb.xcb_expose_event_t, xcb_event);
			find_window: {
				for (windows) |win| if (win.id == event.window) {
					win.draw();
					break :find_window;
				};
				return error.WindowNotFound;
			}
			return unknown_event;
		},
		xcb.XCB_CONFIGURE_NOTIFY => {
			const event =
				castEvent(xcb.xcb_configure_notify_event_t, xcb_event);
			const redraw_required = find_window: {
				for (0..windows.len) |i| if (windows[i].id == event.window) {
					break :find_window
						try windows[i].resize(event.width, event.height);
				};
				return error.WindowNotFound;
			};
			return .{
				.type = .{ .resize = .{
					.width = event.width,
					.height = event.height,
					.redraw_required = redraw_required,
				} },
				.w_id = event.window,
			};
		},
		xcb.XCB_KEY_PRESS, xcb.XCB_KEY_RELEASE => |xcb_type| {
			const event =
				castEvent(xcb.xcb_key_press_event_t, xcb_event);
			const down = xcb_type == xcb.XCB_KEY_PRESS;
			return .{
				.type = .{ .key = .{ .down = down, .code = event.detail } },
				.w_id = event.event,
			};
		},
		else => return unknown_event,
	}
}

pub fn pollEvent(w: []Window) Error!?Event {
	const event = xcb.xcb_wait_for_event(connection) orelse return null;
	return try handleXcbEvent(event, w);
}

pub fn waitEvent(w: []Window) Error!Event {
	const event = xcb.xcb_wait_for_event(connection)
		orelse return error.ConnectionClosed;
	return handleXcbEvent(event, w);
}
