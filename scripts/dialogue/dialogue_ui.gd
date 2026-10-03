extends CanvasLayer
class_name DialogueUI
## Placeholder dialogue box. Speaks only to DialogueSystem — no NPC coupling.

@onready var _root: Control = $Root
@onready var _speaker: Label = $Root/Panel/Margin/VBox/SpeakerLabel
@onready var _body: Label = $Root/Panel/Margin/VBox/BodyLabel
@onready var _hint: Label = $Root/Panel/Margin/VBox/HintLabel

var _system: Node


func _ready() -> void:
	layer = 95
	_system = get_node_or_null("/root/DialogueSystem")
	if _system != null:
		if _system.has_signal("line_changed") and not _system.line_changed.is_connected(_on_line_changed):
			_system.line_changed.connect(_on_line_changed)
		if _system.has_signal("dialogue_finished") and not _system.dialogue_finished.is_connected(_on_dialogue_ended):
			_system.dialogue_finished.connect(_on_dialogue_ended)
		if _system.has_signal("dialogue_cancelled") and not _system.dialogue_cancelled.is_connected(_on_dialogue_cancelled):
			_system.dialogue_cancelled.connect(_on_dialogue_cancelled)
	_hide_box()


func _process(_delta: float) -> void:
	if _system == null:
		_system = get_node_or_null("/root/DialogueSystem")
		return
	if not bool(_system.call("is_active")):
		if _root != null and _root.visible:
			_hide_box()


func _on_line_changed(def: Resource) -> void:
	if def == null:
		_hide_box()
		return
	_speaker.text = str(def.get("speaker_name"))
	_body.text = str(def.get("text"))
	var terminal := true
	if def.has_method("is_terminal"):
		terminal = bool(def.call("is_terminal"))
	else:
		terminal = str(def.get("next_dialogue_id")).is_empty()
	_hint.text = "Espaço / E — Fechar" if terminal else "Espaço / E — Continuar"
	_root.visible = true


func _on_dialogue_ended(_id: String) -> void:
	_hide_box()


func _on_dialogue_cancelled() -> void:
	_hide_box()


func _hide_box() -> void:
	if _root != null:
		_root.visible = false
	if _speaker != null:
		_speaker.text = ""
	if _body != null:
		_body.text = ""
