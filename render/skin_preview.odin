package mirai_render

import "core:mem"
import "mirai:asset"
import "mirai:rhi"

// The skinning of the scene (skin.comp) over pools of its own: a mesh row,
// the clusters of one mesh and room for its posed vertices, read back between
// frames. Editor sampling stays independent of scene geometry and motion history.
Skin_Preview_GPU :: struct {
    source,palette,meshes,vertices,indices,readback,params:rhi.Buffer,
    vertex_count,joint_count,clusters,posed_word:u32,
}

skin_preview_destroy :: proc(device:^rhi.Device,state:^Skin_Preview_GPU) {
    if device!=nil {
        for buffer in ([7]rhi.Buffer{state.source,state.palette,state.meshes,state.vertices,state.indices,state.readback,state.params}) {
            if buffer!=0 {rhi.buffer_destroy(device,buffer)}
        }
    }
    state^={}
}

// The geometry of a mesh as asset.mesh_build or its file gives it, with the
// influences of every one of its vertices.
skin_preview_init :: proc(r:^Renderer,state:^Skin_Preview_GPU,g:asset.Mesh_Geometry,influences:[]Skin_Influence,joint_count:u32)->bool {
    if r==nil || r.device==nil || len(g.vertices)==0 || len(g.clusters)==0 || len(g.levels)==0 || len(g.pages)==0 || len(g.vertices)>int(max(u32)/16) ||
       len(g.vertices)!=len(influences) || !skin_influences_valid(influences,joint_count) {return false}
    device:=r.device
    count:=u32(len(g.vertices))
    next:=Skin_Preview_GPU{vertex_count=count,joint_count=joint_count,clusters=u32(len(g.clusters))}
    success:=false
    defer if !success {skin_preview_destroy(device,&next)}
    vertex_words:=make([dynamic]u32,0,len(g.vertices)*VERTEX_WORDS,context.temp_allocator)
    index_words:=make([dynamic]u32,0,len(g.clusters)*CLUSTER_WORDS,context.temp_allocator)
    row:=Gpu_Mesh{cluster_count=next.clusters,level_count=u32(len(g.levels)),page_count=u32(len(g.pages)),vertex_count=count,flags=mesh_stream_flags(g.flags),
        posed_word=GPU_NONE,previous_word=GPU_NONE,part_word=GPU_NONE,bounds_word=GPU_NONE,position_step=g.position_step,uv_step=g.uv_step,uv1_step=g.uv1_step}
    append(&index_words,..mem.slice_data_cast([]u32,g.clusters))
    row.page_word=u32(len(index_words))
    if !pages_append(g,&vertex_words,&index_words,0) {return false}
    next.posed_word=u32(len(vertex_words))
    resize(&vertex_words,len(vertex_words)+2*int(count)*POSED_WORDS)
    row.level_word=u32(len(index_words))
    append(&index_words,..mem.slice_data_cast([]u32,g.levels))
    row.slot_word=u32(len(index_words))
    append(&index_words,0)
    next.source=rhi.buffer_create(device,{size=u64(len(influences))*size_of(Skin_Influence),usage={.Storage},memory=.Upload,name="preview skin influences"})
    next.palette=rhi.buffer_create(device,{size=u64(joint_count)*size_of(Skin_Joint),usage={.Storage},memory=.Upload,name="preview skin palette"})
    next.meshes=rhi.buffer_create(device,{size=size_of(Gpu_Mesh),usage={.Storage},memory=.Upload,name="preview skin mesh"})
    next.vertices=rhi.buffer_create(device,{size=u64(len(vertex_words))*4,usage={.Storage,.Transfer_Src},memory=.Upload,name="preview skin vertices"})
    next.indices=rhi.buffer_create(device,{size=u64(len(index_words))*4,usage={.Storage},memory=.Upload,name="preview skin clusters"})
    next.readback=rhi.buffer_create(device,{size=u64(count)*size_of(Gpu_Posed_Vertex),usage={.Transfer_Dst},memory=.Readback,name="preview skin readback"})
    next.params=rhi.buffer_create(device,{size=size_of(Skin_Params),usage={.Uniform},memory=.Upload,name="preview skin params"})
    if next.source==0 || next.palette==0 || next.meshes==0 || next.vertices==0 || next.indices==0 || next.readback==0 || next.params==0 {return false}
    mem.copy(rhi.buffer_mapped(device,next.source),raw_data(influences),len(influences)*size_of(Skin_Influence))
    (cast(^Gpu_Mesh)rhi.buffer_mapped(device,next.meshes))^=row
    mem.copy(rhi.buffer_mapped(device,next.vertices),raw_data(vertex_words),len(vertex_words)*4)
    mem.copy(rhi.buffer_mapped(device,next.indices),raw_data(index_words),len(index_words)*4)
    (cast(^Skin_Params)rhi.buffer_mapped(device,next.params))^={clusters=next.clusters,output=next.posed_word,previous=next.posed_word+count*POSED_WORDS,bounds=GPU_NONE}
    skin_preview_destroy(device,state)
    state^=next;success=true
    return true
}

// Blocking transaction between frames; capacities are retained for subsequent
// samples. out: where each vertex of the mesh is under the palette.
skin_preview_sample :: proc(r:^Renderer,state:^Skin_Preview_GPU,palette:[]Mat4,out:[]Gpu_Posed_Vertex)->bool {
    if r==nil || r.device==nil || state.source==0 || len(palette)!=int(state.joint_count) ||
       len(out)!=int(state.vertex_count) || !skin_palette_valid(palette) {return false}
    device:=r.device
    joints:=cast([^]Skin_Joint)rhi.buffer_mapped(device,state.palette)
    for transform,i in palette {rows:=rows_3x4(transform);joints[i]={rows,rows}}
    cmd:=rhi.immediate_begin(device)
    for buffer in ([]rhi.Buffer{state.params,state.source,state.palette,state.meshes,state.indices}) {rhi.cmd_barrier_buffer(cmd,buffer,.Shader_Read)}
    rhi.cmd_barrier_buffer(cmd,state.vertices,.Shader_Write)
    skin_dispatch(r,cmd,state.source,state.palette,0,state.meshes,state.vertices,state.indices,{clusters=state.clusters},state.params)
    rhi.cmd_copy_buffer(cmd,state.vertices,u64(state.posed_word)*4,state.readback,0,u64(len(out))*size_of(Gpu_Posed_Vertex))
    rhi.cmd_barrier_buffer(cmd,state.readback,.Host_Read)
    if !rhi.immediate_end(device,cmd) {return false}
    mem.copy(raw_data(out),rhi.buffer_mapped(device,state.readback),len(out)*size_of(Gpu_Posed_Vertex))
    return true
}
