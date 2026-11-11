class_name HomeCards
extends Container
## Home's cards. The media card (`tall`), while something plays, leads: it gets the large slot
## and every other card keeps its own height. Beside the phone's picture, one column at the
## panel's edge: split in two where it has room (the media card full height on the outer edge,
## the rest stacked beside it), else stacked with the media card filling the height the rest
## leaves, never shorter than the tallest of them. With no picture, a dashboard over the whole
## width: the media card where the picture would be, the rest stacked beside it, centred. With
## nothing playing, the cards stack at their own heights, centred. `wide` blends the column and
## the dashboard, so a change animates with every card keeping its node.

## 0 the column, 1 the dashboard.
var wide := 0.0:
	set(v):
		wide = v
		update_minimum_size()
		queue_sort()
## The column's width; the column keeps to the left edge or the right, away from the picture.
var column := 600.0
var column_left := false
var gap := 16.0
## The dashboard's share of the width for the stacked cards: they keep their column look, a
## little wider; the media card takes the rest.
const LIST_SHARE := 0.42
## Beside the phone, a column with room for two splits: `tall` gets TALL_SHARE of it, full
## height, on the outer edge, at least TALL_TOUCH touch targets wide; the rest stack in the
## other, at least REST_TOUCH wide (a card's title on one line).
const TALL_SHARE := 0.36
const TALL_TOUCH := 5.5
const REST_TOUCH := 10.0
## The media card; it leads while it has content (`has_content()`).
var tall: Control


func _get_minimum_size() -> Vector2:
	return Vector2(column, lerpf(needed(false), needed(true), wide))


## The height the visible cards need in the column (false) or the dashboard (true).
func needed(dashboard: bool) -> float:
	var shown := _shown()
	var lead := _lead(shown)
	if lead == null:
		return _stack_height(shown)
	var rest := shown.duplicate()
	rest.erase(lead)
	if dashboard or split(shown):
		return maxf(_stack_height(rest), _lead_min(lead))
	return _stack_height(rest) + gap * float(not rest.is_empty()) + _lead_floor(lead, rest)


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var shown := _shown()
	var a := _column_rects(shown)
	var b := _dashboard_rects(shown)
	for i in shown.size():
		fit_child_in_rect(shown[i], Rect2(a[i].position.lerp(b[i].position, wide), a[i].size.lerp(b[i].size, wide)))


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
		var tall_w := roundf((w - gap) * TALL_SHARE)
		col = tall_w if c == lead else w - gap - tall_w
	var dash := minf(maxf(column, size.x * 0.5), size.x)
	if lead != null:
		var list_w := minf(maxf(column, (size.x - gap) * LIST_SHARE), size.x)
		dash = maxf(size.x - list_w - gap, 0.0) if c == lead else list_w
	return lerpf(col, dash, wide)


## Whether the column splits in two with `shown`: the media card leading, wide enough.
func split(shown: Array[Control]) -> bool:
	if _lead(shown) == null or shown.size() < 2:
		return false
	var w := minf(column, size.x) - gap
	return w * TALL_SHARE >= ThemeManager.px.touch * TALL_TOUCH and w * (1.0 - TALL_SHARE) >= ThemeManager.px.touch * REST_TOUCH


func _lead(shown: Array[Control]) -> Control:
	return tall if tall != null and tall in shown and tall.has_method("has_content") and tall.has_content() else null


## What the media card needs whatever room it gets: it lays itself out large only in room that
## holds it (`compact_height`), so its present layout, chosen for the last room, does not count.
func _lead_min(lead: Control) -> float:
	return lead.compact_height() if lead.has_method("compact_height") else lead.get_combined_minimum_size().y


## The media card in a stack is never shorter than the tallest other card.
func _lead_floor(lead: Control, rest: Array) -> float:
	var h: float = _lead_min(lead)
	for c in rest:
		h = maxf(h, c.get_combined_minimum_size().y)
	return h


func _with(c: Control) -> Array[Control]:
	var shown := _shown()
	if not c in shown:
		# Where it would be among its siblings.
		shown.clear()
		for ch in get_children():
			if ch is Control and (ch == c or (ch.visible and not ch.top_level)):
				shown.append(ch)
	return shown


func _column_rects(shown: Array[Control]) -> Array[Rect2]:
	var w := minf(column, size.x)
	var x := 0.0 if column_left else size.x - w
	var lead := _lead(shown)
	if lead == null:
		return _stack(shown, x, w, _centred(_stack_height(shown)))
	var rest := shown.duplicate()
	rest.erase(lead)
	if split(shown):
		var tall_w := roundf((w - gap) * TALL_SHARE)
		var rest_w := w - gap - tall_w
		var out := _stack(rest, x + tall_w + gap if column_left else x, rest_w, _centred(_stack_height(rest)))
		out.insert(shown.find(lead), Rect2(x if column_left else x + rest_w + gap, 0.0, tall_w, size.y))
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
	var lead := _lead(shown)
	if lead == null:
		var w := minf(maxf(column, size.x * 0.5), size.x)
		return _stack(shown, (size.x - w) / 2.0, w, _centred(_stack_height(shown)))
	var list_w := minf(maxf(column, (size.x - gap) * LIST_SHARE), size.x)
	var rest := shown.duplicate()
	rest.erase(lead)
	var out := _stack(rest, 0.0 if column_left else size.x - list_w, list_w, _centred(_stack_height(rest)))
	var lead_w := maxf(size.x - list_w - gap, 0.0)
	out.insert(shown.find(lead), Rect2(list_w + gap if column_left else 0.0, 0.0, lead_w, size.y))
	return out


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
		if c is Control and c.visible and not c.top_level:
			out.append(c)
	return out
