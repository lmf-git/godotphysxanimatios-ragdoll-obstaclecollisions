## build_physics_skeleton.gd
## EditorScript — run once via Tools → Execute Script.
## Generates res://characters/PhysicsCharacter.tscn with correctly configured
## PhysicalBone3D nodes baked in, so main.gd no longer has to create them at runtime.
@tool
extends EditorScript

const MASTER_PATH := "res://characters/Master.fbx"
const OUTPUT_PATH := "res://characters/PhysicsCharacter.tscn"

const SKIP_BONE_FRAGMENTS: Array[String] = [
	"ik", "pole", "ctrl", "_end",
	"index", "middle", "ring", "pinky", "thumb", "toe",
	"hand",
	"neck",
	"shoulder",
]


func _run() -> void:
	var master_scene := load(MASTER_PATH) as PackedScene
	if master_scene == null:
		printerr("[build] Could not load ", MASTER_PATH)
		return

	var root := master_scene.instantiate()
	var skeleton := _find_skeleton(root)
	if skeleton == null:
		printerr("[build] No Skeleton3D found in Master.fbx")
		root.free()
		return

	# Remove any existing PhysicalBoneSimulator3D children before building.
	for child in skeleton.get_children():
		if child is PhysicalBoneSimulator3D:
			skeleton.remove_child(child)
			child.queue_free()

	var simulator := PhysicalBoneSimulator3D.new()
	simulator.name = "PhysicalBoneSimulator3D"
	skeleton.add_child(simulator)
	simulator.owner = root

	var created := 0
	for i in skeleton.get_bone_count():
		var bone_name: String = skeleton.get_bone_name(i)
		if _skip_bone(bone_name):
			continue

		var length := _estimate_bone_length(skeleton, i)
		length = clampf(length, 0.02, 0.8)
		var radius := clampf(length * 0.2, 0.008, 0.14)

		var shape := CapsuleShape3D.new()
		shape.radius = radius
		shape.height = maxf(length, radius * 2.2)

		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		col.shape = shape

		var pb := PhysicalBone3D.new()
		pb.name = "Physical_" + bone_name.replace(":", "_").replace(" ", "_")
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
		pb.bone_name = bone_name
		_apply_bone_profile(pb, bone_name)
		pb.collision_layer = 4
		pb.collision_mask  = 5

		simulator.add_child(pb)
		pb.owner = root
		pb.add_child(col)
		col.owner = root

		# Compute joint_offset from rest pose so the CONE Z axis points along the bone.
		# This mirrors _fix_joint_frames_from_bind_pose() but uses get_bone_global_rest()
		# instead of runtime global_transform (no physics server needed here).
		_set_joint_offset_from_rest(skeleton, pb, i)

		_apply_joint_limits(pb, bone_name)
		_apply_collision_shape(pb, bone_name, col)

		created += 1

	print("[build] Created %d physical bones." % created)

	var packed := PackedScene.new()
	packed.pack(root)
	root.free()

	var err := ResourceSaver.save(packed, OUTPUT_PATH)
	if err == OK:
		print("[build] Saved to ", OUTPUT_PATH)
	else:
		printerr("[build] Save failed: error ", err)


# ---------------------------------------------------------------------------
# Bone selection
# ---------------------------------------------------------------------------

func _skip_bone(bone_name: String) -> bool:
	var lower := bone_name.to_lower()
	for frag in SKIP_BONE_FRAGMENTS:
		if lower.contains(frag):
			return true
	if bone_name.ends_with("Spine") or bone_name.ends_with("Spine1"):
		return true
	return false


func _estimate_bone_length(skeleton: Skeleton3D, bone_idx: int) -> float:
	var my_global := skeleton.get_bone_global_rest(bone_idx)
	var best := 0.0
	for j in skeleton.get_bone_count():
		if skeleton.get_bone_parent(j) == bone_idx:
			var d := my_global.origin.distance_to(skeleton.get_bone_global_rest(j).origin)
			if d > best:
				best = d
	if best > 0.0:
		return best
	var parent := skeleton.get_bone_parent(bone_idx)
	if parent >= 0:
		return my_global.origin.distance_to(skeleton.get_bone_global_rest(parent).origin) * 0.5
	return 0.15


# ---------------------------------------------------------------------------
# Joint offset from rest pose
# ---------------------------------------------------------------------------

func _set_joint_offset_from_rest(skeleton: Skeleton3D, pb: PhysicalBone3D, bone_idx: int) -> void:
	# Find the nearest ancestor physical bone.
	var parent_idx := skeleton.get_bone_parent(bone_idx)
	var parent_rest: Transform3D
	var found_parent := false
	while parent_idx >= 0:
		var parent_name: String = skeleton.get_bone_name(parent_idx)
		if not _skip_bone(parent_name):
			parent_rest = skeleton.get_bone_global_rest(parent_idx)
			found_parent = true
			break
		parent_idx = skeleton.get_bone_parent(parent_idx)

	if not found_parent:
		# Root physical bone — leave joint_offset as identity.
		return

	var child_rest := skeleton.get_bone_global_rest(bone_idx)

	# Origin: child bone position in parent's local space.
	var new_origin := parent_rest.affine_inverse() * child_rest.origin

	# Basis: cone Z = direction from parent to child, in parent local space.
	var world_dir := child_rest.origin - parent_rest.origin
	var cone_z: Vector3
	if world_dir.length_squared() > 1e-6:
		cone_z = (parent_rest.basis.inverse() * world_dir.normalized()).normalized()
	else:
		cone_z = Vector3.FORWARD

	var up := Vector3.UP if abs(cone_z.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var cone_x := up.cross(cone_z).normalized()
	var cone_y := cone_z.cross(cone_x).normalized()
	pb.joint_offset = Transform3D(Basis(cone_x, cone_y, cone_z), new_origin)


# ---------------------------------------------------------------------------
# Collision shapes (anatomical sizes)
# ---------------------------------------------------------------------------

func _apply_collision_shape(pb: PhysicalBone3D, bone_name: String, col: CollisionShape3D) -> void:
	var cap := CapsuleShape3D.new()
	if   bone_name.ends_with("Hips"):
		cap.radius = 0.12;  cap.height = 0.25
	elif bone_name.ends_with("Spine2"):
		cap.radius = 0.10;  cap.height = 0.22
	elif bone_name.ends_with("Head"):
		cap.radius = 0.09;  cap.height = 0.16
	elif bone_name.ends_with("LeftArm") or bone_name.ends_with("RightArm"):
		cap.radius = 0.045; cap.height = 0.26
	elif bone_name.ends_with("LeftForeArm") or bone_name.ends_with("RightForeArm"):
		cap.radius = 0.035; cap.height = 0.24
	elif bone_name.ends_with("LeftHand") or bone_name.ends_with("RightHand"):
		cap.radius = 0.04;  cap.height = 0.08
	elif bone_name.ends_with("LeftUpLeg") or bone_name.ends_with("RightUpLeg"):
		cap.radius = 0.07;  cap.height = 0.40
	elif bone_name.ends_with("LeftLeg") or bone_name.ends_with("RightLeg"):
		cap.radius = 0.055; cap.height = 0.38
	elif bone_name.ends_with("LeftFoot") or bone_name.ends_with("RightFoot"):
		cap.radius = 0.05;  cap.height = 0.14
	else:
		cap.radius = 0.04;  cap.height = 0.10
	col.shape = cap


# ---------------------------------------------------------------------------
# Mass / damping profile
# ---------------------------------------------------------------------------

func _apply_bone_profile(pb: PhysicalBone3D, bone_name: String) -> void:
	pb.mass         = 1.0
	pb.linear_damp  = 1.5
	pb.angular_damp = 8.0
	if   bone_name.ends_with("Hips"):
		pb.mass = 20.0; pb.linear_damp = 2.0; pb.angular_damp = 30.0
	elif bone_name.ends_with("Spine") or bone_name.ends_with("Spine1"):
		pb.mass = 5.0;  pb.linear_damp = 2.0; pb.angular_damp = 20.0
	elif bone_name.ends_with("Spine2"):
		pb.mass = 4.0;  pb.linear_damp = 2.0; pb.angular_damp = 20.0
	elif bone_name.ends_with("Neck"):
		pb.mass = 1.5;  pb.angular_damp = 24.0
	elif bone_name.ends_with("Head"):
		pb.mass = 5.0;  pb.angular_damp = 24.0
	elif bone_name.ends_with("LeftShoulder") or bone_name.ends_with("RightShoulder"):
		pb.mass = 1.5
	elif bone_name.ends_with("LeftArm") or bone_name.ends_with("RightArm"):
		pb.mass = 2.0
	elif bone_name.ends_with("LeftForeArm") or bone_name.ends_with("RightForeArm"):
		pb.mass = 1.2;  pb.angular_damp = 10.0
	elif bone_name.ends_with("LeftHand") or bone_name.ends_with("RightHand"):
		pb.mass = 0.4;  pb.linear_damp = 3.0; pb.angular_damp = 12.0
	elif bone_name.ends_with("LeftUpLeg") or bone_name.ends_with("RightUpLeg"):
		pb.mass = 8.0;  pb.angular_damp = 10.0
	elif bone_name.ends_with("LeftLeg") or bone_name.ends_with("RightLeg"):
		pb.mass = 4.0
	elif bone_name.ends_with("LeftFoot") or bone_name.ends_with("RightFoot"):
		pb.mass = 1.2;  pb.linear_damp = 3.0; pb.angular_damp = 12.0
	else:
		pb.mass = 0.5;  pb.linear_damp = 3.0; pb.angular_damp = 15.0


# ---------------------------------------------------------------------------
# Joint limits
# ---------------------------------------------------------------------------

func _apply_joint_limits(pb: PhysicalBone3D, bone_name: String) -> void:
	var swing := 30.0
	var twist := 20.0
	if   bone_name.ends_with("Hips"):
		swing = 20.0;  twist = 15.0
	elif bone_name.ends_with("Spine2"):
		swing = 30.0;  twist = 20.0
	elif bone_name.ends_with("Head"):
		swing = 40.0;  twist = 30.0
	elif bone_name.ends_with("LeftArm") or bone_name.ends_with("RightArm"):
		swing = 80.0;  twist = 90.0
	elif bone_name.ends_with("LeftForeArm") or bone_name.ends_with("RightForeArm"):
		swing = 130.0; twist = 20.0
	elif bone_name.ends_with("LeftUpLeg") or bone_name.ends_with("RightUpLeg"):
		swing = 50.0;  twist = 30.0
	elif bone_name.ends_with("LeftLeg") or bone_name.ends_with("RightLeg"):
		swing = 140.0; twist = 10.0
	elif bone_name.ends_with("LeftFoot") or bone_name.ends_with("RightFoot"):
		swing = 35.0;  twist = 20.0

	pb.set("joint_constraints/swing_span", swing)
	pb.set("joint_constraints/twist_span", twist)
	pb.set("joint_constraints/bias",       0.3)
	pb.set("joint_constraints/softness",   0.8)
	pb.set("joint_constraints/relaxation", 1.0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null
