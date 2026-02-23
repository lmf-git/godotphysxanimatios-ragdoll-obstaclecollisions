## main.gd — attach to the root Node3D in main.tscn.
extends Node3D

const MASTER_PATH := "res://characters/Master.fbx"
const ANIM_DIR    := "res://animations/"

const SKIP_BONE_FRAGMENTS: Array[String] = [
	"ik", "pole", "ctrl", "_end",
	# Finger and toe phalanges are too small for stable joint simulation.
	# They detach under impulse loads and add no meaningful ragdoll benefit.
	# They stay kinematic — the animation drives them directly.
	"index", "middle", "ring", "pinky", "thumb", "toe",
]

const BONE_LIMITS: Dictionary = {
	# Hips / spine — tight so the ragdoll can't fold in on itself.
	"hips":     Vector3(20,  20,  22),
	"spine":    Vector3(15,  15,  15),
	"neck":     Vector3(40,  40,  30),
	"head":     Vector3(40,  40,  30),
	# Shoulder / arm — generous ball-socket range for natural animation.
	"shoulder": Vector3(65,  65,  65),
	"arm":      Vector3(95,  95,  95),
	# Wide X/Z so the spring can track forearm roll / pronation; Y = elbow flex.
	"forearm":  Vector3(80, 150,  80),
	"hand":     Vector3(55,  55,  55),
	# Legs — limit hip flexion so knees don't swing wild; knee stays hinge-like.
	"upleg":    Vector3(65,  45,  35),
	"leg":      Vector3(5,  140,   5),
	"foot":     Vector3(45,  28,  20),
}

# ---------------------------------------------------------------------------
# Rig references
# ---------------------------------------------------------------------------

var _anim_skeleton: Skeleton3D
var _phys_skeleton: Skeleton3D
var _vis_skeleton:  Skeleton3D
var _anim_player:   AnimationPlayer
var _phys_driver:   Node3D   # carries physical_animation.gd
var _vis_driver:    Node3D   # carries interpolated_animation.gd

var _anim_container: Node3D
var _phys_container: Node3D
var _vis_container:  Node3D
var _simulator: PhysicalBoneSimulator3D
## bone_id (int) → PhysicalBone3D — built once, shared with vis_driver.
var _phys_bone_map: Dictionary = {}
## Ordered list of target bones for ball cycling.
var _ball_targets: Array[PhysicalBone3D] = []
var _shot_count: int = 0

## Invisible capsule that gives the character solid collision against walls.
var _char_body: CharacterBody3D
## 0=VisualRig only  1=VisualRig+ghost  2=ghost only
var _vis_mode: int = 0
## Active tween restoring spring stiffness after knockback.
var _recovery_tween: Tween

# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------

var _anim_keys: Array[String] = []
var _anim_idx:  int = 0

# Locomotion animations (auto-detected by name after loading)
var _anim_idle:     String = ""
var _anim_walk_fwd: String = ""
var _anim_walk_bwd: String = ""
var _anim_jump:     String = ""
var _loco_state:    String = ""   # "idle" | "walk_fwd" | "walk_bwd" | "jump"

# ---------------------------------------------------------------------------
# Character movement
# ---------------------------------------------------------------------------

var _char_pos: Vector3 = Vector3(0.0, 0.1, 0.0)
var _char_yaw: float   = 0.0   # radians — 0 = faces +Z (Mixamo FBX default in Godot)
## Previous-frame values used to compute the per-physics-step container delta.
var _prev_char_pos: Vector3 = Vector3(0.0, 0.1, 0.0)
var _prev_char_yaw: float   = 0.0

var _is_grounded:   bool  = true
var _vert_velocity: float = 0.0

const MOVE_SPEED  := 2.5   # m/s
const TURN_SPEED  := 2.0   # rad/s
const JUMP_SPEED  := 5.5   # m/s  upward launch velocity
const GRAVITY     := 14.0  # m/s² downward acceleration

# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

var _camera: Camera3D

const CAM_DIST   := 4.0    # metres behind character
const CAM_HEIGHT := 1.6    # metres above character root
const CAM_LERP   := 14.0   # follow smoothness — higher keeps camera tighter behind character

# ---------------------------------------------------------------------------
# Ragdoll state machine
# ---------------------------------------------------------------------------

enum RagdollMode { ANIMATED, ACTIVE, LIMP }
var _mode: RagdollMode = RagdollMode.ANIMATED
var _knockback_busy: bool = false
var _hit_count: int = 0


# ===========================================================================
# Setup
# ===========================================================================

func _ready() -> void:
	print("[main] Loading Master.fbx…")
	var master: PackedScene = load(MASTER_PATH)
	if master == null:
		push_error("[main] Could not load '%s'" % MASTER_PATH)
		return

	# 1. AnimatedRig — ghost, drives the animation reference pose
	var anim_root := await _make_rig("AnimatedRig", master)
	_anim_skeleton = _find_skeleton(anim_root)
	_make_ghost(anim_root)
	_setup_animation_player(anim_root)
	print("[main] AnimatedRig ready. Bones: %d" % _anim_skeleton.get_bone_count())

	# 2. PhysicsRig — invisible, runs PhysicalBone3D simulation
	var phys_root := await _make_rig("PhysicsRig", master)
	_phys_skeleton = _find_skeleton(phys_root)
	_hide_meshes(phys_root)
	_create_physical_bones(_phys_skeleton)

	# Build bone_id → PhysicalBone3D map FIRST so the simulation check and
	# force-RIGID fallback below can use it.
	_build_phys_bone_map(_phys_skeleton)
	_build_ball_targets()
	_disable_bone_self_collision()
	print("[main] Bone map: %d entries, %d targets." % [_phys_bone_map.size(), _ball_targets.size()])

	# PhysicalBone3D bodies need at least one physics frame to register with the server.
	await get_tree().physics_frame
	_simulator.active = true
	# Call start_simulation on the simulator directly — more reliable than going via Skeleton3D.
	_simulator.physical_bones_start_simulation()
	# PhysicalBoneSimulator3D is a SkeletonModifier3D — it runs _process_modification()
	# during the skeleton's process step, NOT the physics step.  Wait one process frame
	# so the modifier fires and actually flips the bones to dynamic mode, then a physics
	# frame so the PhysicsServer registers the new body mode before we query it.
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Diagnostic: print the actual PhysicsServer3D body mode (0=Static,1=Kinematic,2=Rigid).
	if not _phys_bone_map.is_empty():
		var first_pb: PhysicalBone3D = _phys_bone_map.values()[0] as PhysicalBone3D
		var mode := PhysicsServer3D.body_get_mode(first_pb.get_rid())
		print("[main] Simulator active: %s  — bones: %d  — first bone mode: %d  — simulating: %s" % [
			_simulator.active, _phys_bone_map.size(), mode, first_pb.is_simulating_physics()])
	else:
		print("[main] Simulator active: %s  — bone map EMPTY" % _simulator.active)

	# Create driver BEFORE add_child so _ready() sees valid references.
	_phys_driver = Node3D.new()
	_phys_driver.name = "PhysDriver"
	_phys_driver.set_script(load("res://scripts/physical_animation.gd"))
	_phys_driver.set("target_skeleton", _anim_skeleton)
	_phys_driver.set("phys_body_map",   _phys_bone_map)
	_phys_driver.set("spring_enabled",  true)
	phys_root.add_child(_phys_driver)
	print("[main] PhysicsRig ready.")

	# 3. VisualRig — the mesh the player sees
	var vis_root := await _make_rig("VisualRig", master)
	_vis_skeleton = _find_skeleton(vis_root)

	_vis_driver = Node3D.new()
	_vis_driver.name = "BoneDriver"
	_vis_driver.set_script(load("res://scripts/interpolated_animation.gd"))
	_vis_driver.set("visual_skeleton",   _vis_skeleton)
	_vis_driver.set("physics_skeleton",  _phys_skeleton)
	_vis_driver.set("animated_skeleton", _anim_skeleton)
	_vis_driver.set("physics_blend",     0.0)   # animation drives visual until physics is confirmed
	_vis_driver.set("phys_bone_map",     _phys_bone_map)
	vis_root.add_child(_vis_driver)
	print("[main] VisualRig ready.")

	# Save container references so we can move them all together.
	_anim_container = get_node("AnimatedRig")
	_phys_container = get_node("PhysicsRig")
	_vis_container  = get_node("VisualRig")

	_camera = get_viewport().get_camera_3d()
	_update_camera(99.0)   # instant snap on first frame

	_make_ledge()

	# Invisible capsule — wall/ledge collision for WASD movement only.
	# Layer 2 / mask 1: the capsule stops against layer-1 static geometry
	# (ledges, walls) but is invisible to balls and physics bones which both
	# sit on layer 1.  This prevents the capsule from intercepting ball shots
	# before they reach the physics bones and from blocking bone↔ledge contact.
	_char_body = CharacterBody3D.new()
	_char_body.name = "CharacterBody"
	_char_body.collision_layer = 2   # invisible to layer-1 scanners
	_char_body.collision_mask  = 1   # detects layer-1 static geometry
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 0.9   # covers legs/hips only — upper body reacts to ledge via physics bones
	var cap_col := CollisionShape3D.new()
	cap_col.shape = cap
	cap_col.position = Vector3(0.0, 0.45, 0.0)
	_char_body.add_child(cap_col)
	add_child(_char_body)
	_char_body.global_position = _char_pos

	print("[main] Controls: WASD=move  Space=jump  P=limp  O=toggle-meshes  U=next-anim  LClick=shoot  R=reload")
	# Initialise visibility: vis_mode=0 → visual mesh only, ghost hidden.
	_update_rig_visibility()
	# Restart simulation properly (stop→start) so bones go RIGID, then enable springs.
	# physics_blend stays 0.0 until this completes to avoid a T-pose flash.
	_go_animated_async()


# ===========================================================================
# Per-frame
# ===========================================================================

func _process(delta: float) -> void:
	_handle_movement(delta)
	_update_containers()
	_update_camera(delta)
	_update_locomotion_anim()


func _physics_process(_delta: float) -> void:
	_carry_bodies_with_container()


func _handle_movement(delta: float) -> void:
	# Character faces +Z: positive yaw = CW from above = turns right.
	if Input.is_key_pressed(KEY_A):
		_char_yaw -= TURN_SPEED * delta   # CCW = turn left
	if Input.is_key_pressed(KEY_D):
		_char_yaw += TURN_SPEED * delta   # CW  = turn right

	var fwd_input := 0.0
	if Input.is_key_pressed(KEY_W): fwd_input += 1.0
	if Input.is_key_pressed(KEY_S): fwd_input -= 1.0

	if fwd_input != 0.0:
		var forward := Basis(Vector3.UP, _char_yaw) * Vector3(0.0, 0.0, 1.0)
		if _char_body != null:
			# Sync capsule to current character position, then slide with collision.
			_char_body.global_position = _char_pos
			_char_body.velocity = Vector3(forward.x, 0.0, forward.z) * fwd_input * MOVE_SPEED
			_char_body.move_and_slide()
			_char_pos.x = _char_body.global_position.x
			_char_pos.z = _char_body.global_position.z
		else:
			_char_pos += forward * fwd_input * MOVE_SPEED * delta

	# Jump — only when grounded and in animated mode (not ragdoll).
	if Input.is_key_pressed(KEY_SPACE) and _is_grounded and _mode == RagdollMode.ANIMATED:
		_vert_velocity = JUMP_SPEED
		_is_grounded   = false

	# Vertical integration — gravity when airborne, snap to floor when landed.
	if not _is_grounded:
		_vert_velocity -= GRAVITY * delta
		_char_pos.y    += _vert_velocity * delta
		if _char_pos.y <= 0.1:
			_char_pos.y    = 0.1
			_vert_velocity = 0.0
			_is_grounded   = true
	else:
		_char_pos.y = 0.1


func _update_containers() -> void:
	# Character faces +Z in the FBX.  No extra rotation needed — camera and
	# movement are set up for a +Z-facing character.
	var t := Transform3D(Basis(Vector3.UP, _char_yaw), _char_pos)
	if is_instance_valid(_anim_container): _anim_container.transform = t
	if is_instance_valid(_phys_container): _phys_container.transform = t
	if is_instance_valid(_vis_container):  _vis_container.transform  = t


func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	# Character faces +Z, so "behind" is the -Z side.
	var back := Basis(Vector3.UP, _char_yaw) * Vector3(0.0, 0.0, -1.0)
	var cam_target := _char_pos + back * CAM_DIST + Vector3(0.0, CAM_HEIGHT, 0.0)
	var t := minf(CAM_LERP * delta, 1.0)
	_camera.global_position = _camera.global_position.lerp(cam_target, t)
	_camera.look_at(_char_pos + Vector3(0.0, 1.0, 0.0), Vector3.UP)


func _carry_bodies_with_container() -> void:
	# Physics bodies live in world space — the physics server has no knowledge of the
	# Node3D container hierarchy.  When the character moves or turns, the container
	# transforms update instantly but the rigid bodies remain at their old world
	# positions.  This causes two visible bugs:
	#   1. The physical/visual mesh doesn't rotate with the character.
	#   2. interpolated_animation.gd's (inv_skel * phys_xform) gives wrong local
	#      positions because inv_skel has rotated but phys_xform hasn't.
	#
	# Fix: every physics step compute the container's translation + yaw delta and
	# directly carry each body to its new world position, then rotate its velocity
	# into the new frame.  The spring then handles only small pose corrections.

	var yaw_delta := _char_yaw - _prev_char_yaw
	var pos_delta := _char_pos  - _prev_char_pos
	var from_pos  := _prev_char_pos   # pivot for the yaw orbit

	# Always keep prev in sync regardless of mode so deltas stay accurate.
	_prev_char_yaw = _char_yaw
	_prev_char_pos = _char_pos

	# Only carry bodies in animated mode while the spring is active.
	# During limp the ragdoll should fall freely; during the async rebuild
	# (spring_enabled == false) bodies are kinematic and are being reset.
	if _mode != RagdollMode.ANIMATED or _phys_bone_map.is_empty():
		return
	if is_instance_valid(_phys_driver) and not _phys_driver.get("spring_enabled"):
		return

	if absf(yaw_delta) < 1e-6 and pos_delta.length_squared() < 1e-8:
		return

	var rot := Basis(Vector3.UP, yaw_delta)

	for id: int in _phys_bone_map:
		var pb: PhysicalBone3D = _phys_bone_map[id]
		if not is_instance_valid(pb):
			continue
		# Orbit around the OLD character pivot, then shift to new position.
		pb.global_position  = _char_pos + rot * (pb.global_position - from_pos)
		# Rotate existing velocity into the new frame so spring corrections
		# remain valid after the container has turned.
		pb.linear_velocity  = rot * pb.linear_velocity
		pb.angular_velocity = rot * pb.angular_velocity


# ===========================================================================
# Input
# ===========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_shoot_ball()
			return

	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed:
		return
	match key.keycode:
		KEY_P:
			_toggle_mode(RagdollMode.LIMP)
		KEY_O:
			_vis_mode = (_vis_mode + 1) % 3
			_update_rig_visibility()
		KEY_U:
			_next_animation()
		KEY_R:
			get_tree().reload_current_scene()


# ---------------------------------------------------------------------------
# Ragdoll mode switching
# ---------------------------------------------------------------------------

func _toggle_mode(new_mode: RagdollMode) -> void:
	_set_ragdoll_mode(RagdollMode.ANIMATED if _mode == new_mode else new_mode)


func _update_rig_visibility() -> void:
	# 0 = visual only  |  1 = visual + animated ghost  |  2 = ghost only
	if is_instance_valid(_vis_container):
		_vis_container.visible  = (_vis_mode != 2)
	if is_instance_valid(_anim_container):
		_anim_container.visible = (_vis_mode != 0)
	var labels := ["Visual only", "Visual + ghost", "Ghost only"]
	print("[main] Mesh view: %s" % labels[_vis_mode])


func _set_ragdoll_mode(mode: RagdollMode) -> void:
	_mode = mode
	match mode:
		RagdollMode.ANIMATED:
			_hit_count = 0
			# Restore body damping that was reduced during limp.
			for id: int in _phys_bone_map:
				var pb: PhysicalBone3D = _phys_bone_map[id]
				if is_instance_valid(pb):
					pb.linear_damp  = 0.8
					pb.angular_damp = 0.8
			# Visual temporarily goes animation-driven while simulation restarts.
			if is_instance_valid(_vis_driver): _vis_driver.set("physics_blend", 0.0)
			# Resume animation and let locomotion system pick the right clip.
			_loco_state = ""
			if is_instance_valid(_anim_player):
				var key := _anim_idle if not _anim_idle.is_empty() \
						else (_anim_keys[0] if not _anim_keys.is_empty() else "")
				if not key.is_empty():
					_anim_player.play(key)
			# Restart simulation so joints rebuild at animation pose, then re-enable springs.
			_go_animated_async()
			print("[main] Mode: Animated")
		RagdollMode.ACTIVE:
			if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", true)
			if is_instance_valid(_vis_driver):  _vis_driver.set("physics_blend", 1.0)
			print("[main] Mode: Active Ragdoll")
		RagdollMode.LIMP:
			if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", false)
			if is_instance_valid(_vis_driver):  _vis_driver.set("physics_blend", 1.0)
			# Pause animation — springs are off so the animated skeleton no longer matters.
			if is_instance_valid(_anim_player): _anim_player.pause()
			_loco_state = ""
			_is_grounded   = true
			_vert_velocity = 0.0
			# Kill any active knockback recovery so a stale tween can't corrupt
			# spring stiffness when returning to animated later.
			if _recovery_tween:
				_recovery_tween.kill()
				_recovery_tween = null
			_knockback_busy = false
			# IMPORTANT: we do NOT change joint_type or angular limits here.
			# Changing joint parameters while simulation is running (or after stop/restart
			# with scattered bones) causes _reload_joint() to create joints from wrong
			# anchor positions → bones disconnect.  The existing 6DOF joints from
			# start_simulation() have correct anchors; just let gravity do its work.
			# We only adjust damping — higher on torso/spine/hips so the trunk doesn't
			# fold over, lower on limbs so arms and legs flop naturally.
			for id: int in _phys_bone_map:
				var pb: PhysicalBone3D = _phys_bone_map[id]
				if not is_instance_valid(pb):
					continue
				var low := pb.name.to_lower()
				var is_torso := "hip" in low or "spine" in low or "pelvis" in low \
						or "chest" in low or "neck" in low
				pb.linear_damp  = 0.8
				pb.angular_damp = 10.0 if is_torso else 3.0
			print("[main] Mode: Limp Ragdoll (P to exit)")



func _go_animated_async() -> void:
	# Keep springs off until joints have been rebuilt.
	if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", false)
	_simulator.physical_bones_stop_simulation()
	# PhysicalBoneSimulator3D writes the animation pose back to physics bodies
	# in _process_modification(), which runs during the PROCESS frame — not the
	# physics frame.  We must wait for it before restarting, otherwise bones
	# start simulation from their old ragdoll positions and detach visually.
	await get_tree().process_frame
	await get_tree().physics_frame
	if _mode != RagdollMode.ANIMATED:
		return
	_simulator.physical_bones_start_simulation()
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _mode != RagdollMode.ANIMATED:
		return

	# Enable spring at 3× stiffness + high force caps so bodies converge fast
	# without violating joint constraints (teleporting after joints are anchored
	# causes constraint violations that fight the spring permanently).
	if is_instance_valid(_phys_driver):
		_phys_driver.set("spring_enabled",    true)
		_phys_driver.set("linear_stiffness",  1800.0)
		_phys_driver.set("angular_stiffness", 2400.0)
		_phys_driver.set("max_linear_force",  40.0)   # high cap → fast convergence
		_phys_driver.set("max_angular_force", 200.0)

	# Blend visual from animation → physics over 0.2 s so residual
	# convergence is hidden behind the animation pose.
	if is_instance_valid(_vis_driver):
		_vis_driver.set("physics_blend", 0.0)
		var tw := (_vis_driver as Node).create_tween()
		tw.tween_property(_vis_driver as Node, "physics_blend", 1.0, 0.2)

	# After 0.4 s bodies have converged — ramp stiffness and caps to the
	# impact-responsive normal values.
	get_tree().create_timer(0.4).timeout.connect(func():
		if _mode != RagdollMode.ANIMATED or not is_instance_valid(_phys_driver):
			return
		var ramp := create_tween()
		ramp.tween_property(_phys_driver, "linear_stiffness",  600.0, 0.3).set_ease(Tween.EASE_OUT)
		ramp.parallel().tween_property(_phys_driver, "angular_stiffness", 800.0, 0.3).set_ease(Tween.EASE_OUT)
		ramp.tween_property(_phys_driver, "max_linear_force",   30.0, 0.3).set_ease(Tween.EASE_OUT)
		ramp.parallel().tween_property(_phys_driver, "max_angular_force", 300.0, 0.3).set_ease(Tween.EASE_OUT)
	)
	print("[main] Animated: joints rebuilt, high-stiffness burst active")


# ---------------------------------------------------------------------------
# Animation cycling
# ---------------------------------------------------------------------------

func _next_animation() -> void:
	if _anim_keys.is_empty() or not is_instance_valid(_anim_player):
		print("[main] No animations loaded — wait for editor import to finish, then press R.")
		return
	_anim_idx = (_anim_idx + 1) % _anim_keys.size()
	var anim_name := _anim_keys[_anim_idx]
	_anim_player.play(anim_name, 0.3)   # 0.3 s cross-blend
	print("[main] Animation [%d/%d]: %s" % [_anim_idx + 1, _anim_keys.size(), anim_name])


# ===========================================================================
# Ball shooting
# ===========================================================================

func _shoot_ball() -> void:
	if _camera == null:
		return

	# Each shot targets the next body part in the cycle.
	var target_pos: Vector3
	var target_name: String = "chest"
	if not _ball_targets.is_empty():
		var target_bone: PhysicalBone3D = _ball_targets[_shot_count % _ball_targets.size()]
		if is_instance_valid(target_bone):
			target_pos  = target_bone.global_position
			target_name = target_bone.name
		else:
			target_pos = _char_pos + Vector3(0.0, 1.0, 0.0)
	else:
		target_pos = _char_pos + Vector3(0.0, 1.0, 0.0)

	# Mass grows with each shot (1, 2, 3 … capped at 20).
	var mass   := minf(1.0 + _shot_count, 20.0)
	var radius := 0.08 + sqrt(mass) * 0.035   # visually larger as mass rises

	_shot_count += 1
	print("[main] Shot %d → %s  mass=%.1f  r=%.2f" % [_shot_count, target_name, mass, radius])

	var ball := RigidBody3D.new()
	ball.name  = "Ball"
	ball.mass  = mass
	ball.contact_monitor      = true
	ball.max_contacts_reported = 8
	# Same layer as physics bones so ball↔bone collision fires body_entered.
	# Mask 5 = layer 1 (ledge) + layer 4 (bones) so balls also bounce off walls.
	ball.collision_layer = 4
	ball.collision_mask  = 5

	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var col := CollisionShape3D.new()
	col.shape = sphere
	ball.add_child(col)

	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height  = radius * 2.0
	var mat := StandardMaterial3D.new()
	# Orange → dark red as mass increases.
	var t   := clampf((_shot_count - 1) / 19.0, 0.0, 1.0)
	mat.albedo_color = Color(1.0 - t * 0.5, 0.35 - t * 0.3, 0.05, 1.0)
	sm.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	ball.add_child(mi)

	add_child(ball)
	var cam_fwd   := -_camera.global_transform.basis.z
	var spawn_pos := _camera.global_position + cam_fwd * 1.5
	ball.global_position  = spawn_pos
	ball.linear_velocity  = (target_pos - spawn_pos).normalized() * 18.0

	var ball_ref: WeakRef = weakref(ball)
	# counted[0] is a mutable flag so all contacts from this ball share it.
	# A single shot can touch several bone capsules in one physics frame;
	# only the first contact should increment _hit_count.
	var counted := [false]
	ball.body_entered.connect(func(body: Node3D):
		var b := ball_ref.get_ref() as RigidBody3D
		if b: _on_ball_hit(body, b, counted))

	get_tree().create_timer(6.0).timeout.connect(func():
		var b := ball_ref.get_ref() as RigidBody3D
		if b: b.queue_free())


func _on_ball_hit(body: Node3D, ball: RigidBody3D, counted: Array) -> void:
	if not (body is PhysicalBone3D):
		return
	if not is_instance_valid(ball):
		return
	ball.collision_layer = 0
	ball.collision_mask  = 0
	var pb := body as PhysicalBone3D
	var impulse := ball.linear_velocity * 0.6
	pb.apply_impulse(impulse, Vector3(0.0, 0.15, 0.0))
	# Suspend the spring on the hit bone so it can react freely for 0.4 s
	# before being pulled back.  High-cap spring overwhelms any impulse
	# instantly; per-bone disable lets the impact register naturally.
	if is_instance_valid(_phys_driver):
		_phys_driver.call("disable_bone_spring", pb.get_bone_id(), 0.4)
	# Only count once per ball — a single shot can graze several bone
	# capsules in the same physics frame, firing body_entered multiple times.
	if counted[0]:
		return
	counted[0] = true
	print("[main] Ball hit: %s" % body.name)
	if _mode == RagdollMode.LIMP:
		return   # already limp — impulse applied, nothing else needed
	_hit_count += 1
	print("[main] Hit count: %d/3" % _hit_count)
	if _hit_count >= 3:
		_hit_count = 0
		_set_ragdoll_mode(RagdollMode.LIMP)
	else:
		_trigger_knockback()


func _trigger_knockback() -> void:
	if _knockback_busy or _mode == RagdollMode.LIMP:
		return
	_knockback_busy = true

	# Kill any in-progress recovery tween so a new hit always wins.
	if _recovery_tween:
		_recovery_tween.kill()
		_recovery_tween = null

	# Reduce spring stiffness to ~25 % for a brief stagger — the low damping
	# and cap values already allow per-limb impact response without needing
	# a full global collapse.  Spring stays enabled for a restoring force.
	if is_instance_valid(_phys_driver):
		_phys_driver.set("linear_stiffness",  150.0)   # ~25 % of normal
		_phys_driver.set("angular_stiffness", 200.0)

	get_tree().create_timer(0.5).timeout.connect(_recover_knockback)



func _recover_knockback() -> void:
	_knockback_busy = false
	if _mode != RagdollMode.ANIMATED:
		return   # user switched to a manual ragdoll mode — don't auto-recover
	if not is_instance_valid(_phys_driver):
		return
	# Tween stiffness back to normal over 0.5 s so the recovery feels gradual.
	_recovery_tween = create_tween()
	_recovery_tween.tween_property(_phys_driver, "linear_stiffness",  600.0, 0.5).set_ease(Tween.EASE_OUT)
	_recovery_tween.parallel().tween_property(_phys_driver, "angular_stiffness", 800.0, 0.5).set_ease(Tween.EASE_OUT)



# ---------------------------------------------------------------------------
# Locomotion — auto-play walk/idle based on WASD state
# ---------------------------------------------------------------------------

func _update_locomotion_anim() -> void:
	# Don't interrupt ragdoll/knockback.
	if _mode == RagdollMode.LIMP or _knockback_busy:
		return
	if _anim_idle.is_empty() or not is_instance_valid(_anim_player):
		return

	var new_state: String
	if not _is_grounded:              new_state = "jump"
	elif Input.is_key_pressed(KEY_W): new_state = "walk_fwd"
	elif Input.is_key_pressed(KEY_S): new_state = "walk_bwd"
	else:                             new_state = "idle"

	if new_state == _loco_state:
		return
	_loco_state = new_state

	var key: String
	match new_state:
		"jump":     key = _anim_jump     if not _anim_jump.is_empty()     else _anim_idle
		"walk_fwd": key = _anim_walk_fwd if not _anim_walk_fwd.is_empty() else _anim_idle
		"walk_bwd": key = _anim_walk_bwd if not _anim_walk_bwd.is_empty() else _anim_idle
		_:          key = _anim_idle

	if _anim_player.has_animation(key):
		_anim_player.play(key, 0.15)
		print("[main] Loco: %s → %s" % [new_state, key])


func _find_locomotion_keys() -> void:
	# Score-based selection: fewest words wins — simpler name = more likely a basic clip.
	# Extra penalty if the name includes "standing" (Mixamo's "Standing Idle" is often
	# a stylised/feminine pose; "Idle" or "Breathing Idle" is preferable).
	var idle_score     := 9999
	var walk_fwd_score := 9999
	var walk_bwd_score := 9999
	var jump_score     := 9999

	for k: String in _anim_keys:
		var low   := k.to_lower()
		var words := k.split(" ").size()

		# --- Idle ---
		var idle_neg := "fight" in low or "aim"       in low or "drunk"    in low \
				or "gun"      in low or "rifle"    in low or "dance"    in low \
				or "catwalk"  in low or "female"   in low or "feminine" in low \
				or "samba"    in low or "villain"  in low or "hostage"  in low \
				or "crime"    in low or "combat"   in low or "crouch"   in low \
				or "weapon"   in low or "shoot"    in low or "variation"in low \
				or "zombie"   in low or "hip"      in low
		if "idle" in low and not idle_neg:
			var score := words + (1 if "standing" in low else 0)
			if score < idle_score:
				idle_score = score
				_anim_idle = k

		# --- Walk forward ---
		var wf_neg := "back"    in low or "backward" in low or "catwalk" in low \
				or "rifle"    in low or "gun"      in low or "arc"     in low \
				or "turn"     in low or "stop"     in low or "twist"   in low \
				or "strafe"   in low or "zombie"   in low or "sneak"   in low \
				or "run"      in low or "jog"      in low or "crouch"  in low \
				or " right"   in low or " left"    in low or "injured" in low \
				or "drunk"    in low or "aim"      in low or "limp"    in low \
				or "female"   in low or "feminine" in low
		if "walk" in low and not wf_neg:
			if words < walk_fwd_score:
				walk_fwd_score = words
				_anim_walk_fwd = k

		# --- Walk backward ---
		var wb_neg := "catwalk"  in low or "rifle"   in low or "gun"     in low \
				or "turn"      in low or "injured" in low or "zombie"  in low \
				or "limp"      in low or "arc"     in low
		if "walk" in low and ("back" in low or "backward" in low) and not wb_neg:
			if words < walk_bwd_score:
				walk_bwd_score = words
				_anim_walk_bwd = k

		# --- Jump ---
		var jmp_neg := "flip" in low or "roll" in low or "crawl" in low \
				or "crouch" in low or "attack" in low
		if ("jump" in low or "jumping" in low) and not jmp_neg:
			if words < jump_score:
				jump_score = words
				_anim_jump = k

	print("[main] Loco keys — idle:'%s'  walk_fwd:'%s'  walk_bwd:'%s'  jump:'%s'" \
			% [_anim_idle, _anim_walk_fwd, _anim_walk_bwd, _anim_jump])


# ===========================================================================
# Rig construction helpers
# ===========================================================================

func _make_rig(rig_name: String, scene: PackedScene) -> Node:
	var container := get_node_or_null(rig_name)
	if container == null:
		container = Node3D.new()
		container.name = rig_name
		add_child(container)
	for c in container.get_children():
		c.queue_free()
	await get_tree().process_frame
	var inst := scene.instantiate()
	inst.name = "Character"
	container.add_child(inst)
	return inst


func _build_ball_targets() -> void:
	# Ordered list of body-part name fragments, head → feet.
	var priority: Array[String] = [
		"head", "neck", "spine2", "spine1", "spine",
		"rightarm", "leftarm", "rightforearm", "leftforearm",
		"righthand", "lefthand",
		"rightupleg", "leftupleg", "rightleg", "leftleg",
		"rightfoot", "leftfoot", "hips",
	]
	_ball_targets.clear()
	for frag in priority:
		for id: int in _phys_bone_map:
			var pb: PhysicalBone3D = _phys_bone_map[id]
			if frag in pb.name.to_lower() and not _ball_targets.has(pb):
				_ball_targets.append(pb)
				break
	# Append any remaining physical bones not yet covered.
	for id: int in _phys_bone_map:
		var pb: PhysicalBone3D = _phys_bone_map[id]
		if not _ball_targets.has(pb):
			_ball_targets.append(pb)


func _disable_bone_self_collision() -> void:
	# Prevent physical bones from colliding with each other.
	# Without this, capsule-capsule contacts between adjacent bones produce
	# large impulses that overwhelm the joint solver and fling limbs apart.
	var bones := _phys_bone_map.values()
	for i in bones.size():
		for j in range(i + 1, bones.size()):
			var a := bones[i] as PhysicalBone3D
			var b := bones[j] as PhysicalBone3D
			if is_instance_valid(a) and is_instance_valid(b):
				a.add_collision_exception_with(b)
	print("[main] Self-collision disabled for %d bones." % bones.size())


func _build_phys_bone_map(node: Node) -> void:
	if node is PhysicalBone3D:
		var pb := node as PhysicalBone3D
		var id := pb.get_bone_id()
		if id >= 0:
			_phys_bone_map[id] = pb
	for c in node.get_children():
		_build_phys_bone_map(c)


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


func _make_ghost(node: Node) -> void:
	if node is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.4, 0.7, 1.0, 0.15)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_make_ghost(child)


func _hide_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		node.visible = false
	for child in node.get_children():
		_hide_meshes(child)


# ===========================================================================
# Animation setup
# ===========================================================================

func _setup_animation_player(character_root: Node) -> void:
	_anim_player = _find_animation_player(character_root)
	if _anim_player == null:
		_anim_player = AnimationPlayer.new()
		_anim_player.name = "AnimationPlayer"
		character_root.add_child(_anim_player)

	# Put all loaded animations into the default ("") library.
	var lib: AnimationLibrary
	if _anim_player.has_animation_library(&""):
		lib = _anim_player.get_animation_library(&"")
	else:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library(&"", lib)

	# Build a map: "Jump Push Up.fbx" -> "res://.godot/imported/Jump Push Up.fbx-<hash>.scn"
	# This bypasses the .import validation chain entirely — Godot keeps resetting
	# animation .import files to valid=false, so we load the .scn cache files directly.
	var scn_map: Dictionary = {}
	var imp_dir := DirAccess.open("res://.godot/imported/")
	if imp_dir != null:
		imp_dir.list_dir_begin()
		var scn_name := imp_dir.get_next()
		while scn_name != "":
			# Filename pattern: "Some Animation.fbx-<16hex>.scn"
			if scn_name.ends_with(".scn") and ".fbx-" in scn_name:
				var dash_pos := scn_name.rfind(".fbx-")
				if dash_pos >= 0:
					var fbx_name: String = scn_name.substr(0, dash_pos) + ".fbx"
					scn_map[fbx_name] = "res://.godot/imported/" + scn_name
			scn_name = imp_dir.get_next()
		imp_dir.list_dir_end()
	print("[main] Found %d cached animation scenes." % scn_map.size())

	var loaded         := 0
	var sample_printed := false
	for fbx_name: String in scn_map:
		if fbx_name.to_lower() == "master.fbx":
			continue   # skip the character mesh scene
		var res_path: String = scn_map[fbx_name]
		var scene := ResourceLoader.load(
				res_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if scene == null:
			continue
		var inst := scene.instantiate()
		var src_ap := _find_animation_player(inst)
		if src_ap != null:
			for anim_name: StringName in src_ap.get_animation_list():
				var anim: Animation = src_ap.get_animation(anim_name)
				# Key = FBX base name without extension, spaces preserved for readability.
				var key: StringName = StringName(fbx_name.get_basename())
				if not lib.has_animation(key):
					var anim_copy: Animation = anim.duplicate(true)
					anim_copy.loop_mode = Animation.LOOP_LINEAR
					_strip_root_motion(anim_copy)
					lib.add_animation(key, anim_copy)
					loaded += 1
				if not sample_printed:
					sample_printed = true
					if anim.get_track_count() > 0:
						print("[main] Sample track path: '%s'" \
								% str(anim.track_get_path(0)))
		inst.free()

	print("[main] Loaded %d animation(s)." % loaded)

	# Collect keys: embedded (lib_name="") first so they appear in the cycle.
	_anim_keys.clear()
	var named_keys: Array[String] = []
	for lib_name: StringName in _anim_player.get_animation_library_list():
		var alib: AnimationLibrary = _anim_player.get_animation_library(lib_name)
		for anim_name: StringName in alib.get_animation_list():
			var full: String = str(anim_name) if lib_name == &"" \
					else (str(lib_name) + "/" + str(anim_name))
			if lib_name == &"":
				_anim_keys.append(full)
			else:
				named_keys.append(full)
	_anim_keys.append_array(named_keys)

	_find_locomotion_keys()

	if not _anim_keys.is_empty():
		_anim_idx = 0
		var first: String = _anim_idle if not _anim_idle.is_empty() else _anim_keys[0]
		_anim_player.play(first)
		print("[main] Autoplaying: %s" % first)


func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result := _find_animation_player(child)
		if result:
			return result
	return null


func _strip_root_motion(anim: Animation) -> void:
	# Zero X,Z position on root/hips bone tracks so every animation plays
	# in-place.  Mixamo FBX exports bake world-space locomotion into the
	# hips bone; without stripping the track, looping clips snap the
	# character back to their baked start position on each loop — visible as
	# "being dragged forward/backward" while walking.
	# Y is kept so vertical motion (crouch bob, jump arc) still plays.
	for t in anim.get_track_count():
		if anim.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		var path  := str(anim.track_get_path(t))
		var colon := path.rfind(":")
		var bone  := path.substr(colon + 1) if colon >= 0 else ""
		if bone.is_empty():
			continue
		# Strip from any true root bone (skeleton parent == -1) or hips.
		var should_strip := "hip" in bone.to_lower()
		if not should_strip and is_instance_valid(_anim_skeleton):
			var bi := _anim_skeleton.find_bone(bone)
			if bi >= 0 and _anim_skeleton.get_bone_parent(bi) < 0:
				should_strip = true
		if not should_strip:
			continue
		for i in anim.track_get_key_count(t):
			var v: Vector3 = anim.track_get_key_value(t, i)
			anim.track_set_key_value(t, i, Vector3(0.0, v.y, 0.0))


# ===========================================================================
# Physical bone creation
# ===========================================================================

func _create_physical_bones(skeleton: Skeleton3D) -> void:
	var simulator := PhysicalBoneSimulator3D.new()
	simulator.name = "PhysicalBoneSimulator3D"
	skeleton.add_child(simulator)
	_simulator = simulator   # keep for joint access in limp mode

	var created := 0
	for i in skeleton.get_bone_count():
		var bone_name := skeleton.get_bone_name(i)
		if _skip_bone(bone_name):
			continue

		var length := _estimate_bone_length(skeleton, i)
		length = clampf(length, 0.02, 0.8)   # 0.02 covers tiny finger phalanges
		var radius := clampf(length * 0.2, 0.008, 0.14)

		var shape := CapsuleShape3D.new()
		shape.radius = radius
		shape.height = maxf(length, radius * 2.2)

		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		col.shape = shape
		# Centre the capsule at the joint origin.  Offsetting along +Y assumes
		# every bone extends along its local Y, which isn't guaranteed for all
		# Mixamo bones; centering is stable and orientation-independent.

		var pb := PhysicalBone3D.new()
		pb.name = "Physical_" + bone_name.replace(":", "_").replace(" ", "_")
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_6DOF
		pb.mass       = 1.0
		pb.linear_damp  = 0.8
		pb.angular_damp = 0.8
		pb.bone_name = bone_name   # MUST be set before add_child
		# Layer 4 — separate from static geometry (layer 1) so the CharacterBody3D
		# capsule (mask 1) never collides with physics bones via move_and_slide.
		# Mask 5 = layer 1 (ledge/walls) + layer 4 (other bones, balls).
		pb.collision_layer = 4
		pb.collision_mask  = 5

		pb.add_child(col)
		simulator.add_child(pb)
		_apply_joint_limits(pb, bone_name)
		created += 1

	print("[main] Created %d physical bones." % created)
	# Do NOT start simulation here — the physics engine hasn't processed these
	# bodies yet.  Activation is deferred to _ready() after a physics frame.


func _skip_bone(bone_name: String) -> bool:
	var lower := bone_name.to_lower()
	for frag in SKIP_BONE_FRAGMENTS:
		if lower.contains(frag):
			return true
	return false


func _estimate_bone_length(skeleton: Skeleton3D, bone_idx: int) -> float:
	# For bones with multiple children (e.g. Hips → Spine + LeftUpLeg + RightUpLeg)
	# using the first child in index order gives the wrong length.  Take the LONGEST
	# child distance so branching bones get a capsule that covers their widest extent.
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


func _apply_joint_limits(pb: PhysicalBone3D, bone_name: String) -> void:
	var lower  := bone_name.to_lower()
	var limits := Vector3(30, 30, 30)
	for key in BONE_LIMITS:
		if lower.contains(key):
			limits = BONE_LIMITS[key]
			break

	pb.set("joint/angular_limit_x/enabled",     true)
	pb.set("joint/angular_limit_x/lower_angle", -deg_to_rad(limits.x))
	pb.set("joint/angular_limit_x/upper_angle",  deg_to_rad(limits.x))
	pb.set("joint/angular_limit_y/enabled",     true)
	pb.set("joint/angular_limit_y/lower_angle", -deg_to_rad(limits.y))
	pb.set("joint/angular_limit_y/upper_angle",  deg_to_rad(limits.y))
	pb.set("joint/angular_limit_z/enabled",     true)
	pb.set("joint/angular_limit_z/lower_angle", -deg_to_rad(limits.z))
	pb.set("joint/angular_limit_z/upper_angle",  deg_to_rad(limits.z))


# ===========================================================================
# Environment helpers
# ===========================================================================

func _make_ledge() -> void:
	# A waist-high concrete ledge placed 3 m in front of the character start.
	# Walk into it (forward = -Z) to test head/body pushing against it.
	var ledge := StaticBody3D.new()
	ledge.name = "Ledge"

	var shape := BoxShape3D.new()
	shape.size = Vector3(4.0, 1.4, 0.4)
	var col := CollisionShape3D.new()
	col.shape = shape
	ledge.add_child(col)

	var mesh := BoxMesh.new()
	mesh.size = Vector3(4.0, 1.4, 0.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.50, 0.45)
	mat.roughness    = 0.95
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	ledge.add_child(mi)

	add_child(ledge)
	# 3 m in the backward (-Z) direction — walk into it with S key.
	ledge.global_position = Vector3(0.0, 0.7, -3.0)

	# Floating ledge — shoulder / head height, opposite side so W and S each
	# hit a different obstacle.
	var float_ledge := StaticBody3D.new()
	float_ledge.name = "FloatingLedge"

	var f_shape := BoxShape3D.new()
	f_shape.size = Vector3(4.0, 0.35, 0.45)
	var f_col := CollisionShape3D.new()
	f_col.shape = f_shape
	float_ledge.add_child(f_col)

	var f_mesh := BoxMesh.new()
	f_mesh.size = Vector3(4.0, 0.35, 0.45)
	var f_mat := StandardMaterial3D.new()
	f_mat.albedo_color = Color(0.35, 0.55, 0.65)
	f_mat.roughness    = 0.9
	f_mesh.surface_set_material(0, f_mat)
	var f_mi := MeshInstance3D.new()
	f_mi.mesh = f_mesh
	float_ledge.add_child(f_mi)

	add_child(float_ledge)
	# 3 m in the forward (+Z) direction, centre at 1.75 m — hits the character
	# at head height.  Floats visibly above the ground.
	float_ledge.global_position = Vector3(0.0, 1.75, 3.0)
