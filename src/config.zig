/// fonts to use
pub const fonts: [6][:0]const u8 = .{
	"monospace:size=12",						// normal
	"monospace:style=heavy:size=12",			// bold
	"monospace:style=thin:size=12",				// faint
	"monospace:style=italic:size=12",			// italic
	"monospace:style=heavy italic:size=12",		// italic + bold
	"monospace:style=thin italic:size=12",		// italic + faint
};

/// pixel mode: .mono, .gray, .lcd (does not work with x+xrender)
pub const pixel_mode: @import("font.zig").PixelMode = .gray;

// colors are 0xaarrggbb

/// default background color
pub const default_bg: u32 = 0xc0201e24;
/// default foreground color
pub const default_fg: u32 = 0xffffffff;

/// cursor background color (null to use normal background)
pub const cursor_bg: ?u32 = 0xff605a66;
/// cursor foreground color (null to use normal foreground)
pub const cursor_fg: ?u32 = 0xffffffff;

/// four-bit colors
pub const four_bit_colors: [16]u32 = .{
	0xff302e32,		//  0 black
	0xffd05058,		//  1 red
	0xff40b058,		//  2 green
	0xffb09040,		//  3 yellow
	0xff5060c0,		//  4 blue
	0xffb840bc,		//  5 magenta
	0xff30a09c,		//  6 cyan
	0xffffffff,		//  7 white
	0xff3c3a40,		//  8 bright black
	0xffff707c,		//  9 bright red
	0xff60ff78,		// 10 bright green
	0xffffd080,		// 11 bright yellow
	0xff7080ff,		// 12 bright blue
	0xfff460ff,		// 13 bright magenta
	0xff40d4cc,		// 14 bright cyan
	0xffffffff,		// 15 bright white
};

/// bold text automatically uses the brighter sixteen colors
pub const bold_uses_bright_colors: bool = true;

/// default window width
pub const default_width: u16 = 80;
/// default window height
pub const default_height: u16 = 20;

/// maximum number of lines of scrollback
pub const max_scrollback: u16 = 256;

/// minimum delay after an event before updating
pub const min_latency: u64 = 5;
/// maximum delay after an event before updating
pub const max_latency: u64 = 20;
