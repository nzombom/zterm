const std = @import("std");
const config = @import("config.zig");
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));
const ft = @cImport({
	@cInclude("freetype2/ft2build.h");
	@cInclude("freetype2/freetype/freetype.h");
});

const logger = std.log.scoped(.font);
var ft_lib: ft.FT_Library = undefined;

pub const InitError = error{ FCFailed, FTFailed };
pub const LoadError = error{ SearchFailed, OpenFailed };

pub fn init() InitError!void {
	if (fc.FcInit() == 0) return error.FCFailed;
	logger.info("loaded fontconfig version {}", .{ fc.FcGetVersion() });
	var major: i32 = undefined;
	var minor: i32 = undefined;
	var patch: i32 = undefined;
	if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FTFailed; ft.FT_Library_Version(ft_lib, &major, &minor, &patch); logger.info("loaded freetype version {}.{}.{}",
		.{ major, minor, patch });
}
pub fn deinit() void {
	fc.FcFini();
	_ = ft.FT_Done_FreeType(ft_lib);
	logger.info("unloaded font libraries", .{});
}

pub const Face = struct {
	f: ft.FT_Face,

	pub fn load(query: [:0]const u8) LoadError!Face {
		logger.info("searching for \"{s}\"", .{ query });
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
		var size: f64 = 16.0;

		if (fc.FcPatternGet(pattern, fc.FC_FILE, 0, &file_value)
			!= fc.FcResultMatch) {
			return error.SearchFailed;
		} else file = std.mem.span(file_value.u.s);
		if (fc.FcPatternGet(pattern, fc.FC_INDEX, 0, &index_value)
			!= fc.FcResultMatch) {
			logger.warn("- has no index, defaulting to 0", .{});
		} else index = index_value.u.i;
		if (fc.FcPatternGet(pattern, fc.FC_PIXEL_SIZE, 0, &size_value)
			!= fc.FcResultMatch) {
			logger.warn("- has no size, defaulting to 16px", .{});
		} else size = size_value.u.d;
		logger.info("- loading font at {s}, index {}, size {}px",
			.{ file, index, size });

		var face: ft.FT_Face = undefined;
		if (ft.FT_New_Face(ft_lib, @constCast(file.ptr), index, &face) != 0)
			return error.OpenFailed;

		const size_fixed: u32 = @intFromFloat(size * 64);
		if (ft.FT_Set_Pixel_Sizes(face, size_fixed, size_fixed) != 0)
			return error.OpenFailed;

		return .{ .f = face };
	}
};
