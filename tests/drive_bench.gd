class_name DriveBench
extends Node3D
## A flat test track for vehicle tests and the handling report: a 2 km
## ground slab on the street layer, optional walls and a ramp.

var ground: StaticBody3D


func _ready() -> void:
	ground = StaticBody3D.new()
	ground.collision_layer = 1 << 3
	ground.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000, 2, 4000)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	ground.add_child(cs)
	add_child(ground)


func add_wall(center: Vector3, size: Vector3, yaw := 0.0) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = 1 | 2
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	b.add_child(cs)
	b.position = center
	b.rotation.y = yaw
	add_child(b)
	return b


## A wedge ramp: rises `h` over `length`, facing -Z (drive toward -Z to jump).
func add_ramp(at: Vector3, length: float, h: float, width := 8.0) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = 1 << 3
	var cs := CollisionShape3D.new()
	var hull := ConvexPolygonShape3D.new()
	var w := width * 0.5
	hull.points = PackedVector3Array([
		Vector3(-w, 0, 0), Vector3(w, 0, 0), Vector3(-w, 0, -length), Vector3(w, 0, -length),
		Vector3(-w, h, -length), Vector3(w, h, -length)])
	cs.shape = hull
	b.add_child(cs)
	b.position = at
	add_child(b)
	return b


func spawn_car(id: String, at := Vector3.ZERO, yaw := 0.0, role := "player") -> Car:
	var car := Car.new()
	var spec := CarCatalog.spec(id) if not id.begins_with("police_") else CarCatalog.police_spec(id.trim_prefix("police_"))
	car.setup(spec, role)
	add_child(car)
	car.place(Transform3D(Basis(Vector3.UP, yaw), at + Vector3.UP * 0.6))
	return car


static func frames(tree: SceneTree, n: int) -> void:
	for i in n:
		await tree.physics_frame
