package author

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import escene "mirai:engine/scene"
import "mirai:std/base"

// A recipe: a prefab of one entity in a recipes folder of the engine or of a
// plugin (project.recipe_folders). Create, the API and a document place a
// copy of its entity: its components, and of its transform the rotation and
// the scale; its height is how far above what it is placed on one with no body
// stands. The name of its file is the one a document gives in preset.
Recipe :: struct {
    name:string,  // of its file, without .scene
    path:string,
    label:string, // the name of its entity: that of its card and of what it makes
    local:core.Transform,
}

// The recipes of the folders, each folder in the order of its names; a name
// an earlier folder has, and a file that is not a prefab of one entity, are
// left out.
recipes_read :: proc(folders:[]string,allocator:=context.allocator) -> []Recipe {
    out:=make([dynamic]Recipe,allocator)
    types:asset.Types
    asset.types_init(&types,context.temp_allocator)
    for folder in folders {
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {continue}
        slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        next: for entry in entries {
            if entry.type==.Directory || !strings.has_suffix(entry.name,".scene") {continue}
            name:=entry.name[:len(entry.name)-len(".scene")]
            for known in out {if known.name==name {continue next}}
            path:=strings.concatenate({folder,"/",entry.name},context.temp_allocator)
            scene:asset.Scene
            if asset.scene_load(&scene,&types,path,context.temp_allocator)!=.None || .Prefab not_in scene.doc.flags || asset.scene_entity_count(&scene)!=1 {continue}
            record:=asset.scene_entity(&scene,0)
            identity:=core.TRANSFORM_IDENTITY
            local,_:=asset.scene_get(&scene,record.id,"Transform",core.Transform,&identity)
            append(&out,Recipe{strings.clone(name,allocator),strings.clone(path,allocator),strings.clone(record.name,allocator),local})
        }
    }
    return out[:]
}

recipes_free :: proc(recipes:[]Recipe,allocator:=context.allocator) {
    for recipe in recipes {
        delete(recipe.name,allocator)
        delete(recipe.path,allocator)
        delete(recipe.label,allocator)
    }
    delete(recipes,allocator)
}

// The recipe a name means, as base.name_find takes it.
recipe_named :: proc(recipes:[]Recipe,name:string) -> (index:int,found:bool) {
    names:=make([]string,len(recipes),context.temp_allocator)
    for recipe,i in recipes {names[i]=recipe.name}
    index,_=base.name_find(name,names)
    return index,index>=0
}

// What is wrong with a name recipe_named does not take, with the nearest ones.
recipe_problem :: proc(recipes:[]Recipe,name:string) -> string {
    names:=make([]string,len(recipes),context.temp_allocator)
    for recipe,i in recipes {names[i]=recipe.name}
    return base.name_problem(name,"a recipe",names)
}

// The offsets of the Entity fields of a type.
entity_offsets :: proc(type:^runtime.Type_Info,allocator:=context.temp_allocator) -> []uintptr {
    out:=make([dynamic]uintptr,allocator)
    walk :: proc(info:^runtime.Type_Info,at:uintptr,out:^[dynamic]uintptr) {
        if info.id==core.Entity {append(out,at);return}
        #partial switch v in runtime.type_info_base(info).variant {
        case runtime.Type_Info_Struct:
            for i in 0..<int(v.field_count) {walk(v.types[i],at+v.offsets[i],out)}
        case runtime.Type_Info_Array:
            for i in 0..<v.count {walk(v.elem,at+uintptr(i*v.elem_size),out)}
        }
    }
    walk(type,0,&out)
    return out[:]
}

// A component of an entity a recipe made, as a document shows its value: its
// Entity fields name none.
Part :: struct {
    t:^core.Table_Info,
    value:[]u8,
}

// The components an entity has that a document writes by name, in the order
// of the tables of its world.
entity_parts :: proc(w:core.World_Ref,e:core.Entity,allocator:runtime.Allocator) -> []Part {
    parts:=make([dynamic]Part,allocator)
    for &t in w.info.tables {
        if t.place!=.World || !component_listed(&t) {continue}
        value:=core.raw_find(core.world_table_at(w,&t),t.info,e)
        if value==nil {continue}
        bytes:=make([]u8,max(t.info.size,1),allocator)
        if t.info.size>0 {mem.copy(raw_data(bytes),value,t.info.size)}
        for offset in entity_offsets(t.info) {(cast(^u64)&bytes[offset])^=0}
        append(&parts,Part{&t,bytes[:t.info.size]})
    }
    return parts[:]
}

// A world of a game that holds nothing, to run a recipe on with no editor.
Scratch_World :: struct {
    w:core.World_Ref,
    allocator:runtime.Allocator,
}

scratch_world_make :: proc(info:^core.World_Info,allocator:=context.allocator) -> (scratch:Scratch_World,ok:bool) {
    if info==nil || info.sizes[.World]<=0 {return}
    data,error:=mem.alloc(info.sizes[.World],max(info.aligns[.World],1),allocator)
    if error!=nil {return}
    if !core.world_init(info,.World,data,allocator) {
        core.world_destroy(info,.World,data)
        mem.free(data,allocator)
        return
    }
    return {core.world_ref(data,info),allocator},true
}

scratch_world_free :: proc(scratch:^Scratch_World) {
    if scratch.w.data==nil {return}
    core.world_destroy(scratch.w.info,.World,scratch.w.data)
    mem.free(scratch.w.data,scratch.allocator)
    scratch^={}
}

// The components the entity of a recipe gives, as w lays them out: it is
// placed in w and goes at once. problem: why there are none.
recipe_parts :: proc(w:core.World_Ref,types:^asset.Types,recipe:Recipe,allocator:runtime.Allocator) -> (parts:[]Part,problem:string) {
    bytes,error:=os.read_entire_file(recipe.path,context.temp_allocator)
    if error!=nil {return nil,fmt.tprintf("the recipe %s could not be read",recipe.path)}
    file:asset.Asset
    if asset.asset_open(&file,bytes,context.temp_allocator)!=.None {return nil,fmt.tprintf("the recipe %s is not a scene; mirai asset verify says what its file has",recipe.path)}
    defer asset.asset_close(&file)
    report,placed:=escene.instantiate(w,&file,types,{transient=true})
    if placed!=.None {return nil,fmt.tprintf("the recipe %s could not be placed: %s",recipe.path,escene.error_text(placed))}
    core.world_settle(w)
    parts=entity_parts(w,report.root,allocator)
    core.world_destroy_tree(w,report.root)
    core.world_settle(w)
    return parts,""
}
