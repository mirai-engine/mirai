package editor

import "core:slice"
import "mirai:core"
import "mirai:editor/history"
import scene "mirai:engine/scene"
import "mirai:std/base"

// What the editor keeps of the worlds by the index of their tables, or in the
// layout of their values, follows a migration of the worlds (reload.odin).

// The history of a World whose layout migrated: its steps name the tables by
// their new index and hold their values in the new layout, and the image is
// taken again from the World, which holds what it held: it was committed.
edits_relayout :: proc(edits:^history.Edits,w:core.World_Ref,m:^core.World_Migration) {
    for &step in edits.steps {
        for i:=len(step.tables)-1;i>=0;i-=1 {
            rows:=&step.tables[i]
            to:=rows.table>=0 && rows.table<len(m.table_map)?m.table_map[rows.table]:-1
            if to>=0 && m.tables[to]==.Convert {
                if !step_side_convert(m,to,&rows.other,len(rows.entities)) || !step_side_convert(m,to,&rows.held,len(rows.entities)) {to=-1}
            }
            if to<0 {
                history.rows_free(rows)
                ordered_remove(&step.tables,i)
                continue
            }
            rows.table=to
        }
    }
    history.journal_changes_drop(edits)
    for &image in edits.image {history.journal_table_free(&image)}
    clear(&edits.image)
    for ranges in edits.ranges {delete(ranges.ranges)}
    clear(&edits.ranges)
    history.edits_image_take(edits,w)
}

@(private="file")
step_side_convert :: proc(m:^core.World_Migration,to:int,side:^history.Step_Side,count:int) -> bool {
    from:=&m.from.tables[m.table_sources[to]]
    if len(side.values)!=count*from.info.size {return false}
    converted:=core.table_values_convert(m,to,side.values[:],count)
    if converted==nil && count>0 && m.to.tables[to].info.size>0 {return false}
    clear(&side.values)
    append(&side.values,..converted)
    delete(converted)
    return true
}

// The rows a review keeps, by the new index of their tables and in the new
// layout of their values. A row of a table that is gone goes.
change_rows_relayout :: proc(set:^history.Change_Set,m:^core.World_Migration) {
    for i:=len(set.rows)-1;i>=0;i-=1 {
        row:=&set.rows[i]
        to:=row.table>=0 && row.table<len(m.table_map)?m.table_map[row.table]:-1
        if to>=0 && m.tables[to]==.Convert {
            ok:=true
            if row.before_present {ok&&=change_value_convert(m,to,&row.before)}
            if row.after_present {ok&&=change_value_convert(m,to,&row.after)}
            if ok {row.layout=history.change_layout(m.to.tables[to].info)} else {to=-1}
        }
        if to<0 {
            delete(row.before);delete(row.after)
            ordered_remove(&set.rows,i)
            continue
        }
        row.table=to
    }
}

@(private="file")
change_value_convert :: proc(m:^core.World_Migration,to:int,value:^[]u8) -> bool {
    from:=&m.from.tables[m.table_sources[to]]
    if len(value^)!=from.info.size {return false}
    converted:=core.table_values_convert(m,to,value^,1)
    if converted==nil && m.to.tables[to].info.size>0 {return false}
    delete(value^)
    value^=converted
    return true
}

// What the sections and their references keep by table: the records of the
// loaded sections take the new indices, the editor's watch sees every table
// again, and a reference waiting in a component whose layout changed is
// forgotten (its offset is of the old layout).
sections_relayout :: proc(s:^Session,m:^core.World_Migration) {
    converted:=make([dynamic]u64,context.temp_allocator)
    for kind,i in m.tables {
        if kind==.Convert {append(&converted,base.name_hash(m.to.tables[i].name))}
    }
    keeps:=core.world_migration_keeps_indices(m)
    for slot in s.app.worlds {
        if slot.data==nil {continue}
        w:=core.world_ref(slot.data,s.info)
        if unresolved:=core.world_storage_of(w,scene.Unresolved_References);unresolved!=nil && len(converted)>0 {
            for i:=len(unresolved.items)-1;i>=0;i-=1 {
                if slice.contains(converted[:],unresolved.items[i].table) {ordered_remove(&unresolved.items,i)}
            }
        }
        records:=core.world_storage_of(w,scene.Section_Records)
        if keeps || records==nil {continue}
        for &record in records.items {
            if record.seen!=nil {record.seen=indices_relayout(record.seen,m)}
            if record.fresh!=nil {record.fresh=indices_relayout(record.fresh,m)}
        }
    }
    if watch:=core.world_storage_of(core.world_ref(s.editor_world,s.info,.Editor),Sections_Watch);watch!=nil {clear(&watch.seen)}
    // What a panel changed is kept by offsets of the old layout: Restore no longer applies to it.
    clear(&s.panels.kept)
    clear(&s.panels.kept_bytes)
}

// An array by table of the old layout, by table of the new one: a new table
// starts at zero.
@(private="file")
indices_relayout :: proc(values:[]$T,m:^core.World_Migration) -> []T {
    out:=make([]T,len(m.to.tables))
    for from,i in values {
        if i<len(m.table_map) && m.table_map[i]>=0 {out[m.table_map[i]]=from}
    }
    delete(values)
    return out
}
