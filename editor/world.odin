package editor

import "base:runtime"
import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:strconv"
import "core:strings"
import "mirai:cook/author"
import "mirai:core"
import "mirai:editor/history"
import eaudio "mirai:engine/audio"
import evolume "mirai:engine/volume"
import ecamera "mirai:engine/camera"
import erender "mirai:engine/render"
import "mirai:std/base"
import mm "mirai:std/math"
import "mirai:ui"

// Edits of the World shown, each one a step of undo unless a gesture is
// open. They work on any World through its tables, and on the components of
// the engine that every scene entity has: Id, Name, Transform and Parent.

// What the Create panel and the API make: recipes of components, not kinds.
Preset :: author.Preset

Preset_Card :: struct {
    label:string,
    icon:ui.Icon,
    color:ui.Color,
    lift:f32, // m above what it is placed on, for what has no body
}

MESH_COLOR :: ui.Color{140,180,240,255}
PREFAB_COLOR :: ui.Color{120,200,255,255} // a linked prefab: its icon and the name of its root
GROUP_COLOR :: ui.Color{175,165,230,255}
CAMERA_COLOR :: ui.Color{150,200,255,255}
CAMERA_ICON :: ui.Icon(u8(ui.Icon.User)+u8(User_Icon.Camera))
LIGHT_COLOR :: ui.Color{255,214,140,255}
SOUND_COLOR :: ui.Color{150,140,240,255}

PRESETS :: [Preset]Preset_Card{
    .Empty={"Group",.Group,GROUP_COLOR,0},
    .Cube={"Cube",.Cube,MESH_COLOR,0},
    .Sphere={"Sphere",.Sphere,MESH_COLOR,0},
    .Cylinder={"Cylinder",.Cylinder,MESH_COLOR,0},
    .Cone={"Cone",.Cone,MESH_COLOR,0},
    .Capsule={"Capsule",.Cylinder,MESH_COLOR,0},
    .Plane={"Plane",.Plane,MESH_COLOR,0},
    .Prism={"Prism",.Prism,MESH_COLOR,0},
    .Pyramid={"Pyramid",.Pyramid,MESH_COLOR,0},
    .Point_Light={"Point light",.Light,LIGHT_COLOR,1.5},
    .Spot_Light={"Spot light",.Spot,LIGHT_COLOR,3},
    .Sun={"Sun",.Sun,LIGHT_COLOR,2},
    .Rect_Light={"Rectangle light",.Area_Light,LIGHT_COLOR,1.5},
    .Camera={"Camera",CAMERA_ICON,CAMERA_COLOR,1.6},
    .Isometric_Camera={"Isometric",CAMERA_ICON,CAMERA_COLOR,1.6},
    .Top_Down_Camera={"Top-down",CAMERA_ICON,CAMERA_COLOR,1.6},
    .Side_Camera={"Side view",CAMERA_ICON,CAMERA_COLOR,1.6},
    .First_Person_Camera={"First person",CAMERA_ICON,CAMERA_COLOR,1.6},
    .Third_Person_Camera={"Third person",CAMERA_ICON,CAMERA_COLOR,1.6},
    .Aim_Camera={"Aim",CAMERA_ICON,CAMERA_COLOR,1.6},
    .Sound={"Sound",.Sound,SOUND_COLOR,1},
    .Reverb_Zone={"Reverb zone",.Collider,SOUND_COLOR,3},
}

// The mode of engine/camera a camera preset follows the player in.
@(private)
preset_camera_mode :: proc "contextless" (preset:Preset) -> (ecamera.Camera_Preset,bool) {
    return author.preset_camera_mode(preset)
}

SHAPE_ICONS :: [erender.Shape]ui.Icon{.None=.Mesh,.Cube=.Cube,.Sphere=.Sphere,.Cylinder=.Cylinder,.Cone=.Cone,.Capsule=.Cylinder,.Plane=.Plane,.Prism=.Prism,.Pyramid=.Pyramid}

Create_Desc :: struct {
    preset:Preset,
    card:int,              // its place in cards(), for the card of a plugin; 0: the preset
    name:string,           // the name of the preset when empty; a number follows a name that is taken
    named:bool,            // name is taken as it is, even when another entity has it
    parent:core.Entity,
    transform:core.Transform, // the identity when zero
}

// ---------------------------------------------------------------- reading

entity_alive :: proc(w:core.World_Ref,e:core.Entity) -> bool {return core.alive(core.world_entities(w),e)}

entity_name :: proc(w:core.World_Ref,e:core.Entity) -> string {
    names:=core.world_table_of(w,core.Name)
    if names==nil {return ""}
    return core.name_get(core.read(names),e)
}

// The name of an entity, or one made of its index when it has none.
entity_label :: proc(w:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> string {
    if name:=entity_name(w,e);name!="" {return name}
    return fmt.aprintf("Entity %d",core.entity_index(e),allocator=allocator)
}

entity_parent :: proc(w:core.World_Ref,e:core.Entity) -> core.Entity {
    parents:=core.world_table_of(w,core.Parent)
    if parents==nil {return core.NONE}
    if parent,ok:=core.get(core.read(parents),e);ok {return parent.entity}
    return core.NONE
}

// The tree of Parent at the last settle, to go down it.
entity_hierarchy :: proc(w:core.World_Ref) -> core.Ref(core.Hierarchy) {
    return core.ref(core.world_storage_of(w,core.Hierarchy))
}

entity_children :: proc(w:core.World_Ref,e:core.Entity,allocator:=context.temp_allocator) -> []core.Entity {
    return core.children(entity_hierarchy(w),e,allocator)
}

// True when ancestor is e or holds it.
entity_under :: proc(w:core.World_Ref,e,ancestor:core.Entity) -> bool {
    parents:=core.world_table_of(w,core.Parent)
    if parents==nil {return e==ancestor && e!=core.NONE}
    return core.is_under(core.read(parents),e,ancestor)
}

entity_local :: proc(w:core.World_Ref,e:core.Entity) -> mm.Transform {
    transforms:=core.world_table_of(w,core.Transform)
    if transforms==nil {return mm.TRANSFORM_IDENTITY}
    if t,ok:=core.get(core.read(transforms),e);ok {return core.to_math(t)}
    return mm.TRANSFORM_IDENTITY
}

// Where an entity is in the world now, from the locals: what an edit of this frame moved too.
entity_world :: proc(w:core.World_Ref,e:core.Entity) -> mm.Transform {
    transforms:=core.world_table_of(w,core.Transform)
    parents:=core.world_table_of(w,core.Parent)
    if transforms==nil || parents==nil {return mm.TRANSFORM_IDENTITY}
    world,_:=core.world_of(core.read(transforms),core.read(parents),e)
    return world
}

entity_parent_world :: proc(w:core.World_Ref,e:core.Entity) -> mm.Transform {
    parent:=entity_parent(w,e)
    if parent==core.NONE {return mm.TRANSFORM_IDENTITY}
    return entity_world(w,parent)
}

// Whether an entity has the component, on or off: the editor shows and edits both.
entity_has :: proc(w:core.World_Ref,e:core.Entity,$T:typeid) -> bool {
    t:=core.world_table_of(w,T)
    return t!=nil && core.raw_row(core.raw(t),e)>=0
}

// The component of an entity, on or off.
entity_get :: proc(w:core.World_Ref,e:core.Entity,$T:typeid) -> (value:T,ok:bool) {
    t:=core.world_table_of(w,T)
    if t==nil {return}
    if row:=core.raw_row(core.raw(t),e);row>=0 {return t.values[row],true}
    return
}

// Hidden by itself or by an ancestor.
entity_hidden :: proc(w:core.World_Ref,e:core.Entity) -> bool {
    hidden:=core.world_table_of(w,erender.Hidden)
    if hidden==nil || core.raw_count(core.raw(hidden))==0 {return false}
    at:=e
    for _ in 0..<256 {
        if at==core.NONE {return false}
        if core.raw_row(core.raw(hidden),at)>=0 {return true}
        at=entity_parent(w,at)
    }
    return false
}

// The icon of what the components of an entity make of it: that of the card
// of a plugin whose component it has, before those of the engine.
entity_icon :: proc(s:^Session,w:core.World_Ref,e:core.Entity) -> (icon:ui.Icon,color:ui.Color) {
    if link,linked:=prefab_link_of(w,e);linked && link.root {return .Prefab,PREFAB_COLOR}
    if card,found:=card_of_entity(s,w,e);found {return card.icon,card.color}
    icons:=SHAPE_ICONS
    if mesh,ok:=entity_get(w,e,erender.Mesh_Renderer);ok {return mesh.mesh!={}?.Mesh:icons[mesh.shape],MESH_COLOR}
    light :: proc(icon:ui.Icon,color:[3]f32) -> (ui.Icon,ui.Color) {
        lift:=color*0.6+0.4
        return icon,ui.rgb_color({clamp(lift.x,0,1),clamp(lift.y,0,1),clamp(lift.z,0,1)})
    }
    if point,ok:=entity_get(w,e,erender.Point_Light);ok {return light(.Light,point.color)}
    if spot,ok:=entity_get(w,e,erender.Spot_Light);ok {return light(.Spot,spot.color)}
    if sun,ok:=entity_get(w,e,erender.Sun);ok {return light(.Sun,sun.color)}
    if rect,ok:=entity_get(w,e,erender.Rect_Light);ok {return light(.Area_Light,rect.color)}
    if entity_has(w,e,erender.Camera) {return CAMERA_ICON,CAMERA_COLOR}
    if entity_has(w,e,eaudio.Audio_Source) {return .Sound,SOUND_COLOR}
    if entity_has(w,e,eaudio.Audio_Reverb) {return .Collider,SOUND_COLOR}
    return .Group,GROUP_COLOR
}

// ---------------------------------------------------------------- ids and names

// The name itself when no entity has it; otherwise "name N" with the first
// N free, counting from the number the name ends in.
name_free :: proc(w:core.World_Ref,name:string,allocator:=context.temp_allocator) -> string {
    names:=core.world_table_of(w,core.Name)
    stem:=strings.trim_space(name)
    if stem=="" {stem="Entity"}
    first:=1
    if space:=strings.last_index_byte(stem,' ');space>0 {
        if n,numeric:=strconv.parse_int(stem[space+1:],10);numeric && n>0 {stem,first=stem[:space],n}
    }
    count:=names!=nil?len(names.values):0
    // Each name takes at most one number: one of these is free.
    taken:=make([]bool,count+1,context.temp_allocator)
    for i in 0..<count {
        text:=base.text_get(names.values[i].text[:])
        n:=0
        if text==stem {
            n=1
        } else if len(text)>len(stem)+1 && strings.has_prefix(text,stem) && text[len(stem)]==' ' {
            n,_=strconv.parse_int(text[len(stem)+1:],10)
        }
        if n>=first && n-first<len(taken) {taken[n-first]=true}
    }
    n:=first
    for n-first<count && taken[n-first] {n+=1}
    if n==1 {return strings.clone(stem,allocator)}
    return fmt.aprintf("%s %d",stem,n,allocator=allocator)
}

// The order an entity takes after the children a parent has.
@(private)
order_next :: proc(w:core.World_Ref,parent:core.Entity) -> i32 {
    parents:=core.world_table_of(w,core.Parent)
    if parents==nil || parent==core.NONE {return 0}
    last,ok:=core.get(core.read(parents),core.last_child(entity_hierarchy(w),parent))
    return ok?max(last.order+1,0):0
}

// ---------------------------------------------------------------- edits

// Creates an entity of a preset with Id, Name and Transform, under parent
// when it is given. Its components appear when the function ends.
entity_create :: proc(s:^Session,desc:Create_Desc) -> core.Entity {
    if watching(s) {return core.NONE}
    // While a section is edited in its world, what is added without a parent goes inside it.
    if parent:=desc.parent!=core.NONE?desc.parent:section_editing(s);section_target_refused(s,parent) {return core.NONE}
    index:=max(desc.card,int(desc.preset))
    all:=cards(s)
    if index>=len(all) {return core.NONE}
    opened,edit_ready:=edit_open(s,fmt.tprintf("Add %s",all[index].label))
    if !edit_ready {return core.NONE}
    defer edit_close(s,opened)
    return entity_make(s,editing_world(s),desc)
}

// entity_create without a step of undo.
@(private)
entity_make :: proc(s:^Session,w:core.World_Ref,desc:Create_Desc) -> core.Entity {
    desc:=desc
    if desc.transform=={} {desc.transform=core.TRANSFORM_IDENTITY}
    if index:=max(desc.card,int(desc.preset));index<len(Preset) && desc.transform.rotation==1 {desc.transform.rotation=preset_rotation(Preset(index))}
    root:=core.NONE
    if w.data==s.edit_world {root=section_editing(s)}
    if root!=core.NONE && desc.parent==core.NONE && !playing(s) {
        transform:=desc.transform=={}?core.TRANSFORM_IDENTITY:desc.transform
        local,ok:=mm.transform_relative(core.to_math(transform),entity_world(w,root))
        if !ok {return core.NONE}
        desc.parent,desc.transform=root,core.from_math(local)
    }
    es:=core.world_entities(w)
    all:=cards(s)
    index:=max(desc.card,int(desc.preset))
    if index>=len(all) {return core.NONE}
    card:=all[index]
    e:=core.create(es)
    transform:=desc.transform
    if transform=={} {transform=core.TRANSFORM_IDENTITY}
    if card.scale!={} {transform.scale*=card.scale}
    if t:=core.world_table_of(w,core.Transform);t!=nil {core.add(t,e,transform)}
    if t:=core.world_table_of(w,core.Id);t!=nil {core.add(t,e,core.Id{core.id_new(es,&s.id_state)})}
    if t:=core.world_table_of(w,core.Name);t!=nil {
        name:=desc.named?desc.name:name_free(w,desc.name!=""?desc.name:card.label)
        core.add(t,e,core.name_make(name))
    }
    if desc.parent!=core.NONE && core.alive(es,desc.parent) {
        if t:=core.world_table_of(w,core.Parent);t!=nil {core.add(t,e,core.Parent{desc.parent,order_next(w,desc.parent)})}
    }
    if card.make!=nil {card.make(s,w,e)} else {preset_components(w,e,Preset(index))}
    return e
}

@(private)
preset_components :: proc(w:core.World_Ref,e:core.Entity,preset:Preset) {
    author.preset_components(w,e,preset)
}

// A sound placed in the scene: a spatial source in a loop that the room
// reverberates and walls hide.
sound_components :: proc(w:core.World_Ref,e:core.Entity,sound:base.Asset_Id) {
    author.sound_components(w,e,sound)
}

// How a preset turns what it makes when no rotation is given: a sun shines
// from the morning of SUN_DIRECTION and a spot down. Lights shine toward -Z.
preset_rotation :: proc(preset:Preset) -> mm.Quat {
    return author.preset_rotation(preset)
}

// The primitive a preset shows; None for one without a body.
preset_shape :: proc "contextless" (preset:Preset) -> erender.Shape {
    return author.preset_shape(preset)
}

// Destroys entities and everything under them.
entities_delete :: proc(s:^Session,entities:[]core.Entity) {
    if watching(s) || section_refused(s,..section_alone(s,entities)) {return}
    w:=editing_world(s)
    if len(entities)==0 {return}
    opened,edit_ready:=edit_open(s,"Delete")
    if !edit_ready {return}
    defer edit_close(s,opened)
    kept:=false
    for e in entities {
        // What a section holds goes with its reference, which is among them.
        if section_locked(s,w,e) {continue}
        if prefab_member_locked(s,w,e) {kept=true;continue}
        core.world_destroy_tree(w,e)
    }
    if kept {notify(s,"A member of a prefab instance stays: turn it off, or unlink the instance")}
    selection:=w.data==s.edit_world?document_selection(s):s.selection
    for e in entities {
        if prefab_member_locked(s,w,e) {continue}
        for i:=len(selection.entities)-1;i>=0;i-=1 {
            if entity_under(w,selection.entities[i],e) {ordered_remove(&selection.entities,i)}
        }
    }
    selection.serial+=1
}

// Copies entities with everything under them, next to their originals:
// what a scene saves of each, with references inside a copy pointing to the
// copy. Returns the copies of the entities given, in their order.
entities_duplicate :: proc(s:^Session,entities:[]core.Entity,label:="Duplicate",allocator:=context.temp_allocator) -> []core.Entity {
    if watching(s) || section_refused(s,..entities) {return nil}
    w:=editing_world(s)
    es:=core.world_entities(w)
    if len(entities)==0 {return nil}
    opened,edit_ready:=edit_open(s,label)
    if !edit_ready {return nil}
    defer edit_close(s,opened)
    sources:=make([dynamic]core.Entity,context.temp_allocator)
    roots:=make([dynamic]int,context.temp_allocator)
    gather :: proc(w:core.World_Ref,e:core.Entity,out:^[dynamic]core.Entity) {
        append(out,e)
        for child in entity_children(w,e) {if entity_author(w,child)==child {gather(w,child,out)}}
    }
    for e in entities {
        if !core.alive(es,e) {continue}
        append(&roots,len(sources))
        gather(w,e,&sources)
    }
    copies:=make([]core.Entity,len(sources),context.temp_allocator)
    for &c in copies {c=core.create(es)}
    find :: proc(sources:[]core.Entity,e:core.Entity) -> int {
        for source,i in sources {
            if source==e {return i}
        }
        return -1
    }
    is_root :: proc(roots:[]int,at:int) -> bool {
        for r in roots {
            if r==at {return true}
        }
        return false
    }
    for &t in w.info.tables {
        if t.place!=.World || !author.type_saved(t.info) {continue}
        table:=core.world_table_at(w,&t)
        info:=t.info
        offsets:=entity_offsets(t.info)
        transient:=history.transient_ranges(t.info)
        buffer:=make([]u8,max(info.size,1),context.temp_allocator)
        for source,at in sources {
            value:=core.raw_find(table,t.info,source)
            if value==nil {continue}
            if info.size>0 {mem.copy(raw_data(buffer),value,info.size)}
            for r in transient {
                if r[1]>0 {mem.zero(&buffer[r[0]],r[1])}
            }
            for offset in offsets {
                field:=cast(^core.Entity)&buffer[offset]
                if found:=find(sources[:],field^);found>=0 {field^=copies[found]}
            }
            switch t.type {
            case core.Id:
                (cast(^core.Id)raw_data(buffer)).value=core.id_new(core.world_entities(w),&s.id_state)
            case core.Name:
                if is_root(roots[:],at) {
                    name:=cast(^core.Name)raw_data(buffer)
                    name^=core.name_make(name_free(w,base.text_get(name.text[:])))
                }
            case core.Parent:
                if is_root(roots[:],at) {
                    parent:=cast(^core.Parent)raw_data(buffer)
                    parent.order=order_next(w,parent.entity)
                }
            }
            core.raw_add(table,t.info,copies[at],raw_data(buffer))
        }
    }
    if len(sources)>0 {
        core.world_settle(w)
        prefab_copies_settle(w,copies)
    }
    result:=make([]core.Entity,len(roots),allocator)
    for r,i in roots {result[i]=copies[r]}
    return result
}

entity_rename :: proc(s:^Session,e:core.Entity,name:string) -> bool {
    if watching(s) || section_refused(s,e) {return false}
    w:=editing_world(s)
    names:=core.world_table_of(w,core.Name)
    text:=strings.trim_space(name)
    if names==nil || text=="" || !entity_alive(w,e) {return false}
    opened,edit_ready:=edit_open(s,"Rename")
    if !edit_ready {return false}
    defer edit_close(s,opened)
    if row:=core.get(names,e);row!=nil {
        row^=core.name_make(text)
    } else {
        core.add(names,e,core.name_make(text))
    }
    return true
}

// Moves an entity under another, NONE for the root, keeping where it is in
// the world. False when the parent is the entity or under it, or a parent
// without size on an axis cannot hold it there.
entity_reparent :: proc(s:^Session,e,parent:core.Entity) -> bool {
    if watching(s) {return false}
    w:=editing_world(s)
    parents:=core.world_table_of(w,core.Parent)
    transforms:=core.world_table_of(w,core.Transform)
    if parents==nil || !entity_alive(w,e) || parent!=core.NONE && (!entity_alive(w,parent) || entity_under(w,parent,e)) {return false}
    if entity_parent(w,e)==parent {return true}
    if section_refused(s,e) || section_target_refused(s,parent) || prefab_member_locked(s,w,e) {return false}
    local:=mm.TRANSFORM_IDENTITY
    if transforms!=nil {local=core.local_under(core.read(transforms),core.read(parents),parent,entity_world(w,e)) or_return}
    opened,edit_ready:=edit_open(s,"Parent")
    if !edit_ready {return false}
    defer edit_close(s,opened)
    if transforms!=nil {
        if row:=core.get(transforms,e);row!=nil {row^=core.from_math(local)}
    }
    if parent==core.NONE {core.remove(parents,e)} else {core.add(parents,e,core.Parent{parent,order_next(w,parent)})}
    return true
}

// Places an entity among the children of its parent: order says where.
entity_order_set :: proc(s:^Session,e:core.Entity,order:i32) {
    if watching(s) || section_refused(s,e) {return}
    w:=editing_world(s)
    parents:=core.world_table_of(w,core.Parent)
    if parents==nil {return}
    current,placed:=core.get(core.read(parents),e)
    if !placed || current.order==order {return}
    opened,edit_ready:=edit_open(s,"Order")
    if !edit_ready {return}
    defer edit_close(s,opened)
    if row:=core.get(parents,e);row!=nil {row.order=order}
}

entity_hidden_set :: proc(s:^Session,e:core.Entity,hidden:bool) {
    if watching(s) || section_refused(s,e) {return}
    w:=editing_world(s)
    table:=core.world_table_of(w,erender.Hidden)
    if table==nil || entity_has(w,e,erender.Hidden)==hidden {return}
    opened,edit_ready:=edit_open(s,hidden?"Hide":"Show")
    if !edit_ready {return}
    defer edit_close(s,opened)
    if hidden {core.add(table,e,erender.Hidden{})} else {core.remove(table,e)}
}

// Writes the Transform of an entity. While a Play runs, a row another
// component owns (a body) is left to it.
transform_set :: proc(s:^Session,e:core.Entity,t:mm.Transform) -> bool {
    if watching(s) || section_refused(s,e) {return false}
    w:=editing_world(s)
    transforms:=core.world_table_of(w,core.Transform)
    if transforms==nil {return false}
    opened,edit_ready:=edit_open(s,"Transform")
    if !edit_ready {return false}
    defer edit_close(s,opened)
    row:=w.data==s.edit_world?core.get(transforms,e):core.free(transforms,e)
    if row==nil {return false}
    row^=core.from_math(t)
    return true
}

// The table of a component of the World shown, by its name as scenes and the API name it.
component_table :: proc(s:^Session,name:string) -> ^core.Table_Info {
    _,info:=core.world_table_named(editing_world(s),name)
    return info
}

// The table of the component a text of the API names in a world, as
// base.name_find takes it; nil and what is wrong with the name otherwise.
api_component_named :: proc(w:core.World_Ref,name:string) -> (table:^core.Table_Info,problem:string) {
    for &t in w.info.tables {
        if t.place==w.place && t.name==name {return &t,""}
    }
    names:=make([dynamic]string,context.temp_allocator)
    tables:=make([dynamic]^core.Table_Info,context.temp_allocator)
    for &t in w.info.tables {
        if t.place==w.place {append(&names,t.name);append(&tables,&t)}
    }
    index,_:=base.name_find(name,names[:])
    if index>=0 {return tables[index],""}
    return nil,base.name_problem(name,"a component of the world",names[:])
}

// Gives an entity a component, or replaces its value: value nil gives the
// one it starts with (component_default).
component_add :: proc(s:^Session,e:core.Entity,t:^core.Table_Info,value:rawptr=nil) {
    if watching(s) || section_refused(s,e) {return}
    w:=editing_world(s)
    if t==nil || t.place!=.World || !entity_alive(w,e) {return}
    opened,edit_ready:=edit_open(s,fmt.tprintf("Add %s",readable(t.name)))
    if !edit_ready {return}
    defer edit_close(s,opened)
    source:=value
    if source==nil {
        buffer:=make([]u8,max(t.info.size,1),context.temp_allocator)
        if t.default!=nil {t.default(raw_data(buffer))} else {component_default(t.type,buffer)}
        source=raw_data(buffer)
    }
    core.raw_add(core.world_table_at(w,t),t.info,e,source)
    component_companions(s,e,t)
}

component_remove :: proc(s:^Session,e:core.Entity,t:^core.Table_Info) {
    if watching(s) || section_refused(s,e) {return}
    w:=editing_world(s)
    if t==nil || t.place!=.World {return}
    opened,edit_ready:=edit_open(s,fmt.tprintf("Remove %s",readable(t.name)))
    if !edit_ready {return}
    defer edit_close(s,opened)
    core.raw_remove(core.world_table_at(w,t),e)
}

// Turns a component of an entity off by itself, or on: it keeps its values.
component_turn :: proc(s:^Session,e:core.Entity,t:^core.Table_Info,off:bool) {
    if watching(s) || section_refused(s,e) {return}
    w:=editing_world(s)
    if t==nil || t.place!=.World {return}
    table:=core.world_table_at(w,t)
    _,turned_off,found:=core.raw_state(table,e)
    if !found || table.base || turned_off==off {return}
    opened,edit_ready:=edit_open(s,fmt.tprintf("Turn %s %s",readable(t.name),off?"off":"on"))
    if !edit_ready {return}
    defer edit_close(s,opened)
    if off {core.raw_disable(table,e)} else {core.raw_enable(table,e)}
}

// Turns an entity and everything under it off, or on (core.Disabled).
entity_enabled_set :: proc(s:^Session,e:core.Entity,enabled:bool) {
    if watching(s) || section_refused(s,e) {return}
    w:=editing_world(s)
    table:=core.world_table_of(w,core.Disabled)
    if table==nil || entity_has(w,e,core.Disabled)!=enabled {return}
    opened,edit_ready:=edit_open(s,enabled?"Enable":"Disable")
    if !edit_ready {return}
    defer edit_close(s,opened)
    if enabled {core.remove(table,e)} else {core.add(table,e,core.Disabled{})}
}

// Writes bytes at an offset of the component of every entity given that has
// it. The step is the gesture that is open, or one of its own.
field_write :: proc(s:^Session,t:^core.Table_Info,entities:[]core.Entity,offset:int,bytes:[]u8) -> bool {
    if watching(s) || section_refused(s,..entities) {return false}
    w:=editing_world(s)
    if t==nil || offset<0 || offset+len(bytes)>t.info.size {return false}
    table:=core.world_table_at(w,t)
    opened,edit_ready:=edit_open(s,readable(t.name))
    if !edit_ready {return false}
    defer edit_close(s,opened)
    written:=false
    for e in entities {
        if t.type==core.Transform && s.mode!=.Edit && core.owner(cast(^core.Table(core.Transform))table,e)!=0 {continue}
        value:=core.raw_get(table,t.info,e)
        if value==nil {continue}
        mem.copy(rawptr(uintptr(value)+uintptr(offset)),raw_data(bytes),len(bytes))
        written=true
    }
    return written
}

// The value a component starts with when the editor adds it.
component_default :: proc(type:typeid,out:[]u8) {
    author.component_default(type,out)
}

// Offsets of the Entity fields of a type, nested ones included.
entity_offsets :: proc(type:^runtime.Type_Info,allocator:=context.temp_allocator) -> []uintptr {
    return author.entity_offsets(type,allocator)
}

// "linear_damping" and "Mesh_Renderer" as people read them: "Linear damping", "Static mesh".
readable :: proc(name:string,allocator:=context.temp_allocator) -> string {
    text,error:=make([]u8,len(name),allocator)
    if error!=nil {return name}
    for i in 0..<len(name) {
        c:=name[i]
        switch {
        case c=='_':                 c=' '
        case i==0 && c>='a' && c<='z': c-=32
        case i>0 && c>='A' && c<='Z':  c+=32
        }
        text[i]=c
    }
    return string(text)
}
