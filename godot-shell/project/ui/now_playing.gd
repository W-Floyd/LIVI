class_name NowPlaying
extends Node
## What is playing, from the core's `nowPlaying`, `sessions`, `dab` and `fm`, for home's mini
## player and the media page alike. The position runs on between the core's reports while
## playing, as stock LIVI's player does (livi-ui-model `Playback`): it holds after 3 s without
## progress, keeps still for a second after a seek, and never creeps back by jitter.

signal changed
signal art_changed

## No progress reported for this long while playing: stalled, the position stops.
const STALL_MS := 3000.0
## A tapped play/pause shows at once, until the core agrees or this passes.
const OPTIMISTIC_MS := 4000.0
## The core's reports right after a seek are of before it.
const SEEK_HOLD_MS := 1000.0
## Smaller backward steps are jitter; the bar does not move back for them.
const JUMP_BACK_MS := 500.0
## Art is decoded to at most this, for the media page's cover at the unit's density.
const ART_PX := 640
## The backdrop's blur is this small an image drawn stretched.
const BACKDROP_PX := 24

var title := ""
var artist := ""
var album := ""
## The phone's app (Spotify, Podcasts), when it says.
var app := ""
## carplay | androidauto | airplay | "" (none).
var session := ""
var duration_ms := 0.0
## The phone can seek: CarPlay and AirPlay take a position, Android Auto does not (as stock).
var can_seek := false
## The cover, or null; `backdrop` is the same tiny, for a blurred ground.
var art: Texture2D
var backdrop: Texture2D
## DAB+ and FM, as stock's media model has them (`livi-ui-model` `dab`/`fm`): `receiver`;
## per band `active`, `playing`, `title` ("" none tuned), `detail`, `text`, `tuned`
## (service id or kHz, -1), `favorite`, `logo` (base64), `initials`, `badge`, `stations`.
var receiver := false
var dab := {}
var fm := {}

var _playing := false
var _reported := -1.0
var _live := 0.0
var _at := 0.0
var _last_progress := -1.0
var _stalled := false
var _seek_until := -1.0
var _back_once := false
var _last_fraction := 0.0
var _last_elapsed := 0.0
var _track := ""
var _want := false
var _want_until := -1.0
var _session_key := ""
var _art_b64 := ""
var _art_gen := 0
var _dirty := {}


func _ready() -> void:
	Core.changed.connect(_on_core_changed)
	Core.welcome.connect(func(_v): refresh())
	refresh()


func _on_core_changed(sections: PackedStringArray) -> void:
	var first := _dirty.is_empty()
	for s in sections:
		if s in ["nowPlaying", "sessions", "dab", "fm"]:
			_dirty[s] = true
	if first and not _dirty.is_empty():
		_refresh_dirty.call_deferred()


func _refresh_dirty() -> void:
	var d := _dirty
	_dirty = {}
	refresh(d)


## `sections` are the changed ones; empty reads them all.
func refresh(sections := {}) -> void:
	var all := sections.is_empty()
	if all or sections.has("sessions"):
		var s = Core.get_value("/sessions/active")
		session = str(s) if s != null else ""
		can_seek = session in ["carplay", "airplay"]
		var key := "%s:%s" % [session, Core.get_value("/sessions/position")]
		if key != _session_key and _session_key != "":
			_want_until = -1.0
			_back_once = false
			_last_fraction = 0.0
		_session_key = key
	if all or sections.has("nowPlaying"):
		_read_now_playing()
	if all or sections.has("dab") or sections.has("fm"):
		_read_radio()
	changed.emit()


func _read_now_playing() -> void:
	var v := func(k: String, d): var x = Core.get_value("/nowPlaying/" + k); return d if x == null else x
	title = str(v.call("title", ""))
	artist = str(v.call("artist", ""))
	album = str(v.call("album", ""))
	app = str(v.call("app", ""))
	var now := _now()
	var track := title + "\u001f" + artist
	if track != _track:
		_track = track
		_last_fraction = 0.0
		_last_elapsed = 0.0
	var e = Core.get_value("/nowPlaying/elapsedMs")
	var elapsed: float = -1.0 if e == null else float(e)
	var progressed := e != null and elapsed != _reported
	if progressed:
		_reported = elapsed
	var on: bool = v.call("playing", false) == true
	var resumed := on and not _playing
	_playing = on
	duration_ms = maxf(0.0, float(v.call("durationMs", 0.0)))
	if progressed or resumed or _last_progress < 0.0:
		_last_progress = now
		_stalled = false
	if now >= _seek_until:
		_live = maxf(0.0, elapsed)
		_at = now
	if _want_until >= 0.0 and _want == on:
		_want_until = -1.0
	# The string compare is a memcmp; the decode (a 100 KB JPEG) is off the main thread.
	var a = Core.get_value("/nowPlaying/artwork")
	var b64: String = a if a is String else ""
	if b64 != _art_b64:
		_art_b64 = b64
		_art_gen += 1
		if b64 == "":
			_set_art(null, null, _art_gen)
		else:
			WorkerThreadPool.add_task(_decode.bind(b64, _art_gen), false, "artwork")


func _decode(b64: String, gen: int) -> void:
	var img := decode_image(b64)
	var small: Image = null
	if img != null:
		if maxi(img.get_width(), img.get_height()) > ART_PX:
			var k := float(ART_PX) / maxi(img.get_width(), img.get_height())
			img.resize(maxi(1, roundi(img.get_width() * k)), maxi(1, roundi(img.get_height() * k)), Image.INTERPOLATE_CUBIC)
		small = img.duplicate() as Image
		small.resize(BACKDROP_PX, BACKDROP_PX, Image.INTERPOLATE_CUBIC)
		# Home's thumbnail is a tenth of the cover: without mipmaps it shimmers.
		img.generate_mipmaps()
	_set_art.call_deferred(img, small, gen)


func _set_art(img: Image, small: Image, gen: int) -> void:
	if gen != _art_gen:
		return
	art = ImageTexture.create_from_image(img) if img else null
	backdrop = ImageTexture.create_from_image(small) if small else null
	art_changed.emit()


## A base64 PNG, JPEG or WebP; null when it is none of them.
static func decode_image(b64: String) -> Image:
	var raw := Marshalls.base64_to_raw(b64)
	if raw.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if raw[0] == 0x89 and raw[1] == 0x50:
		err = img.load_png_from_buffer(raw)
	elif raw[0] == 0xFF and raw[1] == 0xD8:
		err = img.load_jpg_from_buffer(raw)
	elif raw.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = img.load_webp_from_buffer(raw)
	if err != OK or img.is_empty():
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img


static var _logos := {}


## A station's logo (base64), decoded once.
static func logo(b64: String) -> Texture2D:
	if not _logos.has(b64):
		var img := decode_image(b64)
		_logos[b64] = ImageTexture.create_from_image(img) if img else null
	return _logos[b64]


## Whether the phone (or a source) is playing, a tapped toggle showing at once.
func playing() -> bool:
	return _want if _now() < _want_until else _playing and not _stalled


## The source on air: dab | fm | phone.
func on_air() -> String:
	return "dab" if dab.get("active", false) else "fm" if fm.get("active", false) else "phone"


func has_content() -> bool:
	return title != "" or on_air() != "phone"


## The position now, run on from the last report while playing.
func elapsed_ms() -> float:
	var now := _now()
	var dt := maxf(0.0, now - _at)
	_at = now
	if _playing:
		if now - _last_progress > STALL_MS:
			_live = maxf(0.0, _reported)
			_stalled = true
		else:
			_live = clampf(_live + dt, 0.0, duration_ms)
	return maxf(0.0, _live)


## Of the duration, 0 to 1; held still against small backward jitter while playing.
func fraction() -> float:
	var e := elapsed_ms()
	var f := e / duration_ms if duration_ms > 0.0 else 0.0
	var restart := _back_once or _last_elapsed - e > JUMP_BACK_MS
	if _playing and not _stalled and not restart and f + 0.001 < _last_fraction:
		f = _last_fraction
	f = clampf(f, 0.0, 1.0)
	_last_fraction = f
	_last_elapsed = e
	_back_once = false
	return f


## Whether the position moves on its own: the page redraws it each frame only then.
func running() -> bool:
	return (_playing and not _stalled) or _now() < _want_until


## A tap on play/pause, prev or next: the shown state follows at once.
func pressed(control: String) -> void:
	match control:
		"playPause":
			_want = not playing()
			_want_until = _now() + OPTIMISTIC_MS
		"prev":
			_back_once = true
	changed.emit()


## Seeks the phone to `f` of the track; the bar shows it at once.
func seek(f: float) -> void:
	var now := _now()
	var pos := clampf(f, 0.0, 1.0) * duration_ms
	_live = pos
	_at = now
	_back_once = true
	_seek_until = now + SEEK_HOLD_MS
	Core.act({kind = "seek", positionMs = roundi(pos)})
	changed.emit()


func _now() -> float:
	return Clock.now() * 1000.0


func _read_radio() -> void:
	var d = Core.get_value("/dab")
	var f = Core.get_value("/fm")
	d = d if d is Dictionary else {}
	f = f if f is Dictionary else {}
	receiver = d.get("receiver") != null
	dab = _dab(d)
	fm = _fm(f)


static func _dab(d: Dictionary) -> Dictionary:
	var tuned = d.get("station")
	var out := {active = d.get("active", false) == true, playing = d.get("playing", false) == true, text = str(d.get("text", "") if d.get("text") != null else ""),
		tuned = int(tuned) if tuned != null else -1, title = "", detail = "", favorite = false, logo = "", stations = []}
	for st in d.get("stations", []):
		if tuned != null and int(st.get("serviceId", -1)) == int(tuned):
			out.title = str(st.get("label", ""))
			out.detail = "%s · %s" % [st.get("ensemble", ""), st.get("channel", "")]
			out.favorite = st.get("favorite", false) == true
			out.logo = str(st.get("logo", "") if st.get("logo") != null else "")
		if st.get("hidden", false):
			continue
		var label := str(st.get("label", ""))
		var short := str(st.get("shortLabel", ""))
		out.stations.append({id = int(st.get("serviceId", 0)), label = short if short != "" else label, favorite = st.get("favorite", false) == true,
			tuned = tuned != null and int(st.get("serviceId", -1)) == int(tuned), logo = str(st.get("logo", "") if st.get("logo") != null else ""), initials = initials(label), badge = badge(label)})
	var shown: String = out.title if out.title != "" else "DAB+"
	out.initials = initials(shown)
	out.badge = badge(shown)
	return out


static func _fm(f: Dictionary) -> Dictionary:
	var tuned = f.get("station")
	var out := {active = f.get("active", false) == true, playing = f.get("playing", false) == true, text = str(f.get("text", "") if f.get("text") != null else ""),
		tuned = int(tuned) if tuned != null else -1, title = "", detail = "", favorite = false, logo = "", stations = []}
	var name := ""
	if tuned != null:
		var listed := {}
		for st in f.get("stations", []):
			if int(st.get("khz", 0)) == int(tuned):
				listed = st
		name = str(f.get("name", "") if f.get("name") != null else "").strip_edges()
		if name == "":
			name = str(listed.get("name", "")).strip_edges()
		out.title = name if name != "" else "%s MHz" % mhz(int(tuned))
		out.detail = "%s MHz" % mhz(int(tuned))
		out.favorite = listed.get("favorite", false) == true
	var shown := name if name != "" else mhz(int(tuned)) if tuned != null else "FM"
	out.initials = _fm_initials(shown)
	out.badge = badge(shown)
	for st in f.get("stations", []):
		if st.get("hidden", false):
			continue
		var khz := int(st.get("khz", 0))
		var n := str(st.get("name", "")).strip_edges()
		var label := n if n != "" else mhz(khz)
		out.stations.append({id = khz, label = label, favorite = st.get("favorite", false) == true, tuned = tuned != null and khz == int(tuned),
			logo = "", initials = _fm_initials(label), badge = badge(label)})
	return out


static func mhz(khz: int) -> String:
	return "%d.%d" % [khz / 1000, khz % 1000 / 100]


## Up to two letters for a station without a logo, as stock's badges.
static func initials(label: String) -> String:
	var words := PackedStringArray()
	var w := ""
	for ch in label:
		if ch in [" ", "\t", "-", "_", "."]:
			if w != "":
				words.append(w)
			w = ""
		else:
			w += ch
	if w != "":
		words.append(w)
	if words.size() > 1:
		return (words[0].left(1) + words[1].left(1)).to_upper()
	return words[0].left(2).to_upper() if words.size() == 1 else "?"


static func _fm_initials(label: String) -> String:
	return label if label != "" and label[0] >= "0" and label[0] <= "9" else initials(label)


## Stock's badge colour: a hue from the label, at HSL 45 % saturation and 38 % lightness.
static func badge(label: String) -> Color:
	var h := 0
	for i in label.length():
		h = (h * 31 + label.unicode_at(i)) % 360
	var s := 0.45
	var l := 0.38
	var c := (1.0 - absf(2.0 * l - 1.0)) * s
	var x := c * (1.0 - absf(fmod(h / 60.0, 2.0) - 1.0))
	var m := l - c / 2.0
	var rgb: Vector3 = [Vector3(c, x, 0), Vector3(x, c, 0), Vector3(0, c, x), Vector3(0, x, c), Vector3(x, 0, c), Vector3(c, 0, x)][int(h / 60) % 6]
	return Color(rgb.x + m, rgb.y + m, rgb.z + m)


## m:ss, or h:mm:ss from an hour.
static func clock(ms: float) -> String:
	var s := maxi(0, int(ms / 1000.0))
	if s >= 3600:
		return "%d:%02d:%02d" % [s / 3600, s / 60 % 60, s % 60]
	return "%d:%02d" % [s / 60, s % 60]
