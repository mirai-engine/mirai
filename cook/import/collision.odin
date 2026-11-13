package importer

import "mirai:asset"

// The colliders a source gives of a mesh (glTF and USD physics, the
// UCX_/UBX_/USP_/UCP_ nodes of a model), in the space of the mesh: stored in
// its asset as they are authored. An import makes none of its own.
Mesh_Collision :: struct {
    colliders:[]asset.Collider,
    points:   [][3]f32,
    indices:  []u32, // of a Mesh collider, relative to its first point
}
