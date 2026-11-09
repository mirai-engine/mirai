package project

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "mirai:std/base"
import "mirai:std/serial"

// What turns a folder into a Mirai project, and a folder into a plugin: a
// manifest of plain data, written as JSON by its schema. A field the file
// does not have keeps its default, and a field the manifest does not have is
// an error. A list of names is a list of strings; its empty entries are not
// written.

PROJECT_FILE :: "project.mirai"
PLUGIN_FILE :: "plugin.mirai"
// The folder of a plugin of the project with its companions: more plugins,
// one per folder, that come and go with it, like its bridges to others. A
// repository of git brings them with its plugin; a companion has none.
PLUGIN_COMPANIONS :: "plugins"
INPUT_FILE :: "input.mirai" // the bindings of the input actions of a project, next to PROJECT_FILE

// Changes with every release whose shared structures or procedures are not
// compatible with the previous one.
ENGINE_VERSION :: "0.1.0"

MAX_PLUGINS :: 32      // plugins a project names; their dependencies come besides
MAX_DEPENDENCIES :: 16
MAX_DEFINES :: 16
MAX_SOURCES :: 16

Name :: [64]u8
Path :: [256]u8
Define :: [96]u8
Url :: [256]u8
Commit :: [64]u8 // the full hash of a git commit: 40 hexadecimal digits, or 64 in a repository of SHA-256

Optimization :: enum u8 {Minimal,None,Size,Speed,Aggressive}

Build_Options :: struct {
    executable:Name `mirai:"text"`,             // file of the shipped game, without extension. Empty: from the name of the project
    optimization:Optimization,                  // of the module libraries; the shipped game is always built for speed
    debug:bool,                                 // debug information in the libraries editor and play: a crash names their procedures and lines
    defines:[MAX_DEFINES]Define `mirai:"text,trim"`, // NAME or NAME=value, given to every build of the project
}

// How the game opens: maximized, on the whole display, or as a window of
// width × height.
Window_Mode :: enum u8 {Maximized,Fullscreen,Windowed}

Window :: struct {
    title:[128]u8 `mirai:"text"`, // empty: the name of the project
    mode:Window_Mode,
    width,height:i32,             // pixels; the size of the window when it is not in full screen or maximized
}

// What the game holds on the machine it is made for; profile.audit says which
// a measurement goes over. 0: no budget.
Performance :: struct {
    frame:f32 `mirai:"min=0,unit=ms"`,  // the 95th percentile of the frame time
    memory:f32 `mirai:"min=0,unit=MB"`, // the private memory of the process at its highest
    load:f32 `mirai:"min=0,unit=ms"`,   // from loading a scene or starting Play until a frame drew with all of it resident
}

// A plugin of the project that comes from a git repository: plugins/<name>
// is a checkout of url at commit, which the repository of the project
// ignores and cook/install makes again where it is missing.
Source :: struct {
    name:Name `mirai:"text"`,
    url:Url `mirai:"text"`,
    commit:Commit `mirai:"text"`,
    catalog:bool, // installed from the catalog: it updates only to the commit the catalog lists
}

Manifest :: struct {
    name:Name `mirai:"text,section=Game"`,
    version:Version `mirai:"text"`,           // of the game, major.minor.patch
    identifier:Identifier `mirai:"text"`,     // what the system knows the game by: a reverse domain name, as com.studio.game. Empty: none
    icon:Path `mirai:"text"`,                 // a PNG of the window of the game, relative to the project, with forward slashes. Empty: none
    thumbnail:Path `mirai:"text"`,            // a PNG the list of projects shows it with, relative to the project, with forward slashes. Empty: the view of its start scene
    start_scene:Path `mirai:"text,kind=.scene"`, // relative to the assets folder of the project, with forward slashes. Empty: none
    plugins:[MAX_PLUGINS]Name `mirai:"text,hidden"`, // active plugins, of the project or of the engine
    sources:[MAX_SOURCES]Source `mirai:"trim,hidden"`, // plugins of its plugins/ that come from git
    window:Window `mirai:"section=Window"`,
    build:Build_Options `mirai:"section=Build"`,
    performance:Performance `mirai:"section=Performance"`,
}

Identifier :: [128]u8

PLUGIN_ICON_MAX :: 128 // pixels a side of the icon of a plugin may take: it is a small mark in a list

// The pixels of a PNG, from its header; ok is false for a file that is not one.
png_size :: proc(path:string) -> (width,height:int,ok:bool) {
    file,error:=os.open(path)
    if error!=nil {return}
    defer os.close(file)
    header:[24]u8
    if read,_:=os.read(file,header[:]);read<len(header) {return}
    if string(header[1:4])!="PNG" || string(header[12:16])!="IHDR" {return}
    width=int(header[16])<<24|int(header[17])<<16|int(header[18])<<8|int(header[19])
    height=int(header[20])<<24|int(header[21])<<16|int(header[22])<<8|int(header[23])
    return width,height,true
}

Plugin_Part :: enum u8 {Runtime,Editor,Shaders,Assets}
Plugin_Parts :: bit_set[Plugin_Part;u8]

Version :: [32]u8

// The versions of the engine a plugin works with, both ends included. Each
// is major, major.minor or major.minor.patch: what min leaves out is zero and
// what max leaves out is any number, so {"0.1","0.1"} is every 0.1.x. An
// empty end has no limit.
Engine_Range :: struct {
    min:Version `mirai:"text"`,
    max:Version `mirai:"text"`,
}

Plugin_Manifest :: struct {
    name:Name `mirai:"text"`,                       // the name of its folder
    version:Version `mirai:"text"`,                 // major.minor.patch
    engine:Engine_Range,
    dependencies:[MAX_DEPENDENCIES]Name `mirai:"text"`, // plugins that are activated with it and register before it
    test_dependencies:[MAX_DEPENDENCIES]Name `mirai:"text"`, // plugins its tests also import: what they test it against, never activated with it
    parts:Plugin_Parts,                             // the folders it has
    development:bool,                               // a tool for making the game: in the editor and the player, never in a published game
    automatic:bool,                                 // active exactly when all its dependencies are: what joins them; no project names it
    icon:Path `mirai:"text"`,                       // a PNG the lists of plugins of the editor show it with, relative to its folder, with forward slashes, PLUGIN_ICON_MAX wide and tall at most. Empty: the generic one
}

Origin :: enum u8 {Project,Engine}

Error_Code :: enum u8 {
    None,
    Not_Found,          // the manifest file does not exist
    Read_Failed,
    Write_Failed,
    Text,               // not the JSON of the manifest: Error.text at line and column
    Name_Missing,
    Name_Invalid,       // subject is not lowercase letters, digits and '_' after a letter
    Name_Repeated,      // subject is twice in a list
    Version_Invalid,    // subject is not major.minor.patch
    Identifier_Invalid, // subject is not parts of letters, digits, '-' and '_' separated by dots
    Icon_Invalid,       // subject is not a PNG relative to the project, or to the folder of `plugin`
    Thumbnail_Invalid,  // the same, of the thumbnail
    Engine_Invalid,     // subject, an end of the engine range, is not a version, or min is above max
    Engine_Old,         // the active plugin `plugin` needs an engine from subject on
    Engine_New,         // the active plugin `plugin` works with engines up to subject
    Scene_Invalid,      // start_scene is absolute, leaves the project or has a backslash
    Executable_Invalid, // subject has something besides letters, digits, '_' and '-'
    Define_Invalid,     // subject is not NAME or NAME=value
    Window_Invalid,     // a side outside 1..MAX_WINDOW_SIDE
    Budget_Invalid,     // a budget of performance below 0 or above MAX_BUDGET
    Depends_On_Itself,
    Folder_Mismatch,    // the manifest in folder `plugin` names itself subject
    Part_Missing,       // the manifest declares the part subject and its folder does not exist
    Part_Undeclared,    // the folder of the part subject exists and the manifest does not declare it
    Plugin_Repeated,    // two folders provide the plugin subject
    Plugin_Missing,     // the project activates subject and no folder provides it
    Dependency_Missing, // `plugin` depends on subject and no folder provides it
    Dependency_Cycle,   // `plugin` depends on subject, which depends on `plugin`
    Automatic_Named,    // the project names subject, an automatic plugin: it is active when its dependencies are
    Automatic_Alone,    // subject is automatic and depends on nothing
    Source_Invalid,     // the source subject has no url, or its commit is not the full hash of one
    Schema_Failed,      // std/serial cannot describe the type subject: a defect of the engine, not of the file
}

Error :: struct {
    code:Error_Code,
    text:serial.Text_Error_Code, // code==.Text
    line,column:int,             // code==.Text: position in the file, from one
    detail:string,               // code==.Text: where in the value and what (serial.text_error_message), in the temp allocator
    plugin:Name,                 // folder of the plugin the error is in. Empty: the project
    origin:Origin,               // of that plugin
    subject:Name,
}

MAX_WINDOW_SIDE :: 16384
MAX_BUDGET :: 1e7 // of a budget of performance, in its own unit

manifest_default :: proc(name:string) -> (m:Manifest) {
    base.text_set(m.name[:],name)
    base.text_set(m.version[:],"0.1.0")
    m.window.width,m.window.height=1280,720
    m.performance.frame=1000.0/60
    return
}

manifest_parse :: proc(text:string) -> (m:Manifest,error:Error) {
    m=manifest_default("")
    if error=value_parse(text,&m,Manifest);error.code!=.None {return}
    return m,manifest_validate(&m)
}

// Sets over m the fields a JSON object has, as a file would: what it does not
// name stays. Unchanged when the result does not validate.
manifest_merge :: proc(m:^Manifest,text:string) -> Error {
    next:=m^
    if error:=value_parse(text,&next,Manifest);error.code!=.None {return error}
    if error:=manifest_validate(&next);error.code!=.None {return error}
    m^=next
    return {}
}

manifest_read :: proc(path:string) -> (m:Manifest,error:Error) {
    data,file_error:=serial.file_read(path,context.temp_allocator)
    if file_error!=.None {return {},{code=file_error==.Not_Found?.Not_Found:.Read_Failed}}
    return manifest_parse(string(data))
}

manifest_text :: proc(m:^Manifest,allocator:=context.allocator) -> string {return value_text(m,Manifest,allocator)}

manifest_write :: proc(path:string,m:^Manifest) -> Error {
    if error:=manifest_validate(m);error.code!=.None {return error}
    text:=manifest_text(m,context.temp_allocator)
    if text=="" {return schema_failed(Manifest)}
    return {code=serial.file_write_atomic(path,transmute([]u8)text)==.None?.None:.Write_Failed}
}

manifest_validate :: proc(m:^Manifest) -> Error {
    if base.text_len(m.name[:])==0 {return {code=.Name_Missing}}
    if version:=base.text_get(m.version[:]);!version_valid(version) {return error_about(.Version_Invalid,version)}
    if identifier:=base.text_get(m.identifier[:]);identifier!="" && !identifier_valid(identifier) {return error_about(.Identifier_Invalid,identifier)}
    if icon:=base.text_get(m.icon[:]);icon!="" && !png_path_valid(icon) {return error_about(.Icon_Invalid,icon)}
    if thumbnail:=base.text_get(m.thumbnail[:]);thumbnail!="" && !png_path_valid(thumbnail) {return error_about(.Thumbnail_Invalid,thumbnail)}
    if error:=names_validate(m.plugins[:],"");error.code!=.None {return error}
    scene:=base.text_get(m.start_scene[:])
    if !relative_path_valid(scene) {return {code=.Scene_Invalid}}
    if executable:=base.text_get(m.build.executable[:]);executable!="" && !file_name_valid(executable) {
        return error_about(.Executable_Invalid,executable)
    }
    for &define in m.build.defines {
        if text:=base.text_get(define[:]);text!="" && !define_valid(text) {return error_about(.Define_Invalid,text)}
    }
    for side in ([2]i32{m.window.width,m.window.height}) {
        if side<1 || side>MAX_WINDOW_SIDE {return {code=.Window_Invalid}}
    }
    for budget in ([3]f32{m.performance.frame,m.performance.memory,m.performance.load}) {
        if !(budget>=0 && budget<=MAX_BUDGET) {return {code=.Budget_Invalid}}
    }
    for &source,i in m.sources {
        name:=base.text_get(source.name[:])
        if name=="" {
            if base.text_len(source.url[:])>0 || base.text_len(source.commit[:])>0 {return {code=.Name_Missing}}
            continue
        }
        if !name_valid(name) {return error_about(.Name_Invalid,name)}
        for &other in m.sources[:i] {
            if other.name==source.name {return error_about(.Name_Repeated,name)}
        }
        if base.text_len(source.url[:])==0 || !commit_valid(base.text_get(source.commit[:])) {return error_about(.Source_Invalid,name)}
    }
    return {}
}

// The source of the plugin named name, or nil when it does not come from git.
source_find :: proc(m:^Manifest,name:string) -> ^Source {
    if name=="" {return nil}
    for &source in m.sources {
        if base.text_get(source.name[:])==name {return &source}
    }
    return nil
}

// The full hash of a commit, in lowercase.
commit_valid :: proc(text:string) -> bool {
    if len(text)!=40 && len(text)!=64 {return false}
    for c in transmute([]u8)text {
        if (c<'0' || c>'9') && (c<'a' || c>'f') {return false}
    }
    return true
}

plugin_parse :: proc(text:string) -> (m:Plugin_Manifest,error:Error) {
    if error=value_parse(text,&m,Plugin_Manifest);error.code!=.None {return}
    return m,plugin_validate(&m)
}

plugin_read :: proc(path:string) -> (m:Plugin_Manifest,error:Error) {
    data,file_error:=serial.file_read(path,context.temp_allocator)
    if file_error!=.None {return {},{code=file_error==.Not_Found?.Not_Found:.Read_Failed}}
    return plugin_parse(string(data))
}

plugin_text :: proc(m:^Plugin_Manifest,allocator:=context.allocator) -> string {return value_text(m,Plugin_Manifest,allocator)}

plugin_write :: proc(path:string,m:^Plugin_Manifest) -> Error {
    if error:=plugin_validate(m);error.code!=.None {return error}
    text:=plugin_text(m,context.temp_allocator)
    if text=="" {return schema_failed(Plugin_Manifest)}
    return {code=serial.file_write_atomic(path,transmute([]u8)text)==.None?.None:.Write_Failed}
}

plugin_validate :: proc(m:^Plugin_Manifest) -> Error {
    name:=base.text_get(m.name[:])
    if name=="" {return {code=.Name_Missing}}
    if !name_valid(name) {return error_about(.Name_Invalid,name)}
    if version:=base.text_get(m.version[:]);!version_valid(version) {return error_about(.Version_Invalid,version)}
    low,high:=base.text_get(m.engine.min[:]),base.text_get(m.engine.max[:])
    low_version,low_parts,low_ok:=version_parse(low)
    high_version,high_parts,high_ok:=version_parse(high)
    if low!="" && !low_ok {return error_about(.Engine_Invalid,low)}
    if high!="" && !high_ok {return error_about(.Engine_Invalid,high)}
    if low_parts>0 && high_parts>0 && version_compare(low_version,high_version,high_parts)>0 {return error_about(.Engine_Invalid,low)}
    if error:=names_validate(m.dependencies[:],name);error.code!=.None {return error}
    if error:=names_validate(m.test_dependencies[:],name);error.code!=.None {return error}
    if icon:=base.text_get(m.icon[:]);icon!="" && !png_path_valid(icon) {return error_about(.Icon_Invalid,icon)}
    if m.automatic {
        alone:=true
        for &dependency in m.dependencies {
            if base.text_len(dependency[:])>0 {alone=false}
        }
        if alone {return error_about(.Automatic_Alone,name)}
    }
    return {}
}

// Whether a plugin works with a version of the engine: .Engine_Old or
// .Engine_New with the end of its range that leaves the engine out.
plugin_engine_check :: proc(m:^Plugin_Manifest,engine:=ENGINE_VERSION) -> Error {
    current,_,_:=version_parse(engine)
    if low:=base.text_get(m.engine.min[:]);low!="" {
        if version,_,ok:=version_parse(low);ok && version_compare(current,version,3)<0 {return error_about(.Engine_Old,low)}
    }
    if high:=base.text_get(m.engine.max[:]);high!="" {
        if version,parts,ok:=version_parse(high);ok && version_compare(current,version,parts)>0 {return error_about(.Engine_New,high)}
    }
    return {}
}

// One to three numbers separated by dots; parts is how many there are.
version_parse :: proc(text:string) -> (version:[3]int,parts:int,ok:bool) {
    digits:=0
    for c in transmute([]u8)text {
        switch {
        case c>='0' && c<='9':
            if parts==0 {parts=1}
            if digits>=6 {return {},0,false}
            version[parts-1]=version[parts-1]*10+int(c-'0')
            digits+=1
        case c=='.' && digits>0 && parts<3:
            parts+=1
            digits=0
        case: return {},0,false
        }
    }
    return version,parts,digits>0
}

// The order of two versions over their first parts numbers.
version_compare :: proc(a,b:[3]int,parts:int) -> int {
    for at in 0..<parts {
        if a[at]!=b[at] {return a[at]<b[at]?-1:1}
    }
    return 0
}

// A name of a plugin: it is a folder, and part of an identifier of the generated code.
name_valid :: proc(text:string) -> bool {
    if text=="" || text[0]<'a' || text[0]>'z' {return false}
    for c in transmute([]u8)text {
        if (c<'a' || c>'z') && (c<'0' || c>'9') && c!='_' {return false}
    }
    return true
}

// The file of the shipped game without its extension: what the manifest
// says, or the name of the project with everything that is not a letter, a
// digit, '_' or '-' turned into '_'.
executable_name :: proc(m:^Manifest,buffer:[]u8) -> string {
    if configured:=base.text_get(m.build.executable[:]);configured!="" {
        return string(buffer[:copy(buffer,configured)])
    }
    count:=copy(buffer,base.text_get(m.name[:]))
    for &c in buffer[:count] {
        if !file_name_byte(c) {c='_'}
    }
    return string(buffer[:count])
}

// What is wrong with the manifests of a project, for whoever has to fix
// them; folder is the project as it is named to them.
error_text :: proc(folder:string,error:Error,allocator:=context.allocator) -> string {
    context.allocator=allocator
    error:=error
    subject:=base.text_get(error.subject[:])
    plugin:=base.text_get(error.plugin[:])
    file:=path(folder,PROJECT_FILE)
    if plugin!="" {
        file=fmt.aprintf("%s/%s (%s)",plugin,PLUGIN_FILE,error.origin==.Engine?"engine plugin":"project plugin")
    }
    switch error.code {
    case .None:               return ""
    case .Not_Found:          return fmt.aprintf("%s does not exist: the folder is not a Mirai project",file)
    case .Read_Failed:        return fmt.aprintf("could not read %s",file)
    case .Write_Failed:       return fmt.aprintf("could not write %s",file)
    case .Text:               return fmt.aprintf("%s(%d:%d) %s",file,error.line,error.column,error.detail)
    case .Name_Missing:       return fmt.aprintf("%s: the name is missing",file)
    case .Name_Invalid:       return fmt.aprintf("%s: '%s' is not a plugin name (lowercase letters, digits and '_' after a letter)",file,subject)
    case .Name_Repeated:      return fmt.aprintf("%s: '%s' is repeated",file,subject)
    case .Identifier_Invalid: return fmt.aprintf("%s: the identifier '%s' is not a reverse domain name like com.studio.game: parts of letters, digits, '-' and '_' separated by dots",file,subject)
    case .Icon_Invalid:       return fmt.aprintf("%s: the icon '%s' must be a .png file relative to the %s, with '/'",file,subject,plugin!=""?"folder of the plugin":"project")
    case .Thumbnail_Invalid:  return fmt.aprintf("%s: the thumbnail '%s' must be a .png file relative to the project, with '/'",file,subject)
    case .Version_Invalid:    return fmt.aprintf("%s: the version '%s' is not major.minor.patch",file,subject)
    case .Engine_Invalid:     return fmt.aprintf("%s: '%s' is not a valid bound of engine (major, major.minor or major.minor.patch, with min up to max)",file,subject)
    case .Engine_Old:         return fmt.aprintf("%s: needs engine %s or later and this one is %s",file,subject,ENGINE_VERSION)
    case .Engine_New:         return fmt.aprintf("%s: works up to engine %s and this one is %s",file,subject,ENGINE_VERSION)
    case .Scene_Invalid:      return fmt.aprintf("%s: start_scene must be a path relative to assets/ with '/'",file)
    case .Executable_Invalid: return fmt.aprintf("%s: the executable '%s' may only have letters, digits, '_' and '-'",file,subject)
    case .Define_Invalid:     return fmt.aprintf("%s: '%s' is neither NAME nor NAME=value",file,subject)
    case .Window_Invalid:     return fmt.aprintf("%s: the width and height of the window go from 1 to %d",file,MAX_WINDOW_SIDE)
    case .Budget_Invalid:     return fmt.aprintf("%s: each budget of performance goes from 0, none, to %.0f",file,MAX_BUDGET)
    case .Depends_On_Itself:  return fmt.aprintf("%s: '%s' depends on itself",file,subject)
    case .Folder_Mismatch:    return fmt.aprintf("%s: it is named '%s' and its folder '%s'",file,subject,plugin)
    case .Part_Missing:       return fmt.aprintf("%s: declares %s/ and the folder does not exist",file,subject)
    case .Part_Undeclared:    return fmt.aprintf("%s: the folder %s/ exists and is not in parts",file,subject)
    case .Plugin_Repeated:    return fmt.aprintf("two folders provide the plugin '%s', in the project or in the engine; rename one",subject)
    case .Plugin_Missing:     return fmt.aprintf("%s: enables the plugin '%s', which exists neither in the project nor in the engine",file,subject)
    case .Dependency_Missing: return fmt.aprintf("%s: depends on '%s', which exists neither in the project nor in the engine",file,subject)
    case .Dependency_Cycle:   return fmt.aprintf("%s: depends on '%s', which depends on it",file,subject)
    case .Automatic_Named:    return fmt.aprintf("%s: enables the plugin '%s', which is automatic: it is enabled by itself when its dependencies are; remove it from plugins",file,subject)
    case .Automatic_Alone:    return fmt.aprintf("%s: '%s' is automatic and depends on nothing; name in dependencies the plugins it joins or remove automatic",file,subject)
    case .Source_Invalid:     return fmt.aprintf("%s: the source '%s' has no url or its commit is not a full hash",file,subject)
    case .Schema_Failed:      return fmt.aprintf("%s: std/serial does not describe the type %s; it is a defect of the engine, not of the file",file,subject)
    }
    return ""
}

// The title of the window: what the manifest says, or the name of the project.
window_title :: proc(m:^Manifest) -> string {
    if title:=base.text_get(m.window.title[:]);title!="" {return title}
    return base.text_get(m.name[:])
}

@(private)
schema_failed :: proc(T:typeid) -> Error {
    name:[64]u8
    return error_about(.Schema_Failed,fmt.bprint(name[:],T))
}

@(private)
error_about :: proc(code:Error_Code,subject:string) -> (error:Error) {
    error.code=code
    base.text_set(error.subject[:],subject)
    return
}

@(private)
names_validate :: proc(names:[]Name,self:string) -> Error {
    for &entry,i in names {
        name:=base.text_get(entry[:])
        if name=="" {continue}
        if !name_valid(name) {return error_about(.Name_Invalid,name)}
        if name==self {return error_about(.Depends_On_Itself,name)}
        for &other in names[:i] {
            if base.text_get(other[:])==name {return error_about(.Name_Repeated,name)}
        }
    }
    return {}
}

@(private)
file_name_byte :: proc(c:u8) -> bool {
    return c>='a' && c<='z' || c>='A' && c<='Z' || c>='0' && c<='9' || c=='_' || c=='-'
}

@(private)
file_name_valid :: proc(text:string) -> bool {
    for c in transmute([]u8)text {
        if !file_name_byte(c) {return false}
    }
    return text!=""
}

@(private)
version_valid :: proc(text:string) -> bool {
    parts,digits:=0,0
    for c in transmute([]u8)text {
        switch {
        case c>='0' && c<='9': digits+=1
        case c=='.' && digits>0: parts+=1;digits=0
        case: return false
        }
    }
    return parts==2 && digits>0
}

@(private)
identifier_valid :: proc(text:string) -> bool {
    part:=0
    for c in transmute([]u8)text {
        switch {
        case file_name_byte(c): part+=1
        case c=='.' && part>0:  part=0
        case: return false
        }
    }
    return part>0
}

@(private)
define_valid :: proc(text:string) -> bool {
    for c,i in transmute([]u8)text {
        switch {
        case c>='a' && c<='z',c>='A' && c<='Z',c=='_':
        case c>='0' && c<='9': if i==0 {return false}
        case c=='=': return i>0
        case: return false
        }
    }
    return text!=""
}

@(private)
png_path_valid :: proc(path:string) -> bool {return relative_path_valid(path) && strings.has_suffix(strings.to_lower(path,context.temp_allocator),".png")}

// Empty, or a path that stays inside the folder it is relative to.
@(private)
relative_path_valid :: proc(path:string) -> bool {
    if path=="" {return true}
    if path[0]=='/' || len(path)>1 && path[1]==':' {return false}
    start:=0
    for i in 0..=len(path) {
        if i<len(path) && path[i]=='\\' {return false}
        if i<len(path) && path[i]!='/' {continue}
        if part:=path[start:i];part=="" || part=="." || part==".." {return false}
        start=i+1
    }
    return true
}

// "" when std/serial cannot describe T (Schema_Failed).
@(private)
value_text :: proc(value:rawptr,T:typeid,allocator:=context.allocator) -> string {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,described:=serial.schema_add_type_info(&schema,type_info_of(T))
    if !described {return ""}
    w:serial.Writer
    serial.writer_init(&w,4096,allocator)
    struct_write(&w,&schema,type,([^]u8)(value)[:serial.schema_type(&schema,type).size],0)
    serial.write_u8(&w,'\n')
    return string(serial.writer_take(&w))
}

@(private)
value_parse :: proc(text:string,value:rawptr,T:typeid) -> Error {
    schema:serial.Schema
    serial.schema_init(&schema,context.temp_allocator)
    defer serial.schema_destroy(&schema)
    type,described:=serial.schema_add_type_info(&schema,type_info_of(T))
    if !described {return schema_failed(T)}
    r:serial.Text_Reader
    serial.text_reader_init(&r,text,context.temp_allocator)
    defer serial.text_reader_destroy(&r)
    if !struct_read(&r,&schema,type,([^]u8)(value)[:serial.schema_type(&schema,type).size]) || !serial.text_end(&r) {
        line,column:=serial.text_position(text,r.error.offset)
        return {code=.Text,text=r.error.code,line=line,column=column,detail=serial.text_error_message(&r,allocator=context.temp_allocator)}
    }
    return {}
}

// A text field holding an array of texts: the list of names std/serial would
// write as lists of bytes.
@(private)
field_is_text_list :: proc(s:^serial.Schema,field:^serial.Field) -> bool {
    type:=serial.schema_type(s,field.type)
    return .Text in field.flags && type.kind==.Array && serial.type_is_bytes(s,type.elem)
}

// With below, a value of the same type, only the fields that differ from it.
@(private)
struct_write :: proc(w:^serial.Writer,s:^serial.Schema,type:serial.Type_Index,data:[]u8,depth:int,below:[]u8={}) {
    fields:=0
    for &field in serial.schema_fields(s,type) {
        field_type:=serial.schema_type(s,field.type)^
        part:=data[field.offset:][:field_type.size]
        under:[]u8
        if len(below)>0 {
            under=below[field.offset:][:field_type.size]
            if mem.compare(part,under)==0 {continue}
        }
        serial.write_u8(w,fields==0?'{':',')
        fields+=1
        serial.text_write_break(w,depth+1)
        serial.text_write_string(w,field.name)
        serial.text_write_raw(w,": ")
        switch {
        case field_type.kind==.Struct:
            struct_write(w,s,field.type,part,depth+1,under)
        case field_is_text_list(s,&field):
            size:=int(serial.schema_type(s,field_type.elem).size)
            written:=0
            serial.write_u8(w,'[')
            for index in 0..<int(field_type.count) {
                text:=base.text_get(part[index*size:][:size])
                if text=="" {continue}
                if written>0 {serial.text_write_raw(w,", ")}
                serial.text_write_string(w,text)
                written+=1
            }
            serial.write_u8(w,']')
        case field_type.kind==.Array && serial.schema_type(s,field_type.elem).kind==.Struct && len(under)>0:
            // A list of entries ends at the last that differs from the layer below: the rest are read from it.
            size:=int(serial.schema_type(s,field_type.elem).size)
            last:=-1
            for index in 0..<int(field_type.count) {
                if mem.compare(part[index*size:][:size],under[index*size:][:size])!=0 {last=index}
            }
            serial.write_u8(w,'[')
            for index in 0..=last {
                if index>0 {serial.write_u8(w,',')}
                serial.text_write_break(w,depth+2)
                serial.text_write(w,s,field_type.elem,part[index*size:][:size],.Pretty,depth+2,.Text in field.flags)
            }
            serial.text_write_break(w,depth+1)
            serial.write_u8(w,']')
        case field.trim && field_type.kind==.Array:
            // Up to its last element with a byte set, each on its lines.
            size:=int(serial.schema_type(s,field_type.elem).size)
            used:=int(field_type.count)
            for used>0 && mem.check_zero(part[(used-1)*size:][:size]) {used-=1}
            if used==0 {
                serial.text_write_raw(w,"[]")
                break
            }
            serial.write_u8(w,'[')
            for index in 0..<used {
                if index>0 {serial.write_u8(w,',')}
                serial.text_write_break(w,depth+2)
                serial.text_write(w,s,field_type.elem,part[index*size:][:size],.Pretty,depth+2,.Text in field.flags)
            }
            serial.text_write_break(w,depth+1)
            serial.write_u8(w,']')
        case:
            serial.text_write(w,s,field.type,part,.Pretty,depth+1,.Text in field.flags)
        }
    }
    if fields==0 {
        serial.text_write_raw(w,"{}")
        return
    }
    serial.text_write_break(w,depth)
    serial.write_u8(w,'}')
}

@(private)
struct_read :: proc(r:^serial.Text_Reader,s:^serial.Schema,type:serial.Type_Index,data:[]u8,lenient:=false) -> (ok:bool) {
    within:string // the field whose value is being read
    defer if !ok && within!="" {serial.text_error_within(r,within)}
    if !serial.text_accept(r,'{') {return serial.text_fail(r,.Expected_Object)}
    if serial.text_accept(r,'}') {return true}
    for {
        serial.text_space(r)
        at:=r.offset
        name:=serial.text_string(r) or_return
        found:^serial.Field
        for &field in serial.schema_fields(s,type) {
            if field.name==name {found=&field;break}
        }
        if found==nil && lenient {
            serial.text_expect(r,':') or_return
            serial.text_skip(r) or_return
            if serial.text_accept(r,',') {continue}
            return serial.text_expect(r,'}')
        }
        if found==nil {return serial.text_fail_names(r,.Unknown_Field,at,nil,serial.schema_fields(s,type))}
        serial.text_expect(r,':') or_return
        within=found.name
        field_type:=serial.schema_type(s,found.type)^
        part:=data[found.offset:][:field_type.size]
        switch {
        case field_type.kind==.Struct:
            struct_read(r,s,found.type,part,lenient) or_return
        case field_is_text_list(s,found):
            size:=int(serial.schema_type(s,field_type.elem).size)
            if !serial.text_accept(r,'[') {return serial.text_fail(r,.Expected_Array)}
            mem.zero_slice(part)
            if !serial.text_accept(r,']') {
                for index:=0;;index+=1 {
                    serial.text_space(r)
                    start:=r.offset
                    if index>=int(field_type.count) {return serial.text_fail(r,.Too_Many_Elements)}
                    text:=serial.text_string(r) or_return
                    if len(text)>size {return serial.text_fail(r,.Text_Too_Long,start)}
                    copy(part[index*size:][:size],text)
                    if serial.text_accept(r,',') {continue}
                    serial.text_expect(r,']') or_return
                    break
                }
            }
        case:
            serial.text_read(r,s,found.type,part,.Text in found.flags) or_return
        }
        within=""
        if serial.text_accept(r,',') {continue}
        return serial.text_expect(r,'}')
    }
}
