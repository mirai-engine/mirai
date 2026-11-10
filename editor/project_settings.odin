package editor

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

// The project of the settings: project.mirai as the Project category of the
// dialog shows it (its Game, Window and Build sections) and the plugins it
// activates, with the methods project.get and project.set. The dialog edits
// a copy and writes the file once no gesture changes it; a change that does
// not validate is said and goes back to what the file has. A change of the
// plugins or of the options of the build starts a build: it changes the
// libraries of the project.

@(private) SETTINGS_CATEGORY_PROJECT :: -3
@(private) PROJECT_HELD :: u64(0x70726f6a656374)

Settings_Project :: struct {
    manifest:project.Manifest, // as the dialog edits it
    written:project.Manifest,  // as the file has it
    loaded:bool,
    unsaved:bool,
}

// Reads project.mirai into the copy the dialog edits.
@(private)
settings_project_load :: proc(s:^Session) {
    p:=&s.settings_project
    p.loaded,p.unsaved=false,false
    if !s.has_project {return}
    manifest,error:=project.manifest_read(project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if error.code!=.None {
        notify(s,project.error_text(s.project_root,error,context.temp_allocator))
        return
    }
    p.manifest=manifest
    p.written=manifest
    p.loaded=true
}

// Writes what the dialog changed once the UI rests: no control is held or edited.
@(private)
settings_project_flush :: proc(s:^Session) {
    p:=&s.settings_project
    if !p.unsaved || s.gui==nil || s.gui.ctx==nil {return}
    if ctx:=s.gui.ctx;ctx.active!=0 || ctx.edit.id!=0 || ctx.input.down!={} {return}
    p.unsaved=false
    next:=p.manifest
    if message,_:=project_manifest_store(s,&next);message!="" {
        notify(s,message)
        p.manifest=p.written
    }
}

// Checks a manifest against the project and writes it, with what it needs:
// the plugins it activates, an icon, a thumbnail and a scene that exist, and a build when
// the plugins or the options of the build changed. message says what is
// wrong and how to fix it; then nothing is written.
@(private)
project_manifest_store :: proc(s:^Session,m:^project.Manifest) -> (message:string,building:bool) {
    if !s.has_project {return "There is no project: open a folder with a project.mirai",false}
    if error:=project.manifest_validate(m);error.code!=.None {return project.error_text(s.project_root,error,context.temp_allocator),false}
    if icon:=base.text_get(m.icon[:]);icon!="" && !os.is_file(project.path(s.project_root,icon,allocator=context.temp_allocator)) {
        return fmt.tprintf("The icon %s does not exist in the project: copy a PNG there or name one that exists",icon),false
    }
    if thumbnail:=base.text_get(m.thumbnail[:]);thumbnail!="" && !os.is_file(project.path(s.project_root,thumbnail,allocator=context.temp_allocator)) {
        return fmt.tprintf("The thumbnail %s does not exist in the project: copy a PNG there or name one that exists",thumbnail),false
    }
    if scene:=base.text_get(m.start_scene[:]);scene!="" && s.assets_root!="" && !os.is_file(project.path(s.assets_root,scene,allocator=context.temp_allocator)) {
        return fmt.tprintf("The start scene %s does not exist in %s: name a .scene of the assets with a path relative to them",scene,s.assets_root),false
    }
    file:=project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator)
    written,read_error:=project.manifest_read(file)
    if read_error.code!=.None {return project.error_text(s.project_root,read_error,context.temp_allocator),false}
    rebuild:=written.plugins!=m.plugins || written.sources!=m.sources || written.build!=m.build
    if written.plugins!=m.plugins {
        if problem:=project_plugins_check(s,m);problem!="" {return problem,false}
    }
    if error:=project.manifest_write(file,m);error.code!=.None {return project.error_text(s.project_root,error,context.temp_allocator),false}
    p:=&s.settings_project
    if p.loaded {
        // What the dialog shows follows the file, except the fields it is editing.
        if !p.unsaved {p.manifest=m^}
        p.written=m^
    }
    settings_plugins_load(s)
    if rebuild {building=build_start(s)}
    return "",building
}

// Whether the plugins a manifest names make a project: each exists, none is
// automatic, their dependencies are found and they work with this engine.
@(private)
project_plugins_check :: proc(s:^Session,m:^project.Manifest) -> string {
    opened,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {return project.error_text(s.project_root,error,context.temp_allocator)}
    wanted:=make([dynamic]string,context.temp_allocator)
    for &entry in m.plugins {
        name:=base.text_get(entry[:])
        if name=="" {continue}
        index,found:=project.plugin_find(opened.plugins,name)
        if !found {return fmt.tprintf("%s is not a plugin of the project or of the engine: they are %s",name,project_plugin_names(opened.plugins))}
        if opened.plugins[index].manifest.automatic {
            return fmt.tprintf("%s is automatic: it is active when %s are; activate those instead",name,names_join(opened.plugins[index].manifest.dependencies[:]))
        }
        append(&wanted,name)
    }
    order,order_error:=project.plugins_order(opened.plugins,wanted[:],context.temp_allocator)
    if order_error.code!=.None {return project.error_text(s.project_root,order_error,context.temp_allocator)}
    for index in order {
        plugin:=&opened.plugins[index]
        if engine_error:=project.plugin_engine_check(&plugin.manifest);engine_error.code!=.None {
            engine_error.plugin,engine_error.origin=plugin.manifest.name,plugin.origin
            return project.error_text(s.project_root,engine_error,context.temp_allocator)
        }
    }
    return ""
}

@(private)
project_plugin_names :: proc(plugins:[]project.Plugin) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for &plugin in plugins {
        if !plugin.manifest.automatic {append(&names,base.text_get(plugin.manifest.name[:]))}
    }
    return strings.join(names[:],", ",context.temp_allocator)
}

@(private)
names_join :: proc(names:[]project.Name) -> string {
    list:=make([dynamic]string,context.temp_allocator)
    for &name in names {
        if text:=base.text_get(name[:]);text!="" {append(&list,text)}
    }
    return strings.join(list[:],", ",context.temp_allocator)
}

// A manifest with the plugins of on named and those of off not: a plugin an
// active one needs stays active through it, which message says.
@(private)
project_plugins_switch :: proc(s:^Session,m:^project.Manifest,on,off:[]string) -> (message:string) {
    kept:[project.MAX_PLUGINS]project.Name
    count:=0
    for &named in m.plugins {
        name:=base.text_get(named[:])
        if name=="" || slice.contains(off,name) || slice.contains(on,name) {continue}
        kept[count]=named
        count+=1
    }
    for name in on {
        if count>=project.MAX_PLUGINS {return fmt.tprintf("A project names at most %d plugins",project.MAX_PLUGINS)}
        if !base.text_set(kept[count][:],name) {return fmt.tprintf("%s is not a plugin name",name)}
        count+=1
    }
    m.plugins=kept
    if len(off)==0 {return ""}
    opened,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {return project.error_text(s.project_root,error,context.temp_allocator)}
    wanted:=make([dynamic]string,context.temp_allocator)
    for &named in m.plugins {
        if name:=base.text_get(named[:]);name!="" {append(&wanted,name)}
    }
    order,order_error:=project.plugins_order(opened.plugins,wanted[:],context.temp_allocator)
    if order_error.code!=.None {return ""}
    for name in off {
        index,found:=project.plugin_find(opened.plugins,name)
        if !found {return fmt.tprintf("%s is not a plugin of the project or of the engine: they are %s",name,project_plugin_names(opened.plugins))}
        if !slice.contains(order,index) {continue}
        for other in order {
            for &dependency in opened.plugins[other].manifest.dependencies {
                if base.text_get(dependency[:])==name {
                    return fmt.tprintf("%s is needed by %s, which stays active: deactivate %s too",name,base.text_get(opened.plugins[other].manifest.name[:]),base.text_get(opened.plugins[other].manifest.name[:]))
                }
            }
        }
    }
    return ""
}

// The switch of a plugin in the dialog: names it in project.mirai or takes it out, and builds the project.
@(private)
settings_plugin_set :: proc(s:^Session,name:project.Name,on:bool) {
    name:=name
    file:=project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator)
    manifest,error:=project.manifest_read(file)
    if error.code!=.None {notify(s,project.error_text(s.project_root,error,context.temp_allocator));return}
    switched:=[]string{base.text_get(name[:])}
    message:=project_plugins_switch(s,&manifest,on?switched:nil,on?nil:switched)
    building:bool
    if message=="" {message,building=project_manifest_store(s,&manifest)}
    if message!="" {notify(s,message);return}
    if building {notify(s,fmt.tprintf("%s %s; building the project",switched[0],on?"activated":"deactivated"))}
}

// The cards of the Project category: the fields of project.mirai of the section title.
@(private)
settings_project_card :: proc(s:^Session,title,needle:string,every:bool) {
    p:=&s.settings_project
    if !p.loaded {settings_project_load(s)}
    if !p.loaded {return}
    defaults:=project.manifest_default(base.text_get(p.manifest.name[:]))
    c:=Inspect{s=s,w=edited_world(s),index=HELD_INDEX,held=PROJECT_HELD,name="Manifest",type=project.Manifest,value=cast([^]u8)&p.manifest,defaults=cast([^]u8)&defaults,size=size_of(project.Manifest),width=SETTINGS_SIZE.x-SETTINGS_NAV-60,sections=true,section=title,ruled=true}
    if !every && !base.contains_fold(title,needle) {c.needle=needle}
    held_take(&c)
    fields_rows(&c,type_info_of(project.Manifest),0,0,"")
    if c.changed {p.unsaved=true}
}

// ---------------------------------------------------------------- API

Api_Project_Plugin :: struct {
    name:project.Name `mirai:"text"`,
    active:bool,
    named:bool `mirai:"label=project.mirai names it; an active one that is not named is a dependency or automatic"`,
    needed_by:project.Name `mirai:"text,label=An active plugin that depends on it; empty: none"`,
    automatic:bool `mirai:"label=Active exactly when its dependencies are: it cannot be activated by name"`,
    development:bool `mirai:"label=A tool for making the game: never in a published game"`,
    origin:string `mirai:"label=project or engine"`,
    version:project.Version `mirai:"text"`,
}

Api_Project :: struct {
    file:string `mirai:"label=The project.mirai it reads and writes"`,
    manifest:project.Manifest `mirai:"label=project.mirai"`,
    plugins:[]Api_Project_Plugin `mirai:"label=Every plugin the project can see"`,
}

// What project.set writes.
Api_Project_Changed :: struct {
    building:bool `mirai:"label=A build of the project still runs: the plugins or the options of the build changed and its wait ran out"`,
    build_error:string `mirai:"label=Empty; or the first error of the build the change started and that failed"`,
    active_plugins:[]string `mirai:"label=The plugins on after the change; project.get gives the manifest and every plugin"`,
}

Api_Project_Set_Params_Window_Mode :: enum u8 {Maximized,Fullscreen,Windowed}
Api_Project_Set_Params_Window :: struct {
    title:string `mirai:"optional,label=empty: the name"`,
    mode:Api_Project_Set_Params_Window_Mode `mirai:"optional"`,
    width,height:int `mirai:"optional,min=1,max=16384"`,
}
Api_Project_Set_Params_Build_Optimization :: enum u8 {Minimal,None,Size,Speed,Aggressive}
Api_Project_Set_Params_Build :: struct {
    executable:string `mirai:"optional,label=file of the shipped game without extension; empty: from the name"`,
    optimization:Api_Project_Set_Params_Build_Optimization `mirai:"optional"`,
    debug:bool `mirai:"optional"`,
    defines:[]string `mirai:"optional,label=NAME or NAME=value"`,
}
Api_Project_Set_Params :: struct {
    name:string `mirai:"optional"`,
    version:string `mirai:"optional,label=of the game: major.minor.patch"`,
    identifier:string `mirai:"optional,label=a reverse domain name, as com.studio.game; empty: none"`,
    icon:string `mirai:"optional,label=a PNG of the window of the game, relative to the project; empty: none"`,
    thumbnail:string `mirai:"optional,label=a PNG the list of projects shows the project with, relative to the project; empty: the view of its start scene"`,
    start_scene:string `mirai:"optional,label=a .scene relative to the assets folder; empty: none"`,
    window:Api_Project_Set_Params_Window `mirai:"optional"`,
    build:Api_Project_Set_Params_Build `mirai:"optional"`,
    plugins:serial.Json `mirai:"optional,label={'<plugin>': true to activate it, false to deactivate it}; project.get lists them"`,
}

@(private)
project_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="project.get",summary="project.mirai (name, version, identifier, icon, thumbnail, start scene, window and build) and every plugin the project can see, active or not.",result=type_info_of(Api_Project),flags={.Read_Only},run=api_project_get})
    api_register(s,st,{name="project.set",params=type_info_of(Api_Project_Set_Params),summary="Changes the fields of project.mirai it names and activates or deactivates plugins; a change of the plugins or of build starts a build, which restarts the editor, and answers when it ends, with build_error when it failed.",result=type_info_of(Api_Project_Changed),run=api_project_set})
}

@(private)
api_project_get :: proc(s:^Session,call:^api.Call) {api_project_write(s,call)}

@(private)
api_project_write :: proc(s:^Session,call:^api.Call) {
    if !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"There is no project: open a folder with a project.mirai")
        return
    }
    file:=project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator)
    opened,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {
        api.call_fail(call,api.SERVER_ERROR,project.error_text(s.project_root,error,context.temp_allocator))
        return
    }
    r:=api.call_result(call,Api_Project)
    r.file=file
    r.manifest=opened.manifest
    plugins:=make([]Api_Project_Plugin,len(opened.plugins),call.allocator)
    for &plugin,i in opened.plugins {
        name:=base.text_get(plugin.manifest.name[:])
        shown:=&plugins[i]
        shown^={name=plugin.manifest.name,active=slice.contains(opened.active,i),automatic=plugin.manifest.automatic,development=plugin.manifest.development,origin=plugin.origin==.Engine?"engine":"project",version=plugin.manifest.version}
        for index in opened.active {
            for &dependency in opened.plugins[index].manifest.dependencies {
                if base.text_get(dependency[:])==name {shown.needed_by=opened.plugins[index].manifest.name}
            }
        }
        for &entry in opened.manifest.plugins {shown.named|=base.text_get(entry[:])==name}
    }
    r.plugins=plugins
}

// Nothing is written unless all of it is valid.
@(private)
api_project_set :: proc(s:^Session,call:^api.Call) {
    if !s.has_project {
        api.call_fail(call,api.SERVER_ERROR,"There is no project: open a folder with a project.mirai")
        return
    }
    // The fields it gives go over project.mirai as they are; plugins switches plugins.
    fields:=strings.builder_make(context.temp_allocator)
    strings.write_byte(&fields,'{')
    members,_:=api.json_members(call.raw)
    for member in members {
        if member.name=="plugins" {continue}
        if len(fields.buf)>1 {strings.write_byte(&fields,',')}
        strings.write_quoted_string(&fields,member.name)
        strings.write_byte(&fields,':')
        strings.write_string(&fields,member.value)
    }
    strings.write_byte(&fields,'}')
    on,off:=make([dynamic]string,context.temp_allocator),make([dynamic]string,context.temp_allocator)
    if plugins:=string(api.call_params(call,Api_Project_Set_Params).plugins);plugins!="" {
        switched,is_object:=api.json_members(plugins)
        if !is_object {
            api.call_fail(call,api.INVALID_PARAMS,`plugins is an object: {"<plugin>": true to activate it, false to deactivate it}`)
            return
        }
        for member in switched {
            switch member.value {
            case "true":  append(&on,member.name)
            case "false": append(&off,member.name)
            case:
                api.call_failf(call,api.INVALID_PARAMS,"plugins: %s is true to activate it or false to deactivate it",member.name)
                return
            }
        }
    }
    file:=project.path(s.project_root,project.PROJECT_FILE,allocator=context.temp_allocator)
    manifest,error:=project.manifest_read(file)
    if error.code!=.None {
        api.call_fail(call,api.SERVER_ERROR,project.error_text(s.project_root,error,context.temp_allocator))
        return
    }
    if error=project.manifest_merge(&manifest,strings.to_string(fields));error.code!=.None {
        if error.code==.Text {
            api.call_failf(call,api.INVALID_PARAMS,"%s at column %d of the fields",error.detail,error.column)
        } else {
            api.call_fail(call,api.INVALID_PARAMS,project.error_text(s.project_root,error,context.temp_allocator))
        }
        return
    }
    if message:=project_plugins_switch(s,&manifest,on[:],off[:]);message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    message,building:=project_manifest_store(s,&manifest)
    if message!="" {
        api.call_fail(call,api.INVALID_PARAMS,message)
        return
    }
    build_error:string
    if building {building,build_error=api_project_build_wait(s)}
    api_project_set_write(s,call,building,build_error)
}

// The build a change of the project started, waited for as build.start waits:
// whether it still runs when the wait is over, and what failed when it ended
// failing, so that whoever changed the project hears it in the answer.
@(private)
api_project_build_wait :: proc(s:^Session) -> (building:bool,error:string) {
    running :: proc(s:^Session,user:rawptr) -> bool {return s.build.phase==.Running || s.build.reload}
    api_wait(s,API_BUILD_SECONDS,nil,running)
    return api_project_build_state(s)
}

@(private)
api_project_build_state :: proc(s:^Session) -> (building:bool,error:string) {
    b:=s.build
    if b.phase==.Running || b.reload {return true,""}
    if b.phase==.Failed {return false,api_build_first_error(s)}
    return false,""
}

// What project.set answers: whether a build still runs, what failed and which plugins are on.
@(private)
api_project_set_write :: proc(s:^Session,call:^api.Call,building:bool,build_error:string) {
    opened,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {
        api.call_fail(call,api.SERVER_ERROR,project.error_text(s.project_root,error,context.temp_allocator))
        return
    }
    active:=make([]string,len(opened.active),call.allocator)
    for index,i in opened.active {active[i]=strings.clone(base.text_get(opened.plugins[index].manifest.name[:]),call.allocator)}
    api.call_result(call,Api_Project_Changed)^={building,build_error,active}
}

