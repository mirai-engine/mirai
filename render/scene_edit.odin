package mirai_render

import "core:math/linalg"
import "mirai:rhi"
import "mirai:std/base"

// Immutable meshes own reusable ranges in the common geometry pools.

@(private)
range_add :: proc(ranges:^[dynamic]Pool_Range,added:Pool_Range) {
    if added.count==0 {return}
    joined:=added
    for i:=0;i<len(ranges); {
        held:=ranges^[i]
        if joined.first>held.first+held.count || held.first>joined.first+joined.count {i+=1;continue}
        end:=max(joined.first+joined.count,held.first+held.count)
        joined.first=min(joined.first,held.first)
        joined.count=end-joined.first
        unordered_remove(ranges,i)
        i=0
    }
    append(ranges,joined)
}

@(private)
pool_store :: proc(pool:^[dynamic]$T,free,dirty:^[dynamic]Pool_Range,first:u32) -> u32 {
    count:=u32(len(pool))-first
    destination:=first
    for &range,index in free^ {
        if range.count<count {continue}
        destination=range.first
        range.first+=count;range.count-=count
        if range.count==0 {unordered_remove(free,index)}
        copy(pool^[destination:][:count],pool^[first:][:count])
        base.truncate(pool,first)
        break
    }
    range_add(dirty,{destination,count})
    return destination
}

// Room for count elements, in the first free range that holds them or past
// the end, as pool_store places them, for a caller that writes them later:
// they are not dirty and hold nothing yet. False without memory.
@(private)
pool_take :: proc(pool:^[dynamic]$T,free:^[dynamic]Pool_Range,count:u32) -> (first:u32,ok:bool) {
    if count==0 {return u32(len(pool)),true}
    for &range,index in free^ {
        if range.count<count {continue}
        first=range.first
        range.first+=count;range.count-=count
        if range.count==0 {unordered_remove(free,index)}
        return first,true
    }
    first=u32(len(pool))
    if !pool_reserve(pool,int(count)) || non_zero_resize(pool,len(pool)+int(count))!=nil {return 0,false}
    return first,true
}

// Room in the copy of the CPU of a pool for more elements past its end, with
// the slack its buffer on the GPU grows with (pool_room): grown to the
// element, it would copy itself whole each time a mesh takes its end.
@(private)
pool_reserve :: proc(pool:^[dynamic]$T,more:int) -> bool {
    needed:=len(pool)+more
    if needed<=cap(pool) {return true}
    return reserve(pool,needed+min(needed/2,int(POOL_SLACK_BYTES/size_of(T))))==nil
}

@(private)
pool_release :: proc(pool:^[dynamic]$T,free:^[dynamic]Pool_Range,first,count:u32) {
    range_add(free,{first,count})
    for i:=0;i<len(free); {
        range:=free^[i]
        if range.first+range.count!=u32(len(pool)) {i+=1;continue}
        base.truncate(pool,range.first)
        unordered_remove(free,i)
        i=0
    }
}

// What scene_set built from the meshes. Instances are gone until the next scene_set.
@(private)
scene_instances_clear :: proc(s: ^Scene_State) {
	clear(&s.translucent)
	clear(&s.instances)
	clear(&s.instance_next)
	clear(&s.instance_prev)
	for &mesh in s.meshes {mesh.first_instance=-1}
	clear(&s.overlays);s.overlay_count=0;clear(&s.reflective)
	clear(&s.instance_keys)
	clear(&s.desc_instance)
	s.highlighted = 0
	clear(&s.hw_instances)
	clear(&s.tlas_items)
	touched_trim(s, 0)
	s.hidden_count = 0
	clear(&s.tlas_refs)
	clear(&s.tlas_nodes)
	append(&s.tlas_nodes, Gpu_Bvh_Node{bounds_min = {1, 1, 1}, bounds_max = {-1, -1, -1}})
	append(&s.tlas_refs, 0)
	s.tlas_node_count, s.glass_node_count = 1, 0
	s.has_bounds = false
}

// Removes only this mesh's ranges and hides the instances that named it.
mesh_remove :: proc(r: ^Renderer, handle: Mesh_Handle) -> bool {
	scene_changed(&r.scene)
	return mesh_release(r, handle)
}

// The same without changing the light of the scene: for a pose no instance shows.
@(private)
mesh_release :: proc(r: ^Renderer, handle: Mesh_Handle) -> bool {
	s := &r.scene
	if int(handle) >= len(s.meshes) || s.meshes[handle].vertex_count == 0 {return false}
	mesh_ray_release(r, handle)
	removed := s.meshes[handle]
	freed := u64(removed.vertex_span + removed.index_span) * 4
	for ray in removed.rays[:removed.ray_count] {
		freed += u64(ray.table_count) * 4 + u64(ray.bvh_node_count) * size_of(Gpu_Bvh_Node) + u64(ray.triangle_count) * size_of(Gpu_Bvh_Triangle)
		if ray.blas != 0 {freed += u64(ray.table_count) * BLAS_TRIANGLE_BYTES}
	}
	geometry_released(s, freed)
	// What still went over frames goes with it, before the binding it may carry.
	geometry_uploads_cancel(s, i64(handle))
	skin_free(r,removed.skin)
	skin_binding_release(r,removed.skin_binding)
	if removed.stream!=nil {mesh_stream_remove(r,u32(handle),removed.stream)}
	if removed.skin!=nil {for skin,index in s.skinned {if skin==handle {unordered_remove(&s.skinned,index);break}}}
	// A pose of it keeps its copy, of a source no other mesh that takes the handle is.
	for _,pose in s.displaced {if pose!=handle && mesh_displaced(s,u32(pose)) && s.meshes[pose].skin.source==handle {s.meshes[pose].skin.source=Mesh_Handle(GPU_NONE)}}
	pool_release(&s.vertices,&s.pool_free[.Vertex],removed.vertex_word,removed.vertex_span)
	pool_release(&s.indices,&s.pool_free[.Index],removed.index_word,removed.index_span)
	for ray in removed.rays[:removed.ray_count] {
		if ray.blas != 0 {rhi.accel_destroy(r.device, ray.blas)}
		if ray.bvh_node_count>0 {
			pool_release(&s.blas_nodes,&s.pool_free[.Node],ray.bvh_root,ray.bvh_node_count)
			pool_release(&s.blas_triangles,&s.pool_free[.Triangle],ray.triangle_offset,ray.triangle_count)
		}
		if ray.table_count>0 {pool_release(&s.indices,&s.pool_free[.Index],ray.table_word,ray.table_count)}
		if ray.input_vertices>0 {pool_release(&s.vertices,&s.pool_free[.Vertex],ray.input_vertex,ray.input_vertices)}
		if ray.input_indices>0 {pool_release(&s.indices,&s.pool_free[.Index],ray.input_index,ray.input_indices)}
	}
	// Its instances leave its list: they are in none until written again.
	for index:=removed.first_instance;index>=0; {
		inst:=&s.instances[index]
		next:=s.instance_next[index]
		s.instance_next[index],s.instance_prev[index]=-1,-1
		if inst.meta.w&(INSTANCE_FLAG_HIDDEN|INSTANCE_FLAG_TRANSLUCENT)==0 {
			for layer in s.overlays[index].entries[:s.overlays[index].count] {if layer.enabled {s.overlay_count-=1}}
		}
		occluder_moved(s,u32(index),inst^,INSTANCE_ABSENT)
		if inst.meta.w&INSTANCE_FLAG_HIDDEN==0 {inst.meta.w|=INSTANCE_FLAG_HIDDEN;s.hidden_count+=1}
		// Hidden for good: no move shows it with the mesh that takes the handle.
		inst.meta.w&~=INSTANCE_FLAG_COLLAPSED
		s.hw_instances[index].mask_flags=0
		s.overlays[index]={}
		instance_touch(s, u32(index))
		index=next
	}
	for i:=len(s.translucent)-1;i>=0;i-=1 {if s.instances[s.translucent[i].instance].meta.x&INSTANCE_MESH_MASK==u32(handle) {unordered_remove(&s.translucent,i)}}
	for i:=len(s.reflective)-1;i>=0;i-=1 {if s.instances[s.reflective[i].instance].meta.x&INSTANCE_MESH_MASK==u32(handle) {unordered_remove(&s.reflective,i)}}
	batches_mesh_removed(s, handle)
	s.triangle_total -= u64(removed.triangle_count)
	s.meshes[handle] = {first_instance=-1}
	append(&s.free_meshes,u32(handle))
	range_add(&s.mesh_dirty,{u32(handle),1})
	s.geometry_dirty = true
	s.tlas_dirty = true
	return true
}

// The entry a new texture takes: the first a removed one left, else the next.
@(private)
texture_slot :: proc "contextless" (state: ^Texture_State) -> int {
	for texture, index in state.textures[:state.count] {
		if texture == 0 {return index}
	}
	return state.count
}

// Removes one texture, between frames. The handles of the others stay as
// they are and the next texture added takes the one this leaves. Materials
// that name it must be replaced with materials_set before the next frame.
// False for a handle that names no texture.
texture_remove :: proc(r: ^Renderer, handle: Texture_Handle) -> bool {
	scene_changed(&r.scene)
	state := &r.textures
	index := int(handle) - 1
	if index < 0 || index >= state.count || state.textures[index] == 0 {return false}
	rhi.texture_table_set(r.device, texture_entry(index), 0)
	rhi.texture_destroy(r.device, state.textures[index])
	geometry_released(&r.scene, state.stored[index])
	state.bytes -= state.stored[index]
	if state.partial[index] {state.reduced -= 1}
	state.textures[index] = 0
	state.keys[index] = 0
	state.sizes[index] = {}
	state.stored[index] = 0
	state.partial[index] = false
	texture_stream_forget(state, index)
	for state.count > 0 && state.textures[state.count - 1] == 0 {state.count -= 1}
	return true
}
