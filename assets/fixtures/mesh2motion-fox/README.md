# Mesh2Motion fox

Files from [Mesh2Motion](https://github.com/Mesh2Motion/mesh2motion-app) at commit
`ec0669b9a2258605c8df267e225cbfa64489a628` (`static/assets/fox`), unchanged. Mesh2Motion rigs,
models and animations are CC0 1.0 ([LICENSE-CC0.md](LICENSE-CC0.md)); the app code is MIT.

- `horse.glb` (`variations/horse.glb`): a horse modeled on the fox skeleton, CC0, with the joints
  placed by hand. It is the reference of the animal rig test: it is imported with its skeleton and
  with `rig=Fox`, and the joints are compared.
- `walk.glb` (`animations/walk.glb`): the fox walk, without a mesh and with
  `EXT_meshopt_compression`. It gives the skeleton it animates, against which the rest of the rig
  is compared.

Coverage: [cook/import/gltf/rig_test.odin](../../../cook/import/gltf/rig_test.odin).
