package scene

import "core:fmt"
import "core:mem"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:std/base"
import "mirai:std/serial"

// A component a document stores otherwise than the world reads it: one the
// world does not have, or one stored with another layout, which is read by
// field names (serial.Migration). Its texts are of the allocator of the list
// it was added to.
Stored :: struct {
    scene:base.Asset_Id,
    component:string,
    unknown:bool,          // the world has no component by that name: a save carries its values, and nothing reads them
    removed:[]string,      // stored fields the component has under no name now: a save loses their values
    incompatible:[]string, // stored fields whose values do not convert to the type they have now: they start at their default
}

// Adds to stored each component of a document that the world has no
// component for or reads from another layout. False without memory.
stored_collect :: proc(w:core.World_Ref,a:^asset.Asset,asset_types:^asset.Types,stored:^[dynamic]Stored) -> bool {
    view,error:=asset.scene_view(a,asset_types)
    if error!=.None {return true}
    types:=schema_of(w)
    if types==nil {return false}
    allocator:=stored.allocator
    for &component in view.components {
        entry:=Stored{scene=a.blob.header.id}
        if at,found:=core.world_table_index_of_hash(w,component.name_hash);!found {
            entry.unknown=true
        } else {
            value_type:=&types.tables[at]
            if is_structural(w.info.tables[at].type) || value_type.type==serial.TYPE_NONE || asset.asset_column_matches(a,component.table,1,value_type.hash) {continue}
            m:serial.Migration
            if serial.migration_init(&m,&a.schema,component.table.columns[1].type,&types.schema,value_type.type,context.temp_allocator)!=.None {return false}
            defer serial.migration_destroy(&m)
            if entry.removed,entry.incompatible=texts_clone(m.removed[:],allocator),texts_clone(m.incompatible[:],allocator);len(entry.removed)<len(m.removed) || len(entry.incompatible)<len(m.incompatible) {return false}
        }
        no_name:mem.Allocator_Error
        if entry.component,no_name=strings.clone(component.name,allocator);no_name!=nil {return false}
        if _,no_room:=append(stored,entry);no_room!=nil {return false}
    }
    return true
}

// Copies of texts, as many as memory had room for.
@(private="file")
texts_clone :: proc(texts:[]string,allocator:=context.allocator) -> []string {
    copied,no_list:=make([]string,len(texts),allocator)
    if no_list!=nil {return nil}
    for text,i in texts {
        no_text:mem.Allocator_Error
        if copied[i],no_text=strings.clone(text,allocator);no_text!=nil {return copied[:i]}
    }
    return copied
}

// What a person or an agent reads of a component a document stores otherwise,
// naming the scene by name, in temporary memory. warning: a save loses values,
// or nothing reads them; otherwise it only says the values were read from
// another layout.
stored_text :: proc(entry:Stored,scene:string) -> (text:string,warning:bool) {
    if entry.unknown {return fmt.tprintf("%s: the component %s is not one of this game: a save keeps its values and nothing reads them; add the plugin or the code that declares it, or take it off the entities (mirai scene write with \"replace\": false and \"%s\": null)",scene,entry.component,entry.component),true}
    b:=strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b,"%s: %s is stored with another layout and read by the names of its fields",scene,entry.component)
    if len(entry.removed)>0 {fmt.sbprintf(&b,"; saving the scene loses the stored fields %v, which it has under no name now: a renamed field says the names it had with the tag mirai:\"was=<earlier name>\"",entry.removed)}
    if len(entry.incompatible)>0 {fmt.sbprintf(&b,"; the stored fields %v do not convert to the types they have now, and start at their default",entry.incompatible)}
    return strings.to_string(b),len(entry.removed)+len(entry.incompatible)>0
}
