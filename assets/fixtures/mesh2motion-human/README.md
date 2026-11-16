# Mesh2Motion human

Files from [Mesh2Motion](https://github.com/Mesh2Motion/mesh2motion-app) at commit
`ec0669b9a2258605c8df267e225cbfa64489a628` (`static/assets/human`), unchanged. Mesh2Motion rigs,
models and animations are CC0 1.0 ([LICENSE-CC0.md](LICENSE-CC0.md)); the app code is MIT.

- `psx-05.glb` (`variations/psx-05.glb`): low poly character by elbolilloduro, CC0, with the
  Mesh2Motion human skeleton placed by hand. It is the reference of the rig test: it is imported
  with its skeleton and with `rig=Humanoid`, and the joints are compared.
- `walk.glb` and `idle-a.glb` (`animations/`): clips of that skeleton without a mesh, as
  glTF-Transform writes them, with `EXT_meshopt_compression` (times without a filter, translations
  with the exponential filter and rotations with the quaternion one). They give the skeleton they
  animate, the origin of a bake.
- `skeleton.glb`: the human skeleton alone, from which the template of
  [cook/rig/template.odin](../../../cook/rig/template.odin) comes.

Coverage: [cook/import/gltf/rig_test.odin](../../../cook/import/gltf/rig_test.odin) and
[meshopt_test.odin](../../../cook/import/gltf/meshopt_test.odin).
