extends Node
## Runs the shell against livi-core, or the scenario runner with `-- --test <path>`.


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--test"):
		var runner := preload("res://test/runner.gd").new()
		add_child(runner)
		runner.run(args)
		return
	var err: String = Wayland.listen("")
	if err != "":
		push_error("compositor: %s" % err)
	err = Core.connect_core("")
	if err != "":
		push_error("core: %s" % err)
	add_child(preload("res://shell.tscn").instantiate())
