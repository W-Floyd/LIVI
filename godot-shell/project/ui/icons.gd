class_name Icons
## Symbolic icons, 24-unit paths rendered from SVG at the pixel size each use needs, so they
## stay sharp at any density. White; tint with `modulate` or a Button's icon colors.

const PATHS := {
	bolt = "M13 2 4 14h7l-1 8 9-12h-7z",
	fuel = "M4 3h10v18H4zm2 2v5h6V5zM15 7l1.4-1.4 3.1 3.1V18a2 2 0 0 1-4 0v-4h-1v-2h1a2 2 0 0 1 2 2v4h0V9.5z",
	play = "M8 5v14l11-7z",
	pause = "M7 5h4v14H7zM13 5h4v14h-4z",
	next = "M6 6v12l8.5-6zM16 6h2v12h-2z",
	prev = "M18 6v12L9.5 12zM6 6h2v12H6z",
	therm = "M12 2a3 3 0 0 0-3 3v8.8a5 5 0 1 0 6 0V5a3 3 0 0 0-3-3zm0 2a1 1 0 0 1 1 1v9.9l.4.3a3 3 0 1 1-2.8 0l.4-.3V5a1 1 0 0 1 1-1zm-1 6h2v7h-2z",
	temp = "M12 2a3 3 0 0 0-3 3v8.8a5 5 0 1 0 6 0V5a3 3 0 0 0-3-3z",
	warn = "M12 2 1 21h22zm-1 7h2v6h-2zm0 8h2v2h-2z",
	info = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1 8h2v8h-2zm0-4h2v2h-2z",
	lock = "M7 10V8a5 5 0 0 1 10 0v2h2v12H5V10zm2 0h6V8a3 3 0 0 0-6 0z",
	bars = "M3 17h3v4H3zM8 13h3v8H8zM13 9h3v12h-3zM18 5h3v16h-3z",
	phone = "M7 1h10a2 2 0 0 1 2 2v18a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2zm0 3v15h10V4z",
	pin = "M12 1a8 8 0 0 0-8 8c0 6 8 14 8 14s8-8 8-14a8 8 0 0 0-8-8zm0 11a3 3 0 1 1 0-6 3 3 0 0 1 0 6z",
	note = "M9 3v11.3A3.5 3.5 0 1 0 11 17V8h7V3z",
	vol = "M3 9h4l5-4v14l-5-4H3zM15 8a5 5 0 0 1 0 8l1.4 1.4a7 7 0 0 0 0-10.8z",
}

static var _cache := {}


static func texture(name: String, size_px: float) -> Texture2D:
	var px := maxi(8, roundi(size_px))
	var key := "%s@%d" % [name, px]
	if _cache.has(key):
		return _cache[key]
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#fff" fill-rule="evenodd" d="%s"/></svg>' % PATHS[name]
	var img := Image.new()
	img.load_svg_from_string(svg, px / 24.0)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex
