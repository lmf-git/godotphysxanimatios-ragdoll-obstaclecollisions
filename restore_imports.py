import os
import re

ANIMATIONS_DIR = "/Users/lmf/Downloads/PhysxAnimationTest/animations"
IMPORTED_DIR = "/Users/lmf/Downloads/PhysxAnimationTest/.godot/imported"

# Build a lookup: fbx filename -> scn filename (just the basename)
scn_files = {}
for name in os.listdir(IMPORTED_DIR):
    if name.endswith(".scn"):
        # Name format: "Some Animation.fbx-<hash>.scn"
        # Extract the fbx prefix (everything up to and including ".fbx")
        match = re.match(r'^(.+\.fbx)-[0-9a-f]+\.scn$', name)
        if match:
            fbx_name = match.group(1)
            scn_files[fbx_name] = name

restored = 0
skipped = 0
missing_scn = []
missing_uid = []

for fname in os.listdir(ANIMATIONS_DIR):
    if not fname.endswith(".fbx"):
        continue

    import_path = os.path.join(ANIMATIONS_DIR, fname + ".import")
    if not os.path.isfile(import_path):
        print(f"  SKIP (no .import file): {fname}")
        skipped += 1
        continue

    # Find matching .scn file
    scn_name = scn_files.get(fname)
    if not scn_name:
        print(f"  SKIP (no matching .scn): {fname}")
        missing_scn.append(fname)
        skipped += 1
        continue

    # Read existing .import to extract uid
    with open(import_path, "r") as f:
        content = f.read()

    uid_match = re.search(r'uid="([^"]+)"', content)
    if not uid_match:
        print(f"  SKIP (no uid found): {fname}")
        missing_uid.append(fname)
        skipped += 1
        continue

    uid = uid_match.group(1)
    scn_res_path = f"res://.godot/imported/{scn_name}"
    fbx_res_path = f"res://animations/{fname}"

    new_content = f"""[remap]

importer="scene"
importer_version=1
type="PackedScene"
uid="{uid}"
path="{scn_res_path}"

[deps]

source_file="{fbx_res_path}"
dest_files=["{scn_res_path}"]

[params]

nodes/root_type=""
nodes/root_name=""
nodes/root_script=null
nodes/apply_root_scale=true
nodes/root_scale=1.0
nodes/import_as_skeleton_bones=false
nodes/use_name_suffixes=true
nodes/use_node_type_suffixes=true
meshes/ensure_tangents=true
meshes/generate_lods=true
meshes/create_shadow_meshes=true
meshes/light_baking=1
meshes/lightmap_texel_size=0.2
meshes/force_disable_compression=false
skins/use_named_skins=true
animation/import=true
animation/fps=30
animation/trimming=true
animation/remove_immutable_tracks=true
animation/import_rest_as_RESET=false
import_script/path=""
materials/extract=0
materials/extract_format=0
materials/extract_path=""
_subresources={{}}
fbx/importer=1
fbx/allow_geometry_helper_nodes=false
fbx/embedded_image_handling=1
fbx/naming_version=2
"""

    with open(import_path, "w") as f:
        f.write(new_content)

    print(f"  OK: {fname}  ->  {scn_name}  (uid={uid})")
    restored += 1

print()
print(f"=== Done ===")
print(f"Restored: {restored}")
print(f"Skipped:  {skipped}")
if missing_scn:
    print(f"No matching .scn found for: {missing_scn}")
if missing_uid:
    print(f"No uid found in .import for: {missing_uid}")
