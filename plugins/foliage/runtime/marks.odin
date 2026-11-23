package foliage

import "core:slice"
import "mirai:core"
import "mirai:std/base"
import render "mirai:engine/render"
import "base:runtime"
import pcg "plugins:pcg/runtime"

// What play changes of how instances look (burnt, wet, frozen) is world
// state beside the graph, as what is taken out is (pcg.Pcg_Suppressed): an
// entity with Foliage_Marked for each cell of a Foliage that has marks,
// hanging from it, holding the id and the color of up to MARKED_PAGE of them; a cell with
// more has more. A saved game keeps them, Play and rollback copy them, a
// Foliage kept for a section that is not loaded keeps them, and the network
// takes each to every client as one object whose entries travel alone. The
// game asks with foliage_mark; the end that decides writes them, and a later
// mark of an instance changes its entry. An id the cell does not show colors
// nothing and is kept.

MARKED_PAGE :: 64 // instances of a cell one entity holds

@(component,replicated="object",description="Instances of a cell of a Foliage marked in play: the Foliage with this Id draws each with its tint and wetness. A saved game keeps them; taking this entity away gives them back their look.")
Foliage_Marked :: struct {
    foliage:base.Entity_Id `mirai:"readonly"`,                // the Id of the Foliage entity
    coord:[2]i32 `mirai:"readonly"`,                          // the cell of the instances
    count:u32 `mirai:"readonly"`,                             // of instances, the first ones; at most MARKED_PAGE
    instances:[MARKED_PAGE]Marked_Instance `mirai:"readonly"`, // in the order they were first marked
}

// A struct, so that the network sends each entry that changes alone.
Marked_Instance :: struct {
    id:u64,    // in its cell (Placed.id)
    color:u32, // its tint and wetness (render.batch_color)
}

// What the game asks: an instance of a Foliage drawn with a tint and a wetness.
Foliage_Mark :: struct {
    plant:pcg.Pcg_Instance,
    color:u32,
}

@(storage,queue)
Foliage_Requests :: struct {marks:core.Queue(Foliage_Mark)}

@(storage,setting)
Foliage_Settings :: struct {
    marks:u32 `mirai:"advanced"`, // instances a tick can ask to mark; past it they are dropped and reported
}
FOLIAGE_SETTINGS_DEFAULT :: Foliage_Settings{marks=1024}

// The room of the requests of a tick, and what did not fit in it.
@(step="input fixed",loops="game editor",stage="begin")
foliage_requests_serve :: proc(requests:^Foliage_Requests,settings:Foliage_Settings,problems:^core.Problems) {
    core.queue_serve(&requests.marks,int(settings.marks),problems,"foliage.requests","instances asked to be marked","Foliage_Settings.marks")
}

// Asks to draw an instance of a Foliage with a tint, which multiplies its
// colors, and a wetness from 0 dry to 1 soaked; white and 0 give it back
// its own look.
foliage_mark :: proc(requests:^Foliage_Requests,plant:pcg.Pcg_Instance,tint:[3]f32,wet:f32) {
    core.offer(&requests.marks,Foliage_Mark{plant,render.batch_color(tint,wet)})
}

// The marks of each Foliage, by cell, from the entities that hold them: made
// again when they or the Foliage change.
@(storage)
Foliage_Marks :: struct {
    owners:[dynamic]Marked_Owner,
    seen:[2]core.Seen, // the tables of Foliage_Marked and Foliage it was made from
    made:bool,
}
Marked_Owner :: struct {
    entity:core.Entity,
    hash:u64,                    // of all of them: what is drawn from them compares it
    items:[dynamic]Marked,       // in the order of their cell, z then x, and their id, each once
    pages:[dynamic]pcg.Suppressed_Page, // the entities that hold them, in the order of their cell
}
Marked :: struct {coord:[2]i32,instance:u64,color:u32}

marked_owner :: proc "contextless" (m:^Foliage_Marks,e:core.Entity) -> ^Marked_Owner {
    if m==nil {return nil}
    for &owner in m.owners {if owner.entity==e {return &owner}}
    return nil
}

// The marks of a cell of a Foliage, in the order of their ids, and a hash of them: 0 for none.
marked_cell :: proc "contextless" (owner:^Marked_Owner,coord:[2]i32) -> (items:[]Marked,hash:u64) {
    if owner==nil {return}
    low,high:=0,len(owner.items)
    for low<high {mid:=(low+high)/2;if coord_before(owner.items[mid].coord,coord) {low=mid+1} else {high=mid}}
    end:=low
    for end<len(owner.items) && owner.items[end].coord==coord {end+=1}
    items=owner.items[low:end]
    for item in items {hash=base.hash_u64(hash~item.instance~u64(item.color)<<40)}
    return
}

// What an instance shows of its own, by the marks of its cell (render.batch_color).
marked_color :: proc "contextless" (marks:[]Marked,id:u64) -> u32 {
    low,high:=0,len(marks)
    for low<high {mid:=(low+high)/2;if marks[mid].instance<id {low=mid+1} else {high=mid}}
    return marks[low].color if low<len(marks) && marks[low].instance==id else render.BATCH_COLOR_PLAIN
}

// The entities that hold the marks of a cell.
@(private)
marked_pages :: proc "contextless" (owner:^Marked_Owner,coord:[2]i32) -> []pcg.Suppressed_Page {
    if owner==nil {return nil}
    low,high:=0,len(owner.pages)
    for low<high {mid:=(low+high)/2;if coord_before(owner.pages[mid].coord,coord) {low=mid+1} else {high=mid}}
    end:=low
    for end<len(owner.pages) && owner.pages[end].coord==coord {end+=1}
    return owner.pages[low:end]
}

// Makes the marks of each Foliage again from the entities that hold them,
// when they or the Foliage changed. One instance marked by two entities
// keeps the mark of the later in the table.
marks_index :: proc(m:^Foliage_Marks,marked:^core.Table(Foliage_Marked,$A),foliages:^core.Table(Foliage,$B),es:^core.Entities) -> (enough:bool) {
    enough=true
    if !(core.touched(marked,&m.seen[0]) | core.touched(foliages,&m.seen[1])) && m.made {return}
    m.made=true
    for &owner in m.owners {clear(&owner.items);clear(&owner.pages)}
    for row in 0..<core.count(marked) {
        page:=&marked.values[row]
        e:=core.entity_of(es,page.foliage)
        if e==core.NONE || !core.has(foliages,e) {continue}
        owner:=marked_owner(m,e)
        if owner==nil {
            if _,error:=append(&m.owners,Marked_Owner{entity=e});error!=nil {enough=false;continue}
            owner=&m.owners[len(m.owners)-1]
        }
        // What came from the network is not trusted to fit.
        count:=min(int(page.count),MARKED_PAGE)
        if _,error:=append(&owner.pages,pcg.Suppressed_Page{page.coord,core.entity_at(marked,row),count});error!=nil {enough=false;continue}
        for instance in page.instances[:count] {
            if _,error:=append(&owner.items,Marked{page.coord,instance.id,instance.color});error!=nil {enough=false;break}
        }
    }
    for i:=len(m.owners)-1;i>=0;i-=1 {
        owner:=&m.owners[i]
        if len(owner.pages)==0 {
            delete(owner.items);delete(owner.pages)
            unordered_remove(&m.owners,i)
            continue
        }
        slice.sort_by(owner.pages[:],proc(a,b:pcg.Suppressed_Page) -> bool {return coord_before(a.coord,b.coord)})
        slice.stable_sort_by(owner.items[:],proc(a,b:Marked) -> bool {return coord_before(a.coord,b.coord) || a.coord==b.coord && a.instance<b.instance})
        // The last of an instance named twice wins.
        kept:=0
        for item in owner.items {
            if kept>0 && owner.items[kept-1].coord==item.coord && owner.items[kept-1].instance==item.instance {owner.items[kept-1]=item;continue}
            owner.items[kept]=item
            kept+=1
        }
        base.truncate(&owner.items,kept)
        owner.hash=0
        for item in owner.items {owner.hash=base.hash_u64(owner.hash~base.hash_u64(u64(u32(item.coord.x))|u64(u32(item.coord.y))<<32)~item.instance~u64(item.color)<<40)}
    }
    m.made=enough
    return
}

// Writes the marks the game asked for, on the end that decides: an instance
// marked before changes its entry; a new one goes to an entity of its cell
// with room, and past them to a new one under the Foliage. A client asks
// nothing; what the server marked arrives.
@(step="fixed frame",loops="game editor",stage="simulate")
foliage_marks :: proc(
    m:^Foliage_Marks,requests:^Foliage_Requests,marked:^core.Table(Foliage_Marked),foliages:^core.Table(Foliage,.Read),ids:^core.Table(core.Id,.Read),
    authority:core.Ref(core.Network),commands:core.Commands,allocator:runtime.Allocator,problems:^core.Problems,
) {
    asked:=core.take(&requests.marks)
    context.allocator=allocator
    if !marks_index(m,marked,foliages,commands.entities) {
        memory_problem(problems,core.NONE,"the marks of the foliage: some instances show their own look again")
    }
    if len(asked)==0 || authority.ptr!=nil && authority.role==.Client {return}
    order:=slice.clone(asked,context.temp_allocator)
    slice.stable_sort_by(order,proc(a,b:Foliage_Mark) -> bool {return a.plant.graph<b.plant.graph || a.plant.graph==b.plant.graph && coord_before(a.plant.coord,b.plant.coord)})
    fresh:=make([dynamic]Marked_Instance,context.temp_allocator)
    for start:=0;start<len(order); {
        end:=start+1
        for end<len(order) && order[end].plant.graph==order[start].plant.graph && order[end].plant.coord==order[start].plant.coord {end+=1}
        group:=order[start:end]
        start=end
        e,coord:=group[0].plant.graph,group[0].plant.coord
        if !core.has(foliages,e) {continue}
        id:=core.id_of(ids,e)
        if id==0 {
            core.report(problems,e,"foliage.mark","an instance of this Foliage cannot be marked: the entity has no Id, which names it in a saved game and on the network; give it an Id, as the entities of a scene have")
            continue
        }
        owner:=marked_owner(m,e)
        pages:=marked_pages(owner,coord)
        clear(&fresh)
        asks: for request in group {
            // An instance marked before, in an entity or earlier in this group, takes the new color there.
            for page in pages {
                row:=core.get(marked,page.entity) or_continue
                for &held,k in row.instances[:min(int(row.count),MARKED_PAGE)] {
                    if held.id!=request.plant.id {continue}
                    if held.color!=request.color {
                        if edited:=core.edit(marked,page.entity);edited!=nil {edited.instances[k].color=request.color}
                    }
                    continue asks
                }
            }
            for &held in fresh {if held.id==request.plant.id {held.color=request.color;continue asks}}
            append(&fresh,Marked_Instance{request.plant.id,request.color})
        }
        marked_write(marked,pages,id,e,coord,fresh[:],commands)
    }
}

// Puts new marks of a cell in the entities of the cell with room, and what
// does not fit in new ones under the Foliage.
@(private)
marked_write :: proc(marked:^core.Table(Foliage_Marked),pages:[]pcg.Suppressed_Page,foliage:base.Entity_Id,e:core.Entity,coord:[2]i32,fresh:[]Marked_Instance,commands:core.Commands) {
    left:=fresh
    for &page in pages {
        if len(left)==0 {return}
        if page.count>=MARKED_PAGE {continue}
        row:=core.edit(marked,page.entity)
        if row==nil {continue}
        n:=min(len(left),MARKED_PAGE-page.count)
        copy(row.instances[page.count:],left[:n])
        page.count+=n
        row.count=u32(page.count)
        left=left[n:]
    }
    for len(left)>0 {
        value:=Foliage_Marked{foliage=foliage,coord=coord}
        n:=min(len(left),MARKED_PAGE)
        copy(value.instances[:],left[:n])
        value.count=u32(n)
        left=left[n:]
        made:=core.commands_create(commands)
        core.commands_add(commands,made,core.Parent{entity=e})
        core.commands_add(commands,made,core.TRANSFORM_IDENTITY)
        core.add(marked,made,value)
    }
}
