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
	expand = "M3 3h7v2H5v5H3zm11 0h7v7h-2V5h-5zM3 14h2v5h5v2H3zm16 0h2v7h-7v-2h5z",
	vol = "M3 9h4l5-4v14l-5-4H3zM15 8a5 5 0 0 1 0 8l1.4 1.4a7 7 0 0 0 0-10.8z",
	grid = "M3 3h8v8H3zm2 2v4h4V5zm8-2h8v8h-8zm2 2v4h4V5zM3 13h8v8H3zm2 2v4h4v-4zm8-2h8v8h-8zm2 2v4h4v-4z",
	close = "M6.4 5 5 6.4 10.6 12 5 17.6 6.4 19l5.6-5.6 5.6 5.6 1.4-1.4-5.6-5.6L19 6.4 17.6 5 12 10.6z",
	chevron = "M8.5 4.5 16 12l-7.5 7.5-1.9-1.9L12.2 12 6.6 6.4z",
	check = "M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z",
	minus = "M5 11h14v2H5z",
	plus = "M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6z",
	car = "M5 11l1.5-4.5A2 2 0 0 1 8.4 5h7.2a2 2 0 0 1 1.9 1.5L19 11h1a1 1 0 0 1 1 1v5h-2v2h-3v-2H8v2H5v-2H3v-5a1 1 0 0 1 1-1zm2.1 0h9.8l-1.1-3.4a.9.9 0 0 0-.9-.6H9.1a.9.9 0 0 0-.9.6zM6.5 13a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm11 0a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z",
	monitor = "M2 4h20v13h-8v2h3v2H7v-2h3v-2H2zm2 2v9h16V6z",
	contrast = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 2v16a8 8 0 0 1 0-16z",
	chip = "M7 7h10v10H7zm2 2v6h6V9zM9 2h2v3H9zm4 0h2v3h-2zM9 19h2v3H9zm4 0h2v3h-2zM2 9h3v2H2zm0 4h3v2H2zm17-4h3v2h-3zm0 4h3v2h-3z",
	tune = "M3 5h10v2H3zm14 0h4v2h-4zm-2-2h2v6h-2zM3 11h4v2H3zm8 0h10v2H11zm-2-2h2v6H9zM3 17h10v2H3zm14 0h4v2h-4zm-2-2h2v6h-2z",
	brush = "M7 14a3 3 0 0 0-3 3c0 1.3-1.2 2-2 2 .9 1.2 2.5 2 4 2a4 4 0 0 0 4-4 3 3 0 0 0-3-3zM20.7 4.6l-1.3-1.3a1 1 0 0 0-1.4 0L9 12.3 11.7 15l9-9a1 1 0 0 0 0-1.4z",
	star = "M12 2.5l2.9 6.3 6.9.7-5.2 4.6 1.5 6.8L12 17.4l-6.1 3.5 1.5-6.8-5.2-4.6 6.9-.7z",
	star_outline = "M12 2.5l2.9 6.3 6.9.7-5.2 4.6 1.5 6.8L12 17.4l-6.1 3.5 1.5-6.8-5.2-4.6 6.9-.7zm0 4.9-1.6 3.5-3.8.4 2.9 2.5-.8 3.8 3.3-1.9 3.3 1.9-.8-3.8 2.9-2.5-3.8-.4z",
	chevron_up = "M4.5 15.5 12 8l7.5 7.5-1.9 1.9L12 11.8l-5.6 5.6z",
	chevron_down = "M4.5 8.5 12 16l7.5-7.5-1.9-1.9L12 12.2 6.4 6.6z",
	android = "M17.6 9.5l1.7-3-.9-.5-1.7 3A10 10 0 0 0 12 8a10 10 0 0 0-4.7 1l-1.7-3-.9.5 1.7 3A8 8 0 0 0 2.5 16h19a8 8 0 0 0-3.9-6.5zM7.5 13.5a1 1 0 1 1 0-2 1 1 0 0 1 0 2zm9 0a1 1 0 1 1 0-2 1 1 0 0 1 0 2z",
	usb = "M11 2h2v12.5l3-2V10h-1V7h3v3h-1v3.5l-4 2.7V18a2 2 0 1 1-2 0v-2.3l-4-2.7V11.7a2 2 0 1 1 2 0V12l2 1.3V5H9l2-3z",
	wifi = "M12 5a17 17 0 0 0-11 4l1.6 1.8A14.5 14.5 0 0 1 12 7.5c3.6 0 6.9 1.2 9.4 3.3L23 9a17 17 0 0 0-11-4zm0 5a11 11 0 0 0-7.3 2.8l1.6 1.8A8.5 8.5 0 0 1 12 12.5c2.2 0 4.2.8 5.7 2.1l1.6-1.8A11 11 0 0 0 12 10zm0 5a5 5 0 0 0-3.5 1.4L12 20l3.5-3.6A5 5 0 0 0 12 15z",
	folder = "M2 5a1 1 0 0 1 1-1h6l2 2h10a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z",
	file = "M6 2h8l5 5v15H6zm7 1.5V8h4.5z",
	backspace = "M22 3H7c-.7 0-1.2.4-1.6.9L0 12l5.4 8.1c.4.5.9.9 1.6.9h15a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2zm-3 12.6L17.6 17 14 13.4 10.4 17 9 15.6 12.6 12 9 8.4 10.4 7 14 10.6 17.6 7 19 8.4 15.4 12z",
	shift = "M12 3 2 13h6v8h8v-8h6zm0 2.8L17.2 11H14v8h-4v-8H6.8z",
	shift_on = "M12 3 2 13h6v8h8v-8h6z",
	caps = "M12 2 3 11h5v6h8v-6h5zM8 19h8v2H8z",
	battery = "M4 7h3V5h3v2h4V5h3v2h3v13H4zm2 2v9h12V9zm1 3.2h4v1.6H7zm6 0h1.7V10.5h1.6v1.7H18v1.6h-1.7v1.7h-1.6v-1.7H13z",
	keyboard = "M4 5h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2zm1 3v2h2V8zm3 0v2h2V8zm3 0v2h2V8zm3 0v2h2V8zm3 0v2h2V8zM5 11v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zm3 0v2h2v-2zM8 15v2h8v-2z",
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
