class_name FrameGovernor
extends Node
## Dynamic resolution: holds the frame rate on slower or hot phones by easing
## the 3D render scale down, and back up to Settings' cap when there is
## headroom. The HUD is unaffected (it always draws at native resolution).
## (Ported from CitySwing's src/core/frame_governor.gd.)
##
## Decisions use the GPU's measured render time when the driver reports it,
## else the real frame interval. Changes are rare (each one reallocates the
## render buffers) and in ~8% steps, so the picture never visibly "breathes".

const CHECK_EVERY := 0.5      # s between samples
const MIN_GAP := 2.0          # s between scale changes
const STEP := 0.92
const FLOOR_FRACTION := 0.62  # never below 62% of the cap…
const ABS_FLOOR := 0.42       # …or 42% of native

var enabled := true
var scale := 1.0
var _cap := 1.0
var _acc := 0.0
var _frames := 0
var _since_change := 0.0
var _headroom_time := 0.0
var _vp_rid: RID
var _last_us := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var vp := get_viewport()
	_vp_rid = vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	var settings := get_node_or_null("/root/Settings")
	if settings:
		settings.changed.connect(_reset)
	_reset()
	_last_us = Time.get_ticks_usec()


func _reset() -> void:
	var settings := get_node_or_null("/root/Settings")
	_cap = settings.render_scale_cap() if settings else get_viewport().scaling_3d_scale
	scale = _cap
	_since_change = 0.0
	_headroom_time = 0.0


func _process(dt: float) -> void:
	var now := Time.get_ticks_usec()
	var real_dt := (now - _last_us) / 1e6
	_last_us = now
	if not enabled or get_tree().paused:
		return
	_acc += real_dt
	_frames += 1
	_since_change += real_dt
	if _acc < CHECK_EVERY:
		return
	var frame_ms := _acc * 1000.0 / _frames
	_acc = 0.0
	_frames = 0
	var budget := 1000.0 / maxf(Engine.max_fps if Engine.max_fps > 0 else 60, 1)
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)
	var gpu_known := gpu_ms > 0.05
	var floor_scale := maxf(_cap * FLOOR_FRACTION, ABS_FLOOR)
	var behind := frame_ms > budget * 1.18
	var gpu_bound := (not gpu_known) or gpu_ms > budget * 0.8
	if behind and gpu_bound:
		_headroom_time = 0.0
		if _since_change >= MIN_GAP and scale > floor_scale + 0.001:
			_set_scale(maxf(scale * STEP, floor_scale))
		return
	# Recover only with clear headroom, measured on the GPU (without a GPU
	# timer, a vsynced frame interval can't show headroom: probe slowly).
	var roomy := (gpu_known and gpu_ms < budget * 0.62) or (not gpu_known and not behind)
	_headroom_time = _headroom_time + CHECK_EVERY if roomy else 0.0
	var wait := 4.0 if gpu_known else 12.0
	if _headroom_time >= wait and scale < _cap - 0.001 and _since_change >= MIN_GAP:
		_headroom_time = 0.0
		_set_scale(minf(scale / STEP, _cap))


func _set_scale(v: float) -> void:
	scale = v
	_since_change = 0.0
	get_viewport().scaling_3d_scale = v
