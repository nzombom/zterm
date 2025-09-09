const std = @import("std");
// const xcb = @cImport(@cInclude("xcb/xcb.h"));
const xcb = @cImport(@cInclude("X11/Xlib-xcb.h"));

var display: *xcb.Display = undefined;
var connection: *xcb.xcb_connection_t = undefined;
var screen: *xcb.xcb_screen_t = undefined;

pub const WindowError = error{ OpenFailed };

pub fn init() void {
	var screen_n: i32 = undefined;
	connection = xcb.xcb_connect(null, &screen_n)
		orelse unreachable;
	const setup = xcb.xcb_get_setup(connection);
	var screen_iter = xcb.xcb_setup_roots_iterator(setup);
	var i: u32 = 0;
	while (i < screen_n) : (i += 1) {
		xcb.xcb_screen_next(&screen_iter);
	}
	screen = screen_iter.data;
}
pub fn deinit() void {
	xcb.xcb_disconnect(connection);
}

pub fn flush() void {
	_ = xcb.xcb_flush(connection);
}

pub const Window = struct {
	id: xcb.xcb_window_t,
	gc: xcb.xcb_gcontext_t,

	pub fn open() WindowError!Window {
		return openRes(800, 600);
	}
	pub fn openRes(width: u16, height: u16) WindowError!Window {
		const w = Window{
			.id = xcb.xcb_generate_id(connection),
			.gc = xcb.xcb_generate_id(connection),
		};

		var value_buffer: [8]u8 = undefined;
		var values: ?*[8]u8 = &value_buffer;

		const open_value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK;
		_ = xcb.xcb_create_window_value_list_serialize(
			&values, open_value_mask, &.{
				.background_pixel = 0xc0201e24,
				.event_mask = xcb.XCB_EVENT_MASK_EXPOSURE
					| xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY
					| xcb.XCB_EVENT_MASK_KEY_PRESS
					| xcb.XCB_EVENT_MASK_KEY_RELEASE,
			});
		const open_request = xcb.xcb_create_window_checked(connection, 24,
			w.id, screen.*.root, 0, 0, width, height,
			0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.*.root_visual,
			open_value_mask, values);

		const gc_value_mask = xcb.XCB_GC_FOREGROUND;
		_ = xcb.xcb_create_gc_value_list_serialize(
			&values, gc_value_mask, &.{
				.foreground = 0xffffffff,
			});
		const gc_request = xcb.xcb_create_gc(connection,
			w.gc, w.id, gc_value_mask, values);

		const open_err = xcb.xcb_request_check(connection, open_request);
		const gc_err = xcb.xcb_request_check(connection, gc_request);
		var err = false;
		if (open_err != null) { err = true; std.c.free(open_err); }
		if (gc_err != null) { err = true; std.c.free(gc_err); }

		return if (err) WindowError.OpenFailed else w;
	}
	pub fn close(w: Window) void {
		_ = xcb.xcb_destroy_window(connection, w.id);
	}

	pub fn map(w: Window) void {
		_ = xcb.xcb_map_window(connection, w.id);
	}

	pub fn testLine(w: Window) void {
		const points: [*]const xcb.xcb_point_t = &.{
			xcb.xcb_point_t{ .x = 0, .y = 0 },
			xcb.xcb_point_t{ .x = 800, .y = 600 },
		};
		_ = xcb.xcb_poly_line(connection, xcb.XCB_COORD_MODE_ORIGIN,
			w.id, w.gc, 2, points);
	}
};

pub const Event = struct {
	pub const Type = union(enum) {
		none,
		unknown,
		destroy,
		expose,
		resize: struct { w: u16, h: u16 },
		key: struct { down: bool, code: u16 },
	};
	type: Type,
	w_id: ?xcb.xcb_window_t,
};

inline fn castEvent(T: anytype, e: ?*xcb.xcb_generic_event_t) *T {
	return @as(*T, @ptrCast(e.?));
}
pub fn getEvent() Event {
	var event: ?*xcb.xcb_generic_event_t = undefined;
	event = xcb.xcb_wait_for_event(connection);
	if (event == null) return Event{ .type = .none, .w_id = null };
	switch (event.?.response_type) {
		xcb.XCB_DESTROY_NOTIFY => return Event{
			.type = .destroy,
			.w_id = castEvent(xcb.xcb_destroy_notify_event_t, event).window,
		},
		xcb.XCB_EXPOSE => return Event{
			.type = .expose,
			.w_id = castEvent(xcb.xcb_expose_event_t, event).window,
		},
		xcb.XCB_CONFIGURE_NOTIFY => return Event{
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
