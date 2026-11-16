package vfx

import "core:fmt"
import "core:mem"
import "core:slice"
import "mirai:core"
import erender "mirai:engine/render"

// The textures of the world: layers of grids that materials read
// (Particle_World_Texture). After the steps of each frame a pass packs each
// layer as halves after the grids and the renderer copies it into a texture
// of its table that it keeps for the world, and the
// views of the world have in their constants (shaders/vfx_world.slang) the
// name, the place and the region of each as the frame before left them: what
// the first view draws before the steps of its frame holds that.

// The texture of the table of a grid, by the hash of its name.
@(private)
world_texture_key :: proc(name:u64) -> string {return fmt.tprintf("vfx world texture %x",name)}

// The grids of the world with a texture, and the textures of those that no
// longer have one released.
@(private)
world_textures_keep :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,id:core.World_Id) {
    kept:=0
    for name in sync.world_textures[:sync.world_texture_count] {
        if at:=grid_find(&sync.grids,name);at>=0 && sync.grids.entries[at].has_texture {
            sync.world_textures[kept]=name
            kept+=1
        } else {
            erender.table_texture_release(renderer,id,world_texture_key(name))
        }
    }
    for &entry in sync.grids.entries {
        if !entry.has_texture || kept==WORLD_TEXTURES || slice.contains(sync.world_textures[:kept],entry.name) {continue}
        sync.world_textures[kept]=entry.name
        kept+=1
    }
    sync.world_texture_count=kept
}

// The textures of the grids that have one, made between frames.
@(private)
world_textures_make :: proc(sync:^Particle_Sync,renderer:^erender.Renderer) {
    for &entry in sync.grids.entries {
        if !entry.has_texture {continue}
        index,_,ok:=erender.table_texture(renderer,sync.world,{name=world_texture_key(entry.name),width=entry.cells.x,height=entry.cells.z})
        entry.texture_index=index
        if !ok {entry.has_texture=false}
    }
}

// Copies each grid with a texture of the world into its texture, after the steps.
@(private)
world_textures_write :: proc(sync:^Particle_Sync,pass:^erender.Pass) {
    sync.world_shown=sync.world_frame
    frame:World_Textures_Frame
    count:=0
    Params :: struct {grid,layer,packed,pad:u32}
    for &entry,at in sync.grids.entries {
        if !entry.has_texture || count==WORLD_TEXTURES {continue}
        packed:=grids_base(sync)+entry.packed
        params:=Params{sync.pool.grids_at+u32(at)*size_of(Gpu_Grid),entry.texture.layer,packed,0}
        erender.pass_pipeline(pass,sync.pipelines.world_texture)
        erender.pass_params(pass,&params,size_of(params))
        erender.pass_dispatch(pass,groups(entry.cells.x,8),groups(entry.cells.z,8))
        if !erender.pass_table_texture_copy(pass,world_buffer(sync),u64(packed+15)&~u64(15),{name=world_texture_key(entry.name),width=entry.cells.x,height=entry.cells.z}) {continue}
        frame.names[count],frame.textures[count]=entry.texture_name,entry.texture_index
        frame.first[count],frame.cells[count]={entry.first.x,entry.first.z},{i32(entry.cells.x),i32(entry.cells.z)}
        frame.cell_size[count]=entry.cell_size
        count+=1
    }
    sync.world_frame=frame
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
