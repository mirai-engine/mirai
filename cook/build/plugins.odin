package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"

// The code a project runs besides the engine is built into libraries of its
// own against the declarations of the engine, the way the engine's libraries
// are (declare.odin): one per part of each active plugin, of the engine or of
// the project, and one for each of the project's game/ and editor/, in
// <project>/.mirai/plugins/lib, with their stages and declarations under
// plugins/<mode>/, one set per optimization so that going from one to the
// other builds nothing. The library of the project compiles only the
// generated world against those declarations, so a change inside the
// procedures of the game compiles the game alone and links the world again.
// A part is compiled again when its sources, the declarations it compiles
// against (the engine's and those of the parts it depends on), the compiler
// or the flags change. The game that ships compiles every plugin from its
// sources.

Plugin_Library :: struct {
	name:    string,   // of the plugin; game or editor for those folders of the project
	part:    project.Plugin_Part,
	project: bool,     // of the project, in the collection project; otherwise of an engine plugin, in plugins
	root:    string,   // what its packages are relative to: <engine>/plugins, or the project
	path:    string,   // the folder of the part, relative to root and to its collection: animation/runtime, game
	packages:[]string, // its packages, same: the part and every folder under it with sources (physics/runtime/sim)
	needs:   []string, // the packages of the engine plugins it compiles against
	project_needs:[]string, // and those of the project
	family:  string,   // plugin-<plugin>-<part>-<mode>, project-<...>-<mode>: what every build of the part shares
	file:    string,   // the name of the library without its prefix and suffix: its family and its hash (plugin_library_name)
	library: string,   // what it builds
	linked:  string,   // what links against it: the library, or its import library on Windows
	stage:   string,   // the copy it is built from, beside the declarations so their relative paths stand
	stamp:   string,
}

@(private)
PLUGIN_ENTRY :: "__plugin"

// The runtime of Odin keeps the cleaners of thread-local memory in an array
// of eight that is a weak symbol: the dynamic loader makes one of it for
// every library of the process, and each library with core:os takes a slot
// when it loads. The libraries of plugins and of the project keep their own,
// so that any number of them load (and the project reloads).
@(private)
LIBRARY_OWN_RUNTIME :: "-Wl,-Bsymbolic" when ODIN_OS==.Linux else "-Wl,-unexported_symbol,*thread_local_cleaners" when ODIN_OS==.Darwin else ""

// The folder of the optimization the libraries of a project are built with.
plugins_mode :: proc(p:^project.Project,dev:bool) -> string {
	names:=[project.Optimization]string{.Minimal="minimal",.None="none",.Size="size",.Speed="speed",.Aggressive="aggressive"}
	return dev?"minimal":names[p.manifest.build.optimization]
}

// <project>/.mirai/plugins/<mode>: the stages, the declarations and the stamps of an optimization.
plugins_folder :: proc(root,mode:string,allocator:=context.allocator) -> string {
	return project.path(project.folder_path(root,.Generated,context.temp_allocator),"plugins",mode,allocator=allocator)
}

// The libraries of every optimization, which the library of the project finds there
// (host.project_library_load on Windows; the rpath elsewhere).
plugins_libraries_folder :: proc(root:string,allocator:=context.allocator) -> string {
	return project.path(project.folder_path(root,.Generated,context.temp_allocator),project.PLUGIN_LIBRARIES,allocator=allocator)
}

// The collection "plugins" of the libraries of a project: the declarations of the engine plugins.
plugins_decl :: proc(root,mode:string,allocator:=context.allocator) -> string {
	return project.path(plugins_folder(root,mode,context.temp_allocator),"decl",allocator=allocator)
}

// The collection "project" of the library of a project: the declarations of its own code.
project_decl :: proc(root,mode:string,allocator:=context.allocator) -> string {
	return project.path(plugins_folder(root,mode,context.temp_allocator),"decl-project",allocator=allocator)
}

// The libraries the library of the project links, in the order they build:
// those of the engine plugins, then those of the project, each with its
// runtime parts as the plugins are ordered (dependencies first) and then its
// editor parts; game/ after the runtime parts of the project and editor/ last.
plugin_libraries :: proc(p:^project.Project,dev:bool,allocator:=context.allocator) -> []Plugin_Library {
	if p.engine_root=="" {return nil}
	list:=make([dynamic]Plugin_Library,allocator)
	parts,folders:=project.PART_NAMES,project.FOLDER_NAMES
	mode:=plugins_mode(p,dev)
	folder:=plugins_folder(p.root,mode,context.temp_allocator)
	add :: proc(list:^[dynamic]Plugin_Library,lib:Plugin_Library,id,mode,folder:string,allocator:=context.allocator) {
		lib:=lib
		packages:=make([dynamic]string,allocator)
		part_packages(lib.root,lib.path,&packages,allocator)
		if len(packages)==0 {return}
		lib.packages=packages[:]
		lib.family=fmt.aprintf("%s%s-%s",lib.project?"":"plugin-",id,mode,allocator=allocator)
		lib.stage=project.path(folder,fmt.tprintf("stage-%s",id),allocator=allocator)
		lib.stamp=project.path(folder,fmt.tprintf("%s.stamp",id),allocator=allocator)
		append(list,lib)
	}
	for origin in ([2]project.Origin{.Engine,.Project}) {
		for part in ([2]project.Plugin_Part{.Runtime,.Editor}) {
			for index in p.active {
				plugin:=&p.plugins[index]
				if plugin.origin!=origin || part not_in plugin.manifest.parts {continue}
				name:=strings.clone(base.text_get(plugin.manifest.name[:]),allocator)
				root,path:=part_path(p,plugin,part,allocator)
				needs,project_needs:=make([dynamic]string,allocator),make([dynamic]string,allocator)
				plugin_needs(p,index,part,&needs,&project_needs,allocator)
				id:=fmt.tprintf("%s%s-%s",origin==.Project?"project-":"",name,parts[part])
				add(&list,{name=name,part=part,project=origin==.Project,root=root,path=path,needs=needs[:],project_needs=project_needs[:]},id,mode,folder,allocator)
			}
			if origin==.Engine {continue}
			// game/ and editor/ may use every part before them that their part may.
			needs,project_needs:=make([dynamic]string,allocator),make([dynamic]string,allocator)
			for before in list {
				if before.part==.Editor && part==.Runtime {continue}
				append(before.project?&project_needs:&needs,..before.packages)
			}
			top:=folders[.Game if part==.Runtime else .Editor]
			add(&list,{name=top,part=part,project=true,root=p.root,path=top,needs=needs[:],project_needs=project_needs[:]},fmt.tprintf("project-%s",top),mode,folder,allocator)
		}
	}
	return list[:]
}

// Where the packages of a part of a plugin are: the folder they are relative
// to, and the folder of the part relative to it, as its collection names it.
@(private="file")
part_path :: proc(p:^project.Project,plugin:^project.Plugin,part:project.Plugin_Part,allocator:=context.allocator) -> (root,path:string) {
	parts:=project.PART_NAMES
	root=p.root if plugin.origin==.Project else project.path(p.engine_root,"plugins",allocator=allocator)
	return root,fmt.aprintf("%s/%s",plugin.folder[len(root)+1:],parts[part],allocator=allocator)
}

// A library is named by what it is built from (plugin_library_hash): a
// program that loaded one loads the one built after it beside it, as the
// editor does when a build changes a plugin.
plugin_library_name :: proc(root:string,lib:^Plugin_Library,hash:u64,allocator:=context.allocator) {
	libraries:=plugins_libraries_folder(root,context.temp_allocator)
	lib.file=fmt.aprintf("%s-%08x",lib.family,u32(hash~(hash>>32)),allocator=allocator)
	lib.library=project.path(libraries,project.library_file(lib.file,context.temp_allocator),allocator=allocator)
	lib.linked=project.path(libraries,library_import_file(lib.file,context.temp_allocator),allocator=allocator)
}

// Removes the libraries of the family of lib that are not lib: those of
// sources that changed. One a program has loaded stays until a later build.
plugin_library_retire :: proc(root:string,lib:^Plugin_Library) {
	entries,error:=os.read_all_directory_by_path(plugins_libraries_folder(root,context.temp_allocator),context.temp_allocator)
	if error!=nil {return}
	family:=strings.concatenate({project.LIBRARY_PREFIX,lib.family,"-"},context.temp_allocator)
	current:=strings.concatenate({project.LIBRARY_PREFIX,lib.file,"."},context.temp_allocator)
	for entry in entries {
		if !strings.has_prefix(entry.name,family) || strings.has_prefix(entry.name,current) {continue}
		_=os.remove(entry.fullpath)
	}
}

// The packages of a part, relative to the plugins folder: the folder of the
// part and every folder under it with sources besides tests, as the generator
// finds them. They all go into the library of the part.
@(private)
part_packages :: proc(plugins,path:string,packages:^[dynamic]string,allocator:=context.allocator) {
	folder:=project.path(plugins,path,allocator=context.temp_allocator)
	entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
	if error!=nil {return}
	slice.sort_by(entries,proc(a,b:os.File_Info) -> bool {return a.name<b.name})
	for entry in entries {
		if entry.type!=.Directory && strings.has_suffix(entry.name,".odin") && !strings.has_suffix(entry.name,"_test.odin") {
			append(packages,strings.clone(path,allocator))
			break
		}
	}
	for entry in entries {
		if entry.type!=.Directory || strings.has_prefix(entry.name,".") || entry.name=="testdata" {continue}
		part_packages(plugins,fmt.tprintf("%s/%s",path,entry.name),packages,allocator)
	}
}

// What a part may import: the runtime of its own plugin from its editor, and
// the parts of the active plugins it depends on, with theirs, each with all
// its packages: those of engine plugins in needs, those of the project's in project_needs.
@(private="file")
plugin_needs :: proc(p:^project.Project,index:int,part:project.Plugin_Part,needs,project_needs:^[dynamic]string,allocator:=context.allocator) {
	plugin:=&p.plugins[index]
	add :: proc(p:^project.Project,plugin:^project.Plugin,part:project.Plugin_Part,needs,project_needs:^[dynamic]string,allocator:=context.allocator) {
		list:=project_needs if plugin.origin==.Project else needs
		root,path:=part_path(p,plugin,part,context.temp_allocator)
		found:=make([dynamic]string,context.temp_allocator)
		part_packages(root,path,&found,context.temp_allocator)
		for package_path in found {
			if !slice.contains(list[:],package_path) {append(list,strings.clone(package_path,allocator))}
		}
	}
	if part==.Editor && .Runtime in plugin.manifest.parts {add(p,plugin,.Runtime,needs,project_needs,allocator)}
	for &dependency in plugin.manifest.dependencies {
		wanted:=base.text_get(dependency[:])
		if wanted=="" {continue}
		for at in p.active {
			other:=&p.plugins[at]
			if base.text_get(other.manifest.name[:])!=wanted {continue}
			if .Runtime in other.manifest.parts {add(p,other,.Runtime,needs,project_needs,allocator)}
			if part==.Editor && .Editor in other.manifest.parts {add(p,other,.Editor,needs,project_needs,allocator)}
			plugin_needs(p,at,part,needs,project_needs,allocator)
		}
	}
}

// The flags of a plugin library besides its collections and its output: the
// optimization and the defines of the project's libraries.
@(private)
plugin_flags :: proc(p:^project.Project,dev:bool,allocator:=context.allocator) -> []string {
	flags:=make([dynamic]string,allocator)
	append(&flags,"-build-mode:dll",fmt.aprintf("-custom-attribute:%s",CUSTOM_ATTRIBUTES,allocator=allocator))
	library_optimization_append(&flags,p,dev)
	for &define in p.manifest.build.defines {
		if text:=base.text_get(define[:]);text!="" {append(&flags,fmt.aprintf("-define:%s",text,allocator=allocator))}
	}
	platform_flags(p.engine_root,&flags,false,allocator)
	environment_flags(&flags,allocator)
	return flags[:]
}

// The folder of the stage of a library, the stages and declarations of its
// optimization, and the declarations of its own collection there.
@(private="file")
plugin_folder_of :: proc(lib:^Plugin_Library) -> (folder,decl:string) {
	folder=lib.stage[:strings.last_index_byte(lib.stage,'/')]
	return folder,project.path(folder,"decl-project" if lib.project else "decl",allocator=context.temp_allocator)
}

@(private="file")
plugin_collection :: proc(lib:^Plugin_Library) -> string {return "project" if lib.project else "plugins"}

// What a library is built from: its sources, the declarations of the
// plugins it compiles against as they are now, the declarations of the
// engine that its sources and those declarations name (by the hashes the
// build of the engine keeps, each of a declaration and of what it reaches:
// declared.odin), the compiler and the flags. A change of the engine that
// declares the same builds no plugin again, and one of a declaration builds
// again the parts that name it or something that reaches it. The mode of the
// engine counts: its libraries, which the part links against, are others in
// each. Nothing of it names the project: with the same
// flags, every project of an engine shares its libraries through the cache,
// and those a package of the engine brings. It names the library
// (plugin_library_name).
@(private)
plugin_library_hash :: proc(p:^project.Project,lib:^Plugin_Library,compiler:string,flags:[]string,engine:Engine_Paths,declared:Declared) -> u64 {
	return plugin_library_hash_of(p,lib,compiler,flags,engine,declared,false)
}

// The same with the names of the libraries it links against masked: what its
// objects are compiled from. A library whose name moves and whose compile
// hash does not is linked again (relink.odin).
@(private)
plugin_library_compile_hash :: proc(p:^project.Project,lib:^Plugin_Library,compiler:string,flags:[]string,engine:Engine_Paths,declared:Declared) -> u64 {
	return plugin_library_hash_of(p,lib,compiler,flags,engine,declared,true)
}

@(private="file")
plugin_library_hash_of :: proc(p:^project.Project,lib:^Plugin_Library,compiler:string,flags:[]string,engine:Engine_Paths,declared:Declared,masked:bool) -> u64 {
	sources:=make([dynamic]string,context.temp_allocator)
	append(&sources,..engine_sources(lib.root,lib.packages))
	hashed:=make([dynamic]string,context.temp_allocator)
	append(&hashed,..flags)
	// The declarations it compiles against, relative to the folder of the project that has them.
	folder,_:=plugin_folder_of(lib)
	needed:=make([dynamic]string,context.temp_allocator)
	append(&needed,..engine_sources(project.path(folder,"decl",allocator=context.temp_allocator),lib.needs))
	append(&needed,..engine_sources(project.path(folder,"decl-project",allocator=context.temp_allocator),lib.project_needs))
	plugins_declared,_:=fingerprint(folder,"",nil,needed[:],masked=folder if masked else "")
	append(&hashed,fmt.tprintf("<plugin declarations %x>",plugins_declared))
	names:=make(map[string]bool,context.temp_allocator)
	declared_names_of(sources[:],nil,&names)
	declared_names_of(needed[:],nil,&names)
	append(&hashed,fmt.tprintf("<%sdeclarations %v %x>",ENGINE_COLLECTION,engine.mode,declared_key(declared,names)))
	// Without the hashes of what it names, every build of the engine builds it again.
	if len(declared)==0 {append(&sources,engine.stamp)}
	hash,_:=fingerprint(p.engine_root,compiler,hashed[:],sources[:])
	return hash
}

// Where a library keeps the record of its last compile (Link_Record).
@(private)
plugin_link_file :: proc(lib:^Plugin_Library) -> string {
	return strings.concatenate({lib.stamp[:len(lib.stamp)-len(".stamp")],".link"},context.temp_allocator)
}

// Writes the stage and the declarations of a library, with the declarations
// it compiles against beside its sources, and its module definition on
// Windows, which names it by the file it is published as. The errors say what
// keeps a source from being declared.
@(private)
plugin_library_prepare :: proc(lib:^Plugin_Library) -> []string {
	_,decl:=plugin_folder_of(lib)
	collection:=plugin_collection(lib)
	errors,_:=declare({root=lib.root,packages=lib.packages,binary=collection,library=lib.linked,stage=lib.stage,decl=decl,definition=plugin_definition(lib)})
	if len(errors)>0 {return errors}
	// The stage is its collection: what it compiles against of the same one is copied there.
	if !decl_mirror(lib.stage,decl,lib.project_needs if lib.project else lib.needs) {
		failed:=make([]string,1)
		failed[0]=fmt.aprintf("%s: the declarations it compiles against could not be copied",lib.stage)
		return failed
	}
	entry_write(lib.stage,PLUGIN_ENTRY,entry_imports(collection,lib.packages)[:])
	return nil
}

// The module definition its import library is made from (import_libraries_make).
@(private)
plugin_definition :: proc(lib:^Plugin_Library) -> string {
	return project.path(lib.stage,fmt.tprintf("%s.def",lib.file),allocator=context.temp_allocator)
}

// The compiler's command for a library, which writes it to staged.
@(private)
plugin_command :: proc(lib:^Plugin_Library,compiler,engine_decl,staged:string,flags:[]string,allocator:=context.allocator) -> []string {
	command:=make([dynamic]string,allocator)
	append(&command,compiler,"build",project.path(lib.stage,PLUGIN_ENTRY,allocator=allocator))
	append(&command,fmt.aprintf("-collection:mirai=%s",engine_decl,allocator=allocator),fmt.aprintf("-collection:%s=%s",plugin_collection(lib),lib.stage,allocator=allocator))
	// The code of the project sees the engine plugins through their declarations.
	if lib.project {
		folder,_:=plugin_folder_of(lib)
		append(&command,fmt.aprintf("-collection:plugins=%s",project.path(folder,"decl",allocator=context.temp_allocator),allocator=allocator))
	}
	append(&command,fmt.aprintf("-out:%s",staged,allocator=allocator))
	append(&command,..flags)
	append(&command,"-json-errors")
	file:=project.library_file(lib.file,context.temp_allocator)
	// The library of the project finds them in their folder, and they find each other there.
	when ODIN_OS==.Linux {linker_flags_append(&command,fmt.tprintf("-Wl,-soname,%s -Wl,-rpath,$ORIGIN %s",file,LIBRARY_OWN_RUNTIME),allocator)}
	else when ODIN_OS==.Darwin {linker_flags_append(&command,fmt.tprintf("-Wl,-install_name,@rpath/%s -Wl,-rpath,@loader_path %s",file,LIBRARY_OWN_RUNTIME),allocator)}
	else when ODIN_OS==.Windows {linker_flags_append(&command,"/NOIMPLIB",allocator)}
	return command[:]
}

// Whether every plugin library of the project stands as its stamp says,
// without writing anything: a library whose declarations would change after
// one it depends on is built again counts as standing until then.
plugins_current :: proc(p:^project.Project,compiler:string,dev:bool,engine:Engine_Mode) -> bool {
	libraries:=plugin_libraries(p,dev,context.temp_allocator)
	if len(libraries)==0 {return true}
	flags:=plugin_flags(p,dev,context.temp_allocator)
	paths:=engine_paths(p.engine_root,engine,context.temp_allocator)
	declared:=declared_read(paths.declared,context.temp_allocator)
	for &lib in libraries {
		saved,_,stamped:=stamp_read(lib.stamp)
		hash:=plugin_library_hash(p,&lib,compiler,flags,paths,declared)
		plugin_library_name(p.root,&lib,hash,context.temp_allocator)
		if !stamped || !os.is_file(lib.library) || saved!=hash {return false}
	}
	return true
}

// How many plugin libraries the shared cache keeps, the last used first: those
// of a few builds of every part and optimization of the branches being worked on.
@(private)
PLUGIN_CACHE_ENTRIES :: 256

// A plugin library in the cache every checkout of the repository shares, by
// what it is built from (plugin_library_hash): built once, by whichever
// checkout gets there first. Its stage, its declarations and the
// declarations it compiles against are written by every checkout, from the
// same sources.
@(private)
plugin_cache_entry :: proc(engine_root:string,lib:^Plugin_Library,hash:u64) -> string {
	return project.path(workspace.cache_folder(engine_root,"plugins",context.temp_allocator),fmt.tprintf("%x-%s",hash,lib.family),allocator=context.temp_allocator)
}

// Keeps a library just built in the cache; what links against it on Windows
// is made from its declarations (import_libraries_make).
@(private)
plugin_cache_store :: proc(engine_root:string,lib:^Plugin_Library,hash:u64) {
	entry:=plugin_cache_entry(engine_root,lib,hash)
	staging,fresh:=cache_entry_begin(entry)
	if !fresh {return}
	if os.copy_file(project.path(staging,project.library_file(lib.file,context.temp_allocator),allocator=context.temp_allocator),lib.library)!=nil {
		_=base.remove_all(staging)
		return
	}
	// The job trims the cache once it ends (plugin_cache_trim).
	cache_entry_commit(entry,staging)
}

// Keeps the PLUGIN_CACHE_ENTRIES libraries of the shared cache used last.
@(private)
plugin_cache_trim :: proc(engine_root:string) {
	cache_trim(workspace.cache_folder(engine_root,"plugins",context.temp_allocator),PLUGIN_CACHE_ENTRIES)
}

// Copies the library of an entry to staged. False when the cache has none or
// it cannot be copied.
@(private)
plugin_cache_take :: proc(engine_root:string,lib:^Plugin_Library,hash:u64,staged:string) -> bool {
	entry:=plugin_cache_entry(engine_root,lib,hash)
	if !cache_entry_complete(entry) {return false}
	if os.copy_file(staged,project.path(entry,project.library_file(lib.file,context.temp_allocator),allocator=context.temp_allocator))!=nil {
		_=os.remove(staged)
		return false
	}
	cache_entry_used(entry)
	return true
}
