package host

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:slice"
import "mirai:core"
import "mirai:std/base"

// Every asset id the tables and the storages of a world hold, each once,
// found by the type of each field, so the components of plugins and of the
// game count like those of the engine: in structs, arrays, enumerated arrays,
// slices and dynamic arrays; not behind pointers nor in maps. With shared and
// the id of the World, also its values of the by_world storages. With owned,
// only those of fields tagged `mirai:"owned"` (or inside one): assets the
// scene makes and saves with it, as the .navmesh of its navigation.
world_asset_ids :: proc(w:core.World_Ref,ids:^[dynamic]base.Asset_Id,owned:=false,shared:rawptr=nil,id:=core.World_Id{}) {
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for &t in w.info.tables {
        if t.place!=w.place {continue}
        plan,_:=ids_plan(t.info,owned,context.temp_allocator)
        if ids_plan_empty(&plan) {continue}
        table:=core.world_table_at(w,&t)
        for row in 0..<core.raw_count(table) {ids_take(&plan,core.raw_value(table,t.info,row),&seen,ids)}
    }
    for &s in w.info.storages {
        value:=storage_value(w,&s,shared,id)
        if value==nil {continue}
        plan,_:=ids_plan(s.info,owned,context.temp_allocator)
        if !ids_plan_empty(&plan) {ids_take(&plan,value,&seen,ids)}
    }
}

// The asset ids the components of an entity hold, each once.
entity_asset_ids :: proc(w:core.World_Ref,e:core.Entity,ids:^[dynamic]base.Asset_Id) {
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for &t in w.info.tables {
        if t.place!=w.place {continue}
        plan,_:=ids_plan(t.info,false,context.temp_allocator)
        if ids_plan_empty(&plan) {continue}
        if value:=core.raw_find(core.world_table_at(w,&t),t.info,e);value!=nil {ids_take(&plan,value,&seen,ids)}
    }
}

// The value of a storage of a world: in it, or its own value of a by_world one.
@(private="file")
storage_value :: proc(w:core.World_Ref,s:^core.Storage_Info,shared:rawptr,id:core.World_Id) -> rawptr {
    switch {
    case s.by_world:       if shared!=nil && id.generation!=0 {return core.by_world_get(cast(^core.By_World(u8))(uintptr(shared)+s.offset),id)}
    case s.place==w.place: return rawptr(uintptr(w.data)+s.offset)
    }
    return nil
}

// Where a type holds asset ids: offsets of fields of type base.Asset_Id in
// its fixed part, and the slices and dynamic arrays whose elements hold some,
// each with the plan of its elements. Making one answers false without
// memory for all of it.
@(private="file")
Ids_Plan :: struct {
    offsets:[dynamic]uintptr,
    lists:[dynamic]Ids_List,
}

@(private="file")
Ids_List :: struct {
    offset:uintptr,
    size:int, // of an element
    plan:^Ids_Plan,
}

@(private="file")
ids_plan :: proc(info:^runtime.Type_Info,owned:bool,allocator:mem.Allocator) -> (plan:Ids_Plan,ok:bool) {
    ok=ids_plan_add(&plan,info,0,owned,false,0,allocator)
    return
}

@(private="file")
ids_plan_empty :: proc(plan:^Ids_Plan) -> bool {return len(plan.offsets)==0 && len(plan.lists)==0}

@(private="file")
ids_plan_free :: proc(plan:^Ids_Plan) {
    for list in plan.lists {
        ids_plan_free(list.plan)
        free(list.plan,plan.lists.allocator)
    }
    delete(plan.offsets);delete(plan.lists)
    plan^={}
}

@(private="file")
ids_plan_add :: proc(plan:^Ids_Plan,info:^runtime.Type_Info,at:uintptr,owned,inside:bool,depth:int,allocator:mem.Allocator) -> bool {
    if depth>16 {return true}
    if info.id==base.Asset_Id {
        if !owned || inside {
            if plan.offsets.allocator.procedure==nil {plan.offsets.allocator=allocator}
            if _,error:=append(&plan.offsets,at);error!=nil {return false}
        }
        return true
    }
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {ids_plan_add(plan,v.types[i],at+v.offsets[i],owned,inside || owned && v.tags!=nil && field_owned(v.tags[i]),depth+1,allocator) or_return}
    case runtime.Type_Info_Array:
        if !ids_hold(v.elem,depth+1) {return true}
        for i in 0..<v.count {ids_plan_add(plan,v.elem,at+uintptr(i*v.elem_size),owned,inside,depth+1,allocator) or_return}
    case runtime.Type_Info_Enumerated_Array:
        if !ids_hold(v.elem,depth+1) {return true}
        for i in 0..<v.count {ids_plan_add(plan,v.elem,at+uintptr(i*v.elem_size),owned,inside,depth+1,allocator) or_return}
    case runtime.Type_Info_Slice:
        return ids_plan_list(plan,v.elem,at,owned,inside,depth+1,allocator)
    case runtime.Type_Info_Dynamic_Array:
        return ids_plan_list(plan,v.elem,at,owned,inside,depth+1,allocator)
    }
    return true
}

// A slice or a dynamic array at at whose elements hold asset ids.
@(private="file")
ids_plan_list :: proc(plan:^Ids_Plan,elem:^runtime.Type_Info,at:uintptr,owned,inside:bool,depth:int,allocator:mem.Allocator) -> bool {
    if !ids_hold(elem,depth) {return true}
    nested,error:=new(Ids_Plan,allocator)
    if error!=nil {return false}
    made:=ids_plan_add(nested,elem,0,owned,inside,depth,allocator)
    if made && ids_plan_empty(nested) {
        free(nested,allocator)
        return true
    }
    if plan.lists.allocator.procedure==nil {plan.lists.allocator=allocator}
    if made {_,error=append(&plan.lists,Ids_List{at,elem.size,nested})}
    if !made || error!=nil {
        ids_plan_free(nested)
        free(nested,allocator)
        return false
    }
    return true
}

// Whether a value of the type can hold an asset id the plan reaches.
@(private="file")
ids_hold :: proc(info:^runtime.Type_Info,depth:int) -> bool {
    if depth>16 {return false}
    if info.id==base.Asset_Id {return true}
    #partial switch v in runtime.type_info_base(info).variant {
    case runtime.Type_Info_Struct:
        for i in 0..<int(v.field_count) {if ids_hold(v.types[i],depth+1) {return true}}
    case runtime.Type_Info_Array:            return ids_hold(v.elem,depth+1)
    case runtime.Type_Info_Enumerated_Array: return ids_hold(v.elem,depth+1)
    case runtime.Type_Info_Slice:            return ids_hold(v.elem,depth+1)
    case runtime.Type_Info_Dynamic_Array:    return ids_hold(v.elem,depth+1)
    }
    return false
}

@(private="file")
ids_take :: proc(plan:^Ids_Plan,value:rawptr,seen:^map[base.Asset_Id]bool,ids:^[dynamic]base.Asset_Id) {
    for offset in plan.offsets {
        id:base.Asset_Id
        intrinsics.mem_copy_non_overlapping(&id,rawptr(uintptr(value)+offset),size_of(id))
        if id!={} && !seen[id] {
            seen[id]=true
            append(ids,id)
        }
    }
    for list in plan.lists {
        // A slice and a dynamic array both begin with their data and their length.
        raw:=cast(^runtime.Raw_Slice)(uintptr(value)+list.offset)
        if raw.data==nil || raw.len<=0 {continue}
        for i in 0..<raw.len {ids_take(list.plan,rawptr(uintptr(raw.data)+uintptr(i*list.size)),seen,ids)}
    }
}

@(private="file")
field_owned :: proc(tag:string) -> bool {
    _,owned:=core.field_option(reflect.Struct_Tag(tag),"owned")
    return owned
}

// What loaded assets the Worlds of the application use, marked between
// frames: at most every ASSETS_MARK_SECONDS, a World marks again the columns
// with base.Asset_Id fields whose table changed (by its version and layout)
// and keeps what the others marked; its storages, few, are read each time.
// What all of them mark is one scope. When it changed, or a World went away,
// what no scope reaches unloads at once (assets_collect, content_collect):
// nothing loaded since the mark is unloaded by an older one. app.scratch does
// not count, nor a World a job builds (app_assets_building).
ASSETS_MARK_SECONDS :: 0.5

Assets_Marks :: struct {
    last:f64, // app.seconds of the last mark; negative: never
    pending:bool, // a mark ended without memory: the next one sets the scope whatever changed
    worlds:[dynamic]World_Marks, // at the index of the World_Id
    building:[dynamic]rawptr,    // Worlds a job writes: not read
    // Where the types of the World_Info hold asset ids, made once for it.
    info:^core.World_Info,
    tables:[dynamic]Ids_Plan,   // at the index of the table in World_Info.tables
    storages:[dynamic]Ids_Plan, // at the index of the storage
}

@(private)
World_Marks :: struct {
    data:rawptr,
    generation:u32,
    columns:[dynamic]Column_Marks, // at the index of the table in World_Info.tables
    storages:[dynamic]base.Asset_Id, // what its storages named at the last mark, in order
    ids:[dynamic]base.Asset_Id,      // what it marked, in order
    stale:bool,                      // ids is behind columns and storages: a mark ended without memory
}

@(private)
Column_Marks :: struct {
    seen:core.Seen, // the table when it was marked
    marked:bool,
    ids:[dynamic]base.Asset_Id, // in order
}

assets_marks_free :: proc(m:^Assets_Marks) {
    for &w in m.worlds {world_marks_free(&w)}
    delete(m.worlds);delete(m.building)
    marks_plans_free(m)
    m^={}
}

@(private="file")
world_marks_free :: proc(w:^World_Marks) {
    for &c in w.columns {delete(c.ids)}
    delete(w.columns);delete(w.storages);delete(w.ids)
    w^={}
}

@(private="file")
marks_plans_free :: proc(m:^Assets_Marks) {
    for &plan in m.tables {ids_plan_free(&plan)}
    for &plan in m.storages {ids_plan_free(&plan)}
    delete(m.tables);delete(m.storages)
    m.tables,m.storages,m.info={},{},nil
}

// A job writes the World data from now on (building), or stopped: the marks
// do not read it meanwhile, and what it names counts once it stopped.
app_assets_building :: proc(app:^App,data:rawptr,building:bool) {
    m:=&app.asset_marks
    at,found:=slice.linear_search(m.building[:],data)
    switch {
    case building && !found:
        if m.building.allocator.procedure==nil {m.building.allocator=app.allocator}
        append(&m.building,data)
    case !building && found:
        unordered_remove(&m.building,at)
        if len(m.building)==0 {
            delete(m.building)
            m.building={}
        }
    }
}

// Marks what the Worlds use and unloads what none does, when it is time.
// Returns how many entries it unloaded.
app_assets_mark :: proc(app:^App,force:=false) -> (unloaded:int) {
    a:=app.assets
    m:=&app.asset_marks
    if a==nil || app.info==nil || !force && m.last>0 && app.seconds-m.last<ASSETS_MARK_SECONDS {return}
    m.last=max(app.seconds,1e-9)
    if (m.info!=app.info || len(m.tables)!=len(app.info.tables) || len(m.storages)!=len(app.info.storages)) && !marks_plans_make(m,app.info,app.allocator) {return}
    if len(m.worlds)<len(app.worlds) {
        m.worlds.allocator=app.allocator
        if resize(&m.worlds,len(app.worlds))!=nil {return}
    }
    changed:=m.pending
    m.pending=true
    for &marks,at in m.worlds {
        slot:World_Slot
        if at<len(app.worlds) {slot=app.worlds[at]}
        if marks.data!=nil && (marks.data!=slot.data || marks.generation!=slot.generation || len(marks.columns)!=len(app.info.tables)) {
            world_marks_free(&marks)
            changed=true
        }
        if slot.data==nil || slot.data==app.scratch || slice.contains(m.building[:],slot.data) {continue}
        if marks.data==nil {
            columns,error:=make([dynamic]Column_Marks,len(app.info.tables),app.allocator)
            if error!=nil {return}
            marks.data,marks.generation=slot.data,slot.generation
            marks.columns=columns
            marks.storages=make([dynamic]base.Asset_Id,app.allocator)
            marks.ids=make([dynamic]base.Asset_Id,app.allocator)
        }
        updated,marked:=world_mark(m,&marks,app_world_ref(app,slot.data),app.shared,{u32(at),slot.generation})
        if !marked {return}
        changed|=updated
    }
    if !changed {
        m.pending=false
        return
    }
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    ids:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for marks in m.worlds {
        for id in marks.ids {
            if !seen[id] {
                seen[id]=true
                append(&ids,id)
            }
        }
    }
    if !assets_scope_set(a,assets_scope_of(a,m),ids[:]) {return}
    m.pending=false
    return assets_collect(a)+content_collect(app)
}

@(private="file")
marks_plans_make :: proc(m:^Assets_Marks,info:^core.World_Info,allocator:mem.Allocator) -> bool {
    marks_plans_free(m)
    error:runtime.Allocator_Error
    if m.tables,error=make([dynamic]Ids_Plan,len(info.tables),allocator);error!=nil {return false}
    if m.storages,error=make([dynamic]Ids_Plan,len(info.storages),allocator);error!=nil {
        marks_plans_free(m)
        return false
    }
    ok:=true
    for &t,at in info.tables {
        made:bool
        m.tables[at],made=ids_plan(t.info,false,allocator)
        ok&&=made
    }
    for &s,at in info.storages {
        made:bool
        m.storages[at],made=ids_plan(s.info,false,allocator)
        ok&&=made
    }
    if !ok {
        marks_plans_free(m)
        return false
    }
    m.info=info
    return true
}

// Marks again what changed of a World; changed when what it marks did. Not ok
// without memory: what it could not mark it marks the next time.
@(private="file")
world_mark :: proc(m:^Assets_Marks,marks:^World_Marks,w:core.World_Ref,shared:rawptr,id:core.World_Id) -> (changed,ok:bool) {
    found:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for &t,at in w.info.tables {
        if t.place!=w.place || ids_plan_empty(&m.tables[at]) {continue}
        table:=core.world_table_at(w,&t)
        column:=&marks.columns[at]
        now:=column.seen
        if !core.raw_touched(table,&now) && column.marked {continue}
        clear(&found)
        seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
        for row in 0..<core.raw_count(table) {ids_take(&m.tables[at],core.raw_value(table,t.info,row),&seen,&found)}
        updated:=ids_update(&column.ids,found[:],marks.ids.allocator) or_return
        column.marked,column.seen=true,now
        marks.stale||=updated
    }
    clear(&found)
    seen:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for &s,at in w.info.storages {
        if ids_plan_empty(&m.storages[at]) {continue}
        if value:=storage_value(w,&s,shared,id);value!=nil {ids_take(&m.storages[at],value,&seen,&found)}
    }
    updated:=ids_update(&marks.storages,found[:],marks.ids.allocator) or_return
    marks.stale||=updated
    if !marks.stale {return false,true}
    clear(&found)
    for c in marks.columns {append(&found,..c.ids[:])}
    append(&found,..marks.storages[:])
    changed=ids_update(&marks.ids,found[:],marks.ids.allocator) or_return
    marks.stale=false
    return changed,true
}

// Makes held the ids of found in order, each once; changed when that changed
// it. Not ok without memory: held as it was.
@(private="file")
ids_update :: proc(held:^[dynamic]base.Asset_Id,found:[]base.Asset_Id,allocator:mem.Allocator) -> (changed,ok:bool) {
    slice.sort_by(found,proc(a,b:base.Asset_Id) -> bool {return a[0]<b[0] || a[0]==b[0] && a[1]<b[1]})
    unique:=0
    for id in found {
        if unique>0 && id==found[unique-1] {continue}
        found[unique]=id
        unique+=1
    }
    if slice.equal(held[:],found[:unique]) {return false,true}
    if held.allocator.procedure==nil {held.allocator=allocator}
    if reserve(held,unique)!=nil {return false,false}
    clear(held)
    append(held,..found[:unique])
    return true,true
}
