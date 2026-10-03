extends SceneTree
## Hold accelerate (+ optional travel) and detect planar halt while speed stays high.

func _initialize() -> void:
	print("vehicle_halt_repro: init")
	seed(4804)
	var err := change_scene_to_file("res://scenes/test/DrivingSandbox.tscn")
	if err != OK:
		push_error("vehicle_halt_repro: failed to load sandbox (%s)" % err)
		quit(1)
		return
	create_timer(0.5).timeout.connect(_begin)


func _begin() -> void:
	var vehicle: CharacterBody3D = root.find_child("PlayerVehicle", true, false) as CharacterBody3D
	var road: Node = root.find_child("RoadManager", true, false)
	if vehicle == null or road == null:
		push_error("vehicle_halt_repro: missing vehicle/road")
		quit(1)
		return
	if vehicle.has_method("try_unpark"):
		vehicle.call("try_unpark")
	var mode := vehicle.get_node_or_null("DrivingModeController")
	Input.action_press("vehicle_accelerate")
	create_timer(1.5).timeout.connect(func() -> void:
		if mode != null:
			mode.call("set_mode", 2) # TRAVEL_MODE
			print("vehicle_halt_repro: TRAVEL_MODE engaged")
	)
	var state := {
		"vehicle": vehicle,
		"road": road,
		"elapsed": 0.0,
		"prev": vehicle.global_position,
		"halts": 0,
		"roadway_halts": 0,
		"shoulder_halts": 0,
		"other_halts": 0,
		"wall": 0,
		"speed_zero": 0,
		"max_speed": 0.0,
		"max_lat": 0.0,
	}
	var ticker := Timer.new()
	ticker.wait_time = 1.0 / 60.0
	ticker.autostart = true
	root.add_child(ticker)
	ticker.timeout.connect(func() -> void:
		var v: CharacterBody3D = state["vehicle"]
		var r: Node = state["road"]
		var delta := 1.0 / 60.0
		state["elapsed"] = float(state["elapsed"]) + delta
		var speed := float(v.call("get_signed_speed"))
		state["max_speed"] = maxf(float(state["max_speed"]), absf(speed))
		var sample: Dictionary = r.call("sample_road", v.global_position, 8.0) if r.has_method("sample_road") else {}
		var lat := absf(float(sample.get("lateral", 0.0)))
		state["max_lat"] = maxf(float(state["max_lat"]), lat)
		var pos := v.global_position
		var disp := Vector3(pos.x - state["prev"].x, 0.0, pos.z - state["prev"].z).length()
		var expected := absf(speed) * delta
		if absf(speed) >= 4.0 and expected > 0.02 and disp < expected * 0.15:
			state["halts"] = int(state["halts"]) + 1
			var hit_kind := "none"
			var col_info := ""
			for i in range(v.get_slide_collision_count()):
				var c := v.get_slide_collision(i)
				if c == null:
					continue
				var collider = c.get_collider()
				var cname := "?"
				if collider != null:
					cname = str(collider.name)
					var p = collider.get_parent()
					if p != null:
						cname = "%s/%s" % [p.name, collider.name]
						if str(p.name).contains("Shoulder") or str(collider.name).contains("Shoulder"):
							hit_kind = "shoulder"
						elif str(p.name).contains("Roadway") or str(collider.name) == "Roadway":
							hit_kind = "roadway"
				col_info += " | hit=%s n=%s" % [cname, c.get_normal()]
			if hit_kind == "shoulder":
				state["shoulder_halts"] = int(state["shoulder_halts"]) + 1
			elif hit_kind == "roadway":
				state["roadway_halts"] = int(state["roadway_halts"]) + 1
			else:
				state["other_halts"] = int(state["other_halts"]) + 1
			if int(state["halts"]) <= 15:
				print("HALT t=%.2f speed=%.2f disp=%.4f lat=%.2f floor=%s wall=%s kind=%s%s" % [
					float(state["elapsed"]), speed, disp, lat, v.is_on_floor(), v.is_on_wall(), hit_kind, col_info
				])
		if v.is_on_wall():
			state["wall"] = int(state["wall"]) + 1
		if Input.get_action_strength("vehicle_accelerate") > 0.5 and absf(speed) < 0.05 and not bool(v.call("is_parked")) and float(state["elapsed"]) > 1.5:
			state["speed_zero"] = int(state["speed_zero"]) + 1
		state["prev"] = pos
		if float(state["elapsed"]) >= 45.0:
			Input.action_release("vehicle_accelerate")
			if mode != null:
				mode.call("set_mode", 0)
			print("vehicle_halt_repro: done max_speed=%.2f max_lat=%.2f halts=%d shoulder=%d roadway=%d other=%d wall=%d speed_zero=%d" % [
				float(state["max_speed"]), float(state["max_lat"]), int(state["halts"]), int(state["shoulder_halts"]),
				int(state["roadway_halts"]), int(state["other_halts"]), int(state["wall"]), int(state["speed_zero"])
			])
			quit(0 if int(state["halts"]) == 0 and int(state["speed_zero"]) == 0 else 2)
	)
	print("vehicle_halt_repro: accelerating…")
