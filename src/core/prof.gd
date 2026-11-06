class_name Prof
extends RefCounted
## Tiny section profiler for benchmarks: Prof.begin("x") ... Prof.end("x");
## Prof.report() prints total ms per section. Off unless enabled.
static var enabled := false
static var _t := {}
static var _acc := {}
static var _n := {}


static func begin(k: String) -> void:
	if enabled:
		_t[k] = Time.get_ticks_usec()


static func end(k: String) -> void:
	if enabled and _t.has(k):
		_acc[k] = _acc.get(k, 0) + Time.get_ticks_usec() - _t[k]
		_n[k] = _n.get(k, 0) + 1


static var _frame_acc := 0
static var _last_total := 0


## Profiled script time since the last call (ms).
static func frame_ms() -> float:
	var total := 0
	for k in _acc:
		if k != "flow_field" and k != "nearest" and k != "driver" and k != "integrate":
			total += _acc[k]
	var d := total - _last_total
	_last_total = total
	return d / 1000.0


static func report(frames: int) -> void:
	var keys := _acc.keys()
	keys.sort_custom(func(a, b): return _acc[a] > _acc[b])
	for k in keys:
		print("PROF %-22s %8.3f ms/frame  (%d calls)" % [k, _acc[k] / 1000.0 / maxf(frames, 1), _n[k]])
