package usd

import "core:math/linalg"
import "core:testing"
import "mirai:asset"
import "mirai:std/base"
import importer "mirai:cook/import"

// A Mesh with PhysicsCollisionAPI collides as its approximation, and a Cube
// with it under the mesh is a box of the mesh where it is, collision only; a
// guide Mesh that collides is collision only too. Neither stays a node.
@(test)
usd_physics_colliders_are_the_colliders_of_the_mesh_they_are_for :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"usd-physics")
    if folder=="" {return}
    path:=write_text(folder,"physics.usda",`#usda 1.0
(
    metersPerUnit = 1
    upAxis = "Y"
)
def Mesh "Crate" (
    prepend apiSchemas = ["PhysicsCollisionAPI", "PhysicsMeshCollisionAPI"]
)
{
    uniform token physics:approximation = "convexHull"
    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]
    int[] faceVertexCounts = [3, 3, 3, 3]
    int[] faceVertexIndices = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
    uniform token subdivisionScheme = "none"

    def Cube "Bumper" (
        prepend apiSchemas = ["PhysicsCollisionAPI"]
    )
    {
        double size = 4
        double3 xformOp:translate = (0, 3, 0)
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }
    def Mesh "Proxy" (
        prepend apiSchemas = ["PhysicsCollisionAPI"]
    )
    {
        uniform token purpose = "guide"
        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        uniform token subdivisionScheme = "none"
    }
}
`)
    model,ok:=import_ok(t,path,TEXT_ONLY)
    if !ok {return}
    defer importer.model_destroy(&model)
    testing.expect_value(t,len(model.nodes),1)
    testing.expect_value(t,len(model.meshes),1)
    if len(model.meshes)!=1 {return}
    kinds:[asset.Collider_Kind]int
    collision:=model.meshes[0].collision
    for c in collision.colliders {kinds[c.kind]+=1}
    testing.expectf(t,kinds[.Hull]==1 && kinds[.Box]==1 && kinds[.Mesh]==1 && len(collision.colliders)==3,"%v",kinds)
    for c in collision.colliders {
        #partial switch c.kind {
        case .Box: testing.expectf(t,linalg.length(c.center-{0,3,0})<1e-4 && linalg.length(c.size-{2,2,2})<1e-4,"the cube: %v",c)
        case .Hull: testing.expect_value(t,c.point_count,u32(4))
        case .Mesh: testing.expect_value(t,c.index_count,u32(3))
        }
    }
}
