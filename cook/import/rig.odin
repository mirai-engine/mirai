package importer

import "core:fmt"
import "core:math/linalg"
import "mirai:asset"
import "mirai:cook/rig"
import "mirai:std/base"
import mm "mirai:std/math"

// Gives a model the rig its settings ask for (Import_Settings.rig) in place
// of what its source has. The meshes are baked where they rest in the model,
// as the rig fits and binds them in its space: a mesh without skin where its
// node puts it, a skinned one where its own skin does at the bind (glTF skins
// ignore the mesh's node); the bones of the source leave with its skeletons,
// and so do its clips, which animate those bones.
@(private)
model_rig :: proc(model:^Imported_Model,settings:Import_Settings,caller:=context.temp_allocator) -> Error {
    if settings.rig==.Source {return {}}
    out:=base.dynamic_arena_allocator(model.arena)
    users:=make([]int,len(model.meshes),context.temp_allocator)
    for &user in users {user=-1}
    for node,i in model.nodes {
        if node.mesh<0 {continue}
        if users[node.mesh]>=0 {return error_make(.Unsupported,"%s: mesh %s is drawn by two nodes; a rig needs each mesh once, so join or duplicate them before export",model.source,model.meshes[node.mesh].name,allocator=caller)}
        users[node.mesh]=i
        for other in model.nodes {
            if other.parent==i {return error_make(.Unsupported,"%s: node %s has a mesh and children; a rig bakes the mesh into the model, so move its children out before export",model.source,node.name,allocator=caller)}
        }
    }
    bones:=make(map[u64]bool,context.temp_allocator)
    for skeleton in model.skeletons {
        for bone in skeleton.bones {bones[bone.target]=true}
    }
    warnings:=make([dynamic]string,out)
    append(&warnings,..model.warnings)
    if len(model.animations)>0 {append(&warnings,fmt.aprintf("%d clips of the source were left out: they animate its skeleton, which the rig replaces",len(model.animations),allocator=out))}
    model.animations=nil
    for &mesh,m in model.meshes {
        if mesh.skeleton>=0 && mesh.skeleton<len(model.skeletons) && len(mesh.joints)>0 && len(mesh.skin)==len(mesh.vertices) {
            mesh_rest(&mesh,model.skeletons[mesh.skeleton].bones)
        } else if users[m]>=0 {
            world:=model_node_world(model,users[m])
            mesh_bake(&mesh,world)
        }
        mesh.skin,mesh.joints,mesh.skeleton=nil,nil,-1
        mesh.flags-={.Skinned}
    }
    // Mesh nodes now sit at the root of the model; bones of the source go,
    // and what hung from them keeps its place under the nearest node that stays.
    keep:=make([]bool,len(model.nodes),context.temp_allocator)
    for node,i in model.nodes {
        _,light:=node.light.?
        keep[i]=node.mesh>=0 || light || node.target not_in bones
    }
    rows:=make([]int,len(model.nodes),context.temp_allocator)
    nodes:=make([dynamic]Imported_Node,out)
    for node,i in model.nodes {
        rows[i]=-1
        if !keep[i] {continue}
        moved:=node
        if node.mesh>=0 {
            moved.parent,moved.transform=-1,mm.TRANSFORM_IDENTITY
        } else {
            ancestor:=node.parent
            for ancestor>=0 && !keep[ancestor] {
                moved.transform=mm.transform_compose(model.nodes[ancestor].transform,moved.transform)
                ancestor=model.nodes[ancestor].parent
            }
            moved.parent=rows[ancestor] if ancestor>=0 else -1
        }
        rows[i]=len(nodes)
        append(&nodes,moved)
    }
    model.nodes=nodes[:]
    parts:=make([]rig.Mesh,len(model.meshes),context.temp_allocator)
    for mesh,m in model.meshes {
        positions:=make([][3]f32,len(mesh.vertices),context.temp_allocator)
        for vertex,v in mesh.vertices {positions[v]=vertex.position}
        parts[m]={positions=positions,indices=mesh.indices}
    }
    made:rig.Rig
    error:rig.Error
    switch settings.rig {
    case .Source:
    case .Humanoid: made,error=rig.humanoid(parts,{crotch=settings.rig_crotch,neck=settings.rig_neck},out)
    case .Fox:      made,error=rig.animal(parts,.Fox,out)
    case .Horse:    made,error=rig.animal(parts,.Horse,out)
    case .Bird:     made,error=rig.animal(parts,.Bird,out)
    case .Dragon:   made,error=rig.animal(parts,.Dragon,out)
    case .Kaiju:    made,error=rig.animal(parts,.Kaiju,out)
    case .Shark:    made,error=rig.animal(parts,.Shark,out)
    case .Snake:    made,error=rig.animal(parts,.Snake,out)
    case .Spider:   made,error=rig.animal(parts,.Spider,out)
    }
    if error!=.None {return error_make(.Malformed,"%s has no triangles to fit a rig to",model.source,allocator=caller)}
    skeleton:=Imported_Skeleton{name=fmt.aprintf("%s skeleton",model.name,allocator=out),bones=made.bones}
    model.skeletons=make([]Imported_Skeleton,1,out)
    model.skeletons[0]=skeleton
    for &mesh,m in model.meshes {
        mesh.skin,mesh.joints,mesh.skeleton=made.skins[m],made.joints,0
        mesh.flags+={.Skinned}
    }
    append(&warnings,..made.warnings)
    model.warnings=warnings[:]
    return {}
}

@(private="file")
model_node_world :: proc(model:^Imported_Model,node:int) -> mm.Transform {
    world:=model.nodes[node].transform
    for parent:=model.nodes[node].parent;parent>=0;parent=model.nodes[parent].parent {
        world=mm.transform_compose(model.nodes[parent].transform,world)
    }
    return world
}

// Moves the vertices of a skinned mesh where its skin puts them with the
// skeleton at rest: each by its joints' frames times their inverse binds.
@(private="file")
mesh_rest :: proc(mesh:^Imported_Mesh,bones:[]asset.Skeleton_Bone) {
    world:=make([]mm.Transform,len(bones),context.temp_allocator)
    for &bone,i in bones {
        world[i]={position=bone.translation,rotation=bone.rotation,scale=bone.scale}
        if bone.parent>=0 {world[i]=mm.transform_compose(world[bone.parent],world[i])}
    }
    frames:=make([]mm.Mat4,len(mesh.joints),context.temp_allocator)
    moved:=false
    for joint,k in mesh.joints {
        frames[k]=1
        if int(joint.node)<len(bones) {frames[k]=mm.transform_matrix(world[joint.node])*joint.inverse_bind}
        for c in 0..<4 {for r in 0..<4 {moved||=abs(frames[k][r,c]-(1 if r==c else 0))>1e-5}}
    }
    if !moved {return}
    blends:=make([]matrix[3,3]f32,len(mesh.vertices),context.temp_allocator)
    lo:=mm.Vec3{max(f32),max(f32),max(f32)}
    hi:=-lo
    flips:=0
    for &vertex,v in mesh.vertices {
        m:mm.Mat4
        total:f32
        for weight,k in mesh.skin[v].weights {
            if weight==0 || int(mesh.skin[v].joints[k])>=len(frames) {continue}
            m+=f32(weight)*frames[mesh.skin[v].joints[k]]
            total+=f32(weight)
        }
        if total<=0 {m,total=1,1}
        m=(1/total)*m
        linear:=matrix[3,3]f32{m[0,0],m[0,1],m[0,2], m[1,0],m[1,1],m[1,2], m[2,0],m[2,1],m[2,2]}
        blends[v]=linear
        determinant:=linalg.determinant(linear)
        if determinant<0 {flips+=1}
        p:=m*[4]f32{vertex.position.x,vertex.position.y,vertex.position.z,1}
        vertex.position=p.xyz
        // A frame without volume has no normal to give: the vertex keeps its own.
        if abs(determinant)<1e-12 {
            lo,hi=linalg.min(lo,vertex.position),linalg.max(hi,vertex.position)
            continue
        }
        vertex.normal=mm.normal_pack(linalg.normalize0(linalg.inverse_transpose(linear)*mm.normal_unpack(vertex.normal)))
        tangent,sign:=mm.tangent_unpack(vertex.tangent)
        vertex.tangent=mm.tangent_pack(linalg.normalize0(linear*tangent),-sign if determinant<0 else sign)
        lo,hi=linalg.min(lo,vertex.position),linalg.max(hi,vertex.position)
    }
    for &delta in mesh.morph_deltas {
        if int(delta.vertex)>=len(blends) {continue}
        linear:=blends[delta.vertex]
        if abs(linalg.determinant(linear))<1e-12 {continue}
        delta.position=linear*delta.position
        delta.normal=linalg.inverse_transpose(linear)*delta.normal
        delta.tangent=linear*delta.tangent
    }
    if 2*flips>len(mesh.vertices) {
        for i:=0;i+2<len(mesh.indices);i+=3 {mesh.indices[i+1],mesh.indices[i+2]=mesh.indices[i+2],mesh.indices[i+1]}
    }
    if len(mesh.vertices)>0 {mesh.bounds_min,mesh.bounds_max=lo,hi}
}

// Moves the geometry of a mesh into the space its node gives it.
@(private="file")
mesh_bake :: proc(mesh:^Imported_Mesh,world:mm.Transform) {
    if world==mm.TRANSFORM_IDENTITY {return}
    mirrored:=world.scale.x*world.scale.y*world.scale.z<0
    lo:=mm.Vec3{max(f32),max(f32),max(f32)}
    hi:=-lo
    for &vertex in mesh.vertices {
        vertex.position=mm.transform_point(world,vertex.position)
        vertex.normal=mm.normal_pack(linalg.normalize0(mm.transform_direction(world,mm.normal_unpack(vertex.normal)/world.scale)))
        tangent,sign:=mm.tangent_unpack(vertex.tangent)
        vertex.tangent=mm.tangent_pack(linalg.normalize0(mm.transform_vector(world,tangent)),-sign if mirrored else sign)
        lo,hi=linalg.min(lo,vertex.position),linalg.max(hi,vertex.position)
    }
    for &delta in mesh.morph_deltas {
        delta.position=mm.transform_vector(world,delta.position)
        delta.normal=mm.transform_direction(world,delta.normal/world.scale)
        delta.tangent=mm.transform_vector(world,delta.tangent)
    }
    if mirrored {
        for i:=0;i+2<len(mesh.indices);i+=3 {mesh.indices[i+1],mesh.indices[i+2]=mesh.indices[i+2],mesh.indices[i+1]}
    }
    if len(mesh.vertices)>0 {mesh.bounds_min,mesh.bounds_max=lo,hi}
    for &collider in mesh.collision.colliders {
        collider.center=mm.transform_point(world,collider.center)
        collider.rotation=world.rotation*collider.rotation
        collider.size*=linalg.abs(world.scale)
    }
    for &point in mesh.collision.points {point=mm.transform_point(world,point)}
}
