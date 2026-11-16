class_name LcsStorm
extends RefCounted
## 12m20s to full collapse. The final centre must be a validated connected road.
const PHASES := [[90.0, 90.0, 850.0, 1.0], [65.0, 75.0, 560.0, 2.0],
	[55.0, 65.0, 330.0, 3.0], [45.0, 55.0, 170.0, 5.0],
	[35.0, 45.0, 80.0, 8.0], [25.0, 35.0, 24.0, 12.0], [0.0, 60.0, 0.0, 20.0]]
var final_center := Vector2.ZERO
var initial_center := Vector2.ZERO
var initial_radius := 2000.0

func sample(t: float) -> Dictionary:
	var center := initial_center
	var radius := initial_radius
	for i in PHASES.size():
		var phase: Array = PHASES[i]
		var next_radius: float = phase[2]
		# Move toward the selected road, with nesting guaranteed even at the bridge.
		var offset := final_center - center
		var next_center := center + offset.limit_length(maxf(0.0, radius - next_radius))
		var duration: float = phase[0] + phase[1]
		if t < duration or i == PHASES.size() - 1:
			var k := clampf((t - float(phase[0])) / float(phase[1]), 0.0, 1.0)
			return {"center": center.lerp(next_center, k), "radius": lerpf(radius, next_radius, k),
				"next_center": next_center, "next_radius": next_radius, "phase": i + 1,
				"countdown": maxf(0.0, float(phase[0]) - t) if t < float(phase[0]) else maxf(0.0, duration - t),
				"moving": t >= float(phase[0]), "dps": phase[3]}
		t -= duration
		center = next_center
		radius = next_radius
	return {}

static func outside(pos: Vector3, circle: Dictionary) -> bool:
	return Vector2(pos.x, pos.z).distance_to(circle.center) > float(circle.radius)
