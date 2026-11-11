extends Control

var _out := ""


func _ready() -> void:
	_out = OS.get_cmdline_user_args()[0] if not OS.get_cmdline_user_args().is_empty() else ""
	var e := LineEdit.new()
	e.name = "Field"
	e.position = Vector2.ZERO
	e.size = Vector2(400, 48)
	e.text_changed.connect(func(t: String) -> void: _log("entry " + t))
	e.text_submitted.connect(func(t: String) -> void: _log("activate " + t))
	add_child(e)


func _log(line: String) -> void:
	if _out == "":
		return
	var f := FileAccess.open(_out, FileAccess.READ_WRITE if FileAccess.file_exists(_out) else FileAccess.WRITE)
	f.seek_end()
	f.store_line(line)
