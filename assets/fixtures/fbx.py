#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Writes the FBX fixtures next to this file, each scene from one tree of FBX nodes:

- hierarchy.fbx (binary FBX 7.4) and hierarchy-ascii.fbx (the same scene in ASCII): Z up and
  centimeters, as 3ds Max writes them. A parent turned 90 degrees about Z holds a mesh of a quad
  and a triangle with two materials (a red Lambert with a texture and a Phong half transparent);
  another node shows the same geometry with a geometry transform.
- skinned.fbx (binary): Y up and meters. A skeleton of two bones under Armature, named in the
  namespace rig as Maya writes it, a quad skinned to them with a blend shape Smile, an empty stack
  Take 001 as Mixamo writes it, and the stack Wave: Tip turns 90 degrees about Z in a second, steps
  0.25 along X at half a second, Smile goes from 0 to 100 percent and the custom attribute jawOpen
  of Root, a curve as animation tools export them, from 0 to 0.8.
- inherit.fbx (binary) and inherit-ascii.fbx (the same scene in ASCII): Y up and meters. Stretch,
  turned 90 degrees about Z, scales (1, 0.5, 1) and in the stack Squash its X goes from 1 to 3 in
  a second and its Z steps to 2 at half a second. Under it Segment (a bone of the skinned Body) and Still do not inherit its scale
  (InheritType Rrs), and Segment's own Y goes from 1 to 2; Blend inherits it axis by axis (RrSs),
  and Leaf under Segment inherits as usual.

Usage: uv run assets/fixtures/fbx.py
"""

import os
import struct

HERE = os.path.dirname(os.path.realpath(__file__))
SECOND = 46186158000  # FBX time units per second


class I(int): pass
class L(int): pass
class D(float): pass
class S(str): pass
class Name:
    def __init__(self, cls, name): self.cls, self.name = cls, name
class Arr:
    def __init__(self, kind, values): self.kind, self.values = kind, list(values)


class Node:
    def __init__(self, name, *props, children=()):
        self.name, self.props, self.children = name, list(props), list(children)


def P(name, kind, *values, flags="A"):
    typed = []
    for v in values:
        if isinstance(v, (I, L, D, S)):
            typed.append(v)
        elif kind in ("int", "enum", "bool"):
            typed.append(I(v))
        elif kind == "KTime":
            typed.append(L(v))
        elif kind == "KString":
            typed.append(S(v))
        else:
            typed.append(D(v))
    return Node("P", S(name), S(kind), S(""), S(flags), *typed)


def props70(*entries):
    return Node("Properties70", children=entries)


# --- writers ---------------------------------------------------------------------------------

def ascii_value(v):
    if isinstance(v, Name):
        return f'"{v.cls}::{v.name}"'
    if isinstance(v, S):
        return '"' + v + '"'
    if isinstance(v, D):
        return repr(float(v))
    return str(int(v))


def ascii_node(node, depth, out):
    tab = "\t" * depth
    arrays = [p for p in node.props if isinstance(p, Arr)]
    if arrays:
        values = arrays[0].values
        text = ",".join(repr(float(v)) if arrays[0].kind in "fd" else str(int(v)) for v in values)
        out.append(f"{tab}{node.name}: *{len(values)} {{")
        out.append(f"{tab}\ta: {text}")
        out.append(f"{tab}}}")
        return
    head = f"{tab}{node.name}: " + ", ".join(ascii_value(p) for p in node.props)
    if node.children:
        out.append(head + " {")
        for child in node.children:
            ascii_node(child, depth + 1, out)
        out.append(f"{tab}}}")
    else:
        out.append(head)


def ascii_file(tree):
    out = ["; FBX 7.4.0 project file", ""]
    for node in tree:
        ascii_node(node, 0, out)
    return ("\n".join(out) + "\n").encode()


def binary_prop(v):
    if isinstance(v, Name):
        b = v.name.encode() + b"\x00\x01" + v.cls.encode()
        return b"S" + struct.pack("<I", len(b)) + b
    if isinstance(v, S):
        b = v.encode()
        return b"S" + struct.pack("<I", len(b)) + b
    if isinstance(v, D):
        return b"D" + struct.pack("<d", v)
    if isinstance(v, L):
        return b"L" + struct.pack("<q", v)
    if isinstance(v, I):
        return b"I" + struct.pack("<i", v)
    if isinstance(v, Arr):
        code = {"f": "<f", "d": "<d", "i": "<i", "l": "<q"}[v.kind]
        data = b"".join(struct.pack(code, x) for x in v.values)
        return v.kind.encode() + struct.pack("<III", len(v.values), 0, len(data)) + data
    raise TypeError(v)


def binary_node(node, offset):
    props = b"".join(binary_prop(p) for p in node.props)
    name = node.name.encode()
    head = 13 + len(name)
    body = props
    at = offset + head + len(props)
    if node.children:
        for child in node.children:
            child_bytes = binary_node(child, at)
            body += child_bytes
            at += len(child_bytes)
        body += b"\x00" * 13
    end = offset + head + len(body)
    return struct.pack("<IIIB", end, len(node.props), len(props), len(name)) + name + body


def binary_file(tree):
    out = b"Kaydara FBX Binary  \x00\x1a\x00" + struct.pack("<I", 7400)
    for node in tree:
        out += binary_node(node, len(out))
    return out + b"\x00" * 13


# --- scenes ----------------------------------------------------------------------------------

def header():
    return Node("FBXHeaderExtension", children=[
        Node("FBXHeaderVersion", I(1003)),
        Node("FBXVersion", I(7400)),
        Node("Creator", S("Mirai fixtures")),
    ])


def settings(up, up_sign, front, front_sign, coord, unit):
    return Node("GlobalSettings", children=[
        Node("Version", I(1000)),
        props70(
            P("UpAxis", "int", up), P("UpAxisSign", "int", up_sign),
            P("FrontAxis", "int", front), P("FrontAxisSign", "int", front_sign),
            P("CoordAxis", "int", coord), P("CoordAxisSign", "int", 1),
            P("UnitScaleFactor", "double", unit),
            P("TimeMode", "enum", 6), P("CustomFrameRate", "double", 30),
        ),
    ])


def model(id, name, kind, *entries):
    return Node("Model", L(id), Name("Model", name), S(kind), children=[
        Node("Version", I(232)), props70(*entries),
    ])


def layer(*kinds):
    return Node("Layer", I(0), children=[Node("Version", I(100))] + [
        Node("LayerElement", children=[Node("Type", S(k)), Node("TypedIndex", I(0))]) for k in kinds
    ])


def C(kind, child, parent, prop=None):
    return Node("C", S(kind), L(child), L(parent), *([S(prop)] if prop else []))


def matrix(tx=0.0, ty=0.0, tz=0.0):
    return Arr("d", [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, tx, ty, tz, 1])


def hierarchy():
    vertices = [0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0, 20, 0, 0]
    polygons = [0, 1, 2, -4, 1, 4, -3]
    geometry = Node("Geometry", L(200), Name("Geometry", "Shape"), S("Mesh"), children=[
        Node("Vertices", Arr("d", vertices)),
        Node("PolygonVertexIndex", Arr("i", polygons)),
        Node("GeometryVersion", I(124)),
        Node("LayerElementNormal", I(0), children=[
            Node("Version", I(101)), Node("Name", S("")),
            Node("MappingInformationType", S("ByPolygonVertex")),
            Node("ReferenceInformationType", S("Direct")),
            Node("Normals", Arr("d", [0, 0, 1] * 7)),
        ]),
        Node("LayerElementUV", I(0), children=[
            Node("Version", I(101)), Node("Name", S("UVMap")),
            Node("MappingInformationType", S("ByPolygonVertex")),
            Node("ReferenceInformationType", S("IndexToDirect")),
            Node("UV", Arr("d", [0, 0, 1, 0, 1, 1, 0, 1, 2, 0])),
            Node("UVIndex", Arr("i", [0, 1, 2, 3, 1, 4, 2])),
        ]),
        Node("LayerElementMaterial", I(0), children=[
            Node("Version", I(101)), Node("Name", S("")),
            Node("MappingInformationType", S("ByPolygon")),
            Node("ReferenceInformationType", S("IndexToDirect")),
            Node("Materials", Arr("i", [0, 1])),
        ]),
        layer("LayerElementNormal", "LayerElementUV", "LayerElementMaterial"),
    ])
    red = Node("Material", L(300), Name("Material", "Red"), S(""), children=[
        Node("Version", I(102)), Node("ShadingModel", S("lambert")),
        props70(P("DiffuseColor", "Color", 1, 0, 0)),
    ])
    glass = Node("Material", L(301), Name("Material", "Glass"), S(""), children=[
        Node("Version", I(102)), Node("ShadingModel", S("phong")),
        props70(P("DiffuseColor", "Color", 0, 0, 1), P("TransparentColor", "Color", 1, 1, 1),
                P("TransparencyFactor", "double", 0.5)),
    ])
    texture = Node("Texture", L(400), Name("Texture", "red"), S(""), children=[
        Node("Type", S("TextureVideoClip")), Node("Version", I(202)),
        Node("TextureName", Name("Texture", "red")),
        Node("FileName", S("red.png")), Node("RelativeFilename", S("red.png")),
    ])
    objects = Node("Objects", children=[
        model(100, "Parent", "Null", P("Lcl Translation", "Lcl Translation", 100, 0, 0),
              P("Lcl Rotation", "Lcl Rotation", 0, 0, 90)),
        model(101, "Quad", "Mesh", P("Lcl Translation", "Lcl Translation", 0, 0, 50)),
        model(102, "Offset", "Mesh", P("GeometricTranslation", "Vector3D", 0, 0, 10)),
        geometry, red, glass, texture,
    ])
    connections = Node("Connections", children=[
        C("OO", 100, 0), C("OO", 101, 100), C("OO", 102, 0),
        C("OO", 200, 101), C("OO", 200, 102),
        C("OO", 300, 101), C("OO", 301, 101), C("OO", 300, 102), C("OO", 301, 102),
        C("OP", 400, 300, "DiffuseColor"),
    ])
    return [header(), settings(2, 1, 1, -1, 0, 1.0), objects, connections]


def curve(id, times, values, flags):
    return Node("AnimationCurve", L(id), Name("AnimCurve", ""), S(""), children=[
        Node("Default", D(values[0])), Node("KeyVer", I(4009)),
        Node("KeyTime", Arr("l", times)),
        Node("KeyValueFloat", Arr("f", values)),
        Node("KeyAttrFlags", Arr("i", flags)),
        Node("KeyAttrDataFloat", Arr("f", [0, 0, 0, 0] * len(flags))),
        Node("KeyAttrRefCount", Arr("i", [len(times) // len(flags)] * len(flags))),
    ])


def curve_node(id, name, *channels):
    return Node("AnimationCurveNode", L(id), Name("AnimCurveNode", name), S(""), children=[
        props70(*(P(f"d|{c}", "Number", v) for c, v in channels)),
    ])


def skinned():
    LINEAR, CONSTANT = 0x4, 0x2
    geometry = Node("Geometry", L(200), Name("Geometry", "BodyMesh"), S("Mesh"), children=[
        Node("Vertices", Arr("d", [-0.1, 0, 0, 0.1, 0, 0, 0.1, 2, 0, -0.1, 2, 0])),
        Node("PolygonVertexIndex", Arr("i", [0, 1, 2, -4])),
        Node("GeometryVersion", I(124)),
        Node("LayerElementNormal", I(0), children=[
            Node("Version", I(101)), Node("Name", S("")),
            Node("MappingInformationType", S("ByPolygonVertex")),
            Node("ReferenceInformationType", S("Direct")),
            Node("Normals", Arr("d", [0, 0, 1] * 4)),
        ]),
        layer("LayerElementNormal"),
    ])
    objects = Node("Objects", children=[
        model(100, "Armature", "Null"),
        model(101, "rig:Root", "LimbNode", P("jawOpen", "Number", 0, flags="A+U")),
        model(102, "rig:Tip", "LimbNode", P("Lcl Translation", "Lcl Translation", 0, 1, 0)),
        model(103, "Body", "Mesh"),
        Node("NodeAttribute", L(110), Name("NodeAttribute", ""), S("LimbNode"), children=[Node("TypeFlags", S("Skeleton"))]),
        Node("NodeAttribute", L(111), Name("NodeAttribute", ""), S("LimbNode"), children=[Node("TypeFlags", S("Skeleton"))]),
        geometry,
        Node("Deformer", L(300), Name("Deformer", "Skin"), S("Skin"), children=[Node("Version", I(101))]),
        Node("Deformer", L(301), Name("SubDeformer", "Root"), S("Cluster"), children=[
            Node("Version", I(100)), Node("Indexes", Arr("i", [0, 1])), Node("Weights", Arr("d", [1, 1])),
            Node("Transform", matrix()), Node("TransformLink", matrix()),
        ]),
        Node("Deformer", L(302), Name("SubDeformer", "Tip"), S("Cluster"), children=[
            Node("Version", I(100)), Node("Indexes", Arr("i", [2, 3])), Node("Weights", Arr("d", [1, 1])),
            Node("Transform", matrix(ty=-1)), Node("TransformLink", matrix(ty=1)),
        ]),
        Node("Deformer", L(400), Name("Deformer", "Blend"), S("BlendShape"), children=[Node("Version", I(100))]),
        Node("Deformer", L(401), Name("SubDeformer", "Smile"), S("BlendShapeChannel"), children=[
            Node("Version", I(100)), Node("DeformPercent", D(0)), Node("FullWeights", Arr("d", [100])),
        ]),
        Node("Geometry", L(402), Name("Geometry", "Smile"), S("Shape"), children=[
            Node("Version", I(100)), Node("Indexes", Arr("i", [2, 3])),
            Node("Vertices", Arr("d", [0, 0, 0.5, 0, 0, 0.5])),
        ]),
        Node("AnimationStack", L(510), Name("AnimStack", "Take 001"), S(""), children=[
            props70(P("LocalStop", "KTime", SECOND), P("ReferenceStop", "KTime", SECOND)),
        ]),
        Node("AnimationLayer", L(511), Name("AnimLayer", "BaseLayer"), S("")),
        Node("AnimationStack", L(500), Name("AnimStack", "Wave"), S(""), children=[
            props70(P("LocalStop", "KTime", SECOND), P("ReferenceStop", "KTime", SECOND)),
        ]),
        Node("AnimationLayer", L(501), Name("AnimLayer", "BaseLayer"), S("")),
        curve_node(502, "R", ("X", 0), ("Y", 0), ("Z", 0)),
        curve(503, [0, SECOND], [0, 90], [LINEAR]),
        curve_node(504, "T", ("X", 0), ("Y", 1), ("Z", 0)),
        curve(505, [0, SECOND // 2], [0, 0.25], [CONSTANT, LINEAR]),
        curve_node(506, "DeformPercent", ("DeformPercent", 0)),
        curve(507, [0, SECOND], [0, 100], [LINEAR]),
        curve_node(508, "jawOpen", ("jawOpen", 0)),
        curve(509, [0, SECOND], [0, 0.8], [LINEAR]),
    ])
    connections = Node("Connections", children=[
        C("OO", 100, 0), C("OO", 101, 100), C("OO", 102, 101), C("OO", 103, 100),
        C("OO", 110, 101), C("OO", 111, 102),
        C("OO", 200, 103), C("OO", 300, 200), C("OO", 301, 300), C("OO", 302, 300),
        C("OO", 101, 301), C("OO", 102, 302),
        C("OO", 400, 200), C("OO", 401, 400), C("OO", 402, 401),
        C("OO", 511, 510), C("OO", 501, 500),
        C("OO", 502, 501), C("OP", 502, 102, "Lcl Rotation"), C("OP", 503, 502, "d|Z"),
        C("OO", 504, 501), C("OP", 504, 102, "Lcl Translation"), C("OP", 505, 504, "d|X"),
        C("OO", 506, 501), C("OP", 506, 401, "DeformPercent"), C("OP", 507, 506, "d|DeformPercent"),
        C("OO", 508, 501), C("OP", 508, 101, "jawOpen"), C("OP", 509, 508, "d|jawOpen"),
    ])
    return [header(), settings(1, 1, 2, 1, 0, 100.0), objects, connections]


def inherit():
    LINEAR, CONSTANT = 0x4, 0x2
    geometry = Node("Geometry", L(200), Name("Geometry", "BodyMesh"), S("Mesh"), children=[
        Node("Vertices", Arr("d", [0, 0, 0, 0.1, 0, 0, 0, 0.1, 0])),
        Node("PolygonVertexIndex", Arr("i", [0, 1, -3])),
        Node("GeometryVersion", I(124)),
    ])
    # Segment at rest: Stretch moves it half a meter along its Y, which its turn sends to -X.
    bind = Arr("d", [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0.5, 0, 0, 1])
    objects = Node("Objects", children=[
        model(100, "Stretch", "LimbNode", P("Lcl Translation", "Lcl Translation", 1, 0, 0),
              P("Lcl Rotation", "Lcl Rotation", 0, 0, 90), P("Lcl Scaling", "Lcl Scaling", 1, 0.5, 1)),
        model(101, "Segment", "LimbNode", P("InheritType", "enum", 2),
              P("Lcl Translation", "Lcl Translation", 0, 1, 0)),
        model(102, "Leaf", "Null", P("Lcl Translation", "Lcl Translation", 0, 1, 0)),
        model(103, "Still", "Null", P("InheritType", "enum", 2),
              P("Lcl Translation", "Lcl Translation", 1, 0, 0), P("Lcl Scaling", "Lcl Scaling", 2, 2, 2)),
        model(104, "Blend", "Null", P("InheritType", "enum", 0),
              P("Lcl Translation", "Lcl Translation", 0, 0, 1)),
        model(105, "Body", "Mesh"),
        geometry,
        Node("Deformer", L(300), Name("Deformer", "Skin"), S("Skin"), children=[Node("Version", I(101))]),
        Node("Deformer", L(301), Name("SubDeformer", "Segment"), S("Cluster"), children=[
            Node("Version", I(100)), Node("Indexes", Arr("i", [0, 1, 2])),
            Node("Weights", Arr("d", [1, 1, 1])),
            Node("Transform", matrix()), Node("TransformLink", bind),
        ]),
        Node("AnimationStack", L(500), Name("AnimStack", "Squash"), S(""), children=[
            props70(P("LocalStop", "KTime", SECOND), P("ReferenceStop", "KTime", SECOND)),
        ]),
        Node("AnimationLayer", L(501), Name("AnimLayer", "BaseLayer"), S("")),
        curve_node(510, "S", ("X", 1), ("Y", 0.5), ("Z", 1)),
        curve(511, [0, SECOND], [1, 3], [LINEAR]),
        curve(514, [0, SECOND // 2], [1, 2], [CONSTANT, LINEAR]),
        curve_node(512, "S", ("X", 1), ("Y", 1), ("Z", 1)),
        curve(513, [0, SECOND], [1, 2], [LINEAR]),
    ])
    connections = Node("Connections", children=[
        C("OO", 100, 0), C("OO", 101, 100), C("OO", 102, 101), C("OO", 103, 100),
        C("OO", 104, 100), C("OO", 105, 0),
        C("OO", 200, 105), C("OO", 300, 200), C("OO", 301, 300), C("OO", 101, 301),
        C("OO", 501, 500),
        C("OO", 510, 501), C("OP", 510, 100, "Lcl Scaling"), C("OP", 511, 510, "d|X"),
        C("OP", 514, 510, "d|Z"),
        C("OO", 512, 501), C("OP", 512, 101, "Lcl Scaling"), C("OP", 513, 512, "d|Y"),
    ])
    return [header(), settings(1, 1, 2, 1, 0, 100.0), objects, connections]


def write(name, data):
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)
    print(f"wrote {name} ({len(data)} bytes)")


if __name__ == "__main__":
    write("hierarchy.fbx", binary_file(hierarchy()))
    write("hierarchy-ascii.fbx", ascii_file(hierarchy()))
    write("skinned.fbx", binary_file(skinned()))
    write("inherit.fbx", binary_file(inherit()))
    write("inherit-ascii.fbx", ascii_file(inherit()))
