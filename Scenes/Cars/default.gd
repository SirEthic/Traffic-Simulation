class_name Default
extends VehicleBody3D

const MAX_STEER = 0.8
const MAX_ENGINE_POWER = 7500
const MAX_BRAKE_POWER = 80
const REVERSE_POWER = 4000
const sensitivity = 0.001
const CONTROLLER_SENSITIVITY = 0.01

# Momentum variables
var current_speed: float = 0.0
var max_speed: float = 25.0
var acceleration_curve: float = 1.0
var steering_curve: float = 1.0

# Camera reset variables
var camera_reset_timer: float = 0.0
const CAMERA_RESET_DELAY: float = 3.0
var should_reset_camera: bool = false
var camera_is_free: bool = false

# Road management variables - OPTIMIZED
var road_grid_size: float = 500.0
var render_distance: int = 2
var current_grid_pos: Vector2i = Vector2i.ZERO
var spawned_roads: Dictionary = {}

# Performance optimization variables
var road_spawn_queue: Array[Dictionary] = []
var roads_cleanup_queue: Array[Vector2i] = []
var max_spawns_per_frame: int = 1
var max_cleanups_per_frame: int = 2
var frame_counter: int = 0
var update_frequency: int = 3  # Check for updates every 3 frames

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera
@onready var reverse_camera: Camera3D = $CameraPivot/ReverseCamera
@onready var speedometer_ui: Control = $SpeedometerUI
@onready var road_manager: RoadManager = $"../RoadManager"

var road_container_scene = preload("res://Scenes/Roads/4_way_2x_2.tscn")

var spawn_position
var spawn_rotation
var cam_position
var cam_spawn_rotation 
var camera_spawn_rotation

var gear = 1
var gear_ratios = [0, 2, 1.2, 0.65, 0.65, 0.6]
var gear_max_speeds = [0, 35, 70, 110, 150, 200]

func _ready() -> void:
	# Check if road_manager exists, if not create it or find it
	if not road_manager:
		print("Warning: RoadManager not found at ../RoadManager")
		# Try to find it elsewhere
		road_manager = get_tree().get_first_node_in_group("road_manager")
		if not road_manager:
			print("Creating new RoadManager")
			road_manager = Node3D.new()
			road_manager.name = "RoadManager"
			get_parent().add_child(road_manager)
	
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	spawn_position = global_position
	spawn_rotation = global_rotation
	cam_position = camera_pivot.global_position
	cam_spawn_rotation = camera_pivot.global_rotation  
	camera_spawn_rotation = camera.rotation
	
	current_grid_pos = Vector2i(
		int(global_position.x / road_grid_size),
		int(global_position.z / road_grid_size)
	)
	
	# Spawn initial roads using optimized system
	queue_initial_roads()
	
	mass = 1200.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.5, 0)

func queue_initial_roads():
	# Queue initial roads instead of spawning them all at once
	for x in range(current_grid_pos.x - render_distance, current_grid_pos.x + render_distance + 1):
		for z in range(current_grid_pos.y - render_distance, current_grid_pos.y + render_distance + 1):
			var grid_key = Vector2i(x, z)
			var world_pos = Vector3(x * road_grid_size, 0, z * road_grid_size)
			road_spawn_queue.append({"grid": grid_key, "pos": world_pos})

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		camera_pivot.rotate_y(-event.relative.x * sensitivity)
		camera.rotate_x(event.relative.y * sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-60), deg_to_rad(60))
		camera_is_free = true
		reset_camera_timer()

func Controller_Rotation():
	var axis_vector = Vector2.ZERO
	axis_vector.x = Input.get_action_strength("look_right") - Input.get_action_strength("look_left")
	axis_vector.y = Input.get_action_strength("look_up") - Input.get_action_strength("look_down")
	
	if InputEventJoypadMotion:
		camera_pivot.rotate_y(-axis_vector.x * CONTROLLER_SENSITIVITY)
		camera.rotate_x(-axis_vector.y * CONTROLLER_SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-60), deg_to_rad(60))

		if axis_vector.length() > 0.1:
			camera_is_free = true
			reset_camera_timer()

# Process queued operations gradually - MAIN OPTIMIZATION
func _process(_delta: float):
	process_spawn_queue()
	process_cleanup_queue()

func _physics_process(delta: float) -> void:
	Controller_Rotation()
	update_infinite_roads()
	
	current_speed = linear_velocity.length() * 3.6
	if speedometer_ui:
		speedometer_ui.update_speed(current_speed)
	
	gear_shift()
	max_speed = gear_max_speeds[gear]
	if speedometer_ui:
		speedometer_ui.update_gear(gear)
	
	handle_camera_reset_timer(delta)
	
	var speed_factor = clamp(1.0 - (current_speed / max_speed) * 0.3, 0.6, 1.0)
	var steering_input = Input.get_action_strength("Left") - Input.get_action_strength("Right")
	var target_steering = steering_input * MAX_STEER * speed_factor
	steering = move_toward(steering, target_steering, delta * 10.0)
	
	var throttle_input = Input.get_action_strength("Forward")
	var reverse_input = Input.get_action_strength("Backward")
	var brake_input = Input.get_action_strength("Brake")
	
	# Forward/Reverse logic
	if throttle_input > 0:
		var power_multiplier = clamp(1.0 - (current_speed / max_speed), 0.1, 1.0)
		var gear_ratio = gear_ratios[gear]
		var target_force = throttle_input * MAX_ENGINE_POWER * power_multiplier * gear_ratio
		engine_force = lerpf(engine_force, target_force, delta * 5.0)
	elif reverse_input > 0:
		if current_speed < 17:
			engine_force = lerpf(engine_force, -reverse_input * REVERSE_POWER, delta * 8.0)
		else:
			brake = lerpf(brake, reverse_input * MAX_BRAKE_POWER, delta * 10.0)
	else:
		engine_force = lerpf(engine_force, 0, delta * 8.0)
	
	# Brake handling
	if brake_input > 0:
		brake = lerpf(brake, brake_input * MAX_BRAKE_POWER, delta * 15.0)
		engine_force = lerpf(engine_force, 0, delta * 10.0)
	else:
		brake = lerpf(brake, 0, delta * 10.0)
	
	if brake_input > 0.9 and current_speed < 2.0:
		engine_force = 0
	
	var drag_force = linear_velocity.length() * 0.5
	engine_force -= drag_force
	
	update_camera_with_momentum(delta)
	check_camera_switch()
	
	if Input.is_action_just_pressed("Reset"):
		reset_car()

	# Gear-specific engine force adjustments
	if current_speed < 10 and gear == 2:
		engine_force *= 0.9
	elif current_speed < 15 and gear == 3:
		engine_force *= 0.7
	elif current_speed < 30 and gear == 4:
		engine_force *= 0.5
	elif current_speed < 50 and gear == 5:
		engine_force *= 0.3

# OPTIMIZED ROAD MANAGEMENT FUNCTIONS
func update_infinite_roads():
	# Only check for updates every few frames to reduce CPU load
	frame_counter += 1
	if frame_counter % update_frequency != 0:
		return
	
	var new_grid_pos = Vector2i(
		int(global_position.x / road_grid_size),
		int(global_position.z / road_grid_size)
	)
	
	if new_grid_pos != current_grid_pos:
		current_grid_pos = new_grid_pos
		queue_roads_for_spawning()
		queue_roads_for_cleanup()

func queue_roads_for_spawning():
	# Clear existing queue
	road_spawn_queue.clear()
	
	# Queue roads that need to be spawned
	for x in range(current_grid_pos.x - render_distance, current_grid_pos.x + render_distance + 1):
		for z in range(current_grid_pos.y - render_distance, current_grid_pos.y + render_distance + 1):
			var grid_key = Vector2i(x, z)
			
			if not spawned_roads.has(grid_key):
				var world_pos = Vector3(x * road_grid_size, 0, z * road_grid_size)
				road_spawn_queue.append({"grid": grid_key, "pos": world_pos})

func queue_roads_for_cleanup():
	roads_cleanup_queue.clear()
	
	for grid_pos in spawned_roads.keys():
		var distance = grid_pos.distance_to(current_grid_pos)
		if distance > render_distance + 2:  # Increased buffer to prevent pop-in
			roads_cleanup_queue.append(grid_pos)

func process_spawn_queue():
	var spawned_count = 0
	
	while road_spawn_queue.size() > 0 and spawned_count < max_spawns_per_frame:
		var road_data = road_spawn_queue.pop_front()
		spawn_road_at_position_optimized(road_data.grid, road_data.pos)
		spawned_count += 1

func process_cleanup_queue():
	var cleaned_count = 0
	
	while roads_cleanup_queue.size() > 0 and cleaned_count < max_cleanups_per_frame:
		var grid_pos = roads_cleanup_queue.pop_front()
		cleanup_road_at_position(grid_pos)
		cleaned_count += 1

func spawn_road_at_position_optimized(grid_key: Vector2i, world_pos: Vector3):
	# Safety check for road_manager
	if not road_manager:
		print("Error: road_manager is null, cannot spawn road")
		return
	
	var road_instance
	var distance_to_player = world_pos.distance_to(global_position)
	
	# Use LOD system - simple roads for distant intersections
	if distance_to_player > road_grid_size * 1.5:
		road_instance = create_simple_4way(world_pos)
		road_manager.add_child(road_instance)
	else:
		# Use detailed road for close intersections
		if road_container_scene:
			road_instance = road_container_scene.instantiate()
			road_instance.global_position = world_pos
			road_manager.add_child(road_instance)
			
			# Defer heavy operations to avoid frame drops
			call_deferred("setup_road_instance", road_instance)
		else:
			road_instance = create_simple_4way(world_pos)
			road_manager.add_child(road_instance)
	
	spawned_roads[grid_key] = road_instance

func setup_road_instance(road_instance):
	if is_instance_valid(road_instance) and road_instance.has_method("rebuild_segments"):
		road_instance.rebuild_segments()

func create_simple_4way(world_pos: Vector3) -> StaticBody3D:
	var simple_road = StaticBody3D.new()
	simple_road.global_position = world_pos
	simple_road.name = "SimpleRoad_" + str(world_pos.x) + "_" + str(world_pos.z)
	
	# Create visual mesh
	var mesh_instance = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(road_grid_size * 0.8, 0.1, road_grid_size * 0.8)
	mesh_instance.mesh = box_mesh
	
	# Create collision
	var collision_shape = CollisionShape3D.new()
	var box_shape = BoxShape3D.new()
	box_shape.size = box_mesh.size
	collision_shape.shape = box_shape
	
	simple_road.add_child(mesh_instance)
	simple_road.add_child(collision_shape)
	
	return simple_road

func cleanup_road_at_position(grid_pos: Vector2i):
	if spawned_roads.has(grid_pos):
		var road = spawned_roads[grid_pos]
		if is_instance_valid(road):
			road.call_deferred("queue_free")
		spawned_roads.erase(grid_pos)

# CAMERA AND OTHER FUNCTIONS (unchanged but optimized)
func handle_camera_reset_timer(delta: float):
	if camera_is_free:
		camera_reset_timer += delta
		if camera_reset_timer >= CAMERA_RESET_DELAY and not should_reset_camera:
			should_reset_camera = true

func reset_camera_timer():
	camera_reset_timer = 0.0
	should_reset_camera = false

func update_camera_with_momentum(delta: float):
	var target_position = global_position
	camera_pivot.global_position = camera_pivot.global_position.lerp(target_position, delta * 10.0)
	
	if not camera_is_free or should_reset_camera:
		if should_reset_camera:
			var car_rotation_difference = global_rotation - spawn_rotation
			var target_cam_rotation = cam_spawn_rotation + car_rotation_difference
			
			var current_quat = camera_pivot.global_transform.basis.get_rotation_quaternion()
			var target_quat = Quaternion.from_euler(target_cam_rotation)
			
			var smooth_quat = current_quat.slerp(target_quat, delta * 1.5)
			camera_pivot.global_transform.basis = Basis(smooth_quat)
			
			camera.rotation = camera.rotation.lerp(camera_spawn_rotation, delta * 1.5)
			
			if current_quat.angle_to(target_quat) < 0.1 and camera.rotation.distance_to(camera_spawn_rotation) < 0.1:
				should_reset_camera = false
				camera_is_free = false
		else:
			var current_quat = camera_pivot.global_transform.basis.get_rotation_quaternion()
			var target_quat = global_transform.basis.get_rotation_quaternion()
			var smooth_quat = current_quat.slerp(target_quat, delta * 3.0)
			camera_pivot.global_transform.basis = Basis(smooth_quat)
	
	add_camera_feedback(delta)

func add_camera_feedback(_delta: float):
	camera.position = Vector3(0, 1.75, -3.2)
	
	var speed_shake = (current_speed / max_speed) * 0.01
	
	if current_speed > 5.0:
		var shake_offset = Vector3(
			randf_range(-speed_shake, speed_shake),
			randf_range(-speed_shake * 0.5, speed_shake * 0.5),
			randf_range(-speed_shake * 0.3, speed_shake * 0.3)
		)
		camera.position += shake_offset

func gear_shift():
	if Input.is_action_just_pressed("Shift Up"):
		if gear < gear_ratios.size() - 1:
			gear += 1
	if Input.is_action_just_pressed("Shift Down"):
		if gear > 1:
			gear -= 1

func reset_car():
	global_position = spawn_position
	global_rotation = spawn_rotation
	camera_pivot.global_position = cam_position
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	engine_force = 0

func check_camera_switch():
	if Input.is_action_pressed("Reverse_Cam"):
		reverse_camera.current = true
	else:
		camera.current = true
