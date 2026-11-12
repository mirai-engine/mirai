package foliage

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import volume "mirai:engine/volume"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/jobs"

// The foliage of a scene, from its .foliage asset, without an entity per
// instance: the renderer draws batches per cell, type and part (engine/render
// batch_set) and the physics has a static body per cell with a shape per
// instance of a type that collides. A cell is drawn while it is resident by
// the residency of the streaming sources (scene.resident) within the farthest
// cull distance of its types (a type that is never culled keeps every cell),
// up to RESIDENT_CELLS, the nearest. A type with an impostor distance has a
// far form (far.odin) and one that casts shadows in the wind sways in
// variants (wind.odin). What is built is
// by cell: a cell is built again when its content, its ground or the band of
// a type changes, and the others keep their batches. A cell collides while
// it is resident for its collision (physics.odin).

@(component,far,description="Shows the foliage of a .foliage asset in the space of this entity: its manual instances and those its cells generate, with their overrides.")
Foliage :: struct {
    source:base.Asset_Id `mirai:"kind=.foliage"`,
    revision:u32 `mirai:"readonly"`, // of the source it shows: the key of the history of its editor
}

File_Stamp :: struct {size,time:i64,found:bool}

// The sources the Foliage of the world show, as their files hold them.
@(storage)
Foliage_Data :: struct {
    entries:[dynamic]Data_Entry,
    registry:u64, // the revision of the registry when the stamps were last compared
    made:u64,     // entries made: the epoch of the next
    stats:Foliage_Data_Stats,
}
Foliage_Data_Stats :: struct {loads:u64}
Data_Entry :: struct {
    id:base.Asset_Id,
    stamp:File_Stamp, // of the file it was read from
    epoch:u64,        // of this entry: what is built from it compares the versions of its cells under it
    loads:u32,        // times it was read
    versions:u32,     // the last version a cell of it took
    look:u32,         // raised when its types change, also only in how they are drawn
    stroke:u64,       // the revision of the Foliage_Stroke it shows; 0: none
    layout:u32,       // raised when its list of cells may have changed: read again, or a stroke added or took one
    source:Source,
}

// The cells a stroke of the brush of the editor holds before it is a step:
// foliage_load shows them over those of the file of their source, so a touch
// hands over only the cells it changed and the file is written once, when
// the stroke ends; then the stroke is cleared and the file read again. The
// editor is its only writer.
@(storage)
Foliage_Stroke :: struct {
    source:base.Asset_Id,
    revision:u64,        // raised when its cells change
    instances:u32,       // Foliage_Info.instances of the source it edits
    cells:[dynamic]Cell, // in the order of their coordinates; version 0: the source has no cell there
}

// Puts in a stroke the cell of a coordinate as an edited source holds it
// (nil: none); filed: the file of the source has one there. Where neither
// has one and the stroke holds none, it adds nothing.
stroke_cell_set :: proc(stroke:^Foliage_Stroke,coord:[2]i32,cell:^Cell,filed:bool) -> bool {
    at:=coord_lower(stroke.cells[:],coord)
    if at==len(stroke.cells) || stroke.cells[at].coord!=coord {
        if cell==nil && !filed {return true}
        if _,error:=inject_at(&stroke.cells,at,Cell{coord=coord});error!=nil {return false}
    }
    held:=&stroke.cells[at]
    clear(&held.manual);clear(&held.overrides);clear(&held.density)
    held.generate,held.version=false,0
    if cell==nil {return true}
    held.generate,held.version=cell.generate,1
    _,manual:=append(&held.manual,..cell.manual[:])
    _,overrides:=append(&held.overrides,..cell.overrides[:])
    _,density:=append(&held.density,..cell.density[:])
    return manual==nil && overrides==nil && density==nil
}

// Ends what a stroke shows: its source is read again from its file.
stroke_clear :: proc(stroke:^Foliage_Stroke) {
    if stroke.source=={} && len(stroke.cells)==0 {return}
    for &cell in stroke.cells {delete(cell.manual);delete(cell.overrides);delete(cell.density)}
    clear(&stroke.cells)
    stroke.source,stroke.instances={},0
    stroke.revision+=1
}

// Shows the cells of a stroke over those of the source of its entry: each
// that differs takes the next version, and one that is not valid in the
// source is left as it was. Whether one changed.
@(private)
stroke_apply :: proc(entry:^Data_Entry,stroke:^Foliage_Stroke) -> (changed:bool) {
    s:=&entry.source
    s.info.instances=max(s.info.instances,stroke.instances)
    for &held in stroke.cells {
        at:=coord_lower(s.cells[:],held.coord)
        found:=at<len(s.cells) && s.cells[at].coord==held.coord
        if held.version==0 {
            if !found {continue}
            delete(s.cells[at].manual);delete(s.cells[at].overrides);delete(s.cells[at].density)
            ordered_remove(&s.cells,at)
            entry.layout+=1
            changed=true
            continue
        }
        if !cell_valid(s,&held) {continue}
        if found {
            cell:=&s.cells[at]
            if cell.generate==held.generate && same_rows(cell.manual[:],held.manual[:]) && same_rows(cell.overrides[:],held.overrides[:]) && same_rows(cell.density[:],held.density[:]) {continue}
        } else {
            if _,error:=inject_at(&s.cells,at,Cell{coord=held.coord});error!=nil {continue}
            entry.layout+=1
        }
        cell:=&s.cells[at]
        clear(&cell.manual);clear(&cell.overrides);clear(&cell.density)
        _,manual:=append(&cell.manual,..held.manual[:])
        _,overrides:=append(&cell.overrides,..held.overrides[:])
        _,density:=append(&cell.density,..held.density[:])
        if manual!=nil || overrides!=nil || density!=nil {clear(&cell.manual);clear(&cell.overrides);clear(&cell.density)}
        cell.generate=held.generate
        entry.versions+=1
        cell.version=entry.versions
        changed=true
    }
    return
}

// The batches of the cells of each Foliage, kept by world: each world
// publishes its own and takes them with it when it is freed.
@(storage,host,by_world,free="foliage_resident_free")
Foliage_Resident :: struct {
    app:^host.App,
    world:core.World_Id, // the world it publishes in
    owners:[dynamic]Resident_Owner,
    prefabs:[dynamic]Resident_Prefab,
    kinds:[dynamic]Resident_Kind, // the far forms of the assets types show
    crowns:[dynamic]Shared_Crown, // the crowns of cells, which the Foliage that show one source share
    winds:[dynamic]Wind_Set,      // the variants of the meshes that sway casting shadows
    epoch:u64,     // of the batches of the renderer (render.batches_epoch)
    structure:u64, // of the assets, when the meshes of the batches were resolved
    wind:volume.Gpu_Wind, // what the frame gives the shaders of the wind (foliage_wind.slang), in the world: each view takes it relative to its origin
    sway:[4]f32,          // the wind the variants sway with in this frame: its velocity, m/s, and its gusts
    benders:[BENDERS]Bender_Shown, // nearest the first streaming source first
    bender_count:int,
    impostors:Impostor_Draw,
    instances_left,kinds_left:int, // of this frame: the instances it may still build (cell_bound) and the far forms it may make
    detail:[2]f32, // what the cells were built with (FOLIAGE_DETAIL): the share of the points of the types without collision, and of the distances
    work:Build_Work,
    stats:Foliage_Resident_Stats,
}
Foliage_Resident_Stats :: struct {builds,cells,batches,instances:u64}
Resident_Owner :: struct {
    entity:core.Entity,
    source:base.Asset_Id,
    epoch:u64,    // of the entry it was built from
    loads:u32,
    look:u32,     // of the entry: how its types were drawn
    layout:u32,   // of the entry: the cells its cells are matched with
    transform:mm.Transform,
    ground:u32,   // the revision of its ground then
    sources:u64,  // the revision of the streaming sources its cells were chosen by
    removed:u64,  // the hash of the instances taken out of it then (Removed_Owner)
    marked:u64,   // the hash of the marks of its instances then (Marked_Owner)
    cells:[dynamic]Resident_Cell, // in the order of the cells of the source
    resident:[dynamic]u32,        // the index in cells of those resident, in their order
    types:[dynamic]Type_Draw,     // by index of the type in its source
    parts:[dynamic]Part_Draw,
    kinds:[dynamic]Kind_Key,      // by type: the far form it shows; none for a type without one
    winds:[dynamic]Wind_Key,      // the variants its types sway with
    slot:u32,                     // of no other owner: where the rows of its types start (Impostor_Draw.bases)
    built:bool,   // its cells are those of its source, transform and ground
    pending:bool, // some of its cells, or the far forms of its types, wait for the budget of a frame
    far_only:bool, // of a section that is not loaded (scene.Far_Kept): only the far forms of its types
}
// The batches of a cell: of a cell of the source at a version, on a ground at
// a revision, while it is resident.
Resident_Cell :: struct {
    coord:[2]i32,
    version:u32,
    ground:u32,
    removed:u64,   // the hash of the instances taken out of it (removed_cell)
    marked:u64,    // the hash of the marks of its instances (marked_cell)
    built:bool,
    stale:bool,    // it waits for the budget of a frame to be built again
    resident:bool, // near a streaming source
    near:[dynamic]bool, // by type: within the distance where its mesh is gone (no far form: always)
    far:bool,           // past CELL_CROWN_REACH times the reach of its meshes: rays meet one crown of the cell
    crown:base.Asset_Id, // that crown, generated; none while its crowns are those of its instances
    batches:[dynamic]Resident_Batch,
    impostors:u32, // its block of Impostor_Draw.blocks, plus one; 0: none
}
// A batch of a cell, a type, a part of it (0 for a type with a mesh) and a role.
Resident_Batch :: struct {
    type:u32,
    part:u32,
    role:Batch_Role,
    handle:render.Batch_Handle,
}

// What a batch of a cell is for: its mesh as the type shows it; a variant of
// the wind; the mesh at rest that the rays which do not see a variant meet;
// the crown rays meet far away.
Batch_Role :: distinct u32
ROLE_MESH :: Batch_Role(0)
ROLE_REST :: Batch_Role(1)
ROLE_CROWN :: Batch_Role(2)
ROLE_CELL_CROWN :: Batch_Role(3) // of no type: the crown of the whole cell

// The crown of a cell of a source, in the space of its Foliage: every
// Foliage that shows the source with the same instances there traces the
// same mesh, placed by its own transform (a world of sections that reference
// one scene many times).
Shared_Crown :: struct {
    source:base.Asset_Id,
    coord:[2]i32,
    key:u64, // crown_key of what it is made of
    mesh:base.Asset_Id,
    users:int,
}

// Lets go of a cell crown: the last cell that traces it takes its mesh.
@(private)
crown_release :: proc(resident:^Foliage_Resident,mesh:base.Asset_Id) {
    if mesh=={} {return}
    for &c,i in resident.crowns {
        if c.mesh!=mesh {continue}
        c.users-=1
        if c.users>0 {return}
        if resident.app!=nil && resident.app.assets!=nil {host.assets_mesh_release(resident.app.assets,mesh)}
        unordered_remove(&resident.crowns,i)
        return
    }
}
ROLE_VARIANT :: Batch_Role(16) // + the variant
Wind_Key :: struct {source:render.Mesh_Handle,count:u32,amount:f32}
// The parts of a prefab some type shows, read once while the assets keep it.
Resident_Prefab :: struct {
    id:base.Asset_Id,
    parts:[dynamic]Prefab_Part,
    read:bool,
}

// How a type is drawn: its parts, each a batch per cell, and its far form.
Type_Draw :: struct {
    first,count:int, // of Build_Work.parts
    error:f32,       // the most of a transform its instances leave out (part_instance)
    far:bool,        // its mesh gives way to its impostor and its crown
    kind:int,        // its far form, of Foliage_Resident.kinds; -1 for none
    reach:f32,       // metres from a source within which a cell draws its mesh and rays meet it
}
Part_Draw :: struct {
    desc:render.Batch_Desc,
    placement:mm.Mat4,
    identity:bool,
    wind:int, // the variants it sways with, of Foliage_Resident.winds; -1 for none
}

// What building the cells reuses.
Build_Work :: struct {
    expand:Expand_Scratch,
    placed:[dynamic]Placed,
    orphans:[dynamic]int,
    instances:[dynamic]render.Batch_Instance,
    colors:[dynamic]u32,      // of each of instances, what it shows of its own (render.batch_color)
    ids:[dynamic][2]u32,      // id and index of each type of the source, by id
    order:[dynamic]u32,       // the placed instances by type, in their order
    firsts:[dynamic]u32,      // where those of the type of each index start in order, and their end
    cursor:[dynamic]u32,
    batches:[dynamic]Resident_Batch,
    cells:[dynamic]Resident_Cell,
    candidates:[dynamic]u32,                 // the cells of an owner whose residency is looked at, by index
    resident:[dynamic]scene.Resident_Order,  // the resident cells, by index in cells
    builds:[dynamic]scene.Resident_Order,    // the resident cells to build, by index, nearest first
    expansions:[dynamic]Cell_Expansion,      // of the cells a frame builds
    bands:[dynamic]scene.Sources_Near, // by type: the sources as far as its mesh reaches
    cell_band:scene.Sources_Near,      // the sources as far as the crowns of instances reach
    crowns:[dynamic]Crown_Triangles,   // by type: those of its far form, while a cell crown is made
    impostors:[dynamic]Impostor_Instance, // of the cell being built, in the world
}

// A cell expanded in a job (cells_expand), with room taken beforehand for
// the most it shows.
Cell_Expansion :: struct {
    index:u32, // of the cell in its source
    ground:Ground_Cell,
    removed:[]u64,
    placed:[dynamic]Placed,
    orphans:[dynamic]int,
    scratch:Expand_Scratch,
    ready:bool, // it has the room the cell needs
    built:bool,
}

build_work_destroy :: proc(w:^Build_Work) {
    expand_scratch_destroy(&w.expand)
    delete(w.placed);delete(w.orphans);delete(w.instances);delete(w.colors)
    delete(w.ids);delete(w.order);delete(w.firsts);delete(w.cursor)
    delete(w.batches);delete(w.cells);delete(w.candidates);delete(w.resident);delete(w.builds);delete(w.bands);delete(w.crowns);delete(w.impostors)
    for &e in w.expansions {delete(e.placed);delete(e.orphans);expand_scratch_destroy(&e.scratch)}
    delete(w.expansions)
    w^={}
}

@(private)
resident_cell_free :: proc(resident:^Foliage_Resident,cell:^Resident_Cell) {
    if resident.app!=nil {for b in cell.batches {render.batch_remove(resident.app.renderer,b.handle)}}
    crown_release(resident,cell.crown)
    cell.crown={}
    impostors_free(&resident.impostors,&cell.impostors)
    delete(cell.batches);delete(cell.near)
    cell.batches,cell.near=nil,nil
}

@(private)
resident_owner_free :: proc(resident:^Foliage_Resident,owner:^Resident_Owner) {
    for &cell in owner.cells {resident_cell_free(resident,&cell)}
    delete(owner.cells);delete(owner.resident);delete(owner.types);delete(owner.parts);delete(owner.kinds);delete(owner.winds)
    owner.cells,owner.resident,owner.types,owner.parts,owner.kinds,owner.winds=nil,nil,nil,nil,nil,nil
}

// What the renderer forgot with its batches and every mesh (meshes_clear):
// the cells, with the crowns they share, and the far forms and variants made
// of those meshes, all made again. A batch it forgot is not found again.
@(private)
resident_forget :: proc(resident:^Foliage_Resident) {
    for &owner in resident.owners {
        for &cell in owner.cells {resident_cell_free(resident,&cell)}
        delete(owner.cells)
        owner.cells,owner.built=nil,false
        clear(&owner.kinds);clear(&owner.winds);clear(&owner.resident)
    }
    for &kind in resident.kinds {kind_free(resident.app,&kind)}
    clear(&resident.kinds)
    clear(&resident.winds)
    impostor_draw_clear(&resident.impostors)
}

// Lets go of the far forms and the variants no Foliage shows any longer, or
// of all of them.
@(private)
resident_sweep :: proc(resident:^Foliage_Resident,all:=false) {
    app:=resident.app
    for i:=len(resident.kinds)-1;i>=0;i-=1 {
        used:=false
        if !all {for owner in resident.owners {for key in owner.kinds {used||=key==resident.kinds[i].key}}}
        if used {continue}
        kind_free(app,&resident.kinds[i])
        unordered_remove(&resident.kinds,i)
    }
    for i:=len(resident.winds)-1;i>=0;i-=1 {
        set:=&resident.winds[i]
        used:=false
        if !all {for owner in resident.owners {for key in owner.winds {used||=key==Wind_Key{set.source,set.count,set.amount}}}}
        if used {continue}
        if app!=nil {wind_set_free(app.renderer,set)}
        unordered_remove(&resident.winds,i)
    }
}

foliage_resident_free :: proc(resident:^Foliage_Resident) {
    for &owner in resident.owners {resident_owner_free(resident,&owner)}
    clear(&resident.owners)
    resident_sweep(resident,true)
    if resident.app!=nil {
        for name in ([]string{IMPOSTOR_BUFFER,IMPOSTOR_VISIBLE,IMPOSTOR_DRAW}) {render.buffer_release(resident.app.renderer,resident.world,name)}
    }
    for &prefab in resident.prefabs {delete(prefab.parts)}
    delete(resident.owners);delete(resident.prefabs);delete(resident.kinds);delete(resident.winds);delete(resident.crowns)
    impostor_draw_destroy(&resident.impostors)
    build_work_destroy(&resident.work)
    resident^={}
}

foliage_stamp :: proc(a:^host.Assets,id:base.Asset_Id) -> File_Stamp {
    file,found:=asset.registry_find(&a.registry,id)
    if !found {return {}}
    return {file.size,file.time,true}
}

// Reads a source as the registry of the assets holds it: what its memory
// holds until the file is written, or the file.
foliage_read :: proc(s:^Source,a:^host.Assets,id:base.Asset_Id,allocator:=context.allocator) -> bool {
    file:asset.Asset
    if host.assets_file(a,id,FOLIAGE_KIND,&file)!=.None {return false}
    defer asset.asset_close(&file)
    read,ok:=source_read(s,&file,&a.types,allocator)
    return ok && read==id
}

data_find :: proc(data:^Foliage_Data,id:base.Asset_Id) -> ^Data_Entry {
    for &entry in data.entries {if entry.id==id {return &entry}}
    return nil
}

@(private)
memory_problem :: proc(problems:^core.Problems,e:core.Entity,what:string) {
    core.report(problems,e,"foliage.memory","out of memory for %s; it is tried again: free memory, or give the foliage fewer types or instances",what)
}

@(private)
source_unread :: proc(problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id) {
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,e,"foliage.source_unread","foliage source %s cannot be read: it is missing, of another kind or version (%s, version %d), damaged, or memory ran out; give Foliage.source a .foliage asset",host.assets_name(a,id,&name),FOLIAGE_EXTENSION,VERSION)
}

@(private)
bytes_of :: proc "contextless" (values:[]$T) -> []u8 {return transmute([]u8)runtime.Raw_Slice{raw_data(values),len(values)*size_of(T)}}

@(private)
same_rows :: proc "contextless" (a,b:[]$T) -> bool {return len(a)==len(b) && mem.compare(bytes_of(a),bytes_of(b))==0}

// A type as its instances are placed and collide: without what only drawing
// reads, which changes no cell.
@(private)
type_placed :: proc "contextless" (t:Foliage_Type) -> Foliage_Type {
    p:=t
    p.name,p.mesh,p.materials,p.prefab={},{},{},{}
    p.fade_distance,p.cull_distance,p.impostor_distance,p.wind,p.wind_variants=0,0,0,0,0
    p.casts_shadow,p.ray_visible=false,false
    return p
}

// Whether two lists of types place and collide the same instances.
@(private)
types_placed_same :: proc "contextless" (a,b:[]Foliage_Type) -> bool {
    if len(a)!=len(b) {return false}
    for t,i in a {
        x,y:=[1]Foliage_Type{type_placed(t)},[1]Foliage_Type{type_placed(b[i])}
        if !same_rows(x[:],y[:]) {return false}
    }
    return true
}

// The versions of the cells of a source read again: a cell equal to the one
// of its coordinate before keeps its version, and the others take the next
// one. Another seed, or types that place or collide otherwise, change every
// cell; a change of how a type is drawn only raises look, which the batches
// compare.
cells_version :: proc(next,previous:^Source,versions:^u32,look:^u32=nil) {
    if look!=nil && !same_rows(next.types[:],previous.types[:]) {look^+=1}
    types_same:=next.info.seed==previous.info.seed && types_placed_same(next.types[:],previous.types[:])
    j:=0
    for &cell in next.cells {
        for j<len(previous.cells) && coord_before(previous.cells[j].coord,cell.coord) {j+=1}
        if types_same && j<len(previous.cells) && previous.cells[j].coord==cell.coord {
            old:=&previous.cells[j]
            if old.generate==cell.generate && same_rows(old.manual[:],cell.manual[:]) && same_rows(old.overrides[:],cell.overrides[:]) && slice.equal(old.density[:],cell.density[:]) {
                cell.version=old.version
                continue
            }
        }
        versions^+=1
        cell.version=versions^
    }
}

// Reads the sources the Foliage of the world name, again when their file
// changes on disk or in the memory of the registry, and drops those no
// Foliage names. Foliage.revision is the editor's: undo puts back what a
// step held, 0 included, and the tool restores the source of that revision.
// The cells of a stroke of the editor (Foliage_Stroke) are shown over their
// source until it is cleared.
@(step="fixed frame",loops="game editor",stage="simulate")
foliage_load :: proc(data:^Foliage_Data,foliages:^core.Table(Foliage,.Read),stroke:core.Ref(Foliage_Stroke),assets:^host.Assets,allocator:runtime.Allocator,problems:^core.Problems) {
    a:=assets
    if a==nil {return}
    context.allocator=allocator
    fresh:=data.registry!=a.registry.revision
    data.registry=a.registry.revision
    for &entry in data.entries {
        held:=stroke.ptr!=nil && stroke.ptr.source==entry.id
        // What a stroke showed and no longer holds: the file again.
        dropped:=entry.stroke!=0 && !held
        if !fresh && !dropped {continue}
        stamp:=foliage_stamp(a,entry.id)
        if stamp==entry.stamp && !dropped {continue}
        next:Source
        if foliage_read(&next,a,entry.id) {
            cells_version(&next,&entry.source,&entry.versions,&entry.look)
            source_destroy(&entry.source)
            entry.source=next
            entry.loads+=1
            entry.layout+=1
            data.stats.loads+=1
        }
        entry.stamp=stamp
        entry.stroke=0
    }
    if stroke.ptr!=nil && stroke.ptr.source!={} {
        if entry:=data_find(data,stroke.ptr.source);entry!=nil && entry.stroke!=stroke.ptr.revision {
            if stroke_apply(entry,stroke.ptr) {entry.loads+=1}
            entry.stroke=stroke.ptr.revision
        }
    }
    for row in 0..<core.count(foliages) {
        f:=core.at(foliages,row)
        if f.source=={} || data_find(data,f.source)!=nil {continue}
        data.made+=1
        entry:=Data_Entry{id=f.source,stamp=foliage_stamp(a,f.source),loads=1,epoch=data.made}
        if !foliage_read(&entry.source,a,f.source) {
            source_unread(problems,core.entity_at(foliages,row),a,f.source)
            // Kept empty, so that it is not read in each frame: a change of its file reads it again.
            source_destroy(&entry.source)
        }
        for &cell in entry.source.cells {entry.versions+=1;cell.version=entry.versions}
        append(&data.entries,entry)
        data.stats.loads+=1
    }
    for i:=len(data.entries)-1;i>=0;i-=1 {
        used:=false
        for row in 0..<core.count(foliages) {if core.at(foliages,row).source==data.entries[i].id {used=true;break}}
        if used {continue}
        source_destroy(&data.entries[i].source)
        unordered_remove(&data.entries,i)
    }
}

// The instances of a cell in the space of its entity, on its ground, in
// work.placed, but those removed (cell_expand); the orphan overrides it has
// in work.orphans; thin as cell_expand takes it.
cell_build :: proc(s:^Source,cell:^Cell,ground:Ground_Cell,work:^Build_Work,removed:[]u64={},thin:=f32(1)) -> bool {
    clear(&work.placed);clear(&work.orphans)
    return cell_expand(s,cell,ground,&work.placed,&work.orphans,&work.expand,removed,thin)
}

// The most instances a cell shows (cell_expand with thin), which is what a
// budget counts it by, and the most points one of its types makes there.
cell_bound :: proc "contextless" (s:^Source,cell:^Cell,thin:f32) -> (instances,points:int) {
    instances=len(cell.manual)
    if !cell.generate {return}
    share:=generated_share(s)
    for t in s.types {
        n:=scatter_max(t,type_share(t,share,thin))
        instances+=n
        points=max(points,n)
    }
    return
}

// What the Detail of the graphics settings draws of the foliage: the share of
// the generated points of the types without collision (the collision is the
// same at any detail), and of the distances of every type.
FOLIAGE_DETAIL :: [render.Detail][2]f32{.Low={0.4,0.6},.Medium={0.8,0.8},.High={1,1},.Ultra={1,1}}

// The index in its source of the type of an id, through work.ids; -1 for none.
@(private)
type_index :: proc "contextless" (work:^Build_Work,id:u32) -> int {
    low,high:=0,len(work.ids)
    for low<high {mid:=(low+high)/2;if work.ids[mid][0]<id {low=mid+1} else {high=mid}}
    return low<len(work.ids) && work.ids[low][0]==id?int(work.ids[low][1]):-1
}

// Groups the instances of work.placed by type, in one pass: work.order holds
// their indices, those of the type of index i of the source from
// work.firsts[i] to work.firsts[i+1], each type in the order they were
// placed. Those of a type the source does not have are left out.
placed_group :: proc(s:^Source,work:^Build_Work) -> bool {
    clear(&work.ids)
    for t,i in s.types {append(&work.ids,[2]u32{t.id,u32(i)})}
    slice.sort_by(work.ids[:],proc(a,b:[2]u32) -> bool {return a[0]<b[0]})
    n:=len(s.types)
    if resize(&work.firsts,n+1)!=nil {return false}
    for &first in work.firsts {first=0}
    for p in work.placed {if i:=type_index(work,p.type);i>=0 {work.firsts[i+1]+=1}}
    for i in 1..=n {work.firsts[i]+=work.firsts[i-1]}
    if resize(&work.order,int(work.firsts[n]))!=nil || resize(&work.cursor,n)!=nil {return false}
    copy(work.cursor[:],work.firsts[:n])
    for p,k in work.placed {
        i:=type_index(work,p.type)
        if i<0 {continue}
        work.order[work.cursor[i]]=u32(k)
        work.cursor[i]+=1
    }
    return true
}

// What an instance shows of its own, as a batch takes it (render.batch_color).
placed_color :: proc "contextless" (p:Placed) -> u32 {return p.color if p.colored else render.BATCH_COLOR_PLAIN}

// An instance as a batch draws it, carried by the transform of its entity.
batch_instance_of :: proc "contextless" (p:Placed,owner:mm.Transform) -> render.Batch_Instance {
    return render.batch_instance(mm.transform_point(owner,p.position),owner.rotation*p.rotation,[3]f32{p.scale[0],p.scale[1],p.scale[0]}*owner.scale)
}

@(private)
orphans_report :: proc(problems:^core.Problems,e:core.Entity,a:^host.Assets,id:base.Asset_Id,cell:^Cell,orphans:[]int) {
    if len(orphans)==0 {return}
    o:=cell.overrides[orphans[0]]
    name:[base.ASSET_ID_TEXT]u8
    core.report(problems,e,"foliage.orphans","%d overrides of foliage source %s name generated instances its generator no longer makes (the first: cell %v, type %d, point %d), and are kept unused; give the cell back its generation or the type its density, or remove them",len(orphans),host.assets_name(a,id,&name),cell.coord,o.type,o.point)
}

// Publishes the batches of the cells of each Foliage of the world: those of
// a cell again when its content, its ground or the band of one of its types
// changes, all of a Foliage when its entity moves or its source is read
// anew, and all when the renderer forgets its batches or a mesh or prefab
// they show changes. The rows their materials derive stay while the batches
// live (render_sync keeps them), so a change of what the entities of the
// world show changes nothing here, and neither does a stable frame. Which
// cells of a Foliage are resident, and in which band each type of them is,
// is chosen again when the streaming sources move; the Detail of the
// graphics settings scales the distances and the density of the types
// without collision (FOLIAGE_DETAIL).
@(step="late",loops="game editor",stage="end")
foliage_render :: proc(resident:^Foliage_Resident,data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),marks:core.Ref(Foliage_Marks),foliages:^core.Table(Foliage,.Read),worlds:^core.Table(core.World_Transform,.Read),kept:^core.Table(scene.Far_Kept,.Read),sources:core.Ref(scene.Streaming_Sources),graphics:render.Graphics_Settings,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    if resident==nil || data.ptr==nil || app.renderer==nil || app.assets==nil {return}
    a:=app.assets
    context.allocator=app.allocator
    resident.app,resident.world=app,id
    changed:=false
    details:=FOLIAGE_DETAIL
    if detail:=details[clamp(graphics.detail,.Low,.Ultra)];detail!=resident.detail {
        resident.detail=detail
        for &owner in resident.owners {owner.built=false}
    }
    if resident.epoch!=render.batches_epoch(app.renderer) {
        resident_forget(resident)
        resident.epoch=render.batches_epoch(app.renderer)
    }
    if resident.structure!=a.structure {
        changes,complete:=host.assets_structure_changes(a,resident.structure)
        all:=!complete
        for change in changes {
            if change.id=={} {all=true;break}
            for prefab in resident.prefabs {
                all||=prefab.id==change.id
                for part in prefab.parts {all||=part.renderer.mesh==change.id}
            }
            for entry in data.entries {for t in entry.source.types {all||=t.mesh==change.id}}
        }
        resident.structure=a.structure
        if all {
            // A mesh, material or prefab they show changed: every cell is
            // built again, and what is made of them, as any cooking.
            for &prefab in resident.prefabs {delete(prefab.parts)}
            clear(&resident.prefabs)
            for &owner in resident.owners {
                for &cell in owner.cells {resident_cell_free(resident,&cell);cell.built=false}
                clear(&owner.kinds);clear(&owner.winds)
                owner.built=false
            }
            resident_sweep(resident)
        }
    }
    // Owners whose entity left, or shows another source, take their batches with them.
    for i:=len(resident.owners)-1;i>=0;i-=1 {
        owner:=&resident.owners[i]
        f,shown:=core.get(foliages,owner.entity)
        if shown && f.source==owner.source {continue}
        resident_owner_free(resident,owner)
        unordered_remove(&resident.owners,i)
        changed=true
    }
    // A load is spread over frames: so many instances and far forms a frame.
    resident.instances_left,resident.kinds_left=INSTANCES_A_FRAME,KINDS_A_FRAME
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        entry:=data_find(data.ptr,f.source)
        world,placed:=core.get(worlds,e)
        if entry==nil || !placed {continue}
        owner:^Resident_Owner
        for &held in resident.owners {if held.entity==e {owner=&held;break}}
        if owner==nil {
            // The first slot no other owner holds.
            slot:=u32(0)
            for {
                taken:=false
                for &held in resident.owners {taken||=held.slot==slot}
                if !taken {break}
                slot+=1
            }
            if slot>0xFFFF {
                core.report(problems,e,"foliage.owners","this Foliage is not drawn: a world draws at most 65536 Foliage at once; join foliage of the same place into one source")
                continue
            }
            if _,err:=append(&resident.owners,Resident_Owner{entity=e,source=f.source,slot=slot});err!=nil {
                memory_problem(problems,e,"this Foliage, which is not drawn")
                continue
            }
            owner=&resident.owners[len(resident.owners)-1]
        }
        ground:=ground_owner(grounds.ptr,e)
        revision:=ground!=nil?ground.revision:0
        streamed:=sources.ptr!=nil?sources.ptr.revision:0
        far_only:=(kept!=nil && core.has(kept,e))
        gone:=removed_owner(removals.ptr,e)
        removed:=gone!=nil?gone.hash:0
        looks:=marked_owner(marks.ptr,e)
        marked:=looks!=nil?looks.hash:0
        if owner.far_only!=far_only {owner.built=false}
        if owner.built && !owner.pending && owner.epoch==entry.epoch && owner.loads==entry.loads && owner.transform==world.transform && owner.ground==revision && owner.sources==streamed && owner.removed==removed && owner.marked==marked {continue}
        if resident.instances_left<=0 && owner.built {continue}
        owner.far_only=far_only
        owner_publish(resident,owner,entry,world.transform,ground,gone,looks,sources.ptr,id,app,problems)
        changed=true
    }
    if changed {
        resident_sweep(resident)
        impostor_rows_build(resident,data.ptr)
    }
}

// The parts of a prefab, read once while the assets keep it; nil without memory.
@(private)
resident_prefab :: proc(resident:^Foliage_Resident,a:^host.Assets,id:base.Asset_Id) -> ^Resident_Prefab {
    for &prefab in resident.prefabs {if prefab.id==id {return &prefab}}
    if _,err:=append(&resident.prefabs,Resident_Prefab{id=id});err!=nil {return nil}
    prefab:=&resident.prefabs[len(resident.prefabs)-1]
    if file:=host.assets_scene(a,id);file!=nil {prefab.read,_=prefab_parts(file,&a.types,&prefab.parts)}
    return prefab
}

// How each type of a source is drawn: the batch description of each of its
// parts, the variants each part sways with, and its far form, made the first
// time a type shows its asset.
@(private)
types_draw :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,entry:^Data_Entry,assets:^host.Assets,renderer:^render.Renderer,job_system:^jobs.Job_System,allocator:runtime.Allocator,problems:^core.Problems) {
    clear(&owner.types);clear(&owner.parts)
    clear(&owner.kinds);clear(&owner.winds)
    name,other:[base.ASSET_ID_TEXT]u8
    distance:=resident.detail[1]
    for &t in entry.source.types {
        draw:=Type_Draw{first=len(owner.parts),kind=-1}
        pieces:[]Prefab_Part
        single:=[1]Prefab_Part{{renderer={mesh=t.mesh,materials=t.materials},placement=1}}
        switch {
        case t.mesh!={}: pieces=single[:]
        case t.prefab!={}:
            prefab:=resident_prefab(resident,assets,t.prefab)
            if prefab==nil {
                memory_problem(problems,owner.entity,"the prefab of a type of this Foliage, which is not drawn")
                owner.pending=true
                break
            }
            if !prefab.read || len(prefab.parts)==0 {
                core.report(problems,owner.entity,"foliage.prefab","foliage type '%s' of source %s shows prefab %s, which is not loaded or has no Mesh_Renderer under a single root; give the type a prefab with meshes, or a mesh",base.text_get(t.name[:]),host.assets_name(assets,entry.id,&name),host.assets_name(assets,t.prefab,&other))
            }
            pieces=prefab.parts[:]
        }
        variants:=wind_variants(t)
        amount:=sway_amount(t)
        fade,cull:=mesh_distances(t,false)
        fade,cull=fade*distance,cull*distance
        for piece in pieces {
            desc,ok:=render.batch_desc(assets,piece.renderer)
            if !ok {
                core.report(problems,owner.entity,"foliage.mesh","foliage type '%s' of source %s shows mesh %s, which is not loaded; give the type a .mesh of the assets",base.text_get(t.name[:]),host.assets_name(assets,entry.id,&name),host.assets_name(assets,piece.renderer.mesh,&other))
                continue
            }
            desc.flags={}
            if t.casts_shadow {desc.flags+={.Casts_Shadow}}
            if t.ray_visible {desc.flags+={.Ray_Visible}}
            desc.fade_distance,desc.cull_distance=fade,cull
            desc.object_id=u64(owner.entity)
            part:=Part_Draw{desc=desc,placement=piece.placement,identity=piece.placement==1,wind=-1}
            if variants>0 {
                part.wind=wind_set(resident,renderer,desc.mesh,variants,amount)
                append(&owner.winds,Wind_Key{desc.mesh,variants,amount})
            }
            // What sways in the hook and not in variants.
            if part.wind<0 && t.wind>0 {
                part.desc.vertex={amount,0,0,0}
                // The views cull it by boxes that hold how far the wind and the benders move it.
                if low,high,known:=render.mesh_bounds(renderer,desc.mesh);known {
                    corner:=linalg.max(linalg.abs(low),linalg.abs(high))
                    part.desc.reach=hook_reach(amount,linalg.length(corner)*t.scale[1]*max(t.height[1],1))
                }
            }
            append(&owner.parts,part)
        }
        draw.count=len(owner.parts)-draw.first
        key:Kind_Key
        if type_far(t) && draw.count>0 {
            parts:=owner.parts[draw.first:][:draw.count]
            key={t.mesh if t.mesh!={} else t.prefab,kind_frame(renderer,t,parts)}
            draw.kind=kind_ensure(resident,assets,renderer,job_system,allocator,key,parts,problems,owner.entity)
            if draw.kind>=0 && kind_ready(&resident.kinds[draw.kind]) {
                draw.far=true
                fade,cull=mesh_distances(t,true)
                fade,cull=fade*distance,cull*distance
                draw.reach=cull
                for &part in owner.parts[draw.first:][:draw.count] {part.desc.fade_distance,part.desc.cull_distance=fade,cull}
            }
        }
        append(&owner.kinds,key)
        append(&owner.types,draw)
    }
}

/// How far the cells of a source are drawn: the farthest cull distance of its
// types, times distance; 0 when one is never culled, and every cell stays.
@(private)
source_reach :: proc(s:^Source,distance:=f32(1)) -> f32 {
    reach:=f32(0)
    for t in s.types {
        if t.cull_distance<=0 {return 0}
        reach=max(reach,t.cull_distance)
    }
    return reach*distance
}

// The box of a cell in the space of its Foliage, as residency measures it.
@(private)
cell_box :: proc "contextless" (coord:[2]i32) -> (low,high:[3]f32) {
    corner:=cell_corner(coord)
    return {corner.x,-POSITION_MAX,corner.z},{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE}
}

// The first of items (in the order of their coordinates, z then x) at or
// after a coordinate.
@(private)
coord_lower :: proc "contextless" (items:[]$T,coord:[2]i32) -> int {
    low,high:=0,len(items)
    for low<high {
        mid:=(low+high)/2
        if coord_before(items[mid].coord,coord) {low=mid+1} else {high=mid}
    }
    return low
}

// The indices of the items, in the order of their coordinates (z then x),
// whose cell a source of near comes within RESIDENT_KEEP of its reach of:
// the only ones it may keep resident. Each once, in their order. Each row of
// cells around a source is found by a search, so what it costs follows what
// is near, not every item.
coords_near :: proc(items:[]$T,near:^scene.Sources_Near,out:^[dynamic]u32) {
    clear(out)
    if len(items)==0 {return}
    rows:=[2]f32{f32(items[0].coord.y),f32(items[len(items)-1].coord.y)}
    for point,i in near.points[:near.count] {
        d:=near.reaches[i]*scene.RESIDENT_KEEP
        if !(d>=0) || point!=point {continue}
        first:=clamp(math.floor((point.z-d)/CELL_SIZE),rows[0],rows[1]+1)
        last:=clamp(math.floor((point.z+d)/CELL_SIZE),rows[0]-1,rows[1])
        if first>last {continue}
        // More rows than items: every one.
        if int(last-first)>=len(items) {
            clear(out)
            for k in 0..<len(items) {append(out,u32(k))}
            return
        }
        low:=i32(clamp(math.floor((point.x-d)/CELL_SIZE),-f32(COORD_MAX)-1,f32(COORD_MAX)+1))
        high:=i32(clamp(math.floor((point.x+d)/CELL_SIZE),-f32(COORD_MAX)-1,f32(COORD_MAX)+1))
        for z in i32(first)..=i32(last) {
            for at:=coord_lower(items,{low,z});at<len(items) && items[at].coord.y==z && items[at].coord.x<=high;at+=1 {append(out,u32(at))}
        }
    }
    if near.count>1 {sorted_unique(out)}
}

@(private)
sorted_unique :: proc(values:^[dynamic]u32) {
    slice.sort(values[:])
    kept:=0
    for v in values^ {
        if kept>0 && values[kept-1]==v {continue}
        values[kept]=v
        kept+=1
    }
    base.truncate(values,kept)
}

// The batches of one Foliage: those of its resident cells that changed, or
// whose types changed band, or of all of them, the nearest first within the
// budget of the frame; a cell that stops being resident lets go of its
// batches and its impostors. When only the sources, the ground or what was
// taken out changed, it looks at the cells that were resident and those a
// source comes near (coords_near), not at every cell.
@(private)
owner_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,entry:^Data_Entry,transform:mm.Transform,ground:^Ground_Owner,gone:^Removed_Owner,looks:^Marked_Owner,sources:^scene.Streaming_Sources,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    all:=!owner.built || owner.epoch!=entry.epoch || owner.transform!=transform || owner.look!=entry.look
    // The cells of its source changed: those built are matched with them again.
    full:=all || owner.layout!=entry.layout
    retype:=full || owner.pending
    owner.epoch,owner.loads,owner.look,owner.layout,owner.transform,owner.source=entry.epoch,entry.loads,entry.look,entry.layout,transform,entry.id
    owner.ground=ground!=nil?ground.revision:0
    owner.removed=gone!=nil?gone.hash:0
    owner.marked=looks!=nil?looks.hash:0
    owner.sources=sources!=nil?sources.revision:0
    s:=&entry.source
    work:=&resident.work
    owner.pending=false
    if retype {types_draw(resident,owner,entry,app.assets,app.renderer,&app.jobs,app.allocator,problems)}
    // Its cells wait for the far forms of its types.
    for draw,i in owner.types {
        if type_far(s.types[i]) && draw.count>0 && draw.kind<0 {
            owner.pending=true
            if full {owner.built=false}
            return
        }
    }
    reach:=source_reach(s,resident.detail[1])
    placed:=mm.transform_matrix(transform)
    near:scene.Sources_Near
    if reach>0 {near=scene.sources_near(sources,placed,reach)}
    if resize(&work.bands,len(owner.types))!=nil {
        memory_problem(problems,owner.entity,"the cells of this Foliage")
        owner.pending=true
        return
    }
    for draw,i in owner.types {work.bands[i]=draw.far?scene.sources_near(sources,placed,draw.reach):{}}
    crown_reach:=f32(0)
    for draw in owner.types {if draw.far {crown_reach=max(crown_reach,draw.reach*CELL_CROWN_REACH)}}
    work.cell_band={}
    if crown_reach>0 {work.cell_band=scene.sources_near(sources,placed,crown_reach)}
    // A type that is never culled keeps every cell, the nearest first.
    if reach<=0 {near=scene.sources_near(sources,placed,CELL_SIZE)}
    if full {
        // The cells of the source and those built, both in the order of their coordinates.
        clear(&work.cells)
        j:=0
        for cell in s.cells {
            for j<len(owner.cells) && coord_before(owner.cells[j].coord,cell.coord) {resident_cell_free(resident,&owner.cells[j]);j+=1}
            held:=Resident_Cell{coord=cell.coord}
            if j<len(owner.cells) && owner.cells[j].coord==cell.coord {held=owner.cells[j];j+=1}
            append(&work.cells,held)
        }
        for ;j<len(owner.cells);j+=1 {resident_cell_free(resident,&owner.cells[j])}
        owner.cells,work.cells=work.cells,owner.cells
        clear(&work.cells)
    }
    // The cells whose residency may change: every one, or those resident and those a source comes near.
    candidates:=&work.candidates
    if full || reach<=0 {
        clear(candidates)
        for k in 0..<len(owner.cells) {append(candidates,u32(k))}
    } else {
        coords_near(owner.cells[:],&near,candidates)
        append(candidates,..owner.resident[:])
        sorted_unique(candidates)
    }
    clear(&work.resident)
    for k in candidates {
        held:=&owner.cells[k]
        low,high:=cell_box(held.coord)
        at:=scene.box_near(&near,low,high)
        held.resident=reach<=0 || scene.resident(at,held.resident)
        if held.resident {append(&work.resident,scene.Resident_Order{near=at,index=k})}
    }
    if left_out:=resident_cap(owner.cells[:],work.resident[:],RESIDENT_CELLS,reach<=0?max(f32):1);left_out>0 {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,owner.entity,"foliage.resident_cells","%d cells of foliage source %s within the reach of its types are not drawn: a Foliage keeps the nearest RESIDENT_CELLS (%d); give its types a cull distance, or a shorter one, or split the foliage into sections",left_out,host.assets_name(app.assets,owner.source,&name),RESIDENT_CELLS)
    }
    clear(&owner.resident)
    clear(&work.builds)
    for k in candidates {
        held:=&owner.cells[k]
        cell:=&s.cells[k]
        if !held.resident {
            if held.built {
                resident_cell_free(resident,held)
                held.built=false
            }
            continue
        }
        append(&owner.resident,k)
        low,high:=cell_box(cell.coord)
        // Each type with a far form draws its mesh within its reach of a source, and its crown past it.
        banded:=len(held.near)!=len(owner.types)
        if banded && resize(&held.near,len(owner.types))!=nil {
            memory_problem(problems,owner.entity,"a cell of this Foliage, which keeps what it showed")
            held.stale,owner.pending=true,true
            continue
        }
        for draw,i in owner.types {
            was:=held.near[i]
            held.near[i]=!owner.far_only && (!draw.far || scene.resident(scene.box_near(&work.bands[i],low,high),was))
            banded||=held.near[i]!=was
        }
        was_far:=held.far
        held.far=crown_reach>0 && !scene.resident(scene.box_near(&work.cell_band,low,high),!was_far)
        banded||=held.far!=was_far
        _,revision:=ground_cell(ground,cell.coord)
        _,removed_hash:=removed_cell(gone,cell.coord)
        _,marked_hash:=marked_cell(looks,cell.coord)
        if all || banded || held.stale || !held.built || held.version!=cell.version || held.ground!=revision || held.removed!=removed_hash || held.marked!=marked_hash {
            append(&work.builds,scene.Resident_Order{near=scene.box_near(&near,low,high),index=k})
        }
    }
    taken:=builds_take(work.builds[:],s,resident.detail[0],&resident.instances_left)
    allocator:=app.jobs.allocator if app.jobs.allocator.procedure!=nil else app.allocator
    expanded:=cells_expand(work,s,ground,gone,work.builds[:taken],resident.detail[0],&app.jobs,allocator)
    for order in work.builds[len(expanded):] {
        owner.cells[order.index].stale=true
        owner.pending=true
    }
    for &e in expanded {
        held:=&owner.cells[e.index]
        cell:=&s.cells[e.index]
        _,revision:=ground_cell(ground,cell.coord)
        _,removed_hash:=removed_cell(gone,cell.coord)
        marks,marked_hash:=marked_cell(looks,cell.coord)
        held.version,held.ground,held.removed,held.marked,held.built,held.stale=cell.version,revision,removed_hash,marked_hash,true,false
        work.placed,e.placed=e.placed,work.placed
        work.orphans,e.orphans=e.orphans,work.orphans
        if e.built {marks_apply(work.placed[:],marks)}
        cell_publish(resident,owner,held,s,cell,e.built,transform,id,app,problems)
        work.placed,e.placed=e.placed,work.placed
        work.orphans,e.orphans=e.orphans,work.orphans
    }
    owner.built=true
    resident.stats.builds+=1
    name:[base.ASSET_ID_TEXT]u8
    if share:=generated_share(s);share<1 {
        core.report(problems,owner.entity,"foliage.cell_instances","the densities of the types of foliage source %s give a cell more than CELL_GENERATED_MAX (%d) generated instances, so each type shows %d%% of its own; lower the densities of its types",host.assets_name(app.assets,owner.source,&name),CELL_GENERATED_MAX,int(share*100))
    }
    for draw,i in owner.types {
        if draw.error<=PREFAB_ERROR {continue}
        t:=&s.types[i]
        core.report(problems,owner.entity,"foliage.prefab_transform","the parts of prefab %s of foliage type '%s' are drawn with up to %d%% of their transform left out: an instance of a batch holds a scale along each of its axes, without shear or mirror; give the parts of the prefab, and the Foliage entity, no scale under a rotation of their parents and no negative scale",host.assets_name(app.assets,t.prefab,&name),base.text_get(t.name[:]),int(draw.error*100+0.5))
    }
}

// Orders the cells to build nearest first and takes those the instances left
// give room for, each by its cell_bound and at least CELL_COST_MIN: how many.
// One goes while some are left, so a cell past the whole budget is built too.
builds_take :: proc(builds:[]scene.Resident_Order,s:^Source,thin:f32,left:^int) -> (taken:int) {
    slice.sort_by(builds,proc(a,b:scene.Resident_Order) -> bool {return a.near<b.near || a.near==b.near && a.index<b.index})
    for order in builds {
        if left^<=0 {break}
        instances,_:=cell_bound(s,&s.cells[order.index],thin)
        left^-=max(instances,CELL_COST_MIN)
        taken+=1
    }
    return
}

// Expands the cells builds names (by index in the cells of s) into the
// expansions of work, in jobs. The room of what it shows (cell_bound) is
// taken here and a cell without it is not built; what the spacing of its
// types needs more comes from allocator, which the threads share. Those it expands, in
// the order of builds; fewer when the expansions do not fit in memory.
cells_expand :: proc(work:^Build_Work,s:^Source,ground:^Ground_Owner,gone:^Removed_Owner,builds:[]scene.Resident_Order,thin:f32,job_system:^jobs.Job_System,allocator:runtime.Allocator) -> []Cell_Expansion {
    count:=0
    for order in builds {
        if count==len(work.expansions) {
            if _,error:=append(&work.expansions,Cell_Expansion{});error!=nil {break}
        }
        e:=&work.expansions[count]
        cell:=&s.cells[order.index]
        instances,points:=cell_bound(s,cell,thin)
        e.index=order.index
        e.ground,_=ground_cell(ground,cell.coord)
        e.removed,_=removed_cell(gone,cell.coord)
        e.ready=expansion_room(e,instances,points,len(cell.overrides),allocator)
        count+=1
    }
    Expanding :: struct {s:^Source,cells:[]Cell_Expansion,thin:f32,allocator:runtime.Allocator}
    expand :: proc(x:^Expanding,first,last:int,worker:int) {
        // What an expansion grows comes from the allocator the threads share.
        context.allocator=x.allocator
        for &e in x.cells[first:last] {
            clear(&e.placed);clear(&e.orphans)
            e.built=e.ready && cell_expand(x.s,&x.s.cells[e.index],e.ground,&e.placed,&e.orphans,&e.scratch,e.removed,x.thin)
        }
    }
    expanding:=Expanding{s,work.expansions[:count],thin,allocator}
    if job_system!=nil && jobs.worker_count(job_system)>1 && count>1 {
        jobs.parallel_for(job_system,jobs.OWNER,count,1,expand,&expanding)
    } else {expand(&expanding,0,count,jobs.OWNER)}
    return work.expansions[:count]
}

@(private)
expansion_room :: proc(e:^Cell_Expansion,instances,points,overrides:int,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    return reserve(&e.placed,instances)==nil && reserve(&e.orphans,overrides)==nil && reserve(&e.scratch.points,points)==nil && reserve(&e.scratch.matched,overrides)==nil
}

// The cells of a Foliage resident at once, at most: past them, those
// farthest from the sources (in reaches of its types) are not drawn.
RESIDENT_CELLS :: 16384

// Keeps the nearest keep of the resident cells order names (their index in
// cells, how near they are) and makes the others not resident: how many of
// those were as near as wanted (within reach, at 1), which are a problem.
@(private)
resident_cap :: proc(cells:[]Resident_Cell,order:[]scene.Resident_Order,keep:int,wanted:f32) -> (left_out:int) {
    if len(order)<=keep {return}
    for past in scene.residents_past(order,keep) {
        cells[past.index].resident=false
        if past.near<=wanted {left_out+=1}
    }
    return
}

// What a frame builds of the foliage at most: instances of the cells
// (cell_bound, at least CELL_COST_MIN a cell), the nearest first, and far
// forms of the assets types show (each draws its impostor). The rest waits
// for the frames that follow; the cells of a Foliage wait for the far forms
// of its types.
INSTANCES_A_FRAME :: 1 << 16
CELL_COST_MIN :: 1024 // instances a cell costs at least: the batches it publishes
KINDS_A_FRAME :: 1

// How much of the transform of a part may be left out before it is a problem.
PREFAB_ERROR :: f32(0.01)

// The instance of a type order[k] gives, of the batch of a role: the index
// of instance j of that batch among the instances of its type, in their
// order. A variant holds those of its turn; the others hold them all.
role_instance :: proc(role:Batch_Role,variants:u32,owner:mm.Quat,placed:[]Placed,order:[]u32,j:int) -> int {
    if role<ROLE_VARIANT {return j}
    v:=u32(role-ROLE_VARIANT)
    seen:=0
    for at,k in order {
        if wind_variant(owner*placed[at].rotation,variants)!=v {continue}
        if seen==j {return k}
        seen+=1
    }
    return -1
}

// The batches of one cell: per type and part with instances, its mesh, or
// its variants and its mesh at rest, while it is near, and its crown past
// that; and the impostors of its types with a far form. It reuses the
// handles the cell had for the same roles. Called with the cell expanded in
// work.placed and work.orphans (built: it fit in memory).
@(private)
cell_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,s:^Source,cell:^Cell,built:bool,transform:mm.Transform,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    work:=&resident.work
    if built {orphans_report(problems,owner.entity,app.assets,owner.source,cell,work.orphans[:])}
    if !built || !placed_group(s,work) {
        memory_problem(problems,owner.entity,"a cell of this Foliage, which keeps what it showed")
        held.stale,owner.pending=true,true
        return
    }
    owner_matrix:=mm.transform_matrix(transform)
    clear(&work.batches)
    clear(&work.impostors)
    publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,coord:[2]i32,t:^Foliage_Type,part:u32,role:Batch_Role,desc:render.Batch_Desc,id:core.World_Id,app:^host.App,problems:^core.Problems) {
        work:=&resident.work
        if len(work.instances)==0 {return}
        handle:render.Batch_Handle
        for &b in held.batches {if b.type==t.id && b.part==part && b.role==role && b.handle!=0 {handle,b.handle=b.handle,0;break}}
        // Colors only for a batch where some instance has a look of its own.
        colors:[]u32
        for color in work.colors {if color!=render.BATCH_COLOR_PLAIN {colors=work.colors[:];break}}
        next,error:=render.batch_set(app.renderer,id,handle,desc,work.instances[:],colors)
        if error!="" {
            if handle!=0 {render.batch_remove(app.renderer,handle)}
            core.report(problems,owner.entity,"foliage.batch","the foliage of cell %v, type '%s', is not drawn: %s",coord,base.text_get(t.name[:]),error)
            return
        }
        append(&work.batches,Resident_Batch{type=t.id,part=part,role=role,handle=next})
        resident.stats.batches+=1
        resident.stats.instances+=u64(len(work.instances))
    }
    for &draw,i in owner.types {
        t:=&s.types[i]
        order:=work.order[work.firsts[i]:work.firsts[i+1]]
        if len(order)==0 {continue}
        // Of a section that is not loaded, only what has a far form, and only that form.
        if owner.far_only && !draw.far {continue}
        near:=i>=len(held.near) || held.near[i]
        for &part,k in owner.parts[draw.first:][:draw.count] {
            if !near {break}
            clear(&work.instances)
            clear(&work.colors)
            for at in order {
                p:=work.placed[at]
                append(&work.colors,placed_color(p))
                if part.identity {append(&work.instances,batch_instance_of(p,transform));continue}
                instance,error:=part_instance(p,owner_matrix,part.placement)
                draw.error=max(draw.error,error)
                append(&work.instances,instance)
            }
            if part.wind<0 {
                publish(resident,owner,held,cell.coord,t,u32(k),ROLE_MESH,part.desc,id,app,problems)
                continue
            }
            // The variants draw and cast shadows; the rays that see surfaces meet the mesh at rest.
            set:=&resident.winds[part.wind]
            if t.ray_visible {
                rest:=part.desc
                rest.flags={.Ray_Visible,.Rays_Only}
                publish(resident,owner,held,cell.coord,t,u32(k),ROLE_REST,rest,id,app,problems)
            }
            all:=make([]render.Batch_Instance,len(work.instances),context.temp_allocator)
            all_colors:=make([]u32,len(work.colors),context.temp_allocator)
            copy(all,work.instances[:])
            copy(all_colors,work.colors[:])
            for v in 0..<set.count {
                clear(&work.instances)
                clear(&work.colors)
                for instance,n in all {
                    if wind_variant(transform.rotation*work.placed[order[n]].rotation,set.count)==v {append(&work.instances,instance);append(&work.colors,all_colors[n])}
                }
                variant:=part.desc
                variant.mesh=set.variants[v]
                variant.flags-={.Ray_Visible}
                publish(resident,owner,held,cell.coord,t,u32(k),ROLE_VARIANT+Batch_Role(v),variant,id,app,problems)
            }
        }
        if !draw.far || draw.kind<0 {continue}
        kind:=&resident.kinds[draw.kind]
        for at in order {
            b:=batch_instance_of(work.placed[at],transform)
            append(&work.impostors,Impostor_Instance{position=b.position,rotation=b.rotation,scale=b.scale,row=owner.slot<<16 | u32(i),color=placed_color(work.placed[at])})
        }
        // Past its mesh, rays meet its crown in place of its leaves; past
        // the crowns of its instances, the crown of the cell.
        if near || !(t.casts_shadow || t.ray_visible) || kind.crown=={} || held.far {continue}
        desc,ok:=render.batch_desc(app.assets,{mesh=kind.crown})
        if !ok {continue}
        desc.flags=crown_flags(t)
        desc.tint=kind.albedo
        desc.object_id=u64(owner.entity)
        clear(&work.instances)
        clear(&work.colors)
        for at in order {append(&work.instances,batch_instance_of(work.placed[at],transform))}
        publish(resident,owner,held,cell.coord,t,0,ROLE_CROWN,desc,id,app,problems)
    }
    if !impostors_set(&resident.impostors,&held.impostors,work.impostors[:]) {
        memory_problem(problems,owner.entity,"the impostors of a cell of this Foliage, which keeps what it showed")
        held.stale,owner.pending=true,true
    }
    previous:=held.crown
    held.crown={}
    cell_crown_publish(resident,owner,held,s,transform,id,app.assets,app.renderer,problems)
    // What the cell no longer shows goes.
    for b in held.batches {if b.handle!=0 {render.batch_remove(app.renderer,b.handle)}}
    clear(&held.batches)
    append(&held.batches,..work.batches[:])
    crown_release(resident,previous)
    resident.stats.cells+=1
}

// The cell, type, part and role of a batch of a Foliage of the world, as an
// editor finds the instance a pick names (role_instance).
resident_batch_find :: proc(resident:^Foliage_Resident,handle:render.Batch_Handle) -> (entity:core.Entity,coord:[2]i32,type,part:u32,role:Batch_Role,found:bool) {
    if resident==nil || handle==0 {return}
    for &owner in resident.owners {
        for &cell in owner.cells {
            for b in cell.batches {if b.handle==handle {return owner.entity,cell.coord,b.type,b.part,b.role,true}}
        }
    }
    return
}

// The batches of the foliage of a world that is freed go with it, and what
// it made: far forms, variants and the buffer of its impostors.
@(step="release")
foliage_release :: proc(resident:^Foliage_Resident,app:^host.App) {
    if resident==nil {return}
    context.allocator=app.allocator
    resident.app=app
    stats:=resident.stats
    foliage_resident_free(resident)
    resident.stats=stats
}

// What the crown of a cell is made of (cell_crown_build): each instance
// where it stands on its ground, and the crown of its type. Two cells with the
// same key make the same crown.
crown_key :: proc(placed:[]Placed,crowns:[]Crown_Triangles) -> u64 {
    key:u64
    for c,i in crowns {
        if len(c.indices)==0 {continue}
        key=base.hash64(bytes_of(c.positions),base.hash64(bytes_of(c.indices),key~u64(i)))
    }
    for p in placed {
        values:=[?]f32{transmute(f32)p.type,p.position.x,p.position.y,p.position.z,real(p.rotation),imag(p.rotation),jmag(p.rotation),kmag(p.rotation),p.scale[0],p.scale[1]}
        key=base.hash64(bytes_of(values[:]),key)
    }
    return key
}

// The crown of a cell far away: one batch of one instance whose mesh is the
// crown of the crowns of its instances that cast shadows (cell_crown_build),
// made again with its batches. Called with the instances of the cell placed
// and grouped (cell_publish).
@(private)
cell_crown_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,s:^Source,transform:mm.Transform,id:core.World_Id,assets:^host.Assets,renderer:^render.Renderer,problems:^core.Problems) {
    work:=&resident.work
    held.crown={}
    if !held.far || assets==nil {return}
    clear(&work.crowns)
    if resize(&work.crowns,len(owner.types))!=nil {
        memory_problem(problems,owner.entity,"the crown of a cell of this Foliage")
        held.stale,owner.pending=true,true
        return
    }
    // What rays meet of each of its types, in the mean color of their instances.
    flags:render.Batch_Flags
    tint:[3]f32
    weight:f32
    for draw,i in owner.types {
        t:=&s.types[i]
        if !draw.far || draw.kind<0 || !(t.casts_shadow || t.ray_visible) || i<len(held.near) && held.near[i] {continue}
        kind:=&resident.kinds[draw.kind]
        work.crowns[i]={kind.crown_positions,kind.crown_indices}
        if len(kind.crown_indices)==0 {continue}
        flags+=crown_flags(t)
        count:=f32(work.firsts[i+1]-work.firsts[i])
        tint+=kind.albedo*count
        weight+=count
    }
    if flags=={} || weight<=0 {return}
    // Each instance that gives the crown, by the index of its type.
    placed:=make([dynamic]Placed,0,len(work.placed),context.temp_allocator)
    for i in 0..<len(owner.types) {
        if len(work.crowns[i].indices)==0 {continue}
        for at in work.order[work.firsts[i]:work.firsts[i+1]] {
            p:=work.placed[at]
            p.type=u32(i)
            append(&placed,p)
        }
    }
    key:=crown_key(placed[:],work.crowns[:])
    crown:base.Asset_Id
    for &c in resident.crowns {
        if c.source==owner.source && c.coord==held.coord && c.key==key {
            c.users+=1
            crown=c.mesh
            break
        }
    }
    if crown=={} {
        shape:geom.Mesh_Buffer
        geom.mesh_buffer_init(&shape,context.temp_allocator)
        if !cell_crown_build(placed[:],work.crowns[:],&shape) {return}
        made:bool
        crown,made=host.assets_mesh_generate(assets,geom.mesh_buffer_view(&shape),options={no_lods=true})
        if !made {return}
        append(&resident.crowns,Shared_Crown{owner.source,held.coord,key,crown,1})
    }
    held.crown=crown
    desc,ok:=render.batch_desc(assets,{mesh=crown})
    if !ok {return}
    desc.flags=flags
    desc.tint=tint/weight
    desc.object_id=u64(owner.entity)
    handle:render.Batch_Handle
    for &b in held.batches {if b.role==ROLE_CELL_CROWN && b.handle!=0 {handle,b.handle=b.handle,0;break}}
    instance:=[1]render.Batch_Instance{render.batch_instance(transform.position,transform.rotation,transform.scale)}
    next,error:=render.batch_set(renderer,id,handle,desc,instance[:])
    if error!="" {
        if handle!=0 {render.batch_remove(renderer,handle)}
        core.report(problems,owner.entity,"foliage.batch","the crown of foliage cell %v is not traced: %s",held.coord,error)
        return
    }
    append(&work.batches,Resident_Batch{type=max(u32),role=ROLE_CELL_CROWN,handle=next})
    resident.stats.batches+=1
    resident.stats.instances+=1
}
