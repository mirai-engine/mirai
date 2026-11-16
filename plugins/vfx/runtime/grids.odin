package vfx

import "core:math"
import "core:math/linalg"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"

// The grids of a world: a region of cells around an entity, each with layers
// of four floats, that the stages of Vfx programs leave and read and that
// particles splat into and sample. A program finds a grid by its name. The
// region follows its entity by whole cells and wraps in place, so moving it
// copies nothing: the cells that come into it start at zero. Each cell keeps
// two copies, what the stage before left and what this one leaves, and what
// the particles of the step splatted. Making the grids again, or one of
// another size, is a load transaction: their cells start at zero.

GRID_CAPACITY :: 128        // grids of a world
GRID_LAYERS :: 16
GRID_CELLS_MAX :: 65535*64  // of a grid: what one dispatch reaches
GRID_NAME_BYTES :: 32

@(component)
Particle_Grid :: struct {
    name:[GRID_NAME_BYTES]u8 `mirai:"text"`,
    cells:[3]u32,                         // along x, y and z of the world; an axis of one cell is flat
    cell_size:f32 `mirai:"min=0,unit=m"`,
    layers:u32 `mirai:"min=1,max=16"`,    // of four floats in each cell
    cached:base.Asset_Id,                 // a .grid of its cells and layers whose state its cells start from, when the grid is made or names another
    follow_view:bool,                     // its region is around where the view (the camera that draws the world) looks at the height of its entity, instead of around its entity
}

PARTICLE_GRID_DEFAULT :: Particle_Grid{cells={64,1,64},cell_size=0.25,layers=1}

// The grid of its entity drawn as a medium: in its first layer, x its
// density and y how much it glows. It is drawn by marching through its
// region at its resolution, lit by what each of its cells receives (the
// light of media, shared with fog): the sun through the scene and through
// the medium towards it, one local light a frame by turns, and the light
// around. A volume draws a grid with more than one cell along each axis.
@(component)
Particle_Volume :: struct {
    density:f32 `mirai:"min=0,unit=1/m"`,          // what a unit of density stops in a metre
    albedo:[3]f32 `mirai:"color"`,                // what it scatters of what it stops
    anisotropy:f32 `mirai:"min=-0.95,max=0.95"`,  // where it scatters: forward above 0
    emission:[3]f32 `mirai:"color"`,              // nits a unit of glow gives
}

PARTICLE_VOLUME_DEFAULT :: Particle_Volume{density=4,albedo={0.8,0.8,0.8},anisotropy=0.2,emission={4,1.6,0.4}}

// A layer of the grid of its entity, flat along y, that materials read as a
// texture of the world by the name of the grid (vfx_world_texture of
// shaders/vfx_world_texture.slang in a Surface program): over its region,
// between its cells; zero outside it. It is what the grid holds after the
// steps of the frame before, at most WORLD_TEXTURES in a world.
@(component)
Particle_World_Texture :: struct {
    layer:u32 `mirai:"max=3"`,
}

WORLD_TEXTURES :: 4

// shaders/vfx_world.slang: the textures of the world in the constants of each view.
Gpu_World_Frame :: struct {
    names:[WORLD_TEXTURES]u32,          // world_texture_name of the name of each grid; 0: none
    textures:[WORLD_TEXTURES]u32,       // their places in the texture table
    starts:[WORLD_TEXTURES/2][4]f32,    // the uv of the lowest corner of the region of each, two in a row
    bounds:[WORLD_TEXTURES][4]f32,      // the region of each, relative to the origin of the frame: lowest x and z, then highest
}
#assert(size_of(Gpu_World_Frame)==128)

// The textures of the world as the steps of a frame left them: the region of
// each in cells of the world, which the views of a frame place relative to
// their origin (world_frame_gpu).
World_Textures_Frame :: struct {
    names:[WORLD_TEXTURES]u32,
    textures:[WORLD_TEXTURES]u32,
    first,cells:[WORLD_TEXTURES][2]i32, // along x and z
    cell_size:[WORLD_TEXTURES]f32,
}

// The textures of the world for the constants of a view whose places are
// relative to origin. The cell c of the world is at the texel c modulo the
// cells: the lowest corner of a region is at the uv of its first cell over them.
world_frame_gpu :: proc "contextless" (shown:World_Textures_Frame,origin:[3]f32) -> (frame:Gpu_World_Frame) {
    frame.names,frame.textures=shown.names,shown.textures
    for i in 0..<WORLD_TEXTURES {
        if shown.names[i]==0 {continue}
        first,cells,size:=shown.first[i],shown.cells[i],f64(shown.cell_size[i])
        start:[2]f32
        for axis in 0..<2 {
            n:=i64(max(cells[axis],1))
            start[axis]=f32(f64((i64(first[axis])%n+n)%n)/f64(n))
        }
        frame.starts[i/2][i%2*2],frame.starts[i/2][i%2*2+1]=start.x,start.y
        low:=erender.origin_cell({first.x,0,first.y},size,origin)
        high:=erender.origin_cell({first.x+cells.x,0,first.y+cells.y},size,origin)
        frame.bounds[i]={low.x,low.z,high.x,high.z}
    }
    return
}

// The name of a texture of the world as a Surface program names it
// (getStringHash of Slang).
world_texture_name :: proc "contextless" (name:string) -> (hash:u32) {
    for c in transmute([]u8)name {hash=u32(c)+(hash<<6)+(hash<<16)-hash}
    return
}

// A grid of the world as the plugin keeps it.
Grid_Entry :: struct {
    entity:core.Entity,
    name:u64,                // base.name_hash of its name
    cells:[3]u32,
    layers:u32,
    cell_size:f32,
    first:[3]i32,            // the cell of the world where its region starts
    cleared:[3]i32,          // where it started when the GPU last cleared the cells that came in
    offset,splat:u32,        // bytes of its copies and of its splats among the grids
    writer:u64,              // the emitter whose stages over it run this frame; 0: none
    held:u64,                // the last writer since its cells were cleared; 0: none
    volume:Particle_Volume,  // with has_volume: it is drawn as one
    has_volume:bool,
    texture:Particle_World_Texture, // with has_texture: materials read a layer of it
    has_texture:bool,
    texture_name:u32,        // world_texture_name of its name
    texture_index:u32,       // the place of its texture in the table, from particles_frame
    cached:base.Asset_Id,    // the .grid its cells start from
    loaded:base.Asset_Id,    // the .grid its cells took last; zero since they were made
    packed:u32,              // with has_texture: bytes of its layer as halves among the grids, which its texture copies
    light:u32,               // of a volume: bytes of the light of its cells among the grids
}

Grids :: struct {
    entries:[dynamic]Grid_Entry,
    bytes:u32,   // of all of them: their parities, their copies, their splats, the light of the cells of the volumes, then the layers of the textures
    splats:u32,  // bytes to the splats of all of them
    layout:u64,  // of the cells and layers of each: when it changes they are made again
    made:bool,   // the world buffer holds them, zeroed, as layout says
}

grids_free :: proc(g:^Grids) {
    delete(g.entries)
    g^={}
}

// shaders/particles.slang: Particle_Grid_Row.
Gpu_Grid :: struct {
    cells:[3]u32, layers:u32,
    first:[3]i32, cell_size:f32,
    previous:[3]i32, parity:u32, // bytes of the word that says which copy holds what the stage before left
    offset,splat,moved,pad:u32,  // bytes of its copies and splats in the world buffer; moved: its region moved since the frame before
    phase:[3]u32, pad1:u32,      // where the first cell of its region is among its cells, which wrap in place
    corner:[3]f32, pad2:u32,     // the lowest corner of its first cell, relative to the origin of the frame
}
#assert(size_of(Gpu_Grid)==96)

// Where the first cell of a region is among the cells of a grid: its first
// along each axis wrapped to them, never below zero.
@(private)
grid_phase :: proc "contextless" (first:[3]i32,cells:[3]u32) -> (phase:[3]u32) {
    for axis in 0..<3 {
        n:=i64(max(cells[axis],1))
        phase[axis]=u32((i64(first[axis])%n+n)%n)
    }
    return
}

@(private)
grid_cells :: proc "contextless" (cells:[3]u32) -> u32 {return cells.x*cells.y*cells.z}

// The grids of the world in this frame: where each region starts, and their
// place in the world buffer, which moves only when a grid comes, goes or
// changes its cells or layers. A grid it does not take is a problem.
@(private)
grids_sync :: proc(g:^Grids,grids:^core.Table(Particle_Grid,$A),volumes:^core.Table(Particle_Volume,$B),textures:^core.Table(Particle_World_Texture,$C),worlds:^core.Table(core.World_Transform,$D),view:core.View,problems:^core.Problems) {
    kept,textured:=0,0
    count:=core.count(grids)
    layout:=u64(count)+1
    // The grids of the frame before go first: of two with one name, the one
    // that had it keeps it, whatever the order of the rows.
    for turn in 0..<2*count {
        row:=turn%count
        e:=core.entity_at(grids,row)
        was:=false
        for entry in g.entries {was||=entry.entity==e}
        if was!=(turn<count) {continue}
        grid:=core.at(grids,row)
        world,placed:=core.get(worlds,e)
        if !placed {continue}
        name:=base.name_hash(base.text_get(grid.name[:]))
        cells:=[3]u32{max(grid.cells.x,1),max(grid.cells.y,1),max(grid.cells.z,1)}
        switch {
        case u64(cells.x)*u64(cells.y)*u64(cells.z)>GRID_CELLS_MAX:
            core.report(problems,e,"vfx.grid","a grid has at most %d cells: give it fewer",GRID_CELLS_MAX)
            continue
        case !(grid.cell_size>0):
            core.report(problems,e,"vfx.grid","give the grid a cell_size above 0")
            continue
        case grid.layers<1 || grid.layers>GRID_LAYERS:
            core.report(problems,e,"vfx.grid","a grid has from 1 to %d layers",GRID_LAYERS)
            continue
        case kept==GRID_CAPACITY:
            core.report(problems,e,"vfx.grid","a world has at most %d grids",GRID_CAPACITY)
            continue
        }
        named:=false
        for other in g.entries[:kept] {named||=other.name==name}
        if named {
            core.report(problems,e,"vfx.grid","another grid of the world has this name: give each its own")
            continue
        }
        // The one it was, if it was one, keeps where its cells were cleared;
        // a new one starts as none was.
        at:=len(g.entries)
        for i in kept..<len(g.entries) {
            if g.entries[i].entity==e {at=i;break}
        }
        if at==len(g.entries) {append(&g.entries,Grid_Entry{entity=e})}
        g.entries[kept],g.entries[at]=g.entries[at],g.entries[kept]
        entry:=&g.entries[kept]
        kept+=1
        entry.name,entry.cells,entry.layers,entry.cell_size,entry.writer=name,cells,grid.layers,grid.cell_size,0
        entry.volume,entry.has_volume=core.get(volumes,e)
        if entry.has_volume && (cells.x<2 || cells.y<2 || cells.z<2) {
            core.report(problems,e,"vfx.volume","a volume draws a grid with more than one cell along each axis: give its grid cells along x, y and z")
            entry.has_volume=false
        }
        entry.texture,entry.has_texture=core.get(textures,e)
        entry.cached=grid.cached
        entry.texture_name=world_texture_name(base.text_get(grid.name[:]))
        switch {
        case !entry.has_texture:
        case cells.y!=1:
            core.report(problems,e,"vfx.world_texture","a texture of the world reads a grid flat along y: give its grid one cell along y")
            entry.has_texture=false
        case entry.texture.layer>=grid.layers:
            core.report(problems,e,"vfx.world_texture","the grid has %d layers: read one below that",grid.layers)
            entry.has_texture=false
        case textured==WORLD_TEXTURES:
            core.report(problems,e,"vfx.world_texture","a world has at most %d textures of the world",WORLD_TEXTURES)
            entry.has_texture=false
        case:
            textured+=1
        }
        position:=world.transform.position
        if grid.follow_view {position.xz=view_ahead(view,position.y,f32(cells.x)*grid.cell_size,f32(cells.z)*grid.cell_size)}
        first:[3]i32
        for axis in 0..<3 {
            first[axis]=i32(math.floor(position[axis]/grid.cell_size))-i32(cells[axis]/2)
        }
        entry.first=first
        layout=base.hash_combine(layout,base.hash_combine(u64(e),u64(cells.x)|u64(cells.y)<<21|u64(cells.z)<<42))
        layout=base.hash_combine(layout,u64(grid.layers)|u64(entry.has_volume)<<8|u64(entry.has_texture)<<9)
    }
    base.truncate(&g.entries,kept)
    grids_place(g,layout)
}

// Where the region of a grid that follows the view stands over the plane at height: from
// the eye toward where the middle of the view meets that plane, but no further than keeps
// what the bottom of the view meets VIEW_NEAR of its half inside it. A camera high over it
// sees the waves where it looks; one low over it, those in front of it too.
@(private)
view_ahead :: proc "contextless" (view:core.View,height,width,depth:f32) -> [2]f32 {
    forward:=mm.quat_forward(view.rotation)
    flat:=[2]f32{forward.x,forward.z}
    along:=linalg.length(flat)
    if !(along>1e-4) {return view.position.xz}
    // How far along the plane a ray from the eye meets it; false looking up or level.
    meet :: proc "contextless" (view:core.View,ray:[3]f32,height:f32) -> (f32,bool) {
        if !(ray.y< -1e-4) {return 0,false}
        return max(view.position.y-height,0)/-ray.y*linalg.length([2]f32{ray.x,ray.z}),true
    }
    near:=min(width,depth)*0.5*VIEW_NEAR
    ahead,met:=meet(view,forward,height)
    if !met {ahead=max(width,depth)}
    bottom:=forward
    if view.projection==.Perspective {bottom=mm.quat_rotate(view.rotation,linalg.normalize([3]f32{0,-math.tan(view.fov*0.5),-1}))}
    if nearest,seen:=meet(view,bottom,height);seen {ahead=min(ahead,nearest+near)} else {ahead=min(ahead,near)}
    return view.position.xz+flat/along*ahead
}

// Of the half of a region that follows the view, how far inside it the nearest water seen stays.
VIEW_NEAR :: f32(0.8)

// The grids whose last writer is gone from the pool, its particles too: nothing moves
// or fades what they hold any more, so their cells are cleared once, as those that come
// into a region that moved.
@(private)
grids_release :: proc(g:^Grids,pool:^Pool) {
    for &entry in g.entries {
        if entry.writer!=0 {entry.held=entry.writer;continue}
        if entry.held==0 || pool_slot_find(pool,entry.held)>=0 {continue}
        entry.held=0
        for axis in 0..<3 {entry.cleared[axis]=entry.first[axis]+i32(entry.cells[axis])}
    }
}

// Where each grid is among them, when their layout changes: they are made again.
@(private)
grids_place :: proc(g:^Grids,layout:u64) {
    if layout==g.layout {return}
    g.layout,g.made=layout,false
    bytes:=u32(GRID_CAPACITY*4)
    for &entry in g.entries {
        entry.offset=bytes
        bytes+=2*grid_cells(entry.cells)*entry.layers*16
    }
    g.splats=bytes
    for &entry in g.entries {
        entry.splat=bytes
        bytes+=grid_cells(entry.cells)*entry.layers*16
    }
    for &entry in g.entries {
        entry.light=bytes
        if entry.has_volume {bytes+=grid_cells(entry.cells)*16}
    }
    for &entry in g.entries {
        entry.packed=bytes
        if entry.has_texture {bytes+=grid_cells(entry.cells)*8+16} // its texels from the first multiple of 16
    }
    g.bytes=bytes
}

// shaders/particles.slang: Particle_Volume_Row.
Gpu_Volume :: struct {
    grid,light:u32,              // bytes of its grid in the rows of the frame, of the light of its cells in the world buffer
    density,anisotropy:f32,
    albedo:[3]f32, pad0:u32,
    emission:[3]f32, pad1:u32,
}
#assert(size_of(Gpu_Volume)==48)

@(private)
grid_of_entity :: proc(g:^Grids,e:core.Entity) -> int {
    for entry,at in g.entries {
        if entry.entity==e {return at}
    }
    return -1
}

@(private)
grid_find :: proc(g:^Grids,name:u64) -> int {
    for entry,at in g.entries {
        if entry.name==name {return at}
    }
    return -1
}
