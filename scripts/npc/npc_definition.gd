extends Resource
class_name NpcDefinition
## Data for a world NPC. Lives outside PlayerCharacter and the POI autoload.
## Ready for static, routine, and traveling presence later — behavior hooks stay empty for now.

enum PresenceMode {
	STATIC, ## Stays at a placed transform (default foundation).
	ROUTINE, ## Future: schedule / day cycle at a location.
	TRAVELING, ## Future: moves along the road / between stops.
}

@export var npc_id: String = ""
@export var display_name: String = "NPC"
@export var role: String = "traveler"
@export var enabled: bool = true
@export var presence_mode: PresenceMode = PresenceMode.STATIC
## Single temporary line on interact — no dialogue tree yet.
@export var greeting_line: String = "Boa viagem."


func get_presence_mode_name() -> String:
	match presence_mode:
		PresenceMode.ROUTINE:
			return "ROUTINE"
		PresenceMode.TRAVELING:
			return "TRAVELING"
		_:
			return "STATIC"
