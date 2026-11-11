package build

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "mirai:asset"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The world of a project, generated from the attributes of its packages:
//
//   @(component) @(component,shared) @(component,locks="core.Transform")
//   @(component,replicated) @(component,replicated="owner") @(component,replicated="others")
//   @(component,replicated="object")
//   @(storage) @(storage,host) @(storage,setting) @(storage,setting="machine")
//   @(storage,queue) @(storage,shared) @(storage,keep)
//   @(storage,copy="state_copy") @(storage,free="state_free") @(storage,reset="state_reset")
//   @(step="fixed late",loops="game editor",stage="end",after="a b",before="c",server)
//   @(net_message) @(net_message,from="client",reliable) @(net_message,from="owner")
//   @(params) @(names) @(name_bits="T") @(name="...") @(actions)
//   @(draw="minimap")
//   @(mind="zombie") on a think procedure, @(act="Chase Circle") on an action of its enum
//
// The engine's libraries (core, engine/*), the runtime/ of the active plugins
// and the game/ of the project go into World and Shared; the editor and the
// editor/ of plugins and of the project into Editor_World.

CUSTOM_ATTRIBUTES :: "component,storage,step,loops,stage,after,before,server,shared,locks,host,by_world,copy,copy_kept,swap,free,replicated,setting,description,queue,keep,persist,single,far,derived,reset,net_message,from,reliable,params,names,name_bits,name,name_requires,presentation,record,actions,draw,mind,act,was,test_world,editor"

PHASES :: [7]string{"input","fixed","frame","late","ui","render","release"}
UI_PHASE :: 4 // where the interfaces are built: the engine and the editor draw in it, a game shows .ui documents
PHASE_TITLES :: [len(PHASES)]string{"Input","Fixed","Frame","Late","Ui","Render","Release"}
FIXED_PHASE :: 1
RELEASE_PHASE :: 6 // runs when a World is freed: from the game loop, never in a frame
LOOPS :: [2]string{"game","editor"}
// Every phase runs its steps by stage, in this order; a step that names none is in intent.
STAGES :: [7]string{"begin","input","intent","apply","simulate","react","end"}
STAGE_DEFAULT :: 2

@(private="file")
Package :: struct {
    path:string,   // import path: mirai:engine/render
    folder:string,
    name:string,   // declared
    alias:string,  // in the generated file
    editor:bool,
    plugin:int,    // into the plugins of the project; -1: not of a plugin
    used:bool,     // declares a type or a step
    files:[]^ast.File,
    names:map[string]bool, // what the package declares: where the defaults of its components are found
}

@(private="file")
Kind :: enum u8 {Component,Storage}


@(private="file")
Type :: struct {
    key:string, // path.Name
    name:string,
    pkg:^Package,
    kind:Kind,
    using declared:core.Declared,
    fields:[dynamic]core.Field_Description, // a component: the comments on the lines of its fields
    locks:[dynamic]string, // keys, resolved later
    logs:[dynamic]string,  // a storage: its fields that are a core.Events
    field:string,
    lock_id:int,
    default,for_device,procs:string, // the procedures the world being written calls for it: type_procs_write
    file:^ast.File,   // where it is declared
    value:^ast.Expr,  // its struct
    where_:string,    // its file and line, for an error
}

// A struct of game data, @(record): the row of the tables of .records assets.
@(private="file")
Record_Type :: struct {
    key,name:string,
    pkg:^Package,
    description:string,
    fields:[dynamic]core.Field_Description, // the comments on the lines of its fields
    file:^ast.File,
    value:^ast.Expr,
    where_:string,
}

// A structure the network sends, @(net_message).
@(private="file")
Message :: struct {
    name:string,
    pkg:^Package,
    from:core.Message_From,
    reliable:bool,
}

@(private="file")
Param_Kind :: enum u8 {Table_Write,Table_Read,Storage_Write,Storage_Ref,Storage_Value,Storage_Stamp,Entities_Read,Commands,World_Ref,App,App_Part,Records,Inbox}

// What host.App holds that a step receives by itself, bound by the type that
// names it: the call hands out what the application owns.
@(private="file")
App_Part :: struct {
    key:string,   // the type as a file names it: import path and name
    form:string,  // how a step receives it
    value:string, // in the generated call, from app
}

@(private="file")
APP_PARTS :: [?]App_Part{
    {"mirai:host.Assets","^host.Assets","app.assets"},
    {"mirai:host.Frame_Extras","^host.Frame_Extras","&app.extras"},
    {"mirai:render.Renderer","^render.Renderer","app.renderer"},
    {"mirai:engine/render.Renderer","^render.Renderer","app.renderer"},
    {"mirai:audio.Mixer","^audio.Mixer","app.mixer"},
    {"mirai:engine/audio.Mixer","^audio.Mixer","app.mixer"},
    {"mirai:std/jobs.Job_System","^jobs.Job_System","&app.jobs"},
    {"base:runtime.Allocator","runtime.Allocator","app.allocator"},
    {"core:mem.Allocator","mem.Allocator","app.allocator"},
    {"mirai:core.Texts","^core.Texts","host.app_texts(app)"},
}

@(private="file")
PARAM_FORMS :: "^core.Table(T), ^core.Table(T,.Read), ^S, core.Ref(S), S, core.Stamp(S), core.Inbox(M) of a @(net_message), core.Ref(core.Entities), core.Commands, core.World_Ref, a part of the application (^host.Assets, ^host.Frame_Extras, ^render.Renderer, ^audio.Mixer, ^jobs.Job_System, runtime.Allocator, ^core.Texts) or ^host.App"

@(private="file")
Param :: struct {
    kind:Param_Kind,
    type:^Type,
    record:^Record_Type, // Records
    message:int,         // Inbox: its index in messages
    part:int,            // App_Part: its index in APP_PARTS
    actions:^Action_Enum, // the enum of the generic @(params) it is a field of
    bundle:^Bundle, // the @(params) the step receives it in; nil when it receives it by itself
    name:string,    // of the field in the bundle, or of the parameter
    arg:int,        // the parameter of the step it binds, by position
}

// A struct whose fields are parameters of a step, @(params): a step receives
// it by value and each field is bound as that parameter alone would be.
@(private="file")
Bundle :: struct {
    key,name:string,
    pkg:^Package,
    file:^ast.File,
    record:^ast.Struct_Type,
    where_:string,
    fields:[dynamic]Param,
    valid:bool,
    generic:bool,      // struct($E:typeid): received for an @(actions) enum, B(E)
    base_field:string, // of a generic one: the field of the @(names,actions) type, which takes the base of E
}

// A distinct integer whose constants are its values with names, @(names), or
// a mask whose bits are the values of one, @(name_bits).
@(private="file")
Named_Type :: struct {
    key,name:string,
    pkg:^Package,
    prefix:string,  // taken off the identifiers of its constants
    bits_of:string, // @(name_bits): the key of the type of its bits
    bits:int,       // of its integer; 0: not known here
    actions:bool,   // @(names,actions): its values are the members of the @(actions) enums
    where_:string,
}

// An enum @(actions): the actions of a library. Its members are values of
// the @(names,actions) type from base on, the libraries one after the other.
@(private="file")
Action_Enum :: struct {
    key,name:string,
    pkg:^Package,
    members:[dynamic]Action_Member,
    base:int,
    file:string, // full path
    where_:string,
}

@(private="file")
Action_Member :: struct {ident:string,line:int}

// A constant whose type may have names: kept until every type is read.
@(private="file")
Named_Value :: struct {
    type_key,ident,name:string,
    type:^Named_Type,
    pkg:^Package,
    file:string, // relative to the project, or to the engine for its packages and plugins
    line:int,
    explicit:bool, // @(name="...")
    requires:string, // @(name_requires="C"): the key of the component an entity needs to take this value
    requires_type:^Type,
    action:^Action_Enum, // a member of an @(actions) enum, whose value is number
    number:int,
    where_:string,
}

@(private="file")
Step :: struct {
    name:string,
    pkg:^Package,
    phases:[len(PHASES)]bool,
    loops:[2]bool,
    stage:int,
    after,before:[dynamic]string,
    server:bool, // runs only where the rules are decided: core.Network.role is not .Client
    params:[dynamic]Param,
    rank:int, // libraries, then declarations
    where_:string,
    file:string,
    line:int,
    mind:^Mind_Step, // the step of a mind: it ticks the agents of the mind instead of calling a procedure
}

// A @(mind="name") think procedure or a @(act="Value ...") action, as read.
@(private="file")
Mind_Decl :: struct {
    name,text,where_:string, // text: the name of the mind, or the values the action runs
    file:^ast.File,
    literal:^ast.Proc_Lit, // nil: not a procedure
    line:int,
    private:bool,
}

// A mind: its step ticks its agents with behavior.minds_tick, in a context
// that begins with Mind_World (arg 0) and holds each other arg of the step.
@(private="file")
Mind_Step :: struct {
    name,enum_name:string, // enum_name: of its actions, in the package of the step
    runner:^Bundle,        // Mind_World
    think:Mind_Proc,
    acts:[dynamic]Mind_Proc, // in the order of the enum
}

// A procedure of a mind and the args of the step it receives after its first parameter.
@(private="file")
Mind_Proc :: struct {
    ident,value:string, // value: the member of the enum an action runs
    args:[dynamic]int,
}

// A procedure of the game that draws the Draw nodes of the interfaces that
// name it, @(draw="name").
@(private="file")
Draw_Proc :: struct {
    name,ident:string,
    pkg:^Package,
    where_:string,
}

@(private="file")
Generator :: struct {
    packages:[dynamic]^Package,
    types:[dynamic]^Type,
    messages:[dynamic]Message,
    by_key:map[string]^Type,
    bundles:map[string]^Bundle,
    bundle_list:[dynamic]^Bundle, // in the order they are declared
    named_types:map[string]^Named_Type,
    named_type_list:[dynamic]^Named_Type,
    named_values:[dynamic]Named_Value, // the constants of named types, once names_settle kept them
    action_enums:[dynamic]^Action_Enum, // in the order of the libraries
    action_by_key:map[string]^Action_Enum,
    actions_type:^Named_Type, // the @(names,actions) type
    records:[dynamic]^Record_Type,
    record_by_key:map[string]^Record_Type,
    steps:[dynamic]^Step,
    mind_names:map[string]string, // the think procedure of each mind, by its name
    draws:[dynamic]Draw_Proc,
    errors:[dynamic]string,
    engine_root,root:string,
}

// The editor is built from editor_world; the game that ships from
// shipped_world, game_world (the world without an editor package) without the
// development plugins. The editor is the library the editor and the player
// load; game is the program that ships, with the engine in it.
Generated :: struct {
    game_world,editor_world,shipped_world,editor_main,game_main:string,
    errors:[]string,
    machine_settings:[]string, // the names of the @(storage,setting="machine"): the sections the file of the engine gives a shipped game
}

// The packages of a project, read: what each declares, before anything is settled.
@(private="file")
generator_read :: proc(p:^project.Project) -> (g:Generator) {
    g.by_key=make(map[string]^Type)
    g.bundles=make(map[string]^Bundle)
    g.named_types=make(map[string]^Named_Type)
    g.action_by_key=make(map[string]^Action_Enum)
    g.record_by_key=make(map[string]^Record_Type)
    g.engine_root,g.root=p.engine_root,p.root
    packages_find(&g,p)
    for pkg in g.packages {package_read(&g,pkg)}
    return
}

// The source of the world packages and of the main packages. The world of
// the game that ships is generated only when shipped is asked for.
world_generate :: proc(p:^project.Project,allocator:=context.allocator,shipped:=false) -> (out:Generated) {
    context.allocator=allocator
    g:=generator_read(p)
    for pkg in g.packages {
        if pkg.plugin>=0 {plugin_imports_check(p.plugins,pkg.plugin,pkg.files,&g.errors)}
    }
    types_settle(&g)
    names_settle(&g)
    bundles_settle(&g)
    for pkg in g.packages {steps_read(&g,pkg)}
    for pkg in g.packages {draws_read(&g,pkg)}
    rules_check(&g)
    defaults_check(&g)
    asset_paths_check(&g,p)
    out.errors=g.errors[:]
    if len(g.errors)>0 {return}
    out.game_world=world_write(&g,false)
    out.editor_world=world_write(&g,true)
    out.shipped_world=out.game_world
    // Without the development plugins the world of the game that ships is generated again.
    kept:=make([dynamic]int,context.temp_allocator)
    for index in p.active {
        if !p.plugins[index].manifest.development {append(&kept,index)}
    }
    if shipped && len(kept)<len(p.active) {
        q:=p^
        q.active=kept[:]
        out.shipped_world=world_generate_world(&q)
    }
    out.editor_main=library_entry("editor_world")
    machine:=make([dynamic]string)
    for t in g.types {
        if t.setting==.Machine {append(&machine,t.name)}
    }
    out.machine_settings=machine[:]
    out.game_main="// Generated by mirai. Do not edit.\npackage main\n\nimport \"core:os\"\nimport \"mirai:host\"\nimport world \"generated:shipped_world\"\n\nmain :: proc() {\n    info:=world.info()\n    root,_:=os.get_executable_directory(context.allocator)\n    os.exit(host.player_run(&info,root,\"\",os.args[1:]))\n}\n"
    return
}

// The game world of a project, for the world of the game that ships.
@(private="file")
world_generate_world :: proc(p:^project.Project) -> string {
    g:=generator_read(p)
    types_settle(&g)
    names_settle(&g)
    bundles_settle(&g)
    for pkg in g.packages {steps_read(&g,pkg)}
    rules_check(&g)
    return world_write(&g,false)
}

// The package a library of the project is built from: what the editor or the
// player asks it for when they load it.
@(private="file")
library_entry :: proc(world_package:string) -> string {
    return fmt.aprintf("// Generated by mirai. Do not edit.\npackage mirai_project\n\nimport \"mirai:core\"\nimport world \"generated:%s\"\n\n@(export,link_name=%q)\nproject_info :: proc() -> core.World_Info {{return world.info()}}\n",world_package,PROJECT_INFO_SYMBOL)
}

// The actions the game world of a project declares, each name with its
// number: for a tool that writes actions in data without a world of the
// project, to look a member up by its name and to give the schema it writes
// with the names that data keeps (serial.Named, by_name).
world_actions :: proc(p:^project.Project,allocator:=context.allocator) -> (actions:[]serial.Choice,errors:[]string) {
    context.allocator=allocator
    g:=generator_read(p)
    names_settle(&g)
    found:=make([dynamic]serial.Choice)
    for value in g.named_values {
        if value.action!=nil {append(&found,serial.Choice{value.name,i64(value.number)})}
    }
    return found[:],g.errors[:]
}

// The procedure a library of a project exports: it returns the core.World_Info of its world.
PROJECT_INFO_SYMBOL :: "mirai_project_info"

// Writes the generated packages under <project>/.mirai/gen when they changed.
// out has what was generated, in the temp allocator.
world_write_files :: proc(p:^project.Project,shipped:=false) -> (out:Generated,ok:bool) {
    if out.errors=kinds_write(p);len(out.errors)>0 {return}
    out=world_generate(p,context.temp_allocator,shipped)
    if len(out.errors)>0 {return}
    gen:=project.path(project.folder_path(p.root,.Generated,context.temp_allocator),"gen",allocator=context.temp_allocator)
    files:=[4][2]string{{"editor_world/world.odin",out.editor_world},{"shipped_world/world.odin",out.shipped_world},{"editor/main.odin",out.editor_main},{"game/main.odin",out.game_main}}
    for f in files {
        if f[0]=="shipped_world/world.odin" && !shipped {continue}
        file:=project.path(gen,f[0],allocator=context.temp_allocator)
        if current,error:=os.read_entire_file(file,context.temp_allocator);error==nil && string(current)==f[1] {continue}
        folder:=file[:strings.last_index_byte(file,'/')]
        if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return}
        if os.write_entire_file(file,f[1])!=nil {return}
    }
    return out,true
}

@(private="file")
packages_find :: proc(g:^Generator,p:^project.Project) {
    add_tree :: proc(g:^Generator,folder,path:string,editor:bool,plugin:=-1) {
        if !os.is_dir(folder) {return}
        if has_sources(folder) {
            pkg:=new(Package)
            pkg.folder,pkg.path,pkg.editor,pkg.plugin=folder,path,editor,plugin
            append(&g.packages,pkg)
        }
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {return}
        slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
        for entry in entries {
            if strings.has_prefix(entry.name,".") || entry.name=="testdata" || !os.is_dir(entry.fullpath) {continue}
            add_tree(g,project.path(folder,entry.name),fmt.aprintf("%s/%s",path,entry.name),editor,plugin)
        }
    }
    e:=p.engine_root
    add_tree(g,project.path(e,"core"),"mirai:core",false)
    // The components of prefab instances are declared where a document holds them.
    add_tree(g,project.path(e,"asset"),"mirai:asset",false)
    add_tree(g,project.path(e,"engine"),"mirai:engine",false)
    names:=project.FOLDER_NAMES
    parts:=project.PART_NAMES
    for index in p.active {
        plugin:=&p.plugins[index]
        name:=base.text_get(plugin.manifest.name[:])
        add_tree(g,project.path(plugin.folder,parts[.Runtime]),plugin_import(p.root,plugin,name,parts[.Runtime]),false,index)
    }
    add_tree(g,project.path(p.root,names[.Game]),fmt.aprintf("project:%s",names[.Game]),false)
    add_tree(g,project.path(e,"editor"),"mirai:editor",true)
    for index in p.active {
        plugin:=&p.plugins[index]
        name:=base.text_get(plugin.manifest.name[:])
        add_tree(g,project.path(plugin.folder,parts[.Editor]),plugin_import(p.root,plugin,name,parts[.Editor]),true,index)
    }
    add_tree(g,project.path(p.root,names[.Editor]),fmt.aprintf("project:%s",names[.Editor]),true)
}

// How a part of a plugin is imported: plugins:<name>/<part> for one of the
// engine; project:<its folder in the project>/<part> for one of the project:
// plugins/<name>, or plugins/<plugin>/plugins/<name> for a companion.
plugin_import :: proc(root:string,plugin:^project.Plugin,name,part:string,allocator:=context.allocator) -> string {
    if plugin.origin==.Engine {return fmt.aprintf("plugins:%s/%s",name,part,allocator=allocator)}
    folder:=strings.trim_prefix(strings.trim_prefix(plugin.folder,root),"/")
    return fmt.aprintf("project:%s/%s",folder,part,allocator=allocator)
}

// A plugin imports only itself and what it depends on, and its tests also what
// they depend on: what it does not name in its plugin.mirai is not active with
// it. Each import of the files of a package of the plugin at index that
// reaches another goes to errors, with what to declare.
plugin_imports_check :: proc(plugins:[]project.Plugin,index:int,files:[]^ast.File,errors:^[dynamic]string) {
    for file in files {
        tests:=strings.has_suffix(file.fullpath,"_test.odin")
        for decl in file.imports {
            imported:=strings.trim(decl.fullpath,"\"`")
            other:=project.import_plugin(imported)
            if other=="" || project.plugin_reaches(plugins,index,other,tests) {continue}
            append(errors,fmt.aprintf("%s(%d:%d): imports %s, a plugin %s does not depend on; add %q to the %s of its plugin.mirai, or take the import out",file.fullpath,decl.pos.line,decl.pos.column,imported,base.text_get(plugins[index].manifest.name[:]),other,tests?"test_dependencies":"dependencies"))
        }
    }
}

@(private="file")
has_sources :: proc(folder:string) -> bool {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        if entry.type!=.Directory && strings.has_suffix(entry.name,".odin") && !strings.has_suffix(entry.name,"_test.odin") {return true}
    }
    return false
}

// Reads and parses the sources of a package folder, its tests only when asked, and returns its
// name and its files in path order. Each problem goes to errors naming the file and the position, as the
// compiler does. Not parser.parse_package: it reads the package clause of a file that failed to
// parse, which a file without one leaves nil.
sources_read :: proc(folder:string,errors:^[dynamic]string,allocator:=context.allocator,tests:=false) -> (name:string,files:[]^ast.File,ok:bool) {
    collected,collected_ok:=parser.collect_package(folder)
    if !collected_ok {
        append(errors,fmt.aprintf("%s: the package could not be read",folder))
        return
    }
    sorted:=make([dynamic]^ast.File,0,len(collected.files),allocator)
    for path,file in collected.files {
        if (tests || !strings.has_suffix(path,"_test.odin")) && !strings.has_suffix(path,TEST_WORLDS_FILE) {append(&sorted,file)}
    }
    slice.sort_by(sorted[:],proc(a,b:^ast.File) -> bool {return a.fullpath<b.fullpath})
    p:=parser.default_parser()
    // The handler takes no data of its own: it finds the problem through the context it is called in.
    problem:string
    context.user_ptr=&problem
    p.err=proc(pos:tokenizer.Pos,format:string,args:..any) {
        problem:=(^string)(context.user_ptr)
        if problem^=="" {problem^=fmt.aprintf("%s(%d:%d): %s",pos.file,pos.line,pos.column,fmt.tprintf(format,..args))}
    }
    ok=true
    for file in sorted {
        problem=""
        if !parser.parse_file(&p,file) {
            append(errors,problem!="" ? problem : fmt.aprintf("%s: the file does not parse",file.fullpath))
            ok=false
            continue
        }
        if name=="" {name=file.pkg_name}
        else if file.pkg_name!=name {
            append(errors,fmt.aprintf("%s(%d:%d): package %s, while its folder is package %s",file.fullpath,file.pkg_decl.pos.line,file.pkg_decl.pos.column,file.pkg_name,name))
            ok=false
        }
    }
    return name,sorted[:],ok
}

@(private="file")
package_sources :: proc(g:^Generator,pkg:^Package,tests:bool) -> (ok:bool) {
    pkg.name,pkg.files=sources_read(pkg.folder,&g.errors,tests=tests) or_return
    pkg.names=make(map[string]bool)
    for file in pkg.files {
        for stmt in file.decls {
            if decl,is_value:=stmt.derived.(^ast.Value_Decl);is_value && len(decl.names)==1 && len(decl.values)==1 {pkg.names[ident_name(decl.names[0])]=true}
        }
    }
    return true
}

@(private="file")
package_read :: proc(g:^Generator,pkg:^Package) {
    if !package_sources(g,pkg,false) {return}
    for file in pkg.files {
        for stmt in file.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
            name:=ident_name(decl.names[0])
            field_tags_check(g,file,name,decl.values[0])
            options:=attributes_read(decl.attributes[:])
            _,is_names:=options["names"]
            _,is_bits:=options["name_bits"]
            if is_names || is_bits {
                named_type_read(g,file,pkg,decl,name,options)
                continue
            }
            if _,is_actions:=options["actions"];is_actions {
                action_enum_read(g,file,pkg,decl,name)
                continue
            }
            if !decl.is_mutable {named_value_read(g,file,pkg,decl,name,options)}
            _,is_component:=options["component"]
            _,is_storage:=options["storage"]
            _,is_message:=options["net_message"]
            _,is_bundle:=options["params"]
            if _,is_record:=options["record"];is_record {
                record_read(g,file,pkg,decl,name,options,is_component || is_storage || is_message || is_bundle)
                continue
            }
            if is_bundle {
                bundle_read(g,file,pkg,decl,name,is_component || is_storage || is_message)
                continue
            }
            if is_message {
                message_read(g,pkg,name,options,is_component || is_storage)
                continue
            }
            if !is_component && !is_storage {continue}
            t:=type_read(g,file,pkg,decl,name,options,pkg.editor)
            if t==nil {continue}
            if t.key in g.by_key {
                append(&g.errors,fmt.aprintf("%s: %s is declared twice",t.where_,name))
                continue
            }
            g.by_key[t.key]=t
            append(&g.types,t)
            pkg.used=true
        }
    }
}

// What the attributes of a declaration @(component) or @(storage) say of its
// type, checked: nil, with the error said, for what no world holds. editor:
// the type is of the editor.
@(private="file")
type_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,decl:^ast.Value_Decl,name:string,options:map[string]string,editor:bool) -> ^Type {
    _,is_component:=options["component"]
    _,is_storage:=options["storage"]
    t:=new(Type)
    t.name,t.pkg=name,pkg
    t.file,t.value=file,decl.values[0]
    t.where_=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
    t.key=fmt.aprintf("%s.%s",pkg.path,name)
    t.kind=is_component?.Component:.Storage
    switch core.declared_read(&t.declared,options,editor) {
    case "replicated":
        append(&g.errors,fmt.aprintf("%s: %s has replicated=%q: write @(component,replicated) for every end that has the entity, replicated=\"owner\" for its owner, replicated=\"others\" for the rest or replicated=\"object\" for every end of an entity it replicates by itself",t.where_,name,options["replicated"]))
        return nil
    case "setting":
        append(&g.errors,fmt.aprintf("%s: %s has setting=%q, which is not a kind of setting: write @(storage,setting) for a setting of the project or @(storage,setting=\"machine\") for a preference of whoever uses the engine on this machine",t.where_,name,options["setting"]))
        return nil
    }
    if t.replication!=.None && !is_component {
        append(&g.errors,fmt.aprintf("%s: %s is a storage and says replicated: the network replicates components of entities; make it a @(component,replicated), or send it as a @(net_message)",t.where_,name))
        return nil
    }
    if _,scene:=options["scene"];scene {
        append(&g.errors,fmt.aprintf("%s: %s says scene: a setting of the scene is a component on an entity of the root scene, which saves, replicates and changes while the game runs; make it a @(component), with single if the world uses one at a time",t.where_,name))
        return nil
    }
    if t.single && !is_component {
        append(&g.errors,fmt.aprintf("%s: %s says single, which is of a component the world uses one of at a time: write @(component,single)",t.where_,name))
        return nil
    }
    if t.far && !is_component {
        append(&g.errors,fmt.aprintf("%s: %s says far, which is of a component whose entity draws a far form of its own and stays when its section unloads: write @(component,far)",t.where_,name))
        return nil
    }
    if _,old:=options["events"];old {
        append(&g.errors,fmt.aprintf("%s: %s says events, which is no option: what a library reports is a field core.Events(T) of a @(storage), which its owner pushes to and never clears; take events out and make its core.Queue(T) a core.Events(T)",t.where_,name))
        return nil
    }
    if record,is_struct:=decl.values[0].derived.(^ast.Struct_Type);is_struct && is_storage {
        for field in record.fields.list {
            call,is_call:=field.type.derived.(^ast.Call_Expr)
            if !is_call || type_key(g,file,pkg,call.expr)!="mirai:core.Events" {continue}
            for n in field.names {append(&t.logs,ident_name(n))}
        }
    }
    if t.queue && (t.kind!=.Storage || len(t.logs)>0) {
        append(&g.errors,fmt.aprintf("%s: %s says queue: a storage of requests is @(storage,queue), and it holds no core.Events, which are what a library reports",t.where_,name))
        return nil
    }
    if t.kind==.Component {field_comments(&t.fields,decl.values[0])}
    for lock in strings.fields(t.lock_names) {append(&t.locks,qualified(g,file,pkg,lock))}
    if t.setting!=.None && (t.kind!=.Storage || t.place==.Editor) {
        append(&g.errors,fmt.aprintf("%s: %s is a setting: mark it @(storage,setting) or @(storage,setting=\"machine\") in a library",t.where_,name))
        return nil
    }
    if t.by_world && (t.kind!=.Storage || t.place!=.Shared || t.setting!=.None) {
        append(&g.errors,fmt.aprintf("%s: %s is by_world: a storage of the application with a value for each World is @(storage,host,by_world) in a library, and is not a setting",t.where_,name))
        return nil
    }
    if t.persist && (t.kind!=.Storage || t.place!=.World || t.queue || len(t.logs)>0 || t.setting!=.None || t.copy=="false" || t.reset!="") {
        append(&g.errors,fmt.aprintf("%s: %s says persist: the progress of the player is a plain @(storage,persist) of a library; not a component, a storage of the application, a queue, events, a setting, nor one that resets or is not copied",t.where_,name))
        return nil
    }
    if t.copy_kept!="" && (t.kind!=.Storage || t.place!=.World || t.copy=="false") {
        append(&g.errors,fmt.aprintf("%s: %s says copy_kept, the copy of a storage of the World that a history keeps: write it on a @(storage) of a library that is copied",t.where_,name))
        return nil
    }
    if (t.keep || t.reset!="") && (t.kind!=.Storage || t.place!=.World) {
        append(&g.errors,fmt.aprintf("%s: %s says keep or reset, which are of a storage of the World: clearing a World resets its storages, and the others have no World to follow",t.where_,name))
        return nil
    }
    if (t.keep || t.reset!="") && (t.setting!=.None || t.copy=="false") || t.keep && t.reset!="" {
        append(&g.errors,fmt.aprintf("%s: %s says keep or reset and survives clearing the World already as a setting or with copy=false, or says both: a storage that the World resets says reset=\"proc\" when it needs more than its default, one that survives says keep",t.where_,name))
        return nil
    }
    return t
}

@(private="file")
record_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,decl:^ast.Value_Decl,name:string,options:map[string]string,also:bool) {
    where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
    if also {
        append(&g.errors,fmt.aprintf("%s: %s is a @(record), the row of tables of game data, and also a component, a storage, a message or a @(params): keep @(record) alone, and name its rows from components with core.Record(%s)",where_,name,name))
        return
    }
    if pkg.editor {
        append(&g.errors,fmt.aprintf("%s: %s is a @(record) in a package of the editor: the game reads its rows, so declare it in a library or in game/",where_,name))
        return
    }
    if _,is_struct:=decl.values[0].derived.(^ast.Struct_Type);!is_struct {
        append(&g.errors,fmt.aprintf("%s: %s is a @(record) and not a struct: a row of a table is a struct of fields",where_,name))
        return
    }
    r:=new(Record_Type)
    r.name,r.pkg,r.where_=name,pkg,where_
    r.key=fmt.aprintf("%s.%s",pkg.path,name)
    r.file,r.value=file,decl.values[0]
    r.description=options["description"] or_else ""
    field_comments(&r.fields,decl.values[0])
    for other in g.records {
        if other.key==r.key {
            append(&g.errors,fmt.aprintf("%s: %s is declared twice",where_,name))
            return
        }
        if other.name==name && other.pkg.name==pkg.name {
            append(&g.errors,fmt.aprintf("%s: %s.%s is also a @(record) of %s: a .records names the type of its rows by its package and name, so rename one of them",where_,pkg.name,name,other.where_))
            return
        }
    }
    g.record_by_key[r.key]=r
    append(&g.records,r)
    pkg.used=true
}

@(private="file")
named_type_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,decl:^ast.Value_Decl,name:string,options:map[string]string) {
    where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
    _,is_names:=options["names"]
    _,is_bits:=options["name_bits"]
    // A mask may be an alias of a distinct integer of a package below the one that names its bits.
    _,distinct_type:=decl.values[0].derived.(^ast.Distinct_Type)
    #partial switch _ in decl.values[0].derived {
    case ^ast.Ident,^ast.Selector_Expr: distinct_type ||= is_bits
    }
    if !distinct_type || is_names && is_bits {
        append(&g.errors,fmt.aprintf("%s: %s says names or name_bits: @(names) marks a distinct integer whose constants have names (%s :: distinct u16), and @(name_bits=\"T\") a distinct integer whose bits are the values of T; it is one of them",where_,name,name))
        return
    }
    t:=new(Named_Type)
    t.key,t.name,t.pkg,t.where_=fmt.aprintf("%s.%s",pkg.path,name),name,pkg,where_
    t.prefix=options["names"] or_else ""
    _,t.actions=options["actions"]
    if d,is_distinct:=decl.values[0].derived.(^ast.Distinct_Type);is_distinct {t.bits=int_bits(d.type)}
    if of,bits:=options["name_bits"];bits {
        if of=="" {
            append(&g.errors,fmt.aprintf("%s: %s says name_bits without a type: write @(name_bits=\"T\") with the @(names) type whose values its bits are",where_,name))
            return
        }
        t.bits_of=qualified(g,file,pkg,of)
    }
    if t.key in g.named_types {
        append(&g.errors,fmt.aprintf("%s: %s is declared twice",where_,name))
        return
    }
    g.named_types[t.key]=t
    append(&g.named_type_list,t)
}

// A constant of a type it names, X :: T(...) or X : T : ..., for names_settle to keep if T has names.
@(private="file")
named_value_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,decl:^ast.Value_Decl,name:string,options:map[string]string) {
    type:=decl.type
    if type==nil {
        call,is_call:=decl.values[0].derived.(^ast.Call_Expr)
        if !is_call || len(call.args)!=1 {return}
        type=call.expr
    }
    #partial switch _ in type.derived {
    case ^ast.Ident,^ast.Selector_Expr:
    case: return
    }
    explicit,has_name:=options["name"]
    requires:=options["name_requires"] or_else ""
    root:=slashes(strings.has_prefix(pkg.path,"project:")?g.root:g.engine_root,context.temp_allocator)
    path:=slashes(file.fullpath,context.temp_allocator)
    if strings.has_prefix(path,root) && len(path)>len(root) && path[len(root)]=='/' {path=path[len(root)+1:]}
    append(&g.named_values,Named_Value{
        type_key=qualified(g,file,pkg,expr_text(file,type)),ident=name,name=explicit,explicit=has_name,pkg=pkg,
        requires=requires!=""?qualified(g,file,pkg,requires):"",
        file=strings.clone(path),line=decl.pos.line,where_=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line),
    })
}

// An enum @(actions) :: enum u8 {Move,Jump}: its members in order, without values of their own.
@(private="file")
action_enum_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,decl:^ast.Value_Decl,name:string) {
    where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
    e,is_enum:=decl.values[0].derived.(^ast.Enum_Type)
    switch {
    case !is_enum:
        append(&g.errors,fmt.aprintf("%s: @(actions) on %s, which is not an enum: declare the actions of a library as @(actions) %s :: enum u8 {{Move,Jump}}",where_,name,name))
        return
    case pkg.editor:
        append(&g.errors,fmt.aprintf("%s: %s is @(actions) in an editor package: actions are of the game; declare them in a library or in game/",where_,name))
        return
    case e.base_type==nil || ident_name(e.base_type)!="u8":
        append(&g.errors,fmt.aprintf("%s: %s is @(actions) and its members are not u8: write %s :: enum u8 {{...}}",where_,name,name))
        return
    }
    a:=new(Action_Enum)
    a.key,a.name,a.pkg,a.file,a.where_=fmt.aprintf("%s.%s",pkg.path,name),name,pkg,file.fullpath,where_
    for field in e.fields {
        ident,plain:=field.derived.(^ast.Ident)
        if !plain {
            append(&g.errors,fmt.aprintf("%s: a member of %s has a value of its own: the generator gives the values of actions; write only the names of the members",where_,name))
            return
        }
        append(&a.members,Action_Member{ident.name,field.pos.line})
    }
    g.action_by_key[a.key]=a
    append(&g.action_enums,a)
}

// The bits of an integer type written as its name (u8, i32...); 0 for another.
@(private="file")
int_bits :: proc(expr:^ast.Expr) -> int {
    ident,is_ident:=expr.derived.(^ast.Ident)
    if !is_ident || len(ident.name)<2 || (ident.name[0]!='u' && ident.name[0]!='i') {return 0}
    bits,ok:=strconv.parse_int(ident.name[1:])
    return ok?bits:0
}

// The members of the @(actions) enums become values of the @(names,actions)
// type: each enum from the next free value on, in the order of the
// libraries (engine, active plugins, game), named in lower case.
@(private="file")
actions_settle :: proc(g:^Generator) {
    for t in g.named_type_list {
        if !t.actions {continue}
        if g.actions_type!=nil || t.bits_of!="" {
            append(&g.errors,fmt.aprintf("%s: %s says actions, and %s is already the type of the actions: one @(names,actions) distinct integer takes the members of every @(actions) enum",t.where_,t.name,g.actions_type!=nil?g.actions_type.name:t.name))
            continue
        }
        g.actions_type=t
    }
    if len(g.action_enums)==0 {return}
    t:=g.actions_type
    if t==nil {
        append(&g.errors,fmt.aprintf("%s: %s is @(actions), and no @(names,actions) type takes the values of actions: the engine declares it in engine/input",g.action_enums[0].where_,g.action_enums[0].name))
        return
    }
    limit:=t.bits>0 && t.bits<63?1<<uint(t.bits):max(int)
    for mask in g.named_type_list {
        if mask.bits_of==t.key && mask.bits>0 {limit=min(limit,mask.bits)}
    }
    total:=0
    for a in g.action_enums {
        a.base=total
        root:=slashes(strings.has_prefix(a.pkg.path,"project:")?g.root:g.engine_root,context.temp_allocator)
        path:=slashes(a.file,context.temp_allocator)
        if strings.has_prefix(path,root) && len(path)>len(root) && path[len(root)]=='/' {path=path[len(root)+1:]}
        for member,i in a.members {
            append(&g.named_values,Named_Value{
                type_key=t.key,ident=member.ident,pkg=a.pkg,file=strings.clone(path),line=member.line,
                action=a,number=total+i,where_=fmt.aprintf("%s(%d)",a.file,member.line),
            })
        }
        total+=len(a.members)
        a.pkg.used=true
    }
    t.pkg.used=true
    if total<=limit {return}
    counts:=strings.builder_make(context.temp_allocator)
    for a,i in g.action_enums {fmt.sbprintf(&counts,"%s%s.%s %d",i>0?", ":"",a.pkg.name,a.name,len(a.members))}
    append(&g.errors,fmt.aprintf("%s: the @(actions) enums declare %d actions (%s), and %s holds %d: remove the actions no longer used",g.action_enums[len(g.action_enums)-1].where_,total,strings.to_string(counts),t.name,limit))
}

// Keeps the constants whose types have names, with the name each takes:
// its @(name), or its identifier without the prefix of its type, in lower case.
@(private="file")
names_settle :: proc(g:^Generator) {
    actions_settle(g)
    for t in g.named_type_list {
        if t.bits_of=="" {continue}
        of,found:=g.named_types[t.bits_of]
        if !found || of.bits_of!="" {
            append(&g.errors,fmt.aprintf("%s: %s says name_bits=%q, which is not a type @(names); name the distinct integer whose values its bits are",t.where_,t.name,t.bits_of))
        }
        t.pkg.used=true
    }
    kept:=make([dynamic]Named_Value)
    for &value in g.named_values {
        t,found:=g.named_types[value.type_key]
        if !found || t.bits_of!="" {continue}
        value.type=t
        if t.actions && value.action==nil {
            append(&g.errors,fmt.aprintf("%s: %s is a constant of %s, whose values are the actions the @(actions) enums declare: make it a member of the @(actions) enum of its library (Action :: enum u8 {{...}}), which gives it its value",value.where_,value.ident,t.name))
            continue
        }
        if !value.explicit {
            ident:=value.ident
            if t.prefix!="" && strings.has_prefix(ident,t.prefix) {ident=ident[len(t.prefix):]}
            value.name=strings.to_lower(ident)
        }
        if value.name=="" {
            append(&g.errors,fmt.aprintf("%s: %s has an empty name; give it one with @(name=\"...\") or an identifier longer than the prefix %q of %s",value.where_,value.ident,t.prefix,t.name))
            continue
        }
        for other in kept {
            if other.type==t && other.name==value.name && value.action!=nil {
                append(&g.errors,fmt.aprintf("%s: %s.%s and %s.%s (%s) are both the action %q; rename one of the members",value.where_,value.action.name,value.ident,other.action.name,other.ident,other.where_,value.name))
            } else if other.type==t && other.name==value.name {
                append(&g.errors,fmt.aprintf("%s: %s and %s (%s) are both named %q in %s; give one another name with @(name=\"...\")",value.where_,value.ident,other.ident,other.where_,value.name,t.name))
            }
        }
        if value.requires!="" {
            needed,known:=g.by_key[value.requires]
            if !known || needed.kind!=.Component {
                append(&g.errors,fmt.aprintf("%s: %s says name_requires=%q, which is not a component; name the component an entity needs to take this value",value.where_,value.ident,value.requires))
                continue
            }
            value.requires_type=needed
            needed.pkg.used=true
        }
        t.pkg.used,value.pkg.used=true,true
        append(&kept,value)
    }
    // Together by type, in the order they are declared.
    slice.stable_sort_by(kept[:],proc(a,b:Named_Value) -> bool {return a.type.key<b.type.key})
    g.named_values=kept
}

@(private="file")
message_read :: proc(g:^Generator,pkg:^Package,name:string,options:map[string]string,also:bool) {
    if also {
        append(&g.errors,fmt.aprintf("%s: %s is a @(net_message) and a component or storage: a message is a structure of its own, sent once",pkg.folder,name))
        return
    }
    if pkg.editor {
        append(&g.errors,fmt.aprintf("%s: %s is a @(net_message) of the editor: messages are of the game, declared in a library or in game/",pkg.folder,name))
        return
    }
    m:=Message{name=name,pkg=pkg}
    switch options["from"] or_else "" {
    case "","server": m.from=.Server
    case "client":    m.from=.Client
    case "owner":     m.from=.Owner
    case:
        append(&g.errors,fmt.aprintf("%s: %s has from=%q: a message is sent from the \"server\" (the default), a \"client\" or the \"owner\" of the entity it is about",pkg.folder,name,options["from"]))
        return
    }
    _,m.reliable=options["reliable"]
    append(&g.messages,m)
    pkg.used=true
}

@(private="file")
bundle_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,decl:^ast.Value_Decl,name:string,also:bool) {
    where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
    record,is_struct:=decl.values[0].derived.(^ast.Struct_Type)
    switch {
    case also:
        append(&g.errors,fmt.aprintf("%s: %s is @(params) and a component, storage or message: a @(params) struct only groups parameters of steps; declare the data apart and put a field that receives it",where_,name))
        return
    case !is_struct || record.poly_params!=nil && (len(record.poly_params.list)!=1 || len(record.poly_params.list[0].names)!=1):
        append(&g.errors,fmt.aprintf("%s: @(params) on %s, which is not a struct without parameters or with one, $E:typeid, for an @(actions) enum: write @(params) %s :: struct {{...}} with a parameter of a step in each field",where_,name,name))
        return
    }
    b:=new(Bundle)
    b.generic=record.poly_params!=nil
    b.key=fmt.aprintf("%s.%s",pkg.path,name)
    b.name,b.pkg,b.file,b.record,b.where_=name,pkg,file,record,where_
    g.bundles[b.key]=b
    append(&g.bundle_list,b)
}

// The fields of every @(params), once the tables and storages are known.
@(private="file")
bundles_settle :: proc(g:^Generator) {
    for b in g.bundle_list {
        b.valid=true
        if b.record.fields==nil || len(b.record.fields.list)==0 {
            append(&g.errors,fmt.aprintf("%s: %s is @(params) and has no fields: give it a field for each parameter it groups, or take it out",b.where_,b.name))
            b.valid=false
            continue
        }
        for field in b.record.fields.list {
            if b.generic && g.actions_type!=nil && type_key(g,b.file,b.pkg,field.type)==g.actions_type.key && len(field.names)==1 && b.base_field=="" {
                b.base_field=ident_name(field.names[0])
                continue
            }
            if inner:=bundle_of(g,b.file,b.pkg,field.type);inner!=nil {
                append(&g.errors,fmt.aprintf("%s: %s has a field of %s, another @(params): they do not nest; put the fields of %s in %s, or have the step receive %s by itself",b.where_,b.name,inner.name,inner.name,b.name,inner.name))
                b.valid=false
                continue
            }
            param,ok:=param_read(g,b.file,b.pkg,field.type)
            for n in field.names {
                if !ok {
                    if param.kind==.App_Part {
                        append(&g.errors,part_error(b.where_,fmt.tprintf("the field %s of %s",ident_name(n),b.name),expr_text(b.file,field.type),param))
                    } else {
                        append(&g.errors,fmt.aprintf("%s: the field %s of %s is %s: no table, storage or service of the engine has that type. A @(params) struct holds parameters of steps: %s",b.where_,ident_name(n),b.name,expr_text(b.file,field.type),PARAM_FORMS))
                    }
                    b.valid=false
                    continue
                }
                param.bundle,param.name=b,ident_name(n)
                append(&b.fields,param)
            }
        }
        if b.generic && b.base_field=="" {
            append(&g.errors,fmt.aprintf("%s: %s is a @(params) with a type parameter, which is received for an @(actions) enum: give it one field of the type of the actions (base:Action), which takes the base of that enum",b.where_,b.name))
            b.valid=false
        }
    }
}

// The @(params) a parameter names, also through a pointer; nil for another type.
@(private="file")
bundle_of :: proc(g:^Generator,file:^ast.File,pkg:^Package,expr:^ast.Expr) -> ^Bundle {
    e:=expr
    if p,is_pointer:=e.derived.(^ast.Pointer_Type);is_pointer {e=p.elem}
    if call,is_call:=e.derived.(^ast.Call_Expr);is_call {e=call.expr}
    return g.bundles[type_key(g,file,pkg,e)] or_else nil
}

// The key of a type named in a file: Name in its package, or alias.Name.
@(private="file")
qualified :: proc(g:^Generator,file:^ast.File,pkg:^Package,text:string) -> string {
    dot:=strings.index_byte(text,'.')
    if dot<0 {return fmt.aprintf("%s.%s",pkg.path,text)}
    path,found:=import_path(g,file,text[:dot])
    if !found {return text}
    return fmt.aprintf("%s.%s",path,text[dot+1:])
}

@(private="file")
import_path :: proc(g:^Generator,file:^ast.File,alias:string) -> (path:string,found:bool) {
    for imp in file.imports {
        full:=strings.trim(imp.relpath.text,"\"`")
        name:=imp.name.text
        if name=="" {
            cut:=max(strings.last_index_any(full,"/:"),-1)
            name=full[cut+1:]
        }
        if name!=alias {continue}
        return full,true
    }
    return "",false
}

@(private="file")
types_settle :: proc(g:^Generator) {
    used:=make(map[string]int)
    for t in g.types {used[snake(t.name)]+=1}
    lock_id:=0
    for t in g.types {
        field:=snake(t.name)
        if used[field]>1 || is_keyword(field) || field=="entities" {field=fmt.aprintf("%s_%s",t.pkg.name,field)}
        t.field=field
        if len(t.locks)>0 {
            lock_id+=1
            t.lock_id=lock_id
        }
        for lock in t.locks {
            target,found:=g.by_key[lock]
            if !found || target.kind!=.Component {
                append(&g.errors,fmt.aprintf("%s: %s locks %s, which is not a component",t.where_,t.name,lock))
            } else if !target.shared {
                append(&g.errors,fmt.aprintf("%s: %s locks %s, which is not @(component,shared): only a table with several writers has owners by entity",t.where_,t.name,target.name))
            } else if target.place!=t.place {
                append(&g.errors,fmt.aprintf("%s: %s locks %s, which is in another place of the world: a row owns rows of its own World, Shared or Editor",t.where_,t.name,target.name))
            }
        }
    }
    aliases:=make(map[string]int)
    for pkg in g.packages {
        alias:=fmt.aprintf("p_%s",pkg.name)
        if n:=aliases[pkg.name];n>0 {alias=fmt.aprintf("%s%d",alias,n)}
        aliases[pkg.name]+=1
        pkg.alias=alias
    }
}

// The procedures @(draw="name"): each receives the context it draws in and the
// node, proc(ctx:^ui.Context,node:ui.Draw_Node), and is in the game binary.
@(private="file")
draws_read :: proc(g:^Generator,pkg:^Package) {
    for file in pkg.files {
        for stmt in file.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
            options:=attributes_read(decl.attributes[:])
            name,is_draw:=options["draw"]
            if !is_draw {continue}
            ident:=ident_name(decl.names[0])
            where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
            literal,is_proc:=decl.values[0].derived.(^ast.Proc_Lit)
            FORM :: "proc(ctx:^ui.Context,node:ui.Draw_Node)"
            switch {
            case !is_proc:
                append(&g.errors,fmt.aprintf("%s: @(draw) on %s, which is not a procedure; it goes on a %s",where_,ident,FORM))
                continue
            case name=="":
                append(&g.errors,fmt.aprintf("%s: %s has @(draw) without a name: write @(draw=\"name\"), the name the Draw nodes of the interfaces say in draw",where_,ident))
                continue
            case pkg.editor:
                append(&g.errors,fmt.aprintf("%s: %s is a @(draw) of an editor package: the game has no editor code, and its interfaces draw in the game; declare it in a library or in game/",where_,ident))
                continue
            }
            types:=make([dynamic]^ast.Expr,context.temp_allocator)
            if literal.type.params!=nil {
                for field in literal.type.params.list {for _ in field.names {append(&types,field.type)}}
            }
            fits:=len(types)==2 && (literal.type.results==nil || len(literal.type.results.list)==0)
            if fits {
                pointer,is_pointer:=types[0].derived.(^ast.Pointer_Type)
                fits=is_pointer && type_key(g,file,pkg,pointer.elem)=="mirai:ui.Context" && type_key(g,file,pkg,types[1])=="mirai:ui.Draw_Node"
            }
            if !fits {
                append(&g.errors,fmt.aprintf("%s: %s is a @(draw) and is not a %s: it draws from the node alone, whose data is the bytes of the field the node binds as its value (ui.draw_value); write what it shows into a component or a storage in a frame step and bind it",where_,ident,FORM))
                continue
            }
            taken:=false
            for other in g.draws {
                if other.name!=name {continue}
                append(&g.errors,fmt.aprintf("%s: %s draws %q, which %s already draws in %s; a name has one procedure",where_,ident,name,other.ident,other.where_))
                taken=true
            }
            if taken {continue}
            pkg.used=true
            append(&g.draws,Draw_Proc{name=name,ident=ident,pkg=pkg,where_=where_})
        }
    }
}

@(private="file")
steps_read :: proc(g:^Generator,pkg:^Package) {
    phases:=PHASES
    loops:=LOOPS
    stages:=STAGES
    minds,acts:=make([dynamic]Mind_Decl,context.temp_allocator),make([dynamic]Mind_Decl,context.temp_allocator)
    for file in pkg.files {
        for stmt in file.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
            options:=attributes_read(decl.attributes[:])
            phase_text,is_step:=options["step"]
            mind_name,is_mind:=options["mind"]
            act_values,is_act:=options["act"]
            name:=ident_name(decl.names[0])
            where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
            if is_mind || is_act {
                literal,_:=decl.values[0].derived.(^ast.Proc_Lit)
                d:=Mind_Decl{name=name,text=is_mind?mind_name:act_values,where_=where_,file=file,literal=literal,line=decl.pos.line}
                _,d.private=options["private"]
                switch {
                case is_step:
                    append(&g.errors,fmt.aprintf("%s: %s is a @(step) and a %s: the generator makes the step of a mind from its think procedure; take @(step) out",where_,name,is_mind?"@(mind)":"@(act)"))
                case is_mind && is_act:
                    append(&g.errors,fmt.aprintf("%s: %s says @(mind) and @(act): the think procedure of a mind proposes and its actions run; give each its own procedure",where_,name))
                case is_mind: append(&minds,d)
                case: append(&acts,d)
                }
                continue
            }
            if !is_step {continue}
            literal,is_proc:=decl.values[0].derived.(^ast.Proc_Lit)
            if !is_proc {
                append(&g.errors,fmt.aprintf("%s: @(step) on %s, which is not a procedure",where_,name))
                continue
            }
            s:=new(Step)
            s.name,s.pkg,s.where_=name,pkg,where_
            s.file,s.line=slashes(file.fullpath,context.allocator),decl.pos.line
            pkg.used=true
            s.rank=len(g.steps)
            for part in strings.fields(phase_text) {
                found:=false
                for phase,i in phases {
                    if phase==part {s.phases[i],found=true,true}
                }
                if !found {append(&g.errors,fmt.aprintf("%s: %s has the phase %q; the phases are input fixed frame late ui render release",where_,name,part))}
            }
            if s.phases[UI_PHASE] && !pkg.editor && !strings.has_prefix(pkg.path,"mirai:") {
                append(&g.errors,fmt.aprintf("%s: %s is a step of the ui phase in a game: a game shows its interfaces as .ui documents on a UI_Screen or a World_Widget, which bind the components and storages it writes in a frame step; what only code can draw is a Draw node of the .ui and a procedure @(draw=\"name\")",where_,name))
            }
            if loop_text,has_loops:=options["loops"];has_loops {
                for part in strings.fields(loop_text) {
                    found:=false
                    for loop,i in loops {
                        if loop==part {s.loops[i],found=true,true}
                    }
                    if !found {append(&g.errors,fmt.aprintf("%s: %s has the loop %q; the loops are game editor",where_,name,part))}
                }
            } else {
                s.loops[pkg.editor?1:0]=true
            }
            if pkg.editor && s.loops[0] {append(&g.errors,fmt.aprintf("%s: %s is in an editor package and asks for the game loop: the game has no editor code",where_,name))}
            s.stage=STAGE_DEFAULT
            if stage,has_stage:=options["stage"];has_stage {
                found:=false
                for known,i in stages {
                    if known==stage {s.stage,found=i,true}
                }
                if !found {append(&g.errors,fmt.aprintf("%s: %s has the stage %q; the stages are begin input intent apply simulate react end, and a step without one is in intent",where_,name,stage))}
            }
            if after,has_after:=options["after"];has_after {names_split(&s.after,after)}
            if before,has_before:=options["before"];has_before {names_split(&s.before,before)}
            _,s.server=options["server"]
            if order,has_order:=options["order"];has_order {
                append(&g.errors,fmt.aprintf("%s: %s has order=%s, and steps are not ordered by number: give it a stage (begin input intent apply simulate react end; intent when it names none) and order it inside the stage with after=\"step\" or before=\"step\"",where_,name,order))
            }
            if literal.type.params!=nil {params_read(g,file,pkg,where_,name,literal.type.params.list[:],&s.params)}
            if literal.type.results!=nil && len(literal.type.results.list)>0 {
                append(&g.errors,fmt.aprintf("%s: %s returns something; a step returns nothing",where_,name))
            }
            append(&g.steps,s)
        }
    }
    minds_read(g,pkg,minds[:],acts[:])
}

// Binds the parameters of a procedure the generator calls, each as its
// type says, into params: the parameters a @(params) groups share their arg.
@(private="file")
params_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,where_,name:string,list:[]^ast.Field,params:^[dynamic]Param) {
    defaulted:=strings.builder_make(context.temp_allocator)
    for field in list {
        if field.default_value==nil {continue}
        for n in field.names {fmt.sbprintf(&defaulted,"%s%s",strings.builder_len(defaulted)>0?", ":"",ident_name(n))}
    }
    if strings.builder_len(defaulted)>0 {
        append(&g.errors,fmt.aprintf("%s: %s gives a default to %s, and the generator binds every parameter: take the defaults out; code outside the loop runs the function with core.world_run, or passes every parameter",where_,name,strings.to_string(defaulted)))
    }
    arg:=0
    for field in list {
        // A default alone gives it no type to bind: the error above says to take it out.
        if field.type==nil {continue}
        if b:=bundle_of(g,file,pkg,field.type);b!=nil {
            if _,is_pointer:=field.type.derived.(^ast.Pointer_Type);is_pointer {
                append(&g.errors,fmt.aprintf("%s: %s receives %s, a @(params) struct, by pointer: receive it by value, %s; its fields already point at what they write",where_,name,expr_text(file,field.type),expr_text(file,field.type)[1:]))
                continue
            }
            if b.pkg.editor && !pkg.editor {
                append(&g.errors,fmt.aprintf("%s: %s receives %s, a @(params) of an editor package: the game has no editor code; declare it in a library",where_,name,b.name))
                continue
            }
            actions:^Action_Enum
            if call,is_call:=field.type.derived.(^ast.Call_Expr);b.generic {
                if is_call && len(call.args)==1 {actions=g.action_by_key[type_key(g,file,pkg,call.args[0])] or_else nil}
                if actions==nil {
                    append(&g.errors,fmt.aprintf("%s: %s receives %s: %s is received for the @(actions) enum whose actions it reads, %s(Action), and that is not one",where_,name,expr_text(file,field.type),b.name,b.name))
                    continue
                }
            } else if is_call {
                append(&g.errors,fmt.aprintf("%s: %s receives %s: %s has no type parameter; receive it as %s",where_,name,expr_text(file,field.type),b.name,b.name))
                continue
            }
            b.pkg.used=true
            for _ in field.names {
                for param in b.fields {
                    bound:=param
                    bound.arg,bound.actions=arg,actions
                    append(params,bound)
                }
                arg+=1
            }
            continue
        }
        param,ok:=param_read(g,file,pkg,field.type)
        for n in field.names {
            if !ok {
                if param.kind==.App_Part {
                    append(&g.errors,part_error(where_,fmt.tprintf("the parameter %s of %s",ident_name(n),name),expr_text(file,field.type),param))
                } else {
                    append(&g.errors,fmt.aprintf("%s: the parameter %s of %s is %s: no table, storage or service of the engine has that type. Mark the type with @(component) or @(storage), receive %s, or a struct marked @(params) whose fields are those",where_,ident_name(n),name,expr_text(file,field.type),PARAM_FORMS))
                }
                arg+=1
                continue
            }
            param.name,param.arg=ident_name(n),arg
            append(params,param)
            arg+=1
        }
    }
}

// The minds of a package: each @(mind) think procedure becomes a step of
// fixed, server, whose context begins with Mind_World and holds what its
// think and its actions receive after their first parameter, each once.
@(private="file")
minds_read :: proc(g:^Generator,pkg:^Package,minds,acts:[]Mind_Decl) {
    act_enums:=make([]string,len(acts),context.temp_allocator)
    for a,i in acts {
        enum_name,members:=mind_proc_check(g,pkg,a,"act","Act","mirai:std/ai.Status")
        act_enums[i]=enum_name
        if enum_name=="" {continue}
        if strings.trim_space(a.text)=="" {
            append(&g.errors,fmt.aprintf("%s: %s has @(act) without values: write @(act=\"Value\") with the values of %s it runs",a.where_,a.name,enum_name))
        }
        for value in strings.fields(a.text) {
            known:=false
            for member in members {known||=member==value}
            if !known {append(&g.errors,fmt.aprintf("%s: %s runs %q, which is no value of %s: name values of the enum in @(act), separated by spaces",a.where_,a.name,value,enum_name))}
        }
    }
    thought:=make(map[string]bool,context.temp_allocator)
    for d in minds {
        enum_name,members:=mind_proc_check(g,pkg,d,"mind","Think","")
        if enum_name=="" {continue}
        thought[enum_name]=true
        if d.text=="" {
            append(&g.errors,fmt.aprintf("%s: %s has @(mind) without a name: write @(mind=\"name\"), the name its agents say in Mind_Agent.mind",d.where_,d.name))
            continue
        }
        if other,taken:=g.mind_names[d.text];taken {
            append(&g.errors,fmt.aprintf("%s: the mind %q of %s is also the one of %s: a name has one mind; give one of them another",d.where_,d.text,d.name,other))
            continue
        }
        runner:^Bundle
        for b in g.bundle_list {
            if b.name=="Mind_World" {runner=b;break}
        }
        if runner==nil || !runner.valid {
            append(&g.errors,fmt.aprintf("%s: %s is the think procedure of a mind, and the world has no behavior plugin, whose Mind_World every mind reads: add behavior to the plugins of project.mirai",d.where_,d.name))
            continue
        }
        g.mind_names[d.text]=d.name
        s:=new(Step)
        s.name,s.pkg,s.where_=d.name,pkg,d.where_
        s.file,s.line=slashes(d.file.fullpath,context.allocator),d.line
        s.rank=len(g.steps)
        s.phases[FIXED_PHASE],s.loops[0],s.stage,s.server=true,true,STAGE_DEFAULT,true
        m:=new(Mind_Step)
        m.name,m.enum_name,m.runner=d.text,enum_name,runner
        s.mind=m
        for param in runner.fields {append(&s.params,param)}
        runner.pkg.used=true
        pkg.used=true
        m.think=mind_proc_bind(g,pkg,s,d)
        for member in members {
            found:=false
            for a,i in acts {
                if act_enums[i]!=enum_name || !mind_acts(a,member) {continue}
                if found {
                    append(&g.errors,fmt.aprintf("%s: %s runs %s.%s, which another action already runs: a value of the enum has one action; take it out of one @(act)",a.where_,a.name,enum_name,member))
                    continue
                }
                found=true
                bound:=mind_proc_bind(g,pkg,s,a)
                bound.value=member
                append(&m.acts,bound)
            }
            if !found {
                append(&g.errors,fmt.aprintf("%s: %s.%s has no action: give a procedure proc(a:^ai.Act(%s), ...) -> ai.Status the attribute @(act=%q), or take the value out of the enum",d.where_,enum_name,member,enum_name,member))
            }
        }
        append(&g.steps,s)
    }
    for a,i in acts {
        if act_enums[i]=="" || thought[act_enums[i]] {continue}
        append(&g.errors,fmt.aprintf("%s: %s is an action of %s, and no think procedure of this package proposes them: give one, proc(t:^ai.Think(%s), ...), the attribute @(mind=\"name\")",a.where_,a.name,act_enums[i],act_enums[i]))
    }
}

// Whether an action runs a value of the enum.
@(private="file")
mind_acts :: proc(a:Mind_Decl,member:string) -> bool {
    for value in strings.fields(a.text) {
        if value==member {return true}
    }
    return false
}

// The enum of a procedure of a mind, whose first parameter is ^ai.<form>(E)
// with E an enum of the package, and its members; "" after an error.
@(private="file")
mind_proc_check :: proc(g:^Generator,pkg:^Package,d:Mind_Decl,attribute,form,result:string) -> (enum_name:string,members:[dynamic]string) {
    shape:=fmt.tprintf("proc(%s:^ai.%s(Actions), ...)%s",form=="Think"?"t":"a",form,result!=""?" -> ai.Status":"")
    switch {
    case d.literal==nil:
        append(&g.errors,fmt.aprintf("%s: @(%s) on %s, which is not a procedure; it goes on a %s",d.where_,attribute,d.name,shape))
        return
    case pkg.editor:
        append(&g.errors,fmt.aprintf("%s: %s is a @(%s) of an editor package: minds decide in the game; declare it in a library or in game/",d.where_,d.name,attribute))
        return
    case d.private:
        append(&g.errors,fmt.aprintf("%s: %s is @(private), and the generated world calls it: take @(private) out",d.where_,d.name))
        return
    }
    params,results:=d.literal.type.params,d.literal.type.results
    returns:=""
    if results!=nil && len(results.list)==1 && len(results.list[0].names)<=1 {returns=type_key(g,d.file,pkg,results.list[0].type)}
    else if results!=nil && len(results.list)>0 {returns="?"}
    shaped:=params!=nil && len(params.list)>0 && len(params.list[0].names)==1 && returns==result
    if shaped {
        shaped=false
        if pointer,is_pointer:=params.list[0].type.derived.(^ast.Pointer_Type);is_pointer {
            if call,is_call:=pointer.elem.derived.(^ast.Call_Expr);is_call && len(call.args)==1 && type_key(g,d.file,pkg,call.expr)==fmt.tprintf("mirai:std/ai.%s",form) {
                enum_name=ident_name(call.args[0])
                shaped=enum_name!=""
            }
        }
    }
    if !shaped {
        append(&g.errors,fmt.aprintf("%s: %s is a @(%s) and is not a %s: its first parameter is the %s of an enum of actions of this package, and the generator binds the others as those of a step",d.where_,d.name,attribute,shape,form=="Think"?"decision":"call"))
        enum_name=""
        return
    }
    e:^ast.Enum_Type
    if _,value,found:=type_decl(pkg,enum_name);found {e,_=value.derived.(^ast.Enum_Type)}
    if e==nil {
        append(&g.errors,fmt.aprintf("%s: %s runs for %s, which is not an enum of this package: declare the actions of a mind as %s :: enum u8 {{...}} beside it",d.where_,d.name,enum_name,enum_name))
        enum_name=""
        return
    }
    members=make([dynamic]string,context.temp_allocator)
    for field in e.fields {
        member:=ident_name(field)
        if fv,valued:=field.derived.(^ast.Field_Value);valued {member=ident_name(fv.field)}
        append(&members,member)
    }
    return
}

// Binds what a procedure of a mind receives after its first parameter into
// the step of the mind: a datum another procedure already receives the same
// way keeps its arg, so the context holds it once.
@(private="file")
mind_proc_bind :: proc(g:^Generator,pkg:^Package,s:^Step,d:Mind_Decl) -> (bound:Mind_Proc) {
    bound.ident=d.name
    params:=d.literal.type.params
    if params==nil || len(params.list)<2 {return}
    local:=make([dynamic]Param,context.temp_allocator)
    params_read(g,d.file,pkg,d.where_,d.name,params.list[1:],&local)
    last:=-1
    for param,i in local {
        if param.arg==last {continue}
        last=param.arg
        if param.kind==.App_Part || param.kind==.App {
            append(&g.errors,fmt.aprintf("%s: %s receives %s, a part of the application: a mind decides from the world; read it in a step and write what the mind needs into a component or a storage",d.where_,d.name,param.name))
            continue
        }
        arg:=-1
        for other in s.params {
            same:=param.bundle!=nil ? other.bundle==param.bundle && other.actions==param.actions : other.bundle==nil && other.kind==param.kind && other.type==param.type && other.record==param.record && other.message==param.message
            if same {arg=other.arg;break}
        }
        if arg<0 {
            arg=s.params[len(s.params)-1].arg+1
            for p in local[i:] {
                if p.arg!=param.arg {break}
                q:=p
                q.arg=arg
                append(&s.params,q)
            }
        }
        append(&bound.args,arg)
    }
    return
}

@(private="file")
param_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,expr:^ast.Expr) -> (param:Param,ok:bool) {
    pointer:=false
    e:=expr
    if p,is_pointer:=e.derived.(^ast.Pointer_Type);is_pointer {
        pointer=true
        e=p.elem
    }
    if call,is_call:=e.derived.(^ast.Call_Expr);is_call && len(call.args)==2 {
        // ^core.Table(T,.Read): the one wrapper with an access.
        access,is_access:=call.args[1].derived.(^ast.Implicit_Selector_Expr)
        inner,found:=g.by_key[type_key(g,file,pkg,call.args[0])]
        if !is_access || access.field.name!="Read" || type_key(g,file,pkg,call.expr)!="mirai:core.Table" || !found || inner.kind!=.Component {return}
        return {kind=.Table_Read,type=inner},pointer
    }
    if call,is_call:=e.derived.(^ast.Call_Expr);is_call && len(call.args)==1 {
        wrapper:=type_key(g,file,pkg,call.expr)
        inner_key:=type_key(g,file,pkg,call.args[0])
        if wrapper=="mirai:core.Records" {
            r,found:=g.record_by_key[inner_key]
            return {kind=.Records,record=r},found && !pointer
        }
        if wrapper=="mirai:core.Ref" && inner_key=="mirai:core.Entities" {return {kind=.Entities_Read,type=nil},!pointer}
        if wrapper=="mirai:core.Inbox" {
            storage:=g.by_key["mirai:core.Net_Messages"] or_else nil
            for m,index in g.messages {
                if fmt.tprintf("%s.%s",m.pkg.path,m.name)==inner_key {return {kind=.Inbox,type=storage,message=index},!pointer && storage!=nil}
            }
            return
        }
        inner,found:=g.by_key[inner_key]
        if !found {return}
        switch {
        case wrapper=="mirai:core.Table" && pointer && inner.kind==.Component: return {kind=.Table_Write,type=inner},true
        case wrapper=="mirai:core.Ref" && !pointer && inner.kind==.Storage: return {kind=.Storage_Ref,type=inner},true
        case wrapper=="mirai:core.Stamp" && !pointer && inner.kind==.Storage && inner.place==.World: return {kind=.Storage_Stamp,type=inner},true
        }
        return
    }
    key:=type_key(g,file,pkg,e)
    switch key {
    case "mirai:core.Commands": return {kind=.Commands,type=nil},!pointer
    case "mirai:core.World_Ref": return {kind=.World_Ref,type=nil},!pointer
    case "mirai:host.App": return {kind=.App,type=nil},pointer
    }
    for part,index in APP_PARTS {
        if part.key==key {return {kind=.App_Part,part=index},pointer==(part.form[0]=='^')}
    }
    t,found:=g.by_key[key]
    if !found || t.kind!=.Storage {return}
    return {kind=pointer?.Storage_Write:.Storage_Value,type=t},true
}

// A part of the application asked for in a form it is not handed out in.
@(private="file")
part_error :: proc(where_,what,written:string,param:Param) -> string {
    parts:=APP_PARTS
    form:=parts[param.part].form
    return fmt.aprintf("%s: %s is %s, and the application hands that part out as %s: receive %s",where_,what,written,form,form)
}

@(private="file")
type_key :: proc(g:^Generator,file:^ast.File,pkg:^Package,expr:^ast.Expr) -> string {
    #partial switch v in expr.derived {
    case ^ast.Ident:
        return fmt.aprintf("%s.%s",pkg.path,v.name)
    case ^ast.Selector_Expr:
        alias:=ident_name(v.expr)
        if path,found:=import_path(g,file,alias);found {return fmt.aprintf("%s.%s",path,v.field.name)}
    }
    return ""
}

@(private="file")
rules_check :: proc(g:^Generator) {
    for t in g.types {
        if t.by_world && "mirai:core.World_Id" not_in g.by_key {
            append(&g.errors,fmt.aprintf("%s: %s is by_world, and the world has no core.World_Id to know whose value a function gets",t.where_,t.name))
        }
        if !t.persist {continue}
        if field,what,fix:=persist_unkept(g,t.file,t.pkg,t.value,"",0);what!="" {
            at:=field==""?t.name:fmt.aprintf("%s.%s",t.name,field)
            append(&g.errors,fmt.aprintf("%s: %s says persist and %s is %s, which the profile of the player does not keep: the profile holds plain data; %s",t.where_,t.name,at,what,fix))
        }
    }
    for r in g.records {
        if field,what,fix:=persist_unkept(g,r.file,r.pkg,r.value,"",0);what!="" {
            at:=field==""?r.name:fmt.aprintf("%s.%s",r.name,field)
            append(&g.errors,fmt.aprintf("%s: %s says record and %s is %s, which a table of game data does not keep: a row is plain data the game reads in every run; %s",r.where_,r.name,at,what,fix))
        }
    }
    names:=make(map[string]^Step)
    for s in g.steps {
        if other,taken:=names[s.name];taken {
            append(&g.errors,fmt.aprintf("%s: a step %s already exists in %s; names of steps are unique",s.where_,s.name,other.where_))
        }
        names[s.name]=s
    }
    stages:=STAGES
    network,has_network:=g.by_key["mirai:core.Network"]
    tick_input:=g.by_key["mirai:core.Input"]
    seats_state:=g.by_key["mirai:engine/input.Seats"]
    for s in g.steps {
        if s.server && (!has_network || network.kind!=.Storage) {
            append(&g.errors,fmt.aprintf("%s: %s is server, and the world has no core.Network to know whether this end decides the rules",s.where_,s.name))
        }
        for list,i in ([2][]string{s.after[:],s.before[:]}) {
            word:=i==0?"after":"before"
            for name in list {
                other,found:=names[name]
                if !found {
                    append(&g.errors,fmt.aprintf("%s: %s runs %s %s, and no step has that name in this project; name a step of the engine or of a plugin this one depends on, or take it out of %s",s.where_,s.name,word,name,word))
                    continue
                }
                if !together(s,other) {continue}
                if i==0 && other.stage>s.stage || i==1 && other.stage<s.stage {
                    append(&g.errors,fmt.aprintf("%s: %s is in the stage %s and runs %s %s, which is in the stage %s: give %s a stage that runs %s %s, or take %s out of %s",s.where_,s.name,stages[s.stage],word,name,stages[other.stage],s.name,i==0?"at or after":"at or before",stages[other.stage],name,word))
                }
            }
        }
        for param in s.params {
            if param.type==nil {continue}
            if param.type.place==.Editor && s.loops[0] {
                append(&g.errors,fmt.aprintf("%s: %s runs in the game and receives %s, which is of the editor",s.where_,s.name,param.type.name))
            }
            if s.phases[1] && param.type.place==.Editor {
                append(&g.errors,fmt.aprintf("%s: %s runs in fixed, which a rollback runs again, and receives %s of the editor",s.where_,s.name,param.type.name))
            }
            if s.phases[1] && param.type.presentation {
                append(&g.errors,fmt.aprintf("%s: %s runs in fixed and receives %s, which came back from the GPU: it is presentation alone, neither deterministic nor in the rollback, and decides nothing of the game; read it in frame or late",s.where_,s.name,param.type.name))
            }
            if param.type.by_world && param.kind==.Storage_Value {
                append(&g.errors,fmt.aprintf("%s: %s receives %s, which has a value for each World, by value: receive ^%s or core.Ref(%s)",s.where_,s.name,param.type.name,param.type.name,param.type.name))
            }
            // The editor loop refills core.Input every frame; only the game loop leaves it, and the actions made of it, at the last tick.
            if s.loops[0] && step_outside_fixed(s) && (param.kind==.Storage_Value || param.kind==.Storage_Ref) {
                if param.type==tick_input {
                    append(&g.errors,fmt.aprintf("%s: %s runs outside fixed and receives core.Input as %s, which there holds the values of the last tick: a frame without a tick repeats its edges and misses what is new; receive core.Frame_Input, or read it in a fixed step",s.where_,s.name,param.name))
                } else if param.type==seats_state && param.bundle!=nil && param.bundle.key=="mirai:engine/input.Input_Of" {
                    append(&g.errors,fmt.aprintf("%s: %s runs outside fixed and receives the actions of the tick as %s: a frame without a tick repeats its edges and misses what is new; receive input.Frame_Input_Of(E), or read them in a fixed step",s.where_,s.name,param_text(param)))
                }
            }
        }
        // What a step writes reaches it once: in a @(params) and by itself, or
        // in two, it would be written through one and read stale through the other.
        for a,i in s.params {
            for b in s.params[i+1:] {
                if a.bundle==nil && b.bundle==nil || !same_datum(a,b) || !writes(a) && !writes(b) {continue}
                what:=a.type.name
                fix:="receive the two @(params) in different steps, or declare one without that field"
                if a.bundle==b.bundle && a.arg==b.arg {fix=fmt.tprintf("take %s or %s out of %s",a.name,b.name,a.bundle.name)}
                else if a.bundle==b.bundle {fix=fmt.tprintf("receive %s once",a.bundle.name)}
                else if a.bundle==nil {fix=fmt.tprintf("take its parameter %s out and use %s.%s",a.name,b.bundle.name,b.name)}
                else if b.bundle==nil {fix=fmt.tprintf("take its parameter %s out and use %s.%s",b.name,a.bundle.name,a.name)}
                append(&g.errors,fmt.aprintf("%s: %s receives %s as %s and as %s, and writes it: a step receives what it writes once; %s",s.where_,s.name,what,param_text(a),param_text(b),fix))
            }
        }
        if s.phases[RELEASE_PHASE] && !s.loops[0] {
            append(&g.errors,fmt.aprintf("%s: %s runs in release, which the application runs from the game loop when it frees a World: release what a library keeps by World in a library, with the game loop",s.where_,s.name))
        }
    }
    // A table or a storage is the state of one library, whose functions write
    // it in the order of the loop: the functions of another push to a queue
    // of it, or it says it is shared.
    loops:=LOOPS
    for loop in 0..<2 {
        owners:=make(map[^Type]^Step,context.temp_allocator)
        for s in g.steps {
            if !s.loops[loop] {continue}
            for param in s.params {
                if !writes(param) || param.type.shared {continue}
                if other,taken:=owners[param.type];taken && other.pkg!=s.pkg {
                    append(&g.errors,fmt.aprintf("%s: %s of %s and %s of %s write %s in the %s loop; a table or a storage has one writing library: %s sends a request through a @(storage,queue) of %s, which a function of %s takes and applies, or %s says shared when several libraries write it in the order of the loop",s.where_,other.name,other.pkg.name,s.name,s.pkg.name,param.type.name,loops[loop],s.name,param.type.pkg.name,param.type.pkg.name,param.type.name))
                }
                owners[param.type]=s
            }
        }
    }
    // A dedicated server runs neither ui nor render: what only those phases
    // do is for whoever watches, and the game has to decide the same without it.
    shown_writer:=make(map[^Type]^Step,context.temp_allocator)
    run_written:=make(map[^Type]bool,context.temp_allocator)
    for s in g.steps {
        if !s.loops[0] {continue}
        shown:=step_shown(s)
        if shown && s.server {
            append(&g.errors,fmt.aprintf("%s: %s is server and runs only in ui or render, which a dedicated server does not run: decide the rules in input, fixed, frame or late",s.where_,s.name))
        }
        for param in s.params {
            if shown {
                #partial switch param.kind {
                case .Table_Write:
                    if param.type.replication!=.None {
                        append(&g.errors,fmt.aprintf("%s: %s runs only in ui or render and writes %s, which is replicated: a dedicated server runs neither and would send what the scene says; write it in input, fixed, frame or late",s.where_,s.name,param.type.name))
                    }
                case .Commands:
                    append(&g.errors,fmt.aprintf("%s: %s runs only in ui or render and receives core.Commands, which creates and destroys entities, as a dedicated server would not: create them in input, fixed, frame or late; to ask only whether an entity is alive or off, receive core.Ref(core.Entities), which also leaves the tables unsettled after it",s.where_,s.name))
                }
            }
            if param.type==nil || !writes(param) {continue}
            if shown {shown_writer[param.type]=s} else {run_written[param.type]=true}
        }
    }
    for s in g.steps {
        if !s.loops[0] || step_shown(s) {continue}
        for param in s.params {
            if param.type==nil || param.type.queue || len(param.type.logs)>0 || run_written[param.type] {continue}
            writer,shown_only:=shown_writer[param.type]
            if !shown_only {continue}
            append(&g.errors,fmt.aprintf("%s: %s reads %s, which only %s writes, in ui or render: a dedicated server runs neither and there %s keeps the value it starts with; write it in input, fixed, frame or late, or read it in ui or render",s.where_,s.name,param.type.name,writer.name,param.type.name))
        }
    }
    // A cycle is reported once, also when its steps share several phases.
    reported:=make(map[string]bool,context.temp_allocator)
    phases:=PHASES
    for loop in 0..<2 {
        for phase in 0..<len(PHASES) {
            o:=phase_order(g,loop,phase)
            if len(o.cycle)==0 {continue}
            // Each step of the cycle waits for the next one, and the last for the first.
            links:=strings.builder_make(context.temp_allocator)
            fix:=""
            fix_kind:=Wait_Kind.Named
            for s,i in o.cycle {
                first:=o.cycle[(i+1)%len(o.cycle)]
                wait:Wait
                for known in o.waits[s] {
                    if known.first==first {wait=known}
                }
                if i>0 {strings.write_string(&links,"; ")}
                switch wait.kind {
                case .Named:
                    fmt.sbprintf(&links,"%s runs after %s by after or before",s.name,first.name)
                case .Request:
                    fmt.sbprintf(&links,"%s runs after %s, which pushes to %s, a queue %s takes",s.name,first.name,wait.datum.name,s.name)
                    if fix_kind==.Named {fix_kind=.Request;fix=fmt.tprintf("write after=\"%s\" on %s, or before=\"%s\" on %s, and what %s pushes to %s waits for the next tick",s.name,first.name,first.name,s.name,first.name,wait.datum.name)}
                case .Data:
                    fmt.sbprintf(&links,"%s runs after %s, which writes %s, which %s reads",s.name,first.name,wait.datum.name,s.name)
                    if fix_kind!=.Data {fix_kind=.Data;fix=fmt.tprintf("write before=\"%s\" on %s, or after=\"%s\" on %s, and %s reads %s as the last tick left it",first.name,s.name,s.name,first.name,s.name,wait.datum.name)}
                }
            }
            text:=strings.to_string(links)
            if reported[text] {continue}
            reported[text]=true
            if fix_kind==.Named {fix="take one of those names out of after or before"}
            else {fix=fmt.tprintf("a name wins over what the data says, so one name settles it: %s; or name another pair of the cycle",fix)}
            append(&g.errors,fmt.aprintf("%s: steps of the stage %s of %s in the %s loop wait for each other: %s. %s",o.cycle[0].where_,stages[o.cycle[0].stage],phases[phase],loops[loop],text,fix))
        }
    }
}

// Whether two steps run in a same phase of a same loop, where after and before order them.
@(private="file")
together :: proc(a,b:^Step) -> bool {
    loop:=a.loops[0] && b.loops[0] || a.loops[1] && b.loops[1]
    for on,phase in a.phases {
        if on && b.phases[phase] && loop {return true}
    }
    return false
}

// Whether a step runs in a phase of the frame, where only a tick that ran has refreshed the input of the tick.
@(private="file")
step_outside_fixed :: proc(s:^Step) -> bool {
    for on,phase in s.phases {
        if on && phase!=FIXED_PHASE && phase!=RELEASE_PHASE {return true}
    }
    return false
}

// Whether a step runs only in ui or render (release aside), which a dedicated server does not run.
@(private="file")
step_shown :: proc(s:^Step) -> bool {
    return !s.phases[0] && !s.phases[1] && !s.phases[2] && !s.phases[3] && (s.phases[4] || s.phases[5])
}

// The names of steps of after or before: separated by spaces or commas.
@(private="file")
names_split :: proc(names:^[dynamic]string,text:string) {
    rest:=text
    for part in strings.split_iterator(&rest,",") {
        for name in strings.fields(part) {append(names,name)}
    }
}

@(private="file")
same_datum :: proc(a,b:Param) -> bool {return a.type!=nil && a.type==b.type}

// A queue is pushed by many: pushing to it is not writing it.
@(private="file")
writes :: proc(p:Param) -> bool {
    return p.kind==.Table_Write || p.kind==.Storage_Write && !p.type.queue
}

@(private="file")
param_text :: proc(p:Param) -> string {
    if p.bundle!=nil {return fmt.tprintf("the field %s of the @(params) %s",p.name,p.bundle.name)}
    return fmt.tprintf("its parameter %s",p.name)
}

// Why a step runs after another of its stage, strongest first: one names the
// other (after, before); it takes the requests the other pushes; it reads
// what the other writes.
@(private="file")
Wait_Kind :: enum u8 {Named,Request,Data}

@(private="file")
Wait :: struct {
    first:^Step,
    kind:Wait_Kind,
    datum:^Type, // Request and Data: the queue, the table or the storage
}

@(private="file")
Ordering :: struct {
    chosen,ordered,path:[dynamic]^Step,
    waits:map[^Step][dynamic]Wait, // what each step runs after, in its stage
    direct:map[^Step][dynamic]Wait, // of those, the ones no other of its waits brings
    state:map[^Step]u8,            // 1 while its waits are visited, 2 once visited, 3 once ordered
    seen:map[^Step]bool,           // of the walk of waits_for
    cycle:[]^Step,                 // steps that wait for each other, each for the next and the last for the first
}

// The steps of a stage that reach a datum no library shares.
@(private="file")
Datum_Use :: struct {
    type:^Type,
    writers,readers:[dynamic]^Step, // a queue: writers are the ones that take it and the ones that push to it
}

// The steps of a loop and phase in the order they run: stage by stage, and
// inside a stage in the order of the libraries, where what a step waits for
// runs before it. A step waits for the ones it names (its after, and the
// before that name it), for the ones that push to a queue of its library that
// it receives, and for the ones that write a table or a storage it reads. A
// wait the stronger ones answer the other way round is not one: a step that
// names the writer of what it reads to run before it, or pushes a request to
// it, reads what the last tick left. Steps that still wait for each other are
// a cycle, which only a name settles.
@(private="file")
phase_order :: proc(g:^Generator,loop,phase:int) -> (o:Ordering) {
    o.chosen=make([dynamic]^Step,context.temp_allocator)
    for s in g.steps {
        if s.loops[loop] && s.phases[phase] {append(&o.chosen,s)}
    }
    slice.sort_by(o.chosen[:],proc(a,b:^Step) -> bool {
        if a.stage!=b.stage {return a.stage<b.stage}
        return a.rank<b.rank
    })
    o.waits=make(map[^Step][dynamic]Wait,context.temp_allocator)
    o.direct=make(map[^Step][dynamic]Wait,context.temp_allocator)
    o.state=make(map[^Step]u8,context.temp_allocator)
    o.seen=make(map[^Step]bool,context.temp_allocator)
    o.ordered=make([dynamic]^Step,context.temp_allocator)
    o.path=make([dynamic]^Step,context.temp_allocator)
    for s in o.chosen {
        for name in s.after {
            for other in o.chosen {
                if other.name==name && other.stage==s.stage {wait_add(&o,s,{other,.Named,nil})}
            }
        }
        for name in s.before {
            for other in o.chosen {
                if other.name==name && other.stage==s.stage {wait_add(&o,other,{s,.Named,nil})}
            }
        }
    }
    for from:=0;from<len(o.chosen); {
        to:=from
        for to<len(o.chosen) && o.chosen[to].stage==o.chosen[from].stage {to+=1}
        stage_waits(&o,o.chosen[from:to])
        from=to
    }
    for s in o.chosen {
        if !order_visit(&o,s) {return}
    }
    // A wait another wait of the step already brings orders nothing by itself:
    // without them the order is the same however many waits say the same.
    for s in o.chosen {
        waited:=o.waits[s]
        direct:=make([dynamic]Wait,context.temp_allocator)
        for wait,i in waited {
            brought:=false
            for other,k in waited {
                if k!=i && waits_for(&o,other.first,wait.first) {brought=true}
            }
            if !brought {append(&direct,wait)}
        }
        slice.sort_by(direct[:],proc(a,b:Wait) -> bool {return a.first.rank<b.first.rank})
        o.direct[s]=direct
    }
    for s in o.chosen {order_run(&o,s)}
    return
}

// What a step waits for runs right before it, in the order of the libraries.
@(private="file")
order_run :: proc(o:^Ordering,s:^Step) {
    if o.state[s]==3 {return}
    o.state[s]=3
    for wait in o.direct[s] {order_run(o,wait.first)}
    append(&o.ordered,s)
}

// The waits the data of a stage gives: the requests, then what is read.
@(private="file")
stage_waits :: proc(o:^Ordering,stage:[]^Step) {
    uses:=make([dynamic]Datum_Use,context.temp_allocator)
    index:=make(map[^Type]int,context.temp_allocator)
    for s in stage {
        for p in s.params {
            if p.type==nil || p.type.shared {continue}
            at,known:=index[p.type]
            if !known {
                at=len(uses)
                index[p.type]=at
                append(&uses,Datum_Use{p.type,make([dynamic]^Step,context.temp_allocator),make([dynamic]^Step,context.temp_allocator)})
            }
            list:=p.kind==.Table_Write || p.kind==.Storage_Write?&uses[at].writers:&uses[at].readers
            if !slice.contains(list[:],s) {append(list,s)}
        }
    }
    found:=make([dynamic]struct{step:^Step,wait:Wait},context.temp_allocator)
    for use in uses {
        if !use.type.queue {continue}
        for taker in use.writers {
            if taker.pkg!=use.type.pkg {continue}
            for pusher in use.writers {
                if pusher.pkg!=use.type.pkg && !waits_for(o,pusher,taker) {append(&found,struct{step:^Step,wait:Wait}{taker,{pusher,.Request,use.type}})}
            }
        }
    }
    for f in found {wait_add(o,f.step,f.wait)}
    clear(&found)
    for use in uses {
        if use.type.queue {continue}
        for reader in use.readers {
            if slice.contains(use.writers[:],reader) {continue}
            for writer in use.writers {
                if !waits_for(o,writer,reader) {append(&found,struct{step:^Step,wait:Wait}{reader,{writer,.Data,use.type}})}
            }
        }
    }
    for f in found {wait_add(o,f.step,f.wait)}
}

@(private="file")
wait_add :: proc(o:^Ordering,s:^Step,wait:Wait) {
    waited:=o.waits[s]
    if waited==nil {waited=make([dynamic]Wait,context.temp_allocator)}
    for known in waited {
        if known.first==wait.first {return}
    }
    append(&waited,wait)
    o.waits[s]=waited
}

// Whether s runs after first by the waits found so far, directly or through others.
@(private="file")
waits_for :: proc(o:^Ordering,s,first:^Step) -> bool {
    visit :: proc(o:^Ordering,seen:^map[^Step]bool,s,first:^Step) -> bool {
        if s==first {return true}
        if seen[s] {return false}
        seen[s]=true
        for wait in o.waits[s] {
            if visit(o,seen,wait.first,first) {return true}
        }
        return false
    }
    if len(o.waits[s])==0 {return false}
    clear(&o.seen)
    return visit(o,&o.seen,s,first)
}

// Finds a cycle of waits, if there is one.
@(private="file")
order_visit :: proc(o:^Ordering,s:^Step) -> bool {
    switch o.state[s] {
    case 2: return true
    case 1:
        at,_:=slice.linear_search(o.path[:],s)
        o.cycle=slice.clone(o.path[at:],context.temp_allocator)
        return false
    }
    o.state[s]=1
    append(&o.path,s)
    for wait in o.waits[s] {
        if !order_visit(o,wait.first) {return false}
    }
    pop(&o.path)
    o.state[s]=2
    return true
}

// Whether a step can create or destroy entities, reach any table or change
// what is off: after it, core.settle runs on the World.
@(private="file")
step_whole :: proc(g:^Generator,s:^Step) -> bool {
    disabled,parent:=g.by_key["mirai:core.Disabled"],g.by_key["mirai:core.Parent"]
    for param in s.params {
        if param.kind==.Commands || param.kind==.World_Ref {return true}
        if param.kind==.Table_Write && (param.type==disabled || param.type==parent) {return true}
    }
    return false
}

@(private="file")
world_write :: proc(g:^Generator,editor:bool) -> string {
    b:=strings.builder_make()
    w:=&b
    included :: proc(t:^Type,editor:bool) -> bool {return editor || t.place!=.Editor}
    fmt.sbprint(w,"// Generated by mirai. Do not edit.\npackage world\n\nimport gen_time \"core:time\"\n")
    imported:=make(map[string]bool,context.temp_allocator)
    for pkg in g.packages {
        if pkg.path in imported || !pkg.used || pkg.editor && !editor {continue}
        imported[pkg.path]=true
        fmt.sbprintf(w,"import %s \"%s\"\n",pkg.alias,pkg.path)
    }
    core_alias:=alias_of(g,"mirai:core")
    if core_alias=="" {
        core_alias="p_core"
        fmt.sbprint(w,"import p_core \"mirai:core\"\n")
    }
    host_alias:=alias_of(g,"mirai:host")
    if host_alias=="" {
        host_alias="p_host"
        fmt.sbprint(w,"import p_host \"mirai:host\"\n")
    }
    for t in g.types {
        if t.kind==.Storage && included(t,editor) && for_device_value(t)!="" {
            fmt.sbprint(w,"import gen_rhi \"mirai:rhi\"\n")
            break
        }
    }
    minds:=0
    for s in g.steps {
        if s.mind==nil {continue}
        if minds==0 {fmt.sbprint(w,"import gen_ai \"mirai:std/ai\"\n")}
        minds+=1
    }
    fmt.sbprint(w,"\n")
    for s in g.steps {
        if s.mind==nil {continue}
        fmt.sbprintf(w,"#assert(%d<=%s.MINDS_CAPACITY,%q)\n\n",minds,s.mind.runner.pkg.alias,fmt.tprintf("the world declares %d minds, more than behavior.MINDS_CAPACITY: join those that share their actions in one mind",minds))
        break
    }

    // The functions as info.steps lists them: where each one adds its time.
    kept:=make([dynamic]^Step,context.temp_allocator)
    index_of:=make(map[^Step]int,context.temp_allocator)
    for s in g.steps {
        if editor || !s.pkg.editor {
            index_of[s]=len(kept)
            append(&kept,s)
        }
    }

    // Where each step that reads the occurrences of a storage left off in each
    // of its logs: for a step of fixed, which a rollback runs again, in a
    // storage copied with the World; for the others, in the World, with its
    // frame. A log a fixed step reads waits for a tick before it ages.
    reads_log :: proc(p:Param) -> bool {
        return p.type!=nil && len(p.type.logs)>0 && p.type.place==.World && (p.kind==.Storage_Ref || p.kind==.Storage_Value)
    }
    cursor_of:=make(map[[2]rawptr]int,context.temp_allocator)
    cursors:[2]int // of the frame, of the ticks
    waits_tick:=make(map[^Type]bool,context.temp_allocator)
    for step in kept {
        ticks:=int(step.phases[FIXED_PHASE])
        for param in step.params {
            key:=[2]rawptr{step,param.type}
            if !reads_log(param) || key in cursor_of {continue}
            cursor_of[key]=cursors[ticks]
            cursors[ticks]+=len(param.type.logs)
            if ticks==1 {waits_tick[param.type]=true}
        }
    }
    if cursors[1]>0 {fmt.sbprintf(w,"Event_Cursors :: struct {{seen:[%d]u64}}\n\n",cursors[1])}

    places:=[3]core.Place{.World,.Shared,.Editor}
    struct_names:=[3]string{"World","Shared","Editor"}
    // Each storage by its index in info.storages, where its revision is.
    storage_index:=make(map[^Type]int,context.temp_allocator)
    for t in g.types {
        if t.kind==.Storage && included(t,editor) {storage_index[t]=len(storage_index)}
    }
    for place,pi in places {
        fmt.sbprintf(w,"%s :: struct {{\n",struct_names[pi])
        if place==.World {
            fmt.sbprintf(w,"    entities:%s.Entities,\n    storage_revisions:[%d]u64,\n",core_alias,len(storage_index)+int(cursors[1]>0))
            if cursors[1]>0 {fmt.sbprint(w,"    event_cursors:Event_Cursors,\n")}
            if cursors[0]>0 {fmt.sbprintf(w,"    frame_cursors:[%d]u64,\n",cursors[0])}
        }
        for t in g.types {
            if t.place!=place || !included(t,editor) {continue}
            if t.kind==.Component {fmt.sbprintf(w,"    %s:%s.Table(%s.%s),\n",t.field,core_alias,t.pkg.alias,t.name)}
            else if t.by_world {fmt.sbprintf(w,"    %s:%s.By_World(%s.%s),\n",t.field,core_alias,t.pkg.alias,t.name)}
            else {fmt.sbprintf(w,"    %s:%s.%s,\n",t.field,t.pkg.alias,t.name)}
        }
        if place!=.World {fmt.sbprint(w,"    _:u8,\n")}
        fmt.sbprint(w,"}\n\n")
    }

    // Who holds each lock, by id.
    fmt.sbprint(w,"@(rodata)\nLOCK_NAMES := [?]string{\"\"")
    for t in g.types {
        if t.lock_id>0 {fmt.sbprintf(w,",\"%s.%s\"",t.pkg.name,t.name)}
    }
    fmt.sbprint(w,"}\n\n")

    world_id:=g.by_key["mirai:core.World_Id"]

    // Each function as the loops call it, with its binding, its settle and
    // its time: the loops call these in order, and core.world_run a part of them.
    for step,si in kept {
        // The value of each arg of the step: a parameter, or a @(params) it builds.
        values:=make([dynamic]string,context.temp_allocator)
        args:=strings.builder_make(context.temp_allocator)
        // A generic @(params) ends with the base of its enum.
        bundle_close :: proc(g:^Generator,args:^strings.Builder,param:Param) {
            if param.bundle==nil {return}
            if param.actions!=nil {fmt.sbprintf(args,",%s=%s.%s(%d)",param.bundle.base_field,g.actions_type.pkg.alias,g.actions_type.name,param.actions.base)}
            strings.write_string(args,"}")
        }
        for param,pi in step.params {
            first:=pi==0 || step.params[pi-1].arg!=param.arg
            if first && pi>0 {
                bundle_close(g,&args,step.params[pi-1])
                append(&values,strings.clone(strings.to_string(args),context.temp_allocator))
                strings.builder_reset(&args)
            }
            if param.bundle!=nil {
                if first && param.actions!=nil {
                    fmt.sbprintf(&args,"%s.%s(%s.%s){{",param.bundle.pkg.alias,param.bundle.name,param.actions.pkg.alias,param.actions.name)
                } else if first {fmt.sbprintf(&args,"%s.%s{{",param.bundle.pkg.alias,param.bundle.name)} else {strings.write_string(&args,",")}
                fmt.sbprintf(&args,"%s=",param.name)
            }
            holder:="w"
            if param.type!=nil {
                switch param.type.place {
                case .World: holder="w"
                case .Shared: holder="s"
                case .Editor: holder="e"
                }
            }
            switch param.kind {
            case .Table_Write: fmt.sbprintf(&args,"&%s.%s",holder,param.type.field)
            case .Table_Read: fmt.sbprintf(&args,"%s.read(&%s.%s)",core_alias,holder,param.type.field)
            case .Storage_Write:
                if param.type.by_world {fmt.sbprintf(&args,"%s.by_world_get(&%s.%s,w.%s)",core_alias,holder,param.type.field,world_id.field)} else {fmt.sbprintf(&args,"&%s.%s",holder,param.type.field)}
            case .Storage_Ref:
                if reads_log(param) {fmt.sbprintf(&args,"%s.ref(&view_%s)",core_alias,param.type.field)} else if param.type.by_world {fmt.sbprintf(&args,"%s.ref(%s.by_world_get(&%s.%s,w.%s))",core_alias,core_alias,holder,param.type.field,world_id.field)} else {fmt.sbprintf(&args,"%s.ref(&%s.%s)",core_alias,holder,param.type.field)}
            case .Storage_Value:
                if reads_log(param) {fmt.sbprintf(&args,"view_%s",param.type.field)} else {fmt.sbprintf(&args,"%s.%s",holder,param.type.field)}
            case .Storage_Stamp: fmt.sbprintf(&args,"%s.Stamp(%s.%s){{&w.storage_revisions[%d]}}",core_alias,param.type.pkg.alias,param.type.name,storage_index[param.type])
            case .Entities_Read: fmt.sbprintf(&args,"%s.ref(&w.entities)",core_alias)
            case .Commands: fmt.sbprintf(&args,"%s.commands(w,app.info)",core_alias)
            case .World_Ref: fmt.sbprintf(&args,"%s.world_ref(w,app.info)",core_alias)
            case .App: fmt.sbprint(&args,"app")
            case .App_Part:
                parts:=APP_PARTS
                value:=parts[param.part].value
                if strings.has_prefix(value,"host.") {fmt.sbprintf(&args,"%s.%s",host_alias,value[5:])} else {fmt.sbprint(&args,value)}
            case .Inbox:
                m:=g.messages[param.message]
                fmt.sbprintf(&args,"%s.inbox(&%s.%s,%d,%s.%s)",core_alias,holder,param.type.field,param.message,m.pkg.alias,m.name)
            case .Records:
                index,_:=slice.linear_search(g.records[:],param.record)
                fmt.sbprintf(&args,"%s.Records(%s.%s){{%s.app_record_set(app,%d)}}",core_alias,param.record.pkg.alias,param.record.name,host_alias,index)
            }
        }
        if len(step.params)>0 {
            bundle_close(g,&args,step.params[len(step.params)-1])
            append(&values,strings.to_string(args))
        }
        call:=fmt.tprintf("%s.%s(%s)",step.pkg.alias,step.name,strings.join(values[:],",",context.temp_allocator))
        // A mind ticks its agents in a context that holds each arg once, which
        // its think and its actions receive through ai.Mind_Context.user.
        mind_decls:=""
        if m:=step.mind;m!=nil {
            ctx_type:=fmt.tprintf("Mind_%s",step.name)
            enum_type:=fmt.tprintf("%s.%s",step.pkg.alias,m.enum_name)
            fmt.sbprintf(w,"%s :: struct {{world:%s.%s",ctx_type,m.runner.pkg.alias,m.runner.name)
            fields:=strings.builder_make(context.temp_allocator)
            fmt.sbprintf(&fields,"world=%s",values[0])
            last:=0
            for param in step.params {
                if param.arg==last {continue}
                last=param.arg
                fmt.sbprintf(w,",a%d:%s",param.arg,param_type(g,param,core_alias))
                fmt.sbprintf(&fields,",a%d=%s",param.arg,values[param.arg])
            }
            fmt.sbprint(w,"}\n")
            fmt.sbprintf(w,"#assert(len(%q)<%s.MIND_NAME,%q)\n\n",m.name,m.runner.pkg.alias,fmt.tprintf("%s: the name of the mind %q is longer than a Mind_Agent holds: shorten it",step.where_,m.name))
            mind_call :: proc(step:^Step,ctx_type:string,p:Mind_Proc,first,returns:string) -> string {
                text:=strings.builder_make(context.temp_allocator)
                if len(p.args)>0 {fmt.sbprintf(&text,"c:=cast(^%s)%s.user;",ctx_type,first)}
                fmt.sbprintf(&text,"%s%s.%s(%s",returns,step.pkg.alias,p.ident,first)
                for arg in p.args {fmt.sbprintf(&text,",c.a%d",arg)}
                strings.write_string(&text,")")
                return strings.to_string(text)
            }
            decls:=strings.builder_make(context.temp_allocator)
            fmt.sbprintf(&decls,"    ctx:=%s{{%s}}\n",ctx_type,strings.to_string(fields))
            fmt.sbprintf(&decls,"    think:=proc(t:^gen_ai.Think(%s)) {{%s}}\n",enum_type,mind_call(step,ctx_type,m.think,"t",""))
            fmt.sbprintf(&decls,"    acts:=[%s]proc(a:^gen_ai.Act(%s)) -> gen_ai.Status{{",enum_type,enum_type)
            for act,i in m.acts {
                fmt.sbprintf(&decls,"%s\n        .%s=proc(a:^gen_ai.Act(%s)) -> gen_ai.Status {{%s}}",i>0?",":"",act.value,enum_type,mind_call(step,ctx_type,act,"a","return "))
            }
            fmt.sbprint(&decls,"}\n")
            mind_decls=strings.to_string(decls)
            call=fmt.tprintf("%s.minds_tick(&ctx.world,%q,&acts,think)",m.runner.pkg.alias,m.name)
        }
        checks:=strings.builder_make(context.temp_allocator)
        for param in step.params {
            if param.kind!=.Table_Write {continue}
            holder:=param.type.place==.Editor?"e":"w"
            if strings.builder_len(checks)>0 {strings.write_string(&checks,",")}
            fmt.sbprintf(&checks,"%s.write_check_begin(%s.raw(&%s.%s),size_of(%s.%s))",core_alias,core_alias,holder,param.type.field,param.type.pkg.alias,param.type.name)
        }
        fmt.sbprintf(w,"call_%s :: proc(world,shared,editor:rawptr,app_data:rawptr) {{\n",step.name)
        fmt.sbprintf(w,"    w:=cast(^World)world\n    s:=cast(^Shared)shared\n    e:=cast(^Editor)editor\n    app:=cast(^%s.App)app_data\n    _,_,_=s,e,app\n",host_alias)
        // A client neither runs nor resimulates what the server or a game alone decides.
        if step.server {fmt.sbprintf(w,"    if w.%s.role==.Client {{return}}\n",g.by_key["mirai:core.Network"].field)}
        // A storage of the World handed out to write is another from here on:
        // the copy of what changed takes it again (core.world_copy_changed).
        for param,pi in step.params {
            if param.kind!=.Storage_Write || param.type.place!=.World || param.type.by_world || param.type.copy=="false" {continue}
            again:=false
            for other in step.params[:pi] {again||=other.kind==.Storage_Write && other.type==param.type}
            if !again {fmt.sbprintf(w,"    w.storage_revisions[%d]+=1\n",storage_index[param.type])}
        }
        // Of a log it reads, the step is handed what came since it last ran.
        ticks:=step.phases[FIXED_PHASE]
        for param,pi in step.params {
            at,reads:=cursor_of[[2]rawptr{step,param.type}]
            if !reads || !reads_log(param) {continue}
            again:=false
            for other in step.params[:pi] {again||=other.type==param.type && reads_log(other)}
            if again {continue}
            fmt.sbprintf(w,"    view_%s:=w.%s\n",param.type.field,param.type.field)
            for log,li in param.type.logs {
                fmt.sbprintf(w,"    %s.events_read(&view_%s.%s,&w.%s[%d])\n",core_alias,param.type.field,log,ticks?"event_cursors.seen":"frame_cursors",at+li)
            }
            if ticks {fmt.sbprintf(w,"    w.storage_revisions[%d]+=1\n",len(storage_index))}
        }
        fmt.sbprint(w,mind_decls)
        fmt.sbprintf(w,"    started:=gen_time.tick_now()\n    zone:=%s.profile_step_begin(app,%d)\n",host_alias,si)
        if strings.builder_len(checks)>0 {
            fmt.sbprintf(w,"    when %s.CHECK_WRITES {{\n        checks:=[?]%s.Write_Check{{%s}}\n        %s\n        %s.write_check_end(checks[:],\"%s\")\n    }} else {{%s}}\n",core_alias,core_alias,strings.to_string(checks),call,core_alias,step.name,call)
        } else {
            fmt.sbprintf(w,"    %s\n",call)
        }
        // What it adds and removes applies to the tables it could write;
        // to all of them when it can create or destroy entities, or
        // change what is disabled.
        whole:=step_whole(g,step)
        for param in step.params {
            if param.kind!=.Table_Write || whole {continue}
            holder:=param.type.place==.Editor?"e":"w"
            fmt.sbprintf(w,"    %s.table_settle(&%s.%s,&w.entities)\n",core_alias,holder,param.type.field)
        }
        if whole {fmt.sbprintf(w,"    %s.settle(app.info,w,e)\n",core_alias)}
        fmt.sbprintf(w,"    %s.profile_step_end(zone)\n",host_alias)
        fmt.sbprintf(w,"    if %d<len(app.step_ns) {{app.step_ns[%d]+=u64(gen_time.tick_since(started))}}\n}}\n\n",si,si)
    }

    // loops, and their order as info.order gives it
    phases:=PHASES
    titles:=PHASE_TITLES
    loops:=LOOPS
    defined:[2][len(PHASES)]bool
    for loop in 0..<(editor?2:1) {
        for phase in 0..<len(PHASES) {
            steps:=phase_order(g,loop,phase).ordered
            if len(steps)==0 {continue}
            defined[loop][phase]=true
            fmt.sbprintf(w,"%s_%s :: proc(world,shared,editor:rawptr,app_data:rawptr) {{\n",loops[loop],phases[phase])
            for step in steps {fmt.sbprintf(w,"    call_%s(world,shared,editor,app_data)\n",step.name)}
            fmt.sbprint(w,"}\n")
            fmt.sbprintf(w,"@(rodata) order_%s_%s:=[%d]i32{{",loops[loop],phases[phase],len(steps))
            for step,k in steps {fmt.sbprintf(w,"%s%d",k>0?",":"",index_of[step])}
            fmt.sbprint(w,"}\n")
            fmt.sbprint(w,"\n")
        }
    }

    // What every reader of the logs has had a frame and a tick to read goes.
    aged:=false
    for pass in 0..<2 {
        for t in g.types {
            if len(t.logs)==0 || t.place!=.World || !included(t,editor) || waits_tick[t]!=(pass==1) {continue}
            if !aged {fmt.sbprint(w,"events_age :: proc(world:rawptr,ticked:bool) {\n    w:=cast(^World)world\n")}
            aged=true
            // An aged log is another: the copy of what changed takes its storage again.
            for log in t.logs {fmt.sbprintf(w,"    if %s%s.events_age(&w.%s.%s) {{w.storage_revisions[%d]+=1}}\n",pass==1?"ticked && ":"",core_alias,t.field,log,storage_index[t])}
        }
    }
    if aged {fmt.sbprint(w,"}\n\n")}

    // A World replaced under the readers of the frame (a rollback, a scene swapped in) leaves
    // each at most at the end of its log: they read what comes after.
    if cursors[0]>0 {
        fmt.sbprint(w,"events_rewind :: proc(world:rawptr) {\n    w:=cast(^World)world\n")
        for step in kept {
            if step.phases[FIXED_PHASE] {continue}
            for param,pi in step.params {
                at,reads:=cursor_of[[2]rawptr{step,param.type}]
                if !reads || !reads_log(param) {continue}
                again:=false
                for other in step.params[:pi] {again||=other.type==param.type && reads_log(other)}
                if again {continue}
                for log,li in param.type.logs {fmt.sbprintf(w,"    w.frame_cursors[%d]=min(w.frame_cursors[%d],%s.log_end(w.%s.%s.log))\n",at+li,at+li,core_alias,param.type.field,log)}
            }
        }
        fmt.sbprint(w,"}\n\n")
    }

    for t in g.types {
        if included(t,editor) {type_procs_write(w,t,fmt.tprintf("%s.",core_alias))}
    }
    fmt.sbprint(w,"\n")

    // The default bindings of each enum @(actions); the compiler asks for every member.
    for a,ai in g.action_enums {
        value:=actions_defaults_value(a) or_continue
        fmt.sbprintf(w,"action_defaults_%d :: proc(dst:rawptr) {{(cast(^[%s.%s]%s.Action_Bindings)dst)^=%s}}\n",ai,a.pkg.alias,a.name,g.actions_type.pkg.alias,value)
    }

    // What a new row of each record type starts as, and the descriptions of their fields.
    for r in g.records {
        tag:=fmt.tprintf("%s_%s",snake(r.pkg.name),snake(r.name))
        if value,found:=record_default(r);found {fmt.sbprintf(w,"record_default_%s :: proc(dst:rawptr) {{(cast(^%s.%s)dst)^=%s}}\n",tag,r.pkg.alias,r.name,value)}
        if len(r.fields)==0 {continue}
        fmt.sbprintf(w,"@(rodata) record_fields_%s:=[%d]%s.Field_Description{{",tag,len(r.fields),core_alias)
        for field,k in r.fields {fmt.sbprintf(w,"%s{{%q,%q}}",k>0?",":"",field.name,field.text)}
        fmt.sbprint(w,"}\n")
    }
    fmt.sbprint(w,"\n")

    // Two constants of a type with names have two values: the compiler knows them.
    for value,vi in g.named_values {
        if (value.pkg.editor || value.type.pkg.editor) && !editor || value.action!=nil {continue}
        for other in g.named_values[vi+1:] {
            if other.type!=value.type || (other.pkg.editor || other.type.pkg.editor) && !editor {continue}
            fmt.sbprintf(w,"#assert(%s.%s!=%s.%s,%q)\n",value.pkg.alias,value.ident,other.pkg.alias,other.ident,fmt.tprintf("%s and %s have one value of %s: give one of them another",value.where_,other.where_,value.type.name))
        }
    }
    fmt.sbprint(w,"\n")

    // info
    fmt.sbprintf(w,"info :: proc() -> %s.World_Info {{\n",core_alias)
    fmt.sbprintf(w,"    tables:=make([]%s.Table_Info,%d)\n",core_alias,count_kind(g,.Component,editor))
    i:=0
    for t in g.types {
        if t.kind!=.Component || !included(t,editor) {continue}
        // The last of each, flat, is found by core.world_info_index.
        locks:="nil"
        if len(t.locks)>0 {
            locks=fmt.tprintf("locks_%s",t.field)
            fmt.sbprintf(w,"    %s:=make([]%s.Lock,%d)\n",locks,core_alias,len(t.locks))
            for lock,li in t.locks {
                target:=g.by_key[lock]
                fmt.sbprintf(w,"    %s[%d]={{int(offset_of(%s,%s))-int(offset_of(%s,%s)),%d,LOCK_NAMES[:],\"%s\"}}\n",locks,li,struct_names[int(t.place)],target.field,struct_names[int(t.place)],t.field,t.lock_id,target.name)
            }
        }
        table_row(w,i,t,t.name,fmt.tprintf("offset_of(%s,%s)",struct_names[int(t.place)],t.field),t.place,false,locks)
        i+=1
    }
    fmt.sbprintf(w,"    storages:=make([]%s.Storage_Info,%d)\n",core_alias,len(storage_index)+int(cursors[1]>0))
    if cursors[1]>0 {fmt.sbprintf(w,"    storages[%d]={{name=\"Event_Cursors\",library=\"world\",type=typeid_of(Event_Cursors),info=type_info_of(Event_Cursors),offset=offset_of(World,event_cursors)}}\n",len(storage_index))}
    i=0
    for t in g.types {
        if t.kind!=.Storage || !included(t,editor) {continue}
        storage_row(w,i,t,t.name,fmt.tprintf("offset_of(%s,%s)",struct_names[int(t.place)],t.field),t.place,false)
        i+=1
    }
    fmt.sbprintf(w,"    messages:=make([]%s.Message_Info,%d)\n",core_alias,len(g.messages))
    for m,mi in g.messages {
        fmt.sbprintf(w,"    messages[%d]={{\"%s\",\"%s\",typeid_of(%s.%s),type_info_of(%s.%s),.%v,%v}}\n",mi,m.name,m.pkg.name,m.pkg.alias,m.name,m.pkg.alias,m.name,m.from,m.reliable)
    }
    named_count,bits_count:=0,0
    for value in g.named_values {
        if editor || !value.pkg.editor && !value.type.pkg.editor {named_count+=1}
    }
    for t in g.named_type_list {
        if t.bits_of!="" && (editor || !t.pkg.editor) {bits_count+=1}
    }
    fmt.sbprintf(w,"    names:=make([]%s.Name_Info,%d)\n",core_alias,named_count)
    i=0
    for value in g.named_values {
        if (value.pkg.editor || value.type.pkg.editor) && !editor {continue}
        number:=value.action!=nil?fmt.tprintf("%d",value.number):fmt.tprintf("%s.%s",value.pkg.alias,value.ident)
        fmt.sbprintf(w,"    names[%d]={{typeid_of(%s.%s),i64(%s),%q,\"%s\",%q,%d,%v,%v,%s}}\n",i,value.type.pkg.alias,value.type.name,number,value.name,value.pkg.name,value.file,value.line,value.explicit,strings.has_prefix(value.pkg.path,"project:"),value.requires_type!=nil && (editor || value.requires_type.place!=.Editor)?fmt.tprintf("typeid_of(%s.%s)",value.requires_type.pkg.alias,value.requires_type.name):"nil")
        i+=1
    }
    types_count:=0
    for t in g.named_type_list {
        if t.bits_of=="" && (editor || !t.pkg.editor) {types_count+=1}
    }
    fmt.sbprintf(w,"    named_types:=make([]%s.Named_Type_Info,%d)\n",core_alias,types_count)
    i=0
    for t in g.named_type_list {
        if t.bits_of!="" || t.pkg.editor && !editor {continue}
        limit:=fmt.tprintf("i64(1)<<uint(min(8*size_of(%s.%s),63))",t.pkg.alias,t.name)
        for mask in g.named_type_list {
            if mask.bits_of==t.key {limit=fmt.tprintf("min(%s,i64(8*size_of(%s.%s)))",limit,mask.pkg.alias,mask.name)}
        }
        fmt.sbprintf(w,"    named_types[%d]={{typeid_of(%s.%s),%q,%q,%q,%s,%v}}\n",i,t.pkg.alias,t.name,t.name,t.pkg.path,t.prefix,limit,t.actions)
        i+=1
    }
    fmt.sbprintf(w,"    name_bits:=make([]%s.Name_Bits_Info,%d)\n",core_alias,bits_count)
    i=0
    for t in g.named_type_list {
        if t.bits_of=="" || t.pkg.editor && !editor {continue}
        of:=g.named_types[t.bits_of]
        fmt.sbprintf(w,"    name_bits[%d]={{typeid_of(%s.%s),typeid_of(%s.%s)}}\n",i,t.pkg.alias,t.name,of.pkg.alias,of.name)
        i+=1
    }
    fmt.sbprintf(w,"    actions:=make([]%s.Actions_Info,%d)\n",core_alias,len(g.action_enums))
    for a,ai in g.action_enums {
        _,has_defaults:=actions_defaults_value(a)
        fmt.sbprintf(w,"    actions[%d]={{typeid_of(%s.%s),type_info_of(%s.%s),%d,\"%s\",%s}}\n",ai,a.pkg.alias,a.name,a.pkg.alias,a.name,a.base,a.pkg.name,has_defaults?fmt.tprintf("action_defaults_%d",ai):"nil")
    }
    fmt.sbprintf(w,"    records:=make([]%s.Record_Info,%d)\n",core_alias,len(g.records))
    for r,ri in g.records {
        tag:=fmt.tprintf("%s_%s",snake(r.pkg.name),snake(r.name))
        _,has_default:=record_default(r)
        game:=strings.has_prefix(r.pkg.path,"project:") && !strings.has_prefix(r.pkg.path,"project:plugins/")
        fmt.sbprintf(w,"    records[%d]={{\"%s\",\"%s\",typeid_of(%s.%s),type_info_of(%s.%s),typeid_of(%s.Record(%s.%s)),%s,%q,%s,%v}}\n",ri,r.name,r.pkg.name,r.pkg.alias,r.name,r.pkg.alias,r.name,core_alias,r.pkg.alias,r.name,has_default?fmt.tprintf("record_default_%s",tag):"nil",r.description,len(r.fields)>0?fmt.tprintf("record_fields_%s[:]",tag):"nil",game)
    }
    fmt.sbprintf(w,"    steps:=make([]%s.Step_Info,%d)\n",core_alias,len(kept))
    for s,si in kept {
        phase_set:=strings.builder_make(context.temp_allocator)
        for on,p in s.phases {
            if on {fmt.sbprintf(&phase_set,".%s,",titles[p])}
        }
        loop_set:=strings.builder_make(context.temp_allocator)
        if s.loops[0] {strings.write_string(&loop_set,".Game,")}
        if s.loops[1] {strings.write_string(&loop_set,".Editor,")}
        fmt.sbprintf(w,"    steps[%d]={{\"%s\",\"%s\",{{%s}},{{%s}},call_%s}}\n",si,s.name,s.pkg.name,strings.to_string(phase_set),strings.to_string(loop_set),s.name)
    }
    fmt.sbprintf(w,"    draws:=make([]%s.Draw_Info,%d)\n",core_alias,len(g.draws))
    for d,di in g.draws {fmt.sbprintf(w,"    draws[%d]={{%q,rawptr(%s.%s)}}\n",di,d.name,d.pkg.alias,d.ident)}
    fmt.sbprintf(w,"    info:%s.World_Info\n",core_alias)
    fmt.sbprint(w,"    info.sizes={.World=size_of(World),.Shared=size_of(Shared),.Editor=size_of(Editor)}\n")
    fmt.sbprint(w,"    info.aligns={.World=align_of(World),.Shared=align_of(Shared),.Editor=align_of(Editor)}\n")
    fmt.sbprint(w,"    info.entities,info.revisions=offset_of(World,entities),offset_of(World,storage_revisions)\n")
    fmt.sbprint(w,"    info.tables,info.storages,info.messages,info.steps=tables,storages,messages,steps\n")
    fmt.sbprint(w,"    info.named_types,info.names,info.name_bits,info.actions=named_types,names,name_bits,actions\n")
    fmt.sbprint(w,"    info.records=records\n")
    fmt.sbprint(w,"    info.draws=draws\n")
    if aged {fmt.sbprint(w,"    info.events_age=events_age\n")}
    if cursors[0]>0 {fmt.sbprint(w,"    info.events_rewind=events_rewind\n")}
    for loop in 0..<(editor?2:1) {
        for phase in 0..<len(PHASES) {
            if defined[loop][phase] {fmt.sbprintf(w,"    info.loops[.%s][.%s],info.order[.%s][.%s]=%s_%s,order_%s_%s[:]\n",loop==0?"Game":"Editor",titles[phase],loop==0?"Game":"Editor",titles[phase],loops[loop],phases[phase],loops[loop],phases[phase])}
        }
    }
    fmt.sbprintf(w,"    %s.world_info_index(&info)\n",core_alias)
    fmt.sbprint(w,"    return info\n}\n")
    return strings.to_string(b)
}

// A name of a package as the file being written says it: bare in the package
// the file is of, whose alias is "".
@(private="file")
ref :: proc(pkg:^Package,name:string) -> string {
    return pkg.alias==""?strings.clone(name):fmt.aprintf("%s.%s",pkg.alias,name)
}

// The type of a table or a storage as the file being written says it; one of
// a test world that no declaration names is said through its field (key).
@(private="file")
type_text :: proc(t:^Type) -> string {return t.pkg==nil?t.key:ref(t.pkg,t.name)}

// Writes the procedures the World_Info being written calls for a type, as
// core calls them, and keeps their names in it: what gives its default, its
// default on a GPU and what its attributes name. Of a component, the
// descriptions of its fields too. c: how the file says core, with its dot.
@(private="file")
type_procs_write :: proc(w:^strings.Builder,t:^Type,c:string) {
    type:=type_text(t)
    t.default,t.for_device,t.procs="nil","nil",""
    if value,found:=default_value(t);found {
        t.default=fmt.aprintf("default_%s",t.field)
        fmt.sbprintf(w,"%s :: proc(dst:rawptr) {{(cast(^%s)dst)^=%s}}\n",t.default,type,value)
    }
    if t.kind==.Component {
        if len(t.fields)==0 {return}
        fmt.sbprintf(w,"@(rodata) fields_%s:=[%d]%sField_Description{{",t.field,len(t.fields),c)
        for field,k in t.fields {fmt.sbprintf(w,"%s{{%q,%q}}",k>0?",":"",field.name,field.text)}
        fmt.sbprint(w,"}\n")
        return
    }
    if maker:=for_device_value(t);maker!="" {
        t.for_device=fmt.aprintf("for_device_%s",t.field)
        fmt.sbprintf(w,"%s :: proc(dst:rawptr,device:rawptr) {{(cast(^%s)dst)^=%s((cast(^gen_rhi.Device_Info)device)^)}}\n",t.for_device,type,maker)
    }
    Named :: struct {option,name:string,pair,result:bool}
    named:=[5]Named{{"copy",t.copy=="false"?"":t.copy,true,true},{"copy_kept",t.copy_kept,true,true},{"swap",t.swap,true,false},{"free",t.free,false,false},{"reset",t.reset,false,false}}
    list:=strings.builder_make()
    for n in named {
        if n.name=="" {continue}
        if n.pair {
            fmt.sbprintf(w,"%s_%s :: proc(a,b:rawptr)%s {{%s%s(cast(^%s)a,cast(^%s)b)}}\n",n.option,t.field,n.result?" -> bool":"",n.result?"return ":"",ref(t.pkg,n.name),type,type)
        } else {
            fmt.sbprintf(w,"%s_%s :: proc(value:rawptr) {{%s(cast(^%s)value)}}\n",n.option,t.field,ref(t.pkg,n.name),type)
        }
        fmt.sbprintf(&list,"%s%s=%s_%s",strings.builder_len(list)>0?",":"",n.option,n.option,t.field)
    }
    t.procs=strings.to_string(list)
}

// Whether the game of a project declares a type, not the engine or a plugin.
@(private="file")
of_game :: proc(t:^Type) -> bool {
    return t.pkg!=nil && strings.has_prefix(t.pkg.path,"project:") && !strings.has_prefix(t.pkg.path,"project:plugins/")
}

// The row of info.tables of a table of a type, after type_procs_write: name,
// what the scene file and the API call it; offset, where it is in the struct
// of its place. named: its fields go by name, as those of a test world do:
// the file git keeps for core, written by a build of before, still compiles
// when core adds a field; the world of a game is refused until the generator
// writes it.
@(private="file")
table_row :: proc(w:^strings.Builder,index:int,t:^Type,name,offset:string,place:core.Place,game:bool,locks:string,named:=false) {
    type:=type_text(t)
    fields:=len(t.fields)>0?fmt.tprintf("fields_%s[:]",t.field):"nil"
    base:=t.pkg!=nil && t.pkg.path=="mirai:core" && t.file!=nil && !strings.has_suffix(t.file.fullpath,"_test.odin")
    NAMED :: "    tables[%d]={{name=%q,library=%q,type=typeid_of(%s),info=type_info_of(%s),offset=%s,place=.%v,shared=%v,replicated=.%v,game=%v,default=%s,description=%q,fields=%s,single=%v,far=%v,derived=%v,was=%q,base=%v,locks=%s}}\n"
    fmt.sbprintf(w,named?NAMED:"    tables[%d]={{%q,%q,typeid_of(%s),type_info_of(%s),%s,.%v,%v,.%v,%v,%s,%q,%s,%v,%v,%v,%q,%v,%s,false}}\n",index,name,t.pkg!=nil?t.pkg.name:"",type,type,offset,place,t.shared,t.replication,game || of_game(t),t.default,t.description,fields,t.single,t.far,t.derived,t.was,base,locks)
}

// The row of info.storages of a storage of a type, as table_row.
@(private="file")
storage_row :: proc(w:^strings.Builder,index:int,t:^Type,name,offset:string,place:core.Place,game:bool,named:=false) {
    type:=type_text(t)
    NAMED :: "    storages[%d]={{name=%q,library=%q,type=typeid_of(%s),info=type_info_of(%s),offset=%s,place=.%v,setting=.%v,default=%s,by_world=%v,for_device=%s,persist=%v,keep=%v,plugin=%q,game=%v,local=%v,procs={{%s}}}}\n"
    fmt.sbprintf(w,named?NAMED:"    storages[%d]={{%q,%q,typeid_of(%s),type_info_of(%s),%s,.%v,.%v,%s,%v,%s,%v,%v,%q,%v,%v,{{%s}},false}}\n",index,name,t.pkg!=nil?t.pkg.name:"",type,type,offset,place,t.setting,t.default,t.by_world,t.for_device,t.persist,t.keep,t.pkg!=nil?project.import_plugin(t.pkg.path):"",game || of_game(t),t.copy=="false",t.procs)
}

// The file mirai writes in the folder of a package whose tests declare a
// @(test_world): their World_Info and what makes a world of them.
TEST_WORLDS_FILE :: "worlds_gen_test.odin"

// A table or a storage a test world holds.
@(private="file")
Test_Field :: struct {
    type:^Type,
    name:string,   // of its table or storage in the World_Info
    offset:string, // in the struct of its place
    place:core.Place,
    game:bool,
}

// A struct @(test_world) of a test file: the World of a test, declared by
// hand, whose World_Info the generator writes as it writes that of a game.
// It starts with `using world:Test_World` and each other field is a table,
// core.Table(T), an array of them or a storage, a value; a field with using
// is a group, the tables and storages a library gives the test worlds of
// others together. host and editor name the structs of what the application
// and the editor hold, where a by_world storage is a core.By_World(T). The
// tag of a field takes `mirai:"game"`, the game of a project declares it, and
// `mirai:"name=Spin"`, the name its table or storage goes by.
@(private="file")
Test_World :: struct {
    name:string,
    structs:[core.Place]string,
    fields:[dynamic]Test_Field, // tables first, then storages, each as its struct declares them
    tables:int,
    headed:bool,
}

// Writes TEST_WORLDS_FILE in the folder of each package a build of tests
// reads with its tests and whose tests declare a @(test_world), when its text
// changed, and removes one left where none is declared now. starts: the
// folders the build is given; the packages they import follow, those of the
// project (project_root; "" outside one) and, when the build reads the engine
// from its sources and not from its libraries, which bring no test, those of
// the engine and its plugins. errors: what no World_Info can be written of,
// with how to fix it. stamp: a file that keeps the folders the last call
// read and what they held, by the names, sizes and dates of their sources,
// with the program that read them: while they stand nothing is read again.
test_worlds_write :: proc(engine_root,project_root:string,starts:[]string,engine_sources:bool,stamp:string,allocator:=context.allocator) -> (errors:[]string) {
    context.allocator=allocator
    // What the folders hold, with what was asked and who asks: another build of the generator may write otherwise.
    held :: proc(folders:[]string,starts:[]string,engine_sources:bool) -> u64 {
        hash:=u64(engine_sources)
        if program,error:=os.stat(os.args[0],context.temp_allocator);error==nil {hash=base.hash_combine(hash,u64(time.to_unix_nanoseconds(program.modification_time)))}
        for start in starts {hash=base.hash_combine(hash,base.name_hash(start))}
        for folder in folders {
            entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
            slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
            for entry in entries {
                if !strings.has_suffix(entry.name,".odin") {continue}
                hash=base.hash_combine(base.hash_combine(base.hash_combine(hash,base.name_hash(entry.name)),u64(entry.size)),u64(time.to_unix_nanoseconds(entry.modification_time)))
            }
        }
        return hash
    }
    if data,error:=os.read_entire_file(stamp,context.temp_allocator);error==nil {
        lines:=strings.split_lines(strings.trim_space(string(data)),context.temp_allocator)
        if saved,parsed:=strconv.parse_u64_of_base(lines[0],16);parsed && saved==held(lines[1:],starts,engine_sources) {return nil}
    }
    g:Generator
    g.by_key=make(map[string]^Type)
    g.engine_root,g.root=slashes(engine_root,allocator),slashes(project_root,allocator)
    core_package:=test_package(&g,"mirai:core")
    if core_package==nil {return g.errors[:]}
    queue:=make([dynamic]^Package)
    for start in starts {
        folder:=slashes(project.path_absolute(start,context.temp_allocator),allocator)
        path:string
        for c in ([3][2]string{{"project",g.root},{"plugins",project.path(g.engine_root,"plugins",allocator=context.temp_allocator)},{"mirai",g.engine_root}}) {
            root:=c[1]
            if root=="" || len(folder)<=len(root) || folder[len(root)]!='/' || !project.path_same(folder[:len(root)],root) {continue}
            path=fmt.aprintf("%s:%s",c[0],folder[len(root)+1:])
            break
        }
        if pkg:=test_package(&g,path);pkg!=nil && !slice.contains(queue[:],pkg) {append(&queue,pkg)}
    }
    for at:=0;at<len(queue);at+=1 {
        pkg:=queue[at]
        for file in pkg.files {
            for imp in file.imports {
                path:=strings.trim(imp.relpath.text,"\"`")
                if !strings.has_prefix(path,"project:") && !(engine_sources && (strings.has_prefix(path,"mirai:") || strings.has_prefix(path,"plugins:"))) {continue}
                if next:=test_package(&g,path);next!=nil && !slice.contains(queue[:],next) {append(&queue,next)}
            }
        }
    }
    for pkg in queue {
        file:=project.path(pkg.folder,TEST_WORLDS_FILE,allocator=context.temp_allocator)
        worlds:=test_worlds_read(&g,pkg)
        if len(worlds)==0 {
            if os.is_file(file) {_=os.remove(file)}
            continue
        }
        if len(g.errors)>0 {continue}
        text:=test_worlds_text(&g,pkg,core_package,worlds)
        if current,error:=os.read_entire_file(file,context.temp_allocator);error==nil && string(current)==text {continue}
        if os.write_entire_file(file,text)!=nil {append(&g.errors,fmt.aprintf("%s: could not be written",file))}
    }
    if len(g.errors)==0 {
        folders:=make([dynamic]string,context.temp_allocator)
        for pkg in g.packages {append(&folders,pkg.folder)}
        _=os.make_directory_all(stamp[:max(strings.last_index_byte(stamp,'/'),0)])
        _=os.write_entire_file(stamp,fmt.tprintf("%x\n%s\n",held(folders[:],starts,engine_sources),strings.join(folders[:],"\n",context.temp_allocator)))
    }
    return g.errors[:]
}

// The package at an import path of the engine, its plugins or the project,
// read once with its tests; nil for another, or when it does not parse.
@(private="file")
test_package :: proc(g:^Generator,path:string) -> ^Package {
    for pkg in g.packages {
        if pkg.path==path {return len(pkg.files)>0?pkg:nil}
    }
    folder:string
    switch {
    case strings.has_prefix(path,"mirai:"):                 folder=project.path(g.engine_root,path[len("mirai:"):])
    case strings.has_prefix(path,"plugins:"):               folder=project.path(g.engine_root,"plugins",path[len("plugins:"):])
    case strings.has_prefix(path,"project:") && g.root!="": folder=project.path(g.root,path[len("project:"):])
    case: return nil
    }
    pkg:=new(Package)
    pkg.path,pkg.folder=path,folder
    append(&g.packages,pkg)
    if !os.is_dir(folder) || !package_sources(g,pkg,true) {return nil}
    same:=0
    for other in g.packages {
        if other!=pkg && other.name==pkg.name {same+=1}
    }
    pkg.alias=same>0?fmt.aprintf("p_%s%d",pkg.name,same):fmt.aprintf("p_%s",pkg.name)
    return pkg
}

// The declaration of a name at the top of the files of a package.
@(private="file")
decl_find :: proc(pkg:^Package,name:string) -> (file:^ast.File,decl:^ast.Value_Decl,found:bool) {
    if pkg==nil {return}
    for f in pkg.files {
        for stmt in f.decls {
            d,is_value:=stmt.derived.(^ast.Value_Decl)
            if is_value && !d.is_mutable && len(d.names)==1 && len(d.values)==1 && ident_name(d.names[0])==name {return f,d,true}
        }
    }
    return
}

// The structs @(test_world) the test files of a package declare, each with
// its tables and storages.
@(private="file")
test_worlds_read :: proc(g:^Generator,pkg:^Package) -> []^Test_World {
    worlds:=make([dynamic]^Test_World)
    for file in pkg.files {
        for stmt in file.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
            options:=attributes_read(decl.attributes[:])
            if "test_world" not_in options {continue}
            tw:=new(Test_World)
            tw.name=ident_name(decl.names[0])
            where_:=fmt.aprintf("%s(%d): %s",file.fullpath,decl.pos.line,tw.name)
            if !strings.has_suffix(file.fullpath,"_test.odin") {
                append(&g.errors,fmt.aprintf("%s is a @(test_world) outside a test: declare it in a file _test.odin",where_))
                continue
            }
            tw.structs={.World=tw.name,.Shared=options["host"] or_else "",.Editor=options["editor"] or_else ""}
            storages:=make([dynamic]Test_Field)
            for place in core.Place {
                if tw.structs[place]=="" {continue}
                record:^ast.Struct_Type
                if _,held,found:=decl_find(pkg,tw.structs[place]);found {record,_=held.values[0].derived.(^ast.Struct_Type)}
                if record==nil {
                    append(&g.errors,fmt.aprintf("%s: %s is not a struct at the top of a file of its package: a test world, and what it names with host and editor, are structs of tables and storages a test file declares outside its procedures",where_,tw.structs[place]))
                    continue
                }
                test_fields_read(g,tw,&storages,place,pkg,pkg,file,record)
            }
            if !tw.headed {append(&g.errors,fmt.aprintf("%s has no `using world:Test_World`: the entities and the revisions of the storages of a test world are in the header its package is given, which goes first",where_))}
            tw.tables=len(tw.fields)
            append(&tw.fields,..storages[:])
            for f,i in tw.fields {
                for other in tw.fields[:i] {
                    if other.type.key==f.type.key && other.place==f.place && other.name==f.name {append(&g.errors,fmt.aprintf("%s holds %s twice: a World has one table of a component and one value of a storage; a second of one type takes another name with the tag `mirai:\"name=Other\"`",where_,f.name))}
                }
            }
            append(&worlds,tw)
        }
    }
    return worlds[:]
}

// The fields of a struct of a place of a test world, or of a group of it.
// owner: the package of the world; pkg, file: where the struct is declared.
@(private="file")
test_fields_read :: proc(g:^Generator,tw:^Test_World,storages:^[dynamic]Test_Field,place:core.Place,owner,pkg:^Package,file:^ast.File,record:^ast.Struct_Type) {
    for field in record.fields.list {
        for n in field.names {
            name:=ident_name(n)
            if name=="_" {continue}
            where_:=fmt.aprintf("%s(%d): %s of %s",file.fullpath,field.pos.line,name,tw.name)
            if .Using in field.flags {
                key:=type_key(g,file,pkg,field.type)
                if key==fmt.tprintf("%s.Test_World",owner.path) && place==.World {
                    tw.headed=true
                    continue
                }
                dot:=max(strings.last_index_byte(key,'.'),0)
                from:=test_package(g,key[:dot])
                group_file,group,found:=decl_find(from,key[min(dot+1,len(key)):])
                group_record:^ast.Struct_Type
                if found {group_record,_=group.values[0].derived.(^ast.Struct_Type)}
                if group_record==nil {
                    append(&g.errors,fmt.aprintf("%s: a field with using is the header, `using world:Test_World` of its own package, or a group, a struct of tables and storages declared at the top of a file; %s is neither",where_,expr_text(file,field.type)))
                    continue
                }
                test_fields_read(g,tw,storages,place,owner,from,group_file,group_record)
                continue
            }
            tag,invalid:=serial.field_tag(strings.trim(field.tag.text,"`"))
            if invalid!="" {
                append(&g.errors,fmt.aprintf("%s: %s",where_,invalid))
                continue
            }
            f:=Test_Field{place=place,offset=fmt.aprintf("offset_of(%s,%s)",tw.structs[place],name),game=.Game in tag.hints}
            held,kind,by_world,count:=field.type,Kind.Storage,false,-1
            if array,is_array:=held.derived.(^ast.Array_Type);is_array && array.len!=nil {
                if call,is_call:=array.elem.derived.(^ast.Call_Expr);is_call && type_key(g,file,pkg,call.expr)=="mirai:core.Table" {
                    lit,is_lit:=array.len.derived.(^ast.Basic_Lit)
                    parsed:=false
                    if is_lit {count,parsed=strconv.parse_int(lit.tok.text)}
                    if !parsed || count<=0 {
                        append(&g.errors,fmt.aprintf("%s: an array of tables says how many as a number, as in [3]core.Table(T): each is a table of its own, named after its type and its index",where_))
                        continue
                    }
                    held=array.elem
                }
            }
            if call,is_call:=held.derived.(^ast.Call_Expr);is_call && len(call.args)>0 {
                switch type_key(g,file,pkg,call.expr) {
                case "mirai:core.Table":    held,kind=call.args[0],.Component
                case "mirai:core.By_World": held,by_world=call.args[0],true
                }
            }
            if kind==.Component && place==.Shared || by_world && place!=.Shared {
                append(&g.errors,fmt.aprintf("%s: a table goes in the World or in the struct editor names, and a core.By_World in the struct host names",where_))
                continue
            }
            f.type=test_type_read(g,file,pkg,held,kind,where_)
            if f.type==nil {continue}
            t:=f.type
            if t.pkg==nil {
                t.name=name
                t.key=fmt.aprintf("type_of((^%s)(nil).%s%s%s)",tw.structs[place],name,count>0?"[0]":"",kind==.Component?".values[0]":"")
            } else if t.file==nil {
                t.by_world=by_world
            } else {
                switch {
                case t.kind!=kind:
                    append(&g.errors,fmt.aprintf("%s: %s is a %s: a test world holds it as %s",where_,t.name,t.kind==.Component?"@(component)":"@(storage)",t.kind==.Component?fmt.tprintf("core.Table(%s)",t.name):"a value"))
                    continue
                case kind==.Storage && t.by_world!=by_world:
                    append(&g.errors,fmt.aprintf("%s: %s is %sby_world: the struct host names holds it as %s",where_,t.name,t.by_world?"":"not ",t.by_world?fmt.tprintf("core.By_World(%s)",t.name):"a value"))
                    continue
                case kind==.Storage && t.host!=(place==.Shared):
                    append(&g.errors,fmt.aprintf("%s: %s is %s: it goes in %s",where_,t.name,t.host?"@(storage,host)":"not @(storage,host)",t.host?"the struct the world names with host":"the World, or in the struct it names with editor"))
                    continue
                }
            }
            f.name=t.name
            if tag.name!="" {f.name=tag.name}
            if kind==.Storage {
                append(storages,f)
                continue
            }
            for k in 0..<max(count,1) {
                if count>0 {
                    f.name=fmt.aprintf("%s_%d",t.name,k)
                    f.offset=fmt.aprintf("offset_of(%s,%s)+%d*size_of((^%s)(nil).%s[0])",tw.structs[place],name,k,tw.structs[place],name)
                }
                append(&tw.fields,f)
            }
        }
    }
}

// The type a field of a test world holds a table or a value of: a @(component)
// or a @(storage) of the package that declares it, read as the generator
// reads those of a game; a type a test file declares without attributes, a
// plain component or storage; or a type no declaration at the top of a file
// names (u32, [dynamic]u32), which has no package. nil, with the error said,
// for another.
@(private="file")
test_type_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,expr:^ast.Expr,kind:Kind,where_:string) -> ^Type {
    key:=type_key(g,file,pkg,expr)
    if t,read:=g.by_key[key];read {return t}
    dot:=max(strings.last_index_byte(key,'.'),0)
    name:=key[min(dot+1,len(key)):]
    from:=test_package(g,key[:dot])
    declared_file,decl,found:=decl_find(from,name)
    if !found {
        if _,is_selector:=expr.derived.(^ast.Selector_Expr);is_selector {
            append(&g.errors,fmt.aprintf("%s: %s is not declared at the top of a file of a package of the engine, its plugins or the project",where_,expr_text(file,expr)))
            return nil
        }
        t:=new(Type)
        t.kind,t.default,t.for_device=kind,"nil","nil"
        return t
    }
    options:=attributes_read(decl.attributes[:])
    _,is_component:=options["component"]
    _,is_storage:=options["storage"]
    t:^Type
    switch {
    case is_component || is_storage:
        t=type_read(g,declared_file,from,decl,name,options,false)
        if t==nil {return nil}
    case type_key(g,declared_file,from,decl.values[0])!="":
        // Another name of a type: scene.Prefab_Instance is asset.Prefab_Instance.
        t=test_type_read(g,declared_file,from,decl.values[0],kind,where_)
        if t==nil || t.pkg==nil {return t}
    case strings.has_suffix(declared_file.fullpath,"_test.odin"):
        t=new(Type)
        t.name,t.pkg,t.key,t.kind=name,from,key,kind
    case:
        append(&g.errors,fmt.aprintf("%s: %s is not a @(component) or a @(storage): a test world holds what a generated one would, or a type a test file declares",where_,expr_text(file,expr)))
        return nil
    }
    g.by_key[key]=t
    return t
}

// The text of TEST_WORLDS_FILE of a package: the header of its test worlds,
// the World_Info of each and the procedures that make a world of one.
@(private="file")
test_worlds_text :: proc(g:^Generator,pkg,core_package:^Package,worlds:[]^Test_World) -> string {
    b:=strings.builder_make()
    w:=&b
    alias:=pkg.alias
    pkg.alias=""
    defer pkg.alias=alias
    c:=core_package==pkg?"":fmt.tprintf("%s.",core_package.alias)
    types:=make([dynamic]^Type,context.temp_allocator)
    imported:=make([dynamic]^Package,context.temp_allocator)
    if core_package!=pkg {append(&imported,core_package)}
    device,revisions:=false,0
    for tw in worlds {
        revisions=max(revisions,len(tw.fields)-tw.tables)
        for f in tw.fields {
            t:=f.type
            if t.pkg==nil || slice.contains(types[:],t) {continue}
            append(&types,t)
            t.field=fmt.aprintf("test_world_%s%s%s",t.pkg.alias,t.pkg.alias!=""?"_":"",snake(t.name))
            device||=t.kind==.Storage && for_device_value(t)!=""
            if t.pkg!=pkg && !slice.contains(imported[:],t.pkg) {append(&imported,t.pkg)}
        }
    }
    fmt.sbprintf(w,"// Generated by mirai. Do not edit.\npackage %s\n\nimport \"core:testing\"\n",pkg.name)
    for other in imported {fmt.sbprintf(w,"import %s \"%s\"\n",other.alias,other.path)}
    if device {fmt.sbprint(w,"import gen_rhi \"mirai:rhi\"\n")}
    template,_:=strings.replace_all(TEST_WORLDS_TEMPLATE,"C.",c,context.temp_allocator)
    template,_=strings.replace_all(template,"[N]",fmt.tprintf("[%d]",revisions),context.temp_allocator)
    strings.write_string(w,template)
    for t in types {type_procs_write(w,t,c)}
    for tw in worlds {
        id:=snake(tw.name)
        holders:=make([dynamic]int,context.temp_allocator)
        for f,i in tw.fields[:tw.tables] {
            if f.place==.World && len(f.type.locks)>0 {append(&holders,i)}
        }
        if len(holders)>0 {
            fmt.sbprintf(w,"@(rodata) test_world_lock_names_%s:=[?]string{{\"\"",id)
            for i in holders {fmt.sbprintf(w,",\"%s.%s\"",tw.fields[i].type.pkg.name,tw.fields[i].name)}
            fmt.sbprint(w,"}\n")
        }
        fmt.sbprintf(w,"@(private=\"file\")\ntest_info_%s :: proc(allocator:=context.allocator) -> (info:%sWorld_Info,ok:bool) {{\n    context.allocator=allocator\n",id,c)
        fmt.sbprintf(w,"    tables,tables_error:=make([]%sTable_Info,%d)\n    storages,storages_error:=make([]%sStorage_Info,%d)\n",c,tw.tables,c,len(tw.fields)-tw.tables)
        fmt.sbprint(w,"    if tables_error!=nil || storages_error!=nil {\n        delete(tables);delete(storages)\n        return\n    }\n")
        for f,i in tw.fields {
            if i>=tw.tables {
                storage_row(w,i-tw.tables,f.type,f.name,f.offset,f.place,f.game,true)
                continue
            }
            locks:="nil"
            if holder,holds:=slice.linear_search(holders[:],i);holds {
                // A test world holds some of the tables of a game: a lock on one it lacks owns nothing.
                targets:=make([dynamic]Test_Field,context.temp_allocator)
                for key in f.type.locks {
                    for other in tw.fields[:tw.tables] {
                        if other.place==.World && other.type.key==key {append(&targets,other)}
                    }
                }
                locks=fmt.tprintf("locks_%d",i)
                fmt.sbprintf(w,"    %s:=make([]%sLock,%d)\n",locks,c,len(targets))
                for target,li in targets {
                    fmt.sbprintf(w,"    %s[%d]={{int(%s)-int(%s),%d,test_world_lock_names_%s[:],%q}}\n",locks,li,target.offset,f.offset,holder+1,id,target.name)
                }
            }
            table_row(w,i,f.type,f.name,f.offset,f.place,f.game,locks,true)
        }
        for of in ([2]string{"size_of","align_of"}) {
            fmt.sbprintf(w,"    info.%ss={{",of[:len(of)-3])
            for place in core.Place {
                fmt.sbprintf(w,"%s.%v=%s",place==.World?"":",",place,tw.structs[place]!=""?fmt.tprintf("%s(%s)",of,tw.structs[place]):"1")
            }
            fmt.sbprint(w,"}\n")
        }
        fmt.sbprintf(w,"    info.entities,info.revisions=offset_of(%s,entities),offset_of(%s,storage_revisions)\n",tw.name,tw.name)
        fmt.sbprintf(w,"    info.tables,info.storages=tables,storages\n    %sworld_info_index(&info)\n    return info,true\n}}\n\n",c)
    }
    fmt.sbprintf(w,"// The World_Info of a @(test_world) of this package, which says of its tables\n// and storages what that of a game says: test_info_destroy frees it.\ntest_info :: proc(t:^testing.T,$W:typeid,allocator:=context.allocator,loc:=#caller_location) -> (info:%sWorld_Info,ok:bool) {{\n",c)
    for tw,i in worlds {fmt.sbprintf(w,"    %swhen W==%s {{info,ok=test_info_%s(allocator)}}\n",i>0?"else ":"",tw.name,snake(tw.name))}
    fmt.sbprintf(w,"    else {{#panic(\"test_info: W is not a @(test_world) of the tests of %s; mark its struct, at the top of a test file of this package, with @(test_world)\")}}\n",pkg.name)
    fmt.sbprint(w,"    testing.expect(t,ok,\"no memory for the World_Info of a test world\",loc=loc)\n    return\n}\n")
    return strings.to_string(b)
}

// What TEST_WORLDS_FILE gives the tests of a package besides the World_Info
// of each world; C. is core, and N the storages of the world with the most.
@(private="file")
TEST_WORLDS_TEMPLATE :: `
// What a @(test_world) starts with: its entities, the revisions of its
// storages and, in a world test_world_init made, its World_Info.
Test_World :: struct {
    entities:C.Entities,
    storage_revisions:[N]u64,
    made_of:C.World_Info,
}

// Indexes a World_Info again after the test gave it names, records or name
// bits, which its schema holds.
test_info_index :: proc(info:^C.World_Info,allocator:=context.allocator) {
    C.world_schema_destroy(info.schema)
    delete(info.tables_by_type);delete(info.storages_by_type)
    info.schema,info.tables_by_type,info.storages_by_type=nil,nil,nil
    C.world_info_index(info,allocator)
}

test_info_destroy :: proc(info:^C.World_Info,allocator:=context.allocator) {
    C.world_schema_destroy(info.schema)
    delete(info.tables_by_type);delete(info.storages_by_type)
    for table in info.tables {delete(table.locks,allocator)}
    delete(info.tables,allocator);delete(info.storages,allocator)
    info^={}
}

// Makes a world that holds its own World_Info, for a test that needs no
// application: test_world_destroy frees both. False, with the test failed,
// without memory.
test_world_init :: proc(t:^testing.T,w:^$W,allocator:=context.allocator,loc:=#caller_location) -> bool {
    w.made_of=test_info(t,W,allocator,loc) or_return
    if C.world_init(&w.made_of,.World,w,allocator) {return true}
    test_world_destroy(w,allocator)
    return testing.expect(t,false,"no memory for a test world",loc=loc)
}

test_world_destroy :: proc(w:^$W,allocator:=context.allocator) {
    if w.made_of.sizes[.World]==0 {return}
    C.world_destroy(&w.made_of,.World,w)
    test_info_destroy(&w.made_of,allocator)
}

test_world_info :: proc(w:^$W) -> ^C.World_Info {return &w.made_of}

test_world_ref :: proc(w:^$W) -> C.World_Ref {return {data=w,info=&w.made_of,place=.World}}

// The settle of a world test_world_init made: how many tables it came to.
test_world_settle :: proc(w:^$W) -> int {return C.settle(&w.made_of,w,nil)}

test_world_copy :: proc(dst,src:^$W) -> bool {return C.world_copy(&src.made_of,dst,src)}

test_world_swap :: proc(a,b:^$W) {C.world_swap(&a.made_of,a,b)}

test_world_clear :: proc(w:^$W) -> bool {return C.world_clear(&w.made_of,w)}

`

// The type of an arg of a step as the generated world writes it; "" for a
// part of the application, which a mind does not receive.
@(private="file")
param_type :: proc(g:^Generator,param:Param,core_alias:string) -> string {
    if b:=param.bundle;b!=nil {
        if param.actions!=nil {return fmt.tprintf("%s.%s(%s.%s)",b.pkg.alias,b.name,param.actions.pkg.alias,param.actions.name)}
        return fmt.tprintf("%s.%s",b.pkg.alias,b.name)
    }
    #partial switch param.kind {
    case .Table_Write: return fmt.tprintf("^%s.Table(%s.%s)",core_alias,param.type.pkg.alias,param.type.name)
    case .Table_Read: return fmt.tprintf("^%s.Table(%s.%s,.Read)",core_alias,param.type.pkg.alias,param.type.name)
    case .Storage_Write: return fmt.tprintf("^%s.%s",param.type.pkg.alias,param.type.name)
    case .Storage_Ref: return fmt.tprintf("%s.Ref(%s.%s)",core_alias,param.type.pkg.alias,param.type.name)
    case .Storage_Value: return fmt.tprintf("%s.%s",param.type.pkg.alias,param.type.name)
    case .Storage_Stamp: return fmt.tprintf("%s.Stamp(%s.%s)",core_alias,param.type.pkg.alias,param.type.name)
    case .Entities_Read: return fmt.tprintf("%s.Ref(%s.Entities)",core_alias,core_alias)
    case .Commands: return fmt.tprintf("%s.Commands",core_alias)
    case .World_Ref: return fmt.tprintf("%s.World_Ref",core_alias)
    case .Records: return fmt.tprintf("%s.Records(%s.%s)",core_alias,param.record.pkg.alias,param.record.name)
    case .Inbox: return fmt.tprintf("%s.Inbox(%s.%s)",core_alias,g.messages[param.message].pkg.alias,g.messages[param.message].name)
    }
    return ""
}

@(private="file")
alias_of :: proc(g:^Generator,path:string) -> string {
    for pkg in g.packages {
        if pkg.path==path {return pkg.alias}
    }
    return ""
}

@(private="file")
count_kind :: proc(g:^Generator,kind:Kind,editor:bool) -> (n:int) {
    for t in g.types {
        if t.kind==kind && (editor || t.place!=.Editor) {n+=1}
    }
    return
}

@(private="file")
is_keyword :: proc(name:string) -> bool {
    switch name {
    case "asm","auto_cast","bit_field","bit_set","break","case","cast","context","continue","defer","distinct","do","dynamic","else","enum","fallthrough","for","foreign","if","import","in","map","matrix","not_in","or_break","or_continue","or_else","or_return","package","proc","return","struct","switch","transmute","typeid","union","using","when","where","world","shared","editor","app","w","s","e":
        return true
    }
    return false
}

// What a component row or a storage starts as: <NAME>_DEFAULT or <name>_default() of its package.
@(private="file")
default_value :: proc(t:^Type) -> (value:string,found:bool) {
    buffer:[512]u8
    constant,maker,_:=core.default_names(t.name,buffer[:])
    switch {
    case t.pkg.names[constant]: return ref(t.pkg,constant),true
    case t.pkg.names[maker]:    return fmt.aprintf("%s()",ref(t.pkg,maker)),true
    }
    return "",false
}

// What a new row of a record type starts as: <NAME>_DEFAULT or <name>_default() of its package.
@(private="file")
record_default :: proc(r:^Record_Type) -> (value:string,found:bool) {
    return default_value(&Type{name=r.name,pkg=r.pkg})
}

// The default bindings of the members of an enum @(actions): <ENUM>_DEFAULTS or
// <enum>_defaults() of its package, a [E]Action_Bindings.
@(private="file")
actions_defaults_value :: proc(a:^Action_Enum) -> (value:string,found:bool) {
    buffer:[512]u8
    constant,maker,_:=core.default_names(a.name,buffer[:])
    constant,maker=fmt.tprintf("%sS",constant),fmt.tprintf("%ss",maker)
    switch {
    case a.pkg.names[constant]: return fmt.aprintf("%s.%s",a.pkg.alias,constant),true
    case a.pkg.names[maker]:    return fmt.aprintf("%s.%s()",a.pkg.alias,maker),true
    }
    return "",false
}

// The default of a storage on a GPU: <name>_for_device(device:rhi.Device_Info) of its package; "" without one.
@(private="file")
for_device_value :: proc(t:^Type) -> string {
    buffer:[512]u8
    _,_,maker:=core.default_names(t.name,buffer[:])
    return t.pkg.names[maker]?ref(t.pkg,maker):""
}

// The options of the attributes of a declaration: name, or name="value", or name=number.
attributes_read :: proc(attributes:[]^ast.Attribute) -> map[string]string {
    options:=make(map[string]string,context.temp_allocator)
    for attribute in attributes {
        for elem in attribute.elems {
            #partial switch v in elem.derived {
            case ^ast.Ident:
                options[v.name]=""
            case ^ast.Field_Value:
                name:=ident_name(v.field)
                if lit,is_lit:=v.value.derived.(^ast.Basic_Lit);is_lit {
                    if name=="description" {
                        options[name],_,_=strconv.unquote_string(lit.tok.text,context.temp_allocator)
                    } else {options[name]=strings.trim(lit.tok.text,"\"`")}
                } else if neg,is_unary:=v.value.derived.(^ast.Unary_Expr);is_unary {
                    if lit,inner:=neg.expr.derived.(^ast.Basic_Lit);inner {options[name]=fmt.tprintf("%s%s",neg.op.text,lit.tok.text)}
                } else if ident,is_ident:=v.value.derived.(^ast.Ident);is_ident {
                    options[name]=ident.name
                } else {
                    options[name]=""
                }
            }
        }
    }
    return options
}

// The tag of each field of a struct, and of the structs declared inside it,
// is one std/serial reads (serial.field_tag): a tag that is not one would only
// fail when the type reaches a schema, or leave the field without what it asks.
@(private="file")
field_tags_check :: proc(g:^Generator,file:^ast.File,name:string,value:^ast.Expr) {
    record,is_struct:=value.derived.(^ast.Struct_Type)
    if !is_struct || record.fields==nil {return}
    for field in record.fields.list {
        if field.type!=nil {field_tags_check(g,file,name,field.type)}
        text:=field.tag.text
        if len(text)<2 {continue}
        if text[0]=='`' {
            text=text[1:len(text)-1]
        } else if unquoted,_,unquoted_ok:=strconv.unquote_string(text,context.temp_allocator);unquoted_ok {
            text=unquoted
        }
        _,problem:=serial.field_tag(text)
        if problem=="" {continue}
        first:=len(field.names)>0?ident_name(field.names[0]):"_"
        append(&g.errors,fmt.aprintf("%s(%d:%d): %s.%s: %s",file.fullpath,field.tag.pos.line,field.tag.pos.column,name,first,problem))
    }
}

// The comment on the line of each field of the struct of a component: what
// component.list and the inspector show of the field.
@(private="file")
field_comments :: proc(fields:^[dynamic]core.Field_Description,value:^ast.Expr) {
    record,is_struct:=value.derived.(^ast.Struct_Type)
    if !is_struct || record.fields==nil {return}
    for field in record.fields.list {
        if field.comment==nil || len(field.comment.list)==0 {continue}
        text:=strings.builder_make()
        for token in field.comment.list {
            line:=strings.trim_space(strings.trim_prefix(token.text,"//"))
            if line=="" {continue}
            if strings.builder_len(text)>0 {strings.write_byte(&text,' ')}
            strings.write_string(&text,line)
        }
        if strings.builder_len(text)==0 {continue}
        for name in field.names {append(fields,core.Field_Description{ident_name(name),strings.to_string(text)})}
    }
}

// Where a type holds what the profile of the player does not keep: the field,
// what it is and how to keep it instead; what is "" for plain data. A type
// of a package the world does not read is taken as plain.
@(private="file")
persist_unkept :: proc(g:^Generator,file:^ast.File,pkg:^Package,expr:^ast.Expr,path:string,depth:int) -> (field,what,fix:string) {
    if expr==nil || depth>32 {return}
    LIST :: "give it a fixed array ([N]T) and a count"
    POINTER :: "keep the value it points at, or an id of it"
    #partial switch v in expr.derived {
    case ^ast.Dynamic_Array_Type: return path,"a dynamic array",LIST
    case ^ast.Map_Type:           return path,"a map","give it a fixed array of its pairs and a count"
    case ^ast.Union_Type:         return path,"a union","give it an enum of what it holds and the fields of each"
    case ^ast.Pointer_Type,^ast.Multi_Pointer_Type,^ast.Proc_Type: return path,"a pointer",POINTER
    case ^ast.Array_Type:
        if v.len==nil {return path,"a slice",LIST}
        return persist_unkept(g,file,pkg,v.elem,path,depth+1)
    case ^ast.Distinct_Type: return persist_unkept(g,file,pkg,v.type,path,depth+1)
    case ^ast.Paren_Expr:    return persist_unkept(g,file,pkg,v.expr,path,depth+1)
    case ^ast.Call_Expr:     return persist_unkept(g,file,pkg,v.expr,path,depth+1)
    case ^ast.Struct_Type:
        if v.fields==nil {return}
        for f in v.fields.list {
            name:=len(f.names)>0?ident_name(f.names[0]):""
            inner:=path==""?name:fmt.aprintf("%s.%s",path,name)
            if field,what,fix=persist_unkept(g,file,pkg,f.type,inner,depth+1);what!="" {return}
        }
    case ^ast.Ident:
        switch v.name {
        case "string","cstring":      return path,"a string","make it a [N]u8 that base.text_set writes"
        case "rawptr","any","typeid": return path,"a pointer",POINTER
        }
        if at,value,found:=type_decl(pkg,v.name);found {return persist_unkept(g,at,pkg,value,path,depth+1)}
    case ^ast.Selector_Expr:
        imported,found:=import_path(g,file,ident_name(v.expr))
        if !found {return}
        if v.field.name=="Entity" && (imported=="mirai:std/base" || imported=="mirai:core") {
            return path,"an Entity, which names nothing in another run","keep the Entity_Id of what it names (core.id_of)"
        }
        for other in g.packages {
            if other.path!=imported {continue}
            if at,value,ok:=type_decl(other,v.field.name);ok {return persist_unkept(g,at,other,value,path,depth+1)}
        }
    }
    return
}

// The value of the constant declaration of a name in a package.
@(private="file")
type_decl :: proc(pkg:^Package,name:string) -> (file:^ast.File,value:^ast.Expr,found:bool) {
    for f in pkg.files {
        for stmt in f.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || decl.is_mutable || len(decl.names)!=1 || len(decl.values)!=1 || ident_name(decl.names[0])!=name {continue}
            return f,decl.values[0],true
        }
    }
    return
}

@(private="file")
ident_name :: proc(expr:^ast.Expr) -> string {
    if ident,ok:=expr.derived.(^ast.Ident);ok {return ident.name}
    return ""
}

@(private="file")
expr_text :: proc(file:^ast.File,expr:^ast.Expr) -> string {
    if expr==nil {return ""}
    start,end:=expr.pos.offset,expr.end.offset
    if start<0 || end>len(file.src) || start>=end {return "?"}
    return file.src[start:end]
}

@(private="file")
snake :: proc(name:string) -> string {
    buffer:[256]u8
    return strings.clone(core.snake_name(name,buffer[:]))
}

// A type whose new rows start from a default: the fields its default sets,
// which a literal of it may not leave out.
@(private="file")
Defaulted :: struct {
    name,path:string,
    pkg:^Package,
    default:string,   // NAME_DEFAULT, or name_default()
    decl:string,      // the declaration that builds it, where its own literal goes
    order:[]string,   // its fields in order, for a literal without names
    set:[]string,     // what its default sets; every field for a procedure
}

// What the defaults of the world ask of the code: the defaults of the
// actions of an enum @(actions) are <ENUM>_DEFAULTS or <enum>_defaults()
// beside it, never a field of a component or storage; and a literal of a type
// whose default sets a field (NAME_DEFAULT or name_default()) names that
// field or starts from the default, since a field it leaves out is zero.
@(private="file")
defaults_check :: proc(g:^Generator) {
    defaulted:=make(map[string]^Defaulted,context.temp_allocator)
    add :: proc(g:^Generator,defaulted:^map[string]^Defaulted,name:string,pkg:^Package,file:^ast.File,value:^ast.Expr) {
        record,is_struct:=value.derived.(^ast.Struct_Type)
        if !is_struct || record.fields==nil {return}
        order:=make([dynamic]string,context.temp_allocator)
        for f in record.fields.list {
            for n in f.names {append(&order,ident_name(n))}
            array,is_array:=f.type.derived.(^ast.Array_Type)
            if !is_array || array.len==nil {continue}
            elem:=ident_name(array.elem)
            if selector,is_selector:=array.elem.derived.(^ast.Selector_Expr);is_selector {elem=selector.field.name}
            if elem!="Action_Bindings" {continue}
            enum_name:=ident_name(array.len)
            if selector,is_selector:=array.len.derived.(^ast.Selector_Expr);is_selector {enum_name=selector.field.name}
            // Indexed by an enum @(actions): its defaults. By anything else: bindings held as data.
            of_actions:=false
            for a in g.action_enums {of_actions||=a.name==enum_name}
            if !of_actions {continue}
            buffer:[512]u8
            constant,maker,_:=core.default_names(enum_name,buffer[:])
            append(&g.errors,fmt.aprintf("%s(%d): %s carries the defaults of the actions of %s, and a struct carries no defaults of actions: declare them beside the enum as %s :: proc() -> [%s]Action_Bindings (or a constant %sS), and remove the field",file.fullpath,f.pos.line,name,enum_name,fmt.tprintf("%ss",maker),enum_name,constant))
        }
        d:=new(Defaulted,context.temp_allocator)
        d.name,d.path,d.pkg,d.order=name,pkg.path,pkg,order[:]
        buffer:[512]u8
        constant,maker,_:=core.default_names(name,buffer[:])
        switch {
        case pkg.names[constant]:
            d.default,d.decl=strings.clone(constant,context.temp_allocator),strings.clone(constant,context.temp_allocator)
            d.set=order[:]
            // TRANSFORM_DEFAULT :: TRANSFORM_IDENTITY is built where that one is.
            for _ in 0..<8 {
                _,built,found:=type_decl(pkg,d.decl)
                if !found {break}
                if other:=ident_name(built);other!="" {
                    d.decl=strings.clone(other,context.temp_allocator)
                    continue
                }
                if lit,is_lit:=built.derived.(^ast.Comp_Lit);is_lit {d.set=literal_fields(lit,order[:],zero=false)}
                break
            }
        case pkg.names[maker]:
            // A maker takes nothing: inspect_default(s,...) of a type Inspect is something else.
            _,built,found:=type_decl(pkg,maker)
            if !found {return}
            made,is_proc:=built.derived.(^ast.Proc_Lit)
            if !is_proc || made.type.params!=nil && len(made.type.params.list)>0 {return}
            d.default,d.decl=fmt.aprintf("%s()",maker,allocator=context.temp_allocator),strings.clone(maker,context.temp_allocator)
            d.set=order[:]
        case:
            return
        }
        if len(d.set)>0 {defaulted[fmt.aprintf("%s.%s",pkg.path,name,allocator=context.temp_allocator)]=d}
    }
    for pkg in g.packages {
        for file in pkg.files {
            for stmt in file.decls {
                decl,is_value:=stmt.derived.(^ast.Value_Decl)
                if !is_value || decl.is_mutable || len(decl.names)!=1 || len(decl.values)!=1 {continue}
                add(g,&defaulted,ident_name(decl.names[0]),pkg,file,decl.values[0])
            }
        }
    }
    if len(defaulted)==0 {return}
    Walk :: struct {
        g:^Generator,
        defaulted:^map[string]^Defaulted,
        pkg:^Package,
        file:^ast.File,
        decl:string,          // the top-level declaration walked
        compared:map[^ast.Node]bool, // literals compared or read a field of, which make no value
    }
    unwrapped :: proc(expr:^ast.Expr) -> ^ast.Node {
        e:=expr
        for e!=nil {
            paren,is_paren:=e.derived.(^ast.Paren_Expr)
            if !is_paren {break}
            e=paren.expr
        }
        return e
    }
    visit :: proc(v:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
        if node==nil {return nil}
        w:=(^Walk)(v.data)
        #partial switch n in node.derived {
        case ^ast.Binary_Expr:
            if n.op.kind==.Cmp_Eq || n.op.kind==.Not_Eq {w.compared[unwrapped(n.left)],w.compared[unwrapped(n.right)]=true,true}
        case ^ast.Selector_Expr:
            w.compared[unwrapped(n.expr)]=true
        }
        lit,is_lit:=node.derived.(^ast.Comp_Lit)
        if !is_lit || lit.type==nil || w.compared[node] {return v}
        key,alias:string
        #partial switch type in lit.type.derived {
        case ^ast.Ident:
            key=fmt.tprintf("%s.%s",w.pkg.path,type.name)
        case ^ast.Selector_Expr:
            alias=ident_name(type.expr)
            path,found:=import_path(w.g,w.file,alias)
            if !found {return v}
            key=fmt.tprintf("%s.%s",path,type.field.name)
        case:
            return v
        }
        d,found:=w.defaulted[key]
        if !found || w.pkg==d.pkg && w.decl==d.decl {return v}
        given:=literal_fields(lit,d.order)
        left:=make([dynamic]string,context.temp_allocator)
        for field in d.set {
            if !slice.contains(given,field) {append(&left,field)}
        }
        if len(left)==0 {return v}
        list:=strings.join(left[:],", ",context.temp_allocator)
        default:=alias!=""?fmt.tprintf("%s.%s",alias,d.default):d.default
        append(&w.g.errors,fmt.aprintf("%s(%d:%d): %s{{...}} leaves out %s, which %s sets, and a literal leaves a field out as zero: start from the default (value:=%s, then change fields), or name %s in the literal",w.file.fullpath,lit.pos.line,lit.pos.column,expr_text(w.file,lit.type),list,default,default,len(left)==1?"it":"them"))
        return v
    }
    for pkg in g.packages {
        for file in pkg.files {
            w:=Walk{g=g,defaulted=&defaulted,pkg=pkg,file=file,compared=make(map[^ast.Node]bool,context.temp_allocator)}
            visitor:=ast.Visitor{visit=visit,data=&w}
            for stmt in file.decls {
                w.decl=""
                if decl,is_value:=stmt.derived.(^ast.Value_Decl);is_value && len(decl.names)==1 {w.decl=ident_name(decl.names[0])}
                ast.walk(&visitor,stmt)
            }
        }
    }
}

// The paths of assets the code of the project writes: a string literal that
// ends in the extension of an asset ("pets/Dog.scene") names an asset of the
// project or of its plugins, or the build fails where it is written, with the
// path that has the same name when there is one.
@(private="file")
asset_paths_check :: proc(g:^Generator,p:^project.Project) {
    assets:=project.folder_path(p.root,.Assets,context.temp_allocator)
    if !os.is_dir(assets) {return}
    registry:asset.Registry
    asset.registry_init(&registry,assets,"",context.temp_allocator,project.imported_path(p.root,context.temp_allocator))
    defer asset.registry_destroy(&registry)
    for folder in project.asset_folders(p,context.temp_allocator) {
        if folder.prefix!="" {asset.registry_mount(&registry,folder.path,folder.prefix,folder.imported)}
    }
    if asset.registry_scan(&registry)!=.None {return}
    extensions:=make(map[string]bool,context.temp_allocator)
    for info in asset.KINDS {extensions[info.extension]=true}
    for file in registry.files {
        if dot:=strings.last_index_byte(file.path,'.');dot>0 {extensions[file.path[dot:]]=true}
    }
    Walk :: struct {g:^Generator,file:^ast.File,registry:^asset.Registry,extensions:^map[string]bool}
    visit :: proc(v:^ast.Visitor,node:^ast.Node) -> ^ast.Visitor {
        if node==nil {return nil}
        w:=(^Walk)(v.data)
        lit,is_lit:=node.derived.(^ast.Basic_Lit)
        if !is_lit || lit.tok.kind!=.String || len(lit.tok.text)<2 {return v}
        path:=lit.tok.text[1:len(lit.tok.text)-1]
        dot:=strings.last_index_byte(path,'.')
        slash:=strings.last_index_byte(path,'/')
        if dot<=slash+1 || !w.extensions[path[dot:]] || strings.contains_any(path,"%{}:\\\n") {return v}
        if _,known:=w.registry.by_path[path];known {return v}
        name:=path[slash+1:]
        like:=""
        for file in w.registry.files {
            if file.path==name || strings.has_suffix(file.path,name) && file.path[len(file.path)-len(name)-1]=='/' {like=file.path;break}
        }
        hint:=like!=""?fmt.tprintf("; the asset of that name is %q",like):""
        append(&w.g.errors,fmt.aprintf("%s(%d:%d): %q names no asset of the project or of its plugins%s: write the path of the asset from the assets folder, or create or import it",w.file.fullpath,lit.pos.line,lit.pos.column,path,hint))
        return v
    }
    for pkg in g.packages {
        if !strings.has_prefix(pkg.path,"project:") {continue}
        for file in pkg.files {
            w:=Walk{g,file,&registry,&extensions}
            visitor:=ast.Visitor{visit=visit,data=&w}
            for stmt in file.decls {ast.walk(&visitor,stmt)}
        }
    }
}

// The fields a literal of a struct whose fields are order names: those it
// names, or the first ones when it gives values without names; without zero,
// only those it gives a value other than zero.
@(private="file")
literal_fields :: proc(lit:^ast.Comp_Lit,order:[]string,zero:=true) -> []string {
    given:=make([dynamic]string,context.temp_allocator)
    for elem,i in lit.elems {
        name,value:=i<len(order)?order[i]:"",elem
        if field,named:=elem.derived.(^ast.Field_Value);named {name,value=ident_name(field.field),field.value}
        if name!="" && (zero || !zero_literal(value)) {append(&given,name)}
    }
    return given[:]
}

// 0, false, nil, {} or a literal of only those.
@(private="file")
zero_literal :: proc(expr:^ast.Expr) -> bool {
    #partial switch v in expr.derived {
    case ^ast.Basic_Lit:
        value,ok:=strconv.parse_f64(v.tok.text)
        return ok && value==0
    case ^ast.Ident:
        return v.name=="false" || v.name=="nil"
    case ^ast.Comp_Lit:
        for elem in v.elems {
            inner:=elem
            if field,named:=elem.derived.(^ast.Field_Value);named {inner=field.value}
            if !zero_literal(inner) {return false}
        }
        return true
    }
    return false
}
