package foliage

import "base:runtime"
import "core:math/linalg"
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
import pcg "plugins:pcg/runtime"
import physics "plugins:physics/runtime"

// The sink of what a Pcg_Graph places on the CPU (plugins/pcg): the Foliage
// on the same entity draws the cells its graph generated, without an entity
// per instance, as batches per cell, layer and part (engine/render
// batch_set), and the physics gives each cell a static body with a shape per
// instance of a layer that collides (physics.odin). What a layer places is
// its look: a mesh, drawn as the Foliage says, or a prefab, drawn as its
// Mesh_Renderers say and swaying by the Foliage_Sway of its root. A layer
// with an impostor distance has a far form (far.odin), and the wind sways
// every layer in the vertex hook (wind.odin). A cell is built again when
// what its graph places there changes, or the band of one of its layers
// does, and the others keep their batches. The Detail of the graphics
// settings thins the filler layers, dropping the last points of each cell
// (filler_kept), and scales the distances; a dense cell gives way to the far
// forms of its layers sooner (density_band). Taking an instance out or
// promoting it to an entity is the graph's (pcg.Pcg_Suppressed,
// foliage_promote).

@(component,far,description="Draws and collides what the Pcg_Graph of this entity places: a batch per cell and layer, impostors and crowns far away, swaying in the wind, and a static body per cell for the layers that collide.")
Foliage :: struct {
    wind:f32 `mirai:"min=0"`,    // how much the wind moves a layer that places a mesh; a prefab with a Foliage_Sway at its root sways by its own
    flutter:f32 `mirai:"min=0"`, // how much the wind flutters its leaves on top, by the red and the green of its vertex colors
    shadows:bool,                // a layer that places a mesh casts shadows; the parts of a prefab, as their Mesh_Renderer says
    rays:bool,                   // reflections and the indirect light see what it draws
    preset:physics.Collision_Preset, // of the hulls of a mesh that collides; a prefab collides as its colliders say
}

FOLIAGE_DEFAULT :: Foliage{wind=1,shadows=true,rays=true}

// What the Detail of the graphics settings draws of the foliage: the share of
// the points of the filler layers each cell keeps (the collision is the same
// at any detail), and of the distances of every layer.
FOLIAGE_DETAIL :: [render.Detail][2]f32{.Low={0.4,0.6},.Medium={0.8,0.8},.High={1,1},.Ultra={1,1}}

// How a cell full of a layer gives way to its far form sooner than one where
// it stands alone, behind which nothing hides: its distances times
// band_scale of its band, DENSITY_BANDS of them from all of the distance
// (band 0, sparse) to DENSITY_LOD_MIN of it (full), chosen once when the
// cell is built.
DENSITY_BANDS :: 4
DENSITY_LOD_MIN :: f32(0.7)

// How a layer of the source of a graph is drawn and collides: by the layer
// (its distances, whether it is filler or collides) and by what it places.
Look :: struct {
    layer:u32,           // the id of its layer
    asset:base.Asset_Id, // a .mesh, or a prefab
    prefab:bool,
    scale:[2]f32,        // of the layer: across, lowest and highest
    height:[2]f32,       // along y, times the scale across
    fade_distance,cull_distance,impostor_distance:f32,
    wind,flutter:f32,
    casts_shadow,ray_visible:bool,
    collides,filler:bool,
    span:f32,     // of the points of its cell, the indices its stable ids run over (filler_kept); 0 for a grammar
    expected:f32, // instances of it a cell full of it holds (density_band); 0 for a grammar
}

// The looks of the layers of a source, in its order: by the Foliage for a
// mesh, by the Foliage_Sway of its root for a prefab that has one.
looks_make :: proc(out:^[dynamic]Look,s:^pcg.Pcg_Source,f:Foliage,assets:^host.Assets) -> bool {
    clear(out)
    if reserve(out,len(s.layers))!=nil {return false}
    share:=pcg.generated_share(s)
    area:=f64(s.info.cell_size)*f64(s.info.cell_size)
    // The density the points of a Scatter layer are scattered at: of its dither group together.
    unit :: proc "contextless" (s:^pcg.Pcg_Source,l:^pcg.Pcg_Layer) -> f64 {
        if l.dither_group==0 {return f64(l.density)}
        sum:=f64(0)
        for &other in s.layers {if other.kind==.Scatter && other.tier==l.tier && other.dither_group==l.dither_group {sum+=f64(other.density)}}
        return sum
    }
    for &l in s.layers {
        look:=Look{layer=l.id,asset=l.asset,scale=l.scale,height=l.height,fade_distance=l.fade_distance,cull_distance=l.cull_distance,impostor_distance=l.impostor_distance}
        look.wind,look.flutter,look.casts_shadow,look.ray_visible=f.wind,f.flutter,f.shadows,f.rays
        look.collides,look.filler=l.collides,l.filler
        switch l.kind {
        case .Scatter:
            look.span,look.expected=f32(unit(s,&l)*area*f64(share)),f32(f64(l.density)*area*f64(share))
        case .Cascade:
            if parent,_:=pcg.source_layer(s,l.parent_layer);parent!=nil {
                look.span=f32(unit(s,parent)*area*f64(share))*pcg.CASCADE_CHILDREN_MAX
                look.expected=f32(f64(parent.density)*area*f64(share)*f64(l.density))
            }
        case .Grammar:
        }
        if assets!=nil && l.asset!={} {
            if file,found:=asset.registry_find(&assets.registry,l.asset);found && file.kind==asset.KIND_SCENE {
                look.prefab=true
                if document:=host.assets_scene(assets,l.asset);document!=nil {
                    if sway,swaying:=prefab_sway(document,&assets.types);swaying {look.wind,look.flutter=sway.wind,sway.flutter}
                }
            }
        }
        append(out,look)
    }
    return true
}

// The ids of the layers of looks with their index, by id, into ids.
looks_ids :: proc(looks:[]Look,ids:^[dynamic][2]u32) -> bool {
    if resize(ids,len(looks))!=nil {return false}
    for look,i in looks {ids[i]={look.layer,u32(i)}}
    slice.sort_by(ids[:],proc(a,b:[2]u32) -> bool {return a[0]<b[0]})
    return true
}

// The index of the look of a layer id, through ids (looks_ids); -1 for none.
look_index :: proc "contextless" (ids:[][2]u32,layer:u32) -> int {
    low,high:=0,len(ids)
    for low<high {mid:=(low+high)/2;if ids[mid][0]<layer {low=mid+1} else {high=mid}}
    return low<len(ids) && ids[low][0]==layer?int(ids[low][1]):-1
}

// Whether a cell draws an instance of a layer at a detail that keeps thin
// of the points of its filler: the first of its points, so a lower detail
// takes the last ones away and keeps the others where they were.
filler_kept :: proc "contextless" (look:Look,id:u64,thin:f32) -> bool {
    if !look.filler || thin>=1 || !(look.span>0) {return true}
    return f32(u32(id))<look.span*max(thin,0)
}

// The band of the distances of a layer in a cell where count of its
// instances stand, of expected in a cell full of it.
density_band :: proc "contextless" (count:int,expected:f32) -> u8 {
    if !(expected>0) {return 0}
    fill:=clamp(f32(count)/expected,0,1)
    return u8(fill*f32(DENSITY_BANDS-1)+0.5)
}

// The share of its distances a band keeps.
band_scale :: proc "contextless" (band:u8) -> f32 {
    return 1-f32(min(band,DENSITY_BANDS-1))*(1-DENSITY_LOD_MIN)/f32(DENSITY_BANDS-1)
}

// The batches of the cells of each Foliage, kept by world: each world
// publishes its own and takes them with it when it is freed.
@(storage,host,by_world,free="foliage_resident_free")
Foliage_Resident :: struct {
    app:^host.App,
    world:core.World_Id, // the world it publishes in
    owners:[dynamic]Resident_Owner,
    prefabs:[dynamic]Resident_Prefab,
    kinds:[dynamic]Resident_Kind, // the far forms of the assets layers show
    crowns:[dynamic]Shared_Crown, // the crowns of cells, which the Foliage that show one source share
    winds:[dynamic]Wind_Zone,     // the zones of wind cells that cast swaying shadows stand in
    zones:volume.Index,           // of the Wind zones, which the cells take their wind by
    zones_hash:u64,               // of where the zones are, not of their values
    zones_revision:u64,           // counts the changes of where the zones are
    epoch:u64,     // of the batches of the renderer (render.batches_epoch)
    structure:u64, // of the assets, when the meshes of the batches were resolved
    wind:volume.Gpu_Wind, // what the frame gives the shaders of the wind (foliage_wind.slang), in the world: each view takes it relative to its origin
    trample:Foliage_Trample,
    impostors:Impostor_Draw,
    instances_left,kinds_left:int, // of this frame: the instances it may still build and the far forms it may make
    detail:[2]f32, // what the cells were built with (FOLIAGE_DETAIL): the share of the points of the filler layers, and of the distances
    work:Build_Work,
    stats:Foliage_Resident_Stats,
    sways:core.Entity_Map(Resident_Sway), // the mesh entities that sway (Foliage_Sway), by entity
    sway_seen:Sway_Seen,
    sway_epoch,sway_structure,sway_zones:u64, // the batches_epoch, assets structure and zones_revision they were drawn at
    sway_outlines:Sway_Outlines,
}
Foliage_Resident_Stats :: struct {builds,cells,batches,instances:u64}
Resident_Owner :: struct {
    entity:core.Entity,
    source:base.Asset_Id, // of its graph
    foliage:Foliage,      // the values it was built with
    epoch:u64,            // of the entry of Pcg_Data its looks were made from
    loads:u32,
    revision,wants:u32,   // of its generated graph when its cells were matched with it
    count:int,            // of the cells of that graph then
    transform:mm.Transform, // the frame of its cells (pcg.graph_frame)
    sources:u64,  // the revision of the streaming sources its bands were chosen by
    zones:u64,    // the revision of the zones of wind its cells were keyed by
    marked:u64,   // the hash of the marks of its instances then (Marked_Owner)
    cells:[dynamic]Resident_Cell, // in the order of their coordinates, those its graph generated
    looks:[dynamic]Look,          // by index of the layer in its source
    ids:[dynamic][2]u32,          // looks_ids of looks
    types:[dynamic]Type_Draw,     // by look
    parts:[dynamic]Part_Draw,
    kinds:[dynamic]Kind_Key,      // by look: the far form it shows; none for a layer without one
    sways:bool,                   // one of its layers casts swaying shadows (Batch_Desc.sway)
    slot:u32,                     // of no other owner: where the rows of its looks start (Impostor_Draw.bases)
    built:bool,   // its looks and cells are those of its source, transform and graph
    pending:bool, // some of its cells, or the far forms of its layers, wait for the budget of a frame
    far_only:bool, // of a section that is not loaded (scene.Far_Kept): only the far forms of its layers
}
// The batches of a cell its graph generated, at a revision, while the graph
// keeps it.
Resident_Cell :: struct {
    coord:[2]i32,
    revision:u32,  // of the generated cell it was built from
    zone:i32,      // the zone of wind it sways in (wind_zone_at), at `at`
    at:[3]f32,     // the middle of its instances in the world
    marked:u64,    // the hash of the marks of its instances (marked_cell)
    built:bool,
    stale:bool,    // it waits for the budget of a frame to be built again
    near:[dynamic]bool, // by look: within the distance where its mesh is gone (no far form: always)
    bands:[dynamic]u8,  // by look: its density_band, chosen when it was built
    far:bool,           // past CELL_CROWN_REACH times the reach of its meshes: rays meet one crown of the cell
    crown:base.Asset_Id, // that crown, generated; none while its crowns are those of its instances
    batches:[dynamic]Resident_Batch,
    impostors:u32, // its block of Impostor_Draw.blocks, plus one; 0: none
}
// A batch of a cell, a layer, a part of it (0 for a mesh) and a role.
Resident_Batch :: struct {
    layer:u32,
    part:u32,
    role:Batch_Role,
    handle:render.Batch_Handle,
}

// What a batch of a cell is for: its mesh as the layer shows it, or the
// crown rays meet far away.
Batch_Role :: distinct u32
ROLE_MESH :: Batch_Role(0)
ROLE_CROWN :: Batch_Role(1)
ROLE_CELL_CROWN :: Batch_Role(2) // of no layer: the crown of the whole cell

// The crown of a cell of a source, in the frame of its graph: every Foliage
// that shows the source with the same instances there traces the same mesh,
// placed by its own transform (a world of sections that reference one scene
// many times).
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
// The parts of a prefab some layer shows, read once while the assets keep it.
Resident_Prefab :: struct {
    id:base.Asset_Id,
    parts:[dynamic]Prefab_Part,
    read:bool,
}

// How a look is drawn: its parts, each a batch per cell, and its far form.
Type_Draw :: struct {
    first,count:int, // of Resident_Owner.parts
    error:f32,       // the most of a transform its instances leave out (part_instance)
    far:bool,        // its mesh gives way to its impostor and its crown
    kind:int,        // its far form, of Foliage_Resident.kinds; -1 for none
    reach:f32,       // metres from a source within which a sparse cell draws its mesh and rays meet it
}
Part_Draw :: struct {
    desc:render.Batch_Desc,
    placement:mm.Mat4,
    identity:bool,
}

// What building the cells reuses.
Build_Work :: struct {
    instances:[dynamic]render.Batch_Instance,
    colors:[dynamic]u32,  // of each of instances, what it shows of its own (render.batch_color)
    shown:[dynamic]u32,   // of each placed instance of the cell, what it shows of its own
    order:[dynamic]u32,   // the instances of the cell it draws by look, in their order
    firsts:[dynamic]u32,  // where those of the look of each index start in order, and their end
    counts:[dynamic]u32,  // by look: its instances in the cell before the detail thins them
    cursor:[dynamic]u32,
    batches:[dynamic]Resident_Batch,
    cells:[dynamic]Resident_Cell,
    builds:[dynamic]scene.Resident_Order, // the cells to build, by index, nearest first
    bands:[dynamic]scene.Sources_Near,    // by look: the sources as far as its mesh reaches
    cell_band:scene.Sources_Near,         // the sources as far as the crowns of instances reach
    crowns:[dynamic]Crown_Triangles,      // by look: those of its far form, while a cell crown is made
    impostors:[dynamic]Impostor_Instance, // of the cell being built, in the world
}

build_work_destroy :: proc(w:^Build_Work) {
    delete(w.instances);delete(w.colors);delete(w.shown);delete(w.order);delete(w.firsts);delete(w.counts);delete(w.cursor)
    delete(w.batches);delete(w.cells);delete(w.builds);delete(w.bands);delete(w.crowns);delete(w.impostors)
    w^={}
}

@(private)
resident_cell_free :: proc(resident:^Foliage_Resident,cell:^Resident_Cell) {
    if resident.app!=nil {for b in cell.batches {render.batch_remove(resident.app.renderer,b.handle)}}
    crown_release(resident,cell.crown)
    cell.crown={}
    impostors_free(&resident.impostors,&cell.impostors)
    delete(cell.batches);delete(cell.near);delete(cell.bands)
    cell.batches,cell.near,cell.bands=nil,nil,nil
    cell.built=false
}

@(private)
resident_owner_free :: proc(resident:^Foliage_Resident,owner:^Resident_Owner) {
    for &cell in owner.cells {resident_cell_free(resident,&cell)}
    delete(owner.cells);delete(owner.looks);delete(owner.ids);delete(owner.types);delete(owner.parts);delete(owner.kinds)
    owner.cells,owner.looks,owner.ids,owner.types,owner.parts,owner.kinds=nil,nil,nil,nil,nil,nil
}

// What the renderer forgot with its batches and every mesh (meshes_clear):
// the cells, with the crowns they share, and the far forms made of those
// meshes, all made again. A batch it forgot is not found again.
@(private)
resident_forget :: proc(resident:^Foliage_Resident) {
    for &owner in resident.owners {
        for &cell in owner.cells {resident_cell_free(resident,&cell)}
        clear(&owner.cells)
        clear(&owner.kinds)
        owner.built=false
    }
    for &kind in resident.kinds {kind_free(resident.app,&kind)}
    clear(&resident.kinds)
    clear(&resident.winds)
    impostor_draw_clear(&resident.impostors)
}

// Lets go of the far forms and the zones of wind no Foliage shows any
// longer, or of all of them.
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
        used:=false
        if !all {for &owner in resident.owners {used||=wind_zone_used(resident.winds[i].zone,&owner)}}
        used||=!all && sway_zone_used(resident,resident.winds[i].zone)
        if !used {unordered_remove(&resident.winds,i)}
    }
}

foliage_resident_free :: proc(resident:^Foliage_Resident) {
    for &owner in resident.owners {resident_owner_free(resident,&owner)}
    clear(&resident.owners)
    resident_sweep(resident,true)
    sways_free(resident)
    if resident.app!=nil {
        for name in ([]string{IMPOSTOR_BUFFER,IMPOSTOR_VISIBLE,IMPOSTOR_DRAW}) {render.buffer_release(resident.app.renderer,resident.world,name)}
    }
    for &prefab in resident.prefabs {delete(prefab.parts)}
    delete(resident.owners);delete(resident.prefabs);delete(resident.kinds);delete(resident.winds);delete(resident.crowns)
    impostor_draw_destroy(&resident.impostors)
    trample_free(resident)
    volume.index_destroy(&resident.zones)
    build_work_destroy(&resident.work)
    resident^={}
}

@(private)
memory_problem :: proc(problems:^core.Problems,e:core.Entity,what:string) {
    core.report(problems,e,"foliage.memory","out of memory for %s; it is tried again: free memory, or give the graph fewer layers or a lower density",what)
}

@(private)
bytes_of :: proc "contextless" (values:[]$T) -> []u8 {return transmute([]u8)runtime.Raw_Slice{raw_data(values),len(values)*size_of(T)}}

// Groups the instances of a cell by look, in one pass: work.order holds the
// indices of those it draws, those of the look of index i from
// work.firsts[i] to work.firsts[i+1], each look in the order they were
// placed, without what the detail thins of the filler (filler_kept);
// work.counts holds how many of each look stand before that. Those of a
// layer without a look are left out.
placed_group :: proc(looks:[]Look,ids:[][2]u32,placed:[]pcg.Placed,thin:f32,work:^Build_Work) -> bool {
    n:=len(looks)
    if resize(&work.firsts,n+1)!=nil || resize(&work.counts,n)!=nil {return false}
    for &first in work.firsts {first=0}
    for &count in work.counts {count=0}
    for p in placed {
        i:=look_index(ids,p.layer)
        if i<0 {continue}
        work.counts[i]+=1
        if filler_kept(looks[i],p.id,thin) {work.firsts[i+1]+=1}
    }
    for i in 1..=n {work.firsts[i]+=work.firsts[i-1]}
    if resize(&work.order,int(work.firsts[n]))!=nil || resize(&work.cursor,n)!=nil {return false}
    copy(work.cursor[:],work.firsts[:n])
    for p,k in placed {
        i:=look_index(ids,p.layer)
        if i<0 || !filler_kept(looks[i],p.id,thin) {continue}
        work.order[work.cursor[i]]=u32(k)
        work.cursor[i]+=1
    }
    return true
}

// An instance as a batch draws it, carried by the frame of its graph.
batch_instance_of :: proc "contextless" (p:pcg.Placed,frame:mm.Transform) -> render.Batch_Instance {
    return render.batch_instance(mm.transform_point(frame,p.position),frame.rotation*p.rotation,p.scale*frame.scale)
}

// Publishes the batches of the cells of each Foliage of the world: those of
// a cell again when what its graph places there changes, its marks or the
// band of one of its layers, all of a Foliage when its frame, its values or
// its source change, and all when the renderer forgets its batches or a mesh
// or prefab they show changes. The rows their materials derive stay while
// the batches live (render_sync keeps them), so a stable frame changes
// nothing. The cells are those the graph generated, which it keeps near the
// streaming sources; in which band each layer of them is is chosen again
// when the sources move; the Detail of the graphics settings scales the
// distances and thins the filler (FOLIAGE_DETAIL).
@(step="late",loops="game editor",stage="end")
foliage_render :: proc(
    resident:^Foliage_Resident,data:core.Ref(pcg.Pcg_Data),generated:core.Ref(pcg.Pcg_Generated),marks:core.Ref(Foliage_Marks),
    foliages:^core.Table(Foliage,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),kept:^core.Table(scene.Far_Kept,.Read),
    sources:core.Ref(scene.Streaming_Sources),graphics:render.Graphics_Settings,id:core.World_Id,app:^host.App,problems:^core.Problems,
) {
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
            for owner in resident.owners {for look in owner.looks {all||=look.asset==change.id}}
        }
        resident.structure=a.structure
        if all {
            // A mesh, material or prefab they show changed: every cell is
            // built again, and what is made of them, as any cooking.
            for &prefab in resident.prefabs {delete(prefab.parts)}
            clear(&resident.prefabs)
            for &owner in resident.owners {
                for &cell in owner.cells {resident_cell_free(resident,&cell)}
                clear(&owner.kinds)
                owner.built=false
            }
            resident_sweep(resident)
        }
    }
    // Owners whose entity left, or whose graph shows another source, take their batches with them.
    for i:=len(resident.owners)-1;i>=0;i-=1 {
        owner:=&resident.owners[i]
        graph,graphed:=core.get(graphs,owner.entity)
        if core.has(foliages,owner.entity) && graphed && graph.source==owner.source {continue}
        resident_owner_free(resident,owner)
        unordered_remove(&resident.owners,i)
        changed=true
    }
    // A load is spread over frames: so many instances and far forms a frame.
    resident.instances_left,resident.kinds_left=INSTANCES_A_FRAME,KINDS_A_FRAME
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        graph,graphed:=core.get(graphs,e)
        if !graphed {
            core.report(problems,e,"foliage.graph","this Foliage draws nothing: its entity has no Pcg_Graph; give it one, whose layers place what it draws")
            continue
        }
        entry:=pcg.data_find(data.ptr,graph.source)
        world,placed:=core.get(worlds,e)
        gen:=pcg.generated_graph(generated.ptr,e)
        if entry==nil || !placed || gen==nil || len(entry.source.compiled)!=len(entry.source.layers) {continue}
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
                core.report(problems,e,"foliage.owners","this Foliage is not drawn: a world draws at most 65536 Foliage at once; join the layers of the same place into one source")
                continue
            }
            if _,err:=append(&resident.owners,Resident_Owner{entity=e,source=graph.source,slot=slot});err!=nil {
                memory_problem(problems,e,"this Foliage, which is not drawn")
                continue
            }
            owner=&resident.owners[len(resident.owners)-1]
        }
        frame:=pcg.graph_frame(graph,world.transform)
        streamed:=sources.ptr!=nil?sources.ptr.revision:0
        far_only:=kept!=nil && core.has(kept,e)
        marking:=marked_owner(marks.ptr,e)
        marked:=marking!=nil?marking.hash:0
        if owner.far_only!=far_only {owner.built=false}
        same_graph:=owner.revision==gen.revision && owner.wants==gen.wants && owner.count==len(gen.cells)
        if owner.built && !owner.pending && owner.epoch==entry.epoch && owner.loads==entry.loads && owner.foliage==f && owner.transform==frame && same_graph && owner.sources==streamed && owner.marked==marked && (owner.zones==resident.zones_revision || !owner.sways) {continue}
        if resident.instances_left<=0 && owner.built {continue}
        owner.far_only=far_only
        owner_publish(resident,owner,f,entry,gen,frame,marking,sources.ptr,id,app,problems)
        changed=true
    }
    if changed {
        resident_sweep(resident)
        impostor_rows_build(resident)
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

// The looks of the layers of the source of an owner, and how each is drawn:
// the batch description of each of its parts and its far form, made the
// first time a layer shows its asset.
@(private)
types_draw :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,f:Foliage,entry:^pcg.Pcg_Data_Entry,assets:^host.Assets,renderer:^render.Renderer,job_system:^jobs.Job_System,allocator:runtime.Allocator,problems:^core.Problems) -> bool {
    clear(&owner.types);clear(&owner.parts);clear(&owner.kinds)
    owner.sways=false
    if !looks_make(&owner.looks,&entry.source,f,assets) || !looks_ids(owner.looks[:],&owner.ids) {return false}
    name,other:[base.ASSET_ID_TEXT]u8
    distance:=resident.detail[1]
    for &look in owner.looks {
        draw:=Type_Draw{first=len(owner.parts),kind=-1}
        pieces:[]Prefab_Part
        single:=[1]Prefab_Part{{renderer={mesh=look.asset,shadows=look.casts_shadow},placement=1}}
        switch {
        case look.asset=={}:
        case !look.prefab: pieces=single[:]
        case:
            prefab:=resident_prefab(resident,assets,look.asset)
            if prefab==nil {
                memory_problem(problems,owner.entity,"the prefab of a layer of this Foliage, which is not drawn")
                owner.pending=true
                break
            }
            if !prefab.read || len(prefab.parts)==0 {
                core.report(problems,owner.entity,"foliage.prefab","layer %d of source %s places prefab %s, which is not loaded or has no Mesh_Renderer under a single root; give the layer a prefab with meshes, or a mesh",look.layer,host.assets_name(assets,entry.id,&name),host.assets_name(assets,look.asset,&other))
            }
            pieces=prefab.parts[:]
            look.casts_shadow=false
            for piece in pieces {look.casts_shadow||=piece.renderer.shadows}
        }
        settled:=true
        fade,cull:=mesh_distances(look,false)
        fade,cull=fade*distance,cull*distance
        for piece in pieces {
            settled&&=render.mesh_renderer_settled(assets,piece.renderer)
            desc,ok:=render.batch_desc(assets,piece.renderer)
            if !ok {
                core.report(problems,owner.entity,"foliage.mesh","layer %d of source %s places mesh %s, which is not loaded; give the layer a .mesh or a prefab of the assets",look.layer,host.assets_name(assets,entry.id,&name),host.assets_name(assets,piece.renderer.mesh,&other))
                continue
            }
            desc.flags={}
            if piece.renderer.shadows {desc.flags+={.Casts_Shadow}}
            if look.ray_visible {desc.flags+={.Ray_Visible}}
            desc.fade_distance,desc.cull_distance=fade,cull
            desc.object_id=u64(owner.entity)
            part:=Part_Draw{desc=desc,placement=piece.placement,identity=piece.placement==1}
            low,high,known:=render.mesh_bounds(renderer,desc.mesh)
            // Metres from where its largest instance stands to its farthest point.
            size:=linalg.length(linalg.max(linalg.abs(low),linalg.abs(high)))*look.scale[1]*max(look.height[1],1)
            // The hook bends every part where bodies trampled it (y), sways it
            // in the wind (x) and flutters its leaves (z); the views cull it by
            // boxes that hold how far all move it, and the maps near the eye by
            // how far it sways.
            part.desc.vertex=hook_vertex(look)
            if known {
                part.desc.reach=hook_reach(look,max(high.y,0)*look.scale[1]*max(look.height[1],1))
                part.desc.sway=shadow_sway(look,high.y,size) if piece.renderer.shadows else 0
                owner.sways||=part.desc.sway>0
            }
            append(&owner.parts,part)
        }
        draw.count=len(owner.parts)-draw.first
        key:Kind_Key
        if type_far(look) && draw.count>0 {
            parts:=owner.parts[draw.first:][:draw.count]
            key={look.asset,kind_frame(renderer,look,parts)}
            draw.kind=kind_ensure(resident,assets,renderer,job_system,allocator,key,parts,settled,problems,owner.entity)
            if draw.kind>=0 && kind_ready(&resident.kinds[draw.kind]) {
                draw.far=true
                fade,cull=mesh_distances(look,true)
                fade,cull=fade*distance,cull*distance
                draw.reach=cull
                for &part in owner.parts[draw.first:][:draw.count] {part.desc.fade_distance,part.desc.cull_distance=fade,cull}
            }
        }
        append(&owner.kinds,key)
        append(&owner.types,draw)
    }
    return true
}

// The box of a cell in the frame of its graph, as residency measures it.
@(private)
cell_box :: proc "contextless" (cell_size:f32,coord:[2]i32) -> (low,high:[3]f32) {
    corner:=pcg.cell_corner(cell_size,coord)
    return {corner.x,-pcg.POSITION_MAX,corner.z},{corner.x+cell_size,pcg.POSITION_MAX,corner.z+cell_size}
}

@(private)
coord_before :: proc "contextless" (a,b:[2]i32) -> bool {return a.y<b.y || a.y==b.y && a.x<b.x}

// The batches of one Foliage: those of its cells that changed, or whose
// layers changed band, or of all of them, the nearest first within the
// budget of the frame; a cell its graph no longer generates lets go of its
// batches and its impostors.
@(private)
owner_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,f:Foliage,entry:^pcg.Pcg_Data_Entry,gen:^pcg.Generated_Graph,transform:mm.Transform,marking:^Marked_Owner,sources:^scene.Streaming_Sources,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    all:=!owner.built || owner.epoch!=entry.epoch || owner.loads!=entry.loads || owner.foliage!=f || owner.transform!=transform
    retype:=all || owner.pending
    matched:=!all && owner.revision==gen.revision && owner.wants==gen.wants && owner.count==len(gen.cells)
    owner.epoch,owner.loads,owner.foliage,owner.transform,owner.source=entry.epoch,entry.loads,f,transform,entry.id
    owner.revision,owner.wants,owner.count=gen.revision,gen.wants,len(gen.cells)
    owner.marked=marking!=nil?marking.hash:0
    owner.sources=sources!=nil?sources.revision:0
    rezone:=owner.zones!=resident.zones_revision && owner.sways
    owner.zones=resident.zones_revision
    cell_size:=entry.source.info.cell_size
    work:=&resident.work
    owner.pending=false
    if retype && !types_draw(resident,owner,f,entry,app.assets,app.renderer,&app.jobs,app.allocator,problems) {
        memory_problem(problems,owner.entity,"the layers of this Foliage")
        owner.pending,owner.built=true,false
        return
    }
    // Its cells wait for the far forms of its layers.
    for draw,i in owner.types {
        if type_far(owner.looks[i]) && draw.count>0 && draw.kind<0 {
            owner.pending=true
            if all {owner.built=false}
            return
        }
    }
    placed:=mm.transform_matrix(transform)
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
    if !matched {
        // The cells the graph built and those held, both in the order of their coordinates.
        clear(&work.cells)
        j:=0
        for &cell in gen.cells {
            if !cell.built {continue}
            for j<len(owner.cells) && coord_before(owner.cells[j].coord,cell.coord) {resident_cell_free(resident,&owner.cells[j]);j+=1}
            held:=Resident_Cell{coord=cell.coord}
            if j<len(owner.cells) && owner.cells[j].coord==cell.coord {held=owner.cells[j];j+=1}
            append(&work.cells,held)
        }
        for ;j<len(owner.cells);j+=1 {resident_cell_free(resident,&owner.cells[j])}
        owner.cells,work.cells=work.cells,owner.cells
        clear(&work.cells)
    }
    clear(&work.builds)
    for &held,k in owner.cells {
        cell:=pcg.generated_cell(gen,held.coord)
        if cell==nil {continue}
        low,high:=cell_box(cell_size,held.coord)
        // Each layer with a far form draws its mesh within its reach of a source, and its crown past it.
        banded:=len(held.near)!=len(owner.types) || len(held.bands)!=len(owner.types)
        if banded && (resize(&held.near,len(owner.types))!=nil || resize(&held.bands,len(owner.types))!=nil) {
            memory_problem(problems,owner.entity,"a cell of this Foliage, which keeps what it showed")
            held.stale,owner.pending=true,true
            continue
        }
        for draw,i in owner.types {
            was:=held.near[i]
            held.near[i]=!owner.far_only && (!draw.far || scene.resident(scene.box_near(&work.bands[i],low,high)/band_scale(held.bands[i]),was))
            banded||=held.near[i]!=was
        }
        was_far:=held.far
        held.far=crown_reach>0 && !scene.resident(scene.box_near(&work.cell_band,low,high),!was_far)
        banded||=held.far!=was_far
        _,marked_hash:=marked_cell(marking,held.coord)
        // Where the zones of wind changed, a cell whose zone is another sways in that one.
        rezoned:=rezone && held.built && wind_zone_at(resident,held.at)!=held.zone
        if all || banded || rezoned || held.stale || !held.built || held.revision!=cell.revision || held.marked!=marked_hash {
            append(&work.builds,scene.Resident_Order{near=cell.near,index=u32(k)})
        }
    }
    taken:=builds_take(work.builds[:],gen,owner.cells[:],&resident.instances_left)
    for order in work.builds[taken:] {
        owner.cells[order.index].stale=true
        owner.pending=true
    }
    for order in work.builds[:taken] {
        held:=&owner.cells[order.index]
        cell:=pcg.generated_cell(gen,held.coord)
        marks,marked_hash:=marked_cell(marking,held.coord)
        held.revision,held.marked,held.built,held.stale=cell.revision,marked_hash,true,false
        cell_publish(resident,owner,held,cell.placed[:],marks,id,app,problems)
    }
    owner.built=true
    resident.stats.builds+=1
    name:[base.ASSET_ID_TEXT]u8
    for draw,i in owner.types {
        if draw.error<=PREFAB_ERROR {continue}
        look:=&owner.looks[i]
        core.report(problems,owner.entity,"foliage.prefab_transform","the parts of prefab %s of layer %d are drawn with up to %d%% of their transform left out: an instance of a batch holds a scale along each of its axes, without shear or mirror; give the parts of the prefab, and the Foliage entity, no scale under a rotation of their parents and no negative scale",host.assets_name(app.assets,look.asset,&name),look.layer,int(draw.error*100+0.5))
    }
}

// Orders the cells to build nearest first and takes those the instances left
// give room for, each by its instances and at least CELL_COST_MIN: how many.
// One goes while some are left, so a cell past the whole budget is built too.
builds_take :: proc(builds:[]scene.Resident_Order,gen:^pcg.Generated_Graph,cells:[]Resident_Cell,left:^int) -> (taken:int) {
    slice.sort_by(builds,proc(a,b:scene.Resident_Order) -> bool {return a.near<b.near || a.near==b.near && a.index<b.index})
    for order in builds {
        if left^<=0 {break}
        cell:=pcg.generated_cell(gen,cells[order.index].coord)
        left^-=max(cell!=nil?len(cell.placed):0,CELL_COST_MIN)
        taken+=1
    }
    return
}

// What a frame builds of the foliage at most: instances of the cells (at
// least CELL_COST_MIN a cell), the nearest first, and far forms of the
// assets layers show (each draws its impostor). The rest waits for the
// frames that follow; the cells of a Foliage wait for the far forms of its
// layers.
INSTANCES_A_FRAME :: 1 << 16
CELL_COST_MIN :: 1024 // instances a cell costs at least: the batches it publishes
KINDS_A_FRAME :: 1

// How much of the transform of a part may be left out before it is a problem.
PREFAB_ERROR :: f32(0.01)

// The batches of one cell: per look and part with instances, its mesh while
// it is near, and its crown past that; and the impostors of its looks with a
// far form. The density band of each look is chosen here, once. It reuses
// the handles the cell had for the same roles.
@(private)
cell_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,placed:[]pcg.Placed,marks:[]Marked,id:core.World_Id,app:^host.App,problems:^core.Problems) {
    work:=&resident.work
    if !placed_group(owner.looks[:],owner.ids[:],placed,resident.detail[0],work) || resize(&work.shown,len(placed))!=nil {
        memory_problem(problems,owner.entity,"a cell of this Foliage, which keeps what it showed")
        held.stale,owner.pending=true,true
        return
    }
    transform:=owner.transform
    owner_matrix:=mm.transform_matrix(transform)
    for p,k in placed {work.shown[k]=marked_color(marks,p.id)}
    for &band,i in held.bands {band=density_band(int(work.counts[i]),owner.looks[i].expected)}
    // Its zone of wind is the one at the middle of its instances.
    if len(placed)>0 {
        sum:=[3]f64{}
        for p in placed {at:=mm.transform_point(transform,p.position);sum+={f64(at.x),f64(at.y),f64(at.z)}}
        sum/=f64(len(placed))
        held.at={f32(sum.x),f32(sum.y),f32(sum.z)}
    }
    held.zone=wind_zone_at(resident,held.at)
    clear(&work.batches)
    clear(&work.impostors)
    publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,layer,part:u32,role:Batch_Role,desc:render.Batch_Desc,id:core.World_Id,app:^host.App,problems:^core.Problems) {
        work:=&resident.work
        if len(work.instances)==0 {return}
        handle:render.Batch_Handle
        for &b in held.batches {if b.layer==layer && b.part==part && b.role==role && b.handle!=0 {handle,b.handle=b.handle,0;break}}
        // Colors only for a batch where some instance has a look of its own.
        colors:[]u32
        for color in work.colors {if color!=render.BATCH_COLOR_PLAIN {colors=work.colors[:];break}}
        next,error:=render.batch_set(app.renderer,id,handle,desc,work.instances[:],colors)
        if error!="" {
            if handle!=0 {render.batch_remove(app.renderer,handle)}
            core.report(problems,owner.entity,"foliage.batch","the foliage of cell %v, layer %d, is not drawn: %s",held.coord,layer,error)
            return
        }
        append(&work.batches,Resident_Batch{layer=layer,part=part,role=role,handle=next})
        resident.stats.batches+=1
        resident.stats.instances+=u64(len(work.instances))
    }
    for &draw,i in owner.types {
        look:=&owner.looks[i]
        order:=work.order[work.firsts[i]:work.firsts[i+1]]
        if len(order)==0 {continue}
        // Of a section that is not loaded, only what has a far form, and only that form.
        if owner.far_only && !draw.far {continue}
        near:=i>=len(held.near) || held.near[i]
        scale:=band_scale(held.bands[i])
        for &part,k in owner.parts[draw.first:][:draw.count] {
            if !near {break}
            clear(&work.instances)
            clear(&work.colors)
            for at in order {
                p:=placed[at]
                append(&work.colors,work.shown[at])
                if part.identity {append(&work.instances,batch_instance_of(p,transform));continue}
                instance,error:=part_instance(p,owner_matrix,part.placement)
                draw.error=max(draw.error,error)
                append(&work.instances,instance)
            }
            desc:=part.desc
            // A dense cell gives way to the far form sooner.
            if draw.far {desc.fade_distance,desc.cull_distance=desc.fade_distance*scale,desc.cull_distance*scale}
            // What casts swaying shadows sways with the wind of the zone of the cell.
            if desc.sway>0 {desc.wind=wind_zone_take(resident,held.zone,held.at)}
            publish(resident,owner,held,look.layer,u32(k),ROLE_MESH,desc,id,app,problems)
        }
        if !draw.far || draw.kind<0 {continue}
        kind:=&resident.kinds[draw.kind]
        row:=owner.slot<<16 | u32(i*DENSITY_BANDS)+u32(held.bands[i])
        for at in order {
            b:=batch_instance_of(placed[at],transform)
            append(&work.impostors,Impostor_Instance{position=b.position,rotation=b.rotation,scale=b.scale,row=row,color=work.shown[at]})
        }
        // Past its mesh, rays meet its crown in place of its leaves; past
        // the crowns of its instances, the crown of the cell.
        if near || !(look.casts_shadow || look.ray_visible) || kind.crown=={} || held.far {continue}
        desc,ok:=render.batch_desc(app.assets,{mesh=kind.crown})
        if !ok {continue}
        desc.flags=crown_flags(look)
        desc.tint=kind.albedo
        desc.object_id=u64(owner.entity)
        clear(&work.instances)
        clear(&work.colors)
        for at in order {append(&work.instances,batch_instance_of(placed[at],transform))}
        publish(resident,owner,held,look.layer,0,ROLE_CROWN,desc,id,app,problems)
    }
    if !impostors_set(&resident.impostors,&held.impostors,work.impostors[:]) {
        memory_problem(problems,owner.entity,"the impostors of a cell of this Foliage, which keeps what it showed")
        held.stale,owner.pending=true,true
    }
    previous:=held.crown
    held.crown={}
    cell_crown_publish(resident,owner,held,placed,id,app.assets,app.renderer,problems)
    // What the cell no longer shows goes.
    for b in held.batches {if b.handle!=0 {render.batch_remove(app.renderer,b.handle)}}
    clear(&held.batches)
    append(&held.batches,..work.batches[:])
    crown_release(resident,previous)
    resident.stats.cells+=1
}

// The cell, layer, part and role of a batch of a Foliage of the world.
resident_batch_find :: proc(resident:^Foliage_Resident,handle:render.Batch_Handle) -> (entity:core.Entity,coord:[2]i32,layer,part:u32,role:Batch_Role,found:bool) {
    if resident==nil || handle==0 {return}
    for &owner in resident.owners {
        for &cell in owner.cells {
            for b in cell.batches {if b.handle==handle {return owner.entity,cell.coord,b.layer,b.part,b.role,true}}
        }
    }
    return
}

// The instance of its graph that instance `index` of a batch of a layer
// draws, as a pick names it: what pcg_suppress_request and foliage_promote
// take. False for a batch of no layer (a cell crown), or one not drawn.
foliage_picked :: proc(resident:^Foliage_Resident,generated:^pcg.Pcg_Generated,handle:render.Batch_Handle,index:int) -> (instance:pcg.Pcg_Instance,ok:bool) {
    e,coord,layer,_,role:=resident_batch_find(resident,handle) or_return
    if role==ROLE_CELL_CROWN {return}
    cell:=pcg.generated_cell(pcg.generated_graph(generated,e),coord)
    if cell==nil {return}
    for &owner in resident.owners {
        if owner.entity!=e {continue}
        id:=layer_instance(owner.looks[:],owner.ids[:],cell.placed[:],layer,index,resident.detail[0]) or_return
        return {e,coord,id},true
    }
    return
}

// The id of instance `index` of the batches of a layer of a cell, which
// draw its instances in their order but those the detail thins (filler_kept).
layer_instance :: proc "contextless" (looks:[]Look,ids:[][2]u32,placed:[]pcg.Placed,layer:u32,index:int,thin:f32) -> (id:u64,ok:bool) {
    i:=look_index(ids,layer)
    if i<0 || index<0 {return}
    n:=0
    for p in placed {
        if p.layer!=layer || !filler_kept(looks[i],p.id,thin) {continue}
        if n==index {return p.id,true}
        n+=1
    }
    return
}

// Asks to take an instance out of its graph and spawn in its place the
// prefab its layer places, as a scene entity with its own collider, look and
// wind: a tree that falls, what the editor edits by hand.
foliage_promote :: proc(requests:^pcg.Pcg_Promote_Requests,plant:pcg.Pcg_Instance) {pcg.pcg_promote(requests,plant)}

// The batches of the foliage of a world that is freed go with it, and what
// it made: far forms and the buffer of its impostors.
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
// where it stands, and the crown of its look. Two cells with the same key
// make the same crown.
crown_key :: proc(placed:[]pcg.Placed,crowns:[]Crown_Triangles) -> u64 {
    key:u64
    for c,i in crowns {
        if len(c.indices)==0 {continue}
        key=base.hash64(bytes_of(c.positions),base.hash64(bytes_of(c.indices),key~u64(i)))
    }
    for p in placed {
        values:=[?]f32{transmute(f32)p.layer,p.position.x,p.position.y,p.position.z,real(p.rotation),imag(p.rotation),jmag(p.rotation),kmag(p.rotation),p.scale.x,p.scale.y,p.scale.z}
        key=base.hash64(bytes_of(values[:]),key)
    }
    return key
}

// The crown of a cell far away: one batch of one instance whose mesh is the
// crown of the crowns of its instances that cast shadows (cell_crown_build),
// made again with its batches. Called with the instances of the cell
// grouped (cell_publish).
@(private)
cell_crown_publish :: proc(resident:^Foliage_Resident,owner:^Resident_Owner,held:^Resident_Cell,shown:[]pcg.Placed,id:core.World_Id,assets:^host.Assets,renderer:^render.Renderer,problems:^core.Problems) {
    work:=&resident.work
    held.crown={}
    if !held.far || assets==nil {return}
    clear(&work.crowns)
    if resize(&work.crowns,len(owner.types))!=nil {
        memory_problem(problems,owner.entity,"the crown of a cell of this Foliage")
        held.stale,owner.pending=true,true
        return
    }
    // What rays meet of each of its looks, in the mean color of their instances.
    flags:render.Batch_Flags
    tint:[3]f32
    weight:f32
    for draw,i in owner.types {
        look:=&owner.looks[i]
        if !draw.far || draw.kind<0 || !(look.casts_shadow || look.ray_visible) || i<len(held.near) && held.near[i] {continue}
        kind:=&resident.kinds[draw.kind]
        work.crowns[i]={kind.crown_positions,kind.crown_indices}
        if len(kind.crown_indices)==0 {continue}
        flags+=crown_flags(look)
        count:=f32(work.firsts[i+1]-work.firsts[i])
        tint+=kind.albedo*count
        weight+=count
    }
    if flags=={} || weight<=0 {return}
    // Each instance that gives the crown, with the index of its look for its layer.
    placed:=make([dynamic]pcg.Placed,0,len(shown),context.temp_allocator)
    for i in 0..<len(owner.types) {
        if len(work.crowns[i].indices)==0 {continue}
        for at in work.order[work.firsts[i]:work.firsts[i+1]] {
            p:=shown[at]
            p.layer=u32(i)
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
        crown,made=host.assets_mesh_generate(assets,geom.mesh_buffer_view(&shape),options={no_lods=true,label="foliage crown"})
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
    transform:=owner.transform
    instance:=[1]render.Batch_Instance{render.batch_instance(transform.position,transform.rotation,transform.scale)}
    next,error:=render.batch_set(renderer,id,handle,desc,instance[:])
    if error!="" {
        if handle!=0 {render.batch_remove(renderer,handle)}
        core.report(problems,owner.entity,"foliage.batch","the crown of foliage cell %v is not traced: %s",held.coord,error)
        return
    }
    append(&work.batches,Resident_Batch{layer=max(u32),role=ROLE_CELL_CROWN,handle=next})
    resident.stats.batches+=1
    resident.stats.instances+=1
}
