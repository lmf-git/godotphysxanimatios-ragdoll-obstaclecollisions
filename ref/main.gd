extends Node3D

const CHARACTER_SCENE_PATH := "res://character.tscn"

# ---------------------------------------------------------------------------
# Interaction tuning
# ---------------------------------------------------------------------------
const DRAG_THRESHOLD_PX    := 8.0    # pixels moved before press becomes a drag
const CLICK_VEL_CHANGE     := 5.0    # m/s velocity change per click (mass-scaled impulse)
const SPRING_STIFFNESS     := 350.0  # N/m (scaled by bone mass below)
const SPRING_DAMPING       := 22.0   # N·s/m

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
enum IState { IDLE, BONE_PRESSED, BONE_DRAGGING }

var character: Node3D = null
var ragdoll: Node      = null

@onready var camera: CameraController = $Camera3D

var _istate: IState           = IState.IDLE
var _grabbed_bone: PhysicalBone3D = null
var _grab_depth: float        = 0.0
var _drag_target: Vector3     = Vector3.ZERO
var _press_start_pos: Vector2 = Vector2.ZERO


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	_spawn_character()


func _physics_process(_delta: float) -> void:
	if _istate != IState.BONE_DRAGGING:
		return
	if not (_grabbed_bone and is_instance_valid(_grabbed_bone)):
		_istate = IState.IDLE
		return

	# PD spring toward the drag target — scale by bone mass so all limbs
	# feel equally responsive regardless of weight.
	var diff         := _drag_target - _grabbed_bone.global_position
	var spring_force := diff  * SPRING_STIFFNESS * _grabbed_bone.mass
	var damp_force   := -_grabbed_bone.linear_velocity * SPRING_DAMPING * _grabbed_bone.mass
	_grabbed_bone.apply_central_force(spring_force + damp_force)


# ---------------------------------------------------------------------------
# Character spawning
# ---------------------------------------------------------------------------

func _spawn_character() -> void:
	if not ResourceLoader.exists(CHARACTER_SCENE_PATH):
		push_warning("character.tscn not found. See RAGDOLL_SETUP.md for instructions.")
		return

	var scene: PackedScene = load(CHARACTER_SCENE_PATH)
	character = scene.instantiate()
	add_child(character)
	character.position = Vector3(0.0, 1.0, 0.0)

	ragdoll = character.get_node_or_null("RagdollController")
	if ragdoll:
		ragdoll.ragdoll_started.connect(_on_ragdoll_started)
		ragdoll.ragdoll_stopped.connect(_on_ragdoll_stopped)
		print("RagdollController found. Skeleton: ", ragdoll.get("_skeleton"))
		print("Physical bones: ", ragdoll.call("_get_physical_bones").size())
	else:
		push_warning("RagdollController not found on character.")

	# Tell the orbit camera which node to follow.
	camera.target = character


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# ---- Keyboard shortcuts ----
	if event.is_action_pressed("ragdoll_toggle"):
		_toggle_ragdoll()
		return
	if event.is_action_pressed("reset"):
		_reset_character()
		return
	if event.is_action_pressed("explode"):
		_apply_explosion()
		return

	# ---- Left-mouse bone interaction ----
	if event is InputEventMouseButton and \
			(event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		if (event as InputEventMouseButton).pressed:
			_on_left_press((event as InputEventMouseButton).position)
		else:
			_on_left_release((event as InputEventMouseButton).position)
		return

	if event is InputEventMouseMotion and _istate != IState.IDLE:
		_on_mouse_move(event as InputEventMouseMotion)


func _on_left_press(mouse_pos: Vector2) -> void:
	var result := _do_raycast(mouse_pos)
	if result.is_empty() or not (result["collider"] is PhysicalBone3D):
		return

	var bone     := result["collider"] as PhysicalBone3D
	var hit_pos  := result["position"] as Vector3

	# Activate ragdoll on demand.
	if ragdoll and not ragdoll.is_ragdoll_active:
		ragdoll.start_ragdoll()

	_grabbed_bone    = bone
	_grab_depth      = camera.global_position.distance_to(hit_pos)
	_drag_target     = hit_pos
	_press_start_pos = mouse_pos
	_istate          = IState.BONE_PRESSED


func _on_left_release(_mouse_pos: Vector2) -> void:
	if _istate == IState.BONE_PRESSED:
		# Short click → apply an impulse in the view-ray direction.
		# Scale by mass so every bone reacts with the same visible velocity change.
		if _grabbed_bone and is_instance_valid(_grabbed_bone):
			var dir := camera.project_ray_normal(_press_start_pos)
			_grabbed_bone.apply_central_impulse(dir * CLICK_VEL_CHANGE * _grabbed_bone.mass)

	_grabbed_bone = null
	_istate       = IState.IDLE


func _on_mouse_move(event: InputEventMouseMotion) -> void:
	# Promote BONE_PRESSED → BONE_DRAGGING once the cursor drifts enough.
	if _istate == IState.BONE_PRESSED and \
			event.position.distance_to(_press_start_pos) > DRAG_THRESHOLD_PX:
		_istate = IState.BONE_DRAGGING

	if _istate == IState.BONE_DRAGGING:
		_drag_target = _ray_at_depth(event.position, _grab_depth)


# ---------------------------------------------------------------------------
# Ragdoll actions
# ---------------------------------------------------------------------------

func _toggle_ragdoll() -> void:
	if not ragdoll:
		push_warning("No ragdoll — SPACE has no effect.")
		return
	if ragdoll.is_ragdoll_active:
		ragdoll.stop_ragdoll()
	else:
		ragdoll.start_ragdoll(Vector3(0.0, 3.0, -2.0) * 12.0)


func _apply_explosion() -> void:
	if not ragdoll:
		return
	if not ragdoll.is_ragdoll_active:
		ragdoll.start_ragdoll()
		await get_tree().process_frame
	ragdoll.apply_explosion_force(
		character.global_position + Vector3(1.5, 0.0, 0.0),
		600.0,
		4.0
	)


func _reset_character() -> void:
	_grabbed_bone = null
	_istate       = IState.IDLE
	if character:
		character.queue_free()
		character = null
		ragdoll   = null
	await get_tree().process_frame
	_spawn_character()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _do_raycast(mouse_pos: Vector2) -> Dictionary:
	var from  := camera.project_ray_origin(mouse_pos)
	var dir   := camera.project_ray_normal(mouse_pos)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 50.0)
	query.collide_with_bodies = true
	return space.intersect_ray(query)


func _ray_at_depth(mouse_pos: Vector2, depth: float) -> Vector3:
	var from := camera.project_ray_origin(mouse_pos)
	var dir  := camera.project_ray_normal(mouse_pos)
	return from + dir * depth


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_ragdoll_started() -> void:
	print("Ragdoll STARTED — char pos: ", str(character.global_position) if character else "N/A")


func _on_ragdoll_stopped() -> void:
	print("Ragdoll STOPPED")
