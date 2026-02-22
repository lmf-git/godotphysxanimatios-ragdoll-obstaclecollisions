## main.gd — attach to the root Node3D in main.tscn.
extends Node3D

const MASTER_PATH := "res://characters/Master.fbx"
const ANIM_DIR    := "res://animations/"

const SKIP_BONE_FRAGMENTS: Array[String] = [
	"thumb", "index", "middle", "ring", "pinky",
	"toe", "ik", "pole", "ctrl", "_end",
]

const BONE_LIMITS: Dictionary = {
	"hips":     Vector3(30,  30,  45),
	"spine":    Vector3(15,  15,  20),
	"neck":     Vector3(30,  30,  30),
	"head":     Vector3(40,  40,  30),
	"shoulder": Vector3(20,  20,  20),
	"arm":      Vector3(90,  90,  90),
	"forearm":  Vector3(5,  140,   5),
	"hand":     Vector3(45,  45,  45),
	"upleg":    Vector3(80,  80,  45),
	"leg":      Vector3(5,  145,   5),
	"foot":     Vector3(50,  30,  20),
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

# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------

var _anim_keys: Array[String] = []
var _anim_idx:  int = 0

# Locomotion animations (auto-detected by name after loading)
var _anim_idle:     String = ""
var _anim_walk_fwd: String = ""
var _anim_walk_bwd: String = ""
var _loco_state:    String = ""   # "idle" | "walk_fwd" | "walk_bwd"

# ---------------------------------------------------------------------------
# Character movement
# ---------------------------------------------------------------------------

var _char_pos: Vector3 = Vector3(0.0, 0.1, 0.0)
var _char_yaw: float   = 0.0   # radians — 0 = faces -Z (Mixamo default in Godot)

const MOVE_SPEED  := 2.5   # m/s
const TURN_SPEED  := 2.0   # rad/s

# ---------------------------------------------------------------------------
# Camera
# ---------------------------------------------------------------------------

var _camera: Camera3D

const CAM_DIST   := 4.0    # metres behind character
const CAM_HEIGHT := 1.6    # metres above character root
const CAM_LERP   := 6.0    # follow smoothness

# ---------------------------------------------------------------------------
# Ragdoll state machine
# ---------------------------------------------------------------------------

enum RagdollMode { ANIMATED, ACTIVE, LIMP }
var _mode: RagdollMode = RagdollMode.ANIMATED
var _knockback_busy: bool = false


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
	print("[main] Controls: WASD=move  G=active-ragdoll  P=limp  U=next-anim  LClick=shoot  R=reload")


# ===========================================================================
# Per-frame
# ===========================================================================

func _process(delta: float) -> void:
	_handle_movement(delta)
	_update_containers()
	_update_camera(delta)
	_update_locomotion_anim()


func _handle_movement(delta: float) -> void:
	if Input.is_key_pressed(KEY_A):
		_char_yaw += TURN_SPEED * delta
	if Input.is_key_pressed(KEY_D):
		_char_yaw -= TURN_SPEED * delta

	var fwd_input := 0.0
	if Input.is_key_pressed(KEY_W): fwd_input += 1.0   # W = move forward
	if Input.is_key_pressed(KEY_S): fwd_input -= 1.0   # S = move backward

	if fwd_input != 0.0:
		# Character faces -Z; rotate by yaw to get world forward.
		var forward := Basis(Vector3.UP, _char_yaw) * Vector3(0.0, 0.0, -1.0)
		_char_pos += forward * fwd_input * MOVE_SPEED * delta
		_char_pos.y = 0.1   # stay on floor


func _update_containers() -> void:
	var t := Transform3D(Basis(Vector3.UP, _char_yaw), _char_pos)
	if is_instance_valid(_anim_container): _anim_container.transform = t
	if is_instance_valid(_phys_container): _phys_container.transform = t
	if is_instance_valid(_vis_container):  _vis_container.transform  = t


func _update_camera(delta: float) -> void:
	if _camera == null:
		return
	# Back direction in world space (character faces -Z, so back is +Z).
	var back := Basis(Vector3.UP, _char_yaw) * Vector3(0.0, 0.0, 1.0)
	var cam_target := _char_pos + back * CAM_DIST + Vector3(0.0, CAM_HEIGHT, 0.0)
	var t := minf(CAM_LERP * delta, 1.0)
	_camera.global_position = _camera.global_position.lerp(cam_target, t)
	_camera.look_at(_char_pos + Vector3(0.0, 1.0, 0.0), Vector3.UP)


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
		KEY_G:
			_toggle_mode(RagdollMode.ACTIVE)
		KEY_P:
			_toggle_mode(RagdollMode.LIMP)
		KEY_U:
			_next_animation()
		KEY_R:
			get_tree().reload_current_scene()


# ---------------------------------------------------------------------------
# Ragdoll mode switching
# ---------------------------------------------------------------------------

func _toggle_mode(new_mode: RagdollMode) -> void:
	_set_ragdoll_mode(RagdollMode.ANIMATED if _mode == new_mode else new_mode)


func _set_ragdoll_mode(mode: RagdollMode) -> void:
	_mode = mode
	match mode:
		RagdollMode.ANIMATED:
			_set_limp_joints(false)
			# Visual goes back to animation-driven (no dependency on physics bone state).
			if is_instance_valid(_vis_driver): _vis_driver.set("physics_blend", 0.0)
			# Resume animation and let locomotion system pick the right clip.
			_loco_state = ""
			if is_instance_valid(_anim_player):
				var key := _anim_idle if not _anim_idle.is_empty() \
						else (_anim_keys[0] if not _anim_keys.is_empty() else "")
				if not key.is_empty():
					_anim_player.play(key)
			# Restart simulation so 6DOF joints rebuild, then re-enable springs.
			_go_animated_async()
			print("[main] Mode: Animated")
		RagdollMode.ACTIVE:
			_set_limp_joints(false)
			if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", true)
			if is_instance_valid(_vis_driver):  _vis_driver.set("physics_blend", 1.0)
			print("[main] Mode: Active Ragdoll (G to exit)")
		RagdollMode.LIMP:
			if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", false)
			if is_instance_valid(_vis_driver):  _vis_driver.set("physics_blend", 1.0)
			# Stop animation — springs are off so animated skeleton no longer matters,
			# but halting it avoids any stray modifier influence.
			if is_instance_valid(_anim_player): _anim_player.pause()
			_loco_state = ""
			_set_limp_joints(true)
			# Restart simulation asynchronously so JOINT_TYPE_NONE is registered
			# in the physics server, then force RIGID and kick all bones downward.
			_go_limp_async()
			print("[main] Mode: Limp Ragdoll (P to exit)")


func _go_limp_async() -> void:
	# Joint-type property changes are only applied to the physics server when
	# the simulation is stopped and restarted — do that on the simulator directly.
	_simulator.physical_bones_stop_simulation()
	await get_tree().physics_frame
	if _mode != RagdollMode.LIMP:
		return
	_simulator.physical_bones_start_simulation()
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _mode != RagdollMode.LIMP:
		return
	# Verify and report body modes so we can tell if simulation actually started.
	var rigid_count := 0
	for id: int in _phys_bone_map:
		var pb: PhysicalBone3D = _phys_bone_map[id]
		if is_instance_valid(pb) and pb.get_rid().is_valid():
			var m := PhysicsServer3D.body_get_mode(pb.get_rid())
			if m == PhysicsServer3D.BODY_MODE_RIGID:
				rigid_count += 1
	print("[main] Limp: %d/%d bones in RIGID mode — kicking." % [rigid_count, _phys_bone_map.size()])
	_kick_limp_bones()


func _go_animated_async() -> void:
	# Keep springs off until joints have been rebuilt.
	if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", false)
	_simulator.physical_bones_stop_simulation()
	await get_tree().physics_frame
	if _mode != RagdollMode.ANIMATED:
		return
	_simulator.physical_bones_start_simulation()
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _mode != RagdollMode.ANIMATED:
		return
	if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", true)
	print("[main] Animated: joints rebuilt, springs active.")


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
	ball.body_entered.connect(func(body: Node3D):
		var b := ball_ref.get_ref() as RigidBody3D
		if b: _on_ball_hit(body, b))

	get_tree().create_timer(6.0).timeout.connect(func():
		var b := ball_ref.get_ref() as RigidBody3D
		if b: b.queue_free())


func _on_ball_hit(body: Node3D, ball: RigidBody3D) -> void:
	if not (body is PhysicalBone3D):
		return
	if not is_instance_valid(ball):
		return
	print("[main] Ball hit: %s" % body.name)
	ball.collision_layer = 0
	ball.collision_mask  = 0
	var pb := body as PhysicalBone3D
	var impulse := ball.linear_velocity * 0.6
	# apply_impulse at an offset creates both linear and angular response.
	# The 0.15 m Y offset means the force acts above the bone centre,
	# producing a natural rotation around the joint even when translation
	# is constrained by the 6DOF joint.
	pb.apply_impulse(impulse, Vector3(0.0, 0.15, 0.0))
	_trigger_knockback()


func _trigger_knockback() -> void:
	if _knockback_busy or _mode == RagdollMode.LIMP:
		return
	_knockback_busy = true

	# Disable springs so the physics bones react to the impact instead of
	# being immediately snapped back by the spring forces.
	# physics_blend is always 1.0 so the visual responds immediately.
	if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", false)

	get_tree().create_timer(1.8).timeout.connect(_recover_knockback)


func _kick_limp_bones() -> void:
	# Apply a downward impulse via PhysicsServer3D directly — this is guaranteed
	# to work on any RIGID body regardless of property-setter caching.
	for id: int in _phys_bone_map:
		var pb: PhysicalBone3D = _phys_bone_map[id]
		if is_instance_valid(pb) and pb.get_rid().is_valid():
			var impulse := Vector3(
					randf_range(-1.5, 1.5),
					randf_range(-8.0, -5.0),   # strong downward kick
					randf_range(-1.5, 1.5))
			PhysicsServer3D.body_apply_central_impulse(pb.get_rid(), impulse)


func _recover_knockback() -> void:
	_knockback_busy = false
	if _mode != RagdollMode.ANIMATED:
		return   # user switched to a manual ragdoll mode — don't auto-recover
	if is_instance_valid(_phys_driver): _phys_driver.set("spring_enabled", true)


# ---------------------------------------------------------------------------
# Joint limit helpers — unlock for limp collapse, restore for active/animated
# ---------------------------------------------------------------------------

func _set_limp_joints(limp: bool) -> void:
	if not is_instance_valid(_phys_skeleton):
		return
	for id: int in _phys_bone_map:
		var pb: PhysicalBone3D = _phys_bone_map[id]
		if not is_instance_valid(pb):
			continue
		if limp:
			# Remove ALL joint constraints so every bone falls freely under gravity.
			# (The physics server only applies these changes after stop/start — see
			# _go_limp_async which restarts the simulation immediately after.)
			pb.joint_type   = PhysicalBone3D.JOINT_TYPE_NONE
			pb.linear_damp  = 0.05
			pb.angular_damp = 0.05
		else:
			# Restore constrained 6DOF joint for spring-driven animation.
			pb.joint_type   = PhysicalBone3D.JOINT_TYPE_6DOF
			pb.linear_damp  = 0.8
			pb.angular_damp = 0.8
			_apply_joint_limits(pb, _phys_skeleton.get_bone_name(id))


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
	if Input.is_key_pressed(KEY_W):   new_state = "walk_fwd"
	elif Input.is_key_pressed(KEY_S): new_state = "walk_bwd"
	else:                              new_state = "idle"

	if new_state == _loco_state:
		return
	_loco_state = new_state

	var key: String
	match new_state:
		"walk_fwd": key = _anim_walk_fwd if not _anim_walk_fwd.is_empty() else _anim_idle
		"walk_bwd": key = _anim_walk_bwd if not _anim_walk_bwd.is_empty() else _anim_idle
		_:          key = _anim_idle

	if _anim_player.has_animation(key):
		_anim_player.play(key, 0.25)
		print("[main] Loco: %s → %s" % [new_state, key])


func _find_locomotion_keys() -> void:
	for k: String in _anim_keys:
		var low := k.to_lower()
		if _anim_idle.is_empty() and ("idle" in low or "standing" in low) \
				and "fight" not in low and "aim" not in low:
			_anim_idle = k
		if _anim_walk_fwd.is_empty() and "walk" in low \
				and "back" not in low and "rifle" not in low \
				and "arc" not in low and "turn" not in low and "stop" not in low:
			_anim_walk_fwd = k
		if _anim_walk_bwd.is_empty() and "walk" in low \
				and ("back" in low or "backward" in low):
			_anim_walk_bwd = k
	print("[main] Loco keys — idle:'%s'  walk_fwd:'%s'  walk_bwd:'%s'" \
			% [_anim_idle, _anim_walk_fwd, _anim_walk_bwd])


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
		length = clampf(length, 0.05, 0.5)
		var radius := clampf(length * 0.18, 0.03, 0.12)

		var shape := CapsuleShape3D.new()
		shape.radius = radius
		shape.height = maxf(length, radius * 2.2)

		var col := CollisionShape3D.new()
		col.name = "CollisionShape3D"
		col.shape = shape

		var pb := PhysicalBone3D.new()
		pb.name = "Physical_" + bone_name.replace(":", "_").replace(" ", "_")
		pb.joint_type = PhysicalBone3D.JOINT_TYPE_6DOF
		pb.mass       = 1.0
		pb.linear_damp  = 0.8
		pb.angular_damp = 0.8
		pb.bone_name = bone_name   # MUST be set before add_child

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
	var my_rest := skeleton.get_bone_rest(bone_idx)
	for j in skeleton.get_bone_count():
		if skeleton.get_bone_parent(j) == bone_idx:
			return my_rest.origin.distance_to(skeleton.get_bone_rest(j).origin)
	var parent := skeleton.get_bone_parent(bone_idx)
	if parent >= 0:
		return my_rest.origin.distance_to(skeleton.get_bone_rest(parent).origin) * 0.5
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
	# Character faces -Z; ledge is 3 m ahead, centred at half the box height.
	ledge.global_position = Vector3(0.0, 0.7, -3.0)
