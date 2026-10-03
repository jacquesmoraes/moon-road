extends CanvasLayer
class_name InteractionPromptUI
## Minimal on-screen prompt for the focused interactable. Hidden when none.

@export var detector_path: NodePath
@export var occupancy_path: NodePath = NodePath("../PlayerOccupancyController")

@onready var _label: Label = $Center/PromptLabel

var _detector: Node
var _occupancy: Node


func _ready() -> void:
	layer = 90
	_resolve()
	_label.visible = false


func _process(_delta: float) -> void:
	if _detector == null or not is_instance_valid(_detector):
		_resolve()
	if _occupancy == null or not is_instance_valid(_occupancy):
		_resolve()

	var on_foot := true
	if _occupancy != null and _occupancy.has_method("is_on_foot"):
		on_foot = bool(_occupancy.call("is_on_foot"))

	if not on_foot or _detector == null:
		_label.visible = false
		return

	var prompt := ""
	if _detector.has_method("has_focus") and bool(_detector.call("has_focus")):
		if _detector.has_method("get_focus_prompt"):
			prompt = str(_detector.call("get_focus_prompt"))

	if prompt.is_empty():
		_label.visible = false
		_label.text = ""
	else:
		_label.visible = true
		_label.text = prompt


func _resolve() -> void:
	if detector_path != NodePath():
		_detector = get_node_or_null(detector_path)
	if _detector == null and get_tree() != null and get_tree().current_scene != null:
		_detector = get_tree().current_scene.find_child("InteractionDetector", true, false)
	if occupancy_path != NodePath():
		_occupancy = get_node_or_null(occupancy_path)
	if _occupancy == null and get_tree() != null and get_tree().current_scene != null:
		_occupancy = get_tree().current_scene.find_child("PlayerOccupancyController", true, false)
