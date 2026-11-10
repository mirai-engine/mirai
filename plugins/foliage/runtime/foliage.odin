package foliage

import "base:runtime"
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
    source:Source,
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
    cells_left,kinds_left:int, // of this frame: the cells it may build, by their cost, and the far forms it may make
    work:Build_Work,
    stats:Foliage_Resident_Stats,
}
Foliage_Resident_Stats :: struct {builds,cells,batches,instances:u64}
Resident_Owner :: struct {
    entity:core.Entity,
    source:base.Asset_Id,
    epoch:u64,    // of the entry it was built from
    loads:u32,
    transform:mm.Transform,
    ground:u32,   // the revision of its ground then
    sources:u64,  // the revision of the streaming sources its cells were chosen by
    removed:u64,  // the hash of the instances taken out of it then (Removed_Owner)
    cells:[dynamic]Resident_Cell, // in the order of the cells of the source
    kinds:[dynamic]base.Asset_Id, // the far forms its types show
    winds:[dynamic]Wind_Key,      // the variants its types sway with
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
    built:bool,
    stale:bool,    // it waits for the budget of a frame to be built again
    resident:bool, // near a streaming source
    near:[dynamic]bool, // by type: within the distance where its mesh is gone (no far form: always)
    far:bool,           // past CELL_CROWN_REACH times the reach of its meshes: rays meet one crown of the cell
    crown:base.Asset_Id, // that crown, generated; none while its crowns are those of its instances
    batches:[dynamic]Resident_Batch,
    impostors:[dynamic]Impostor_Placed,
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

// The crown of a cell of a source at a version, in the space of its Foliage:
// every Foliage that shows the source traces the same mesh, placed by its
// own transform (a world of sections that reference one scene many times).
Shared_Crown :: struct {
    source:base.Asset_Id,
    coord:[2]i32,
    version:u32,
    removed:u64, // the hash of the instances taken out of the cell
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
    types:[dynamic]Type_Draw, // by index of the type in its source
    parts:[dynamic]Part_Draw,
    ids:[dynamic][2]u32,      // id and index of each type of the source, by id
    order:[dynamic]u32,       // the placed instances by type, in their order
    firsts:[dynamic]u32,      // where those of the type of each index start in order, and their end
    cursor:[dynamic]u32,
    batches:[dynamic]Resident_Batch,
    cells:[dynamic]Resident_Cell,
    resident:[dynamic]scene.Resident_Order, // the resident cells, by index in cells
    bands:[dynamic]scene.Sources_Near, // by type: the sources as far as its mesh reaches
    cell_band:scene.Sources_Near,      // the sources as far as the crowns of instances reach
    crowns:[dynamic]Crown_Triangles,   // by type: those of its far form, while a cell crown is made
}

build_work_destroy :: proc(w:^Build_Work) {
    expand_scratch_destroy(&w.expand)
    delete(w.placed);delete(w.orphans);delete(w.instances)
    delete(w.types);delete(w.parts);delete(w.ids);delete(w.order);delete(w.firsts);delete(w.cursor)
    delete(w.batches);delete(w.cells);delete(w.resident);delete(w.bands);delete(w.crowns)
    w^={}
}

@(private)
resident_cell_free :: proc(resident:^Foliage_Resident,cell:^Resident_Cell) {
    if resident.app!=nil {for b in cell.batches {render.batch_remove(resident.app.renderer,b.handle)}}
    crown_release(resident,cell.crown)
    cell.crown={}
    if len(cell.impostors)>0 {resident.impostors.dirty=true}
    delete(cell.batches);delete(cell.impostors);delete(cell.near)
    cell.batches,cell.impostors,cell.near=nil,nil,nil
}

@(private)
resident_owner_free :: proc(resident:^Foliage_Resident,owner:^Resident_Owner) {
    for &cell in owner.cells {resident_cell_free(resident,&cell)}
    delete(owner.cells);delete(owner.kinds);delete(owner.winds)
    owner.cells,owner.kinds,owner.winds=nil,nil,nil
}

// Lets go of the far forms and the variants no Foliage shows any longer, or
// of all of them.
@(private)
resident_sweep :: proc(resident:^Foliage_Resident,all:=false) {
    app:=resident.app
    for i:=len(resident.kinds)-1;i>=0;i-=1 {
        used:=false
        if !all {for owner in resident.owners {for id in owner.kinds {used||=id==resident.kinds[i].id}}}
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
    if resident.app!=nil {render.buffer_release(resident.app.renderer,resident.world,IMPOSTOR_BUFFER)}
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
// keeps unsaved, or the file.
foliage_read :: proc(s:^Source,a:^host.Assets,id:base.Asset_Id,allocator:=context.allocator) -> bool {
    file:asset.Asset
    if host.assets_file(a,id,KIND,&file)!=.None {return false}
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
    core.report(problems,e,"foliage.source_unread","foliage source %s cannot be read: it is missing, of another kind or version (%s, version %d), damaged, or memory ran out; give Foliage.source a .foliage asset",host.assets_name(a,id,&name),EXTENSION,VERSION)
}

@(private)
bytes_of :: proc "contextless" (values:[]$T) -> []u8 {return transmute([]u8)runtime.Raw_Slice{raw_data(values),len(values)*size_of(T)}}

@(private)
same_rows :: proc "contextless" (a,b:[]$T) -> bool {return len(a)==len(b) && mem.compare(bytes_of(a),bytes_of(b))==0}

// The versions of the cells of a source read again: a cell equal to the one
// of its coordinate before keeps its version, and the others take the next
// one. Another seed or other types change every cell.
cells_version :: proc(next,previous:^Source,versions:^u32) {
    types_same:=next.info.seed==previous.info.seed && same_rows(next.types[:],previous.types[:])
    j:=0
    for &cell in next.cells {
        for j<len(previous.cells) && coord_before(previous.cells[j].coord,cell.coord) {j+=1}
        if types_same && j<len(previous.cells) && previous.cells[j].coord==cell.coord {
            old:=&previous.cells[j]
            if old.generate==cell.generate && same_rows(old.manual[:],cell.manual[:]) && same_rows(old.overrides[:],cell.overrides[:]) {
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
@(step="fixed frame",loops="game editor",stage="simulate")
foliage_load :: proc(data:^Foliage_Data,foliages:^core.Table(Foliage,.Read),assets:^host.Assets,allocator:runtime.Allocator,problems:^core.Problems) {
    a:=assets
    if a==nil {return}
    context.allocator=allocator
    if data.registry!=a.registry.revision {
        data.registry=a.registry.revision
        for &entry in data.entries {
            stamp:=foliage_stamp(a,entry.id)
            if stamp==entry.stamp {continue}
            next:Source
            if foliage_read(&next,a,entry.id) {
                cells_version(&next,&entry.source,&entry.versions)
                source_destroy(&entry.source)
                entry.source=next
                entry.loads+=1
                data.stats.loads+=1
            }
            entry.stamp=stamp
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
// in work.orphans.
cell_build :: proc(s:^Source,cell:^Cell,ground:Ground_Cell,work:^Build_Work,removed:[]u64={}) -> bool {
    clear(&work.placed);clear(&work.orphans)
    return cell_expand(s,cell,ground,&work.placed,&work.orphans,&work.expand,removed)
}

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

// An instance as a batch draws it, carried by the transform of its entity.
batch_instance_of :: proc "contextless" (p:Placed,owner:mm.Transform) -> render.Batch_Instance {
    return render.batch_instance(mm.transform_point(owner,p.position),owner.rotation*p.rotation,p.scale[0]*owner.scale.x,p.scale[1]*owner.scale.y)
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
// is chosen again when the streaming sources move.
@(step="late",loops="game editor",stage="end")
foliage_render :: proc(resident:^Foliage_Resident,data:core.Ref(Foliage_Data),grounds:core.Ref(Foliage_Ground),removals:core.Ref(Foliage_Removals),foliages:^core.Table(Foliage,.Read),worlds:^core.Table(core.World_Transform,.Read),kept:^core.Table(scene.Far_Kept,.Read),sources:core.Ref(scene.Streaming_Sources),id:core.World_Id,app:^host.App,problems:^core.Problems) {
    if resident==nil || data.ptr==nil || app.renderer==nil || app.assets==nil {return}
    a:=app.assets
    context.allocator=app.allocator
    resident.app,resident.world=app,id
    changed:=false
    if resident.epoch!=render.batches_epoch(app.renderer) {
        // The renderer forgot them, and every mesh with them: their handles name nothing.
        for &owner in resident.owners {
            for &cell in owner.cells {delete(cell.batches);delete(cell.impostors);delete(cell.near)}
            delete(owner.cells)
            owner.cells,owner.built=nil,false
        }
        clear(&resident.winds)
        resident.impostors.dirty=true
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
    // A load is spread over frames: so many cells and far forms a frame.
    resident.cells_left,resident.kinds_left=CELLS_A_FRAME,KINDS_A_FRAME
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        entry:=data_find(data.ptr,f.source)
        world,placed:=core.get(worlds,e)
        if entry==nil || !placed {continue}
        owner:^Resident_Owner
        for &held in resident.owners {if held.entity==e {owner=&held;break}}
        if owner==nil {
            if _,err:=append(&resident.owners,Resident_Owner{entity=e,source=f.source});err!=nil {
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
        if owner.far_only!=far_only {owner.built=false}
        if owner.built && !owner.pending && owner.epoch==entry.epoch && owner.loads==entry.loads && owner.transform==world.transform && owner.ground==revision && owner.sources==streamed && owner.removed==removed {continue}
        if resident.cells_left<=0 && owner.built {continue}
        owner.far_only=far_only
        owner_publish(resident,owner,entry,world.transform,ground,gone,sources.ptr,id,app,problems)
        changed=true
    }
    if changed {resident_sweep(resident)}
    if resident.impostors.dirty {impostors_build(resident,data.ptr)}
}

// The parts of a prefab, read once while the assets keep it; nil without memory.
@(private)
resident_prefab :: proc(resident:^Foliage_Resident,a:^host.Assets,id:base.Asset_Id) -> ^Resident_Prefab {
    for &prefab in resident.prefabs {if prefab.id==id {return &prefab}}
    if _,err:=append(&resident.prefabs,Resident_Prefab{id=id});err!=nil {return nil}
    prefab:=&resident.prefabs[len(resident.prefabs)-1]
    if file:=host.assets_scene(a,id);file!=nil {prefab.read=prefab_parts(file,&a.types,&prefab.parts)}
    return prefab
}

// How each type of a source is drawn: the batch description of each of its
// parts, the variants each part sways with, and its far form, made the first
// time a type shows its asset.
@(private)
types_draw :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,entry:^Data_Entry,assets:^host.Assets,renderer:^render.Renderer,job_system:^jobs.Job_System,allocator:runtime.Allocator,problems:^core.Problems) {
    work:=&resident.work
    clear(&work.types);clear(&work.parts)
    clear(&owner.kinds);clear(&owner.winds)
    name,other:[base.ASSET_ID_TEXT]u8
    for &t in entry.source.types {
        draw:=Type_Draw{first=len(work.parts),kind=-1}
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
            append(&work.parts,part)
        }
        draw.count=len(work.parts)-draw.first
        if type_far(t) && draw.count>0 {
            id:=t.mesh if t.mesh!={} else t.prefab
            draw.kind=kind_ensure(resident,assets,renderer,job_system,allocator,id,work.parts[draw.first:][:draw.count],problems,owner.entity)
            append(&owner.kinds,id)
            if draw.kind>=0 && kind_ready(&resident.kinds[draw.kind]) {
                draw.far=true
                fade,cull=mesh_distances(t,true)
                draw.reach=cull
                for &part in work.parts[draw.first:][:draw.count] {part.desc.fade_distance,part.desc.cull_distance=fade,cull}
            }
        }
        append(&work.types,draw)
    }
}

// How far the cells of a source are drawn: the farthest cull distance of its
// types; 0 when one is never culled, and every cell stays.
@(private)
source_reach :: proc(s:^Source) -> f32 {
    reach:=f32(0)
    for t in s.types {
        if t.cull_distance<=0 {return 0}
        reach=max(reach,t.cull_distance)
    }
    return reach
}

// The batches of one Foliage: those of its resident cells that changed, or
// whose types changed band, or of all of them; a cell that stops being
// resident lets go of its batches and its impostors.
@(private)
owner_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,entry:^Data_Entry,transform:mm.Transform,ground:^Ground_Owner,gone:^Removed_Owner,sources:^scene.Streaming_Sources,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    all:=!owner.built || owner.epoch!=entry.epoch || owner.transform!=transform
    owner.epoch,owner.loads,owner.transform,owner.source=entry.epoch,entry.loads,transform,entry.id
    owner.ground=ground!=nil?ground.revision:0
    owner.removed=gone!=nil?gone.hash:0
    owner.sources=sources!=nil?sources.revision:0
    s:=&entry.source
    work:=&resident.work
    owner.pending=false
    types_draw(resident,owner,entry,app.assets,app.renderer,&app.jobs,app.allocator,problems)
    // Its cells wait for the far forms of its types.
    for draw,i in work.types {
        if type_far(s.types[i]) && draw.count>0 && draw.kind<0 {
            owner.pending=true
            return
        }
    }
    reach:=source_reach(s)
    placed:=mm.transform_matrix(transform)
    near:scene.Sources_Near
    if reach>0 {near=scene.sources_near(sources,placed,reach)}
    if resize(&work.bands,len(work.types))!=nil {
        memory_problem(problems,owner.entity,"the cells of this Foliage")
        owner.pending=true
        return
    }
    for draw,i in work.types {work.bands[i]=draw.far?scene.sources_near(sources,placed,draw.reach):{}}
    crown_reach:=f32(0)
    for draw in work.types {if draw.far {crown_reach=max(crown_reach,draw.reach*CELL_CROWN_REACH)}}
    work.cell_band={}
    if crown_reach>0 {work.cell_band=scene.sources_near(sources,placed,crown_reach)}
    // A type that is never culled keeps every cell, the nearest first.
    if reach<=0 {near=scene.sources_near(sources,placed,CELL_SIZE)}
    // The cells of the source and those built, both in the order of their coordinates.
    clear(&work.cells)
    clear(&work.resident)
    j:=0
    for cell in s.cells {
        for j<len(owner.cells) && coord_before(owner.cells[j].coord,cell.coord) {resident_cell_free(resident,&owner.cells[j]);j+=1}
        held:=Resident_Cell{coord=cell.coord}
        if j<len(owner.cells) && owner.cells[j].coord==cell.coord {held=owner.cells[j];j+=1}
        corner:=cell_corner(cell.coord)
        at:=scene.box_near(&near,{corner.x,-POSITION_MAX,corner.z},{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE})
        held.resident=reach<=0 || scene.resident(at,held.resident)
        if held.resident {append(&work.resident,scene.Resident_Order{near=at,index=u32(len(work.cells))})}
        append(&work.cells,held)
    }
    for ;j<len(owner.cells);j+=1 {resident_cell_free(resident,&owner.cells[j])}
    if left_out:=resident_cap(work.cells[:],work.resident[:],RESIDENT_CELLS,reach<=0?max(f32):1);left_out>0 {
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,owner.entity,"foliage.resident_cells","%d cells of foliage source %s within the reach of its types are not drawn: a Foliage keeps the nearest RESIDENT_CELLS (%d); give its types a cull distance, or a shorter one, or split the foliage into sections",left_out,host.assets_name(app.assets,owner.source,&name),RESIDENT_CELLS)
    }
    for &cell,k in s.cells {
        held:=&work.cells[k]
        if !held.resident {
            if held.built {
                resident_cell_free(resident,held)
                held.built=false
            }
            continue
        }
        corner:=cell_corner(cell.coord)
        low,high:=[3]f32{corner.x,-POSITION_MAX,corner.z},[3]f32{corner.x+CELL_SIZE,POSITION_MAX,corner.z+CELL_SIZE}
        // Each type with a far form draws its mesh within its reach of a source, and its crown past it.
        banded:=len(held.near)!=len(work.types)
        if banded && resize(&held.near,len(work.types))!=nil {
            memory_problem(problems,owner.entity,"a cell of this Foliage, which keeps what it showed")
            held.stale,owner.pending=true,true
            continue
        }
        for draw,i in work.types {
            was:=held.near[i]
            held.near[i]=!owner.far_only && (!draw.far || scene.resident(scene.box_near(&work.bands[i],low,high),was))
            banded||=held.near[i]!=was
        }
        was_far:=held.far
        held.far=crown_reach>0 && !scene.resident(scene.box_near(&work.cell_band,low,high),!was_far)
        banded||=held.far!=was_far
        tile,revision:=ground_cell(ground,cell.coord)
        removed,removed_hash:=removed_cell(gone,cell.coord)
        if all || banded || held.stale || !held.built || held.version!=cell.version || held.ground!=revision || held.removed!=removed_hash {
            // What stands for a section that is not loaded publishes no batches: it costs less.
            cost:=owner.far_only?1:CELL_COST
            if resident.cells_left<cost {
                held.stale=true
                owner.pending=true
            } else {
                resident.cells_left-=cost
                held.version,held.ground,held.removed,held.built,held.stale=cell.version,revision,removed_hash,true,false
                cell_publish(resident,owner,held,s,&cell,tile,removed,transform,id,app,problems)
            }
        }
    }
    clear(&owner.cells)
    append(&owner.cells,..work.cells[:])
    owner.built=true
    resident.stats.builds+=1
    for draw,i in work.types {
        if draw.error<=PREFAB_ERROR {continue}
        t:=&s.types[i]
        name:[base.ASSET_ID_TEXT]u8
        core.report(problems,owner.entity,"foliage.prefab_transform","the parts of prefab %s of foliage type '%s' are drawn with up to %d%% of their transform left out: an instance of a batch holds one scale across x and z and one along y, without shear; give the parts of the prefab, and the Foliage entity, the same scale along x and z, and no scale under a rotation of their parents",host.assets_name(app.assets,t.prefab,&name),base.text_get(t.name[:]),int(draw.error*100+0.5))
    }
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

// What a frame builds of the foliage at most: cells, and far forms of the
// assets types show (each draws its impostor). The rest waits for the frames
// that follow; the cells of a Foliage wait for the far forms of its types.
CELLS_A_FRAME :: 48
CELL_COST :: 4 // of CELLS_A_FRAME, a cell that publishes batches; one of a Foliage that is not loaded (far_only) costs 1
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
// handles the cell had for the same roles.
@(private)
cell_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,s:^Source,cell:^Cell,ground:Ground_Cell,removed:[]u64,transform:mm.Transform,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    work:=&resident.work
    built:=cell_build(s,cell,ground,work,removed)
    if built {orphans_report(problems,owner.entity,app.assets,owner.source,cell,work.orphans[:])}
    if !built || !placed_group(s,work) {
        memory_problem(problems,owner.entity,"a cell of this Foliage, which keeps what it showed")
        held.stale,owner.pending=true,true
        return
    }
    owner_matrix:=mm.transform_matrix(transform)
    clear(&work.batches)
    if len(held.impostors)>0 {resident.impostors.dirty=true}
    clear(&held.impostors)
    publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,coord:[2]i32,t:^Foliage_Type,part:u32,role:Batch_Role,desc:render.Batch_Desc,id:core.World_Id,app:^host.App,problems:^core.Problems) {
        work:=&resident.work
        if len(work.instances)==0 {return}
        handle:render.Batch_Handle
        for &b in held.batches {if b.type==t.id && b.part==part && b.role==role && b.handle!=0 {handle,b.handle=b.handle,0;break}}
        next,error:=render.batch_set(app.renderer,id,handle,desc,work.instances[:])
        if error!="" {
            if handle!=0 {render.batch_remove(app.renderer,handle)}
            core.report(problems,owner.entity,"foliage.batch","the foliage of cell %v, type '%s', is not drawn: %s",coord,base.text_get(t.name[:]),error)
            return
        }
        append(&work.batches,Resident_Batch{type=t.id,part=part,role=role,handle=next})
        resident.stats.batches+=1
        resident.stats.instances+=u64(len(work.instances))
    }
    for &draw,i in work.types {
        t:=&s.types[i]
        order:=work.order[work.firsts[i]:work.firsts[i+1]]
        if len(order)==0 {continue}
        // Of a section that is not loaded, only what has a far form, and only that form.
        if owner.far_only && !draw.far {continue}
        near:=i>=len(held.near) || held.near[i]
        for &part,k in work.parts[draw.first:][:draw.count] {
            if !near {break}
            clear(&work.instances)
            for at in order {
                p:=work.placed[at]
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
            copy(all,work.instances[:])
            for v in 0..<set.count {
                clear(&work.instances)
                for instance,n in all {
                    if wind_variant(transform.rotation*work.placed[order[n]].rotation,set.count)==v {append(&work.instances,instance)}
                }
                variant:=part.desc
                variant.mesh=set.variants[v]
                variant.flags-={.Ray_Visible}
                publish(resident,owner,held,cell.coord,t,u32(k),ROLE_VARIANT+Batch_Role(v),variant,id,app,problems)
            }
        }
        if !draw.far || draw.kind<0 {continue}
        kind:=&resident.kinds[draw.kind]
        for at in order {append(&held.impostors,Impostor_Placed{instance=batch_instance_of(work.placed[at],transform),type=u32(i)})}
        resident.impostors.dirty=true
        // Past its mesh, rays meet its crown in place of its leaves; past
        // the crowns of its instances, the crown of the cell.
        if near || !t.casts_shadow || kind.crown=={} || held.far {continue}
        desc,ok:=render.batch_desc(app.assets,{mesh=kind.crown})
        if !ok {continue}
        desc.flags={.Casts_Shadow,.Rays_Only}
        desc.object_id=u64(owner.entity)
        clear(&work.instances)
        for at in order {append(&work.instances,batch_instance_of(work.placed[at],transform))}
        publish(resident,owner,held,cell.coord,t,0,ROLE_CROWN,desc,id,app,problems)
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
    if resize(&work.crowns,len(work.types))!=nil {
        memory_problem(problems,owner.entity,"the crown of a cell of this Foliage")
        held.stale,owner.pending=true,true
        return
    }
    any:=false
    for draw,i in work.types {
        if !draw.far || draw.kind<0 || !s.types[i].casts_shadow || i<len(held.near) && held.near[i] {continue}
        kind:=&resident.kinds[draw.kind]
        work.crowns[i]={kind.crown_positions,kind.crown_indices}
        any||=len(kind.crown_indices)>0
    }
    if !any {return}
    crown:base.Asset_Id
    for &c in resident.crowns {
        if c.source==owner.source && c.coord==held.coord && c.version==held.version && c.removed==held.removed {
            c.users+=1
            crown=c.mesh
            break
        }
    }
    if crown=={} {
        shape:geom.Mesh_Buffer
        geom.mesh_buffer_init(&shape,context.temp_allocator)
        // Each instance by the index of its type.
        placed:=make([dynamic]Placed,0,len(work.placed),context.temp_allocator)
        for i in 0..<len(work.types) {
            for at in work.order[work.firsts[i]:work.firsts[i+1]] {
                p:=work.placed[at]
                p.type=u32(i)
                append(&placed,p)
            }
        }
        if !cell_crown_build(placed[:],work.crowns[:],&shape) {return}
        made:bool
        crown,made=host.assets_mesh_generate(assets,geom.mesh_buffer_view(&shape),options={no_lods=true})
        if !made {return}
        append(&resident.crowns,Shared_Crown{owner.source,held.coord,held.version,held.removed,crown,1})
    }
    held.crown=crown
    desc,ok:=render.batch_desc(assets,{mesh=crown})
    if !ok {return}
    desc.flags={.Casts_Shadow,.Rays_Only}
    desc.object_id=u64(owner.entity)
    handle:render.Batch_Handle
    for &b in held.batches {if b.role==ROLE_CELL_CROWN && b.handle!=0 {handle,b.handle=b.handle,0;break}}
    instance:=[1]render.Batch_Instance{render.batch_instance(transform.position,transform.rotation,transform.scale.x,transform.scale.y)}
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
