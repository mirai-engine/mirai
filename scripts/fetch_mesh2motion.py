#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Downloads the clips of a rig of Mesh2Motion (CC0 1.0) at a fixed commit, the library of the
rig of an import with the same name (cook/rig): its bones have the paths and the rest of that rig,
so they play its clips after a bake.

They go to <project>/.mirai/library/mesh2motion/<rig>, which git ignores, with CREDITS.md, and
together in <rig>.glb: one skeleton and every clip asked for, which an import makes one .anim, the
library a bake and animation.character.setup take. Import it with asset.import or mirai import,
like any other source. The model variations of the app that are not CC0 are not downloaded.

Usage: uv run scripts/fetch_mesh2motion.py [--project <folder>] [--rig human|fox|...]
       [--clips walk,idle-a,...] [--list]
"""

import argparse
import fnmatch
import json
import pathlib
import struct
import sys
import urllib.request

COMMIT = "ec0669b9a2258605c8df267e225cbfa64489a628"
BASE = f"https://raw.githubusercontent.com/Mesh2Motion/mesh2motion-app/{COMMIT}/static/assets/"
CREDITS = """# Mesh2Motion {rig} clips

From <https://github.com/Mesh2Motion/mesh2motion-app> at `{commit}`,
`static/assets/{rig}`. Rigs, models and animations of Mesh2Motion are CC0 1.0
(<https://creativecommons.org/publicdomain/zero/1.0/>); its code is MIT.
"""


def fetch(path: str) -> bytes:
    with urllib.request.urlopen(BASE + path, timeout=60) as response:
        return response.read()


def glb_read(data: bytes) -> tuple[dict, bytes]:
    length = struct.unpack_from("<I", data, 12)[0]
    document = json.loads(data[20 : 20 + length])
    at = 20 + length
    binary = b""
    if at < len(data):
        size = struct.unpack_from("<I", data, at)[0]
        binary = data[at + 8 : at + 8 + size]
    return document, binary


def glb_write(document: dict, binary: bytes) -> bytes:
    text = json.dumps(document, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    binary += b"\x00" * (-len(binary) % 4)
    chunks = struct.pack("<I4s", len(text), b"JSON") + text + struct.pack("<I4s", len(binary), b"BIN\x00") + binary
    return struct.pack("<4sII", b"glTF", 2, 12 + len(chunks)) + chunks


# The clips of several files of the same skeleton in one: the nodes and the skin of the first,
# and of each file its animations, with their accessors, views and data after those before them.
# Each file has its data in the GLB chunk and, with meshopt, a fallback buffer without bytes.
def merge(files: list[bytes]) -> bytes:
    merged, binary = glb_read(files[0])
    names = {node.get("name"): i for i, node in enumerate(merged["nodes"])}
    fallback = sum(b["byteLength"] for b in merged["buffers"][1:])
    for data in files[1:]:
        document, chunk = glb_read(data)
        binary += b"\x00" * (-len(binary) % 16)
        base, views, accessors = len(binary), len(merged["bufferViews"]), len(merged["accessors"])
        fallback += -fallback % 16
        for view in document["bufferViews"]:
            view = dict(view)
            if view["buffer"] == 0:
                view["byteOffset"] = view.get("byteOffset", 0) + base
            else:
                view["buffer"] = 1
                view["byteOffset"] = view.get("byteOffset", 0) + fallback
            compressed = view.get("extensions", {}).get("EXT_meshopt_compression")
            if compressed is not None:
                compressed = dict(compressed, buffer=0, byteOffset=compressed.get("byteOffset", 0) + base)
                view["extensions"] = {"EXT_meshopt_compression": compressed}
            merged["bufferViews"].append(view)
        for accessor in document["accessors"]:
            merged["accessors"].append(dict(accessor, bufferView=accessor["bufferView"] + views))
        for animation in document.get("animations", []):
            animation = json.loads(json.dumps(animation))
            for sampler in animation["samplers"]:
                sampler["input"] += accessors
                sampler["output"] += accessors
            for channel in animation["channels"]:
                name = document["nodes"][channel["target"]["node"]].get("name")
                if name not in names:
                    raise SystemExit(f"fetch_mesh2motion: a clip animates {name}, which the first clip's skeleton has not")
                channel["target"]["node"] = names[name]
            merged.setdefault("animations", []).append(animation)
        binary += chunk
        fallback += sum(b["byteLength"] for b in document["buffers"][1:])
    merged["buffers"][0]["byteLength"] = len(binary)
    if len(merged["buffers"]) > 1:
        merged["buffers"][1]["byteLength"] = fallback
    return glb_write(merged, binary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", default=".", help="the project the clips are for")
    parser.add_argument("--rig", default="human", help="the rig of Mesh2Motion; --list without --clips names them")
    parser.add_argument("--clips", default="", help="names or patterns, comma separated; all by default")
    parser.add_argument("--list", action="store_true", help="names the clips and downloads nothing")
    args = parser.parse_args()
    manifest = json.loads(fetch("manifest.json"))
    rigs = manifest["rigs"]
    if args.rig not in rigs:
        print(f"fetch_mesh2motion: no rig {args.rig}; the rigs are {', '.join(rigs)}", file=sys.stderr)
        return 2
    clips = rigs[args.rig]["animations"]
    wanted = [p.strip() for p in args.clips.split(",") if p.strip()]
    if wanted:
        missing = [p for p in wanted if not any(
            fnmatch.fnmatch(pathlib.PurePosixPath(c["file"]).stem, p) for c in clips
        )]
        if missing:
            print(f"fetch_mesh2motion: no clip matches {', '.join(missing)}; --list names them", file=sys.stderr)
            return 2
        clips = [c for c in clips if any(fnmatch.fnmatch(pathlib.PurePosixPath(c["file"]).stem, p) for p in wanted)]
    if args.list:
        for clip in clips:
            print(f"{pathlib.PurePosixPath(clip['file']).stem}\t{clip.get('duration', 0):.2f} s\t{'loop' if clip.get('loop') else ''}")
        return 0
    folder = pathlib.Path(args.project) / ".mirai" / "library" / "mesh2motion" / args.rig
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "CREDITS.md").write_text(CREDITS.format(rig=args.rig, commit=COMMIT), encoding="utf-8")
    files = []
    for clip in clips:
        target = folder / pathlib.PurePosixPath(clip["file"]).name
        if not target.exists():
            partial = target.with_suffix(".part")
            partial.write_bytes(fetch(clip["file"]))
            partial.replace(target)
        files.append(target.read_bytes())
    library = folder / f"{args.rig}.glb"
    library.write_bytes(merge(files))
    print(library.resolve().as_posix())
    return 0


if __name__ == "__main__":
    sys.exit(main())
