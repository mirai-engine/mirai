package vfx

import "core:math/linalg"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"

// The bones of a skinned mesh, as segments particles start on and follow:
// from the joint of each parent bone to its own, posed by the palette the
// renderer deforms its skin with in this frame and in the one before. Only
// the joints that move vertices count: the bones that help a rig (an IK
// target, a root on the ground) deform nothing and would start particles
// away from the body. What each joint is (its parent among them and where it
// is in the bind pose) is read from the mesh and its skeleton the first time
// (a load transaction); a mesh no entity poses is its bind pose.

// A rig a world read, by its mesh.
Bone_Rig :: struct {
    mesh:base.Asset_Id,
    joints:[]Bone_Joint, // by joint of the palette; none: the mesh has no bones, or they did not load
}

Bone_Joint :: struct {
    parent:i32,  // the joint of its nearest parent bone that moves vertices; -1: none, or it moves none: it starts no bone
    bind:[3]f32, // where it is in the bind pose, in the space of the mesh
}

// shaders/particles.slang: Particle_Segment, in the space of the mesh.
Gpu_Segment :: struct {
    start:[3]f32, length:f32, // length: of the bones up to this one, added up
    end:[3]f32, pad0:u32,
    previous_start:[3]f32, pad1:u32,
    previous_end:[3]f32, pad2:u32,
}
#assert(size_of(Gpu_Segment)==64)

bone_rigs_free :: proc(rigs:^[dynamic]Bone_Rig) {
    for &rig in rigs {delete(rig.joints)}
    delete(rigs^)
    rigs^=nil
}

// The rig of a mesh: read once; one that failed stays without joints.
@(private)
bone_rig :: proc(rigs:^[dynamic]Bone_Rig,assets:^host.Assets,mesh:base.Asset_Id) -> ^Bone_Rig {
    if mesh=={} || assets==nil {return nil}
    for &rig in rigs {
        if rig.mesh==mesh {return &rig}
    }
    joints:=bone_rig_read(assets,mesh)
    if _,error:=append(rigs,Bone_Rig{mesh=mesh,joints=joints});error!=nil {
        delete(joints)
        return nil
    }
    return &rigs[len(rigs)-1]
}

@(private)
bone_rig_read :: proc(assets:^host.Assets,mesh:base.Asset_Id) -> []Bone_Joint {
    file:asset.Asset
    if host.assets_file(assets,mesh,asset.KIND_MESH,&file)!=.None {return nil}
    defer asset.asset_close(&file)
    view,error:=asset.mesh_view(&file,&assets.types)
    if error!=.None || len(view.joints)==0 || view.info.skeleton=={} {return nil}
    skeleton_file:asset.Asset
    if host.assets_file(assets,view.info.skeleton,asset.KIND_SKELETON,&skeleton_file)!=.None {return nil}
    defer asset.asset_close(&skeleton_file)
    skeleton,skeleton_error:=asset.skeleton_view(&skeleton_file,&assets.types)
    if skeleton_error!=.None {return nil}
    // The joints that move some vertex.
    moves:=make([]bool,len(view.joints),context.temp_allocator)
    for vertex in view.skin {
        for weight,i in vertex.weights {
            if weight>0 && int(vertex.joints[i])<len(moves) {moves[vertex.joints[i]]=true}
        }
    }
    // The joint of each bone of the skeleton; -1 for one the skin does not name or that moves nothing.
    of_bone:=make([]i32,len(skeleton.bones),context.temp_allocator)
    for &joint in of_bone {joint=-1}
    for joint,at in view.joints {
        if int(joint.node)<len(of_bone) && moves[at] {of_bone[joint.node]=i32(at)}
    }
    joints,made:=make([]Bone_Joint,len(view.joints))
    if made!=nil {return nil}
    for joint,at in view.joints {
        bind:=linalg.inverse(joint.inverse_bind)
        joints[at]={parent=-1,bind={bind[0,3],bind[1,3],bind[2,3]}}
        if int(joint.node)>=len(skeleton.bones) || !moves[at] {continue}
        // The nearest bone above it that the skin names.
        for parent:=skeleton.bones[joint.node].parent;parent>=0 && int(parent)<len(skeleton.bones);parent=skeleton.bones[parent].parent {
            if of_bone[parent]>=0 {joints[at].parent=of_bone[parent];break}
        }
    }
    return joints
}

// The posed bones of a rig after those of the frame: by the palette of the
// skin the renderer deforms (none: its bind pose). first and count: its
// bones among those of the frame.
@(private)
bones_pose :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,rig:^Bone_Rig,skin:erender.Mesh_Handle,posed:bool) -> (first,count:u32,ok:bool) {
    joints:=len(rig.joints)
    if joints==0 {return}
    current,previous:[][3][4]f32
    if posed {
        if resize(&sync.palette,2*joints)!=nil {return}
        current,previous=sync.palette[:joints],sync.palette[joints:]
        known,read:=erender.skin_palette(renderer,skin,current,previous)
        if !read || known!=joints {current,previous=nil,nil}
    }
    place :: proc(palette:[][3][4]f32,at:int,bind:[3]f32) -> [3]f32 {
        if palette==nil {return bind}
        m:=palette[at]
        return {
            m[0].x*bind.x+m[0].y*bind.y+m[0].z*bind.z+m[0].w,
            m[1].x*bind.x+m[1].y*bind.y+m[1].z*bind.z+m[1].w,
            m[2].x*bind.x+m[2].y*bind.y+m[2].z*bind.z+m[2].w,
        }
    }
    first=u32(len(sync.segments))
    length:f32
    for joint,at in rig.joints {
        if joint.parent<0 {continue}
        parent:=int(joint.parent)
        segment:=Gpu_Segment{
            start=place(current,parent,rig.joints[parent].bind),end=place(current,at,joint.bind),
            previous_start=place(previous,parent,rig.joints[parent].bind),previous_end=place(previous,at,joint.bind),
        }
        length+=linalg.length(segment.end-segment.start)
        segment.length=length
        if _,error:=append(&sync.segments,segment);error!=nil {
            base.truncate(&sync.segments,int(first))
            return 0,0,false
        }
    }
    count=u32(len(sync.segments))-first
    // Bones of no length give nothing to start on.
    if count==0 || length<=0 {
        base.truncate(&sync.segments,int(first))
        return 0,0,false
    }
    return first,count,true
}

// The bones of the mesh an entity draws, posed as the renderer draws its
// skin; without the scene of its world in the renderer, its Mesh_Renderer
// where it is, in its bind pose.
@(private)
entity_bones :: proc(sync:^Particle_Sync,drawn:^erender.Render_Sync,meshes:^core.Table(erender.Mesh_Renderer,$A),worlds:^core.Table(core.World_Transform,$B),id:core.World_Id,assets:^host.Assets,renderer:^erender.Renderer,e:core.Entity) -> Resource_Desc {
    shown,has_mesh:=core.get(meshes,e)
    if !has_mesh {return {}}
    rig:=bone_rig(&sync.rigs,assets,shown.mesh)
    if rig==nil {return {}}
    if drawn!=nil && drawn.world==id {
        // The mesh its instance shows is its skin, when a library poses it.
        if at:=core.entity_map_index(&drawn.drawn,e);at>=0 {
            if mesh,transform,held:=erender.instance_placed(renderer,at);held {return bones_of(sync,renderer,rig,mesh,transform,true)}
        }
    }
    world,placed:=core.get(worlds,e)
    if !placed {return {}}
    return bones_of(sync,renderer,rig,0,mm.transform_matrix(world.transform),false)
}

// The bones of a mesh asset at a transform, in its bind pose.
@(private)
asset_bones :: proc(sync:^Particle_Sync,assets:^host.Assets,renderer:^erender.Renderer,mesh:base.Asset_Id,transform:mm.Mat4) -> Resource_Desc {
    rig:=bone_rig(&sync.rigs,assets,mesh)
    if rig==nil {return {}}
    return bones_of(sync,renderer,rig,0,transform,false)
}

@(private)
bones_of :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,rig:^Bone_Rig,skin:erender.Mesh_Handle,transform:mm.Mat4,posed:bool) -> Resource_Desc {
    first,count,ok:=bones_pose(sync,renderer,rig,skin,posed)
    if !ok {return {}}
    return {kind=.Bones,first=first,count=count,transform=transform}
}
