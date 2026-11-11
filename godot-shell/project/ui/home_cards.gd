class_name HomeCards
extends Container
## Home's cards. Beside the phone's picture: one column at the panel's edge. With no picture: a
## dashboard over the whole width, the first card a hero where the picture would be and the rest
## stacked beside it. `wide` blends the two, so a change animates with every card keeping its node.

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
## little wider; the hero takes the rest.
const LIST_SHARE := 0.42


func _get_minimum_size() -> Vector2:
	return Vector2(column, lerpf(needed(false), needed(true), wide))


## The height the visible cards need in the column (false) or the dashboard (true).
func needed(dashboard: bool) -> float:
	var shown := _shown()
	var hero: Control = _hero(shown) if dashboard else null
	var h := 0.0
	var n := 0
	for c in shown:
		if c == hero:
			continue
		h += c.get_combined_minimum_size().y
		n += 1
	h += gap * maxi(n - 1, 0)
	return maxf(h, hero.get_combined_minimum_size().y) if hero else h


func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var shown := _shown()
	var a := _column_rects(shown)
	var b := _dashboard_rects(shown)
	for i in shown.size():
		fit_child_in_rect(shown[i], Rect2(a[i].position.lerp(b[i].position, wide), a[i].size.lerp(b[i].size, wide)))


func _column_rects(shown: Array[Control]) -> Array[Rect2]:
	var w := minf(column, size.x)
	return _stack(shown, 0.0 if column_left else size.x - w, w)


func _dashboard_rects(shown: Array[Control]) -> Array[Rect2]:
	var hero := _hero(shown)
	if hero == null:
		return _stack(shown, 0.0, size.x)
	var list_w := minf(maxf(column, (size.x - gap) * LIST_SHARE), size.x)
	var rest := shown.duplicate()
	rest.erase(hero)
	var out := _stack(rest, 0.0 if column_left else size.x - list_w, list_w)
	var hero_w := maxf(size.x - list_w - gap, 0.0)
	out.insert(shown.find(hero), Rect2(list_w + gap if column_left else 0.0, 0.0, hero_w, size.y))
	return out


func _stack(cards: Array, x: float, w: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var y := 0.0
	for c in cards:
		var h: float = c.get_combined_minimum_size().y
		out.append(Rect2(x, y, w, h))
		y += h + gap
	return out


## The first card, while it shows: the others stack beside it.
func _hero(shown: Array[Control]) -> Control:
	return shown[0] if not shown.is_empty() and shown[0] == get_child(0) else null


func _shown() -> Array[Control]:
	var out: Array[Control] = []
	for c in get_children():
		if c is Control and c.visible and not c.top_level:
			out.append(c)
	return out
