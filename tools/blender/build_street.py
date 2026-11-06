"""City Swing street life: pedestrians, trees and street furniture.

Run:  blender -b --factory-startup --python tools/blender/build_street.py -- assets/models [preview.png]

Same conventions as build_kit.py (Z-up / +Y forward in Blender = Y-up / -Z
forward in Godot, base-centre origins, stable material names):
  * pedestrian.glb – walker for the GPU walk cycle (pedestrian.gdshader):
    legs inside |x| < 0.2 below the hips (0.86 m), arms outside |x| > 0.2.
    Materials "skin", "shirt", "pants", "hair", "shoes" are recoloured per
    instance in the shader.
  * tree.glb / tree_tall.glb – broad street tree and a columnar one; the
    canopy's lower clumps use "leaves_dark" so it reads as a volume.
  * bench, bin, hydrant, bollard, sign_post, bus_shelter, planter – merged
    into one street-furniture mesh per chunk in Godot (vertex colours from
    the material colours), so a whole chunk's furniture is one draw call.
Optional second argument: render a lineup (Workbench) for review.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(__file__))
import build_kit as kit  # noqa: E402  (helpers only; its __main__ doesn't run)
from build_kit import box, cyl, export, join, mat, new_obj, reset, sphere  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "assets/models"
PREVIEW = ARGS[1] if len(ARGS) > 1 else ""
kit.OUT = OUT
os.makedirs(OUT, exist_ok=True)


def tapered(name, r0, r1, z0, z1, x, y, material, segs=8, sx=1.0, sy=1.0, cap=False):
    """Vertical tapered limb/torso piece from z0 (radius r0) to z1 (r1); open
    ends by default (they sit inside the next piece)."""
    ob = cyl(name, r0, z1 - z0, (x, y, z0), material, segs, r2=r1, cap=cap)
    ob.scale = (sx, sy, 1.0)
    return ob


# ------------------------------------------------------------ pedestrian
def pedestrian():
    reset()
    skin = mat("skin", (0.62, 0.45, 0.36), 0.7)
    shirt = mat("shirt", (1.0, 1.0, 1.0), 0.8)
    pants = mat("pants", (0.17, 0.19, 0.25), 0.85)
    hair = mat("hair", (0.12, 0.09, 0.07), 0.9)
    shoes = mat("shoes", (0.1, 0.1, 0.1), 0.6)
    p = []
    for sx in (-0.095, 0.095):
        # Thigh + shin taper; slight gap between the legs.
        p.append(tapered("thigh", 0.082, 0.07, 0.46, 0.9, sx, 0.0, pants, 5))
        p.append(tapered("shin", 0.066, 0.05, 0.08, 0.47, sx, 0.0, pants, 5))
        p.append(box("shoe", (0.11, 0.25, 0.085), (sx, 0.045, 0.045), shoes, bevel=0.025, segs=1))
    p.append(tapered("pelvis", 0.15, 0.16, 0.8, 0.95, 0, 0, pants, 8, sy=0.7, cap=True))
    # Torso: narrow waist widening to the shoulders, flattened front-to-back.
    p.append(tapered("waist", 0.15, 0.185, 0.94, 1.22, 0, 0, shirt, 8, sy=0.68))
    p.append(tapered("chest", 0.185, 0.17, 1.22, 1.44, 0, 0, shirt, 8, sy=0.68, cap=True))
    for sx in (-1, 1):
        p.append(box("shoulder", (0.12, 0.14, 0.1), (sx * 0.19, 0, 1.39), shirt))
        p.append(tapered("upper_arm", 0.052, 0.045, 1.13, 1.42, sx * 0.235, 0.0, shirt, 6))
        p.append(tapered("forearm", 0.043, 0.036, 0.9, 1.14, sx * 0.24, 0.01, skin if sx > 0 else shirt, 6))
        p.append(box("hand", (0.06, 0.08, 0.1), (sx * 0.24, 0.01, 0.85), skin))
    p.append(tapered("neck", 0.05, 0.045, 1.43, 1.54, 0, 0, skin, 6))
    p.append(sphere("head", 0.105, (0, 0.012, 1.64), skin, 7, 5, scale=(0.88, 1.0, 1.1)))
    p.append(sphere("hair", 0.112, (0, -0.012, 1.68), hair, 7, 3, scale=(0.94, 1.0, 0.82)))
    export("pedestrian.glb", [join("pedestrian", p)])


# ------------------------------------------------------------------ trees
def lumpy(name, r, loc, material, subdiv=2, wobble=0.16, squash=1.0, seed=0.0):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=r)
    for v in bm.verts:
        n = v.co.normalized()
        v.co += n * wobble * r * math.sin(v.co.x * 3.1 + v.co.y * 2.3 + v.co.z * 1.7 + seed)
        v.co.z *= squash
    bmesh.ops.translate(bm, vec=Vector(loc), verts=bm.verts)
    return new_obj(name, bm, material)


def branch(name, a, b, r0, r1, material):
    d = Vector(b) - Vector(a)
    ob = cyl(name, r0, d.length, (0, 0, 0), material, 5, r2=r1)
    ob.rotation_mode = "QUATERNION"
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    ob.location = a
    return ob


def tree():
    """Broad street tree (plane/lime): forked trunk, irregular open crown."""
    reset()
    bark = mat("bark", (0.29, 0.22, 0.17), 0.9)
    leaf = mat("leaves", (0.34, 0.5, 0.24), 0.85)
    dark = mat("leaves_dark", (0.22, 0.36, 0.18), 0.9)
    parts = [cyl("trunk", 0.2, 2.6, (0, 0, 0), bark, 7, r2=0.13)]
    parts.append(branch("b1", (0, 0, 2.4), (0.9, 0.3, 3.9), 0.11, 0.05, bark))
    parts.append(branch("b2", (0, 0, 2.5), (-0.7, -0.4, 4.1), 0.1, 0.05, bark))
    parts.append(branch("b3", (0, 0, 2.5), (0.1, 0.1, 4.6), 0.1, 0.05, bark))
    clumps = ((0.15, 0.1, 4.9, 1.5, leaf), (1.15, 0.35, 4.2, 1.2, leaf), (-0.95, -0.45, 4.35, 1.25, leaf),
              (0.1, 0.6, 3.7, 1.15, dark))
    for i, (x, y, z, r, m) in enumerate(clumps):
        parts.append(lumpy("c", r, (x, y, z), m, 2, 0.16, 0.85, i * 1.3))
    export("tree.glb", [join("tree", parts)])


def tree_tall():
    """Columnar tree (hornbeam/poplar): slim, taller crown of stacked clumps."""
    reset()
    bark = mat("bark", (0.3, 0.24, 0.19), 0.9)
    leaf = mat("leaves", (0.3, 0.47, 0.22), 0.85)
    dark = mat("leaves_dark", (0.2, 0.33, 0.16), 0.9)
    parts = [cyl("trunk", 0.17, 2.4, (0, 0, 0), bark, 7, r2=0.11)]
    for i, (x, y, z, r, m) in enumerate(((0.05, 0.05, 6.0, 0.85, leaf), (-0.1, -0.05, 4.8, 1.1, leaf),
                                          (0.05, 0.12, 3.6, 0.95, dark))):
        parts.append(lumpy("c", r, (x, y, z), m, 2, 0.14, 1.25, i * 2.1))
    export("tree_tall.glb", [join("tree_tall", parts)])


# ------------------------------------------------------ street furniture
def furniture_mats():
    return {
        "iron": mat("iron", (0.11, 0.13, 0.13), 0.5, 0.6),
        "wood": mat("wood", (0.47, 0.31, 0.18), 0.8),
        "steel": mat("steel", (0.55, 0.57, 0.58), 0.4, 0.7),
        "red": mat("hydrant_red", (0.72, 0.12, 0.08), 0.5),
        "green": mat("sign_green", (0.1, 0.33, 0.22), 0.5),
        "white": mat("sign_white", (0.92, 0.91, 0.86), 0.6),
        "glass": mat("shelter_glass", (0.55, 0.66, 0.7), 0.15),
        "stone": mat("planter_stone", (0.62, 0.6, 0.56), 0.9),
        "leaf": mat("leaves", (0.3, 0.46, 0.22), 0.85),
        "ad": mat("shelter_ad", (0.95, 0.75, 0.3), 0.5),
    }


def bench():
    """Park bench facing +Y (towards the road when placed), 1.8 m."""
    reset()
    m = furniture_mats()
    p = []
    for x in (-0.75, 0.75):
        p.append(box("leg", (0.06, 0.5, 0.42), (x, 0.0, 0.21), m["iron"]))
        p.append(box("arm", (0.06, 0.45, 0.05), (x, 0.0, 0.62), m["iron"]))
        p.append(box("back_leg", (0.05, 0.05, 0.5), (x, -0.24, 0.65), m["iron"]))
    for i in range(3):
        p.append(box("slat", (1.8, 0.11, 0.035), (0, -0.16 + i * 0.14, 0.44), m["wood"]))
    for i in range(2):
        p.append(box("back", (1.8, 0.03, 0.1), (0, -0.27, 0.62 + i * 0.16), m["wood"]))
    export("bench.glb", [join("bench", p)])


def bin_():
    reset()
    m = furniture_mats()
    p = [cyl("body", 0.24, 0.9, (0, 0, 0), m["green"], 10),
         cyl("lid", 0.26, 0.08, (0, 0, 0.9), m["iron"], 10),
         box("slot", (0.3, 0.02, 0.1), (0, 0.24, 0.74), m["iron"])]
    export("bin.glb", [join("bin", p)])


def hydrant():
    reset()
    m = furniture_mats()
    p = [cyl("base", 0.16, 0.08, (0, 0, 0), m["red"], 8),
         cyl("body", 0.12, 0.52, (0, 0, 0.08), m["red"], 8),
         sphere("cap", 0.13, (0, 0, 0.62), m["red"], 8, 4, scale=(1, 1, 0.7)),
         cyl("nozzle", 0.05, 0.3, (0, 0, 0), m["steel"], 6)]
    noz = p[-1]
    noz.rotation_euler = (0, math.radians(90), 0)
    noz.location = (-0.15, 0, 0.42)
    export("hydrant.glb", [join("hydrant", p)])


def bollard():
    reset()
    m = furniture_mats()
    p = [cyl("post", 0.09, 0.85, (0, 0, 0), m["iron"], 8, r2=0.075),
         sphere("top", 0.085, (0, 0, 0.86), m["iron"], 8, 4, scale=(1, 1, 0.6)),
         cyl("band", 0.095, 0.05, (0, 0, 0.7), m["white"], 8)]
    export("bollard.glb", [join("bollard", p)])


def sign_post():
    """Street-name sign on a post (two blades, crossed)."""
    reset()
    m = furniture_mats()
    p = [cyl("post", 0.04, 2.9, (0, 0, 0), m["iron"], 6)]
    p.append(box("blade", (0.9, 0.03, 0.2), (0.3, 0, 2.75), m["green"]))
    p.append(box("blade_face", (0.84, 0.035, 0.12), (0.3, 0, 2.75), m["white"]))
    b2 = box("blade2", (0.03, 0.9, 0.2), (0, 0.3, 2.5), m["green"])
    b3 = box("blade2_face", (0.035, 0.84, 0.12), (0, 0.3, 2.5), m["white"])
    export("sign_post.glb", [join("sign_post", p + [b2, b3])])


def bus_shelter():
    """3.6 m shelter, open side facing +Y (the road): roof, back glass, ad panel, bench."""
    reset()
    m = furniture_mats()
    p = [box("roof", (3.8, 1.5, 0.1), (0, -0.05, 2.45), m["iron"])]
    for x in (-1.75, 1.75):
        p.append(box("post", (0.08, 0.08, 2.4), (x, -0.62, 1.2), m["iron"]))
        p.append(box("post_f", (0.08, 0.08, 2.4), (x, 0.55, 1.2), m["iron"]))
    p.append(box("back_glass", (3.5, 0.03, 1.9), (0, -0.62, 1.25), m["glass"]))
    p.append(box("side_glass", (0.03, 1.1, 1.9), (-1.75, -0.05, 1.25), m["glass"]))
    p.append(box("ad", (0.06, 1.0, 1.6), (1.75, -0.05, 1.15), m["ad"]))
    p.append(box("seat", (1.8, 0.3, 0.05), (-0.5, -0.42, 0.5), m["steel"]))
    export("bus_shelter.glb", [join("bus_shelter", p)])


def planter():
    reset()
    m = furniture_mats()
    p = [box("tub", (1.2, 1.2, 0.55), (0, 0, 0.275), m["stone"], bevel=0.04, segs=1)]
    p.append(lumpy("shrub", 0.55, (0, 0, 0.85), m["leaf"], 1, 0.2, 0.7))
    export("planter.glb", [join("planter", p)])


def preview(path):
    """Workbench lineup of everything built here."""
    reset()
    files = ["pedestrian", "tree", "tree_tall", "bench", "bin", "hydrant", "bollard", "sign_post",
             "bus_shelter", "planter"]
    x = 0.0
    for f in files:
        bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, f + ".glb"))
        for o in bpy.context.selected_objects:
            o.location.x += x
        x += 4.5 if f in ("tree", "bus_shelter") else 2.4
    scn = bpy.context.scene
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scn.collection.objects.link(cam)
    cam.location = (x * 0.47, -30.0, 4.0)
    cam.rotation_euler = (math.radians(86), 0, 0)
    cam.data.lens = 28
    scn.camera = cam
    scn.render.engine = "BLENDER_WORKBENCH"
    scn.display.shading.color_type = "MATERIAL"
    scn.display.shading.light = "STUDIO"
    scn.render.resolution_x = 1600
    scn.render.resolution_y = 600
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    for fn in (pedestrian, tree, tree_tall, bench, bin_, hydrant, bollard, sign_post, bus_shelter, planter):
        fn()
    if PREVIEW:
        preview(PREVIEW)
    print("STREET DONE")
