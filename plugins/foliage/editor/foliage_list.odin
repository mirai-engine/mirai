package foliage_editor

import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:core"
import foliage "plugins:foliage/runtime"

// What the list of types knows: which ones the search shows, which ones the
// brush paints, and how many instances of each the Foliage the tool edits
// shows.

COUNT_CELLS :: 64 // cells a frame counts at most

// The instances of each type of the source of a Foliage, counted by cell
// from what foliage_load read: a frame counts again only the cells whose
// version or ground changed, and nothing when none did.
Counts :: struct {
    key:Counts_Key,
    pending:bool, // cells are left to count: their version is 0
    cells,next_cells:[dynamic]Count_Cell,
    types,next_types:[dynamic]Type_Count, // those of each cell, in its range
    totals:[dynamic]Type_Count,           // by id, once every cell is counted
}
// What the counts come from: a frame with the same key and nothing pending counts nothing.
Counts_Key :: struct {entity:core.Entity,epoch:u64,loads:u32,ground:u32}
Count_Cell :: struct {coord:[2]i32,version,ground:u32,first,count:u32}
Type_Count :: struct {type,count:u32}

counts_free :: proc(c:^Counts) {
    delete(c.cells);delete(c.next_cells);delete(c.types);delete(c.next_types);delete(c.totals)
    c^={}
}

// Counts the cells of a source whose version or ground (the revision of its
// tile, for a cell that generates) changed, up to budget of them, and the
// totals once none is left. How many it counted.
counts_update :: proc(c:^Counts,s:^foliage.Source,key:Counts_Key,ground:^foliage.Ground_Owner,work:^foliage.Build_Work,budget:=COUNT_CELLS) -> (built:int) {
    if key==c.key && !c.pending {return}
    if key.entity!=c.key.entity || key.epoch!=c.key.epoch {clear(&c.cells);clear(&c.types);clear(&c.totals)}
    c.key,c.pending=key,false
    clear(&c.next_cells);clear(&c.next_types)
    j:=0
    for &cell in s.cells {
        for j<len(c.cells) && cell_before(c.cells[j].coord,cell.coord) {j+=1}
        old:^Count_Cell
        if j<len(c.cells) && c.cells[j].coord==cell.coord {old=&c.cells[j]}
        tile:foliage.Ground_Cell
        revision:u32
        if cell.generate {tile,revision=foliage.ground_cell(ground,cell.coord)}
        next:=Count_Cell{coord=cell.coord,version=cell.version,ground=revision,first=u32(len(c.next_types))}
        switch {
        case old!=nil && old.version!=0 && old.version==cell.version && old.ground==revision:
            append(&c.next_types,..c.types[old.first:][:old.count])
        case built<budget && foliage.cell_build(s,&cell,tile,work) && foliage.placed_group(s,work):
            built+=1
            for t,i in s.types {
                if n:=work.firsts[i+1]-work.firsts[i];n>0 {append(&c.next_types,Type_Count{t.id,n})}
            }
        case:
            // Left for a later frame with what it had.
            if old!=nil {append(&c.next_types,..c.types[old.first:][:old.count])}
            next.version=0
            c.pending=true
        }
        next.count=u32(len(c.next_types))-next.first
        append(&c.next_cells,next)
    }
    c.cells,c.next_cells=c.next_cells,c.cells
    c.types,c.next_types=c.next_types,c.types
    if c.pending {return}
    clear(&c.totals)
    for t in s.types {append(&c.totals,Type_Count{type=t.id})}
    slice.sort_by(c.totals[:],proc(a,b:Type_Count) -> bool {return a.type<b.type})
    for counted in c.types {
        if at,found:=slice.binary_search_by(c.totals[:],counted.type,type_order);found {c.totals[at].count+=counted.count}
    }
    return
}

// The order of the cells of a source: z, then x.
@(private)
cell_before :: proc "contextless" (a,b:[2]i32) -> bool {return a.y<b.y || a.y==b.y && a.x<b.x}

@(private)
type_order :: proc(a:Type_Count,type:u32) -> slice.Ordering {
    return .Less if a.type<type else (.Greater if a.type>type else .Equal)
}

// The instances of a type; not known until every cell was counted once.
counts_total :: proc(c:^Counts,type:u32) -> (count:u32,known:bool) {
    at,found:=slice.binary_search_by(c.totals[:],type,type_order)
    if !found {return}
    return c.totals[at].count,true
}

// The instances a cell shows, of every type: 0 for one the source does not have.
counts_cell :: proc(c:^Counts,coord:[2]i32) -> (count:u32,known:bool) {
    at,found:=slice.binary_search_by(c.cells[:],coord,proc(a:Count_Cell,coord:[2]i32) -> slice.Ordering {
        if a.coord==coord {return .Equal}
        return .Less if cell_before(a.coord,coord) else .Greater
    })
    if !found {return 0,!c.pending && len(c.totals)>0}
    cell:=c.cells[at]
    if cell.version==0 {return}
    for counted in c.types[cell.first:][:cell.count] {count+=counted.count}
    return count,true
}

// A count with its thousands apart, as Terrain3D writes it.
count_text :: proc(count:u32,allocator:=context.temp_allocator) -> string {
    digits:=fmt.tprintf("%d",count)
    b:=strings.builder_make(allocator)
    for c,i in transmute([]u8)digits {
        if i>0 && (len(digits)-i)%3==0 {strings.write_byte(&b,',')}
        strings.write_byte(&b,c)
    }
    return strings.to_string(b)
}

// Whether the search shows a type by its name: the search anywhere in it,
// in capitals or not; an empty search shows every type.
type_matches :: proc(name,search:string) -> bool {
    needle:=strings.trim_space(search)
    if len(needle)>len(name) {return false}
    for i in 0..=len(name)-len(needle) {
        if strings.equal_fold(name[i:][:len(needle)],needle) {return true}
    }
    return false
}

// What a click on the card of a type does to the types the brush paints, as
// in the list of Terrain3D: alone it takes that type alone; with Ctrl (Cmd)
// it adds it or takes it out, keeping one; with Shift it takes those the
// list shows from the last one taken alone or added up to it, and with Ctrl
// too it keeps the others. shown: the ids of the cards, in their order.
types_click :: proc(tool:^Foliage_Tool,shown:[]u32,id:u32,toggle,extend:bool) {
    from,to:=-1,-1
    if extend {
        a,has_anchor:=slice.linear_search(shown,tool.anchor)
        b,has_id:=slice.linear_search(shown,id)
        if has_anchor && has_id {from,to=min(a,b),max(a,b)}
    }
    if from<0 {
        at,found:=slice.linear_search(tool.painted[:],id)
        if toggle && found {
            if len(tool.painted)<2 {return}
            ordered_remove(&tool.painted,at)
            if tool.type==id {tool.type=tool.painted[len(tool.painted)-1]}
            return
        }
        if !toggle {clear(&tool.painted)}
        append(&tool.painted,id)
        tool.type,tool.anchor=id,id
        return
    }
    if !toggle {clear(&tool.painted)}
    for other in shown[from:to+1] {if !slice.contains(tool.painted[:],other) {append(&tool.painted,other)}}
    tool.type=id
}

// The types the brush paints are types of the source, and one at least
// while it has any: the one the panel shows.
types_keep :: proc(tool:^Foliage_Tool) {
    source:=&tool.edit.source
    for i:=len(tool.painted)-1;i>=0;i-=1 {
        if t,_:=foliage.source_type(source,tool.painted[i]);t==nil {ordered_remove(&tool.painted,i)}
    }
    if _,index:=foliage.source_type(source,tool.type);index<0 && len(source.types)>0 {tool.type=source.types[0].id}
    if len(tool.painted)==0 && len(source.types)>0 {append(&tool.painted,tool.type);tool.anchor=tool.type}
}

// The type of the instance Select took, alone in the list and in sight.
type_reveal :: proc(tool:^Foliage_Tool,type:u32) {
    clear(&tool.painted)
    append(&tool.painted,type)
    tool.type,tool.anchor,tool.reveal=type,type,type
}
