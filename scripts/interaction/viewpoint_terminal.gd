extends Area3D
class_name ViewpointTerminal
## Stateful viewpoint console. Duck-types Interactable.
## When linked_quest_id is set, powering ON requires an ACTIVE quest turn-in
## (consume required items via QuestSystem). Otherwise legacy one-shot OFF→ON.

enum PowerState {
	OFF,
	ON,
}

signal state_changed(previous_state: PowerState, current_state: PowerState)
signal interacted(actor: Node)
signal turn_in_failed(reason: String)

@export var interaction_name: String = "Viewpoint Terminal"
@export var interaction_priority: int = 1
@export var enabled: bool = true
## If set, interact attempts QuestSystem.try_turn_in before powering ON.
@export var linked_quest_id: String = "power_the_viewpoint"

@export_group("Feedback (placeholder)")
@export var color_off: Color = Color(0.22, 0.24, 0.28, 1)
@export var color_on: Color = Color(0.95, 0.55, 0.18, 1)
@export var emission_on: Color = Color(1.0, 0.45, 0.12, 1)
@export var light_energy_on: float = 2.4

var _state: PowerState = PowerState.OFF
var _body_mat: StandardMaterial3D
var _screen_mat: StandardMaterial3D
var _light: OmniLight3D
var _status_label: Label3D


func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = true
	_cache_feedback_nodes()
	_apply_visuals()


func get_state() -> PowerState:
	return _state


func get_state_name() -> String:
	match _state:
		PowerState.ON:
			return "ON"
		_:
			return "OFF"


func is_on() -> bool:
	return _state == PowerState.ON


func is_off() -> bool:
	return _state == PowerState.OFF


func get_interaction_name() -> String:
	return interaction_name


func get_interaction_prompt() -> String:
	if _state == PowerState.ON:
		return ""
	if not linked_quest_id.is_empty():
		var qs := _quest_system()
		if qs != null and qs.has_method("is_active") and bool(qs.call("is_active", linked_quest_id)):
			return "E — Ligar: %s" % interaction_name
		if qs != null and qs.has_method("is_completed") and bool(qs.call("is_completed", linked_quest_id)):
			return ""
	return "E — Interagir: %s" % interaction_name


func can_interact(_actor: Node = null) -> bool:
	if not enabled or not is_inside_tree() or not is_visible_in_tree():
		return false
	if _state == PowerState.ON:
		return false
	if linked_quest_id.is_empty():
		return true
	var qs := _quest_system()
	if qs == null:
		return true
	# Allow interact while OFF so the player can attempt turn-in / get feedback.
	if qs.has_method("is_completed") and bool(qs.call("is_completed", linked_quest_id)):
		return false
	return true


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false

	if not linked_quest_id.is_empty():
		var qs := _quest_system()
		if qs == null:
			turn_in_failed.emit("no_quest_system")
			return false
		if qs.has_method("is_completed") and bool(qs.call("is_completed", linked_quest_id)):
			return false
		if qs.has_method("is_active") and not bool(qs.call("is_active", linked_quest_id)):
			turn_in_failed.emit("not_active")
			print("ViewpointTerminal: talk to Mira first (quest inactive)")
			set_meta("last_interact_message", "Talk to Mira first")
			return false
		if qs.has_method("has_required_items") and not bool(qs.call("has_required_items", linked_quest_id)):
			turn_in_failed.emit("missing_items")
			print("ViewpointTerminal: missing scrap/wire for turn-in")
			set_meta("last_interact_message", "Need 3 Scrap Metal + 1 Copper Wire")
			return false
		if not bool(qs.call("try_turn_in", linked_quest_id)):
			turn_in_failed.emit("turn_in_failed")
			print("ViewpointTerminal: turn-in failed")
			return false
		_set_state(PowerState.ON)
		interacted.emit(actor)
		print("ViewpointTerminal: powered ON via quest '%s'" % linked_quest_id)
		set_meta("last_interact_message", "Terminal powered")
		set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
		return true

	# Legacy one-shot (no linked quest).
	_set_state(PowerState.ON)
	interacted.emit(actor)
	print("ViewpointTerminal: powered ON (actor=%s)" % (str(actor.name) if actor else "unknown"))
	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
	return true


## Test helper — does not bypass one-shot rules for normal play.
func force_state(state: PowerState) -> void:
	_set_state(state)


func _quest_system() -> Node:
	return get_node_or_null("/root/QuestSystem")


func _set_state(next: PowerState) -> void:
	if next == _state:
		return
	var previous := _state
	_state = next
	_apply_visuals()
	state_changed.emit(previous, _state)


func _cache_feedback_nodes() -> void:
	var body := get_node_or_null("Model/Body") as MeshInstance3D
	var screen := get_node_or_null("Model/Screen") as MeshInstance3D
	if body != null:
		_body_mat = body.material_override as StandardMaterial3D
		if _body_mat == null:
			_body_mat = StandardMaterial3D.new()
			body.material_override = _body_mat
		else:
			_body_mat = _body_mat.duplicate() as StandardMaterial3D
			body.material_override = _body_mat
	if screen != null:
		_screen_mat = screen.material_override as StandardMaterial3D
		if _screen_mat == null:
			_screen_mat = StandardMaterial3D.new()
			screen.material_override = _screen_mat
		else:
			_screen_mat = _screen_mat.duplicate() as StandardMaterial3D
			screen.material_override = _screen_mat
	_light = get_node_or_null("StatusLight") as OmniLight3D
	_status_label = get_node_or_null("StatusLabel") as Label3D


func _apply_visuals() -> void:
	var on := _state == PowerState.ON
	if _body_mat != null:
		_body_mat.albedo_color = color_on if on else color_off
	if _screen_mat != null:
		_screen_mat.albedo_color = color_on if on else Color(0.12, 0.14, 0.16, 1)
		_screen_mat.emission_enabled = on
		_screen_mat.emission = emission_on
		_screen_mat.emission_energy_multiplier = 3.5 if on else 0.0
	if _light != null:
		_light.light_color = emission_on
		_light.light_energy = light_energy_on if on else 0.0
		_light.visible = on
	if _status_label != null:
		_status_label.text = "ON" if on else "OFF"
		_status_label.modulate = color_on if on else Color(0.65, 0.68, 0.72, 1)
