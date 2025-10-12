//! provides display functions using x11 & xrender

const std = @import("std");
const config = @import("../config.zig");
const char = @import("../char.zig");
const font = @import("../font.zig");
const xcb = @cImport({
	@cInclude("xcb/xcb.h");
	@cInclude("xcb/render.h");
	@cInclude("xcb/xkb.h");
	@cInclude("xcb/xcb_renderutil.h");
	@cInclude("xkbcommon/xkbcommon.h");
	@cInclude("xkbcommon/xkbcommon-x11.h");
});

const logger = std.log.scoped(.display);

var connection: *xcb.xcb_connection_t = undefined;
var screen: *xcb.xcb_screen_t = undefined;
var render_formats: [3]*xcb.xcb_render_pictforminfo_t = undefined;
var xkb_context: *xcb.xkb_context = undefined;
var xkb_keymap: *xcb.xkb_keymap = undefined;
var xkb_state: *xcb.xkb_state = undefined;

pub const Error = error {
	OutOfMemory,
	InitFailed, ConnectionClosed,
	WindowOpenFailed, FontOpenFailed, RenderGlyphFailed,
	WindowNotFound,
};

fn logXcbError(err: *xcb.xcb_generic_error_t) void {
	logger.err("xcb error {} {}:{}", .{
		err.*.error_code, err.*.major_code, err.*.minor_code,
	});
}
fn checkXcb(
	req: xcb.xcb_void_cookie_t, ret_err: anytype
) @TypeOf(ret_err)!void {
	const err = xcb.xcb_request_check(connection, req);
	if (err != null) {
		logXcbError(err);
		std.c.free(err);
		return ret_err;
	}
}

pub fn init() Error!void {
	var screen_n: i32 = undefined;
	connection = xcb.xcb_connect(null, &screen_n)
		orelse return Error.InitFailed;
	const setup = xcb.xcb_get_setup(connection);
	var screen_iter = xcb.xcb_setup_roots_iterator(setup);
	if (screen_n < 0) return error.InitFailed;
	for (0..@intCast(screen_n)) |_| {
		xcb.xcb_screen_next(&screen_iter);
	}
	screen = screen_iter.data;

	const xrender_info = xcb.xcb_get_extension_data(connection,
		&xcb.xcb_render_id);
	if (xrender_info.*.present == 0) return error.InitFailed;
	const xkb_info = xcb.xcb_get_extension_data(connection,
		&xcb.xcb_xkb_id);
	if (xkb_info.*.present == 0) return error.InitFailed;

	const formats_query = xcb.xcb_render_util_query_formats(connection);
	render_formats = .{
		xcb.xcb_render_util_find_standard_format(formats_query,
			xcb.XCB_PICT_STANDARD_A_1),
		xcb.xcb_render_util_find_standard_format(formats_query,
			xcb.XCB_PICT_STANDARD_A_8),
		xcb.xcb_render_util_find_standard_format(formats_query,
			xcb.XCB_PICT_STANDARD_RGB_24),
		};

	if (xcb.xcb_xkb_use_extension_reply(connection,
			xcb.xcb_xkb_use_extension_unchecked(connection, 1, 0),
			null).*.supported != 1)
		return error.InitFailed;

	xkb_context = xcb.xkb_context_new(xcb.XKB_CONTEXT_NO_FLAGS)
		orelse return error.InitFailed;
	const xkb_device = xcb.xkb_x11_get_core_keyboard_device_id(connection);
	if (xkb_device < 0) return error.InitFailed;
	xkb_keymap = xcb.xkb_x11_keymap_new_from_device(xkb_context, connection,
		xkb_device, xcb.XKB_KEYMAP_COMPILE_NO_FLAGS)
		orelse return error.InitFailed;
	xkb_state = xcb.xkb_state_new(xkb_keymap)
		orelse return error.InitFailed;

	logger.debug("established xcb connection on screen {}", .{ screen_n });
}
pub fn deinit() void {
	xcb.xkb_state_unref(xkb_state);
	xcb.xkb_keymap_unref(xkb_keymap);
	xcb.xkb_context_unref(xkb_context);
	xcb.xcb_disconnect(connection);
}
pub fn flush() void { _ = xcb.xcb_flush(connection); }

inline fn eventAs(T: type, e: *xcb.xcb_generic_event_t) *T {
	return @as(*T, @ptrCast(e));
}

pub const Event = union(enum) {
	/// just ignore these events
	unknown,
	/// the window was destroyed
	destroy: struct { win: *Window },
	/// the window was resized
	resize: struct {
		win: *Window,
		width: u16, height: u16,
		redraw_required: bool
	},
	/// a key was pressed/released
	key: struct { win: *Window, event: char.KeyEvent },
};

fn findWindow(window_id: xcb.xcb_window_t, windows: []Window) Error!*Window {
	for (0..windows.len) |i| if (windows[i].id == window_id)
		return &windows[i];
	return error.WindowNotFound;
}

fn handleXcbEvent(
	xcb_event: *xcb.xcb_generic_event_t,
	windows: []Window,
) Error!Event { switch (xcb_event.response_type) {
	0 => {
		logXcbError(eventAs(xcb.xcb_generic_error_t, xcb_event));
		return .unknown;
	},
	xcb.XCB_EXPOSE => {
		const event = eventAs(xcb.xcb_expose_event_t, xcb_event);
		const win = try findWindow(event.window, windows);
		win.draw();
		return .unknown;
	},
	xcb.XCB_DESTROY_NOTIFY => {
		const event = eventAs(xcb.xcb_destroy_notify_event_t, xcb_event);
		return .{ .destroy = .{
			.win = try findWindow(event.window, windows),
		} };
	},
	xcb.XCB_CONFIGURE_NOTIFY => {
		const event = eventAs(xcb.xcb_configure_notify_event_t, xcb_event);
		const win = try findWindow(event.window, windows);
		const redraw_required = try win.resize(event.width, event.height);
		return .{ .resize = .{
			.win = win,
			.width = event.width,
			.height = event.height,
			.redraw_required = redraw_required,
		} };
	},
	xcb.XCB_KEY_PRESS, xcb.XCB_KEY_RELEASE => |xcb_type| {
		const event = eventAs(xcb.xcb_key_press_event_t, xcb_event);
		const down = xcb_type == xcb.XCB_KEY_PRESS;
		_ = xcb.xkb_state_update_key(xkb_state, event.detail,
			if (down) xcb.XKB_KEY_DOWN else xcb.XKB_KEY_UP);
		const sym = xcb.xkb_state_key_get_one_sym(xkb_state, event.detail);
		const n: u21 = @intCast(xcb.xkb_keysym_to_utf32(sym));

		var key: char.Key = undefined;
		if (n == 0) {
			key = .{ .control = switch (sym) {
				0xffe5 => .caps_lock,
				0xffe1 => .shift_l, 0xffe2 => .shift_r,
				0xffe3 => .ctrl_l, 0xffe4 => .ctrl_r,
				0xffe9 => .alt_l, 0xffea => .alt_r,
				0xffeb => .super_l, 0xffec => .super_r,
				0xff61 => .print_screen,
				0xff14 => .scroll_lock, 0xff13 => .pause_break,
				0xffbe...0xffd5 => |e| @enumFromInt(
					@intFromEnum(char.Key.Control.f_1) + e - 0xffbe),
				0xff63 => .insert,
				0xff50 => .home, 0xff57 => .end,
				0xff55 => .page_up, 0xff56 => .page_down,
				0xff51 => .left, 0xff52 => .up,
				0xff53 => .right, 0xff54 => .down,
				else => .unknown,
			} };
		} else key = .{ .char = char.fromCode(n) };

		const key_event: char.KeyEvent = .{ .down = down, .key = key, .mods = .{
			.shift = xcb.xkb_state_mod_name_is_active(xkb_state,
				xcb.XKB_MOD_NAME_SHIFT, xcb.XKB_STATE_MODS_EFFECTIVE) > 0,
			.caps = xcb.xkb_state_mod_name_is_active(xkb_state,
				xcb.XKB_MOD_NAME_CAPS, xcb.XKB_STATE_MODS_EFFECTIVE) > 0,
			.ctrl = xcb.xkb_state_mod_name_is_active(xkb_state,
				xcb.XKB_MOD_NAME_CTRL, xcb.XKB_STATE_MODS_EFFECTIVE) > 0,
			.alt = xcb.xkb_state_mod_name_is_active(xkb_state,
				xcb.XKB_VMOD_NAME_ALT, xcb.XKB_STATE_MODS_EFFECTIVE) > 0,
			.super = xcb.xkb_state_mod_name_is_active(xkb_state,
				xcb.XKB_VMOD_NAME_SUPER, xcb.XKB_STATE_MODS_EFFECTIVE) > 0,
		} };

		return .{ .key = .{
			.win = try findWindow(event.event, windows),
			.event = key_event,
		} };
	},
	else => return .unknown,
}
}

pub fn pollEvent(w: []Window) Error!?Event {
	const event = xcb.xcb_poll_for_event(connection) orelse return null;
	return try handleXcbEvent(event, w);
}

pub fn waitEvent(w: []Window) Error!Event {
	const event = xcb.xcb_wait_for_event(connection)
		orelse return error.ConnectionClosed;
	return handleXcbEvent(event, w);
}

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

pub const Window = struct {
	allocator: std.mem.Allocator,
	width: u16, height: u16,
	/// opaque
	id: xcb.xcb_window_t,
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

	fn getAtom(str: []const u8) xcb.xcb_atom_t {
		return xcb.xcb_intern_atom_reply(connection,
			xcb.xcb_intern_atom_unchecked(connection, 0,
				@intCast(str.len), str.ptr), null).*.atom;
	}
	/// set the title of the window
	pub fn setTitle(win: *const Window, title: []const u8) void {
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING,
			8, @intCast(title.len), title.ptr);
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, getAtom("_NET_WM_NAME"), getAtom("UTF8_STRING"),
			8, @intCast(title.len), title.ptr);
		_ = xcb.xcb_change_property(connection, xcb.XCB_PROP_MODE_REPLACE,
			win.id, xcb.XCB_ATOM_WM_ICON_NAME, xcb.XCB_ATOM_STRING,
			8, @intCast(title.len), title.ptr);
	}
	/// sets the class of the window
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
