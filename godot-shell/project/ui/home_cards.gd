class_name HomeCards
extends Container
## Home's cards. The media card (`tall`), while something plays, leads: it gets the large slot
## and every other card keeps its own height. Beside the phone's picture, one column at the
## panel's edge: in rows where it has room for two (the media card the column's width on top, at
## least half the height, the rest side by side under it at the height of the tallest), else
## stacked with the media card filling the height the rest
## leaves, never shorter than the tallest of them. With no picture, a dashboard over the whole
## width: the media card on the driver's side, the rest stacked beside it, centred. With
## nothing playing, the cards stack at their own heights, centred. `wide` blends the column and
## the dashboard, so a change animates with every card keeping its node. Side by side (Look → Home
## layout): `host` (the battery card) a narrow column full height away from the driver, the
## rest stacked in the other with the media card filling what they leave, in the column and the
## dashboard alike.

## 0 the column, 1 the dashboard.
var wide := 0.0:
	set(v):
		wide = v
		update_minimum_size()
		queue_sort()
## The column's width; the column keeps to the left edge or the right, away from the picture.
var column := 600.0
var column_left := false
## The driver's side: in two columns the media card, the one most touched, takes the nearer.
var driver_left := true:
	set(v):
		driver_left = v
		queue_sort()
var gap := 16.0
## The dashboard's share of the width for the stacked cards: they keep their column look, a
## little wider; the media card takes the rest.
const LIST_SHARE := 0.42
## Beside the phone, a column with room for two (TALL_SHARE of it at least TALL_TOUCH touch
## targets, the rest at least REST_TOUCH: a card's title on one line) goes in rows (`split`).
const TALL_SHARE := 0.36
const TALL_TOUCH := 5.5
const REST_TOUCH := 10.0
## The media card; it leads while it has content (`has_content()`).
var tall: Control
## A card carried inside `host` as its bottom row, over the room the host keeps (`StatTile.foot`),
## rather than stacked on its own.
var foot: Control:
	set(v):
		if foot == v:
			return
		if foot:
			foot.minimum_size_changed.disconnect(sync_foot)
			foot.visibility_changed.disconnect(sync_foot)
		foot = v
		if v:
			v.minimum_size_changed.connect(sync_foot)
			v.visibility_changed.connect(sync_foot)
		sync_foot()
var host: Control
var side_by_side := false:
	set(v):
		side_by_side = v
		update_minimum_size()
		queue_sort()
## The host's column in `side_by_side`.
var host_width := 200.0:
	set(v):
		host_width = v
		queue_sort()
## How far under the panel the host's column reaches (the band beside the Phone | <app> pill).
var below := 0.0:
	set(v):
		below = v
		queue_sort()


## The host's room for `foot`, at once: the fit measures with it before anything sorts.
func sync_foot() -> void:
	if host:
		host.foot = foot.get_combined_minimum_size().y if _carried() else 0.0
	queue_sort()


func _get_minimum_size() -> Vector2:
	return Vector2(column, lerpf(needed(false, true), needed(true, true), wide))


## The height the visible cards need in the column (false) or the dashboard (true); `least`, the
## least they can take.
func needed(dashboard: bool, least := false) -> float:
	var shown := _shown()
	var lead := _lead(shown)
	if side_by_side:
		var h := -gap
		var hosted := 0.0
		for c in shown:
			if c == host:
				hosted = c.get_combined_minimum_size().y - below
			else:
				h += gap + (_lead_min(c) if c == lead else c.get_combined_minimum_size().y)
		return maxf(hosted, h)
	if lead == null:
		return _stack_height(shown)
	var rest := shown.duplicate()
	rest.erase(lead)
	if dashboard:
		return maxf(_stack_height(rest), _lead_min(lead))
	if split(shown):
		# The least: mid-drag nothing refits, and the media card gives way before the panel grows.
		return (_lead_min(lead) if least else _lead_row(lead)) + gap + _row_height(rest)
	return _stack_height(rest) + gap * float(not rest.is_empty()) + _lead_floor(lead, rest)


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var shown := _shown()
	var a := _column_rects(shown)
	var b := _dashboard_rects(shown)
	for i in shown.size():
		fit_child_in_rect(shown[i], Rect2(a[i].position.lerp(b[i].position, wide), a[i].size.lerp(b[i].size, wide)))
	if _carried() and host in shown:
		var r := host.get_rect()
		var box: StyleBox = host.get_theme_stylebox("panel")
		var h := foot.get_combined_minimum_size().y
		var l := box.get_margin(SIDE_LEFT)
		fit_child_in_rect(foot, Rect2(r.position.x + l, r.end.y - box.get_margin(SIDE_BOTTOM) - h, r.size.x - l - box.get_margin(SIDE_RIGHT), h))


## The rect `c` gets at the panel's present size, shown or not: for a card that arranges itself
## by its room before the panel decides whether it fits.
func child_rect(c: Control) -> Rect2:
	var shown := _with(c)
	var i := shown.find(c)
	var a := _column_rects(shown)[i]
	var b := _dashboard_rects(shown)[i]
	return Rect2(a.position.lerp(b.position, wide), a.size.lerp(b.size, wide))


## Its width alone, which no card's height changes (a card may size itself by it).
func child_width(c: Control) -> float:
	var shown := _with(c)
	var lead := _lead(shown)
	var w := minf(column, size.x)
	var col := w
	if lead != null and split(shown):
		if c == lead:
			col = w
		else:
			var rest := shown.duplicate()
			rest.erase(lead)
			col = _row_widths(rest, w)[rest.find(c)]
	if side_by_side:
		var hw := minf(host_width, size.x) if host in _with(c) else 0.0
		return hw if c == host else size.x - (hw + gap if hw > 0.0 else 0.0)
	var dash := minf(maxf(column, size.x * 0.5), size.x)
	if lead != null:
		var list_w := _list_width(_with(c), lead)
		dash = maxf(size.x - list_w - gap, 0.0) if c == lead else list_w
	return lerpf(col, dash, wide)


## Whether the column splits in two with `shown`: the media card leading, wide enough.
func split(shown: Array[Control]) -> bool:
	if side_by_side or _lead(shown) == null or shown.size() < 2:
		return false
	var w := minf(column, size.x) - gap
	return w * TALL_SHARE >= ThemeManager.px.touch * TALL_TOUCH and w * (1.0 - TALL_SHARE) >= ThemeManager.px.touch * REST_TOUCH


func _lead(shown: Array[Control]) -> Control:
	# Side by side it keeps its column with nothing playing too.
	return tall if tall != null and tall in shown and (side_by_side or tall.has_method("has_content") and tall.has_content()) else null


## What the media card needs whatever room it gets: it lays itself out large only in room that
## holds it (`compact_height`), so its present layout, chosen for the last room, does not count.
func _lead_min(lead: Control) -> float:
	return lead.compact_height() if lead.has_method("compact_height") else lead.get_combined_minimum_size().y


## The media card in a stack is never shorter than the tallest other card, a carried row aside.
func _lead_floor(lead: Control, rest: Array) -> float:
	var h: float = _lead_min(lead)
	for c in rest:
		h = maxf(h, c.get_combined_minimum_size().y - (c.foot if c == host and _carried() else 0.0))
	return h


func _with(c: Control) -> Array[Control]:
	var shown := _shown()
	if not c in shown:
		# Where it would be among its siblings.
		shown.clear()
		for ch in get_children():
			if ch is Control and (ch == c or (ch.visible and not ch.top_level and not (ch == foot and _carried()))):
				shown.append(ch)
	return shown


func _side_rects(shown: Array[Control]) -> Array[Rect2]:
	var hw := minf(host_width, size.x) if host in shown else 0.0
	var mw := size.x - (hw + gap if hw > 0.0 else 0.0)
	var mx := 0.0 if driver_left else size.x - mw
	var lead := _lead(shown)
	var fill := size.y
	for c in shown:
		if c != host and c != lead:
			fill -= c.get_combined_minimum_size().y + gap
	var out: Array[Rect2] = []
	var y := 0.0
	for c in shown:
		if c == host:
			out.append(Rect2(size.x - hw if driver_left else 0.0, 0.0, hw, size.y + below))
			continue
		var h: float = maxf(fill, _lead_min(c)) if c == lead else c.get_combined_minimum_size().y
		out.append(Rect2(mx, y, mw, h))
		y += h + gap
	return out


## The left edge and width of the column beside the host's, in the panel's coordinates.
func side_column() -> Vector2:
	var hw := minf(host_width, size.x) if host and host.visible else 0.0
	var mw := size.x - (hw + gap if hw > 0.0 else 0.0)
	return Vector2(0.0 if driver_left else size.x - mw, mw)


func _column_rects(shown: Array[Control]) -> Array[Rect2]:
	if side_by_side:
		return _side_rects(shown)
	var w := minf(column, size.x)
	var x := 0.0 if column_left else size.x - w
	var lead := _lead(shown)
	if lead == null:
		return _stack(shown, x, w, _centred(_stack_height(shown)))
	var rest := shown.duplicate()
	rest.erase(lead)
	if split(shown):
		# Rows: the media card the column's width over the rest side by side, the driver's first,
		# alike in height; the media card takes the height they leave.
		var row_h := _row_height(rest)
		var lead_h := maxf(_lead_row(lead), size.y - row_h - gap)
		var widths := _row_widths(rest, w)
		var out: Array[Rect2] = []
		var cx := x if driver_left else x + w
		for c in shown:
			if c == lead:
				out.append(Rect2(x, 0.0, w, lead_h))
				continue
			var cw: float = widths[rest.find(c)]
			if not driver_left:
				cx -= cw
			out.append(Rect2(cx, lead_h + gap, cw, row_h))
			cx += cw + gap if driver_left else -gap
		return out
	# Stacked: the media card takes the height the rest leave.
	var fill := maxf(_lead_floor(lead, rest), size.y - _stack_height(rest) - gap * float(not rest.is_empty()))
	var out: Array[Rect2] = []
	var y := 0.0
	for c in shown:
		var h: float = fill if c == lead else c.get_combined_minimum_size().y
		out.append(Rect2(x, y, w, h))
		y += h + gap
	return out


func _dashboard_rects(shown: Array[Control]) -> Array[Rect2]:
	if side_by_side:
		return _side_rects(shown)
	var lead := _lead(shown)
	if lead == null:
		var w := minf(maxf(column, size.x * 0.5), size.x)
		return _stack(shown, (size.x - w) / 2.0, w, _centred(_stack_height(shown)))
	var list_w := _list_width(shown, lead)
	var rest := shown.duplicate()
	rest.erase(lead)
	var out := _stack(rest, size.x - list_w if driver_left else 0.0, list_w, _centred(_stack_height(rest)))
	var lead_w := maxf(size.x - list_w - gap, 0.0)
	out.insert(shown.find(lead), Rect2(0.0 if driver_left else list_w + gap, 0.0, lead_w, size.y))
	return out


## In rows the media card keeps the height its cover beside the text needs (`wide_height`), at
## least half; the rest go compact first (`Shell._fit`).
func _lead_row(lead: Control) -> float:
	var want: float = lead.wide_height() if lead.has_method("wide_height") else 0.0
	return maxf(_lead_min(lead), maxf(want, floorf((size.y - gap) / 2.0)))


## The row's widths: each card at least its least, then what it wants (a row's words whole,
## ToggleRow), the rest shared alike.
func _row_widths(cards: Array, w: float) -> Array[float]:
	var least: Array[float] = []
	var more: Array[float] = []
	for c in cards:
		var m: float = ceilf(c.get_combined_minimum_size().x)
		least.append(m)
		more.append(maxf(0.0, c.compact_width(true) + ThemeManager.px.gap * 2.0 - m) if c.has_method("compact_width") else 0.0)
	var spare: float = w - gap * (cards.size() - 1) - _sum(least)
	var k := 1.0 if _sum(more) <= spare else maxf(0.0, spare) / _sum(more)
	var left := maxf(0.0, spare - _sum(more) * k)
	var out: Array[float] = []
	for i in cards.size():
		out.append(floorf(least[i] + more[i] * k + left / cards.size()))
	return out


## Whether the row gives every card what it wants (`_row_widths`).
func row_fits() -> bool:
	var shown := _shown()
	var lead := _lead(shown)
	if lead == null or not split(shown):
		return true
	var rest := shown.duplicate()
	rest.erase(lead)
	var w := minf(column, size.x)
	var want := gap * (rest.size() - 1)
	for c in rest:
		want += maxf(c.get_combined_minimum_size().x, c.compact_width(true) + ThemeManager.px.gap * 2.0 if c.has_method("compact_width") else 0.0)
	return want <= w + 0.5


static func _sum(a: Array[float]) -> float:
	var t := 0.0
	for v in a:
		t += v
	return t


func _row_height(cards: Array) -> float:
	var h := 0.0
	for c in cards:
		h = maxf(h, c.get_combined_minimum_size().y)
	return h


## The dashboard's stacked cards' width: never narrower than the widest of them (large type), so
## none reaches over the media card.
func _list_width(shown: Array[Control], lead: Control) -> float:
	var w := maxf(column, (size.x - gap) * LIST_SHARE)
	for c in shown:
		if c != lead:
			w = maxf(w, c.get_combined_minimum_size().x)
	return minf(w, size.x)


func _centred(h: float) -> float:
	return maxf(0.0, (size.y - h) / 2.0)


func _stack_height(cards: Array) -> float:
	var h := 0.0
	for c in cards:
		h += c.get_combined_minimum_size().y
	return h + gap * maxi(cards.size() - 1, 0)


func _stack(cards: Array, x: float, w: float, y := 0.0) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for c in cards:
		var h: float = c.get_combined_minimum_size().y
		out.append(Rect2(x, y, w, h))
		y += h + gap
	return out


func _shown() -> Array[Control]:
	var out: Array[Control] = []
	for c in get_children():
		if c is Control and c.visible and not c.top_level and not (c == foot and _carried()):
			out.append(c)
	return out


func _carried() -> bool:
	return foot != null and host != null and foot.visible and host.visible and not foot.top_level
