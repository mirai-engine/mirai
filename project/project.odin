package project

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:std/base"

// The standard layout of a project. A plugin has the same shape below its
// own folder: plugin.mirai, runtime/, editor/, shaders/ and assets/.
Folder :: enum u8 {
    Assets,    // cooked assets
    Source,    // art sources with their import options
    Game,      // the runtime module of the project
    Editor,    // its engine-time module
    Plugins,
    Shaders,
    Panels,    // interfaces of the editor made for the project (engine-time)
    Generated, // module roots, libraries and caches: never edited, never versioned
}
FOLDER_NAMES :: [Folder]string{
    .Assets="assets",.Source="source",.Game="game",.Editor="editor",
    .Plugins="plugins",.Shaders="shaders",.Panels="panels",.Generated=".mirai",
}
PART_NAMES :: [Plugin_Part]string{.Runtime="runtime",.Editor="editor",.Shaders="shaders",.Assets="assets",.Recipes="recipes"}

// Under the generated folder, beside the libraries of the project: the libraries of the engine's plugins it links.
PLUGIN_LIBRARIES :: "plugins/lib"
// Under the generated folder: what the machine that edits a project made from
// it and keeps so as not to make it again. Deleting them costs only time.
CACHE_FOLDER :: "cache"
REGISTRY_CACHE :: "registry"   // in it: what the registry of the assets saw
TEXTURE_CACHE :: "textures"    // in it: built textures, by image and settings
MESH_CACHE :: "meshes"         // in it: built meshes, by geometry and settings
ANIMATION_CACHE :: "animations" // in it: compressed .anim libraries, by asset and inputs
THUMBNAIL_FOLDER :: "thumbs"   // beside it: the previews of the editor
// Under the generated folder of a project or a plugin: what the imports of its
// sources build that nobody edits (meshes, textures, sounds, fonts), each at
// the path it has among the assets. Built again from the sources and their
// sidecars wherever it is missing (cook/import/sources.sync).
IMPORTED_FOLDER :: "imported"

Plugin :: struct {
    manifest:Plugin_Manifest,
    origin:Origin,
    folder:string, // absolute, with forward slashes
}

// A project as found on disk. Everything it points to is owned by it.
Project :: struct {
    allocator:runtime.Allocator,
    root:string,        // absolute, with forward slashes and no trailing one
    engine_root:string, // same; empty when there is no engine checkout
    manifest:Manifest,
    plugins:[]Plugin,   // every plugin found: the ones of the project, then the ones of the engine, each sorted by name
    active:[]int,       // into plugins: the ones the project names and their dependencies, dependencies first
}

// Reads project.mirai of the folder, finds the plugins under its plugins/
// and under <engine_root>/plugins/, and orders the active ones.
open :: proc(root:string,engine_root:="",allocator:=context.allocator) -> (p:Project,error:Error) {
    p.allocator=allocator
    p.root=path_absolute(root,allocator)
    if engine_root!="" {p.engine_root=path_absolute(engine_root,allocator)}
    defer if error.code!=.None {close(&p)}
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    manifest,read_error:=manifest_read(path(p.root,PROJECT_FILE,allocator=context.temp_allocator))
    p.manifest=manifest;error=read_error
    if error.code!=.None {return}
    names:=FOLDER_NAMES
    found:=make([dynamic]Plugin,allocator)
    defer if error.code!=.None {
        for plugin in found {delete(plugin.folder,allocator)}
        delete(found)
    }
    if error=plugins_discover(path(p.root,names[.Plugins],allocator=context.temp_allocator),.Project,&found,allocator);error.code!=.None {return}
    if p.engine_root!="" {
        if error=plugins_discover(path(p.engine_root,names[.Plugins],allocator=context.temp_allocator),.Engine,&found,allocator);error.code!=.None {return}
    }
    for &plugin,i in found {
        for &other in found[:i] {
            if other.manifest.name==plugin.manifest.name {
                error=error_about(.Plugin_Repeated,base.text_get(plugin.manifest.name[:]))
                return
            }
        }
    }
    wanted:=make([dynamic]string,context.temp_allocator)
    for &name in p.manifest.plugins {
        text:=base.text_get(name[:])
        if text=="" {continue}
        if index,known:=plugin_find(found[:],text);known && found[index].manifest.automatic {
            error=error_about(.Automatic_Named,text)
            return
        }
        append(&wanted,text)
    }
    if p.active,error=plugins_order(found[:],wanted[:],allocator);error.code!=.None {return}
    // An automatic plugin joins once all its dependencies are active, after
    // them; one that joins can complete the dependencies of another.
    for joined:=true;joined; {
        joined=false
        for &plugin,i in found {
            if !plugin.manifest.automatic || slice.contains(p.active,i) || !dependencies_active(found[:],p.active,&plugin.manifest) {continue}
            append(&wanted,base.text_get(plugin.manifest.name[:]))
            delete(p.active,allocator)
            if p.active,error=plugins_order(found[:],wanted[:],allocator);error.code!=.None {return}
            joined=true
        }
    }
    for index in p.active {
        plugin:=&found[index]
        if error=plugin_engine_check(&plugin.manifest);error.code!=.None {
            error.plugin,error.origin=plugin.manifest.name,plugin.origin
            return
        }
    }
    shrink(&found)
    p.plugins=found[:]
    return
}

close :: proc(p:^Project) {
    for plugin in p.plugins {delete(plugin.folder,p.allocator)}
    delete(p.plugins,p.allocator)
    delete(p.active,p.allocator)
    delete(p.root,p.allocator)
    delete(p.engine_root,p.allocator)
    p^={}
}

plugin_find :: proc(plugins:[]Plugin,name:string) -> (index:int,found:bool) {
    for &plugin,i in plugins {
        if base.text_get(plugin.manifest.name[:])==name {return i,true}
    }
    return -1,false
}

// The plugin an import path names: plugins:<name>/...,
// project:plugins/<name>/... or, for a companion,
// project:plugins/<plugin>/plugins/<name>/...; empty for another collection.
import_plugin :: proc(path:string) -> string {
    rest:string
    switch {
    case strings.has_prefix(path,"plugins:"):         rest=path[len("plugins:"):]
    case strings.has_prefix(path,"project:plugins/"):
        rest=path[len("project:plugins/"):]
        if slash:=strings.index_byte(rest,'/');slash>=0 && strings.has_prefix(rest[slash+1:],PLUGIN_COMPANIONS+"/") {rest=rest[slash+len(PLUGIN_COMPANIONS)+2:]}
    case: return ""
    }
    if slash:=strings.index_byte(rest,'/');slash>=0 {rest=rest[:slash]}
    return rest
}

// Whether the code of plugins[from] may import the plugin named name: itself,
// a dependency or one of theirs; its tests also a test dependency and theirs.
plugin_reaches :: proc(plugins:[]Plugin,from:int,name:string,tests:bool) -> bool {
    seen:=make([]bool,len(plugins),context.temp_allocator)
    reach :: proc(plugins:[]Plugin,seen:[]bool,at:int,name:string) -> bool {
        if at<0 || seen[at] {return false}
        seen[at]=true
        m:=&plugins[at].manifest
        if base.text_get(m.name[:])==name {return true}
        for &entry in m.dependencies {
            dependency:=base.text_get(entry[:])
            if dependency=="" {continue}
            index,_:=plugin_find(plugins,dependency)
            if reach(plugins,seen,index,name) {return true}
        }
        return false
    }
    if reach(plugins,seen,from,name) {return true}
    if !tests {return false}
    for &entry in plugins[from].manifest.test_dependencies {
        dependency:=base.text_get(entry[:])
        if dependency=="" {continue}
        index,_:=plugin_find(plugins,dependency)
        if reach(plugins,seen,index,name) {return true}
    }
    return false
}

@(private="file")
dependencies_active :: proc(plugins:[]Plugin,active:[]int,m:^Plugin_Manifest) -> bool {
    for &entry in m.dependencies {
        name:=base.text_get(entry[:])
        if name=="" {continue}
        index,found:=plugin_find(plugins,name)
        if !found || !slice.contains(active,index) {return false}
    }
    return true
}

// Appends the plugins of a plugins/ folder, sorted by name: every folder in
// it that has a plugin.mirai and, after a plugin of the project, its
// companions. A folder that does not exist has none. A manifest has to carry
// the name of its folder and declare exactly the parts whose folders exist.
plugins_discover :: proc(folder:string,origin:Origin,out:^[dynamic]Plugin,allocator:=context.allocator) -> Error {
    return plugins_discover_in(folder,origin,origin==.Project,out,allocator)
}

@(private)
plugins_discover_in :: proc(folder:string,origin:Origin,companions:bool,out:^[dynamic]Plugin,allocator:=context.allocator) -> Error {
    if !os.is_dir(folder) {return {}}
    entries,read_error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if read_error!=nil {return {}}
    slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
    part_names:=PART_NAMES
    for entry in entries {
        if entry.type!=.Directory {continue}
        manifest_path:=path(folder,entry.name,PLUGIN_FILE,allocator=context.temp_allocator)
        if !os.is_file(manifest_path) {continue}
        manifest,error:=plugin_read(manifest_path)
        if error.code==.None && base.text_get(manifest.name[:])!=entry.name {
            error=error_about(.Folder_Mismatch,base.text_get(manifest.name[:]))
        }
        for part in Plugin_Part {
            if error.code!=.None {break}
            exists:=os.is_dir(path(folder,entry.name,part_names[part],allocator=context.temp_allocator))
            if exists!=(part in manifest.parts) {error=error_about(exists?.Part_Undeclared:.Part_Missing,part_names[part])}
        }
        if error.code!=.None {
            base.text_set(error.plugin[:],entry.name)
            error.origin=origin
            return error
        }
        append(out,Plugin{manifest,origin,path(folder,entry.name,allocator=allocator)})
        if companions {
            if error:=plugins_discover_in(path(folder,entry.name,PLUGIN_COMPANIONS,allocator=context.temp_allocator),origin,false,out,allocator);error.code!=.None {return error}
        }
    }
    return {}
}

// The plugins to build and load for the names wanted: those and everything
// they depend on, each after its dependencies and otherwise in the order
// they are wanted.
plugins_order :: proc(plugins:[]Plugin,wanted:[]string,allocator:=context.allocator) -> (order:[]int,error:Error) {
    Visit :: enum u8 {None,Open,Done}
    Walk :: struct {plugins:[]Plugin,state:[]Visit,order:[dynamic]int}
    visit :: proc(walk:^Walk,index:int) -> Error {
        if walk.state[index]==.Done {return {}}
        walk.state[index]=.Open
        plugin:=&walk.plugins[index]
        for &entry in plugin.manifest.dependencies {
            name:=base.text_get(entry[:])
            if name=="" {continue}
            dependency,found:=plugin_find(walk.plugins,name)
            error:Error
            switch {
            case !found:                            error=error_about(.Dependency_Missing,name)
            case walk.state[dependency]==.Open:     error=error_about(.Dependency_Cycle,name)
            case:
                if error=visit(walk,dependency);error.code!=.None {return error}
                continue
            }
            error.plugin,error.origin=plugin.manifest.name,plugin.origin
            return error
        }
        walk.state[index]=.Done
        append(&walk.order,index)
        return {}
    }
    listed,allocation:=make([dynamic]int,0,len(plugins),allocator)
    if allocation!=nil {return nil,{code=.Out_Of_Memory}}
    walk:=Walk{plugins,make([]Visit,len(plugins),context.temp_allocator),listed}
    for name in wanted {
        index,found:=plugin_find(plugins,name)
        if !found {error=error_about(.Plugin_Missing,name)}
        else {error=visit(&walk,index)}
        if error.code!=.None {
            delete(walk.order)
            return nil,error
        }
    }
    return walk.order[:],{}
}

// The parts joined with forward slashes, the only separator the manifests,
// the generated sources and the compiler share on every system.
path :: proc(parts:..string,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    for part in parts {
        if part=="" {continue}
        if strings.builder_len(b)>0 && !strings.has_suffix(strings.to_string(b),"/") {strings.write_byte(&b,'/')}
        strings.write_string(&b,part)
    }
    return strings.to_string(b)
}

EXECUTABLE_SUFFIX :: ".exe" when ODIN_OS==.Windows else ""
when ODIN_OS==.Windows {
    LIBRARY_PREFIX :: ""
    LIBRARY_SUFFIX :: ".dll"
} else when ODIN_OS==.Darwin {
    LIBRARY_PREFIX :: "lib"
    LIBRARY_SUFFIX :: ".dylib"
} else {
    LIBRARY_PREFIX :: "lib"
    LIBRARY_SUFFIX :: ".so"
}

// The file of a dynamic library on this system: mirai-engine.dll,
// libmirai-engine.so. "" without memory for it.
library_file :: proc(name:string,allocator:=context.allocator) -> string {
    file,error:=strings.concatenate({LIBRARY_PREFIX,name,LIBRARY_SUFFIX},allocator)
    if error!=nil {return ""}
    return file
}

// A library of the project, in .mirai: editor, which the editor loads, or
// play, which the player loads.
project_library :: proc(root,name:string,allocator:=context.allocator) -> string {
    return path(folder_path(root,.Generated,context.temp_allocator),library_file(name,context.temp_allocator),allocator=allocator)
}

// A file or folder of the caches of a project, under its generated folder.
cache_path :: proc(root:string,parts:..string,allocator:=context.allocator) -> string {
    b:=strings.builder_make(allocator)
    strings.write_string(&b,path(folder_path(root,.Generated,context.temp_allocator),CACHE_FOLDER,allocator=context.temp_allocator))
    for part in parts {
        if part=="" {continue}
        strings.write_byte(&b,'/')
        strings.write_string(&b,part)
    }
    return strings.to_string(b)
}

// The imported folder of the project or the plugin at root.
imported_path :: proc(root:string,allocator:=context.allocator) -> string {
    return path(folder_path(root,.Generated,context.temp_allocator),IMPORTED_FOLDER,allocator=allocator)
}

folder_path :: proc(root:string,folder:Folder,allocator:=context.allocator) -> string {
    names:=FOLDER_NAMES
    return path(root,names[folder],allocator=allocator)
}

// The start scene the manifest of the project at root names, relative to
// its assets folder. Empty when it names none or cannot be read.
start_scene :: proc(root:string,allocator:=context.allocator) -> string {
    m,error:=manifest_read(path(root,PROJECT_FILE,allocator=context.temp_allocator))
    if error.code!=.None {return ""}
    scene,scene_error:=strings.clone(base.text_get(m.start_scene[:]),allocator)
    if scene_error!=nil {return ""}
    return scene
}

// Whether two paths written from the same folder name the same file: without
// case on Windows and macOS, whose file systems fold it, with either slash on
// Windows, and with or without a slash at the end.
path_same :: proc(a,b:string) -> bool {
    SEPARATORS :: "/\\" when ODIN_OS==.Windows else "/"
    a,b:=strings.trim_right(a,SEPARATORS),strings.trim_right(b,SEPARATORS)
    for {
        i,j:=strings.index_any(a,SEPARATORS),strings.index_any(b,SEPARATORS)
        if (i<0)!=(j<0) {return false}
        x,y:=a[:i] if i>=0 else a,b[:j] if j>=0 else b
        when ODIN_OS==.Windows || ODIN_OS==.Darwin {
            if !strings.equal_fold(x,y) {return false}
        } else {
            if x!=y {return false}
        }
        if i<0 {return true}
        a,b=a[i+1:],b[j+1:]
    }
}

// Absolute, with forward slashes and no trailing one. "" without memory for it.
path_absolute :: proc(location:string,allocator:=context.allocator) -> string {
    absolute,error:=os.get_absolute_path(location,context.temp_allocator)
    if error!=nil {
        // What does not exist yet has no real path on Linux and macOS: it is resolved by name.
        absolute=location
        if working,working_error:=os.get_working_directory(context.temp_allocator);working_error==nil && !os.is_absolute_path(location) {
            absolute=strings.concatenate({working,"/",location},context.temp_allocator)
        }
        absolute,_=os.clean_path(absolute,context.temp_allocator)
    }
    result,_:=strings.replace_all(absolute,"\\","/",context.temp_allocator)
    for len(result)>1 && result[len(result)-1]=='/' {result=result[:len(result)-1]}
    copy,copy_error:=strings.clone(result,allocator)
    if copy_error!=nil {return ""}
    return copy
}

// The folders of the recipes Create and the preset of a document place: that
// of the engine, then the one of each active plugin that declares the part,
// in the order of p.active. A recipe is a scene of one entity, which is
// copied where it is placed; the name of its file is its name.
recipe_folders :: proc(p:^Project,allocator:=context.allocator) -> []string {
    folders:=make([dynamic]string,allocator)
    parts:=PART_NAMES
    if p.engine_root!="" {append(&folders,path(p.engine_root,parts[.Recipes],allocator=allocator))}
    for index in p.active {
        plugin:=&p.plugins[index]
        if .Recipes in plugin.manifest.parts {append(&folders,path(plugin.folder,parts[.Recipes],allocator=allocator))}
    }
    return folders[:]
}

// A folder of assets of a project, and the path its files have among the
// assets: "" for the ones of the project, plugins/<name> for those of a plugin.
// imported: the imported folder that goes with it, whose files are assets at
// the same paths. root: the project or the plugin the folder is of.
Asset_Folder :: struct {path,prefix,imported,root:string}

// The assets folder of the project, when it has one, and the one of each
// active plugin that declares the part, in the order of p.active.
asset_folders :: proc(p:^Project,allocator:=context.allocator) -> []Asset_Folder {
    folders:=make([dynamic]Asset_Folder,allocator)
    names:=FOLDER_NAMES
    parts:=PART_NAMES
    if own:=folder_path(p.root,.Assets,allocator);os.is_dir(own) {append(&folders,Asset_Folder{own,"",imported_path(p.root,allocator),p.root})}
    for index in p.active {
        plugin:=&p.plugins[index]
        if .Assets not_in plugin.manifest.parts {continue}
        append(&folders,Asset_Folder{
            path(plugin.folder,parts[.Assets],allocator=allocator),
            path(names[.Plugins],base.text_get(plugin.manifest.name[:]),allocator=allocator),
            imported_path(plugin.folder,allocator),
            plugin.folder,
        })
    }
    return folders[:]
}
