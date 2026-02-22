## interpolated_animation.gd
## A plain Node3D driver that reads poses from two skeletons and writes
## the blended result into visual_skeleton via set_bone_global_pose_override().
##
## Create this node, set all @export properties, THEN add_child it so that
## _ready() fires with valid references already in place.
extends Node3D

## 0.0 = fully animated, 1.0 = fully physics-driven.
@export_range(0.0, 1.0) var physics_blend: float = 0.0

@export var visual_skeleton:   Skeleton3D
@export var physics_skeleton:  Skeleton3D
@export var animated_skeleton: Skeleton3D

## Map bone_id (int) → PhysicalBone3D so we can read the physics body's
## actual world transform directly, bypassing the PhysicalBoneSimulator3D
## modifier write-back (which may or may not have run this frame).
var phys_bone_map: Dictionary = {}

var _skip_first := true


func _ready() -> void:
	print("[vis_driver] _ready() — vis=%s  anim=%s  phys=%s" % [
		is_instance_valid(visual_skeleton),
		is_instance_valid(animated_skeleton),
		is_instance_valid(physics_skeleton)])


func _process(_delta: float) -> void:
	# Skip the very first frame so the AnimationPlayer has ticked at least once.
	if _skip_first:
		_skip_first = false
		return

	if not (is_instance_valid(visual_skeleton)
			and is_instance_valid(animated_skeleton)):
		return

	var inv_skel := visual_skeleton.global_transform.affine_inverse()

	for i in visual_skeleton.get_bone_count():
		var anim_xform: Transform3D = (
			animated_skeleton.global_transform * animated_skeleton.get_bone_global_pose(i))

		var blended_local: Transform3D
		if physics_blend < 0.001:
			blended_local = inv_skel * anim_xform
		else:
			var phys_xform: Transform3D
			if phys_bone_map.has(i):
				# Read directly from the RigidBody-like physics object — always current.
				var pb: PhysicalBone3D = phys_bone_map[i]
				if is_instance_valid(pb):
					phys_xform = pb.global_transform
				else:
					phys_xform = anim_xform
			else:
				# Fallback for skipped bones (fingers, toes, etc.) — use the
				# animated pose so they follow the animation rather than the
				# undriven physics skeleton (which is always in T-pose).
				phys_xform = anim_xform
			blended_local = inv_skel * anim_xform.interpolate_with(phys_xform, physics_blend)

		visual_skeleton.set_bone_global_pose_override(i, blended_local, 1.0, true)


# ---------------------------------------------------------------------------
# Blend helpers called from main.gd
# ---------------------------------------------------------------------------

func blend_to_ragdoll(duration: float = 0.3) -> void:
	var tw := create_tween()
	tw.tween_property(self, "physics_blend", 1.0, duration).set_ease(Tween.EASE_IN)


func blend_to_animation(duration: float = 0.3) -> void:
	var tw := create_tween()
	tw.tween_property(self, "physics_blend", 0.0, duration).set_ease(Tween.EASE_OUT)
