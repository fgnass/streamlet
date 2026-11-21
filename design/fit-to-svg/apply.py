import bpy, json, sys
from mathutils import Vector
args = sys.argv[sys.argv.index("--") + 1:]
new = json.load(open(args[0])); out_blend = args[1]
sc = bpy.context.scene; sc.frame_set(sc.frame_end)
dg = bpy.context.evaluated_depsgraph_get()
for name, verts in new.items():
    o = bpy.data.objects[name]
    ev = o.evaluated_get(dg); me = ev.to_mesh()
    mw = ev.matrix_world.copy(); inv = mw.to_3x3().inverted()
    old_world = [mw @ v.co for v in me.vertices]
    ev.to_mesh_clear()
    key = o.shape_key_add(name="Flache Form", from_mix=False)
    basis = key.relative_key
    for i, (kp, ow) in enumerate(zip(key.data, old_world)):
        # Relative key: it holds only the offset from its reference shape.
        kp.co = basis.data[i].co + inv @ (Vector(verts[i]) - ow)
    key.value = 1.0
bpy.ops.wm.save_as_mainfile(filepath=out_blend, copy=True)
print("SAVED", out_blend)
