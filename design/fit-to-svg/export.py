import bpy, json, sys
out = sys.argv[sys.argv.index("--") + 1]
sc = bpy.context.scene
sc.frame_set(sc.frame_end)
dg = bpy.context.evaluated_depsgraph_get()
data = {"res": [sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage],
        "cam": {"loc": list(sc.camera.location), "rot": list(sc.camera.rotation_euler), "ortho_scale": sc.camera.data.ortho_scale,
                "shift": [sc.camera.data.shift_x, sc.camera.data.shift_y]},
        "frame": sc.frame_end, "blades": {}}
for name in ("Oberes Blatt", "Unteres Blatt"):
    o = bpy.data.objects[name]
    ev = o.evaluated_get(dg)
    me = ev.to_mesh()
    mw = ev.matrix_world
    verts = [list(mw @ v.co) for v in me.vertices]
    faces = [list(p.vertices) for p in me.polygons]
    keys = {k.name: k.value for k in o.data.shape_keys.key_blocks}
    data["blades"][name] = {"verts": verts, "faces": faces, "keys": keys,
        "matrix_world": [list(r) for r in mw]}
    ev.to_mesh_clear()
json.dump(data, open(out, "w"))
print("EXPORTED", data["res"], data["cam"], {n: b["keys"] for n, b in data["blades"].items()})
