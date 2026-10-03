extends CanvasLayer
class_name DialogueUI
## Placeholder dialogue box. Speaks only to DialogueSystem — no NPC coupling.

@onready var _root: Control = $Root
@onready var _speaker: Label = $Root/Panel/Margin/VBox/SpeakerLabel
@onready var _body: Label = $Root/Panel/Margin/VBox/BodyLabel
@onready var _choices: VBoxContainer = $Root/Panel/Margin/VBox/ChoicesBox
@onready var _hint: Label = $Root/Panel/Margin/VBox/HintLabel

var _system: Node
var _choice_labels: Array[Label] = []


func _ready() -> void:
	layer = 95
	_system = get_node_or_null("/root/DialogueSystem")
	if _system != null:
		if _system.has_signal("line_changed") and not _system.line_changed.is_connected(_on_line_changed):
			_system.line_changed.connect(_on_line_changed)
		if _system.has_signal("choice_selection_changed") and not _system.choice_selection_changed.is_connected(_on_choice_selection_changed):
			_system.choice_selection_changed.connect(_on_choice_selection_changed)
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
	_rebuild_choices()
	_update_hint()
	_root.visible = true


func _on_choice_selection_changed(_index: int) -> void:
	_refresh_choice_highlight()
	_update_hint()


func _rebuild_choices() -> void:
	_clear_choice_labels()
	if _choices == null or _system == null:
		return
	if not _system.has_method("get_available_choices"):
		_choices.visible = false
		return
	var available: Array = _system.call("get_available_choices")
	if available.is_empty():
		_choices.visible = false
		return
	_choices.visible = true
	var selected := int(_system.call("get_choice_index")) if _system.has_method("get_choice_index") else 0
	for i in range(available.size()):
		var choice: Variant = available[i]
		var label := Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 18)
		var prefix := ">" if i == selected else " "
		label.text = "%s %s" % [prefix, str(choice.get("text"))]
		label.add_theme_color_override(
			"font_color",
			Color(0.98, 0.86, 0.42, 1.0) if i == selected else Color(0.78, 0.8, 0.74, 1.0)
		)
		_choices.add_child(label)
		_choice_labels.append(label)


func _refresh_choice_highlight() -> void:
	if _system == null or not _system.has_method("get_available_choices"):
		return
	var available: Array = _system.call("get_available_choices")
	if available.is_empty() or _choice_labels.is_empty():
		return
	var selected := int(_system.call("get_choice_index")) if _system.has_method("get_choice_index") else 0
	for i in range(_choice_labels.size()):
		var label := _choice_labels[i]
		if i >= available.size():
			break
		var prefix := ">" if i == selected else " "
		label.text = "%s %s" % [prefix, str(available[i].get("text"))]
		label.add_theme_color_override(
			"font_color",
			Color(0.98, 0.86, 0.42, 1.0) if i == selected else Color(0.78, 0.8, 0.74, 1.0)
		)


func _update_hint() -> void:
	if _hint == null or _system == null:
		return
	if _system.has_method("has_available_choices") and bool(_system.call("has_available_choices")):
		_hint.text = "↑/↓ — Escolher · Enter / E — Confirmar"
		return
	var def: Resource = _system.call("get_current") if _system.has_method("get_current") else null
	var terminal := true
	if def != null:
		if def.has_method("is_terminal"):
			terminal = bool(def.call("is_terminal"))
		else:
			terminal = str(def.get("next_dialogue_id")).is_empty()
	_hint.text = "Espaço / E — Fechar" if terminal else "Espaço / E — Continuar"


func _on_dialogue_ended(_id: String) -> void:
	_hide_box()


func _on_dialogue_cancelled() -> void:
	_hide_box()


func _clear_choice_labels() -> void:
	_choice_labels.clear()
	if _choices == null:
		return
	for child in _choices.get_children():
		child.queue_free()


func _hide_box() -> void:
	if _root != null:
		_root.visible = false
	if _speaker != null:
		_speaker.text = ""
	if _body != null:
		_body.text = ""
	_clear_choice_labels()
	if _choices != null:
		_choices.visible = false
	if _hint != null:
		_hint.text = ""
