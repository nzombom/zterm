const std = @import("std");
const config = @import("config.zig");
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));
const ft = @cImport({
	@cInclude("freetype2/ft2build.h");
	@cInclude("freetype2/freetype/freetype.h");
});

const logger = std.log.scoped(.font);
var ft_lib: ft.FT_Library = undefined;

pub const InitError = error { FCFailed, FTFailed };
pub const LoadError = error { SearchFailed, OpenFailed };
pub const FontError = error { DrawFailed, Unsupported };

pub fn init() InitError!void {
	if (fc.FcInit() == 0) return error.FCFailed;
	logger.debug("loaded fontconfig version {}", .{ fc.FcGetVersion() });
	var major: i32 = undefined;
	var minor: i32 = undefined;
	var patch: i32 = undefined;
	if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FTFailed;
	ft.FT_Library_Version(ft_lib, &major, &minor, &patch);
	logger.debug("loaded freetype version {}.{}.{}",
		.{ major, minor, patch });
}
pub fn deinit() void {
	fc.FcFini();
	_ = ft.FT_Done_FreeType(ft_lib);
	logger.debug("unloaded font libraries", .{});
}

pub const Bitmap = struct {
	x: i32, y: i32,
	w: u32, h: u32,
	pitch: i32,
	data: []u8,
	mode: Mode,
	pub const Mode = enum { mono, gray, lcd };
	pub fn bitsPerPixel(m: Mode) u8 { return switch (m) {
		.mono => 1,
		.gray => 8,
		.lcd => 24,
	}; }
};

pub const Face = struct {
	f: ft.FT_Face,

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
		logger.debug("font found at {s}, index {}, size {}pt = {}px",
			.{ file, index, size, size * config.dpi / 72 });

		var face: ft.FT_Face = undefined;
		if (ft.FT_New_Face(ft_lib, @constCast(file.ptr), index, &face) != 0)
			return error.OpenFailed;

		const size_fixed: u32 = @intFromFloat(size * 64);
		if (ft.FT_Set_Char_Size(face, 0, size_fixed, 0, config.dpi) != 0)
			return error.OpenFailed;

		if (ft.FT_Select_Charmap(face, ft.FT_ENCODING_UNICODE) != 0)
			return error.OpenFailed;

		return .{ .f = face };
	}

	pub fn getCharGlyphIndex(self: Face, c: u32) u32 {
		const idx = ft.FT_Get_Char_Index(self.f, c);
		if (idx == 0) logger.warn("glyph for {0x} {0} not found", .{ c });
		return idx;
	}

	pub fn renderGlyph(
		allocator: std.mem.Allocator,
		self: Face, idx: u32
	) FontError!Bitmap {
		if (ft.FT_Load_Glyph(self.f, idx, ft.FT_LOAD_DEFAULT) != 0)
			return error.DrawFailed;
		if (ft.FT_Render_Glyph(self.f.glyph, ft.FT_RENDER_MODE_NORMAL) != 0)
			return error.DrawFailed;

		const g = self.f.glyph;
		const bmp = g.bitmap;
		const mode: Bitmap.Mode = switch (bmp.pixel_mode) {
			ft.FT_PIXEL_MODE_MONO => .mono,
			ft.FT_PIXEL_MODE_GRAY => .gray,
			ft.FT_PIXEL_MODE_LCD => .lcd,
			else => return error.Unsupported,
		};
		const bits_per_pixel = Bitmap.bitsPerPixel(mode);
		const pitch = (bmp.width * bits_per_pixel + 31) / 32 * 4;
		const data = allocator.alloc(u8, pitch * bmp.rows);
		var y: u32 = 0;
		while (y < bmp.height) : (y += 1) {
			@memcpy(data[pitch * y .. pitch * y + pitch],
				bmp.buffer[bmp.pitch * y .. bmp.pitch * y + pitch]);
		}
		return .{
			.x = g.bitmap_left, .y = g.bitmap_top,
			.w = bmp.width, .h = bmp.rows,
			.pitch = pitch, .data = data, .mode = mode,
		};
	}
};

