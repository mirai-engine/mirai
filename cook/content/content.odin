package content

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:cook/author"
import "mirai:cook/records"
import "mirai:core"
import "mirai:engine/input"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/geom"
import mm "mirai:std/math"
import "mirai:std/serial"

// What the content tool of a project (its tools/content, which mirai content
// builds and runs in the root of the project) writes the assets it makes from
// code with. It is opened from the World_Info of the world generated for the
// project, which the tool imports, so the types of the game, the record types
// and the names of the generator are those the game is built with:
//
//   import world "generated:editor_world"
//
//   w:content.Writer
//   if !content.open(&w,world.info()) {os.exit(1)}
//   content.records_write(&w,"data/weapons.records",[]content.Row(game.Weapon){{"sword",{damage=12}}})
//   content.scene_write(&w,"arena/crates.scene",`{"entities":[{"name":"Crate","prefab":"props/crate.scene"}]}`)
//   content.check(&w,"assets/hud/badge.tex",asset.texture_save("assets/hud/badge.tex",&w.types,desc))
//   os.exit(content.close(&w))
//
// Every write leaves a file that already holds its bytes untouched, and every
// failure names the file and the line of the tool that asked for it. A scene
// or a prefab is validated by what scene.write and mirai scene use and stays
// editable like any other; running the tool again overwrites what it writes.

Writer :: struct {
    using project:author.Project, // the assets of the project (registry, types) and its root
    world:core.World_Info,        // of the generated world the tool was built with
    started:time.Time,
    failed:bool,                  // something was not written: close returns 1
    written,unchanged:int,
}

// A row of a table of a record type, by its name.
Row :: struct($T:typeid) {
    name:string,
    value:T,
}

// Opens the project the tool runs in (the current folder) with the types of
// world: the World_Info of the generated world (world.info()). False, after
// saying why, when the project cannot be read; the tool is run by mirai
// content, which says where the engine is.
open :: proc(w:^Writer,world:core.World_Info,loc:=#caller_location) -> bool {
    w^={world=world,started=time.now()}
    engine,found:=os.lookup_env("MIRAI_ROOT",context.temp_allocator)
    if !found {return fail(w,loc,"the engine is unknown: a content tool runs with mirai content <project>, which builds it and names the engine")}
    root,_:=os.get_working_directory(context.temp_allocator)
    if problem:=author.project_open(&w.project,project.path_absolute(root,context.temp_allocator),engine,library=false);problem!="" {return fail(w,loc,problem)}
    // What the documents the tool writes compress with: what the project ships with.
    w.types.codecs=asset.project_codecs(w.root)
    w.info=&w.world
    return true
}

// Says what was written and frees the writer. The exit code of the tool: 1
// when something failed.
close :: proc(w:^Writer) -> int {
    fmt.printfln("content: %d written, %d unchanged%s",w.written,w.unchanged,w.failed?", failed":"")
    failed:=w.failed
    author.project_close(&w.project)
    w^={}
    return 1 if failed else 0
}

// Takes the result of an asset save procedure (asset.texture_save,
// asset.material_save, asset.sound_set_save...) for the file at path,
// relative to the root of the project: it counts as written when the file
// changed and as unchanged when it already held those bytes (the save
// procedures leave such a file untouched). False on error, said with the line
// of the caller.
check :: proc(w:^Writer,path:string,error:asset.Error,loc:=#caller_location) -> bool {
    if error!=.None {return fail(w,loc,fmt.tprintf("%s: %v",path,error))}
    // What names no file (a step of the tool) counts as neither.
    info,stat_error:=os.stat(path,context.temp_allocator)
    if stat_error!=nil {return true}
    if time.diff(w.started,info.modification_time)<0 {w.unchanged+=1} else {note(w,path)}
    return true
}

// Makes the folder of a file the tool is about to write.
folder :: proc(path:string) {
    if at:=strings.last_index_byte(path,'/');at>0 {_=os.make_directory_all(path[:at])}
}

// The id of an asset the tool writes: the same on every run, and apart from those of other projects.
id :: proc(w:^Writer,kind,name:string) -> base.Asset_Id {return asset.content_id(w.name,kind,name)}

// ---------------------------------------------------------------- names

// The input action a member of an @(actions) enum of the game or of a library
// is, as the generator numbers it: data saves it by its name, never by this
// number, which moves when a library adds an action.
action :: proc(w:^Writer,member:$E,loc:=#caller_location) -> input.Action where intrinsics.type_is_enum(E) {
    actions:=core.actions_of(&w.world,typeid_of(E))
    if actions==nil {
        fail(w,loc,fmt.tprintf("%v is not of an @(actions) enum of the world the tool was built with",member))
        return 0
    }
    return input.Action(actions.base+i64(member))
}

// ---------------------------------------------------------------- records

// The reference of a row of a table of the record type T: the table at path
// under the assets folder and the row named. Write the table it names first:
// a row it does not have yet takes the id records_write gives it.
record :: proc(w:^Writer,$T:typeid,path,name:string) -> core.Record(T) {
    table:=table_id(w,path)
    ids,names,read:=records.rows_read(&w.registry,&w.types,table)
    if read {
        for &n,i in names {
            if serial.text_field(n[:])==name {return {table,core.Record_Id(ids[i])}}
        }
    }
    return {table,core.Record_Id(records.id_of_name(name,ids))}
}

// Writes the rows of a table of the declared record type T at path under the
// assets folder, in their order: the table holds these rows and no other. A
// row keeps the id it had by its name, and a new one takes an id made from
// its name, the same on every run. A table that does not exist holds rows of
// T beside the one that declares it. False, said with the line of the caller,
// when the type, the table or a row is refused.
records_write :: proc(w:^Writer,path:string,rows:[]Row($T),loc:=#caller_location) -> bool {
    type:=record_type(w,typeid_of(T))
    if type=="" {return fail(w,loc,fmt.tprintf("%v is not a record type of the world the tool was built with: a .records declares it (mirai records create) and the build generates its struct",typeid_of(T)))}
    values:=make([]string,len(rows),context.temp_allocator)
    for row,i in rows {
        value:=row.value
        text,ok:=value_text(w,type_info_of(T),&value)
        if !ok {return fail(w,loc,fmt.tprintf("%s: row %s could not be written as text",path,row.name))}
        values[i]=text
    }
    names:=make([]string,len(rows),context.temp_allocator)
    for row,i in rows {names[i]=row.name}
    return table_write(w,path,type,names,values,loc)
}

// The rows of a table as names and values as JSON, as records.set takes them:
// what records_write writes once each row is text. Exported for tools that
// read their rows from text (a CSV of a spreadsheet).
table_write :: proc(w:^Writer,path,type:string,names,values:[]string,loc:=#caller_location) -> bool {
    path:=records_path(path)
    e:records.Edit
    if message:=table_open(w,path,type,&e);message!="" {return fail(w,loc,fmt.tprintf("%s: %s",path,message))}
    defer records.destroy(&e)
    kept:=slice.clone(e.ids[:],context.temp_allocator)
    old_names:=slice.clone(e.names[:],context.temp_allocator)
    size:=records.row_size(&e)
    clear(&e.ids);clear(&e.names)
    e.values=e.values[:0]
    files:=records.tables_scan(&w.registry,&w.types)
    c,_:=records.context_make(&e,&w.world,&w.registry,&w.types,files)
    taken:=make([dynamic]u64,context.temp_allocator)
    for name,i in names {
        if message:=records.name_refusal(&e,name);message!="" {return fail(w,loc,fmt.tprintf("%s: %s",path,message))}
        id:u64
        for &n,at in old_names {
            if serial.text_field(n[:])==name {id=kept[at]}
        }
        if id==0 {id=records.id_of_name(name,taken[:])}
        append(&taken,id)
        bytes:=make([]u8,size,context.temp_allocator)
        copy(bytes,e.defaults)
        if message:=records.values_put(&c,bytes,values[i]);message!="" {return fail(w,loc,fmt.tprintf("%s: row %s: %s",path,name,message))}
        if !records.row_put(&e,id,name,bytes) {return fail(w,loc,fmt.tprintf("%s: out of memory",path))}
    }
    bytes,problem:=records.file_bytes(&e,&w.types)
    if problem!="" {return fail(w,loc,fmt.tprintf("%s: %s",path,problem))}
    return file_write(w,path,e.file,bytes,loc)
}

// The table at path loaded, or a new one of rows of the type, beside the
// table that declares it. message: why not.
@(private)
table_open :: proc(w:^Writer,path,type:string,e:^records.Edit) -> (message:string) {
    if file,found:=asset.registry_find_path(&w.registry,path);found {
        if message=records.load(&w.registry,&w.types,&w.world,file.id,e,context.temp_allocator);message!="" {return}
        if records.type_name(e)!=type {
            records.destroy(e)
            return fmt.tprintf("it holds rows of %s, not of %s",records.type_name(e),type)
        }
        return ""
    }
    declaring,_:=records.declaring_find(&w.registry,&w.types,type)
    if declaring=={} {return fmt.tprintf("no .records declares %s",type)}
    if message=records.load(&w.registry,&w.types,&w.world,declaring,e,context.temp_allocator);message!="" {return}
    e.id,e.declaring=table_id(w,path),declaring
    e.file=fmt.aprintf("%s/%s",w.assets_root,path,allocator=context.temp_allocator)
    e.folder=records.folder_of(path)
    e.info.declares=false
    e.info.description={}
    clear(&e.ids);clear(&e.names)
    e.values=e.values[:0]
    return ""
}

// The id of the table at path: the one its file has, or the one it takes when the tool makes it.
@(private)
table_id :: proc(w:^Writer,path:string) -> base.Asset_Id {
    path:=records_path(path)
    if file,found:=asset.registry_find_path(&w.registry,path);found {return file.id}
    return asset.content_id(w.name,"records",path)
}

@(private)
records_path :: proc(path:string) -> string {
    path:=author.asset_path(path)
    return path if strings.has_suffix(path,".records") else fmt.tprintf("%s.records",path)
}

// The name of the record type the Odin type is; "" when it is none.
@(private)
record_type :: proc(w:^Writer,type:typeid) -> string {
    for &r in w.world.records {
        if r.type==type {return r.name}
    }
    return ""
}

// A value of the game as JSON on one line, with the names of its @(names)
// values and of its enums.
@(private)
value_text :: proc(w:^Writer,info:^runtime.Type_Info,value:rawptr) -> (text:string,ok:bool) {
    s:serial.Schema
    serial.schema_init(&s,context.temp_allocator)
    defer serial.schema_destroy(&s)
    if _,named:=core.schema_named(&s,&w.world,context.temp_allocator);!named {return}
    type,added:=serial.schema_add_type_info(&s,info)
    if !added {return}
    out:serial.Writer
    serial.writer_init(&out,256,context.temp_allocator)
    serial.text_write(&out,&s,type,([^]u8)(value)[:info.size],.Line)
    return string(serial.writer_bytes(&out)),out.overflow==0
}

// ---------------------------------------------------------------- scenes

// Makes the scene or the prefab at path under the assets folder say what a
// document declares (the document of mirai scene and scene.write: entities
// by name, their components, placed prefabs), with the validation of both; a
// file that already says it is left as it is. False, said with the line of
// the caller, when the document is refused.
scene_write :: proc(w:^Writer,path,document:string,loc:=#caller_location) -> bool {
    written,problem:=author.scene_write(&w.project,author.asset_path(path),document)
    if problem!="" {return fail(w,loc,fmt.tprintf("%s: %s",path,problem))}
    if written.same {
        w.unchanged+=1
    } else {
        note(w,written.path)
    }
    return true
}

// A component of the game as the document of a scene takes it: JSON of its
// fields, by their names.
component :: proc(w:^Writer,value:$T) -> string {
    value:=value
    text,_:=value_text(w,type_info_of(T),&value)
    return text
}

// ---------------------------------------------------------------- meshes

// Writes a mesh made from code (geom.*_build, one Mesh_Buffer per asset) to
// path, relative to the root of the project; materials are its slots in
// order, none: the engine's default, and the colors of the buffer multiply
// them. Its id, from the project and the path, is the same on every run.
mesh :: proc(w:^Writer,path:string,buffer:^geom.Mesh_Buffer,materials:..base.Asset_Id,loc:=#caller_location) -> base.Asset_Id {
    made:=id(w,"mesh",path)
    if !geom.mesh_buffer_paint(buffer,{1,1,1,1}) {check(w,path,.Out_Of_Memory,loc);return made}
    if !geom.mesh_is_valid(geom.mesh_buffer_view(buffer)) || len(buffer.normals)!=len(buffer.positions) || len(buffer.uvs)!=len(buffer.positions) || len(buffer.indices)==0 {
        check(w,path,.Invalid,loc)
        return made
    }
    scratch:=context.temp_allocator
    vertices:=make([dynamic]asset.Vertex,0,len(buffer.positions),scratch)
    flags:asset.Mesh_Flags
    for position,i in buffer.positions {
        painted:=mm.rgba8_pack({buffer.colors[i].r,buffer.colors[i].g,buffer.colors[i].b,1})
        if painted!=0xffffffff {flags+={.Has_Colors}}
        append(&vertices,asset.Vertex{position=position,normal=mm.normal_pack(buffer.normals[i]),uv=buffer.uvs[i],uv1=buffer.uvs[i],color=painted})
    }
    indices:=make([]u32,len(buffer.indices),scratch)
    copy(indices,buffer.indices[:])
    if !asset.mesh_tangents(&vertices,indices) {check(w,path,.Out_Of_Memory,loc);return made}
    desc:=asset.Mesh_Desc{id=made}
    if len(materials)>0 {
        slots:=make([]asset.Material_Slot,len(materials),scratch)
        for material,i in materials {slots[i]={id=u32(i),material=material}}
        desc.slots=slots
    }
    if !asset.mesh_build_dag({vertices=vertices[:],flags=flags},indices,&desc.geometry,scratch) {check(w,path,.Invalid,loc);return made}
    folder(path)
    check(w,path,asset.mesh_save(path,&w.types,desc),loc)
    return made
}

// ---------------------------------------------------------------- files

// Writes bytes at file (path names it under the assets) unless it holds them already.
@(private)
file_write :: proc(w:^Writer,path,file:string,bytes:[]u8,loc:runtime.Source_Code_Location) -> bool {
    folder(file)
    written,error:=serial.file_write_changed(file,bytes)
    if error!=.None {return fail(w,loc,fmt.tprintf("%s could not be written",file))}
    if !written {
        w.unchanged+=1
        return true
    }
    _=asset.registry_refresh(&w.registry,{path})
    note(w,path)
    return true
}

@(private)
note :: proc(w:^Writer,path:string) {
    w.written+=1
    fmt.printfln("wrote %s",path)
}

// Says what failed with where the tool asked for it, as the compiler says
// where an error is, and marks the run as failed. Always false.
// The message is formatted by the caller: a generic procedure of this package
// is compiled in the tool, whose types the tables of this library lack.
@(private)
fail :: proc(w:^Writer,loc:runtime.Source_Code_Location,message:string) -> bool {
    fmt.eprintfln("%s(%d:%d) Error: %s",loc.file_path,loc.line,loc.column,message)
    w.failed=true
    return false
}

// Writes a file under the root of the project that is no asset document (the
// WAV or the glTF a tool makes as the source of an import) unless it holds
// those bytes already, so an import of an unchanged source makes the same asset.
source_write :: proc(w:^Writer,path:string,bytes:[]u8,loc:=#caller_location) -> bool {
    folder(path)
    written,error:=serial.file_write_changed(path,bytes)
    if error!=.None {return fail(w,loc,fmt.tprintf("%s could not be written",path))}
    if written {note(w,path)} else {w.unchanged+=1}
    return true
}
