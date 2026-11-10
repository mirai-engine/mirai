package core

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"

// The world of a test, described from its struct as the generator describes
// that of a project from its declarations. The struct starts with
// `using world:core.Test_World`; each other field is a table, Table(T) of a
// @(component), or a storage, a value of a @(storage). What the attributes of
// T say is read from the source that declares it, with declared_read as the
// generator does, so a test world marks no table or storage by hand. A type
// a test file declares may have no attribute: a plain component or storage.
// The tag of a field takes two options: `mirai:"game"`, the game of a
// project declares it, and `mirai:"name=Spin"`, the name its table or
// storage goes by when its type is named otherwise, as two versions of one
// library in a test are.
//
// A test that needs what the application or the editor hold gives two more
// structs: one of the @(storage,host), where a by_world one is a
// By_World(T), and one of the tables and storages of editor packages.
//
// It is here, in a test file of core, because the tests of core use it and a
// package that fills a World_Info imports core: no game binary carries it,
// and the tests of every package that imports core see it.
Test_World :: struct {
    entities:Entities,
    storage_revisions:[TEST_STORAGES]u64,
    made_of:^Test_Made,
}

// The storages a test world may hold, with those of its application and editor.
TEST_STORAGES :: 128

// A test world without Shared or without Editor names this in their place.
Test_None :: struct {_:u8}

// What the declaration of a type names and reflection does not find: the
// value it starts as, <NAME>_DEFAULT or <name>_default() of its package, the
// default of a storage on a GPU and the procedures of its attributes. A
// world fails to be made when one is missing or is given without being
// declared.
Test_Type :: struct {
    type:typeid,
    default:proc(dst:rawptr),
    for_device:proc(dst:rawptr,device:rawptr),
    copy,copy_kept:proc(dst,src:rawptr) -> bool,
    swap:proc(a,b:rawptr),
    free,reset:proc(value:rawptr),
}

// Adds the Test_Type of the types of a package and of the packages it
// depends on. A package whose components or storages have one exports it
// from a test file as test_types; a world of several libraries is given a
// procedure that calls theirs. Those of core are always there.
Test_Types :: #type proc(types:^[dynamic]Test_Type)

test_type :: proc($T:typeid,default:proc(dst:^T)=nil,copy:proc(dst,src:^T) -> bool=nil,copy_kept:proc(dst,src:^T) -> bool=nil,swap:proc(a,b:^T)=nil,free:proc(value:^T)=nil,reset:proc(value:^T)=nil,for_device:proc(dst:^T,device:rawptr)=nil) -> Test_Type {
    return {
        type=T,
        default=cast(proc(dst:rawptr))rawptr(default),
        for_device=cast(proc(dst:rawptr,device:rawptr))rawptr(for_device),
        copy=cast(proc(dst,src:rawptr) -> bool)rawptr(copy),
        copy_kept=cast(proc(dst,src:rawptr) -> bool)rawptr(copy_kept),
        swap=cast(proc(a,b:rawptr))rawptr(swap),
        free=cast(proc(value:rawptr))rawptr(free),
        reset=cast(proc(value:rawptr))rawptr(reset),
    }
}

@(private="file")
test_types_none :: proc(types:^[dynamic]Test_Type) {}

test_types_core :: proc(types:^[dynamic]Test_Type) {
    append(types,
        test_type(Transform,default=proc(dst:^Transform) {dst^=TRANSFORM_DEFAULT}),
        test_type(Own_Pace,default=proc(dst:^Own_Pace) {dst^=OWN_PACE_DEFAULT}),
        test_type(Simulation_Settings,default=proc(dst:^Simulation_Settings) {dst^=SIMULATION_SETTINGS_DEFAULT}),
        test_type(Frame_Time,default=proc(dst:^Frame_Time) {dst^=FRAME_TIME_DEFAULT}),
        test_type(Clock,default=proc(dst:^Clock) {dst^=CLOCK_DEFAULT}),
        test_type(View,default=proc(dst:^View) {dst^=VIEW_DEFAULT}),
        test_type(Hierarchy,reset=hierarchy_clear),
    )
}

// The World_Info of a test world, with those of core alone, with the types
// of other packages, or with what its application and its editor hold.
// Its init, destroy, copy, copy_changed, swap, clear, attach and detach do
// what the generated ones do; the test adds what it needs of the rest
// (steps, messages, names, records). test_info_destroy frees it.
test_info :: proc{test_info_core,test_info_types,test_info_app,test_info_places}

test_info_core :: proc(t:^testing.T,$W:typeid,allocator:=context.allocator,loc:=#caller_location) -> (info:World_Info,ok:bool) {
    return test_info_places(t,W,Test_None,Test_None,test_types_none,allocator,loc)
}

test_info_app :: proc(t:^testing.T,$W,$S,$E:typeid,allocator:=context.allocator,loc:=#caller_location) -> (info:World_Info,ok:bool) {
    return test_info_places(t,W,S,E,test_types_none,allocator,loc)
}

test_info_types :: proc(t:^testing.T,$W:typeid,$TYPES:Test_Types,allocator:=context.allocator,loc:=#caller_location) -> (info:World_Info,ok:bool) {
    return test_info_places(t,W,Test_None,Test_None,TYPES,allocator,loc)
}

test_info_places :: proc(t:^testing.T,$W,$S,$E:typeid,$TYPES:Test_Types,allocator:=context.allocator,loc:=#caller_location) -> (info:World_Info,ok:bool) {
    made,problem:=made_build({.World=type_info_of(W),.Shared=type_info_of(S),.Editor=type_info_of(E)},TYPES,{.World,.Shared,.Editor},true,allocator)
    if !testing.expect(t,made!=nil,problem,loc=loc) {return}
    info,ok=made_info(made,test_procs(W,S,E,TYPES),allocator)
    made_destroy(made)
    testing.expect(t,ok,"no memory for the World_Info of a test world",loc=loc)
    return
}

// Indexes a World_Info again after the test gave it names, records or name
// bits, which its schema holds.
test_info_index :: proc(info:^World_Info,allocator:=context.allocator) {
    world_schema_destroy(info.schema)
    delete(info.tables_by_type);delete(info.storages_by_type)
    info.schema,info.tables_by_type,info.storages_by_type=nil,nil,nil
    world_info_index(info,allocator)
}

test_info_destroy :: proc(info:^World_Info,allocator:=context.allocator) {
    world_schema_destroy(info.schema)
    delete(info.tables_by_type);delete(info.storages_by_type)
    for table in info.tables {delete(table.description,allocator)}
    delete(info.tables,allocator);delete(info.storages,allocator)
    info^={}
}

// Makes a world that holds its own World_Info, for a test that needs no
// application: test_world_destroy frees both. False, with the test failed,
// when its struct does not describe a world or without memory.
test_world_init :: proc{test_world_init_core,test_world_init_types}

test_world_init_core :: proc(t:^testing.T,w:^$W,allocator:=context.allocator,loc:=#caller_location) -> bool {
    return test_world_init_types(t,w,test_types_none,allocator,loc)
}

test_world_init_types :: proc(t:^testing.T,w:^$W,$TYPES:Test_Types,allocator:=context.allocator,loc:=#caller_location) -> bool {
    made,problem:=made_build({.World=type_info_of(W),.Shared=type_info_of(Test_None),.Editor=type_info_of(Test_None)},TYPES,{.World},true,allocator)
    if !testing.expect(t,made!=nil,problem,loc=loc) {return false}
    ok:bool
    made.info,ok=made_info(made,test_procs(W,Test_None,Test_None,TYPES),allocator)
    if !ok {
        made_destroy(made)
    } else if !made_world_init(made,w,allocator) {
        made_world_destroy(w)
        ok=false
    }
    return testing.expect(t,ok,"no memory for a test world",loc=loc)
}

test_world_destroy :: proc(w:^$W) {made_world_destroy(w)}

// The World_Info of a world test_world_init made.
test_world_info :: proc(w:^$W) -> ^World_Info {return &w.made_of.info}

test_world_ref :: proc(w:^$W) -> World_Ref {return {w,&w.made_of.info,.World}}

// The settle of a world test_world_init made: how many tables it came to.
test_world_settle :: proc(w:^$W) -> int {return settle(&w.made_of.info,w,nil)}

test_world_copy :: proc(dst,src:^$W) -> bool {return made_copy(dst,src)}

test_world_copy_changed :: proc(dst,src:^$W,marks:[]Copy_Mark) -> bool {return made_copy_changed(dst,src,marks)}

test_world_swap :: proc(a,b:^$W) {made_swap(a,b)}

test_world_clear :: proc(w:^$W) -> bool {return made_clear(w)}

// The options of the attributes of the declaration whose name is at a line
// and a column of a source: those before it on its line and those on the
// lines right above it, as the generator reads them from the parsed source.
test_declared_options :: proc(text:string,line,column:int,allocator:=context.temp_allocator) -> map[string]string {
    options:=make(map[string]string,allocator)
    at:=0
    for _ in 1..<line {
        next:=strings.index_byte(text[at:],'\n')
        if next<0 {return options}
        at+=next+1
    }
    attributes_text(&options,text[at:min(at+max(column-1,0),len(text))],allocator)
    for at>0 {
        end:=at-1
        start:=strings.last_index_byte(text[:end],'\n')+1
        above:=strings.trim_space(text[start:end])
        if !strings.has_prefix(above,"@(") {break}
        attributes_text(&options,above,allocator)
        at=start
    }
    return options
}

@(private="file")
attributes_text :: proc(options:^map[string]string,text:string,allocator:runtime.Allocator) {
    i:=0
    for {
        open:=strings.index(text[i:],"@(")
        if open<0 {return}
        i+=open+2
        for i<len(text) && text[i]!=')' {
            start:=i
            for i<len(text) && is_name(text[i]) {i+=1}
            name:=text[start:i]
            if name=="" {
                i+=1
                continue
            }
            for i<len(text) && text[i]==' ' {i+=1}
            value:=""
            if i<len(text) && text[i]=='=' {
                i+=1
                for i<len(text) && text[i]==' ' {i+=1}
                start=i
                if i<len(text) && (text[i]=='"' || text[i]=='`') {
                    quote:=text[i]
                    i+=1
                    for i<len(text) && text[i]!=quote {i+=text[i]=='\\' && quote=='"'?2:1}
                    i=min(i+1,len(text))
                    if name=="description" {value,_,_=strconv.unquote_string(text[start:i],allocator)} else {value=strings.trim(text[start:i],"\"`")}
                } else {
                    for i<len(text) && text[i]!=',' && text[i]!=')' {i+=1}
                    value=strings.trim_space(text[start:i])
                }
            }
            options[name]=value
        }
    }
}

@(private="file")
Test_Field_Kind :: enum u8 {Storage,Table,By_World}

@(private="file")
Test_Field :: struct {
    kind:Test_Field_Kind,
    place:Place,
    offset:uintptr,
    name,library,plugin:string,
    type:typeid,
    info:^runtime.Type_Info,   // of the component or the storage
    values:^runtime.Type_Info, // a table: of the dynamic array of its values
    file:string,               // where a type with attributes is declared; "" for a plain one
    declared:Declared,
    procs:Test_Type,
    base,game:bool,
    locks:[]Lock,
}

// What a test world is made of: its tables as its World_Info lists them,
// those of the World and then those of the editor, and after them its
// storages, those of the World, of the application and of the editor.
Test_Made :: struct {
    fields:[]Test_Field,
    tables:int,
    id:int,       // the table of Id of the World; -1 without one
    world_id:int, // the storage World_Id of the World; -1 without one
    lock_names:[]string,
    allocator:runtime.Allocator,
    info:World_Info, // of a world test_world_init made
}

@(private="file")
Test_Procs :: struct {
    sizes,aligns:[Place]int,
    init:[Place]proc(data:rawptr,allocator:runtime.Allocator) -> bool,
    destroy:[Place]proc(data:rawptr),
}

@(private="file")
test_procs :: proc($W,$S,$E:typeid,$TYPES:Test_Types) -> Test_Procs {
    return {
        sizes={.World=size_of(W),.Shared=size_of(S),.Editor=size_of(E)},
        aligns={.World=align_of(W),.Shared=align_of(S),.Editor=align_of(E)},
        init={
            .World=proc(data:rawptr,allocator:runtime.Allocator) -> bool {
                made,_:=made_build({.World=type_info_of(W),.Shared=type_info_of(S),.Editor=type_info_of(E)},TYPES,{.World},false,allocator)
                if made==nil {return false}
                return made_world_init(made,data,allocator)
            },
            .Shared=proc(data:rawptr,allocator:runtime.Allocator) -> bool {
                made,_:=made_build({.World=nil,.Shared=type_info_of(S),.Editor=nil},TYPES,{},false,allocator)
                if made==nil {return false}
                defer made_destroy(made)
                return made_place_init(made,.Shared,data,allocator)
            },
            .Editor=proc(data:rawptr,allocator:runtime.Allocator) -> bool {
                made,_:=made_build({.World=nil,.Shared=nil,.Editor=type_info_of(E)},TYPES,{.Editor},false,allocator)
                if made==nil {return false}
                defer made_destroy(made)
                return made_place_init(made,.Editor,data,allocator)
            },
        },
        destroy={
            .World=made_world_destroy,
            .Shared=proc(data:rawptr) {
                made,_:=made_build({.World=nil,.Shared=type_info_of(S),.Editor=nil},TYPES,{},false,context.allocator)
                if made==nil {return}
                made_place_destroy(made,.Shared,data)
                made_destroy(made)
            },
            .Editor=proc(data:rawptr) {
                made,_:=made_build({.World=nil,.Shared=nil,.Editor=type_info_of(E)},TYPES,{},false,context.allocator)
                if made==nil {return}
                made_place_destroy(made,.Editor,data)
                made_destroy(made)
            },
        },
    }
}

@(private="file")
Source :: struct {path,text:string}

// The fields of the structs of a test world. read: the places whose types
// are looked up in their sources; the others give only what reflection
// says. verify: also that every default the sources declare was given.
// nil with what is wrong, in the temp allocator.
@(private="file")
made_build :: proc(structs:[Place]^runtime.Type_Info,types:Test_Types,read:bit_set[Place],verify:bool,allocator:runtime.Allocator) -> (made:^Test_Made,problem:string) {
    given:=make([dynamic]Test_Type,context.temp_allocator)
    test_types_core(&given)
    types(&given)
    sources:=make([dynamic]Source,context.temp_allocator)
    defer for source in sources {delete(source.text,allocator)}
    tables:=make([dynamic]Test_Field,context.temp_allocator)
    storages:=make([dynamic]Test_Field,context.temp_allocator)
    for place in ([3]Place{.World,.Shared,.Editor}) {
        if structs[place]==nil {continue}
        layout,is_struct:=runtime.type_info_base(structs[place]).variant.(runtime.Type_Info_Struct)
        if !is_struct {return nil,fmt.tprintf("%v is not a struct: a test world is a struct of tables and storages",structs[place])}
        if place==.World && (layout.field_count==0 || layout.types[0].id!=Test_World || layout.offsets[0]!=0) {
            return nil,fmt.tprintf("%v does not start with `using world:core.Test_World`: its entities and the revisions of its storages go first",structs[place])
        }
        for i in 0..<int(layout.field_count) {
            if layout.names[i]=="_" || layout.types[i].id==Test_World {continue}
            f:=Test_Field{place=place,offset=layout.offsets[i],info=layout.types[i],name=layout.names[i]}
            _,f.game=field_option(reflect.Struct_Tag(layout.tags[i]),"game")
            if held,kind:=field_held(layout.types[i]);held!=nil {
                f.kind,f.info=kind,held
                if kind==.Table {f.values=runtime.type_info_base(layout.types[i]).variant.(runtime.Type_Info_Struct).types[0]}
            }
            if f.kind==.Table && place==.Shared || f.kind==.By_World && place!=.Shared {
                return nil,fmt.tprintf("%v.%s: a table goes in the World or in the editor, and a By_World in the struct of the application",structs[place],layout.names[i])
            }
            f.type=f.info.id
            named,is_named:=f.info.variant.(runtime.Type_Info_Named)
            if is_named {f.name,f.library=named.name,named.pkg}
            if name,renamed:=field_option(reflect.Struct_Tag(layout.tags[i]),"name");renamed {f.name=name}
            for type in given {
                if type.type==f.type {
                    f.procs=type
                    break
                }
            }
            if is_named && named.loc!=nil && place in read {
                if problem=field_declared(&f,named.loc^,&sources,allocator);problem!="" {return nil,problem}
            }
            if f.file!="" {
                if f.kind==.By_World && !f.declared.by_world || f.kind==.Storage && f.declared.by_world {
                    return nil,fmt.tprintf("%s is %sby_world: the struct of the application holds it as %s",f.name,f.declared.by_world?"":"not ",f.declared.by_world?fmt.tprintf("core.By_World(%s)",f.name):"a value")
                }
                if f.declared.host!=(place==.Shared) {
                    return nil,fmt.tprintf("%s is %s: it goes in the struct of %s",f.name,f.declared.host?"@(storage,host)":"not @(storage,host)",f.declared.host?"the application":"the World, or of the editor")
                }
                if problem=field_procs(&f);problem!="" {return nil,problem}
            }
            append(f.kind==.Table?&tables:&storages,f)
        }
    }
    if len(storages)>TEST_STORAGES {return nil,fmt.tprintf("a test world of %d storages: TEST_STORAGES holds the revisions of %d",len(storages),TEST_STORAGES)}
    if verify {
        folders:=make([dynamic]Folder,context.temp_allocator)
        for &f in tables {
            if problem=field_defaults(&f,&folders,&sources,allocator);problem!="" {return nil,problem}
        }
        for &f in storages {
            if problem=field_defaults(&f,&folders,&sources,allocator);problem!="" {return nil,problem}
        }
    }
    error:runtime.Allocator_Error
    made,error=new(Test_Made,allocator)
    if error!=nil {return nil,"no memory for a test world"}
    made.allocator,made.tables,made.id,made.world_id=allocator,len(tables),-1,-1
    made.fields,error=make([]Test_Field,len(tables)+len(storages),allocator)
    if error!=nil {
        made_destroy(made)
        return nil,"no memory for a test world"
    }
    copy(made.fields,tables[:])
    copy(made.fields[len(tables):],storages[:])
    for &f,index in made.fields {
        if f.place!=.World {continue}
        if f.kind==.Table && f.type==Id {made.id=index}
        if f.kind==.Storage && f.type==World_Id {made.world_id=index}
    }
    if !made_locks(made) {
        made_destroy(made)
        return nil,"no memory for a test world"
    }
    for &f in made.fields {
        description:=f.declared.description
        f.declared={single=f.declared.single,keep=f.declared.keep,persist=f.declared.persist,setting=f.declared.setting,shared=f.declared.shared,far=f.declared.far,replication=f.declared.replication,by_world=f.declared.by_world,host=f.declared.host,copy=f.declared.copy=="false"?"false":""}
        f.file=""
        if verify {f.declared.description=strings.clone(description,allocator)}
    }
    return made,""
}

// The type a Table or a By_World of core holds, and which of them it is; nil for another type.
@(private="file")
field_held :: proc(info:^runtime.Type_Info) -> (held:^runtime.Type_Info,kind:Test_Field_Kind) {
    named,is_named:=info.variant.(runtime.Type_Info_Named)
    if !is_named || named.pkg!="core" {return}
    layout,is_struct:=named.base.variant.(runtime.Type_Info_Struct)
    if !is_struct || layout.field_count==0 {return}
    first,is_dynamic:=layout.types[0].variant.(runtime.Type_Info_Dynamic_Array)
    if !is_dynamic {return}
    switch {
    case strings.has_prefix(named.name,"Table(") && info.size==size_of(Raw_Table) && layout.names[0]=="values":
        return first.elem,.Table
    case strings.has_prefix(named.name,"By_World(") && layout.names[0]=="entries":
        entry,is_entry:=runtime.type_info_base(first.elem).variant.(runtime.Type_Info_Struct)
        if !is_entry || entry.field_count!=2 {return}
        value,is_pointer:=entry.types[1].variant.(runtime.Type_Info_Pointer)
        if !is_pointer {return}
        return value.elem,.By_World
    }
    return
}

// What the source of a type says of it.
@(private="file")
field_declared :: proc(f:^Test_Field,loc:runtime.Source_Code_Location,sources:^[dynamic]Source,allocator:runtime.Allocator) -> (problem:string) {
    text,found:=source_text(sources,loc.file_path,allocator)
    if !found {return fmt.tprintf("%s: the source that declares %s could not be read; a test world reads the attributes of its types from their sources",loc.file_path,f.name)}
    options:=test_declared_options(text,int(loc.line),int(loc.column))
    _,component:=options["component"]
    _,storage:=options["storage"]
    if !component && !storage {
        if strings.has_suffix(loc.file_path,"_test.odin") {return}
        return fmt.tprintf("%s.%s is not a @(component) or a @(storage): a test world holds what a generated one would",f.library,f.name)
    }
    if component!=(f.kind==.Table) {
        return fmt.tprintf("%s.%s is a %s: a test world holds it as %s",f.library,f.name,component?"@(component)":"@(storage)",component?fmt.tprintf("core.Table(%s)",f.name):"a value")
    }
    invalid:string
    f.declared,invalid=declared_read(options,f.place==.Editor)
    if invalid!="" {return fmt.tprintf("%s.%s has %s=%q, which the generator refuses",f.library,f.name,invalid,options[invalid])}
    f.file=loc.file_path
    folder:=path_folder(loc.file_path)
    f.base=component && path_folder(#file)==folder && !strings.has_suffix(loc.file_path,"_test.odin")
    f.plugin=path_plugin(folder)
    return
}

// Each procedure the attributes name was given, and no other.
@(private="file")
field_procs :: proc(f:^Test_Field) -> (problem:string) {
    Named :: struct {option,name:string,given:bool}
    custom:=f.declared.copy!="" && f.declared.copy!="false"
    for n in ([5]Named{{"copy",custom?f.declared.copy:"",f.procs.copy!=nil},{"copy_kept",f.declared.copy_kept,f.procs.copy_kept!=nil},{"swap",f.declared.swap,f.procs.swap!=nil},{"free",f.declared.free,f.procs.free!=nil},{"reset",f.declared.reset,f.procs.reset!=nil}}) {
        if (n.name!="")==n.given {continue}
        if n.given {return fmt.tprintf("%s.%s was given a %s its declaration does not name: take it out of the test_types of its package",f.library,f.name,n.option)}
        return fmt.tprintf("%s.%s says %s=%q: add core.test_type(%s,%s=%s) to the test_types of its package and give them to the world",f.library,f.name,n.option,n.name,f.name,n.option,n.name)
    }
    return
}

// The defaults the package of a type declares for it were given, and no other.
@(private="file")
field_defaults :: proc(f:^Test_Field,folders:^[dynamic]Folder,sources:^[dynamic]Source,allocator:runtime.Allocator) -> (problem:string) {
    if f.file=="" {return}
    buffer:[512]u8
    constant,maker,for_device:=default_names(f.name,buffer[:])
    names,found:=folder_defaults(folders,path_folder(f.file),sources,allocator)
    if !found {return fmt.tprintf("%s: the package of %s could not be read",path_folder(f.file),f.name)}
    declares_default:=slice.contains(names,constant) || slice.contains(names,maker)
    declares_for_device:=slice.contains(names,for_device)
    if declares_default!=(f.procs.default!=nil) {
        if declares_default {return fmt.tprintf("%s.%s starts as %s or %s(): add core.test_type(%s,default=...) with it to the test_types of its package and give them to the world",f.library,f.name,constant,maker,f.name)}
        return fmt.tprintf("%s.%s was given a default its package does not declare: take it out of the test_types of its package",f.library,f.name)
    }
    if declares_for_device!=(f.procs.for_device!=nil) {
        if declares_for_device {return fmt.tprintf("%s.%s has %s: add it as the for_device of its core.test_type",f.library,f.name,for_device)}
        return fmt.tprintf("%s.%s was given a for_device its package does not declare",f.library,f.name)
    }
    return
}

@(private="file")
Folder :: struct {
    path:string,
    names:[]string, // what its sources declare that is named as a default
}

// The names the sources of a package declare, without its tests, that end
// as a default does.
@(private="file")
folder_defaults :: proc(folders:^[dynamic]Folder,path:string,sources:^[dynamic]Source,allocator:runtime.Allocator) -> (names:[]string,found:bool) {
    for folder in folders {
        if folder.path==path {return folder.names,true}
    }
    entries,error:=os.read_all_directory_by_path(path,context.temp_allocator)
    if error!=nil {return}
    declared:=make([dynamic]string,context.temp_allocator)
    for entry in entries {
        if entry.type==.Directory || !strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,"_test.odin") {continue}
        text:=source_text(sources,fmt.tprintf("%s/%s",path,entry.name),allocator) or_continue
        for at:=0;at<len(text); {
            end:=at
            for end<len(text) && is_name(text[end]) {end+=1}
            name:=text[at:end]
            if strings.has_suffix(name,"_DEFAULT") || strings.has_suffix(name,"_default") || strings.has_suffix(name,"_for_device") {
                if strings.has_prefix(strings.trim_left_space(text[end:min(end+8,len(text))]),":") {append(&declared,name)}
            }
            next:=strings.index_byte(text[end:],'\n')
            if next<0 {break}
            at=end+next+1
        }
    }
    append(folders,Folder{path,declared[:]})
    return declared[:],true
}

@(private="file")
is_name :: proc "contextless" (c:u8) -> bool {return c=='_' || c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9'}

@(private="file")
source_text :: proc(sources:^[dynamic]Source,path:string,allocator:runtime.Allocator) -> (text:string,found:bool) {
    for source in sources {
        if source.path==path {return source.text,true}
    }
    data,error:=os.read_entire_file(path,allocator)
    if error!=nil {return "",false}
    append(sources,Source{strings.clone(path,context.temp_allocator),string(data)})
    return string(data),true
}

@(private="file")
path_folder :: proc(path:string) -> string {
    return path[:max(strings.last_index_any(path,"/\\"),0)]
}

// The plugin a folder is a part of; "" for one of the engine.
@(private="file")
path_plugin :: proc(folder:string) -> string {
    rest:=folder
    for {
        cut:=strings.last_index_any(rest,"/\\")
        if cut<0 {return ""}
        part:=rest[cut+1:]
        rest=rest[:cut]
        if part!="runtime" && part!="editor" {continue}
        name:=rest[strings.last_index_any(rest,"/\\")+1:]
        above:=rest[:max(len(rest)-len(name)-1,0)]
        if above[strings.last_index_any(above,"/\\")+1:]=="plugins" {return name}
    }
}

// The rows of other tables a row of each table of the World owns, as its
// declaration says with locks.
@(private="file")
made_locks :: proc(made:^Test_Made) -> bool {
    holders:=0
    for &f in made.fields[:made.tables] {
        if f.declared.lock_names!="" && f.place==.World {holders+=1}
    }
    if holders==0 {return true}
    error:runtime.Allocator_Error
    made.lock_names,error=make([]string,holders+1,made.allocator)
    if error!=nil {return false}
    id:=0
    for &f in made.fields[:made.tables] {
        if f.declared.lock_names=="" || f.place!=.World {continue}
        id+=1
        made.lock_names[id]=fmt.aprintf("%s.%s",f.library,f.name,allocator=made.allocator)
        found:=make([dynamic]Lock,context.temp_allocator)
        for target in strings.fields(f.declared.lock_names,context.temp_allocator) {
            library,_,name:=strings.partition(target,".")
            if name=="" {library,name=f.library,library}
            for &other in made.fields[:made.tables] {
                if other.place!=.World || other.name!=name || other.library!=library {continue}
                append(&found,Lock{int(other.offset)-int(f.offset),u16(id),made.lock_names,other.name})
            }
        }
        f.locks,error=slice.clone(found[:],made.allocator)
        if error!=nil {return false}
    }
    return true
}

@(private="file")
made_destroy :: proc(made:^Test_Made) {
    if made==nil {return}
    allocator:=made.allocator
    if made.info.init[.World]!=nil {test_info_destroy(&made.info,allocator)}
    for f in made.fields {
        delete(f.locks,allocator)
        delete(f.declared.description,allocator)
    }
    for name in made.lock_names {delete(name,allocator)}
    delete(made.lock_names,allocator);delete(made.fields,allocator)
    _=runtime.mem_free(made,allocator)
}

@(private="file")
made_info :: proc(made:^Test_Made,procs:Test_Procs,allocator:runtime.Allocator) -> (info:World_Info,ok:bool) {
    tables,tables_error:=make([]Table_Info,made.tables,allocator)
    storages,storages_error:=make([]Storage_Info,len(made.fields)-made.tables,allocator)
    if tables_error!=nil || storages_error!=nil {
        delete(tables,allocator);delete(storages,allocator)
        return
    }
    for &f,index in made.fields {
        d:=f.declared
        if index<made.tables {
            tables[index]={name=f.name,library=f.library,type=f.type,info=f.info,offset=f.offset,place=f.place,shared=d.shared,replicated=d.replication,game=f.game,default=f.procs.default,description=strings.clone(d.description,allocator),single=d.single,far=d.far}
        } else {
            storages[index-made.tables]={name=f.name,library=f.library,type=f.type,info=f.info,offset=f.offset,place=f.place,setting=d.setting,default=f.procs.default,by_world=f.kind==.By_World,for_device=f.procs.for_device,persist=d.persist,keep=d.keep,plugin=f.plugin,game=f.game}
        }
    }
    info.sizes,info.aligns=procs.sizes,procs.aligns
    info.entities,info.revisions=offset_of(Test_World,entities),offset_of(Test_World,storage_revisions)
    info.tables,info.storages=tables,storages
    info.init,info.destroy=procs.init,procs.destroy
    info.copy,info.copy_changed,info.swap,info.clear=made_copy,made_copy_changed,made_swap,made_clear
    info.attach,info.detach=made_attach,made_detach
    world_info_index(&info,allocator)
    return info,true
}

@(private="file")
field_at :: #force_inline proc "contextless" (data:rawptr,f:^Test_Field) -> rawptr {return rawptr(uintptr(data)+f.offset)}

@(private="file")
field_free :: proc(f:^Test_Field,value:rawptr) {
    if f.procs.free!=nil {f.procs.free(value)} else {value_free(value,f.info)}
}

// The world keeps made, also when it fails: its destroy frees it.
@(private="file")
made_world_init :: proc(made:^Test_Made,data:rawptr,allocator:runtime.Allocator) -> bool {
    w:=cast(^Test_World)data
    w.made_of=made
    context.allocator=allocator
    if !entities_init(&w.entities,allocator) || !entities_tables(&w.entities,made.tables) {return false}
    return made_place_init(made,.World,data,allocator)
}

@(private="file")
made_place_init :: proc(made:^Test_Made,place:Place,data:rawptr,allocator:runtime.Allocator) -> bool {
    context.allocator=allocator
    for &f,index in made.fields {
        if f.place!=place {continue}
        switch f.kind {
        case .Table:
            table:=cast(^Raw_Table)field_at(data,&f)
            if !raw_init(table,f.name,allocator) {return false}
            if place==.World {raw_follow(table,&(cast(^Test_World)data).entities,index)}
            table.base,table.single,table.locks=f.base,f.declared.single,f.locks
        case .Storage:
            if f.procs.default!=nil {f.procs.default(field_at(data,&f))}
        case .By_World:
        }
    }
    return true
}

@(private="file")
made_place_destroy :: proc(made:^Test_Made,place:Place,data:rawptr) {
    for &f in made.fields {
        if f.place!=place {continue}
        switch f.kind {
        case .Table:
            raw_destroy(cast(^Raw_Table)field_at(data,&f),f.info.size)
        case .Storage:
            field_free(&f,field_at(data,&f))
        case .By_World:
            held:=cast(^By_World(u8))field_at(data,&f)
            for entry in held.entries {
                if entry.value==nil {continue}
                field_free(&f,entry.value)
                by_world_release(held,entry.value)
            }
            delete(held.entries)
        }
    }
}

@(private="file")
made_world_destroy :: proc(data:rawptr) {
    w:=cast(^Test_World)data
    if w.made_of==nil {return}
    made_place_destroy(w.made_of,.World,data)
    entities_destroy(&w.entities)
    made_destroy(w.made_of)
    w.made_of=nil
}

@(private="file")
made_ids :: proc "contextless" (made:^Test_Made,data:rawptr) -> Read(Id) {
    return {cast(^Table(Id))field_at(data,&made.fields[made.id])}
}

@(private="file")
made_copy :: proc(dst_data,src_data:rawptr) -> bool {return made_copy_marked(dst_data,src_data,nil)}

@(private="file")
made_copy_changed :: proc(dst_data,src_data:rawptr,marks:[]Copy_Mark) -> bool {
    made:=(cast(^Test_World)src_data).made_of
    return made_copy_marked(dst_data,src_data,len(marks)<len(made.fields)?nil:marks)
}

// marks: of the copy of what changed; nil copies it whole.
@(private="file")
made_copy_marked :: proc(dst_data,src_data:rawptr,marks:[]Copy_Mark) -> bool {
    if dst_data==src_data {return true}
    dst,src:=cast(^Test_World)dst_data,cast(^Test_World)src_data
    made:=src.made_of
    changed:=marks!=nil
    context.allocator=dst.entities.generation.allocator
    synced:=made.id>=0 && ids_synced(&src.entities,made_ids(made,src_data))
    if !entities_copy(&dst.entities,&src.entities) {return false}
    for &f,index in made.fields {
        if f.place!=.World {continue}
        to,from:=field_at(dst_data,&f),field_at(src_data,&f)
        if f.kind==.Table {
            if changed {
                if !raw_copy_changed(cast(^Raw_Table)to,cast(^Raw_Table)from,f.info,f.values,f.info.size,&marks[index]) {return false}
            } else if !raw_copy(cast(^Raw_Table)to,cast(^Raw_Table)from,f.values) {return false}
            continue
        }
        if f.declared.copy=="false" {continue}
        k:=index-made.tables
        if changed && !storage_changed(&marks[index],src.storage_revisions[k]) {
            when CHECK_WRITES {if f.procs.copy==nil && f.procs.copy_kept==nil {storage_check(to,from,f.info,f.name)}}
            continue
        }
        copy:=changed && f.procs.copy_kept!=nil?f.procs.copy_kept:f.procs.copy
        if copy!=nil {
            if !copy(to,from) {return false}
        } else if !value_copy(to,from,f.info) {return false}
        if changed {storage_copied(&marks[index],&dst.storage_revisions[k],src.storage_revisions[k])}
    }
    count:=len(made.fields)-made.tables
    if !changed {revisions_copied(dst.storage_revisions[:count],src.storage_revisions[:count])}
    if made.id>=0 {ids_moved(&dst.entities,made_ids(made,dst_data),synced)}
    return true
}

@(private="file")
made_swap :: proc(a_data,b_data:rawptr) {
    if a_data==b_data {return}
    a,b:=cast(^Test_World)a_data,cast(^Test_World)b_data
    made:=a.made_of
    a_synced:=made.id>=0 && ids_synced(&a.entities,made_ids(made,a_data))
    b_synced:=made.id>=0 && ids_synced(&b.entities,made_ids(made,b_data))
    slice.ptr_swap_non_overlapping(&a.entities,&b.entities,size_of(Entities))
    for &f in made.fields {
        if f.place!=.World {continue}
        x,y:=field_at(a_data,&f),field_at(b_data,&f)
        switch {
        case f.kind==.Table:         raw_swap(cast(^Raw_Table)x,cast(^Raw_Table)y)
        case f.declared.copy=="false":
        case f.procs.swap!=nil:      f.procs.swap(x,y)
        case:                        slice.ptr_swap_non_overlapping(x,y,f.info.size)
        }
    }
    count:=len(made.fields)-made.tables
    revisions_swapped(a.storage_revisions[:count],b.storage_revisions[:count])
    if made.id>=0 {
        ids_moved(&a.entities,made_ids(made,a_data),b_synced)
        ids_moved(&b.entities,made_ids(made,b_data),a_synced)
    }
}

@(private="file")
made_clear :: proc(data:rawptr) -> bool {
    w:=cast(^Test_World)data
    made:=w.made_of
    if !entities_clear(&w.entities) {return false}
    for &f in made.fields[:made.tables] {
        if f.place==.World {raw_clear(cast(^Raw_Table)field_at(data,&f))}
    }
    for &f in made.fields[made.tables:] {
        d:=f.declared
        if f.place!=.World || d.keep || d.setting!=.None || d.copy=="false" {continue}
        value:=field_at(data,&f)
        if f.procs.reset!=nil {
            f.procs.reset(value)
            continue
        }
        field_free(&f,value)
        mem.zero(value,f.info.size)
        if f.procs.default!=nil {f.procs.default(value)}
    }
    revisions_moved(w.storage_revisions[:len(made.fields)-made.tables])
    return true
}

@(private="file")
made_attach :: proc(world,shared:rawptr,allocator:runtime.Allocator) -> bool {
    made:=(cast(^Test_World)world).made_of
    if made.world_id<0 {return true}
    id:=(cast(^World_Id)field_at(world,&made.fields[made.world_id]))^
    if id.generation==0 {return true}
    context.allocator=allocator
    for &f in made.fields[made.tables:] {
        if f.kind!=.By_World {continue}
        value:=by_world_room(cast(^By_World(u8))field_at(shared,&f),id,f.info.size,f.info.align,allocator)
        if value==nil {return false}
        mem.zero(value,f.info.size)
        if f.procs.default!=nil {f.procs.default(value)}
    }
    return true
}

@(private="file")
made_detach :: proc(world,shared:rawptr) {
    made:=(cast(^Test_World)world).made_of
    if made.world_id<0 {return}
    id:=(cast(^World_Id)field_at(world,&made.fields[made.world_id]))^
    for &f in made.fields[made.tables:] {
        if f.kind!=.By_World {continue}
        held:=cast(^By_World(u8))field_at(shared,&f)
        if value:=by_world_detach(held,id);value!=nil {
            field_free(&f,value)
            by_world_release(held,value)
        }
    }
}

@(private="file") @(storage,reset="described_reset") Described_Reset :: struct {value:i32}

@(private="file")
Described_World :: struct {
    using world:Test_World,
    transforms:Table(Transform),
    paces:Table(Own_Pace),
    disabled:Table(Disabled),
    hierarchy:Hierarchy,
    time:Time,
    frame:Frame_Time,
    clock:Clock,
}

@(private="file")
Described_Shared :: struct {
    settings:Simulation_Settings,
    problems:By_World(Problems),
}

// A test world says of each table and storage what the attributes of its
// type say, starts and copies them as a generated one does, and one that a
// generated World could not be is refused saying which type is wrong.
@(test)
a_test_world_is_described_as_the_declarations_of_its_types_say :: proc(t:^testing.T) {
    info,ok:=test_info(t,Described_World,Described_Shared,Test_None)
    if !ok {return}
    defer test_info_destroy(&info)
    transforms,paces:=info.tables[0],info.tables[1]
    testing.expect(t,transforms.name=="Transform" && transforms.library=="core" && transforms.shared && transforms.replicated==.None && transforms.default!=nil && transforms.description!="")
    testing.expect(t,paces.replicated==.All && !paces.shared)
    time,settings,problems:=info.storages[1],info.storages[4],info.storages[5]
    testing.expect(t,time.keep && time.place==.World && time.setting==.None)
    testing.expect(t,settings.place==.Shared && settings.setting==.Project && settings.default!=nil)
    testing.expect(t,problems.by_world && problems.place==.Shared)

    a,b:Described_World
    testing.expect(t,info.init[.World](&a,context.allocator) && info.init[.World](&b,context.allocator))
    defer info.destroy[.World](&a)
    defer info.destroy[.World](&b)
    testing.expect(t,a.transforms.base && a.disabled.base && a.paces.base,"the components of core are the base of every entity")
    testing.expect(t,a.clock.scale==1 && a.frame.alpha==1,"a storage starts as its default")
    a.time.tick,a.frame.alpha,a.clock.scale=7,0.5,2
    testing.expect(t,info.copy(&b,&a))
    testing.expect(t,b.time.tick==7 && b.clock.scale==2 && b.frame.alpha==1,"what says copy=false stays")
    testing.expect(t,info.clear(&a))
    testing.expect(t,a.time.tick==7 && a.clock.scale==2,"what says keep survives clearing the World")

    Case :: struct {what:string,world:^runtime.Type_Info,shared:^runtime.Type_Info,names:string}
    cases:=[]Case{
        {"no header",type_info_of(struct {transforms:Table(Transform)}),nil,"Test_World"},
        {"a storage held as a table",type_info_of(struct {using world:Test_World,hierarchy:Table(Hierarchy)}),nil,"Hierarchy"},
        {"a component held as a value",type_info_of(struct {using world:Test_World,transform:Transform}),nil,"Transform"},
        {"a storage of the application in the World",type_info_of(struct {using world:Test_World,settings:Simulation_Settings}),nil,"Simulation_Settings"},
        {"a by_world storage held as a value",type_info_of(struct {using world:Test_World}),type_info_of(struct {problems:Problems}),"Problems"},
        {"a type that is no component or storage",type_info_of(struct {using world:Test_World,seen:Seen}),nil,"Seen"},
        {"a procedure its attributes name was not given",type_info_of(struct {using world:Test_World,reset:Described_Reset}),nil,"described_reset"},
    }
    for c in cases {
        made,problem:=made_build({.World=c.world,.Shared=c.shared,.Editor=nil},test_types_none,{.World,.Shared},true,context.allocator)
        testing.expectf(t,made==nil && strings.contains(problem,c.names),"%s: %q",c.what,problem)
        made_destroy(made)
    }
}
