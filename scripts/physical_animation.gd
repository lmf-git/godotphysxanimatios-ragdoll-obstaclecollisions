## physical_animation.gd
## Plain Node3D that drives PhysicalBone3D nodes in a physics skeleton toward
## the pose of an animated reference skeleton using Hooke's-law springs.
##
## Create this node, set all @export properties, THEN add_child it so that
## _ready() fires with valid references already in place.
extends Node3D

## The Skeleton3D that owns the PhysicalBone3D simulation.
@export var skeleton: Skeleton3D

## The animated skeleton this ragdoll tries to match.
@export var target_skeleton: Skeleton3D

## When false, springs are disabled and the physics bones are free to fall
## under gravity — i.e. full ragdoll. Toggle this alongside physics_blend.
@export var spring_enabled: bool = true

@export_group("Linear Spring")
@export var linear_stiffness:  float = 1200.0
@export var linear_damping:    float = 40.0
@export var max_linear_force:  float = 9999.0
## If a bone drifts further than this (metres) teleport it instead of springing.
@export var teleport_threshold: float = 1.0

@export_group("Angular Spring")
@export var angular_stiffness: float = 4000.0
@export var angular_damping:   float = 80.0
@export var max_angular_force: float = 9999.0

var _physics_bones: Array[PhysicalBone3D] = []


func _ready() -> void:
	print("[phys_driver] _ready() — skeleton=%s  target=%s" % [
		is_instance_valid(skeleton), is_instance_valid(target_skeleton)])
	if is_instance_valid(skeleton):
		_physics_bones = _collect_physical_bones(skeleton)
		print("[phys_driver] Found %d physical bones." % _physics_bones.size())


func _collect_physical_bones(node: Node) -> Array[PhysicalBone3D]:
	var result: Array[PhysicalBone3D] = []
	for child in node.get_children():
		if child is PhysicalBone3D:
			result.append(child as PhysicalBone3D)
		elif child is PhysicalBoneSimulator3D:
			result.append_array(_collect_physical_bones(child))
	return result


func _physics_process(_delta: float) -> void:
	if not spring_enabled:
		return
	if not is_instance_valid(target_skeleton) or not is_instance_valid(skeleton):
		return
	for bone in _physics_bones:
		_apply_spring(bone)


func _apply_spring(bone: PhysicalBone3D) -> void:
	var id := bone.get_bone_id()

	var target_xform: Transform3D = target_skeleton.global_transform * target_skeleton.get_bone_global_pose(id)
	# Read the bone's ACTUAL physics-body world transform — not the skeleton pose,
	# which relies on PhysicalBoneSimulator3D having already written results back.
	var current_xform: Transform3D = bone.global_transform

	# --- Linear spring ---
	var pos_diff := target_xform.origin - current_xform.origin
	if pos_diff.length_squared() > teleport_threshold * teleport_threshold:
		bone.global_position = target_xform.origin
	else:
		var force := _hookes_law(pos_diff, bone.linear_velocity, linear_stiffness, linear_damping)
		bone.linear_velocity += force.limit_length(max_linear_force) * get_physics_process_delta_time()

	# --- Angular spring ---
	var rot_diff: Basis = target_xform.basis * current_xform.basis.inverse()
	var torque := _hookes_law(rot_diff.get_euler(), bone.angular_velocity, angular_stiffness, angular_damping)
	bone.angular_velocity += torque.limit_length(max_angular_force) * get_physics_process_delta_time()


func _hookes_law(displacement: Vector3, velocity: Vector3, stiffness: float, damping: float) -> Vector3:
	return (stiffness * displacement) - (damping * velocity)
