package vfx

import "core:mem"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:std/base"
import "plugins:vfx/runtime/gridfile"

// The states of grids in files (.grid, gridfile): a grid that names one
// starts from it when it is made, and again when it names another. A state
// keeps the cells of the region from its first one, so a grid takes it
// wherever its region is.

// A state of the frame for a grid: its cells as the grid keeps them, in
// load_bytes from at.
Grid_Load :: struct {
    grid:u64,          // the name of the grid
    cached:base.Asset_Id,
    at,size:int,
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
            core.report(problems,entry.entity,"vfx.memory","out of memory for the cached state of this grid; it is read again in the next frame: free memory, or give the grid fewer cells")
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
