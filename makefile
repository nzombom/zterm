zterm: *.zig freetype/freetype.zig
	zig build-exe zterm.zig -lc -lxcb -lfontconfig

freetype/freetype.zig: freetype/freetype.h
	pkgconf --cflags-only-I freetype2\
	| xargs zig translate-c freetype/freetype.h -lc\
	> freetype/freetype.zig
