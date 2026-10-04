extends Resource
class_name NpcScheduleCatalog
## Flat registry of NpcScheduleData. One active schedule per npc_id for now.

@export var schedules: Array = [] ## Array of NpcScheduleData
