extends Control

@onready var speed_label = $SpeedLabel
@onready var unit_label = $UnitLabel
@onready var gear_label: Label = $GearLabel


var current_speed = 0.0
var display_speed = 0.0
var smooth_speed = true

var gear_no = 1

func _ready():
	# Style the labels
	speed_label.add_theme_font_size_override("font_size", 48)
	speed_label.add_theme_color_override("font_color", Color.CYAN)
	unit_label.add_theme_font_size_override("font_size", 48)
	unit_label.add_theme_color_override("font_color", Color.WHITE)
	unit_label.text = "Km/Hr"
	gear_label.add_theme_font_size_override("font_size", 48)
	gear_label.add_theme_color_override("font_color", Color.WHITE)

func _process(delta):
	if smooth_speed:
		# Smooth transition between speed values
		display_speed = lerp(display_speed, current_speed, delta * 10)
	else:
		display_speed = current_speed
	
	speed_label.text = str(int(display_speed))
	
	gear_label.text = str(int(gear_no))

func update_speed(speed: float):
	current_speed = speed

func update_gear(gear: int):
	gear_no = gear
