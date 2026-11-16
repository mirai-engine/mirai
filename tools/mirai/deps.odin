package main

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:cook/build"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// Flags every Odin invocation needs on this platform besides the collection.
platform_flags :: proc(root:string,command:^[dynamic]string) {
    build.platform_flags(root,command)
}

// Environment of this process and of its children: the dependencies prepared under .deps.
platform_environment :: proc(root:string) {
    for variable in build.platform_environment(root) {
        cut:=strings.index_byte(variable,'=')
        os.set_env(variable[:cut],variable[cut+1:])
    }
}

// Runs a child like run; with a log, what it prints goes there instead of to the streams of this process.
run_logged :: proc(root:string,command:[]string,log:^strings.Builder) -> int {
    if log==nil {return run(root,command)}
    state,output,errors,error:=subprocess.exec({working_dir=root,command=command},context.allocator)
    strings.write_bytes(log,output)
    strings.write_bytes(log,errors)
    if error!=nil {return 127}
    return state.exit_code
}

// Whether the C compiler the C libraries are built with is there: MSVC on Windows, $CC or cc and ar elsewhere.
c_toolchain_find :: proc() -> (description:string,found:bool) {
    when ODIN_OS==.Windows {
        if directory,active:=os.lookup_env("VCINSTALLDIR",context.allocator);active && directory!="" {return directory,true}
        state,output,_,error:=subprocess.exec({command={VSWHERE,"-latest","-products","*","-requires","Microsoft.VisualStudio.Component.VC.Tools.x86.x64","-property","installationPath"}},context.allocator)
        installation:=strings.trim_space(string(output))
        return installation,error==nil && state.exit_code==0 && installation!=""
    } else {
        compiler:=os.get_env("CC",context.allocator)
        if compiler=="" {compiler="cc"}
        for tool in ([]string{compiler,"ar"}) {
            if _,present:=path_find(tool);!present {return tool,false}
        }
        return compiler,true
    }
}

// A file of PATH by name, or the name itself when it is already a path to a file.
path_find :: proc(name:string) -> (path:string,found:bool) {
    if strings.contains_any(name,"/\\") {return name,os.is_file(name)}
    search,_:=os.lookup_env("PATH",context.allocator)
    directories,_:=os.split_path_list(search,context.allocator)
    for directory in directories {
        if directory=="" {continue}
        for extension in ([2]string{"",project.EXECUTABLE_SUFFIX}) {
            candidate:=fmt.aprintf("%s/%s%s",strings.trim_right(directory,"/\\"),name,extension)
            if os.is_file(candidate) {return candidate,true}
        }
    }
    return "",false
}

when ODIN_OS==.Windows {
    VSWHERE :: `C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe`
}

// A static C library of third_party/<name>, built from its sources with the
// C compiler of the system.
C_Library :: struct {
    name:string,
    sources:[]string,     // relative to its folder, with distinct file names
    includes:[]string,    // folders searched for headers, relative to its folder, in order
    definitions:[]string,
}

// The modules of FreeType the UI uses (third_party/freetype/UPSTREAM.md);
// config/ goes first so that its configuration replaces that of include/.
@(rodata,private="file")
freetype_sources:=[?]string{
    "src/base/ftsystem.c","src/base/ftinit.c","src/base/ftdebug.c","src/base/ftbase.c",
    "src/sfnt/sfnt.c","src/truetype/truetype.c","src/smooth/smooth.c","src/autofit/autofit.c",
    "src/cff/cff.c","src/psaux/psaux.c","src/pshinter/pshinter.c","src/psnames/psnames.c",
}
@(rodata,private="file")
freetype_includes:=[?]string{"config","include"}
@(rodata,private="file")
freetype_definitions:=[?]string{"FT2_BUILD_LIBRARY"}

c_library_freetype :: proc() -> C_Library {return {"freetype",freetype_sources[:],freetype_includes[:],freetype_definitions[:]}}

// ufbx reads FBX for the importer (third_party/ufbx/UPSTREAM.md): engine-time, in the editor alone.
@(rodata,private="file")
ufbx_sources:=[?]string{"ufbx.c"}

c_library_ufbx :: proc() -> C_Library {return {"ufbx",ufbx_sources[:],nil,nil}}

// SQLite with FTS5 keeps the search index of the project chats
// (third_party/sqlite/UPSTREAM.md): engine-time, in the editor alone.
@(rodata,private="file")
sqlite_sources:=[?]string{"sqlite3.c"}
@(rodata,private="file")
sqlite_definitions:=[?]string{
    "SQLITE_ENABLE_FTS5","SQLITE_THREADSAFE=2","SQLITE_DQS=0","SQLITE_DEFAULT_MEMSTATUS=0",
    "SQLITE_OMIT_LOAD_EXTENSION","SQLITE_OMIT_DEPRECATED","SQLITE_OMIT_SHARED_CACHE",
}

c_library_sqlite :: proc() -> C_Library {return {"sqlite",sqlite_sources[:],nil,sqlite_definitions[:]}}

// The C libraries of third_party: FreeType, which the runtime links, and
// ufbx and SQLite, which the editor does.
c_libraries :: proc() -> [3]C_Library {return {c_library_freetype(),c_library_ufbx(),c_library_sqlite()}}

// The C libraries the engine links: games, the editor and the tools that
// use them. An installed engine carries them built, without their sources.
ensure_runtime_dependencies :: proc(root:string,log:^strings.Builder=nil) -> bool {
    for library in c_libraries() {
        if project.engine_installed(root) {
            if !os.is_file(c_library_files(root,library).library) {return false}
        } else if !ensure_c_library(root,library,log) {
            return false
        }
    }
    return true
}

// Whether the C libraries are there, built from the sources of now: what a
// build that compiles nothing checks before deciding to take no turn.
c_libraries_current :: proc(root:string) -> bool {
    for library in c_libraries() {
        if project.engine_installed(root) {
            if !os.is_file(c_library_files(root,library).library) {return false}
        } else if !c_library_current(root,library) {
            return false
        }
    }
    return true
}

c_library_current :: proc(root:string,library:C_Library) -> bool {
    files:=c_library_files(root,library)
    key,error:=os.read_entire_file(files.key,context.temp_allocator)
    return error==nil && os.is_file(files.library) && string(key)==c_library_key(files,library)
}

C_Library_Files :: struct {folder,directory,library,key:string}

c_library_files :: proc(root:string,library:C_Library) -> (files:C_Library_Files) {
    files.folder=join(root,"third_party",library.name)
    when ODIN_OS==.Windows {
        files.directory=join(files.folder,"windows");files.library=join(files.directory,fmt.tprintf("%s.lib",library.name))
    } else when ODIN_OS==.Darwin {
        files.directory=join(files.folder,ODIN_ARCH==.arm64?"macos-arm64":"macos");files.library=join(files.directory,fmt.tprintf("%s.a",library.name))
    } else {
        files.directory=join(files.folder,"linux");files.library=join(files.directory,fmt.tprintf("%s.a",library.name))
    }
    files.key=fmt.aprintf("%s.key",files.library)
    return
}

// Where the shared cache keeps the library built from what key names.
c_library_cached :: proc(root:string,library:C_Library,files:C_Library_Files,key:string) -> string {
    return join(workspace.cache_folder(root,"c-libraries",context.temp_allocator),fmt.tprintf("%s-%s",library.name,key),files.library[len(files.directory)+1:])
}

C_LIBRARY_OUTPUTS :: [?]string{"windows","linux","macos","macos-arm64"}

// The files a C library is built from, relative to its folder with forward
// slashes and sorted: all of them but its outputs, its Odin binding and its notes.
@(private="file")
c_library_inputs :: proc(folder,prefix:string,files:^[dynamic]string) {
    entries,_:=os.read_all_directory_by_path(folder,context.temp_allocator)
    outputs:=C_LIBRARY_OUTPUTS
    walk: for entry in entries {
        if entry.type==.Directory {
            if prefix=="" {for output in outputs {if entry.name==output {continue walk}}}
            c_library_inputs(entry.fullpath,fmt.tprintf("%s%s/",prefix,entry.name),files)
            continue
        }
        if strings.has_suffix(entry.name,".odin") || strings.has_suffix(entry.name,".md") {continue}
        append(files,fmt.tprintf("%s%s",prefix,entry.name))
    }
    if prefix=="" {slice.sort(files[:])}
}

// What a library is built from: the names and the contents of its inputs,
// without the line endings of the checkout, its sources, include folders and
// definitions. The same in every checkout.
c_library_key :: proc(files:C_Library_Files,library:C_Library) -> string {
    hash:=u64(0)
    inputs:=make([dynamic]string,context.temp_allocator)
    c_library_inputs(files.folder,"",&inputs)
    for input in inputs {
        data,_:=os.read_entire_file(join(files.folder,input),context.temp_allocator)
        kept:=0
        for b in data {
            if b!='\r' {data[kept]=b;kept+=1}
        }
        hash=base.hash_combine(base.hash_combine(hash,base.name_hash(input)),xxhash.XXH3_64_default(data[:kept]))
    }
    for list in ([3][]string{library.sources,library.includes,library.definitions}) {
        for item in list {hash=base.hash_combine(hash,base.name_hash(item))}
    }
    return fmt.tprintf("%x",hash)
}

// Builds a C library unless the one there was built from its sources of now.
// The cache every checkout of the repository shares keeps it by the hash of
// what it is built from: a worktree or a branch with the same sources copies
// it, and only the first one compiles.
ensure_c_library :: proc(root:string,library:C_Library,log:^strings.Builder) -> bool {
    files:=c_library_files(root,library)
    key:=c_library_key(files,library)
    if saved,error:=os.read_entire_file(files.key,context.temp_allocator);error==nil && string(saved)==key && os.is_file(files.library) {return true}
    if os.make_directory_all(files.directory)!=nil && !os.is_dir(files.directory) {return false}
    cached:=c_library_cached(root,library,files,key)
    if os.is_file(cached) && os.copy_file(files.library,cached)==nil {
        return os.write_entire_file(files.key,key)==nil
    }
    folder,directory,library_file:=files.folder,files.directory,files.library
    when ODIN_OS==.Windows {object_extension:=".obj"} else {object_extension:=".o"}
    objects:=make([dynamic]string,context.temp_allocator)
    for source in library.sources {
        name:=source[strings.last_index_byte(source,'/')+1:]
        append(&objects,join(directory,fmt.tprintf("%s%s",name[:len(name)-len(".c")],object_extension)))
    }
    when ODIN_OS==.Windows {
        // cl and lib need the MSVC environment; vswhere locates it when it is not active.
        // The steps go through a batch file: cmd does not parse the quoting of a spawned command line.
        script:=strings.builder_make()
        // vcvars runs vswhere by name, which the shell does not find in the current folder when this is set.
        fmt.sbprint(&script,"@echo off\r\nset NoDefaultCurrentDirectoryInExePath=\r\n")
        if _,found:=os.lookup_env("VCINSTALLDIR",context.allocator);!found {
            installation,found:=c_toolchain_find()
            if !found {
                if log==nil {fmt.eprintfln("mirai: the MSVC C compiler is needed to build %s",library.name)}
                return false
            }
            fmt.sbprintf(&script,"call \"%s%s\" >nul || exit /b 1\r\n",installation,`\VC\Auxiliary\Build\vcvars64.bat`)
        }
        fmt.sbprint(&script,"cl /nologo /c /O2 ")
        for definition in library.definitions {fmt.sbprintf(&script,"/D%s ",definition)}
        for include in library.includes {fmt.sbprintf(&script,"/I\"%s\" ",join(folder,include))}
        // A folder for /Fo ends in a separator; doubled, the quote that follows stays a quote.
        fmt.sbprintf(&script,"/Fo\"%s\\\\\"",directory)
        for source in library.sources {fmt.sbprintf(&script," \"%s\"",join(folder,source))}
        fmt.sbprintf(&script," || exit /b 1\r\nlib /nologo /OUT:\"%s\"",library_file)
        for object in objects {fmt.sbprintf(&script," \"%s\"",object)}
        fmt.sbprint(&script," || exit /b 1\r\n")
        batch:=join(directory,"build.bat")
        if os.write_entire_file(batch,strings.to_string(script))!=nil {return false}
        code:=run_logged(root,{"cmd","/c",batch},log)
        os.remove(batch)
        if code!=0 {return false}
    } else {
        compiler:=os.get_env("CC",context.allocator)
        if compiler=="" {compiler="cc"}
        for source,i in library.sources {
            command:=make([dynamic]string)
            append(&command,compiler,"-std=c99","-O2","-c",join(folder,source),"-o",objects[i])
            for definition in library.definitions {append(&command,fmt.tprintf("-D%s",definition))}
            for include in library.includes {append(&command,fmt.tprintf("-I%s",join(folder,include)))}
            when ODIN_OS==.Darwin {append(&command,"-mmacosx-version-min=13.0")} else {append(&command,"-fPIC")}
            if run_logged(root,command[:],log)!=0 {return false}
        }
        command:=make([dynamic]string)
        append(&command,"ar","rcs",library_file)
        append(&command,..objects[:])
        if run_logged(root,command[:],log)!=0 {return false}
    }
    if !os.is_file(library_file) {return false}
    // Written aside and renamed: another checkout never copies half of it.
    if os.make_directory_all(os.dir(cached))==nil || os.is_dir(os.dir(cached)) {
        staged:=fmt.tprintf("%s.part-%d",cached,os.get_pid())
        if os.copy_file(staged,library_file)!=nil || os.rename(staged,cached)!=nil {_=os.remove(staged)}
    }
    return os.write_entire_file(files.key,key)==nil
}

// Windows loads SDL3.dll from the folder of the executable: copy the one of the Odin installation there.
ensure_sdl :: proc(root,directory:string) {
    when ODIN_OS==.Windows {
        target:=join(directory,"SDL3.dll")
        if os.exists(target) {return}
        state,output,_,error:=subprocess.exec({command={odin_executable(root),"root"}},context.allocator)
        if error!=nil || state.exit_code!=0 {return}
        source:=join(strings.trim_space(string(output)),"vendor","sdl3","SDL3.dll")
        if os.exists(source) {os.copy_file(target,source)}
    }
}
