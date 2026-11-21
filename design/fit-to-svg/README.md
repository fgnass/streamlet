# Fit the Blender blades to the flat S

The shape key "Flache Form" in `Streamlet.blend` moves the vertices of both blades in the
image plane (x/y only), so that the silhouette in the last frame matches the outline of
`../streamlet-s.svg`. The play triangle keeps sharp corners.

```sh
B=/Applications/Blender.app/Contents/MacOS/Blender
# 1. Export the blades in the last frame. Mute the shape key "Flache Form" first, if it exists.
$B -b ../Streamlet.blend --python export.py -- geo.json
# 2. Thin-plate-spline warp from the current silhouette to the SVG outline (numpy and Pillow)
python3 warp.py ../streamlet-s.svg        # writes new_verts.json and overlay.png
# 3. Add the result as the shape key "Flache Form"
$B -b ../Streamlet.blend --python apply.py -- new_verts.json ../Streamlet.blend
```
