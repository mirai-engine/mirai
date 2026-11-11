package foliage

import "core:slice"
import "mirai:core"
import "mirai:std/base"
import "base:runtime"

// Instances taken out in play (harvested, cut, burnt) are what the world
// says of its foliage beyond its source: an entity with Foliage_Removed for
// each cell of a Foliage that lost some, hanging from it, holding the ids of
// up to REMOVED_PAGE of them, as the tombstones of what is destroyed in a
// section; a cell that loses more has more. A saved game keeps them, Play and
// rollback copy them, a Foliage kept for a section that is not loaded keeps
// them with it (scene.Far_Kept), and the network takes each to every client as
// one object whose changes travel alone (replicated="object"). The
// source does not change. The game asks with foliage_remove; the end that
// decides writes the entities, and a client asks nothing: what it is told
// arrives. The Foliage is named by its Id, which every end of a session and
// every saved game give it alike, and an instance by its id in its cell
// (Placed.id), which edits of the source do not move to another instance. An
// id the cell no longer has (its instance was deleted from the source, or a
// manual one moved to another cell) takes nothing out and is kept: it is what
// the game did, and costs nothing. Each Foliage shows and collides without
// the instances its entities name, building again only the cells whose
// entities changed.

REMOVED_PAGE :: 128 // instances of a cell one entity holds

@(component,replicated="object",description="Instances of a cell of a Foliage taken out in play: the Foliage with this Id neither shows them nor collides with them. A saved game keeps them; taking this entity away puts them back.")
Foliage_Removed :: struct {
    foliage:base.Entity_Id `mirai:"readonly"`,                   // the Id of the Foliage entity
    coord:[2]i32 `mirai:"readonly"`,                             // the cell of the instances
    count:u32 `mirai:"readonly"`,                                // of instances, the first ones; at most REMOVED_PAGE
    instances:[REMOVED_PAGE]Removed_Instance `mirai:"readonly"`, // in the order they were taken out
}

// A struct, so that the network sends each entry that changes alone.
Removed_Instance :: struct {
    id:u64, // in its cell (Placed.id)
}

// What the game asks: take an instance of a Foliage out.
@(storage,queue)
Foliage_Requests :: struct {removes:core.Queue(Foliage_Plant)}

// An instance of a Foliage: its cell and its id there (Placed.id).
Foliage_Plant :: struct {
    foliage:core.Entity,
    coord:[2]i32,
    instance:u64,
}

// Asks to take out an instance of a Foliage, as a hit of its collision
// (hit_of) or a pick of its batches gives it.
foliage_remove :: proc(requests:^Foliage_Requests,instance:Foliage_Plant) {core.offer(&requests.removes,instance)}

@(storage,setting)
Foliage_Settings :: struct {
    removes:u32 `mirai:"advanced"`,         // instances a tick can ask to take out; past it they are dropped and reported
    ground_requests:u32 `mirai:"advanced"`, // cells a tick can ask the ground of; as many
}
FOLIAGE_SETTINGS_DEFAULT :: Foliage_Settings{removes=1024,ground_requests=256}

// The room of the requests of a tick, and what did not fit in it.
@(step="input fixed",loops="game editor",stage="begin")
foliage_requests_serve :: proc(requests:^Foliage_Requests,ground:^Foliage_Ground_Requests,settings:Foliage_Settings,problems:^core.Problems) {
    core.queue_serve(&requests.removes,int(settings.removes),problems,"foliage.requests","instances asked to be taken out","Foliage_Settings.removes")
    core.queue_serve(&ground.cells,int(settings.ground_requests),problems,"foliage.requests","cells asked of the ground","Foliage_Settings.ground_requests")
}

// The instances taken out of each Foliage, by cell, from the entities that
// name them: made again when they or the Foliage change.
@(storage)
Foliage_Removals :: struct {
    owners:[dynamic]Removed_Owner,
    seen:[2]core.Seen, // the tables of Foliage_Removed and Foliage it was made from
    made:bool,
}
Removed_Owner :: struct {
    entity:core.Entity,
    hash:u64,                    // of all of them: what is built from them compares it
    items:[dynamic]Removed,      // in the order of their cell, z then x, and their id, each once
    ids:[dynamic]u64,            // the same, their ids alone
    pages:[dynamic]Removed_Page, // the entities that name them, in the order of their cell
}
Removed :: struct {coord:[2]i32,instance:u64}
Removed_Page :: struct {
    coord:[2]i32,
    entity:core.Entity,
    count:int, // of its instances
}

@(private)
removed_before :: proc(a,b:Removed) -> bool {
    return coord_before(a.coord,b.coord) || a.coord==b.coord && a.instance<b.instance
}

removed_owner :: proc "contextless" (r:^Foliage_Removals,e:core.Entity) -> ^Removed_Owner {
    if r==nil {return nil}
    for &owner in r.owners {if owner.entity==e {return &owner}}
    return nil
}

// The ids taken out of a cell of a Foliage, in order, and a hash of them: 0 for none.
removed_cell :: proc "contextless" (owner:^Removed_Owner,coord:[2]i32) -> (ids:[]u64,hash:u64) {
    if owner==nil {return}
    low,high:=0,len(owner.items)
    for low<high {mid:=(low+high)/2;if coord_before(owner.items[mid].coord,coord) {low=mid+1} else {high=mid}}
    end:=low
    for end<len(owner.items) && owner.items[end].coord==coord {end+=1}
    ids=owner.ids[low:end]
    for id in ids {hash=base.hash_u64(hash~id)}
    return
}

// The entities that hold the instances taken out of a cell of a Foliage.
removed_pages :: proc "contextless" (owner:^Removed_Owner,coord:[2]i32) -> []Removed_Page {
    if owner==nil {return nil}
    low,high:=0,len(owner.pages)
    for low<high {mid:=(low+high)/2;if coord_before(owner.pages[mid].coord,coord) {low=mid+1} else {high=mid}}
    end:=low
    for end<len(owner.pages) && owner.pages[end].coord==coord {end+=1}
    return owner.pages[low:end]
}

// Whether a sorted list of ids holds one.
@(private)
ids_have :: proc "contextless" (ids:[]u64,id:u64) -> bool {
    low,high:=0,len(ids)
    for low<high {mid:=(low+high)/2;if ids[mid]<id {low=mid+1} else {high=mid}}
    return low<len(ids) && ids[low]==id
}

removals_destroy :: proc(r:^Foliage_Removals) {
    for &owner in r.owners {delete(owner.items);delete(owner.ids);delete(owner.pages)}
    delete(r.owners)
    r^={}
}

// Makes the instances taken out of each Foliage again from the entities
// that name them, when they or the Foliage changed.
removals_index :: proc(r:^Foliage_Removals,removed:^core.Table(Foliage_Removed,$A),foliages:^core.Table(Foliage,$B),es:^core.Entities) -> (enough:bool) {
    enough=true
    if !(core.touched(removed,&r.seen[0]) | core.touched(foliages,&r.seen[1])) && r.made {return}
    r.made=true
    for &owner in r.owners {clear(&owner.items);clear(&owner.pages)}
    for row in 0..<core.count(removed) {
        page:=&removed.values[row]
        e:=core.entity_of(es,page.foliage)
        if e==core.NONE || !core.has(foliages,e) {continue}
        owner:=removed_owner(r,e)
        if owner==nil {
            if _,error:=append(&r.owners,Removed_Owner{entity=e});error!=nil {enough=false;continue}
            owner=&r.owners[len(r.owners)-1]
        }
        // What came from the network is not trusted to fit.
        count:=min(int(page.count),REMOVED_PAGE)
        append(&owner.pages,Removed_Page{page.coord,core.entity_at(removed,row),count})
        for instance in page.instances[:count] {append(&owner.items,Removed{page.coord,instance.id})}
    }
    for i:=len(r.owners)-1;i>=0;i-=1 {
        owner:=&r.owners[i]
        if len(owner.pages)==0 {
            delete(owner.items);delete(owner.ids);delete(owner.pages)
            unordered_remove(&r.owners,i)
            continue
        }
        slice.sort_by(owner.pages[:],proc(a,b:Removed_Page) -> bool {return coord_before(a.coord,b.coord)})
        slice.sort_by(owner.items[:],removed_before)
        // The same instance named twice counts once.
        kept:=0
        for item,k in owner.items {
            if k>0 && item==owner.items[kept-1] {continue}
            owner.items[kept]=item
            kept+=1
        }
        base.truncate(&owner.items,kept)
        // Without its ids an owner has nothing taken out, and the index is made again.
        if resize(&owner.ids,kept)!=nil {
            clear(&owner.items);clear(&owner.ids)
            owner.hash,enough=0,false
            continue
        }
        owner.hash=0
        for item,k in owner.items {
            owner.ids[k]=item.instance
            owner.hash=base.hash_u64(owner.hash~base.hash_u64(u64(u32(item.coord.x))|u64(u32(item.coord.y))<<32)~item.instance)
        }
    }
    r.made=enough
    return
}

// Takes what the game asked out, on the end that decides: the ids of the
// instances a cell shows and has not taken out go to the entities of that
// cell with room, and past them to new ones under the Foliage. A client asks
// nothing; what the server took out arrives.
@(step="fixed frame",loops="game editor",stage="simulate",before="physics_prepare")
foliage_removals :: proc(
    r:^Foliage_Removals,requests:^Foliage_Requests,removed:^core.Table(Foliage_Removed),foliages:^core.Table(Foliage,.Read),ids:^core.Table(core.Id,.Read),
    data:core.Ref(Foliage_Data),authority:core.Ref(core.Network),commands:core.Commands,allocator:runtime.Allocator,problems:^core.Problems,
) {
    asked:=core.take(&requests.removes)
    context.allocator=allocator
    if !removals_index(r,removed,foliages,commands.entities) {
        memory_problem(problems,core.NONE,"the instances taken out of the foliage: some show again")
    }
    if len(asked)==0 || authority.ptr!=nil && authority.role==.Client || data.ptr==nil {return}
    // By Foliage and cell: each cell is built once and its entities filled together.
    order:=slice.clone(asked,context.temp_allocator)
    slice.stable_sort_by(order,proc(a,b:Foliage_Plant) -> bool {return a.foliage<b.foliage || a.foliage==b.foliage && coord_before(a.coord,b.coord)})
    shown:=make([dynamic]u64,context.temp_allocator)
    taken:=make([dynamic]u64,context.temp_allocator)
    work:Build_Work
    defer build_work_destroy(&work)
    for start:=0;start<len(order); {
        end:=start+1
        for end<len(order) && order[end].foliage==order[start].foliage && order[end].coord==order[start].coord {end+=1}
        group:=order[start:end]
        start=end
        e,coord:=group[0].foliage,group[0].coord
        f,has:=core.get(foliages,e)
        if !has {continue}
        id:=core.id_of(ids,e)
        if id==0 {
            core.report(problems,e,"foliage.remove","an instance of this Foliage cannot be taken out: the entity has no Id, which names it in a saved game and on the network; give it an Id, as the entities of a scene have")
            continue
        }
        entry:=data_find(data.ptr,f.source)
        cell:=entry!=nil?source_cell(&entry.source,coord):nil
        if cell==nil {continue}
        if !cell_build(&entry.source,cell,{},&work) {
            for request in group {core.offer(&requests.removes,request)}
            memory_problem(problems,e,"taking instances out of this Foliage")
            continue
        }
        clear(&shown)
        for p in work.placed {append(&shown,p.id)}
        slice.sort(shown[:])
        owner:=removed_owner(r,e)
        gone,_:=removed_cell(owner,coord)
        clear(&taken)
        for request in group {
            if !ids_have(shown[:],request.instance) || ids_have(gone,request.instance) || slice.contains(taken[:],request.instance) {continue}
            append(&taken,request.instance)
        }
        removed_write(removed,removed_pages(owner,coord),id,e,coord,taken[:],commands)
    }
}

// Puts ids taken out of a cell in the entities of the cell with room, and
// what does not fit in new ones under the Foliage.
@(private)
removed_write :: proc(removed:^core.Table(Foliage_Removed),pages:[]Removed_Page,foliage:base.Entity_Id,e:core.Entity,coord:[2]i32,taken:[]u64,commands:core.Commands) {
    left:=taken
    for &page in pages {
        if len(left)==0 {return}
        if page.count>=REMOVED_PAGE {continue}
        row:=core.edit(removed,page.entity)
        if row==nil {continue}
        n:=min(len(left),REMOVED_PAGE-page.count)
        for id,k in left[:n] {row.instances[page.count+k]={id}}
        page.count+=n
        row.count=u32(page.count)
        left=left[n:]
    }
    for len(left)>0 {
        value:=Foliage_Removed{foliage=foliage,coord=coord}
        n:=min(len(left),REMOVED_PAGE)
        for id,k in left[:n] {value.instances[k]={id}}
        value.count=u32(n)
        left=left[n:]
        made:=core.commands_create(commands)
        core.commands_add(commands,made,core.Parent{entity=e})
        core.commands_add(commands,made,core.TRANSFORM_IDENTITY)
        core.add(removed,made,value)
    }
}
