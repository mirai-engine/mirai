package author

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import erender "mirai:engine/render"
import escene "mirai:engine/scene"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:std/serial"

// A scene as a document, and the one writer of scenes: scene.write of the
// editor applies it to the world it edits, and mirai scene write to a file,
// through what each gives as a Scene_Target.
//
//   {"root": "Yard/Lamp", "replace": true, "kind": "Prefab", "entities": [...]}
//
// Entities nest by children and give what differs from a new entity: their
// transform local to the parent, being hidden or off, and by name the
// components they have with the fields that differ from the value a
// component starts with. A preset names a recipe and stands for the
// components it gives; a new entity with prefab is a linked instance
// of that prefab, one with copy a copy of another entity, and one with group
// takes the entities it names under it, at their center.
//
// Without root the entities are those at the top of the scene; with it, the
// one entity is root. What the document leaves out stays: entities,
// components, fields and places. An entity is matched by id or by name among
// its siblings, and the others are made; one at the top named by id stays
// under the parent it has, a component takes the fields given over the value
// it has, null takes it away, and delete true takes the entity away.
//
// With replace the document declares all there is under root, or in the
// scene: entities are also matched by place, and what it leaves out goes; a
// member of an instance of a prefab, which keeps the place its prefab gives
// it, is turned off. A file is written whole: mirai scene write replaces
// unless the document says replace false.
//
// kind makes the scene a Scene or a Prefab, which has exactly one root; left
// out, it stays what it is. An entity placed or matched by the path or the id
// of its prefab alone, and what a copy holds, keep what the document leaves
// out the same way in any write.

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
    case erender.Material_Values:            put(out,erender.MATERIAL_VALUES_DEFAULT)
    case erender.Camera:          put(out,erender.CAMERA_DEFAULT)
    case erender.Exposure:        put(out,erender.EXPOSURE_DEFAULT)
    case erender.Draw_Offset:     put(out,erender.Draw_Offset{rotation=1})
    }
}

// Whether a component is what links an entity to its prefab: a document says
// it with prefab, and declares it as no component.
component_links :: proc(name:string) -> bool {
    return name==asset.COMPONENT_INSTANCE || name==asset.COMPONENT_MEMBER
}

COMPONENT_LINKS_TEXT :: "%s: %s is what links an entity to its prefab, which a document does not override: leave it out, and give a new entity prefab to place an instance"

// Whether a document writes a component by its name: every one a scene saves
// besides the identity, the place and the links of an entity, which have keys
// of their own or are kept by the engine. One with no field to show is {}.
component_listed :: proc(t:^core.Table_Info) -> bool {
    if t.derived {return false}
    switch t.type {
    case core.Transform,core.Name,core.Id,core.Parent,core.Disabled,erender.Hidden,
         escene.Prefab_Instance,escene.Prefab_Member,escene.Section_Member: return false
    }
    return true
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


// ---------------------------------------------------------------- what a document is written to

// An entity of what a document is written to: a live entity by its handle, an
// entity of a file by its id. 0: none; as a parent, the top of the scene.
Node :: distinct u64

// What a document says of an entity that is there.
Node_Info :: struct {
    id:base.Entity_Id,
    name:string,
    parent:Node,
    order:int,            // among its siblings
    local:core.Transform,
    hidden,disabled:bool,
    prefab:base.Asset_Id, // of the instance it is of
    instance:Node,        // the root of that instance; 0: of none
}

// What the recipe a preset names gives the entity it makes.
Scene_Preset :: struct {
    using recipe:Recipe,
    parts:[]Part, // its components, each as the target keeps a value
}

// Where a document is read from and written to. The procedures that can
// refuse answer with why, "" when they did not.
Scene_Target :: struct {
    user:rawptr,
    tables:[]^core.Table_Info, // the components a document writes by name
    lists:string,              // what tells the components there are, for an error
    assets:Assets,             // where a prefab is read from
    into:base.Asset_Id,        // the scene: a prefab that holds it is not placed in it
    fresh:bool,                // it is being made: its entities take the ids the document gives
    find:     proc(user:rawptr,id:base.Entity_Id) -> (node:Node,problem:string), // 0 without a problem: no entity has it
    named:    proc(user:rawptr,text,what:string,allocator:runtime.Allocator) -> (node:Node,problem:string), // the entity root or copy names
    children: proc(user:rawptr,parent:Node,allocator:runtime.Allocator) -> []Node, // in their order, those a document declares
    entity:   proc(user:rawptr,node:Node) -> Node_Info,
    has:      proc(user:rawptr,node:Node,t:^core.Table_Info) -> (has,off:bool),
    text:     proc(user:rawptr,out:^serial.Writer,node:Node,t:^core.Table_Info), // the fields of a component that differ from the value it starts with
    preset:   proc(user:rawptr,name:string,allocator:runtime.Allocator) -> (preset:Scene_Preset,problem:string),
    create:   proc(user:rawptr,parent:Node,name:string,preset:Scene_Preset,id:base.Entity_Id) -> (node:Node,problem:string),
    place:    proc(user:rawptr,prefab:^asset.Scene,id:base.Asset_Id,parent:Node) -> (root:Node,made:int,problem:string),
    copy:     proc(user:rawptr,sources:[]Node,allocator:runtime.Allocator) -> (copies:[]Node,made:int,problem:string), // one of each, beside its source: what a copy names of another source is its copy
    group:    proc(user:rawptr,members:[]Node) -> (node:Node,problem:string), // a new entity at their center, where they hang from when they share a parent, with them under it where they are
    reparent: proc(user:rawptr,node,parent:Node) -> string,
    rename:   proc(user:rawptr,node:Node,name:string) -> string,
    move:     proc(user:rawptr,node:Node,local:core.Transform) -> string,
    mark:     proc(user:rawptr,node:Node,hidden,on:bool) -> string, // Hidden, or Disabled
    order:    proc(user:rawptr,node:Node,order:int),
    write:    proc(user:rawptr,reading:^Reading,node:Node,t:^core.Table_Info,text,path:string,from:[]u8,merge:bool) -> (changed,ok:bool), // from: the value of a preset it starts with
    drop:     proc(user:rawptr,node:Node,t:^core.Table_Info),
    forget:   proc(user:rawptr,node:Node,name:string) -> bool, // takes off a stored component the game does not declare; nil where none is stored
    turn:     proc(user:rawptr,node:Node,t:^core.Table_Info,off:bool),
    remove:   proc(user:rawptr,nodes:[]Node) -> (removed:int,problem:string), // with what hangs from them
    kind:     proc(user:rawptr,prefab:bool) -> (changed:bool,problem:string), // after the entities: a prefab has exactly one root
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
    delete:bool,
    preset,components,off,prefab,copy,group:string, // as given; "": left out
    given:Scene_Prefab, // what prefab says
    recipe:Scene_Preset,
    node:Node,         // the entity it is matched to or made as
    made:bool,         // made now, and not as a prefab or a copy
    keeps:bool,        // what it leaves out stays
}

@(private="file") SCENE_ENTITY_KEYS :: "id, name, preset, prefab, copy, group, delete, position, rotation_deg, scale, visible, enabled, components, off and children"

@(private="file")
scene_entities_read :: proc(reading:^Reading,text:string,parent:int,path:string,out:^[dynamic]Scene_Entity) -> bool {
    items,listed:=doc_items(reading,text,path,"entities")
    if !listed {return false}
    for item,at in items {
        index:=len(out)
        append(out,Scene_Entity{path=fmt.aprintf("%s[%d]",path,at,allocator=reading.allocator),parent=parent,recipe={local=core.TRANSFORM_IDENTITY}})
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
        said:=0 // keys that say something of the entity besides which one it is
        for key,i in keys {
            d:=&out[index]
            value:=values[i]
            what:=fmt.tprintf("%s.%s",d.path,key)
            if key!="id" && key!="name" && key!="delete" {said+=1}
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
                if d.name=="" {reading_failf(reading,"%s: name is empty; leave it out",d.path);return false}
                if len(d.name)>=asset.ENTITY_NAME_BYTES {reading_failf(reading,"%s must be shorter than %d bytes",what,asset.ENTITY_NAME_BYTES);return false}
            case "preset","copy":
                word,is_text:=doc_string(reading,value)
                if !is_text || word=="" {
                    reading_failf(reading,"%s must be %s",what,"the name of a recipe" if key=="preset" else "the entity it copies: its name, a path Parent/Child or its id")
                    return false
                }
                if key=="preset" {d.preset=word} else {d.copy=word}
            case "position":     vector(reading,value,what,&d.position) or_return;d.has_position=true
            case "rotation_deg": vector(reading,value,what,&d.rotation_deg) or_return;d.has_rotation=true
            case "scale":        vector(reading,value,what,&d.scale) or_return;d.has_scale=true
            case "visible","enabled","delete":
                flag,ok:=doc_bool(value)
                if !ok {reading_failf(reading,"%s must be true or false",what);return false}
                switch key {
                case "visible": d.hidden,d.has_visible=!flag,true
                case "enabled": d.disabled,d.has_enabled=!flag,true
                case "delete":  d.delete=flag
                }
            case "components": d.components=value
            case "off":        d.off=value
            case "prefab":     d.prefab=value
            case "group":      d.group=value
            case "children":
                scene_entities_read(reading,value,index,fmt.tprintf("%s.children",d.path),out) or_return
            case:
                reading_failf(reading,"%s has no '%s'; an entity has %s",d.path,key,SCENE_ENTITY_KEYS)
                return false
            }
        }
        d:=&out[index]
        if d.delete && said>0 {reading_failf(reading,"%s: an entity that goes declares nothing else; leave its id or its name beside delete",d.path);return false}
        if d.copy!="" && (d.id!=0 || d.preset!="" || d.prefab!="") {reading_failf(reading,"%s.copy: a copy is a new entity made from another; leave id, preset and prefab out",d.path);return false}
        if d.group!="" && (d.id!=0 || d.copy!="" || d.prefab!="" || parent>=0 || len(out)>index+1) {reading_failf(reading,"%s.group: a group is a new entity at the top of the document, made where the entities it names hang from, with them as its children; leave id, copy, prefab and children out",d.path);return false}
        d.end=len(out)
    }
    return true
}

// ---------------------------------------------------------------- writing

// What a write did.
Scene_Applied :: struct {
    id:base.Entity_Id,     // of the first entity the document declares
    made,removed,disabled:int,
    created:[dynamic]Node, // the entities it made, in its order: of a prefab the root of the instance
    changed:bool,          // something of an entity it kept is another
    first:string,          // the first thing that is
}

// What a write keeps while it applies a document.
@(private="file")
Scene_Apply :: struct {
    using target:^Scene_Target,
    using applied:Scene_Applied,
    reading:^Reading,
    replace:bool, // what the document leaves out goes
    decls:[]Scene_Entity,
    taken:map[Node]bool,  // the entities a document entity is
    placed:map[Node]bool, // the instances, by their roots, the document names by their prefab alone: what it leaves out of them stays
    closed:map[Node]bool, // the copies it made and the entities that go: what hangs from them is not looked at
    presets:map[string]Scene_Preset,
}

// Makes a scene say what a document declares. replace: what a document that
// does not say it does; also: keys beside those of the document, which are of
// whoever gives it. False after failing the reading: whoever owns the target
// undoes what was applied until then.
scene_apply :: proc(target:^Scene_Target,reading:^Reading,text:string,replace:=false,also:[]string=nil) -> (applied:Scene_Applied,ok:bool) {
    keys,values:=tree_object(reading,text,"document") or_return
    a:=Scene_Apply{target=target,reading=reading,replace=replace}
    root,entities,kind:="","",""
    for key,i in keys {
        switch key {
        case "kind":
            is_text:bool
            if kind,is_text=doc_string(reading,values[i]);!is_text || kind!="Scene" && kind!="Prefab" {reading_fail(reading,"kind must be Scene or Prefab");return}
        case "root":
            if strings.trim_space(values[i])=="null" {break}
            is_text:bool
            if root,is_text=doc_string(reading,values[i]);!is_text || root=="" {reading_fail(reading,"root must be an entity: its name, a path Parent/Child or its id");return}
        case "replace":
            known:bool
            if a.replace,known=doc_bool(values[i]);!known {reading_fail(reading,"replace must be true or false");return}
        case "entities": entities=values[i]
        case:
            if slice.contains(also,key) {break}
            reading_failf(reading,"document has no '%s'; it has root, replace, kind and entities: the entities at the top of the scene, or root alone, nesting what hangs from them by children. What it leaves out stays, unless replace is true",key)
            return
        }
    }
    if entities=="" {reading_fail(reading,"entities is required: the entities at the top of the scene, or root alone, as the tree of scene.inspect with root and mirai scene read give them");return}
    read:=make([dynamic]Scene_Entity,reading.allocator)
    scene_entities_read(reading,entities,-1,"entities",&read) or_return
    declared:=make(map[base.Entity_Id]bool,reading.allocator)
    for d in read {
        if d.id==0 {continue}
        if declared[d.id] {reading_failf(reading,"%s.id: 0x%016x is declared twice",d.path,u64(d.id));return}
        declared[d.id]=true
    }
    a.created=make([dynamic]Node,reading.allocator)
    a.presets=make(map[string]Scene_Preset,reading.allocator)
    node:Node
    if root!="" {
        if len(read)==0 || read[0].end!=len(read) {reading_fail(reading,"entities declares one entity with root: root itself, with what hangs from it as its children");return}
        problem:string
        if node,problem=a.named(a.user,root,"root",reading.allocator);problem!="" {reading_fail(reading,problem);return}
    }
    a.decls=read[:]
    scene_apply_at(&a,node) or_return
    if kind!="" {
        changed,problem:=a.target.kind(a.user,kind=="Prefab")
        if scene_refused(&a,"kind",problem) {return}
        if changed {scene_changed(&a,"kind","")}
    }
    return a.applied,true
}

@(private="file")
scene_member :: proc(info:Node_Info,node:Node) -> bool {return info.instance!=0 && info.instance!=node}

// Something of an entity the scene kept is another now; the first one is told.
@(private="file")
scene_changed :: proc(a:^Scene_Apply,place,what:string) {
    if !a.changed {a.first=fmt.tprintf("%s.%s",place,what) if what!="" else place}
    a.changed=true
}

// Fails the reading with why the target refused something of the document; true when it did.
@(private="file")
scene_refused :: proc(a:^Scene_Apply,path,problem:string) -> bool {
    if problem!="" {reading_brokef(a.reading,"%s: %s",path,problem)}
    return problem!=""
}

// Matches the entities of the document from..to, which hang from parent,
// that no id matched: by name among the entities of the parent, then by
// place. ids: those that give an id too, of what was placed just now, whose
// children match in the order they were made. False after failing the
// reading: a name more than one untaken child has names none of them.
@(private="file")
scene_match :: proc(a:^Scene_Apply,parent:Node,from,to:int,ids:=false) -> bool {
    children:=a.children(a.user,parent,a.reading.allocator)
    for by_name in ([]bool{true,false}) {
        if !by_name && !a.replace {break}
        for c:=from;c<to;c=a.decls[c].end {
            d:=&a.decls[c]
            if d.node!=0 || d.copy!="" || d.group!="" || d.id!=0 && !ids || (d.name!="")!=by_name {continue}
            named:=make([dynamic]Node,a.reading.allocator)
            for x in children {
                if a.taken[x] || by_name && a.entity(a.user,x).name!=d.name {continue}
                append(&named,x)
                if !by_name || ids {break}
            }
            if len(named)>1 {
                listed:=strings.builder_make(a.reading.allocator)
                for x,i in named {fmt.sbprintf(&listed,"%s0x%016x",i>0?", ":"",u64(a.entity(a.user,x).id))}
                reading_failf(a.reading,"%s: %d children are named %s (ids %s); give the id of the one meant",d.path,len(named),d.name,strings.to_string(listed))
                return false
            }
            if len(named)==0 {continue}
            d.node=named[0]
            a.taken[d.node]=true
        }
    }
    return true
}

// The prefab a matched entity gives is what the scene says of it; by its path
// or id alone, as the document that placed it, the instance is declared as
// its prefab gives it.
@(private="file")
scene_prefab_linked :: proc(a:^Scene_Apply,d:^Scene_Entity) -> bool {
    info:=a.entity(a.user,d.node)
    scene_prefab_same(a.reading,d.given,d.path,info.prefab,info.instance==d.node,info.instance!=0) or_return
    if d.given.alone {
        d.keeps=true
        a.placed[info.instance]=true
    }
    return true
}

// root: the entity the document declares; 0: those at the top of the scene.
@(private="file")
scene_apply_at :: proc(a:^Scene_Apply,root:Node) -> bool {
    reading,decls:=a.reading,a.decls
    a.taken=make(map[Node]bool,reading.allocator)
    a.placed=make(map[Node]bool,reading.allocator)
    a.closed=make(map[Node]bool,reading.allocator)
    under :: proc(a:^Scene_Apply,node,root:Node) -> bool {
        for at:=node;at!=0;at=a.entity(a.user,at).parent {if at==root {return true}}
        return false
    }
    if root!=0 {
        if id:=a.entity(a.user,root).id;decls[0].id!=0 && decls[0].id!=id {
            reading_failf(reading,"entities[0].id: the entity the document declares is root, 0x%016x",u64(id))
            return false
        }
        decls[0].node=root
        a.taken[root]=true
    }
    for &d in decls {
        if d.id==0 || d.node!=0 {continue}
        node,problem:=a.find(a.user,d.id)
        if problem!="" {reading_failf(reading,"%s.id: %s",d.path,problem);return false}
        if node==0 {
            if a.fresh || d.delete {continue}
            reading_failf(reading,"%s.id: 0x%016x is no entity of the scene; leave id out to make one",d.path,u64(d.id))
            return false
        }
        if root!=0 && !under(a,node,root) || node==root {
            reading_failf(reading,"%s.id: 0x%016x %s; a write with root declares root and what hangs from it",d.path,u64(d.id),"is root, the entity at the top of the document" if node==root else "does not hang from root")
            return false
        }
        d.node=node
        a.taken[node]=true
    }
    if root==0 {scene_match(a,0,0,len(decls)) or_return}
    for &p,i in decls {
        if p.node!=0 {scene_match(a,p.node,i+1,p.end) or_return}
    }
    for &d in decls {
        if d.preset!="" {
            known:bool
            if d.recipe,known=a.presets[d.preset];!known {
                problem:string
                if d.recipe,problem=a.preset(a.user,d.preset,reading.allocator);problem!="" {reading_failf(reading,"%s.preset: %s",d.path,problem);return false}
                a.presets[d.preset]=d.recipe
            }
        }
        if d.prefab!="" {d.given=scene_prefab_read(reading,d.prefab,d.path) or_return}
        if d.node==0 {continue}
        if d.copy!="" {reading_failf(reading,"%s.copy: a copy is a new entity; root is the entity that is there",d.path);return false}
        if d.prefab!="" {scene_prefab_linked(a,&d) or_return}
        info:=a.entity(a.user,d.node)
        parent:=decls[d.parent].node if d.parent>=0 else 0
        if scene_member(info,d.node) && info.parent!=parent && !(d.parent<0 && (root!=0 || !a.replace)) {
            reading_failf(reading,"%s: %s is a member of an instance of a prefab and keeps the place its prefab gives it; declare it under its parent, or leave it out to turn it off",d.path,info.name)
            return false
        }
    }
    // What the document copies is copied together.
    sources:=make([dynamic]Node,reading.allocator)
    for &d in decls {
        if d.copy=="" {continue}
        source,unknown:=a.named(a.user,d.copy,fmt.tprintf("%s.copy",d.path),reading.allocator)
        if unknown!="" {reading_fail(reading,unknown);return false}
        append(&sources,source)
    }
    if len(sources)>0 {
        copies,made,problem:=a.copy(a.user,sources[:],reading.allocator)
        if scene_refused(a,"copy",problem) {return false}
        a.made+=made
        at:=0
        for &d in decls {
            if d.copy!="" {d.node=copies[at];at+=1}
        }
    }
    // What the document adds, and what it moves, in the order it gives.
    for &d,i in decls {
        if d.delete {continue}
        parent:=decls[d.parent].node if d.parent>=0 else 0
        // What declares under an instance or a copy made now is of what it holds, by its names.
        inside :: proc(a:^Scene_Apply,i:int) -> bool {
            for c in i..<a.decls[i].end {
                d:=&a.decls[c]
                if d.node==0 {continue}
                d.keeps=true
                if c>i && d.prefab!="" {scene_prefab_linked(a,d) or_return}
                scene_match(a,d.node,c+1,d.end,true) or_return
            }
            return true
        }
        switch {
        case d.copy!="":
            append(&a.created,d.node)
            a.taken[d.node],a.closed[d.node]=true,true
            // A copy stays beside what it copies unless the document nests it.
            if d.parent>=0 && scene_refused(a,d.path,a.reparent(a.user,d.node,parent)) {return false}
            inside(a,i) or_return
        case d.node!=0:
            // The root stays where it is, and so does what a document that keeps the rest names at its top.
            if d.parent<0 && (root!=0 || !a.replace) || a.entity(a.user,d.node).parent==parent {continue}
            if scene_refused(a,d.path,a.reparent(a.user,d.node,parent)) {return false}
            scene_changed(a,d.path,"its parent")
        case d.group!="":
            place:=fmt.tprintf("%s.group",d.path)
            items:=doc_items(reading,d.group,place,"entities") or_return
            members:=make([]Node,len(items),reading.allocator)
            for item,at in items {
                name,_:=doc_string(reading,item)
                unknown:string
                if members[at],unknown=a.named(a.user,name,fmt.tprintf("%s[%d]",place,at),reading.allocator);unknown!="" {reading_fail(reading,unknown);return false}
            }
            node,problem:=a.group(a.user,members)
            if scene_refused(a,place,problem) {return false}
            // What it leaves out stays as the group was made: its place is their center.
            d.node,d.keeps=node,true
            a.made+=1
            append(&a.created,node)
            a.taken[node]=true
        case d.prefab!="":
            prefab:asset.Scene
            scene_prefab_open(reading,a.assets,d.given,d.path,a.into,&prefab) or_return
            node,made,problem:=a.place(a.user,&prefab,d.given.asset,parent)
            if scene_refused(a,fmt.tprintf("%s.prefab",d.path),problem) {return false}
            d.node=node
            a.made+=made
            append(&a.created,node)
            a.taken[node],a.placed[node]=true,true
            inside(a,i) or_return
        case:
            node,problem:=a.create(a.user,parent,d.name,d.recipe,d.id)
            if scene_refused(a,d.path,problem) {return false}
            d.node,d.made=node,true
            a.made+=1
            append(&a.created,node)
            a.taken[node]=true
        }
    }
    if a.id==0 && len(decls)>0 && decls[0].node!=0 {a.id=a.entity(a.user,decls[0].node).id}
    for &d in decls {
        if d.node!=0 && !d.delete {scene_values_apply(a,&d) or_return}
    }
    // Siblings in the order of the document; a member keeps the place of its prefab.
    order :: proc(a:^Scene_Apply,from,to:int) {
        last:=-1
        for c:=from;c<to;c=a.decls[c].end {
            d:=&a.decls[c]
            if d.node==0 || d.delete || d.copy!="" && d.parent<0 {continue}
            info:=a.entity(a.user,d.node)
            at:=info.order
            if scene_member(info,d.node) {last=max(last,at);continue}
            if at<=last {
                at=last+1
                a.order(a.user,d.node,at)
                scene_changed(a,d.path,"its order among its siblings")
            }
            last=at
        }
    }
    if a.replace {
        if root==0 {order(a,0,len(decls))}
        for &p,i in decls {order(a,i+1,p.end)}
    }
    // What goes: a member of an instance is turned off, the others are taken away with what hangs from them.
    gone:=make([dynamic]Node,reading.allocator)
    leave :: proc(a:^Scene_Apply,gone:^[dynamic]Node,node:Node,info:Node_Info,what:string) -> bool {
        if !scene_member(info,node) {append(gone,node);return true}
        if info.disabled {return true}
        if scene_refused(a,what,a.mark(a.user,node,false,true)) {return false}
        a.disabled+=1
        scene_changed(a,what,"being on")
        return true
    }
    for &d in decls {
        if !d.delete || d.node==0 {continue}
        a.closed[d.node]=true
        leave(a,&gone,d.node,a.entity(a.user,d.node),d.path) or_return
    }
    // What the document leaves out goes too; of an instance it names by its prefab alone it stays.
    left :: proc(a:^Scene_Apply,gone:^[dynamic]Node,parent:Node,parent_taken,under_member:bool) -> bool {
        for node in a.children(a.user,parent,a.reading.allocator) {
            if a.taken[node] {
                if !a.closed[node] {left(a,gone,node,true,false) or_return}
                continue
            }
            info:=a.entity(a.user,node)
            if !scene_member(info,node) {
                if parent_taken || under_member {append(gone,node)}
            } else if !a.placed[info.instance] {
                if parent_taken {leave(a,gone,node,info,"a member of an instance the document leaves out") or_return}
                left(a,gone,node,false,true) or_return
            }
        }
        return true
    }
    if a.replace {left(a,&gone,root,true,false) or_return}
    if len(gone)>0 {
        removed,problem:=a.remove(a.user,gone[:])
        if scene_refused(a,"what the document takes away",problem) {return false}
        a.removed+=removed
    }
    return true
}

// The component of the target a document names; nil after failing the reading.
@(private="file")
scene_table :: proc(a:^Scene_Apply,name,path:string) -> ^core.Table_Info {
    for t in a.tables {if t.name==name {return t}}
    switch name {
    case "Transform","Name","Id","Parent","Hidden","Disabled":
        reading_failf(a.reading,"%s: %s is not written as a component: Transform, Name, Parent, Hidden and Disabled have their own keys (position, name, children, visible, enabled)",path,name)
        return nil
    }
    names:=make([dynamic]string,a.reading.allocator)
    for t in a.tables {append(&names,t.name)}
    reading_failf(a.reading,"%s: %s; %s",path,base.name_problem(name,"a component",names[:],a.reading.allocator),a.lists)
    return nil
}

// The entity of the document takes what it declares: name, transform, being
// hidden or off, its components and those it turns off. The components of
// its preset are declared too, and the fields the document does not name
// take the values the preset gives.
@(private="file")
scene_values_apply :: proc(a:^Scene_Apply,d:^Scene_Entity) -> bool {
    reading,node:=a.reading,d.node
    info:=a.entity(a.user,node)
    if d.name!="" && d.name!=info.name {
        if scene_refused(a,fmt.tprintf("%s.name",d.path),a.rename(a.user,node,d.name)) {return false}
        scene_changed(a,d.path,"name")
    }
    keeps:=!d.made && (!a.replace || d.keeps || a.placed[info.instance])
    local:=info.local
    rotation:=mm.quat_from_euler(d.rotation_deg*mm.RAD_PER_DEG) if d.has_rotation else d.recipe.local.rotation
    target:=local
    target.position,target.scale=d.position,d.scale if d.has_scale else d.recipe.local.scale
    // The rotation the document of the scene gave keeps its quaternion: degrees do not say it to the last bit.
    angles:=d.rotation_deg if d.has_rotation else mm.quat_to_euler(rotation)*mm.DEG_PER_RAD
    if mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD!=angles {target.rotation=rotation}
    if keeps {
        if !d.has_position {target.position=local.position}
        if !d.has_rotation {target.rotation=local.rotation}
        if !d.has_scale {target.scale=local.scale}
    }
    if target!=local {
        if scene_refused(a,d.path,a.move(a.user,node,target)) {return false}
        scene_changed(a,d.path,"its transform")
    }
    for mark in ([2]struct{hidden,is,on,given:bool}{{true,info.hidden,d.hidden,d.has_visible},{false,info.disabled,d.disabled,d.has_enabled}}) {
        if mark.is==mark.on || keeps && !mark.given {continue}
        if scene_refused(a,d.path,a.mark(a.user,node,mark.hidden,mark.on)) {return false}
        scene_changed(a,d.path,"Hidden" if mark.hidden else "Disabled")
    }
    from :: proc(parts:[]Part,t:^core.Table_Info) -> []u8 {
        for part in parts {if part.t==t {return part.value}}
        return nil
    }
    declared:=make([dynamic]^core.Table_Info,reading.allocator)
    if d.components!="" {
        keys,values:=tree_object(reading,d.components,fmt.tprintf("%s.components",d.path)) or_return
        for name,i in keys {
            path:=fmt.aprintf("%s.components.%s",d.path,name,allocator=reading.allocator)
            if component_links(name) {reading_failf(reading,COMPONENT_LINKS_TEXT,path,name);return false}
            // A component the game no longer declares is taken off by name.
            declares:=false
            for t in a.tables {declares ||= t.name==name}
            if a.forget!=nil && keeps && !declares && strings.trim_space(values[i])=="null" {
                if a.forget(a.user,node,name) {scene_changed(a,d.path,name)}
                continue
            }
            t:=scene_table(a,name,path)
            if t==nil {return false}
            if strings.trim_space(values[i])=="null" {
                if !keeps {reading_failf(reading,"%s: a document that replaces declares the components the entity has; leave %s out to take it away",path,name);return false}
                if has,_:=a.has(a.user,node,t);has {
                    a.drop(a.user,node,t)
                    scene_changed(a,d.path,name)
                }
                continue
            }
            changed:=a.write(a.user,reading,node,t,values[i],path,from(d.recipe.parts,t),keeps) or_return
            if changed {scene_changed(a,path,"")}
            append(&declared,t)
        }
    }
    for part in d.recipe.parts {
        if slice.contains(declared[:],part.t) {continue}
        path:=fmt.aprintf("%s.preset",d.path,allocator=reading.allocator)
        changed:=a.write(a.user,reading,node,part.t,"{}",path,part.value,keeps) or_return
        if changed {scene_changed(a,path,"")}
        append(&declared,part.t)
    }
    // What the document leaves out goes.
    for t in a.tables {
        if keeps {break}
        if has,_:=a.has(a.user,node,t);!has || slice.contains(declared[:],t) {continue}
        a.drop(a.user,node,t)
        scene_changed(a,d.path,t.name)
    }
    if d.off=="" && keeps {return true}
    off:=make([dynamic]^core.Table_Info,reading.allocator)
    if d.off!="" {
        items:=doc_items(reading,d.off,fmt.tprintf("%s.off",d.path),"names of components it declares") or_return
        for item in items {
            name,_:=doc_string(reading,item)
            found:^core.Table_Info
            for t in a.tables {if t.name==name {found=t}}
            has:=found!=nil && slice.contains(declared[:],found)
            if found!=nil && !has && keeps {
                if has,_=a.has(a.user,node,found);has {append(&declared,found)}
            }
            if !has {reading_failf(reading,"%s.off: %s is not among the components it %s",d.path,name,"has" if keeps else "declares");return false}
            append(&off,found)
        }
    }
    for t in declared {
        _,turned_off:=a.has(a.user,node,t)
        if turned_off==slice.contains(off[:],t) {continue}
        a.turn(a.user,node,t,!turned_off)
        scene_changed(a,d.path,"off")
    }
    return true
}

// ---------------------------------------------------------------- the document of what is there

// The document of an entity and what hangs from it, with the values of the
// components of tables.
scene_entity_write :: proc(target:^Scene_Target,out:^serial.Writer,node:Node,tables:[]^core.Table_Info) {
    info:=target.entity(target.user,node)
    serial.text_write_raw(out,`{"id":"`);serial.text_write_hex(out,u64(info.id));serial.write_u8(out,'"')
    serial.json_text(out,"name",info.name)
    local:=info.local
    angles:=mm.quat_to_euler(local.rotation)*mm.DEG_PER_RAD
    if local.position!={} {serial.json_key(out,"position");serial.json_list(out,local.position[:])}
    if angles!={} {serial.json_key(out,"rotation_deg");serial.json_list(out,angles[:])}
    if local.scale!={1,1,1} {serial.json_key(out,"scale");serial.json_list(out,local.scale[:])}
    if info.hidden {serial.json_bool(out,"visible",false)}
    if info.disabled {serial.json_bool(out,"enabled",false)}
    if info.instance!=0 {
        buffer:[base.ASSET_ID_TEXT]u8
        serial.json_key(out,"prefab");serial.text_write_raw(out,`{"asset":"`);serial.text_write_raw(out,base.asset_id_format(info.prefab,buffer[:]));serial.write_u8(out,'"')
        serial.json_bool(out,"root",info.instance==node)
        serial.write_u8(out,'}')
    }
    first,off_first:=true,true
    for t in tables {
        if has,_:=target.has(target.user,node,t);!has {continue}
        if first {serial.json_key(out,"components");serial.write_u8(out,'{')}
        serial.json_key(out,t.name,first)
        first=false
        target.text(target.user,out,node,t)
    }
    if !first {serial.write_u8(out,'}')}
    for t in tables {
        if has,off:=target.has(target.user,node,t);!has || !off {continue}
        if off_first {serial.json_key(out,"off");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        off_first=false
        serial.text_write_string(out,t.name)
    }
    if !off_first {serial.write_u8(out,']')}
    children:=target.children(target.user,node,context.temp_allocator)
    for child,i in children {
        if i==0 {serial.json_key(out,"children");serial.write_u8(out,'[')} else {serial.write_u8(out,',')}
        scene_entity_write(target,out,child,tables)
    }
    if len(children)>0 {serial.write_u8(out,']')}
    serial.write_u8(out,'}')
}

// ---------------------------------------------------------------- prefabs

// What an entity of a document says of its prefab: the path or the id of one
// alone, or {asset, root} as the document of a scene gives it.
@(private="file")
Scene_Prefab :: struct {
    asset:base.Asset_Id, // zero: none given
    named:string,        // as the document names it, for errors
    root,has_root:bool,
    alone:bool,          // by its path or id alone: what the entity leaves out is what its prefab gives
}

@(private="file")
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
                reading_failf(reading,"%s.prefab has no '%s'; it is the path or the id of a prefab, or {asset, root} as the document of a scene gives it",path,key)
                return
            }
        }
        if named=="" {return given,true}
    }
    word,is_text:=doc_string(reading,named)
    if !is_text || word=="" {reading_failf(reading,"%s.prefab must be the path or the id of a prefab of the project",path);return}
    problem:string
    if given.asset,problem=reading.assets.resolve(reading.assets.user,asset_path(word),".scene");problem!="" {reading_failf(reading,"%s.prefab: %s",path,problem);return}
    given.named=word
    return given,true
}

// What an entity that is there gives of its prefab is what links it: prefab
// and root are those of the instance it is a member of, linked false for none.
@(private="file")
scene_prefab_same :: proc(reading:^Reading,given:Scene_Prefab,path:string,prefab:base.Asset_Id,root,linked:bool) -> bool {
    if linked && (given.asset=={} || given.asset==prefab) && (!given.has_root || given.root==root) {return true}
    reading_failf(reading,"%s.prefab: it is not what links the entity to a prefab; a document changes no link of an entity that is there: leave prefab out, or declare a new entity with it to place an instance",path)
    return false
}

// Reads the prefab a new entity names, to be placed in the scene of id into:
// one of the project that loads, has one entity at its top and does not hold
// that scene. prefab lives in the temporary allocator.
@(private="file")
scene_prefab_open :: proc(reading:^Reading,a:Assets,given:Scene_Prefab,path:string,into:base.Asset_Id,prefab:^asset.Scene) -> bool {
    if given.asset=={} {reading_failf(reading,"%s.prefab must be the path or the id of a prefab of the project",path);return false}
    if a.registry==nil {reading_brokef(reading,"%s.prefab: the project has no assets folder to read a prefab from",path);return false}
    record,found:=asset.registry_find(a.registry,given.asset)
    if !found || !asset.registry_prefab(record) {reading_failf(reading,"%s.prefab: %q is no prefab of the project; give the path or the id of a .scene whose kind is Prefab, or make it one in the editor",path,given.named);return false}
    files:asset.Registry_Prefabs
    asset.registry_prefabs_init(&files,a.registry,context.temp_allocator)
    defer asset.registry_prefabs_destroy(&files)
    opened:=asset.registry_prefab_files(&files)
    file,opening:=opened.open(opened.data,given.asset)
    if opening!=.None {reading_brokef(reading,"%s.prefab: %s could not be read: %v",path,record.path,opening);return false}
    if file==nil || asset.scene_from_asset(prefab,a.types,file,context.temp_allocator)!=.None {
        reading_failf(reading,"%s.prefab: %s does not load; mirai asset verify says what its file has",path,record.path)
        return false
    }
    if _,rooted:=asset.prefab_root(prefab);!rooted {
        reading_failf(reading,"%s.prefab: %s has no single entity at its top to place; give it one, with the rest under it",path,record.path)
        return false
    }
    holds,asking:=asset.prefab_holds(opened,a.types,given.asset,into)
    if asking!=.None {reading_brokef(reading,"%s.prefab: the prefabs %s places could not be read: %v",path,record.path,asking);return false}
    if holds {
        reading_failf(reading,"%s.prefab: %s holds the scene it would be placed in, itself or through the prefabs it places; place another prefab, or take that instance out of it",path,record.path)
        return false
    }
    return true
}
