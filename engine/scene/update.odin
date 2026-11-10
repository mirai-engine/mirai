package scene

import "base:intrinsics"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

Update_Desc :: struct {
    scope:[]base.Entity_Id, // the entities the document was captured from: those it lacks go, with what hangs from them
    entities:[]core.Entity, // when given, receives the entity of every row of the document
}

// Writes a document onto the entities of a settled world that have its Ids,
// the reverse of a capture of them. An Id no entity has gets a new entity.
// Each takes the name, the parent and order the document gives it among its
// own entities, and the components it gives it; a component a capture would
// have saved and the document lacks goes. A row that already holds what the
// document says is not written, and a row written keeps its transient
// fields. The rows without a parent in the document keep the parent they
// have. Entity fields name the entity of the document with that Id, else the
// one of the world. Of desc.scope, the entities the document lacks go with
// what hangs from them: Invalid, with the world as it was, when one the
// document keeps hangs from one of those. Rows appear at the next settle;
// report.components counts the values written, added and removed.
update :: proc(w:core.World_Ref,a:^asset.Asset,asset_types:^asset.Types,desc:Update_Desc={}) -> (report:Report,error:Error) {
    es:=core.world_entities(w)
    view,view_error:=asset.scene_view(a,asset_types)
    if view_error!=.None {return {},view_error==.Invalid?.Invalid:view_error==.Out_Of_Memory?.Out_Of_Memory:.Corrupt}
    if checked:=asset.scene_view_check(view,context.temp_allocator);checked!=.None {return {},.Out_Of_Memory if checked==.Out_Of_Memory else .Corrupt}
    count:=len(view.ids)
    if desc.entities!=nil && len(desc.entities)<count {return {},.Invalid}
    types:=schema_of(w)
    if types==nil {return {},.Out_Of_Memory}
    ids:=core.world_table_of(w,core.Id)
    names:=core.world_table_of(w,core.Name)
    parent_table:=core.world_table_of(w,core.Parent)
    if ids==nil || parent_table==nil {return {},.Invalid}

    keys:=make([]Key,count,context.temp_allocator)
    parents:=make([]u32,count,context.temp_allocator)
    for id,row in view.ids {keys[row]={id,u32(row)}}
    slice.sort_by(keys,proc(a,b:Key) -> bool {return a.id<b.id})
    for parent,row in view.parents {parents[row],_=key_find(keys,parent)}
    entities:=desc.entities!=nil?desc.entities[:count]:make([]core.Entity,count,context.temp_allocator)
    created:=make([]bool,count,context.temp_allocator)
    for id,row in view.ids {
        entities[row]=core.entity_of(es,id)
        created[row]=entities[row]==core.NONE
    }

    going:=make(map[core.Entity]bool,context.temp_allocator)
    for id in desc.scope {
        if _,kept:=key_find(keys,id);kept {continue}
        if e:=core.entity_of(es,id);e!=core.NONE {going[e]=true}
    }
    if len(going)>0 {
        for e,row in entities {
            if created[row] {continue}
            at:=e
            for _ in 0..=core.HIERARCHY_DEPTH {
                parent,has:=core.get(parent_table,at)
                if !has {break}
                at=parent.entity
                if at in going {return {},.Invalid}
            }
        }
        hierarchy:=core.world_storage_of(w,core.Hierarchy)
        for e in going {
            if hierarchy!=nil {core.destroy_tree(es,core.ref(hierarchy),e)} else {core.destroy(es,e)}
        }
    }

    for id,row in view.ids {
        if created[row] {
            entities[row]=core.create(es)
            core.add(ids,entities[row],core.Id{id})
        }
        if names==nil {continue}
        name:=core.Name{text=view.names[row]}
        if held,has:=core.get(names,entities[row]);created[row] || !has || held!=name {core.add(names,entities[row],name)}
    }

    Off :: struct {entity:base.Entity_Id,component:u64}
    off:=make(map[Off]bool,context.temp_allocator)
    for record in view.off {off[{record.entity,record.component}]=true}
    values:=make([dynamic]u8,context.temp_allocator)
    scratch:=make([dynamic]u8,context.temp_allocator)
    given:=make([]bool,count,context.temp_allocator)
    for &info,at in w.info.tables {
        value_type:=&types.tables[at]
        if info.place!=w.place || is_structural(info.type) || info.type==Section_Member || value_type.type==serial.TYPE_NONE {continue}
        size:=info.info.size
        layout:=&value_type.layout
        if size>0 && len(layout.runs)==0 {continue}
        table:=core.world_table_at(w,&info)
        hash:=base.name_hash(info.name)
        slice.fill(given,false)
        component:^asset.Scene_Component
        for &candidate in view.components {
            if candidate.name_hash==hash {component=&candidate;break}
        }
        if resize(&scratch,2*size)!=nil {return report,.Out_Of_Memory}
        if component!=nil {
            if resize(&values,len(component.entities)*size)!=nil {return report,.Out_Of_Memory}
            if size>0 {
                if !component_read(a,component,types,&info,value_type,values[:]) {return report,.Corrupt}
                for i in 0..<len(component.entities) {
                    image:=values[i*size:][:size]
                    for offset in value_type.entities {
                        field:=cast(^u64)&image[offset]
                        target:=base.Entity_Id(intrinsics.unaligned_load(field))
                        live:=core.NONE
                        if target!=0 {
                            if found,known:=key_find(keys,target);known {live=entities[found]} else {live=core.entity_of(es,target)}
                            if live==core.NONE {report.dangling+=1}
                        }
                        intrinsics.unaligned_store(field,u64(live))
                    }
                }
            }
            for row,i in component.entities {
                given[row]=true
                e:=entities[row]
                value:rawptr=size>0?&values[i*size]:nil
                turned:=!table.base && off[{view.ids[row],hash}]
                _,was_turned,held:=core.raw_state(table,e)
                switch {
                case created[row] || !held:
                    core.raw_add(table,info.info,e,value)
                    report.components+=1
                    if turned {core.raw_disable(table,e)}
                    continue
                case size>0 && !saved_same(layout,core.raw_find(table,info.info,e),value,scratch[:]):
                    saved_put(layout,core.raw_edit(table,info.info,e),value)
                    report.components+=1
                }
                if turned!=was_turned {
                    if turned {core.raw_disable(table,e)} else {core.raw_enable(table,e)}
                    report.components+=1
                }
            }
        }
        for row in 0..<count {
            if given[row] {continue}
            e:=entities[row]
            if info.type==core.Transform {
                // Every entity has one: the identity where the document gives none.
                identity:=core.TRANSFORM_IDENTITY
                held:=created[row]?nil:core.raw_find(table,info.info,e)
                if held==nil {core.raw_add(table,info.info,e,&identity)} else if !saved_same(layout,held,&identity,scratch[:]) {saved_put(layout,core.raw_edit(table,info.info,e),&identity)} else {continue}
                report.components+=1
                continue
            }
            if !created[row] && core.raw_row(table,e)>=0 {
                core.raw_remove(table,e)
                report.components+=1
            }
        }
    }

    // Children keep the order of the document, as instantiate gives it.
    Place :: struct {order,row:u32}
    places:=make([]Place,count,context.temp_allocator)
    for order,row in view.orders {places[row]={order,u32(row)}}
    slice.sort_by(places,proc(a,b:Place) -> bool {return a.order<b.order || a.order==b.order && a.row<b.row})
    siblings:=make(map[u32]i32,context.temp_allocator)
    for place in places {
        parent_row:=parents[place.row]
        if parent_row==NONE_ROW {
            if report.root==core.NONE {report.root=entities[place.row]}
            continue
        }
        order:=siblings[parent_row]
        siblings[parent_row]=order+1
        wanted:=core.Parent{entities[parent_row],order}
        if held,has:=core.get(parent_table,entities[place.row]);created[place.row] || !has || held!=wanted {core.add(parent_table,entities[place.row],wanted)}
    }
    report.entities=count
    return report,.None
}

// Whether two values of a component agree in what a scene saves. scratch
// holds two of them.
@(private)
saved_same :: proc(layout:^serial.Layout,a,b:rawptr,scratch:[]u8) -> bool {
    size:=layout.size
    if size==0 {return true}
    if layout.dense {return mem.compare_ptrs(a,b,size)==0}
    serial.value_write(layout,scratch[:size],a,1)
    serial.value_write(layout,scratch[size:][:size],b,1)
    return mem.compare(scratch[:size],scratch[size:][:size])==0
}

// Copies what a scene saves of a value.
@(private)
saved_put :: proc(layout:^serial.Layout,dst,src:rawptr) {
    if layout.dense {
        mem.copy(dst,src,layout.size)
        return
    }
    for run in layout.runs {mem.copy(rawptr(uintptr(dst)+uintptr(run.offset)),rawptr(uintptr(src)+uintptr(run.offset)),int(run.size))}
}
