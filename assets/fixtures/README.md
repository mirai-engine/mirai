These small fixtures belong to the repository and contain no third-party game assets.

- `concave.obj` is an L-shaped polygon with negative OBJ indices, vertex colors and a diffuse/
  emissive MTL material.
- `multiple.obj` has two meshes of different objects in the same file.
- `single-transform.gltf` has a single node with a mesh, with a non-zero translation and an uneven
  scale: it exercises the preservation of the node transform and the support when placing copies.
- `hierarchy.gltf` and `hierarchy.glb` contain a shared triangle mesh, instanced under different
  transforms, and an unused mesh outside the default scene.
- `hierarchy.usda` contains a parent transform, a static polygonal mesh and a uniform display
  color. `hierarchy.usdc` is its binary crate representation, generated with
  `/usr/bin/usdcat hierarchy.usda -o hierarchy.usdc`.
- `referenced.usda` references `hierarchy.usda` and overrides the parent transform: it exercises
  the composition before the native mesh parser.
- `cff.otf` is an own OpenType font with CFF outlines: rectangles for `A`, `H`, `?`, alpha and
  zhe, and a kerning pair of the Latin script and another of Cyrillic only. It is written by
  `uv run assets/fixtures/cff.py`.
- `hierarchy.fbx` (binary, FBX 7.4) and `hierarchy-ascii.fbx` (the same scene in ASCII): Z up
  and centimeters, as 3ds Max writes them. A parent rotated 90° about Z with a mesh of one quad and
  one triangle, two materials (a red Lambert with a texture and a Phong with medium transparency)
  and another node that shows the same geometry with a geometry transform. `skinned.fbx` (binary):
  Y up and meters; two bones with a namespace (`rig:`) under `Armature`, a skinned quad and the
  blend shape `Smile`, and the stack `Wave` with a linear rotation, a constant step and the weight
  of the blend shape. They are written by `uv run assets/fixtures/fbx.py`.
- `material.usda` has four meshes, with normals per corner, per point and per face and texture
  coordinates per corner and per point, and three `UsdPreviewSurface` materials: one bound through
  a parent prim with a diffuse image and a normal, one with a mask and a packed
  occlusion/roughness/metallic image, and one with a blend whose color comes from an input of its
  material. The fourth mesh has no material and keeps its display color. The images it names do
  not exist: the tests only read their paths.

What each importer reads and rejects is in the
[imports guide](../../.agents/skills/mirai-imports/references/imports.md).

## Skinned meshes

- `skeletal-analytic.gltf` / `.glb`: own asset with two joints, four triangles, blended weights
  and a translated mesh and skeleton. The joint that bends rests rotated 90° relative to its bind,
  so the rest pose has exact coordinates; the lower vertices name a joint outside the rig with
  zero weight.
- [`khronos-simple-skin/`](khronos-simple-skin/README.md): external SimpleSkin by
  Marco Hutter/Khronos, CC0; external buffers and interleaved accessors. Its clip
  is not imported.
- The [original demo robot](../../demo/assets/characters/robot/README.md)
  has 13 joints and blended weights.
- [`mesh2motion-human/`](mesh2motion-human/README.md): a CC0 character with the Mesh2Motion human
  skeleton placed by hand and two clips of that skeleton compressed with meshopt; they test the
  humanoid rig and the meshopt decoding.
- [`mesh2motion-fox/`](mesh2motion-fox/README.md): a CC0 horse on the Mesh2Motion fox skeleton,
  with the joints placed by hand, and the walk of that skeleton; they test the animal rig.

There is no generator available in the repository for the sources of the own skeletal fixtures or
of the robot. The import coverage of their rest pose, rig and weights is in
[cook/import/gltf/skin_test.odin](../../cook/import/gltf/skin_test.odin).
