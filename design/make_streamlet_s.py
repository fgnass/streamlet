# Point-symmetric S: one half of the outline, the other half is the same half rotated by 180°.
# Few long cubic sweeps; at each smooth joint the two handles are on one line, so no dents.
import sys, math
out = sys.argv[1]
N1 = (62, 31)          # notch under the top arm
T1 = (87, 21)          # underside of the tip
T2 = (80, 8)           # top of the tip
L = (13, 40)           # leftmost point, tangent vertical
N2 = (38, 69)          # notch above the bottom arm (= N1 rotated)
def along(p, d, h):
    l = math.hypot(*d); return (p[0] + d[0] / l * h, p[1] + d[1] / l * h)
dT1 = (1, -1)          # direction at T1
dT2 = (-1, -0.3)       # direction at T2
half = [
    (along(N1, (1, -0.08), 9), along(T1, dT1, -7), T1),          # underside of the top arm
    (along(T1, dT1, 4), along(T2, dT2, -6), T2),                 # round tip
    (along(T2, dT2, 38), along(L, (0, -1), 27), L),              # one sweep over the top and around the left
    (along(L, (0, 1), 16), along(N2, (1, 0.45), -14), N2),       # down into the notch
]
rot = lambda p: (100 - p[0], 100 - p[1])
segs = half + [tuple(rot(p) for p in s) for s in half]

def check(p0, seg):
    # Sign changes of the curvature inside a segment are dents or bumps.
    (c1, c2, p3) = seg
    def d1(t): return [3*(1-t)**2*(c1[i]-p0[i]) + 6*(1-t)*t*(c2[i]-c1[i]) + 3*t*t*(p3[i]-c2[i]) for i in (0,1)]
    def d2(t): return [6*(1-t)*(c2[i]-2*c1[i]+p0[i]) + 6*t*(p3[i]-2*c2[i]+c1[i]) for i in (0,1)]
    signs = [math.copysign(1, (lambda a, b: a[0]*b[1]-a[1]*b[0])(d1(t), d2(t))) for t in [i/50 for i in range(1, 50)]]
    return sum(1 for a, b in zip(signs, signs[1:]) if a != b)
p = N1
for s in half:
    print("inflections:", check(p, s)); p = s[2]

f = lambda p: " ".join(f"{v:.2f}".rstrip('0').rstrip('.') for v in p)
d = f"M{f(N1)} " + " ".join(f"C{f(a)} {f(b)} {f(c)}" for a, b, c in segs) + " Z"

# Play triangle: vertical left edge, tip on the horizontal center line, rounded corners.
tri = [(41.5, 34), (65, 50), (41.5, 66)]
radius = 2.5
def toward(p, q, dist):
    dx, dy = q[0] - p[0], q[1] - p[1]; l = math.hypot(dx, dy)
    return (p[0] + dx / l * dist, p[1] + dy / l * dist)
parts = []
for i, v in enumerate(tri):
    a, b = toward(v, tri[i - 1], radius), toward(v, tri[(i + 1) % 3], radius)
    parts.append(("L" if parts else "M") + f(a) + f" Q{f(v)} {f(b)}")
tri_d = " ".join(parts) + " Z"
open(out, "w").write(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <path fill="currentColor" fill-rule="evenodd" d="{d} {tri_d}"/>
</svg>
''')
print(d)
