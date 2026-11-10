package scene

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:slice"
import "mirai:asset"
import "mirai:core"
import volume "mirai:engine/volume"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"

// A document as a world places it: its values in the layout of the world,
// the row of the entity each reference names and the order of its children.
// Instantiating reads a document into one and places it; a prefab spawned
// while the world runs keeps its own (Prefab_Forms), so placing it again
// reads nothing. It holds nothing of the world it is placed in, and all of
// it is one block of memory.
@(private)
Form :: struct {
    scene:base.Asset_Id,
    kind:asset.Fourcc,
    root:u32,                  // the row the document names as its root, else its first root; NONE_ROW in an empty one
    ids:[]base.Entity_Id,
    names:[]asset.Entity_Name,
    parents:[]u32,             // rows; NONE_ROW for a root
    siblings:[]i32,            // the place of each among the children of its parent
    order:[]u32,               // the rows as their parents receive them
    instanced:[]bool,          // a prefab instance of the document placed it
    placed:[]bool,             // it has a Transform
    components:[]Form_Component,
    migrated,unknown:int,
    block:[]u8,
}

@(private)
Form_Component :: struct {
    table:int,       // of the World_Info
    name_hash:u64,
    size:int,
    membership:bool, // Prefab_Instance or Prefab_Member: a copy is no instance and gets none
    rows:[]u32,      // of the entities, increasing
    values:[]u8,     // as the world holds them, their Entity fields none
    off:[]bool,
    refs:[]Form_Ref, // the Entity fields that name something, by value
}

@(private)
Form_Ref :: struct {
    value:u32,  // index in rows
    offset:u32, // of the field in the value
    row:u32,    // of the entity it names; NONE_ROW: one outside the document
    target:base.Entity_Id,
}

@(private) FORM_ALIGN :: 16

// The block of a form: measured first, then taken part by part.
@(private)
Form_Memory :: struct {
    block:[]u8,
    used:int,
    measuring:bool,
}

@(private)
form_take :: proc(m:^Form_Memory,$T:typeid,count:int,align:=align_of(T)) -> []T {
    start:=mem.align_forward_int(m.used,align)
    m.used=start+count*size_of(T)
    if m.measuring || count==0 {return nil}
    return (cast([^]T)raw_data(m.block[start:]))[:count]
}

@(private)
Form_Off :: struct {entity:base.Entity_Id,component:u64}

// Reads a document into a form for the world, in memory of the allocator.
// One larger than limit is made in temporary memory instead, and is not held.
@(private)
form_make :: proc(w:core.World_Ref,a:^asset.Asset,asset_types:^asset.Types,allocator:runtime.Allocator,limit:=max(int)) -> (form:Form,held:bool,error:Error) {
    view,view_error:=asset.scene_view(a,asset_types)
    if view_error!=.None {return {},false,view_error==.Invalid?.Invalid:view_error==.Out_Of_Memory?.Out_Of_Memory:.Corrupt}
    if checked:=asset.scene_view_check(view,context.temp_allocator);checked!=.None {return {},false,.Out_Of_Memory if checked==.Out_Of_Memory else .Corrupt}
    types:=schema_of(w)
    if types==nil {return {},false,.Out_Of_Memory}
    memory:=Form_Memory{measuring=true}
    form_read(&memory,&form,w,a,view,types) or_return
    held=memory.used<=limit
    block,no_block:=mem.alloc_bytes(memory.used,FORM_ALIGN,held?allocator:context.temp_allocator)
    if no_block!=nil {return {},false,.Out_Of_Memory}
    memory={block=block}
    form={}
    if error=form_read(&memory,&form,w,a,view,types);error!=.None {
        if held {mem.free_bytes(block,allocator)}
        return {},false,error
    }
    form.block=block
    return
}

@(private)
form_read :: proc(m:^Form_Memory,form:^Form,w:core.World_Ref,a:^asset.Asset,view:asset.Scene_View,types:^core.World_Schema) -> Error {
    count:=len(view.ids)
    form.scene,form.kind,form.root=a.blob.header.id,a.blob.header.kind,NONE_ROW
    form.ids=form_take(m,base.Entity_Id,count)
    form.names=form_take(m,asset.Entity_Name,count)
    form.parents=form_take(m,u32,count)
    form.siblings=form_take(m,i32,count)
    form.order=form_take(m,u32,count)
    form.instanced=form_take(m,bool,count)
    form.placed=form_take(m,bool,count)
    form.components=form_take(m,Form_Component,len(view.components))
    keys:[]Key
    off:map[Form_Off]bool
    if !m.measuring {
        Place :: struct {order,row:u32}
        places,no_places:=make([]Place,count,context.temp_allocator)
        next,no_next:=make([]i32,count+1,context.temp_allocator)
        no_keys:mem.Allocator_Error
        keys,no_keys=make([]Key,count,context.temp_allocator)
        if no_places!=nil || no_next!=nil || no_keys!=nil {return .Out_Of_Memory}
        copy(form.ids,view.ids)
        copy(form.names,view.names)
        for id,row in view.ids {keys[row]={id,u32(row)}}
        slice.sort_by(keys,proc(a,b:Key) -> bool {return a.id<b.id})
        for parent,row in view.parents {form.parents[row],_=key_find(keys,parent)}
        for row in view.member_rows {form.instanced[row]=true}
        // Children keep the order of the document.
        for order,row in view.orders {places[row]={order,u32(row)}}
        slice.sort_by(places,proc(a,b:Place) -> bool {return a.order<b.order || a.order==b.order && a.row<b.row})
        for place,at in places {
            parent:=form.parents[place.row]
            slot:=parent==NONE_ROW?0:int(parent)+1
            form.siblings[place.row]=next[slot]
            next[slot]+=1
            form.order[at]=place.row
            if parent==NONE_ROW && form.root==NONE_ROW {form.root=place.row}
        }
        if root,found:=key_find(keys,view.info.root);found {form.root=root}
        off=make(map[Form_Off]bool,context.temp_allocator)
        for record in view.off {off[{record.entity,record.component}]=true}
    }
    known:=0
    for &component in view.components {
        at,found:=core.world_table_index_of_hash(w,component.name_hash)
        if !found {
            form.unknown+=1
            continue
        }
        info:=&w.info.tables[at]
        if is_structural(info.type) {continue}
        value_type:=&types.tables[at]
        rows,size:=len(component.entities),info.info.size
        c:=Form_Component{table=at,name_hash=component.name_hash,size=size,membership=info.type==Prefab_Instance || info.type==Prefab_Member}
        c.rows=form_take(m,u32,rows)
        c.off=form_take(m,bool,rows)
        c.values=form_take(m,u8,rows*size,FORM_ALIGN)
        c.refs=form_take(m,Form_Ref,rows*len(value_type.entities))
        if m.measuring {continue}
        copy(c.rows,component.entities)
        if size>0 && rows>0 {
            if value_type.type==serial.TYPE_NONE {
                stored,stored_error:=asset.scene_component_values(a,&component)
                if stored_error!=.None {return .Corrupt}
                copy(c.values,stored)
            } else {
                if !component_read(a,&component,types,info,value_type,c.values) {return .Corrupt}
                if !asset.asset_column_matches(a,component.table,1,value_type.hash) {form.migrated+=1}
            }
            named:=0
            for i in 0..<rows {
                image:=c.values[i*size:][:size]
                for offset in value_type.entities {
                    field:=cast(^u64)&image[offset]
                    target:=base.Entity_Id(intrinsics.unaligned_load(field))
                    intrinsics.unaligned_store(field,u64(core.NONE))
                    if target==0 {continue}
                    // Outside the document: the Id in the world of an entity of another section or of the root.
                    row,_:=key_find(keys,target)
                    c.refs[named]={u32(i),offset,row,target}
                    named+=1
                }
            }
            c.refs=c.refs[:named]
        }
        if len(off)>0 {
            for row,i in component.entities {c.off[i]=off[{view.ids[row],component.name_hash}]}
        }
        if info.type==core.Transform {
            for row in component.entities {form.placed[row]=true}
        }
        form.components[known]=c
        known+=1
    }
    if !m.measuring {form.components=form.components[:known]}
    return .None
}

@(private)
Form_Section :: struct {entity:core.Entity,reference:Scene_Reference,id:base.Entity_Id}

// Creates the entities of a form in a world, as desc says: entities receives
// the entity of every row. It reads the form and leaves it as it was.
@(private)
form_place :: proc(w:core.World_Ref,form:^Form,asset_types:^asset.Types,desc:Instantiate_Desc,entities:[]core.Entity) -> (report:Report,error:Error) {
    es:=core.world_entities(w)
    count:=len(form.ids)
    // The rows of the document it makes: all, or those under the one asked for.
    kept:[]bool
    top:=NONE_ROW
    if desc.only!=0 {
        for id,row in form.ids {
            if id_in(desc.salt,id)==desc.only {top=u32(row);break}
        }
        if top==NONE_ROW {return {},.Not_Found}
        no_kept:mem.Allocator_Error
        if kept,no_kept=make([]bool,count,context.temp_allocator);no_kept!=nil {return {},.Out_Of_Memory}
        for row in 0..<count {
            for x,depth:=u32(row),0;x!=NONE_ROW && depth<=count;x,depth=form.parents[x],depth+1 {
                if x==top {kept[row]=true;break}
            }
        }
    }
    for row in 0..<count {
        entities[row]=kept==nil || kept[row]?core.create(es):core.NONE
        report.entities+=int(entities[row]!=core.NONE)
    }

    transforms:=core.world_table_of(w,core.Transform)
    names:=core.world_table_of(w,core.Name)
    ids:=core.world_table_of(w,core.Id)
    parent_table:=core.world_table_of(w,core.Parent)
    members:=core.world_table_of(w,Section_Member)
    for row in 0..<count {
        e:=entities[row]
        if e==core.NONE {continue}
        if names!=nil {core.add(names,e,core.Name{text=form.names[row]})}
        if ids!=nil && !desc.transient {core.add(ids,e,core.Id{desc.fresh?core.id_next(es):id_in(desc.salt,form.ids[row])})}
        if members!=nil && desc.salt!=0 && !desc.transient {core.add(members,e,Section_Member{form.ids[row]})}
    }

    unresolved:=core.world_storage_of(w,Unresolved_References)
    sections:=make([dynamic]Form_Section,context.temp_allocator)
    // A copy is no instance: the prefabs its prefab places are not of this world.
    copied:=desc.fresh || desc.transient
    report.migrated,report.unknown=form.migrated,form.unknown
    for &c in form.components {
        if copied && c.membership {continue}
        info:=&w.info.tables[c.table]
        table:=core.world_table_at(w,info)
        report.components+=len(c.rows)
        named:=0
        for row,i in c.rows {
            e:=entities[row]
            if e==core.NONE {
                for named<len(c.refs) && c.refs[named].value==u32(i) {named+=1}
                continue
            }
            core.raw_add(table,info.info,e,c.size>0?&c.values[i*c.size]:nil)
            value:=c.size>0?core.raw_added(table,info.info,e):nil
            for ;named<len(c.refs) && c.refs[named].value==u32(i);named+=1 {
                ref:=c.refs[named]
                live:=core.NONE
                if ref.row!=NONE_ROW {live=entities[ref.row]}
                else if unresolved!=nil && !desc.transient {append(&unresolved.items,Unresolved_Reference{e,c.name_hash,ref.offset,ref.target})}
                else {report.dangling+=1}
                intrinsics.unaligned_store(cast(^u64)(uintptr(value)+uintptr(ref.offset)),u64(live))
            }
            if info.type==volume.Volume && desc.scope!=core.NONE {
                place:=(^volume.Volume)(value)
                if place.shape==.Unbounded {place.scope,place.scope_extents=desc.scope,desc.scope_extents}
            }
            if info.type==Scene_Reference && desc.only==0 {
                reference:=(^Scene_Reference)(value)
                if (desc.documents.open!=nil || desc.saved) && (reference.rule==.With_Document || desc.saved) && reference.state!=.Unloaded {reference.loaded=reference.scene}
                // Only what loads with its document; the others wait for their state (scene_sections).
                if reference.rule==.With_Document && reference.state!=.Unloaded {append(&sections,Form_Section{e,reference^,id_in(desc.salt,form.ids[row])})}
            }
            // What the world uses one of (a sky, a sun) of a section or a prefab, placed or in the document, comes off: only enable turns it on.
            if c.off[i] || info.single && (desc.salt!=0 || copied || form.instanced[row]) {core.raw_disable(table,e)}
        }
    }
    if transforms!=nil {
        for row in 0..<count {
            if entities[row]!=core.NONE && !form.placed[row] {core.add(transforms,entities[row],core.TRANSFORM_IDENTITY)}
        }
    }
    if parent_table!=nil {
        for row in form.order {
            e:=entities[row]
            if e==core.NONE {continue}
            parent_row:=row==top?NONE_ROW:form.parents[row]
            parent:=parent_row==NONE_ROW?desc.parent:entities[parent_row]
            if parent!=core.NONE {core.add(parent_table,e,core.Parent{parent,row==top?0:form.siblings[row]})}
        }
    }
    if top!=NONE_ROW {report.root=entities[top]}
    else if form.root!=NONE_ROW {report.root=entities[form.root]}
    // A section that loads with what holds it knows what its scene brought.
    if desc.parent!=core.NONE && desc.salt!=0 && !desc.transient && desc.only==0 {
        if _,recorded:=records_add(w,desc.parent,form.ids);!recorded {return report,.Out_Of_Memory}
    }
    if len(sections)>0 {
        if form.kind==asset.KIND_PREFAB {return report,.Invalid}
        sections_error:=sections_load(w,form.scene,asset_types,desc,sections[:],&report)
        if sections_error!=.None {return report,sections_error}
    }
    return report,.None
}

// How many prefabs a World keeps prepared, and the bytes of them all: past
// either, the one spawned longest ago goes.
PREFAB_FORMS :: 128
PREFAB_FORMS_BYTES :: 32<<20

// A file a prepared prefab was read from, as it was then.
@(private)
Form_Source :: struct {
    id:base.Asset_Id,
    hash:u64, // the content hash of the file; 0: there was none
}

// The files a document was resolved from, for whoever keeps what it read of it.
@(private)
Form_Sources :: struct {
    items:[dynamic]Form_Source,
    unsure:bool, // a prefab it places could not be asked: what was read may not be what the files give
}

@(private)
Prefab_Form :: struct {
    prefab:base.Asset_Id,
    form:Form,
    sources:[]Form_Source, // the prefab and every prefab it places, itself or through them
    used:u64,              // Prefab_Forms.clock when it was last spawned
}

// The prefabs a World spawned, each read once into the form the World places
// (scene.spawn): spawning one again creates its entities and rows and reads
// no file. A form is of the content of its prefab and of the prefabs that
// one places: when a file of them is another, it is read again. It is of this
// World and stays in it: a copy of the World (Play, a rollback) starts
// without them and prepares what it spawns.
@(storage,copy=false,free="prefab_forms_free")
Prefab_Forms :: struct {
    items:[dynamic]Prefab_Form,
    entities:[dynamic]core.Entity, // of the rows of the prefab being placed: room for the largest one prepared
    bytes:int,
    clock:u64,
    prepared:int, // prefabs read into a form since the World was made
    allocator:runtime.Allocator,
}

prefab_forms_free :: proc(forms:^Prefab_Forms) {
    for len(forms.items)>0 {forms_drop(forms,len(forms.items)-1)}
    delete(forms.items)
    delete(forms.entities)
    forms^={}
}

@(private)
forms_drop :: proc(forms:^Prefab_Forms,at:int) {
    kept:=forms.items[at]
    forms.bytes-=len(kept.form.block)+len(kept.sources)*size_of(Form_Source)
    mem.free_bytes(kept.form.block,forms.allocator)
    delete(kept.sources,forms.allocator)
    unordered_remove(&forms.items,at)
}

// Whether the files a form was read from are what they were.
@(private)
sources_current :: proc(assets:^host.Assets,sources:[]Form_Source) -> bool {
    for source in sources {
        file:=host.assets_scene(assets,source.id)
        if (file!=nil?file.blob.header.content_hash:0)!=source.hash {return false}
    }
    return true
}

// The form of a prefab for the world, and room for the entities of its rows:
// the one the World keeps while its files are what they were, else read now
// and kept. Without forms, or for a prefab larger than they keep, it is read
// into temporary memory.
@(private)
prefab_form :: proc(forms:^Prefab_Forms,w:core.World_Ref,assets:^host.Assets,prefab:base.Asset_Id,file:^asset.Asset) -> (form:^Form,entities:[]core.Entity,error:Error) {
    if forms!=nil {
        for &kept,at in forms.items {
            if kept.prefab!=prefab {continue}
            if sources_current(assets,kept.sources) {
                forms.clock+=1
                kept.used=forms.clock
                return &kept.form,forms.entities[:len(kept.form.ids)],.None
            }
            forms_drop(forms,at)
            break
        }
        if forms.allocator.procedure==nil {forms.allocator=context.allocator}
    }
    sources:=Form_Sources{items=make([dynamic]Form_Source,context.temp_allocator)}
    append(&sources.items,Form_Source{prefab,file.blob.header.content_hash})
    resolved:asset.Asset
    defer asset.asset_close(&resolved)
    document:=current(assets_documents(assets),file,&resolved,&sources) or_return
    keep:=forms!=nil && !sources.unsure
    made,held:=form_make(w,document,&assets.types,keep?forms.allocator:context.temp_allocator,keep?PREFAB_FORMS_BYTES:max(int)) or_return
    count:=len(made.ids)
    if !keep || !held {
        no_form,no_entities:mem.Allocator_Error
        if form,no_form=new_clone(made,context.temp_allocator);no_form!=nil {return nil,nil,.Out_Of_Memory}
        if entities,no_entities=make([]core.Entity,count,context.temp_allocator);no_entities!=nil {return nil,nil,.Out_Of_Memory}
        return
    }
    size:=len(made.block)+len(sources.items)*size_of(Form_Source)
    for len(forms.items)>0 && (len(forms.items)>=PREFAB_FORMS || forms.bytes+size>PREFAB_FORMS_BYTES) {
        oldest:=0
        for other,at in forms.items {
            if other.used<forms.items[oldest].used {oldest=at}
        }
        forms_drop(forms,oldest)
    }
    if forms.items==nil {forms.items=make([dynamic]Prefab_Form,forms.allocator)}
    if forms.entities==nil {forms.entities=make([dynamic]core.Entity,forms.allocator)}
    read_from,no_sources:=slice.clone(sources.items[:],forms.allocator)
    no_room:=no_sources!=nil || reserve(&forms.items,PREFAB_FORMS)!=nil
    if !no_room && len(forms.entities)<count {no_room=resize(&forms.entities,count)!=nil}
    forms.clock+=1
    if !no_room {
        _,no_item:=append(&forms.items,Prefab_Form{prefab,made,read_from,forms.clock})
        no_room=no_item!=nil
    }
    if no_room {
        mem.free_bytes(made.block,forms.allocator)
        delete(read_from,forms.allocator)
        return nil,nil,.Out_Of_Memory
    }
    forms.bytes+=size
    forms.prepared+=1
    return &forms.items[len(forms.items)-1].form,forms.entities[:count],.None
}
