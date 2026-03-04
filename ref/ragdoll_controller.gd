class_name RagdollController
extends Node

## Manages transitions between animation and ragdoll physics.
## Also configures humanoid joint limits at startup (Mixamo rig).

signal ragdoll_started
signal ragdoll_stopped

@export var skeleton_path: NodePath = ^"../Skeleton3D"
@export var animation_player_path: NodePath = ^"../AnimationPlayer"
@export var idle_animation: String = ""

var is_ragdoll_active: bool = false

var _skeleton: Skeleton3D = null
var _animation_player: AnimationPlayer = null


func _ready() -> void:
	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	_animation_player = get_node_or_null(animation_player_path) as AnimationPlayer

	if not _skeleton:
		push_error("RagdollController: Skeleton3D not found at '%s'." % skeleton_path)
		return

	var bones := _get_physical_bones()
	print("RagdollController ready — skeleton: %s, physical bones found: %d" % [_skeleton.name, bones.size()])

	_configure_joints()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func start_ragdoll(impulse: Vector3 = Vector3.ZERO) -> void:
	if is_ragdoll_active or not _skeleton:
		return

	is_ragdoll_active = true

	if _animation_player and _animation_player.is_playing():
		_animation_player.stop()

	# Reset all bones to rest pose so physics always starts from a clean,
	# constraint-satisfying state. Skipping this means a second activation
	# starts from the fallen ragdoll pose → immediate joint violations → explosion.
	for i in _skeleton.get_bone_count():
		_skeleton.reset_bone_pose(i)

	# Give the skeleton one physics frame to update before handing off to physics.
	await get_tree().physics_frame

	# Recompute joint frames now that global_transforms reflect the live
	# bind pose (character at runtime position, bones reset above).
	# Running this at _ready() uses stale scene-file transforms.
	_fix_joint_frames_from_bind_pose()

	# Register exceptions BEFORE activating bodies so no inter-bone collision
	# is processed on the very first physics step (a common cause of blow-apart
	# on repeated resets).
	_apply_collision_exceptions()

	var sim := _skeleton.get_node_or_null(^"PhysicalBoneSimulator3D")
	if sim and sim.has_method(&"physical_bones_start_simulation"):
		sim.physical_bones_start_simulation()
	else:
		_skeleton.physical_bones_start_simulation()

	print("Simulation started — simulator: ", sim)

	if impulse != Vector3.ZERO:
		await get_tree().physics_frame
		_apply_impulse_to_all_bones(impulse)

	ragdoll_started.emit()


func stop_ragdoll() -> void:
	if not is_ragdoll_active or not _skeleton:
		return

	is_ragdoll_active = false

	var sim := _skeleton.get_node_or_null(^"PhysicalBoneSimulator3D")
	if sim and sim.has_method(&"physical_bones_stop_simulation"):
		sim.physical_bones_stop_simulation()
	else:
		_skeleton.physical_bones_stop_simulation()

	# Snap skeleton back to rest pose. Without this the skeleton stays in the
	# ragdoll's last fallen state, so the next start_ragdoll() begins with
	# joints already violated and immediately explodes.
	for i in _skeleton.get_bone_count():
		_skeleton.reset_bone_pose(i)

	if _animation_player and not idle_animation.is_empty():
		if _animation_player.has_animation(idle_animation):
			_animation_player.play(idle_animation)

	ragdoll_stopped.emit()


func apply_explosion_force(origin: Vector3, force: float = 500.0, radius: float = 5.0) -> void:
	if not is_ragdoll_active or not _skeleton:
		return

	for bone_body in _get_physical_bones():
		var dir := bone_body.global_position - origin
		var distance := dir.length()
		if distance < radius and distance > 0.001:
			var strength := (1.0 - distance / radius) * force
			bone_body.apply_central_impulse(dir.normalized() * strength)


func apply_hit_force(bone_name: String, force: Vector3, spread_radius: float = 0.5) -> void:
	if not is_ragdoll_active or not _skeleton:
		return

	var hit_bone := _find_physical_bone(bone_name)
	if not hit_bone:
		push_warning("RagdollController: PhysicalBone3D for '%s' not found." % bone_name)
		return

	hit_bone.apply_central_impulse(force)

	for bone_body in _get_physical_bones():
		if bone_body == hit_bone:
			continue
		var dist := bone_body.global_position.distance_to(hit_bone.global_position)
		if dist < spread_radius:
			bone_body.apply_central_impulse(force * (1.0 - dist / spread_radius) * 0.4)


# ---------------------------------------------------------------------------
# Joint configuration — mass / damping per bone
# ---------------------------------------------------------------------------
#
# Sets mass/damping/swing/twist on every bone at ready-time (before simulation
# starts). Joint offsets are left as-is from the scene — the physical skeleton
# wizard already aligns them correctly; re-computing them at runtime corrupts
# HINGE joint axes and causes the solver to explode on first frame.
# ---------------------------------------------------------------------------

func _configure_joints() -> void:
	for bone_body in _get_physical_bones():
		_apply_bone_profile(bone_body, bone_body.bone_name)
	_resize_collision_shapes()
	_setup_self_collision()


func _apply_bone_profile(bone: PhysicalBone3D, bname: String) -> void:
	# Default physics — overridden per region below.
	bone.linear_damp  = 1.5
	bone.angular_damp = 8.0

	# All angle values are in DEGREES, matching the PhysicalBone3D property API.
	# CONE joints use swing_span / twist_span.
	# HINGE joints use angular_limit_upper (positive) / angular_limit_lower (negative).
	# Both sets are always computed; _apply_joint_limits picks the right one by joint type.
	var swing        := 20.0
	var twist        := 15.0
	var hinge_upper  := 30.0
	var hinge_lower  := -30.0

	# --- Root (Hips): heaviest segment, high angular_damp resists backward tilt ---
	if bname.ends_with("Hips"):
		bone.mass         = 20.0
		bone.linear_damp  = 2.0
		bone.angular_damp = 30.0
		hinge_upper = 10.0;  hinge_lower = -10.0   # HINGE in scene; keep root almost locked
		swing = 15.0;        twist = 15.0

	# --- Lumbar / thoracic spine ---
	elif bname.ends_with("Spine") or bname.ends_with("Spine1"):
		bone.mass         = 5.0
		bone.linear_damp  = 2.0
		bone.angular_damp = 20.0
		hinge_upper = 25.0;  hinge_lower = -25.0
		swing = 18.0;        twist = 18.0

	elif bname.ends_with("Spine2"):
		bone.mass         = 4.0
		bone.linear_damp  = 2.0
		bone.angular_damp = 20.0
		hinge_upper = 35.0;  hinge_lower = -35.0
		swing = 18.0;        twist = 18.0

	# --- Neck ---
	elif bname.ends_with("Neck"):
		bone.mass         = 1.5
		bone.angular_damp = 24.0
		hinge_upper = 20.0;  hinge_lower = -20.0
		swing = 20.0;        twist = 20.0

	# --- Head ---
	elif bname.ends_with("Head"):
		bone.mass         = 5.0
		bone.angular_damp = 24.0
		hinge_upper = 25.0;  hinge_lower = -25.0
		swing = 25.0;        twist = 30.0

	# --- Clavicles ---
	elif bname.ends_with("LeftShoulder") or bname.ends_with("RightShoulder"):
		bone.mass = 1.5
		swing = 30.0;        twist = 30.0
		hinge_upper = 30.0;  hinge_lower = -30.0

	# --- Upper arms (shoulder ball-socket — CONE) ---
	elif bname.ends_with("LeftArm") or bname.ends_with("RightArm"):
		bone.mass = 2.0
		swing = 60.0;        twist = 90.0

	# --- Forearms (elbow hinge — flexes one way only) ---
	elif bname.ends_with("LeftForeArm") or bname.ends_with("RightForeArm"):
		bone.mass         = 1.2
		bone.angular_damp = 10.0
		hinge_upper = 0.0;   hinge_lower = -120.0

	# --- Hands (wrist hinge) ---
	elif bname.ends_with("LeftHand") or bname.ends_with("RightHand"):
		bone.mass         = 0.4
		bone.linear_damp  = 3.0
		bone.angular_damp = 12.0
		hinge_upper = 30.0;  hinge_lower = -90.0

	# --- Thighs (hip ball-socket — CONE) ---
	elif bname.ends_with("LeftUpLeg") or bname.ends_with("RightUpLeg"):
		bone.mass         = 8.0
		bone.angular_damp = 10.0
		swing = 45.0;        twist = 30.0

	# --- Shins (knee hinge — flexes backward only) ---
	elif bname.ends_with("LeftLeg") or bname.ends_with("RightLeg"):
		bone.mass = 4.0
		hinge_upper = 0.0;   hinge_lower = -150.0

	# --- Feet (ankle — CONE) ---
	elif bname.ends_with("LeftFoot") or bname.ends_with("RightFoot"):
		bone.mass         = 1.2
		bone.linear_damp  = 3.0
		bone.angular_damp = 12.0
		swing = 30.0;        twist = 20.0

	# --- Toes / fingers ---
	else:
		bone.mass         = 0.2
		bone.linear_damp  = 3.0
		bone.angular_damp = 15.0
		swing = 20.0;        twist = 15.0
		hinge_upper = 20.0;  hinge_lower = -20.0

	_apply_joint_limits(bone, hinge_upper, hinge_lower, swing, twist)


func _apply_joint_limits(bone: PhysicalBone3D,
		hinge_upper: float, hinge_lower: float,
		swing: float, twist: float) -> void:
	if bone.joint_type == PhysicalBone3D.JOINT_TYPE_HINGE:
		bone.set("joint_constraints/angular_limit_enabled",    true)
		bone.set("joint_constraints/angular_limit_upper",      hinge_upper)
		bone.set("joint_constraints/angular_limit_lower",      hinge_lower)
		bone.set("joint_constraints/angular_limit_bias",       0.3)
		bone.set("joint_constraints/angular_limit_softness",   0.9)
		bone.set("joint_constraints/angular_limit_relaxation", 1.0)
	elif bone.joint_type == PhysicalBone3D.JOINT_TYPE_CONE:
		bone.set("joint_constraints/swing_span", swing)
		bone.set("joint_constraints/twist_span", twist)
		bone.set("joint_constraints/bias",       0.3)
		bone.set("joint_constraints/softness",   0.8)
		bone.set("joint_constraints/relaxation", 1.0)
	# JOINT_TYPE_NONE / others: no constraint properties


func _fix_joint_frames_from_bind_pose() -> void:
	# Fix joint_offset for bones whose direct skeleton parent was deleted and
	# replaced by a more distant physical ancestor.  Only these bones need
	# correction — for direct parent-child pairs the wizard values are correct.
	#
	# Two fixes per affected bone:
	#   ORIGIN  — the pivot position was stored relative to the deleted bone's
	#             local space; re-express it in the actual physical parent's space.
	#   BASIS   — CONE_TWIST joints also need the cone axis realigned with the
	#             child's actual orientation (e.g. arms extend ~90° away from
	#             the spine, so an identity joint_offset gives a ~90° initial
	#             violation → explosion).  HINGE axes are not changed because
	#             the saved basis already encodes the correct flex direction.
	var bones := _get_physical_bones()
	var bone_map: Dictionary = {}
	for b in bones:
		bone_map[b.bone_name] = b

	for b in bones:
		var bone_idx       := _skeleton.find_bone(b.bone_name)
		var direct_par_idx := _skeleton.get_bone_parent(bone_idx)
		if direct_par_idx < 0:
			continue
		# Skip bones whose direct skeleton parent has a physical body —
		# the wizard already computed a correct joint_offset for them.
		if bone_map.has(_skeleton.get_bone_name(direct_par_idx)):
			continue

		var phys_parent := _walk_to_physical_parent(b.bone_name, bone_map)
		if phys_parent == null:
			continue

		# Origin: pivot at this bone's world position, in the physical parent's space.
		var new_origin: Vector3 = phys_parent.global_transform.affine_inverse() \
				* b.global_transform.origin

		# Basis: for CONE_TWIST, realign cone axis with child orientation in
		# parent's space → zero initial angular violation.
		# For HINGE, keep the existing basis (already encodes the correct axis).
		var new_basis: Basis
		if b.joint_type == PhysicalBone3D.JOINT_TYPE_CONE:
			new_basis = (phys_parent.global_transform.basis.inverse() \
					* b.global_transform.basis).orthonormalized()
		else:
			new_basis = b.joint_offset.basis

		b.joint_offset = Transform3D(new_basis, new_origin)


func _resize_collision_shapes() -> void:
	# The auto-generated capsule shapes are proportional to bone length, which
	# produces absurdly small colliders (Hips = 1 cm radius, 10 cm tall).
	# A 20 kg pelvis hitting the floor with a 1 cm capsule creates enormous
	# penetration-correction forces that blow joints apart.
	# Replace each shape with an anatomically scaled one (for a ~1.7 m character).
	for bone in _get_physical_bones():
		var col := bone.get_node_or_null(^"CollisionShape3D") as CollisionShape3D
		if col == null:
			continue
		var cap := CapsuleShape3D.new()
		var bname: String = bone.bone_name
		if   bname.ends_with("Hips"):
			cap.radius = 0.12;  cap.height = 0.25
		elif bname.ends_with("Spine2"):
			cap.radius = 0.10;  cap.height = 0.22
		elif bname.ends_with("Head"):
			cap.radius = 0.09;  cap.height = 0.16
		elif bname.ends_with("LeftArm") or bname.ends_with("RightArm"):
			cap.radius = 0.045; cap.height = 0.26
		elif bname.ends_with("LeftForeArm") or bname.ends_with("RightForeArm"):
			cap.radius = 0.035; cap.height = 0.24
		elif bname.ends_with("LeftHand") or bname.ends_with("RightHand"):
			cap.radius = 0.04;  cap.height = 0.08
		elif bname.ends_with("LeftUpLeg") or bname.ends_with("RightUpLeg"):
			cap.radius = 0.07;  cap.height = 0.40
		elif bname.ends_with("LeftLeg") or bname.ends_with("RightLeg"):
			cap.radius = 0.055; cap.height = 0.38
		elif bname.ends_with("LeftFoot") or bname.ends_with("RightFoot"):
			cap.radius = 0.05;  cap.height = 0.14
		else:
			cap.radius = 0.04;  cap.height = 0.10
		# Keep the CollisionShape3D's existing local transform — it orients
		# the capsule axis along the correct bone direction.
		col.shape = cap


func _setup_self_collision() -> void:
	# Layer 2 (bit 1) is the ragdoll self-collision layer.
	# Bones remain on layer 1 so they still interact with the environment.
	# Layer/mask are node properties — set once at ready, they persist forever.
	for bone in _get_physical_bones():
		bone.collision_layer |= 2
		bone.collision_mask  |= 2

	# Exceptions are registered on the physics server with body RIDs.
	# They may be dropped when simulation restarts, so we re-apply them
	# in start_ragdoll() as well as here.
	_apply_collision_exceptions()


func _apply_collision_exceptions() -> void:
	var bones := _get_physical_bones()
	var bone_map: Dictionary = {}
	for bone in bones:
		bone_map[bone.bone_name] = bone

	# Exclude each bone from its nearest physical ancestor. Walk UP the
	# skeleton hierarchy because intermediate bones may have been removed
	# (e.g. Neck, Shoulder, Spine1), leaving gaps where the physics joint
	# skips multiple levels. Without this, pairs like Hips↔Spine2 or
	# Spine2↔Head have no exception — their capsules overlap at simulation
	# start and the solver explodes.
	for bone in bones:
		var phys_parent := _walk_to_physical_parent(bone.bone_name, bone_map)
		if phys_parent:
			PhysicsServer3D.body_add_collision_exception(
					bone.get_rid(), phys_parent.get_rid())


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _apply_impulse_to_all_bones(impulse: Vector3) -> void:
	var bones := _get_physical_bones()
	if bones.is_empty():
		return
	var per_bone := impulse / bones.size()
	for bone_body in bones:
		# Small fixed jitter so each bone tumbles slightly differently.
		var jitter := Vector3(
			randf_range(-0.5, 0.5),
			randf_range(-0.2, 0.5),
			randf_range(-0.5, 0.5)
		)
		bone_body.apply_central_impulse(per_bone + jitter)


func _walk_to_physical_parent(bone_name: String, bone_map: Dictionary) -> PhysicalBone3D:
	var idx := _skeleton.get_bone_parent(_skeleton.find_bone(bone_name))
	while idx >= 0:
		var ancestor: PhysicalBone3D = bone_map.get(_skeleton.get_bone_name(idx))
		if ancestor:
			return ancestor
		idx = _skeleton.get_bone_parent(idx)
	return null


func _get_physical_bones() -> Array[PhysicalBone3D]:
	var result: Array[PhysicalBone3D] = []
	if _skeleton:
		_collect_physical_bones(_skeleton, result)
	return result


func _collect_physical_bones(node: Node, result: Array[PhysicalBone3D]) -> void:
	for child in node.get_children():
		if child is PhysicalBone3D:
			result.append(child)
		if child.get_child_count() > 0:
			_collect_physical_bones(child, result)


func _find_physical_bone(bone_name: String) -> PhysicalBone3D:
	for bone_body in _get_physical_bones():
		if bone_body.name == "Physical Bone " + bone_name or bone_body.name == bone_name:
			return bone_body
	return null
