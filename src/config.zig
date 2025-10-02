pub const font: [:0]const u8 = "monospace:size=12";

// colors are 0xaarrggbb
/// default background color
pub const background_color: u32 = 0xc0201e24;
/// default foreground color
pub const foreground_color: u32 = 0xffffffff;
/// cursor background color (null to use normal background)
pub const cursor_background_color: ?u32 = 0x605a66;
/// cursor foreground color (null to use normal foreground)
pub const cursor_foreground_color: ?u32 = null;

pub const default_width: u16 = 80;
pub const default_height: u16 = 20;
pub const max_scrollback: u16 = 256;

pub const min_latency: u64 = 5;
pub const max_latency: u64 = 25;
