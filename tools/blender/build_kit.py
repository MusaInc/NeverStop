"""Procedural asset kit for City Swing.

Run:  blender -b --factory-startup --python tools/blender/build_kit.py -- <out_dir>

Every model is built from code (bmesh + modifiers, no hand modelling) and
exported as its own GLB. Conventions:
  * Blender Z-up / +Y forward  ->  glTF/Godot Y-up / -Z forward.
  * Material names are stable; Godot keys off a few of them ("lamp", "glass",
    "paint") to swap in shared runtime materials.
  * Origins sit where Godot places the piece (base centre, or joint pivot for
    character parts).
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "assets/models"
os.makedirs(OUT, exist_ok=True)

# ---------------------------------------------------------------- helpers
_mats = {}


def mat(name, rgb, rough=0.7, metal=0.0, emit=None):
    if name in _mats:
        return _mats[name]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emit:
        bsdf.inputs["Emission Color"].default_value = (*emit, 1.0)
        bsdf.inputs["Emission Strength"].default_value = 3.0
    _mats[name] = m
    return m


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()


def new_obj(name, bm, material=None):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if material:
        me.materials.append(material)
    return ob


def box(name, size, loc=(0, 0, 0), material=None, bevel=0.0, segs=2):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    ob = new_obj(name, bm, material)
    if bevel > 0:
        mod = ob.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = segs
        mod.limit_method = "ANGLE"
    return ob


def cyl(name, r, h, loc=(0, 0, 0), material=None, verts=16, r2=None, cap=True):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=cap, cap_tris=False, segments=verts,
                          radius1=r, radius2=r if r2 is None else r2, depth=h)
    bmesh.ops.translate(bm, vec=Vector(loc) + Vector((0, 0, h / 2)), verts=bm.verts)
    return new_obj(name, bm, material)


def sphere(name, r, loc=(0, 0, 0), material=None, segs=16, rings=10, scale=(1, 1, 1)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r)
    bmesh.ops.scale(bm, vec=Vector(scale), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return new_obj(name, bm, material)


def dome(name, r, loc=(0, 0, 0), material=None, segs=16, rings=6, height=1.0):
    """Upper hemisphere, flattened/raised by `height`."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings * 2, radius=r)
    for v in [v for v in bm.verts if v.co.z < -1e-4]:
        bm.verts.remove(v)
    bmesh.ops.scale(bm, vec=Vector((1, 1, height)), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return new_obj(name, bm, material)


def smooth(ob, level=1, shade=True):
    mod = ob.modifiers.new("sub", "SUBSURF")
    mod.levels = level
    mod.render_levels = level
    if shade:
        for p in ob.data.polygons:
            p.use_smooth = True
    return ob


def join(name, objs, origin=(0, 0, 0)):
    objs = [o for o in objs if o is not None]
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.convert(target="MESH")  # apply modifiers
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    if len(objs) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    bpy.context.scene.cursor.location = origin
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    return ob


def export(filename, objs=None):
    bpy.ops.object.select_all(action="DESELECT")
    targets = objs or [o for o in bpy.context.scene.objects if o.type == "MESH"]
    for o in targets:
        o.select_set(True)
    path = os.path.join(OUT, filename)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True, export_materials="EXPORT",
                              export_vertex_color="ACTIVE")
    tris = sum(len(o.data.polygons) for o in targets)
    print(f"KIT {filename}: {len(targets)} objects, ~{tris} faces")


# ---------------------------------------------------------------- props
def water_tower():
    reset()
    wood = mat("timber", (0.42, 0.27, 0.17), 0.85)
    steel = mat("steel_dark", (0.16, 0.16, 0.17), 0.5, 0.6)
    roofm = mat("roof_metal", (0.25, 0.3, 0.32), 0.45, 0.5)
    parts = [cyl("tank", 2.3, 4.2, (0, 0, 3.2), wood, 20)]
    for i in range(5):
        parts.append(cyl(f"hoop{i}", 2.36, 0.12, (0, 0, 3.5 + i * 0.85), steel, 20))
    parts.append(cyl("cap", 2.5, 1.6, (0, 0, 7.4), roofm, 20, r2=0.15))
    for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        leg = cyl("leg", 0.12, 3.3, (sx * 1.5, sy * 1.5, 0), steel, 6)
        parts.append(leg)
    parts.append(box("deck", (3.8, 3.8, 0.15), (0, 0, 3.15), steel))
    parts.append(box("xb1", (3.2, 0.06, 0.06), (0, 1.5, 1.6), steel))
    parts.append(box("xb2", (3.2, 0.06, 0.06), (0, -1.5, 1.6), steel))
    export("water_tower.glb", [join("water_tower", parts)])


def ac_unit():
    reset()
    body = mat("hvac", (0.72, 0.73, 0.72), 0.5, 0.2)
    dark = mat("steel_dark", (0.12, 0.12, 0.13), 0.5, 0.5)
    parts = [box("b", (3.0, 2.0, 1.4), (0, 0, 0.7), body, bevel=0.05)]
    for x in (-0.75, 0.75):
        parts.append(cyl("fan", 0.6, 0.06, (x, 0, 1.4), dark, 16))
    export("ac_unit.glb", [join("ac_unit", parts)])


def antenna():
    reset()
    steel = mat("steel_light", (0.7, 0.7, 0.72), 0.4, 0.7)
    red = mat("lamp_red", (0.9, 0.1, 0.05), 0.4, 0.0, emit=(1.0, 0.1, 0.05))
    parts = [cyl("mast", 0.18, 14, (0, 0, 0), steel, 8, r2=0.06)]
    for i in range(4):
        parts.append(box("arm", (2.2 - i * 0.4, 0.06, 0.06), (0, 0, 3 + i * 2.8), steel))
    parts.append(sphere("beacon", 0.22, (0, 0, 14.1), red, 8, 6))
    export("antenna.glb", [join("antenna", parts)])


def streetlight():
    reset()
    pole = mat("lamp_post", (0.13, 0.15, 0.16), 0.45, 0.6)
    lamp = mat("lamp", (1.0, 0.92, 0.75), 0.3, 0.0, emit=(1.0, 0.85, 0.6))
    parts = [cyl("pole", 0.11, 7.0, (0, 0, 0), pole, 8, r2=0.07),
             cyl("foot", 0.2, 0.6, (0, 0, 0), pole, 8)]
    arm = box("arm", (0.08, 1.6, 0.08), (0, 0.75, 6.9), pole)
    head = box("head", (0.34, 0.7, 0.16), (0, 1.45, 6.82), pole, bevel=0.03)
    glow = box("glow", (0.28, 0.6, 0.04), (0, 1.45, 6.72), lamp)
    export("streetlight.glb", [join("streetlight", parts + [arm, head, glow])])


# tree(), pedestrian(): tools/blender/build_street.py


# ------------------------------------------------------------- landmarks
def clock_crown():
    """Crown for a waterfront clock tower (loosely early-1900s Liverpool):
    clock stage with four faces, colonnaded drum, ribbed dome, finial bird."""
    reset()
    stone = mat("stone_light", (0.78, 0.76, 0.72), 0.8)
    dark = mat("stone_dark", (0.45, 0.44, 0.42), 0.8)
    face = mat("clock_face", (0.95, 0.92, 0.82), 0.4, 0.0, emit=(0.4, 0.38, 0.3))
    bronze = mat("bronze", (0.35, 0.5, 0.42), 0.4, 0.8)  # verdigris
    gold = mat("gilt", (0.85, 0.66, 0.28), 0.3, 1.0)
    p = [box("stage", (16, 16, 12), (0, 0, 6), stone, bevel=0.2)]
    p.append(box("cornice", (17.2, 17.2, 0.9), (0, 0, 12.2), dark, bevel=0.1))
    for ang in range(4):  # clock faces
        a = ang * math.pi / 2
        c = cyl("clock", 3.6, 0.3, (0, 0, 0), face, 32)
        c.rotation_euler = (math.pi / 2, 0, a)
        c.location = (math.sin(a) * 8.05, -math.cos(a) * 8.05, 6.5)
        p.append(c)
    p.append(cyl("drum", 6.2, 7.0, (0, 0, 12.6), stone, 24))
    for i in range(12):  # colonnade
        a = i / 12 * math.tau
        p.append(cyl("col", 0.42, 6.6, (math.cos(a) * 6.9, math.sin(a) * 6.9, 12.8), stone, 8))
    p.append(cyl("ring", 7.4, 0.8, (0, 0, 19.4), dark, 24))
    p.append(dome("dome", 6.0, (0, 0, 20.2), bronze, 24, 6, 1.25))
    for i in range(8):  # dome ribs
        a = i / 8 * math.tau
        rib = box("rib", (0.35, 0.35, 7.2), (0, 0, 0), dark)
        rib.location = (math.cos(a) * 4.3, math.sin(a) * 4.3, 23.4)
        rib.rotation_euler = (0, -0.75, a)
        rib.rotation_euler = (math.sin(a) * 0.75, -math.cos(a) * 0.75, 0)
        p.append(rib)
    p.append(cyl("lantern", 1.3, 3.0, (0, 0, 27.4), stone, 12))
    p.append(cyl("plinth", 0.9, 1.0, (0, 0, 30.4), dark, 12))
    # Stylised mythical bird: body, neck, wings half-raised.
    p.append(sphere("bird_body", 1.0, (0, 0, 32.4), gold, 12, 8, (0.7, 1.3, 0.9)))
    p.append(sphere("bird_head", 0.45, (0, 1.2, 33.6), gold, 10, 6))
    p.append(cyl("bird_neck", 0.3, 1.2, (0, 0.8, 32.6), gold, 8))
    for s in (-1, 1):
        w = box("wing", (2.6, 1.2, 0.15), (s * 1.6, -0.1, 33.0), gold, bevel=0.05)
        w.rotation_euler = (0, s * 0.5, 0)
        p.append(w)
    export("clock_crown.glb", [join("clock_crown", p)])


def harbour_dome():
    """Big central dome with four corner cupolas (port-authority style)."""
    reset()
    stone = mat("stone_light", (0.78, 0.76, 0.72), 0.8)
    copper = mat("copper_patina", (0.36, 0.52, 0.46), 0.5, 0.6)
    p = [cyl("drum", 13, 8, (0, 0, 0), stone, 32), cyl("ring", 14, 1.0, (0, 0, 8), stone, 32),
         dome("dome", 12.5, (0, 0, 9), copper, 32, 8, 1.15), cyl("lantern", 2.0, 4.0, (0, 0, 22.8), stone, 12),
         dome("lanterncap", 2.2, (0, 0, 26.8), copper, 12, 4)]
    for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        p.append(cyl("cup", 3.0, 5.0, (sx * 24, sy * 18, -8), stone, 12))
        p.append(dome("cupd", 3.1, (sx * 24, sy * 18, -3), copper, 12, 4, 1.3))
    export("harbour_dome.glb", [join("harbour_dome", p)])


def beacon():
    """Radio-beacon tower: tapering concrete shaft with a revolving-restaurant pod."""
    reset()
    conc = mat("concrete", (0.82, 0.8, 0.76), 0.85)
    glass = mat("glass", (0.25, 0.35, 0.42), 0.1, 0.6)
    steel = mat("steel_light", (0.7, 0.7, 0.72), 0.4, 0.7)
    red = mat("lamp_red", (0.9, 0.1, 0.05), 0.4, 0.0, emit=(1.0, 0.1, 0.05))
    dark = mat("concrete_dark", (0.6, 0.6, 0.6), 0.85)
    p = [cyl("shaft", 6.5, 118, (0, 0, 0), conc, 24, r2=5.0)]
    # Slip-form rings every 13 m and a glazed lift band halfway up give the
    # shaft scale; aviation lights at three heights read at night.
    for i in range(1, 9):
        z = i * 13.0
        r = 6.5 - 1.5 * z / 118.0
        p.append(cyl(f"ring_{i}", r + 0.22, 0.7, (0, 0, z - 0.35), dark, 24))
    p.append(cyl("lobby_band", 6.25, 4.0, (0, 0, 53.0), glass, 24, r2=6.05))
    for k, z in enumerate((40.0, 78.0)):
        r = 6.5 - 1.5 * z / 118.0
        for a in range(4):
            ang = a * math.pi / 2 + k * math.pi / 4
            p.append(sphere(f"avlight_{k}_{a}", 0.35, (math.cos(ang) * (r + 0.3), math.sin(ang) * (r + 0.3), z), red, 6, 4))
    p.append(cyl("pod_base", 7.0, 3.0, (0, 0, 115), conc, 24, r2=10.5))
    p.append(cyl("pod_glass", 10.5, 7.0, (0, 0, 118), glass, 32, r2=11.0))
    p.append(cyl("pod_top", 11.4, 1.6, (0, 0, 125), conc, 32, r2=9.0))
    p.append(cyl("crown", 5.0, 6.0, (0, 0, 126.6), conc, 16, r2=4.2))
    p.append(cyl("mast", 0.6, 12, (0, 0, 132.6), steel, 8, r2=0.2))
    p.append(sphere("tip", 0.5, (0, 0, 144.8), red, 8, 6))
    export("beacon.glb", [join("beacon", p)])


def cathedral_tower_top():
    """Pinnacles + louvred belfry stage for the sandstone cathedral tower."""
    reset()
    sand = mat("sandstone", (0.62, 0.38, 0.3), 0.9)
    dark = mat("sandstone_dark", (0.42, 0.25, 0.2), 0.9)
    p = [box("belfry", (34, 34, 20), (0, 0, 10), sand, bevel=0.3)]
    for i in range(3):  # tall louvred lancets on each face
        for a in range(4):
            ang = a * math.pi / 2
            off = (i - 1) * 8.5
            x = math.cos(ang) * 17.1 - math.sin(ang) * off
            y = math.sin(ang) * 17.1 + math.cos(ang) * off
            l = box("lancet", (2.8, 0.6, 14), (x, y, 10), dark)
            l.rotation_euler = (0, 0, ang + math.pi / 2)
            p.append(l)
    for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        p.append(box("pier", (5, 5, 26), (sx * 15, sy * 15, 13), sand))
        p.append(cyl("pinnacle", 2.6, 9, (sx * 15, sy * 15, 26), sand, 8, r2=0.2))
    p.append(box("parapet", (35, 35, 2), (0, 0, 21), dark))
    export("cathedral_top.glb", [join("cathedral_top", p)])


def viaduct():
    """25 m bay of an elevated railway: brick arch pier, iron deck, girders."""
    reset()
    brick = mat("brick_dark", (0.42, 0.2, 0.15), 0.9)
    iron = mat("iron", (0.2, 0.24, 0.26), 0.5, 0.7)
    p = [box("pier_a", (9, 3, 9.2), (0, 0, 4.6), brick)]
    p.append(box("cap", (10, 3.6, 0.8), (0, 0, 9.4), brick))
    p.append(box("deck", (9, 25, 0.8), (0, 12.5, 10.2), iron))
    for x in (-4.3, 4.3):
        p.append(box("girder", (0.4, 25, 1.6), (x, 12.5, 11.2), iron))
        for i in range(10):
            p.append(box("post", (0.2, 0.2, 1.4), (x, i * 2.5, 11.4), iron))
    export("viaduct.glb", [join("viaduct", p)])


# ------------------------------------------------------------------ trains
TRAIN_PROFILE = [(1.40, 0.95), (1.45, 1.35), (1.46, 2.7), (1.40, 3.2), (1.2, 3.6), (0.75, 3.84), (0.0, 3.9)]


def _ring(prof, y, sx=1.0, sz=1.0):
    """Closed cross-section (mirrored half profile) at Y = y, scaled about the floor."""
    half = [(x * sx, 0.95 + (z - 0.95) * sz) for x, z in prof]
    full = half + [(-x, z) for x, z in reversed(half[:-1])]
    return [Vector((x, y, z)) for x, z in full]


def loft_rings(name, rings, material, cap_ends=True):
    """Skin between successive cross-section rings (same vertex count)."""
    bm = bmesh.new()
    vrings = [[bm.verts.new(v) for v in r] for r in rings]
    n = len(rings[0])
    for a, b in zip(vrings, vrings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap_ends:
        bm.faces.new(list(reversed(vrings[0])))
        bm.faces.new(vrings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = new_obj(name, bm, material)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


def train_car(cab):
    """Elevated-railway car, 17.6 m over the couplers, origin at rail top under
    its centre, front (+Y in Blender = -Z in Godot). Cab cars have a raked
    nose with a wrap windscreen and headlights at the front."""
    reset()
    body = mat("train_body", (0.88, 0.87, 0.83), 0.35, 0.1)
    stripe = mat("train_stripe", (0.72, 0.09, 0.08), 0.4, 0.1)
    glass = mat("train_window", (0.07, 0.09, 0.11), 0.08, 0.3, emit=(1.0, 0.86, 0.62))
    dark = mat("train_dark", (0.12, 0.12, 0.13), 0.6, 0.4)
    roof = mat("train_roof", (0.55, 0.56, 0.57), 0.5, 0.3)
    door = mat("train_door", (0.3, 0.32, 0.34), 0.4, 0.3)
    lamp = mat("lamp", (1.0, 0.95, 0.85), 0.2, 0.0, emit=(1.0, 0.95, 0.85))
    p = []
    L = 8.8
    if cab:
        rings = [_ring(TRAIN_PROFILE, -L), _ring(TRAIN_PROFILE, 6.2), _ring(TRAIN_PROFILE, 7.4, 0.97, 0.94),
                 _ring(TRAIN_PROFILE, 8.3, 0.88, 0.8), _ring(TRAIN_PROFILE, 8.8, 0.74, 0.62)]
    else:
        rings = [_ring(TRAIN_PROFILE, -L), _ring(TRAIN_PROFILE, L)]
    p.append(loft_rings("body", rings, body))
    side_end = 6.0 if cab else L - 0.4
    for sx in (-1, 1):
        x = sx * 1.47
        # Window band with pillars, broken by two doors a side.
        p.append(box("band", (0.03, side_end + L - 0.8, 0.95), (x, (side_end - L + 0.4) / 2, 2.4), glass))
        for yy in [y * 0.5 for y in range(-16, int(side_end * 2) - 1, 4)]:
            p.append(box("pillar", (0.05, 0.16, 1.0), (x * 1.005, yy, 2.4), body))
        for dy in (-4.4, 3.6):
            p.append(box("door", (0.05, 1.5, 2.0), (x * 1.008, dy, 2.0), door))
            p.append(box("doorwin", (0.06, 0.5, 0.8), (x * 1.01, dy - 0.36, 2.45), glass))
            p.append(box("doorwin", (0.06, 0.5, 0.8), (x * 1.01, dy + 0.36, 2.45), glass))
        p.append(box("stripe", (0.04, side_end + L - 0.8, 0.22), (x * 1.0, (side_end - L + 0.4) / 2, 1.62), stripe))
        p.append(box("skirt", (0.05, 2 * L - 1.0, 0.18), (sx * 1.42, 0, 1.06), dark))
    # Underframe, equipment boxes, bogies with wheels.
    p.append(box("frame", (2.5, 2 * L - 1.2, 0.5), (0, 0, 0.72), dark))
    for by in (-6.2, 6.2):
        p.append(box("bogie", (2.3, 2.8, 0.45), (0, by, 0.48), dark, bevel=0.05))
        for wy in (-0.9, 0.9):
            for wx in (-0.75, 0.75):
                w = cyl("wheel", 0.42, 0.14, (0, 0, 0), dark, 12)
                w.rotation_euler = (0, math.pi / 2, 0)
                w.location = (wx - 0.07, by + wy, 0.42)
                p.append(w)
    for ey in (-2.0, 1.4):
        p.append(box("equip", (1.6, 1.8, 0.4), (0, ey, 0.35), dark))
    # Roof: air-con pods and a walkway strip.
    for ry in (-4.0, 3.0):
        p.append(box("ac", (1.7, 2.6, 0.32), (0, ry, 3.95), roof, bevel=0.08))
    p.append(box("roofstrip", (0.5, 2 * L - 2.5, 0.06), (0, -0.4 if cab else 0, 3.92), roof))
    # Gangway ends.
    for gy in ([-L] if cab else [-L, L]):
        p.append(box("gangway", (1.3, 0.3, 2.5), (0, gy + (0.15 if gy < 0 else -0.15), 2.2), dark))
    if cab:
        # Raked windscreen, headlights, a crimson nose band and a coupler.
        ws = box("windscreen", (2.3, 0.06, 1.05), (0, 8.15, 2.95), glass)
        ws.rotation_euler = (math.radians(-38), 0, 0)
        p.append(ws)
        p.append(box("nose_band", (2.15, 0.08, 0.32), (0, 8.72, 1.62), stripe))
        for lx in (-0.75, 0.75):
            p.append(box("headlight", (0.42, 0.06, 0.18), (lx, 8.78, 1.3), lamp))
        p.append(box("coupler", (0.3, 0.6, 0.25), (0, 8.95, 0.85), dark))
        for wx in (-1.0, 1.0):  # side cab windows
            p.append(box("cabwin", (0.04, 0.9, 0.7), (wx * 1.4, 7.0, 2.6), glass))
    export("train_cab.glb" if cab else "train_car.glb", [join("train_cab" if cab else "train_car", p)])


def cooling_tower():
    """Rooftop cooling tower / chiller: louvred box, fan shrouds, pipework.
    3.6 x 2.4 x 2.6 m, origin at the base centre."""
    reset()
    body = mat("hvac", (0.72, 0.73, 0.72), 0.5, 0.2)
    louvre = mat("hvac_louvre", (0.42, 0.44, 0.45), 0.6, 0.3)
    dark = mat("steel_dark", (0.12, 0.12, 0.13), 0.5, 0.5)
    pipe = mat("pipe", (0.55, 0.5, 0.42), 0.5, 0.6)
    p = [box("frame", (3.6, 2.4, 0.3), (0, 0, 0.15), dark)]
    p.append(box("body", (3.5, 2.3, 1.9), (0, 0, 1.25), body, bevel=0.04))
    for sx in (-1, 1):  # louvre panels on the long sides
        for i in range(7):
            p.append(box("louvre", (3.2, 0.05, 0.08), (0, sx * 1.17, 0.55 + i * 0.22), louvre))
    for x in (-0.85, 0.85):
        p.append(cyl("shroud", 0.72, 0.42, (x, 0, 2.2), body, 20))
        p.append(cyl("fan", 0.66, 0.05, (x, 0, 2.55), dark, 20))
        p.append(box("hub", (0.18, 0.18, 0.12), (x, 0, 2.6), dark))
    for z in (0.5, 0.9):  # pipes out of one end, down to the roof
        p.append(box("pipe", (0.6, 0.16, 0.16), (2.05, 0.6, z), pipe))
        p.append(box("pipe", (0.16, 0.16, z), (2.3, 0.6, z / 2), pipe))
    export("cooling_tower.glb", [join("cooling_tower", p)])


def crane():
    reset()
    paint = mat("crane_paint", (0.86, 0.6, 0.16), 0.6, 0.3)
    dark = mat("steel_dark", (0.16, 0.16, 0.17), 0.5, 0.6)
    p = []
    for sx, sy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        p.append(box("leg", (0.8, 0.8, 22), (sx * 4, sy * 4, 11), paint))
    p.append(box("cab", (9, 9, 4), (0, 0, 24), paint))
    p.append(box("boom", (2.2, 46, 2.2), (0, 14, 27), paint))
    p.append(box("counter", (5, 6, 3), (0, -12, 26), dark))
    p.append(box("apex", (1.2, 1.2, 10), (0, 0, 31), paint))
    export("crane.glb", [join("crane", p)])


def roof_hut():
    """Stair/lift housing on a flat roof: 3.4 x 4.2 x 3 m, door on +Y."""
    reset()
    conc = mat("hut_concrete", (0.62, 0.6, 0.57), 0.9)
    trim = mat("hut_trim", (0.42, 0.42, 0.43), 0.7)
    door = mat("hut_door", (0.25, 0.3, 0.33), 0.5, 0.4)
    p = [box("hut", (3.4, 4.2, 3.0), (0, 0, 1.5), conc)]
    p.append(box("cap", (3.7, 4.5, 0.18), (0, 0, 3.09), trim))
    p.append(box("door", (1.0, 0.06, 2.1), (0.6, 2.12, 1.05), door))
    p.append(box("vent", (0.6, 0.6, 0.5), (-0.9, -1.2, 3.4), trim))
    export("roof_hut.glb", [join("roof_hut", p)])


def traffic_light():
    """Mast-arm signal: pole on the kerb, arm out over the road (+X), two heads."""
    reset()
    pole_m = mat("signal_pole", (0.18, 0.2, 0.2), 0.5, 0.6)
    head_m = mat("signal_head", (0.08, 0.08, 0.08), 0.6)
    red = mat("lamp_red", (0.9, 0.1, 0.05), 0.3, emit=(1.0, 0.12, 0.05))
    amber = mat("lamp_amber", (0.3, 0.22, 0.05), 0.3)
    green = mat("lamp_green", (0.05, 0.25, 0.1), 0.3)
    p = [cyl("pole", 0.13, 6.2, (0, 0, 0), pole_m, 10)]
    p.append(cyl("base", 0.22, 0.6, (0, 0, 0), pole_m, 10))
    arm = cyl("arm", 0.08, 5.2, (0, 0, 0), pole_m, 8)
    arm.rotation_euler = (0, math.radians(90), 0)
    arm.location = (0, 0, 5.9)
    p.append(arm)
    for x in (2.6, 4.9):
        p.append(box("head", (0.38, 0.32, 1.05), (x, 0, 5.3), head_m))
        p.append(box("visor", (0.42, 0.06, 1.1), (x, 0.17, 5.3), head_m))
        for i, m in enumerate((red, amber, green)):
            p.append(cyl("lamp", 0.11, 0.05, (x, -0.18, 5.62 - i * 0.32), m, 10))
    for o in p:
        if o.name.startswith("lamp"):
            o.rotation_euler = (math.radians(90), 0, 0)
    p.append(box("ped", (0.3, 0.3, 0.55), (0, -0.2, 2.6), head_m))
    export("traffic_light.glb", [join("traffic_light", p)])


# ------------------------------------------------------------- character
def loft(name, rings, segs=14, cap=True):
    """Lofted body part. rings: [(z, rx, ry, cy)] – ellipse half-widths in x/y,
    y-centre offset cy, at height z (Blender Z up, +Y = character front)."""
    bm = bmesh.new()
    loops = []
    for (z, rx, ry, *rest) in rings:
        cy = rest[0] if rest else 0.0
        ring = []
        for i in range(segs):
            a = i / segs * math.tau
            ring.append(bm.verts.new((math.cos(a) * rx, cy + math.sin(a) * ry, z)))
        loops.append(ring)
    for r0, r1 in zip(loops, loops[1:]):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((r0[i], r0[j], r1[j], r1[i]))
    if cap:
        for ring, flip in ((loops[0], True), (loops[-1], False)):
            c = sum((v.co for v in ring), Vector()) / len(ring)
            cv = bm.verts.new(c)
            for i in range(segs):
                j = (i + 1) % segs
                bm.faces.new((ring[j], ring[i], cv) if flip else (ring[i], ring[j], cv))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = new_obj(name, bm)
    return ob


def paint(ob, material):
    ob.data.materials.clear()
    ob.data.materials.append(material)
    return ob


def bake_vertex_colors(ob):
    """One surface per part: material colours become vertex colours (alpha 0 =
    emissive), and all faces use a single material. Godot draws each part in
    one call with a shared vertex-colour material."""
    me = ob.data
    cols = []
    for m in me.materials:
        bsdf = m.node_tree.nodes["Principled BSDF"]
        c = bsdf.inputs["Base Color"].default_value
        emissive = bsdf.inputs["Emission Strength"].default_value > 0.0 and \
            sum(bsdf.inputs["Emission Color"].default_value[:3]) > 0.0
        cols.append((c[0], c[1], c[2], 0.0 if emissive else 1.0))
    attr = me.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    for poly in me.polygons:
        col = cols[poly.material_index] if cols else (1, 1, 1, 1)
        for li in poly.loop_indices:
            attr.data[li].color = col
        poly.material_index = 0
    me.color_attributes.active_color = attr
    keep = me.materials[0] if me.materials else None
    me.materials.clear()
    body = _mats.get("character") or mat("character", (1, 1, 1), 0.7)
    me.materials.append(body)


def character():
    """One original stylised human (~1.82 m) – lofted anatomy, techwear outfit,
    grapple gear. One object per bone; origin at the joint; limbs extend toward
    -Z (Blender) = -Y (Godot). The Godot rig poses these pivots every frame."""
    reset()
    skin = mat("skin", (0.72, 0.5, 0.38), 0.6)
    lip = mat("lip", (0.55, 0.32, 0.27), 0.6)
    hair = mat("hair", (0.09, 0.06, 0.05), 0.8)
    brow = mat("brow", (0.08, 0.05, 0.04), 0.8)
    jacket = mat("jacket", (0.8, 0.1, 0.09), 0.7)
    jacket_dk = mat("jacket_dark", (0.42, 0.05, 0.05), 0.75)
    yoke = mat("yoke", (0.14, 0.15, 0.17), 0.7)
    tee = mat("tee", (0.16, 0.16, 0.18), 0.6)  # zip line
    pants = mat("pants", (0.12, 0.14, 0.2), 0.85)
    pad = mat("kneepad", (0.2, 0.21, 0.24), 0.6)
    strap = mat("strap", (0.06, 0.06, 0.07), 0.6)
    metal = mat("metal", (0.55, 0.57, 0.6), 0.35, 0.8)
    shoe = mat("sneaker", (0.93, 0.93, 0.9), 0.6)
    sole = mat("sole", (0.8, 0.12, 0.1), 0.6)
    glove = mat("glove", (0.1, 0.1, 0.11), 0.7)
    gear = mat("gear", (0.18, 0.2, 0.22), 0.4, 0.7)
    glow = mat("gear_glow", (0.2, 0.95, 0.95), 0.3, 0.0, emit=(0.1, 0.9, 0.95))
    lens = mat("lens", (0.2, 0.9, 0.95), 0.1, 0.0, emit=(0.05, 0.6, 0.7))
    scarf = mat("scarf", (0.95, 0.75, 0.2), 0.8)
    parts = []

    def part(name, objs):
        ob = join(name, objs)
        bake_vertex_colors(ob)
        parts.append(ob)

    # ---- torso ---------------------------------------------------------
    pelvis = paint(smooth(loft("pelvis", [(-0.13, 0.12, 0.09), (-0.07, 0.165, 0.11), (0.02, 0.165, 0.11),
                                           (0.1, 0.145, 0.1)])), pants)
    belt = paint(loft("belt", [(0.04, 0.17, 0.115), (0.09, 0.165, 0.112)], segs=16), strap)
    buckle = box("buckle", (0.06, 0.02, 0.045), (0, 0.115, 0.065), metal, bevel=0.005)
    pocket = box("pocket", (0.07, 0.03, 0.08), (0.14, 0.03, -0.05), pants, bevel=0.01)
    part("hips", [pelvis, belt, buckle, pocket])

    abdomen = paint(smooth(loft("abdomen", [(-0.03, 0.15, 0.105), (0.08, 0.152, 0.105), (0.18, 0.168, 0.115),
                                             (0.25, 0.178, 0.12)])), jacket)
    tee_gap = paint(loft("tee", [(-0.02, 0.012, 0.012, 0.104), (0.24, 0.012, 0.012, 0.118)], segs=6), tee)
    hem = paint(loft("hem", [(-0.035, 0.157, 0.112), (0.0, 0.157, 0.112)], segs=16), jacket_dk)
    part("spine", [abdomen, tee_gap, hem])

    chest = paint(smooth(loft("chest", [(-0.05, 0.172, 0.12), (0.05, 0.185, 0.13, 0.01), (0.15, 0.2, 0.125, 0.005),
                                         (0.21, 0.195, 0.11), (0.26, 0.13, 0.085), (0.28, 0.07, 0.06)])), jacket)
    yokes = []
    for sx in (-1, 1):
        y = paint(smooth(loft("yoke", [(0.15, 0.07, 0.115, 0.0), (0.24, 0.06, 0.1)], segs=10)), yoke)
        y.location = (sx * 0.12, 0, 0)
        yokes.append(y)
        delt = sphere("deltoid", 0.072, (sx * 0.2, 0.0, 0.19), yoke, 12, 8, (1.0, 1.0, 0.95))
        yokes.append(smooth(delt))
    collar = paint(smooth(loft("collar", [(0.24, 0.085, 0.075, -0.005), (0.32, 0.075, 0.07, -0.01)], segs=14, cap=False)),
                   jacket_dk)
    straps = []
    for sx in (-1, 1):  # crossed harness straps over the chest
        st = box("strap", (0.032, 0.012, 0.36), (0, 0.128, 0.09), strap)
        st.rotation_euler = (0, sx * 0.62, 0)
        straps.append(st)
    straps.append(cyl("clip", 0.03, 0.02, (0, 0.13, 0.08), metal, 12))
    straps[-1].rotation_euler = (math.pi / 2, 0, 0)
    straps[-1].location = (0, 0.128, 0.09)
    # Back-mounted twin-drum spool with glowing rings.
    housing = box("housing", (0.24, 0.09, 0.22), (0, -0.165, 0.11), gear, bevel=0.02)
    drums = []
    for sx in (-1, 1):
        d = cyl("drum", 0.065, 0.06, (0, 0, 0), gear, 18)
        d.rotation_euler = (0, math.pi / 2, 0)
        d.location = (sx * 0.15, -0.17, 0.13)
        drums.append(d)
        r = cyl("ring", 0.068, 0.012, (0, 0, 0), glow, 18)
        r.rotation_euler = (0, math.pi / 2, 0)
        r.location = (sx * 0.183, -0.17, 0.13)
        drums.append(r)
    part("chest", [chest, *yokes, collar, *straps, housing, *drums])

    neck = paint(smooth(loft("neck_m", [(-0.02, 0.05, 0.05), (0.1, 0.045, 0.047)])), skin)
    scarf_wrap = paint(smooth(loft("scarf_wrap", [(0.0, 0.08, 0.075, -0.01), (0.06, 0.07, 0.068, -0.005)],
                                   segs=14, cap=False)), scarf)
    part("neck", [neck, scarf_wrap])

    # ---- head ------------------------------------------------------------
    skull = smooth(sphere("skull", 0.1, (0, -0.005, 0.12), skin, 18, 12, (0.88, 1.0, 1.08)))
    jaw = smooth(paint(loft("jaw", [(0.02, 0.06, 0.06, 0.02), (0.07, 0.075, 0.075, 0.02), (0.11, 0.08, 0.08, 0.01)]), skin))
    nose = sphere("nose", 0.02, (0, 0.098, 0.105), skin, 8, 6, (0.75, 1.0, 1.35))
    lips = box("lips", (0.04, 0.012, 0.012), (0, 0.083, 0.06), lip, bevel=0.005)
    brows = [box("brow", (0.035, 0.012, 0.01), (sx * 0.035, 0.09, 0.145), brow, bevel=0.003) for sx in (-1, 1)]
    ears = [sphere("ear", 0.026, (sx * 0.088, -0.005, 0.11), skin, 8, 6, (0.45, 0.9, 1.3)) for sx in (-1, 1)]
    hair_parts = [smooth(sphere("hair_cap", 0.106, (0, -0.02, 0.15), hair, 16, 10, (0.92, 1.0, 0.95)))]
    for v in hair_parts[0].data.vertices:  # hairline: keep the cap off the face
        if v.co.y > 0.035 and v.co.z < 0.03:
            v.co.y = 0.035 - (v.co.y - 0.035) * 0.2
    for (x, y, z, r) in ((0.0, 0.055, 0.22, 0.05), (0.04, 0.03, 0.235, 0.045), (-0.04, 0.02, 0.23, 0.045),
                         (0.02, -0.03, 0.235, 0.05), (-0.03, -0.06, 0.21, 0.05)):
        hair_parts.append(smooth(sphere("tuft", r, (x, y, z), hair, 10, 7, (1.0, 1.25, 0.6))))
    band = paint(loft("goggle_band", [(0.17, 0.104, 0.112, -0.012), (0.19, 0.104, 0.112, -0.012)], segs=18, cap=False), strap)
    goggles = [band]
    for sx in (-1, 1):
        g = cyl("goggle", 0.026, 0.022, (0, 0, 0), gear, 14)
        g.rotation_euler = (math.pi / 2 - 0.35, 0, 0)
        g.location = (sx * 0.038, 0.088, 0.185)
        l = cyl("lens", 0.02, 0.006, (0, 0, 0), lens, 14)
        l.rotation_euler = (math.pi / 2 - 0.35, 0, 0)
        l.location = (sx * 0.038, 0.1, 0.19)
        goggles += [g, l]
    part("head", [skull, jaw, nose, lips, *brows, *ears, *hair_parts, *goggles])

    # ---- arms ------------------------------------------------------------
    for side, sx in (("l", -1), ("r", 1)):
        ua = paint(smooth(loft("ua", [(0.02, 0.062, 0.062), (-0.09, 0.066, 0.064), (-0.21, 0.052, 0.05),
                                       (-0.29, 0.046, 0.046)])), jacket)
        stripe = box("stripe", (0.012, 0.014, 0.26), (sx * 0.06, 0.0, -0.13), jacket_dk)
        elbow = sphere("elbow", 0.047, (0, -0.005, -0.29), jacket, 10, 8)
        part(f"upper_arm_{side}", [ua, stripe, elbow])
        fa = paint(smooth(loft("fa", [(0.0, 0.047, 0.047), (-0.07, 0.052, 0.05), (-0.2, 0.04, 0.038),
                                       (-0.26, 0.036, 0.034)])), jacket)
        cuff = paint(loft("cuff", [(-0.2, 0.043, 0.041), (-0.26, 0.04, 0.038)], segs=12), jacket_dk)
        extra = []
        if side == "r":  # launcher gauntlet on the web hand
            extra.append(box("gauntlet", (0.09, 0.115, 0.15), (0, 0.02, -0.15), gear, bevel=0.015))
            extra.append(box("nozzle", (0.03, 0.05, 0.04), (0, 0.075, -0.22), metal, bevel=0.006))
            extra.append(box("led", (0.06, 0.006, 0.012), (0, 0.078, -0.12), glow))
        part(f"forearm_{side}", [fa, cuff, *extra])
        # Open, relaxed hand.
        palm = box("palm", (0.075, 0.03, 0.08), (0, 0.0, -0.045), glove, bevel=0.012)
        fingers = []
        for i in range(4):
            x = (i - 1.5) * 0.019
            f = cyl("finger", 0.0085, 0.065 - abs(i - 1.5) * 0.008, (0, 0, 0), skin, 6)
            f.location = (x, 0.004, -0.085 - (0.065 - abs(i - 1.5) * 0.008))
            f.rotation_euler = (-0.25, 0, 0)
            fingers.append(f)
        th = cyl("thumb", 0.01, 0.05, (0, 0, 0), skin, 6)
        th.location = (sx * -0.04, 0.02, -0.06)
        th.rotation_euler = (0.4, sx * 0.9, 0)
        part(f"hand_{side}", [palm, *fingers, th])
        # Gripping fist (shown while holding the web / on the stick).
        fist = box("fist", (0.08, 0.06, 0.085), (0, 0.012, -0.05), glove, bevel=0.022, segs=3)
        knuckles = box("knuckles", (0.078, 0.02, 0.03), (0, 0.04, -0.085), skin, bevel=0.008)
        thumb_g = box("thumb_g", (0.022, 0.03, 0.045), (sx * -0.035, 0.035, -0.06), skin, bevel=0.009)
        part(f"hand_{side}_grip", [fist, knuckles, thumb_g])

    # ---- legs --------------------------------------------------------------
    for side, sx in (("l", -1), ("r", 1)):
        th = paint(smooth(loft("th", [(0.03, 0.086, 0.09), (-0.1, 0.092, 0.094), (-0.3, 0.072, 0.074),
                                       (-0.45, 0.058, 0.06)])), pants)
        cargo = box("cargo", (0.03, 0.08, 0.1), (sx * 0.09, 0.0, -0.2), pants, bevel=0.012)
        kp = smooth(sphere("kneepad", 0.06, (0, 0.035, -0.45), pad, 12, 8, (1.0, 0.7, 1.15)))
        part(f"thigh_{side}", [th, cargo, kp])
        sh = paint(smooth(loft("sh", [(0.0, 0.058, 0.06), (-0.1, 0.062, 0.068, -0.012), (-0.3, 0.046, 0.048),
                                       (-0.4, 0.04, 0.042)])), pants)
        cuffl = paint(loft("cuffl", [(-0.36, 0.05, 0.052), (-0.42, 0.048, 0.05)], segs=12), strap)
        part(f"shin_{side}", [sh, cuffl])
        collar_s = paint(smooth(loft("hightop", [(0.02, 0.055, 0.06, 0.0), (-0.06, 0.06, 0.07, 0.01)], segs=12)), shoe)
        body = box("shoe", (0.11, 0.27, 0.085), (0, 0.065, -0.07), shoe, bevel=0.035, segs=3)
        toe = box("toecap", (0.105, 0.06, 0.05), (0, 0.17, -0.085), sole, bevel=0.02)
        so = box("sole", (0.118, 0.285, 0.03), (0, 0.065, -0.115), sole, bevel=0.01)
        lace = box("laces", (0.05, 0.12, 0.012), (0, 0.09, -0.025), strap)
        part(f"foot_{side}", [collar_s, body, toe, so, lace])

    # ---- scarf tail (3 segments, simulated as a spring chain in Godot) ------
    for i in range(3):
        w = 0.085 - i * 0.012
        seg = box(f"scarf_{i}", (w, 0.016, 0.17), (0, 0, -0.085), scarf, bevel=0.006)
        part(f"scarf_{i}", [seg])
    export("character.glb", parts)


if __name__ == "__main__":
    # Cars: tools/blender/build_cars.py; trees, pedestrians, street furniture:
    # tools/blender/build_street.py
    for fn in (water_tower, ac_unit, antenna, streetlight, clock_crown, harbour_dome, beacon,
               cathedral_tower_top, viaduct, crane, traffic_light, roof_hut,
               lambda: train_car(False), lambda: train_car(True), cooling_tower):
        fn()
    print("KIT DONE")
