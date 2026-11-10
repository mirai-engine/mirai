package core

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "mirai:std/serial"

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
    made_of:^Test_Own, // of a world test_world_init made
}

// The World_Info a world test_world_init made holds.
Test_Own :: struct {
    info:World_Info,
    allocator:runtime.Allocator,
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
// of other packages, or with what its application and its editor hold. It
// says of its tables and storages what a generated one says, so world_init,
// world_copy and the others treat its worlds alike; the test adds what it
// needs of the rest (steps, messages, names, records). test_info_destroy
// frees it.
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
    made,problem:=made_build({.World=type_info_of(W),.Shared=type_info_of(S),.Editor=type_info_of(E)},TYPES,allocator)
    if !testing.expect(t,made!=nil,problem,loc=loc) {return}
    info,ok=made_info(made,{.World=size_of(W),.Shared=size_of(S),.Editor=size_of(E)},{.World=align_of(W),.Shared=align_of(S),.Editor=align_of(E)},allocator)
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
    lock_names:[]string
    for table in info.tables {
        delete(table.description,allocator)
        if len(table.locks)>0 {lock_names=table.locks[0].names}
        delete(table.locks,allocator)
    }
    for name in lock_names {delete(name,allocator)}
    delete(lock_names,allocator)
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
    made,problem:=made_build({.World=type_info_of(W),.Shared=type_info_of(Test_None),.Editor=type_info_of(Test_None)},TYPES,allocator)
    if !testing.expect(t,made!=nil,problem,loc=loc) {return false}
    own,error:=new(Test_Own,allocator)
    ok:=error==nil
    if ok {
        own.allocator=allocator
        own.info,ok=made_info(made,{.World=size_of(W),.Shared=size_of(Test_None),.Editor=size_of(Test_None)},{.World=align_of(W),.Shared=align_of(Test_None),.Editor=align_of(Test_None)},allocator)
    }
    made_destroy(made)
    if ok {
        w.made_of=own
        if !world_init(&own.info,.World,w,allocator) {
            test_world_destroy(w)
            ok=false
        }
    } else if own!=nil {_=runtime.mem_free(own,allocator)}
    return testing.expect(t,ok,"no memory for a test world",loc=loc)
}

test_world_destroy :: proc(w:^$W) {
    own:=w.made_of
    if own==nil {return}
    world_destroy(&own.info,.World,w)
    allocator:=own.allocator
    test_info_destroy(&own.info,allocator)
    _=runtime.mem_free(own,allocator)
    w.made_of=nil
}

// The World_Info of a world test_world_init made.
test_world_info :: proc(w:^$W) -> ^World_Info {return &w.made_of.info}

test_world_ref :: proc(w:^$W) -> World_Ref {return {w,&w.made_of.info,.World}}

// The settle of a world test_world_init made: how many tables it came to.
test_world_settle :: proc(w:^$W) -> int {return settle(&w.made_of.info,w,nil)}

test_world_copy :: proc(dst,src:^$W) -> bool {return world_copy(&src.made_of.info,dst,src)}

test_world_copy_changed :: proc(dst,src:^$W,marks:[]Copy_Mark) -> bool {return world_copy_changed(&src.made_of.info,dst,src,marks)}

test_world_swap :: proc(a,b:^$W) {world_swap(&a.made_of.info,a,b)}

test_world_clear :: proc(w:^$W) -> bool {return world_clear(&w.made_of.info,w)}

// The options of the attributes of the declaration whose name is at a line
// and a column of a source: those before it on its line and those on the
// lines right above it that hold attributes alone, as the generator reads
// them from the parsed source. A line above that goes on after its
// attributes is another declaration, which keeps them.
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
        read:=make(map[string]string,allocator)
        rest:=attributes_text(&read,above,allocator)
        if rest!="" && !strings.has_prefix(rest,"//") {break}
        for name,value in read {options[name]=value}
        at=start
    }
    return options
}

// Reads the attributes a text starts with, one after another; rest is what
// follows them.
@(private="file")
attributes_text :: proc(options:^map[string]string,text:string,allocator:runtime.Allocator) -> (rest:string) {
    i:=0
    for {
        for i<len(text) && (text[i]==' ' || text[i]=='\t') {i+=1}
        if !strings.has_prefix(text[i:],"@(") {return text[i:]}
        i+=2
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
        i=min(i+1,len(text))
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
    file:string,               // where a type with attributes is declared; "" for a plain one
    declared:Declared,
    procs:Test_Type,
    base,game:bool,
    locks:[]Lock,
}

// What a test world is made of: its tables as its World_Info lists them,
// those of the World and then those of the editor, and after them its
// storages, those of the World, of the application and of the editor.
@(private="file")
Test_Made :: struct {
    fields:[]Test_Field,
    tables:int,
    lock_names:[]string,
    allocator:runtime.Allocator,
}

@(private="file")
Source :: struct {path,text:string}

// The fields of the structs of a test world, each with what the source of
// its type says of it. nil with what is wrong, in the temp allocator.
@(private="file")
made_build :: proc(structs:[Place]^runtime.Type_Info,types:Test_Types,allocator:runtime.Allocator) -> (made:^Test_Made,problem:string) {
    b:Build
    b.allocator=allocator
    b.given=make([dynamic]Test_Type,context.temp_allocator)
    test_types_core(&b.given)
    types(&b.given)
    b.sources=make([dynamic]Source,context.temp_allocator)
    defer for source in b.sources {delete(source.text,allocator)}
    b.tables=make([dynamic]Test_Field,context.temp_allocator)
    b.storages=make([dynamic]Test_Field,context.temp_allocator)
    for place in ([3]Place{.World,.Shared,.Editor}) {
        if structs[place]==nil {continue}
        layout,is_struct:=runtime.type_info_base(structs[place]).variant.(runtime.Type_Info_Struct)
        if !is_struct {return nil,fmt.tprintf("%v is not a struct: a test world is a struct of tables and storages",structs[place])}
        if place==.World && (layout.field_count==0 || layout.types[0].id!=Test_World || layout.offsets[0]!=0) {
            return nil,fmt.tprintf("%v does not start with `using world:core.Test_World`: its entities and the revisions of its storages go first",structs[place])
        }
        if problem=build_fields(&b,place,layout,0);problem!="" {return nil,problem}
    }
    tables,storages:=b.tables,b.storages
    for list in ([2][]Test_Field{tables[:],storages[:]}) {
        for &f,i in list {
            for &other in list[:i] {
                if other.type==f.type && other.place==f.place && other.name==f.name {return nil,fmt.tprintf("%s.%s is held twice: a World has one table of a component and one value of a storage",f.library,f.name)}
            }
        }
    }
    if len(storages)>TEST_STORAGES {return nil,fmt.tprintf("a test world of %d storages: TEST_STORAGES holds the revisions of %d",len(storages),TEST_STORAGES)}
    folders:=make([dynamic]Folder,context.temp_allocator)
    for &f in tables {
        if problem=field_defaults(&f,&folders,&b.sources,allocator);problem!="" {return nil,problem}
    }
    for &f in storages {
        if problem=field_defaults(&f,&folders,&b.sources,allocator);problem!="" {return nil,problem}
    }
    error:runtime.Allocator_Error
    made,error=new(Test_Made,allocator)
    if error!=nil {return nil,"no memory for a test world"}
    made.allocator,made.tables=allocator,len(tables)
    made.fields,error=make([]Test_Field,len(tables)+len(storages),allocator)
    if error!=nil {
        made_destroy(made)
        return nil,"no memory for a test world"
    }
    copy(made.fields,tables[:])
    copy(made.fields[len(tables):],storages[:])
    if !made_locks(made) {
        made_destroy(made)
        return nil,"no memory for a test world"
    }
    for &f in made.fields {
        description:=f.declared.description
        f.declared={single=f.declared.single,keep=f.declared.keep,persist=f.declared.persist,setting=f.declared.setting,shared=f.declared.shared,far=f.declared.far,replication=f.declared.replication,by_world=f.declared.by_world,host=f.declared.host,copy=f.declared.copy=="false"?"false":""}
        f.file=""
        f.declared.description=strings.clone(description,allocator)
    }
    return made,""
}

@(private="file")
Build :: struct {
    given:[dynamic]Test_Type,
    sources:[dynamic]Source,
    tables,storages:[dynamic]Test_Field,
    allocator:runtime.Allocator,
}

// The fields of a struct of a place, base bytes into it. A field with using
// that is a struct is a group: the tables and storages a library gives its
// test worlds together.
@(private="file")
build_fields :: proc(b:^Build,place:Place,layout:runtime.Type_Info_Struct,base:uintptr) -> (problem:string) {
    for i in 0..<int(layout.field_count) {
        if layout.names[i]=="_" || layout.types[i].id==Test_World {continue}
        held,kind:=field_held(layout.types[i])
        if group,is_group:=runtime.type_info_base(layout.types[i]).variant.(runtime.Type_Info_Struct);is_group && layout.usings[i] && held==nil {
            if problem=build_fields(b,place,group,base+layout.offsets[i]);problem!="" {return}
            continue
        }
        f:=Test_Field{place=place,offset=base+layout.offsets[i],info=layout.types[i],name=layout.names[i]}
        tagged,invalid:=serial.field_tag(layout.tags[i])
        if invalid!="" {return fmt.tprintf("%s: %s",layout.names[i],invalid)}
        f.game=.Game in tagged.hints
        if held!=nil {f.kind,f.info=kind,held}
        if f.kind==.Table && place==.Shared || f.kind==.By_World && place!=.Shared {
            return fmt.tprintf("%s: a table goes in the World or in the editor, and a By_World in the struct of the application",layout.names[i])
        }
        f.type=f.info.id
        named,is_named:=f.info.variant.(runtime.Type_Info_Named)
        if is_named {f.name,f.library=named.name,named.pkg}
        if tagged.name!="" {f.name=tagged.name}
        for type in b.given {
            if type.type==f.type {
                f.procs=type
                break
            }
        }
        if is_named && named.loc!=nil {
            if problem=field_declared(&f,named.loc^,&b.sources,b.allocator);problem!="" {return}
        }
        if f.file!="" {
            if f.kind==.By_World && !f.declared.by_world || f.kind==.Storage && f.declared.by_world {
                return fmt.tprintf("%s is %sby_world: the struct of the application holds it as %s",f.name,f.declared.by_world?"":"not ",f.declared.by_world?fmt.tprintf("core.By_World(%s)",f.name):"a value")
            }
            if f.declared.host!=(place==.Shared) {
                return fmt.tprintf("%s is %s: it goes in the struct of %s",f.name,f.declared.host?"@(storage,host)":"not @(storage,host)",f.declared.host?"the application":"the World, or of the editor")
            }
            if problem=field_procs(&f);problem!="" {return}
        }
        append(f.kind==.Table?&b.tables:&b.storages,f)
    }
    return ""
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
    if invalid:=declared_read(&f.declared,options,f.place==.Editor);invalid!="" {return fmt.tprintf("%s.%s has %s=%q, which the generator refuses",f.library,f.name,invalid,options[invalid])}
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
    if f.file=="" || strings.has_suffix(f.file,"_test.odin") {return} // a test file declares no default: its type takes the one it is given
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
    for f in made.fields {
        delete(f.locks,allocator)
        delete(f.declared.description,allocator)
    }
    for name in made.lock_names {delete(name,allocator)}
    delete(made.lock_names,allocator);delete(made.fields,allocator)
    _=runtime.mem_free(made,allocator)
}

// The World_Info of what was made, which takes its locks from it.
@(private="file")
made_info :: proc(made:^Test_Made,sizes,aligns:[Place]int,allocator:runtime.Allocator) -> (info:World_Info,ok:bool) {
    tables,tables_error:=make([]Table_Info,made.tables,allocator)
    storages,storages_error:=make([]Storage_Info,len(made.fields)-made.tables,allocator)
    if tables_error!=nil || storages_error!=nil {
        delete(tables,allocator);delete(storages,allocator)
        return
    }
    locked:=false
    for &f,index in made.fields {
        d:=f.declared
        if index<made.tables {
            tables[index]={name=f.name,library=f.library,type=f.type,info=f.info,offset=f.offset,place=f.place,shared=d.shared,replicated=d.replication,game=f.game,default=f.procs.default,description=strings.clone(d.description,allocator),single=d.single,far=d.far,base=f.base,locks=f.locks}
            locked||=len(f.locks)>0
            f.locks=nil
        } else {
            storages[index-made.tables]={name=f.name,library=f.library,type=f.type,info=f.info,offset=f.offset,place=f.place,setting=d.setting,default=f.procs.default,by_world=f.kind==.By_World,for_device=f.procs.for_device,persist=d.persist,keep=d.keep,plugin=f.plugin,game=f.game,local=d.copy=="false",procs={f.procs.copy,f.procs.copy_kept,f.procs.swap,f.procs.free,f.procs.reset}}
        }
    }
    if locked {made.lock_names=nil}
    info.sizes,info.aligns=sizes,aligns
    info.entities,info.revisions=offset_of(Test_World,entities),offset_of(Test_World,storage_revisions)
    info.tables,info.storages=tables,storages
    world_info_index(&info,allocator)
    return info,true
}

@(private="file") @(storage,reset="described_reset") Described_Reset :: struct {value:i32}

// Declarations on one line right above others: each keeps its attributes.
@(private="file") @(storage,keep) Described_Kept :: struct {value:i32}
Described_Plain :: struct {value:i32}
@(private="file") @(component,replicated) Described_Sent :: struct {value:i32}
@(private="file")
@(component,single)
Described_Single :: struct {value:i32}

@(private="file")
Described_Lines :: struct {
    using world:Test_World,
    sent:Table(Described_Sent),
    single:Table(Described_Single),
    kept:Described_Kept,
    plain:Described_Plain,
}

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
    plain:Described_Plain,
    reset:Described_Reset,
}

@(private="file")
described_types :: proc(types:^[dynamic]Test_Type) {
    append(types,
        test_type(Described_Plain,default=proc(dst:^Described_Plain) {dst.value=3}),
        test_type(Described_Reset,reset=proc(value:^Described_Reset) {value.value=-1}),
    )
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
    info,ok:=test_info(t,Described_World,Described_Shared,Test_None,described_types)
    if !ok {return}
    defer test_info_destroy(&info)
    transforms,paces:=info.tables[0],info.tables[1]
    testing.expect(t,transforms.name=="Transform" && transforms.library=="core" && transforms.shared && transforms.replicated==.None && transforms.default!=nil && transforms.description!="")
    testing.expect(t,paces.replicated==.All && !paces.shared)
    time,settings,problems:=info.storages[1],info.storages[6],info.storages[7]
    testing.expect(t,time.keep && time.place==.World && time.setting==.None)
    testing.expect(t,settings.place==.Shared && settings.setting==.Project && settings.default!=nil)
    testing.expect(t,problems.by_world && problems.place==.Shared)

    a,b:Described_World
    testing.expect(t,world_init(&info,.World,&a,context.allocator) && world_init(&info,.World,&b,context.allocator))
    defer world_destroy(&info,.World,&a)
    defer world_destroy(&info,.World,&b)
    testing.expect(t,a.transforms.base && a.disabled.base && a.paces.base,"the components of core are the base of every entity")
    testing.expect(t,a.clock.scale==1 && a.frame.alpha==1 && a.plain.value==3,"a storage starts as its default")
    a.time.tick,a.frame.alpha,a.clock.scale,a.plain.value,a.reset.value=7,0.5,2,9,9
    testing.expect(t,world_copy(&info,&b,&a))
    testing.expect(t,b.time.tick==7 && b.clock.scale==2 && b.plain.value==9 && b.frame.alpha==1,"what says copy=false stays")
    testing.expect(t,world_clear(&info,&a))
    testing.expect(t,a.time.tick==7 && a.clock.scale==2,"what says keep survives clearing the World")
    testing.expect(t,a.plain.value==3 && a.reset.value==-1,"a derived storage goes back to its default, or to what its reset leaves")
    world_swap(&info,&a,&b)
    testing.expect(t,a.plain.value==9 && b.plain.value==3 && a.frame.alpha==0.5 && b.frame.alpha==1,"a swap trades what two Worlds hold, but for what says copy=false")

    if lines,read:=test_info(t,Described_Lines);read {
        defer test_info_destroy(&lines)
        sent,single:=lines.tables[0],lines.tables[1]
        kept,plain:=lines.storages[0],lines.storages[1]
        testing.expect(t,sent.replicated==.All && !sent.single && kept.keep,"a declaration on one line has its attributes")
        testing.expect(t,single.single && single.replicated==.None && !plain.keep,"and the declaration below it does not")
    }

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
        made,problem:=made_build({.World=c.world,.Shared=c.shared,.Editor=nil},test_types_none,context.allocator)
        testing.expectf(t,made==nil && strings.contains(problem,c.names),"%s: %q",c.what,problem)
        made_destroy(made)
    }
}
