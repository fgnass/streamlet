import json, math, re, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

geo = json.load(open("geo.json"))
S = geo["cam"]["ortho_scale"]; R = 2048
def w2p(xy): return np.stack([(xy[:, 0] / S + 0.5) * R, (0.5 - xy[:, 1] / S) * R], 1)
def p2w(p): return np.stack([(p[:, 0] / R - 0.5) * S, (0.5 - p[:, 1] / R) * S], 1)

def raster(blades):
    im = Image.new("L", (R, R), 0); dr = ImageDraw.Draw(im)
    for verts, faces in blades:
        P = w2p(verts[:, :2])
        for f in faces: dr.polygon([tuple(P[i]) for i in f], fill=255)
    return im

def contours(im):
    """Marching squares on a slightly blurred image: closed loops in pixel coordinates."""
    a = np.asarray(im.filter(ImageFilter.GaussianBlur(1.5)), float) / 255
    a = np.pad(a, 1); th = 0.5
    b = a > th
    c = b[:-1, :-1] * 8 + b[:-1, 1:] * 4 + b[1:, 1:] * 2 + b[1:, :-1] * 1
    ys, xs = np.nonzero((c > 0) & (c < 15))
    def ip(p, q):
        (y0, x0), (y1, x1) = p, q; v0, v1 = a[y0, x0], a[y1, x1]
        t = (th - v0) / (v1 - v0); return (x0 + t * (x1 - x0) - 1, y0 + t * (y1 - y0) - 1)
    edges = {}
    table = {1: [(3, 2)], 2: [(2, 1)], 3: [(3, 1)], 4: [(1, 0)], 5: [(3, 0), (1, 2)], 6: [(2, 0)], 7: [(3, 0)],
             8: [(0, 3)], 9: [(0, 2)], 10: [(0, 1), (2, 3)], 11: [(0, 1)], 12: [(1, 3)], 13: [(1, 2)], 14: [(2, 3)]}
    for y, x in zip(ys, xs):
        corners = [(y, x), (y, x + 1), (y + 1, x + 1), (y + 1, x)]
        ekey = lambda e: (y, x, e)
        def eid(e):  # shared edge ids
            return {0: ("h", y, x), 1: ("v", y, x + 1), 2: ("h", y + 1, x), 3: ("v", y, x)}[e]
        for e0, e1 in table[c[y, x]]:
            edges[eid(e0)] = eid(e1)
    def pos(e):
        k, y, x = e
        return ip((y, x), (y, x + 1)) if k == "h" else ip((y, x), (y + 1, x))
    loops, seen = [], set()
    for s in list(edges):
        if s in seen: continue
        loop, e = [], s
        while e not in seen and e in edges:
            seen.add(e); loop.append(pos(e)); e = edges[e]
        if len(loop) > 50: loops.append(np.array(loop))
    return loops

def area(l): x, y = l[:, 0], l[:, 1]; return 0.5 * np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y)

def resample(l, n):
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(np.vstack([l, l[:1]]), axis=0), axis=1))]
    t = np.linspace(0, d[-1], n, endpoint=False)
    L = np.vstack([l, l[:1]])
    return np.stack([np.interp(t, d, L[:, 0]), np.interp(t, d, L[:, 1])], 1)

# --- target from the SVG (100 x 100, y down) ---
svg = open(sys.argv[1]).read()
dpath = re.search(r'd="([^"]+)"', svg).group(1)
outline_d, tri_d = dpath.split(" Z ", 1)
def bez(p0, c1, c2, p3, n=200):
    t = np.linspace(0, 1, n, endpoint=False)[:, None]
    return (1-t)**3*p0 + 3*(1-t)**2*t*c1 + 3*(1-t)*t**2*c2 + t**3*p3
def parse(d):
    pts, cur = [], None
    for cmd, args in re.findall(r'([MCLQ])([^MCLQZ]+)', d):
        n = np.array([float(v) for v in args.split()]).reshape(-1, 2)
        if cmd == "M": cur = n[0]
        elif cmd == "C": pts.append(bez(cur, n[0], n[1], n[2])); cur = n[2]
        elif cmd == "L": pts.append(np.linspace(cur, n[0], 60, endpoint=False)); cur = n[0]
        elif cmd == "Q":
            c1 = cur + 2/3*(n[0]-cur); c2 = n[1] + 2/3*(n[0]-n[1]); pts.append(bez(cur, c1, c2, n[1], 40)); cur = n[1]
    return np.vstack(pts)
T_out = parse(outline_d)
# The 3D model keeps a sharp play triangle: only the flat icon has rounded corners.
T_tri = parse("M41.5 34 L65 50 L41.5 66 L41.5 34")

blades = [(np.array(b["verts"]), b["faces"]) for b in geo["blades"].values()]
old = raster(blades); old.save("old_mask.png")
loops = sorted(contours(old), key=lambda l: -abs(area(l)))
O_out, O_tri = loops[0], loops[1]
print("loops:", [(len(l), round(abs(area(l)))) for l in loops[:4]])

# Same orientation for all loops (clockwise on screen, like the SVG outline)
def orient(l, ref_sign): return l if np.sign(area(l)) == ref_sign else l[::-1]
sgn = np.sign(area(T_out))
O_out, O_tri, T_tri = orient(O_out, sgn), orient(O_tri, sgn), orient(T_tri, sgn)

# --- alignment: SVG units -> pixels, by matching bounding boxes of the outlines ---
ob = np.r_[O_out.min(0), O_out.max(0)]; tb = np.r_[T_out.min(0), T_out.max(0)]
k = np.mean([(ob[2]-ob[0]) / (tb[2]-tb[0]), (ob[3]-ob[1]) / (tb[3]-tb[1])])
oc = (ob[:2] + ob[2:]) / 2; tc = (tb[:2] + tb[2:]) / 2
to_px = lambda p: (p - tc) * k + oc
T_out, T_tri = to_px(T_out), to_px(T_tri)
print("scale px/unit", round(k, 2), "bbox old", ob.round(), "bbox target", np.r_[T_out.min(0), T_out.max(0)].round())

# --- landmarks: corresponding points on both outlines ---
def landmarks(l, c):
    up = l[:, 1] < c[1]; lo = ~up
    idx = lambda m, key: np.flatnonzero(m)[np.argmin(key[m])]
    x, y = l[:, 0], l[:, 1]
    # notches: concave points; use the points closest to the center on the right (upper) and left (lower) side
    d = np.linalg.norm(l - c, axis=1)
    right_up = up & (x > c[0]); left_lo = lo & (x < c[0])
    return {
        "N1": idx(right_up, d), "tipR": idx(up, -x), "top": idx(up, y), "L": idx(up & (x < c[0]), x),
        "N2": idx(left_lo, d), "tipL": idx(lo, x), "bottom": idx(lo, -y), "R": idx(lo & (x > c[0]), -x)}
center = oc
lo_, lt_ = landmarks(O_out, center), landmarks(T_out, center)
order = ["N1", "tipR", "top", "L", "N2", "tipL", "bottom", "R"]
print("old landmarks", {k_: O_out[v].round() for k_, v in lo_.items()})
print("new landmarks", {k_: T_out[v].round() for k_, v in lt_.items()})

def piecewise(l, lm, per=60):
    out = []
    ids = [lm[o] for o in order]
    for a, b in zip(ids, ids[1:] + ids[:1]):
        seg = l[a:b + 1] if b > a else np.vstack([l[a:], l[:b + 1]])
        out.append(resample(seg, per)[:per] if len(seg) > 2 else np.repeat(seg[:1], per, 0))
    return np.vstack(out)
def piecewise_open(seg, n):
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(seg, axis=0), axis=1))]
    t = np.linspace(0, d[-1], n, endpoint=False)
    return np.stack([np.interp(t, d, seg[:, 0]), np.interp(t, d, seg[:, 1])], 1)
def pw(l, lm, per=60):
    ids = [lm[o] for o in order]; out = []
    for a, b in zip(ids, ids[1:] + ids[:1]):
        seg = l[a:b + 1] if b > a else np.vstack([l[a:], l[:b + 1]])
        out.append(piecewise_open(seg, per))
    return np.vstack(out)
A_out, B_out = pw(O_out, lo_), pw(T_out, lt_)

# triangle: corners = top-left, tip (rightmost), bottom-left
def tri_lm(l):
    x, y = l[:, 0], l[:, 1]; cx, cy = l.mean(0)
    return {"tl": int(np.argmin((x - cx) + (y - cy))), "tip": int(np.argmax(x)), "bl": int(np.argmin((x - cx) - (y - cy)))}
def pw_tri(l, lm, per=40):
    names = sorted(("tl", "tip", "bl"), key=lambda n_: lm[n_])
    while names[0] != "tl": names = names[1:] + names[:1]
    ids = [lm[n_] for n_ in names]; out = []
    for a, b in zip(ids, ids[1:] + ids[:1]):
        seg = l[a:b + 1] if b > a else np.vstack([l[a:], l[:b + 1]])
        out.append(piecewise_open(seg, per))
    return np.vstack(out), names
A_tri, na = pw_tri(O_tri, tri_lm(O_tri)); B_tri, nb = pw_tri(T_tri, tri_lm(T_tri))
assert na == nb, (na, nb)
print("triangle old corners", {n_: O_tri[i].round() for n_, i in tri_lm(O_tri).items()})

src = np.vstack([A_out, A_tri]); dst = np.vstack([B_out, B_tri])
disp = dst - src
print("max boundary shift (px of 2048):", round(np.abs(np.linalg.norm(disp, axis=1)).max(), 1),
      "mean:", round(np.linalg.norm(disp, axis=1).mean(), 1))

# --- thin-plate spline in normalized coordinates ---
def U(r2): return np.where(r2 > 0, 0.5 * r2 * np.log(r2 + 1e-30), 0)
sc = 1 / R
P = src * sc
n = len(P)
K = U(((P[:, None] - P[None]) ** 2).sum(-1))
lam = float(sys.argv[2]) if len(sys.argv) > 2 else 1e-5
A = np.zeros((n + 3, n + 3)); A[:n, :n] = K + lam * np.eye(n); A[:n, n] = 1; A[:n, n+1:] = P; A[n, :n] = 1; A[n+1:, :n] = P.T
rhs = np.zeros((n + 3, 2)); rhs[:n] = disp * sc
W = np.linalg.solve(A, rhs)
def warp(px):
    q = px * sc
    Kq = U(((q[:, None] - P[None]) ** 2).sum(-1))
    return px + (Kq @ W[:n] + W[n] + q @ W[n+1:]) / sc

# fold check: Jacobian determinant on a grid around the shape
g = np.stack(np.meshgrid(np.linspace(ob[0]-60, ob[2]+60, 120), np.linspace(ob[1]-60, ob[3]+60, 120)), -1).reshape(-1, 2)
h = 0.5
J = [(warp(g + [h, 0]) - warp(g - [h, 0])) / (2*h), (warp(g + [0, h]) - warp(g - [0, h])) / (2*h)]
det = J[0][:, 0] * J[1][:, 1] - J[0][:, 1] * J[1][:, 0]
print("jacobian det min/max:", round(det.min(), 3), round(det.max(), 3))

new_blades = []
for name, b in geo["blades"].items():
    v = np.array(b["verts"])
    pxy = warp(w2p(v[:, :2]))
    nv = v.copy(); nv[:, :2] = p2w(pxy)
    new_blades.append((nv, b["faces"]))
    b["new_verts"] = nv.tolist()
json.dump({n_: b["new_verts"] for n_, b in geo["blades"].items()}, open("new_verts.json", "w"))
new = raster(new_blades); new.save("new_mask.png")
# deviation of the new silhouette from the target
nl = sorted(contours(new), key=lambda l: -abs(area(l)))
def dev(a_, b_):
    d = np.sqrt(((a_[:, None] - b_[None]) ** 2).sum(-1)).min(1); return d.max(), d.mean()
print("new outline vs target  max/mean px:", [round(v_, 1) for v_ in dev(resample(nl[0], 800), resample(T_out, 1600))])
print("new triangle vs target max/mean px:", [round(v_, 1) for v_ in dev(resample(nl[1], 300), resample(T_tri, 600))])
np.save("target_px.npy", np.vstack([T_out, [[np.nan, np.nan]], T_tri]))
# overlay: old grey, new white, target outline red
ov = Image.new("RGB", (R, R), (0, 0, 0))
ov.paste((90, 90, 90), (0, 0), old); ov.paste((235, 235, 235), (0, 0), new)
dr = ImageDraw.Draw(ov)
for l in (T_out, T_tri): dr.line([tuple(p) for p in np.vstack([l, l[:1]])], fill=(255, 40, 40), width=3)
x0, y0, x1, y1 = (ob + [-80, -80, 80, 80]).astype(int)
ov.crop((x0, y0, x1, y1)).save("overlay.png")
