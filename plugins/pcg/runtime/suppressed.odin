package pcg

import "base:runtime"
import "core:slice"
import "mirai:core"
import scene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"

// What is taken out of a graph is world data, never the asset: an entity with
// Pcg_Suppressed for each cell of a Pcg_Graph that lost some of its points,
// hanging from it, holding the stable ids of up to SUPPRESSED_PAGE of them; a
// cell that loses more has more. The editor writes them to delete or promote
// what a graph places (its journal undoes them, and the scene saves them);
// the game asks with pcg_suppress_request and pcg_promote (a saved game keeps
// them, rollback and Play copy them, and the network takes each to every
// client as one object). The graph is named by its Id, which every end of a
// session and every saved game give it alike, and a point by its stable id in
// its cell. A graph applies them after its points kept apart (generate.odin):
// what is taken out leaves its place empty, and nothing new grows there. An
// id the cell does not place takes nothing out and costs nothing.

SUPPRESSED_PAGE :: 128 // ids of a cell one entity holds

@(component,replicated="object",description="Points a Pcg_Graph does not place in a cell: taken out in the editor or in play. Saved with the scene or the game; taking this entity away puts them back.")
Pcg_Suppressed :: struct {
    graph:base.Entity_Id `mirai:"readonly"`,                 // the Id of the Pcg_Graph entity
    coord:[2]i32 `mirai:"readonly"`,                         // the cell of the points
    count:u32 `mirai:"readonly"`,                            // of ids, the first ones; at most SUPPRESSED_PAGE
    items:[SUPPRESSED_PAGE]Suppressed_Id `mirai:"readonly"`, // in the order they were taken out
}

// A struct, so that the network sends each entry that changes alone.
Suppressed_Id :: struct {
    id:u64, // stable in its cell (Placed.id)
}

// A point of a graph: its cell and its stable id there.
Pcg_Instance :: struct {
    graph:core.Entity,
    coord:[2]i32,
    id:u64,
}

@(storage,queue)
Pcg_Suppress_Requests :: struct {items:core.Queue(Pcg_Instance)}

// Points to take out of their graph and place as entities: the prefab of
// what placed them, at their transform.
@(storage,queue)
Pcg_Promote_Requests :: struct {items:core.Queue(Pcg_Instance)}

// Asks to take a point out of its graph, as a pick or a hit names it.
pcg_suppress_request :: proc(requests:^Pcg_Suppress_Requests,instance:Pcg_Instance) {core.offer(&requests.items,instance)}

// Asks to take a point out of its graph and spawn in its place the prefab of
// its layer (or of its grammar symbol), as a scene entity: a tree that
// falls, a fence module that breaks, what the editor edits by hand.
pcg_promote :: proc(requests:^Pcg_Promote_Requests,instance:Pcg_Instance) {core.offer(&requests.items,instance)}

@(storage,setting)
Pcg_Settings :: struct {
    suppresses:u32 `mirai:"advanced"`,      // points a tick can ask to take out; past it they are dropped and reported
    promotes:u32 `mirai:"advanced"`,        // points a tick can ask to promote; as many
    ground_requests:u32 `mirai:"advanced"`, // cells a tick can ask the ground of; as many
}
PCG_SETTINGS_DEFAULT :: Pcg_Settings{suppresses=1024,promotes=256,ground_requests=256}

// The room of the requests of a tick, and what did not fit in it.
@(step="input fixed",loops="game editor",stage="begin")
pcg_requests_serve :: proc(suppress:^Pcg_Suppress_Requests,promote:^Pcg_Promote_Requests,ground:^Pcg_Ground_Requests,settings:Pcg_Settings,problems:^core.Problems) {
    core.queue_serve(&suppress.items,int(settings.suppresses),problems,"pcg.requests","points asked to be taken out","Pcg_Settings.suppresses")
    core.queue_serve(&promote.items,int(settings.promotes),problems,"pcg.requests","points asked to be promoted","Pcg_Settings.promotes")
    core.queue_serve(&ground.cells,int(settings.ground_requests),problems,"pcg.requests","cells asked of the ground","Pcg_Settings.ground_requests")
}

// The ids taken out of each graph, by cell, from the entities that name
// them: made again when they or the graphs change.
@(storage)
Pcg_Suppressions :: struct {
    owners:[dynamic]Suppressed_Owner,
    seen:[2]core.Seen, // the tables of Pcg_Suppressed and Pcg_Graph it was made from
    made:bool,
}
Suppressed_Owner :: struct {
    entity:core.Entity,
    hash:u64,                       // of all of them
    items:[dynamic]Suppressed,      // in the order of their cell, z then x, and their id, each once
    ids:[dynamic]u64,               // the same, their ids alone
    pages:[dynamic]Suppressed_Page, // the entities that name them, in the order of their cell
}
Suppressed :: struct {coord:[2]i32,id:u64}
Suppressed_Page :: struct {
    coord:[2]i32,
    entity:core.Entity,
    count:int, // of its ids
}

@(private)
suppressed_before :: proc(a,b:Suppressed) -> bool {return coord_before(a.coord,b.coord) || a.coord==b.coord && a.id<b.id}

suppressed_owner :: proc "contextless" (s:^Pcg_Suppressions,e:core.Entity) -> ^Suppressed_Owner {
    if s==nil {return nil}
    for &owner in s.owners {if owner.entity==e {return &owner}}
    return nil
}

// The ids taken out of a cell of a graph, in order, and a hash of them: 0 for none.
suppressed_cell :: proc "contextless" (owner:^Suppressed_Owner,coord:[2]i32) -> (ids:[]u64,hash:u64) {
    if owner==nil {return}
    low:=coord_lower(owner.items[:],coord)
    end:=low
    for end<len(owner.items) && owner.items[end].coord==coord {end+=1}
    ids=owner.ids[low:end]
    for id in ids {hash=base.hash_u64(hash~id)}
    return
}

// The entities that hold the ids taken out of a cell of a graph.
suppressed_pages :: proc "contextless" (owner:^Suppressed_Owner,coord:[2]i32) -> []Suppressed_Page {
    if owner==nil {return nil}
    low:=coord_lower(owner.pages[:],coord)
    end:=low
    for end<len(owner.pages) && owner.pages[end].coord==coord {end+=1}
    return owner.pages[low:end]
}

// Whether a sorted list of ids holds one.
ids_have :: proc "contextless" (ids:[]u64,id:u64) -> bool {
    low,high:=0,len(ids)
    for low<high {mid:=(low+high)/2;if ids[mid]<id {low=mid+1} else {high=mid}}
    return low<len(ids) && ids[low]==id
}

suppressions_destroy :: proc(s:^Pcg_Suppressions) {
    for &owner in s.owners {delete(owner.items);delete(owner.ids);delete(owner.pages)}
    delete(s.owners)
    s^={}
}

// Makes the ids taken out of each graph again from the entities that name
// them, when they or the graphs changed. False without memory: some show again.
suppressions_index :: proc(s:^Pcg_Suppressions,suppressed:^core.Table(Pcg_Suppressed,$A),graphs:^core.Table(Pcg_Graph,$B),es:^core.Entities) -> (enough:bool) {
    enough=true
    if !(core.touched(suppressed,&s.seen[0]) | core.touched(graphs,&s.seen[1])) && s.made {return}
    for &owner in s.owners {clear(&owner.items);clear(&owner.pages)}
    for row in 0..<core.count(suppressed) {
        page:=&suppressed.values[row]
        e:=core.entity_of(es,page.graph)
        if e==core.NONE || !core.has(graphs,e) {continue}
        owner:=suppressed_owner(s,e)
        if owner==nil {
            if _,error:=append(&s.owners,Suppressed_Owner{entity=e});error!=nil {enough=false;continue}
            owner=&s.owners[len(s.owners)-1]
        }
        // What came from the network is not trusted to fit.
        count:=min(int(page.count),SUPPRESSED_PAGE)
        if _,error:=append(&owner.pages,Suppressed_Page{page.coord,core.entity_at(suppressed,row),count});error!=nil {enough=false;continue}
        for item in page.items[:count] {
            if _,error:=append(&owner.items,Suppressed{page.coord,item.id});error!=nil {enough=false;break}
        }
    }
    for i:=len(s.owners)-1;i>=0;i-=1 {
        owner:=&s.owners[i]
        if len(owner.pages)==0 {
            delete(owner.items);delete(owner.ids);delete(owner.pages)
            unordered_remove(&s.owners,i)
            continue
        }
        slice.sort_by(owner.pages[:],proc(a,b:Suppressed_Page) -> bool {return coord_before(a.coord,b.coord)})
        slice.sort_by(owner.items[:],suppressed_before)
        // The same id named twice counts once.
        kept:=0
        for item,k in owner.items {
            if k>0 && item==owner.items[kept-1] {continue}
            owner.items[kept]=item
            kept+=1
        }
        base.truncate(&owner.items,kept)
        if resize(&owner.ids,kept)!=nil {
            clear(&owner.items);clear(&owner.ids)
            owner.hash,enough=0,false
            continue
        }
        owner.hash=0
        for item,k in owner.items {
            owner.ids[k]=item.id
            owner.hash=base.hash_u64(owner.hash~base.hash_u64(u64(u32(item.coord.x))|u64(u32(item.coord.y))<<32)~item.id)
        }
    }
    s.made=enough
    return
}

// Takes out what was asked, on the end that decides, and promotes: the ids a
// cell places and has not taken out go to the entities of that cell with
// room, and past them to new ones under the graph; a promoted point also
// spawns the prefab of what placed it at its transform in the world. A cell
// not generated yet takes any id. A client asks nothing; what the server took
// out arrives. The cells place without them from the next tick, when the
// index of the entities is made again.
@(step="fixed frame",loops="game editor",stage="simulate",before="pcg_update")
pcg_suppress :: proc(
    s:^Pcg_Suppressions,suppress:^Pcg_Suppress_Requests,promote:^Pcg_Promote_Requests,suppressed:^core.Table(Pcg_Suppressed),
    graphs:^core.Table(Pcg_Graph,.Read),ids:^core.Table(core.Id,.Read),worlds:^core.Table(core.World_Transform,.Read),
    generated:core.Ref(Pcg_Generated),authority:core.Ref(core.Network),spawner:scene.Spawner,allocator:runtime.Allocator,
) {
    asked:=core.take(&suppress.items)
    promoted:=core.take(&promote.items)
    context.allocator=allocator
    commands,problems:=spawner.commands,spawner.problems
    if !suppressions_index(s,suppressed,graphs,commands.entities) {
        core.report(problems,core.NONE,"pcg.memory","out of memory for the points taken out of the graphs: some show again; free memory")
    }
    if len(asked)+len(promoted)==0 || authority.ptr!=nil && authority.role==.Client {return}
    Order :: struct {using instance:Pcg_Instance,promote:bool}
    order:=make([dynamic]Order,0,len(asked)+len(promoted),context.temp_allocator)
    for a in asked {append(&order,Order{a,false})}
    for p in promoted {append(&order,Order{p,true})}
    // By graph and cell: each cell writes its entities once.
    slice.stable_sort_by(order[:],proc(a,b:Order) -> bool {return a.graph<b.graph || a.graph==b.graph && coord_before(a.coord,b.coord)})
    taken:=make([dynamic]u64,context.temp_allocator)
    for start:=0;start<len(order); {
        end:=start+1
        for end<len(order) && order[end].graph==order[start].graph && order[end].coord==order[start].coord {end+=1}
        group:=order[start:end]
        start=end
        e,coord:=group[0].graph,group[0].coord
        graph,has:=core.get(graphs,e)
        if !has {continue}
        id:=core.id_of(ids,e)
        if id==0 {
            core.report(problems,e,"pcg.suppress","a point of this Pcg_Graph cannot be taken out: the entity has no Id, which names it in a saved game and on the network; give it an Id, as the entities of a scene have")
            continue
        }
        cell:=generated_cell(generated_graph(generated.ptr,e),coord)
        owner:=suppressed_owner(s,e)
        gone,_:=suppressed_cell(owner,coord)
        clear(&taken)
        for request in group {
            placed:Placed
            shown:=true
            if cell!=nil {placed,shown=placed_find(cell.placed[:],request.id)}
            if !shown || ids_have(gone,request.id) || slice.contains(taken[:],request.id) {continue}
            append(&taken,request.id)
            if !request.promote {continue}
            if cell==nil {
                core.report(problems,e,"pcg.promote","point %d of cell %v of this Pcg_Graph is taken out but not promoted: its cell is not generated, so where it stands is not known; promote points of resident cells",request.id,coord)
                continue
            }
            if placed.asset=={} {
                core.report(problems,e,"pcg.promote","point %d of cell %v of this Pcg_Graph is taken out but not promoted: its layer places no asset; give the layer a prefab",request.id,coord)
                continue
            }
            world,_:=core.get(worlds,e)
            frame:=graph_frame(graph,world.transform)
            at:=mm.transform_compose(frame,mm.Transform{position=placed.position,rotation=placed.rotation,scale=placed.scale})
            scene.spawn(spawner,placed.asset,core.Transform{position=at.position,rotation=at.rotation,scale=at.scale})
        }
        suppressed_write(suppressed,suppressed_pages(owner,coord),id,e,coord,taken[:],commands)
    }
}

// Puts ids taken out of a cell in the entities of the cell with room, and
// what does not fit in new ones under the graph.
@(private)
suppressed_write :: proc(suppressed:^core.Table(Pcg_Suppressed),pages:[]Suppressed_Page,graph:base.Entity_Id,e:core.Entity,coord:[2]i32,taken:[]u64,commands:core.Commands) {
    left:=taken
    for &page in pages {
        if len(left)==0 {return}
        if page.count>=SUPPRESSED_PAGE {continue}
        row:=core.edit(suppressed,page.entity)
        if row==nil {continue}
        n:=min(len(left),SUPPRESSED_PAGE-page.count)
        for id,k in left[:n] {row.items[page.count+k]={id}}
        page.count+=n
        row.count=u32(page.count)
        left=left[n:]
    }
    for len(left)>0 {
        value:=Pcg_Suppressed{graph=graph,coord=coord}
        n:=min(len(left),SUPPRESSED_PAGE)
        for id,k in left[:n] {value.items[k]={id}}
        value.count=u32(n)
        left=left[n:]
        made:=core.commands_create(commands)
        core.commands_add(commands,made,core.Parent{entity=e})
        core.commands_add(commands,made,core.TRANSFORM_IDENTITY)
        core.add(suppressed,made,value)
    }
}
