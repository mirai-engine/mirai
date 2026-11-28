package vfx

import "core:mem"
import "core:slice"
import "mirai:core"
import erender "mirai:engine/render"

// The textures of the world: layers of grids that materials read
// (Particle_World_Texture). After the steps of each frame a pass packs each
// layer as halves after the grids and the renderer copies it into a dynamic
// texture the world keeps for the grid, and the
// views of the world have in their constants (shaders/vfx_world.slang) the
// name, the place and the region of each as the frame before left them: what
// the first view draws before the steps of its frame holds that.

// The grids of the world with a texture, and the textures of those that no
// longer have one released.
@(private)
world_textures_keep :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,id:core.World_Id) {
    kept:=0
    for name,i in sync.world_textures[:sync.world_texture_count] {
        texture:=sync.world_texture_handles[i]
        sync.world_texture_handles[i]=0
        if at:=grid_find(&sync.grids,name);at>=0 && sync.grids.entries[at].has_texture {
            sync.world_textures[kept],sync.world_texture_handles[kept]=name,texture
            kept+=1
        } else {
            erender.texture_remove(renderer,texture)
        }
    }
    for &entry in sync.grids.entries {
        if !entry.has_texture || kept==WORLD_TEXTURES || slice.contains(sync.world_textures[:kept],entry.name) {continue}
        sync.world_textures[kept],sync.world_texture_handles[kept]=entry.name,0
        kept+=1
    }
    if kept!=sync.world_texture_count {
        sync.world_texture_count=kept
        sync.world_texture_layout_dirty=true
    }
}

// The texture a grid keeps of the world, by its name; 0 without one.
@(private)
world_texture_handle :: proc "contextless" (sync:^Particle_Sync,name:u64) -> erender.Texture_Handle {
    for kept,i in sync.world_textures[:sync.world_texture_count] {
        if kept==name {return sync.world_texture_handles[i]}
    }
    return 0
}

// The textures of the grids that have one, made between frames, of zeros,
// and made again with the size of their cells when it changes.
@(private)
world_textures_make :: proc(sync:^Particle_Sync,renderer:^erender.Renderer) {
    for &entry in sync.grids.entries {
        if !entry.has_texture {continue}
        at:=-1
        for name,i in sync.world_textures[:sync.world_texture_count] {
            if name==entry.name {at=i;break}
        }
        if at<0 {
            entry.texture_index=max(u32)
            continue
        }
        texture:=&sync.world_texture_handles[at]
        if texture^!=0 && erender.texture_size(renderer,texture^)!={entry.cells.x,entry.cells.z} {
            erender.texture_remove(renderer,texture^)
            texture^=0
        }
        // A texture made again of zeros can take the slot it freed, and so its index.
        made:=texture^==0
        if made {
            ok:bool
            if texture^,ok=erender.texture_add_dynamic(renderer,entry.cells.x,entry.cells.z,.RGBA16F,false,"vfx world texture");!ok {
                entry.has_texture=false
                continue
            }
        }
        index:=erender.texture_index(texture^)
        entry.texture_dirty||=made || entry.texture_index!=index
        entry.texture_index=index
    }
}

// Copies each grid with a texture of the world into its texture, after the steps.
@(private)
world_textures_write :: proc(sync:^Particle_Sync,pass:^erender.Pass) {
    if sync.world_textures_changed {
        sync.world_shown=sync.world_frame
        sync.world_textures_changed=false
    }
    dirty:=sync.world_texture_layout_dirty
    for &entry in sync.grids.entries {
        if entry.has_texture && entry.texture_dirty {dirty=true;break}
    }
    if !dirty {return}
    sync.world_texture_layout_dirty=false
    frame:World_Textures_Frame
    count:=0
    Params :: struct {grid,layer,packed,pad:u32}
    for &entry,at in sync.grids.entries {
        if !entry.has_texture || count==WORLD_TEXTURES || entry.texture_index==max(u32) {continue}
        if entry.texture_dirty {
            packed:=grids_base(sync)+entry.packed
            params:=Params{sync.pool.grids_at+u32(at)*size_of(Gpu_Grid),entry.texture.layer,packed,0}
            erender.pass_pipeline(pass,sync.pipelines.world_texture)
            erender.pass_params(pass,&params,size_of(params))
            erender.pass_dispatch(pass,groups(entry.cells.x,8),groups(entry.cells.z,8))
            if !erender.pass_texture_copy(pass,world_buffer(sync),u64(packed+15)&~u64(15),world_texture_handle(sync,entry.name)) {continue}
            entry.texture_dirty=false
        }
        frame.names[count],frame.textures[count]=entry.texture_name,entry.texture_index
        frame.first[count],frame.cells[count]={entry.first.x,entry.first.z},{i32(entry.cells.x),i32(entry.cells.z)}
        frame.cell_size[count]=entry.cell_size
        count+=1
    }
    if sync.world_frame!=frame {
        sync.world_frame=frame
        sync.world_textures_changed=true
    }
}

// The textures of the world in the constants of each view of the world.
@(private)
world_textures_frame :: proc(pass:^erender.Pass,user:rawptr) {
    sync:=cast(^Particle_Sync)user
    if pass.world!=sync.world {return}
    data:=erender.pass_extension_data(pass,"vfx_world")
    if len(data)<size_of(Gpu_World_Frame) {return}
    frame:=world_frame_gpu(sync.world_shown,pass.origin)
    mem.copy(raw_data(data),&frame,size_of(Gpu_World_Frame))
}

// Where the texture of the world of a grid is, as the steps of the last frame
// left it: what a pass of another plugin reads of it outside the views (the
// vertices of a Geometry stage), by its place in the texture table. The cell c
// of the world is at the texel c modulo cells. False without it.
World_Texture_Place :: struct {
    texture:u32,        // its place in the texture table
    first,cells:[2]i32, // the cell of the world its region starts at, and its cells, along x and z
    cell_size:f32,
}

world_texture_place :: proc "contextless" (sync:^Particle_Sync,name:string) -> (place:World_Texture_Place,ok:bool) {
    if sync==nil {return}
    hash:=world_texture_name(name)
    shown:=&sync.world_frame
    for i in 0..<WORLD_TEXTURES {
        if hash==0 || shown.names[i]!=hash {continue}
        return {shown.textures[i],shown.first[i],shown.cells[i],shown.cell_size[i]},true
    }
    return
}
