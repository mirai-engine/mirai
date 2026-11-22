package kai_assets

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import vcs "mirai:kai"

// The conflicts of a working copy, never blocking: a conflicted asset is
// written with ours where the sides disagree, and its fields in conflict are
// read again from the sides of the conflict. Resolving writes the file with a
// side picked per field, or one side whole, and the next snapshot records it.

// A field, a row or a table both sides changed apart.
Field_Conflict :: struct {
    kind:asset.Merge_Kind,
    path:string,        // document_locate path: what resolve takes
    table:string,
    key:u64,            // the entity or row, when it has an id
    name:string,        // of the entity, else the key in hex
    ours_has,theirs_has:bool,
    ours,theirs:string, // of a value, as text
}

Resolve_Whole :: enum u8 {Fields,Ours,Theirs}

// The fields in conflict of the file at path; asset false for a file that is
// not an asset both sides of which read (text, binary): it resolves whole.
conflict_fields :: proc(w:^vcs.Workspace,types:^asset.Types,path:string,out:^[dynamic]Field_Conflict,allocator:=context.temp_allocator) -> (is_asset:bool,error:vcs.Error) {
    ours_bytes,origin_bytes,theirs_bytes,has_base,ok:=conflict_sides(w,path,allocator)
    if !ok {return false,.Invalid_Argument}
    ours,origin,theirs:asset.Document
    if ours_bytes==nil || theirs_bytes==nil || asset.document_read(&ours,ours_bytes,allocator)!=.None {return false,.None}
    if asset.document_read(&theirs,theirs_bytes,allocator)!=.None {return false,.None}
    if has_base && asset.document_read(&origin,origin_bytes,allocator)!=.None {return false,.None}
    if ours.kind!=theirs.kind {return false,.None}
    m:asset.Merge
    m.conflicts=make([dynamic]asset.Merge_Conflict,allocator)
    merged:asset.Document
    if asset.document_read(&merged,ours_bytes,allocator)!=.None {return false,.None}
    if asset.scene_merge(&m,types,&merged,has_base?&origin:nil,&theirs)!=.None {return false,.None}
    for c in m.conflicts {
        row:=Field_Conflict{kind=c.kind,path=c.path,table=c.table,key=c.key,ours_has=c.ours,theirs_has=c.theirs}
        if c.kind==.Value {
            row.ours=value_text(&ours,c.path,allocator)
            row.theirs=value_text(&theirs,c.path,allocator)
        }
        row.name=entity_name(&ours,&theirs,c.key,allocator)
        if _,e:=append(out,row);e!=nil {return true,.Out_Of_Memory}
    }
    return true,.None
}

@(private)
value_text :: proc(doc:^asset.Document,path:string,allocator:runtime.Allocator) -> string {
    location,error:=asset.document_locate(doc,path)
    if error!=.None || location.column<0 {return ""}
    w:serial.Writer
    serial.writer_init(&w,allocator=allocator)
    serial.text_write(&w,&doc.schema,location.type,location.bytes,.Line,0,location.is_text)
    return string(serial.writer_bytes(&w))
}

@(private)
entity_name :: proc(ours,theirs:^asset.Document,key:u64,allocator:runtime.Allocator) -> string {
    if key==0 {return ""}
    path:=fmt.tprintf("entities[@0x%016x].name",key)
    for doc in ([]^asset.Document{ours,theirs}) {
        if value,_,error:=asset.document_get(doc,path);error==.None {
            if name,ok:=value.(string);ok && name!="" {return fmt.aprint(name,allocator=allocator)}
        }
    }
    return fmt.aprintf("0x%016x",key,allocator=allocator)
}

// The bytes of the file at path resolved: one side whole, or the merge with
// ours where they disagree but for the conflicts whose paths are in theirs.
conflict_resolved :: proc(w:^vcs.Workspace,types:^asset.Types,path:string,whole:Resolve_Whole,theirs:[]string,allocator:=context.temp_allocator) -> (bytes:[]u8,removed:bool,error:vcs.Error) {
    ours_bytes,origin_bytes,theirs_bytes,has_base,ok:=conflict_sides(w,path,allocator)
    if !ok {return nil,false,.Invalid_Argument}
    switch whole {
    case .Ours: return ours_bytes,ours_bytes==nil,.None
    case .Theirs: return theirs_bytes,theirs_bytes==nil,.None
    case .Fields:
    }
    ours,origin,other:asset.Document
    if ours_bytes==nil || theirs_bytes==nil || asset.document_read(&ours,ours_bytes,allocator)!=.None || asset.document_read(&other,theirs_bytes,allocator)!=.None {return nil,false,.Invalid_Argument}
    if has_base && asset.document_read(&origin,origin_bytes,allocator)!=.None {return nil,false,.Invalid_Argument}
    m:asset.Merge
    m.conflicts=make([dynamic]asset.Merge_Conflict,allocator)
    if asset.scene_merge(&m,types,&ours,has_base?&origin:nil,&other)!=.None {return nil,false,.Invalid_Argument}
    is_scene:=ours.kind==asset.KIND_SCENE
    scene:asset.Scene
    if is_scene {
        if asset.scene_from_document(&scene,types,&ours)!=.None {return nil,false,.Invalid_Argument}
    }
    target:=is_scene?&scene.doc:&ours
    theirs_scene:asset.Scene
    theirs_read:=false
    for c in m.conflicts {
        if !slice.contains(theirs,c.path) {continue}
        switch c.kind {
        case .Value:
            location,locate_error:=asset.document_locate(target,c.path)
            if locate_error!=.None || location.column<0 {continue}
            reader:serial.Text_Reader
            serial.text_reader_init(&reader,value_text(&other,c.path,allocator))
            if serial.text_read(&reader,&target.schema,location.type,location.bytes,location.is_text) {serial.text_end(&reader)}
        case .Removed:
            if !is_scene {continue}
            key:=base.Entity_Id(c.key)
            if c.ours && !c.theirs {
                if c.table==asset.TABLE_ENTITIES {asset.scene_entities_remove(&scene,{key},descendants=false)}
                else if at,found:=asset.scene_component(&scene,c.table);found {asset.scene_component_remove(&scene,at,key)}
            } else if !c.ours && c.theirs {
                if !theirs_read {theirs_read=asset.scene_read(&theirs_scene,types,theirs_bytes,allocator)==.None}
                if theirs_read {scene_restore(&scene,&theirs_scene,key,c.table)}
            }
        case .Table:
            asset.document_table_take(target,&other,c.table)
        }
    }
    e:asset.Error
    if is_scene {bytes,e=asset.scene_bytes(&scene,allocator)} else {bytes,e=asset.document_bytes(&ours,allocator)}
    if e!=.None {return nil,false,.Invalid_Argument}
    return bytes,false,.None
}

// An entity, or one component of it, as theirs has it.
@(private)
scene_restore :: proc(scene,theirs:^asset.Scene,key:base.Entity_Id,table:string) {
    row,found:=asset.scene_entity_find(theirs,key)
    if !found {return}
    if table==asset.TABLE_ENTITIES {
        if _,has:=asset.scene_entity_find(scene,key);!has {
            record:=asset.scene_entity(theirs,row)
            parent:=record.parent
            if _,known:=asset.scene_entity_find(scene,parent);!known {parent=0}
            if _,error:=asset.scene_entity_add(scene,key,parent,record.name);error!=.None {return}
        }
    }
    for &source,at in theirs.doc.tables {
        component:=at>0 && len(source.columns)==2 && source.columns[0].name==asset.COLUMN_ENTITY && source.columns[0].ref==0 && source.columns[1].name==asset.COLUMN_VALUE
        if !component || table!=asset.TABLE_ENTITIES && source.name!=table {continue}
        image,has:=asset.scene_component_get(theirs,at,key)
        if !has {continue}
        target,_:=asset.scene_component(scene,source.name)
        if target<0 {
            added,error:=asset.scene_component_add(scene,source.name,&theirs.doc.schema,source.columns[1].type)
            if error!=.None {continue}
            target=added
        }
        asset.scene_component_set(scene,target,key,image)
    }
}

// The file at path is resolved as it is now (written by whoever resolved it,
// or as the checkout left it): the conflict goes and a snapshot records it.
conflict_settle :: proc(w:^vcs.Workspace,path:string) -> vcs.Error {
    for m,k in w.state.conflicts {
        if m.path!=path {continue}
        delete(m.path,w.allocator)
        ordered_remove(&w.state.conflicts,k)
        _,e:=vcs.workspace_snapshot(w)
        return e
    }
    return .Invalid_Argument
}

// Resolves the conflict at path: the file written as conflict_resolved says,
// or removed, and settled. Io when the file could not be written or removed.
conflict_resolve :: proc(w:^vcs.Workspace,types:^asset.Types,path:string,whole:Resolve_Whole,theirs:[]string) -> vcs.Error {
    bytes,removed,e:=conflict_resolved(w,types,path,whole,theirs)
    if e!=.None {return e}
    file:=project.path(w.root,path,allocator=context.temp_allocator)
    if removed {
        if os.exists(file) && os.remove(file)!=nil {return .Io}
    } else {
        os.make_directory_all(os.dir(file))
        if serial.file_write_atomic(file,bytes)!=.None {return .Io}
    }
    return conflict_settle(w,path)
}
