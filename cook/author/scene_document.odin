package author

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A scene or a prefab as a document, between its text and its file, with no
// world: {"entities":[...]} holds the entities at the top of the file, each
// as scene.inspect gives one with root and scene.write takes it back. They
// nest by children and give what differs from a new entity: their transform
// local to the parent, being hidden or off, and by name the components they
// have with the fields that differ from the value a component starts with.
// Writing makes the file say what the document declares: entities matched by
// id, else by name among their siblings, else by place, keep what ties them
// to the file (their id, the records of an instance of a prefab, the
// components the game of this build does not know); the others are made, and
// those it does not declare go. A member of an instance keeps the place its
// prefab gives it: left out, it is turned off.
//
// The components are read against the types of the game (core.World_Info),
// whose values are stored as the file keeps them: an Entity field holds an id.
// A preset or the card of a plugin stands for the components its recipe
// gives (recipes.odin), and a new entity with prefab is placed as a linked
// instance of that prefab; what a document changes of an entity of an
// instance is recorded as what the instance holds on its own. An entity that
// names its prefab by path or id alone, as the document that placed it does,
// declares an instance as its prefab gives it: what it and the entities under
// it leave out stays. With {asset, root}, as the document of a file gives
// it, it declares all it has, as any other entity.

// ---------------------------------------------------------------- components

// The value a component starts with when its type declares none: what the
// editor gives the ones of the engine it makes by hand.
component_default :: proc(type:typeid,out:[]u8) {
    put :: proc(out:[]u8,value:$T) {
        value:=value
        if len(out)>=size_of(T) {mem.copy(raw_data(out),&value,size_of(T))}
    }
    mem.zero_slice(out)
    switch type {
    case core.Transform:          put(out,core.TRANSFORM_IDENTITY)
    case erender.Mesh_Renderer:     put(out,erender.Mesh_Renderer{shape=.Cube})
    case erender.Tint:            put(out,erender.TINT_DEFAULT)
    case erender.Camera:          put(out,erender.CAMERA_DEFAULT)
    case erender.Exposure:        put(out,erender.EXPOSURE_DEFAULT)
    case erender.Draw_Offset:     put(out,erender.Draw_Offset{rotation=1})
    }
}

// Whether a scene saves values of a type: it has a field that is not transient.
type_saved :: proc(info:^runtime.Type_Info) -> bool {
    s,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct || s.field_count==0 {return true}
    for i in 0..<int(s.field_count) {
        if _,transient:=core.field_option(reflect.Struct_Tag(s.tags[i]),"transient");!transient {return true}
    }
    return false
}

// Whether a document writes a component by its name: what a scene saves
// besides the identity and the place of an entity, which have keys of their own.
component_listed :: proc(t:^core.Table_Info) -> bool {
    switch t.type {
    case core.Transform,core.Name,core.Id,core.Parent,core.Disabled,erender.Hidden,erender.Material_Override: return false
    }
    fields,structured:=runtime.type_info_base(t.info).variant.(runtime.Type_Info_Struct)
    if structured && fields.field_count>0 {
        visible:=false
        for tag in fields.tags[:fields.field_count] {if _,hidden:=core.field_option(reflect.Struct_Tag(tag),"hidden");!hidden {visible=true;break}}
        if !visible {return false}
    }
    return type_saved(t.info)
}

// Copies from kept the fields a document neither shows nor changes: hidden, transient and read-only ones.
fields_kept :: proc(schema:^serial.Schema,type:serial.Type_Index,bytes,kept:[]u8) {
    for field in serial.schema_fields(schema,type) {
        inner:=serial.schema_type(schema,field.type)
        if inner==nil || int(field.offset+inner.size)>len(bytes) {continue}
        part:=bytes[field.offset:][:inner.size]
        if field.flags&{.Hidden,.Transient,.Read_Only}!={} {
            copy(part,kept[field.offset:][:inner.size])
        } else if inner.kind==.Struct {
            fields_kept(schema,field.type,part,kept[field.offset:][:inner.size])
        }
    }
}

// The path of the first read-only field whose bytes a reader changed; "" when none did.
read_only_written :: proc(schema:^serial.Schema,type:serial.Type_Index,before,after:[]u8,prefix:string) -> string {
    for field in serial.schema_fields(schema,type) {
        inner:=serial.schema_type(schema,field.type)
        if inner==nil || int(field.offset+inner.size)>len(after) {continue}
        path:=prefix==""?field.name:strings.concatenate({prefix,".",field.name},context.temp_allocator)
        at:=before[field.offset:][:inner.size]
        now:=after[field.offset:][:inner.size]
        if .Read_Only in field.flags && !slice.equal(at,now) {return path}
        if inner.kind==.Struct {
            if found:=read_only_written(schema,field.type,at,now,path);found!="" {return found}
        }
    }
    return ""
}

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
    fresh:bool, // the file is being made: its entities take the ids the document gives
}

// The path of the scene or prefab a name gives, and whether its file exists.
@(private="file")
scene_path :: proc(p:^Project,named:string) -> (path:string,exists:bool,problem:string) {
    path=asset_path(named)
    if _,found:=asset.registry_find_path(&p.registry,path);found {return path,true,""}
    fresh:=(strings.has_suffix(path,".scene") || strings.has_suffix(path,".prefab")) && !strings.contains_rune(path,':')
    if fresh {return path,false,""}
    id,unknown:=asset.registry_resolve(&p.registry,path,".scene .prefab")
    if unknown!="" {return "",false,fmt.tprintf("asset: %s",unknown)}
    record,_:=asset.registry_find(&p.registry,id)
    return strings.clone(record.path,context.temp_allocator),true,""
}

@(private="file")
scene_open :: proc(p:^Project,f:^Scene_File,path:string,exists:bool) -> (problem:string) {
    if p.info==nil || p.info.schema==nil {return "the types of the game are needed to read its components"}
    f.p,f.info,f.ws=p,p.info,p.info.schema
    if exists {
        file:=asset.registry_file_path(&p.registry,path,context.temp_allocator)
        if error:=asset.scene_load(&f.scene,&p.types,file,context.temp_allocator);error!=.None {
            return fmt.tprintf("asset %s is not a scene or a prefab that loads (%v); mirai asset verify says what its file has",path,error)
        }
    } else {
        kind:=asset.KIND_PREFAB if strings.has_suffix(path,".prefab") else asset.KIND_SCENE
        if asset.scene_init(&f.scene,&p.types,kind,asset.content_id(p.name,"scene",path),context.temp_allocator)!=.None {return "the file could not be made: memory ran out"}
        f.fresh=true
    }
    scene_children(f)
    return ""
}

// The entities under each parent, in their order.
@(private="file")
scene_children :: proc(f:^Scene_File) {
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

// The table of the game a name gives; nil: it has none.
@(private="file")
scene_table :: proc(f:^Scene_File,name:string) -> (t:^core.Table_Info,v:^core.Value_Schema) {
    for &table,i in f.info.tables {
        if table.place==.World && table.name==name {return &table,&f.ws.tables[i]}
    }
    return nil,nil
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
    stored:=f.scene.doc.tables[table].columns[1]
    if f.scene.doc.hashes[stored.type]==v.hash {return asset.scene_component_set(&f.scene,table,id,value)==.None}
    image:=make([]u8,max(stored.size,1),context.temp_allocator)[:stored.size]
    migration:serial.Migration
    if serial.migration_init(&migration,&f.ws.schema,v.type,&f.scene.doc.schema,stored.type,context.temp_allocator)!=.None {return false}
    defer serial.migration_destroy(&migration)
    if current,has:=asset.scene_component_get(&f.scene,table,id);has {copy(image,current)}
    serial.migration_apply(&migration,image,value,1)
    return asset.scene_component_set(&f.scene,table,id,image)==.None
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
    if scene_has(f,name,id)==on {return true}
    if !on {
        table,_:=asset.scene_component(&f.scene,name)
        return asset.scene_component_remove(&f.scene,table,id)
    }
    t,v:=scene_table(f,name)
    if t==nil || v.type==serial.TYPE_NONE {return false}
    return scene_value_set(f,t,v,id,scene_start(t,v))
}

// The prefab an entity is of in the file: the instance it is a member of.
@(private="file")
scene_link :: proc(f:^Scene_File,id:base.Entity_Id) -> (prefab:base.Asset_Id,root,linked:bool) {
    instance:=asset.scene_entity_instance(&f.scene,id)
    if instance==0 {return}
    at:=asset.scene_instance_find(&f.scene,instance)
    if at<0 {return}
    return f.scene.instances[at].prefab,f.scene.instances[at].root==id,true
}

@(private="file")
scene_local :: proc(f:^Scene_File,id:base.Entity_Id) -> core.Transform {
    identity:=core.TRANSFORM_IDENTITY
    local,found:=asset.scene_get(&f.scene,id,"Transform",core.Transform,&identity)
    return local if found else identity
}

// ---------------------------------------------------------------- reading a file

// The document of the scene or prefab a path or an id names, on one line.
// problem: why there is none.
scene_read :: proc(p:^Project,named:string,out:^serial.Writer) -> (problem:string) {
    path,exists,unknown:=scene_path(p,named)
    if unknown!="" {return unknown}
    if !exists {return fmt.tprintf("asset: %q is no scene or prefab of the project",named)}
    f:Scene_File
    if problem=scene_open(p,&f,path,true);problem!="" {return}
    serial.text_write_raw(out,`{"entities":[`)
    for id,i in f.children[0] {
        if i>0 {serial.write_u8(out,',')}
        scene_entity_write(&f,out,id)
    }
    serial.text_write_raw(out,"]}")
    return ""
}

@(private="file")
scene_entity_write :: proc(f:^Scene_File,out:^serial.Writer,id:base.Entity_Id) {
    row,_:=asset.scene_entity_find(&f.scene,id)
    serial.text_write_raw(out,`{"id":"`);serial.text_write_hex(out,u64(id));serial.write_u8(out,'"')
    serial.json_text(out,"name",asset.scene_entity(&f.scene,row).name)
    local:=scene_local(f,id)
    angles:=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    if local.position!={} {serial.json_key(out,"position");serial.json_list(out,local.position[:])}
    if angles!={} {serial.json_key(out,"rotation_deg");serial.json_list(out,angles[:])}
    if local.scale!={1,1,1} {serial.json_key(out,"scale");serial.json_list(out,local.scale[:])}
    if scene_has(f,"Hidden",id) {serial.json_bool(out,"visible",false)}
    if scene_has(f,"Disabled",id) {serial.json_bool(out,"enabled",false)}
    if prefab,root,linked:=scene_link(f,id);linked {
        buffer:[base.ASSET_ID_TEXT]u8
        serial.json_key(out,"prefab");serial.text_write_raw(out,`{"asset":"`);serial.text_write_raw(out,base.asset_id_format(prefab,buffer[:]));serial.write_u8(out,'"')
        serial.json_bool(out,"root",root)
        serial.write_u8(out,'}')
    }
    first,off_first:=true,true
    for &t,i in f.info.tables {
        v:=&f.ws.tables[i]
        if t.place!=.World || v.type==serial.TYPE_NONE || !component_listed(&t) {continue}
        start:=scene_start(&t,v)
        value,found:=scene_value(f,&t,v,id,start)
        if !found {continue}
        if first {serial.json_key(out,"components");serial.write_u8(out,'{')}
        serial.json_key(out,t.name,first)
        first=false
        serial.text_write_changed(out,&f.ws.schema,v.type,value,start,omit_fields={.Transient,.Hidden})
    }
    if !first {serial.write_u8(out,'}')}
    for &t,i in f.info.tables {
        if t.place!=.World || f.ws.tables[i].type==serial.TYPE_NONE || !component_listed(&t) {continue}
        if !asset.scene_component_off(&f.scene,id,base.name_hash(t.name)) || !scene_has(f,t.name,id) {continue}
        if off_first {serial.json_key(out,"off");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        off_first=false
        serial.text_write_string(out,t.name)
    }
    if !off_first {serial.write_u8(out,']')}
    for child,i in f.children[id] {
        if i==0 {serial.json_key(out,"children");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        scene_entity_write(f,out,child)
    }
    if len(f.children[id])>0 {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

// ---------------------------------------------------------------- reading a document

// An entity of a document, read in pre-order.
@(private="file")
Scene_Entity :: struct {
    path:string,       // where it is in the document, for errors
    parent:int,        // the entity of the document it hangs from; -1 at the top
    end:int,           // past the last entity of the document that hangs from it
    id:base.Entity_Id, // 0: none given
    name:string,       // "": none given
    position,rotation_deg,scale:[3]f32,
    has_position,has_rotation,has_scale:bool,
    hidden,disabled:bool,
    has_visible,has_enabled:bool,
    preset:string,     // "": none given
    recipe:int,        // its place among the recipes; -1 without a preset
    components,off,prefab:string, // as given; "": left out
    given:Scene_Prefab, // what prefab says
    e:base.Entity_Id,  // the entity it is matched to or made as
    made:bool,
    placed:bool,       // it names its prefab by path or id, placed now or before: what it leaves out is what its prefab gives
}

@(private="file") SCENE_ENTITY_KEYS :: "id, name, preset, position, rotation_deg, scale, visible, enabled, components, off, prefab and children"

@(private="file")
scene_entities_read :: proc(reading:^Reading,text:string,parent:int,path:string,out:^[dynamic]Scene_Entity) -> bool {
    items,listed:=doc_items(reading,text,path,"entities")
    if !listed {return false}
    for item,at in items {
        index:=len(out)
        append(out,Scene_Entity{path=fmt.aprintf("%s[%d]",path,at,allocator=reading.allocator),parent=parent,recipe=-1})
        keys,values:=tree_object(reading,item,out[index].path) or_return
        vector :: proc(reading:^Reading,text,what:string,value:^[3]f32) -> bool {
            items:=doc_items(reading,text,what,"3 numbers") or_return
            if len(items)!=3 {reading_failf(reading,"%s must be an array of 3 numbers",what);return false}
            for item,i in items {
                number,ok:=doc_number(item)
                if !ok || number-number!=0 {reading_failf(reading,"%s must be an array of 3 finite numbers",what);return false}
                value[i]=number
            }
            return true
        }
        for key,i in keys {
            d:=&out[index]
            value:=values[i]
            what:=fmt.tprintf("%s.%s",d.path,key)
            switch key {
            case "id":
                word,is_text:=doc_string(reading,value)
                id,parsed:=serial.text_parse_hex(word)
                if strings.trim_space(value)=="null" {break}
                if !is_text || !parsed {reading_failf(reading,"%s must be an entity id",what);return false}
                d.id=base.Entity_Id(id)
            case "name":
                word,is_text:=doc_string(reading,value)
                if !is_text {reading_failf(reading,"%s must be a string",what);return false}
                d.name=strings.trim_space(word)
                if d.name=="" {reading_failf(reading,"%s: name is empty; leave it out to match by place",d.path);return false}
                if len(d.name)>=asset.ENTITY_NAME_BYTES {reading_failf(reading,"%s must be shorter than %d bytes",what,asset.ENTITY_NAME_BYTES);return false}
            case "preset":
                word,is_text:=doc_string(reading,value)
                if !is_text || word=="" {reading_failf(reading,"%s must be the name of a preset or of the card of a plugin",what);return false}
                d.preset=word
            case "position":     vector(reading,value,what,&d.position) or_return;d.has_position=true
            case "rotation_deg": vector(reading,value,what,&d.rotation_deg) or_return;d.has_rotation=true
            case "scale":        vector(reading,value,what,&d.scale) or_return;d.has_scale=true
            case "visible","enabled":
                flag,ok:=doc_bool(value)
                if !ok {reading_failf(reading,"%s must be true or false",what);return false}
                if key=="visible" {d.hidden,d.has_visible=!flag,true} else {d.disabled,d.has_enabled=!flag,true}
            case "components": d.components=value
            case "off":        d.off=value
            case "prefab":     d.prefab=value
            case "children":
                scene_entities_read(reading,value,index,fmt.tprintf("%s.children",d.path),out) or_return
            case:
                reading_failf(reading,"%s has no '%s'; an entity has %s",d.path,key,SCENE_ENTITY_KEYS)
                return false
            }
        }
        out[index].end=len(out)
    }
    return true
}

// ---------------------------------------------------------------- writing a file

// Makes the scene or prefab a path names say what a document declares, and
// writes its file: one that does not exist yet is made. A document it
// refuses leaves the file as it was. problem: why.
scene_write :: proc(p:^Project,named,text:string) -> (written:Written,problem:string) {
    path,exists,unknown:=scene_path(p,named)
    if unknown!="" {return {},unknown}
    f:Scene_File
    if problem=scene_open(p,&f,path,exists);problem!="" {return}
    reading:=Reading{allocator=context.temp_allocator,raw=text,assets=registry_assets(&p.registry)}
    if !scene_apply(&f,&reading,text,&written) {return {},reading.problem}
    if strings.has_suffix(path,".prefab") {
        if _,kept:=asset.scene_entity_find(&f.scene,f.scene.info.root);!kept {
            scene_children(&f)
            f.scene.info.root=f.children[0][0] if len(f.children[0])>0 else 0
        }
    }
    bytes,error:=asset.scene_bytes(&f.scene,context.temp_allocator)
    if error!=.None {return {},fmt.tprintf("the file could not be written: %v",error)}
    written.path,written.fresh=path,!exists
    file:=asset.registry_file_path(&p.registry,path,context.temp_allocator) if exists else fmt.tprintf("%s/%s",p.assets_root,path)
    // A file that says the same stays as it is, in the layout it was written with.
    if exists && written.made==0 && written.removed==0 && !written.changed {
        written.same=true
        return written,""
    }
    problem=file_put(p,file,path,bytes,&written)
    return
}

// Whether the document of a scene or prefab reads and writes it back
// unchanged: "" when it does.
scene_verify :: proc(p:^Project,path:string) -> (problem:string) {
    out:serial.Writer
    serial.writer_init(&out,0,context.temp_allocator)
    if problem=scene_read(p,path,&out);problem!="" {return}
    text:=string(serial.writer_bytes(&out))
    found,exists,unknown:=scene_path(p,path)
    if unknown!="" {return unknown}
    f:Scene_File
    if problem=scene_open(p,&f,found,exists);problem!="" {return}
    reading:=Reading{allocator=context.temp_allocator,raw=text,assets=registry_assets(&p.registry)}
    written:Written
    if !scene_apply(&f,&reading,text,&written) {return reading.problem}
    if written.made!=0 || written.removed!=0 || written.changed {
        return fmt.tprintf("its document does not write it back as it is: %s is another (%d made, %d removed)",written.first!=""?written.first:"what it holds",written.made,written.removed)
    }
    return ""
}

// What a write keeps while it applies a document.
@(private="file")
Scene_Apply :: struct {
    f:^Scene_File,
    reading:^Reading,
    written:^Written,
    decls:[dynamic]Scene_Entity,
    taken:map[base.Entity_Id]bool,
    parts:map[int][]Part,      // by recipe: the components it gives, as the file keeps them
    placed:map[u32]bool,       // the instances the document names by their prefab alone: what it leaves out of them stays
}

// Whether an entity is of an instance of a prefab, and not its root.
@(private="file")
scene_member :: proc(f:^Scene_File,id:base.Entity_Id) -> bool {
    _,root,linked:=scene_link(f,id)
    return linked && !root
}

// An entity of an instance holds something on its own from now on.
@(private="file")
scene_overrides :: proc(a:^Scene_Apply,id:base.Entity_Id,component:u64,kind:asset.Override_Kind,path:="") {
    probe:=id
    if kind==.Child {probe=asset.scene_parents(&a.f.scene)[a.f.scene.index[id]]}
    if _,_,linked:=scene_link(a.f,probe);!linked {return}
    // The whole transform of the root of an instance is its placement.
    if _,root,_:=scene_link(a.f,id);root && kind==.Field && component==base.name_hash(asset.INSTANCE_PLACEMENT) {return}
    _=asset.scene_override_add(&a.f.scene,id,component,path,kind)
}

// Matches the entities of the document from..to, which hang from parent,
// that no id matched: by name among the entities of the parent, then by
// place. ids: those that give an id too, which a file being made has not.
@(private="file")
scene_match :: proc(a:^Scene_Apply,parent:base.Entity_Id,from,to:int,ids:=false) {
    f:=a.f
    for by_name in ([]bool{true,false}) {
        for c:=from;c<to;c=a.decls[c].end {
            d:=&a.decls[c]
            if d.e!=0 || d.id!=0 && !ids || (d.name!="")!=by_name {continue}
            for x in f.children[parent] {
                if a.taken[x] {continue}
                at,_:=asset.scene_entity_find(&f.scene,x)
                if by_name && asset.scene_entity(&f.scene,at).name!=d.name {continue}
                d.e=x
                a.taken[x]=true
                break
            }
        }
    }
}

@(private="file")
scene_apply :: proc(f:^Scene_File,reading:^Reading,text:string,written:^Written) -> bool {
    scene:=&f.scene
    keys,values:=tree_object(reading,text,"document") or_return
    entities:=""
    for key,i in keys {
        if key!="entities" {reading_failf(reading,"document has no '%s'; it has entities: the entities at the top of the file, nesting what hangs from them by children",key);return false}
        entities=values[i]
    }
    if entities=="" {reading_fail(reading,"entities is required: the entities at the top of the file, as mirai scene read gives them");return false}
    a:=Scene_Apply{f=f,reading=reading,written=written}
    a.decls=make([dynamic]Scene_Entity,reading.allocator)
    a.taken=make(map[base.Entity_Id]bool,reading.allocator)
    a.parts=make(map[int][]Part,reading.allocator)
    a.placed=make(map[u32]bool,reading.allocator)
    scene_entities_read(reading,entities,-1,"entities",&a.decls) or_return
    decls:=a.decls[:]

    for &d in decls {
        if d.id==0 {continue}
        if a.taken[d.id] {reading_failf(reading,"%s.id: 0x%016x is declared twice",d.path,u64(d.id));return false}
        if f.fresh {a.taken[d.id]=true;continue}
        if _,found:=asset.scene_entity_find(scene,d.id);!found {reading_failf(reading,"%s.id: 0x%016x is no entity of the file; leave id out to make one",d.path,u64(d.id));return false}
        d.e=d.id
        a.taken[d.id]=true
    }
    scene_match(&a,0,0,len(decls))
    for &p,i in decls {
        if p.e!=0 {scene_match(&a,p.e,i+1,p.end)}
    }
    for &d in decls {
        if d.preset!="" {scene_recipe(&a,&d) or_return}
        if d.prefab!="" {d.given=scene_prefab_read(reading,d.prefab,d.path) or_return}
        if d.e==0 {continue}
        if d.prefab!="" {scene_prefab_linked(&a,&d) or_return}
        parent:=decls[d.parent].e if d.parent>=0 else 0
        if scene_member(f,d.e) && asset.scene_parents(scene)[scene.index[d.e]]!=parent {
            reading_failf(reading,"%s: it is a member of an instance of a prefab and keeps the place its prefab gives it; declare it under its parent, or leave it out to turn it off",d.path)
            return false
        }
    }
    // What the document adds, and what it moves, in the order it gives.
    for &d,i in decls {
        parent:=decls[d.parent].e if d.parent>=0 else 0
        if d.e==0 && d.prefab!="" {
            scene_place(&a,&d,parent) or_return
            // What it declares under the instance is of its members, by their names.
            scene_children(f)
            for c in i..<d.end {
                if decls[c].e==0 {continue}
                if c>i && decls[c].prefab!="" {scene_prefab_linked(&a,&decls[c]) or_return}
                scene_match(&a,decls[c].e,c+1,decls[c].end,true)
            }
        } else if d.e==0 {
            d.e=d.id if d.id!=0 else asset.scene_new_id(scene)
            if _,error:=asset.scene_entity_add(scene,d.e,parent,d.name if d.name!="" else scene_recipe_name(&d));error!=.None {reading_broke(reading,"the file holds no more entities");return false}
            identity:=core.TRANSFORM_IDENTITY
            if asset.scene_set(scene,d.e,"Transform",&identity)!=.None {reading_broke(reading,"the file holds no more components");return false}
            d.made=true
            written.made+=1
            scene_overrides(&a,d.e,0,.Child)
        } else if row:=scene.index[d.e];asset.scene_parents(scene)[row]!=parent {
            if asset.scene_entity_reparent(scene,d.e,parent,asset.scene_orders(scene)[row])!=.None {
                reading_failf(reading,"%s: it cannot go under an entity that hangs from it",d.path)
                return false
            }
            scene_changed(written,d.path,"its parent")
        }
    }
    order :: proc(a:^Scene_Apply,from,to:int) {
        f:=a.f
        orders:=asset.scene_orders(&f.scene)
        last:=-1
        for c:=from;c<to;c=a.decls[c].end {
            d:=&a.decls[c]
            row:=f.scene.index[d.e]
            at:=int(orders[row])
            if scene_member(f,d.e) {last=max(last,at);continue}
            if at<=last || d.made && at!=last+1 {
                orders[row]=u32(last+1)
                at=last+1
                scene_changed(a.written,d.path,"its order among its siblings")
            }
            last=at
        }
    }
    order(&a,0,len(decls))
    for &p,i in decls {order(&a,i+1,p.end)}
    for &d in decls {scene_values_apply(&a,&d) or_return}
    // What the file held and the document leaves out goes with what hangs
    // from it; a member of an instance is turned off, unless this write
    // placed the instance: what it leaves out of it is what its prefab gives.
    gone:=make([dynamic]base.Entity_Id,reading.allocator)
    declared:=make(map[base.Entity_Id]bool,reading.allocator)
    for &d in decls {declared[d.e]=true}
    ids,parents:=asset.scene_ids(scene),asset.scene_parents(scene)
    for id,row in ids {
        if declared[id] {continue}
        parent:=parents[row]
        if scene_member(f,id) {
            if a.placed[asset.scene_entity_instance(scene,id)] {continue}
            if (parent==0 || declared[parent]) && !scene_has(f,"Disabled",id) {
                if !scene_mark(f,"Disabled",id,true) {reading_broke(reading,"the game of this build has no Disabled to turn a member of an instance off with");return false}
                scene_changed(written,"a member of an instance the document leaves out","being on")
            }
        } else if parent==0 || declared[parent] {
            append(&gone,id)
        }
    }
    if len(gone)>0 {
        error:asset.Error
        if written.removed,error=asset.scene_entities_remove(scene,gone[:]);error!=.None {reading_broke(reading,"the entities the document leaves out could not be removed: memory ran out");return false}
    }
    return true
}

// The name of an entity a recipe makes when the document gives none: that of
// its preset, as a person reads it.
@(private="file")
scene_recipe_name :: proc(d:^Scene_Entity) -> string {
    if d.preset=="" {return "Entity"}
    name,_:=strings.replace_all(d.preset,"_"," ",context.temp_allocator)
    return name
}

// Finds the recipe the preset of an entity names and the components it gives,
// which it makes once on a world of the game.
@(private="file")
scene_recipe :: proc(a:^Scene_Apply,d:^Scene_Entity) -> bool {
    f,reading:=a.f,a.reading
    p:=f.p
    found:bool
    if d.recipe,found=recipe_named(d.preset,p.plugins.labels);!found {
        reading_failf(reading,"%s.preset: %s",d.path,recipe_problem(d.preset,p.plugins.labels))
        return false
    }
    if d.recipe in a.parts {return true}
    if p.scratch.w.data==nil {
        made:bool
        if p.scratch,made=scratch_world_make(p.info);!made {
            reading_brokef(reading,"%s.preset: a preset is made on a world of the game, and the library of the project gives none; %s",d.path,BUILD_FIX)
            return false
        }
    }
    native:=recipe_parts(&p.scratch,d.recipe,p.plugins,reading.allocator)
    parts:=make([dynamic]Part,reading.allocator)
    for part in native {
        index:=int((uintptr(part.t)-uintptr(raw_data(f.info.tables)))/size_of(core.Table_Info))
        if index<0 || index>=len(f.ws.tables) || f.ws.tables[index].type==serial.TYPE_NONE {continue}
        image:=make([]u8,max(len(part.value),1),reading.allocator)[:len(part.value)]
        if len(image)>0 {serial.value_write(&f.ws.tables[index].layout,image,raw_data(part.value),1)}
        append(&parts,Part{part.t,image})
    }
    a.parts[d.recipe]=parts[:]
    return true
}

// Places the prefab a new entity names under parent, as a linked instance.
@(private="file")
scene_place :: proc(a:^Scene_Apply,d:^Scene_Entity,parent:base.Entity_Id) -> bool {
    f,reading:=a.f,a.reading
    prefab:asset.Scene
    scene_prefab_open(reading,{&f.p.registry,&f.p.types},d.given,d.path,f.scene.doc.id,&prefab) or_return
    before:=asset.scene_entity_count(&f.scene)
    instance,root,error:=asset.scene_instantiate(&f.scene,&prefab,d.given.asset,parent)
    if error!=.None {reading_brokef(reading,"%s.prefab: %s could not be placed (%v)",d.path,d.given.named,error);return false}
    d.e,d.placed,d.made=root,true,true
    a.placed[instance]=true
    a.taken[root]=true
    a.written.made+=asset.scene_entity_count(&f.scene)-before
    return true
}

// The prefab a matched entity gives is what the file says of it; by its path
// or id alone, as the document that placed it, the instance is declared as
// its prefab gives it.
@(private="file")
scene_prefab_linked :: proc(a:^Scene_Apply,d:^Scene_Entity) -> bool {
    prefab,root,linked:=scene_link(a.f,d.e)
    scene_prefab_same(a.reading,d.given,d.path,prefab,root,linked) or_return
    if d.given.alone {
        d.placed=true
        a.placed[asset.scene_entity_instance(&a.f.scene,d.e)]=true
    }
    return true
}

// What an entity of a document says of its prefab: the path or the id of one
// alone, or {asset, root} as the document of a file gives it.
Scene_Prefab :: struct {
    asset:base.Asset_Id, // zero: none given
    named:string,        // as the document names it, for errors
    root,has_root:bool,
    alone:bool,          // by its path or id alone: what the entity leaves out is what its prefab gives
}

scene_prefab_read :: proc(reading:^Reading,text,path:string) -> (given:Scene_Prefab,ok:bool) {
    text:=strings.trim_space(text)
    named:=text
    given.alone=len(text)==0 || text[0]!='{'
    if !given.alone {
        named=""
        keys,values:=tree_object(reading,text,fmt.tprintf("%s.prefab",path)) or_return
        for key,i in keys {
            switch key {
            case "asset": named=values[i]
            case "root":
                if given.root,given.has_root=doc_bool(values[i]);!given.has_root {reading_failf(reading,"%s.prefab.root must be true or false",path);return}
            case "instance","source":
            case:
                reading_failf(reading,"%s.prefab has no '%s'; it is the path or the id of a prefab, or {asset, root} as the document of a file gives it",path,key)
                return
            }
        }
        if named=="" {return given,true}
    }
    word,is_text:=doc_string(reading,named)
    if !is_text || word=="" {reading_failf(reading,"%s.prefab must be the path or the id of a prefab of the project",path);return}
    problem:string
    if given.asset,problem=reading.assets.resolve(reading.assets.user,asset_path(word),".prefab");problem!="" {reading_failf(reading,"%s.prefab: %s",path,problem);return}
    given.named=word
    return given,true
}

// What an entity that is there gives of its prefab is what links it: prefab
// and root are those of the instance it is a member of, linked false for none.
scene_prefab_same :: proc(reading:^Reading,given:Scene_Prefab,path:string,prefab:base.Asset_Id,root,linked:bool) -> bool {
    if linked && (given.asset=={} || given.asset==prefab) && (!given.has_root || given.root==root) {return true}
    reading_failf(reading,"%s.prefab: it is not what links the entity to a prefab; a document changes no link of an entity that is there: leave prefab out, or declare a new entity with it to place an instance",path)
    return false
}

// Reads the prefab a new entity names, to be placed in the file of id into:
// one of the project that loads, has one entity at its top and does not hold
// that file. prefab lives in the temporary allocator.
scene_prefab_open :: proc(reading:^Reading,a:Assets,given:Scene_Prefab,path:string,into:base.Asset_Id,prefab:^asset.Scene) -> bool {
    if given.asset=={} {reading_failf(reading,"%s.prefab must be the path or the id of a prefab of the project",path);return false}
    if a.registry==nil {reading_brokef(reading,"%s.prefab: the project has no assets folder to read a prefab from",path);return false}
    record,found:=asset.registry_find(a.registry,given.asset)
    if !found || record.kind!=asset.KIND_PREFAB {reading_failf(reading,"%s.prefab: %q is no prefab of the project; give the path or the id of a .prefab",path,given.named);return false}
    files:asset.Registry_Prefabs
    asset.registry_prefabs_init(&files,a.registry,context.temp_allocator)
    defer asset.registry_prefabs_destroy(&files)
    opened:=asset.registry_prefab_files(&files)
    file:=opened.open(opened.data,given.asset)
    if file==nil || asset.scene_from_asset(prefab,a.types,file,context.temp_allocator)!=.None {
        reading_failf(reading,"%s.prefab: %s does not load; mirai asset verify says what its file has",path,record.path)
        return false
    }
    if _,rooted:=asset.prefab_root(prefab);!rooted {
        reading_failf(reading,"%s.prefab: %s has no single entity at its top to place; give it one, with the rest under it",path,record.path)
        return false
    }
    if asset.prefab_holds(opened,a.types,given.asset,into) {
        reading_failf(reading,"%s.prefab: %s holds the file it would be placed in, itself or through the prefabs it places; place another prefab, or take that instance out of it",path,record.path)
        return false
    }
    return true
}

// The entity of the document takes what it declares: name, transform, being
// hidden or off, its components and those it turns off. The components of
// its recipe are declared too, and the fields the document does not name
// take the values the recipe gives.
@(private="file")
scene_values_apply :: proc(a:^Scene_Apply,d:^Scene_Entity) -> bool {
    f,reading,written:=a.f,a.reading,a.written
    scene:=&f.scene
    id:=d.e
    row:=int(scene.index[id])
    if d.name!="" && d.name!=asset.scene_entity(scene,row).name {
        asset.scene_entity_rename(scene,id,d.name)
        scene_overrides(a,id,0,.Field,"name")
        scene_changed(written,d.path,"name")
    }
    // An entity of an instance the document names by its prefab alone keeps what it leaves out.
    sparse:=d.placed || a.placed[asset.scene_entity_instance(scene,id)]
    local:=scene_local(f,id)
    rotation,scale:=recipe_place(d.recipe,f.p.plugins)
    if d.has_rotation {rotation=mm.quat_from_euler(d.rotation_deg*mm.RAD_PER_DEG)}
    target:=local
    target.position,target.scale=d.position,d.scale if d.has_scale else scale
    // The rotation the document of the file gave keeps its quaternion: degrees do not say it to the last bit.
    angles:=d.rotation_deg if d.has_rotation else mm.quat_to_euler(rotation)*mm.DEG_PER_RAD
    if mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD!=angles {target.rotation=rotation}
    if sparse {
        if !d.has_position {target.position=local.position}
        if !d.has_rotation {target.rotation=local.rotation}
        if !d.has_scale {target.scale=local.scale}
    }
    if target!=local {
        if asset.scene_set(scene,id,"Transform",&target)!=.None {reading_brokef(reading,"%s: its transform could not be written",d.path);return false}
        scene_overrides(a,id,base.name_hash(asset.INSTANCE_PLACEMENT),.Field)
        scene_changed(written,d.path,"its transform")
    }
    for mark in ([2]struct{name:string,on,given:bool}{{"Hidden",d.hidden,d.has_visible},{"Disabled",d.disabled,d.has_enabled}}) {
        if scene_has(f,mark.name,id)==mark.on || sparse && !mark.given {continue}
        if !scene_mark(f,mark.name,id,mark.on) {reading_brokef(reading,"%s: the game of this build has no %s",d.path,mark.name);return false}
        scene_overrides(a,id,base.name_hash(mark.name),.Added if mark.on else .Removed)
        scene_changed(written,d.path,mark.name)
    }
    parts:=a.parts[d.recipe] if d.recipe>=0 else nil
    from :: proc(parts:[]Part,t:^core.Table_Info) -> []u8 {
        for part in parts {if part.t==t {return part.value}}
        return nil
    }
    declared:=make([dynamic]^core.Table_Info,reading.allocator)
    if d.components!="" {
        keys,values:=tree_object(reading,d.components,fmt.tprintf("%s.components",d.path)) or_return
        for name,i in keys {
            path:=fmt.aprintf("%s.components.%s",d.path,name,allocator=reading.allocator)
            t,v:=scene_table(f,name)
            if t==nil {reading_failf(reading,"%s: the game of this build has no component '%s'; %s",path,name,scene_components_near(f,name));return false}
            if !component_listed(t) || v.type==serial.TYPE_NONE {
                reading_failf(reading,"%s: %s is not written as a component: Transform, Name, Parent, Hidden and Disabled have their own keys (position, name, children, visible, enabled)",path,name)
                return false
            }
            if strings.trim_space(values[i])=="null" {reading_failf(reading,"%s: the document declares the components the entity has; leave %s out to take it away",path,name);return false}
            scene_component_apply(a,id,t,v,values[i],path,from(parts,t)) or_return
            append(&declared,t)
        }
    }
    for part in parts {
        if slice.contains(declared[:],part.t) {continue}
        _,v:=scene_table(f,part.t.name)
        scene_component_apply(a,id,part.t,v,"{}",fmt.aprintf("%s.preset",d.path,allocator=reading.allocator),part.value) or_return
        append(&declared,part.t)
    }
    // What the document leaves out goes; of an instance it names by its prefab alone, it stays.
    if !sparse {
        for &t,i in f.info.tables {
            if t.place!=.World || f.ws.tables[i].type==serial.TYPE_NONE || !component_listed(&t) || slice.contains(declared[:],&t) || !scene_has(f,t.name,id) {continue}
            table,_:=asset.scene_component(scene,t.name)
            scene_overrides(a,id,base.name_hash(t.name),.Removed)
            asset.scene_component_remove(scene,table,id)
            scene_changed(written,d.path,t.name)
        }
    }
    off:=make([dynamic]^core.Table_Info,reading.allocator)
    if d.off!="" {
        items:=doc_items(reading,d.off,fmt.tprintf("%s.off",d.path),"names of components it declares") or_return
        for item in items {
            name,is_text:=doc_string(reading,item)
            t,_:=scene_table(f,name)
            if !is_text || t==nil || !slice.contains(declared[:],t) {reading_failf(reading,"%s.off: %s is not among the components it declares",d.path,name);return false}
            append(&off,t)
        }
    }
    for t in declared {
        hash:=base.name_hash(t.name)
        turned_off:=asset.scene_component_off(scene,id,hash)
        if turned_off==slice.contains(off[:],t) {continue}
        asset.scene_component_turn(scene,id,hash,!turned_off)
        scene_overrides(a,id,hash,.Turned)
        scene_changed(written,d.path,"off")
    }
    return true
}

// A component of the entity takes the value of the document over the one it
// starts with (from: the one its recipe gives), keeping of its current value
// what a document does not show.
@(private="file")
scene_component_apply :: proc(a:^Scene_Apply,id:base.Entity_Id,t:^core.Table_Info,v:^core.Value_Schema,text,path:string,from:[]u8) -> bool {
    f,reading:=a.f,a.reading
    start:=scene_start(t,v)
    size:=t.info.size
    bytes:=make([]u8,max(size,1),reading.allocator)[:size]
    copy(bytes,from if from!=nil else start)
    current,has:=scene_value(f,t,v,id,start)
    if has {fields_kept(&f.ws.schema,v.type,bytes,current)}
    before:=slice.clone(bytes,reading.allocator)
    r:serial.Text_Reader
    reading_reader(reading,&r,text)
    if !serial.text_read(&r,&f.ws.schema,v.type,bytes) {
        line,column:=serial.text_position(r.text,r.error.offset)
        reading_failf(reading,"%s at line %d column %d",serial.text_error_message(&r,path,reading.allocator),line,column)
        return false
    }
    if field:=read_only_written(&f.ws.schema,v.type,before,bytes,"");field!="" {
        reading_failf(reading,"%s.%s is read only: leave it out of the value",path,field)
        return false
    }
    place:[serial.TEXT_PATH_BYTES]u8
    if problem:=serial.value_check(&f.ws.schema,v.type,bytes,place[:]);problem.fault!=.None {
        reading_failf(reading,"%s.%s: %v; give a finite number inside the range of the field, or a member of its enum",path,problem.path,problem.fault)
        return false
    }
    for offset in v.entities {
        named:=(cast(^u64)&bytes[offset])^
        if named==0 {continue}
        if _,found:=asset.scene_entity_find(&f.scene,base.Entity_Id(named));!found {
            reading_failf(reading,"%s names 0x%016x, which is not an entity of the file",path,named)
            return false
        }
    }
    if has && slice.equal(bytes,current) {return true}
    if !scene_value_set(f,t,v,id,bytes) {reading_brokef(reading,"%s could not be written",path);return false}
    scene_overrides(a,id,base.name_hash(t.name),.Field if has else .Added)
    scene_changed(a.written,path,"")
    return true
}

// The components of the game a name is near, for an error.
@(private="file")
scene_components_near :: proc(f:^Scene_File,name:string) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for &t,i in f.info.tables {
        if t.place==.World && f.ws.tables[i].type!=serial.TYPE_NONE && component_listed(&t) {append(&names,t.name)}
    }
    nearest:[base.NAME_NEAREST]int
    count:=base.names_nearest(name,names[:],nearest[:])
    if count==0 {return "what its code declares is here after the game is built"}
    b:=strings.builder_make(context.temp_allocator)
    for at,i in nearest[:count] {fmt.sbprintf(&b,"%s%s",i>0?", ":"",names[at])}
    return fmt.tprintf("the nearest are %s; what its code declares is here after the game is built",strings.to_string(b))
}

// Something of an entity the file kept is another now; the first one is told.
@(private="file")
scene_changed :: proc(written:^Written,place,what:string) {
    if !written.changed {written.first=fmt.tprintf("%s.%s",place,what) if what!="" else place}
    written.changed=true
}
