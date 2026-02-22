## physical_animation.gd
## Drives a set of RigidBody3D nodes toward the pose of an animated reference
## skeleton using Hooke's-law springs.
##
## Set target_skeleton and phys_body_map BEFORE add_child so that _ready()
## fires with valid references already in place.
extends Node3D

## The animated skeleton this system tries to match.
@export var target_skeleton: Skeleton3D

## When false, springs are disabled — bodies are free to fall under gravity.
@export var spring_enabled: bool = true

@export_group("Linear Spring")
@export var linear_stiffness:  float = 1200.0
@export var linear_damping:    float = 40.0
@export var max_linear_force:  float = 9999.0
## If a body drifts further than this (metres) teleport it instead of springing.
@export var teleport_threshold: float = 1.0

@export_group("Angular Spring")
@export var angular_stiffness: float = 4000.0
@export var angular_damping:   float = 80.0
@export var max_angular_force: float = 9999.0

## bone_id (int) → RigidBody3D — populated by main.gd before add_child.
var phys_body_map: Dictionary = {}


func _ready() -> void:
	print("[phys_driver] _ready() — target=%s  bodies=%d" % [
		is_instance_valid(target_skeleton), phys_body_map.size()])


func _physics_process(_delta: float) -> void:
	if not spring_enabled:
		return
	if not is_instance_valid(target_skeleton):
		return
	var dt := get_physics_process_delta_time()
	for bone_id: int in phys_body_map:
		var rb: PhysicalBone3D = phys_body_map[bone_id]
		if not is_instance_valid(rb):
			continue
		_apply_spring(bone_id, rb, dt)


func _apply_spring(bone_id: int, rb: PhysicalBone3D, dt: float) -> void:
	var target_xform: Transform3D = (
		target_skeleton.global_transform * target_skeleton.get_bone_global_pose(bone_id))
	var current_xform: Transform3D = rb.global_transform

	# --- Linear spring ---
	var pos_diff := target_xform.origin - current_xform.origin
	if pos_diff.length_squared() > teleport_threshold * teleport_threshold:
		rb.global_position = target_xform.origin
		rb.linear_velocity  = Vector3.ZERO
	else:
		var force := _hookes_law(pos_diff, rb.linear_velocity, linear_stiffness, linear_damping)
		rb.linear_velocity += force.limit_length(max_linear_force) * dt

	# --- Angular spring ---
	var rot_diff: Basis = target_xform.basis * current_xform.basis.inverse()
	var torque := _hookes_law(rot_diff.get_euler(), rb.angular_velocity, angular_stiffness, angular_damping)
	rb.angular_velocity += torque.limit_length(max_angular_force) * dt


func _hookes_law(displacement: Vector3, velocity: Vector3, stiffness: float, damping: float) -> Vector3:
	return (stiffness * displacement) - (damping * velocity)
