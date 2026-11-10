package build

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "mirai:core"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The world of a project, generated from the attributes of its packages:
//
//   @(component) @(component,shared) @(component,locks="core.Transform")
//   @(component,replicated) @(component,replicated="owner") @(component,replicated="others")
//   @(storage) @(storage,host) @(storage,setting) @(storage,setting="machine")
//   @(storage,queue) @(storage,events) @(storage,shared) @(storage,keep)
//   @(storage,copy="state_copy") @(storage,free="state_free") @(storage,reset="state_reset")
//   @(step="fixed late",loops="game editor",stage="end",after="a b",before="c",server)
//   @(net_message) @(net_message,from="client",reliable) @(net_message,from="owner")
//   @(params) @(names) @(name_bits="T") @(name="...") @(actions)
//   @(draw="minimap")
//
// The engine's libraries (core, engine/*), the runtime/ of the active plugins
// and the game/ of the project go into World and Shared; the editor and the
// editor/ of plugins and of the project into Editor_World.

CUSTOM_ATTRIBUTES :: "component,storage,step,loops,stage,after,before,server,shared,locks,host,by_world,copy,copy_kept,swap,free,replicated,setting,description,queue,events,keep,persist,single,far,reset,net_message,from,reliable,params,names,name_bits,name,name_requires,presentation,record,actions,draw"

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
    field:string,
    lock_id:int,
    file:^ast.File,   // where it is declared
    value:^ast.Expr,  // its struct
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
Param_Kind :: enum u8 {Table_Write,Table_Read,Storage_Write,Storage_Ref,Storage_Value,Entities_Read,Commands,World_Ref,App,App_Part,Records}

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
}

@(private="file")
PARAM_FORMS :: "^core.Table(T), core.Read(T), ^S, core.Ref(S), S, core.Ref(core.Entities), core.Commands, core.World_Ref, a part of the application (^host.Assets, ^host.Frame_Extras, ^render.Renderer, ^audio.Mixer, ^jobs.Job_System, runtime.Allocator) or ^host.App"

@(private="file")
Param :: struct {
    kind:Param_Kind,
    type:^Type,
    record:^Record_Type, // Records
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
    draws:[dynamic]Draw_Proc,
    errors:[dynamic]string,
    engine_root,root:string,
}

// Play is built from game_world, which has no editor package; the editor from
// editor_world; the game that ships from shipped_world, game_world without the
// development plugins. The editor and play are the libraries the editor and
// the player load; game is the program that ships, with the engine in it.
Generated :: struct {
    game_world,editor_world,shipped_world,editor_main,play_main,game_main:string,
    errors:[]string,
    machine_settings:[]string, // the names of the @(storage,setting="machine"): the sections the file of the engine gives a shipped game
}

// The source of the world packages and of the main packages. The world of
// the game that ships is generated only when shipped is asked for.
world_generate :: proc(p:^project.Project,allocator:=context.allocator,shipped:=false) -> (out:Generated) {
    context.allocator=allocator
    g:Generator
    g.by_key=make(map[string]^Type)
    g.bundles=make(map[string]^Bundle)
    g.named_types=make(map[string]^Named_Type)
    g.action_by_key=make(map[string]^Action_Enum)
    g.record_by_key=make(map[string]^Record_Type)
    g.engine_root,g.root=p.engine_root,p.root
    packages_find(&g,p)
    for pkg in g.packages {package_read(&g,pkg)}
    for pkg in g.packages {plugin_imports_check(&g,p,pkg)}
    types_settle(&g)
    names_settle(&g)
    bundles_settle(&g)
    for pkg in g.packages {steps_read(&g,pkg)}
    for pkg in g.packages {draws_read(&g,pkg)}
    rules_check(&g)
    defaults_check(&g)
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
    out.play_main=library_entry("game_world")
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
    g:Generator
    g.by_key=make(map[string]^Type)
    g.bundles=make(map[string]^Bundle)
    g.named_types=make(map[string]^Named_Type)
    g.action_by_key=make(map[string]^Action_Enum)
    g.record_by_key=make(map[string]^Record_Type)
    g.engine_root,g.root=p.engine_root,p.root
    packages_find(&g,p)
    for pkg in g.packages {package_read(&g,pkg)}
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
    g:Generator
    g.by_key=make(map[string]^Type)
    g.bundles=make(map[string]^Bundle)
    g.named_types=make(map[string]^Named_Type)
    g.action_by_key=make(map[string]^Action_Enum)
    g.record_by_key=make(map[string]^Record_Type)
    g.engine_root,g.root=p.engine_root,p.root
    packages_find(&g,p)
    for pkg in g.packages {package_read(&g,pkg)}
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
    out=world_generate(p,context.temp_allocator,shipped)
    if len(out.errors)>0 {return}
    gen:=project.path(project.folder_path(p.root,.Generated,context.temp_allocator),"gen",allocator=context.temp_allocator)
    files:=[6][2]string{{"game_world/world.odin",out.game_world},{"editor_world/world.odin",out.editor_world},{"shipped_world/world.odin",out.shipped_world},{"editor/main.odin",out.editor_main},{"play/main.odin",out.play_main},{"game/main.odin",out.game_main}}
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

// A plugin imports only itself and what it depends on: what it does not name
// in its plugin.mirai is not active with it.
@(private="file")
plugin_imports_check :: proc(g:^Generator,p:^project.Project,pkg:^Package) {
    if pkg.plugin<0 {return}
    for file in pkg.files {
        for decl in file.imports {
            imported:=strings.trim(decl.fullpath,"\"`")
            other:=project.import_plugin(imported)
            if other=="" || project.plugin_reaches(p.plugins,pkg.plugin,other,false) {continue}
            append(&g.errors,fmt.aprintf("%s: imports %s, a plugin %s does not depend on; add %q to the dependencies of its plugin.mirai, or take the import out",file.fullpath,imported,base.text_get(p.plugins[pkg.plugin].manifest.name[:]),other))
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

@(private="file",thread_local)
parse_problem:string

// Reads and parses the sources of a package folder, without its tests, and returns its name and
// its files in path order. Each problem goes to errors naming the file and the position, as the
// compiler does. Not parser.parse_package: it reads the package clause of a file that failed to
// parse, which a file without one leaves nil.
sources_read :: proc(folder:string,errors:^[dynamic]string,allocator:=context.allocator) -> (name:string,files:[]^ast.File,ok:bool) {
    collected,collected_ok:=parser.collect_package(folder)
    if !collected_ok {
        append(errors,fmt.aprintf("%s: the package could not be read",folder))
        return
    }
    sorted:=make([dynamic]^ast.File,0,len(collected.files),allocator)
    for path,file in collected.files {
        if !strings.has_suffix(path,"_test.odin") {append(&sorted,file)}
    }
    slice.sort_by(sorted[:],proc(a,b:^ast.File) -> bool {return a.fullpath<b.fullpath})
    p:=parser.default_parser()
    p.err=proc(pos:tokenizer.Pos,format:string,args:..any) {
        if parse_problem=="" {parse_problem=fmt.aprintf("%s(%d:%d): %s",pos.file,pos.line,pos.column,fmt.tprintf(format,..args))}
    }
    ok=true
    for file in sorted {
        parse_problem=""
        if !parser.parse_file(&p,file) {
            append(errors,parse_problem!="" ? parse_problem : fmt.aprintf("%s: the file does not parse",file.fullpath))
            ok=false
            continue
        }
        if name=="" {name=file.pkg_name}
        else if file.pkg_name!=name {
            append(errors,fmt.aprintf("%s(%d:%d): package %s, while its folder is package %s",file.fullpath,file.pkg_decl.pos.line,file.pkg_decl.pos.column,file.pkg_name,name))
            ok=false
        }
    }
    parse_problem=""
    return name,sorted[:],ok
}

@(private="file")
package_read :: proc(g:^Generator,pkg:^Package) {
    name,files,ok:=sources_read(pkg.folder,&g.errors)
    if !ok {return}
    pkg.name=name
    pkg.files=files
    pkg.names=make(map[string]bool)
    for file in pkg.files {
        for stmt in file.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
            name:=ident_name(decl.names[0])
            pkg.names[name]=true
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
            t:=new(Type)
            t.name,t.pkg=name,pkg
            t.file,t.value=file,decl.values[0]
            t.key=fmt.aprintf("%s.%s",pkg.path,name)
            t.kind=is_component?.Component:.Storage
            switch core.declared_read(&t.declared,options,pkg.editor) {
            case "replicated":
                append(&g.errors,fmt.aprintf("%s: %s has replicated=%q: write @(component,replicated) for every end that has the entity, replicated=\"owner\" for its owner or replicated=\"others\" for the rest",pkg.folder,name,options["replicated"]))
                continue
            case "setting":
                append(&g.errors,fmt.aprintf("%s: %s has setting=%q, which is not a kind of setting: write @(storage,setting) for a setting of the project or @(storage,setting=\"machine\") for a preference of whoever uses the engine on this machine",pkg.folder,name,options["setting"]))
                continue
            }
            if t.replication!=.None && !is_component {
                append(&g.errors,fmt.aprintf("%s: %s is a storage and says replicated: the network replicates components of entities; make it a @(component,replicated), or send it as a @(net_message)",pkg.folder,name))
                continue
            }
            if _,scene:=options["scene"];scene {
                append(&g.errors,fmt.aprintf("%s: %s says scene: a setting of the scene is a component on an entity of the root scene, which saves, replicates and changes while the game runs; make it a @(component), with single if the world uses one at a time",pkg.folder,name))
                continue
            }
            if t.single && !is_component {
                append(&g.errors,fmt.aprintf("%s: %s says single, which is of a component the world uses one of at a time: write @(component,single)",pkg.folder,name))
                continue
            }
            if t.far && !is_component {
                append(&g.errors,fmt.aprintf("%s: %s says far, which is of a component whose entity draws a far form of its own and stays when its section unloads: write @(component,far)",pkg.folder,name))
                continue
            }
            if (t.queue || t.events) && (t.kind!=.Storage || t.queue && t.events) {
                append(&g.errors,fmt.aprintf("%s: %s says queue or events: a storage of requests is @(storage,queue), one of what a library reports is @(storage,events), and none is both",pkg.folder,name))
                continue
            }
            if t.kind==.Component {field_comments(&t.fields,decl.values[0])}
            for lock in strings.fields(t.lock_names) {append(&t.locks,qualified(g,file,pkg,lock))}
            if t.setting!=.None && (t.kind!=.Storage || t.place==.Editor) {
                append(&g.errors,fmt.aprintf("%s: %s is a setting: mark it @(storage,setting) or @(storage,setting=\"machine\") in a library",pkg.folder,name))
                continue
            }
            if t.by_world && (t.kind!=.Storage || t.place!=.Shared || t.setting!=.None) {
                append(&g.errors,fmt.aprintf("%s: %s is by_world: a storage of the application with a value for each World is @(storage,host,by_world) in a library, and is not a setting",pkg.folder,name))
                continue
            }
            if t.persist && (t.kind!=.Storage || t.place!=.World || t.queue || t.events || t.setting!=.None || t.copy=="false" || t.reset!="") {
                append(&g.errors,fmt.aprintf("%s: %s says persist: the progress of the player is a plain @(storage,persist) of a library; not a component, a storage of the application, a queue, events, a setting, nor one that resets or is not copied",pkg.folder,name))
                continue
            }
            if t.copy_kept!="" && (t.kind!=.Storage || t.place!=.World || t.copy=="false") {
                append(&g.errors,fmt.aprintf("%s: %s says copy_kept, the copy of a storage of the World that a history keeps: write it on a @(storage) of a library that is copied",pkg.folder,name))
                continue
            }
            if (t.keep || t.reset!="") && (t.kind!=.Storage || t.place!=.World) {
                append(&g.errors,fmt.aprintf("%s: %s says keep or reset, which are of a storage of the World: clearing a World resets its storages, and the others have no World to follow",pkg.folder,name))
                continue
            }
            if (t.keep || t.reset!="") && (t.setting!=.None || t.copy=="false") || t.keep && t.reset!="" {
                append(&g.errors,fmt.aprintf("%s: %s says keep or reset and survives clearing the World already as a setting or with copy=false, or says both: a storage that the World resets says reset=\"proc\" when it needs more than its default, one that survives says keep",pkg.folder,name))
                continue
            }
            if t.key in g.by_key {
                append(&g.errors,fmt.aprintf("%s: %s is declared twice",pkg.folder,name))
                continue
            }
            g.by_key[t.key]=t
            append(&g.types,t)
            pkg.used=true
        }
    }
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
                append(&g.errors,fmt.aprintf("%s: %s locks %s, which is not a component",t.pkg.folder,t.name,lock))
            } else if !target.shared {
                append(&g.errors,fmt.aprintf("%s: %s locks %s, which is not @(component,shared): only a table with several writers has owners by entity",t.pkg.folder,t.name,target.name))
            } else if target.place!=t.place {
                append(&g.errors,fmt.aprintf("%s: %s locks %s, which is in another place of the world: a row owns rows of its own World, Shared or Editor",t.pkg.folder,t.name,target.name))
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
    for file in pkg.files {
        for stmt in file.decls {
            decl,is_value:=stmt.derived.(^ast.Value_Decl)
            if !is_value || len(decl.names)!=1 || len(decl.values)!=1 {continue}
            options:=attributes_read(decl.attributes[:])
            phase_text,is_step:=options["step"]
            if !is_step {continue}
            literal,is_proc:=decl.values[0].derived.(^ast.Proc_Lit)
            name:=ident_name(decl.names[0])
            where_:=fmt.aprintf("%s(%d)",file.fullpath,decl.pos.line)
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
            if literal.type.params!=nil {
                defaulted:=strings.builder_make(context.temp_allocator)
                for field in literal.type.params.list {
                    if field.default_value==nil {continue}
                    for n in field.names {fmt.sbprintf(&defaulted,"%s%s",strings.builder_len(defaulted)>0?", ":"",ident_name(n))}
                }
                if strings.builder_len(defaulted)>0 {
                    append(&g.errors,fmt.aprintf("%s: %s gives a default to %s, and the generator binds every parameter: take the defaults out; code outside the loop runs the function with core.world_run, or passes every parameter",where_,name,strings.to_string(defaulted)))
                }
                arg:=0
                for field in literal.type.params.list {
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
                                append(&s.params,bound)
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
                        append(&s.params,param)
                        arg+=1
                    }
                }
            }
            if literal.type.results!=nil && len(literal.type.results.list)>0 {
                append(&g.errors,fmt.aprintf("%s: %s returns something; a step returns nothing",where_,name))
            }
            append(&g.steps,s)
        }
    }
}

@(private="file")
param_read :: proc(g:^Generator,file:^ast.File,pkg:^Package,expr:^ast.Expr) -> (param:Param,ok:bool) {
    pointer:=false
    e:=expr
    if p,is_pointer:=e.derived.(^ast.Pointer_Type);is_pointer {
        pointer=true
        e=p.elem
    }
    if call,is_call:=e.derived.(^ast.Call_Expr);is_call && len(call.args)==1 {
        wrapper:=type_key(g,file,pkg,call.expr)
        inner_key:=type_key(g,file,pkg,call.args[0])
        if wrapper=="mirai:core.Records" {
            r,found:=g.record_by_key[inner_key]
            return {kind=.Records,record=r},found && !pointer
        }
        if wrapper=="mirai:core.Ref" && inner_key=="mirai:core.Entities" {return {kind=.Entities_Read,type=nil},!pointer}
        inner,found:=g.by_key[inner_key]
        if !found {return}
        switch {
        case wrapper=="mirai:core.Table" && pointer && inner.kind==.Component: return {kind=.Table_Write,type=inner},true
        case wrapper=="mirai:core.Read" && !pointer && inner.kind==.Component: return {kind=.Table_Read,type=inner},true
        case wrapper=="mirai:core.Ref" && !pointer && inner.kind==.Storage: return {kind=.Storage_Ref,type=inner},true
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
            append(&g.errors,fmt.aprintf("%s: %s is by_world, and the world has no core.World_Id to know whose value a function gets",t.pkg.folder,t.name))
        }
        if !t.persist {continue}
        if field,what,fix:=persist_unkept(g,t.file,t.pkg,t.value,"",0);what!="" {
            at:=field==""?t.name:fmt.aprintf("%s.%s",t.name,field)
            append(&g.errors,fmt.aprintf("%s: %s says persist and %s is %s, which the profile of the player does not keep: the profile holds plain data; %s",t.pkg.folder,t.name,at,what,fix))
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
    tick_actions:=g.by_key["mirai:engine/input.Actions"]
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
                } else if param.type==tick_actions {
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
    // One writer of a table that is not shared, in each loop.
    loops:=LOOPS
    for loop in 0..<2 {
        writers:=make(map[^Type]^Step,context.temp_allocator)
        for s in g.steps {
            if !s.loops[loop] {continue}
            for param in s.params {
                if param.kind!=.Table_Write || param.type.shared {continue}
                if other,taken:=writers[param.type];taken && other!=s {
                    append(&g.errors,fmt.aprintf("%s: %s and %s write %s in the %s loop; a table that is not @(component,shared) has one writer: the other sends a request through a storage",s.where_,other.name,s.name,param.type.name,loops[loop]))
                }
                writers[param.type]=s
            }
        }
        // A storage is the state of one library: the functions of another
        // push to it when it is a queue, or write it in the order of the loop
        // when it says it is shared.
        owners:=make(map[^Type]^Step,context.temp_allocator)
        for s in g.steps {
            if !s.loops[loop] {continue}
            for param in s.params {
                if param.kind!=.Storage_Write || param.type.queue || param.type.shared {continue}
                if other,taken:=owners[param.type];taken && other.pkg!=s.pkg {
                    append(&g.errors,fmt.aprintf("%s: %s of %s and %s of %s write %s in the %s loop; a storage is the state of one library: the other sends a request through a storage marked @(storage,queue), or the storage says @(storage,shared) when several libraries write it in the order of the loop",s.where_,other.name,other.pkg.name,s.name,s.pkg.name,param.type.name,loops[loop]))
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
            if param.type==nil || param.type.queue || param.type.events || run_written[param.type] {continue}
            writer,shown_only:=shown_writer[param.type]
            if !shown_only {continue}
            append(&g.errors,fmt.aprintf("%s: %s reads %s, which only %s writes, in ui or render: a dedicated server runs neither and there %s keeps the value it starts with; write it in input, fixed, frame or late, or read it in ui or render",s.where_,s.name,param.type.name,writer.name,param.type.name))
        }
    }
    // A frame runs any number of ticks: a fixed step would see twice, or never,
    // what only the frame fills and empties.
    filled_outside:=make(map[^Type]^Step,context.temp_allocator)
    filled_in_fixed:=make(map[^Type]bool,context.temp_allocator)
    for s in g.steps {
        if !s.loops[0] {continue}
        for param in s.params {
            if param.kind!=.Storage_Write || !param.type.events {continue}
            if s.phases[FIXED_PHASE] {filled_in_fixed[param.type]=true} else {filled_outside[param.type]=s}
        }
    }
    for s in g.steps {
        if !s.loops[0] || !s.phases[FIXED_PHASE] {continue}
        for param in s.params {
            if param.type==nil || !param.type.events || param.kind==.Storage_Write || filled_in_fixed[param.type] {continue}
            writer,outside:=filled_outside[param.type]
            if !outside {continue}
            append(&g.errors,fmt.aprintf("%s: %s runs in fixed and reads %s, which only %s fills, and which is emptied every frame: a frame runs any number of ticks, so a tick would see it twice or never; read it in a frame step",s.where_,s.name,param.type.name,writer.name))
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
    fmt.sbprint(w,"\n")

    places:=[3]core.Place{.World,.Shared,.Editor}
    struct_names:=[3]string{"World","Shared","Editor"}
    // Each storage by its index in info.storages, where its revision is.
    storage_index:=make(map[^Type]int,context.temp_allocator)
    for t in g.types {
        if t.kind==.Storage && included(t,editor) {storage_index[t]=len(storage_index)}
    }
    for place,pi in places {
        fmt.sbprintf(w,"%s :: struct {{\n",struct_names[pi])
        if place==.World {fmt.sbprintf(w,"    entities:%s.Entities,\n    storage_revisions:[%d]u64,\n",core_alias,len(storage_index))}
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

    // The functions as info.steps lists them: where each one adds its time.
    kept:=make([dynamic]^Step,context.temp_allocator)
    index_of:=make(map[^Step]int,context.temp_allocator)
    for s in g.steps {
        if editor || !s.pkg.editor {
            index_of[s]=len(kept)
            append(&kept,s)
        }
    }

    // Each function as the loops call it, with its binding, its settle and
    // its time: the loops call these in order, and core.world_run a part of them.
    for step,si in kept {
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
                strings.write_string(&args,",")
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
                if param.type.by_world {fmt.sbprintf(&args,"%s.ref(%s.by_world_get(&%s.%s,w.%s))",core_alias,core_alias,holder,param.type.field,world_id.field)} else {fmt.sbprintf(&args,"%s.ref(&%s.%s)",core_alias,holder,param.type.field)}
            case .Storage_Value: fmt.sbprintf(&args,"%s.%s",holder,param.type.field)
            case .Entities_Read: fmt.sbprintf(&args,"%s.ref(&w.entities)",core_alias)
            case .Commands: fmt.sbprintf(&args,"%s.commands(w,app.info)",core_alias)
            case .World_Ref: fmt.sbprintf(&args,"%s.world_ref(w,app.info)",core_alias)
            case .App: fmt.sbprint(&args,"app")
            case .App_Part:
                parts:=APP_PARTS
                fmt.sbprint(&args,parts[param.part].value)
            case .Records:
                index,_:=slice.linear_search(g.records[:],param.record)
                fmt.sbprintf(&args,"%s.Records(%s.%s){{%s.app_record_set(app,%d)}}",core_alias,param.record.pkg.alias,param.record.name,host_alias,index)
            }
        }
        if len(step.params)>0 {bundle_close(g,&args,step.params[len(step.params)-1])}
        call:=fmt.tprintf("%s.%s(%s)",step.pkg.alias,step.name,strings.to_string(args))
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

    // Defaults are also metadata for storage providers and project settings.
    defaults:=make(map[^Type]string,context.temp_allocator)
    for t in g.types {
        if !included(t,editor) {continue}
        value:=default_value(t) or_continue
        name:=fmt.aprintf("default_%s",t.field)
        fmt.sbprintf(w,"%s :: proc(dst:rawptr) {{(cast(^%s.%s)dst)^=%s}}\n",name,t.pkg.alias,t.name,value)
        defaults[t]=name
    }
    for_device:=make(map[^Type]string,context.temp_allocator)
    for t in g.types {
        if t.kind!=.Storage || !included(t,editor) {continue}
        maker:=for_device_value(t)
        if maker=="" {continue}
        name:=fmt.aprintf("for_device_%s",t.field)
        fmt.sbprintf(w,"%s :: proc(dst:rawptr,device:rawptr) {{(cast(^%s.%s)dst)^=%s((cast(^gen_rhi.Device_Info)device)^)}}\n",name,t.pkg.alias,t.name,maker)
        for_device[t]=name
    }
    // The procedures the attributes of a storage name, as core calls them.
    procs:=make(map[^Type]string,context.temp_allocator)
    for t in g.types {
        if t.kind!=.Storage || !included(t,editor) {continue}
        Named :: struct {option,name:string,pair,result:bool}
        named:=[5]Named{{"copy",t.copy=="false"?"":t.copy,true,true},{"copy_kept",t.copy_kept,true,true},{"swap",t.swap,true,false},{"free",t.free,false,false},{"reset",t.reset,false,false}}
        list:=strings.builder_make(context.temp_allocator)
        for n in named {
            if n.name=="" {continue}
            type:=fmt.tprintf("%s.%s",t.pkg.alias,t.name)
            if n.pair {
                fmt.sbprintf(w,"%s_%s :: proc(a,b:rawptr)%s {{%s%s.%s(cast(^%s)a,cast(^%s)b)}}\n",n.option,t.field,n.result?" -> bool":"",n.result?"return ":"",t.pkg.alias,n.name,type,type)
            } else {
                fmt.sbprintf(w,"%s_%s :: proc(value:rawptr) {{%s.%s(cast(^%s)value)}}\n",n.option,t.field,t.pkg.alias,n.name,type)
            }
            fmt.sbprintf(&list,"%s%s=%s_%s",strings.builder_len(list)>0?",":"",n.option,n.option,t.field)
        }
        procs[t]=strings.to_string(list)
    }
    fmt.sbprint(w,"\n")

    // The descriptions of the fields of the components, read only.
    for t in g.types {
        if t.kind!=.Component || !included(t,editor) || len(t.fields)==0 {continue}
        fmt.sbprintf(w,"@(rodata) fields_%s:=[%d]%s.Field_Description{{",t.field,len(t.fields),core_alias)
        for field,k in t.fields {fmt.sbprintf(w,"%s{{%q,%q}}",k>0?",":"",field.name,field.text)}
        fmt.sbprint(w,"}\n")
    }
    fmt.sbprint(w,"\n")

    // The default bindings of each enum @(actions); the compiler asks for every member.
    for a,ai in g.action_enums {
        value:=actions_defaults_value(a) or_continue
        fmt.sbprintf(w,"action_defaults_%d :: proc(dst:rawptr) {{(cast(^[%s.%s]%s.Action_Default)dst)^=%s}}\n",ai,a.pkg.alias,a.name,g.actions_type.pkg.alias,value)
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
        fields:=len(t.fields)>0?fmt.tprintf("fields_%s[:]",t.field):"nil"
        game:=strings.has_prefix(t.pkg.path,"project:") && !strings.has_prefix(t.pkg.path,"project:plugins/")
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
        fmt.sbprintf(w,"    tables[%d]={{\"%s\",\"%s\",typeid_of(%s.%s),type_info_of(%s.%s),offset_of(%s,%s),.%v,%v,.%v,%v,%s,%q,%s,%v,%v,%v,%s,false}}\n",i,t.name,t.pkg.name,t.pkg.alias,t.name,t.pkg.alias,t.name,struct_names[int(t.place)],t.field,t.place,t.shared,t.replication,game,defaults[t] or_else "nil",t.description,fields,t.single,t.far,t.pkg.path=="mirai:core",locks)
        i+=1
    }
    fmt.sbprintf(w,"    storages:=make([]%s.Storage_Info,%d)\n",core_alias,count_kind(g,.Storage,editor))
    i=0
    for t in g.types {
        if t.kind!=.Storage || !included(t,editor) {continue}
        fmt.sbprintf(w,"    storages[%d]={{\"%s\",\"%s\",typeid_of(%s.%s),type_info_of(%s.%s),offset_of(%s,%s),.%v,.%v,%s,%v,%s,%v,%v,%q,%v,%v,{{%s}},false}}\n",i,t.name,t.pkg.name,t.pkg.alias,t.name,t.pkg.alias,t.name,struct_names[int(t.place)],t.field,t.place,t.setting,defaults[t] or_else "nil",t.by_world,for_device[t] or_else "nil",t.persist,t.keep,project.import_plugin(t.pkg.path),strings.has_prefix(t.pkg.path,"project:") && !strings.has_prefix(t.pkg.path,"project:plugins/"),t.copy=="false",procs[t])
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
    for loop in 0..<(editor?2:1) {
        for phase in 0..<len(PHASES) {
            if defined[loop][phase] {fmt.sbprintf(w,"    info.loops[.%s][.%s],info.order[.%s][.%s]=%s_%s,order_%s_%s[:]\n",loop==0?"Game":"Editor",titles[phase],loop==0?"Game":"Editor",titles[phase],loops[loop],phases[phase],loops[loop],phases[phase])}
        }
    }
    fmt.sbprintf(w,"    %s.world_info_index(&info)\n",core_alias)
    fmt.sbprint(w,"    return info\n}\n")
    return strings.to_string(b)
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
    case t.pkg.names[constant]: return fmt.aprintf("%s.%s",t.pkg.alias,constant),true
    case t.pkg.names[maker]:    return fmt.aprintf("%s.%s()",t.pkg.alias,maker),true
    }
    return "",false
}

// What a new row of a record type starts as: <NAME>_DEFAULT or <name>_default() of its package.
@(private="file")
record_default :: proc(r:^Record_Type) -> (value:string,found:bool) {
    return default_value(&Type{name=r.name,pkg=r.pkg})
}

// The default bindings of the members of an enum @(actions): <ENUM>_DEFAULTS or
// <enum>_defaults() of its package, a [E]Action_Default.
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
    return t.pkg.names[maker]?fmt.aprintf("%s.%s",t.pkg.alias,maker):""
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
            if elem!="Action_Default" {continue}
            enum_name:=ident_name(array.len)
            if selector,is_selector:=array.len.derived.(^ast.Selector_Expr);is_selector {enum_name=selector.field.name}
            buffer:[512]u8
            constant,maker,_:=core.default_names(enum_name,buffer[:])
            append(&g.errors,fmt.aprintf("%s(%d): %s carries the defaults of the actions of %s, and a struct carries no defaults of actions: declare them beside the enum as %s :: proc() -> [%s]Action_Default (or a constant %sS), and remove the field",file.fullpath,f.pos.line,name,enum_name,fmt.tprintf("%ss",maker),enum_name,constant))
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
