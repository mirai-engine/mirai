package ui_inspector_editor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "mirai:asset"
import "mirai:core"
import "mirai:editor"
import "mirai:editor/api"
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

PICK_DEPTH :: 3     // structs a list of paths goes into to find what a binding takes
PICK_RESULTS :: 60  // paths a search or a source in use lists

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
@(private)
type_next :: proc(t:^runtime.Type_Info) -> (next:Path_Scope,navigable:bool) {
    if t==nil || t.id==base.Asset_Id {return}
    if t.id==base.Entity {return {kind=.Entity},true}
    if _,is_struct:=runtime.type_info_base(t).variant.(runtime.Type_Info_Struct);is_struct {return {kind=.Struct,info=t},true}
    return
}

// The fields of a struct, those of its using fields among them.
@(private)
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

// The type a path names from scope, and where the paths after it go. The
// paths of a widget that start with @ start at data.
path_walk :: proc(info:^core.World_Info,scope:Path_Scope,path:string,data:Path_Scope={}) -> (next:Path_Scope,leaf:^runtime.Type_Info,ok:bool) {
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
            if rest!="" {
                if !e.navigable {return}
                s=e.next
            } else {
                s,_=type_next(e.info)
            }
            break
        }
        if !found {return}
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
        array,is_array:=runtime.type_info_base(leaf).variant.(runtime.Type_Info_Array)
        if !is_array {return {},false}
        scope,ok=type_next(array.elem)
        if !ok {return}
    }
    return scope,true
}

// A path as a person reads it: its parts with arrows between them.
path_shown :: proc(path:string) -> string {
    if path=="" {return ""}
    shown,_:=strings.replace_all(path,"."," > ",context.temp_allocator)
    return shown
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

@(private)
bind_types_host :: proc(b:^Bind_Types,info:^core.World_Info,allocator:runtime.Allocator) -> ui.Bind_Host {
    if !b.ready || b.info!=info {
        if b.ready {serial.schema_destroy(&b.schema)}
        serial.schema_init(&b.schema,allocator)
        if b.sources.allocator.procedure==nil {b.sources=make([dynamic]Bind_Type,allocator)}
        clear(&b.sources)
        b.ready,b.info=true,info
    }
    return {user=b,schema=&b.schema,source=proc(user:rawptr,name:u64) -> (type:serial.Type_Index,storage,ok:bool) {
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

WIDGET_MISSING :: "a widget it uses is missing, does not load or uses it back"

// What the paths of a .ui fail at, against the types of the world: a node
// of its records whose binding the game does not have, or why it does not load.
Bind_Problem :: struct {
    asset:base.Asset_Id,
    row:int,              // of its nodes; -1: a node of a widget it uses, or the tree as a whole
    node:int,             // of the tree as it loads; -1: it does not load
    name:[ui.TREE_NAME_CAPACITY*2]u8, // of that node; inside a widget, instance/node
    binding:ui.Binding,
    fault:Bind_Fault,
    path:[ui.TREE_PATH_CAPACITY]u8, // Path: what it binds; Widget and Load: why
}

// Checks the records of a .ui, linked with the widgets they use (imports, as
// host.ui_tree_imports gives them): what fails goes to out, each binding the
// game does not have once. Returns how many.
bind_check :: proc(types:^Bind_Types,allocator:runtime.Allocator,a:^host.Assets,info:^core.World_Info,data:ui.Tree_Data,imports:[]ui.Tree_Data,imported:bool,out:[]Bind_Problem) -> (count:int) {
    if len(out)==0 {return}
    fail :: proc(out:[]Bind_Problem,fault:Bind_Fault,why:string) -> int {
        out[0]={row=-1,node=-1,fault=fault}
        ui.tree_text_set(out[0].path[:],why)
        return 1
    }
    if !imported {return fail(out,.Widget,WIDGET_MISSING)}
    linked,linked_ok:=ui.tree_link(data,imports)
    if !linked_ok {return fail(out,.Widget,"a widget it uses has no single root Box")}
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
        problem:=Bind_Problem{row=-1,node=failure.node,binding=failure.binding,fault=.Template if failure.template else .Path}
        if !failure.template {ui.tree_text_set(problem.path[:],ui.tree_binding(&tree,node,failure.binding))}
        // The row of the records it comes from, as the preview counts them.
        at:=0
        for n,row in linked.nodes {
            nodes:=preview_count(linked,n,0)
            if failure.node<at+nodes {
                if n.kind!=.Component {problem.row=row}
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

// Names a problem after the node it failed at: the row of its records, or
// instance/node for one inside a widget.
@(private)
bind_problem_name :: proc(problem:^Bind_Problem,linked:ui.Tree_Data,row:int,node:u64) {
    outer:=&linked.nodes[row]
    name:=serial.text_field(outer.name[:])
    if outer.kind==.Component {
        for &inner in data_template(linked,int(outer.component)) {
            if inner_name:=serial.text_field(inner.name[:]);inner_name!="" && base.name_hash(inner_name)==node {name=fmt.tprintf("%s/%s",name,inner_name);break}
        }
    }
    ui.tree_text_set(problem.name[:],name)
}

// Why records of a .ui do not load, for a person: an override that names a
// node its widget does not have, or records that contradict themselves.
load_why :: proc(a:^host.Assets,data:ui.Tree_Data,imports:[]ui.Tree_Data) -> string {
    linked,ok:=ui.tree_link(data,imports)
    if !ok {return "a widget it uses has no single root Box"}
    for &o in data.overrides {
        name:=serial.text_field(o.node[:])
        if int(o.instance)>=len(data.nodes) || data.nodes[o.instance].kind!=.Component {return fmt.tprintf("the override of '%s' is of a node that is not an instance",name)}
        instance:=&data.nodes[o.instance]
        found:=false
        for &n in data_template(linked,int(instance.component)) {found|=serial.text_field(n.name[:])==name}
        if found {continue}
        c:=int(instance.component)-1
        widget:=data.components[c].widget if c>=0 && c<len(data.components) else {}
        return fmt.tprintf("%s overrides '%s', which %s does not have",serial.text_field(instance.name[:]),name,editor.asset_name_of(a,widget,"missing") if widget!={} else "its template")
    }
    return "its records contradict themselves"
}

// What a problem says, for a person or an agent.
bind_problem_text :: proc(a:^host.Assets,problem:^Bind_Problem) -> string {
    file:=editor.asset_name_of(a,problem.asset,"missing")
    switch problem.fault {
    case .Widget,.Load: return fmt.tprintf("%s does not load: %s",file,serial.text_field(problem.path[:]))
    case .Name:         return fmt.tprintf("%s: %s",file,serial.text_field(problem.path[:]))
    case .Template:     return fmt.tprintf("%s: node '%s' has a name in braces of its text without a field, or whose field names a path the game does not have or cannot show",file,serial.text_field(problem.name[:]))
    case .Path:
    }
    return fmt.tprintf("%s: node '%s' binds '%s' for its %v, which the game does not have or cannot show there",file,serial.text_field(problem.name[:]),serial.text_field(problem.path[:]),problem.binding)
}

// A .ui as the check of the project read it last: the stamp of its file and
// the widgets it names, checked_uses[first:][:count].
Ui_Checked :: struct {
    id:base.Asset_Id,
    stamp:[2]i64,
    first,count:int,
}

// The .ui of the project checked again when the game is another build, or
// when they change: only those whose file changed and those that use them.
// What fails is said once.
@(step="ui",after="editor_panels")
ui_bindings_check :: proc(s:^editor.Session,u:^Ui_Inspector,app:^host.App) {
    a:=app.assets
    if a==nil || app.info==nil || s.gui==nil || !s.gui.begun || editor.playing(s) {return}
    if u.checked_info==app.info && u.checked_revision==a.revision {return}
    first:=u.checked_info==nil
    all:=u.checked_info!=app.info
    u.checked_info,u.checked_revision=app.info,a.revision
    if u.problems.allocator.procedure==nil {
        u.problems=make([dynamic]Bind_Problem,app.allocator)
        u.checked=make([dynamic]Ui_Checked,app.allocator)
        u.checked_uses=make([dynamic]base.Asset_Id,app.allocator)
    }
    before:=bind_files(u.problems[:])
    if !bind_check_changed(u,app.allocator,a,app.info,all) {return}
    if files:=bind_files(u.problems[:]);files>0 && (files!=before || first) {
        names:=make([dynamic]string,context.temp_allocator)
        for &problem in u.problems {
            if name:=editor.asset_name_of(a,problem.asset,"missing");!slice_has(names[:],name) {append(&names,name)}
        }
        editor.notify(s,fmt.tprintf("%d interfaces bind paths the game does not have or do not load: %s",files,strings.join(names[:],", ",context.temp_allocator)))
    }
}

// How many .ui the problems are of.
@(private)
bind_files :: proc(problems:[]Bind_Problem) -> (files:int) {
    for &problem,i in problems {
        earlier:=false
        for &other in problems[:i] {earlier|=other.asset==problem.asset}
        files+=int(!earlier)
    }
    return
}

// Checks the .ui whose file changed since the last check (all: every one),
// and those that use them through their widgets. False when none did.
@(private)
bind_check_changed :: proc(u:^Ui_Inspector,allocator:runtime.Allocator,a:^host.Assets,info:^core.World_Info,all:bool) -> bool {
    dirty:=make([dynamic]base.Asset_Id,context.temp_allocator)
    checked :: proc(u:^Ui_Inspector,id:base.Asset_Id) -> int {
        for &c,i in u.checked {if c.id==id {return i}}
        return -1
    }
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        at:=checked(u,file.id)
        if all || at<0 || u.checked[at].stamp!=([2]i64{file.size,file.time}) {append(&dirty,file.id)}
    }
    for &c in u.checked {
        if file,found:=asset.registry_find(&a.registry,c.id);!found || file.kind!=asset.KIND_UI {append(&dirty,c.id)}
    }
    // Those that use a changed one, through as many widgets as they go.
    for grew:=len(dirty)>0;grew; {
        grew=false
        for &c in u.checked {
            if slice.contains(dirty[:],c.id) {continue}
            for use in u.checked_uses[c.first:][:c.count] {
                if slice.contains(dirty[:],use) {append(&dirty,c.id);grew=true;break}
            }
        }
    }
    if len(dirty)==0 {return false}
    for i:=len(u.problems)-1;i>=0;i-=1 {
        if slice.contains(dirty[:],u.problems[i].asset) {ordered_remove(&u.problems,i)}
    }
    kept:=make([dynamic]Ui_Checked,context.temp_allocator)
    uses:=make([dynamic]base.Asset_Id,context.temp_allocator)
    for c in u.checked {
        if slice.contains(dirty[:],c.id) {continue}
        moved:=c
        moved.first=len(uses)
        append(&uses,..u.checked_uses[c.first:][:c.count])
        append(&kept,moved)
    }
    clear(&u.checked);clear(&u.checked_uses)
    append(&u.checked,..kept[:])
    append(&u.checked_uses,..uses[:])
    for id in dirty {
        file,found:=asset.registry_find(&a.registry,id)
        if !found || file.kind!=asset.KIND_UI {continue}
        entry:=Ui_Checked{id=id,stamp={file.size,file.time},first=len(u.checked_uses)}
        records:Records
        if records_read(a,id,&records,context.temp_allocator) {
            for &template in records.templates {
                if template.component.widget!={} {append(&u.checked_uses,template.component.widget)}
            }
        }
        entry.count=len(u.checked_uses)-entry.first
        append(&u.checked,entry)
        bind_check_file(&u.problems,&u.bind_types,allocator,a,info,id)
    }
    return true
}

// Checks one .ui of the project: its problems go to problems.
@(private)
bind_check_file :: proc(problems:^[dynamic]Bind_Problem,types:^Bind_Types,allocator:runtime.Allocator,a:^host.Assets,info:^core.World_Info,id:base.Asset_Id) {
    found:[BIND_PROBLEMS]Bind_Problem
    count:int
    records:Records
    if records_read(a,id,&records,context.temp_allocator) {
        count=records_names_check(a,&records,found[:])
        if count<len(found) {
            data:=records_data(&records)
            imports,imported:=host.ui_tree_imports(a,data)
            count+=bind_check(types,allocator,a,info,data,imports,imported,found[count:])
        }
    } else {
        found[0]={row=-1,node=-1,fault=.Load}
        ui.tree_text_set(found[0].path[:],"its file cannot be read")
        count=1
    }
    for &problem in found[:count] {
        problem.asset=id
        append(problems,problem)
    }
}

@(private)
bind_check_all :: proc(problems:^[dynamic]Bind_Problem,types:^Bind_Types,allocator:runtime.Allocator,a:^host.Assets,info:^core.World_Info) {
    clear(problems)
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        bind_check_file(problems,types,allocator,a,info,file.id)
    }
}

// The names of a .ui that resolve to nothing: of styles, tokens, components
// and parameters, with where. What the file named in another that changed
// since it was written shows here, before it fails to load. How many went to out.
records_names_check :: proc(a:^host.Assets,r:^Records,out:[]Bind_Problem) -> (count:int) {
    args:=Tree_Args{}
    report :: proc(out:[]Bind_Problem,count:^int,format:string,args:..any) {
        if count^>=len(out) {return}
        out[count^]={row=-1,node=-1,fault=.Name}
        ui.tree_text_set(out[count^].path[:],fmt.tprintf(format,..args))
        count^+=1
    }
    libs:=make([dynamic]Doc_Lib,context.temp_allocator)
    args.libs=&libs
    for &template in r.templates {
        if template.component.widget=={} {continue}
        seen:=false
        for &lib in libs {seen||=lib.id==template.component.widget}
        if seen {continue}
        records:Records
        if records_read(a,template.component.widget,&records,context.temp_allocator) {append(&libs,Doc_Lib{template.component.widget,records})}
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
        component:=serial.text_field(p.component[:])
        node:=serial.text_field(p.node[:])
        if node=="" {continue}
        found:=false
        for &template in r.templates {
            if template.component.widget!={} || serial.text_field(template.component.name[:])!=component {continue}
            for &n in template.nodes {found||=serial.text_field(n.name[:])==node}
        }
        if !found {report(out,&count,"the parameter '%s' of '%s' goes to node '%s', which the component does not have",serial.text_field(p.name[:]),component,node)}
    }
    for &n in r.nodes {
        if n.kind!=.Component || n.component==0 || int(n.component)>len(r.templates) {continue}
        c:=&r.templates[n.component-1].component
        name:=serial.text_field(c.name[:])
        if !c.named && c.widget=={} {continue}
        if c.named {
            found:=false
            for &lib in libs {
                if lib.id!=c.widget {continue}
                for &other in lib.records.templates {found||=!other.component.library && serial.text_field(other.component.name[:])==name}
            }
            if !found {report(out,&count,"node '%s' uses the component '%s', which its file no longer has",serial.text_field(n.name[:]),name)}
        }
        // A parameter a use gives: that its node still exists is the check of the load.
    }
    for &o in r.overrides {
        n:=&r.nodes[o.instance] if int(o.instance)<len(r.nodes) else nil
        if n==nil || n.kind!=.Component || n.component==0 || int(n.component)>len(r.templates) {continue}
        c:=&r.templates[n.component-1].component
        if !c.named {continue}
        name:=serial.text_field(c.name[:])
        target:=serial.text_field(o.node[:])
        found:=false
        for &lib in libs {
            if lib.id!=c.widget {continue}
            for &other in lib.records.templates {
                if other.component.library || serial.text_field(other.component.name[:])!=name {continue}
                for &tn in other.nodes {found||=serial.text_field(tn.name[:])==target}
            }
        }
        if !found {report(out,&count,"node '%s' sets node '%s' of '%s', which the component does not have",serial.text_field(n.name[:]),target,name)}
    }
    return
}

// Whether the game lacks what a binding of the node chosen names.
@(private)
bind_failing :: proc(u:^Ui_Inspector,binding:ui.Binding) -> bool {
    if u.scope>=0 {return false}
    for &problem in u.problem[:u.problem_count] {
        if problem.fault==.Path && problem.row==u.selected && problem.binding==binding {return true}
    }
    return false
}

// The records of a .ui as the assets hold it, unsaved changes included.
records_read :: proc(a:^host.Assets,id:base.Asset_Id,records:^Records,allocator:runtime.Allocator) -> bool {
    file:asset.Asset
    if host.assets_file(a,id,asset.KIND_UI,&file)!=.None {return false}
    defer asset.asset_close(&file)
    data,error:=host.ui_tree_view(&file,&a.types)
    return error==.None && records_load(records,data,allocator)
}

// Where the paths of a widget that start with @ start: the data an
// interface of the project gives one of its instances. Sources: none does.
widget_scope :: proc(u:^Ui_Inspector,a:^host.Assets,info:^core.World_Info) -> Path_Scope {
    if u.widget_scope_id==u.id && u.widget_scope_revision==a.revision && u.widget_scope_info==info {return u.widget_scope}
    u.widget_scope_id,u.widget_scope_revision,u.widget_scope_info=u.id,a.revision,info
    u.widget_scope=widget_scope_of(a,info,u.id)
    return u.widget_scope
}

// Where the @ paths of the .ui id start, as widget_scope says.
widget_scope_of :: proc(a:^host.Assets,info:^core.World_Info,id:base.Asset_Id) -> Path_Scope {
    if a==nil {return {}}
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} || file.id==id {continue}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        for &template,component in records.templates {
            if template.component.widget!=id {continue}
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

// ---------------------------------------------------------------- the rows

// A property a path of the game can take: unbound, the row of its own value,
// which the caller builds when this returns true; bound, the path in place of
// it. The icon after it chooses the path.
@(private,deferred_in_out=bindable_end)
bindable :: proc(p:^Pane,label:string,field:[]u8,kind:Bind_Kind,about:="") -> (free:bool) {
    path:=serial.text_field(field)
    p.bind_open=false
    if !shown_either(p,label,path) {return false}
    p.bind_open=true
    ctx:=p.s.gui.ctx
    ui.id_push(ctx,ui.id(ctx,"bind",int(ui.id(ctx,label)&0x7fffffff)))
    ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,gap=2,align_y=.Center})
    if path=="" {
        ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column})
        return true
    }
    th:=&ctx.theme
    row:=ui.id(ctx,"bound")
    ui.box_begin(ctx,{id=row,width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.Center,track=about!=""})
    ui.column_label(ctx,label)
    editor.row_description(p.s,row,about)
    failing:=bind_failing(p.u,bind_binding(p,field))
    chip:=ui.id(ctx,"path")
    if ui.button(ctx,chip,{label=path_shown(path),icon=.Link,icon_size=12,icon_color=th.danger if failing else th.accent,style=.Field,width=-1,height=th.row,size=th.font_small,padding=6}).clicked {
        bind_pick_open(p,ctx,chip,kind)
    }
    if ui.button(ctx,ui.id(ctx,"unbind"),{icon=.Cross,icon_size=10,icon_color=th.text_muted,tip="Unbind",style=.Ghost,width=editor.REVERT_SIDE,height=editor.REVERT_SIDE}).clicked {
        if n:=selected_node(p.u);n!=nil {node_unbind(n,field)} else {for &b in field {b=0}}
        changed(p.u,"Unbind")
    }
    ui.box_end(ctx,{})
    return false
}
@(private)
bindable_end :: proc(p:^Pane,label:string,field:[]u8,kind:Bind_Kind,about:string,free:bool) {
    if !p.bind_open {return}
    p.bind_open=false
    ctx:=p.s.gui.ctx
    th:=&ctx.theme
    if free {ui.box_end(ctx,{})}
    bound:=serial.text_field(field)!=""
    button:=ui.id(ctx,"pick")
    if ui.button(ctx,button,{icon=.Link,icon_size=13,icon_color=th.accent if bound else th.text_muted,tip="Bind to a field of the game",style=.Ghost,width=th.row,height=th.row,active=ui.popup_is_open(ctx,bind_popup(ctx))}).clicked {
        bind_pick_open(p,ctx,button,kind)
    }
    bind_pick(p,field,kind)
    ui.box_end(ctx,{})
    ui.id_pop(ctx)
}

// Takes a path away from a node: unbound, its visibility is Visible again,
// not what it was while the bool of the game was false.
node_unbind :: proc(n:^ui.Tree_Node,field:[]u8) {
    for &b in field {b=0}
    if raw_data(field)==raw_data(n.bind_visible[:]) {n.flags-={.Invisible,.Collapsed}}
}

// A binding the node has no value of its own for: its row says so until it is bound.
@(private)
bind_only :: proc(p:^Pane,label:string,field:[]u8,kind:Bind_Kind,about:="") -> (changes:bool) {
    if bindable(p,label,field,kind,about) {
        if row(p,label,about) {ui.label(p.s.gui.ctx,"Not bound",p.s.gui.ctx.theme.font_small,p.s.gui.ctx.theme.text_faint)}
    }
    return
}

// Which binding of the node chosen a field is.
@(private)
bind_binding :: proc(p:^Pane,field:[]u8) -> ui.Binding {
    n:=selected_node(p.u)
    if n==nil {return .Text}
    fields:=[ui.Binding][]u8{.Text=n.bind_text[:],.Value=n.bind_value[:],.Visible=n.bind_visible[:],.Selected=n.bind_selected[:],.Disabled=n.bind_disabled[:],
        .Items=n.bind_items[:],.Image=n.bind_image[:],.Tint=n.bind_tint[:],.Variant=n.bind_variant[:]}
    for f,binding in fields {if raw_data(f)==raw_data(field) {return binding}}
    return .Text
}

@(private)
bind_popup :: proc(ctx:^ui.Context) -> ui.Id {return ui.id(ctx,"bind_list")}

@(private)
bind_pick_open :: proc(p:^Pane,ctx:^ui.Context,anchor:ui.Id,kind:Bind_Kind) {
    rect,_:=ui.widget_rect(ctx,anchor)
    p.u.pick_length,p.u.pick_scroll=0,0
    ui.popup_open(ctx,bind_popup(ctx),rect)
}

// The list of the paths a binding can take, from where the node's paths
// start: a click on a source, a struct or an entity goes into it, one on a
// field the binding takes binds it.
@(private)
bind_pick :: proc(p:^Pane,field:[]u8,kind:Bind_Kind) {
    s,u:=p.s,p.u
    ctx:=s.gui.ctx
    th:=&ctx.theme
    popup:=bind_popup(ctx)
    if !ui.popup_is_open(ctx,popup) {return}
    info:=s.app.info
    a:=s.app.assets
    nodes:=scope_nodes(u)
    root,rooted:=node_scope(info,nodes,u.selected)
    data:=widget_scope(u,a,info) if a!=nil else Path_Scope{}
    if ui.popup(ctx,popup,{min_width=280,search="Search",side=.Below}) {
        needle,searched:=ui.popup_search(ctx,popup)
        if searched {u.pick_scroll=0}
        prefix:=string(u.pick_prefix[:u.pick_length])
        if !rooted {
            ui.label(ctx,"Bind the List around it to an array first",th.font_small,th.text_muted)
            return
        }
        scope:=root
        if prefix!="" {
            next,_,ok:=path_walk(info,root,prefix,data)
            if !ok {u.pick_length=0;prefix=""} else {scope=next}
        }
        pick :: proc(p:^Pane,field:[]u8,path:string) {
            ui.tree_text_set(field,path)
            changed(p.u,"Bind")
            ui.popup_close(p.s.gui.ctx)
        }
        if prefix!="" {
            back:=prefix[:max(strings.last_index_byte(prefix,'.'),0)]
            if prefix=="@" || !strings.contains(prefix,".") && !strings.has_prefix(prefix,"@") {back=""}
            if strings.has_prefix(prefix,"@") && !strings.contains(prefix,".") && prefix!="@" {back="@"}
            if ui.row(ctx,ui.id(ctx,"back"),{label=path_shown(prefix),icon=.Chevron_Up,icon_size=11,accent=true,height=th.row}).clicked {
                u.pick_length=copy(u.pick_prefix[:],back)
            }
            if kind==.Data && scope.kind!=.Sources {
                if ui.row(ctx,ui.id(ctx,"use"),{label=fmt.tprintf("Use %s",path_shown(prefix)),icon=.Check,icon_size=11,accent=true,height=th.row}).clicked {pick(p,field,prefix)}
            }
            ui.menu_separator(ctx)
        } else if data.kind!=.Sources {
            if ui.row(ctx,ui.id(ctx,"widget_data"),{label="Data of this widget",icon=.Prefab,icon_size=12,accent=true,height=th.row}).clicked {
                u.pick_length=copy(u.pick_prefix[:],"@")
            }
        }
        if ui.scroll_area(ctx,ui.id(ctx,"bind_rows"),&u.pick_scroll,{width=ui.GROW,height=ui.FIT,max_height=ADD_HEIGHT,direction=.Column}) {
            any:=false
            entries:=path_entries(info,scope,kind)
            leaves :: proc(p:^Pane,field:[]u8,paths:[]string,from:int) -> (picked,any:bool) {
                ctx:=p.s.gui.ctx
                for path,i in paths {
                    any=true
                    if ui.row(ctx,ui.id(ctx,"leaf",from+i+1),{label=path_shown(path),icon=.Link,icon_size=12,icon_color=ctx.theme.accent,accent=true,height=ctx.theme.row}).clicked {
                        ui.tree_text_set(field,path)
                        changed(p.u,"Bind")
                        ui.popup_close(ctx)
                        picked=true
                    }
                }
                return
            }
            if needle!="" {
                // A search finds the paths under this place by any of their names.
                found:=make([dynamic]string,context.temp_allocator)
                path_leaves(info,scope,kind,prefix,needle,&found,PICK_DEPTH)
                _,any=leaves(p,field,found[:],0)
            } else if scope.kind==.Sources && prefix=="" {
                // What the interface already reads comes first, field by field.
                used:=records_sources(&u.records,info)
                found:=make([dynamic]string,context.temp_allocator)
                for &e in entries {
                    if !slice_has(used,e.name) {continue}
                    path_leaves(info,e.next,kind,e.name,"",&found,PICK_DEPTH-1)
                }
                if len(found)>0 {
                    ui.menu_header(ctx,"In this interface")
                    _,any=leaves(p,field,found[:],0)
                }
            }
            // The places to go into that have something it takes: the game's, then the engine's.
            for game in ([2]bool{true,false}) {
                header:=false
                for &e,i in entries {
                    if e.game!=game && scope.kind!=.Struct {continue}
                    if scope.kind==.Struct && !game {break}
                    if needle!="" && !(e.navigable && editor.contains_fold(e.name,needle)) {continue}
                    if !entry_offers(info,&e,kind,PICK_DEPTH) {continue}
                    if !header && scope.kind!=.Struct {
                        if any {ui.menu_separator(ctx)}
                        ui.menu_header(ctx,"Game" if game else "Engine")
                        header=true
                    }
                    any=true
                    icon:=ui.Icon.None
                    switch {
                    case e.storage:                icon=.Layers
                    case scope.kind!=.Struct:      icon=.Cube
                    case e.next.kind==.Entity && e.navigable: icon=.Link
                    case e.navigable:              icon=.Chevron_Right
                    }
                    if ui.row(ctx,ui.id(ctx,"entry",i+1),{label=e.name,detail="storage" if e.storage else "",icon=icon,icon_size=12,icon_color=th.accent if e.fits else th.text_muted,accent=true,height=th.row}).clicked {
                        if e.fits && !(e.navigable && kind==.Data) {pick(p,field,path_join(prefix,e.name))} else if e.navigable {
                            u.pick_length=copy(u.pick_prefix[:],path_join(prefix,e.name))
                            u.pick_scroll=0
                        }
                    }
                }
            }
            if !any {ui.label(ctx,"Nothing here this binding takes",th.font_small,th.text_muted)}
        }
    }
}

@(private)
path_join :: proc(prefix,name:string) -> string {
    if prefix=="" {return name}
    if prefix=="@" {return fmt.tprintf("@%s",name)}
    return fmt.tprintf("%s.%s",prefix,name)
}

@(private)
slice_has :: proc(list:[]string,name:string) -> bool {
    for item in list {if item==name {return true}}
    return false
}

// Whether something under e is a path a binding of kind takes: e itself, or
// a field of the struct it leads to, depth structs down. An entity leads to
// every component, so it offers.
@(private)
entry_offers :: proc(info:^core.World_Info,e:^Path_Entry,kind:Bind_Kind,depth:int) -> bool {
    if e.fits {return true}
    if !e.navigable {return false}
    if e.next.kind==.Entity {return true}
    if depth<=0 {return false}
    for &f in path_entries(info,e.next,kind) {
        if entry_offers(info,&f,kind,depth-1) {return true}
    }
    return false
}

// The paths under scope a binding of kind takes, depth structs down (not
// through entities), each after prefix; with a needle, those that have it.
@(private)
path_leaves :: proc(info:^core.World_Info,scope:Path_Scope,kind:Bind_Kind,prefix,needle:string,list:^[dynamic]string,depth:int) {
    for &e in path_entries(info,scope,kind) {
        if len(list)>=PICK_RESULTS {return}
        if scope.kind==.Entity && e.storage {continue}
        path:=path_join(prefix,e.name)
        if e.fits && editor.contains_fold(path,needle) {append(list,path)}
        if e.navigable && depth>0 && (e.next.kind==.Struct || scope.kind==.Sources) {
            path_leaves(info,e.next,kind,path,needle,list,depth-1)
        }
    }
}

// The paths of a node: its bindings and the data of a widget.
@(private)
node_paths :: proc(n:^ui.Tree_Node) -> [14][]u8 {
    f:=&n.fields
    return {n.bind_text[:],n.bind_value[:],n.bind_visible[:],n.bind_selected[:],n.bind_disabled[:],n.bind_items[:],n.bind_image[:],n.bind_tint[:],n.bind_variant[:],n.data[:],
        f[0].path[:],f[1].path[:],f[2].path[:],f[3].path[:]}
}

// The names in braces of a text, once each, in order: "{coins}", "{time:mm:ss}".
@(private)
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
@(private)
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

// A row under the text for each name in its braces, with the path of the
// game it shows.
@(private)
text_field_rows :: proc(p:^Pane,n:^ui.Tree_Node) {
    ctx:=p.s.gui.ctx
    for name in text_field_names(records_text(&p.u.records,n.text)) {
        label:=strings.concatenate({"{",name,"}"},context.temp_allocator)
        // The name takes a field the first time; nothing changes until a path is chosen.
        at:=text_field_of(&p.u.records,n,name,true)
        if at<0 {
            if row(p,label) {ui.label(ctx,fmt.tprintf("At most %d names",ui.TREE_TEXT_FIELDS),ctx.theme.font_small,ctx.theme.danger)}
            continue
        }
        bind_only(p,label,n.fields[at].path[:],.Shown,"The field of the game this name of the text shows; translations name it as the text does")
    }
}

// The sources the paths of the records start at.
@(private)
records_sources :: proc(r:^Records,info:^core.World_Info) -> []string {
    list:=make([dynamic]string,context.temp_allocator)
    add :: proc(list:^[dynamic]string,info:^core.World_Info,path:string) {
        if path=="" || strings.has_prefix(path,"@") {return}
        name:=path
        if dot:=strings.index_byte(path,'.');dot>=0 {name=path[:dot]}
        if slice_has(list[:],name) {return}
        for &e in path_entries(info,{kind=.Sources},.Data) {
            if e.name==name {append(list,name);return}
        }
    }
    each :: proc(list:^[dynamic]string,info:^core.World_Info,n:^ui.Tree_Node) {
        for field in node_paths(n) {add(list,info,serial.text_field(field))}
    }
    for &n in r.nodes {each(&list,info,&n)}
    for &o in r.overrides {each(&list,info,&o.values)}
    return list[:]
}

// Whether the row of label shows: the search finds its name or the path it
// binds. The card that waited for it opens.
@(private)
shown_either :: proc(p:^Pane,label,path:string) -> bool {
    if p.needle=="" || p.whole {return true}
    if path!="" && editor.contains_fold(path,p.needle) {return shown(p,p.needle)}
    return shown(p,label)
}

// Whether a node takes any path of the game, the fields of its text too.
node_bound :: proc(n:^ui.Tree_Node) -> bool {
    for f in node_paths(n) {if f[0]!=0 {return true}}
    return false
}

// ---------------------------------------------------------------- the API

// Agents bind as a person does: ui.paths lists what a binding of a node takes
// from a prefix, ui.bind sets it, ui.check says what the project's interfaces
// bind that the game does not have, and ui.path.rename follows a field the
// code renamed in every .ui.
@(storage)
Ui_Bind_Api :: struct {provider:editor.Api_Provider}
ui_bind_api_default :: proc() -> Ui_Bind_Api {return {provider={register=bind_api_register}}}

Ui_Paths_Params :: struct {
    asset:base.Asset_Id,
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=Its name; the paths of a node inside a List start at its element"`,
    binding:[16]u8 `mirai:"text,label=Text; Value; Visible; Selected; Disabled; Items; Image; Tint; Variant; or Data: what a widget instance gives its @ paths"`,
    prefix:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=The path walked so far. Empty: the sources (the components of the entity the interface is for and the storages); past a struct its fields; past a field of type Entity the components of that entity"`,
}
Ui_Bind_Params :: struct {
    asset:base.Asset_Id,
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text,label=Its name"`,
    binding:[16]u8 `mirai:"text,label=Text; Value; Visible; Selected; Disabled; Items; Image; Tint; Variant; or Data: what a widget instance gives its @ paths"`,
    path:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=Of the data of the game as Player_Stats.health or Player_Stats.target.Nameplate_Data.health. Inside a List it starts at its element; in a widget @ starts at the data its instances give it (ui.paths lists @ first). Empty: unbinds"`,
    field:[ui.TREE_FIELD_NAME_CAPACITY]u8 `mirai:"text,label=With binding Text: a name in braces of its text that shows the path"`,
}
Ui_Rename_Params :: struct {
    from:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=Each path that is it or starts with it and a dot starts with to instead"`,
    to:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text"`,
}
Ui_Empty_Params :: struct {}

Ui_Paths_Result :: struct {
    scope:Path_Scope_Kind `mirai:"label=What the entries are: the sources; the fields of a struct; or the components of an entity"`,
    entries:[1]Ui_Path_Entry `mirai:"list"`,
}
Ui_Path_Entry :: struct {
    name:[RESULT_TEXT_BYTES]u8 `mirai:"text,label=@ is the data an instance of the widget gives it"`,
    path:[RESULT_TEXT_BYTES]u8 `mirai:"text,label=What prefix and ui.bind take"`,
    type:[RESULT_TEXT_BYTES]u8 `mirai:"text,optional,label=Its type in the game; @ has none"`,
    fits:bool `mirai:"label=Whether the binding takes it"`,
    navigable:bool `mirai:"label=Whether it is a prefix that goes on"`,
    storage:bool `mirai:"optional,label=A storage; absent: a component or a field"`,
}
Ui_Bind_Result :: struct {
    node:[ui.TREE_NAME_CAPACITY]u8 `mirai:"text"`,
    binding:[16]u8 `mirai:"text"`,
    path:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=Empty: unbound"`,
}
Ui_Check_Result :: struct {
    problems:[1]Ui_Check_Problem `mirai:"list,label=Each binding the game lacks once and each .ui that does not load; at most 16 by .ui"`,
}
Ui_Check_Problem :: struct {
    asset:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The name of the file of the .ui"`,
    node:[ui.TREE_NAME_CAPACITY*2]u8 `mirai:"text,label=The node that fails: its name, or instance/node inside a widget; empty when it does not load"`,
    binding:[24]u8 `mirai:"text,label=The binding that fails; Text (in braces) for a name in braces of the text; empty when it does not load"`,
    path:[ui.TREE_PATH_CAPACITY]u8 `mirai:"text,label=What the binding names that the game does not have or cannot show there; empty for a name in braces or when it does not load"`,
    loads:bool `mirai:"label=False: it does not load because a widget it uses is missing or an override names a node its widget no longer has"`,
    message:[RESULT_TEXT_BYTES]u8 `mirai:"text,label=What fails for a person"`,
}
Ui_Rename_Result :: struct {
    files:[1][editor.API_PATH_BYTES]u8 `mirai:"list,text,label=The paths of the .ui it changed; each waits for Save"`,
}

@(private)
bind_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="ui.paths",summary="Lists what a binding of a node of a .ui can take, one level of the data of the game at a time.",params=Ui_Paths_Params,params_info=type_info_of(Ui_Paths_Params),result=Ui_Paths_Result,result_info=type_info_of(Ui_Paths_Result),writes_result=true,flags={.Read_Only},run=api_paths})
    editor.api_method_register(s,{name="ui.bind",summary="Binds a property of a node of a .ui to a path of the data of the game, checked against its types, or unbinds it. One step of history; the file waits for Save.",params=Ui_Bind_Params,params_info=type_info_of(Ui_Bind_Params),result=Ui_Bind_Result,result_info=type_info_of(Ui_Bind_Result),run=api_bind})
    editor.api_method_register(s,{name="ui.check",summary="Checks every .ui of the project against the types of the game of this build: the paths they bind that the game lacks, the names of styles, tokens, components and parameters that resolve to nothing, and each .ui that does not load with why.",params=Ui_Empty_Params,params_info=type_info_of(Ui_Empty_Params),result=Ui_Check_Result,result_info=type_info_of(Ui_Check_Result),writes_result=true,flags={.Read_Only},run=api_check})
    editor.api_method_register(s,{name="ui.path.rename",summary="Follows a field or a source the code renamed in the paths of every .ui: bindings, widget data and the fields of texts. One step of history per file.",params=Ui_Rename_Params,params_info=type_info_of(Ui_Rename_Params),result=Ui_Rename_Result,result_info=type_info_of(Ui_Rename_Result),writes_result=true,run=api_rename})
    texts_api_register(s)
}

@(private)
api_binding :: proc(text:string) -> (binding:ui.Binding,data,ok:bool) {
    if text=="Data" {return .Text,true,true}
    for b in ui.Binding {if fmt.tprintf("%v",b)==text {return b,false,true}}
    return
}

// The records of a .ui and the row of a node of its tree, by its name.
@(private)
api_node :: proc(s:^editor.Session,call:^api.Call,id:base.Asset_Id,name:string,records:^Records) -> (row:int,ok:bool) {
    a:=s.app.assets
    api_flush(s)
    if a==nil || !records_read(a,id,records,context.temp_allocator) {
        api.call_failf(call,api.INVALID_PARAMS,"asset %v is not a .ui that loads; pass the id of a .ui of the project",id)
        return
    }
    for &n,i in records.nodes {if serial.text_field(n.name[:])==name {return i,true}}
    api.call_failf(call,api.INVALID_PARAMS,"the .ui has no node named '%s'; give the name a node of its tree has",name)
    return
}

@(private)
api_paths :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Paths_Params)
    binding,data,known:=api_binding(serial.text_field(p.binding[:]))
    if !known {api.call_fail(call,api.INVALID_PARAMS,"binding is one of Text, Value, Visible, Selected, Disabled, Items, Image, Tint, Variant or Data");return}
    records:Records
    row,ok:=api_node(s,call,p.asset,serial.text_field(p.node[:]),&records)
    if !ok {return}
    info:=s.app.info
    kind:=Bind_Kind.Data if data else bind_kind(binding,records.nodes[row].kind)
    widget:=widget_scope_of(s.app.assets,info,p.asset)
    root,rooted:=node_scope(info,records.nodes[:],row,widget)
    if !rooted {api.call_fail(call,api.INVALID_PARAMS,"the node is inside a List that binds no array: bind its Items first");return}
    prefix:=serial.text_field(p.prefix[:])
    scope:=root
    if prefix!="" {
        next,_,walked:=path_walk(info,root,prefix,widget)
        if !walked || next.kind==.Sources && prefix!="" {api.call_failf(call,api.INVALID_PARAMS,"prefix '%s' is not a source, a struct or an entity of the game; walk it one name at a time from the entries ui.paths gives",prefix);return}
        scope=next
    }
    out:=call.out
    serial.write_u8(out,'{')
    names:=PATH_SCOPE_NAMES
    api.write_text(out,"scope",names[scope.kind],true)
    api.write_key(out,"entries");serial.write_u8(out,'[')
    first:=true
    // What an instance of this widget gives it, which its @ paths read.
    if prefix=="" && widget.kind!=.Sources {
        serial.text_write_raw(out,`{"name":"@","path":"@","fits":`)
        serial.text_write_raw(out,"true" if type_fits(widget.info,kind) else "false")
        serial.text_write_raw(out,`,"navigable":true}`)
        first=false
    }
    for &e in path_entries(info,scope,kind) {
        if !e.navigable && !e.fits {continue}
        if !first {serial.write_u8(out,',')};first=false
        serial.write_u8(out,'{')
        api.write_text(out,"name",e.name,true)
        api.write_text(out,"path",path_join(prefix,e.name))
        api.write_text(out,"type",fmt.tprintf("%v",e.info.id))
        api.write_bool(out,"fits",e.fits)
        api.write_bool(out,"navigable",e.navigable)
        if e.storage {api.write_bool(out,"storage",true)}
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_bind :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Bind_Params)
    binding,data,known:=api_binding(serial.text_field(p.binding[:]))
    if !known {api.call_fail(call,api.INVALID_PARAMS,"binding is one of Text, Value, Visible, Selected, Disabled, Items, Image, Tint, Variant or Data");return}
    records:Records
    row,ok:=api_node(s,call,p.asset,serial.text_field(p.node[:]),&records)
    if !ok {return}
    n:=&records.nodes[row]
    info:=s.app.info
    path:=serial.text_field(p.path[:])
    if path!="" {
        kind:=Bind_Kind.Data if data else bind_kind(binding,n.kind)
        widget:=widget_scope_of(s.app.assets,info,p.asset)
        root,rooted:=node_scope(info,records.nodes[:],row,widget)
        _,leaf,walked:=path_walk(info,root,path,widget)
        if !rooted || !walked || !type_fits(leaf,kind) {
            takes:=BIND_KIND_TAKES
            api.call_failf(call,api.INVALID_PARAMS,"the game has no '%s' that fits this node: this binding takes %s; list what fits with ui.paths",path,takes[kind])
            return
        }
    }
    field:=serial.text_field(p.field[:])
    switch {
    case data:
        if n.kind!=.Component {api.call_fail(call,api.INVALID_PARAMS,"Data is what a widget instance gives its @ paths: the node is not one");return}
        ui.tree_text_set(n.data[:],path)
    case field!="":
        if binding!=.Text || !slice_has(text_field_names(records_text(&records,n.text)),field) {api.call_failf(call,api.INVALID_PARAMS,"field names a name in braces of the text of the node, with binding Text: its text has no {%s}",field);return}
        at:=text_field_of(&records,n,field,true)
        if at<0 {api.call_failf(call,api.INVALID_PARAMS,"a text shows at most %d names in braces",ui.TREE_TEXT_FIELDS);return}
        ui.tree_text_set(n.fields[at].path[:],path)
    case:
        fields:=[ui.Binding][]u8{.Text=n.bind_text[:],.Value=n.bind_value[:],.Visible=n.bind_visible[:],.Selected=n.bind_selected[:],.Disabled=n.bind_disabled[:],
            .Items=n.bind_items[:],.Image=n.bind_image[:],.Tint=n.bind_tint[:],.Variant=n.bind_variant[:]}
        if path=="" {node_unbind(n,fields[binding])} else {ui.tree_text_set(fields[binding],path)}
    }
    message,written:=records_write(s,p.asset,&records,fmt.tprintf("Bind %v",binding))
    if !written {api.call_fail(call,api.INVALID_PARAMS,message);return}
    api.call_result(call,Ui_Bind_Result)^={node=p.node,binding=p.binding,path=p.path}
}

// Writes records as a step of the history of the document of their .ui. A
// tree the game would not load is not written: message says why.
@(private)
records_write :: proc(s:^editor.Session,id:base.Asset_Id,records:^Records,label:string) -> (message:string,ok:bool) {
    a:=s.app.assets
    api_flush(s)
    record,found:=asset.registry_find(&a.registry,id)
    if !found {return "the .ui is not in the assets",false}
    path:=asset.registry_file_path(&a.registry,record.path,context.temp_allocator)
    records_tidy(records)
    imports,imported:=records_settle(records,a)
    if !imported {return WIDGET_MISSING,false}
    data:=records_data(records)
    bytes,error:=host.ui_tree_bytes(&a.types,id,data,imports,context.temp_allocator)
    if error==.Invalid {return fmt.tprintf("the interface would not load: %s",load_why(a,data,imports)),false}
    if error!=.None {return fmt.tprintf("the interface could not be written: %v",error),false}
    written,opened:=false,false
    for &d in s.asset_documents {
        if d.id!=id || d.kind!=asset.KIND_UI {continue}
        written,opened=editor.asset_document_write(s,&d,path,bytes,label),true
        break
    }
    if !opened {written=editor.file_write(s,path,bytes,label)}
    if !written {return "the file could not be written",false}
    return "",true
}

@(private)
api_check :: proc(s:^editor.Session,call:^api.Call) {
    a:=s.app.assets
    if a==nil || s.app.info==nil {api.call_fail(call,api.SERVER_ERROR,"the editor has no world or assets to check against");return}
    types:Bind_Types
    defer bind_types_free(&types)
    problems:=make([dynamic]Bind_Problem,context.temp_allocator)
    bind_check_all(&problems,&types,context.allocator,a,s.app.info)
    out:=call.out
    serial.text_write_raw(out,`{"problems":[`)
    for &problem,i in problems {
        if i>0 {serial.write_u8(out,',')}
        serial.write_u8(out,'{')
        api.write_text(out,"asset",editor.asset_name_of(a,problem.asset,"missing"),true)
        api.write_text(out,"node",serial.text_field(problem.name[:]))
        api.write_text(out,"binding","Text (in braces)" if problem.fault==.Template else fmt.tprintf("%v",problem.binding) if problem.fault==.Path else "")
        api.write_text(out,"path",serial.text_field(problem.path[:]) if problem.fault==.Path else "")
        api.write_bool(out,"loads",problem.fault!=.Widget && problem.fault!=.Load)
        api.write_text(out,"message",bind_problem_text(a,&problem))
        serial.write_u8(out,'}')
    }
    serial.text_write_raw(out,"]}")
}

@(private)
api_rename :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Ui_Rename_Params)
    api_flush(s)
    from,to:=serial.text_field(p.from[:]),serial.text_field(p.to[:])
    if from=="" || to=="" {api.call_fail(call,api.INVALID_PARAMS,"from and to are paths: Old_Name.field and New_Name.field");return}
    a:=s.app.assets
    if a==nil {api.call_fail(call,api.SERVER_ERROR,"the editor has no assets");return}
    out:=call.out
    serial.text_write_raw(out,`{"files":[`)
    first:=true
    for &file in a.registry.files {
        if file.kind!=asset.KIND_UI || file.id=={} {continue}
        records:Records
        if !records_read(a,file.id,&records,context.temp_allocator) {continue}
        count:=0
        rename :: proc(field:[]u8,from,to:string) -> int {
            path:=serial.text_field(field)
            if path!=from && !strings.has_prefix(path,fmt.tprintf("%s.",from)) {return 0}
            renamed:=fmt.tprintf("%s%s",to,path[len(from):])
            if len(renamed)>=len(field) {return 0}
            ui.tree_text_set(field,renamed)
            return 1
        }
        each :: proc(n:^ui.Tree_Node,from,to:string) -> int {
            count:=0
            for f in node_paths(n) {count+=rename(f,from,to)}
            return count
        }
        for &n in records.nodes {count+=each(&n,from,to)}
        for &template in records.templates {for &n in template.nodes {count+=each(&n,from,to)}}
        for &o in records.overrides {count+=each(&o.values,from,to)}
        if count==0 {continue}
        if _,written:=records_write(s,file.id,&records,"Rename path");!written {continue}
        if !first {serial.write_u8(out,',')};first=false
        serial.text_write_string(out,file.path)
    }
    serial.text_write_raw(out,"]}")
}

