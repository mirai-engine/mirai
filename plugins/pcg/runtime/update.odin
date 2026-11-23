package pcg

import "base:runtime"
import "core:slice"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:std/base"
import "mirai:std/jobs"
import mm "mirai:std/math"

// What each graph places in the cells it wants, kept by world and never
// copied with it: a world that is copied or replaced places them again from
// the same inputs, and gets the same. pcg_update builds the cells whose
// inputs changed (their source, seed and frame, their ground tile, what is
// suppressed in them, the zones and the Volume of the graph), the nearest
// the sources first, GENERATE_POINTS points a frame (its ticks and itself
// together), in jobs that end within the call; the others wait for the next
// frames and keep what they placed. A cell keeps its room from build to
// build, so a stable frame allocates nothing.

GENERATE_POINTS :: 1 << 18 // candidate points a frame builds, at least one cell
CELL_COST_MIN :: 64        // points a cell counts for, however few it scatters

@(storage,host,by_world,free="pcg_generated_free")
Pcg_Generated :: struct {
    graphs:[dynamic]Generated_Graph,
    workers:[dynamic]Pcg_Scratch, // by job worker
    spent:int,                    // points built in the frame so far
    seen:[4]core.Seen,            // the tables of Pcg_Zone, Volume, Spline and Id the zones and spans are made of
    zones:u64,                    // raised when the zones or spans change
    zones_hash:u64,               // of what they were
    allocator:runtime.Allocator,
    stats:Pcg_Generated_Stats,
}
Pcg_Generated_Stats :: struct {builds,cells,placed:u64}
Generated_Graph :: struct {
    entity:core.Entity,
    key:u64,        // of what all its cells are built from: its source, seed, frame, zones and Volume
    ground:u32,     // the revision of its ground owner, and of the cells it wants, when its cells were last compared
    wants:u32,
    suppressed:u64, // the hash of what was taken out of it then
    cells:[dynamic]Generated_Cell, // in the order of their coordinates
    revision:u32,   // raised when one of its cells places otherwise
    pending:bool,   // some cells wait for the budget of a frame
}
Generated_Cell :: struct {
    coord:[2]i32,
    key:u64,        // that of its graph when it was built
    ground:u32,     // the revision of its tile then
    suppressed:u64, // the hash of what was taken out of it then
    built:bool,
    revision:u32,   // raised each time it places otherwise
    near:f32,
    placed:[dynamic]Placed,
    occupied:Occupancy, // with Micro layers in its source: where its Macro and Meso points stand, suppressed ones too
    occupied_hash:u64,  // of occupied; 0 when nothing is covered
}

pcg_generated_free :: proc(g:^Pcg_Generated) {
    for &graph in g.graphs {graph_cells_free(&graph)}
    for &w in g.workers {scratch_destroy(&w)}
    delete(g.graphs);delete(g.workers)
    g^={}
}

@(private)
graph_cells_free :: proc(graph:^Generated_Graph) {
    for &cell in graph.cells {delete(cell.placed)}
    delete(graph.cells)
    graph.cells={}
}

generated_graph :: proc "contextless" (g:^Pcg_Generated,e:core.Entity) -> ^Generated_Graph {
    if g==nil {return nil}
    for &graph in g.graphs {if graph.entity==e {return &graph}}
    return nil
}

// The cell of a coordinate a graph built; nil when it is not built.
generated_cell :: proc "contextless" (graph:^Generated_Graph,coord:[2]i32) -> ^Generated_Cell {
    if graph==nil {return nil}
    at:=coord_lower(graph.cells[:],coord)
    if at<len(graph.cells) && graph.cells[at].coord==coord && graph.cells[at].built {return &graph.cells[at]}
    return nil
}

// What a cell of a graph places, in the frame of the graph (graph_frame), and
// the revision it was built at: what is built from it compares it.
pcg_cell :: proc "contextless" (g:^Pcg_Generated,e:core.Entity,coord:[2]i32) -> (placed:[]Placed,revision:u32,ok:bool) {
    cell:=generated_cell(generated_graph(g,e),coord)
    if cell==nil {return}
    return cell.placed[:],cell.revision,true
}

// The zones that give masks in the world, in the order they apply, and the
// spans of the Splines of all the zones, by graph frame later.
Zone_Inputs :: struct {
    zones:[dynamic]Pcg_Zone_Placed,
    splines:[dynamic]Zone_Spline,
}
Zone_Spline :: struct {entity:u64,channel:u32,pose:mm.Transform,points:[]mm.Path_Point}

zone_inputs :: proc(zones:^core.Table(Pcg_Zone,$A),at:volume.Where,ids:^core.Table(core.Id,$B),problems:^core.Problems) -> (z:Zone_Inputs) {
    z.zones=make([dynamic]Pcg_Zone_Placed,context.temp_allocator)
    z.splines=make([dynamic]Zone_Spline,context.temp_allocator)
    if zones==nil {return}
    for row in 0..<core.count(zones) {
        e:=core.entity_at(zones,row)
        zone:=core.at(zones,row)
        if zone.exclude {continue}
        if v,pose,outline,ok:=volume.placed(at,e);ok {
            weight:=zone.weight>0?min(zone.weight,1):0
            append(&z.zones,Pcg_Zone_Placed{region={v,pose,outline},zone=zone.zone,channel=zone.channel,weight=weight,box=volume.bounds(v,pose,outline)})
        }
        if at.splines==nil || !core.has(at.splines,e) {continue}
        world,placed:=core.get(at.worlds,e)
        if !placed {continue}
        id:=core.id_of(ids,e)
        if id==0 {
            core.report(problems,e,"pcg.grammar","the Spline of this Pcg_Zone places no grammar: the entity has no Id, which names its modules; give it an Id, as the entities of a scene have")
            continue
        }
        points:=volume.spline_outline(at.splines,e)
        append(&z.splines,Zone_Spline{u64(id),zone.channel,world.transform,points})
    }
    slice.sort_by(z.zones[:],proc(a,b:Pcg_Zone_Placed) -> bool {
        if a.zone.priority!=b.zone.priority {return a.zone.priority<b.zone.priority}
        return volume.size(a.region.volume,a.region.pose,a.region.outline)>volume.size(b.region.volume,b.region.pose,b.region.outline)
    })
    return
}

@(private)
zone_inputs_hash :: proc(z:^Zone_Inputs) -> u64 {
    h:=base.HASH_SEED
    for &zone in z.zones {
        Fixed :: struct {v:volume.Volume,pose:mm.Transform,zone:volume.Zone,channel:u32,weight:f32}
        fixed:=Fixed{zone.region.volume,zone.region.pose,zone.zone,zone.channel,zone.weight}
        h=base.hash64(([^]byte)(&fixed)[:size_of(fixed)],h)
        h=base.hash64(([^]byte)(raw_data(zone.region.outline))[:len(zone.region.outline)*size_of(mm.Path_Point)],h)
    }
    for &sp in z.splines {
        Fixed :: struct {entity:u64,channel:u32,pose:mm.Transform}
        fixed:=Fixed{sp.entity,sp.channel,sp.pose}
        h=base.hash64(([^]byte)(&fixed)[:size_of(fixed)],h)
        h=base.hash64(([^]byte)(raw_data(sp.points))[:len(sp.points)*size_of(mm.Path_Point)],h)
    }
    return h
}

// The spans of the zone splines in the frame of a graph.
@(private)
frame_spans :: proc(z:^Zone_Inputs,frame_local:mm.Mat4) -> []Pcg_Span {
    spans:=make([dynamic]Pcg_Span,context.temp_allocator)
    for sp in z.splines {
        for i in 1..<len(sp.points) {
            a:=mm.mat4_point(frame_local,mm.transform_point(sp.pose,sp.points[i-1].position))
            b:=mm.mat4_point(frame_local,mm.transform_point(sp.pose,sp.points[i].position))
            append(&spans,Pcg_Span{entity=sp.entity,span=u32(i-1),channel=sp.channel,a=a,b=b})
        }
    }
    return spans[:]
}

// The points a cell of a source counts for in the budget.
@(private)
cell_cost :: proc "contextless" (s:^Pcg_Source,share:f32) -> int {
    cost:=0
    for u in s.units {cost+=unit_count_max(s,u,share)*(u.reach>0?9:1)}
    for l in s.layers {
        if l.kind!=.Cascade {continue}
        if parent,_:=source_layer(s,l.parent_layer);parent!=nil {
            cost+=int(f64(parent.density)*f64(s.info.cell_size)*f64(s.info.cell_size)*f64(share)*f64(l.density))+1
        }
    }
    return max(cost,CELL_COST_MIN)
}

@(private)
Build :: struct {
    graph,cell:int, // indices in Pcg_Generated
    input:Pcg_Cell_Input,
    ground:u32,     // the revision of its tile
    suppressed:u64, // the hash of what is taken out of it
    near:f32,
    ok:bool,
}

@(private)
build_before :: proc(a,b:Build) -> bool {
    if a.near!=b.near {return a.near<b.near}
    if a.graph!=b.graph {return a.graph<b.graph}
    return coord_before(a.input.coord,b.input.coord)
}

@(step="fixed frame",loops="game editor",stage="simulate")
pcg_update :: proc(
    generated:^Pcg_Generated,data:core.Ref(Pcg_Data),grounds:core.Ref(Pcg_Ground),suppressions:core.Ref(Pcg_Suppressions),
    graphs:^core.Table(Pcg_Graph,.Read),zones:^core.Table(Pcg_Zone,.Read),ids:^core.Table(core.Id,.Read),at:volume.Where,
    frame:core.Frame_Time,job_system:^jobs.Job_System,allocator:runtime.Allocator,problems:^core.Problems,
) {
    g:=generated
    defer if frame.phase!=.Fixed {g.spent=0}
    if g.allocator.procedure==nil {g.allocator=allocator}
    context.allocator=g.allocator
    // The graphs that are gone go with their cells.
    for i:=len(g.graphs)-1;i>=0;i-=1 {
        if core.has(graphs,g.graphs[i].entity) {continue}
        graph_cells_free(&g.graphs[i])
        unordered_remove(&g.graphs,i)
    }
    inputs_made:=false
    z:Zone_Inputs
    // A table they are made of changed: they changed when what they hold did.
    if core.touched(zones,&g.seen[0]) | core.touched(at.volumes,&g.seen[1]) | core.touched(at.splines,&g.seen[2]) | core.touched(ids,&g.seen[3]) {
        z,inputs_made=zone_inputs(zones,at,ids,problems),true
        if hash:=zone_inputs_hash(&z);hash!=g.zones_hash {g.zones_hash=hash;g.zones+=1}
    }
    if data.ptr==nil || grounds.ptr==nil {return}
    builds:=make([dynamic]Build,context.temp_allocator)
    for row in 0..<core.count(graphs) {
        e:=core.entity_at(graphs,row)
        graph_value:=core.at(graphs,row)
        entry:=data_find(data.ptr,graph_value.source)
        owner:=ground_owner(grounds.ptr,e)
        world,placed:=core.get(at.worlds,e)
        if entry==nil || owner==nil || !placed {continue}
        s:=&entry.source
        if len(s.compiled)!=len(s.layers) {continue}
        frame_pose:=graph_frame(graph_value,world.transform)
        frame_local,inverted:=mm.transform_inverse_matrix(frame_pose)
        if !inverted {continue}
        _,_,domain,domain_hash:=graph_domain(at,e,frame_local)
        seed:=graph_seed(s.info.seed,graph_value.seed)
        key:=base.hash_mix(base.hash_mix(base.hash_mix(base.HASH_SEED,entry.epoch),u64(entry.loads)|u64(seed)<<32),g.zones)
        key=base.hash_mix(key,domain_hash)
        key=base.hash64(([^]byte)(&frame_pose)[:size_of(frame_pose)],key)
        gone:=suppressed_owner(suppressions.ptr,e)
        gone_hash:=gone!=nil?gone.hash:0
        graph:=generated_graph(g,e)
        if graph==nil {
            if _,error:=append(&g.graphs,Generated_Graph{entity=e});error!=nil {
                core.report(problems,e,"pcg.memory","out of memory for what this Pcg_Graph places; it is tried again: free memory")
                continue
            }
            graph=&g.graphs[len(g.graphs)-1]
            graph.pending=true
        }
        if !graph.pending && graph.key==key && graph.ground==owner.revision && graph.wants==owner.cells_revision && graph.suppressed==gone_hash {continue}
        // The cells it wants, each kept with what it placed.
        if graph.wants!=owner.cells_revision || len(graph.cells)!=len(owner.cells) {
            kept:=0
            for cell in graph.cells {
                if _,wanted:=ground_wants(owner,cell.coord);wanted {graph.cells[kept]=cell;kept+=1} else {delete(cell.placed)}
            }
            base.truncate(&graph.cells,kept)
            for want in owner.cells {
                at_cell:=coord_lower(graph.cells[:],want.coord)
                if at_cell<len(graph.cells) && graph.cells[at_cell].coord==want.coord {continue}
                if _,error:=inject_at(&graph.cells,at_cell,Generated_Cell{coord=want.coord,placed=make([dynamic]Placed)});error!=nil {break}
            }
        }
        graph.key,graph.ground,graph.wants,graph.suppressed=key,owner.revision,owner.cells_revision,gone_hash
        graph.pending=false
        if !inputs_made {z=zone_inputs(zones,at,ids,problems);inputs_made=true}
        spans:=frame_spans(&z,frame_local)
        share:=generated_share(s)
        frame_world:=mm.transform_matrix(frame_pose)
        index:=int(uintptr(graph)-uintptr(raw_data(g.graphs)))/size_of(Generated_Graph)
        for &cell,k in graph.cells {
            near,_:=ground_wants(owner,cell.coord)
            cell.near=near
            tile,revision:=ground_cell(owner,cell.coord)
            ids_gone,hash:=suppressed_cell(gone,cell.coord)
            if cell.built && cell.key==key && cell.ground==revision && cell.suppressed==hash {continue}
            if tile.absent {
                // No ground known yet: it waits for its tile, and places nothing.
                if cell.built && (len(cell.placed)>0 || cell.occupied_hash!=0) {clear(&cell.placed);cell.revision+=1;graph.revision+=1}
                cell.occupied,cell.occupied_hash={},0
                cell.built,cell.key,cell.ground,cell.suppressed=true,key,revision,hash
                continue
            }
            input:=Pcg_Cell_Input{source=s,seed=seed,coord=cell.coord,ground=tile,paint=source_cell(s,cell.coord),frame=frame_world,domain=domain,zones=z.zones[:],spans=spans,suppressed=ids_gone,share=share}
            append(&builds,Build{graph=index,cell=k,input=input,ground=revision,suppressed=hash,near=near})
        }
        if share<1 {
            core.report(problems,e,"pcg.cell_points","the densities of the layers of the source of this Pcg_Graph give a cell more than CELL_GENERATED_MAX (%d) points, so each layer places %d%% of its own; lower the densities of its layers",CELL_GENERATED_MAX,int(share*100))
        }
    }
    if len(builds)==0 {return}
    // The nearest first, within the points left in the frame; one goes while some are left.
    slice.sort_by(builds[:],build_before)
    left:=GENERATE_POINTS-g.spent
    taken:=0
    for &b in builds {
        if left<=0 {break}
        cost:=cell_cost(b.input.source,b.input.share)
        left-=cost
        g.spent+=cost
        taken+=1
    }
    for b in builds[taken:] {g.graphs[b.graph].pending=true}
    if taken==0 {return}
    builds_now:=builds[:taken]
    workers:=job_system!=nil?max(jobs.worker_count(job_system),1):1
    for len(g.workers)<workers {
        w:Pcg_Scratch
        if !scratch_init(&w,g.allocator) {
            core.report(problems,core.NONE,"pcg.memory","out of memory for the work of placing cells; they wait: free memory")
            for b in builds_now {g.graphs[b.graph].pending=true}
            return
        }
        append(&g.workers,w)
    }
    Building :: struct {g:^Pcg_Generated,builds:[]Build}
    build :: proc(x:^Building,first,last:int,worker:int) {
        scratch:=&x.g.workers[worker]
        context.allocator=x.g.allocator
        for &b in x.builds[first:last] {
            cell:=&x.g.graphs[b.graph].cells[b.cell]
            clear(&cell.placed)
            b.ok=cell_generate(&b.input,scratch,&cell.placed)
            cell.occupied,cell.occupied_hash=scratch.occupied,scratch.occupied_hash
        }
    }
    building:=Building{g,builds_now}
    if job_system!=nil && workers>1 && len(builds_now)>1 {
        jobs.parallel_for(job_system,jobs.OWNER,len(builds_now),1,build,&building)
    } else {build(&building,0,len(builds_now),jobs.OWNER)}
    for b in builds_now {
        graph:=&g.graphs[b.graph]
        cell:=&graph.cells[b.cell]
        g.stats.builds+=1
        if !b.ok {
            graph.pending=true
            core.report(problems,graph.entity,"pcg.memory","out of memory placing cell %v of this Pcg_Graph; it is tried again: free memory, or lower the densities of its layers",cell.coord)
            continue
        }
        cell.built=true
        cell.key,cell.ground,cell.suppressed=graph.key,b.ground,b.suppressed
        cell.revision+=1
        graph.revision+=1
        g.stats.placed+=u64(len(cell.placed))
    }
}
