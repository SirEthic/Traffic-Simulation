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
	reset_pos_road()
	
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

func reset_pos_road():
	var boundary = 1000.0
	var shift_distance = 2000.0  # How far to shift the world
	  
	var world_shift = Vector3.ZERO
	
	# Check X boundary
	if global_position.x > boundary:
		world_shift.x = -shift_distance
		print("Shifting world X: ", world_shift.x)
	elif global_position.x < -boundary:
		world_shift.x = shift_distance
		print("Shifting world X: ", world_shift.x)
		
	# Check Z boundary  
	if global_position.z > boundary:
		world_shift.z = -shift_distance
		print("Shifting world Z: ", world_shift.z)
	elif global_position.z < -boundary:
		world_shift.z = shift_distance
		print("Shifting world Z: ", world_shift.z)
	
	if global_position.x > boundary and global_position.z > boundary:
		world_shift.x = -shift_distance
		world_shift.z = -shift_distance
	elif global_position.x < -boundary and global_position.z < -boundary:
		world_shift.x = shift_distance
		world_shift.z = shift_distance
	
	# Apply shift to car and all world objects
	if world_shift != Vector3.ZERO:
		print("Car position before shift: ", global_position)
		print("World shift vector: ", world_shift)
		
		global_position += world_shift
		
		# IMPORTANT: Shift the camera pivot by the same amount to maintain seamless illusion
		camera_pivot.global_position += world_shift
		
		# Also update the stored spawn positions so reset still works correctly
		spawn_position += world_shift
		cam_position += world_shift
		
