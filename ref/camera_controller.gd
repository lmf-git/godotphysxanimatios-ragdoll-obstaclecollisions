class_name CameraController
extends Camera3D

## Orbit camera that smoothly follows a target node.
##
## Mouse controls:
##   Right-click drag  — orbit (yaw / pitch)
##   Middle-click drag — pan pivot off-centre
##   Scroll wheel      — zoom in / out
##
## Keyboard controls (WASD):
##   A / D — orbit left / right
##   W / S — orbit up / down
##   Q / E — zoom in / out

@export var follow_speed: float         = 6.0
@export var orbit_sensitivity: float    = 0.3    # degrees per pixel
@export var pan_sensitivity: float      = 0.003   # world-units per pixel per unit distance
@export var zoom_speed: float           = 0.8
@export var kb_orbit_speed: float       = 90.0   # degrees per second (WASD)
@export var kb_zoom_speed: float        = 6.0    # units per second (Q/E)
@export var min_distance: float         = 1.5
@export var max_distance: float         = 25.0
@export var target_height_offset: float = 1.0

var target: Node3D = null

var _pivot: Vector3  = Vector3(0.0, 1.0, 0.0)
var _yaw: float      = 0.0    # radians; 0 = camera sits on +Z side
var _pitch: float    = 0.4    # radians; positive = above horizon (~23 deg)
var _distance: float = 6.0

var _orbiting: bool  = false
var _panning: bool   = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(_distance - zoom_speed, min_distance)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(_distance + zoom_speed, max_distance)

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_yaw   -= deg_to_rad(mm.relative.x * orbit_sensitivity)
			_pitch -= deg_to_rad(mm.relative.y * orbit_sensitivity)
			_pitch  = clampf(_pitch, deg_to_rad(5.0), deg_to_rad(80.0))
		elif _panning:
			var right := global_transform.basis.x
			var up    := global_transform.basis.y
			_pivot -= right * mm.relative.x * pan_sensitivity * _distance
			_pivot += up    * mm.relative.y * pan_sensitivity * _distance


func _process(delta: float) -> void:
	# ---- WASD keyboard orbit ----
	var orbit_delta := kb_orbit_speed * delta
	if Input.is_physical_key_pressed(KEY_A):
		_yaw += deg_to_rad(orbit_delta)
	if Input.is_physical_key_pressed(KEY_D):
		_yaw -= deg_to_rad(orbit_delta)
	if Input.is_physical_key_pressed(KEY_W):
		_pitch = clampf(_pitch + deg_to_rad(orbit_delta), deg_to_rad(5.0), deg_to_rad(80.0))
	if Input.is_physical_key_pressed(KEY_S):
		_pitch = clampf(_pitch - deg_to_rad(orbit_delta), deg_to_rad(5.0), deg_to_rad(80.0))
	if Input.is_physical_key_pressed(KEY_Q):
		_distance = maxf(_distance - kb_zoom_speed * delta, min_distance)
	if Input.is_physical_key_pressed(KEY_E):
		_distance = minf(_distance + kb_zoom_speed * delta, max_distance)

	# ---- Smooth pivot follow ----
	if target and is_instance_valid(target) and not _panning:
		var goal := target.global_position + Vector3(0.0, target_height_offset, 0.0)
		_pivot = _pivot.lerp(goal, clampf(follow_speed * delta, 0.0, 1.0))

	# ---- Spherical coord → world position ----
	var cos_p  := cos(_pitch)
	var offset := Vector3(
		cos_p * sin(_yaw),
		sin(_pitch),
		cos_p * cos(_yaw)
	) * _distance

	global_position = _pivot + offset
	if not global_position.is_equal_approx(_pivot):
		look_at(_pivot, Vector3.UP)
