"""NEVER STOP vehicles v2: crisp, section-lofted original car bodies.

Run:  blender -b --factory-startup --python tools/blender/build_vehicles.py -- assets/vehicles [preview.png] [only,ids]

How a body is made (all from code, no hand modelling):
  * Lower body: a loft through cross-sections. Each section is a half
    profile - crowned top, top edge, shoulder crease, side, rocker - with
    its own corner radii, so a design can be soft (Halcyon) or knife-edged
    (Stiletto). Every parameter is a curve along the car's length (plan
    taper, hips and waist, wedge line, tumblehome), and the nose and tail are
    rounded off with a small end radius. No subdivision: hard creases stay
    hard, the mesh stays light for mobile.
  * Glasshouse: lofted the same way on top of the body. Materials go by
    ring index (roof panel, rails/pillars, side glass), so edges are clean.
  * Wheel wells: exact booleans with a black liner on the cut.
  * Detail is projected: lamps, LED strips, grilles, vents, panel seams,
    stripes and livery are quads ray-cast onto the body surface (BVH), with an
    optional thickness so a lamp sits proud in a housing. They follow every
    curve and never float or sink.
  * Real geometry for the rest: wings, diffuser fins, exhausts, mirrors,
    light bars, roll bars, bull bars, cargo boxes, fuel tanks...

Conventions: Blender +Y forward -> Godot -Z; origin on the ground under the
car's centre; wheel centres at (±track/2, ±wb/2, wheel_r). Material names
are what Godot keys off (see src/vehicle/car_visual.gd). Writes
assets/vehicles/bodies.json with each body's real dimensions; the car
catalogue reads it so physics and art always agree.
"""
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

sys.path.insert(0, os.path.dirname(__file__))
import build_kit as kit  # noqa: E402
from build_kit import box, cyl, mat  # noqa: E402

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = ARGS[0] if ARGS else "assets/vehicles"
PREVIEW = ARGS[1] if len(ARGS) > 1 else ""
ONLY = set(ARGS[2].split(",")) if len(ARGS) > 2 and ARGS[2] else set()
kit.OUT = OUT
os.makedirs(OUT, exist_ok=True)

V2 = Vector


def mats():
    return {
        "paint": mat("paint", (0.8, 0.8, 0.8), 0.25, 0.4),
        "paint2": mat("paint2", (0.95, 0.95, 0.95), 0.3, 0.2),
        "glass": mat("glass", (0.05, 0.06, 0.08), 0.05, 0.3),
        "trim": mat("trim", (0.04, 0.04, 0.045), 0.6),
        "seam": mat("seam", (0.01, 0.01, 0.012), 0.8),
        "carbon": mat("carbon", (0.05, 0.05, 0.055), 0.3, 0.2),
        "cladding": mat("cladding", (0.07, 0.07, 0.075), 0.85),
        "chrome": mat("chrome", (0.75, 0.76, 0.78), 0.15, 1.0),
        "liner": mat("liner", (0.02, 0.02, 0.02), 0.9),
        "bed": mat("bed", (0.05, 0.05, 0.05), 0.95),
        "grille": mat("grille", (0.03, 0.03, 0.035), 0.5, 0.3),
        "lamp_head": mat("lamp_head", (0.95, 0.95, 0.92), 0.1, 0.0, emit=(1.0, 0.95, 0.85)),
        "lamp_tail": mat("lamp_tail", (0.6, 0.03, 0.03), 0.2, 0.0, emit=(1.0, 0.05, 0.03)),
        "lamp_amber": mat("lamp_amber", (0.9, 0.45, 0.05), 0.2, 0.0, emit=(1.0, 0.5, 0.05)),
        "lamp_rev": mat("lamp_rev", (0.9, 0.9, 0.9), 0.2),
        "lamp_housing": mat("lamp_housing", (0.02, 0.02, 0.025), 0.15, 0.6),
        "beacon_red": mat("beacon_red", (0.8, 0.05, 0.05), 0.2, 0.0, emit=(1.0, 0.05, 0.05)),
        "beacon_blue": mat("beacon_blue", (0.05, 0.15, 0.9), 0.2, 0.0, emit=(0.1, 0.3, 1.0)),
        "plate": mat("plate", (0.92, 0.9, 0.8), 0.6),
        "sign": mat("sign", (1.0, 0.85, 0.3), 0.3, 0.0, emit=(1.0, 0.8, 0.3)),
        "tyre": mat("tyre", (0.03, 0.03, 0.03), 0.85),
        "rim": mat("rim", (0.7, 0.71, 0.74), 0.25, 1.0),
    }


# ---------------------------------------------------------------- curves


def interp(pts, x):
    """Smooth piecewise interpolation through [(x, y), ...] sorted by x. Numbers pass through."""
    if not isinstance(pts, (list, tuple)):
        return pts
    if x <= pts[0][0]:
        return pts[0][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x <= x1:
            t = (x - x0) / (x1 - x0) if x1 > x0 else 1.0
            t = t * t * (3 - 2 * t)
            return y0 + (y1 - y0) * t
    return pts[-1][1]


def lin(pts, x):
    if not isinstance(pts, (list, tuple)):
        return pts
    if x <= pts[0][0]:
        return pts[0][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x <= x1:
            t = (x - x0) / (x1 - x0) if x1 > x0 else 1.0
            return y0 + (y1 - y0) * t
    return pts[-1][1]


def curve(P, key, y, default=None):
    v = P.get(key, default)
    if isinstance(v, dict):  # {"lin": [...]}
        return lin(v["lin"], y)
    return interp(v, y)


# ---------------------------------------------------------------- sections

K = 4  # points per rounded corner (constant: lofts need a fixed ring size)


def corner(p0, c, p1, r, k=K):
    a = p0 - c
    b = p1 - c
    rr = max(0.004, min(r, 0.45 * a.length, 0.45 * b.length))
    s = c + a.normalized() * rr
    e = c + b.normalized() * rr
    out = []
    for i in range(k):
        t = i / (k - 1)
        out.append((1 - t) ** 2 * s + 2 * (1 - t) * t * c + t * t * e)
    return out


def body_half(hw, zb, zs, zt, tt, tb, crown, rt, rs, rb):
    """Half section (x >= 0) from the top centre round to the bottom centre."""
    zt_e = zt - crown
    zs = min(max(zs, zb + 0.06), zt_e - 0.03)
    T0 = V2((0.0, zt))
    TM = V2(((hw - tt) * 0.5, zt - crown * 0.3))
    TE = V2((hw - tt, zt_e))
    SH = V2((hw, zs))
    BE = V2((hw - tb, zb))
    BM = V2(((hw - tb) * 0.5, zb))
    B0 = V2((0.0, zb))
    pts = [T0, TM]
    pts += corner(TM, TE, SH, rt)
    pts += corner(TE, SH, BE, rs)
    pts += corner(SH, BE, BM, rb)
    pts += [BM, B0]
    return pts


def mirror_ring(half):
    return half + [V2((-p.x, p.y)) for p in reversed(half[1:-1])]


def loft(name, stations, material, close=True):
    """stations: [(y, ring[(x, z)...])] -> closed lofted solid. Returns (obj, ring_size)."""
    bm = bmesh.new()
    rings = []
    for y, ring in stations:
        rings.append([bm.verts.new((p.x, y, p.y)) for p in ring])
    n = len(rings[0])
    lr = bm.faces.layers.int.new("ring")
    ls = bm.faces.layers.int.new("st")
    for si, (r0, r1) in enumerate(zip(rings, rings[1:])):
        for i in range(n):
            j = (i + 1) % n
            f = bm.faces.new((r0[i], r0[j], r1[j], r1[i]))
            f[lr] = i
            f[ls] = si
    if close:
        bm.faces.new(list(reversed(rings[0])))
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(material)
    return ob, n


def set_mat(ob, material, face_pred):
    names = [m.name if m else "" for m in ob.data.materials]
    if material.name not in names:
        ob.data.materials.append(material)
        names.append(material.name)
    idx = names.index(material.name)
    ring = ob.data.attributes.get("ring")
    st = ob.data.attributes.get("st")
    for p in ob.data.polygons:
        r = ring.data[p.index].value if ring else -1
        s = st.data[p.index].value if st else -1
        if face_pred(p, r, s):
            p.material_index = idx


def end_stations(L, step=0.11):
    """Station positions along the length: dense at both ends for the end radius."""
    hl = L / 2
    ends = [0.0, 0.012, 0.035, 0.07, 0.12, 0.19, 0.28]
    ys = [-hl + d for d in ends]
    y = -hl + 0.28 + step
    while y < hl - 0.28 - step * 0.5:
        ys.append(y)
        y += step
    ys += [hl - d for d in reversed(ends)]
    return ys


def section_at(P, y):
    hl = P["L"] / 2
    W2 = P["W"] / 2
    hw = W2 * curve(P, "plan", y)
    zt = curve(P, "top", y)
    zb = curve(P, "bottom", y)
    zs = curve(P, "shoulder", y)
    tt = curve(P, "tuck_top", y, 0.12)
    tb = curve(P, "tuck_bot", y, 0.06)
    crown = curve(P, "crown", y, 0.04)
    R = P.get("end_r", 0.14)
    d = min(y + hl, hl - y)
    if d < R:
        inset = R - math.sqrt(max(0.0, R * R - (R - d) ** 2))
        hw -= inset
        zt -= inset * P.get("end_top", 0.5)
        zb += inset * P.get("end_bot", 0.35)
        zs = min(zs, zt - crown - 0.04)
    return hw, zb, zs, zt, tt, tb, crown


def lower_body(P, m):
    sts = []
    for y in end_stations(P["L"], P.get("step", 0.11)):
        hw, zb, zs, zt, tt, tb, crown = section_at(P, y)
        half = body_half(hw, zb, zs, zt, tt, tb, crown, curve(P, "r_top", y, 0.05),
                         curve(P, "r_sh", y, 0.03), curve(P, "r_bot", y, 0.06))
        sts.append((y, mirror_ring(half)))
    body, n = loft("body", sts, m["paint"])
    nh = 2 + 3 * K + 2  # half size
    # Underbody: the bottom faces go dark.
    set_mat(body, m["trim"], lambda p, r, s: r >= 0 and (nh - 4 <= r <= nh + 1))
    return body


def top_z(P, y, x_frac=1.0):
    hw, zb, zs, zt, tt, tb, crown = section_at(P, y)
    return zt - crown * x_frac


def glasshouse(P, m):
    g = P["glass"]
    yf, yr = g["y_front"], g["y_rear"]
    rf, rr = g["roof_f"], g["roof_r"]
    roof = g["roof"]
    n_st = g.get("n", 26)
    inset = g.get("inset", 0.06)
    gk = 3
    sts = []
    ys = []
    for i in range(n_st):
        t = i / (n_st - 1)
        y = yr + (yf - yr) * t
        ys.append(y)
        hw, zb, zs, zt, tt, tb, crown = section_at(P, y)
        base = zt - crown - 0.012
        bw = hw - tt - inset
        # Roof line: convex windscreen and backlight, a gently arched roof.
        if y > rf:
            u = (yf - y) / max(yf - rf, 0.01)
            z = base + (roof - base) * (1 - (1 - u) ** g.get("ws_curve", 1.5))
        elif y < rr:
            u = (y - yr) / max(rr - yr, 0.01)
            z = base + (roof - base) * (1 - (1 - u) ** g.get("bl_curve", 1.5))
        else:
            u = (y - rr) / max(rf - rr, 0.01)
            z = roof + g.get("roof_arc", 0.02) * math.sin(u * math.pi)
        h = max(0.025, z - base)
        z = base + h
        rw = bw - g.get("tumble", 0.16) * min(1.0, h / 0.35)
        rw = max(rw, bw * 0.4)
        T0 = V2((0.0, z))
        TM = V2((rw * 0.5, z - 0.008))
        RC = V2((rw, z - g.get("crown", 0.025)))
        BS = V2((bw, base))
        half = [T0, TM] + corner(TM, RC, BS, g.get("r", 0.06), gk) + [BS, V2((bw * 0.97, base - 0.08)),
                                                                        V2((bw * 0.5, base - 0.08)), V2((0.0, base - 0.08))]
        sts.append((y, mirror_ring(half)))
    glass, n = loft("glass", sts, m["glass"])
    nh = 2 + gk + 4
    # Ring indices: 0..1 top, 2..2+gk-1 corner, 2+gk side glass, rest buried.
    top_r = {0, n - 1, 1, n - 2}
    corner_r = set(range(2, 2 + gk - 1)) | set(range(n - 1 - gk, n - 2))
    side_r = {2 + gk - 1, n - 2 - gk}  # the face between the corner's end and the belt
    roof_m = m[g.get("roof_mat", "paint")]
    pil_m = m[g.get("pillar_mat", "paint")]
    bands = g.get("pillars", [])
    c_y = g.get("c_pillar", yr - 1.0)  # side glass ends here (behind: painted panel)
    a_y = g.get("a_pillar", yf + 1.0)  # side glass starts here

    def st_y(s):
        return (ys[s] + ys[min(s + 1, len(ys) - 1)]) * 0.5

    deck_y = g.get("deck_y", yr - 1.0)  # canopy top behind this is painted (engine cover)

    def is_roof(p, r, s):
        y = st_y(s)
        return r in top_r and (rr - 0.02 < y < rf + 0.02 or y < deck_y)

    def is_pillar(p, r, s):
        y = st_y(s)
        if r in corner_r:
            return True
        if r in side_r or r in corner_r:
            return y < c_y or y > a_y or any(abs(y - b[0]) < b[1] / 2 for b in bands)
        return False

    def is_buried(p, r, s):
        return r >= 0 and r not in top_r and r not in corner_r and r not in side_r

    set_mat(glass, pil_m, is_pillar)
    set_mat(glass, roof_m, is_roof)
    set_mat(glass, m["trim"], is_buried)
    for p in glass.data.polygons:
        p.use_smooth = True
    return glass


def arches(body, P, m):
    wr = P["wheel_r"]
    W2 = P["W"] / 2
    depth = P.get("tyre_w", 0.27) + 0.16
    for y in P.get("axles", (P["wb"] / 2, -P["wb"] / 2)):
        for sx in (-1, 1):
            c = axle_cyl("arch", wr + P.get("arch_gap", 0.045), depth + 0.4, sx * (W2 - depth / 2 + 0.2), y, wr, 36)
            cut(body, c, m["liner"])


def apply_mods(ob):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.convert(target="MESH")
    return ob


def shade(ob, angle=32):
    for p in ob.data.polygons:
        p.use_smooth = True
    try:
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        bpy.ops.object.shade_auto_smooth(angle=math.radians(angle))
        apply_mods(ob)
    except Exception as e:  # noqa: BLE001
        print("auto smooth failed", e)


def cut(ob, cutter, cutter_mat=None, op="DIFFERENCE"):
    if cutter_mat is not None:
        cutter.data.materials.clear()
        cutter.data.materials.append(cutter_mat)
        if cutter_mat.name not in [mm.name for mm in ob.data.materials if mm]:
            ob.data.materials.append(cutter_mat)
    mod = ob.modifiers.new("cut", "BOOLEAN")
    mod.operation = op
    mod.solver = "EXACT"
    mod.object = cutter
    try:
        mod.material_mode = "TRANSFER"
    except Exception:  # noqa: BLE001
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


def solid(name, verts_fn, material):
    """Convex-ish solid from 8 corner points [(x,y,z)] (box order: bottom 4 then top 4)."""
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts_fn]
    for f in ((0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)):
        bm.faces.new([vs[i] for i in f])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return kit.new_obj(name, bm, material)


def tube(name, a, b, r, material, segs=10):
    a, b = Vector(a), Vector(b)
    d = b - a
    c = cyl(name, r, d.length, (0, 0, 0), material, segs)
    c.rotation_mode = "QUATERNION"
    c.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    c.location = a
    return c


def ycyl(name, r, length, loc, material, segs=16, r2=None):
    c = cyl(name, r, length, (0, 0, 0), material, segs, r2=r2)
    c.rotation_euler = (-math.pi / 2, 0, 0)
    c.location = (loc[0], loc[1] - length / 2, loc[2])
    return c


def xcyl(name, r, length, loc, material, segs=16):
    c = cyl(name, r, length, (0, 0, 0), material, segs)
    c.rotation_euler = (0, math.pi / 2, 0)
    c.location = (loc[0] - length / 2, loc[1], loc[2])
    return c


# ---------------------------------------------------------------- projected detail


class Surface:
    """Ray-cast target: the lower body (and optionally the glasshouse)."""

    def __init__(self, objs):
        dg = bpy.context.evaluated_depsgraph_get()
        self.trees = [BVHTree.FromObject(o, dg) for o in objs]

    def cast(self, o, d):
        best = None
        for t in self.trees:
            hit = t.ray_cast(Vector(o), Vector(d), 30.0)
            if hit[0] is not None and (best is None or hit[3] < best[3]):
                best = hit
        return best


def _ray(view, u, v, side=1):
    """view: front/rear/left/right/top -> (origin, dir) for plane coords (u, v)."""
    if view == "front":
        return (u, 20.0, v), (0, -1, 0)
    if view == "rear":
        return (u, -20.0, v), (0, 1, 0)
    if view == "side":
        return (side * 20.0, u, v), (-side, 0, 0)
    if view == "top":
        return (u, v, 20.0), (0, 0, -1)
    if view == "bottom":
        return (u, v, -5.0), (0, 0, 1)
    raise ValueError(view)


def decal(surf, view, fn, material, nu=6, nv=2, off=0.004, thick=0.0, side=1, name="decal", max_jump=None):
    """Projects the patch fn(s, t) -> (u, v), s,t in [0,1], onto the surface.
    Returns an object (or None). thick > 0 gives a raised shell with walls."""
    if max_jump is None:
        # Along the car's length the nose and tail curve away steeply.
        max_jump = 0.35 if view in ("front", "rear") else 0.12
    grid = []
    for j in range(nv + 1):
        row = []
        for i in range(nu + 1):
            u, v = fn(i / nu, j / nv)
            o, d = _ray(view, u, v, side)
            h = surf.cast(o, d)
            row.append(h)
        grid.append(row)
    bm = bmesh.new()
    top = {}
    bot = {}

    def vert(i, j, lift, store):
        if (i, j) not in store:
            h = grid[j][i]
            store[(i, j)] = bm.verts.new(h[0] + h[1] * lift)
        return store[(i, j)]

    faces = 0
    used = set()
    for j in range(nv):
        for i in range(nu):
            hs = [grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]]
            if any(h is None for h in hs):
                continue
            ds = [h[3] for h in hs]
            if max(ds) - min(ds) > max_jump:
                continue
            q = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)]
            f = bm.faces.new([vert(a, b, off + thick, top) for a, b in q])
            f.normal_update()
            nrm = sum((h[1] for h in hs), Vector())
            if f.normal.dot(nrm) < 0:
                f.normal_flip()
            used.add((i, j))
            faces += 1
    if faces == 0:
        bm.free()
        return None
    if thick > 0.0:
        cen = sum((v.co for v in top.values()), Vector()) / max(1, len(top))
        # Walls round the outside of the patch, down to the surface.
        for (i, j) in list(used):
            for (a, b, c, d, ni, nj) in (((i, j), (i + 1, j), None, None, i, j - 1), ((i + 1, j), (i + 1, j + 1), None, None, i + 1, j),
                                          ((i + 1, j + 1), (i, j + 1), None, None, i, j + 1), ((i, j + 1), (i, j), None, None, i - 1, j)):
                if (ni, nj) in used:
                    continue
                t0, t1 = vert(*a, off + thick, top), vert(*b, off + thick, top)
                b0, b1 = vert(*a, off * 0.3, bot), vert(*b, off * 0.3, bot)
                try:
                    wf = bm.faces.new((t1, t0, b0, b1))
                    wf.normal_update()
                    if wf.normal.dot(wf.calc_center_median() - cen) < 0:
                        wf.normal_flip()
                except ValueError:
                    pass
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    me.materials.append(material)
    for p in me.polygons:
        p.use_smooth = True
    return ob


def quad(c0, c1, c2, c3):
    """Bilinear patch through four (u, v) corners: c0 bottom-left, c1 bottom-right, c2 top-right, c3 top-left."""
    def f(s, t):
        a = (c0[0] + (c1[0] - c0[0]) * s, c0[1] + (c1[1] - c0[1]) * s)
        b = (c3[0] + (c2[0] - c3[0]) * s, c3[1] + (c2[1] - c3[1]) * s)
        return a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
    return f


def rect(u0, v0, u1, v1):
    return quad((u0, v0), (u1, v0), (u1, v1), (u0, v1))


def arc_band(cu, cv, r0, r1, a0, a1):
    """Ring segment in the side plane (u = y, v = z) - wheel arch flares."""
    def f(s, t):
        a = a0 + (a1 - a0) * s
        r = r0 + (r1 - r0) * t
        return cu + math.cos(a) * r, cv + math.sin(a) * r
    return f


def both(surf, view, fn_right, material, **kw):
    """Decal on the right side and its mirror on the left."""
    out = []
    if view == "side":
        for sd in (1, -1):
            out.append(decal(surf, "side", fn_right, material, side=sd, **kw))
    else:
        out.append(decal(surf, view, fn_right, material, **kw))
        out.append(decal(surf, view, lambda s, t: (lambda u, v: (-u, v))(*fn_right(1 - s, t)), material, **kw))
    return [o for o in out if o]


# ---------------------------------------------------------------- common kit


def mirrors(P, m, out, y=None, z=None, style="body"):
    g = P["glass"]
    y = g["y_front"] - 0.28 if y is None else y
    hw, zb, zs, zt, tt, tb, crown = section_at(P, y)
    z = zt - crown + 0.12 if z is None else z
    x = hw - tt * 0.5 + 0.1
    for sx in (-1, 1):
        if style == "truck":
            out.append(box("mirror", (0.06, 0.12, 0.34), (sx * (x + 0.12), y, z + 0.2), m["trim"], bevel=0.02))
            out.append(tube("mirror_arm", (sx * x, y, z), (sx * (x + 0.12), y, z + 0.1), 0.015, m["chrome"]))
        else:
            out.append(box("mirror", (0.16, 0.1, 0.085), (sx * x, y, z), m["paint"], bevel=0.035))
            out.append(box("mirror_glass", (0.13, 0.01, 0.06), (sx * x, y - 0.052, z), m["chrome"]))
            out.append(box("mirror_arm", (0.1, 0.04, 0.025), (sx * (x - 0.08), y + 0.01, z - 0.03), m["trim"]))


def plate(P, m, out, z=None, front=False):
    hl = P["L"] / 2
    y = -hl + 0.01 if not front else hl - 0.01
    z = P["ride"] + 0.35 if z is None else z
    sgn = -1 if not front else 1
    hw, zb, zs, zt, tt, tb, crown = section_at(P, y - sgn * 0.08)
    out.append(box("plate", (0.5, 0.025, 0.12), (0, y - sgn * 0.02 + sgn * 0.0, z), m["plate"]))


def wing(m, span, chord, loc, angle=0.12, posts=0.35, post_h=0.2, mat_key="carbon", plates=True):
    out = []
    x0, y0, z0 = loc
    bm = bmesh.new()
    prof = [(0.0, 0.0), (0.15, 0.045), (0.4, 0.06), (0.75, 0.04), (1.0, 0.0), (0.7, -0.012), (0.3, -0.016), (0.08, -0.01)]
    rings = []
    for x in (-span / 2, span / 2):
        ring = []
        for (s, h) in prof:
            yy = -s * chord
            zz = h * chord * 1.6
            # pitch
            yr = yy * math.cos(angle) - zz * math.sin(angle)
            zr = yy * math.sin(angle) + zz * math.cos(angle)
            ring.append(bm.verts.new((x0 + x, y0 + chord * 0.5 + yr, z0 + zr)))
        rings.append(ring)
    n = len(prof)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    out.append(kit.new_obj("wing", bm, m[mat_key]))
    if plates:
        for sx in (-1, 1):
            out.append(box("endplate", (0.025, chord * 1.15, 0.16), (x0 + sx * (span / 2 + 0.012), y0, z0 + 0.02), m[mat_key], bevel=0.008))
    for sx in (-1, 1):
        out.append(box("wing_post", (0.035, 0.12, post_h), (x0 + sx * span * posts, y0 + 0.03, z0 - post_h / 2), m[mat_key], bevel=0.01))
    return out


def exhaust(m, x, y, z, r=0.045, length=0.18, out=None):
    out.append(ycyl("exhaust", r, length, (x, y, z), m["chrome"], 16))
    out.append(ycyl("exhaust_in", r * 0.72, 0.02, (x, y - length / 2 - 0.004, z), m["liner"], 12))


def lightbar(m, out, y, z, w, police=True, n=6, depth=0.26):
    out.append(box("lightbar_base", (w, depth, 0.05), (0, y, z), m["trim"], bevel=0.015))
    seg = w / n
    for i in range(n):
        if police:
            mt = m["beacon_red"] if i < n / 2 else m["beacon_blue"]
        else:
            mt = m["lamp_head"]
        out.append(box("beacon" if police else "spot", (seg * 0.9, depth * 0.85, 0.07), (-w / 2 + seg * (i + 0.5), y, z + 0.055), mt, bevel=0.018))
    for sx in (-1, 1):
        out.append(box("lb_foot", (0.06, 0.12, 0.05), (sx * w * 0.38, y, z - 0.04), m["trim"]))


# ---------------------------------------------------------------- the line-up
# Every body: dimensions + curves along y (rear -L/2 .. front +L/2) + features.
# All original designs.


def common_lamps(P, m, surf, out, style):
    """Head and tail lamps, indicators, grille, intake, per style."""
    hl, W2 = P["L"] / 2, P["W"] / 2
    ride = P["ride"]
    zf = top_z(P, hl - 0.15)          # bonnet edge at the nose
    zr = top_z(P, -hl + 0.15)
    s = P.get("lamps", {})
    # Headlamps: a slanted quad; housing behind it.
    hx0, hx1 = s.get("head_x", (W2 * 0.48, W2 * 0.9))
    hz = s.get("head_z", zf - 0.06)
    hh = s.get("head_h", 0.09)
    slant = s.get("head_slant", 0.03)
    if style != "none":
        out += both(surf, "front", quad((hx0, hz - hh - slant), (hx1, hz - hh), (hx1, hz), (hx0 + 0.03, hz - slant * 0.4)),
             m["lamp_housing"], nu=6, nv=2, off=0.003, thick=0.008, name="head_housing")
        out += both(surf, "front", quad((hx0 + 0.03, hz - hh * 0.78 - slant), (hx1 - 0.02, hz - hh * 0.8), (hx1 - 0.02, hz - hh * 0.25),
                                (hx0 + 0.05, hz - hh * 0.25 - slant * 0.6)), m["lamp_head"], nu=5, nv=1, off=0.013, name="head")
        if s.get("drl", True):
            out += both(surf, "front", quad((hx0 + 0.02, hz - hh * 0.12 - slant * 0.5), (hx1 - 0.01, hz - hh * 0.1), (hx1 - 0.01, hz - hh * 0.0 + 0.005),
                                    (hx0 + 0.02, hz - slant * 0.5 + 0.005)), m["lamp_head"], nu=5, nv=1, off=0.014, name="drl")
        out += both(surf, "front", rect(hx1 - 0.07, hz - hh - 0.05, hx1 - 0.005, hz - hh - 0.02), m["lamp_amber"], nu=1, nv=1, off=0.01)
    out.extend([])
    # Grille / intake.
    gw = W2 * s.get("grille_w", 0.5)
    gz = s.get("grille_z", (zf + ride) * 0.5)
    gh = s.get("grille_h", 0.16)
    if gw > 0:
        decal_add(out, decal(surf, "front", quad((-gw, gz - gh / 2), (gw, gz - gh / 2), (gw * s.get("grille_top", 1.0), gz + gh / 2),
                                                (-gw * s.get("grille_top", 1.0), gz + gh / 2)),
                             m["grille"], nu=8, nv=2, off=0.002, thick=s.get("grille_t", 0.012), name="grille"))
        if s.get("grille_chrome"):
            for k in range(s.get("grille_bars", 3)):
                zz = gz - gh / 2 + gh * (k + 1) / (s.get("grille_bars", 3) + 1)
                decal_add(out, decal(surf, "front", rect(-gw * 0.96, zz - 0.008, gw * 0.96, zz + 0.008), m["chrome"], nu=8, nv=1,
                                     off=0.018, name="grille_bar"))
    iw = W2 * s.get("intake_w", 0.82)
    iz = s.get("intake_z", ride + 0.13)
    ih = s.get("intake_h", 0.08)
    if iw > 0:
        decal_add(out, decal(surf, "front", rect(-iw, iz - ih / 2, iw, iz + ih / 2), m["grille"], nu=10, nv=1, off=0.003, name="intake"))
    # Tail lamps.
    tz = s.get("tail_z", zr - 0.08)
    th = s.get("tail_h", 0.09)
    tx0, tx1 = s.get("tail_x", (W2 * 0.55, W2 * 0.92))
    if s.get("tail_bar"):
        decal_add(out, decal(surf, "rear", rect(-tx1, tz - 0.022, tx1, tz + 0.012), m["lamp_tail"], nu=14, nv=1, off=0.01, name="tail_bar"))
    out += both(surf, "rear", rect(-tx1 if False else tx0, tz - th, tx1, tz), m["lamp_housing"], nu=4, nv=1, off=0.003, thick=0.008)
    out += both(surf, "rear", rect(tx0 + 0.02, tz - th * 0.85, tx1 - 0.02, tz - th * 0.15), m["lamp_tail"], nu=4, nv=1, off=0.013)
    out += both(surf, "rear", rect(tx0 + 0.02, tz - th * 0.85, tx0 + 0.1, tz - th * 0.15), m["lamp_rev"], nu=1, nv=1, off=0.015)


_decal_bucket = []


def decal_add(out, ob):
    if ob is not None:
        out.append(ob)


def seams(P, m, surf, out, doors):
    """Panel seams: door cut lines from the rocker to the belt; bonnet and boot shut lines."""
    ride = P["ride"]
    for (y, z0, z1) in doors:
        for sd in (1, -1):
            decal_add(out, decal(surf, "side", rect(y - 0.006, z0, y + 0.006, z1), m["seam"], nu=1, nv=6, off=0.002, side=sd, name="seam"))


def hood_lines(P, m, surf, out, y_back, y_front, x):
    for sx in (-1, 1):
        decal_add(out, decal(surf, "top", rect(sx * x - 0.006, y_back, sx * x + 0.006, y_front), m["seam"], nu=1, nv=8, off=0.002, name="hood_line"))
    decal_add(out, decal(surf, "top", rect(-x, y_back - 0.006, x, y_back + 0.006), m["seam"], nu=8, nv=1, off=0.002, name="hood_line"))


def stripes(P, m, surf, out, w=0.13, gap=0.07, y0=None, y1=None, glass=None):
    hl = P["L"] / 2
    y0 = -hl if y0 is None else y0
    y1 = hl if y1 is None else y1
    for sx in (-1, 1):
        x0 = sx * gap / 2
        x1 = sx * (gap / 2 + w)
        decal_add(out, decal(surf, "top", rect(min(x0, x1), y0, max(x0, x1), y1), m["paint2"], nu=2, nv=40, off=0.003, name="stripe", max_jump=0.4))


def side_band(P, m, surf, out, z0, z1, y0, y1, material, slope=0.0, nu=24):
    for sd in (1, -1):
        decal_add(out, decal(surf, "side", quad((y0, z0), (y1, z0 + slope), (y1, z1 + slope), (y0, z1)), material, nu=nu, nv=2,
                             off=0.003, side=sd, name="band"))


def arch_flares(P, m, surf, out, material, width=0.09, thick=0.03, a0=-0.15, a1=math.pi + 0.15):
    wr = P["wheel_r"]
    r0 = wr + P.get("arch_gap", 0.045) - 0.005
    for y in P.get("axles", (P["wb"] / 2, -P["wb"] / 2)):
        for sd in (1, -1):
            decal_add(out, decal(surf, "side", arc_band(y, wr, r0, r0 + width, a0, a1), material, nu=16, nv=1,
                                 off=0.002, thick=thick, side=sd, name="flare", max_jump=0.12))


def skirts(P, m, surf, out, material, y0, y1, z0, z1, thick=0.02):
    for sd in (1, -1):
        decal_add(out, decal(surf, "side", rect(y0, z0, y1, z1), material, nu=10, nv=1, off=0.002, thick=thick, side=sd, name="skirt"))


# ---- body definitions -------------------------------------------------------

def def_kestrel():
    L, W = 4.0, 1.8
    hl = L / 2
    return dict(
        L=L, W=1.84, ride=0.15, wheel_r=0.325, wb=2.6, tyre_w=0.25, end_r=0.14,
        top=[(-hl, 0.9), (-hl + 0.2, 0.97), (-1.2, 0.97), (0.9, 0.9), (1.55, 0.84), (hl, 0.68)],
        bottom=[(-hl, 0.4), (-hl + 0.42, 0.2), (hl - 0.5, 0.2), (hl, 0.34)],
        shoulder=[(-hl, 0.8), (-1.3, 0.8), (0.0, 0.76), (hl, 0.62)],
        plan=[(-hl, 0.9), (-1.5, 1.0), (-0.6, 0.96), (0.7, 0.96), (1.35, 1.0), (hl, 0.86)],
        tuck_top=0.12, tuck_bot=0.05, crown=0.045, r_top=0.08, r_sh=0.06, r_bot=0.07,
        glass=dict(y_front=0.92, y_rear=-1.9, roof_f=0.12, roof_r=-1.5, roof=1.42, tumble=0.2, r=0.07,
                   pillars=[(-0.42, 0.12)], c_pillar=-1.45, ws_curve=1.5, bl_curve=1.25),
        lamps=dict(head_h=0.1, head_slant=0.02, grille_w=0.42, grille_h=0.08, intake_w=0.7, intake_h=0.1,
                   tail_z=0.98, tail_h=0.16, tail_x=(0.55, 0.85)),
        doors=[(0.98, 0.3, 0.9), (-0.42, 0.3, 0.93)],
        sill=True, flares=True,
    )


def def_marlin():
    L, W = 4.82, 1.88
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.14, wheel_r=0.355, wb=2.9, tyre_w=0.26, end_r=0.13,
        top=[(-hl, 0.86), (-hl + 0.25, 0.94), (-1.35, 0.95), (0.95, 0.86), (1.9, 0.8), (hl, 0.7)],
        bottom=[(-hl, 0.4), (-hl + 0.6, 0.2), (hl - 0.7, 0.2), (hl, 0.32)],
        shoulder=[(-hl, 0.8), (0.0, 0.76), (hl, 0.6)],
        plan=[(-hl, 0.9), (-1.75, 1.0), (-0.9, 0.97), (0.8, 0.97), (1.5, 1.0), (hl, 0.9)],
        tuck_top=0.12, tuck_bot=0.05, crown=0.04, r_top=0.05, r_sh=0.035, r_bot=0.07,
        glass=dict(y_front=1.22, y_rear=-1.55, roof_f=0.2, roof_r=-0.95, roof=1.39, tumble=0.2, r=0.06,
                   pillars=[(-0.28, 0.12)], c_pillar=-1.25, ws_curve=1.5, bl_curve=1.4),
        lamps=dict(head_h=0.075, head_slant=0.035, grille_w=0.52, grille_h=0.13, grille_chrome=True, grille_bars=2,
                   intake_w=0.76, tail_bar=True, tail_z=0.9, tail_h=0.085),
        doors=[(1.0, 0.3, 0.86), (-0.28, 0.3, 0.9), (-1.38, 0.32, 0.92)],
        boot_lip=True, sill=True, flares=True,
    )


def def_scout():
    P = def_kestrel()
    P.update(W=1.9, ride=0.24, wheel_r=0.34, tyre_w=0.27, arch_gap=0.07, sill=False, flares=False)
    hl = P["L"] / 2
    P["top"] = [(-hl, 0.98), (-hl + 0.2, 1.06), (-1.2, 1.07), (0.9, 1.0), (1.55, 0.94), (hl, 0.74)]
    P["bottom"] = [(-hl, 0.5), (-hl + 0.45, 0.3), (hl - 0.55, 0.3), (hl, 0.44)]
    P["shoulder"] = [(-hl, 0.86), (0.0, 0.88), (hl, 0.68)]
    P["glass"] = dict(P["glass"], roof=1.56)
    P["lamps"] = dict(P["lamps"], tail_z=1.06)
    P["doors"] = [(0.95, 0.4, 1.0), (-0.38, 0.4, 1.03)]
    return P


def def_brute():
    L, W = 4.92, 1.96
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.14, wheel_r=0.365, wb=2.9, tyre_w=0.31, end_r=0.09, sill=True, flares=True,
        top=[(-hl, 0.86), (-hl + 0.12, 0.93), (-1.5, 0.94), (0.5, 0.92), (2.1, 0.88), (hl, 0.8)],
        bottom=[(-hl, 0.36), (-hl + 0.5, 0.2), (hl - 0.6, 0.2), (hl, 0.3)],
        shoulder=[(-hl, 0.78), (-1.6, 0.8), (0.4, 0.76), (hl, 0.74)],
        plan=[(-hl, 0.95), (-1.7, 1.0), (-0.6, 0.97), (1.2, 0.98), (hl, 0.95)],
        tuck_top=0.1, tuck_bot=0.08, crown=0.02, r_top=0.035, r_sh=0.02, r_bot=0.05,
        glass=dict(y_front=0.62, y_rear=-1.75, roof_f=-0.12, roof_r=-0.72, roof=1.34, tumble=0.18, r=0.05,
                   pillars=[], c_pillar=-0.95, ws_curve=1.2, bl_curve=1.05),
        lamps=dict(head_x=(0.5, 0.88), head_h=0.11, head_slant=0.0, head_z=0.78, drl=False,
                   grille_w=0.9, grille_h=0.2, grille_z=0.66, grille_chrome=True, grille_bars=1, intake_w=0.0,
                   tail_bar=False, tail_z=0.86, tail_h=0.1, tail_x=(0.18, 0.92)),
        doors=[(0.42, 0.3, 0.9), (-0.95, 0.3, 0.92)],
    )


def def_vanta():
    L, W = 4.48, 1.92
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.12, wheel_r=0.355, wb=2.62, tyre_w=0.29, end_r=0.13, flares=True,
        top=[(-hl, 0.8), (-hl + 0.18, 0.9), (-1.25, 0.92), (0.4, 0.8), (1.5, 0.68), (hl, 0.48)],
        bottom=[(-hl, 0.32), (-hl + 0.5, 0.16), (hl - 0.6, 0.16), (hl, 0.24)],
        shoulder=[(-hl, 0.74), (-1.3, 0.76), (0.2, 0.64), (1.4, 0.6), (hl, 0.42)],
        plan=[(-hl, 0.84), (-1.55, 1.0), (-0.9, 0.94), (0.4, 0.92), (1.3, 1.0), (1.9, 0.94), (hl, 0.74)],
        tuck_top=0.16, tuck_bot=0.05, crown=0.05, r_top=0.08, r_sh=0.05, r_bot=0.05,
        glass=dict(y_front=0.78, y_rear=-1.5, roof_f=-0.12, roof_r=-0.7, roof=1.26, tumble=0.26, r=0.08,
                   pillars=[], c_pillar=-0.9, ws_curve=1.6, bl_curve=1.2, roof_mat="paint"),
        lamps=dict(head_x=(0.42, 0.88), head_h=0.065, head_slant=0.05, grille_w=0.38, grille_h=0.08, grille_z=0.3,
                   intake_w=0.8, intake_z=0.22, intake_h=0.07, tail_z=0.74, tail_h=0.06, tail_x=(0.45, 0.9), tail_bar=True),
        doors=[(0.62, 0.26, 0.78), (-0.75, 0.26, 0.84)],
    )


def def_halcyon():
    L, W = 4.62, 2.04
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.1, wheel_r=0.365, wb=2.72, tyre_w=0.33, end_r=0.16, flares=True,
        top=[(-hl, 0.86), (-hl + 0.2, 0.96), (-1.25, 0.94), (-0.2, 0.76), (1.2, 0.64), (hl, 0.42)],
        bottom=[(-hl, 0.3), (-hl + 0.45, 0.13), (hl - 0.55, 0.13), (hl, 0.2)],
        shoulder=[(-hl, 0.72), (-1.3, 0.82), (-0.3, 0.6), (1.35, 0.6), (hl, 0.36)],
        plan=[(-hl, 0.86), (-1.5, 1.0), (-0.6, 0.88), (0.6, 0.88), (1.35, 1.0), (2.0, 0.92), (hl, 0.72)],
        tuck_top=0.18, tuck_bot=0.06, crown=0.05, r_top=0.14, r_sh=0.2, r_bot=0.08,
        glass=dict(y_front=1.05, y_rear=-1.25, roof_f=0.12, roof_r=-0.45, roof=1.13, tumble=0.3, r=0.1,
                   pillars=[], c_pillar=-0.4, ws_curve=1.7, bl_curve=1.1, roof_mat="paint"),
        lamps=dict(head_x=(0.45, 0.9), head_h=0.055, head_slant=0.06, grille_w=0.0, intake_w=0.86, intake_z=0.2,
                   intake_h=0.09, tail_bar=True, tail_z=0.8, tail_h=0.05, tail_x=(0.5, 0.9)),
        doors=[(0.9, 0.22, 0.72), (-0.42, 0.22, 0.8)],
    )


def def_stiletto():
    # Wedge hypercar: knife-edged facets, cab-forward canopy, huge intakes.
    L, W = 4.7, 2.06
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.09, wheel_r=0.37, wb=2.74, tyre_w=0.35, end_r=0.06, step=0.1,
        top=dict(lin=[(-hl, 0.86), (-hl + 0.08, 0.92), (-1.8, 0.93), (-0.6, 0.86), (0.6, 0.74), (1.6, 0.6), (hl - 0.1, 0.42), (hl, 0.38)]),
        bottom=dict(lin=[(-hl, 0.3), (-hl + 0.4, 0.12), (hl - 0.45, 0.12), (hl, 0.17)]),
        shoulder=dict(lin=[(-hl, 0.7), (-1.4, 0.74), (0.0, 0.6), (1.4, 0.48), (hl, 0.3)]),
        plan=dict(lin=[(-hl, 0.9), (-1.7, 1.0), (-1.0, 0.98), (-0.2, 0.9), (0.6, 0.9), (1.3, 0.99), (1.9, 0.95), (hl, 0.78)]),
        tuck_top=0.22, tuck_bot=0.07, crown=0.03, r_top=0.018, r_sh=0.012, r_bot=0.03, end_top=0.3,
        glass=dict(y_front=1.2, y_rear=-1.9, roof_f=0.15, roof_r=-0.35, roof=1.12, tumble=0.36, r=0.02, crown=0.015,
                   pillars=[], c_pillar=-0.45, ws_curve=1.05, bl_curve=1.0, roof_mat="paint", inset=0.04, deck_y=-0.6),
        lamps=dict(head_x=(0.38, 0.93), head_h=0.045, head_slant=0.075, head_z=0.5, grille_w=0.0,
                   intake_w=0.0, tail_bar=False, tail_z=0.84, tail_h=0.045, tail_x=(0.35, 0.92)),
        doors=[(1.05, 0.2, 0.62)],
    )


def def_goliath():
    # Lifted crew-cab pickup.
    L, W = 5.6, 2.16
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.42, wheel_r=0.5, wb=3.4, tyre_w=0.38, end_r=0.08, arch_gap=0.1,
        top=dict(lin=[(-hl, 1.42), (-hl + 0.06, 1.48), (0.9, 1.48), (1.6, 1.44), (hl - 0.05, 1.4), (hl, 1.34)]),
        bottom=dict(lin=[(-hl, 0.72), (-hl + 0.4, 0.6), (hl - 0.5, 0.6), (hl, 0.7)]),
        shoulder=dict(lin=[(-hl, 1.3), (hl, 1.3)]),
        plan=dict(lin=[(-hl, 0.97), (-hl + 0.2, 1.0), (hl - 0.3, 1.0), (hl, 0.95)]),
        tuck_top=0.05, tuck_bot=0.03, crown=0.02, r_top=0.03, r_sh=0.02, r_bot=0.04,
        glass=dict(y_front=1.25, y_rear=-0.62, roof_f=0.62, roof_r=-0.5, roof=2.18, tumble=0.1, r=0.05,
                   pillars=[(0.1, 0.12)], c_pillar=-0.48, ws_curve=1.2, bl_curve=3.0, inset=0.03),
        lamps=dict(head_x=(0.5, 0.94), head_h=0.12, head_slant=0.0, head_z=1.4, drl=True,
                   grille_w=0.78, grille_h=0.34, grille_z=1.18, grille_chrome=True, grille_bars=2, grille_t=0.02,
                   intake_w=0.6, intake_z=0.86, intake_h=0.1, tail_z=1.38, tail_h=0.3, tail_x=(0.86, 0.97)),
        doors=[(1.22, 0.66, 1.42), (0.1, 0.66, 1.44), (-0.62, 0.66, 1.44)],
        bed=(-0.68, -hl + 0.08, 0.07),
    )


def def_warden():
    L, W = 4.98, 2.08
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.32, wheel_r=0.43, wb=2.96, tyre_w=0.34, end_r=0.07, arch_gap=0.09,
        top=dict(lin=[(-hl, 1.22), (-hl + 0.06, 1.28), (1.1, 1.27), (2.0, 1.22), (hl - 0.06, 1.16), (hl, 1.1)]),
        bottom=dict(lin=[(-hl, 0.56), (-hl + 0.35, 0.46), (hl - 0.45, 0.46), (hl, 0.56)]),
        shoulder=dict(lin=[(-hl, 1.08), (hl, 1.04)]),
        plan=dict(lin=[(-hl, 0.97), (-hl + 0.15, 1.0), (hl - 0.25, 1.0), (hl, 0.94)]),
        tuck_top=0.06, tuck_bot=0.04, crown=0.02, r_top=0.02, r_sh=0.015, r_bot=0.03,
        glass=dict(y_front=1.2, y_rear=-2.32, roof_f=0.82, roof_r=-2.22, roof=1.98, tumble=0.1, r=0.04,
                   pillars=[(0.18, 0.2), (-0.95, 0.2)], c_pillar=-1.9, ws_curve=1.3, bl_curve=6.0, inset=0.03),
        lamps=dict(head_x=(0.5, 0.92), head_h=0.1, head_slant=0.0, head_z=1.12, drl=False,
                   grille_w=0.5, grille_h=0.26, grille_z=0.95, grille_t=0.02, intake_w=0.0,
                   tail_z=1.2, tail_h=0.24, tail_x=(0.84, 0.96)),
        doors=[(1.18, 0.5, 1.22), (0.18, 0.5, 1.24), (-0.95, 0.5, 1.24)],
    )


def def_mammoth():
    # Cab-over heavy box truck: a flat glass face, a huge bumper, a cargo box.
    L, W = 6.6, 2.34
    hl = L / 2
    cab_r = hl - 1.9
    return dict(
        L=L, W=W, ride=0.48, wheel_r=0.55, wb=3.7, tyre_w=0.4, end_r=0.1, arch_gap=0.09, step=0.12,
        top=dict(lin=[(-hl, 1.32), (cab_r - 0.12, 1.32), (cab_r, 2.85), (hl - 0.25, 2.88), (hl, 2.6)]),
        bottom=dict(lin=[(-hl, 0.92), (hl - 0.3, 0.82), (hl, 0.88)]),
        shoulder=dict(lin=[(-hl, 1.2), (cab_r - 0.12, 1.2), (cab_r, 1.55), (hl, 1.55)]),
        plan=dict(lin=[(-hl, 0.94), (cab_r - 0.12, 0.94), (cab_r, 1.0), (hl - 0.15, 1.0), (hl, 0.96)]),
        tuck_top=dict(lin=[(-hl, 0.02), (cab_r - 0.1, 0.02), (cab_r, 0.1), (hl, 0.12)]),
        tuck_bot=0.02, crown=0.03, r_top=0.08, r_sh=0.03, r_bot=0.04, end_top=0.15,
        glass=None,
        lamps=dict(head_x=(0.62, 0.96), head_h=0.14, head_slant=0.0, head_z=1.16, drl=False,
                   grille_w=0.7, grille_h=0.5, grille_z=1.5, grille_t=0.025, grille_chrome=True, grille_bars=4,
                   intake_w=0.0, tail_z=1.3, tail_h=0.16, tail_x=(0.7, 0.92)),
        cab_r=cab_r,
    )


# Civilian bodies (lighter detail, distinct silhouettes).

def def_civ_compact():
    P = def_kestrel()
    P.update(L=3.7, W=1.72, wb=2.4, wheel_r=0.3, tyre_w=0.22)
    hl = P["L"] / 2
    P["top"] = [(-hl, 0.92), (-hl + 0.18, 1.0), (-1.1, 1.0), (0.8, 0.94), (1.4, 0.86), (hl, 0.68)]
    P["bottom"] = [(-hl, 0.42), (-hl + 0.4, 0.22), (hl - 0.5, 0.22), (hl, 0.36)]
    P["shoulder"] = [(-hl, 0.8), (hl, 0.62)]
    P["plan"] = [(-hl, 0.9), (-hl + 0.35, 0.99), (hl - 0.5, 1.0), (hl, 0.86)]
    P["glass"] = dict(P["glass"], y_front=0.98, y_rear=-1.78, roof_f=0.1, roof_r=-1.5, roof=1.52, c_pillar=-1.45,
                      pillars=[(-0.35, 0.1)])
    P["doors"] = [(0.88, 0.32, 0.94)]
    return P


def def_civ_sedan():
    P = def_marlin()
    P["lamps"] = dict(P["lamps"], grille_chrome=False, tail_bar=False, tail_h=0.1)
    P["r_sh"] = 0.08
    return P


def def_civ_taxi():
    P = def_civ_sedan()
    P["taxi"] = True
    return P


def def_civ_suv():
    P = def_warden()
    P.update(L=4.7, W=1.94, ride=0.24, wheel_r=0.38, wb=2.8, tyre_w=0.28, end_r=0.14)
    hl = P["L"] / 2
    P["top"] = [(-hl, 1.1), (-hl + 0.12, 1.16), (0.9, 1.12), (1.8, 1.02), (hl, 0.88)]
    P["bottom"] = [(-hl, 0.5), (-hl + 0.4, 0.34), (hl - 0.5, 0.34), (hl, 0.46)]
    P["shoulder"] = [(-hl, 1.0), (hl, 0.86)]
    P["plan"] = [(-hl, 0.92), (-hl + 0.3, 1.0), (hl - 0.4, 1.0), (hl, 0.88)]
    P.update(r_top=0.07, r_sh=0.06, r_bot=0.06, tuck_top=0.1)
    P["glass"] = dict(y_front=1.0, y_rear=-2.25, roof_f=0.45, roof_r=-2.0, roof=1.7, tumble=0.14, r=0.07,
                      pillars=[(0.0, 0.14), (-1.1, 0.12)], c_pillar=-1.9, ws_curve=1.5, bl_curve=2.0)
    P["lamps"] = dict(head_x=(0.48, 0.9), head_h=0.09, head_slant=0.03, head_z=1.0, grille_w=0.5, grille_h=0.16,
                      grille_z=0.82, intake_w=0.7, intake_z=0.5, tail_z=1.08, tail_h=0.14, tail_x=(0.7, 0.92))
    P["doors"] = [(1.0, 0.42, 1.1), (0.0, 0.42, 1.12), (-1.15, 0.42, 1.12)]
    return P


def def_civ_van():
    L, W = 5.3, 2.0
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.2, wheel_r=0.36, wb=3.3, tyre_w=0.26, end_r=0.12,
        top=[(-hl, 2.2), (-hl + 0.1, 2.28), (1.2, 2.3), (1.85, 1.95), (2.15, 1.15), (hl, 0.95)],
        bottom=[(-hl, 0.42), (-hl + 0.3, 0.3), (hl - 0.5, 0.3), (hl, 0.4)],
        shoulder=[(-hl, 1.0), (1.6, 1.0), (hl, 0.8)],
        plan=[(-hl, 0.97), (-hl + 0.15, 1.0), (hl - 0.5, 1.0), (hl, 0.9)],
        tuck_top=dict(lin=[(-hl, 0.06), (1.2, 0.06), (2.0, 0.18), (hl, 0.12)]), tuck_bot=0.03, crown=0.03,
        r_top=0.08, r_sh=0.05, r_bot=0.05,
        glass=None,
        lamps=dict(head_x=(0.55, 0.93), head_h=0.1, head_slant=0.02, head_z=0.98, grille_w=0.55, grille_h=0.16,
                   grille_z=0.75, intake_w=0.8, intake_z=0.45, tail_z=1.2, tail_h=0.4, tail_x=(0.88, 0.97)),
        van=True,
    )


def def_civ_box():
    P = def_mammoth()
    P.update(L=6.4, W=2.24, wb=3.6, wheel_r=0.48, tyre_w=0.32, ride=0.4)
    hl = P["L"] / 2
    cab_r = hl - 1.8
    P["cab_r"] = cab_r
    P["top"] = dict(lin=[(-hl, 1.2), (cab_r - 0.12, 1.2), (cab_r, 2.6), (hl - 0.3, 2.62), (hl, 2.3)])
    P["bottom"] = dict(lin=[(-hl, 0.82), (hl - 0.3, 0.72), (hl, 0.78)])
    P["shoulder"] = dict(lin=[(-hl, 1.1), (cab_r - 0.12, 1.1), (cab_r, 1.4), (hl, 1.4)])
    P["plan"] = dict(lin=[(-hl, 0.94), (cab_r - 0.12, 0.94), (cab_r, 1.0), (hl - 0.15, 1.0), (hl, 0.95)])
    P["tuck_top"] = dict(lin=[(-hl, 0.02), (cab_r - 0.1, 0.02), (cab_r, 0.12), (hl, 0.14)])
    P["lamps"] = dict(P["lamps"], grille_chrome=False, grille_h=0.35, grille_z=1.3, head_z=1.04)
    P["civ"] = True
    return P


def def_civ_bus():
    L, W = 10.4, 2.5
    hl = L / 2
    return dict(
        L=L, W=W, ride=0.28, wheel_r=0.5, wb=5.6, tyre_w=0.32, end_r=0.16, step=0.22,
        top=dict(lin=[(-hl, 2.96), (hl - 0.2, 3.0), (hl, 2.9)]),
        bottom=dict(lin=[(-hl, 0.62), (-hl + 1.3, 0.42), (hl - 1.2, 0.42), (hl, 0.56)]),
        shoulder=dict(lin=[(-hl, 1.25), (hl, 1.25)]),
        plan=dict(lin=[(-hl, 0.98), (-hl + 0.2, 1.0), (hl - 0.2, 1.0), (hl, 0.97)]),
        tuck_top=0.08, tuck_bot=0.02, crown=0.04, r_top=0.14, r_sh=0.03, r_bot=0.04, end_top=0.2,
        glass=None,
        lamps=dict(head_x=(0.68, 0.94), head_h=0.12, head_slant=0.0, head_z=0.92, drl=False, grille_w=0.0,
                   intake_w=0.6, intake_z=0.62, intake_h=0.1, tail_z=1.1, tail_h=0.3, tail_x=(0.82, 0.95)),
        bus=True,
    )


BODIES = {
    "kestrel": def_kestrel, "marlin": def_marlin, "scout": def_scout, "brute": def_brute, "vanta": def_vanta,
    "goliath": def_goliath, "warden": def_warden, "halcyon": def_halcyon, "mammoth": def_mammoth,
    "stiletto": def_stiletto,
    "civ_compact": def_civ_compact, "civ_sedan": def_civ_sedan, "civ_taxi": def_civ_taxi, "civ_suv": def_civ_suv,
    "civ_van": def_civ_van, "civ_box": def_civ_box, "civ_bus": def_civ_bus,
}

# police body -> (base body, kit)
POLICE = {
    "police_patrol": ("marlin", "patrol"),
    "police_interceptor": ("vanta", "interceptor"),
    "police_heavy": ("warden", "heavy"),
}


# ---------------------------------------------------------------- per-body features


def features(name, P, m, body, glass, surf, out):
    hl, W2 = P["L"] / 2, P["W"] / 2
    ride = P["ride"]
    if P.get("doors"):
        seams(P, m, surf, out, P["doors"])
    if name in ("kestrel", "civ_compact"):
        mirrors(P, m, out)
        hood_lines(P, m, surf, out, 1.15, hl - 0.25, 0.45)
        out.append(box("roof_spoiler", (P["W"] * 0.7, 0.22, 0.04), (0, -hl + 0.3, P["glass"]["roof"] - 0.04), m["paint"], bevel=0.015))
        plate(P, m, out, z=0.62)
        exhaust(m, -0.5, -hl + 0.02, ride + 0.2, 0.03, 0.12, out)
    elif name == "scout":
        mirrors(P, m, out)
        arch_flares(P, m, surf, out, m["cladding"], width=0.1, thick=0.035)
        skirts(P, m, surf, out, m["cladding"], -0.95, 0.95, ride + 0.14, ride + 0.24)
        g = P["glass"]
        out += wing(m, P["W"] * 0.78, 0.3, (0, -hl + 0.32, g["roof"] - 0.02), angle=0.2, post_h=0.08, mat_key="paint", plates=True)
        out.append(box("roof_scoop", (0.38, 0.5, 0.08), (0, -0.3, g["roof"] + 0.04), m["paint"], bevel=0.03))
        out.append(box("roof_scoop_mouth", (0.3, 0.02, 0.05), (0, -0.05, g["roof"] + 0.045), m["liner"]))
        # Rally lamp pod on the bonnet.
        zf = top_z(P, hl - 0.35)
        out.append(box("lamp_pod", (1.0, 0.1, 0.16), (0, hl - 0.18, zf + 0.06), m["trim"], bevel=0.02))
        for k in range(4):
            x = -0.375 + k * 0.25
            out.append(ycyl("rally_lamp", 0.085, 0.07, (x, hl - 0.12, zf + 0.06), m["lamp_head"], 16))
        for sx in (-1, 1):
            out.append(box("mudflap", (0.24, 0.02, 0.24), (sx * (W2 - 0.18), -P["wb"] / 2 - P["wheel_r"] - 0.12, ride + 0.12), m["cladding"]))
        side_band(P, m, surf, out, 0.42, 0.56, -hl + 0.2, hl - 0.4, m["paint2"], slope=0.22)
        plate(P, m, out, z=0.7)
        exhaust(m, 0.55, -hl + 0.02, ride + 0.26, 0.05, 0.16, out)
    elif name in ("marlin", "civ_sedan", "civ_taxi"):
        mirrors(P, m, out)
        hood_lines(P, m, surf, out, 1.25, hl - 0.25, 0.5)
        # Chrome window line.
        if name == "marlin":
            side_band(P, m, surf, out, 0.855, 0.875, -1.4, 1.15, m["chrome"], slope=-0.06, nu=20)
            out += [box("lip_spoiler", (P["W"] * 0.66, 0.12, 0.03), (0, -hl + 0.12, top_z(P, -hl + 0.15) + 0.015), m["carbon"], bevel=0.01)]
            for sx in (-1, 1):
                exhaust(m, sx * 0.55, -hl + 0.04, ride + 0.18, 0.045, 0.14, out)
        else:
            exhaust(m, -0.55, -hl + 0.04, ride + 0.18, 0.035, 0.12, out)
        if name == "civ_taxi":
            g = P["glass"]
            out.append(box("taxi_sign", (0.62, 0.22, 0.14), (0, -0.25, g["roof"] + 0.08), m["sign"], bevel=0.03))
            # Chequer band.
            for k in range(14):
                y0 = -1.5 + k * 0.2
                for row in (0, 1):
                    if (k + row) % 2 == 0:
                        for sd in (1, -1):
                            decal_add(out, decal(surf, "side", rect(y0, 0.56 + row * 0.07, y0 + 0.2, 0.63 + row * 0.07), m["trim"],
                                                 nu=1, nv=1, off=0.004, side=sd, name="chequer"))
        plate(P, m, out, z=0.6)
    elif name == "brute":
        mirrors(P, m, out, y=0.35)
        # Hood bulge with a scoop.
        bz = top_z(P, 1.0, 0.0)
        bulge = decal(surf, "top", rect(-0.32, 0.55, 0.32, 1.9), m["paint"], nu=4, nv=8, off=0.002, thick=0.05, name="bulge")
        decal_add(out, bulge)
        surf = Surface([body, glass, bulge])
        out.append(box("scoop", (0.42, 0.3, 0.09), (0, 0.85, bz + 0.07), m["paint"], bevel=0.025))
        out.append(box("scoop_mouth", (0.36, 0.02, 0.06), (0, 1.0, bz + 0.07), m["liner"]))
        stripes(P, m, surf, out, w=0.14, gap=0.12)
        # Ducktail and chrome bumpers.
        zr = top_z(P, -hl + 0.12)
        out.append(box("ducktail", (P["W"] * 0.86, 0.22, 0.05), (0, -hl + 0.12, zr + 0.03), m["paint"], bevel=0.02))
        for y, z in ((hl - 0.02, ride + 0.32), (-hl + 0.02, ride + 0.34)):
            hw, zb, zs, zt, tt, tb, crown = section_at(P, y)
            out.append(box("bumper", (hw * 2 - 0.04, 0.09, 0.09), (0, y, z), m["chrome"], bevel=0.03))
        side_band(P, m, surf, out, 0.36, 0.4, -1.9, 1.9, m["paint2"], nu=20)
        for sx in (-1, 1):
            exhaust(m, sx * 0.62, -hl + 0.02, ride + 0.16, 0.055, 0.16, out)
            exhaust(m, sx * 0.48, -hl + 0.02, ride + 0.16, 0.055, 0.16, out)
        plate(P, m, out, z=0.6)
    elif name == "vanta":
        mirrors(P, m, out)
        hood_lines(P, m, surf, out, 0.95, hl - 0.25, 0.36)
        for sx in (-1, 1):
            for k in range(3):
                y = 1.45 - k * 0.08
                decal_add(out, decal(surf, "top", rect(sx * 0.5 - 0.12, y - 0.018, sx * 0.5 + 0.12, y + 0.018), m["liner"], nu=3, nv=1, off=0.003))
            # Side vent behind the front wheel.
            decal_add(out, decal(surf, "side", quad((0.82, 0.42), (0.98, 0.44), (0.9, 0.62), (0.8, 0.6)), m["liner"], nu=2, nv=2, off=0.003, side=sx))
        out += wing(m, P["W"] * 0.66, 0.26, (0, -hl + 0.3, top_z(P, -hl + 0.3) + 0.12), angle=0.12, post_h=0.11, mat_key="carbon")
        skirts(P, m, surf, out, m["carbon"], -0.95, 0.95, 0.17, 0.24)
        decal_add(out, decal(surf, "front", rect(-0.8, 0.13, 0.8, 0.17), m["carbon"], nu=10, nv=1, off=0.002, thick=0.03, name="splitter"))
        for sx in (-1, 1):
            exhaust(m, sx * 0.15, -hl + 0.03, ride + 0.16, 0.05, 0.14, out)
        plate(P, m, out, z=0.52)
    elif name == "halcyon":
        mirrors(P, m, out, y=0.72)
        # Side intakes in the hips, engine louvres, a big diffuser.
        for sx in (-1, 1):
            decal_add(out, decal(surf, "side", quad((-0.55, 0.36), (-0.2, 0.42), (-0.3, 0.68), (-0.62, 0.62)), m["liner"], nu=4, nv=3,
                                 off=0.003, side=sx, name="hip_intake"))
        for k in range(5):
            y = -0.75 - k * 0.12
            decal_add(out, decal(surf, "top", rect(-0.42, y - 0.02, 0.42, y + 0.02), m["liner"], nu=6, nv=1, off=0.003, name="louvre"))
        out += wing(m, P["W"] * 0.72, 0.3, (0, -hl + 0.3, top_z(P, -hl + 0.3) + 0.2), angle=0.16, post_h=0.2, mat_key="carbon")
        for k in range(5):
            out.append(box("fin", (0.02, 0.4, 0.14), (-0.5 + k * 0.25, -hl + 0.22, ride + 0.1), m["carbon"]))
        skirts(P, m, surf, out, m["carbon"], -0.95, 0.95, 0.13, 0.2)
        decal_add(out, decal(surf, "front", rect(-0.85, 0.1, 0.85, 0.15), m["carbon"], nu=10, nv=1, off=0.002, thick=0.04, name="splitter"))
        for sx in (-1, 1):
            exhaust(m, sx * 0.12, -hl + 0.05, ride + 0.32, 0.06, 0.1, out)
        plate(P, m, out, z=0.48)
    elif name == "stiletto":
        mirrors(P, m, out, y=0.85, z=0.85)
        for sx in (-1, 1):
            # Huge door-to-hip intake: a dark scoop with a carbon blade on its leading edge.
            decal_add(out, decal(surf, "side", quad((-1.3, 0.3), (-0.28, 0.3), (-0.45, 0.74), (-1.3, 0.78)), m["liner"], nu=6, nv=3,
                                 off=0.003, side=sx, name="side_intake"))
            decal_add(out, decal(surf, "side", quad((-0.3, 0.28), (-0.22, 0.28), (-0.4, 0.76), (-0.48, 0.76)), m["carbon"], nu=1, nv=4,
                                 off=0.003, thick=0.03, side=sx, name="intake_blade"))
            decal_add(out, decal(surf, "front", quad((sx * 0.2, 0.2), (sx * 0.62, 0.22), (sx * 0.66, 0.29), (sx * 0.22, 0.27)), m["liner"],
                                 nu=4, nv=1, off=0.003, name="nose_intake"))
        decal_add(out, decal(surf, "front", rect(-0.18, 0.16, 0.18, 0.3), m["grille"], nu=3, nv=1, off=0.003, name="nose_vent"))
        # Bonnet vents and NACA ducts.
        for sx in (-1, 1):
            decal_add(out, decal(surf, "top", quad((sx * 0.18, 1.3), (sx * 0.5, 1.28), (sx * 0.46, 1.72), (sx * 0.26, 1.74)), m["liner"],
                                 nu=3, nv=3, off=0.003, name="bonnet_vent"))
        for k in range(6):
            y = -0.55 - k * 0.15
            decal_add(out, decal(surf, "top", rect(-0.5, y - 0.025, 0.5, y + 0.025), m["liner"], nu=6, nv=1, off=0.003, name="louvre",
                                 max_jump=0.3))
        # Hexagon-ish tail lamps: a full Y-shape of thin bars.
        zr = 0.84
        for sx in (-1, 1):
            decal_add(out, decal(surf, "rear", quad((sx * 0.35, zr - 0.05), (sx * 0.92, zr - 0.02), (sx * 0.92, zr + 0.0), (sx * 0.35, zr - 0.03)),
                                 m["lamp_tail"], nu=6, nv=1, off=0.012, name="tail_y"))
            decal_add(out, decal(surf, "rear", quad((sx * 0.7, zr - 0.14), (sx * 0.75, zr - 0.14), (sx * 0.62, zr - 0.04), (sx * 0.57, zr - 0.04)),
                                 m["lamp_tail"], nu=1, nv=2, off=0.012, name="tail_y"))
        decal_add(out, decal(surf, "rear", rect(-0.9, 0.22, 0.9, 0.5), m["grille"], nu=10, nv=2, off=0.003, name="rear_mesh"))
        out += wing(m, P["W"] * 0.8, 0.3, (0, -hl + 0.28, 1.12), angle=0.16, post_h=0.2, posts=0.22, mat_key="carbon")
        for k in range(7):
            out.append(box("fin", (0.02, 0.45, 0.18), (-0.75 + k * 0.25, -hl + 0.24, ride + 0.11), m["carbon"]))
        out.append(box("diffuser", (P["W"] * 0.86, 0.5, 0.04), (0, -hl + 0.26, ride + 0.02), m["carbon"]))
        skirts(P, m, surf, out, m["carbon"], -1.0, 1.0, 0.12, 0.18, thick=0.03)
        decal_add(out, decal(surf, "front", rect(-0.9, 0.1, 0.9, 0.15), m["carbon"], nu=10, nv=1, off=0.002, thick=0.05, name="splitter"))
        # Periscope roof scoop, quad exhaust in the centre.
        out.append(box("roof_scoop", (0.34, 0.6, 0.1), (0, -0.55, 1.08), m["carbon"], bevel=0.03))
        out.append(box("roof_scoop_mouth", (0.28, 0.02, 0.07), (0, -0.25, 1.1), m["liner"]))
        for sx in (-1, 1):
            for sz in (0, 1):
                exhaust(m, sx * 0.09, -hl + 0.06, ride + 0.42 + sz * 0.1, 0.045, 0.12, out)
        plate(P, m, out, z=0.6)
        return surf
    elif name == "goliath":
        # Open load bed: cut down into the body behind the cab, lined.
        bf, br, wall = P["bed"]
        c = box("bed_cut", (P["W"] - 2 * wall, bf - br, 1.0), (0, (bf + br) / 2, 1.16 + 0.5))
        cut(body, c, m["bed"])
        surf = Surface([body, glass])
        mirrors(P, m, out, style="truck", y=1.0, z=1.6)
        arch_flares(P, m, surf, out, m["cladding"], width=0.14, thick=0.05)
        skirts(P, m, surf, out, m["cladding"], -1.1, 1.1, 0.62, 0.72)
        g = P["glass"]
        # Roll bar and roof light bar.
        for sx in (-1, 1):
            out.append(tube("rollbar", (sx * (W2 - 0.12), -0.72, 1.46), (sx * (W2 - 0.16), -0.85, 2.05), 0.04, m["chrome"]))
        out.append(tube("rollbar_top", (-(W2 - 0.16), -0.85, 2.05), ((W2 - 0.16), -0.85, 2.05), 0.04, m["chrome"]))
        lightbar(m, out, 0.4, g["roof"] + 0.05, P["W"] * 0.62, police=False, n=6, depth=0.14)
        # Side steps, tow hitch.
        for sx in (-1, 1):
            out.append(box("step", (0.14, 1.9, 0.05), (sx * (W2 + 0.03), 0.3, 0.6), m["trim"], bevel=0.015))
        out.append(box("hitch", (0.12, 0.25, 0.1), (0, -hl - 0.1, 0.62), m["chrome"]))
        hw, zb, zs, zt, tt, tb, crown = section_at(P, hl - 0.05)
        out.append(box("bumper", (P["W"] * 0.96, 0.16, 0.22), (0, hl + 0.02, 0.8), m["trim"], bevel=0.03))
        out.append(box("bumper_r", (P["W"] * 0.96, 0.14, 0.2), (0, -hl - 0.01, 0.8), m["chrome"], bevel=0.03))
        exhaust(m, 0.7, -hl + 0.1, 0.62, 0.06, 0.2, out)
        plate(P, m, out, z=0.95)
    elif name == "warden":
        mirrors(P, m, out, style="truck", y=1.0, z=1.42)
        arch_flares(P, m, surf, out, m["cladding"], width=0.12, thick=0.045)
        # Armour plates on the doors.
        for (y0, y1) in ((0.22, 1.1), (-0.9, 0.14)):
            for sd in (1, -1):
                decal_add(out, decal(surf, "side", rect(y0, 0.62, y1, 1.0), m["paint"], nu=6, nv=2, off=0.003, thick=0.025, side=sd, name="plate"))
        # Bull bar, roof rack, spare wheel, snorkel.
        hl_ = hl
        for sx in (-1, 1):
            out.append(tube("bull_post", (sx * 0.55, hl_ + 0.1, 0.45), (sx * 0.55, hl_ + 0.12, 1.18), 0.045, m["trim"]))
        out.append(tube("bull_top", (-0.55, hl_ + 0.12, 1.18), (0.55, hl_ + 0.12, 1.18), 0.045, m["trim"]))
        out.append(tube("bull_mid", (-0.8, hl_ + 0.1, 0.7), (0.8, hl_ + 0.1, 0.7), 0.05, m["trim"]))
        g = P["glass"]
        for sx in (-1, 1):
            out.append(tube("rack_rail", (sx * 0.8, 0.7, g["roof"] + 0.12), (sx * 0.8, -2.0, g["roof"] + 0.12), 0.025, m["trim"]))
        for k in range(5):
            y = 0.6 - k * 0.62
            out.append(tube("rack_bar", (-0.8, y, g["roof"] + 0.12), (0.8, y, g["roof"] + 0.12), 0.02, m["trim"]))
        sp = cyl("spare", 0.38, 0.24, (0, 0, 0), m["tyre"], 20)
        sp.rotation_euler = (math.pi / 2, 0, 0)
        sp.location = (0, -hl - 0.0, 1.0)
        out.append(sp)
        sp2 = cyl("spare_hub", 0.22, 0.26, (0, 0, 0), m["rim"], 16)
        sp2.rotation_euler = (math.pi / 2, 0, 0)
        sp2.location = (0, -hl - 0.0, 1.0)
        out.append(sp2)
        out.append(tube("snorkel", (W2 + 0.04, 1.4, 0.9), (W2 + 0.04, 1.32, 1.95), 0.05, m["trim"]))
        out.append(box("snorkel_head", (0.12, 0.18, 0.12), (W2 + 0.04, 1.36, 2.0), m["trim"], bevel=0.02))
        lightbar(m, out, 1.0, g["roof"] + 0.12, 1.1, police=False, n=4, depth=0.12)
        plate(P, m, out, z=0.7)
    elif name == "mammoth" or name == "civ_box":
        cab_r = P["cab_r"]
        civ = P.get("civ", False)
        # Windscreen and side windows as raised glass panels on the cab.
        decal_add(out, decal(surf, "front", rect(-W2 * 0.86, 1.92, W2 * 0.86, (2.62 if not civ else 2.4)), m["glass"], nu=8, nv=2,
                             off=0.004, thick=0.01, name="windscreen"))
        for sd in (1, -1):
            decal_add(out, decal(surf, "side", rect(cab_r + 0.9, 1.9, hl - 0.25, 2.55 if not civ else 2.35), m["glass"], nu=3, nv=2, off=0.004,
                                 thick=0.008, side=sd, name="side_window"))
        seams(P, m, surf, out, [(cab_r + 0.25, 1.0, 2.6 if not civ else 2.4), (hl - 0.18, 1.0, 2.4)])
        # Cargo box.
        bw = P["W"] * (0.995 if not civ else 1.0)
        box_h = 2.0 if not civ else 1.9
        out.append(box("cargo", (bw, cab_r + hl - 0.14, box_h), (0, (cab_r - 0.18 - hl) / 2 + 0.02, 1.32 + box_h / 2),
                       m["paint2"], bevel=0.03))
        for k in range(7):
            y = -hl + 0.2 + k * (cab_r + hl - 0.4) / 6
            for sx in (-1, 1):
                out.append(box("rib", (0.03, 0.06, box_h - 0.06), (sx * bw / 2, y, 1.32 + box_h / 2), m["chrome"] if not civ else m["trim"]))
        out.append(box("rear_door_line", (0.02, 0.02, box_h - 0.1), (0, -hl - 0.0, 1.32 + box_h / 2), m["seam"]))
        # Chassis, tanks, bumper, mirrors.
        out.append(box("chassis", (1.0, P["L"] - 0.6, 0.25), (0, 0, 0.82), m["trim"]))
        for sx in (-1, 1):
            out.append(ycyl("tank", 0.28, 1.1, (sx * (W2 - 0.32), cab_r - 0.95, 0.9), m["chrome"] if not civ else m["trim"], 18))
            out.append(box("mirror", (0.06, 0.14, 0.42), (sx * (W2 + 0.2), hl - 0.3, 2.15), m["trim"], bevel=0.02))
            out.append(tube("mirror_arm", (sx * W2, hl - 0.3, 2.3), (sx * (W2 + 0.2), hl - 0.3, 2.3), 0.02, m["chrome"]))
            out.append(box("step", (0.3, 0.4, 0.05), (sx * (W2 - 0.1), hl - 0.9, 0.75), m["trim"]))
        out.append(box("bumper", (P["W"] * 1.0, 0.24, 0.42), (0, hl + 0.04, 0.95), m["chrome"] if not civ else m["trim"], bevel=0.04))
        out.append(box("rear_bar", (P["W"] * 0.9, 0.1, 0.12), (0, -hl - 0.05, 0.78), m["trim"]))
        out.append(box("visor", (P["W"] * 0.9, 0.3, 0.05), (0, hl + 0.05, 2.7 if not civ else 2.48), m["trim"]))
        if not civ:
            out.append(tube("stack", (W2 - 0.12, cab_r + 0.02, 1.0), (W2 - 0.12, cab_r + 0.02, 3.3), 0.07, m["chrome"]))
            out.append(cyl("stack_cap", 0.075, 0.08, (W2 - 0.12, cab_r + 0.02, 3.3), m["liner"], 12))
            out.append(box("roof_lamps", (1.1, 0.12, 0.08), (0, hl - 0.15, 2.92), m["trim"]))
            for k in range(5):
                out.append(box("marker", (0.12, 0.05, 0.05), (-0.44 + k * 0.22, hl - 0.09, 2.92), m["lamp_amber"]))
            arch_flares(P, m, surf, out, m["cladding"], width=0.12, thick=0.05, a0=0.0, a1=math.pi)
        plate(P, m, out, z=1.0)
    elif name == "civ_suv":
        mirrors(P, m, out, y=0.85)
        arch_flares(P, m, surf, out, m["cladding"], width=0.08, thick=0.02)
        g = P["glass"]
        for sx in (-1, 1):
            out.append(tube("rack_rail", (sx * 0.72, 0.3, g["roof"] + 0.06), (sx * 0.72, -1.9, g["roof"] + 0.06), 0.02, m["chrome"]))
        plate(P, m, out, z=0.72)
    elif name == "civ_van":
        # Cab glass: windscreen, door windows; a sliding-door line; roof bars.
        decal_add(out, decal(surf, "front", rect(-W2 * 0.84, 1.28, W2 * 0.84, 1.9), m["glass"], nu=8, nv=3, off=0.004, thick=0.008, name="windscreen"))
        for sd in (1, -1):
            decal_add(out, decal(surf, "side", quad((1.25, 1.18), (2.0, 1.18), (1.82, 1.85), (1.25, 1.88)), m["glass"], nu=3, nv=2, off=0.004,
                                 thick=0.006, side=sd, name="door_window"))
        seams(P, m, surf, out, [(2.1, 0.4, 1.5), (1.2, 0.4, 2.15), (-0.2, 0.4, 2.15), (-2.55, 0.42, 2.1)])
        mirrors(P, m, out, style="truck", y=1.95, z=1.25)
        side_band(P, m, surf, out, 0.9, 1.05, -2.6, 1.2, m["paint2"], nu=20)
        plate(P, m, out, z=0.6)
    elif name == "civ_bus":
        # Window band down both sides, front and rear glass, doors.
        for sd in (1, -1):
            decal_add(out, decal(surf, "side", rect(-hl + 0.4, 1.45, hl - 0.4, 2.6), m["glass"], nu=24, nv=2, off=0.004, thick=0.008, side=sd,
                                 name="windows"))
            for k in range(9):
                y = -hl + 1.4 + k * 1.0
                decal_add(out, decal(surf, "side", rect(y - 0.05, 1.42, y + 0.05, 2.62), m["trim"], nu=1, nv=2, off=0.014, side=sd, name="mullion"))
        decal_add(out, decal(surf, "front", rect(-W2 * 0.9, 1.25, W2 * 0.9, 2.7), m["glass"], nu=8, nv=2, off=0.004, thick=0.01, name="windscreen"))
        decal_add(out, decal(surf, "rear", rect(-W2 * 0.8, 1.8, W2 * 0.8, 2.6), m["glass"], nu=8, nv=2, off=0.004, thick=0.01))
        decal_add(out, decal(surf, "front", rect(-W2 * 0.6, 2.72, W2 * 0.6, 2.9), m["sign"], nu=6, nv=1, off=0.01, name="route_sign"))
        decal_add(out, decal(surf, "side", rect(hl - 2.0, 0.5, hl - 0.9, 2.6), m["glass"], nu=3, nv=4, off=0.012, side=1, name="door"))
        decal_add(out, decal(surf, "side", rect(-0.6, 0.5, 0.5, 2.6), m["glass"], nu=3, nv=4, off=0.012, side=1, name="door"))
        side_band(P, m, surf, out, 1.0, 1.25, -hl + 0.2, hl - 0.2, m["paint2"], nu=30)
        for sx in (-1, 1):
            out.append(box("mirror", (0.06, 0.12, 0.34), (sx * (W2 + 0.25), hl - 0.1, 2.3), m["trim"], bevel=0.02))
            out.append(tube("mirror_arm", (sx * W2, hl - 0.2, 2.6), (sx * (W2 + 0.25), hl - 0.1, 2.5), 0.02, m["trim"]))
    return surf


def police_kit(P, m, out, kind, surf):
    hl, W2 = P["L"] / 2, P["W"] / 2
    g = P["glass"]
    roof = g["roof"]
    y = (g["roof_r"] + g["roof_f"]) / 2 if kind != "heavy" else 0.2
    lightbar(m, out, y, roof + (0.06 if kind != "heavy" else 0.06), P["W"] * (0.62 if kind != "interceptor" else 0.5), police=True, n=6)
    zf = top_z(P, hl - 0.12)
    for sx in (-1, 1):
        out.append(box("strobe", (0.14, 0.03, 0.035), (sx * 0.24, hl + 0.0, zf - 0.2), m["beacon_red"] if sx < 0 else m["beacon_blue"]))
        out.append(box("strobe_r", (0.14, 0.03, 0.035), (sx * 0.3, -hl - 0.0, top_z(P, -hl + 0.12) - 0.05),
                       m["beacon_red"] if sx < 0 else m["beacon_blue"]))
    out.append(tube("antenna", (0.3, -hl + 0.6, top_z(P, -hl + 0.6)), (0.32, -hl + 0.62, top_z(P, -hl + 0.6) + 0.5), 0.006, m["trim"]))
    if kind == "patrol":
        # White doors and roof, navy bonnet/boot; a thin hi-vis stripe.
        side_band(P, m, surf, out, 0.32, 0.86, -1.32, 1.0, m["paint2"], slope=-0.04, nu=22)
        side_band(P, m, surf, out, 0.5, 0.56, -2.3, 2.3, m["beacon_blue"] if False else m["lamp_amber"], nu=30)
        hl_ = hl
        out.append(box("pushbar", (P["W"] * 0.55, 0.1, 0.32), (0, hl_ + 0.06, P["ride"] + 0.38), m["trim"], bevel=0.03))
        for sx in (-1, 1):
            out.append(box("pushbar_post", (0.06, 0.24, 0.06), (sx * 0.4, hl_ - 0.06, P["ride"] + 0.45), m["trim"]))
        out.append(box("spotlight", (0.1, 0.16, 0.1), (-(W2 - 0.25), g["y_front"] - 0.3, g["belt_f"] if "belt_f" in g else top_z(P, 1.0) + 0.16),
                       m["chrome"], bevel=0.03))
    elif kind == "interceptor":
        # Dark car, hi-vis chequer band along the sills.
        for k in range(16):
            y0 = -1.85 + k * 0.22
            for row in (0, 1):
                if (k + row) % 2 == 0:
                    for sd in (1, -1):
                        decal_add(out, decal(surf, "side", rect(y0, 0.34 + row * 0.08, y0 + 0.22, 0.42 + row * 0.08), m["paint2"], nu=1, nv=1,
                                             off=0.004, side=sd, name="chequer"))
        stripes(P, m, surf, out, w=0.1, gap=0.06)
    elif kind == "heavy":
        # Battenburg panels down the sides.
        for k in range(10):
            y0 = -2.2 + k * 0.42
            for row in (0, 1):
                mt = m["paint2"] if (k + row) % 2 == 0 else m["lamp_amber"]
                for sd in (1, -1):
                    decal_add(out, decal(surf, "side", rect(y0, 0.62 + row * 0.2, y0 + 0.42, 0.82 + row * 0.2), mt, nu=2, nv=1,
                                         off=0.033, side=sd, name="battenburg"))


# ---------------------------------------------------------------- stance


def stance(P, m, surf, out):
    """What makes a toy car look planted: body-colour flares that swell over
    the tyres, and a dark sill between the wheels that visually lowers the
    body. Driven by flags on the body definition."""
    wr = P["wheel_r"]
    if P.get("flares"):
        arch_flares(P, m, surf, out, m["paint"], width=0.07, thick=0.022, a0=0.05, a1=math.pi - 0.05)
    if P.get("sill"):
        zb = curve(P, "bottom", 0.0)
        axles = P.get("axles", (P["wb"] / 2, -P["wb"] / 2))
        y0 = min(axles) + wr + P.get("arch_gap", 0.045) + 0.1
        y1 = max(axles) - wr - P.get("arch_gap", 0.045) - 0.1
        skirts(P, m, surf, out, m["cladding"], y0, y1, zb + 0.01, zb + 0.11, thick=0.018)


# ---------------------------------------------------------------- build


DIMS = {}


def build(name, P, police=None):
    kit.reset()
    m = mats()
    out = []
    body = lower_body(P, m)
    arches(body, P, m)
    glass = glasshouse(P, m) if P.get("glass") else None
    surf = Surface([body] + ([glass] if glass else []))
    surf = features(name if police is None else police[0], P, m, body, glass, surf, out) or surf
    stance(P, m, surf, out)
    common_lamps(P, m, surf, out, "std")
    if police:
        police_kit(P, m, out, police[1], surf)
    shade(body, 30)
    parts = [body] + ([glass] if glass else []) + [o for o in out if o is not None]
    ob = kit.join(name, parts)
    kit.export(name + ".glb", [ob])
    roof = P["glass"]["roof"] if P.get("glass") else max(curve(P, "top", y) for y in end_stations(P["L"]))
    DIMS[name] = {"L": P["L"], "W": P["W"], "roof": round(roof, 3), "wb": P["wb"], "wheel_r": P["wheel_r"],
                  "ride": P["ride"], "tyre_w": P.get("tyre_w", 0.27),
                  "axles": list(P.get("axles", (P["wb"] / 2, -P["wb"] / 2)))}
    print("BODY", name, len(ob.data.polygons), "faces")


def wheel(style):
    """A wheel centred on the origin, axle along X, radius 1, tyre width 0.44 (scaled in Godot)."""
    kit.reset()
    m = mats()
    dark_m = mat("rim_dark", (0.08, 0.08, 0.09), 0.35, 0.8)
    parts = []
    bm = bmesh.new()
    if style == "offroad":
        prof = [(0.62, -0.44), (0.9, -0.47), (0.97, -0.42), (1.0, -0.3), (1.0, 0.3), (0.97, 0.42), (0.9, 0.47), (0.62, 0.44)]
    else:
        prof = [(0.66, -0.42), (0.9, -0.44), (0.97, -0.38), (1.0, -0.22), (1.0, 0.22), (0.97, 0.38), (0.9, 0.44), (0.66, 0.42)]
    segs = 32
    rings = []
    for i in range(segs):
        a = i * 2 * math.pi / segs
        rings.append([bm.verts.new((w * 0.5, r * math.cos(a), r * math.sin(a))) for r, w in prof])
    for i in range(segs):
        r0, r1 = rings[i], rings[(i + 1) % segs]
        for k in range(len(prof) - 1):
            bm.faces.new((r0[k], r0[k + 1], r1[k + 1], r1[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    t = kit.new_obj("tyre", bm, m["tyre"])
    for p in t.data.polygons:
        p.use_smooth = True
    parts.append(t)
    # Tread: grooves (or chunky lugs for the off-road tyre).
    if style == "offroad":
        for i in range(18):
            a = i * 2 * math.pi / 18
            for side in (-1, 1):
                lug = box("lug", (0.2, 0.2, 0.06), (0, 0, 0), m["tyre"])
                lug.location = (side * 0.12 + (0.05 if i % 2 else -0.05), math.cos(a) * 1.0, math.sin(a) * 1.0)
                lug.rotation_euler = (a - math.pi / 2, 0, 0)
                parts.append(lug)
    rim_r = 0.7 if style != "offroad" else 0.62
    wall_m = mat("tyre_wall", (0.07, 0.07, 0.07), 0.8)
    disc_m = mat("disc", (0.32, 0.32, 0.33), 0.45, 0.8)
    # Sidewall: a raised band so the tyre reads as a tyre, not a black disc.
    for sx in (-1, 1):
        parts.append(annulus("sidewall", rim_r + 0.04, 0.9, sx * 0.235, wall_m))
    # Deep, dark wheel well behind the spokes: gaps read as depth, not grey.
    face = xcyl("rimface", rim_r * 0.98, 0.04, (-0.14, 0, 0), m["liner"], 32)
    parts.append(face)
    # Rim lip: a ring (it used to be a solid disc that hid the spokes, so
    # every alloy read as a flat silver hubcap).
    parts.append(annulus("lip", rim_r * 0.9, rim_r, 0.17, m["rim"]))
    parts.append(annulus("lip_in", rim_r * 0.9, rim_r, 0.13, m["rim"]))

    # Brake disc behind the spokes (the caliper is added in Godot: it mustn't spin).
    parts.append(xcyl("disc", rim_r * 0.8, 0.04, (-0.02, 0, 0), disc_m, 28))
    parts.append(xcyl("disc_hat", rim_r * 0.36, 0.05, (0.0, 0, 0), m["rim_dark"] if "rim_dark" in m else dark_m, 20))
    spokes = {"five": 5, "split": 10, "blade": 7, "mesh": 16, "steel": 0, "turbine": 12, "offroad": 6, "deep": 6}[style]
    for i in range(spokes):
        a = i * 2 * math.pi / spokes
        w = {"five": 0.15, "mesh": 0.05, "split": 0.08, "turbine": 0.09, "offroad": 0.16, "deep": 0.12}.get(style, 0.09)
        s = box("spoke", (0.06, w, rim_r * 0.92), (0.0, 0, 0), m["rim"] if style != "offroad" else dark_m, bevel=0.012)
        s.location = (0.16, math.sin(a) * rim_r * 0.47, math.cos(a) * rim_r * 0.47)
        tilt = {"blade": 0.35, "turbine": 0.6}.get(style, 0.0)
        s.rotation_euler = (-a, 0.0, tilt) if tilt else (-a, 0, 0)
        parts.append(s)
    if style == "deep":
        dish = cyl("dish", rim_r, 0.12, (0, 0, 0), m["chrome"], 32, r2=rim_r * 0.86)
        dish.rotation_euler = (0, math.pi / 2, 0)
        dish.location = (0.06, 0, 0)
        parts.append(dish)
    if style == "steel":
        parts.append(xcyl("steel_disc", rim_r * 0.94, 0.05, (0.13, 0, 0), m["rim"], 28))
        for i in range(8):
            a = i * math.pi / 4
            parts.append(xcyl("hole", 0.08, 0.06, (0.145, math.sin(a) * 0.46, math.cos(a) * 0.46), m["trim"], 10))
    if style == "offroad":
        parts.append(xcyl("beadlock", rim_r * 1.0, 0.05, (0.17, 0, 0), dark_m, 32))
        for i in range(16):
            a = i * math.pi / 8
            parts.append(xcyl("bolt", 0.025, 0.03, (0.2, math.sin(a) * rim_r * 0.93, math.cos(a) * rim_r * 0.93), m["chrome"], 6))
    parts.append(xcyl("hub", 0.16, 0.05, (0.165, 0, 0), m["rim"], 16))
    parts.append(xcyl("hub_cap", 0.08, 0.02, (0.2, 0, 0), m["chrome"], 12))
    ob = kit.join("wheel", parts)
    kit.export("wheel_%s.glb" % style, [ob])


def annulus(name, r0, r1, x, material, segs=32):
    """A flat ring in the YZ plane at x, facing +X (or -X when x < 0)."""
    bm = bmesh.new()
    inner = [bm.verts.new((x, r0 * math.cos(a), r0 * math.sin(a))) for a in (i * 2 * math.pi / segs for i in range(segs))]
    outer = [bm.verts.new((x, r1 * math.cos(a), r1 * math.sin(a))) for a in (i * 2 * math.pi / segs for i in range(segs))]
    for i in range(segs):
        j = (i + 1) % segs
        f = bm.faces.new((inner[i], inner[j], outer[j], outer[i]))
        if (f.normal.x > 0) != (x > 0):
            f.normal_flip()
    return kit.new_obj(name, bm, material)


def preview(path, names):
    kit.reset()
    tints = [(0.78, 0.77, 0.73), (0.08, 0.2, 0.45), (0.85, 0.42, 0.05), (0.55, 0.06, 0.04), (0.9, 0.45, 0.05),
             (0.12, 0.14, 0.16), (0.22, 0.26, 0.2), (0.88, 0.88, 0.9), (0.85, 0.7, 0.1), (0.6, 0.85, 0.12)]
    cols = 5
    for i, f in enumerate(names):
        bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, f + ".glb"))
        ob = bpy.context.selected_objects[0]
        ob.rotation_mode = "XYZ"
        col, row = i % cols, i // cols
        ob.location = (col * 7.0 - 14.0, row * -8.5, 0)
        ob.rotation_euler = (0, 0, math.radians(-125))
        for s in ob.material_slots:
            if not s.material:
                continue
            bsdf = s.material.node_tree.nodes.get("Principled BSDF") if s.material.node_tree else None
            if s.material.name == "paint":
                c = s.material.copy()
                c.diffuse_color = (*tints[i % len(tints)], 1)
                s.material = c
            elif bsdf:
                s.material.diffuse_color = bsdf.inputs["Base Color"].default_value
        d = DIMS.get(f) or json.load(open(os.path.join(OUT, "bodies.json")))[f]
        import mathutils
        rot = mathutils.Matrix.Rotation(math.radians(-125), 4, "Z")
        track = d["W"] - d["tyre_w"] - 0.05
        for k, (x, y) in enumerate([(1, 1), (-1, 1), (1, -1), (-1, -1)]):
            bpy.ops.import_scene.gltf(filepath=os.path.join(OUT, "wheel_five.glb"))
            w = bpy.context.selected_objects[0]
            w.rotation_mode = "XYZ"
            w.scale = (d["tyre_w"] / 0.44 * 1.0, d["wheel_r"], d["wheel_r"])
            ay = d["axles"][0] if y > 0 else d["axles"][1]
            off = rot @ Vector((x * track / 2, ay, d["wheel_r"]))
            w.location = Vector(ob.location) + off
            w.rotation_euler = (0, 0, math.radians(-125) + (0 if x > 0 else math.pi))
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
    sc.render.resolution_x, sc.render.resolution_y = 2000, 1100
    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 38
    cam = bpy.data.objects.new("cam", cam_data)
    sc.collection.objects.link(cam)
    rows = (len(names) + cols - 1) // cols
    cam.location = (0, -18 - rows * 4.0, 9 + rows * 2.5)
    cam.rotation_euler = (math.radians(64), 0, 0)
    sc.camera = cam
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.3, 0.32, 0.38)
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    jpath = os.path.join(OUT, "bodies.json")
    if os.path.exists(jpath):
        DIMS.update(json.load(open(jpath)))
    for name, fn in BODIES.items():
        if ONLY and name not in ONLY:
            continue
        build(name, fn())
    for name, (base, kind) in POLICE.items():
        if ONLY and name not in ONLY:
            continue
        build(name, BODIES[base](), (base, kind))
    if not ONLY or "wheels" in ONLY:
        for style in ("five", "split", "blade", "mesh", "steel", "turbine", "deep", "offroad"):
            wheel(style)
    with open(jpath, "w") as f:
        json.dump(DIMS, f, indent=1, sort_keys=True)
    # The same numbers for the game (the car catalogue sizes physics from them).
    with open(os.path.join(OUT, "body_dims.gd"), "w") as f:
        f.write("class_name BodyDims\nextends RefCounted\n## Generated by tools/blender/build_vehicles.py: real body dimensions (m). Do not edit.\n\n")
        f.write("const DIMS := " + json.dumps(DIMS, indent="\t", sort_keys=True) + "\n")
    if PREVIEW:
        names = [n for n in BODIES if not n.startswith("civ_")] if "civ" not in PREVIEW else [n for n in BODIES if n.startswith("civ_")] + list(POLICE)
        preview(PREVIEW, names)
    print("VEHICLES DONE")
