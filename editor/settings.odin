package editor

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "mirai:core"
import "mirai:editor/api"
import erender "mirai:engine/render"
import "mirai:host"
import "mirai:project"
import "mirai:rhi"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:ui"

// The settings: a section per @(storage,setting) of the engine, the active
// plugins and the game, with the rows of the Details panel. The dialog edits
// a layer of them (project.Settings_Layer): the project, whose values are
// those of the edited World, or of the application for a setting of the
// Shared, or the one of the engine on this machine, which holds only the
// settings of the machine (@(storage,setting="machine")) and which every
// project follows in what it does not set. A change takes effect at once and
// goes to the file of its layer when the gesture that makes it ends; a Play
// and the game read the files when they make their worlds.

SETTINGS_PLUGINS :: 64
SETTINGS_SECTION_INDENT :: f32(16) // of the sections of a category in the list, under its name

// The plugins the settings dialog lists: every one the project can see, the
// ones the project names and the ones their dependencies bring.
Settings_Plugins :: struct {
    names:[SETTINGS_PLUGINS]project.Name,
    named:[SETTINGS_PLUGINS]bool,       // project.mirai names it
    needed_by:[SETTINGS_PLUGINS]project.Name, // an active plugin that depends on it; empty: none
    development:[SETTINGS_PLUGINS]bool,
    automatic:[SETTINGS_PLUGINS]bool,   // active when its dependencies are: not listed
    icon_file:[SETTINGS_PLUGINS][project.RECENT_PATH]u8,
    icons:[SETTINGS_PLUGINS]Plugin_Icon,
    origin:[SETTINGS_PLUGINS]project.Origin,
    from_git:[SETTINGS_PLUGINS]bool,    // of the project, a checkout its project.mirai names a source for (plugins_git.odin), or a companion in one
    companion:[SETTINGS_PLUGINS]bool,   // comes and goes with the plugin whose companions folder has it
    source_commit:[SETTINGS_PLUGINS]project.Commit, // from git: the commit of its checkout
    source_catalog:[SETTINGS_PLUGINS]bool,          // from git: installed from the catalog
    catalog_update:[SETTINGS_PLUGINS]bool,          // from the catalog: it lists a commit the checkout does not have yet
    count:int,
}

// Reads the plugins of the project as project.mirai and the plugins found say now.
@(private)
settings_plugins_load :: proc(s:^Session) {
    list:=&s.settings_plugins
    list^={}
    if !s.has_project {return}
    p,error:=project.open(s.project_root,s.engine_root,context.temp_allocator)
    if error.code!=.None {return}
    for &plugin in p.plugins {
        if list.count>=SETTINGS_PLUGINS {break}
        list.names[list.count]=plugin.manifest.name
        list.development[list.count],list.automatic[list.count]=plugin.manifest.development,plugin.manifest.automatic
        base.text_set(list.icon_file[list.count][:],plugin_icon_file(plugin.folder,base.text_get(plugin.manifest.icon[:])))
        list.origin[list.count]=plugin.origin
        if source:=project.source_find(&p.manifest,base.text_get(plugin.manifest.name[:]));source!=nil && plugin.origin==.Project {
            list.from_git[list.count]=true
            list.source_commit[list.count],list.source_catalog[list.count]=source.commit,source.catalog
        }
        // <root>/plugins/<plugin>/plugins/<name>
        if parts:=strings.split(strings.trim_prefix(plugin.folder,p.root),"/",context.temp_allocator);plugin.origin==.Project && len(parts)==5 {
            list.companion[list.count]=true
            list.from_git[list.count]=project.source_find(&p.manifest,parts[2])!=nil
        }
        for named in p.manifest.plugins {
            if named==plugin.manifest.name {list.named[list.count]=true}
        }
        for index in p.active {
            // An automatic plugin follows its dependencies: it does not hold them on.
            if p.plugins[index].manifest.automatic {continue}
            for dependency in p.plugins[index].manifest.dependencies {
                if dependency==plugin.manifest.name {list.needed_by[list.count]=p.plugins[index].manifest.name}
            }
        }
        list.count+=1
    }
    plugins_git_catalog_updates(s)
}

// The settings of the edited World and of the application, as the file names them.
@(private)
settings_all :: proc(s:^Session) -> []project.Setting {
    list:=make([dynamic]project.Setting,context.temp_allocator)
    append(&list,..host.app_settings(s.info,s.edit_world,.World,s.app.device))
    append(&list,..host.app_settings(s.info,s.app.shared,.Shared,s.app.device))
    return list[:]
}

// Opens Project Settings, as the File menu does, on the setting of the world named name.
settings_open :: proc(s:^Session,name:string) {
    if command_state(s,"settings").disabled || s.info==nil {return}
    settings_show(s)
    d:=&s.settings_dialog
    for c in settings_categories(s) {
        for storage,k in c.storages {
            if s.info.storages[storage].name!=name {continue}
            d.current,d.section,d.jump=c.storage,k,k
            return
        }
    }
}

// The settings of the edited World and of the application as the code and the files of the layers this process reads leave them.
@(private)
settings_load :: proc(s:^Session) {
    if !s.has_project {return}
    all:=settings_all(s)
    layers:=project.settings_layers_of_process()
    if error,layer:=project.settings_load(all,s.project_root,s.engine_root,layers);error.code!=.None {notify(s,settings_error_text(s,error,layer))}
    if .Engine not_in layers {return}
    if misplaced:=project.settings_misplaced(all,s.project_root,s.engine_root);len(misplaced)>0 {
        notify(s,fmt.tprintf("%s: settings of the project, which %s does not read; move them to the settings of the project",strings.join(misplaced,", ",context.temp_allocator),project.settings_file(.Engine,s.project_root,s.engine_root,context.temp_allocator)))
    }
}

// The names of the settings of the machine, as settings.get and its errors list them.
@(private)
settings_machine_names :: proc(s:^Session) -> string {
    names:=make([dynamic]string,context.temp_allocator)
    for info in s.info.storages {
        if info.setting==.Machine {append(&names,info.name)}
    }
    return strings.join(names[:],", ",context.temp_allocator)
}

// What is wrong with the file of a layer, for whoever has to fix it.
@(private)
settings_error_text :: proc(s:^Session,error:project.Error,layer:project.Settings_Layer) -> string {
    return settings_file_error_text(project.settings_file(layer,s.project_root,s.engine_root,context.temp_allocator),error)
}

// What is wrong with a file of settings or of preferences.
@(private)
settings_file_error_text :: proc(file:string,error:project.Error) -> string {
    #partial switch error.code {
    case .Text:        return fmt.tprintf("%s: %s at line %d, column %d; fix the file or remove it",file,error.detail,error.line,error.column)
    case .Read_Failed: return fmt.tprintf("%s could not be read",file)
    }
    return fmt.tprintf("%s could not be written",file)
}

// Writes the values of a layer into its file. The engine layer lies under the
// project: the edited World takes it again with the project over it.
@(private)
settings_store :: proc(s:^Session,values:[]project.Setting,layer:project.Settings_Layer) -> (message:string) {
    if !s.has_project {return "There is no project to keep the settings in"}
    if layer==.Engine && s.engine_root=="" {return "The root of the engine is not known: only the project layer can be written"}
    if error,failed:=project.settings_save(values,layer,s.project_root,s.engine_root);error.code!=.None {return settings_error_text(s,error,failed)}
    if layer==.Engine {settings_load(s)}
    return ""
}

// Writes a layer: the project from the edited World and the application, the
// engine from the values the dialog holds of it.
settings_save :: proc(s:^Session,layer:=project.Settings_Layer.Project) -> bool {
    s.settings_unsaved=false
    if !s.has_project || layer==.Engine && s.settings_engine==nil {return false}
    if message:=settings_store(s,layer==.Engine?s.settings_engine:settings_all(s),layer);message!="" {
        notify(s,message)
        return false
    }
    return true
}

// The values of the code and of the file of the engine, for the dialog: what
// it edits in the engine layer, and what a field of the project goes back to.
@(private)
settings_engine_load :: proc(s:^Session) {
    settings_engine_free(s)
    s.settings_engine=project.settings_clone(settings_all(s))
    if error,layer:=project.settings_load(s.settings_engine,s.project_root,s.engine_root,{.Engine});error.code!=.None {notify(s,settings_error_text(s,error,layer))}
}

@(private)
settings_engine_free :: proc(s:^Session) {
    if s.settings_engine!=nil {free(raw_data(s.settings_engine))}
    s.settings_engine=nil
}

// The value of a setting in the engine layer the dialog holds; nil when it does not hold it.
@(private)
setting_engine_value :: proc(s:^Session,name:string) -> rawptr {
    for setting in s.settings_engine {
        if setting.name==name {return setting.value}
    }
    return nil
}

// The dialog edits another layer, once the one it edited has what changed in it.
@(private)
settings_layer_set :: proc(s:^Session,layer:project.Settings_Layer) {
    if s.settings_unsaved {settings_save(s,s.settings_layer)}
    s.settings_layer=layer
}

// The value the project gives a setting of the world, of its type, as the
// dialog edits it: what a plugin shows as the game would. nil when the world
// has no setting of that type. Only read it.
setting_value :: proc(s:^Session,type:typeid) -> rawptr {
    if s.info==nil {return nil}
    for &info,i in s.info.storages {
        if info.type==type && info.setting!=.None {return setting_data(s,i)}
    }
    return nil
}

// Where the dialog reads and writes a setting of the world info: the edited
// World or the application, or the values of the engine layer.
@(private)
setting_data :: proc(s:^Session,storage:int) -> rawptr {
    info:=&s.info.storages[storage]
    if s.settings_layer==.Engine {
        if value:=setting_engine_value(s,info.name);value!=nil {return value}
    }
    data:=info.place==.Shared?s.app.shared:s.edit_world
    return rawptr(uintptr(data)+info.offset)
}

// Writes bytes at an offset of a setting of the world info, where the dialog
// edits it. The file of its layer takes it when the gesture that changes it ends.
@(private)
setting_write :: proc(s:^Session,storage,offset:int,bytes:[]u8) {
    if storage<0 || storage>=len(s.info.storages) {return}
    info:=&s.info.storages[storage]
    if offset<0 || offset+len(bytes)>info.info.size {return}
    if info.setting==.None || s.settings_layer==.Engine && info.setting!=.Machine {return}
    mem.copy(rawptr(uintptr(setting_data(s,storage))+uintptr(offset)),raw_data(bytes),len(bytes))
    s.settings_unsaved=true
}

// Writes the file of the layer the dialog edits once no gesture is changing it.
@(private)
settings_flush :: proc(s:^Session) {
    settings_project_flush(s)
    if s.settings_unsaved && s.inspector.gesture==0 {settings_save(s,s.settings_layer)}
}

// The dialog: the categories in groups on its left, the sections of the one
// shown as cards on its right. A category is the Plugins of the project or a
// setting; its sections are the titles of its fields (section=Title), and
// the fields before the first title make one with its name.
SETTINGS_SIZE :: [2]f32{800,576}
SETTINGS_NAV :: f32(202)
SETTINGS_CATEGORY_PLUGINS :: -1
SETTINGS_CATEGORY_INPUT :: -2
SETTINGS_CATEGORY_EDITOR :: -4 // the preferences of the editor in the machine (preferences.odin), not of the project

Settings_Dialog :: struct {
    current:int,          // the category shown: a storage of the world info, SETTINGS_CATEGORY_PROJECT, SETTINGS_CATEGORY_PLUGINS or SETTINGS_CATEGORY_INPUT
    section:int,          // the card in sight of the category shown
    jump:int,             // a card to bring to the top on the next frame; -1: none
    unfolded:[256]bool,   // categories whose sections the list shows, by settings_fold_slot
    search:[64]u8,
    search_length:int,
    scroll,nav_scroll:[2]f32,
    input:Input_Settings, // the category Input (input_settings.odin)
}

// Where unfolded keeps a category: a storage at its index +1, Input at the last.
@(private)
settings_fold_slot :: proc(storage:int) -> int {
    if storage==SETTINGS_CATEGORY_INPUT {return len(Settings_Dialog{}.unfolded)-1}
    if storage==SETTINGS_CATEGORY_PROJECT {return len(Settings_Dialog{}.unfolded)-2}
    if storage==SETTINGS_CATEGORY_EDITOR {return len(Settings_Dialog{}.unfolded)-3}
    return storage+1
}

@(private)
Settings_Category :: struct {
    storage:int,       // its first, or SETTINGS_CATEGORY_PROJECT or SETTINGS_CATEGORY_PLUGINS
    name,group:string,
    sections:[]string, // the cards; "" is the one of the fields before the first title
    storages:[]int,    // of settings: the storage each card shows, the settings of one package or plugin together
}

// A category of the list: its name and where it comes from, the engine, a plugin or the game.
@(private)
settings_categories :: proc(s:^Session) -> []Settings_Category {
    list:=make([dynamic]Settings_Category,context.temp_allocator)
    d:=&s.settings_dialog
    needle:=string(d.search[:d.search_length])
    // The editor goes first in both layers: its preferences are of the machine.
    if needle=="" || base.contains_fold("Editor Panels Floating Docked",needle) {
        append(&list,Settings_Category{storage=SETTINGS_CATEGORY_EDITOR,name="Editor",group="Editor",sections=[]string{"Panels"}})
    }
    if s.settings_layer==.Project && s.has_project {
        manifest:=Settings_Category{storage=SETTINGS_CATEGORY_PROJECT,name="Project",group="Project"}
        manifest.sections=settings_sections(type_info_of(project.Manifest),manifest.name,needle)
        if len(manifest.sections)>0 {append(&list,manifest)}
    }
    if s.settings_layer==.Project && s.settings_plugins.count>0 {
        plugins:=Settings_Category{storage=SETTINGS_CATEGORY_PLUGINS,name="Plugins",group="Project"}
        found:=needle=="" || base.contains_fold("Plugins",needle) || base.contains_fold("Git",needle) || base.contains_fold("Catalog",needle)
        for i in 0..<s.settings_plugins.count {found|=!s.settings_plugins.automatic[i] && base.contains_fold(base.text_get(s.settings_plugins.names[i][:]),needle)}
        if found {append(&list,plugins)}
    }
    if s.settings_layer==.Project && s.has_project {
        sections:=input_sections(s,needle)
        if len(sections)>0 {append(&list,Settings_Category{storage=SETTINGS_CATEGORY_INPUT,name="Input",group="Project",sections=sections})}
    }
    // The settings of one package or plugin are one category, each a part of it.
    for pass in 0..<3 {
        first:=len(list)
        for &info,index in s.info.storages {
            if info.setting==.None || s.settings_layer==.Engine && info.setting!=.Machine {continue}
            group:=settings_group(s,&info)
            if pass==0 && group!="Engine" || pass==1 && (group=="Engine" || group=="Game") || pass==2 && group!="Game" {continue}
            owner:=settings_owner(&info)
            at:=-1
            for &c,i in list[first:] {
                if settings_owner(&s.info.storages[c.storage])==owner {at=first+i;break}
            }
            name:=settings_storage_name(&info)
            sections:=settings_sections(info.info,name,needle)
            if at<0 {
                append(&list,Settings_Category{storage=index,name=name,group=group})
                at=len(list)-1
            }
            c:=&list[at]
            joined:=make([dynamic]string,context.temp_allocator)
            storages:=make([dynamic]int,context.temp_allocator)
            append(&joined,..c.sections);append(&storages,..c.storages)
            for title in sections {append(&joined,title);append(&storages,index)}
            c.sections,c.storages=joined[:],storages[:]
        }
        // A plugin names its category; one of several of a package, the one it is named after.
        for &c in list[first:] {
            if plugin:=s.info.storages[c.storage].plugin;plugin!="" {
                c.name=readable(plugin)
                continue
            }
            if !settings_grouped(c) {continue}
            owner:=strings.to_lower(settings_owner(&s.info.storages[c.storage]),context.temp_allocator)
            c.name=readable(owner)
            for index in c.storages {
                if name:=settings_storage_name(&s.info.storages[index]);strings.contains(owner,strings.to_lower(name,context.temp_allocator)) {c.name=name;break}
            }
        }
        for i:=first;i<len(list); {
            if len(list[i].sections)==0 {ordered_remove(&list,i)} else {i+=1}
        }
    }
    return list[:]
}

@(private)
settings_owner :: proc(info:^core.Storage_Info) -> string {return info.plugin if info.plugin!="" else info.library}

@(private)
settings_storage_name :: proc(info:^core.Storage_Info) -> string {return readable(strings.trim_suffix(info.name,"_Settings"))}

// Whether a category holds the settings of more than one storage.
@(private)
settings_grouped :: proc(c:Settings_Category) -> bool {
    for index in c.storages {
        if index!=c.storage {return true}
    }
    return false
}

// What a card and its entry in the list say: the title of its section, or
// for the fields before the first title, the name of its setting when the
// category holds several, else the name of the category.
@(private)
settings_section_title :: proc(s:^Session,c:Settings_Category,k:int) -> string {
    if c.sections[k]!="" {return c.sections[k]}
    if !settings_grouped(c) {return c.name}
    // Under the category its name is not said again: Audio > Volumes, and General for its own.
    name:=settings_storage_name(&s.info.storages[c.storages[k]])
    if len(name)>=len(c.name) && strings.equal_fold(name[:len(c.name)],c.name) {name=strings.trim_space(name[len(c.name):])}
    if name=="" {return "General"}
    return readable(name)
}

// Where a setting comes from: the engine, a plugin or the game.
@(private)
settings_group :: proc(s:^Session,info:^core.Storage_Info) -> string {
    if info.plugin!="" {return "Plugins"}
    for i in 0..<s.settings_plugins.count {
        if base.text_get(s.settings_plugins.names[i][:])==info.library {return "Plugins"}
    }
    for &t in s.info.tables {
        if t.library==info.library && t.game {return "Game"}
    }
    return "Engine"
}

// The titles of the sections of a setting in the order of its fields, and
// of them those with a field whose name has needle; all of them when the
// title or the name of the setting has it.
@(private)
settings_sections :: proc(info:^runtime.Type_Info,name,needle:string) -> []string {
    titles:=make([dynamic]string,context.temp_allocator)
    v,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return titles[:]}
    every:=needle=="" || base.contains_fold(name,needle)
    current:=""
    found:=false
    for i in 0..<int(v.field_count) {
        tag:=reflect.Struct_Tag(v.tags[i])
        tagged:=field_tagged(v.tags[i])
        if title:=tagged.section;title!="" && title!=current {
            if found {append(&titles,current)}
            current,found=title,false
        }
        if .Hidden in tagged.flags {continue}
        if .Transient in tagged.flags {continue}
        label:=readable(v.names[i])
        if custom:=tagged.label;custom!="" {label=custom}
        found|=every || base.contains_fold(current,needle) || base.contains_fold(label,needle)
    }
    if found {append(&titles,current)}
    return titles[:]
}

// Whether the section title of a setting shows fields not tagged advanced,
// and fields tagged advanced, of those whose name has needle (all: empty).
@(private)
settings_section_fields :: proc(info:^runtime.Type_Info,title,needle:string) -> (plain,advanced:bool) {
    v,is_struct:=runtime.type_info_base(info).variant.(runtime.Type_Info_Struct)
    if !is_struct {return}
    current:=""
    for i in 0..<int(v.field_count) {
        tag:=reflect.Struct_Tag(v.tags[i])
        tagged:=field_tagged(v.tags[i])
        if section:=tagged.section;section!="" {current=section}
        if current!=title || .Hidden in tagged.flags || .Transient in tagged.flags {continue}
        label:=readable(v.names[i])
        if custom:=tagged.label;custom!="" {label=custom}
        if needle!="" && !base.contains_fold(label,needle) {continue}
        if .Advanced in tagged.hints {advanced=true} else {plain=true}
    }
    return
}

// A row per plugin the project can see but the automatic ones, under where
// it comes from, each with its switch: the ones an active plugin needs are
// on and cannot go off.
// Those from git have their update and removal; under them, adding more.
@(private)
settings_plugins_rows :: proc(s:^Session,needle:string) {
    ctx:=s.gui.ctx
    th:=&ctx.theme
    list:=&s.settings_plugins
    ui.id_push(ctx,ui.id(ctx,"plugins"))
    defer ui.id_pop(ctx)
    Group :: enum u8 {Project,Git,Engine}
    titles:=[Group]string{.Project="Project",.Git="Git",.Engine="Engine"}
    for group in Group {
        titled,open:=false,true
        defer if titled && open {fold_band_end(s)}
        for i in 0..<list.count {
            name:=base.text_get(list.names[i][:])
            in_group:Group=list.origin[i]==.Engine?.Engine:list.from_git[i]?.Git:.Project
            if in_group!=group || list.automatic[i] || needle!="" && !base.contains_fold(name,needle) && !base.contains_fold("Plugins",needle) {continue}
            if !titled {
                open=fold_section(s,ui.id(ctx,"origin",int(group)+1),base.hash_combine(0x706c7567696e73,u64(group)),titles[group])
                if open {fold_band_begin(s)}
                titled=true
            }
            if !open {break}
            needed:=base.text_get(list.needed_by[i][:])
            on:=list.named[i] || needed!=""
            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=6,align_y=.Center}) {
                plugin_icon_draw(s,&list.icons[i],base.text_get(list.icon_file[i][:]))
                ui.label(ctx,name,th.font_small,th.text_label)
                if list.development[i] {
                    if ui.box(ctx,{width=ui.FIT,height=ui.fixed(18),padding={6,0,6,0},align_y=.Center,fill={242,184,75,20},stroke={242,184,75,85},radius=th.radius_control}) {ui.label(ctx,"dev",th.font_caption,{242,184,75,255})}
                }
                if needed!="" {ui.label(ctx,fmt.tprintf("needed by %s",needed),th.font_label,th.text_faint)}
                ui.spacer(ctx)
                if group==.Git && !list.companion[i] {plugins_git_row_actions(s,i)}
                if ui.toggle_switch(ctx,ui.id(ctx,name),&on,disabled=needed!="" || s.build.phase==.Running || plugins_git_busy(s)) {settings_plugin_set(s,list.names[i],on)}
            }
        }
    }
    if needle=="" || base.contains_fold("Plugins",needle) || base.contains_fold("Git",needle) || base.contains_fold("Catalog",needle) {settings_plugins_git(s)}
}

// How the right panel sits: the mode of every document, and under it each
// type of document with the mode of its own or the global one. An asset
// document draws its own right side.
@(private)
settings_panels_card :: proc(s:^Session) {
    ctx:=s.gui.ctx;th:=&ctx.theme;l:=&s.gui.layout
    modes:=[]string{"Floating","Docked"}
    choices:=[]string{"Global","Floating","Docked"}
    column:=f32(190)
    ui.id_push(ctx,ui.id(ctx,"panels"))
    defer ui.id_pop(ctx)
    if ui.property(ctx,"Right panel") {
        value:=int(l.right_mode)
        if ui.tabs(ctx,ui.id(ctx,"right"),modes,&value,ui.fixed(column),th.control) {l.right_mode=Panel_Mode(value)}
    }
    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.row),gap=4,align_y=.End}) {
        if ui.box(ctx,{width=ui.fixed(th.label_width),height=ui.FIT}) {ui.label(ctx,"BY DOCUMENT",th.font_caption,th.text_caption,font=ui.FONT_SEMIBOLD)}
        ui.label(ctx,"Right",th.font_caption,th.text_faint,column)
    }
    names:=#partial [Document_Type]string{.Scene="Scene",.Prefab="Prefab"}
    for type in Document_Type {
        if type==.Asset {continue}
        if ui.property(ctx,names[type]) {
            right:=int(l.right_modes[type])
            if ui.tabs(ctx,ui.id(ctx,"right_of",int(type)+1),choices,&right,ui.fixed(column),th.control) {l.right_modes[type]=Panel_Choice(right)}
        }
    }
}


// What the fields of the layer the dialog edits go back to: the layers under it.
@(private)
settings_defaults :: proc(s:^Session,info:^core.Storage_Info,defaults:^[INSPECTOR_COMPONENT_BYTES]u8) -> [^]u8 {
    if engine:=setting_engine_value(s,info.name);s.settings_layer==.Project && engine!=nil {return cast([^]u8)engine}
    if info.info.size>len(defaults) {return nil}
    if info.for_device!=nil && s.app.device!=nil {info.for_device(&defaults[0],rhi.device_info(s.app.device))} else if info.default!=nil {info.default(&defaults[0])}
    return raw_data(defaults[:])
}

// Whether a field of the layer the dialog edits differs from the layers under it.
@(private)
settings_changed :: proc(s:^Session) -> bool {
    for &info,index in s.info.storages {
        if info.setting==.None || s.settings_layer==.Engine && info.setting!=.Machine {continue}
        defaults:[INSPECTOR_COMPONENT_BYTES]u8
        under:=settings_defaults(s,&info,&defaults)
        if under!=nil && mem.compare_ptrs(under,setting_data(s,index),info.info.size)!=0 {return true}
    }
    return false
}

// Every setting of the layer the dialog edits back to the layers under it: its file keeps none.
@(private)
settings_reset :: proc(s:^Session) {
    for &info,index in s.info.storages {
        if info.setting==.None || s.settings_layer==.Engine && info.setting!=.Machine {continue}
        defaults:[INSPECTOR_COMPONENT_BYTES]u8
        if under:=settings_defaults(s,&info,&defaults);under!=nil {setting_write(s,index,0,under[:info.info.size])}
    }
    settings_save(s,s.settings_layer)
}

@(private)
settings_modal :: proc(s:^Session) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    d:=&s.settings_dialog
    if s.settings_engine==nil {settings_engine_load(s)}
    // The dialog edits the project; the settings of the machine are the Graphics popup's and the preferences'.
    if s.settings_layer==.Engine {settings_layer_set(s,.Project)}
    closed:=false
    defer if closed {g.modal,d.input.listen=.None,{}}
    size:=[2]f32{min(SETTINGS_SIZE.x,ctx.size.x-2*th.margin),min(SETTINGS_SIZE.y,ctx.size.y-2*th.margin)}
    needle:=strings.trim_space(string(d.search[:d.search_length]))
    categories:=settings_categories(s)
    shown:=-1
    for category,i in categories {
        if category.storage==d.current {shown=i}
    }
    if shown<0 && len(categories)>0 {
        shown=0
        d.current,d.section,d.scroll=categories[0].storage,0,0
    }
    if d.input.listen.active {input_listen_poll(s)}
    if ui.modal(ctx,shell_id(g,"settings"),{width=size.x,padding=-1,close=&closed,own_cross=true,fill=th.panel}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(size.y)}) {
            settings_nav(s,categories,shown,needle,size.y)
            if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=th.border}) {}
            if ui.box(ctx,{width=ui.GROW,height=ui.GROW,direction=.Column}) {
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(57),padding={20,0,14,0},gap=10,align_y=.Center}) {
                    ui.label(ctx,shown>=0?categories[shown].name:"No results",th.font_heading,th.text,0,font=ui.FONT_SEMIBOLD)
                    search:=shell_id(g,"settings_search")
                    if ui.box(ctx,{width=ui.fixed(220),height=ui.fixed(th.control),padding={9,0,4,0},gap=6,align_y=.Center,fill=th.well,stroke=ctx.edit.id==search?th.accent:th.well_stroke,radius=th.radius_control}) {
                        ui.icon(ctx,ui.icon_user(u8(User_Icon.Search)),th.text_muted,13)
                        if ui.text_field(ctx,search,d.search[:],&d.search_length,{placeholder="Search settings",live=true,keep_caret=true,height=ctx.theme.control,size=th.font,bare=true}).changed {d.scroll=0}
                        if d.search_length>0 && ui.button(ctx,shell_id(g,"settings_search_clear"),{icon=.Cross,icon_size=10,icon_color=th.text_muted,style=.Ghost,width=20,height=20}).clicked {d.search_length,d.scroll=0,0}
                    }
                    if ui.button(ctx,shell_id(g,"settings_close"),{icon=.Cross,icon_size=12,icon_color=th.text_muted,style=.Ghost,width=25,height=ctx.theme.control}).clicked {closed=true}
                }
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.border}) {}
                if shown<0 {
                    if ui.box(ctx,{width=ui.GROW,height=ui.GROW,padding={18,54,18,0},align_x=.Center}) {
                        ui.label(ctx,fmt.tprintf("No setting matches \"%s\".",needle),th.font,th.text_muted)
                    }
                } else {
                    settings_cards(s,categories[shown],needle,size.y-58)
                }
            }
        }
    }
}

// The list of the categories: the name of the dialog and the project, a
// title per group and, under a category unfolded, its sections.
@(private)
settings_nav :: proc(s:^Session,categories:[]Settings_Category,shown:int,needle:string,height:f32) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    d:=&s.settings_dialog
    unfolded :: proc(d:^Settings_Dialog,c:Settings_Category,needle:string) -> bool {
        slot:=settings_fold_slot(c.storage)
        return len(c.sections)>1 && (needle!="" || slot>=0 && slot<len(d.unfolded) && d.unfolded[slot])
    }
    any_open:=false
    foldable:=false
    for c in categories {
        foldable|=len(c.sections)>1
        any_open|=unfolded(d,c,needle)
    }
    if ui.box(ctx,{width=ui.fixed(SETTINGS_NAV),height=ui.GROW,direction=.Column,padding={10,14,10,11},gap=4}) {
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control+4),padding={5,0,0,0},gap=8,align_y=.Center}) {
            if ui.box(ctx,{width=ui.fixed(28),height=ui.fixed(28),fill=th.accent,radius=th.radius_popup,align_x=.Center,align_y=.Center}) {ui.icon(ctx,ui.icon_user(u8(User_Icon.Gear)),th.on_accent,15)}
            if ui.box(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column}) {
                ui.label(ctx,"Project settings",th.font,th.text,0,font=ui.FONT_SEMIBOLD)
                ui.label(ctx,project_name(s),th.font_small,th.text_muted,0)
            }
            if ui.button(ctx,shell_id(g,"settings_unfold"),{icon=any_open?ui.icon_user(u8(User_Icon.Collapse)):.Plus,icon_size=13,icon_color=th.text_muted,style=.Ghost,width=25,height=ctx.theme.control,disabled=!foldable || needle!=""}).clicked {
                for c in categories {
                    if slot:=settings_fold_slot(c.storage);slot>=0 && slot<len(d.unfolded) {d.unfolded[slot]=!any_open}
                }
            }
        }
        // The bar of the scroll goes in its own gutter at the right, over no item.
        if ui.scroll_area(ctx,shell_id(g,"settings_nav"),&d.nav_scroll,{height=ui.GROW,padding={0,6,10,0},gap=2,fade=th.panel}) {
            group:=""
            for c,i in categories {
                if c.group!=group {
                    group=c.group
                    if ui.box(ctx,{width=ui.GROW,height=ui.fixed(i==0?20:30),padding={9,0,0,4},gap=7,align_y=.End}) {
                        ui.label(ctx,strings.to_upper(group,context.temp_allocator),th.font_caption,th.text_caption,font=ui.FONT_SEMIBOLD)
                        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(5),padding={0,0,0,4},direction=.Column}) {
                            if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.border}) {}
                        }
                    }
                }
                open:=unfolded(d,c,needle)
                current:=i==shown
                id:=shell_id(g,"settings_category",i+1)
                it:=ui.interact(ctx,id,{.Focusable})
                if ui.box(ctx,{id=id,width=ui.GROW,height=ui.fixed(th.control),padding={9,0,9,0},align_y=.Center,fill=current?th.accent_soft:it.hot?th.field_hover:ui.Color{},radius=th.radius_control}) {
                    ui.label(ctx,c.name,th.font,current?th.text:th.text_muted,0,font=current?ui.FONT_SEMIBOLD:ui.FONT_REGULAR)
                    if len(c.sections)>1 {ui.icon(ctx,open?.Chevron_Down:.Chevron_Right,th.text_faint,11)}
                }
                if it.clicked {
                    if d.current!=c.storage {d.current,d.section,d.scroll=c.storage,0,0}
                    if slot:=settings_fold_slot(c.storage);len(c.sections)>1 && needle=="" && slot>=0 && slot<len(d.unfolded) {d.unfolded[slot]=!d.unfolded[slot]}
                }
                if !open {continue}
                // The sections hang from their category: indented, after a rule.
                ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,padding={SETTINGS_SECTION_INDENT,2,0,2},gap=6})
                if ui.box(ctx,{width=ui.fixed(1),height=ui.GROW,fill=th.border}) {}
                ui.box_begin(ctx,{width=ui.GROW,height=ui.FIT,direction=.Column})
                for title,k in c.sections {
                    sub:=shell_id(g,"settings_section",(i+1)*64+k)
                    on:=current && d.section==k
                    if ui.button(ctx,sub,{label=settings_section_title(s,c,k),style=.Ghost,active=on,width=-1,height=th.row,size=th.font_small,padding=7}).clicked {
                        if d.current!=c.storage {d.current,d.scroll=c.storage,0}
                        d.section,d.jump=k,k
                    }
                }
                ui.box_end(ctx,{})
                ui.box_end(ctx,{})
            }
        }
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.border}) {}
        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),padding={6,0,0,0},align_y=.Center}) {
            changed:=settings_changed(s)
            appearance:=ui.Node_Style{text={size=th.font_label,color=changed?th.accent_hover:th.text_faint}}
            reset,confirm:=shell_id(g,"settings_reset"),shell_id(g,"settings_reset_confirm")
            if ui.button(ctx,reset,{label="Reset to default",width=0,height=th.row,size=th.font_label,padding=0,disabled=!changed,look=&appearance}).clicked {
                anchor,_:=ui.widget_rect(ctx,reset)
                ui.popup_open(ctx,confirm,anchor)
            }
            // What it undoes cannot be got back: it asks first.
            if ui.popup(ctx,confirm,{width=280,padding=12,gap=8}) {
                ui.label(ctx,"Reset to default?",th.font,th.text,font=ui.FONT_SEMIBOLD)
                ui.text(ctx,"Every setting of the project goes back to those of the engine and the code.",ui.prose(ctx,th.font_small,th.text_muted))
                if ui.box(ctx,{width=ui.GROW,height=ui.fixed(th.control),gap=8,align_x=.End,align_y=.Center}) {
                    if ui.button(ctx,shell_id(g,"settings_reset_cancel"),{label="Cancel",style=.Field,width=84,height=th.control,center=true}).clicked {ui.popup_close(ctx,confirm)}
                    if ui.button(ctx,shell_id(g,"settings_reset_yes"),{label="Reset",style=.Accent,width=84,height=th.control,center=true}).clicked {
                        settings_reset(s)
                        ui.popup_close(ctx,confirm)
                    }
                }
            }
        }
    }
}

// The id of the card k of a category, the same wherever it is built: the
// list finds it to bring it to the top, and its fold is its own.
@(private)
settings_card_id :: proc(s:^Session,category,k:int) -> ui.Id {
    return ui.id_derive(s.gui.ctx,shell_id(s.gui,"settings_cards"),"card",(category+8)*256+k+1)
}

// The sections of the category shown, a card each.
@(private)
settings_cards :: proc(s:^Session,category:Settings_Category,needle:string,height:f32) {
    g:=s.gui
    ctx:=g.ctx
    th:=&ctx.theme
    d:=&s.settings_dialog
    area:=shell_id(g,"settings_cards")
    // The card asked for comes to the top; the one at the top is the one the list lights.
    if view,found:=ui.widget_rect(ctx,area);found {
        for k in 0..<len(category.sections) {
            card_rect,placed:=ui.widget_rect(ctx,settings_card_id(s,category.storage,k))
            if !placed {continue}
            if d.jump==k {d.scroll+=card_rect.y-view.y-14}
            if d.jump<0 && card_rect.y-view.y<=48 {d.section=k}
        }
    }
    d.jump=-1
    // The bands of the sections reach both edges; their rows are set in.
    if ui.scroll_area(ctx,area,&d.scroll,{height=ui.fixed(height),padding={0,14,0,18},gap=10,fade=th.panel}) {
        // The fields read at the size of the rest of the dialog, with the room
        // it has for the column of labels.
        theme:=ctx.theme
        ctx.theme.font_small=theme.font
        ctx.theme.label_width=(SETTINGS_SIZE.x-SETTINGS_NAV-60)*0.3
        defer ctx.theme=theme
        if category.storage==SETTINGS_CATEGORY_EDITOR {
            if section_card(s,settings_card_id(s,category.storage,0),"Panels") {settings_panels_card(s)}
            return
        }
        if category.storage==SETTINGS_CATEGORY_PLUGINS {
            if section_card(s,settings_card_id(s,category.storage,0),"") {settings_plugins_rows(s,needle)}
            return
        }
        if category.storage==SETTINGS_CATEGORY_PROJECT {
            for title,k in category.sections {
                if section_card(s,settings_card_id(s,category.storage,k),title) {settings_project_card(s,title,needle,needle=="" || base.contains_fold(category.name,needle))}
            }
            return
        }
        if category.storage==SETTINGS_CATEGORY_INPUT {
            input_settings_cards(s,needle)
            return
        }
        w:=edited_world(s)
        grouped:=settings_grouped(category)
        // The name of the category is the title of the dialog: a card says only the title of its section.
        for title,k in category.sections {
            storage:=category.storages[k]
            info:=&s.info.storages[storage]
            every:=needle=="" || base.contains_fold(category.name,needle) || base.contains_fold(settings_storage_name(info),needle)
            if section_card(s,settings_card_id(s,category.storage,k),settings_section_title(s,category,k) if grouped || title!="" else "") {
                // The ids of the rows are those of their setting: two of a category do not share them.
                ui.id_push(ctx,ui.id(ctx,info.name))
                defer ui.id_pop(ctx)
                c:=Inspect{s=s,w=w,index=SETTING_INDEX+storage,storage=storage+1,name=info.name,type=info.type,value=cast([^]u8)setting_data(s,storage),size=info.info.size,width=SETTINGS_SIZE.x-SETTINGS_NAV-60,sections=true,section=title,ruled=true}
                if !every && !base.contains_fold(title,needle) {c.needle=needle}
                defaults:[INSPECTOR_COMPONENT_BYTES]u8
                c.defaults=settings_defaults(s,info,&defaults)
                fields_rows(&c,info.info,0,0,"")
                // The fields tagged advanced go last, under a fold that starts closed.
                if plain,advanced:=settings_section_fields(info.info,title,c.needle);advanced {
                    if plain {
                        if ui.box(ctx,{width=ui.GROW,height=ui.fixed(1),fill=th.row_rule}) {}
                    }
                    key:=base.hash_combine(base.hash_combine(u64(c.index),base.hash64(transmute([]u8)title)),0x616476616e636564)
                    if fold_section(s,ui.id(ctx,"settings_advanced",k+1),key,ADVANCED_SECTION,folded=true,searching=needle!="") {
                        fold_band_begin(s)
                        c.advanced=true
                        fields_rows(&c,info.info,0,0,"")
                        fold_band_end(s)
                    }
                }
            }
        }
    }
}

// The name of the project, as its folder.
@(private)
project_name :: proc(s:^Session) -> string {
    root:=strings.trim_right(s.project_root,"/\\")
    if slash:=strings.last_index_any(root,"/\\");slash>=0 {return root[slash+1:]}
    return root
}

// ---------------------------------------------------------------- API

API_SECTIONS :: 32 // how many sections, areas or actions a get names

Api_Settings_Get_Params :: struct {
    sections:[API_SECTIONS][64]u8 `mirai:"text,optional,label=Only these sections, by the names settings gives them; none: every section"`,
}

Api_Settings :: struct {
    machine:[]string `mirai:"optional,label=The settings of the machine: the only ones the file of the engine holds; only without sections"`,
    settings:serial.Json `mirai:"label=Every value in effect: a section per setting with its fields"`,
    engine:serial.Json `mirai:"label=The sections and fields the file of the engine sets over the values of the code"`,
    project:serial.Json `mirai:"label=The sections and fields the file of the project sets over the engine and the code"`,
}

Api_Settings_Set_Params_Graphics_Preset :: enum u8 {Low,Medium,High,Ultra}
Api_Settings_Set_Params_Layer :: enum u8 {project,engine}
Api_Settings_Set_Params :: struct {
    graphics_preset:Api_Settings_Set_Params_Graphics_Preset `mirai:"optional,label=Sets every field of the quality of Graphics_Settings as that preset of the Graphics popup does, before what settings says"`,
    layer:Api_Settings_Set_Params_Layer `mirai:"optional,label=project, the default, may set any setting; engine holds only the settings of the machine (machine in settings.get), which every project follows in what it does not set"`,
    settings:serial.Json `mirai:"optional,label={'<Section>': {'<field>': value}}: an object of sections, each with the fields to change"`,
}

@(private)
settings_api_register :: proc(s:^Session,st:^Api_State) {
    api_register(s,st,{name="settings.get",summary="The settings of the engine, the active plugins and the game: the values in effect and what the file of each layer sets over the layers under it.",params=type_info_of(Api_Settings_Get_Params),result=type_info_of(Api_Settings),flags={.Read_Only},run=api_settings_get})
    api_register(s,st,{name="settings.set",params=type_info_of(Api_Settings_Set_Params),summary="Changes settings in a layer, whose file keeps what differs from the layers under it; the edited World and the games that play take the result at once and it answers with the sections changed.",result=type_info_of(Api_Settings),run=api_settings_set})
}

@(private)
api_settings_get :: proc(s:^Session,call:^api.Call) {
    keep,named:=api_sections_kept(call,api.call_params(call,Api_Settings_Get_Params).sections[:],settings_all(s),"setting")
    if named {api_settings_write(s,call,keep)}
}

// The settings each mask entry keeps of a list: every one with no mask.
@(private)
settings_kept :: proc(list:[]project.Setting,keep:[]bool) -> []project.Setting {
    if keep==nil {return list}
    kept:=make([dynamic]project.Setting,context.temp_allocator)
    for setting,i in list {
        if keep[i] {append(&kept,setting)}
    }
    return kept[:]
}

// The sections a get of settings or preferences names, as a mask over list:
// nil for every section. False after failing the call.
@(private)
api_sections_kept :: proc(call:^api.Call,given:[][64]u8,list:[]project.Setting,what:string) -> (keep:[]bool,named:bool) {
    for &name in given {
        wanted:=base.text_get(name[:])
        if wanted=="" {continue}
        if keep==nil {keep=make([]bool,len(list),context.temp_allocator)}
        found:=false
        for setting,i in list {
            if setting.name==wanted {keep[i],found=true,true}
        }
        if !found {
            names:=make([dynamic]string,context.temp_allocator)
            for setting in list {append(&names,setting.name)}
            api.call_failf(call,api.INVALID_PARAMS,"%s is not a %s: they are %s",wanted,what,strings.join(names[:],", ",context.temp_allocator))
            return
        }
    }
    return keep,true
}

// The mask of a change: the sections of its text.
@(private)
settings_touched :: proc(list:[]project.Setting,sections:string,also:="") -> []bool {
    keep:=make([]bool,len(list),context.temp_allocator)
    for setting,i in list {keep[i]=also!="" && setting.name==also}
    for name in settings_section_names(sections) {
        for setting,i in list {
            if setting.name==name {keep[i]=true}
        }
    }
    return keep
}

// The answer of settings.get for the sections of a mask (nil: all), and of
// settings.set for those it changed.
@(private)
api_settings_write :: proc(s:^Session,call:^api.Call,keep:[]bool) {
    current:=settings_all(s)
    code:=project.settings_clone(current,context.temp_allocator)
    engine:=project.settings_clone(current,context.temp_allocator)
    if len(code)!=len(current) || len(engine)!=len(current) {
        api.call_fail(call,api.SERVER_ERROR,"There is no memory to read the settings")
        return
    }
    project.settings_default(code)
    if error,layer:=project.settings_load(engine,s.project_root,s.engine_root,{.Engine});error.code!=.None {
        api.call_fail(call,api.SERVER_ERROR,settings_error_text(s,error,layer))
        return
    }
    r:=api.call_result(call,Api_Settings)
    if keep==nil {
        machine:=make([dynamic]string,call.allocator)
        for info in s.info.storages {
            if info.setting==.Machine {append(&machine,info.name)}
        }
        r.machine=machine[:]
    }
    shown,under,top:=settings_kept(current,keep),settings_kept(engine,keep),settings_kept(code,keep)
    r.settings=serial.Json(strings.trim_space(project.settings_text(shown,{},{},call.allocator)))
    r.engine=serial.Json(strings.trim_space(project.settings_text(under,top,{},call.allocator)))
    r.project=serial.Json(strings.trim_space(project.settings_text(shown,under,{},call.allocator)))
}

// The names of the sections of an object of settings, as far as it reads.
@(private)
settings_section_names :: proc(text:string) -> []string {
    names:=make([dynamic]string,context.temp_allocator)
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    if !serial.text_accept(&r,'{') || serial.text_accept(&r,'}') {return names[:]}
    for {
        name,named:=serial.text_string(&r)
        if !named || !serial.text_expect(&r,':') {break}
        append(&names,strings.clone(name,context.temp_allocator))
        if !serial.text_skip(&r) || !serial.text_accept(&r,',') {break}
    }
    return names[:]
}

// Read into copies of the layer and checked against the fields of each type:
// a change that fails leaves every setting as it was.
@(private)
api_settings_set :: proc(s:^Session,call:^api.Call) {
    p:=api.call_params(call,Api_Settings_Set_Params)
    layer:=project.Settings_Layer.Engine if p.layer==.engine else .Project
    sections:=string(p.settings)
    preset:=api.call_given(call,"graphics_preset")?fmt.tprint(p.graphics_preset):""
    if sections=="" && preset=="" {
        api.call_fail(call,api.INVALID_PARAMS,`settings is missing: give {"settings": {"<Section>": {"<field>": value}}} or graphics_preset`)
        return
    }
    if layer==.Engine && s.engine_root=="" {
        api.call_fail(call,api.INVALID_PARAMS,"The root of the engine is not known: only the project layer can be written")
        return
    }
    current:=settings_all(s)
    next:=project.settings_clone(current,context.temp_allocator)
    if len(next)!=len(current) {
        api.call_fail(call,api.SERVER_ERROR,"There is no memory to read the settings")
        return
    }
    if layer==.Engine {
        for name in settings_section_names(sections) {
            machine:=false
            for info in s.info.storages {
                if info.name==name && info.setting==.Machine {machine=true;break}
            }
            if !machine {
                held:=settings_machine_names(s)
                api.call_failf(call,api.INVALID_PARAMS,`%s is not a setting of this machine: the engine layer holds only %s; set it with "layer": "project"`,name,held!=""?held:"the settings of the machine, and this project has none")
                return
            }
        }
        if error,failed:=project.settings_load(next,s.project_root,s.engine_root,{.Engine});error.code!=.None {
            api.call_fail(call,api.SERVER_ERROR,settings_error_text(s,error,failed))
            return
        }
    }
    for name in settings_section_names(sections) {
        known:=false
        for setting in next {
            if setting.name==name {known=true;break}
        }
        if known {continue}
        names:=make([dynamic]string,context.temp_allocator)
        for setting in next {append(&names,setting.name)}
        api.call_failf(call,api.INVALID_PARAMS,"%s is not a setting of the project: they are %s",name,strings.join(names[:],", ",context.temp_allocator))
        return
    }
    if preset!="" {
        if layer==.Engine && !strings.contains(settings_machine_names(s),"Graphics_Settings") {
            api.call_fail(call,api.INVALID_PARAMS,`Graphics_Settings is not a setting of this machine: set it with "layer": "project"`)
            return
        }
        if problem:=settings_graphics_preset(next,preset);problem!="" {
            api.call_fail(call,api.INVALID_PARAMS,problem)
            return
        }
    }
    if sections!="" {
        if error:=project.settings_parse(sections,next,strict=true);error.code!=.None {
            api.call_failf(call,api.INVALID_PARAMS,"settings: %s at line %d, column %d",error.detail,error.line,error.column)
            return
        }
    }
    for setting in next {
        if problem:=setting_problem(s,setting.info,setting.value);problem!="" {
            api.call_failf(call,api.INVALID_PARAMS,"%s: %s",setting.name,problem)
            return
        }
        schema:serial.Schema
        serial.schema_init(&schema,context.temp_allocator)
        type,_:=serial.schema_add_type_info(&schema,setting.info)
        check,valid:=api.value_check(&schema,type,([^]u8)(setting.value)[:setting.info.size],setting.name,context.temp_allocator)
        serial.schema_destroy(&schema)
        if !valid {
            api.call_fail(call,api.INVALID_PARAMS,check)
            return
        }
    }
    if layer==.Project {
        for setting,i in next {mem.copy(current[i].value,setting.value,setting.info.size)}
        next=current
    }
    if message:=settings_store(s,next,layer);message!="" {
        api.call_fail(call,api.SERVER_ERROR,message)
        return
    }
    if layer==.Engine {
        for setting in next {
            if value:=setting_engine_value(s,setting.name);value!=nil {mem.copy(value,setting.value,setting.info.size)}
        }
    }
    touched:=settings_touched(settings_all(s),sections,preset!=""?"Graphics_Settings":"")
    settings_runs_take(s,touched)
    api_settings_write(s,call,touched)
}

// The sections settings.set changed, in the games that play: each run holds
// its own copy of the settings of the World, and the edited World already has
// the new values. keep is settings_touched over settings_all.
@(private)
settings_runs_take :: proc(s:^Session,keep:[]bool) {
    list:=settings_all(s)
    for &r in s.runs {
        if r.world==nil {continue}
        for setting,i in list {
            if !keep[i] {continue}
            for info,index in s.info.storages {
                if info.name==setting.name && info.setting!=.None && info.place==.World {
                    mem.copy(core.world_storage_at(core.world_ref(r.world,s.info),index),rawptr(uintptr(s.edit_world)+info.offset),info.info.size)
                }
            }
        }
    }
}
