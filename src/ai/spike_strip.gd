class_name SpikeStrip
extends Area3D
## A stinger across the road. Running over it punctures the tyres: less
## grip and top speed for the rest of the run (Car.puncture), sparks from
## the rims. It is laid ahead of a roadblock, so it's visible on approach.

signal spiked

const LENGTH := 7.0
var player: Car
var _used := false


func _ready() -> void:
	collision_layer = 0
	collision_mask = 1 << 2
	monitoring = true
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3(LENGTH, 0.6, 1.0)
	cs.shape = b
	cs.position.y = 0.3
	add_child(cs)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.09)
	mat.metallic = 0.6
	mat.roughness = 0.4
	var hi := StandardMaterial3D.new()
	hi.albedo_color = Color(0.95, 0.75, 0.1)
	hi.emission_enabled = true
	hi.emission = Color(0.9, 0.6, 0.05)
	hi.emission_energy_multiplier = 0.6
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var spike := PrismMesh.new()
	spike.size = Vector3(0.08, 0.14, 0.08)
	mm.mesh = spike
	mm.instance_count = 56
	for i in 56:
		var x := -LENGTH * 0.5 + (i / 2) * (LENGTH / 28.0)
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(x, 0.1, -0.12 if i % 2 == 0 else 0.12)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	add_child(mmi)
	var bar := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(LENGTH, 0.05, 0.4)
	bar.mesh = bm
	bar.position.y = 0.03
	bar.material_override = hi
	add_child(bar)
	body_entered.connect(_on_body)


func _on_body(b: Node) -> void:
	if _used or b != player:
		return
	_used = true
	player.puncture = 1.0
	player.grip_loss = 1.2
	spiked.emit()
