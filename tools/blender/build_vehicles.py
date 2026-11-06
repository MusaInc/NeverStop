"""NEVER STOP vehicles: lofted, smoothed original car bodies + wheel styles.

Run:  blender -b --factory-startup --python tools/blender/build_vehicles.py -- assets/vehicles [preview.png]

Every body is built from code: a lower body lofted through superellipse
cross-sections (plan taper, hood/deck/beltline heights per station), a
glasshouse lofted the same way with tumblehome, a thin painted roof skin,
wheel arches cut with exact booleans (the cut faces take the black liner
material), lamps, grille, mirrors, and per-role kit (police light bar, push
bar, livery bands). Wheels are separate GLBs (tyre + rim style) so Godot
spins and steers them.

Conventions (as City Swing's kit): Blender +Y forward -> Godot -Z; origin on
the ground under the car's centre. Material names Godot keys off:
  paint, paint2 (livery), glass, trim, chrome, liner, lamp_head, lamp_tail,
  lamp_rev, beacon_red, beacon_blue, plate, grille, tyre, rim
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(__file__))
import build_kit as kit  # noqa: E402
from build_kit import box, cyl, mat  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "assets/vehicles"
PREVIEW = ARGS[1] if len(ARGS) > 1 else ""
kit.OUT = OUT
os.makedirs(OUT, exist_ok=True)


def mats():
    return {
        "paint": mat("paint", (0.8, 0.8, 0.8), 0.25, 0.4),
        "paint2": mat("paint2", (0.95, 0.95, 0.95), 0.3, 0.2),
        "glass": mat("glass", (0.05, 0.06, 0.08), 0.05, 0.3),
        "trim": mat("trim", (0.04, 0.04, 0.045), 0.6),
        "chrome": mat("chrome", (0.75, 0.76, 0.78), 0.15, 1.0),
        "liner": mat("liner", (0.02, 0.02, 0.02), 0.9),
        "grille": mat("grille", (0.03, 0.03, 0.035), 0.5, 0.3),
        "lamp_head": mat("lamp_head", (0.95, 0.95, 0.92), 0.1, 0.0, emit=(1.0, 0.95, 0.85)),
        "lamp_tail": mat("lamp_tail", (0.6, 0.03, 0.03), 0.2, 0.0, emit=(1.0, 0.05, 0.03)),
        "lamp_rev": mat("lamp_rev", (0.9, 0.9, 0.9), 0.2),
        "beacon_red": mat("beacon_red", (0.8, 0.05, 0.05), 0.2, 0.0, emit=(1.0, 0.05, 0.05)),
        "beacon_blue": mat("beacon_blue", (0.05, 0.15, 0.9), 0.2, 0.0, emit=(0.1, 0.3, 1.0)),
        "plate": mat("plate", (0.92, 0.9, 0.8), 0.6),
    }


def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


def interp(pts, x):
    """Piecewise-smooth interpolation through [(x, y), ...] (sorted by x)."""
    if x <= pts[0][0]:
        return pts[0][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x <= x1:
            t = (x - x0) / (x1 - x0)
            t = t * t * (3 - 2 * t)
            return y0 + (y1 - y0) * t
    return pts[-1][1]


def superellipse_ring(cx, cz, hw, hh, n, segs, tumble=0.0, flat_bottom=True):
    """Cross-section ring in the XZ plane, counter-clockwise from the bottom."""
    out = []
    for i in range(segs):
        a = -math.pi / 2 + i * 2 * math.pi / segs
        c, s = math.cos(a), math.sin(a)
        x = hw * math.copysign(abs(c) ** (2.0 / n), c)
        z = hh * math.copysign(abs(s) ** (2.0 / n), s)
        if z > 0:
            x *= 1.0 - tumble * (z / hh)
        if flat_bottom and z < -hh * 0.6:
            z = -hh * 0.6 - (hh * 0.4) * 0.15 * abs(s)
        out.append((cx + x, cz + z))
    return out


def loft(name, stations, material, segs=20, close=True):
    """stations: [(y, ring[(x, z), ...]), ...] -> a closed lofted solid."""
    bm = bmesh.new()
    rings = []
    for y, ring in stations:
        rings.append([bm.verts.new((x, y, z)) for x, z in ring])
    for r0, r1 in zip(rings, rings[1:]):
        n = len(r0)
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((r0[i], r0[j], r1[j], r1[i]))
    if close:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return kit.new_obj(name, bm, material)


def apply_mods(ob):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.convert(target="MESH")
    return ob


def shade_smooth(ob, angle=40):
    for p in ob.data.polygons:
        p.use_smooth = True
    try:
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.shade_auto_smooth(angle=math.radians(angle))
    except Exception:
        pass


def paint_faces(ob, material, pred):
    """Assigns `material` to every face whose (centre, normal) passes pred."""
    names = [m.name if m else "" for m in ob.data.materials]
    if material.name not in names:
        ob.data.materials.append(material)
        names.append(material.name)
    idx = names.index(material.name)
    for p in ob.data.polygons:
        if pred(Vector(p.center), Vector(p.normal)):
            p.material_index = idx


def cut(ob, cutter, cutter_mat=None):
    if cutter_mat is not None:
        cutter.data.materials.clear()
        cutter.data.materials.append(cutter_mat)
        if cutter_mat.name not in [m.name for m in ob.data.materials if m]:
            ob.data.materials.append(cutter_mat)
    mod = ob.modifiers.new("cut", "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.solver = "EXACT"
    mod.object = cutter
    try:
        mod.material_mode = "TRANSFER"
    except Exception:
        pass
    apply_mods(ob)
    bpy.data.objects.remove(cutter, do_unlink=True)


def axle_cyl(name, r, w, x, y, z, segs=28):
    c = cyl(name, r, w, (0, 0, 0), None, segs)
    c.rotation_euler = (0, math.pi / 2, 0)
    c.location = (x - w / 2, y, z)
    apply_mods(c)
    bpy.context.view_layer.objects.active = c
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return c


# ---------------------------------------------------------------- body


def car_body(P, m):
    """Builds one body from a parameter dict P (metres). Returns object list."""
    L, W = P["L"], P["W"]
    hl, hw = L / 2, W / 2
    ride = P["ride"]
    wr = P["wheel_r"]
    wb = P["wb"]
    n_st = 34
    parts = []
    # --- lower body: plan taper and section heights along the length ---
    top = P["top"]          # [(y, z_top)] hood / belt / deck heights, front=+hl
    plan = P.get("plan", [(-hl, 0.86), (-hl + 0.35, 0.985), (hl - 0.55, 1.0), (hl - 0.15, 0.92), (hl, 0.8)])
    bottom = P.get("bottom", [(-hl, ride + 0.18), (-hl + 0.5, ride), (hl - 0.6, ride), (hl, ride + 0.16)])
    st = []
    for i in range(n_st):
        t = i / (n_st - 1)
        y = -hl + t * L
        zt = interp(top, y)
        zb = interp(bottom, y)
        w = hw * interp(plan, y)
        end = min(t, 1 - t)
        shrink = smoothstep(0.0, 0.03, end)
        hh = (zt - zb) / 2 * (0.55 + 0.45 * shrink)
        ww = w * (0.75 + 0.25 * shrink)
        cz = (zt + zb) / 2
        st.append((y, superellipse_ring(0, cz, ww, hh, P.get("n", 3.4), 20, tumble=P.get("body_tumble", 0.08))))
    body = loft("body", st, m["paint"])
    sub = body.modifiers.new("sub", "SUBSURF")
    sub.levels = 1
    apply_mods(body)
    # Wheel arches.
    for y in (wb / 2 + P.get("wb_off", 0.0), -wb / 2 + P.get("wb_off", 0.0)):
        # One well per side: from just inside the tyre's inner face outward,
        # so the bonnet between the wheels stays whole.
        for sx in (-1, 1):
            depth = 0.42
            c = axle_cyl("arch", wr + 0.07, depth + 0.3, sx * (hw - depth / 2 + 0.15), y, wr, 32)
            cut(body, c, m["liner"])
        # inner tub so the arch doesn't show the hollow body
    shade_smooth(body, 35)
    parts.append(body)

    # --- glasshouse: from the windscreen base to the rear window base ---
    g = P["glass"]  # dict: y_front, y_rear, belt_f, belt_r, roof, roof_f, roof_r, w_top
    gst = []
    n_g = 18
    for i in range(n_g):
        t = i / (n_g - 1)
        y = g["y_rear"] + t * (g["y_front"] - g["y_rear"])
        belt = g["belt_r"] + (g["belt_f"] - g["belt_r"]) * t
        roof_curve = [(g["y_rear"], belt + 0.02), (g["roof_r"], g["roof"]), (g["roof_f"], g["roof"]),
                      (g["y_front"], belt + 0.02)]
        rz = interp(roof_curve, y)
        hw_b = hw * interp(plan, y) * 0.93
        hh = max(0.02, (rz - belt) / 2)
        gst.append((y, superellipse_ring(0, belt + hh - 0.03, hw_b, hh + 0.03, 2.6, 18,
                                         tumble=g.get("tumble", 0.22), flat_bottom=False)))
    glass = loft("glass", gst, m["glass"])
    s2 = glass.modifiers.new("sub", "SUBSURF")
    s2.levels = 1
    apply_mods(glass)
    shade_smooth(glass, 50)
    parts.append(glass)
    # Roof and pillars are the glasshouse's own faces, painted: they follow
    # its curvature exactly (no floating panels).
    roof_z = g["roof"]
    yf, yr = g["roof_f"], g["roof_r"]
    pillars = g.get("pillars", [])

    def is_roof(c, n):
        return n.z > 0.55 and c.z > roof_z - 0.12 and yr - 0.05 < c.y < yf + 0.05

    def is_pillar(c, n):
        if abs(n.x) < 0.35:
            return False
        if any(abs(c.y - py) < 0.055 for py in pillars):
            return True
        # A-pillar: the front edge of the side glass, C-pillar the rear.
        return c.y > g["y_front"] - 0.16 or c.y < g["y_rear"] + 0.14

    paint_faces(glass, m["paint"], lambda c, n: is_roof(c, n) or is_pillar(c, n))

    # --- front / rear details, painted onto the body's own faces ---
    zf = interp(top, hl - 0.12)
    zr = interp(top, -hl + 0.12)
    lamp_w = P.get("lamp_w", 0.36)
    lh = P.get("lamp_h", 0.09)
    th = P.get("tail_h", 0.1)
    gw = W * P.get("grille_w", 0.48) / 2
    gh = P.get("grille_h", 0.16)
    gz = (zf + ride) * 0.5 + P.get("grille_z", 0.0)
    x_out = hw * 0.93

    def head(c, n):
        return n.y > 0.25 and c.y > hl - 0.45 and zf - 0.07 - lh < c.z < zf - 0.05 and x_out - lamp_w < abs(c.x) < x_out

    def tail(c, n):
        if not (n.y < -0.3 and c.y < -hl + 0.35 and zr - 0.08 - th < c.z < zr - 0.06):
            return False
        return P.get("tail_bar", False) or x_out - lamp_w * 1.1 < abs(c.x) < x_out

    def grille(c, n):
        return n.y > 0.5 and c.y > hl - 0.3 and abs(c.x) < gw and gz - gh / 2 < c.z < gz + gh / 2

    def intake(c, n):
        return n.y > 0.4 and c.y > hl - 0.3 and abs(c.x) < hw * 0.8 and ride + 0.04 < c.z < ride + 0.14

    paint_faces(body, m["lamp_head"], head)
    paint_faces(body, m["lamp_tail"], tail)
    paint_faces(body, m["grille"], grille)
    paint_faces(body, m["trim"], intake)
    for sx in (-1, 1):
        my = g["y_front"] - 0.22
        mz = g["belt_f"] + 0.07
        mx = sx * (hw * interp(plan, my) * 0.9 + 0.06)
        parts.append(box("mirror", (0.15, 0.1, 0.09), (mx, my, mz), m["paint"], bevel=0.03))
        parts.append(box("mirror_arm", (0.12, 0.05, 0.03), (mx - sx * 0.08, my + 0.01, mz - 0.03), m["trim"]))
    parts.append(box("plate_r", (0.48, 0.03, 0.11), (0, -hl + 0.02, ride + 0.32), m["plate"]))
    parts.append(box("splitter", (W * 0.66, 0.3, 0.05), (0, hl - 0.4, ride + 0.03), m["trim"], bevel=0.02))
    parts.append(box("diffuser", (W * 0.6, 0.25, 0.08), (0, -hl + 0.4, ride + 0.05), m["trim"], bevel=0.02))
    if P.get("spoiler"):
        sp = P["spoiler"]  # (height above deck, width frac)
        parts.append(box("wing", (W * sp[1], 0.32, 0.04), (0, -hl + 0.32, zr + sp[0]), m["trim"], bevel=0.015))
        for sx in (-1, 1):
            parts.append(box("wing_post", (0.04, 0.14, sp[0]), (sx * W * sp[1] * 0.35, -hl + 0.34, zr + sp[0] / 2), m["trim"]))
    if P.get("scoop"):
        parts.append(box("scoop", (0.6, 0.9, 0.08), (0, hl * 0.45, interp(top, hl * 0.45) + 0.02), m["trim"], bevel=0.03))
    return parts


def police_kit(P, m, heavy=False):
    W = P["W"]
    g = P["glass"]
    parts = []
    y = (g["roof_r"] + g["roof_f"]) / 2
    z = g["roof"] + 0.04
    bar_w = W * 0.62
    parts.append(box("lightbar_base", (bar_w, 0.24, 0.05), (0, y, z), m["trim"], bevel=0.015))
    seg = bar_w / 6
    for i in range(6):
        mt = m["beacon_red"] if i < 3 else m["beacon_blue"]
        parts.append(box("beacon", (seg * 0.92, 0.2, 0.08), (-bar_w / 2 + seg * (i + 0.5), y, z + 0.06), mt, bevel=0.02))
    # Grille strobes.
    hl = P["L"] / 2
    zf = interp(P["top"], hl - 0.12)
    for sx in (-1, 1):
        parts.append(box("strobe", (0.16, 0.05, 0.04), (sx * 0.22, hl - 0.01, zf - 0.22),
                         m["beacon_red"] if sx < 0 else m["beacon_blue"]))
    if heavy:
        parts.append(box("pushbar", (W * 0.7, 0.12, 0.45), (0, hl + 0.05, P["ride"] + 0.45), m["trim"], bevel=0.03))
        for sx in (-1, 1):
            parts.append(box("pushbar_post", (0.08, 0.28, 0.08), (sx * W * 0.25, hl - 0.06, P["ride"] + 0.55), m["trim"]))
    return parts


# ---------------------------------------------------------------- the line-up
# (y = along the car, +front; z = height). All original designs.

BODIES = {
    # Kestrel: the everyday hatch you start in.
    "kestrel": dict(L=4.02, W=1.78, ride=0.17, wheel_r=0.31, wb=2.56, n=3.2,
                    top=[(-2.01, 0.86), (-1.9, 0.98), (-0.9, 0.97), (0.85, 0.92), (1.6, 0.84), (2.01, 0.62)],
                    glass=dict(y_front=1.05, y_rear=-1.93, belt_f=0.94, belt_r=0.98, roof=1.47, roof_f=0.1,
                               roof_r=-1.7, tumble=0.2, pillars=[-0.32]), lamp_w=0.34, grille_w=0.4),
    # Marlin GT: a quick four-door saloon.
    "marlin": dict(L=4.78, W=1.86, ride=0.15, wheel_r=0.34, wb=2.86, n=3.5,
                   top=[(-2.39, 0.78), (-2.2, 0.92), (-1.2, 0.95), (0.9, 0.86), (1.9, 0.78), (2.39, 0.56)],
                   glass=dict(y_front=1.15, y_rear=-1.42, belt_f=0.88, belt_r=0.95, roof=1.4, roof_f=0.25,
                              roof_r=-0.85, tumble=0.22, pillars=[-0.25]), spoiler=(0.05, 0.6), tail_bar=True),
    # Brute 8: long-hood muscle, fastback.
    "brute": dict(L=4.88, W=1.94, ride=0.15, wheel_r=0.35, wb=2.88, n=4.0, wb_off=0.05,
                  top=[(-2.44, 0.84), (-2.3, 0.94), (-1.3, 0.95), (0.6, 0.9), (2.0, 0.86), (2.44, 0.7)],
                  glass=dict(y_front=0.55, y_rear=-1.7, belt_f=0.9, belt_r=0.95, roof=1.33, roof_f=-0.15,
                             roof_r=-0.75, tumble=0.18, pillars=[]), scoop=True, grille_w=0.72, grille_h=0.2,
                  lamp_w=0.22, spoiler=(0.03, 0.7), tail_bar=True, body_tumble=0.04),
    # Vanta S: compact front-engine sports coupe.
    "vanta": dict(L=4.45, W=1.9, ride=0.12, wheel_r=0.34, wb=2.6, n=3.0,
                  top=[(-2.22, 0.78), (-2.05, 0.9), (-1.2, 0.92), (0.5, 0.82), (1.6, 0.7), (2.22, 0.5)],
                  plan=[(-2.22, 0.84), (-1.6, 1.0), (-1.0, 0.95), (0.4, 0.93), (1.3, 1.0), (1.9, 0.92), (2.22, 0.76)],
                  glass=dict(y_front=0.72, y_rear=-1.45, belt_f=0.8, belt_r=0.9, roof=1.26, roof_f=-0.15,
                             roof_r=-0.75, tumble=0.26, pillars=[]), spoiler=(0.12, 0.62), lamp_w=0.4, lamp_h=0.07),
    # Halcyon R: mid-engine supercar, cab-forward.
    "halcyon": dict(L=4.6, W=2.02, ride=0.1, wheel_r=0.35, wb=2.7, n=2.8,
                    top=[(-2.3, 0.85), (-2.1, 0.95), (-1.2, 0.9), (0.2, 0.74), (1.4, 0.62), (2.3, 0.42)],
                    plan=[(-2.3, 0.86), (-1.5, 1.0), (-0.6, 0.9), (0.6, 0.9), (1.4, 1.0), (2.0, 0.9), (2.3, 0.74)],
                    glass=dict(y_front=1.0, y_rear=-0.9, belt_f=0.66, belt_r=0.86, roof=1.12, roof_f=0.15,
                               roof_r=-0.45, tumble=0.3, pillars=[]), spoiler=(0.22, 0.75), lamp_w=0.42, lamp_h=0.06,
                    grille_w=0.6, grille_h=0.12, grille_z=-0.06, tail_bar=True),
    # Warden: an armoured 4x4 – slow, nearly unstoppable.
    "warden": dict(L=4.95, W=2.06, ride=0.32, wheel_r=0.43, wb=2.96, n=5.5,
                   top=[(-2.47, 1.18), (-2.3, 1.24), (-1.0, 1.24), (1.2, 1.2), (2.1, 1.16), (2.47, 1.0)],
                   glass=dict(y_front=1.25, y_rear=-2.25, belt_f=1.2, belt_r=1.24, roof=1.9, roof_f=0.95,
                              roof_r=-2.15, tumble=0.08, pillars=[-0.45, 0.4]), grille_w=0.7, grille_h=0.3,
                   lamp_w=0.3, lamp_h=0.14, side_skirt=False, body_tumble=0.02),
}

POLICE = {
    # Patrol: the saloon in livery.
    "police_patrol": ("marlin", False, (0.06, 0.08, 0.14), (0.92, 0.94, 0.96)),
    # Interceptor: the coupe, dark with a hi-vis band.
    "police_interceptor": ("vanta", False, (0.04, 0.045, 0.05), (0.75, 0.95, 0.15)),
    # Heavy: the 4x4 with a push bar.
    "police_heavy": ("warden", True, (0.1, 0.11, 0.13), (0.92, 0.94, 0.96)),
}


def build(name, P, police=None):
    kit.reset()
    m = mats()
    parts = car_body(P, m)
    if police:
        parts += police_kit(P, m, heavy=police[1])
        # Livery: a band along the doors and the bonnet/roof panels in paint2.
        body, glass = parts[0], parts[1]
        g = P["glass"]
        belt = (g["belt_f"] + g["belt_r"]) / 2
        wb = P["wb"]
        y0 = P.get("wb_off", 0.0)
        paint_faces(body, m["paint2"], lambda c, n: abs(n.x) > 0.6 and belt - 0.36 < c.z < belt - 0.12
                    and abs(c.y - y0) < wb * 0.5 and c.z > P["ride"] + 0.2)
        paint_faces(glass, m["paint2"], lambda c, n: n.z > 0.55 and c.z > g["roof"] - 0.12
                    and g["roof_r"] < c.y < g["roof_f"])
    ob = kit.join(name, parts)
    kit.export(name + ".glb", [ob])


def wheel(style):
    """A wheel centred on the origin, axle along X, tyre width 0.25, r 1 (scaled in Godot)."""
    kit.reset()
    m = mats()
    tyre_m = mat("tyre", (0.03, 0.03, 0.03), 0.85)
    rim_m = mat("rim", (0.7, 0.71, 0.74), 0.25, 1.0)
    dark_m = mat("rim_dark", (0.08, 0.08, 0.09), 0.35, 0.8)
    parts = []
    # Tyre: a lathed rounded profile.
    bm = bmesh.new()
    prof = [(0.66, -0.42), (0.9, -0.44), (0.98, -0.36), (1.0, 0.0), (0.98, 0.36), (0.9, 0.44), (0.66, 0.42)]
    segs = 28
    rings = []
    for i in range(segs):
        a = i * 2 * math.pi / segs
        rings.append([bm.verts.new((w * 0.36, r * math.cos(a), r * math.sin(a))) for r, w in prof])
    for i in range(segs):
        r0, r1 = rings[i], rings[(i + 1) % segs]
        for k in range(len(prof) - 1):
            bm.faces.new((r0[k], r0[k + 1], r1[k + 1], r1[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    t = kit.new_obj("tyre", bm, tyre_m)
    for p in t.data.polygons:
        p.use_smooth = True
    parts.append(t)
    rim_r = 0.68
    face = cyl("rimface", rim_r, 0.05, (0, 0, 0), dark_m if style in ("blade", "mesh") else m["trim"], 28)
    face.rotation_euler = (0, math.pi / 2, 0)
    face.location = (0.06, 0, 0)
    parts.append(face)
    lip = cyl("lip", rim_r, 0.03, (0, 0, 0), rim_m, 28, r2=rim_r * 0.96)
    lip.rotation_euler = (0, math.pi / 2, 0)
    lip.location = (0.11, 0, 0)
    parts.append(lip)
    spokes = {"five": 5, "split": 10, "blade": 7, "mesh": 14, "steel": 0}[style]
    for i in range(spokes):
        a = i * 2 * math.pi / spokes
        w = 0.13 if style == "five" else (0.06 if style == "mesh" else 0.08)
        s = box("spoke", (0.05, w, rim_r * 0.9), (0.13, 0, 0), rim_m, bevel=0.01)
        s.location = (0.13, math.sin(a) * rim_r * 0.47, math.cos(a) * rim_r * 0.47)
        s.rotation_euler = (-a, 0, 0) if style != "blade" else (-a, 0.0, 0.25)
        parts.append(s)
    if style == "steel":
        disc = cyl("disc", rim_r * 0.92, 0.04, (0, 0, 0), rim_m, 24)
        disc.rotation_euler = (0, math.pi / 2, 0)
        disc.location = (0.1, 0, 0)
        parts.append(disc)
        for i in range(6):
            a = i * math.pi / 3
            h = cyl("hole", 0.09, 0.05, (0, 0, 0), m["trim"], 10)
            h.rotation_euler = (0, math.pi / 2, 0)
            h.location = (0.115, math.sin(a) * 0.45, math.cos(a) * 0.45)
            parts.append(h)
    hub = cyl("hub", 0.15, 0.06, (0, 0, 0), rim_m, 14)
    hub.rotation_euler = (0, math.pi / 2, 0)
    hub.location = (0.14, 0, 0)
    parts.append(hub)
    ob = kit.join("wheel", parts)
    kit.export("wheel_%s.glb" % style, [ob])


def preview(path):
    kit.reset()
    names = list(BODIES) + list(POLICE)
    tints = [(0.75, 0.75, 0.72), (0.08, 0.2, 0.45), (0.55, 0.06, 0.04), (0.9, 0.42, 0.05), (0.85, 0.85, 0.86),
             (0.2, 0.24, 0.2), (0.06, 0.08, 0.14), (0.04, 0.045, 0.05), (0.1, 0.11, 0.13)]
    for i, f in enumerate(names):
        bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, f + ".glb"))
        ob = bpy.context.selected_objects[0]
        ob.rotation_mode = "XYZ"
        col, row = i % 5, i // 5
        ob.location = (col * 5.6 - 11.2, row * -7.0, 0)
        ob.rotation_euler = (0, 0, math.radians(-130))
        for s in ob.material_slots:
            if not s.material:
                continue
            bsdf = s.material.node_tree.nodes.get("Principled BSDF") if s.material.node_tree else None
            if s.material.name.startswith("paint") and not s.material.name.startswith("paint2"):
                c = s.material.copy()
                c.diffuse_color = (*tints[i], 1)
                s.material = c
            elif bsdf:
                s.material.diffuse_color = bsdf.inputs["Base Color"].default_value
        for k, (x, y) in enumerate([(1, 1), (-1, 1), (1, -1), (-1, -1)]):
            P = BODIES[POLICE[f][0]] if f in POLICE else BODIES[f]
            bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, "wheel_five.glb"))
            w = bpy.context.selected_objects[0]
            w.rotation_mode = "XYZ"
            w.scale = (P["wheel_r"],) * 3
            import mathutils
            rot = mathutils.Matrix.Rotation(math.radians(-130), 4, "Z")
            off = rot @ Vector((x * (P["W"] / 2 - 0.13), y * P["wb"] / 2 + P.get("wb_off", 0.0), P["wheel_r"]))
            w.location = Vector(ob.location) + off
            w.rotation_euler = (0, 0, math.radians(-130) + (0 if x > 0 else math.pi))
            for s in w.material_slots:
                if s.material and s.material.node_tree:
                    b = s.material.node_tree.nodes.get("Principled BSDF")
                    if b:
                        s.material.diffuse_color = b.inputs["Base Color"].default_value
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.color_type = "MATERIAL"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.show_shadows = True
    sc.display.shading.show_cavity = True
    sc.render.resolution_x, sc.render.resolution_y = 1800, 900
    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 40
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    cam.location = (0, -24, 13)
    cam.rotation_euler = (math.radians(62), 0, 0)
    sc.camera = cam
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.3, 0.32, 0.38)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    for name, P in BODIES.items():
        build(name, P)
    for name, (base, heavy, c1, c2) in POLICE.items():
        build(name, BODIES[base], (base, heavy))
    for style in ("five", "split", "blade", "mesh", "steel"):
        wheel(style)
    if PREVIEW:
        preview(PREVIEW)
    print("VEHICLES DONE")
