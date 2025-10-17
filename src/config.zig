/// fonts to use (normal, bold, faint, italic, italic+bold, italic+faint)
pub const fonts: [6][:0]const u8 = .{
	"monospace:size=12",
	"monospace:style=heavy:size=12",
	"monospace:style=thin:size=12",
	"monospace:style=italic:size=12",
	"monospace:style=heavy italic:size=12",
	"monospace:style=thin italic:size=12",
};

// colors are 0xaarrggbb
/// default background color
pub const default_bg: u32 = 0xc0201e24;
/// default foreground color
pub const default_fg: u32 = 0xffffffff;
/// cursor background color (null to use normal background)
pub const cursor_bg: ?u32 = 0x605a66;
/// cursor foreground color (null to use normal foreground)
pub const cursor_fg: ?u32 = null;
/// four-bit colors
pub const four_bit_colors: [16]u32 = .{
	0xff302e32,
	0xffd05058,
	0xff40b058,
	0xffb09040,
	0xff5060c0,
	0xffb840bc,
	0xff30a09c,
	0xffffffff,
	0xff3c3a40,
	0xffff707c,
	0xff60ff78,
	0xffffd080,
	0xff7080ff,
	0xfff460ff,
	0xff40d4cc,
	0xffffffff,
};

/// default window width
pub const default_width: u16 = 80;
/// default window height
pub const default_height: u16 = 20;

/// maximum number of lines of scrollback
pub const max_scrollback: u16 = 256;

/// minimum delay after an event before updating
pub const min_latency: u64 = 5;
/// maximum delay after an event before updating
pub const max_latency: u64 = 25;
