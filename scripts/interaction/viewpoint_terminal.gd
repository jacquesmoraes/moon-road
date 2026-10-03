extends Area3D
class_name ViewpointTerminal
## Stateful viewpoint console. Starts OFF; first interact turns ON (one-shot).
## State lives on the instance while the viewpoint scene is loaded — no disk save.
## Duck-types the Interactable API; no coupling to PlayerCharacter.

enum PowerState {
	OFF,
	ON,
}

signal state_changed(previous_state: PowerState, current_state: PowerState)
signal interacted(actor: Node)

@export var interaction_name: String = "Viewpoint Terminal"
@export var interaction_priority: int = 1
@export var enabled: bool = true

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
	## One-shot: only prompt while OFF.
	if _state == PowerState.ON:
		return ""
	return "E — Interagir: %s" % interaction_name


func can_interact(_actor: Node = null) -> bool:
	if not enabled or not is_inside_tree() or not is_visible_in_tree():
		return false
	# One-shot ON — no further interacts after activation.
	return _state == PowerState.OFF


func interact(actor: Node = null) -> bool:
	if not can_interact(actor):
		return false
	_set_state(PowerState.ON)
	interacted.emit(actor)
	print("ViewpointTerminal: powered ON (actor=%s)" % (str(actor.name) if actor else "unknown"))
	return true


## Test helper — does not bypass one-shot rules for normal play.
func force_state(state: PowerState) -> void:
	_set_state(state)


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
