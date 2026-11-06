"""City Swing traffic: five car bodies built from side profiles.

Run:  blender -b --factory-startup --python tools/blender/build_cars.py -- assets/models [preview.png]

Each body is a side profile (length along +Y = Godot's forward -Z, height Z)
extruded across the width and bevelled, with a glass cabin, roof, wheels
with hubs, bumpers, lamps and mirrors. Material names drive the Godot
traffic shader: "paint" takes the per-car colour, "lamp*" emit.
Optional second argument: render a lineup of all five (Workbench) for review.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(__file__))
import build_kit as kit  # noqa: E402  (helpers only; its __main__ doesn't run)
from build_kit import box, cyl, join, mat  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "assets/models"
PREVIEW = ARGS[1] if len(ARGS) > 1 else ""
kit.OUT = OUT


def mats():
    return {
        "paint": mat("paint", (1.0, 1.0, 1.0), 0.3, 0.3),
        "glass": mat("car_glass", (0.07, 0.09, 0.12), 0.08, 0.2),
        "trim": mat("trim", (0.06, 0.06, 0.065), 0.7),
        "tyre": mat("tyre", (0.035, 0.035, 0.035), 0.9),
        "hub": mat("hub", (0.62, 0.63, 0.66), 0.35, 0.8),
        "lamp": mat("lamp", (1.0, 0.94, 0.8), 0.3, 0.0, emit=(1.0, 0.88, 0.65)),
        "lamp_red": mat("lamp_red", (0.85, 0.08, 0.05), 0.4, 0.0, emit=(1.0, 0.08, 0.04)),
        "sign": mat("lamp_sign", (1.0, 0.9, 0.55), 0.4, 0.0, emit=(1.0, 0.85, 0.4)),
        "plate": mat("plate", (0.92, 0.9, 0.82), 0.6),
    }


def profile(name, pts, width, material, bevel=0.06, x0=0.0):
    """Extrude a closed side profile [(y, z), ...] across `width` (centred on x0)."""
    bm = bmesh.new()
    left = [bm.verts.new((x0 - width / 2, y, z)) for y, z in pts]
    face = bm.faces.new(left)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    moved = [e for e in ext["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=Vector((width, 0, 0)), verts=moved)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = kit.new_obj(name, bm, material)
    if bevel > 0:
        mod = ob.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
        mod.limit_method = "ANGLE"
    return ob


def wheels(m, track, base, r, w=0.24, z=None):
    z = r if z is None else z
    out = []
    for sx in (-1, 1):
        for y in base:
            t = cyl("tyre", r, w, (0, 0, 0), m["tyre"], 14)
            t.rotation_euler = (0, math.pi / 2, 0)
            t.location = (sx * (track / 2 - w / 2) - w / 2, y, z)
            h = cyl("hub", r * 0.55, 0.03, (0, 0, 0), m["hub"], 10)
            h.rotation_euler = (0, math.pi / 2, 0)
            h.location = (sx * (track / 2 + 0.005) - 0.015, y, z)
            out += [t, h]
    return out


def lamps(m, length, width, z_front, z_rear, wide=0.34):
    out = []
    for sx in (-1, 1):
        out.append(box("hl", (wide, 0.05, 0.11), (sx * (width / 2 - wide / 2 - 0.06), length / 2 + 0.01, z_front),
                       m["lamp"], bevel=0.02))
        out.append(box("tl", (wide, 0.05, 0.12), (sx * (width / 2 - wide / 2 - 0.06), -length / 2 - 0.01, z_rear),
                       m["lamp_red"], bevel=0.02))
    return out


def bumpers(m, length, width, z=0.42, h=0.2):
    return [box("bumper_f", (width + 0.04, 0.18, h), (0, length / 2 - 0.02, z), m["trim"], bevel=0.05),
            box("bumper_r", (width + 0.04, 0.18, h), (0, -length / 2 + 0.02, z), m["trim"], bevel=0.05),
            box("plate_r", (0.5, 0.02, 0.12), (0, -length / 2 - 0.08, z + 0.02), m["plate"])]


def mirrors(m, width, y, z):
    return [box("mirror", (0.16, 0.08, 0.1), (sx * (width / 2 + 0.06), y, z), m["paint"], bevel=0.02)
            for sx in (-1, 1)]


def sedan(taxi=False):
    kit.reset()
    m = mats()
    L, W = 4.5, 1.8
    body = [(-2.25, 0.3), (2.25, 0.3), (2.27, 0.6), (2.15, 0.82), (0.95, 0.96), (-1.45, 0.98), (-2.15, 0.93),
            (-2.27, 0.62)]
    cabin = [(0.98, 0.94), (0.1, 1.41), (-0.85, 1.42), (-1.5, 0.97)]
    parts = [profile("body", body, W, m["paint"], 0.08),
             profile("cabin", cabin, W - 0.18, m["glass"], 0.05),
             profile("roof", [(0.06, 1.38), (-0.82, 1.39), (-0.84, 1.45), (0.02, 1.45)], W - 0.24, m["paint"], 0.03),
             box("pillar_b", (W - 0.16, 0.12, 0.42), (0, -0.38, 1.18), m["paint"]),
             box("sill", (W + 0.02, 2.6, 0.1), (0, 0, 0.33), m["trim"])]
    parts += wheels(m, W, (1.42, -1.38), 0.33)
    parts += lamps(m, L, W, 0.74, 0.8)
    parts += bumpers(m, L, W)
    parts += mirrors(m, W, 0.85, 1.02)
    if taxi:
        parts.append(box("taxi_sign", (0.62, 0.26, 0.18), (0, -0.4, 1.55), m["sign"], bevel=0.04))
    kit.export("car_taxi.glb" if taxi else "car_sedan.glb", [join("car", parts)])


def hatch():
    kit.reset()
    m = mats()
    L, W = 3.95, 1.75
    body = [(-1.97, 0.3), (1.97, 0.3), (2.0, 0.6), (1.9, 0.82), (0.85, 0.96), (-1.85, 1.0), (-2.0, 0.66)]
    cabin = [(0.88, 0.94), (0.0, 1.43), (-1.45, 1.44), (-1.86, 0.99)]
    parts = [profile("body", body, W, m["paint"], 0.08),
             profile("cabin", cabin, W - 0.18, m["glass"], 0.05),
             profile("roof", [(-0.04, 1.4), (-1.42, 1.41), (-1.48, 1.47), (-0.08, 1.47)], W - 0.24, m["paint"], 0.03),
             box("pillar_b", (W - 0.16, 0.12, 0.44), (0, -0.55, 1.19), m["paint"]),
             box("pillar_c", (W - 0.16, 0.22, 0.4), (0, -1.6, 1.16), m["paint"]),
             box("sill", (W + 0.02, 2.3, 0.1), (0, 0, 0.33), m["trim"])]
    parts += wheels(m, W, (1.25, -1.25), 0.31)
    parts += lamps(m, L, W, 0.74, 0.86, 0.3)
    parts += bumpers(m, L, W)
    parts += mirrors(m, W, 0.75, 1.02)
    kit.export("car_hatch.glb", [join("car", parts)])


def suv():
    kit.reset()
    m = mats()
    L, W = 4.75, 1.95
    body = [(-2.37, 0.42), (2.37, 0.42), (2.4, 0.8), (2.3, 1.08), (1.05, 1.18), (-2.3, 1.2), (-2.4, 0.82)]
    cabin = [(1.08, 1.16), (0.3, 1.78), (-2.15, 1.8), (-2.3, 1.19)]
    parts = [profile("body", body, W, m["paint"], 0.09),
             profile("cabin", cabin, W - 0.16, m["glass"], 0.05),
             profile("roof", [(0.26, 1.75), (-2.12, 1.77), (-2.14, 1.84), (0.22, 1.83)], W - 0.2, m["paint"], 0.03),
             box("pillar_b", (W - 0.14, 0.14, 0.58), (0, -0.55, 1.48), m["paint"]),
             box("pillar_c", (W - 0.14, 0.14, 0.58), (0, -1.6, 1.48), m["paint"]),
             box("cladding", (W + 0.06, 3.0, 0.22), (0, 0, 0.5), m["trim"], bevel=0.04),
             box("rail_l", (0.05, 1.9, 0.06), (-(W / 2 - 0.22), -0.95, 1.87), m["trim"]),
             box("rail_r", (0.05, 1.9, 0.06), (W / 2 - 0.22, -0.95, 1.87), m["trim"])]
    parts += wheels(m, W, (1.5, -1.5), 0.4, 0.28)
    parts += lamps(m, L, W, 0.98, 1.02, 0.38)
    parts += bumpers(m, L, W, 0.55, 0.26)
    parts += mirrors(m, W, 0.95, 1.28)
    kit.export("car_suv.glb", [join("car", parts)])


def van():
    kit.reset()
    m = mats()
    L, W = 5.2, 2.0
    body = [(-2.6, 0.38), (2.6, 0.38), (2.62, 0.8), (2.5, 1.05), (1.9, 1.2), (1.35, 2.2), (-2.55, 2.25),
            (-2.62, 2.15)]
    parts = [profile("body", body, W, m["paint"], 0.1),
             profile("windscreen", [(1.93, 1.24), (1.42, 2.08), (1.2, 2.08), (1.3, 1.2)], W - 0.12, m["glass"], 0.04),
             box("side_win_l", (0.04, 0.9, 0.55), (-W / 2 - 0.005, 0.85, 1.65), m["glass"]),
             box("side_win_r", (0.04, 0.9, 0.55), (W / 2 + 0.005, 0.85, 1.65), m["glass"]),
             box("rear_win", (W - 0.5, 0.04, 0.5), (0, -2.63, 1.75), m["glass"]),
             box("door_line", (W + 0.012, 0.03, 1.5), (0, -0.4, 1.2), m["trim"]),
             box("sill", (W + 0.02, 3.6, 0.12), (0, 0, 0.42), m["trim"])]
    parts += wheels(m, W, (1.75, -1.75), 0.37, 0.26)
    parts += lamps(m, L, W, 0.95, 1.1, 0.3)
    parts += bumpers(m, L, W, 0.5, 0.24)
    parts += mirrors(m, W, 1.55, 1.5)
    kit.export("car_van.glb", [join("car", parts)])


def preview(path):
    """Lineup render for review: Workbench, material colours, paint tinted."""
    kit.reset()
    tints = [(0.62, 0.08, 0.07), (0.95, 0.75, 0.12), (0.12, 0.24, 0.45), (0.85, 0.85, 0.83), (0.2, 0.35, 0.3)]
    for i, f in enumerate(["car_sedan", "car_taxi", "car_hatch", "car_suv", "car_van"]):
        bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, f + ".glb"))
        ob = bpy.context.selected_objects[0]
        ob.rotation_mode = "XYZ"
        ob.location = (i * 3.6 - 7.2, 0, 0)
        ob.rotation_euler = (0, 0, math.radians(-125))
        for s in ob.material_slots:
            if s.material and s.material.name.startswith("paint"):
                c = s.material.copy()
                c.diffuse_color = (*tints[i], 1)
                s.material = c
            elif s.material:
                bsdf = s.material.node_tree.nodes.get("Principled BSDF") if s.material.node_tree else None
                if bsdf:
                    s.material.diffuse_color = bsdf.inputs["Base Color"].default_value
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.color_type = "MATERIAL"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.show_shadows = True
    sc.render.resolution_x, sc.render.resolution_y = 1600, 600
    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    cam.location = (0, -21, 6.5)
    cam.rotation_euler = (math.radians(75), 0, 0)
    sc.camera = cam
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.3, 0.32, 0.38)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    sedan()
    sedan(taxi=True)
    hatch()
    suv()
    van()
    if PREVIEW:
        preview(PREVIEW)
    print("CARS DONE")
