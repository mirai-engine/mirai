package physics

import "mirai:core"
import "mirai:host"
import "mirai:std/base"

// Why a collider has no shape in the simulation.
@(private)
Shape_Failure :: enum u8 {None,No_Mesh,No_Geometry,No_Heightfield,Mirrored_Heightfield,Hull,Geometry_Budget,Shapes,Convex_Radius,Sheared}

@(private)
shape_problem :: proc(s:^Sync,e:core.Entity,collider:Collider,failure:Shape_Failure) {
    static,_:=core.get(s.statics,e)
    name:[base.ASSET_ID_TEXT]u8
    mesh:=host.assets_name(s.app.assets,static.mesh,&name)
    w:=&s.state.world
    switch failure {
    case .None:
    case .No_Mesh:
        core.report(s.problems,e,"physics.collider_mesh","its Collider is a %v, which takes its shape from the Mesh_Renderer of the entity, and it has none; add a Mesh_Renderer, or make the Collider a Box, Sphere, Capsule or Cylinder",collider.kind)
    case .No_Geometry:
        core.report(s.problems,e,"physics.collider_geometry","its %v Collider takes its shape from mesh %s, which has no collision geometry: the mesh is missing, or a generated mesh was freed; give Mesh_Renderer.mesh a mesh of the assets, or use another Collider kind",collider.kind,mesh)
    case .No_Heightfield:
        core.report(s.problems,e,"physics.collider_heightfield","its Heightfield Collider takes its shape from mesh %s, which is not a valid heightfield; give it the mesh of a terrain, or use another Collider kind",mesh)
    case .Mirrored_Heightfield:
        core.report(s.problems,e,"physics.collider_mirrored","its Heightfield Collider has a negative axis in its world scale, and a heightfield cannot be mirrored; make the scale positive, or mirror the terrain itself")
    case .Sheared:
        core.report(s.problems,e,"physics.collider_sheared","its %v Collider turns under a scale that is not the same along the turned axes, which shears it, and a shape cannot be sheared: it collides with that scale along its own axes; make the scale of its parents uniform, or turn it only by quarter turns about their axes",collider.kind)
    case .Hull:
        core.report(s.problems,e,"physics.collider_hull","the convex hull of mesh %s could not be built for its Hull Collider: its points are degenerate, or the hull needs more than 255 faces or vertices; use a simpler mesh, or a Mesh or Box Collider",mesh)
    case .Geometry_Budget:
        used,capacity:=geometry_budget({s.state},collider.kind)
        field:=collider.kind==.Hull?"hulls":collider.kind==.Mesh?"meshes":"heightfields"
        core.report(s.problems,e,"physics.geometry_budget","the simulation refused the %v geometry of mesh %s: %d of the %d of Physics_Settings.%s are in use, or its triangles are not valid; raise %s, or use fewer of them",collider.kind,mesh,used,capacity,field,field)
    case .Convex_Radius:
        core.report(s.problems,e,"physics.convex_radius","its %v Collider has a convex_radius of %v m, which leaves its shape no core: at the scale of the entity it must be below the smallest half extent of a Box, the radius and half height of a Cylinder, or the distance from the center of a Hull to its nearest face; lower convex_radius",collider.kind,collider.convex_radius)
    case .Shapes:
        core.report(s.problems,e,"physics.shapes","the simulation refused the shape of its %v Collider: the %d shapes of Physics_Settings.shapes are in use, or its size is zero or not finite; raise shapes, or fix Collider.size",collider.kind,w.desc.shape_capacity)
    }
}

// A request of Body_Requests that did nothing on its entity.
@(private)
request_problem :: proc(s:^Sync,e:core.Entity,kind:Body_Request_Kind,code,why,fix:string) {
    core.report(s.problems,e,code,"a %v request of Body_Requests did nothing on this entity: %s; %s",kind,why,fix)
}

@(private)
memory_problem :: proc(problems:^core.Problems,e:core.Entity,what:string) {
    if e==core.NONE {
        core.report(problems,core.NONE,"physics.memory","out of memory for %s; it waits for the next tick: free memory, or lower the capacities of Physics_Settings",what)
    } else {
        core.report(problems,e,"physics.memory","out of memory for %s of this entity; it waits for the next tick: free memory",what)
    }
}
