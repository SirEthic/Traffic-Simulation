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


var road_grid_size: float = 500.0  # Size of each road tile
var render_distance: int = 2  # How many tiles to render in each direction
var current_grid_pos: Vector2i = Vector2i.ZERO
var spawned_roads: Dictionary = {}  # Track spawned road positions
var roads_to_remove: Array[Vector3] = []

var road_spawn_queue: Array[Dictionary] = []
var roads_cleanup_queue: Array[Vector2i] = []
var max_spawns_per_frame: int = 1
var max_cleanups_per_frame: int = 2
var frame_counter: int = 0
var update_frequency: int = 3

# Road prefabs - using 4-way as universal road tile
var road_container_scene  = preload("res://Scenes/Roads/4_way_2x_2.tscn")

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera
@onready var reverse_camera: Camera3D = $CameraPivot/ReverseCamera

@onready var speedometer_ui: Control = $SpeedometerUI

@onready var road_manager: RoadManager = $"../RoadManager"


var spawn_position
var spawn_rotation
var cam_position
var cam_spawn_rotation 
var camera_spawn_rotation

var gear = 1
var gear_ratios = [0, 2, 1.2, 0.65, 0.65, 0.6]
#var gear_ratios = [0, 3.5, 2.2, 1.5, 1.0, 0.7]

var gear_max_speeds = [0, 35, 70, 110, 150, 200]

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	spawn_position = global_position
	spawn_rotation = global_rotation
	cam_position = camera_pivot.global_position
	cam_spawn_rotation = camera_pivot.global_rotation  # Store original camera pivot rotation
	camera_spawn_rotation = camera.rotation  # Store original camera local rotation
	
	current_grid_pos = Vector2i(
		int(global_position.x / road_grid_size),
		int(global_position.z / road_grid_size)
	)
	
	# Spawn initial roads
	spawn_roads_around_player()
	
	mass = 1200.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.5, 0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		camera_pivot.rotate_y(-event.relative.x * sensitivity)
		camera.rotate_x(event.relative.y * sensitivity)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-60), deg_to_rad(60))
		
		# Set camera to free mode when player moves mouse
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
		
		# Set camera to free mode when player uses controller
		if axis_vector.length() > 0.1:
			camera_is_free = true
			reset_camera_timer()

func _physics_process(delta: float) -> void:
	Controller_Rotation()
	update_infinite_roads()
	
	process_spawn_queue()
	process_cleanup_queue()
	
	current_speed = linear_velocity.length() * 3.6
	speedometer_ui.update_speed(current_speed)
	
	gear_shift()
	max_speed = gear_max_speeds[gear]
	speedometer_ui.update_gear(gear)
	
	# Handle camera reset logic
	handle_camera_reset_timer(delta)
	
	
	var speed_factor = clamp(1.0 - (current_speed / max_speed) * 0.3, 0.6, 1.0)  # Less reduction
	var steering_input = Input.get_action_strength("Left") - Input.get_action_strength("Right")
	var target_steering = steering_input * MAX_STEER * speed_factor
	steering = move_toward(steering, target_steering, delta * 10.0)  # Faster steering response
	
	var throttle_input = Input.get_action_strength("Forward")
	var reverse_input = Input.get_action_strength("Backward")
	var brake_input = Input.get_action_strength("Brake")
	
	
	# Forward/Reverse logic
	if throttle_input > 0:
		#Forward
		var power_multiplier = clamp(1.0 - (current_speed / max_speed), 0.1, 1.0)
		var gear_ratio = gear_ratios[gear]
		var target_force = throttle_input * MAX_ENGINE_POWER * power_multiplier * gear_ratio
		engine_force = lerpf(engine_force, target_force, delta * 5.0)
	elif reverse_input > 0:
		# Reverse
		if current_speed < 17:  # Only reverse when nearly stopped
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
	
	var drag_force = linear_velocity.length() * 0.5  # Adjust 0.2 for strength
	engine_force -= drag_force
	
	update_camera_with_momentum(delta)
	
	check_camera_switch()
	
	if Input.is_action_just_pressed("Reset"):
		reset_car()

	if current_speed < 10 and gear == 2:
		engine_force *= 0.9
	elif current_speed < 15 and gear == 3:
		engine_force *= 0.7
	elif current_speed < 30 and gear == 4:
		engine_force *= 0.5
	elif current_speed < 50 and gear == 5:
		engine_force *= 0.3

func update_infinite_roads():
	# Only check for updates every few frames
	frame_counter += 1
	if frame_counter % update_frequency != 0:
		return
	
	# Calculate current grid position
	var new_grid_pos = Vector2i(
		int(global_position.x / road_grid_size),
		int(global_position.z / road_grid_size)
	)
	
	# Only update if we've moved to a new grid cell
	if new_grid_pos != current_grid_pos:
		current_grid_pos = new_grid_pos
		queue_roads_for_spawning()
		queue_roads_for_cleanup()

func spawn_roads_around_player():
	# Spawn roads in a grid around the player
	for x in range(current_grid_pos.x - render_distance, current_grid_pos.x + render_distance + 1):
		for z in range(current_grid_pos.y - render_distance, current_grid_pos.y + render_distance + 1):
			var grid_key = Vector2i(x, z)
			
			# Skip if road already exists at this position
			if spawned_roads.has(grid_key):
				continue
			
			# Calculate world position
			var world_pos = Vector3(
				x * road_grid_size,
				0,
				z * road_grid_size
			)
			
			# Spawn the road using your road generator system
			spawn_road_at_position(grid_key, world_pos)

func spawn_road_at_position(grid_key: Vector2i, world_pos: Vector3):
	var road_instance
	
	# Method 1: If your 4-way is a saved scene file
	if road_container_scene:
		road_instance = road_container_scene.instantiate()
		road_instance.global_position = world_pos
		# Add to your existing road_manager
		road_manager.add_child(road_instance)
		
		# If it's a RoadContainer, trigger rebuild
		if road_instance.has_method("is_road_container"):
			road_instance.rebuild_segments()
	
	# Method 2: If you need to create RoadContainer programmatically
	else:
		road_instance = create_programmatic_road_container(world_pos, grid_key)
	
	# Store reference
	spawned_roads[grid_key] = road_instance
	print("Spawned road at grid: ", grid_key, " world: ", world_pos)

func create_programmatic_road_container(world_pos: Vector3, grid_key: Vector2i) -> Node3D:
	# This function creates a RoadContainer programmatically
	# You'll need to adjust this based on your road generator's API
	
	# Create a new RoadContainer (adjust class name as needed)
	var road_container = RoadContainer.new()  # Or whatever your container class is called
	road_container.global_position = world_pos
	road_container.name = "Road_" + str(grid_key.x) + "_" + str(grid_key.y)
	
	# Create road points for a 4-way intersection
	# This is a basic example - you'll need to adjust based on your system
	create_4way_road_points(road_container, world_pos)
	
	# Add to road manager
	road_manager.add_child(road_container)
	
	# Rebuild the road mesh
	road_container.rebuild_segments()
	
	return road_container

func create_4way_road_points(container: Node3D, center_pos: Vector3):
	# Create road points for a 4-way intersection
	# This is a simplified example - adjust based on your road generator's requirements
	
	var road_width = 50.0  # Adjust based on your road width
	var points = [
		center_pos + Vector3(-road_width, 0, 0),  # West
		center_pos,  # Center
		center_pos + Vector3(road_width, 0, 0),   # East
		center_pos,  # Back to center
		center_pos + Vector3(0, 0, -road_width),  # North
		center_pos,  # Back to center
		center_pos + Vector3(0, 0, road_width),   # South
	]
	
	# Add points to your road container
	# You'll need to adapt this to your road generator's API
	for i in range(points.size()):
		var road_point = RoadPoint.new()  # Or whatever your point class is
		road_point.position = points[i]
		container.add_child(road_point)

func cleanup_distant_roads():
	roads_to_remove.clear()
	
	# Find roads that are too far away
	for grid_pos in spawned_roads.keys():
		var distance = grid_pos.distance_to(current_grid_pos)
		if distance > render_distance + 1:  # Add buffer before removing
			roads_to_remove.append(grid_pos)
	
	# Remove distant roads
	for grid_pos in roads_to_remove:
		if spawned_roads.has(grid_pos):
			var road = spawned_roads[grid_pos]
			if is_instance_valid(road):
				road.queue_free()
			spawned_roads.erase(grid_pos)
			print("Removed road at grid: ", grid_pos)

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
	# Clear existing cleanup queue
	roads_cleanup_queue.clear()
	
	# Queue roads that are too far away
	for grid_pos in spawned_roads.keys():
		var distance = grid_pos.distance_to(current_grid_pos)
		if distance > render_distance + 2:  # Increased buffer
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

# Optimized spawning function
func spawn_road_at_position_optimized(grid_key: Vector2i, world_pos: Vector3):
	# Use object pooling if possible, or lighter-weight road creation
	var road_instance
	
	# Option 1: Use a simpler road for distant intersections
	var distance_to_player = world_pos.distance_to(global_position)
	if distance_to_player > road_grid_size * 1.5:
		road_instance = create_simple_4way(world_pos)
	else:
		# Use full detailed road only when close
		if road_container_scene:
			road_instance = road_container_scene.instantiate()
			road_instance.global_position = world_pos
			
			# Defer heavy operations
			call_deferred("setup_road_instance", road_instance)
	
	if road_instance:
		road_manager.add_child(road_instance)
		spawned_roads[grid_key] = road_instance

func setup_road_instance(road_instance):
	# Do heavy setup operations in deferred calls
	if road_instance.has_method("rebuild_segments"):
		road_instance.rebuild_segments()

func create_simple_4way(world_pos: Vector3) -> StaticBody3D:
	# Create a very simple 4-way intersection for distant roads
	var simple_road = StaticBody3D.new()
	simple_road.global_position = world_pos
	
	# Create a simple box mesh for the intersection
	var mesh_instance = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = Vector3(road_grid_size * 0.8, 0.1, road_grid_size * 0.8)
	mesh_instance.mesh = box_mesh
	
	# Simple collision
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
			# Use call_deferred for cleanup to avoid frame hitches
			road.call_deferred("queue_free")
		spawned_roads.erase(grid_pos)

# Add LOD (Level of Detail) system
func should_use_detailed_road(world_pos: Vector3) -> bool:
	var distance = world_pos.distance_to(global_position)
	return distance < road_grid_size * 2.0  # Only use detailed roads within 2 grid cells


func rebuild_road_segments(road_instance):
	if is_instance_valid(road_instance):
		road_instance.rebuild_segments()

func handle_camera_reset_timer(delta: float):
	# Always increment timer when camera is free
	if camera_is_free:
		camera_reset_timer += delta
		if camera_reset_timer >= CAMERA_RESET_DELAY and not should_reset_camera:
			should_reset_camera = true

func reset_camera_timer():
	camera_reset_timer = 0.0
	should_reset_camera = false
	# Don't reset camera_is_free here - let it stay free until timer expires

func update_camera_with_momentum(delta: float):
	# Camera follows car position smoothly (always)
	var target_position = global_position
	camera_pivot.global_position = camera_pivot.global_position.lerp(target_position, delta * 10.0)
	
	# Only update camera rotation if it's not in free mode or if it's resetting
	if not camera_is_free or should_reset_camera:
		if should_reset_camera:
			# Reset to the original camera setup relative to car
			# Calculate what the original camera pivot rotation should be relative to current car rotation
			var car_rotation_difference = global_rotation - spawn_rotation
			var target_cam_rotation = cam_spawn_rotation + car_rotation_difference
			
			var current_quat = camera_pivot.global_transform.basis.get_rotation_quaternion()
			var target_quat = Quaternion.from_euler(target_cam_rotation)
			
			# Smoothly reset camera pivot rotation
			var smooth_quat = current_quat.slerp(target_quat, delta * 1.5)
			camera_pivot.global_transform.basis = Basis(smooth_quat)
			
			# Reset camera local rotation to original
			camera.rotation = camera.rotation.lerp(camera_spawn_rotation, delta * 1.5)
			
			# Check if camera is close enough to target rotation to stop resetting
			if current_quat.angle_to(target_quat) < 0.1 and camera.rotation.distance_to(camera_spawn_rotation) < 0.1:
				should_reset_camera = false
				camera_is_free = false  # Camera is no longer free after reset
		else:
			# Normal camera follow behavior (when not free and not resetting)
			var current_quat = camera_pivot.global_transform.basis.get_rotation_quaternion()
			var target_quat = global_transform.basis.get_rotation_quaternion()
			var smooth_quat = current_quat.slerp(target_quat, delta * 3.0)
			camera_pivot.global_transform.basis = Basis(smooth_quat)
	
	add_camera_feedback(delta)

func add_camera_feedback(_delta: float):
	# Reset camera
	camera.position = Vector3(0, 1.75, -3.2)
	
	# Camera movement based on speed and acceleration
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
	brake = 0
	steering = 0
	
	# Reset camera timer when car is manually reset
	reset_camera_timer()

func check_camera_switch():
	if Input.is_action_pressed("Reverse_Cam"):
		reverse_camera.current = true
	else:
		camera.current = true

var roads_to_spawn: Array[Dictionary] = []
var spawn_batch_size: int = 1  # How many roads to spawn per frame

func spawn_roads_around_player_batched():
	# Clear previous batch
	roads_to_spawn.clear()
	
	# Collect all positions that need roads
	for x in range(current_grid_pos.x - render_distance, current_grid_pos.x + render_distance + 1):
		for z in range(current_grid_pos.y - render_distance, current_grid_pos.y + render_distance + 1):
			var grid_key = Vector2i(x, z)
			
			if not spawned_roads.has(grid_key):
				var world_pos = Vector3(x * road_grid_size, 0, z * road_grid_size)
				roads_to_spawn.append({"grid": grid_key, "pos": world_pos})
	
	# Start spawning process
	if roads_to_spawn.size() > 0:
		spawn_next_batch()

func spawn_next_batch():
	# Spawn a batch of roads per frame for better performance
	var spawned_this_frame = 0
	
	while roads_to_spawn.size() > 0 and spawned_this_frame < spawn_batch_size:
		var road_data = roads_to_spawn.pop_front()
		spawn_road_at_position(road_data.grid, road_data.pos)
		spawned_this_frame += 1
	
	# Continue spawning next frame if there are more roads
	if roads_to_spawn.size() > 0:
		call_deferred("spawn_next_batch")
