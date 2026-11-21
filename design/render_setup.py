# Blender helper for render-assets.sh: sets the size, the camera and the output of a render.
#   blender -b Streamlet.blend -P render_setup.py -- <resolution> <camera zoom out> <output pattern>
# A zoom out of 2 doubles the orthographic scale (the wider camera of the website animation).
import bpy, sys
res, zoom, out = sys.argv[sys.argv.index("--") + 1:][:3]
sc = bpy.context.scene
sc.render.resolution_x = sc.render.resolution_y = int(res)
sc.render.resolution_percentage = 100
sc.camera.data.ortho_scale *= float(zoom)
sc.render.filepath = out
sc.render.image_settings.file_format = "PNG"
