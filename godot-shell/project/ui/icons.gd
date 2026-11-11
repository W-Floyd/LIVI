class_name Icons
## Symbolic icons, 24-unit paths rendered from SVG at the pixel size each use needs, so they
## stay sharp at any density. White; tint with `modulate` or a Button's icon colors.

const PATHS := {
	home = "M12 3 2 12h3v9h5v-6h4v6h5v-9h3z",
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
	plug = "M8 2v5H6v3a6 6 0 0 0 4 5.7V22h4v-6.3A6 6 0 0 0 18 10V7h-2V2h-2v5h-4V2z",
	clock = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 2a8 8 0 1 1 0 16 8 8 0 0 1 0-16zm-1 3v6l4.5 2.7.8-1.3L13 12.2V7z",
	fan = "M12 10.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM12 3c2.5 0 3.5 2 2.6 3.8L13 10l-2-.5C9.7 7.8 9.5 3 12 3zm9 9c0 2.5-2 3.5-3.8 2.6L14 13l.5-2c1.7-1.3 6.5-1.5 6.5 1zm-9 9c-2.5 0-3.5-2-2.6-3.8L11 14l2 .5c1.3 1.7 1.5 6.5-1 6.5zM3 12c0-2.5 2-3.5 3.8-2.6L10 11l-.5 2C7.8 14.3 3 14.5 3 12z",
	gear = "M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM9.4 4.8L9.8 2.0L14.2 2.0L14.6 4.8L15.2 5.1L17.5 3.4L20.6 6.5L18.9 8.8L19.2 9.4L22.0 9.8L22.0 14.2L19.2 14.6L18.9 15.2L20.6 17.5L17.5 20.6L15.2 18.9L14.6 19.2L14.2 22.0L9.8 22.0L9.4 19.2L8.8 18.9L6.5 20.6L3.4 17.5L5.1 15.2L4.8 14.6L2.0 14.2L2.0 9.8L4.8 9.4L5.1 8.8L3.4 6.5L6.5 3.4L8.8 5.1z",
	v2l = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 2a8 8 0 1 1 0 16 8 8 0 0 1 0-16zm1 3-4 6h3l-1 4 4-6h-3z",
	heading = "M3 3h10v3H8.1L21 18.9 18.9 21 6 8.1V13H3z",
	back = "M15.5 4.5 8 12l7.5 7.5 1.9-1.9L11.8 12l5.6-5.6z",
	eye = "M12 5C6.5 5 2.7 9.2 1 12c1.7 2.8 5.5 7 11 7s9.3-4.2 11-7c-1.7-2.8-5.5-7-11-7zm0 11a4 4 0 1 1 0-8 4 4 0 0 1 0 8zm0-2a2 2 0 1 0 0-4 2 2 0 0 0 0 4z",
	eye_off = "M3.3 2 2 3.3l3 3C3.4 7.6 2 9.4 1 12c1.7 2.8 5.5 7 11 7 1.8 0 3.4-.4 4.8-1.1l3.9 3.8 1.3-1.3zM12 17c-3.5 0-6.3-2.5-8-5 .8-1.2 1.9-2.4 3.2-3.3l2 2A4 4 0 0 0 14.3 14.9l1.5 1.5c-1.1.4-2.4.6-3.8.6zM12 7c3.5 0 6.3 2.5 8 5-.5.8-1.2 1.6-2 2.3l1.4 1.4c1.2-1.1 2.2-2.3 2.6-3.7-1.7-2.8-5.5-7-11-7-1 0-2 .1-2.9.4L10 7.1c.6-.1 1.3-.1 2-.1z",
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
