extends Interactable
class_name TestTerminal
## Sandbox interactable — logs a message. Swap mesh later; keep Interactable API.

@export var log_message: String = "TestTerminal: interaction OK"


func _ready() -> void:
	super._ready()
	if interaction_name.is_empty() or interaction_name == "Object":
		interaction_name = "Terminal"
	if interaction_prompt.is_empty() or interaction_prompt == "E — Interagir":
		interaction_prompt = "E — Interagir: Terminal"


func _on_interact(actor: Node) -> void:
	var actor_name := str(actor.name) if actor != null else "unknown"
	var msg := "%s (actor=%s)" % [log_message, actor_name]
	print(msg)
	set_meta("last_interact_message", msg)
	set_meta("interact_count", int(get_meta("interact_count", 0)) + 1)
