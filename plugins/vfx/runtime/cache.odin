package vfx

import "core:mem"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/gridfile"

// The states of grids baked to files (.grid, gridfile): a grid that names
// one starts from it when it is made, and again when it names another. A
// state keeps the cells of the region from its first one, so a grid takes it
// wherever its region is. Baking reads back the cells of a grid as the steps
// of a frame left them (grid_bake_ask, then grid_bake_take frames later).

GRID_BAKE_READBACK :: "vfx grid bake"

// A state of the frame for a grid: its cells as the grid keeps them, in
// load_bytes from at.
Grid_Load :: struct {
    grid:u64,          // the name of the grid
    cached:base.Asset_Id,
    at,size:int,
}

// A bake asked of a grid: the readback of the frame that ends its steps.
Grid_Bake :: struct {
    grid:u64,          // the name of the grid; 0: none asked
    asked:bool,        // the next frame reads it back
    bytes:u64,         // of the readback: the grids from their start to the end of the copies of this one
    frame:u64,         // whose steps it reads back; 0: not yet
}

// The states the grids of the world start from in this frame, read from
// their files, in the order the grids keep their cells. A file that is not
// one of the cells and layers of its grid is a problem of the grid.
grids_load_prepare :: proc(sync:^Particle_Sync,assets:^host.Assets,problems:^core.Problems=nil) {
    clear(&sync.loads)
    clear(&sync.load_bytes)
    a:=assets
    if a==nil {return}
    for &entry in sync.grids.entries {
        if entry.cached=={} || entry.loaded==entry.cached {continue}
        file:=host.assets_document(a,entry.cached,gridfile.GRID_KIND)
        if file==nil {continue}
        info,cells,error:=gridfile.grid_view(file,&a.types)
        if error!=.None {
            host.assets_document_refuse(a,entry.cached,error)
            continue
        }
        if info.cells!=entry.cells || info.layers!=entry.layers {
            if problems!=nil {core.report(problems,entry.entity,"vfx.grid","its cached state is of %v cells and %d layers, not %v and %d: bake it again",info.cells,info.layers,entry.cells,entry.layers)}
            entry.loaded=entry.cached
            continue
        }
        size:=len(cells)*4
        at:=len(sync.load_bytes)
        if resize(&sync.load_bytes,at+size)!=nil {
            core.report(problems,entry.entity,"vfx.memory","out of memory for the cached state of this grid; it is read again in the next frame: free memory, or bake fewer cells")
            continue
        }
        out:=mem.slice_data_cast([]f32,sync.load_bytes[at:])
        phase:=grid_phase(entry.first,entry.cells)
        floats:=int(entry.layers)*4
        for z in 0..<entry.cells.z {
            for y in 0..<entry.cells.y {
                for x in 0..<entry.cells.x {
                    local:=int(x+entry.cells.x*(y+entry.cells.y*z))
                    kept:=grid_at(entry.cells,{(x+phase.x)%entry.cells.x,(y+phase.y)%entry.cells.y,(z+phase.z)%entry.cells.z})
                    copy(out[kept*floats:][:floats],cells[local*floats:][:floats])
                }
            }
        }
        append(&sync.loads,Grid_Load{entry.name,entry.cached,at,size})
    }
}

@(private)
grid_at :: proc "contextless" (cells,cell:[3]u32) -> int {return int(cell.x+cells.x*(cell.y+cells.y*cell.z))}

// Writes the states of the frame into both copies of their grids.
@(private)
grids_load :: proc(sync:^Particle_Sync,pass:^erender.Pass) {
    world:=world_buffer(sync)
    base:=u64(grids_base(sync))
    for load in sync.loads {
        at:=grid_find(&sync.grids,load.grid)
        if at<0 {continue}
        entry:=&sync.grids.entries[at]
        if load.cached!=entry.cached || load.size!=int(grid_cells(entry.cells)*entry.layers*16) {continue}
        data:=raw_data(sync.load_bytes[load.at:])
        first:=base+u64(entry.offset)
        if !erender.pass_buffer_write(pass,world,first,data,load.size) || !erender.pass_buffer_write(pass,world,first+u64(load.size),data,load.size) {continue}
        entry.loaded,entry.cleared=entry.cached,entry.first
    }
    clear(&sync.loads)
}

// Asks for the cells of the grid of an entity as the steps of the next frame
// leave them. False when the world has no such grid.
grid_bake_ask :: proc(sync:^Particle_Sync,e:core.Entity) -> bool {
    for &entry in sync.grids.entries {
        if entry.entity!=e {continue}
        sync.bake={grid=entry.name,asked=true,bytes=u64(entry.offset)+u64(2*grid_cells(entry.cells)*entry.layers*16),frame=0}
        return true
    }
    return false
}

// The readback of a bake, after the steps of a frame.
@(private)
grid_bake_read :: proc(sync:^Particle_Sync,pass:^erender.Pass) {
    if !sync.bake.asked || sync.bake.bytes==0 {return}
    sync.bake.asked=false
    sync.bake.frame=pass.frame
    erender.pass_readback(pass,world_buffer(sync),u64(grids_base(sync)),{GRID_BAKE_READBACK,sync.bake.bytes})
}

// The state of the grid of the last bake as a file holds it, from what came
// back: the copy its last stage left, from the first cell of its region, in
// allocator, once: the bake is done. False while nothing came back, or the
// grid changed since.
grid_bake_take :: proc(sync:^Particle_Sync,renderer:^erender.Renderer,world:core.World_Id,allocator:=context.allocator) -> (info:gridfile.Grid_Info,cells:[]f32,ok:bool) {
    data,frame,read:=erender.readback(renderer,world,GRID_BAKE_READBACK)
    if !read || sync.bake.grid==0 || sync.bake.frame==0 || frame<sync.bake.frame {return}
    at:=grid_find(&sync.grids,sync.bake.grid)
    if at<0 {return}
    entry:=&sync.grids.entries[at]
    count:=grid_cells(entry.cells)
    floats:=int(entry.layers)*4
    end:=int(entry.offset)+2*int(count)*floats*4
    if len(data)<end || u64(len(data))!=sync.bake.bytes {return}
    parity:=(cast(^u32)&data[at*4])^&1
    copy_at:=int(entry.offset)+int(parity)*int(count)*floats*4
    kept:=mem.slice_data_cast([]f32,data[copy_at:][:int(count)*floats*4])
    allocated,allocation_error:=make([]f32,int(count)*floats,allocator)
    if allocation_error!=nil {return}
    cells=allocated
    phase:=grid_phase(entry.first,entry.cells)
    for z in 0..<entry.cells.z {
        for y in 0..<entry.cells.y {
            for x in 0..<entry.cells.x {
                local:=int(x+entry.cells.x*(y+entry.cells.y*z))
                from:=grid_at(entry.cells,{(x+phase.x)%entry.cells.x,(y+phase.y)%entry.cells.y,(z+phase.z)%entry.cells.z})
                copy(cells[local*floats:][:floats],kept[from*floats:][:floats])
            }
        }
    }
    sync.bake={}
    return {cells=entry.cells,layers=entry.layers,cell_size=entry.cell_size},cells,true
}

// Gives up the bake asked: what comes back of it is not taken.
grid_bake_cancel :: proc "contextless" (sync:^Particle_Sync) {sync.bake={}}

// Whether a bake is asked and not yet taken.
grid_bake_pending :: proc "contextless" (sync:^Particle_Sync) -> bool {return sync.bake.grid!=0}
