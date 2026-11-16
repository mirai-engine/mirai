package mirai_render

// Colors of every vertex of a mesh, by index in the mesh (cluster vertex
// order, every level), that instances of it show in place of those of the
// mesh: two instances of one mesh show their own. 0 is none.
Colors_Handle :: distinct u32

// Puts colors in the vertex pool for instances to show. False for none or
// without room.
colors_load :: proc(r:^Renderer,colors:[]u32) -> (handle:Colors_Handle,ok:bool) {
    s:=&r.scene
    if len(colors)==0 || len(colors)>int(max(u32)/4) || !pool_room(r,.Vertex,len(colors)) || !pool_reserve(&s.vertices,len(colors)) {return}
    slot:=-1
    for run,at in s.colors {if run.count==0 {slot=at;break}}
    if slot<0 {
        if _,error:=append(&s.colors,Pool_Range{});error!=nil {return}
        slot=len(s.colors)-1
    }
    first:=u32(len(s.vertices))
    append(&s.vertices,..colors)
    s.colors[slot]={pool_store(&s.vertices,&s.pool_free[.Vertex],&s.pool_dirty[.Vertex],first),u32(len(colors))}
    s.geometry_dirty=true
    return Colors_Handle(slot+1),true
}

// The instances that show colors go back to those of their mesh, and the
// colors leave the pool. False for a handle the renderer does not have.
colors_remove :: proc(r:^Renderer,colors:Colors_Handle) -> bool {
    s:=&r.scene
    if colors==0 || int(colors)>len(s.colors) || s.colors[colors-1].count==0 {return false}
    run:=s.colors[colors-1]
    for &inst,index in s.instances {
        if inst.color_count==0 || inst.colors!=run.first {continue}
        inst.colors,inst.color_count=0,0
        instance_changed_near(s,&inst)
        instance_touch(s,u32(index))
    }
    pool_release(&s.vertices,&s.pool_free[.Vertex],run.first,run.count)
    geometry_released(s,u64(run.count)*4)
    s.colors[colors-1]={}
    return true
}

// The colors an instance shows, by its descriptor, while it keeps its
// identity and its mesh; 0 gives it back those of its mesh. False for a
// descriptor or colors the scene does not have, or colors of another number
// of vertices than its mesh has.
scene_set_instance_colors :: proc(r:^Renderer,descriptor:u32,colors:Colors_Handle) -> bool {
    s:=&r.scene
    if int(descriptor)>=len(s.instances) || int(colors)>len(s.colors) {return false}
    run:Pool_Range
    if colors!=0 {
        run=s.colors[colors-1]
        if run.count==0 {return false}
    }
    index:=descriptor
    inst:=&s.instances[index]
    if run.count!=0 && run.count!=s.meshes[inst.meta.x&INSTANCE_MESH_MASK].vertex_count {return false}
    if inst.colors==run.first && inst.color_count==run.count {return true}
    inst.colors,inst.color_count=run.first,run.count
    instance_changed_near(s,inst)
    instance_touch(s,u32(index))
    return true
}
