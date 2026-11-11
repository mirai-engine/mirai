package author

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import escene "mirai:engine/scene"
import "mirai:std/base"
import "mirai:std/serial"

// A scene of a project as the target of a document, with no world: what
// mirai scene reads and writes. Its entities are named by their ids, and its
// components are read against the types of the game (core.World_Info), whose
// values are stored as the file keeps them: an Entity field holds an id. What
// a document changes of an entity of an instance is recorded as what the
// instance holds on its own, and the components the game of this build does
// not know stay with the entities the document keeps.

// ---------------------------------------------------------------- the file

// A scene of a project open as its file, with the types its components are
// read against.
@(private="file")
Scene_File :: struct {
    p:^Project,
    scene:asset.Scene,
    info:^core.World_Info,
    ws:^core.World_Schema,
    children:map[base.Entity_Id][dynamic]base.Entity_Id, // by parent, 0 the top, in order
    stale:bool, // children is behind what the file holds
    fresh:bool, // the file is being made: its entities take the ids the document gives
}

// The path of the scene a name gives, and whether its file exists.
@(private="file")
scene_path :: proc(p:^Project,named:string) -> (path:string,exists:bool,problem:string) {
    path=asset_path(named)
    if _,found:=asset.registry_find_path(&p.registry,path);found {return path,true,""}
    // A file outside the assets (a recipe), which asset_named read in memory by its path.
    if asset.registry_outside(path) {
        if _,held:=asset.registry_memory_find(&p.registry,path);held {return path,true,""}
    }
    fresh:=strings.has_suffix(path,".scene") && !strings.contains_rune(path,':')

    if fresh {return path,false,""}
    id,unknown:=asset.registry_resolve(&p.registry,path,".scene")
    if unknown!="" {return "",false,fmt.tprintf("asset: %s",unknown)}
    record,_:=asset.registry_find(&p.registry,id)
    return strings.clone(record.path,context.temp_allocator),true,""
}

@(private="file")
scene_open :: proc(p:^Project,f:^Scene_File,path:string,exists:bool) -> (problem:string) {
    if p.info==nil || p.info.schema==nil {return "the types of the game are needed to read its components"}
    f.p,f.info,f.ws=p,p.info,p.info.schema
    if exists {
        bytes,error:=asset.registry_read(&p.registry,path,context.temp_allocator)
        if error==.None {error=asset.scene_read(&f.scene,&p.types,bytes,context.temp_allocator)}
        if error!=.None {
            return fmt.tprintf("asset %s is not a scene that loads (%v); mirai asset verify says what its file has",path,error)
        }
    } else {
        if asset.scene_init(&f.scene,&p.types,asset.content_id(p.name,"scene",path),context.temp_allocator)!=.None {return "the file could not be made: memory ran out"}
        f.fresh=true
    }
    scene_children(f)
    return ""
}

// The entities under each parent, in their order.
@(private="file")
scene_children :: proc(f:^Scene_File) {
    f.stale=false
    f.children=make(map[base.Entity_Id][dynamic]base.Entity_Id,context.temp_allocator)
    ids,parents:=asset.scene_ids(&f.scene),asset.scene_parents(&f.scene)
    for id,row in ids {
        parent:=parents[row]
        if !(parent in f.children) {f.children[parent]=make([dynamic]base.Entity_Id,context.temp_allocator)}
        append(&f.children[parent],id)
    }
    orders:=asset.scene_orders(&f.scene)
    for _,&list in f.children {
        for i in 1..<len(list) {
            for j:=i;j>0 && orders[f.scene.index[list[j]]]<orders[f.scene.index[list[j-1]]];j-=1 {list[j],list[j-1]=list[j-1],list[j]}
        }
    }
}

// How the game of this build lays out the values of one of its tables.
@(private="file")
scene_schema :: proc(f:^Scene_File,t:^core.Table_Info) -> ^core.Value_Schema {
    return &f.ws.tables[(uintptr(t)-uintptr(raw_data(f.info.tables)))/size_of(core.Table_Info)]
}

// The value a component of the game starts with, as the file keeps one.
@(private="file")
scene_start :: proc(t:^core.Table_Info,v:^core.Value_Schema) -> []u8 {
    size:=t.info.size
    native:=make([]u8,max(size,1),context.temp_allocator)
    if t.default!=nil {t.default(raw_data(native))} else {component_default(t.type,native[:size])}
    image:=make([]u8,max(size,1),context.temp_allocator)
    if size>0 {serial.value_write(&v.layout,image[:size],raw_data(native),1)}
    for offset in v.entities {(cast(^u64)&image[offset])^=0}
    return image[:size]
}

// The component of an entity as the game of this build lays it out; found
// false when the entity has none.
@(private="file")
scene_value :: proc(f:^Scene_File,t:^core.Table_Info,v:^core.Value_Schema,id:base.Entity_Id,start:[]u8) -> (value:[]u8,found:bool) {
    table:=asset.scene_component(&f.scene,t.name) or_return
    image:=asset.scene_component_get(&f.scene,table,id) or_return
    stored:=f.scene.doc.tables[table].columns[1]
    value=make([]u8,max(t.info.size,1),context.temp_allocator)[:t.info.size]
    if f.scene.doc.hashes[stored.type]==v.hash {
        copy(value,image)
        return value,true
    }
    migration:serial.Migration
    if serial.migration_init(&migration,&f.scene.doc.schema,stored.type,&f.ws.schema,v.type,context.temp_allocator)!=.None {return nil,false}
    defer serial.migration_destroy(&migration)
    serial.migration_apply(&migration,value,image,1,start)
    return value,true
}

// Gives an entity a component from a value as the game lays it out.
@(private="file")
scene_value_set :: proc(f:^Scene_File,t:^core.Table_Info,v:^core.Value_Schema,id:base.Entity_Id,value:[]u8) -> bool {
    table,error:=asset.scene_component_add(&f.scene,t.name,&f.ws.schema,v.type)
    if error!=.None {return false}
    // A table stored with another layout takes the game's first, so no value of the document is lost.
    if f.scene.doc.hashes[f.scene.doc.tables[table].columns[1].type]!=v.hash && asset.document_column_retype(&f.scene.doc,table,1,&f.ws.schema,v.type,scene_start(t,v))!=.None {return false}
    return asset.scene_component_set(&f.scene,table,id,value)==.None
}

@(private="file")
scene_has :: proc(f:^Scene_File,name:string,id:base.Entity_Id) -> bool {
    table,found:=asset.scene_component(&f.scene,name)
    if !found {return false}
    _,has:=asset.scene_component_get(&f.scene,table,id)
    return has
}

// Gives or takes a component without values: Hidden, Disabled.
@(private="file")
scene_mark :: proc(f:^Scene_File,name:string,id:base.Entity_Id,on:bool) -> bool {
    if !on {
        table,_:=asset.scene_component(&f.scene,name)
        return asset.scene_component_remove(&f.scene,table,id)
    }
    for &t in f.info.tables {
        if t.place!=.World || t.name!=name {continue}
        v:=scene_schema(f,&t)
        return v.type!=serial.TYPE_NONE && scene_value_set(f,&t,v,id,scene_start(&t,v))
    }
    return false
}

// An entity of an instance holds something on its own from now on.
@(private="file")
scene_overrides :: proc(f:^Scene_File,id:base.Entity_Id,component:u64,kind:asset.Override_Kind,path:="") {
    scene:=&f.scene
    probe:=id
    if kind==.Child {probe=asset.scene_parents(scene)[scene.index[id]]}
    if asset.scene_entity_instance(scene,probe)==0 {return}
    // The whole transform of the root of an instance is its placement.
    if asset.scene_entity_instance(scene,id)==id && kind==.Field && component==base.name_hash(asset.INSTANCE_PLACEMENT) {return}
    _=asset.scene_override_add(scene,id,component,path,kind)
}

// A component of the entity takes the value of the document over the one it
// starts with (from: the one its preset gives), or with merge over the one
// it has, keeping of its current value what a document does not show.
@(private="file")
scene_component_apply :: proc(f:^Scene_File,reading:^Reading,id:base.Entity_Id,t:^core.Table_Info,text,path:string,from:[]u8,merge:bool) -> (changed,ok:bool) {
    v:=scene_schema(f,t)
    start:=scene_start(t,v)
    size:=t.info.size
    bytes:=make([]u8,max(size,1),reading.allocator)[:size]
    current,has:=scene_value(f,t,v,id,start)
    copy(bytes,current if merge && has else from if from!=nil else start)
    if has {fields_kept(&f.ws.schema,v.type,bytes,current)}
    before:=slice.clone(bytes,reading.allocator)
    r:serial.Text_Reader
    reading_reader(reading,&r,text)
    if !serial.text_read(&r,&f.ws.schema,v.type,bytes) {
        line,column:=serial.text_position(r.text,r.error.offset)
        reading_failf(reading,"%s at line %d column %d",serial.text_error_message(&r,path,reading.allocator),line,column)
        return
    }
    if field:=read_only_written(&f.ws.schema,v.type,before,bytes,"");field!="" {
        reading_failf(reading,"%s.%s is read only: leave it out of the value",path,field)
        return
    }
    place:[serial.TEXT_PATH_BYTES]u8
    if problem:=serial.value_check(&f.ws.schema,v.type,bytes,place[:]);problem.fault!=.None {
        reading_failf(reading,"%s.%s: %v; give a finite number inside the range of the field, or a member of its enum",path,problem.path,problem.fault)
        return
    }
    for offset in v.entities {
        named:=(cast(^u64)&bytes[offset])^
        if named==0 {continue}
        if _,found:=asset.scene_entity_find(&f.scene,base.Entity_Id(named));!found {
            reading_failf(reading,"%s names 0x%016x, which is not an entity of the file",path,named)
            return
        }
    }
    if has && slice.equal(bytes,current) {return false,true}
    if !scene_value_set(f,t,v,id,bytes) {reading_brokef(reading,"%s could not be written",path);return}
    scene_overrides(f,id,base.name_hash(t.name),.Field if has else .Added)
    return true,true
}

// The file as what a document is read from and written to.
@(private="file")
scene_target :: proc(f:^Scene_File) -> Scene_Target {
    tables:=make([dynamic]^core.Table_Info,context.temp_allocator)
    for &t in f.info.tables {
        if t.place==.World && scene_schema(f,&t).type!=serial.TYPE_NONE && component_listed(&t) {append(&tables,&t)}
    }
    return {
        user=f,tables=tables[:],lists="what its code declares is here after the game is built",
        assets={&f.p.registry,&f.p.types},into=f.scene.doc.id,fresh=f.fresh,
        find=proc(user:rawptr,id:base.Entity_Id) -> (Node,string) {
            _,found:=asset.scene_entity_find(&(^Scene_File)(user).scene,id)
            return Node(id) if found else 0,""
        },
        named=proc(user:rawptr,text,what:string,allocator:runtime.Allocator) -> (Node,string) {
            f:=(^Scene_File)(user)
            at:=base.Entity_Id(0)
            if id,is_id:=serial.text_parse_hex(text);is_id && (len(text)==16 || strings.has_prefix(text,"0x")) {
                if _,found:=asset.scene_entity_find(&f.scene,base.Entity_Id(id));found {at=base.Entity_Id(id)}
            } else {
                if f.stale {scene_children(f)}
                for name in strings.split(text,"/",context.temp_allocator) {
                    next:=base.Entity_Id(0)
                    for child in f.children[at] {
                        if asset.scene_entity(&f.scene,int(f.scene.index[child])).name==name {next=child;break}
                    }
                    if at=next;at==0 {break}
                }
            }
            if at==0 {return 0,fmt.aprintf("%s: %q names no entity of the file; give its id, or its path of names from the top",what,text,allocator=allocator)}
            return Node(at),""
        },
        children=proc(user:rawptr,parent:Node,allocator:runtime.Allocator) -> []Node {
            f:=(^Scene_File)(user)
            if f.stale {scene_children(f)}
            return transmute([]Node)f.children[base.Entity_Id(parent)][:]
        },
        entity=proc(user:rawptr,node:Node) -> (info:Node_Info) {
            f:=(^Scene_File)(user)
            id:=base.Entity_Id(node)
            row,found:=asset.scene_entity_find(&f.scene,id)
            if !found {return}
            record:=asset.scene_entity(&f.scene,row)
            info={id=id,name=record.name,parent=Node(record.parent),order=int(record.order),local=core.TRANSFORM_IDENTITY,hidden=scene_has(f,"Hidden",id),disabled=scene_has(f,"Disabled",id),instance=Node(asset.scene_entity_instance(&f.scene,id))}
            if local,placed:=asset.scene_get(&f.scene,id,"Transform",core.Transform,&info.local);placed {info.local=local}
            if info.instance!=0 {
                instance,_:=asset.scene_instance(&f.scene,base.Entity_Id(info.instance))
                info.prefab=instance.prefab
            }
            return
        },
        has=proc(user:rawptr,node:Node,t:^core.Table_Info) -> (has,off:bool) {
            f:=(^Scene_File)(user)
            has=scene_has(f,t.name,base.Entity_Id(node))
            return has,has && asset.scene_component_off(&f.scene,base.Entity_Id(node),base.name_hash(t.name))
        },
        text=proc(user:rawptr,out:^serial.Writer,node:Node,t:^core.Table_Info) {
            f:=(^Scene_File)(user)
            v:=scene_schema(f,t)
            start:=scene_start(t,v)
            value,found:=scene_value(f,t,v,base.Entity_Id(node),start)
            serial.text_write_changed(out,&f.ws.schema,v.type,value if found else start,start,omit_fields={.Transient,.Hidden})
        },
        // A recipe is placed once on a world of the game, and its components kept as the file keeps them.
        preset=proc(user:rawptr,name:string,allocator:runtime.Allocator) -> (preset:Scene_Preset,problem:string) {
            f:=(^Scene_File)(user)
            p:=f.p
            index,found:=recipe_named(p.recipes,name)
            if !found {return {},recipe_problem(p.recipes,name)}
            if p.scratch.w.data==nil {
                made:bool
                if p.scratch,made=scratch_world_make(p.info);!made {return {},"a recipe is placed on a world of the game, and the library of the project gives none; "+BUILD_FIX}
            }
            recipe:=p.recipes[index]
            native:[]Part
            if native,problem=recipe_parts(p.scratch.w,&p.types,recipe,allocator);problem!="" {return}
            parts:=make([dynamic]Part,allocator)
            for part in native {
                v:=scene_schema(f,part.t)
                if v.type==serial.TYPE_NONE {continue}
                image:=make([]u8,max(len(part.value),1),allocator)[:len(part.value)]
                if len(image)>0 {serial.value_write(&v.layout,image,raw_data(part.value),1)}
                append(&parts,Part{part.t,image})
            }
            return {recipe=recipe,parts=parts[:]},""
        },
        create=proc(user:rawptr,parent:Node,name:string,preset:Scene_Preset,id:base.Entity_Id) -> (Node,string) {
            f:=(^Scene_File)(user)
            name:=name
            if name=="" {name=preset.label if preset.label!="" else "Entity"}
            e:=id if id!=0 else asset.scene_new_id(&f.scene)
            if _,error:=asset.scene_entity_add(&f.scene,e,base.Entity_Id(parent),name);error!=.None {return 0,"the file holds no more entities"}
            identity:=core.TRANSFORM_IDENTITY
            if asset.scene_set(&f.scene,e,"Transform",&identity)!=.None {return 0,"the file holds no more components"}
            scene_overrides(f,e,0,.Child)
            f.stale=true
            return Node(e),""
        },
        place=proc(user:rawptr,prefab:^asset.Scene,id:base.Asset_Id,parent:Node) -> (Node,int,string) {
            f:=(^Scene_File)(user)
            before:=asset.scene_entity_count(&f.scene)
            root,error:=asset.scene_instantiate(&f.scene,prefab,id,base.Entity_Id(parent))
            if error!=.None {return 0,0,fmt.tprintf("it could not be placed (%v)",error)}
            f.stale=true
            return Node(root),asset.scene_entity_count(&f.scene)-before,""
        },
        copy=proc(user:rawptr,sources:[]Node,allocator:runtime.Allocator) -> ([]Node,int,string) {
            return nil,0,"scene.write of the editor makes a copy; in a file, declare the entity in full"
        },
        group=proc(user:rawptr,members:[]Node) -> (Node,string) {
            return 0,"scene.write of the editor groups entities; in a file, declare the entity with them as its children"
        },
        reparent=proc(user:rawptr,node,parent:Node) -> string {
            f:=(^Scene_File)(user)
            order:=asset.scene_orders(&f.scene)[f.scene.index[base.Entity_Id(node)]]
            if asset.scene_entity_reparent(&f.scene,base.Entity_Id(node),base.Entity_Id(parent),order)!=.None {return "it cannot go under an entity that hangs from it"}
            f.stale=true
            return ""
        },
        rename=proc(user:rawptr,node:Node,name:string) -> string {
            f:=(^Scene_File)(user)
            asset.scene_entity_rename(&f.scene,base.Entity_Id(node),name)
            scene_overrides(f,base.Entity_Id(node),0,.Field,"name")
            return ""
        },
        move=proc(user:rawptr,node:Node,local:core.Transform) -> string {
            f:=(^Scene_File)(user)
            local:=local
            if asset.scene_set(&f.scene,base.Entity_Id(node),"Transform",&local)!=.None {return "its transform could not be written"}
            scene_overrides(f,base.Entity_Id(node),base.name_hash(asset.INSTANCE_PLACEMENT),.Field)
            return ""
        },
        mark=proc(user:rawptr,node:Node,hidden,on:bool) -> string {
            f:=(^Scene_File)(user)
            name:="Hidden" if hidden else "Disabled"
            if !scene_mark(f,name,base.Entity_Id(node),on) {return fmt.tprintf("the game of this build has no %s",name)}
            scene_overrides(f,base.Entity_Id(node),base.name_hash(name),.Added if on else .Removed)
            return ""
        },
        order=proc(user:rawptr,node:Node,order:int) {
            f:=(^Scene_File)(user)
            asset.scene_orders(&f.scene)[f.scene.index[base.Entity_Id(node)]]=u32(order)
            f.stale=true
        },
        write=proc(user:rawptr,reading:^Reading,node:Node,t:^core.Table_Info,text,path:string,from:[]u8,merge:bool) -> (changed,ok:bool) {
            return scene_component_apply((^Scene_File)(user),reading,base.Entity_Id(node),t,text,path,from,merge)
        },
        forget=proc(user:rawptr,node:Node,name:string) -> bool {
            f:=(^Scene_File)(user)
            table,found:=asset.scene_component(&f.scene,name)
            return found && asset.scene_component_remove(&f.scene,table,base.Entity_Id(node))
        },
        drop=proc(user:rawptr,node:Node,t:^core.Table_Info) {
            f:=(^Scene_File)(user)
            table,_:=asset.scene_component(&f.scene,t.name)
            scene_overrides(f,base.Entity_Id(node),base.name_hash(t.name),.Removed)
            asset.scene_component_remove(&f.scene,table,base.Entity_Id(node))
        },
        turn=proc(user:rawptr,node:Node,t:^core.Table_Info,off:bool) {
            f:=(^Scene_File)(user)
            asset.scene_component_turn(&f.scene,base.Entity_Id(node),base.name_hash(t.name),off)
            scene_overrides(f,base.Entity_Id(node),base.name_hash(t.name),.Turned)
        },
        remove=proc(user:rawptr,nodes:[]Node) -> (int,string) {
            f:=(^Scene_File)(user)
            removed,error:=asset.scene_entities_remove(&f.scene,transmute([]base.Entity_Id)nodes)
            f.stale=true
            return removed,"memory ran out" if error!=.None else ""
        },
        kind=proc(user:rawptr,prefab:bool) -> (bool,string) {
            f:=(^Scene_File)(user)
            if (.Prefab in f.scene.doc.flags)==prefab {return false,""}
            if !prefab {f.scene.doc.flags-={.Prefab};return true,""}
            if refused:=asset.prefab_refused(&f.scene);refused!="" {return false,refused}
            f.scene.doc.flags+={.Prefab}
            return true,""
        },
    }
}

// ---------------------------------------------------------------- the commands

// The document of the scene a path or an id names, on one line.
// problem: why there is none.
scene_read :: proc(p:^Project,named:string,out:^serial.Writer) -> (problem:string) {
    path,exists,unknown:=scene_path(p,named)
    if unknown!="" {return unknown}
    if !exists {return fmt.tprintf("asset: %q is no scene of the project",named)}
    f:Scene_File
    if problem=scene_open(p,&f,path,true);problem!="" {return}
    target:=scene_target(&f)
    serial.text_write_raw(out,`{"kind":"Prefab","entities":[` if .Prefab in f.scene.doc.flags else `{"entities":[`)
    for node,i in target.children(&f,0,context.temp_allocator) {
        if i>0 {serial.write_u8(out,',')}
        scene_entity_write(&target,out,node,target.tables)
    }
    serial.text_write_raw(out,"]}")
    return ""
}

@(private="file")
scene_file_apply :: proc(f:^Scene_File,text:string) -> (applied:Scene_Applied,problem:string) {
    reading:=Reading{allocator=context.temp_allocator,raw=text,assets=registry_assets(&f.p.registry)}
    target:=scene_target(f)
    ok:bool
    if applied,ok=scene_apply(&target,&reading,text,true);!ok {problem=reading.problem}
    return
}

// The bytes of a scene as a save of the editor writes it: its entities in a
// world of the game info describes, captured, so the same scene is the same
// bytes whoever wrote it, every component in the layout the game declares.
// scratch: that world, made the first time; in the temp allocator.
scene_file_bytes :: proc(scene:^asset.Scene,types:^asset.Types,info:^core.World_Info,scratch:^Scratch_World) -> (bytes:[]u8,problem:string) {
    FAILED :: "the file could not be written: "
    edited,packing:=asset.scene_bytes(scene,context.temp_allocator)
    file:asset.Asset
    if packing!=.None || asset.asset_open(&file,edited,context.temp_allocator)!=.None {return nil,FAILED+"memory ran out"}
    defer asset.asset_close(&file)
    if scratch.w.data==nil {
        made:bool
        if scratch^,made=scratch_world_make(info);!made {return nil,FAILED+"a scene is written through a world of the game, and the library of the project gives none; "+BUILD_FIX}
    }
    w:=scratch.w
    defer {
        if ids:=core.world_table_of(w,core.Id);ids!=nil {
            for e in slice.clone(ids.entities[:],context.temp_allocator) {core.destroy(core.world_entities(w),e)}
        }
        core.world_settle(w)
    }
    if _,error:=escene.instantiate(w,&file,types);error!=.None {return nil,fmt.tprintf("%s%s",FAILED,escene.error_text(error))}
    core.world_settle(w)
    captured:asset.Scene
    if _,error:=escene.capture(w,&captured,types,{previous=scene},context.temp_allocator);error!=.None {return nil,fmt.tprintf("%s%s",FAILED,escene.error_text(error))}
    for override in scene.overrides {append(&captured.overrides,override)}
    if bytes,packing=asset.scene_bytes(&captured,context.temp_allocator);packing!=.None {return nil,FAILED+"memory ran out"}
    return bytes,""
}

// Makes the scene a path names say what a document declares, and
// writes its file: one that does not exist yet is made. A document it
// refuses leaves the file as it was. problem: why.
scene_write :: proc(p:^Project,named,text:string) -> (written:Written,problem:string) {
    path,exists,unknown:=scene_path(p,named)
    if unknown!="" {return {},unknown}
    f:Scene_File
    if problem=scene_open(p,&f,path,exists);problem!="" {return}
    applied:Scene_Applied
    if applied,problem=scene_file_apply(&f,text);problem!="" {return}
    written={path=path,fresh=!exists,made=applied.made,removed=applied.removed}
    relaid:=make([dynamic]escene.Stored,context.temp_allocator)
    if exists {
        for entry in scene_stored(p,path) {
            if !entry.unknown {append(&relaid,entry)}
        }
    }
    written.stored=relaid[:]
    // A file that says the same and stores every component of the game as the game reads it stays as it is.
    if exists && applied.made==0 && applied.removed==0 && !applied.changed && len(relaid)==0 {
        written.same=true
        return written,""
    }
    if .Prefab in f.scene.doc.flags {
        if refused:=asset.prefab_refused(&f.scene);refused!="" {return {},fmt.tprintf("%s: %s",path,refused)}
    }
    bytes:[]u8
    if bytes,problem=scene_file_bytes(&f.scene,&p.types,p.info,&p.scratch);problem!="" {return {},problem}
    file:=asset.registry_file_path(&p.registry,path,context.temp_allocator) if exists else fmt.tprintf("%s/%s",p.assets_root,path)
    problem=file_put(p,file,path,bytes,&written)
    return
}

// The components a scene of the project stores otherwise than the game reads
// them (escene.Stored); none without the types of the game, or a file that
// does not read, which scene_verify reports.
scene_stored :: proc(p:^Project,path:string) -> []escene.Stored {
    stored:=make([dynamic]escene.Stored,context.temp_allocator)
    if p.info==nil || p.info.schema==nil {return nil}
    bytes,read:=asset.registry_read(&p.registry,path,context.temp_allocator)
    file:asset.Asset
    if read!=.None || asset.asset_take(&file,bytes,context.temp_allocator)!=.None {return nil}
    defer asset.asset_close(&file)
    escene.stored_collect(core.world_ref(nil,p.info),&file,&p.types,&stored)
    return stored[:]
}

// Whether the document of a scene reads and writes it back
// unchanged: "" when it does.
scene_verify :: proc(p:^Project,path:string) -> (problem:string) {
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    if problem=scene_read(p,path,&out);problem!="" {return}
    found,exists,unknown:=scene_path(p,path)
    if unknown!="" {return unknown}
    f:Scene_File
    if problem=scene_open(p,&f,found,exists);problem!="" {return}
    applied:Scene_Applied
    if applied,problem=scene_file_apply(&f,string(serial.writer_bytes(&out)));problem!="" {return}
    if applied.made!=0 || applied.removed!=0 || applied.changed {
        return fmt.tprintf("its document does not write it back as it is: %s is another (%d made, %d removed)",applied.first!=""?applied.first:"what it holds",applied.made,applied.removed)
    }
    return ""
}
