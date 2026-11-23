package foliage

import "core:math"
import "core:slice"
import "mirai:core"
import render "mirai:engine/render"
import scene "mirai:engine/scene"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import mm "mirai:std/math"
import pcg "plugins:pcg/runtime"

// The Micro layers of the graphs of the world (grass, small stones, flowers):
// scattered on the GPU, never placed on the CPU nor colliding. A tile is a
// cell of a graph and one of its Micro layers, resident while the streaming
// sources are within the cull distance of the layer. When a tile comes, or
// what it stands on changes (its ground tile, the source, the Macro and Meso
// points that occupy its cell), the CPU gives it the heights of its ground
// tile (pcg.Pcg_Ground) and how much of the density of the layer stands on a
// grid over it (pcg.micro_samples), and the Simulate stage scatters it once
// into its slot of the buffer of the world (foliage_micro_gen.comp). Each
// view culls what the slots hold against its frustum and the depth of the
// scene (foliage_micro_cull.comp) and draws them, a draw a look and Surface
// program, into the G-buffer with the mesh of the layer, bent by the wind as
// the batches are (foliage_micro.vert). A stable frame generates nothing;
// without a renderer, nothing at all is done.

MICRO_SLOTS :: 1024          // tiles a world holds at once
MICRO_LOOKS :: 64            // Micro layers a world draws
MICRO_TILES_A_FRAME :: 8     // tiles generated a frame
MICRO_SIDE_MAX :: 256        // candidates a side of a tile
MICRO_REACH_MAX :: f32(256)  // m from a source a Micro layer never culled shows to
MICRO_INSTANCES_MIN :: 1 << 16
MICRO_INSTANCES :: "foliage micro instances"
MICRO_COUNTS :: "foliage micro counts"
MICRO_VISIBLE :: "foliage micro visible"
MICRO_DRAWS :: "foliage micro draws"
MICRO_PROGRAMS :: 8          // Surface programs of the mesh of a look it draws

// What the shaders read (foliage_micro.slang).
Micro_Instance :: struct {
    place:u32,  // x | z << 16, unorm16 across its cell
    height:f32,
    normal:u32,
    slot:u32,
}
#assert(size_of(Micro_Instance)==16)
Micro_Slot :: struct {
    world:[3][4]f32, // from the space of its cell into the world, relative to the origin
    info:[4]u32,     // first instance, capacity, look, 1 once generated
    cell:[4]f32,     // metres across its cell, the seed of its instances (as bits)
}
Micro_Look_Row :: struct {
    sphere:[4]f32,
    scale:[4]f32,
    turn:[4]f32,
    offset:[4]f32,
    distance:[4]f32,
    mesh:[4]u32, // mesh, clusters, first among those visible, how many fit there
}
Micro_Gen :: struct {
    a:[4]u32, // slot, first instance, candidates a side, samples a side of the heights
    b:[4]u32, // seed, candidates the detail keeps of 2^32, samples a side of the densities
    c:[4]f32, // metres across the cell
}
Micro_Cull :: struct {count:[4]u32}
Micro_Draw :: struct {look,program,mesh,pad:u32}

@(storage,host,by_world,free="foliage_micro_free")
Foliage_Micro :: struct {
    app:^host.App,
    world:core.World_Id,
    looks:[dynamic]Micro_Look,
    tiles:[dynamic]Micro_Tile,   // by slot; one that is not used is free
    blocks:[dynamic]Micro_Block, // of the buffer of instances
    end:u32,                     // instances the blocks span
    capacity:u32,                // instances the buffer holds
    visible:u32,                 // instances the visible lists of the looks hold together
    inputs:u64,                  // the hash of what the tiles were chosen from
    detail:[2]f32,
    jobs:[dynamic]Micro_Job,     // of this frame
    packets:[dynamic]u32,
    wants:[dynamic]Micro_Want,
    held:[dynamic]Micro_Want,    // the tiles in use and their slots, in order (micro_before)
    dirty:[dynamic]scene.Resident_Order,
    samples:[dynamic]u8,
    scratch:pcg.Pcg_Scratch,
    scratched:bool,
    slot_rows:[dynamic]Micro_Slot,
    look_rows:[dynamic]Micro_Look_Row,
    stats:Micro_Stats,
}
Micro_Stats :: struct {generated,refreshes:u64}

// A Micro layer of a Foliage, as drawn.
Micro_Look :: struct {
    entity:core.Entity,
    layer:u32,  // its id
    index:int,  // in its source
    mesh:render.Mesh_Handle,
    row:Micro_Look_Row,
    reach:f32,  // m from a source within which its tiles are resident
    side:u32,   // candidates a side of a tile
    thin:u32,   // of 2^32, the candidates the detail keeps; max(u32): all
    seed:u32,
    pose:mm.Transform, // of the cells of its graph (pcg.graph_frame)
    frame:mm.Mat4,     // and as a matrix into the world
    cell_size:f32,
}

// A tile in a slot: a cell of a graph and one of its Micro layers.
Micro_Tile :: struct {
    used:bool,
    entity:core.Entity,
    layer:u32,
    coord:[2]i32,
    look:u32,
    near:f32,
    block:u32, // of Foliage_Micro.blocks, plus one
    key:u64,   // what its instances were generated from; 0: none are
    want:u64,  // what they are to be generated from
}
Micro_Want :: struct {
    entity:core.Entity,
    layer:u32,
    coord:[2]i32,
    look:u32,
    near:f32,
    key:u64,
    slot:i32,
}
Micro_Block :: struct {first,capacity:u32,used:bool}
Micro_Job :: struct {
    slot:u32,
    key:u64,
    packet:[2]u32, // first word of Foliage_Micro.packets, and how many
    gen:Micro_Gen,
}

foliage_micro_free :: proc(m:^Foliage_Micro) {
    if m.app!=nil {
        for name in ([]string{MICRO_INSTANCES,MICRO_COUNTS,MICRO_VISIBLE,MICRO_DRAWS}) {render.buffer_release(m.app.renderer,m.world,name)}
    }
    if m.scratched {pcg.scratch_destroy(&m.scratch)}
    delete(m.looks);delete(m.tiles);delete(m.blocks);delete(m.jobs);delete(m.packets);delete(m.wants);delete(m.held)
    delete(m.dirty);delete(m.samples);delete(m.slot_rows);delete(m.look_rows)
    m^={}
}

@(step="release")
foliage_micro_release :: proc(m:^Foliage_Micro,app:^host.App) {
    if m==nil {return}
    context.allocator=app.allocator
    m.app=app
    stats:=m.stats
    foliage_micro_free(m)
    m.stats=stats
}

@(private)
micro_before :: proc(a,b:Micro_Want) -> bool {
    if a.entity!=b.entity {return a.entity<b.entity}
    if a.layer!=b.layer {return a.layer<b.layer}
    return coord_before(a.coord,b.coord)
}

// The tile of the wants of an entity, layer and coordinate; -1 for none.
@(private)
micro_want_find :: proc(wants:[]Micro_Want,key:Micro_Want) -> int {
    low,high:=0,len(wants)
    for low<high {mid:=(low+high)/2;if micro_before(wants[mid],key) {low=mid+1} else {high=mid}}
    if low<len(wants) && wants[low].entity==key.entity && wants[low].layer==key.layer && wants[low].coord==key.coord {return low}
    return -1
}


// A run of capacity instances of the buffer: a free one that fits without
// wasting half of it, or a new one at the end. Its index plus one.
micro_block_take :: proc(m:^Foliage_Micro,capacity:u32) -> (block:u32,ok:bool) {
    for &b,i in m.blocks {
        if !b.used && b.capacity>=capacity && b.capacity<=2*capacity {
            b.used=true
            return u32(i+1),true
        }
    }
    if u64(m.end)+u64(capacity)>u64(max(u32)) {return}
    if _,error:=append(&m.blocks,Micro_Block{first=m.end,capacity=capacity,used=true});error!=nil {return}
    m.end+=capacity
    return u32(len(m.blocks)),true
}

// Lets go of a run of the buffer: the free ones at the end give their room back.
micro_block_free :: proc(m:^Foliage_Micro,block:^u32) {
    if block^==0 {return}
    m.blocks[block^-1].used=false
    block^=0
    for len(m.blocks)>0 && !m.blocks[len(m.blocks)-1].used {
        last:=pop(&m.blocks)
        m.end=last.first
    }
}

@(private)
micro_tile_free :: proc(m:^Foliage_Micro,slot:int) {
    micro_block_free(m,&m.tiles[slot].block)
    m.tiles[slot]={}
}

// The look of a Micro layer of a Foliage: its mesh, how its instances are
// turned, sized and swayed, and how far it shows at a detail. False while
// its mesh is not loaded, or for one that places no mesh.
micro_look_make :: proc(l:^pcg.Pcg_Layer,f:Foliage,cell_size:f32,detail:[2]f32,a:^host.Assets,renderer:^render.Renderer) -> (look:Micro_Look,ok:bool) {
    if l.asset=={} {return}
    desc,loaded:=render.batch_desc(a,{mesh=l.asset})
    if !loaded {return}
    low,high,known:=render.mesh_bounds(renderer,desc.mesh)
    primitives,drawable:=render.mesh_primitive_count(renderer,desc.mesh)
    if !known || !drawable || primitives==0 {return}
    center:=(low+high)*0.5
    look.mesh=desc.mesh
    look.row.sphere={center.x,center.y,center.z,0.5*math.sqrt((high.x-low.x)*(high.x-low.x)+(high.y-low.y)*(high.y-low.y)+(high.z-low.z)*(high.z-low.z))}
    look.row.scale={l.scale[0],l.scale[1],l.height[0],l.height[1]}
    look.row.turn={l.yaw,l.tilt,l.align,0}
    sway:=Look{wind=f.wind,flutter=f.flutter}
    look.row.offset={l.offset[0],l.offset[1],sway_amount(sway),flutter_amount(sway)}
    fade,cull:=l.fade_distance*detail[1],l.cull_distance*detail[1]
    look.row.distance={min(fade,cull>0?cull:fade),cull,0,0}
    look.row.mesh={u32(desc.mesh),primitives/CLUSTER_PRIMITIVES,0,0}
    look.reach=cull>0?min(cull,MICRO_REACH_MAX):MICRO_REACH_MAX
    count:=f64(l.density)*f64(cell_size)*f64(cell_size)
    look.side=u32(clamp(math.round(math.sqrt(max(count,0))),0,MICRO_SIDE_MAX))
    look.thin=max(u32)
    if l.filler && detail[0]<1 {look.thin=u32(clamp(f64(detail[0]),0,1)*f64(max(u32)))}
    look.cell_size=cell_size
    return look,look.side>0
}

// Triangles of a cluster (render.mesh_primitive_count counts them).
CLUSTER_PRIMITIVES :: 128

// What a tile is generated from: what its graph places from (its source,
// seed, frame, zones and Volume: pcg.Generated_Graph.key), its ground tile,
// where the Macro and Meso points of its cell stand, its layer and how many
// candidates it has.
micro_tile_key :: proc "contextless" (graph_key:u64,ground:u32,occupied:u64,layer:u32,side,thin:u32) -> u64 {
    key:=base.hash_mix(base.hash_mix(base.HASH_SEED,graph_key),u64(ground)|u64(layer)<<32)
    key=base.hash_mix(base.hash_mix(key,occupied),u64(side)|u64(thin)<<32)
    return key|1
}

// The tiles of each Micro layer of each Foliage of the world near the
// sources, and of those that changed, the nearest MICRO_TILES_A_FRAME are
// made ready for the Simulate stage to generate; the passes that generate,
// cull and draw them asked for. A frame whose inputs are those of the frame
// before only goes through the tiles to find those still waiting.
@(step="render",loops="game editor")
foliage_micro :: proc(
    m:^Foliage_Micro,data:core.Ref(pcg.Pcg_Data),grounds:core.Ref(pcg.Pcg_Ground),generated:core.Ref(pcg.Pcg_Generated),
    foliages:^core.Table(Foliage,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),zones:^core.Table(pcg.Pcg_Zone,.Read),ids:^core.Table(core.Id,.Read),at:volume.Where,
    sources:core.Ref(scene.Streaming_Sources),graphics:render.Graphics_Settings,id:core.World_Id,app:^host.App,problems:^core.Problems,
) {
    if m==nil || app.renderer==nil || app.assets==nil || data.ptr==nil || grounds.ptr==nil || generated.ptr==nil {return}
    context.allocator=app.allocator
    m.app,m.world=app,id
    details:=FOLIAGE_DETAIL
    detail:=details[clamp(graphics.detail,.Low,.Ultra)]
    inputs:=micro_inputs(data.ptr,grounds.ptr,generated.ptr,foliages,graphs,at.worlds,sources.ptr,detail,app)
    if inputs!=m.inputs || len(m.looks)==0 && inputs!=0 {
        m.inputs,m.detail=inputs,detail
        micro_refresh(m,data.ptr,grounds.ptr,generated.ptr,foliages,graphs,at.worlds,sources.ptr,app,problems)
    }
    micro_jobs(m,data.ptr,grounds.ptr,generated.ptr,graphs,zones,ids,at,problems)
    used:=false
    for t in m.tiles {used||=t.used}
    if !used {return}
    for look in m.looks {
        render.frame_gbuffer_mesh(app.renderer,look.mesh,0)
        render.frame_mesh_whole(app.renderer,look.mesh)
    }
    if len(m.jobs)>0 {render.frame_pass(app.renderer,.Simulate,foliage_micro_generate,m)}
    render.frame_pass(app.renderer,.Gbuffer,foliage_micro_draw,m)
}

// The hash of what the tiles are chosen from: the sources, the detail, the
// assets and the batches of the renderer, and of each Foliage with Micro
// layers what its graph placed, its ground and its frame. 0 without any.
micro_inputs :: proc(data:^pcg.Pcg_Data,grounds:^pcg.Pcg_Ground,generated:^pcg.Pcg_Generated,foliages:^core.Table(Foliage,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),sources:^scene.Streaming_Sources,detail:[2]f32,app:^host.App) -> u64 {
    h:=u64(0)
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        graph,graphed:=core.get(graphs,e)
        if !graphed {continue}
        entry:=pcg.data_find(data,graph.source)
        if entry==nil || !pcg.source_micro(&entry.source) {continue}
        gen:=pcg.generated_graph(generated,e)
        owner:=pcg.ground_owner(grounds,e)
        world,placed:=core.get(worlds,e)
        if gen==nil || owner==nil || !placed {continue}
        frame:=pcg.graph_frame(graph,world.transform)
        Fixed :: struct {e:core.Entity,f:Foliage,key:u64,revision,ground,cells,loads:u32,epoch:u64,frame:mm.Transform}
        fixed:=Fixed{e,f,gen.key,gen.revision,owner.revision,owner.cells_revision,entry.loads,entry.epoch,frame}
        h=base.hash64(([^]u8)(&fixed)[:size_of(fixed)],h~base.HASH_SEED)
    }
    if h==0 {return 0}
    h=base.hash_mix(h,sources!=nil?sources.revision:0)
    h=base.hash_mix(h,u64(transmute(u32)detail[0])|u64(transmute(u32)detail[1])<<32)
    h=base.hash_mix(base.hash_mix(h,app.assets.structure),render.batches_epoch(app.renderer))
    return h|1
}

// The looks of the Micro layers and the tiles that are resident: those near
// the sources whose ground tile is read whole and whose cell is placed, the
// nearest MICRO_SLOTS. A tile that stays keeps its slot and its instances; one
// that goes lets go of them; a new one takes a slot and room in the buffer.
micro_refresh :: proc(m:^Foliage_Micro,data:^pcg.Pcg_Data,grounds:^pcg.Pcg_Ground,generated:^pcg.Pcg_Generated,foliages:^core.Table(Foliage,.Read),graphs:^core.Table(pcg.Pcg_Graph,.Read),worlds:^core.Table(core.World_Transform,.Read),sources:^scene.Streaming_Sources,app:^host.App,problems:^core.Problems) {
    m.stats.refreshes+=1
    clear(&m.looks);clear(&m.wants);clear(&m.held)
    for t,slot in m.tiles {if t.used {append(&m.held,Micro_Want{entity=t.entity,layer=t.layer,coord=t.coord,slot=i32(slot)})}}
    slice.sort_by(m.held[:],micro_before)
    for row in 0..<core.count(foliages) {
        e:=core.entity_at(foliages,row)
        f:=core.at(foliages,row)
        graph,graphed:=core.get(graphs,e)
        if !graphed {continue}
        entry:=pcg.data_find(data,graph.source)
        if entry==nil || !pcg.source_micro(&entry.source) || len(entry.source.compiled)!=len(entry.source.layers) {continue}
        gen:=pcg.generated_graph(generated,e)
        owner:=pcg.ground_owner(grounds,e)
        world,placed:=core.get(worlds,e)
        if gen==nil || owner==nil || !placed {continue}
        s:=&entry.source
        pose:=pcg.graph_frame(graph,world.transform)
        frame:=mm.transform_matrix(pose)
        cell_size:=s.info.cell_size
        for &l,i in s.layers {
            if l.tier!=.Micro {continue}
            if l.kind!=.Scatter {
                core.report(problems,e,"foliage.micro","Micro layer %d is a %v layer, which the GPU does not scatter; make it a Scatter layer, or move it to the Meso tier",l.id,l.kind)
                continue
            }
            look,ok:=micro_look_make(&l,f,cell_size,m.detail,app.assets,app.renderer)
            if !ok {
                if l.asset=={} || l.density<=0 {continue}
                if desc,loaded:=render.batch_desc(app.assets,{mesh=l.asset});!loaded || desc.mesh==0 {
                    core.report(problems,e,"foliage.micro","Micro layer %d draws nothing: it places no loaded mesh (a prefab is not scattered on the GPU); give it a .mesh",l.id)
                }
                continue
            }
            if len(m.looks)>=MICRO_LOOKS {
                core.report(problems,e,"foliage.micro","Micro layer %d is not drawn: a world draws at most %d Micro layers; join layers that look alike",l.id,MICRO_LOOKS)
                continue
            }
            look.entity,look.layer,look.index,look.pose,look.frame=e,l.id,i,pose,frame
            look.seed=pcg.graph_seed(s.info.seed,graph.seed)
            append(&m.looks,look)
            index:=u32(len(m.looks)-1)
            near:=scene.sources_near(sources,frame,look.reach)
            if near.count==0 {continue}
            for want in owner.cells {
                low,high:=cell_box(cell_size,want.coord)
                n:=scene.box_near(&near,low,high)
                if !scene.resident(n,micro_want_find(m.held[:],{entity=e,layer=l.id,coord=want.coord})>=0) {continue}
                if pcg.ground_tile_sparse(owner,want.coord) || pcg.ground_tile_samples(owner,want.coord)<2 {continue}
                cell:=pcg.generated_cell(gen,want.coord)
                if cell==nil {continue}
                ground,revision:=pcg.ground_cell(owner,want.coord)
                if ground.absent {continue}
                key:=micro_tile_key(gen.key,revision,cell.occupied_hash,l.id,look.side,look.thin)
                append(&m.wants,Micro_Want{entity=e,layer=l.id,coord=want.coord,look=index,near=n,key=key,slot=-1})
            }
        }
    }
    if len(m.wants)>MICRO_SLOTS {
        slice.sort_by(m.wants[:],proc(a,b:Micro_Want) -> bool {return a.near<b.near || a.near==b.near && micro_before(a,b)})
        base.truncate(&m.wants,MICRO_SLOTS)
    }
    slice.sort_by(m.wants[:],micro_before)
    // The tiles that stay keep their slot; the others go.
    for &t,slot in m.tiles {
        if !t.used {continue}
        k:=micro_want_find(m.wants[:],{entity=t.entity,layer=t.layer,coord=t.coord})
        if k<0 {micro_tile_free(m,slot);continue}
        w:=&m.wants[k]
        w.slot=i32(slot)
        look:=m.looks[w.look]
        if t.block>0 && m.blocks[t.block-1].capacity<look.side*look.side {
            micro_block_free(m,&t.block)
            t.key=0
        }
        t.look,t.near,t.want=w.look,w.near,w.key
    }
    free_slot:=0
    for &w in m.wants {
        if w.slot>=0 {continue}
        for free_slot<len(m.tiles) && m.tiles[free_slot].used {free_slot+=1}
        if free_slot>=len(m.tiles) {
            if _,error:=append(&m.tiles,Micro_Tile{});error!=nil {break}
        }
        w.slot=i32(free_slot)
        m.tiles[free_slot]={used=true,entity=w.entity,layer=w.layer,coord=w.coord,look=w.look,near=w.near,want=w.key}
    }
    for len(m.tiles)>0 && !m.tiles[len(m.tiles)-1].used {pop(&m.tiles)}
    // Room in the buffer for each, and of the visible lists for each look.
    for &t in m.tiles {
        if !t.used || t.block>0 {continue}
        side:=m.looks[t.look].side
        block,ok:=micro_block_take(m,side*side)
        if !ok {t.used=false;continue}
        t.block,t.key=block,0
    }
    for &look in m.looks {look.row.mesh.w=0}
    for t in m.tiles {if t.used && t.block>0 {m.looks[t.look].row.mesh.w+=m.blocks[t.block-1].capacity}}
    m.visible=0
    for &look in m.looks {
        look.row.mesh.z=m.visible
        m.visible+=look.row.mesh.w
    }
}

// The tiles to generate this frame, the nearest first, each with what the
// CPU gives it: the heights of its ground tile and the densities of its layer.
micro_jobs :: proc(m:^Foliage_Micro,data:^pcg.Pcg_Data,grounds:^pcg.Pcg_Ground,generated:^pcg.Pcg_Generated,graphs:^core.Table(pcg.Pcg_Graph,.Read),zones:^core.Table(pcg.Pcg_Zone,.Read),ids:^core.Table(core.Id,.Read),at:volume.Where,problems:^core.Problems) {
    clear(&m.jobs);clear(&m.packets);clear(&m.dirty)
    for t,slot in m.tiles {
        if t.used && t.block>0 && t.key!=t.want {append(&m.dirty,scene.Resident_Order{near=t.near,index=u32(slot)})}
    }
    if len(m.dirty)==0 {return}
    if len(m.dirty)>MICRO_TILES_A_FRAME {scene.residents_past(m.dirty[:],MICRO_TILES_A_FRAME)}
    if !m.scratched {
        if !pcg.scratch_init(&m.scratch,m.app.allocator) {
            core.report(problems,core.NONE,"foliage.memory","out of memory for the micro foliage; it is tried again: free memory")
            return
        }
        m.scratched=true
    }
    n:=pcg.MICRO_SAMPLES
    if resize(&m.samples,n*n)!=nil {return}
    z:pcg.Zone_Inputs
    zoned:=false
    for order in m.dirty[:min(len(m.dirty),MICRO_TILES_A_FRAME)] {
        slot:=int(order.index)
        t:=&m.tiles[slot]
        look:=&m.looks[t.look]
        graph,graphed:=core.get(graphs,t.entity)
        if !graphed {continue}
        entry:=pcg.data_find(data,graph.source)
        owner:=pcg.ground_owner(grounds,t.entity)
        cell:=pcg.generated_cell(pcg.generated_graph(generated,t.entity),t.coord)
        if entry==nil || owner==nil || cell==nil {continue}
        s:=&entry.source
        if look.index>=len(s.layers) || s.layers[look.index].id!=t.layer {continue}
        ground,_:=pcg.ground_cell(owner,t.coord)
        if ground.absent || len(ground.keys)>0 || ground.samples<2 || len(ground.heights)<ground.samples*ground.samples {continue}
        if !zoned {z,zoned=pcg.zone_inputs(zones,at,ids,problems),true}
        local,inverted:=mm.transform_inverse_matrix(look.pose)
        if !inverted {continue}
        _,_,domain,_:=pcg.graph_domain(at,t.entity,local)
        cin:=pcg.Pcg_Cell_Input{source=s,seed=look.seed,coord=t.coord,ground=ground,paint=pcg.source_cell(s,t.coord),frame=look.frame,domain=domain,zones=z.zones[:],share=1}
        occupied:=&cell.occupied if cell.occupied_hash!=0 else nil
        if !pcg.micro_samples(&cin,&m.scratch,look.index,occupied,m.samples[:]) {
            core.report(problems,t.entity,"foliage.micro","Micro layer %d is not scattered in cell %v: its field does not run, or memory is short",t.layer,t.coord)
            continue
        }
        first:=len(m.packets)
        heights:=ground.samples*ground.samples
        words:=heights+(n*n+3)/4
        if resize(&m.packets,first+words)!=nil {return}
        for h,i in ground.heights[:heights] {m.packets[first+i]=transmute(u32)h}
        for &w in m.packets[first+heights:][:(n*n+3)/4] {w=0}
        for v,i in m.samples[:n*n] {m.packets[first+heights+i/4]|=u32(v)<<(uint(i%4)*8)}
        b:=m.blocks[t.block-1]
        job:=Micro_Job{slot=u32(slot),key=t.want,packet={u32(first),u32(words)}}
        job.gen.a={u32(slot),b.first,look.side,u32(ground.samples)}
        job.gen.b={u32(base.hash_mix(base.hash_mix(u64(look.seed),u64(transmute(u64)t.coord)),u64(t.layer))),look.thin,u32(n),0}
        job.gen.c={look.cell_size,0,0,0}
        append(&m.jobs,job)
    }
}

// The Simulate stage: the tiles of this frame, each into its slot. A buffer
// made again holds nothing known: every tile is generated again.
@(private)
foliage_micro_generate :: proc(pass:^render.Pass,user:rawptr) {
    m:=cast(^Foliage_Micro)user
    if pass.world!=render.world_key(m.world) || len(m.jobs)==0 {return}
    pipeline:=render.pass_stage_pipeline(pass,{stage=.Simulate,shader="foliage_micro_gen",name="foliage micro generate"})
    if pipeline==0 {return}
    if !micro_buffers(pass,m) {return}
    instances,counts:=micro_instances_desc(m),micro_counts_desc()
    render.pass_timestamp(pass,"foliage micro generate")
    for job in m.jobs {
        zero:=u32(0)
        if !render.pass_buffer_write(pass,counts,u64(job.slot)*4,&zero,4) {continue}
        rows,uploaded:=render.pass_rows_upload(pass,&m.packets[job.packet[0]],int(job.packet[1])*4)
        if !uploaded {continue}
        gen:=job.gen
        render.pass_pipeline(pass,pipeline)
        render.pass_buffer(pass,0,instances)
        render.pass_buffer(pass,1,counts)
        render.pass_rows(pass,2,rows)
        if !render.pass_params(pass,&gen,size_of(gen)) {continue}
        render.pass_dispatch(pass,(job.gen.a.z*job.gen.a.z+63)/64)
        if int(job.slot)<len(m.tiles) {m.tiles[job.slot].key=job.key}
        m.stats.generated+=1
    }
    clear(&m.jobs)
}

micro_instances_desc :: proc "contextless" (m:^Foliage_Micro) -> render.Buffer_Desc {return {name=MICRO_INSTANCES,size=u64(max(m.capacity,1))*size_of(Micro_Instance)}}
micro_counts_desc :: proc "contextless" () -> render.Buffer_Desc {return {name=MICRO_COUNTS,size=MICRO_SLOTS*4}}

// The buffers of the instances and of the counts of the slots, made large
// enough for the blocks: one made again forgets every tile it held.
@(private)
micro_buffers :: proc(pass:^render.Pass,m:^Foliage_Micro) -> bool {
    if m.capacity<m.end || m.capacity==0 {
        capacity:=u32(MICRO_INSTANCES_MIN)
        for capacity<m.end {capacity*=2}
        m.capacity=capacity
    }
    instances,counts:=micro_instances_desc(m),micro_counts_desc()
    ok,made:=render.pass_buffer(pass,0,instances)
    counted,counts_made:=render.pass_buffer(pass,1,counts)
    if !ok || !counted {return false}
    if counts_made && !render.pass_buffer_fill(pass,counts,0,counts.size) {return false}
    if made || counts_made {
        for &t in m.tiles {t.key=0}
    }
    return true
}

// The Gbuffer stage of a view: the instances of the slots it sees into the
// list of each look, then a draw a look and Surface program of its mesh.
@(private)
foliage_micro_draw :: proc(pass:^render.Pass,user:rawptr) {
    m:=cast(^Foliage_Micro)user
    if pass.world!=render.world_key(m.world) || len(m.looks)==0 || m.end==0 || m.visible==0 {return}
    instances,counts:=micro_instances_desc(m),micro_counts_desc()
    if !render.pass_buffer_held(pass,instances) || !render.pass_buffer_held(pass,counts) {return}
    cull:=render.pass_stage_pipeline(pass,{stage=.Simulate,shader="foliage_micro_cull",name="foliage micro cull"})
    if cull==0 {return}
    clear(&m.slot_rows);clear(&m.look_rows)
    generated:=false
    for t in m.tiles {
        row:Micro_Slot
        if t.used && t.block>0 && t.key!=0 {
            look:=m.looks[t.look]
            corner:=pcg.cell_corner(look.cell_size,t.coord)
            placed:=look.frame*mm.Mat4{1,0,0,corner.x,0,1,0,corner.y,0,0,1,corner.z,0,0,0,1}
            rows:=[3][4]f32{{placed[0,0],placed[0,1],placed[0,2],placed[0,3]},{placed[1,0],placed[1,1],placed[1,2],placed[1,3]},{placed[2,0],placed[2,1],placed[2,2],placed[2,3]}}
            row.world=render.origin_to_world(rows,pass.origin)
            b:=m.blocks[t.block-1]
            row.info={b.first,b.capacity,t.look,1}
            row.cell={look.cell_size,transmute(f32)look.seed,0,0}
            generated=true
        }
        append(&m.slot_rows,row)
    }
    if !generated {return}
    for look in m.looks {append(&m.look_rows,look.row)}
    visible:=render.Buffer_Desc{name=MICRO_VISIBLE,size=u64(m.visible)*4}
    draws:=render.Buffer_Desc{name=MICRO_DRAWS,size=MICRO_LOOKS*16}
    seen,_:=render.pass_buffer(pass,2,visible)
    counted,_:=render.pass_buffer(pass,3,draws)
    if !seen || !counted || !render.pass_buffer_fill(pass,draws,0,draws.size) {return}
    slots,slots_ok:=render.pass_rows_upload(pass,raw_data(m.slot_rows),len(m.slot_rows)*size_of(Micro_Slot))
    looks,looks_ok:=render.pass_rows_upload(pass,raw_data(m.look_rows),len(m.look_rows)*size_of(Micro_Look_Row))
    if !slots_ok || !looks_ok {return}
    render.pass_timestamp(pass,"foliage micro cull")
    render.pass_pipeline(pass,cull)
    render.pass_buffer(pass,0,instances)
    render.pass_buffer(pass,1,counts)
    render.pass_buffer(pass,2,visible)
    render.pass_buffer(pass,3,draws)
    render.pass_rows(pass,4,slots)
    render.pass_rows(pass,5,looks)
    levels,now:=render.pass_depth_pyramid(pass,6)
    params:=Micro_Cull{count={m.end,u32(len(m.slot_rows)),u32(len(m.look_rows)),now?levels:0}}
    if !render.pass_params(pass,&params,size_of(params)) {return}
    render.pass_dispatch(pass,(max(m.end,u32(len(m.look_rows)))+63)/64)
    render.pass_gbuffer_begin(pass,"foliage micro")
    bound:=render.Pipeline(0)
    for look,i in m.looks {
        if look.row.mesh.w==0 {continue}
        programs:[MICRO_PROGRAMS]u32
        count:=render.pass_mesh_programs(pass,look.mesh,0,programs[:])
        for program in programs[:min(count,len(programs))] {
            pipeline:=render.pass_gbuffer_pipeline(pass,"foliage_micro","foliage micro",program=program)
            if pipeline==0 {continue}
            if pipeline!=bound {
                render.pass_pipeline(pass,pipeline)
                bound=pipeline
            }
            render.pass_buffer(pass,0,instances)
            render.pass_buffer(pass,2,visible)
            render.pass_rows(pass,4,slots)
            render.pass_rows(pass,5,looks)
            d:=Micro_Draw{look=u32(i),program=program if count>1 else max(u32),mesh=u32(look.mesh)}
            if render.pass_params(pass,&d,size_of(d)) {render.pass_draw_indirect(pass,draws,u64(i)*16)}
        }
    }
    render.pass_end(pass)
}
