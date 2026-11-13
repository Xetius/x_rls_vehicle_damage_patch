"""Builds the mod zip with forward-slash paths. Run from the project folder.

python tools/build.py            -> x_rls_vehicle_damage_patch_dev.zip (for your own mods folder)
python tools/build.py --release  -> dist/x_rls_vehicle_damage_patch_<version>.zip (to share),
                                    version from mod_info/.../info.json, with the tests included
"""
import json
import pathlib
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = "x_rls_vehicle_damage_patch"
CONTENT = ["lua", "scripts", "ui", "mod_info", "LICENSE", "README.txt"]
# The release also carries the test and build scripts, so the zip holds the complete source.
RELEASE_EXTRA = ["tools/build.py", "tools/test.lua", "tools/test_business.lua"]

release = "--release" in sys.argv[1:]
if release:
    info = json.loads((ROOT / "mod_info" / NAME / "info.json").read_text(encoding="utf-8"))
    version = info["version_string"]
    (ROOT / "dist").mkdir(exist_ok=True)
    output = ROOT / "dist" / f"{NAME}_{version}.zip"
else:
    output = ROOT / f"{NAME}_dev.zip"

with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
    for name in CONTENT + (RELEASE_EXTRA if release else []):
        path = ROOT / name
        files = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file())
        for file in files:
            archive.write(file, file.relative_to(ROOT).as_posix())
            print(file.relative_to(ROOT).as_posix())

print("built", output, output.stat().st_size)
