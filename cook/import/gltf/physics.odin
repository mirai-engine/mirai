package gltf

import "core:encoding/json"
import "core:math"
import cg "vendor:cgltf"
import importer "mirai:cook/import"

// The collision a glTF authors, as the colliders of the meshes it is for:
// KHR_physics_rigid_bodies with the shapes of KHR_implicit_shapes, and
// OMI_physics_body with those of OMI_physics_shape. A collider of a node
// that shows a mesh is of that mesh; one of a node that shows none is
// collision only, and collides for the nearest mesh (importer.colliders_resolve).
// Bodies that move and triggers are left out with a warning: what moves is
// said by the Rigid_Body of the entity, and a trigger is a sensor.

@(private)
Gltf_Physics :: struct {
    khr,omi:[]Physics_Shape,
    motions,triggers,planes:int,
}

@(private)
Physics_Shape :: struct {
    kind:enum u8 {None,Box,Sphere,Capsule,Cylinder,Plane,Convex,Trimesh},
    size:[3]f32,
    radius_top,radius_bottom,height:f32,
    mesh:int,
}

// Segments around the round shapes a hull stands for (a tapered capsule, a cylinder).
@(private="file") ROUND_SEGMENTS :: 16

@(private)
physics_shapes :: proc(g:^Gltf) -> bool {
    data:=g.data
    for e in data.data_extensions[:data.data_extensions_count] {
        name:=string(e.name)
        if name!="KHR_implicit_shapes" && name!="OMI_physics_shape" {continue}
        value,error:=json.parse_string(string(cstring(e.data)),allocator=context.temp_allocator)
        if error!=nil {return importer.fail(g.r,.Malformed,"glTF %s is not JSON",name)}
        listed,_:=field(value,"shapes").(json.Array)
        shapes:=make([]Physics_Shape,len(listed),context.temp_allocator)
        for item,i in listed {
            shape:=&shapes[i]
            shape.mesh=-1
            kind,_:=field(item,"type").(json.String)
            body:=field(item,kind)
            switch kind {
            case "box":
                size,_:=field(body,"size").(json.Array)
                shape.kind,shape.size=.Box,{1,1,1}
                if len(size)==3 {for k in 0..<3 {shape.size[k]=f32(number(size[k],1))}}
            case "sphere":
                shape.kind,shape.size.x=.Sphere,f32(number(field(body,"radius"),0.5))
            case "capsule","cylinder":
                shape.kind=.Capsule if kind=="capsule" else .Cylinder
                radius:=number(field(body,"radius"),0.5)
                shape.radius_top=f32(number(field(body,"radiusTop"),radius))
                shape.radius_bottom=f32(number(field(body,"radiusBottom"),radius))
                shape.height=f32(number(field(body,"height"),1 if kind=="capsule" else 2))
            case "plane":
                shape.kind=.Plane
            case "convex","hull","trimesh":
                shape.kind=.Trimesh if kind=="trimesh" else .Convex
                shape.mesh=int(number(field(body,"mesh"),-1))
            }
            for v in ([]f32{shape.size.x,shape.size.y,shape.size.z,shape.radius_top,shape.radius_bottom,shape.height}) {
                if !(v>=0) || v-v!=0 {return importer.fail(g.r,.Malformed,"glTF %s shape %d has a size that is negative or not finite",name,i)}
            }
        }
        if name=="KHR_implicit_shapes" {g.physics.khr=shapes} else {g.physics.omi=shapes}
    }
    return true
}

// The collider the node at row authors, added to the colliders of the reader.
@(private)
physics_node :: proc(g:^Gltf,node:^cg.node,row:int) -> bool {
    r:=g.r
    for e in node.extensions[:node.extensions_count] {
        name:=string(e.name)
        khr:=name=="KHR_physics_rigid_bodies"
        if !khr && name!="OMI_physics_body" {continue}
        value,error:=json.parse_string(string(cstring(e.data)),allocator=context.temp_allocator)
        if error!=nil {return importer.fail(r,.Malformed,"glTF node %s: %s is not JSON",node_label(node),name)}
        if field(value,"motion")!=nil {g.physics.motions+=1}
        if field(value,"trigger")!=nil {g.physics.triggers+=1}
        collider:=field(value,"collider")
        if collider==nil {continue}
        shapes:=g.physics.omi
        geometry:=collider
        if khr {
            shapes=g.physics.khr
            if inner:=field(collider,"geometry");inner!=nil {geometry=inner}
        }
        shape_index:=int(number(field(geometry,"shape"),-1))
        mesh_index:=int(number(field(geometry,"mesh"),-1))
        convex,_:=field(geometry,"convexHull").(json.Boolean)
        made:=importer.Source_Collider{placed=row,target=-1,rotation=1,mesh=-1,only=node.mesh==nil}
        if !made.only {made.target=row}
        by_mesh:=shape_index<0
        if shape_index>=0 {
            if shape_index>=len(shapes) {return importer.fail(r,.Malformed,"glTF node %s names physics shape %d of %d",node_label(node),shape_index,len(shapes))}
            shape:=shapes[shape_index]
            switch shape.kind {
            case .None: continue
            case .Plane:
                g.physics.planes+=1
                continue
            case .Box: made.shape,made.size=.Box,shape.size*0.5
            case .Sphere: made.shape,made.size=.Sphere,{shape.size.x,0,0}
            case .Capsule,.Cylinder:
                if shape.kind==.Capsule && shape.radius_top==shape.radius_bottom {
                    made.shape,made.size=.Capsule,{shape.radius_top,shape.height*0.5,0}
                } else {
                    made.shape,made.points=.Points,round_points(shape)
                }
            case .Convex,.Trimesh:
                mesh_index,by_mesh=shape.mesh,true
                convex=shape.kind==.Convex
            }
        }
        if by_mesh {
            if mesh_index<0 || mesh_index>=len(g.data.meshes) {return importer.fail(r,.Malformed,"glTF node %s has a collider without a shape or a mesh of the file",node_label(node))}
            mesh:=&g.data.meshes[mesh_index]
            if node.mesh==mesh && r.nodes[row].mesh>=0 {
                made.mesh=r.nodes[row].mesh
            } else {
                found:bool
                made.mesh,found=g.mesh_rows[mesh]
                if !found {
                    built:bool
                    made.mesh,built=gltf_mesh(g,mesh,nil,node)
                    if !built {return false}
                    g.mesh_rows[mesh]=made.mesh
                }
            }
            made.shape=.Hull if convex else .Mesh
        }
        append(&r.colliders,made)
    }
    return true
}

@(private)
physics_report :: proc(g:^Gltf) {
    p:=g.physics
    if p.motions>0 {importer.warn(g.r,"%d glTF bodies that move are imported as their colliders: give their entities a Rigid_Body",p.motions)}
    if p.triggers>0 {importer.warn(g.r,"%d glTF triggers are left out: a trigger is a Collider with sensor set",p.triggers)}
    if p.planes>0 {importer.warn(g.r,"%d glTF plane shapes are left out: a collider is a box, sphere, capsule or hull",p.planes)}
}

// The points a tapered capsule or a cylinder is the convex hull of, along Y.
@(private="file")
round_points :: proc(shape:Physics_Shape) -> [][3]f32 {
    out:=make([dynamic][3]f32,context.temp_allocator)
    half:=shape.height*0.5
    ring :: proc(out:^[dynamic][3]f32,y,radius:f32) {
        if radius<=0 {
            append(out,[3]f32{0,y,0})
            return
        }
        for k in 0..<ROUND_SEGMENTS {
            angle:=f32(k)*2*math.PI/ROUND_SEGMENTS
            append(out,[3]f32{radius*math.cos(angle),y,radius*math.sin(angle)})
        }
    }
    if shape.kind==.Cylinder {
        ring(&out,-half,shape.radius_bottom)
        ring(&out,half,shape.radius_top)
        return out[:]
    }
    // A capsule: its two spheres, by rings of latitude.
    for side in 0..<2 {
        y,radius:=(f32(side)*2-1)*half,side==0?shape.radius_bottom:shape.radius_top
        for step in 0..=ROUND_SEGMENTS/4 {
            latitude:=f32(step)*math.PI*0.5/(ROUND_SEGMENTS/4)
            ring(&out,y+(f32(side)*2-1)*radius*math.sin(latitude),radius*math.cos(latitude))
        }
    }
    return out[:]
}

@(private="file")
field :: proc(value:json.Value,name:string) -> json.Value {
    object,is_object:=value.(json.Object)
    if !is_object {return nil}
    return object[name]
}

@(private="file")
number :: proc(value:json.Value,fallback:f64) -> f64 {
    #partial switch v in value {
    case json.Float: return v
    case json.Integer: return f64(v)
    }
    return fallback
}
