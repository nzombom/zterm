//! functions for rendering fonts to bitmaps

const std = @import("std");
const config = @import("config.zig");
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));
const ft = @cImport({
	@cInclude("freetype2/ft2build.h");
	@cInclude("freetype2/freetype/freetype.h");
});

const logger = std.log.scoped(.font);

var ft_lib: ft.FT_Library = undefined;

pub const Error = error { OutOfMemory, InitFailed, OpenFailed, DrawFailed };

/// initialize the libraries
pub fn init() Error!void {
	if (fc.FcInit() == 0) return error.InitFailed;
	logger.debug("loaded fontconfig version {}", .{ fc.FcGetVersion() });
	var major: i32 = undefined;
	var minor: i32 = undefined;
	var patch: i32 = undefined;
	if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.InitFailed;
	ft.FT_Library_Version(ft_lib, &major, &minor, &patch);
	logger.debug("loaded freetype version {}.{}.{}",
		.{ major, minor, patch });
}
/// deinit & exit
pub fn deinit() void {
	fc.FcFini();
	_ = ft.FT_Done_FreeType(ft_lib);
}

/// the mode of drawing
pub const PixelMode = enum {
	/// u1; black and white only
	mono,
	/// u8; antialiased, 256 grays
	gray,
	/// u24; subpixel rendering, 0xrrggbb
	lcd,

	pub fn bitSize(m: PixelMode) u8 { return switch (m) {
		.mono => 1, .gray => 8, .lcd => 24,
	}; }
};

pub const Bitmap = struct {
	// positive y = down
	x: i16, y: i16,
	w: u16, h: u16,
	pitch: u16,
	mode: PixelMode,
	data: []u8,

	pub fn at(bitmap: *const Bitmap, x: u16, y: u16) u32 {
		return switch (bitmap.mode) {
			.mono => (bitmap.data[y * bitmap.pitch + x / 8]
				>> @intCast(7 - x % 8)) % 2,
			.gray => bitmap.data[y * bitmap.pitch + x],
			.lcd => (@as(u32, bitmap.data[y * bitmap.pitch + x * 3]) << 16)
				+ (@as(u32, bitmap.data[y * bitmap.pitch + x * 3 + 1]) << 8)
				+ @as(u32, bitmap.data[y * bitmap.pitch + x * 3 + 2]),
		};
	}

	pub fn paddingBits(bitmap: *const Bitmap) u16 {
		return bitmap.pitch * 8 - bitmap.w * bitmap.mode.bitSize();
	}

	/// allocator should be the same one used to create .data
	pub fn deinit(bitmap: *const Bitmap, allocator: std.mem.Allocator) void {
		allocator.free(bitmap.data);
	}

	pub fn reverseBitOrder(bitmap: *const Bitmap) void {
		for (bitmap.data) |*c| c.* = @bitReverse(c.*);
	}
};

pub const Face = struct {
	/// the maximum width of a glyph
	width: u16,
	/// the total height in pixels of a glyph, including ascenders & descenders
	/// so no glyphs overlap
	height: u16,
	/// baseline position, in pixels from the top of the cell
	baseline: u16,
	/// opaque
	ft_face: ft.FT_Face,

	/// load a face given a fontconfig string
	pub fn init(query: [*:0]const u8, dpi: u16) Error!Face {
		const search_pattern = fc.FcNameParse(query);
		defer fc.FcPatternDestroy(search_pattern);
		fc.FcDefaultSubstitute(search_pattern);
		if (fc.FcConfigSubstitute(null,
				search_pattern, fc.FcMatchPattern) == 0)
			return error.OpenFailed;

		var result: fc.FcResult = undefined;
		const pattern = fc.FcFontMatch(null, search_pattern, &result);
		defer fc.FcPatternDestroy(pattern);
		if (result != fc.FcResultMatch)
			return error.OpenFailed;

		var file_value: fc.FcValue = undefined;
		var index_value: fc.FcValue = undefined;
		var size_value: fc.FcValue = undefined;

		var file: [:0]const u8 = undefined;
		var index: i32 = 0;
		var size: f64 = 16.0;

		if (fc.FcPatternGet(pattern, fc.FC_FILE, 0, &file_value)
			!= fc.FcResultMatch) {
			return error.OpenFailed;
		} else file = std.mem.span(file_value.u.s);
		if (fc.FcPatternGet(pattern, fc.FC_INDEX, 0, &index_value)
			!= fc.FcResultMatch) {
			logger.warn("font has no index, defaulting to 0", .{});
		} else index = index_value.u.i;
		if (fc.FcPatternGet(pattern, fc.FC_SIZE, 0, &size_value)
			!= fc.FcResultMatch) {
			logger.warn("font has no size, defaulting to 16px", .{});
		} else size = size_value.u.d;

		var face: ft.FT_Face = undefined;
		if (ft.FT_New_Face(ft_lib, @constCast(file.ptr), index, &face) != 0)
			return error.OpenFailed;
		if (ft.FT_Set_Char_Size(face,
				@intFromFloat(size * 64), 0, dpi, 0) != 0)
			return error.OpenFailed;
		if (ft.FT_Select_Charmap(face, ft.FT_ENCODING_UNICODE) != 0)
			return error.OpenFailed;

		const px_width: u16 = @intCast(face.*.size.*.metrics.max_advance >> 6);
		const px_height: u16 = @intCast((face.*.size.*.metrics.ascender
			- face.*.size.*.metrics.descender) >> 6);
		const px_baseline: u16 = @intCast(face.*.size.*.metrics.ascender >> 6);

		logger.debug("found font \"{s}\" at {s}", .{ query, file });
		return .{
			.ft_face = face,
			.width = px_width, .height = px_height,
			.baseline = px_baseline,
		};
	}

	pub fn deinit(face: *const Face) void {
		_ = ft.FT_Done_Face(face.ft_face);
	}

	pub fn getCharGlyphIndex(face: *const Face, c: u32) u32 {
		const idx = ft.FT_Get_Char_Index(face.ft_face, c);
		if (idx == 0) logger.warn("glyph for 0x{x} not found", .{ c });
		return idx;
	}

	/// render a glyph and return a bitmap;
	/// caller must free the bitmap with .deinit()
	pub fn renderGlyph(
		face: Face, allocator: std.mem.Allocator,
		idx: u32, mode: PixelMode,
	) Error!Bitmap {
		if (ft.FT_Load_Glyph(face.ft_face, idx, ft.FT_LOAD_DEFAULT) != 0)
			return error.DrawFailed;
		if (ft.FT_Render_Glyph(face.ft_face.*.glyph, switch (mode) {
			.mono => ft.FT_RENDER_MODE_MONO,
			.gray => ft.FT_RENDER_MODE_NORMAL,
			.lcd => ft.FT_RENDER_MODE_LCD,
		}) != 0)
			return error.DrawFailed;

		const g = face.ft_face.*.glyph;
		const bmp = g.*.bitmap;
		const bits_per_pixel = mode.bitSize();
		const pitch = (bmp.width * bits_per_pixel + 31) / 32 * 4;
		const data = try allocator.alloc(u8, pitch * bmp.rows);

		const bmp_pitch: u32 = @abs(bmp.pitch);
		for (0..bmp.rows) |i| {
			const y = if (bmp.pitch > 0) i else bmp.rows - i;
			@memcpy(data[pitch * y .. pitch * y + pitch],
				bmp.buffer[bmp_pitch * y .. bmp_pitch * y + pitch]);
		}
		return .{
			.x = @intCast(g.*.bitmap_left), .y = @intCast(-g.*.bitmap_top),
			.w = @as(u16, @intCast(bmp.width))
				/ @as(u16, if (mode == .lcd) 3 else 1),
			.h = @intCast(bmp.rows),
			.pitch = @intCast(pitch),
			.mode = mode, .data = data,
		};
	}
};
