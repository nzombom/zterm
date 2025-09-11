const std = @import("std");
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));

pub const FontError = error{ InitFailed, LoadFailed };

pub fn init() FontError!void {
	if(fc.FcInit() == 0) return FontError.InitFailed;
}
pub fn deinit() void {
	fc.FcFini();
}

pub fn load(query: [:0]const u8) FontError!void {
	const logger = std.log.scoped(.font);
	logger.info("searching for \"{s}\"", .{ query });
	const search_pattern = fc.FcNameParse(query.ptr);
	defer fc.FcPatternDestroy(search_pattern);
	fc.FcDefaultSubstitute(search_pattern);
	if (fc.FcConfigSubstitute(null,
			search_pattern, fc.FcMatchPattern) == 0)
		return FontError.LoadFailed;

	var result: fc.FcResult = undefined;
	const pattern = fc.FcFontMatch(null, search_pattern, &result);
	defer fc.FcPatternDestroy(pattern);
	if (result != fc.FcResultMatch)
		return FontError.LoadFailed;

	var file_value: fc.FcValue = undefined;
	var index_value: fc.FcValue = undefined;
	if (fc.FcPatternGet(pattern, fc.FC_FILE, 0, &file_value)
		!= fc.FcResultMatch)
		return FontError.LoadFailed;
	if (fc.FcPatternGet(pattern, fc.FC_INDEX, 0, &index_value)
		!= fc.FcResultMatch) {
		logger.info("has no index, defaulting to 0", .{});
		index_value.type = fc.FcTypeInteger;
		index_value.u.i = 0;
	}
	const file = std.mem.span(file_value.u.s);
	const index = index_value.u.i;
	logger.info("found font at {s}, index {}", .{ file, index });
}
