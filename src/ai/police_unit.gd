class_name PoliceUnit
extends RefCounted
## One police unit in the pursuit. Simulated at one of three tiers by the
## PursuitDirector (the fourth, D, is just a count of units on their way):
##   A  close (< ~90 m or in view): a physical Car, AI every physics frame
##   B  nearby: a physical Car, AI decisions 5x a second (controls held between)
##   C  distant: no body – a point moving along the road graph at road speed
##      toward its goal; promoted to a Car when it gets close *out of view*
## Roles decide what a unit wants; states are what it's doing now.

enum Tier { A, B, C }

const ROLES := ["pursuer", "interceptor", "aggressor", "blocker", "heavy"]

var id := 0
var kind := "patrol"          # CarCatalog.POLICE key
var role := "pursuer"
var state := "respond"        # respond, pursue, ram, intercept, block, roadblock, recover, wrecked, leave
var tier := Tier.C
var car: Car
var visual: CarVisual
var driver: AIDriver
# Tier C position on the road graph.
var lane := -1
var s := 0.0
var pos := Vector3.ZERO
var heading := Vector3.FORWARD
var road_speed := 30.0
# Brain.
var think_t := 0.0
var route_t := 0.0
var skill := 0.85
var aggression := 0.5
var flank := 0.0              # lateral offset preference when following
var last_seen := Vector3.INF
var seen_t := 0.0             # seconds since it last saw the player
var wrecked_t := 0.0
var counted_wreck := false
var block_point := Vector3.INF
var block_dir := Vector3.FORWARD
var roadblock_id := -1
var spawn_time := 0.0
var close_time := 0.0         # seconds spent within 12 m of the player
var hit_player_t := -10.0
var hold_t := 0.0              # virtual and held near the player (see PursuitDirector._tiers)
# Watchdog (director): seconds without progress / off the road / inside geometry.
var idle_t := 0.0
var off_t := 0.0
var inside_t := 0.0
var watch_t := 0.0
var last_watch_pos := Vector3.INF


func is_physical() -> bool:
	return car != null


func world_pos() -> Vector3:
	return car.global_position if car else pos


func alive() -> bool:
	return state != "wrecked"
