extends Area3D
class_name NpcCharacter
## Reusable placeholder NPC. Duck-types the Interactable API (same detector as terminals).
## Data comes from NpcDefinition — not hardcoded on PlayerCharacter.
## No pathfinding, routines, dialogue trees, or coupling to the POI autoload.

signal interacted(actor: Node)
signal line_spoken(line: String)

@export var definition: NpcDefinition
## Fallback exports when no Resource is assigned (editor convenience / tests).
@export var npc_id: String = ""
@export var display_name: String = "NPC"
@export var role: String = "traveler"
@export var enabled: bool = true
@export var greeting_line: String = "Boa viagem."
@export var interaction_priority: int = 0
@export var line_display_seconds: float = 2.5

var _line_label: Label3D
var _line_timer: Timer
var _name_label: Label3D


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true
	_apply_definition_to_exports()
	_cache_nodes()
	_refresh_name_label()
	_hide_line()


func get_npc_id() -> String:
	_apply_definition_to_exports()
	return npc_id


func get_display_name() -> String:
	_apply_definition_to_exports()
	return display_name


func get_role() -> String:
	_apply_definition_to_exports()
	return role


func is_npc_enabled() -> bool:
	_apply_definition_to_exports()
	return enabled


func get_greeting_line() -> String:
	_apply_definition_to_exports()
	return greeting_line


func get_presence_mode_name() -> String:
	if definition != null and definition.has_method("get_presence_mode_name"):
		return str(definition.call("get_presence_mode_name"))
	return "STATIC"


func get_interaction_name() -> String:
	return get_display_name()


func get_interaction_prompt() -> String:
	return "E — Falar: %s" % get_display_name()


func can_interact(_actor: Node = null) -> bool:
	if not is_npc_enabled() or not is_inside_tree() or not is_visible_in_tree():
		return false
	return true


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false
	var line := get_greeting_line()
	if line.is_empty():
		line = "..."
	_show_line(line)
	var actor_name := str(actor.name) if actor != null else "unknown"
	var msg := "Npc %s (%s): \"%s\" (actor=%s)" % [get_display_name(), get_role(), line, actor_name]
	print(msg)
	set_meta("last_interact_message", msg)
	set_meta("last_spoken_line", line)
	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
	line_spoken.emit(line)
	interacted.emit(actor)
	return true


func get_last_spoken_line() -> String:
	return str(get_meta("last_spoken_line", ""))


func is_line_visible() -> bool:
	return _line_label != null and _line_label.visible


func _apply_definition_to_exports() -> void:
	if definition == null:
		return
	if not definition.npc_id.is_empty():
		npc_id = definition.npc_id
	if not definition.display_name.is_empty():
		display_name = definition.display_name
	if not definition.role.is_empty():
		role = definition.role
	enabled = definition.enabled
	if not definition.greeting_line.is_empty():
		greeting_line = definition.greeting_line


func _cache_nodes() -> void:
	_line_label = get_node_or_null("SpeechLabel") as Label3D
	_name_label = get_node_or_null("NameLabel") as Label3D
	_line_timer = get_node_or_null("SpeechTimer") as Timer
	if _line_timer == null:
		_line_timer = Timer.new()
		_line_timer.name = "SpeechTimer"
		_line_timer.one_shot = true
		add_child(_line_timer)
	if not _line_timer.timeout.is_connected(_hide_line):
		_line_timer.timeout.connect(_hide_line)


func _refresh_name_label() -> void:
	if _name_label == null:
		return
	_name_label.text = get_display_name()


func _show_line(line: String) -> void:
	_cache_nodes()
	if _line_label != null:
		_line_label.text = line
		_line_label.visible = true
	if _line_timer != null:
		_line_timer.stop()
		_line_timer.wait_time = maxf(line_display_seconds, 0.2)
		_line_timer.start()


func _hide_line() -> void:
	if _line_label != null:
		_line_label.visible = false
		_line_label.text = ""
