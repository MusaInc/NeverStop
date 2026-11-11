class_name Car
extends RigidBody3D
## Arcade raycast-suspension car on Jolt. One model drives the player, every
## police unit and wrecked civilians, so police mistakes (overshot corners,
## pile-ups) come from the same physics the player fights.
##
##  * Four suspension rays: spring + damper along the body's up axis, the
##    reaction applied at the contact point (so braking dives, cornering rolls
##    and landings compress for real).
##  * Tyres: lateral force from slip angle (peak at SLIP_PEAK, then a lower
##    sliding grip), longitudinal drive/brake; both clamped by a friction
##    circle on each wheel's normal load. The handbrake locks the rears and
##    drops their sliding grip: oversteer you can hold.
##  * Arcade layer (all tunable in the spec): speed-sensitive steering, a yaw
##    assist toward the steering's intended yaw rate while gripping, a drift
##    assist that holds a slide's angle instead of spinning out, mild
##    downforce, self-levelling and a little yaw control in the air.
##  * Damage: contact impulses (from _integrate_forces) become per-side
##    damage, a short loss of grip after a heavy side hit, less power, a
##    steering pull and smoke. Body panels (bumpers, bonnet, boot, doors and
##    any Workshop armour plates) wear down per hit and fall off (`parts`,
##    `part_lost`); a side with its panel gone takes more damage. `health` 0
##    = immobilised, except the player's car: its engine never dies
##    (`immortal`), it just gets slower and smokier until it is repaired.

signal impact(strength: float, at: Vector3, normal: Vector3, other: Object)
signal landed(airtime: float, impact_speed: float)
signal wrecked
signal part_lost(part: String, at: Vector3, normal: Vector3)
signal repaired

## Body panels that can come off, and the impact side that wears each one.
## (Plates only exist with Workshop armour plating; they take the hit first.)
const PARTS := ["bumper_f", "bumper_r", "hood", "boot", "door_l", "door_r"]
const PLATES := ["plate_f", "plate_r", "plate_l", "plate_rt"]
const SIDE_PARTS := {"front": ["bumper_f", "hood"], "rear": ["bumper_r", "boot"], "left": ["door_l"], "right": ["door_r"]}
const SIDE_PLATE := {"front": "plate_f", "rear": "plate_r", "left": "plate_l", "right": "plate_rt"}

const GRAVITY := 9.8
const SLIP_PEAK := deg_to_rad(9.0)
const RAY_MASK := 1 | (1 << 3)          # buildings/structures + street surface
const BODY_LAYER := 1 << 2              # vehicles
const BODY_MASK := 1 | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7)  # world, vehicles, street, trains, solid props
## Kerbs are 0.15 m; the hull floor stays above this so they go under the car.
const KERB_CLEAR := 0.3
## Ledges up to this tall (above the ground under the car) are climbed, not crashed into.
const STEP_MAX := 0.62

var spec: Dictionary
## Controls, set every frame by the driver (player input or an AI brain).
var throttle := 0.0   # 0..1
var brake := 0.0      # 0..1 (held at a standstill = reverse)
var steer := 0.0      # -1 left .. +1 right
var handbrake := false
var nitro := false
## Driver: "player", "police", "civilian" (affects damage scale and scoring).
var role := "player"

# --- state (read by camera, audio, HUD, AI) ---
var forward_speed := 0.0       # m/s along the body's forward axis
var speed := 0.0               # |velocity| m/s
var drift_angle := 0.0         # rad, signed slip of the body's velocity vs heading
var drifting := false
var wheels_on_ground := 0
var airtime := 0.0
var rpm := 0.0                 # 0..1 for engine audio
var gear := 1
var health := 1.0
var dmg := {"front": 0.0, "rear": 0.0, "left": 0.0, "right": 0.0}
var wheel_slip: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]  # 0..1 for smoke/skids
var scraping := 0.0            # 0..1, metal on wall
var nitro_amount := 1.0
var disabled := false          # wrecked: no drive, no steering
var stuck_time := 0.0
var upside_time := 0.0
var steer_angle := 0.0
var last_impact_time := -10.0
var grip_loss := 0.0           # seconds of reduced grip after a heavy hit
var puncture := 0.0            # 1 = tyres shredded by a spike strip
var climbed_kerb := 0.0        # > 0 just after hopping a kerb/ledge (camera, audio)
## Panel condition 1..0; a part at 0 has fallen off. Plates only with plating.
var parts := {}
## The player's engine never dies: damage slows the car, never stops it.
var immortal := false
var last_hit_by: Car            # who hit us last (for kill credit)
var jump_cd := 0.0              # hydraulics cooldown (Workshop)

# wheel layout (local, at the suspension top), filled from spec
var _wheel_pos: Array[Vector3] = []
var _rays: Array[RayCast3D] = []
var _comp: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _contact: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _normal: Array[Vector3] = [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
var _hit: Array[bool] = [false, false, false, false]
var wheel_spin: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var wheel_comp_visual: PackedFloat32Array = [0.0, 0.0, 0.0, 0.0]
var _prev_vel := Vector3.ZERO
var _was_air := false
var _air_peak_fall := 0.0
var _gear_timer := 0.0
var _impacts: Array = []       # filled in _integrate_forces, handled in _physics_process
var _steps: Array = []         # low contacts with the world: [at, normal, dv]
var _time := 0.0
var visual: Node3D             # CarVisual (optional)


func setup(p_spec: Dictionary, p_role := "player") -> void:
	spec = p_spec
	role = p_role
	immortal = role == "player"
	_reset_parts()
	process_physics_priority = 10  # after every driver has set the controls
	mass = spec["mass"]
	collision_layer = BODY_LAYER
	collision_mask = BODY_MASK
	contact_monitor = true
	max_contacts_reported = 6
	continuous_cd = true
	can_sleep = false
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.6
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, spec.get("com_y", 0.25), 0)
	var mat := PhysicsMaterial.new()
	mat.friction = 0.35
	mat.bounce = 0.05
	physics_material_override = mat
	var size: Vector3 = spec["size"]  # width, height, length
	var shape := CollisionShape3D.new()
	# A chamfered hull (not a box) so corners glance off walls and other cars.
	var h := ConvexPolygonShape3D.new()
	var hw := size.x * 0.5
	var hl := size.z * 0.5
	var y0 := spec["ride"] as float - 0.05
	var y1 := y0 + size.y * 0.55
	var y2 := y0 + size.y
	var ch := 0.28
	# The hull's floor sits above kerb height and its nose and tail are
	# wedged, so kerbs and low ledges go under the car (the wheels ride up
	# them) and anything a little taller is ramped over instead of stopping
	# the car dead. The drawn body hangs a few cm lower; nobody can tell.
	var yb := maxf(y0, KERB_CLEAR)
	var wedge := 0.34
	var pts := PackedVector3Array()
	for z in [-hl, hl]:
		var zi := (z as float) - signf(z) * ch
		var zb := (z as float) - signf(z) * (ch + wedge)
		pts.append_array([Vector3(-hw + 0.1, yb, zb), Vector3(hw - 0.1, yb, zb),
			Vector3(-hw, y1, zi), Vector3(hw, y1, zi), Vector3(-hw + ch, y1, z), Vector3(hw - ch, y1, z)])
	# Lower side line, a little in from the sides (kerbs scraped sideways in a drift).
	for z in [-hl * 0.55, hl * 0.55]:
		pts.append_array([Vector3(-hw, yb + 0.12, z), Vector3(hw, yb + 0.12, z)])
	var cab_f := -hl * 0.35
	var cab_r := hl * 0.7
	for z in [cab_f, cab_r]:
		pts.append_array([Vector3(-hw * 0.82, y2, z), Vector3(hw * 0.82, y2, z)])
	h.points = pts
	shape.shape = h
	add_child(shape)
	_wheel_pos.clear()
	var wb: float = spec["wheelbase"] * 0.5
	var tr: float = spec["track"] * 0.5
	var top: float = spec["wheel_r"] + spec["susp_len"] - 0.08
	_wheel_pos = [Vector3(-tr, top, -wb), Vector3(tr, top, -wb), Vector3(-tr, top, wb), Vector3(tr, top, wb)]
	for i in 4:
		var r := RayCast3D.new()
		r.position = _wheel_pos[i]
		r.target_position = Vector3(0, -(spec["susp_len"] + spec["wheel_r"] + 0.1), 0)
		r.collision_mask = RAY_MASK
		r.add_exception(self)
		r.hit_back_faces = false
		add_child(r)
		_rays.append(r)
	# Inertia: a box of the car's size, a little more yaw inertia for stability.
	inertia = Vector3(
		mass * (size.y * size.y + size.z * size.z) / 12.0,
		mass * (size.x * size.x + size.z * size.z) / 12.0 * 1.1,
		mass * (size.x * size.x + size.y * size.y) / 12.0)


func wheel_local(i: int) -> Vector3:
	var top := _wheel_pos[i]
	var rest: float = spec["susp_len"]
	return top + Vector3(0, -(rest - wheel_comp_visual[i]) - 0.0, 0)


func wheel_contact(i: int) -> bool:
	return _hit[i]


func wheel_contact_point(i: int) -> Vector3:
	return _contact[i]


func reset_damage() -> void:
	health = 1.0
	for k in dmg:
		dmg[k] = 0.0
	disabled = false
	grip_loss = 0.0
	puncture = 0.0
	nitro_amount = 1.0
	_reset_parts()


func _reset_parts() -> void:
	parts = {}
	for p in PARTS:
		parts[p] = 1.0
	if int(spec.get("mod_plating", 0)) > 0:
		for p in PLATES:
			parts[p] = 1.0


## A repair pickup: good as new (panels back on, dents out, tyres fixed).
func repair_full() -> void:
	var keep_nitro := nitro_amount
	reset_damage()
	nitro_amount = maxf(keep_nitro, 0.5)
	repaired.emit()


func parts_lost() -> int:
	var n := 0
	for p in parts:
		if parts[p] <= 0.0:
			n += 1
	return n


## Hydraulics (Workshop): a hop straight up – over a roadblock, a spike
## strip or a pile-up. Needs wheels on the ground.
func hydraulic_jump() -> bool:
	var lvl := int(spec.get("mod_jump", 0))
	if lvl <= 0 or jump_cd > 0.0 or wheels_on_ground < 2 or disabled:
		return false
	jump_cd = 6.0 if lvl == 1 else 4.0
	var up := global_basis.y
	linear_velocity += up * (7.5 if lvl == 1 else 9.5) + Vector3.UP * 0.5
	angular_velocity *= 0.3
	return true


## Full lock at this speed. Speed-sensitive the way a good arcade racer is:
## at every speed full lock asks for (a touch more than) what the tyres can
## actually deliver, so the whole stick/slider range does something and the
## fronts never get thrown to a huge slip angle (the old curve saturated grip
## at ~60 % input above 100 km/h, then snapped the nose in and overshot).
func max_steer_angle() -> float:
	var lock := deg_to_rad(spec["steer_lock"])
	var fast := deg_to_rad(spec["steer_fast"])
	var v := maxf(absf(forward_speed), 1.0)
	var grip_yaw: float = spec["grip"] * GRAVITY * 1.1 / maxf(v, 4.0)
	# Arcade: full lock asks for well over what the tyres alone could do
	# (the yaw assist and path-follow force below deliver it), so a full
	# flick is a genuinely sharp turn at any speed.
	var ideal := atan(float(spec["wheelbase"]) * grip_yaw * float(spec.get("turn", 1.7)) / v) + SLIP_PEAK * float(spec.get("steer_slip", 0.3))
	return clampf(ideal, minf(fast, lock), lock)


func _physics_process(dt: float) -> void:
	Prof.begin("car")
	if freeze:
		Prof.end("car")
		return
	_time += dt
	var xf := global_transform
	var b := xf.basis
	var up := b.y
	var fwd := -b.z
	var right := b.x
	var vel := linear_velocity
	speed = vel.length()
	forward_speed = vel.dot(fwd)
	var lat_speed := vel.dot(right)
	var planar := Vector2(forward_speed, lat_speed)
	drift_angle = atan2(lat_speed, absf(forward_speed)) if planar.length() > 4.0 else 0.0

	# Perk: some cars patch themselves up when they're left alone for a bit.
	var rep: float = spec.get("repair", 0.0)
	if rep > 0.0 and not disabled and _time - last_impact_time > 4.0 and health < 1.0:
		health = minf(1.0, health + rep * dt)
		for k in dmg:
			dmg[k] = maxf(0.0, dmg[k] - rep * dt)
	# --- controls with damage ---
	var power_scale: float = 1.0 - 0.45 * maxf(dmg["front"], dmg["rear"]) - 0.25 * (1.0 - health)
	if immortal:
		power_scale = maxf(power_scale, 0.62)  # beaten up, never dead
	jump_cd = maxf(0.0, jump_cd - dt)
	var thr := 0.0 if disabled else throttle
	var brk := 1.0 if disabled else brake
	var str_in := 0.0 if disabled else steer
	# Front-end damage pulls the steering (misalignment) – correctable.
	var pull: float = (dmg["left"] - dmg["right"]) * 0.12 + dmg["front"] * 0.05 * sin(_time * 0.7)
	var target_steer := clampf(str_in + pull, -1.0, 1.0) * max_steer_angle()
	# Constant time from centre to full lock at any speed (~0.17 s, quicker
	# on the sharper cars): fast enough to feel direct, slow enough that a
	# flick at 150 km/h can't spike the yaw rate.
	var steer_rate := max_steer_angle() / 0.09 * float(spec.get("steer_rate", 200.0)) / 200.0
	# Unwinding (back to centre or across to counter-steer) is quicker than
	# winding on: catching a slide should never feel laggy.
	if absf(target_steer) < absf(steer_angle) or signf(target_steer) != signf(steer_angle):
		steer_rate *= 1.7
	steer_angle = move_toward(steer_angle, target_steer, steer_rate * dt)

	# Reverse: brake held at (near) standstill.
	var reversing := brk > 0.5 and forward_speed < 1.5 and thr < 0.5
	var drive := 0.0
	var top: float = spec["top_speed"] * (1.0 - 0.2 * (1.0 - health)) * (1.0 - 0.18 * puncture)
	if reversing:
		drive = -0.45 * brk
		brk = 0.0
		top = 12.0
	else:
		drive = thr
	var using_nitro: bool = nitro and nitro_amount > 0.0 and thr > 0.1 and not disabled and spec.get("nitro", 0.0) > 0.0
	if using_nitro:
		nitro_amount = maxf(0.0, nitro_amount - dt / spec.get("nitro_time", 4.0))
		top *= 1.18
	elif not nitro:
		nitro_amount = minf(1.0, nitro_amount + dt * float(spec.get("nitro_regen", 0.02)))

	# Engine force curve: strong low down, tapering to zero at top speed.
	var sp_t := clampf(absf(forward_speed) / maxf(top, 1.0), 0.0, 1.2)
	var curve := clampf(1.0 - pow(sp_t, 3.0), 0.0, 1.0)
	if forward_speed < 0.0 and drive > 0.0:
		curve = 1.0
	var engine_f: float = spec["engine"] * mass * drive * curve * power_scale
	# Nitro is a straight shove (not through the tyres: on a RWD muscle car
	# the rears were already spinning, so the boost just became wheelspin).
	var nitro_f := 0.0
	if using_nitro:
		nitro_f = spec["engine"] * mass * 0.75 * spec.get("nitro", 0.0)
	# Engine braking: lifting off GAS slows the car like a real one (it used
	# to coast at 0.4 m/s², which made press-to-go feel like driving on ice).
	var coast := 0.0
	if thr < 0.05 and not reversing and not disabled:
		coast = mass * (float(spec.get("engine_brake", 1.2)) + 1.3 * minf(sp_t, 1.0))
	# GAS while still rolling backwards brakes first, then drives off.
	var auto_brk := clampf(thr, 0.0, 1.0) if (thr > 0.1 and forward_speed < -0.5 and not reversing) else 0.0
	_update_gears(sp_t, thr, dt)

	# --- wheels ---
	var k: float = spec["spring"] * mass
	var c: float = spec["damper"] * mass
	var rest: float = spec["susp_len"]
	var wr: float = spec["wheel_r"]
	var mu: float = spec["grip"] * (1.0 - 0.25 * (1.0 - health)) * (1.0 - 0.28 * puncture)
	if grip_loss > 0.0:
		mu *= 0.45
		grip_loss -= dt
	var ground := 0
	var drv: String = spec["drive"]
	var n_driven := 2 if drv != "awd" else 4
	var loads := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var rear_sliding := 0.0
	var roll_lift: float = spec.get("com_y", 0.4) * spec.get("roll_center", 0.75)
	for i in 4:
		var r := _rays[i]
		# Cast now: a RayCast3D's own update is a physics frame old, which at
		# 25 m/s puts the hit 40 cm behind the wheel and unloads it.
		r.force_raycast_update()
		_hit[i] = r.is_colliding()
		if not _hit[i]:
			_comp[i] = move_toward(_comp[i], 0.0, dt * 2.0)
			wheel_comp_visual[i] = _comp[i]
			wheel_slip[i] = 0.0
			continue
		ground += 1
		var p := r.get_collision_point()
		var n := r.get_collision_normal()
		var origin := xf * _wheel_pos[i]
		var dist := (origin - p).dot(up)
		var comp := clampf(rest + wr - dist, 0.0, rest + 0.15)
		# Rolling onto a kerb compresses the spring 15 cm in one tick; an
		# unclamped damper turns that into a launch. Cap the damper speed.
		var comp_v := clampf((comp - _comp[i]) / dt, -3.0, 3.0)
		_comp[i] = comp
		wheel_comp_visual[i] = minf(comp, rest)
		var fz := maxf(0.0, k * comp + c * comp_v)
		# Bump stop: bottoming out hits hard instead of tunnelling.
		if comp > rest:
			fz += (comp - rest) * k * 6.0
		fz = minf(fz, mass * GRAVITY * 3.5)
		loads[i] = fz
		_contact[i] = p
		_normal[i] = n
		var at := p - global_position
		apply_force(up * fz, at)
		# Tyre frame on the contact plane.
		var wfwd := fwd
		if i < 2:
			wfwd = fwd.rotated(up, -steer_angle)
		wfwd = (wfwd - n * wfwd.dot(n)).normalized()
		var wside := wfwd.cross(n).normalized()  # points right
		var pv := vel + angular_velocity.cross(at)
		var v_long := pv.dot(wfwd)
		var v_lat := pv.dot(wside)
		var front := i < 2
		var mu_w: float = mu * (spec["grip_front"] if front else spec["grip_rear"])
		var slide_mu: float = mu_w * spec.get("slide", 0.82)
		var hb := handbrake and not front and not disabled
		if hb:
			slide_mu = mu_w * spec.get("hb_grip", 0.42)
		# Lateral: slip angle -> force (peak, then sliding grip).
		var slip := atan2(v_lat, maxf(absf(v_long), 2.5))
		var s_ratio := absf(slip) / SLIP_PEAK
		var lat_mu: float = mu_w * minf(s_ratio, 1.0) if s_ratio <= 1.0 else lerpf(mu_w, slide_mu, clampf((s_ratio - 1.0) / 2.0, 0.0, 1.0))
		if hb:
			lat_mu = minf(lat_mu, slide_mu)
		var f_lat: float = -signf(slip) * lat_mu * fz
		# Low speed: kill creep sideways (parking-lot stability).
		if absf(v_long) < 3.0 and absf(v_lat) < 2.0:
			f_lat = -v_lat * mass * 0.25 * 4.0
			f_lat = clampf(f_lat, -mu_w * fz, mu_w * fz)
		# Longitudinal.
		var f_long := 0.0
		var driven := drv == "awd" or (drv == "rwd" and not front) or (drv == "fwd" and front)
		if driven:
			f_long += engine_f / n_driven
		var b_in := maxf(brk, auto_brk)
		if b_in > 0.0 and not reversing:
			var bf: float = spec["brake"] * mass * b_in * (0.62 if front else 0.38)
			f_long -= signf(v_long) * minf(bf, absf(v_long) * mass * 0.25 / dt)
		if hb:
			f_long -= signf(v_long) * minf(mass * 3.5 * 0.5, absf(v_long) * mass * 0.25 / dt)
		f_long -= v_long * mass * 0.0015  # rolling resistance
		if disabled:
			f_long -= signf(v_long) * minf(mass * 6.0 * 0.25, absf(v_long) * mass * 0.25 / dt)
		# Engine braking on the driven wheels.
		if driven and coast > 0.0:
			f_long -= signf(v_long) * minf(coast / n_driven, absf(v_long) * mass * 0.25 / dt)
		# Friction circle.
		var cap: float = (mu_w if not hb else slide_mu * 1.3) * fz
		# ABS: braking never takes the grip the tyre needs to corner, so
		# braking mid-turn slows the car instead of spinning it (it used to
		# slide every car out to ~65°).
		if b_in > 0.0 and not hb and absf(f_long) > 0.0:
			var room := sqrt(maxf(cap * cap - f_lat * f_lat, 0.0))
			f_long = signf(f_long) * minf(absf(f_long), maxf(room, cap * 0.35))
		var f := Vector2(f_long, f_lat)
		var excess := 0.0
		if f.length() > cap and f.length() > 0.0:
			excess = f.length() / cap - 1.0
			f = f.normalized() * cap
		# Lateral force acts at a raised roll centre (arcade: cars lean but
		# don't trip over their own tyres); drive/brake at the contact patch.
		apply_force(wfwd * f.x, at)
		apply_force(wside * f.y, at + up * roll_lift)
		var ws := clampf(maxf((s_ratio - 1.3) * 0.5, excess * 1.5), 0.0, 1.0)
		if hb and absf(v_long) > 4.0:
			ws = maxf(ws, 0.7)
		if absf(pv.length()) < 3.0:
			ws *= 0.3
		wheel_slip[i] = ws
		if not front:
			rear_sliding = maxf(rear_sliding, s_ratio)
		wheel_spin[i] += (v_long / wr) * dt * (0.0 if hb else 1.0)
	for i in 4:
		if not _hit[i]:
			wheel_spin[i] += (forward_speed / wr) * dt * 0.98
	wheels_on_ground = ground

	# Anti-roll bars (front and rear axle pairs).
	var arb: float = spec.get("anti_roll", 0.6) * k
	for axle in [[0, 1], [2, 3]]:
		var dl := _comp[axle[0]] - _comp[axle[1]]
		if _hit[axle[0]] or _hit[axle[1]]:
			var fa := dl * arb
			# The more compressed side is held up, the other pulled down.
			apply_force(up * fa, (xf * _wheel_pos[axle[0]]) - global_position)
			apply_force(up * -fa, (xf * _wheel_pos[axle[1]]) - global_position)

	if nitro_f > 0.0 and ground > 0:
		apply_central_force(fwd * nitro_f)
	# Aerodynamics: drag + downforce.
	apply_central_force(-vel * speed * spec.get("drag", 0.0009) * mass)
	if ground > 0:
		apply_central_force(-up * speed * speed * spec.get("downforce", 0.012) * mass * 0.1)

	# --- arcade assists ---
	# Drift state with hysteresis: in above 11°, out below 6°.
	var beta := -drift_angle   # > 0: nose turned right of the direction of travel
	if drifting:
		drifting = ground >= 2 and absf(beta) > deg_to_rad(6.0) and speed > 7.0
	else:
		drifting = ground >= 2 and absf(beta) > deg_to_rad(11.0) and speed > 9.0
	var yaw_rate := angular_velocity.dot(up)
	if ground >= 3 and not disabled:
		var wb: float = spec["wheelbase"]
		var fs := signf(forward_speed + 0.01)
		# The yaw rate the tyres can actually deliver at this speed.
		var grip_yaw := mu * GRAVITY * 1.1 / maxf(speed, 4.0)
		# Arcade turning: the more you steer, the further past plain tyre grip
		# the car is allowed to rotate (full lock ~1.7x).
		var turn_k := lerpf(1.0, float(spec.get("turn", 1.7)), clampf(absf(str_in), 0.0, 1.0))
		# Braking hard: the extra arcade rotation backs off (the tyres are busy stopping).
		turn_k = lerpf(turn_k, 1.0, clampf(brk, 0.0, 1.0) * 0.7)
		var want := clampf(-forward_speed * tan(steer_angle) / wb, -grip_yaw * turn_k, grip_yaw * turn_k)
		var assist: float = spec.get("yaw_assist", 0.35)
		# The drift assist (which HOLDS a slide angle) is for deliberate drifts:
		# the handbrake, or power-oversteer on the throttle. A slide that comes
		# from braking or a knock is caught and straightened instead.
		var drift_mode := (handbrake and speed > 8.0) or (drifting and thr > 0.3 and brk < 0.2)
		if drift_mode:
			# Drift assist: steering sets the slide angle it holds; centred
			# steering (or counter-steer) straightens it. The path itself
			# curves with the steering, so the drift goes round the corner.
			var max_a := deg_to_rad(spec.get("drift_max", 44.0))
			var hold := str_in * deg_to_rad(spec.get("drift_hold", 30.0))
			if handbrake:
				hold = str_in * max_a if absf(str_in) > 0.1 else beta
			var path := -str_in * grip_yaw * 0.8
			want = (path - clampf((hold - beta) * 3.0, -2.5, 2.5)) * fs
			assist = spec.get("drift_assist", 0.55)
			if absf(beta) > max_a:
				# Past the limit: pull back toward it, hard.
				want = (path + (beta - signf(beta) * max_a) * 5.0) * fs
				assist = 1.0
			# Keep momentum through a slide (arcade: drifting shouldn't kill speed).
			if speed > 10.0 and thr > 0.2:
				apply_central_force(vel.normalized() * mass * spec.get("drift_push", 1.6) * clampf(absf(beta), 0.0, 0.8))
		# Centred steering while gripping: hold the heading firmly (planted
		# on the straights; also cancels solver drift).
		# (Blended in, so a touch of steering doesn't drop the car off a cliff
		# from fully held to loose.)
		if not drift_mode:
			assist = lerpf(1.0, assist, smoothstep(0.03, 0.35, absf(str_in)))
			if drifting:
				assist = maxf(assist, 0.9)  # an unwanted slide: catch it
			if role == "player" and _time - last_impact_time < 0.6:
				assist = maxf(assist, 1.0)  # just been hit: straighten up fast
			# Stability control: rotating faster than the wheel asks for
			# (the nose snapping in on a flick) is caught firmly; turning in
			# is still left to the tyres.
			if yaw_rate * want > 0.0 and absf(yaw_rate) > absf(want) + 0.02:
				assist = maxf(assist, float(spec.get("stability", 0.9)))
			elif absf(str_in) > 0.2:
				# Turning in: the assist brings the nose round quickly.
				assist = maxf(assist, float(spec.get("turn_assist", 0.7)))
			# Path follow: the direction of travel swings round with the nose
			# instead of the car sliding wide (arcade grip). Stronger while
			# steering; capped so a crash or a ramp still behaves.
			var lat := vel.dot(right)
			if speed > 3.0:
				var pf := -lat * mass * float(spec.get("path_follow", 3.0)) * (0.35 + 0.65 * absf(str_in))
				apply_central_force(right * clampf(pf, -mass * GRAVITY * 0.9, mass * GRAVITY * 0.9))
		var dyaw := (want - yaw_rate)
		apply_torque(up * clampf(dyaw, -3.0, 3.0) * inertia.y * assist * 10.0)
		# Damp roll/pitch wobble.
		var rp := angular_velocity - up * yaw_rate
		apply_torque(-rp * inertia.x * 1.2)
	elif ground == 0:
		airtime += dt
		_air_peak_fall = minf(_air_peak_fall, vel.y)
		# Air: level out slowly, nose follows the arc a little, small yaw control.
		var target_up := Vector3.UP
		var axis := up.cross(target_up)
		apply_torque(axis * inertia.x * spec.get("air_level", 3.5))
		apply_torque(-angular_velocity * inertia.x * 1.4)
		apply_torque(Vector3.UP * -str_in * inertia.y * 1.2)
	if ground > 0:
		if _was_air and airtime > 0.25:
			landed.emit(airtime, -_air_peak_fall)
		airtime = 0.0
		_air_peak_fall = 0.0
	_was_air = ground == 0

	# Wrecked / stuck / upside down tracking (the game decides what to do).
	if up.dot(Vector3.UP) < 0.3:
		upside_time += dt
	else:
		upside_time = 0.0
	if speed < 1.5 and (throttle > 0.3 or brake > 0.5) and not disabled:
		stuck_time += dt
	else:
		stuck_time = maxf(0.0, stuck_time - dt * 2.0)

	# Launch guard: a car squeezed out of a pile-up or a building's collision
	# can be shot out at absurd speed by the solver (a wreck was seen at
	# 130 m altitude). Nothing in the game legitimately climbs this fast.
	if vel.y > 18.0 or speed > 95.0:
		var lv := vel
		lv.y = minf(lv.y, 18.0)
		if lv.length() > 95.0:
			lv = lv.normalized() * 95.0
		linear_velocity = lv
		angular_velocity = angular_velocity.limit_length(6.0)
	climbed_kerb = maxf(0.0, climbed_kerb - dt)
	_handle_steps()
	_handle_impacts()
	scraping = move_toward(scraping, 0.0, dt * 4.0)
	_prev_vel = vel
	Prof.end("car")


func _update_gears(sp_t: float, thr: float, dt: float) -> void:
	var gears: int = spec.get("gears", 6)
	var g := clampi(int(sp_t * gears * 0.999) + 1, 1, gears)
	_gear_timer -= dt
	if g != gear and _gear_timer <= 0.0:
		gear = g
		_gear_timer = 0.35
	var lo := float(gear - 1) / gears
	var hi := float(gear) / gears
	var in_gear := clampf((sp_t - lo) / maxf(hi - lo, 0.01), 0.0, 1.0)
	var target := lerpf(0.28, 1.0, in_gear)
	if wheels_on_ground == 0 or (wheel_slip[2] > 0.6 and thr > 0.5):
		target = lerpf(target, 1.0, 0.5 * thr)  # spinning / air revs
	if disabled:
		target = 0.12
	rpm = lerpf(rpm, target, clampf(dt * 10.0, 0.0, 1.0))


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	Prof.begin("integrate")
	_integrate(state)
	Prof.end("integrate")


func _integrate(state: PhysicsDirectBodyState3D) -> void:
	var up := state.transform.basis.y
	var base := state.transform.origin
	for i in state.get_contact_count():
		var imp: Vector3 = state.get_contact_impulse(i)
		var j := imp.length()
		var n := state.get_contact_local_normal(i)
		var at := state.get_contact_local_position(i)
		var other := state.get_contact_collider_object(i)
		# Low on the hull against the world: maybe a kerb or ledge to climb
		# (checked against the obstacle's real height in _handle_impacts).
		if j > mass * 0.05 and not (other is Car) and (at - base).dot(up) < STEP_MAX + 0.15 \
				and n.dot(Vector3.UP) < 0.75:
			_steps.append([at, n, j / mass])
			continue
		if j < mass * 1.2:
			if j > mass * 0.15:
				scraping = minf(1.0, scraping + 0.25)
			continue
		# Ground contacts under the wheels aren't impacts.
		if n.dot(state.transform.basis.y) > 0.75:
			continue
		_impacts.append([j / mass, at, n, other])


## Kerbs and low ledges: if what we touched is short enough, hop the car up
## onto it and give back the speed the contact took; otherwise it's a wall
## and goes through the normal impact path.
func _handle_steps() -> void:
	if _steps.is_empty():
		return
	var steps := _steps
	_steps = []
	if disabled or wheels_on_ground < 2:
		for s in steps:
			if s[2] > 1.2:
				_impacts.append([s[2], s[0], s[1], null])
		return
	var space := get_world_3d().direct_space_state
	var ground_y := global_position.y
	var best_top := -1.0
	for s in steps:
		var at: Vector3 = s[0]
		var n: Vector3 = s[1]
		var nh := Vector3(n.x, 0.0, n.z)
		if nh.length_squared() < 0.01:
			continue
		nh = nh.normalized()
		# A little way into the obstacle (the normal points out of it, at us).
		var probe := at - nh * 0.25
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(probe.x, ground_y + STEP_MAX + 0.4, probe.z), Vector3(probe.x, ground_y - 0.3, probe.z), RAY_MASK | (1 << 7))
		q.exclude = [get_rid()]
		q.hit_from_inside = true  # starting inside a building = a wall, not a step
		var hit := space.intersect_ray(q)
		var top := INF
		if hit and (hit["normal"] as Vector3).y > 0.6:
			top = (hit["position"] as Vector3).y - ground_y
		if top <= STEP_MAX:
			best_top = maxf(best_top, top)
		elif s[2] > 1.2:
			_impacts.append([s[2], s[0], s[1], null])  # a wall after all
	if best_top < 0.0:
		return
	# Climb: enough upward speed to clear the ledge, and keep (most of) the
	# speed we had before touching it.
	var v := linear_velocity
	var pv := _prev_vel
	var h := Vector3(v.x, 0.0, v.z)
	var ph := Vector3(pv.x, 0.0, pv.z)
	if ph.length() > h.length():
		h = h.lerp(ph * 0.96, 0.85)
	var vy := maxf(v.y, sqrt(2.0 * GRAVITY * (best_top + 0.1)) * clampf(ph.length() / 4.0, 0.4, 1.0))
	linear_velocity = Vector3(h.x, vy, h.z)
	climbed_kerb = 0.25


func _handle_impacts() -> void:
	if _impacts.is_empty():
		return
	var best: Array = _impacts[0]
	for im in _impacts:
		if im[0] > best[0]:
			best = im
	_impacts.clear()
	var dv: float = best[0]
	var at: Vector3 = best[1]
	var n: Vector3 = best[2]
	var other: Object = best[3]
	if dv < 2.0:
		return
	if _time - last_impact_time < 0.12 and dv < 8.0:
		return
	last_impact_time = _time
	var local := global_transform.affine_inverse() * at
	var side := "front"
	var size: Vector3 = spec["size"]
	if absf(local.x) / size.x > absf(local.z) / size.z:
		side = "right" if local.x > 0.0 else "left"
	else:
		side = "front" if local.z < 0.0 else "rear"
	var dur: float = spec.get("durability", 1.0)
	var amount := clampf((dv - 2.0) / 40.0, 0.0, 0.6) / dur
	# Heavy rammers (trucks, the armoured 4x4, a Workshop ram bar) hurt what they hit.
	if other is Car:
		var oc := other as Car
		amount *= float(oc.spec.get("ram", 1.0))
		last_hit_by = oc
		# Spiked wheels: a side swipe shreds the other car's tyres.
		if int(oc.spec.get("mod_spikes", 0)) > 0 and role != "player":
			amount *= 1.3
			if dv > 4.0:
				puncture = 1.0
	if role == "civilian":
		amount *= 1.6
	elif role == "police":
		amount *= 2.2  # (cops crash out spectacularly; the player is the tough one)
	# Workshop: a ram bar shields the nose, plating the whole car.
	if side == "front":
		amount *= float(spec.get("front_armour", 1.0))
	amount *= float(spec.get("plating_k", 1.0))
	# Panels: an armour plate takes the hit first; a side whose panel has
	# already come off is open and takes more.
	var plate: String = SIDE_PLATE[side]
	var wear := amount * (1.7 if dv > 9.0 else 1.1)
	if parts.get(plate, 0.0) > 0.0:
		_wear_part(plate, wear * 0.9, at, n)
		amount *= 0.6
	else:
		var list: Array = SIDE_PARTS[side]
		var gone := 0
		for pi in list.size():
			var pn: String = list[pi]
			if parts.get(pn, 0.0) <= 0.0:
				gone += 1
				continue
			# The bumper goes first; the bonnet / boot behind it wears slower.
			_wear_part(pn, wear * (1.0 if pi == 0 else 0.55), at, n)
		if gone > 0:
			amount *= 1.0 + 0.25 * gone
	dmg[side] = minf(1.0, dmg[side] + amount)
	health = maxf(0.2 if immortal else 0.0, health - amount * 0.6)
	if dv > 9.0 and (side == "left" or side == "right"):
		grip_loss = clampf(dv / 30.0, 0.2, 0.8)
	# Arcade: the player's car shrugs off most of the spin from a ram (police
	# PIT you, they don't pirouette you into a wall).
	if role == "player" and other is Car:
		var av := angular_velocity
		angular_velocity = Vector3(av.x, av.y * 0.5, av.z)
	impact.emit(dv, at, n, other)
	if health <= 0.0 and not disabled and not immortal:
		disabled = true
		wrecked.emit()


func _wear_part(pn: String, k: float, at: Vector3, n: Vector3) -> void:
	var before: float = parts.get(pn, 0.0)
	if before <= 0.0:
		return
	parts[pn] = maxf(0.0, before - k)
	if parts[pn] <= 0.0:
		part_lost.emit(pn, at, n)


## Teleport (recovery / pooling): zero momentum, clear wheel history.
func place(xf: Transform3D, vel := Vector3.ZERO) -> void:
	global_transform = xf
	linear_velocity = vel
	angular_velocity = Vector3.ZERO
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, vel)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	for i in 4:
		_comp[i] = 0.0
	airtime = 0.0
	_was_air = false
	stuck_time = 0.0
	upside_time = 0.0
	_impacts.clear()
	_steps.clear()
