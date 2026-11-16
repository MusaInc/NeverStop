extends Node
func test_lcs_real_jolt_ram(t) -> void:
	var track := DriveBench.new()
	add_child(track)
	var cars: Array[Car] = []
	for kind in ["sports", "heavy"]:
		var c := LcsCompetitor.new()
		c.setup(LcsRules.vehicle(kind), "competitor")
		track.add_child(c)
		cars.append(c)
	cars[0].place(Transform3D(Basis.IDENTITY, Vector3(0, 0.6, 18)))
	cars[1].place(Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0.6, -18)))
	await DriveBench.frames(get_tree(), 30)
	cars[0].linear_velocity = Vector3(0, 0, -28)
	cars[1].linear_velocity = Vector3(0, 0, 18)
	var contacts := [0]
	cars[0].impact.connect(func(_s, _p, _n, other):
		if other == cars[1]:
			contacts[0] += 1)
	await DriveBench.frames(get_tree(), 90)
	t.check(contacts[0] > 0, "Jolt reports competitor contact")
	t.check(cars[0].health < 1 and cars[1].health < 1, "real ram damages both vehicles")
	t.check(cars[0].health < cars[1].health, "mass and durability affect real impact outcome")
	t.check(cars[0].parts.bumper_f < 1, "real front hit wears body panels")
	t.note("real ram HP: sports %.1f / heavy %.1f" % [cars[0].health * 100, cars[1].health * 100])
	track.queue_free()
	await get_tree().physics_frame
