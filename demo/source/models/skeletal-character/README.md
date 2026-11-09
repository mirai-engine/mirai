# Mirai robot with a skeleton

Original asset of this repository, with no third-party content. It does not require an external
assets license.

`robot.glb` and `robot.gltf` + `robot.bin` are two serializations of the same model: 13 bones,
about 5500 triangles and one primitive for each of its four non-metallic materials (one with an
emissive visor), with four influences available per vertex. The arm and leg segments blend weights
near elbows and knees, and the spherical joints cover the ends that meet. It has no animation
clips. The file uses meters, Y up and its front toward +Z, which the import turns to -Z.

There is no generator available in the repository to regenerate these sources.

Importing `robot.glb` from Assets, File > Import model... or `asset.import` produces a prefab
whose root is the rig: it draws the mesh with `Mesh_Renderer`, the skeleton comes from the mesh
asset and the bones are not entities. The bind geometry, the rig and the weights are kept in
`.mesh`; the `animation` plugin evaluates the poses and deforms on the GPU. As this source has no
clips, own clips and an `Animation` component are added on that root. The contract and the limits
are in the
[imports guide](../../../../.agents/skills/mirai-imports/references/imports.md#skinned-meshes).

The demo imports it with the rest of `source/models` and the import tests read it; the animation
gallery shows Mirai instead.
