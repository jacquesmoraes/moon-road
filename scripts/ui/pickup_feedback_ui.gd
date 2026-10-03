extends CanvasLayer
class_name PickupFeedbackUI
## Debug toast for world pickups ("+1 Scrap Metal"). Listens via group pickup_feedback.

@onready var _label: Label = $Center/ToastLabel
@onready var _timer: Timer = $HideTimer

var _queue: PackedStringArray = []


func _ready() -> void:
	layer = 93
	add_to_group("pickup_feedback")
	if _label != null:
		_label.visible = false
		_label.text = ""
	if _timer != null and not _timer.timeout.is_connected(_on_timeout):
		_timer.timeout.connect(_on_timeout)


func show_pickup_message(message: String) -> void:
	if message.is_empty():
		return
	_queue.append(message)
	if _timer != null and _timer.is_stopped():
		_show_next()


func _show_next() -> void:
	if _queue.is_empty():
		if _label != null:
			_label.visible = false
			_label.text = ""
		return
	var msg := _queue[0]
	_queue.remove_at(0)
	if _label != null:
		_label.text = msg
		_label.visible = true
	if _timer != null:
		_timer.start()


func _on_timeout() -> void:
	_show_next()
