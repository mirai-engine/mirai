package mirai_render

import "core:math"
import "core:math/linalg"
import "core:mem"
import "mirai:asset"
import "mirai:rhi"
import "mirai:std/base"

// The influences of a vertex as a mesh stores them: eight joints and their
// weights in 255ths that add up to 255.
Skin_Influence :: asset.Skin_Vertex

// The morph targets of a pose, by vertex: the deltas of a vertex are a range
// of deltas, by target, each what its target at weight 1 adds before skinning.
// A delta is quantized as a mesh stores it (asset.Morph_Cluster_Delta), its
// position in steps of step, and skin.comp reads it as it is.
Morph_Range :: struct {first,count:u32}
Morph_Delta :: struct {
    target:u32,
    position,normal:[3]i16,
    tangent:u32,
}
#assert(size_of(Morph_Delta)==size_of(asset.Morph_Cluster_Delta) && offset_of(Morph_Delta,tangent)==offset_of(asset.Morph_Cluster_Delta,tangent))
Morph_Data :: struct {ranges:[]Morph_Range,deltas:[]Morph_Delta,count:u32,step:f32}
MORPH_MAX_TARGETS :: 256

// The part of a pose that a view which does not draw its layers draws
// collapsed: the palette that collapses it, as a scale of zero on its bones
// does, and the layers it is in.
Skin_Part_Pose :: struct {palette:[]Mat4,layers:u32}

// Refits of the native BLAS of a pose before it is built again over the shape it has then.
SKIN_REBUILD_INTERVAL :: 120

@(private) Skin_Joint :: struct {current,previous:[3]Vec4}
// skin.comp: mesh is the row of the mesh table it reads clusters from,
// clusters those it poses, output and previous words of the vertex pool.
@(private) Skin_Params :: struct {mesh,clusters,output,previous,morph_count:u32,morph_step:f32,pad:[2]u32}
// How far the deltas of a target move the vertices of a joint, at weight 1.
@(private) Morph_Joint_Bounds :: struct {joint,target:u32,lo,hi:Vec3}
// The threads of a batched pass from start on work on one pose. Triangles:
// x its mesh, z its first triangle. Refit: its root, its triangle offset and
// the first node of the level.
@(private) Skin_Job :: struct {x,y,z,start:u32}
@(private) Skin_Jobs_Params :: struct {first,count,total,pad:u32}
@(private) Skin_Bounds :: struct {lo,hi:Vec3}
@(private) Skin_Binding :: struct {
    source:rhi.Buffer, // the influences of the vertices it poses
    morph_ranges,morph_deltas:rhi.Buffer,
    morph:Morph_Data,
    morph_bounds:[]Morph_Joint_Bounds,
    influences:[]Skin_Influence,
    bounds:[]Skin_Bounds,
    levels:[BVH_MAX_DEPTH+1]Pool_Range, // the nodes of each depth of a pose, whose tree is stored breadth first
    references:u32,
    uploading:bool, // its buffers wait for the copies of the CPU: skin_binding_upload, or a pose that goes over frames
    allocator:mem.Allocator,
}
// A pose: a mesh whose vertices change on the GPU, with its own copy of the
// clusters, of where they are posed (current, then previous: Gpu_Posed_Vertex
// in the vertex pool), of the tree of its triangles and of its native BLAS.
// Skinning writes those of a skinned one from its joints; an extension writes
// those of an external one in the Geometry stage of the frame, from the rest
// vertices that follow them; the vertex functions of the programs of its
// instance write those of a displaced one from the rest of its clusters, and
// move those of a skinned one after its skin (displace.odin).
@(private) Skin_State :: struct {
    binding:^Skin_Binding,
    joints:[]Skin_Joint,
    part_joints:[]Skin_Joint, // those that collapse its part; nil without one
    part_layers:u32,
    morph_weights:[]Vec2, // current and previous, by target
    bounds:[]Skin_Bounds, // of each joint with its morph targets at their weights
    refits:u32, // of its native BLAS since it was last built
    dirty,bounds_dirty,settle:bool,
    external:bool,
    vertices:u32, // that an extension writes in an external one: of its first level, or of each of its levels
    displaced:bool, // of an instance whose material programs move the vertices of source
    moves:bool,     // a skinned one whose instance has programs that move its vertices after its skin
    fresh:bool,     // displaced and not written yet: its previous vertices take the first ones too
    source:Mesh_Handle, // of a displaced one
    reach:f32,      // how far those programs move a vertex, in its own space: the boxes of its instances grow by it
    inputs:u64,     // what its vertices were last moved from (displaced_prepare)
    allocator:mem.Allocator,
}

@(private)
skin_influences_valid :: proc(influences:[]Skin_Influence,joint_count:u32)->bool {
    if joint_count==0 || joint_count>65536 {return false}
    for influence in influences {
        total:u32
        for weight,i in influence.weights {
            if weight>0 && u32(influence.joints[i])>=joint_count {return false}
            total+=u32(weight)
        }
        if total!=255 {return false}
    }
    return true
}

@(private)
skin_palette_valid :: proc(palette:[]Mat4)->bool {
    for transform in palette {
        for column in 0..<4 {for row in 0..<4 {if math.is_nan(transform[row,column]) || math.is_inf(transform[row,column]) {return false}}}
        if abs(transform[3,0])+abs(transform[3,1])+abs(transform[3,2])+abs(transform[3,3]-1)>1e-5 {return false}
    }
    return true
}

// The deltas of a pose without targets are not read: the source stands in for their buffers.
@(private)
Skin_Morph_Buffers :: struct {ranges,deltas,weights:rhi.Buffer,weights_offset:u64,count:u32,step:f32}

// Poses the clusters of a mesh of the table bound at SLOT_MESHES, reading
// its clusters and vertices from the pools bound there too.
@(private)
skin_dispatch :: proc(r:^Renderer,cmd:^rhi.Command_List,source,palette:rhi.Buffer,palette_offset:u64,meshes,vertices,indices:rhi.Buffer,params:Skin_Params,constants:rhi.Buffer=0,morph:Skin_Morph_Buffers={}) {
    params:=params
    params.morph_count,params.morph_step=morph.count,morph.step
    rhi.cmd_bind_pipeline(cmd,r.pipelines[.Skin])
    rhi.cmd_bind_buffer(cmd,SLOT_PASS0,source)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS1,palette,palette_offset)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS2,morph.ranges if morph.count>0 else source)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS3,morph.deltas if morph.count>0 else source)
    rhi.cmd_bind_buffer(cmd,SLOT_PASS4,morph.weights if morph.count>0 else source,morph.weights_offset)
    rhi.cmd_bind_buffer(cmd,SLOT_MESHES,meshes)
    rhi.cmd_bind_buffer(cmd,SLOT_VERTICES,vertices)
    rhi.cmd_bind_buffer(cmd,SLOT_INDICES,indices)
    if constants!=0 {rhi.cmd_bind_buffer(cmd,SLOT_PARAMS,constants)} else {set_params(cmd,&params)}
    rhi.cmd_dispatch(cmd,params.clusters,1)
}

@(private)
skin_free :: proc(r:^Renderer,skin:^Skin_State) {
    if skin==nil {return}
    skin_binding_release(r,skin.binding)
    delete(skin.joints,skin.allocator);delete(skin.part_joints,skin.allocator)
    delete(skin.morph_weights,skin.allocator);delete(skin.bounds,skin.allocator)
    free(skin,skin.allocator)
}

@(private)
skin_binding_release :: proc(r:^Renderer,binding:^Skin_Binding) {
    if binding==nil {return}
    binding.references-=1
    if binding.references!=0 {return}
    if binding.source!=0 {rhi.buffer_destroy(r.device,binding.source)}
    if binding.morph_ranges!=0 {rhi.buffer_destroy(r.device,binding.morph_ranges)}
    if binding.morph_deltas!=0 {rhi.buffer_destroy(r.device,binding.morph_deltas)}
    delete(binding.morph.ranges,binding.allocator);delete(binding.morph.deltas,binding.allocator);delete(binding.morph_bounds,binding.allocator)
    delete(binding.influences,binding.allocator);delete(binding.bounds,binding.allocator)
    free(binding,binding.allocator)
}

// Ranges that cover the deltas one after another, each delta of a target of
// the pose, after the target of the delta before it in its range, on a step
// that is a positive finite number.
@(private)
skin_morph_valid :: proc(morph:Morph_Data,vertices:int) -> bool {
    if morph.count==0 {return len(morph.ranges)==0 && len(morph.deltas)==0}
    if morph.count>MORPH_MAX_TARGETS || len(morph.ranges)!=vertices {return false}
    if !(morph.step>0) || math.is_inf(morph.step) {return false}
    used:u64
    for range in morph.ranges {
        if u64(range.first)!=used || u64(range.first)+u64(range.count)>u64(len(morph.deltas)) {return false}
        for delta,i in morph.deltas[range.first:][:range.count] {
            if delta.target>=morph.count || i>0 && delta.target<=morph.deltas[int(range.first)+i-1].target {return false}
        }
        used+=u64(range.count)
    }
    return used==u64(len(morph.deltas))
}

@(private)
skin_morph_equal :: proc(a,b:Morph_Data) -> bool {
    return a.count==b.count && a.step==b.step && len(a.ranges)==len(b.ranges) && len(a.deltas)==len(b.deltas) &&
        mem.compare(slice_bytes(a.ranges),slice_bytes(b.ranges))==0 && mem.compare(slice_bytes(a.deltas),slice_bytes(b.deltas))==0
}

// The targets of a binding: its copy of the deltas, their buffers, and how
// far each target moves the vertices of each joint.
@(private)
skin_morph_binding :: proc(r:^Renderer,binding:^Skin_Binding,morph:Morph_Data) -> bool {
    if morph.count==0 {return true}
    error:mem.Allocator_Error
    binding.morph.count,binding.morph.step=morph.count,morph.step
    binding.morph.ranges,error=make([]Morph_Range,len(morph.ranges),r.allocator);if error!=nil {return false}
    binding.morph.deltas,error=make([]Morph_Delta,len(morph.deltas),r.allocator);if error!=nil {return false}
    copy(binding.morph.ranges,morph.ranges);copy(binding.morph.deltas,morph.deltas)
    bounds:=make([dynamic]Morph_Joint_Bounds,r.allocator);defer delete(bounds)
    rows:=make(map[u64]int,r.allocator);defer delete(rows)
    for range,v in morph.ranges {
        influence:=binding.influences[v]
        for delta in morph.deltas[range.first:][:range.count] {
            if delta.position=={} {continue}
            for weight,k in influence.weights {
                if weight==0 {continue}
                joint:=u32(influence.joints[k])
                key:=u64(delta.target)<<32|u64(joint)
                row,found:=rows[key]
                if !found {
                    row=len(bounds)
                    if _,appended:=append(&bounds,Morph_Joint_Bounds{joint=joint,target=delta.target});appended!=nil {return false}
                    if map_insert(&rows,key,row)==nil {return false}
                }
                position:=asset.morph_position(delta.position,morph.step)
                bounds[row].lo=linalg.min(bounds[row].lo,position);bounds[row].hi=linalg.max(bounds[row].hi,position)
            }
        }
    }
    binding.morph_bounds,error=make([]Morph_Joint_Bounds,len(bounds),r.allocator);if error!=nil {return false}
    copy(binding.morph_bounds,bounds[:])
    binding.morph_ranges=rhi.buffer_create(r.device,{size=u64(len(morph.ranges))*size_of(Morph_Range),usage={.Storage},name="morph vertex ranges"})
    binding.morph_deltas=rhi.buffer_create(r.device,{size=u64(max(1,len(morph.deltas)))*size_of(Morph_Delta),usage={.Storage},name="morph deltas"})
    return binding.morph_ranges!=0 && binding.morph_deltas!=0
}

// The influences of a pose and how far the vertices of each joint reach at
// rest, in its own buffer of influences, which waits for them
// (Skin_Binding.uploading).
@(private)
skin_binding_create :: proc(r:^Renderer,original:Mesh_Record,influences:[]Skin_Influence,joint_count:u32,morph:Morph_Data)->^Skin_Binding {
    binding,error:=new(Skin_Binding,r.allocator)
    if error!=nil {return nil}
    binding.allocator=r.allocator;binding.references=1
    success:=false
    defer if !success {skin_binding_release(r,binding)}
    binding.bounds,error=make([]Skin_Bounds,int(joint_count),r.allocator)
    if error!=nil {return nil}
    binding.influences,error=make([]Skin_Influence,len(influences),r.allocator)
    if error!=nil {return nil}
    copy(binding.influences,influences)
    for &bounds in binding.bounds {bounds.lo,bounds.hi=EMPTY_BOUNDS_MIN,EMPTY_BOUNDS_MAX}
    p:=record_pooled(&r.scene,original)
    for whole,ordinal in p.clusters {
        g,c,resident:=pooled_cluster(p,u32(ordinal))
        if !resident {continue}
        for local in 0..<asset.cluster_vertex_count(c) {
            index:=int(whole.vertex_first+local)
            if index>=len(influences) {continue}
            position:=asset.cluster_position(g,c,local)
            for weight,j in influences[index].weights {
                if weight==0 {continue}
                bounds:=&binding.bounds[influences[index].joints[j]]
                bounds.lo=linalg.min(bounds.lo,position);bounds.hi=linalg.max(bounds.hi,position)
            }
        }
    }
    binding.source=rhi.buffer_create(r.device,{size=u64(len(influences)*size_of(Skin_Influence)),usage={.Storage},name="skin influences"})
    if binding.source==0 || !skin_morph_binding(r,binding,morph) {return nil}
    binding.uploading=true
    success=true
    return binding
}

// The copies of the CPU of a binding into its buffers, as a transaction.
@(private)
skin_binding_upload :: proc(r:^Renderer,binding:^Skin_Binding) -> bool {
    if !binding.uploading {return true}
    copies,copies_error:=make([dynamic]Geometry_Copy,0,3,r.allocator)
    if copies_error!=nil {set_error(r,"skin binding: out of memory for its upload");return false}
    defer delete(copies)
    append(&copies,Geometry_Copy{binding.source,0,slice_bytes(binding.influences)})
    if binding.morph_ranges!=0 {append(&copies,Geometry_Copy{binding.morph_ranges,0,slice_bytes(binding.morph.ranges)})}
    if binding.morph_deltas!=0 && len(binding.morph.deltas)>0 {append(&copies,Geometry_Copy{binding.morph_deltas,0,slice_bytes(binding.morph.deltas)})}
    if !geometry_copies_commit(r,copies[:],nil) {return false}
    binding.uploading=false
    return true
}

// Copies a tree breadth first: the nodes of each depth follow one another
// from the root and the children of a node stay together, so a refit runs a
// level at a time over contiguous nodes. False for a tree deeper than levels.
@(private)
bvh_breadth_first :: proc(nodes,out:[]Gpu_Bvh_Node,levels:^[BVH_MAX_DEPTH+1]Pool_Range)->bool {
    if len(nodes)==0 || len(out)!=len(nodes) {return false}
    out[0]=nodes[0]
    head,next:=0,1
    for &level in levels {
        level={u32(head),u32(next-head)}
        end:=next
        for &node in out[head:end] {
            if node.count!=0 {continue}
            if int(node.left_first)+1>=len(nodes) || next+1>=len(out) {return false}
            out[next],out[next+1]=nodes[node.left_first],nodes[node.left_first+1]
            node.left_first=u32(next)
            next+=2
        }
        head=end
    }
    return head==len(out)
}

// The tree of level 0 of a pose, which mesh_rays_complete just made, stored
// breadth first where it is, so that its refit runs a level at a time.
@(private)
pose_tree_breadth_first :: proc(r:^Renderer,m:^Mesh_Record)->bool {
    s:=&r.scene
    ray:=&m.rays[0]
    if ray.bvh_node_count==0 || m.skin==nil {return true}
    nodes:=s.blas_nodes[ray.bvh_root:][:ray.bvh_node_count]
    depth_first,depth_first_error:=make([]Gpu_Bvh_Node,len(nodes),r.allocator)
    if depth_first_error!=nil {set_error(r,"pose tree of %d nodes: out of memory",len(nodes));return false}
    defer delete(depth_first,r.allocator)
    copy(depth_first,nodes)
    if !bvh_breadth_first(depth_first,nodes,&m.skin.binding.levels) {return false}
    m.skin.dirty=true
    return true
}

// The vertices of level 0 of a mesh, the first of its vertices, and its clusters.
@(private)
level0_vertices :: proc(s:^Scene_State,m:Mesh_Record)->(vertices,clusters:u32) {
    _,clusters=record_level(s,m,0)
    if clusters==m.cluster_count {return m.vertex_count,clusters}
    return s.indices[m.cluster_word+clusters*CLUSTER_WORDS+3],clusters
}

// The clusters a pose poses: those of level 0, or all of them.
@(private)
posed_clusters :: proc(s:^Scene_State,m:Mesh_Record)->u32 {
    if m.flags&MESH_FLAG_LEVEL0==0 {return m.cluster_count}
    _,clusters:=record_level(s,m,0)
    return clusters
}

// The words of the blocks of the pages of a pose of a mesh: a streamed mesh
// has its pages out of the root elsewhere, and its pose holds every one.
@(private)
pose_blocks :: proc(original:Mesh_Record) -> (blocks:int) {
    if original.stream==nil {return int(original.vertex_span)}
    for page in original.stream.pages {blocks+=int(page.words)}
    return
}

// What a pose of streams runs of posed vertices gives the pools, and the
// buffers of a binding that is not on the GPU yet.
@(private)
pose_bytes :: proc(original:Mesh_Record,posed:u32,streams:int,binding:^Skin_Binding) -> (bytes:u64) {
    bytes=u64(pose_blocks(original)+streams*int(posed)*POSED_WORDS+int(original.index_span))*size_of(u32)
    bytes+=u64(original.rays[0].bvh_node_count)*size_of(Gpu_Bvh_Node)+u64(original.rays[0].triangle_count)*size_of(Gpu_Bvh_Triangle)
    if binding.uploading {bytes+=u64(len(slice_bytes(binding.influences))+len(slice_bytes(binding.morph.ranges))+len(slice_bytes(binding.morph.deltas)))}
    return
}

// A copy of the clusters of a mesh, posed: after its own blocks come
// `streams` runs of posed vertices (current, previous, then those of a part
// or the rest an extension deforms from), each filled with the vertices at
// rest. Its software tree is that of level 0 of the source, breadth first.
@(private)
pose_store :: proc(r:^Renderer,original:Mesh_Record,posed:u32,streams:int,skin:^Skin_State)->(Mesh_Handle,bool) {
    s:=&r.scene
    words:=int(posed)*POSED_WORDS
    // A streamed mesh has its pages out of the root elsewhere: its pose holds every one.
    blocks:=pose_blocks(original)
    if !pool_room(r,.Vertex,blocks+streams*words) || !pool_room(r,.Index,int(original.index_span)) ||
       !pool_room(r,.Node,int(original.rays[0].bvh_node_count)) || !pool_room(r,.Triangle,int(original.rays[0].triangle_count)) {
        s.refused.meshes+=1
        s.refused.triangles+=u64(original.triangle_count)
        return 0,false
    }
    if reserve(&s.vertices,len(s.vertices)+blocks+streams*words)!=nil ||
       reserve(&s.indices,len(s.indices)+int(original.index_span))!=nil ||
       reserve(&s.blas_nodes,len(s.blas_nodes)+int(original.rays[0].bvh_node_count))!=nil ||
       reserve(&s.blas_triangles,len(s.blas_triangles)+int(original.rays[0].triangle_count))!=nil ||
       reserve(&s.meshes,len(s.meshes)+1)!=nil || reserve(&s.skinned,len(s.skinned)+1)!=nil ||
       reserve(&s.mesh_dirty,len(s.mesh_dirty)+1)!=nil {return 0,false}
    for &ranges in s.pool_dirty {if reserve(&ranges,len(ranges)+4)!=nil {return 0,false}}
    record:=original
    record.skin,record.skin_binding,record.stream=skin,nil,nil
    record.flags&~=MESH_FLAG_STREAMED
    record.rays={}
    record.ray_count=1
    // A pose leaves the faces of its box: it is no slab.
    record.slab_axes=0
    record.vertices_posed=posed
    record.cluster_word,record.page_word=original.cluster_word-original.index_word,original.page_word-original.index_word
    record.level_word,record.slot_word=original.level_word-original.index_word,original.slot_word-original.index_word
    vertex_start,index_start:=u32(len(s.vertices)),u32(len(s.indices))
    append(&s.indices,..s.indices[original.index_word:][:original.index_span])
    table:=mem.slice_data_cast([]Gpu_Mesh_Page,s.indices[index_start+record.page_word:][:record.page_count*PAGE_ENTRY_WORDS])
    // The copy of the page table names the blocks of the copy, from its own block until mesh_store places it.
    if original.stream==nil {
        append(&s.vertices,..s.vertices[original.vertex_word:][:original.vertex_span])
        for &page in table {if page.base!=GPU_NONE {page.base-=original.vertex_word}}
    } else {
        p:=record_pooled(s,original)
        for &page,k in table {
            size:=original.stream.pages[k].words
            block:=pooled_page_block(p,u32(k))
            if block==nil {base.truncate(&s.vertices,vertex_start);base.truncate(&s.indices,index_start);return 0,false}
            page.base=u32(len(s.vertices))-vertex_start
            append(&s.vertices,..block[:size])
        }
    }
    // The rest of every vertex posed, as a pose holds it before the GPU first writes it.
    rest,rest_error:=make([]Gpu_Posed_Vertex,posed,r.allocator)
    if rest_error!=nil {base.truncate(&s.vertices,vertex_start);base.truncate(&s.indices,index_start);return 0,false}
    defer delete(rest,r.allocator)
    p:=record_pooled(s,original)
    for whole,ordinal in p.clusters {
        g,c,resident:=pooled_cluster(p,u32(ordinal))
        if !resident {continue}
        for local in 0..<asset.cluster_vertex_count(c) {
            index:=whole.vertex_first+local
            if index>=posed {continue}
            v:=asset.cluster_vertex(g,c,local)
            rest[index]={position=v.position,normal=v.normal,tangent=v.tangent}
        }
    }
    first:=u32(len(s.vertices))-vertex_start
    for _ in 0..<streams {append(&s.vertices,..mem.slice_data_cast([]u32,rest))}
    record.posed_word,record.previous_word=first,first+u32(words)
    record.part_word,record.rest_word=GPU_NONE,GPU_NONE
    if skin.part_joints!=nil {record.part_word=first+2*u32(words)}
    if skin.external {record.rest_word=first+2*u32(words)}
    if posed<original.vertex_count {record.flags|=MESH_FLAG_LEVEL0}
    source:=original.rays[0]
    if source.bvh_node_count>0 {
        nodes:=len(s.blas_nodes)
        if resize(&s.blas_nodes,nodes+int(source.bvh_node_count))!=nil ||
           !bvh_breadth_first(s.blas_nodes[source.bvh_root:][:source.bvh_node_count],s.blas_nodes[nodes:],&skin.binding.levels) {
            base.truncate(&s.blas_nodes,nodes);base.truncate(&s.vertices,vertex_start);base.truncate(&s.indices,index_start)
            return 0,false
        }
        triangles:=u32(len(s.blas_triangles))
        append(&s.blas_triangles,..s.blas_triangles[source.triangle_offset:][:source.triangle_count])
        record.rays[0].bvh_node_count,record.rays[0].triangle_count=source.bvh_node_count,source.triangle_count
        record.rays[0].bvh_root=pool_store(&s.blas_nodes,&s.pool_free[.Node],&s.pool_dirty[.Node],u32(nodes))
        record.rays[0].triangle_offset=pool_store(&s.blas_triangles,&s.pool_free[.Triangle],&s.pool_dirty[.Triangle],triangles)
    }
    handle:=mesh_store(r,record,vertex_start,index_start)
    skin.refits=u32(handle)%SKIN_REBUILD_INTERVAL
    skin.dirty=true
    append(&s.skinned,handle)
    return handle,true
}

// A mesh an extension deforms on the GPU: a copy of `source` whose vertices
// the extension writes in the Geometry stage of each frame it asked
// deformable_update for. The renderer keeps its motion, the tree of its
// triangles and its native BLAS up to those vertices, for raster and for rays
// alike. levels: the copy keeps the levels of the source, whose vertices the
// extension writes too, and the GPU keeps choosing among them; without, it is
// drawn at level 0. Rays meet level 0. The source may be retired after this load
// transaction.
deformable_create :: proc(r:^Renderer,source:Mesh_Handle,levels:=false)->(Mesh_Handle,bool) {
    s:=&r.scene
    if int(source)>=len(s.meshes) {return 0,false}
    mesh_filled(s,u32(source))
    original:=s.meshes[source]
    if original.skin!=nil || original.vertex_count==0 {return 0,false}
    skin,error:=new(Skin_State,r.allocator)
    if error!=nil {return 0,false}
    skin.allocator,skin.external=r.allocator,true
    skin.binding,error=new(Skin_Binding,r.allocator)
    if error!=nil {free(skin,r.allocator);return 0,false}
    skin.binding.allocator,skin.binding.references=r.allocator,1
    posed,_:=level0_vertices(s,original)
    if levels {posed=original.vertex_count}
    // Current, previous and rest.
    handle,ok:=pose_store(r,original,posed,3,skin)
    if !ok {skin_free(r,skin);return 0,false}
    return handle,true
}

// The box of a mesh, in its own space; that of a deformable is the one its
// last deformable_update gave.
mesh_bounds :: proc(r:^Renderer,handle:Mesh_Handle)->(bounds_min,bounds_max:Vec3,ok:bool) {
    s:=&r.scene
    if int(handle)>=len(s.meshes) || s.meshes[handle].vertex_count==0 {return}
    return s.meshes[handle].bounds_min,s.meshes[handle].bounds_max,true
}

// Says that the extension writes the vertices of a deformable in the Geometry
// stage of the next frame, and the box they stay in, in the space of the mesh.
deformable_update :: proc(r:^Renderer,handle:Mesh_Handle,bounds_min,bounds_max:Vec3)->bool {
    s:=&r.scene
    if int(handle)>=len(s.meshes) {return false}
    m:=&s.meshes[handle]
    if m.skin==nil || !m.skin.external {return false}
    for i in 0..<3 {if !(bounds_min[i]<=bounds_max[i]) || math.is_inf(bounds_min[i]) || math.is_inf(bounds_max[i]) {return false}}
    if m.bounds_min!=bounds_min || m.bounds_max!=bounds_max {
        m.bounds_min,m.bounds_max=bounds_min,bounds_max
        m.skin.bounds_dirty=true
    }
    m.skin.dirty=true
    return true
}

// Where the vertices of a deformable are in the vertex pool of the scene, in
// words, Gpu_Posed_Vertex each: those the extension writes, and those of its
// rest shape, which it reads; and its row of the mesh table, through which
// the rest of each vertex is read (geometry.slang, mesh_vertex_color).
deformable_vertices :: proc(r:^Renderer,handle:Mesh_Handle)->(written,rest,count,mesh:u32,ok:bool) {
    s:=&r.scene
    if int(handle)>=len(s.meshes) {return}
    m:=s.meshes[handle]
    if m.skin==nil || !m.skin.external {return}
    return m.posed_word,m.rest_word,m.vertices_posed,u32(handle),true
}

// How many times the vertex buffer of the scene was made again: what an
// extension wrote in a deformable is gone with the buffer it was written in,
// and its vertices are those at rest.
vertices_made :: proc(r:^Renderer)->u64 {return r.scene.vertices_made}

// One independently posed mesh. With influences for the vertices of level 0
// it is that level alone; with influences for every vertex of the mesh,
// every level is posed and the GPU keeps choosing among them.
// morph: the targets of those vertices, whose weights skin_update gives.
// part: it has a part some views draw collapsed (Skin_Part_Pose), with its
// own vertices. The source may be retired after this load transaction.
skin_create :: proc(r:^Renderer,source:Mesh_Handle,influences:[]Skin_Influence,joint_count:u32,morph:Morph_Data={},part:=false)->(Mesh_Handle,bool) {
    s:=&r.scene
    if int(source)>=len(s.meshes) || joint_count==0 || joint_count>65536 {return 0,false}
    mesh_filled(s,u32(source))
    original:=s.meshes[source]
    if original.skin!=nil || original.vertex_count==0 {return 0,false}
    level0,_:=level0_vertices(s,original)
    if len(influences)!=int(original.vertex_count) && len(influences)!=int(level0) {return 0,false}
    if original.skin_binding!=nil && (len(original.skin_binding.bounds)!=int(joint_count) ||
       mem.compare(slice_bytes(influences),slice_bytes(original.skin_binding.influences))!=0 || !skin_morph_equal(original.skin_binding.morph,morph)) {return 0,false}
    if !skin_influences_valid(influences,joint_count) || !skin_morph_valid(morph,len(influences)) {return 0,false}
    skin,error:=new(Skin_State,r.allocator)
    if error!=nil {return 0,false}
    skin.allocator=r.allocator
    success:=false
    defer if !success {skin_free(r,skin)}
    skin.joints,error=make([]Skin_Joint,int(joint_count),r.allocator)
    if error!=nil {return 0,false}
    for &joint in skin.joints {joint.current=rows_3x4(Mat4(1));joint.previous=joint.current}
    if part {
        skin.part_joints,error=make([]Skin_Joint,int(joint_count),r.allocator)
        if error!=nil {return 0,false}
        copy(skin.part_joints,skin.joints)
    }
    if morph.count>0 {
        skin.morph_weights,error=make([]Vec2,int(morph.count),r.allocator)
        if error!=nil {return 0,false}
        skin.bounds,error=make([]Skin_Bounds,int(joint_count),r.allocator)
        if error!=nil {return 0,false}
    }
    skin.binding=original.skin_binding
    if skin.binding!=nil {skin.binding.references+=1} else {skin.binding=skin_binding_create(r,original,influences,joint_count,morph)}
    if skin.binding==nil {return 0,false}
    binding:=skin.binding
    // Current, then previous; those of its collapsed part follow, the same way.
    streams:=4 if part else 2
    // More than a frame uploads goes over frames, and so does a pose of a mesh
    // or a binding that still go; any other is there in the next frame.
    over:=pose_bytes(original,u32(len(influences)),streams,binding)>UPLOAD_FRAME_BYTES || mesh_pending(s,u32(source)) || binding_queued(s,binding)
    over&&=mesh_upload_room(r)
    if !over && !skin_binding_upload(r,binding) {return 0,false}
    handle,ok:=pose_store(r,original,u32(len(influences)),streams,skin)
    if !ok {return 0,false}
    success=true
    if s.meshes[source].skin_binding==nil {s.meshes[source].skin_binding=binding;binding.references+=1}
    if over {upload_start(r,upload_make(s,handle,binding if binding.uploading else nil))}
    return handle,true
}

// The palette a skinned mesh deforms with in the next frame and the one it
// deformed with in the frame before, as the rows of a 3x4 matrix by joint,
// into current and previous, as many as fit; count: its joints.
skin_palette :: proc(r:^Renderer,handle:Mesh_Handle,current,previous:[][3]Vec4)->(count:int,ok:bool) {
    s:=&r.scene
    if int(handle)>=len(s.meshes) {return}
    skin:=s.meshes[handle].skin
    if skin==nil || skin.external {return}
    for joint,i in skin.joints {
        if i<len(current) {current[i]=joint.current}
        if i<len(previous) {previous[i]=joint.previous}
    }
    return len(skin.joints),true
}

// Palette maps bind vertices to current mesh space; inverse bind is already
// composed. morph_weights: one per target of the pose, or none to keep them.
// part: of a pose made with one; a palette of no joints keeps the one it has.
skin_update :: proc(r:^Renderer,handle:Mesh_Handle,palette:[]Mat4,reset_motion:bool=false,morph_weights:[]f32=nil,part:Skin_Part_Pose={})->bool {
    s:=&r.scene
    if int(handle)>=len(s.meshes) {return false}
    m:=&s.meshes[handle];skin:=m.skin
    if skin==nil || len(palette)!=len(skin.joints) {return false}
    if !skin_palette_valid(palette) {return false}
    if len(morph_weights)!=0 && len(morph_weights)!=len(skin.morph_weights) {return false}
    if len(part.palette)!=0 && (len(part.palette)!=len(skin.part_joints) || !skin_palette_valid(part.palette)) {return false}
    for weight in morph_weights {if math.is_nan(weight) || math.is_inf(weight) {return false}}
    changed:=false
    for transform,i in palette {
        rows:=rows_3x4(transform)
        changed ||= rows!=skin.joints[i].current
        skin.joints[i].current=rows
        if reset_motion {skin.joints[i].previous=rows}
    }
    for transform,i in part.palette {
        rows:=rows_3x4(transform)
        changed ||= rows!=skin.part_joints[i].current
        skin.part_joints[i].current=rows
        if reset_motion {skin.part_joints[i].previous=rows}
    }
    if skin.part_joints!=nil && part.layers!=skin.part_layers {skin.part_layers=part.layers;changed=true}
    for weight,i in morph_weights {
        changed ||= weight!=skin.morph_weights[i].x
        skin.morph_weights[i].x=weight
    }
    if reset_motion {for &weight in skin.morph_weights {weight.y=weight.x}}
    if !changed && !reset_motion {return true}
    joints:=skin.binding.bounds
    if len(skin.morph_weights)>0 {
        copy(skin.bounds,joints);joints=skin.bounds
        for moved in skin.binding.morph_bounds {
            weight:=skin.morph_weights[moved.target].x
            if weight==0 {continue}
            a,b:=moved.lo*weight,moved.hi*weight
            joints[moved.joint].lo+=linalg.min(a,b);joints[moved.joint].hi+=linalg.max(a,b)
        }
    }
    lo,hi:=EMPTY_BOUNDS_MIN,EMPTY_BOUNDS_MAX
    for transform,i in palette {
        bounds:=joints[i]
        if bounds.lo.x>bounds.hi.x {continue}
        a,b:=transform_bounds(transform,bounds.lo,bounds.hi)
        lo=linalg.min(lo,a);hi=linalg.max(hi,b)
    }
    m.bounds_min,m.bounds_max=lo,hi
    skin.dirty,skin.bounds_dirty=true,true
    return true
}

// The boxes of the instances of the poses that changed their own, and the
// shadows of every pose that changed (occluder_moved).
@(private)
skins_bounds :: proc(r:^Renderer) {
    s:=&r.scene
    changed:=false
    for handle in s.skinned {
        mesh:=s.meshes[handle]
        if mesh.skin==nil {continue}
        if mesh.skin.dirty && !mesh.skin.bounds_dirty {
            for index:=mesh.first_instance;index>=0;index=s.instance_next[index] {occluder_moved(s,u32(index),s.instances[index],s.instances[index])}
        }
        if !mesh.skin.bounds_dirty {continue}
        mesh.skin.bounds_dirty=false
        for index:=mesh.first_instance;index>=0;index=s.instance_next[index] {
            changed||=pose_instance_box(s,u32(index))
        }
    }
    if !changed {return}

    instances_moved(s)
}

// How far the programs of the instance of a pose move its vertices out of its box.
@(private)
pose_reach :: proc "contextless" (m:Mesh_Record) -> f32 {return m.skin.reach if m.skin!=nil else 0}

// The box of an instance of a pose, from the box of the pose and its reach;
// false for one hidden until it can be drawn.
@(private)
pose_instance_box :: proc(s:^Scene_State,index:u32) -> bool {
    inst:=&s.instances[index]
    if inst.meta.w&INSTANCE_FLAG_COLLAPSED!=0 {return false}
    mesh:=s.meshes[inst.meta.x&INSTANCE_MESH_MASK]
    reach:=pose_reach(mesh)
    before:=inst^
    transform:=Mat4(1)
    for row in 0..<3 {for column in 0..<4 {transform[row,column]=inst.world[row][column]}}
    lo,hi:=transform_bounds(transform,mesh.bounds_min-reach,mesh.bounds_max+reach)
    scene_changed_box(s,inst.bounds_min.xyz,inst.bounds_max.xyz)
    scene_changed_box(s,lo,hi)
    inst.bounds_min.xyz=lo;inst.bounds_max.xyz=hi
    instance_resized(s,int(index),lo,hi)
    occluder_moved(s,index,before,inst^)
    s.tlas_items[index]={bounds_min=lo,bounds_max=hi,center=(lo+hi)*0.5}
    if len(s.touched)<cap(s.touched) {append(&s.touched,index)} else {s.instances_dirty=true}
    return true
}

// The vertices of the poses that changed or settle, before the Geometry stage
// of the frame: those of the skinned ones from their joints, and for the ones
// an extension deforms, the vertices they had as their previous ones. Every
// pose is written before any refit: each pass covers every pose, so the
// barriers separate passes and not poses.
@(private)
poses_record :: proc(r:^Renderer,cmd:^rhi.Command_List)->bool {
    s:=&r.scene
    posed:=0
    for handle in s.skinned {
        skin:=s.meshes[handle].skin
        if skin!=nil && (skin.dirty || skin.settle) && !mesh_pending(s,u32(handle)) {posed+=1}
    }
    if posed==0 {return true}
    rhi.cmd_timestamp(cmd,"skinning")
    for handle in s.skinned {
        mesh:=s.meshes[handle]
        if mesh.skin==nil || !mesh.skin.dirty || mesh_pending(s,u32(handle)) {continue}
        row:=rhi.frame_alloc(r.device,size_of(Gpu_Mesh),16)
        if row.ptr==nil {set_error(r,"transient ring exhausted uploading skin mesh");return false}
        (cast(^Gpu_Mesh)row.ptr)^=gpu_mesh(mesh)
        rhi.cmd_copy_buffer(cmd,row.buffer,row.offset,s.mesh_buffer,u64(handle)*size_of(Gpu_Mesh),size_of(Gpu_Mesh))
    }
    rhi.cmd_barrier_buffer(cmd,s.mesh_buffer,.Shader_Read)
    // What an extension deforms, or the programs of its instance move, keeps the vertices it had as its previous ones.
    for handle in s.skinned {
        mesh:=s.meshes[handle]
        if mesh.skin==nil || !(mesh.skin.external || mesh.skin.displaced) || !(mesh.skin.dirty || mesh.skin.settle) || mesh_pending(s,u32(handle)) {continue}
        bytes:=u64(mesh.vertices_posed)*size_of(Gpu_Posed_Vertex)
        rhi.cmd_copy_buffer(cmd,s.vertex_buffer,u64(mesh.posed_word)*4,s.vertex_buffer,u64(mesh.previous_word)*4,bytes)
    }
    rhi.cmd_barrier_buffer(cmd,s.vertex_buffer,.Shader_Write)
    rhi.cmd_barrier_buffer(cmd,s.index_buffer,.Shader_Read)
    for handle in s.skinned {
        mesh:=s.meshes[handle]
        skin:=mesh.skin
        if skin==nil || skin.external || skin.displaced || !(skin.dirty || skin.settle) || mesh_pending(s,u32(handle)) {continue}
        size:=len(skin.joints)*size_of(Skin_Joint)
        palette:=rhi.frame_alloc(r.device,u64(size),16)
        if palette.ptr==nil {set_error(r,"transient ring exhausted uploading skin palette");return false}
        mem.copy(palette.ptr,raw_data(skin.joints),size)
        rhi.cmd_barrier_buffer(cmd,skin.binding.source,.Shader_Read)
        // Targets at rest now and before add nothing: they are not read.
        morph:Skin_Morph_Buffers
        for weight in skin.morph_weights {if weight!={} {morph.count=u32(len(skin.morph_weights));break}}
        if morph.count>0 && len(skin.binding.morph.deltas)>0 {
            bytes:=len(skin.morph_weights)*size_of(Vec2)
            weights:=rhi.frame_alloc(r.device,u64(bytes),16)
            if weights.ptr==nil {set_error(r,"transient ring exhausted uploading morph weights");return false}
            mem.copy(weights.ptr,raw_data(skin.morph_weights),bytes)
            morph.ranges,morph.deltas,morph.weights,morph.weights_offset,morph.step=skin.binding.morph_ranges,skin.binding.morph_deltas,weights.buffer,weights.offset,skin.binding.morph.step
            rhi.cmd_barrier_buffer(cmd,morph.ranges,.Shader_Read);rhi.cmd_barrier_buffer(cmd,morph.deltas,.Shader_Read)
        } else {morph.count=0}
        params:=Skin_Params{mesh=u32(handle),clusters=posed_clusters(s,mesh),output=mesh.posed_word,previous=mesh.previous_word}
        skin_dispatch(r,cmd,skin.binding.source,palette.buffer,palette.offset,s.mesh_buffer,s.vertex_buffer,s.index_buffer,params,morph=morph)
        if skin.part_joints!=nil {
            part:=rhi.frame_alloc(r.device,u64(size),16)
            if part.ptr==nil {set_error(r,"transient ring exhausted uploading skin palette");return false}
            mem.copy(part.ptr,raw_data(skin.part_joints),size)
            params.output,params.previous=mesh.part_word,mesh.part_word+mesh.vertices_posed*POSED_WORDS
            skin_dispatch(r,cmd,skin.binding.source,part.buffer,part.offset,s.mesh_buffer,s.vertex_buffer,s.index_buffer,params,morph=morph)
        }
    }
    return true
}

// The trees or the native BLAS of the poses that changed, those the rays use,
// up to the vertices they have after the Geometry stage, and the instances of
// the native TLAS.
@(private)
poses_refit :: proc(r:^Renderer,cmd:^rhi.Command_List)->bool {
    s:=&r.scene
    // A pose whose geometry still goes to the GPU waits for it, dirty.
    posing :: proc(s:^Scene_State,handle:Mesh_Handle)->bool {skin:=s.meshes[handle].skin;return skin!=nil && (skin.dirty || skin.settle) && !mesh_pending(s,u32(handle))}
    tree_refit :: proc(r:^Renderer,handle:Mesh_Handle)->bool {mesh:=r.scene.meshes[handle];return posing(&r.scene,handle) && mesh.skin.dirty && !r.hardware_rt && mesh.rays[0].bvh_node_count>0}
    posed,refit,level_jobs,deepest:int
    for handle in s.skinned {
        if !posing(s,handle) {continue}
        skin:=s.meshes[handle].skin
        posed+=1
        if !tree_refit(r,handle) {continue}
        refit+=1
        for level,depth in skin.binding.levels {if level.count>0 {level_jobs+=1;deepest=max(deepest,depth)}}
    }
    if posed==0 {return true}
    if refit>0 {
        size:=u64(refit+level_jobs)*size_of(Skin_Job)
        bytes:=rhi.frame_alloc(r.device,size,16)
        if bytes.ptr==nil {set_error(r,"transient ring exhausted uploading skin jobs");return false}
        jobs:=([^]Skin_Job)(bytes.ptr)[:refit+level_jobs]
        at:=0
        triangles:u32
        for handle in s.skinned {
            mesh:=s.meshes[handle]
            if !tree_refit(r,handle) {continue}
            jobs[at]={u32(handle),0,mesh.rays[0].triangle_offset,triangles}
            triangles+=mesh.rays[0].triangle_count;at+=1
        }
        params:=Skin_Jobs_Params{0,u32(refit),triangles,0}
        rhi.cmd_bind_pipeline(cmd,r.pipelines[.Skin_Triangles])
        rhi.cmd_bind_buffer(cmd,SLOT_PASS0,bytes.buffer,bytes.offset,size)
        rhi.cmd_bind_buffer(cmd,SLOT_MESHES,s.mesh_buffer)
        rhi.cmd_bind_buffer(cmd,SLOT_VERTICES,s.vertex_buffer)
        rhi.cmd_bind_buffer(cmd,SLOT_INDICES,s.index_buffer)
        rhi.cmd_bind_buffer(cmd,SLOT_BLAS_TRIANGLES,s.blas_triangle_buffer)
        set_params(cmd,&params)
        rhi.cmd_barrier_buffer(cmd,s.vertex_buffer,.Shader_Read);rhi.cmd_barrier_buffer(cmd,s.index_buffer,.Shader_Read)
        rhi.cmd_barrier_buffer(cmd,s.blas_triangle_buffer,.Shader_Write)
        rhi.cmd_dispatch(cmd,groups(triangles,64),1)
        // From the deepest level up: a node reads the boxes the level below wrote.
        rhi.cmd_bind_pipeline(cmd,r.pipelines[.Skin_Refit])
        rhi.cmd_bind_buffer(cmd,SLOT_PASS0,bytes.buffer,bytes.offset,size)
        rhi.cmd_bind_buffer(cmd,SLOT_BLAS_TRIANGLES,s.blas_triangle_buffer)
        rhi.cmd_bind_buffer(cmd,SLOT_BLAS_NODES,s.blas_node_buffer)
        rhi.cmd_barrier_buffer(cmd,s.blas_triangle_buffer,.Shader_Read)
        for depth:=deepest;depth>=0;depth-=1 {
            first:=at
            nodes:u32
            for handle in s.skinned {
                mesh:=s.meshes[handle]
                if !tree_refit(r,handle) {continue}
                level:=mesh.skin.binding.levels[depth]
                if level.count==0 {continue}
                jobs[at]={mesh.rays[0].bvh_root,mesh.rays[0].triangle_offset,level.first,nodes}
                nodes+=level.count;at+=1
            }
            if nodes==0 {continue}
            params=Skin_Jobs_Params{u32(first),u32(at-first),nodes,0}
            set_params(cmd,&params)
            rhi.cmd_barrier_buffer(cmd,s.blas_node_buffer,.Shader_Write)
            rhi.cmd_dispatch(cmd,groups(nodes,64),1)
        }
    }
    if r.hardware_rt {
        for handle in s.skinned {
            mesh:=s.meshes[handle]
            skin:=mesh.skin
            if !posing(s,handle) || !skin.dirty || mesh.rays[0].blas==0 {continue}
            rebuild:=skin.refits>=SKIN_REBUILD_INTERVAL
            rhi.cmd_build_blas(cmd,mesh.rays[0].blas,rebuild)
            skin.refits=0 if rebuild else skin.refits+1
            s.tlas_dirty=true
        }
    }
    for handle in s.skinned {
        skin:=s.meshes[handle].skin
        if !posing(s,handle) {continue}
        // What moved is drawn once more at rest: its previous vertices take the current ones.
        moving:=(skin.external || skin.displaced) && skin.dirty
        for &joint in skin.joints {moving ||= joint.current!=joint.previous;joint.previous=joint.current}
        for &joint in skin.part_joints {moving ||= joint.current!=joint.previous;joint.previous=joint.current}
        for &weight in skin.morph_weights {moving ||= weight.x!=weight.y;weight.y=weight.x}
        skin.dirty=false;skin.settle=moving
    }
    rhi.cmd_timestamp(cmd,"skin end")
    return true
}
