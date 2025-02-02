extends Spatial

onready var camera := $Camera as EditorCamera
var editor_directory: String = ""

var selected_object: Node = null
var selected_object_type: String = ""

var rail_res: PackedScene = preload("res://Data/Modules/Rail.tscn")

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	load_world()
	yield(get_tree(), "idle_frame")
	save_world(false)  # yes, really, gras sometimes breaks if we don't *sigh*


var bouncing_timer: float = 0
var one_second_timer: float = 0
func _process(delta):
	one_second_timer += delta
	if one_second_timer > 1:
		one_second_timer = 0
		load_chunks_near_camera()


func _enter_tree() -> void:
	Root.Editor = true


func _exit_tree() -> void:
	Root.Editor = false


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == BUTTON_LEFT and mb.pressed:
		select_object_under_mouse()

	if Input.is_action_just_pressed("save"):
		save_world()

	if Input.is_action_just_pressed("delete"):
		delete_selected_object()

	if Input.is_action_just_pressed("ui_accept") and $EditorHUD/Message.visible:
		_on_MessageClose_pressed()


func _input(event) -> void:
	if event is InputEventMouseButton and not event.pressed and drag_mode:
		end_drag_mode()

	if event is InputEventMouseMotion and drag_mode:
		handle_drag_mode()


var drag_mode: bool = false
func begin_drag_mode() -> void:
	drag_mode = true
	#print("DRAG MODE START")


func end_drag_mode() -> void:
	drag_mode = false
	#print("DRAG MODE END")


var _last_connected_signal: String = ""
func handle_drag_mode() -> void:
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var plane := Plane(Vector3(0,1,0), selected_object.startpos.y)
	var mouse_pos_3d: Vector3 = plane.intersects_ray(camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
	if mouse_pos_3d != null:
		selected_object.calculate_from_start_end(mouse_pos_3d)  # update rail
		provide_settings_for_selected_object()  # update ui

	# wait for update of overlapping areas, else we can never un-snap
	# yes, this really needs idle_frame, won't work otherwise
	yield(get_tree(), "idle_frame")

	# lazy snapping done via collision areas
	var snapped_object: Node = null
	var snapped_start: bool = false
	var overlaps: Array = selected_object.get_node("Ending").get_overlapping_areas()
	if not overlaps.empty():
		for area in overlaps:
			if get_type_of_object(area.get_parent()) == "Rail" and area.get_parent() != selected_object:
				selected_object.calculate_from_start_end(area.global_transform.origin)
				snapped_object = area.get_parent()
				snapped_start = (area.name == "Beginning")
				break

	# multi-segment snapping (subdivide rail to make angles fit together)
	if snapped_object != null:
		var startrot: float = selected_object.startrot
		var endrot: float = selected_object.endrot
		var snap_rot: float
		var snap_pos: Vector3
		if snapped_start:
			snap_rot = snapped_object.startrot
			snap_pos = snapped_object.startpos
		else:
			snap_rot = snapped_object.endrot
			snap_pos = snapped_object.endpos

		if Math.angle_distance_deg(endrot, snap_rot) < 1:
			# angles snapped correctly, we can leave this as is :)
			pass
		elif Math.angle_distance_deg(startrot, snap_rot) < 1:
			if _local_x_distance(startrot, selected_object.startpos, snap_pos) < 20:
				return
			if not $EditorHUD/SnapDialog.is_connected("confirmed", self, "_snap_simple_connector"):
				$EditorHUD/SnapDialog.dialog_text = tr("EDITOR_SNAP_CONNECTOR")
				$EditorHUD/SnapDialog.popup_centered()
				_last_connected_signal = "_snap_simple_connector"
				$EditorHUD/SnapDialog.connect("confirmed", self, "_snap_simple_connector", [snap_pos, snap_rot], CONNECT_ONESHOT)
		elif abs(Math.angle_distance_deg(startrot, snap_rot) - 90) < 1:
			# right angle, can be done with straight rail + 90deg curve
			if not $EditorHUD/SnapDialog.is_connected("confirmed", self, "_snap_90deg_connector"):
				$EditorHUD/SnapDialog.dialog_text = tr("EDITOR_SNAP_CONNECTOR")
				$EditorHUD/SnapDialog.popup_centered()
				_last_connected_signal = "_snap_90deg_connector"
				$EditorHUD/SnapDialog.connect("confirmed", self, "_snap_90deg_connector", [snap_pos, snap_rot], CONNECT_ONESHOT)
		else:
			# complicated snapping I don't know how to do yet
			if not $EditorHUD/SnapDialog.is_connected("confirmed", self, "_snap_complex_connector"):
				$EditorHUD/SnapDialog.dialog_text = tr("EDITOR_SNAP_CONNECTOR_TODO")
				$EditorHUD/SnapDialog.popup_centered()
				_last_connected_signal = "_snap_complex_connector"
				$EditorHUD/SnapDialog.connect("confirmed", self, "_snap_complex_connector", [snap_pos, snap_rot], CONNECT_ONESHOT)
	else:
		if _last_connected_signal != "" and $EditorHUD/SnapDialog.is_connected("confirmed", self, _last_connected_signal):
			$EditorHUD/SnapDialog.disconnect("confirmed", self, _last_connected_signal)
		$EditorHUD/SnapDialog.hide()


func _local_x_distance(rot: float, a: Vector3, b: Vector3) -> float:
	var dir := Vector3(1,0,0).rotated(Vector3.UP, deg2rad(rot)).normalized()
	return dir.dot(b - a)


func _local_z_distance(rot: float, a: Vector3, b: Vector3) -> float:
	var dir := Vector3(0,0,1).rotated(Vector3.UP, deg2rad(rot)).normalized()
	return dir.dot(b - a)


func _snap_90deg_connector(snap_pos: Vector3, snap_rot: float) -> void:
	var startpos: Vector3 = selected_object.startpos
	var startrot: float = selected_object.startrot

	var start_dir := Vector3(1,0,0).rotated(Vector3.UP, deg2rad(selected_object.startrot)).normalized()
	var ortho_dir := Vector3(0,0,1).rotated(Vector3.UP, deg2rad(selected_object.startrot)).normalized()

	var x_length: float = abs(start_dir.dot(snap_pos - startpos))
	var y_length: float = ortho_dir.dot(snap_pos - startpos)
	var y_sign: float = sign(y_length)
	y_length = abs(y_length)

	if abs(x_length - y_length) < 1:
		var new_end: Vector3 = startpos + Vector3(x_length, 0, y_sign * y_length).rotated(Vector3.UP, deg2rad(startrot))
		selected_object.calculate_from_start_end(new_end)

	elif x_length > y_length:
		selected_object.radius = 0
		selected_object.length = x_length - y_length
		selected_object.update()

		var rail2: Node = _spawn_rail()
		rail2.translation = selected_object.endpos
		rail2.startpos = selected_object.endpos
		rail2.rotation_degrees.y = selected_object.endrot
		rail2.startrot = selected_object.endrot
		var new_end = rail2.startpos + Vector3(y_length, 0, y_sign * y_length).rotated(Vector3.UP, deg2rad(startrot))
		rail2.calculate_from_start_end(new_end)

	else:
		var new_end: Vector3 = startpos + Vector3(x_length, 0, y_sign * x_length).rotated(Vector3.UP, deg2rad(startrot))
		selected_object.calculate_from_start_end(new_end)

		var rail2: Node = _spawn_rail()
		rail2.translation = selected_object.endpos
		rail2.startpos = selected_object.endpos
		rail2.rotation_degrees.y = selected_object.endrot
		rail2.startrot = selected_object.endrot
		rail2.radius = 0
		rail2.length = y_length - x_length
		rail2.update()


func _snap_simple_connector(snap_pos: Vector3, snap_rot: float) -> void:
	# can easily connect with 2 segments
	# this is basically the old rail connector for switches
	var rail1_end: Vector3 = 0.5 * (selected_object.startpos + snap_pos)
	selected_object.calculate_from_start_end(rail1_end)

	var rail2: Node = _spawn_rail()
	rail2.translation = rail1_end
	rail2.startpos = rail1_end
	rail2.rotation_degrees.y = selected_object.endrot
	rail2.startrot = selected_object.endrot
	rail2.calculate_from_start_end(snap_pos)

	assert(Math.angle_distance_deg(rail2.endrot, snap_rot) < 1)

	drag_mode = false


func _snap_complex_connector(snap_pos: Vector3, snap_rot: float) -> void:
	# TODO: I don't know how to do it yet
	pass


func select_object_under_mouse() -> void:
	var ray_length: float = 1000
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var to: Vector3 = from + camera.project_ray_normal(mouse_pos) * ray_length

	var space_state = get_world().get_direct_space_state()
	# use global coordinates, not local to node
	var result = space_state.intersect_ray(from, to, [  ], 0x7FFFFFFF, true, true)
	if result.has("collider"):
		var obj_to_select = result["collider"].get_parent()

		if get_type_of_object(obj_to_select) == "Rail" and result.collider.name == "Ending":
			begin_drag_mode()

		set_selected_object(obj_to_select)
		provide_settings_for_selected_object()
		Logger.vlog("selected!")


func clear_selected_object() -> void:
	# Reset scale of current object because of editor "bouncing"
	if is_instance_valid(selected_object):
		var vis = get_children_of_type_recursive(selected_object, VisualInstance)
		for vi in vis:
			vi.set_layer_mask_bit(1, false)

		if selected_object_type == "Building":
			selected_object.scale = Vector3(1,1,1)
			selected_object.get_node("SelectCollider").show()
			selected_object.get_child(1).queue_free()
			$EditorHUD.hide_current_object_transform()
		if selected_object_type == "Rail":
			selected_object.get_node("Ending").scale = Vector3(1,1,1)
			selected_object.get_node("Mid").scale = Vector3(1,1,1)
			selected_object.get_node("Beginning").scale = Vector3(1,1,1)
			$EditorHUD.hide_current_object_transform()
			for child in selected_object.get_children():
				if child.is_in_group("Gizmo"):
					child.queue_free()
		if selected_object_type == "Signal":
			selected_object.scale = Vector3(1,1,1)

	selected_object = null
	selected_object_type = ""
	$EditorHUD.clear_current_object_name()


func get_type_of_object(object: Node) -> String:
	if object is MeshInstance:
		return "Building"
	if object.is_in_group("Rail"):
		return "Rail"
	if object.is_in_group("Signal"):
		return "Signal"
	else:
		return "Unknown"


func provide_settings_for_selected_object() -> void:
	if selected_object_type == "Rail":
		$EditorHUD/Settings/TabContainer/RailAttachments.update_selected_rail(selected_object)
		$EditorHUD/Settings/TabContainer/RailBuilder.update_selected_rail(selected_object)
		$EditorHUD.ensure_rail_settings()
	else:
		$EditorHUD/Settings/TabContainer/RailAttachments.update_selected_rail(null)
		$EditorHUD/Settings/TabContainer/RailBuilder.update_selected_rail(null)
	if selected_object_type == "Building":
		$EditorHUD/Settings/TabContainer/BuildingSettings.set_mesh(selected_object)
		$EditorHUD.show_building_settings()
	if selected_object_type == "Signal":
		$EditorHUD/Settings/TabContainer/RailLogic.set_rail_logic(selected_object)
		$EditorHUD.show_signal_settings()
	$EditorHUD.update_ShowSettingsButton()


## Should be used, if world is loaded into scene.
func load_world() -> void:
	editor_directory = jSaveManager.get_setting("editor_directory_path")
	var path = editor_directory + "Worlds/" + Root.current_editor_track + "/" + Root.current_editor_track + ".tscn"
	var world_resource: PackedScene = load(path)
	if world_resource == null:
		send_message("World data could not be loaded! Is your .tscn file corrupt?\nIs every resource available?")
		return

	var world: Node = world_resource.instance()
	world.owner = self
	world.FileName = Root.current_editor_track
	world.get_node("jSaveModule").save_path = path.get_basename() + ".save"
	add_child(world)

	$EditorHUD/Settings/TabContainer/RailBuilder.world = $World
	$EditorHUD/Settings/TabContainer/RailAttachments.world = $World
	$EditorHUD/Settings/TabContainer/Configuration.world = $World

	## Load Camera Position
	var last_editor_camera_transforms = jSaveManager.get_value("last_editor_camera_transforms", {})
	if last_editor_camera_transforms.has(Root.current_editor_track):
		camera.load_from_transform(last_editor_camera_transforms[Root.current_editor_track])

	## Add Colliding Boxes to Buildings:
	for building in $World/Buildings.get_children():
		building.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	for signal_ins in $World/Signals.get_children():
#		if signal_ins.type == "Signal":
		signal_ins.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())

	Root.fix_frame_drop()


func save_world(send_message: bool = true) -> void:
	## Save Camera Position
	var last_editor_camera_transforms: Dictionary = jSaveManager.get_value("last_editor_camera_transforms", {})
	last_editor_camera_transforms[Root.current_editor_track] = camera.transform
	jSaveManager.save_value("last_editor_camera_transforms", last_editor_camera_transforms)

	$World.unload_and_save_all_chunks()

	jEssentials.call_delayed(0.1, self, "save_world_step_2", [send_message])


func save_world_step_2(send_message: bool = true) -> void:
	var packed_scene = PackedScene.new()
	var result = packed_scene.pack($World)
	if result == OK:
		var error = ResourceSaver.save(editor_directory + "Worlds/" + Root.current_editor_track + "/" + Root.current_editor_track + ".tscn", packed_scene)
		if error != OK:
			send_message("An error occurred while saving the scene to disk.")
			return

	$EditorHUD/Settings/TabContainer/Configuration.save_everything()
	$World/jSaveModule.write_to_disk()
	$World/jSaveModuleScenarios.write_to_disk()

	ist_chunks.clear()

#	$World.force_load_all_chunks()
	if send_message:
		send_message("World successfully saved!")


func _on_SaveWorldButton_pressed() -> void:
	save_world()


func rename_selected_object(new_name: String) -> void:
	Root.name_node_appropriate(selected_object, new_name, selected_object.get_parent())
	$EditorHUD.set_current_object_name(selected_object.name)
	provide_settings_for_selected_object()


func delete_selected_object() -> void:
	selected_object.queue_free()
	clear_selected_object()


func get_rail(name: String) -> Node:
	return $World/Rails.get_node_or_null(name)


func set_selected_object(object: Node) -> void:
	clear_selected_object()

	var vis = get_children_of_type_recursive(object, VisualInstance)
	for vi in vis:
		vi.set_layer_mask_bit(1, true)

	selected_object = object
	$EditorHUD.set_current_object_name(selected_object.name)
	selected_object_type = get_type_of_object(selected_object)

	if selected_object_type == "Building":
		selected_object.get_node("SelectCollider").hide()
		selected_object.add_child(preload("res://Editor/Modules/Gizmo.tscn").instance())
		$EditorHUD.show_current_object_transform()
	if selected_object_type == "Rail":
		if selected_object.manualMoving:
			selected_object.add_child(preload("res://Editor/Modules/Gizmo.tscn").instance())
			$EditorHUD.show_current_object_transform()

	provide_settings_for_selected_object()


func _spawn_rail() -> Node:
	var rail_instance: Node = rail_res.instance()
	rail_instance.name = Root.name_node_appropriate(rail_instance, "Rail", $World/Rails)
	$World/Rails.add_child(rail_instance)
	rail_instance.set_owner($World)
	#rail_instance._update()

	if rail_instance.overheadLine:
		_spawn_poles_for_rail(rail_instance)

	return rail_instance


func _spawn_poles_for_rail(rail: Node) -> void:
	var track_object = preload("res://Data/Modules/TrackObjects.tscn").instance()
	track_object.sides = 2
	track_object.rows = 1
	track_object.wholeRail = true
	track_object.placeLast = true
	track_object.objectPath = "res://Resources/Objects/Pole1.obj"
	track_object.materialPaths = [ "res://Resources/Materials/Beton.tres", "res://Resources/Materials/Metal_Green.tres", "res://Resources/Materials/Metal.tres", "res://Resources/Materials/Metal_Brown.tres" ]
	track_object.attached_rail = rail.name
	track_object.length = rail.length
	track_object.distanceLength = 50
	track_object.rotationObjects = -90.0
	track_object.name = rail.name + " Poles"
	track_object.description = "Poles"

	rail.trackObjects.append(track_object)

	$World/TrackObjects.add_child(track_object)
	track_object.set_owner($World/TrackObjects)

	track_object.update(rail)
	rail.update()


func add_rail() -> void:
	var rail_instance: Node = _spawn_rail()
	rail_instance.translation = get_current_ground_position()
	set_selected_object(rail_instance)


func get_current_ground_position() -> Vector3:
	var position: Vector3 = camera.translation
	position.y = $World.get_terrain_height_at(Vector2(position.x, position.z))
	return position


func add_object(complete_path: String) -> void:
	var position: Vector3 = get_current_ground_position()
	var obj_res: Mesh = load(complete_path)
	var mesh_instance := MeshInstance.new()
	mesh_instance.mesh = obj_res
	var mesh_name: String = complete_path.get_file().get_basename() + "_"
	mesh_instance.name = Root.name_node_appropriate(mesh_instance, mesh_name, $World/Buildings)
	mesh_instance.translation = position
	$World/Buildings.add_child(mesh_instance)
	mesh_instance.set_owner($World)
	mesh_instance.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	set_selected_object(mesh_instance)


func test_track_pck() -> void:
	save_world()
	var dir := Directory.new()
	dir.make_dir_recursive(editor_directory + "/.cache/")
	var pck_path: String = editor_directory + "/.cache/" + Root.current_editor_track + ".pck"
	var packer := PCKPacker.new()
	packer.pck_start(pck_path)

	packer.add_file("res://Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".tscn", editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".tscn")
	packer.add_file("res://Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".save", editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".save")
	packer.add_file("res://Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+"-scenarios.cfg", editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+"-scenarios.cfg")
	packer.flush()

	if ProjectSettings.load_resource_pack(pck_path, true):
		Logger.log("Loading Content Pack "+ pck_path+" successfully finished")
	Root.start_menu_in_play_menu = true
	LoadingScreen.load_main_menu()


func export_track_pck(export_path: String) -> void:
	var track_name: String = Root.current_editor_track
	export_path += "/" + track_name + ".pck"
	var packer := PCKPacker.new()
	packer.pck_start(export_path)

	## Handle dependencies
	var dependencies_raw: Array = ResourceLoader.get_dependencies(editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".tscn")

	$World/jSaveModuleScenarios.set_save_path(editor_directory + "/Worlds/" + track_name + "/" + track_name + "-scenarios.cfg")
	var scenario_data : Dictionary = $World/jSaveModuleScenarios.get_value("scenario_data")
	for scenario in scenario_data.keys():
		for train in scenario_data[scenario]["Trains"].keys():
			if not scenario_data[scenario]["Trains"][train]["Stations"].has("approachAnnouncePath"):
				continue
			for path in scenario_data[scenario]["Trains"][train]["Stations"]["approachAnnouncePath"]:
				dependencies_raw.append(path)
			for path in scenario_data[scenario]["Trains"][train]["Stations"]["arrivalAnnouncePath"]:
				dependencies_raw.append(path)
			for path in scenario_data[scenario]["Trains"][train]["Stations"]["departureAnnouncePath"]:
				dependencies_raw.append(path)
	dependencies_raw = jEssentials.remove_duplicates(dependencies_raw)

	# Get all dependencies of track objects, buildings, etc..
	for chunk in $World.get_all_chunks():
		var chunk_data = $World/jSaveModule.get_value($World.chunk2String(chunk))
		for building_key in chunk_data["Buildings"].keys():
			dependencies_raw.append(chunk_data["Buildings"][building_key]["mesh_path"])
			dependencies_raw.append_array(chunk_data["Buildings"][building_key]["surfaceArr"])
		for track_object_key in chunk_data["TrackObjects"].keys():
			dependencies_raw.append(chunk_data["TrackObjects"][track_object_key]["data"]["objectPath"])
			dependencies_raw.append_array(chunk_data["TrackObjects"][track_object_key]["data"]["materialPaths"])
	dependencies_raw = jEssentials.remove_duplicates(dependencies_raw)
	for rail_node in $World/Rails.get_children():
		dependencies_raw.append(rail_node.railTypePath)
	for signal_node in $World/Signals.get_children():
		if signal_node.type == "Signal":
			dependencies_raw.append(signal_node.visualInstancePath)
	dependencies_raw = jEssentials.remove_duplicates(dependencies_raw)

	## Convert some resources to resource pathes
	for dependence in dependencies_raw:
		if not dependence is String:
			dependencies_raw.append(dependence.resource_path)
			dependencies_raw.erase(dependence)

	## Get dependencies of dependencies:
	for dependence in dependencies_raw:
		if not dependence is String:
			dependencies_raw.append_array(ResourceLoader.get_dependencies(dependence.resource_path))
			continue
		dependencies_raw.append_array(ResourceLoader.get_dependencies(dependence))
	dependencies_raw = jEssentials.remove_duplicates(dependencies_raw)

	## Get import files with resource pathes:
	for dependence in dependencies_raw:
		if not dependence is String:
			continue
		if dependence.ends_with("obj") or dependence.ends_with("png") or dependence.ends_with("ogg"):
			var dependence_import_file = dependence + ".import"
			dependencies_raw.append_array(get_imported_cache_file_path_of_import_file(dependence_import_file))
			dependencies_raw.append(dependence_import_file)
#			dependencies_raw.erase(dependence)
	dependencies_raw = jEssentials.remove_duplicates(dependencies_raw)

	var dependencies_export := []
	for dependence in dependencies_raw:
		if dependence == null:
			continue
		if not dependence is String:
			dependencies_export.append(dependence.resource_path)
#			print(dependence.resource_path)
			continue
		if not dependence.begins_with("res://addons/") and jEssentials.does_path_exist(dependence):
			dependencies_export.append(dependence)
	for dependence in dependencies_export:
		Logger.vlog(dependence)
		packer.add_file(dependence, dependence)

	packer.add_file("res://Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".tscn", editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".tscn")
	packer.add_file("res://Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".save", editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+".save")
	packer.add_file("res://Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+"-scenarios.cfg", editor_directory + "/Worlds/"+Root.current_editor_track+"/"+Root.current_editor_track+"-scenarios.cfg")
	packer.add_file("res://Worlds/"+Root.current_editor_track+"/screenshot.png", editor_directory + "/Worlds/"+Root.current_editor_track+"/screenshot.png")

	packer.flush()
	send_message("Track successfully exported to: " + export_path)
	$EditorHUD/ExportDialog.hide()


func _on_ExportTrack_pressed() -> void:
	$EditorHUD/ExportDialog.show_up(editor_directory)


func _on_TestTrack_pressed() -> void:
	test_track_pck()


func _on_ExportDialog_export_confirmed(path: String) -> void:
	export_track_pck(path)


func send_message(message: String) -> void:
	Logger.log("Editor sends message: " + message)
	$EditorHUD/Message/RichTextLabel.text = message
	$EditorHUD/Message.show()


func _on_MessageClose_pressed() -> void:
	$EditorHUD/Message.hide()
	if not has_node("World"):
		LoadingScreen.load_main_menu()


func duplicate_selected_object() -> void:
	Logger.vlog(selected_object_type)
	if selected_object_type != "Building":
		return
	else:
		Logger.vlog("Duplicating " + selected_object.name + " ...")
		var new_object: Node = selected_object.duplicate()
		Root.name_node_appropriate(new_object, new_object.name, $World/Buildings)
		$World/Buildings.add_child(new_object)
		new_object.set_owner($World)
		set_selected_object(new_object)


func add_signal_to_selected_rail() -> void:
	if selected_object_type != "Rail":
		send_message("Error, you need to select a Rail first, before you add a Rail Logic element")
		return
	var signal_res: PackedScene = preload("res://Data/Modules/Signal.tscn")
	var signal_ins: Node = signal_res.instance()
	Root.name_node_appropriate(signal_ins, "Signal", $World/Signals)
	$World/Signals.add_child(signal_ins)
	signal_ins.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	signal_ins.set_owner($World)
	signal_ins.attached_rail = selected_object.name
	signal_ins.set_to_rail()
	set_selected_object(signal_ins)


func add_station_to_selected_rail() -> void:
	if selected_object_type != "Rail":
		send_message("Error, you need to select a Rail first, before you add a Rail Logic element")
		return
	var station_res: PackedScene = preload("res://Data/Modules/Station.tscn")
	var station_ins: Node = station_res.instance()
	Root.name_node_appropriate(station_ins, "Station", $World/Signals)
	$World/Signals.add_child(station_ins)
	station_ins.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	station_ins.set_owner($World)
	station_ins.attached_rail = selected_object.name
	station_ins.set_to_rail()
	set_selected_object(station_ins)


func add_speed_limit_to_selected_rail() -> void:
	if selected_object_type != "Rail":
		send_message("Error, you need to select a Rail first, before you add a Rail Logic element")
		return
	var speed_limit_res: PackedScene = preload("res://Data/Modules/SpeedLimit_Lf7.tscn")
	var speed_limit_ins: Node = speed_limit_res.instance()
	Root.name_node_appropriate(speed_limit_ins, "SpeedLimit", $World/Signals)
	$World/Signals.add_child(speed_limit_ins)
	speed_limit_ins.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	speed_limit_ins.set_owner($World)
	speed_limit_ins.attached_rail = selected_object.name
	speed_limit_ins.set_to_rail()
	set_selected_object(speed_limit_ins)


func add_warn_speed_limit_to_selected_rail() -> void:
	if selected_object_type != "Rail":
		send_message("Error, you need to select a Rail first, before you add a Rail Logic element")
		return
	var war_speed_limit_res: PackedScene = preload("res://Data/Modules/WarnSpeedLimit_Lf6.tscn")
	var warn_speed_limit_ins: Node = war_speed_limit_res.instance()
	Root.name_node_appropriate(warn_speed_limit_ins, "SpeedLimit", $World/Signals)
	$World/Signals.add_child(warn_speed_limit_ins)
	warn_speed_limit_ins.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	warn_speed_limit_ins.set_owner($World)
	warn_speed_limit_ins.attached_rail = selected_object.name
	warn_speed_limit_ins.set_to_rail()
	set_selected_object(warn_speed_limit_ins)


func add_contact_point_to_selected_rail() -> void:
	if selected_object_type != "Rail":
		send_message("Error, you need to select a Rail first, before you add a Rail Logic element")
		return
	var contact_point_res: PackedScene = preload("res://Data/Modules/ContactPoint.tscn")
	var contact_point_ins: Node = contact_point_res.instance()
	Root.name_node_appropriate(contact_point_ins, "ContactPoint", $World/Signals)
	$World/Signals.add_child(contact_point_ins)
	contact_point_ins.add_child(preload("res://Editor/Modules/SelectCollider.tscn").instance())
	contact_point_ins.set_owner($World)
	contact_point_ins.attached_rail = selected_object.name
	contact_point_ins.set_to_rail()
	set_selected_object(contact_point_ins)


func get_all_station_node_names_in_world() -> Array:
	var station_node_names := []
	for signal_node in $World/Signals.get_children():
		if signal_node.type == "Station":
			station_node_names.append(signal_node.name)
	return station_node_names


func jump_to_station(station_node_name: String) -> void:
	var station_node: Node = $World/Signals.get_node(station_node_name)
	if station_node == null:
		Logger.err("Station not found:" + station_node_name, self)
		return
	camera.transform = station_node.transform.translated(Vector3(0, 5, 0))
	camera.rotation_degrees.y -= 90
	camera.load_from_transform(camera.transform)



var ist_chunks := []
func load_chunks_near_camera() -> void:
	var wanted_chunks: Array = $World.get_chunks_around_position(camera.translation)
	for wanted_chunk in wanted_chunks.duplicate():
		if ist_chunks.has(wanted_chunk):
			wanted_chunks.erase(wanted_chunk)
	$World.load_chunks(wanted_chunks)
	ist_chunks.append_array(wanted_chunks)


func get_imported_cache_file_path_of_import_file(file_path: String) -> Array:
	var config := ConfigFile.new()
	config.load(file_path)
	var return_values := []
	var value: String = config.get_value("remap", "path")
	if value == "" || value == null:
		return_values.append(config.get_value("remap", "path.s3tc"))
		return_values.append(config.get_value("remap", "path.etc2"))
		Logger.warn("No cached import file found of " + file_path, self)
	else:
		return_values.append(value)
	return return_values


func get_children_of_type_recursive(node: Node, type) -> Array:
	var children = []
	var stack = [node]

	if node is type:
		children.append(node)

	while not stack.empty():
		var parent = stack.pop_front()
		for child in parent.get_children():
			if child is type:
				children.append(child)
			stack.append(child)

	return children
