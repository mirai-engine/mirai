package author

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:host"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The bindings of the nodes: a path of the data of the game (ui.tree_bind)
// for what a node shows or does, chosen with the icon next to the property it
// takes the place of. The lists walk the types of the world of the editor;
// whether the game has a path is what ui.tree_instance_init says: the
// resolver the game runs. After every build the .ui of the project are
// checked against the types of the game, and ui.check says what failed.

// What a binding takes: the kinds of fields its list offers.
Bind_Kind :: enum u8 {Shown,Number,Asset,Color,Name,Entity,Items,Options,Data}

BIND_KIND_TAKES :: [Bind_Kind]string{
    .Shown  = "a number, a bool, an enum or a text",
    .Number = "a number, a bool or an enum",
    .Asset  = "an Asset_Id",
    .Color  = "a color of 3 or 4 f32 or u8",
    .Name   = "an enum or a text",
    .Entity = "an Entity",
    .Items  = "an array of structs or of entities",
    .Options = "an array of texts or of enums",
    .Data   = "a struct or an Entity",
}

// Where a list of paths stands: the sources (the components of the entity
// and the storages), the fields of a struct, or the components of an entity.
Path_Scope_Kind :: enum u8 {Sources,Struct,Entity}

PATH_SCOPE_NAMES :: [Path_Scope_Kind]string{.Sources="Sources",.Struct="Struct",.Entity="Entity"}

Path_Scope :: struct {
    kind:Path_Scope_Kind,
    info:^runtime.Type_Info, // Struct
}

Path_Entry :: struct {
    name:string,
    info:^runtime.Type_Info,
    storage:bool,
    next:Path_Scope, // where it leads, when it is navigable
    navigable:bool,
    fits:bool,       // the binding takes it
    game:bool,       // a source the game of the project declares
}

// The kind of field each binding takes.
bind_kind :: proc(binding:ui.Binding,node:ui.Node_Kind) -> Bind_Kind {
    switch binding {
    case .Text:                         return .Shown
    case .Value:                        return .Entity if node==.View else .Number
    case .Visible,.Selected,.Disabled:  return .Number
    case .Items:                        return .Options if node==.Selector || node==.Dropdown || node==.Tabs else .Items
    case .Image:                        return .Asset
    case .Tint:                         return .Color
    case .Variant:                      return .Name
    }
    return .Shown
}

// Whether a binding of kind takes a field of type t, as ui.tree_bind does.
type_fits :: proc(t:^runtime.Type_Info,kind:Bind_Kind) -> bool {
    if t==nil {return false}
    if t.id==base.Asset_Id {return kind==.Asset}
    if t.id==base.Entity {return kind==.Entity || kind==.Data}
    #partial switch v in runtime.type_info_base(t).variant {
    case runtime.Type_Info_Boolean,runtime.Type_Info_Integer:
        return kind==.Shown || kind==.Number
    case runtime.Type_Info_Float:
        return (t.size==4 || t.size==8) && (kind==.Shown || kind==.Number)
    case runtime.Type_Info_Enum:
        return kind==.Shown || kind==.Number || kind==.Name
    case runtime.Type_Info_Array:
        elem:=runtime.type_info_base(v.elem)
        _,is_uint:=elem.variant.(runtime.Type_Info_Integer)
        _,is_float:=elem.variant.(runtime.Type_Info_Float)
        if kind==.Items {
            _,is_struct:=elem.variant.(runtime.Type_Info_Struct)
            return v.elem.id==base.Entity || is_struct && v.elem.id!=base.Asset_Id
        }
        if kind==.Options {
            if _,is_enum:=elem.variant.(runtime.Type_Info_Enum);is_enum {return true}
            text,is_array:=elem.variant.(runtime.Type_Info_Array)
            if !is_array {return false}
            letter,is_integer:=runtime.type_info_base(text.elem).variant.(runtime.Type_Info_Integer)
            return is_integer && !letter.signed && text.elem.size==1
        }
        if (v.count==3 || v.count==4) && kind==.Color {return is_float && v.elem.size==4 || is_uint && v.elem.size==1}
        return is_uint && v.elem.size==1 && (kind==.Shown || kind==.Name)
    case runtime.Type_Info_Struct:
        return kind==.Data
    }
    return false
}

// Where a field leads: a struct to its fields, an entity to its components.
type_next :: proc(t:^runtime.Type_Info) -> (next:Path_Scope,navigable:bool) {
    if t==nil || t.id==base.Asset_Id {return}
    if t.id==base.Entity {return {kind=.Entity},true}
    if _,is_struct:=runtime.type_info_base(t).variant.(runtime.Type_Info_Struct);is_struct {return {kind=.Struct,info=t},true}
    return
}

// The fields of a struct, those of its using fields among them.
struct_fields :: proc(t:^runtime.Type_Info,list:^[dynamic]Path_Entry,kind:Bind_Kind) {
    v,ok:=runtime.type_info_base(t).variant.(runtime.Type_Info_Struct)
    if !ok {return}
    for i in 0..<int(v.field_count) {
        tag:=v.tags[i]
        if strings.contains(tag,"transient") || strings.contains(tag,"hidden") {continue}
        if v.usings[i] {struct_fields(v.types[i],list,kind);continue}
        next,navigable:=type_next(v.types[i])
        append(list,Path_Entry{name=v.names[i],info=v.types[i],next=next,navigable=navigable,fits=type_fits(v.types[i],kind)})
    }
}

// What a list of paths offers in scope: the game's components first.
path_entries :: proc(info:^core.World_Info,scope:Path_Scope,kind:Bind_Kind) -> []Path_Entry {
    list:=make([dynamic]Path_Entry,context.temp_allocator)
    switch scope.kind {
    case .Sources,.Entity:
        if info==nil {break}
        // A storage is the game's when its library declares a component of the game.
        game_library :: proc(info:^core.World_Info,library:string) -> bool {
            for &t in info.tables {if t.game && t.library==library {return true}}
            return false
        }
        for game in ([2]bool{true,false}) {
            for &t in info.tables {
                if t.place!=.World || t.game!=game {continue}
                append(&list,Path_Entry{name=t.name,info=t.info,next={kind=.Struct,info=t.info},navigable=true,fits=kind==.Data,game=game})
            }
            if scope.kind!=.Sources {continue}
            for &s in info.storages {
                if s.place!=.World || s.by_world || game_library(info,s.library)!=game {continue}
                append(&list,Path_Entry{name=s.name,info=s.info,storage=true,next={kind=.Struct,info=s.info},navigable=true,fits=kind==.Data,game=game})
            }
        }
    case .Struct:
        struct_fields(scope.info,&list,kind)
    }
    return list[:]
}

// Where a path stops being one of the game: the scope it was walked to and
// the name that scope lacks, or, with leaf, the one the path goes on past
// though it leads nowhere.
Path_Stop :: struct {
    scope:Path_Scope,
    name:string,
    leaf:^runtime.Type_Info,
}

// The type a path names from scope, and where the paths after it go. The
// paths of a widget that start with @ start at data. A path the game does not
// have leaves in stop where it ends.
path_walk :: proc(info:^core.World_Info,scope:Path_Scope,path:string,data:Path_Scope={},stop:^Path_Stop=nil) -> (next:Path_Scope,leaf:^runtime.Type_Info,ok:bool) {
    s:=scope
    rest:=path
    if strings.has_prefix(rest,"@") {
        if data.kind==.Sources {return}
        s,rest=data,rest[1:]
        if rest=="" {return s,s.info,true}
    }
    for rest!="" {
        name:=rest
        if dot:=strings.index_byte(rest,'.');dot>=0 {name,rest=rest[:dot],rest[dot+1:]} else {rest=""}
        found:=false
        for &e in path_entries(info,s,.Data) {
            if e.name!=name {continue}
            if s.kind==.Entity && e.storage {break}
            leaf,found=e.info,true
            // A number after an array names its element.
            for rest!="" && leaf.id!=base.Asset_Id {
                array,is_array:=runtime.type_info_base(leaf).variant.(runtime.Type_Info_Array)
                if !is_array {break}
                segment,after:=rest,""
                if dot:=strings.index_byte(rest,'.');dot>=0 {segment,after=rest[:dot],rest[dot+1:]}
                element,parsed:=strconv.parse_uint(segment,10)
                if !parsed {break}
                if element>=uint(array.count) {
                    if stop!=nil {stop^={scope=s,name=segment,leaf=leaf}}
                    return s,nil,false
                }
                name,leaf,rest=segment,array.elem,after
            }
            next_scope,navigable:=type_next(leaf)
            if rest!="" && !navigable {
                if stop!=nil {stop^={scope=s,name=name,leaf=leaf}}
                return s,nil,false
            }
            s=next_scope
            break
        }
        if !found {
            if stop!=nil {stop^={scope=s,name=name}}
            return
        }
    }
    return s,leaf,true
}

// Where the paths of a node of a list start: the elements of each List around it.
node_scope :: proc(info:^core.World_Info,nodes:[]ui.Tree_Node,row:int,data:Path_Scope={}) -> (scope:Path_Scope,ok:bool) {
    lists:[ui.TREE_DEPTH]int
    count:=0
    for parent:=int(nodes[row].parent) if row>=0 && row<len(nodes) else -1;parent>=0;parent=int(nodes[parent].parent) {
        if nodes[parent].kind==.List && count<len(lists) {lists[count]=parent;count+=1}
    }
    scope={kind=.Sources}
    #reverse for list in lists[:count] {
        items:=serial.text_field(nodes[list].bind_items[:])
        if items=="" {return {},false}
        _,leaf:=path_walk(info,scope,items,data) or_return
        // A component named alone, outside lists, is its table: each row that struct.
        if scope.kind==.Sources && info!=nil && strings.index_byte(items,'.')<0 {
            table:=false
            for &t in info.tables {table||=t.place==.World && t.name==items}
            if table {scope={kind=.Struct,info=leaf};continue}
        }
        array,is_array:=runtime.type_info_base(leaf).variant.(runtime.Type_Info_Array)
        if !is_array {return {},false}
        scope,ok=type_next(array.elem)
        if !ok {return}
    }
    return scope,true
}

PATH_WHY_NAMES :: 24 // names a reason lists of what the game has

// Why the game does not take path from scope for a binding of kind: the name
// it lacks with those it has there, or the type it has that the binding
// does not take.
path_why :: proc(info:^core.World_Info,scope:Path_Scope,path:string,kind:Bind_Kind) -> string {
    takes:=BIND_KIND_TAKES
    stop:Path_Stop
    _,leaf,walked:=path_walk(info,scope,path,{},&stop)
    if walked {
        if leaf==nil || type_fits(leaf,kind) {return fmt.tprintf("the game cannot show it there: this binding takes %s",takes[kind])}
        return fmt.tprintf("it is a %v, and this binding takes %s",leaf,takes[kind])
    }
    if stop.name=="" {return "the game does not have it"}
    if stop.leaf!=nil {
        if array,is_array:=runtime.type_info_base(stop.leaf).variant.(runtime.Type_Info_Array);is_array {
            if _,number:=strconv.parse_uint(stop.name,10);number {return fmt.tprintf("the array has %d elements: %s is past the last, %d",array.count,stop.name,array.count-1)}
        }
        return fmt.tprintf("'%s' is a %v, which has no fields for the path to go on to",stop.name,stop.leaf)
    }
    names:=make([dynamic]string,context.temp_allocator)
    entries:=path_entries(info,stop.scope,.Data)
    game:=false
    for &e in entries {game||=e.game}
    more:=0
    for &e in entries {
        if game && !e.game || stop.scope.kind==.Entity && e.storage {continue}
        if len(names)<PATH_WHY_NAMES {append(&names,e.name)} else {more+=1}
    }
    has:=strings.join(names[:],", ",context.temp_allocator) if len(names)>0 else "none"
    if more>0 {has=fmt.tprintf("%s and %d more",has,more)}
    switch stop.scope.kind {
    case .Sources: return fmt.tprintf("the game has no component or storage '%s'; %s %s",stop.name,"it declares" if game else "there are",has)
    case .Entity:  return fmt.tprintf("the game has no component '%s' for an Entity to lead to; %s %s",stop.name,"it declares" if game else "there are",has)
    case .Struct:
    }
    return fmt.tprintf("%v has no field '%s'; it has %s",stop.scope.info,stop.name,has)
}


// ---------------------------------------------------------------- the resolver of the game

// The sources of the world of the editor for ui.tree_instance_init: by
// name, in a schema of their own, made again when the world is another.
Bind_Types :: struct {
    schema:serial.Schema,
    ready:bool,
    info:^core.World_Info,
    sources:[dynamic]Bind_Type,
}
Bind_Type :: struct {name:u64,index:serial.Type_Index,storage:bool}

bind_types_free :: proc(b:^Bind_Types) {
    if b.ready {serial.schema_destroy(&b.schema)}
    delete(b.sources)
    b^={}
}

bind_types_host :: proc(b:^Bind_Types,info:^core.World_Info,allocator:runtime.Allocator) -> ui.Bind_Host {
    if !b.ready || b.info!=info {
        if b.ready {serial.schema_destroy(&b.schema)}
        serial.schema_init(&b.schema,allocator)
        if b.sources.allocator.procedure==nil {b.sources=make([dynamic]Bind_Type,allocator)}
        clear(&b.sources)
        b.ready,b.info=true,info
    }
    // A List that names a component binds the rows of its table, as in the game: none here.
    rows :: proc(user:rawptr,name:u64) -> (data:rawptr,count,stride:int,stamp:u64) {return}
    return {user=b,schema=&b.schema,rows=rows,source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
        b:=(^Bind_Types)(user)
        for known in b.sources {if known.name==name {return known.index,known.storage,true}}
        if b.info==nil {return}
        found:^runtime.Type_Info
        for &t in b.info.tables {if t.place==.World && base.name_hash(t.name)==name {found=t.info;break}}
        if found==nil {
            for &s in b.info.storages {
                if s.place==.World && !s.by_world && base.name_hash(s.name)==name {found,storage=s.info,true;break}
            }
        }
        if found==nil {return}
        type,ok=serial.schema_add_type_info(&b.schema,found)
        if ok {append(&b.sources,Bind_Type{name,type,storage})}
        return
    }}
}

BIND_PROBLEMS :: 16 // problems a check of one .ui reports at most

// What fails: a path the game does not have, a name in braces of a text, a
// widget it uses, records that do not load, or a name of a style, a token, a
// component or a parameter that resolves to nothing.
Bind_Fault :: enum u8 {Path,Template,Widget,Load,Name}

// Why the widgets the records name do not read: the first one missing, one
// that is not a .ui that loads, or one that uses the file back.
widget_why :: proc(a:Assets,data:ui.Tree_Data) -> string {
    a:=a
    w:=widget_walk(data.components,{},{},widget_uses_of_file,&a)
    if w.broken.widget=={} {return "a widget it uses does not load"}
    record,found:=asset.registry_find(a.registry,w.broken.widget)
    if !found || record.kind!=asset.KIND_UI {return fmt.tprintf("it uses '%s', whose file is missing",serial.text_field(w.broken.name[:]))}
    if w.cycle {return fmt.tprintf("'%s' uses a file that uses it back: a cycle",record.path)}
    return fmt.tprintf("'%s', which it uses, does not load",record.path)
}

// What the paths of a .ui fail at, against the types of the world: a node
// of its records whose binding the game does not have, or why it does not load.
Bind_Problem :: struct {
    asset:base.Asset_Id,
    row:int,              // of its nodes; -1: a node of a widget it uses, or the tree as a whole
    use:int,              // of its nodes: the use of the widget the node is inside; -1: none
    node:int,             // of the tree as it loads; -1: it does not load
    name:[ui.TREE_NAME_CAPACITY*2]u8, // of that node; inside a widget, instance/node
    binding:ui.Binding,
    takes:Bind_Kind,      // Path: what that binding takes at that node
    fault:Bind_Fault,
    path:[ui.TREE_PATH_CAPACITY]u8, // Path: what it binds; Widget and Load: why
}

// Checks the records of a .ui, linked with the widgets they use (imports, as
// host.ui_tree_imports gives them): what fails goes to out, each binding the
// game does not have once. Returns how many.
bind_check :: proc(types:^Bind_Types,allocator:runtime.Allocator,a:Assets,info:^core.World_Info,data:ui.Tree_Data,imports:[]ui.Tree_Data,imported:bool,out:[]Bind_Problem) -> (count:int) {
    if len(out)==0 {return}
    fail :: proc(out:[]Bind_Problem,fault:Bind_Fault,why:string) -> int {
        out[0]={row=-1,use=-1,node=-1,fault=fault}
        ui.tree_text_set(out[0].path[:],why)
        return 1
    }
    if !imported {return fail(out,.Widget,widget_why(a,data))}
    linked,linked_ok:=ui.tree_link(data,imports)
    if !linked_ok {return fail(out,.Widget,"a widget it uses has no single root")}
    tree:ui.Widget_Tree
    textures:=make([]u32,len(linked.images),context.temp_allocator)
    fonts:=make([]u8,len(linked.fonts),context.temp_allocator)
    if !ui.tree_load(&tree,linked,{textures=textures,fonts=fonts},context.temp_allocator) {return fail(out,.Load,load_why(a,data,imports))}
    defer ui.tree_destroy(&tree)
    host_of:=bind_types_host(types,info,allocator)
    for count<len(out) {
        instance:ui.Tree_Instance
        if ui.tree_instance_init(&instance,&tree,&host_of,{},context.temp_allocator) {
            ui.tree_instance_destroy(&instance)
            return
        }
        failure:=instance.failure
        if failure.capacity || failure.node<0 || failure.node>=tree.node_count {return}
        node:=&tree.nodes[failure.node]
        // A path that starts with @ reads the data its uses give, and each use
        // is checked where it is; so is what a List of such a path holds, and a
        // text with one in its braces.
        if bind_late(&tree,node,failure) {
            switch {
            case failure.template:                             node.text_length=0
            case failure.binding==.Items && node.kind==.List:  for &inner in tree.nodes[failure.node:][:int(node.subtree)+1] {inner.binds={};inner.text_length=0}
            case:                                              node.binds[failure.binding]={}
            }
            continue
        }
        problem:=Bind_Problem{row=-1,use=-1,node=failure.node,binding=failure.binding,takes=bind_kind(failure.binding,node.kind),fault=.Template if failure.template else .Path}
        if !failure.template {ui.tree_text_set(problem.path[:],ui.tree_binding(&tree,node,failure.binding))}
        // The row of the records it comes from, as the preview counts them.
        at:=0
        for n,row in linked.nodes {
            nodes:=tree_node_count(linked,n,0)
            if failure.node<at+nodes {
                if n.kind!=.Component {problem.row=row} else {problem.use=row}
                bind_problem_name(&problem,linked,row,node.name)
                break
            }
            at+=nodes
        }
        out[count]=problem
        count+=1
        // What failed binds nothing from now on, so the next check finds the
        // next; what a List holds would fail with its items.
        switch {
        case failure.template:         node.text_length=0
        case failure.binding==.Items:  for &inner in tree.nodes[failure.node:][:int(node.subtree)+1] {inner.binds={};inner.text_length=0}
        case:                          node.binds[failure.binding]={}
        }
    }
    return
}

// Whether what failed is a path that starts with @: one only a use knows.
bind_late :: proc(tree:^ui.Widget_Tree,node:^ui.Node,failure:ui.Bind_Failure) -> bool {
    if !failure.template {return strings.has_prefix(ui.tree_binding(tree,node,failure.binding),"@")}
    for f in node.fields {
        if f.path.length>0 && tree.strings[f.path.offset]=='@' {return true}
    }
    return false
}

// Names a problem after the node it failed at: the row of its records, or
// instance/node for one inside a widget.
bind_problem_name :: proc(problem:^Bind_Problem,linked:ui.Tree_Data,row:int,node:u64) {
    outer:=&linked.nodes[row]
    name:=serial.text_field(outer.name[:])
    if outer.kind==.Component {
        for &inner in data_template(linked,int(outer.component)) {
            if inner_name:=serial.text_field(inner.name[:]);inner_name!="" && base.name_hash(fmt.tprintf("%s/%s",name,inner_name))==node {name=fmt.tprintf("%s/%s",name,inner_name);break}
        }
    }
    ui.tree_text_set(problem.name[:],name)
}

// Why records of a .ui do not load, for a person: an override that names a
// node its widget does not have, or records that contradict themselves.
load_why :: proc(a:Assets,data:ui.Tree_Data,imports:[]ui.Tree_Data) -> string {
    linked,ok:=ui.tree_link(data,imports)
    if !ok {return "a widget it uses has no single root"}
    for &o in data.overrides {
        name:=serial.text_field(o.node[:])
        if int(o.instance)>=len(data.nodes) || data.nodes[o.instance].kind!=.Component {return fmt.tprintf("the override of '%s' is of a node that is not an instance",name)}
        instance:=&data.nodes[o.instance]
        found:=false
        for &n in data_template(linked,int(instance.component)) {found|=serial.text_field(n.name[:])==name}
        if found {continue}
        c:=int(instance.component)-1
        widget:=data.components[c].widget if c>=0 && c<len(data.components) else {}
        return fmt.tprintf("%s sets '%s', which %s does not have",serial.text_field(instance.name[:]),name,file_name_of(a,widget,"missing") if a.registry!=nil else "its widget")
    }
    return "its records contradict themselves"
}

// What a problem says, for a person or an agent.
bind_problem_text :: proc(a:Assets,problem:^Bind_Problem) -> string {
    file:=file_name_of(a,problem.asset,"missing")
    switch problem.fault {
    case .Widget,.Load: return fmt.tprintf("%s does not load: %s",file,serial.text_field(problem.path[:]))
    case .Name:         return fmt.tprintf("%s: %s",file,serial.text_field(problem.path[:]))
    case .Template:     return fmt.tprintf("%s: node '%s' has a name in braces of its text without a field, or whose field names a path the game does not have or cannot show",file,serial.text_field(problem.name[:]))
    case .Path:
    }
    return fmt.tprintf("%s: node '%s' binds '%s' for its %v, which the game does not have or cannot show there",file,serial.text_field(problem.name[:]),serial.text_field(problem.path[:]),problem.binding)
}


// Checks one .ui of the project: its problems go to problems.
bind_check_file :: proc(problems:^[dynamic]Bind_Problem,types:^Bind_Types,allocator:runtime.Allocator,a:Assets,info:^core.World_Info,id:base.Asset_Id) {
    found:[BIND_PROBLEMS]Bind_Problem
    count:int
    records:Records
    if records_read(a,id,&records,context.temp_allocator) {
        count=records_names_check(a,&records,found[:])
        if count<len(found) {
            data:=records_data(&records)
            imports,imported:=tree_imports(a,data)
            count+=bind_check(types,allocator,a,info,data,imports,imported,found[count:])
        }
    } else {
        found[0]={row=-1,use=-1,node=-1,fault=.Load}
        ui.tree_text_set(found[0].path[:],"its file cannot be read")
        count=1
    }
    for &problem in found[:count] {
        problem.asset=id
        append(problems,problem)
    }
}

bind_check_all :: proc(problems:^[dynamic]Bind_Problem,types:^Bind_Types,allocator:runtime.Allocator,a:Assets,info:^core.World_Info) {
    clear(problems)
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        bind_check_file(problems,types,allocator,a,info,file.id)
    }
}

// The names of a .ui that resolve to nothing: of styles, tokens, components
// and parameters, with where. What the file named in another that changed
// since it was written shows here, before it fails to load. How many went to out.
records_names_check :: proc(a:Assets,r:^Records,out:[]Bind_Problem) -> (count:int) {
    args:=Tree_Args{}
    report :: proc(out:[]Bind_Problem,count:^int,format:string,args:..any) {
        if count^>=len(out) {return}
        out[count^]={row=-1,use=-1,node=-1,fault=.Name}
        ui.tree_text_set(out[count^].path[:],fmt.tprintf(format,..args))
        count^+=1
    }
    libs:=make([dynamic]Doc_Lib,context.temp_allocator)
    args.libs=&libs
    for &template in r.components {
        if template.widget=={} {continue}
        seen:=false
        for &lib in libs {seen||=lib.id==template.widget}
        if seen {continue}
        records:Records
        if lib,read:=doc_lib_read(a,template.widget,context.temp_allocator);read {append(&libs,lib)}
    }
    has_style :: proc(r:^Records,libs:[]Doc_Lib,name:string) -> bool {
        if tree_style_row(r,name)>=0 {return true}
        for &lib in libs {
            for &info in lib.records.style_infos {if serial.text_field(info.name[:])==name {return true}}
        }
        return false
    }
    for &info,row in r.style_infos {
        name:=records_style_name(r,row)
        if ext:=serial.text_field(info.extends[:]);ext!="" && !has_style(r,libs[:],ext) {
            report(out,&count,"style '%s' extends '%s', which is no style of this file or of a file it uses",name,ext)
        }
        if info.from!=0 {
            found:=false
            for &lib in libs {
                for &other in lib.records.style_infos {found||=other.name==info.name}
            }
            if !found {report(out,&count,"nodes take the style '%s', which the file it is taken from no longer has",name)}
        }
    }
    for &use in r.token_uses {
        token:=serial.text_field(use.token[:])
        if doc_token_find(r,libs[:],token)==nil {
            report(out,&count,"style '%s' names the token '%s', which is not in tokens or in a file this one uses",records_style_name(r,int(use.style)),token)
        }
    }
    for &p in r.params {
        node:=serial.text_field(p.node[:])
        param:=serial.text_field(p.param[:])
        name:=serial.text_field(p.name[:])
        if node=="" {continue}
        n:=records_node_named(r,node)
        if n==nil {report(out,&count,"the parameter '%s' goes to node '%s', which this file does not have",name,node);continue}
        if param=="" {continue}
        if n.kind!=.Component || int(n.component)==0 || int(n.component)>len(r.components) {report(out,&count,"the parameter '%s' goes to the parameter '%s' of node '%s', which is not the use of a widget",name,param,node);continue}
        found:=false
        for &lib in libs {
            if lib.id!=r.components[n.component-1].widget {continue}
            for &inner in lib.linked.params {found||=serial.text_field(inner.name[:])==param}
        }
        if !found {report(out,&count,"the parameter '%s' goes to '%s' of node '%s', which its widget no longer has",name,param,node)}
    }
    roots:=0
    for &n in r.nodes {roots+=int(n.parent<0)}
    if (len(r.params)>0 || records_slot_row(r)>=0) && roots!=1 {report(out,&count,"it declares parameters or a slot, so it is a widget: it needs one root and has %d",roots)}
    return
}


// The records of a .ui as the assets hold it, unsaved changes included.
records_read :: proc(a:Assets,id:base.Asset_Id,records:^Records,allocator:runtime.Allocator) -> bool {
    if a.registry==nil {return false}
    record,found:=asset.registry_find(a.registry,id)
    if !found || record.kind!=asset.KIND_UI {return false}
    bytes,read:=asset.registry_read(a.registry,record.path,context.temp_allocator)
    if read!=.None {return false}
    file:asset.Asset
    if asset.asset_take(&file,bytes,context.temp_allocator)!=.None {return false}
    defer asset.asset_close(&file)
    if !asset.blob_verify_hash(&file.blob) || file.blob.header.id!=id {return false}
    data,error:=host.ui_tree_view(&file,a.types)
    return error==.None && records_load(records,data,allocator)
}


// Where the @ paths of the .ui id start, as widget_scope says.
widget_scope_of :: proc(a:Assets,info:^core.World_Info,id:base.Asset_Id) -> Path_Scope {
    if a.registry==nil {return {}}
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} || file.id==id {continue}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        for &template,component in records.components {
            if template.widget!=id {continue}
            for &n,row in records.nodes {
                data:=serial.text_field(n.data[:])
                if n.kind!=.Component || int(n.component)!=component+1 || data=="" || strings.has_prefix(data,"@") {continue}
                scope,ok:=node_scope(info,records.nodes[:],row)
                if !ok {continue}
                if next,_,walked:=path_walk(info,scope,data);walked && next.kind!=.Sources {return next}
            }
        }
    }
    return {}
}


path_join :: proc(prefix,name:string) -> string {
    if prefix=="" {return name}
    if prefix=="@" {return fmt.tprintf("@%s",name)}
    return fmt.tprintf("%s.%s",prefix,name)
}

slice_has :: proc(list:[]string,name:string) -> bool {
    for item in list {if item==name {return true}}
    return false
}


// The paths of a node: its bindings and the data of a widget.
node_paths :: proc(n:^ui.Tree_Node) -> [14][]u8 {
    f:=&n.fields
    return {n.bind_text[:],n.bind_value[:],n.bind_visible[:],n.bind_selected[:],n.bind_disabled[:],n.bind_items[:],n.bind_image[:],n.bind_tint[:],n.bind_variant[:],n.data[:],
        f[0].path[:],f[1].path[:],f[2].path[:],f[3].path[:]}
}

// The names in braces of a text, once each, in order: "{coins}", "{time:mm:ss}".
text_field_names :: proc(text:string) -> []string {
    names:=make([dynamic]string,context.temp_allocator)
    for i:=0;i<len(text);i+=1 {
        if text[i]!='{' {continue}
        if i+1<len(text) && text[i+1]=='{' {i+=1;continue}
        end:=i+1
        for end<len(text) && text[end]!='}' && text[end]!=':' {end+=1}
        name:=strings.trim_space(text[i+1:end])
        if name!="" && !slice_has(names[:],name) {append(&names,name)}
        for end<len(text) && text[end]!='}' {end+=1}
        i=end
    }
    return names[:]
}

// The field of a node a name of its text has; with make, a free one takes
// the name, or one whose name the text no longer has. -1: none.
text_field_of :: proc(r:^Records,n:^ui.Tree_Node,name:string,make:=false) -> int {
    for &f,i in n.fields {if serial.text_field(f.name[:])==name {return i}}
    if !make || len(name)>=ui.TREE_FIELD_NAME_CAPACITY {return -1}
    names:=text_field_names(records_text(r,n.text))
    for &f,i in n.fields {
        if f.name[0]==0 || !slice_has(names,serial.text_field(f.name[:])) {
            f={}
            ui.tree_text_set(f.name[:],name)
            return i
        }
    }
    return -1
}

// Whether a node takes any path of the game, the fields of its text too.
node_bound :: proc(n:^ui.Tree_Node) -> bool {
    for f in node_paths(n) {if f[0]!=0 {return true}}
    return false
}


// The file records are written as, tidied, in the temporary allocator, and
// the widgets they use. A tree the game would not load gives none: message
// says why.
records_bytes :: proc(a:Assets,id:base.Asset_Id,records:^Records) -> (bytes:[]u8,imports:[]ui.Tree_Data,message:string,ok:bool) {
    records_tidy(records)
    imported:bool
    if imports,imported=tree_imports(a,records_data(records));!imported {return nil,nil,widget_why(a,records_data(records)),false}
    error:asset.Error
    bytes,error=records_commit(a.types,id,records,imports)
    if error==.Invalid {return nil,nil,fmt.tprintf("the interface would not load: %s",load_why(a,records_data(records),imports)),false}
    if error!=.None {return nil,nil,fmt.tprintf("the interface could not be written: %v",error),false}
    return bytes,imports,"",true
}

// Takes a path away from a node: unbound, its visibility is Visible again,
// not what it was while the bool of the game was false.
node_unbind :: proc(n:^ui.Tree_Node,field:[]u8) {
    for &b in field {b=0}
    if raw_data(field)==raw_data(n.bind_visible[:]) {n.flags-={.Invisible,.Collapsed}}
}

// The file a document leaves the records of the .ui id as, as records_bytes
// gives it. False after failing the reading with why its tree would not load.
document_bytes :: proc(args:^Tree_Args,id:base.Asset_Id,r:^Records) -> (bytes:[]u8,imports:[]ui.Tree_Data,ok:bool) {
    why:string
    bytes,imports,why,ok=records_bytes(args.assets,id,r)
    if !ok {
        reading_failf(args.reading,"%s. Nothing changed. A tree loads when containers (Box, Scroll, Switcher, List, Tooltip, Tabs, Popup, Modal, Context_Menu, Radial) hold the nodes, a List holds one node, numbers are finite, keys go in time order and every row it names exists",why)
    }
    return
}

// The problems of a check as ui.check and mirai ui check give them.
problems_write :: proc(out:^serial.Writer,a:Assets,problems:[]Bind_Problem) {
    serial.text_write_raw(out,`{"problems":[`)
    for &problem,i in problems {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        serial.json_text(out,"asset",file_name_of(a,problem.asset,"missing"),true)
        serial.json_text(out,"node",serial.text_field(problem.name[:]))
        serial.json_text(out,"binding","Text (in braces)" if problem.fault==.Template else fmt.tprintf("%v",problem.binding) if problem.fault==.Path else "")
        serial.json_text(out,"path",serial.text_field(problem.path[:]) if problem.fault==.Path else "")
        serial.json_bool(out,"loads",problem.fault!=.Widget && problem.fault!=.Load)
        serial.json_text(out,"message",bind_problem_text(a,&problem))
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}
