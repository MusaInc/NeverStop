class_name SafeSave
extends RefCounted
## Shared persistence envelope (WorldState · CitySwing · NEVER STOP; copied by
## tools/shared/sync.py). Game-agnostic: each game passes its own schema check.
##
##   write(path, data)        temp file → read back and parse → keep the current
##                            file as .bak only if it is itself valid → rename.
##                            Every filesystem step's result is checked; returns
##                            "" or a reason (the caller reports it, never
##                            claims "saved" on failure).
##   read(path, check)        primary, then .bak; a file is accepted only when it
##                            parses to a Dictionary and check(d) returns "".
##                            last_error / last_source say what happened.
##   migrate_dir(old, files)  desktop only: copy saves left in an older app-data
##                            folder (an app rename) – never moves or deletes.
##
## Helpers for schema checks: has_types(d, {"key": TYPE_FLOAT, ...}).

static var last_error := ""
static var last_source := ""   # "primary" | "backup" | ""


static func write(path: String, data: Dictionary) -> String:
	var text := JSON.stringify(data)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "cannot open %s (%s)" % [tmp, error_string(FileAccess.get_open_error())]
	f.store_string(text)
	var werr := f.get_error()
	f.close()
	if werr != OK:
		return "write failed (%s)" % error_string(werr)
	# Read the temp file back: a short write (disk full) must not replace a good save.
	var back := FileAccess.get_file_as_string(tmp)
	if back.length() != text.length() or not (JSON.parse_string(back) is Dictionary):
		DirAccess.remove_absolute(_abs(tmp))
		return "the saved file did not read back (disk full?)"
	if FileAccess.file_exists(path):
		# Only a valid primary becomes the backup: a corrupt one must not push
		# out the last good .bak.
		if JSON.parse_string(FileAccess.get_file_as_string(path)) is Dictionary:
			var e1 := DirAccess.rename_absolute(_abs(path), _abs(path + ".bak"))
			if e1 != OK:
				# (rename over an existing file fails on some platforms: copy)
				e1 = DirAccess.copy_absolute(_abs(path), _abs(path + ".bak"))
				if e1 != OK:
					return "cannot keep the backup (%s)" % error_string(e1)
	var e2 := DirAccess.rename_absolute(_abs(tmp), _abs(path))
	if e2 != OK:
		e2 = DirAccess.copy_absolute(_abs(tmp), _abs(path))
		DirAccess.remove_absolute(_abs(tmp))
		if e2 != OK:
			return "cannot replace the save (%s)" % error_string(e2)
	return ""


static func read(path: String, check: Callable = Callable()) -> Variant:
	last_error = ""
	last_source = ""
	var why: Array[String] = []
	for p in [path, path + ".bak"]:
		if not FileAccess.file_exists(p):
			continue
		var d = JSON.parse_string(FileAccess.get_file_as_string(p))
		var reason := ""
		if not (d is Dictionary):
			reason = "not valid JSON"
		elif check.is_valid():
			reason = String(check.call(d))
		if reason == "":
			last_source = "primary" if p == path else "backup"
			if p != path:
				push_warning("SafeSave: %s unusable (%s); loaded the backup" % [path.get_file(), ", ".join(why)])
			return d
		why.append("%s: %s" % [p.get_file(), reason])
	last_error = ", ".join(why)
	if last_error != "":
		push_warning("SafeSave: no usable save – " + last_error)
	return null


## True when every present key has the given type and every `required` key exists (int and float are
## interchangeable: JSON gives floats). Returns "" or the first problem.
static func has_types(d: Dictionary, spec: Dictionary, required: Array = []) -> String:
	for k in required:
		if not d.has(k):
			return "missing " + str(k)
	for k in spec:
		if not d.has(k):
			continue  # (older saves lack newer fields: the loader defaults them)
		var want: int = spec[k]
		var got := typeof(d[k])
		var num := (want == TYPE_FLOAT or want == TYPE_INT) and (got == TYPE_FLOAT or got == TYPE_INT)
		if got != want and not num:
			return "%s has the wrong type" % k
		if num and not is_finite(float(d[k])):
			return "%s is not a number" % k
	return ""


## Field-level repair against a defaults dictionary (profiles): any key whose
## value has the wrong type – or a list holding the wrong kind of element, or a
## number that isn't finite – goes back to its default, keeping the rest of the
## player's progress. Unknown keys are kept (newer builds). Returns what it fixed.
static func repair(data: Dictionary, defaults: Dictionary) -> Array[String]:
	var fixed: Array[String] = []
	for k in defaults:
		if not data.has(k):
			data[k] = _copy(defaults[k])
			continue
		var want := typeof(defaults[k])
		var v = data[k]
		var got := typeof(v)
		var num_w := want == TYPE_INT or want == TYPE_FLOAT
		var ok := got == want or (num_w and (got == TYPE_INT or got == TYPE_FLOAT))
		if ok and num_w and not is_finite(float(v)):
			ok = false
		if ok and want == TYPE_ARRAY and not (defaults[k] as Array).is_empty():
			var et := typeof((defaults[k] as Array)[0])
			for x in v:
				var xt := typeof(x)
				if xt != et and not ((et == TYPE_INT or et == TYPE_FLOAT) and (xt == TYPE_INT or xt == TYPE_FLOAT)):
					ok = false
					break
		if not ok:
			data[k] = _copy(defaults[k])
			fixed.append(str(k))
		elif want == TYPE_INT and got == TYPE_FLOAT:
			data[k] = int(v)  # (JSON numbers come back as floats)
	if not fixed.is_empty():
		push_warning("SafeSave: repaired " + ", ".join(fixed))
	return fixed


static func _copy(v: Variant) -> Variant:
	return v.duplicate(true) if (v is Array or v is Dictionary) else v


## Copies `files` from an older app-data folder name (desktop only; iOS keeps
## user:// in the app's container whatever the name). Never overwrites a save
## in the current folder and never removes the old copy. Returns files copied.
static func migrate_dir(old_names: Array, files: Array) -> int:
	if OS.get_name() in ["iOS", "Android", "Web"]:
		return 0
	var cur := OS.get_user_data_dir()
	var parent := cur.get_base_dir()
	var n := 0
	for f: String in files:
		if FileAccess.file_exists(cur.path_join(f)):
			continue
		for old: String in old_names:
			var src := parent.path_join(old).path_join(f)
			if src != cur.path_join(f) and FileAccess.file_exists(src):
				DirAccess.make_dir_recursive_absolute(cur)
				if DirAccess.copy_absolute(src, cur.path_join(f)) == OK:
					n += 1
					print("SafeSave: brought %s over from %s" % [f, parent.path_join(old)])
				break
	return n


static func _abs(p: String) -> String:
	return ProjectSettings.globalize_path(p)
