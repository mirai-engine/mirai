#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Writes the animal templates of cook/rig from the rigs of Mesh2Motion (CC0 1.0) at the commit
fetch_mesh2motion.py pins: cook/rig/animals.odin with the bones of each rig, as its skeleton.glb
has them (the rest its clips animate), and cook/rig/animals/<rig>.samples with points of the
surface of its model.glb and their weights to those bones, the shape a registration deforms. The
rigs face +Z in their files; what is written is turned half a turn about +Y, the engine's space.

Each sample is 20 bytes, little endian: the position (3 f32, meters, +Y up, facing -Z), then 4
bone rows (u8) and their 4 weights (u8, summing to 255), as cook/rig.Sample reads them.

Usage: uv run scripts/gen_rig_templates.py [--assets <mesh2motion-app/static/assets>]
"""

import argparse
import json
import math
import pathlib
import random
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from fetch_mesh2motion import fetch, glb_read  # noqa: E402

RIGS = ["fox", "horse", "bird", "dragon", "kaiju", "shark", "snake", "spider"]
SAMPLES = 400
COMPONENT = {5126: ("f", 4), 5123: ("H", 2), 5125: ("I", 4), 5121: ("B", 1)}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
ROOT = pathlib.Path(__file__).resolve().parent.parent


def accessor(document: dict, binary: bytes, index: int) -> list:
    a = document["accessors"][index]
    view = document["bufferViews"][a["bufferView"]]
    form, size = COMPONENT[a["componentType"]]
    width = WIDTH[a["type"]]
    stride = view.get("byteStride", size * width)
    at = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    out = []
    for k in range(a["count"]):
        value = struct.unpack_from("<" + form * width, binary, at + k * stride)
        if a.get("normalized") and form != "f":
            value = tuple(v / (2 ** (8 * size) - 1) for v in value)
        out.append(value if width > 1 else value[0])
    return out


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    return qmul(qmul(q, (v[0], v[1], v[2], 0)), (-x, -y, -z, w))[:3]


def number(x: float) -> str:
    text = f"{x:.6f}".rstrip("0").rstrip(".")
    return "0" if text in ("", "-0") else text


# The bones under the node named root, parents first, with their local transforms.
def bones(document: dict) -> tuple[str, list]:
    nodes = document["nodes"]
    parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}
    root = next(i for i, n in enumerate(nodes) if n.get("name") == "root")
    top = nodes[parent[root]]
    if any(k in top for k in ("translation", "rotation", "scale", "matrix")):
        raise SystemExit(f"gen_rig_templates: {top['name']} moves its skeleton; the template takes it as identity")
    order = []

    def walk(i):
        order.append(i)
        for c in nodes[i].get("children", []):
            walk(c)

    walk(root)
    row = {i: k for k, i in enumerate(order)}
    out = []
    for i in order:
        n = nodes[i]
        tx, ty, tz = n.get("translation", [0, 0, 0])
        rx, ry, rz, rw = n.get("rotation", [0, 0, 0, 1])
        out.append((n["name"], row[parent[i]] if i != root else -1, [-tx, ty, -tz], [-rx, ry, -rz, rw]))
    return top["name"], out


# Surface points of the skinned meshes, area weighted, with the weights of their nearest corner.
def samples(document: dict, binary: bytes, rows: dict, rng: random.Random) -> list:
    nodes = document["nodes"]
    joints = [nodes[j]["name"] for j in document["skins"][0]["joints"]]
    triangles = []
    for n in nodes:
        if "mesh" not in n or "skin" not in n:
            continue
        for primitive in document["meshes"][n["mesh"]]["primitives"]:
            attributes = primitive["attributes"]
            positions = accessor(document, binary, attributes["POSITION"])
            bone = accessor(document, binary, attributes["JOINTS_0"])
            weight = accessor(document, binary, attributes["WEIGHTS_0"])
            indices = accessor(document, binary, primitive["indices"])
            for t in range(0, len(indices) - 2, 3):
                corners = indices[t : t + 3]
                a, b, c = (positions[k] for k in corners)
                u = [b[i] - a[i] for i in range(3)]
                v = [c[i] - a[i] for i in range(3)]
                cross = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
                area = 0.5 * math.sqrt(sum(x * x for x in cross))
                if area > 0:
                    triangles.append((area, [positions[k] for k in corners], [(bone[k], weight[k]) for k in corners]))
    total = sum(t[0] for t in triangles)
    cumulative = []
    acc = 0.0
    for t in triangles:
        acc += t[0]
        cumulative.append(acc / total)
    out = []
    for _ in range(SAMPLES):
        pick = triangles[min(bisect(cumulative, rng.random()), len(triangles) - 1)]
        u, v = rng.random(), rng.random()
        if u + v > 1:
            u, v = 1 - u, 1 - v
        bary = [1 - u - v, u, v]
        point = [sum(bary[k] * pick[1][k][i] for k in range(3)) for i in range(3)]
        bone, weight = pick[2][bary.index(max(bary))]
        pairs = sorted(((w, rows[joints[j]]) for j, w in zip(bone, weight) if w > 0), reverse=True)[:4]
        total_w = sum(w for w, _ in pairs)
        q = [round(255 * w / total_w) for w, _ in pairs]
        q[0] += 255 - sum(q)
        b = [r for _, r in pairs] + [0] * (4 - len(pairs))
        q += [0] * (4 - len(q))
        out.append(struct.pack("<3f4B4B", -point[0], point[1], -point[2], *b, *q))
    return out


def bisect(values: list, x: float) -> int:
    lo, hi = 0, len(values)
    while lo < hi:
        mid = (lo + hi) // 2
        if values[mid] < x:
            lo = mid + 1
        else:
            hi = mid
    return lo


def load(assets: str | None, path: str) -> bytes:
    if assets:
        return (pathlib.Path(assets) / path).read_bytes()
    return fetch(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--assets", help="a checkout's static/assets; the pinned commit on GitHub by default")
    args = parser.parse_args()
    folder = ROOT / "cook" / "rig" / "animals"
    folder.mkdir(exist_ok=True)
    lines = [
        "package rig",
        "",
        "// Generated by scripts/gen_rig_templates.py from the rigs of Mesh2Motion (CC0,",
        "// github.com/Mesh2Motion/mesh2motion-app, static/assets/<rig>): the bones of each",
        "// skeleton.glb, the rest its clips animate, and samples of the surface of its",
        "// model.glb weighted to them. Do not edit.",
        "",
        "@(rodata)",
        "ANIMALS:=[Animal]Template{",
    ]
    for rig in RIGS:
        top, rows = bones(glb_read(load(args.assets, f"{rig}/skeleton.glb"))[0])
        document, binary = glb_read(load(args.assets, f"{rig}/model.glb"))
        index = {name: k for k, (name, _, _, _) in enumerate(rows)}
        model_top, model_rows = bones(document)
        if [r[0] for r in model_rows] != [r[0] for r in rows]:
            raise SystemExit(f"gen_rig_templates: {rig}: model.glb and skeleton.glb have different bones")
        data = samples(document, binary, index, random.Random(rig))
        (folder / f"{rig}.samples").write_bytes(b"".join(data))
        lines.append(f"    .{rig.capitalize()}={{root=\"{top}\",samples=#load(\"animals/{rig}.samples\",[]Sample),bones=[]Bone{{")
        for name, parent, t, r in rows:
            lines.append(f"        {{\"{name}\",{parent},{{{','.join(number(x) for x in t)}}},{{{','.join(number(x) for x in r)}}}}},")
        lines.append("    }},")
    lines.append("}")
    (ROOT / "cook" / "rig" / "animals.odin").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print((ROOT / "cook" / "rig" / "animals.odin").as_posix())
    return 0


if __name__ == "__main__":
    sys.exit(main())
