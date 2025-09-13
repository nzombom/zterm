const std = @import("std");
const config = @import("config.zig");
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));
const ft = @cImport({
	@cInclude("freetype2/ft2build.h");
	@cInclude("freetype2/freetype/freetype.h");
});

const logger = std.log.scoped(.font);

var ft_lib: ft.FT_Library = undefined;

pub const InitError = error { FCInitFailed, FTInitFailed };
pub const LoadError = error { SearchFailed, OpenFailed };
pub const RenderError = error { OutOfMemory, DrawFailed };

pub fn init() InitError!void {
	if (fc.FcInit() == 0) return error.FCInitFailed;
	logger.debug("loaded fontconfig version {}", .{ fc.FcGetVersion() });
	var major: i32 = undefined;
	var minor: i32 = undefined;
	var patch: i32 = undefined;
	if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FTInitFailed;
	ft.FT_Library_Version(ft_lib, &major, &minor, &patch);
	logger.debug("loaded freetype version {}.{}.{}",
		.{ major, minor, patch });
}
pub fn deinit() void {
	fc.FcFini();
	_ = ft.FT_Done_FreeType(ft_lib);
}

pub const PixelMode = enum {
	mono,	 // u1; black and white only
	gray,	 // u8; antialiased, 256 values of gray
	lcd,	 // u24; subpixel rendering, 0xrrggbb

	pub fn bitSize(m: PixelMode) u8 { return switch (m) {
		.mono => 1, .gray => 8, .lcd => 24,
	}; }
};

pub const Bitmap = struct {
	x: i16, y: i16,
	w: u16, h: u16,
	pitch: u16,
	mode: PixelMode,
	data: []u8,

	pub fn at(self: Bitmap, x: u16, y: u16) u32 {
		return switch (self.mode) {
			.mono => (self.data[y * self.pitch + x / 8]
				>> @intCast(7 - x % 8)) % 2,
			.gray => self.data[y * self.pitch + x],
			.lcd => (@as(u32, self.data[y * self.pitch + x * 3]) << 16)
				+ (@as(u32, self.data[y * self.pitch + x * 3 + 1]) << 8)
				+ @as(u32, self.data[y * self.pitch + x * 3 + 2]),
		};
	}
	pub fn paddingBits(self: Bitmap) u16 {
		return self.pitch * 8 - self.w * self.mode.bitSize();
	}

	pub fn free(self: Bitmap, allocator: std.mem.Allocator) void {
		allocator.free(self.data);
	}
};

pub const Face = struct {
	f: ft.FT_Face,

	/// load a face given a fontconfig string
	pub fn load(query: [:0]const u8) LoadError!Face {
		logger.debug("loading font \"{s}\"", .{ query });
		const search_pattern = fc.FcNameParse(query.ptr);
		defer fc.FcPatternDestroy(search_pattern);
		fc.FcDefaultSubstitute(search_pattern);
		if (fc.FcConfigSubstitute(null,
				search_pattern, fc.FcMatchPattern) == 0)
			return error.SearchFailed;

		var result: fc.FcResult = undefined;
		const pattern = fc.FcFontMatch(null, search_pattern, &result);
		defer fc.FcPatternDestroy(pattern);
		if (result != fc.FcResultMatch)
			return error.SearchFailed;

		var file_value: fc.FcValue = undefined;
		var index_value: fc.FcValue = undefined;
		var size_value: fc.FcValue = undefined;

		var file: [:0]const u8 = undefined;
		var index: i32 = 0;
		var size: f64 = 12.0;

		if (fc.FcPatternGet(pattern, fc.FC_FILE, 0, &file_value)
			!= fc.FcResultMatch) {
			return error.SearchFailed;
		} else file = std.mem.span(file_value.u.s);
		if (fc.FcPatternGet(pattern, fc.FC_INDEX, 0, &index_value)
			!= fc.FcResultMatch) {
			logger.warn("font has no index, defaulting to 0", .{});
		} else index = index_value.u.i;
		if (fc.FcPatternGet(pattern, fc.FC_SIZE, 0, &size_value)
			!= fc.FcResultMatch) {
			logger.warn("font has no size, defaulting to 12pt", .{});
		} else size = size_value.u.d;
		logger.debug(
			\\found font:
			\\  file: {s},
			\\  index: {},
			\\  size: {}px
			, .{ file, index, size });

		var face: ft.FT_Face = undefined;
		if (ft.FT_New_Face(ft_lib, @constCast(file.ptr), index, &face) != 0)
			return error.OpenFailed;

		if (ft.FT_Set_Char_Size(face,
				0, @intFromFloat(size * 64), 0, config.dpi) != 0)
			return error.OpenFailed;

		if (ft.FT_Select_Charmap(face, ft.FT_ENCODING_UNICODE) != 0)
			return error.OpenFailed;

		return .{ .f = face };
	}

	pub fn getCharGlyphIndex(self: Face, c: u32) u32 {
		const idx = ft.FT_Get_Char_Index(self.f, c);
		if (idx == 0) logger.warn("glyph for 0x{x} not found", .{ c });
		return idx;
	}

	/// render a glyph and return a bitmap;
	/// caller must free the bitmap with .free()
	pub fn renderGlyph(
		self: Face,
		allocator: std.mem.Allocator,
		idx: u32,
		mode: PixelMode,
	) RenderError!Bitmap {
		if (ft.FT_Load_Glyph(self.f, idx, ft.FT_LOAD_DEFAULT) != 0)
			return error.DrawFailed;
		if (ft.FT_Render_Glyph(self.f.*.glyph, switch (mode) {
			.mono => ft.FT_RENDER_MODE_MONO,
			.gray => ft.FT_RENDER_MODE_NORMAL,
			.lcd => ft.FT_RENDER_MODE_LCD,
		}) != 0)
			return error.DrawFailed;

		const g = self.f.*.glyph;
		const bmp = g.*.bitmap;
		const bits_per_pixel = mode.bitSize();
		const pitch = (bmp.width * bits_per_pixel + 31) / 32 * 4;
		const data = try allocator.alloc(u8, pitch * bmp.rows);

		const bmp_pitch: u32 = @abs(bmp.pitch);
		var i: u32 = 0;
		while (i < bmp.rows) : (i += 1) {
			const y = if (bmp.pitch > 0) i else bmp.rows - i;
			@memcpy(data[pitch * y .. pitch * y + pitch],
				bmp.buffer[bmp_pitch * y .. bmp_pitch * y + pitch]);
		}
		return .{
			.x = @intCast(g.*.bitmap_left), .y = @intCast(g.*.bitmap_top),
			.w = @as(u16, @intCast(bmp.width))
				/ @as(u16, if (mode == .lcd) 3 else 1),
			.h = @intCast(bmp.rows),
			.pitch = @intCast(pitch),
			.mode = mode, .data = data,
		};
	}
};
