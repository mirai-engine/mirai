package usd

import "core:math"
import "core:math/linalg"
import "core:slice"
import importer "mirai:cook/import"
import mm "mirai:std/math"

// The collision a USD authors with UsdPhysics: a prim with
// PhysicsCollisionAPI (and physics:collisionEnabled not off) is a collider of
// the mesh it is for. A Mesh collides as its physics:approximation of
// PhysicsMeshCollisionAPI says (its triangles without one); a Cube, Sphere,
// Capsule, Cylinder or Cone as that shape. A Mesh with purpose guide or
// invisible, and every shape, is collision only (importer.colliders_resolve).

// Segments around the round shapes a hull stands for (a cylinder, a cone).
@(private="file") ROUND_SEGMENTS :: 16

// Whether a prim has PhysicsCollisionAPI on.
@(private)
usd_collides :: proc(prim:Usd_Prim) -> bool {
    schemas,found:=prim.properties["apiSchemas"]
    if !found || !slice.contains(usd_strings(schemas),"PhysicsCollisionAPI") {return false}
    if enabled,set:=prim.properties["physics:collisionEnabled"];set {
        value:=usd_string(enabled)
        return value!="0" && value!="false"
    }
    return true
}

// The collider a prim that collides authors, placed at the node of row; mesh
// is the row of the geometry of a Mesh prim, or -1.
@(private)
usd_collider :: proc(r:^importer.Reader,prim:Usd_Prim,row,mesh:int) -> bool {
    made:=importer.Source_Collider{placed=row,target=-1,rotation=1,mesh=mesh,only=true}
    number :: proc(r:^importer.Reader,prim:Usd_Prim,name:string,fallback:f32) -> (value:f32,ok:bool) {
        property,found:=prim.properties[name]
        if !found {return fallback,true}
        values:=usd_numbers(r,property) or_return
        if len(values)!=1 || !(values[0]>=0) {return 0,importer.fail(r,.Malformed,"%s: %s must be one number of zero or more",prim.path,name)}
        return f32(values[0]),true
    }
    // Y, along which the round shapes are made, turned to the axis of the prim.
    axis_turn :: proc(prim:Usd_Prim) -> mm.Quat {
        axis:=[3]f32{0,0,1}
        if property,found:=prim.properties["axis"];found {
            switch usd_string(property) {
            case "X": axis={1,0,0}
            case "Y": axis={0,1,0}
            }
        }
        return mm.quat_between({0,1,0},axis)
    }
    switch prim.type_name {
    case "Mesh":
        if mesh<0 {return true}
        purpose:=""
        if property,found:=prim.properties["purpose"];found {purpose=usd_string(property)}
        visible:=true
        if property,found:=prim.properties["visibility"];found {visible=usd_string(property)!="invisible"}
        made.only=purpose=="guide" || !visible
        if !made.only {made.target=row}
        approximation:=""
        if property,found:=prim.properties["physics:approximation"];found {approximation=usd_string(property)}
        switch approximation {
        case "","none","meshSimplification": made.shape=.Mesh
        case "convexHull":
            made.shape,made.points=.Points,mesh_points(r,mesh)
        case "convexDecomposition": made.shape=.Decompose
        case "boundingSphere","boundingCube":
            points:=mesh_points(r,mesh)
            if len(points)==0 {return true}
            low,high:=points[0],points[0]
            for p in points {low,high=linalg.min(low,p),linalg.max(high,p)}
            made.center=(low+high)*0.5
            if approximation=="boundingCube" {
                made.shape,made.size=.Box,(high-low)*0.5
            } else {
                radius:=f32(0)
                for p in points {radius=max(radius,linalg.length(p-made.center))}
                made.shape,made.size=.Sphere,{radius,0,0}
            }
        case:
            return importer.fail(r,.Unsupported,"%s: physics:approximation %s is not a UsdPhysics approximation",prim.path,approximation)
        }
    case "Cube":
        size:=number(r,prim,"size",2) or_return
        made.shape,made.size=.Box,{size,size,size}*0.5
    case "Sphere":
        made.shape=.Sphere
        made.size.x=number(r,prim,"radius",1) or_return
    case "Capsule":
        radius:=number(r,prim,"radius",0.5) or_return
        height:=number(r,prim,"height",1) or_return
        made.shape,made.size,made.rotation=.Capsule,{radius,height*0.5,0},axis_turn(prim)
    case "Cylinder","Cone":
        radius:=number(r,prim,"radius",1) or_return
        height:=number(r,prim,"height",2) or_return
        points:=make([dynamic][3]f32,context.temp_allocator)
        for k in 0..<ROUND_SEGMENTS {
            angle:=f32(k)*2*math.PI/ROUND_SEGMENTS
            append(&points,[3]f32{radius*math.cos(angle),-height*0.5,radius*math.sin(angle)})
            if prim.type_name=="Cylinder" {append(&points,[3]f32{radius*math.cos(angle),height*0.5,radius*math.sin(angle)})}
        }
        if prim.type_name=="Cone" {append(&points,[3]f32{0,height*0.5,0})}
        made.shape,made.points,made.rotation=.Points,points[:],axis_turn(prim)
    case:
        return importer.fail(r,.Unsupported,"%s: PhysicsCollisionAPI on a %s, which is no shape or mesh",prim.path,prim.type_name)
    }
    append(&r.colliders,made)
    return true
}

@(private="file")
mesh_points :: proc(r:^importer.Reader,mesh:int) -> [][3]f32 {
    vertices:=r.meshes[mesh].vertices
    out:=make([][3]f32,len(vertices),context.temp_allocator)
    for vertex,i in vertices {out[i]=vertex.position}
    return out
}
