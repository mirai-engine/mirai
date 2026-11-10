package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "mirai:cook/workspace"
import "mirai:project"
import "mirai:std/base"

// The engine's plugins a project activates are built into libraries of their
// own, one per part, against the declarations of the engine, the way the
// engine's libraries are (declare.odin): <project>/.mirai/plugins/lib/
// libplugin-<name>-<part>-<mode>, with their stages and declarations under
// plugins/<mode>/, one set per optimization so that going from one to the
// other builds nothing. The
// editor and play libraries of the project compile the game and the world
// against those declarations, so a change of the game compiles neither the
// plugins nor the engine. A part is compiled again when its sources, the
// declarations it compiles against (the engine's and those of the parts it
// depends on), the compiler or the flags change; a program that loaded the
// previous library starts again to use the new one. The plugins of the
// project's own plugins/ are compiled with the project, and the game that
// ships compiles every plugin from its sources.

Plugin_Library :: struct {
	name:    string,
	part:    project.Plugin_Part,
	path:    string,   // the folder of the part, relative to <engine>/plugins: animation/runtime
	packages:[]string, // its packages, same: the part and every folder under it with sources (physics/runtime/sim)
	needs:   []string, // the packages of the parts it compiles against
	family:  string,   // plugin-<plugin>-<part>-<mode>: what every build of the part shares
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

// The collection "plugins" of the libraries of a project.
plugins_decl :: proc(root,mode:string,allocator:=context.allocator) -> string {
	return project.path(plugins_folder(root,mode,context.temp_allocator),"decl",allocator=allocator)
}

// The libraries of the active engine plugins the library of the project
// links, in the order they build: the runtime parts as the plugins are
// ordered (dependencies first), then the editor parts.
plugin_libraries :: proc(p:^project.Project,dev:bool,allocator:=context.allocator) -> []Plugin_Library {
	if p.engine_root=="" {return nil}
	list:=make([dynamic]Plugin_Library,allocator)
	parts:=project.PART_NAMES
	mode:=plugins_mode(p,dev)
	folder:=plugins_folder(p.root,mode,context.temp_allocator)
	libraries:=plugins_libraries_folder(p.root,context.temp_allocator)
	sources:=project.path(p.engine_root,"plugins",allocator=context.temp_allocator)
	for part in ([2]project.Plugin_Part{.Runtime,.Editor}) {
		for index in p.active {
			plugin:=&p.plugins[index]
			if plugin.origin!=.Engine || part not_in plugin.manifest.parts {continue}
			name:=base.text_get(plugin.manifest.name[:])
			family:=fmt.aprintf("plugin-%s-%s-%s",name,parts[part],mode,allocator=allocator)
			path:=fmt.aprintf("%s/%s",name,parts[part],allocator=allocator)
			packages:=make([dynamic]string,allocator)
			part_packages(sources,path,&packages,allocator)
			needs:=make([dynamic]string,allocator)
			plugin_needs(p,index,part,&needs,allocator)
			append(&list,Plugin_Library{
				name=strings.clone(name,allocator),part=part,
				path=path,
				packages=packages[:],
				needs=needs[:],
				family=family,
				stage=project.path(folder,fmt.tprintf("stage-%s-%s",name,parts[part]),allocator=allocator),
				stamp=project.path(folder,fmt.tprintf("%s-%s.stamp",name,parts[part]),allocator=allocator),
			})
		}
	}
	return list[:]
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
// the parts of the plugins it depends on, with theirs, each with all its packages.
@(private="file")
plugin_needs :: proc(p:^project.Project,index:int,part:project.Plugin_Part,needs:^[dynamic]string,allocator:=context.allocator) {
	parts:=project.PART_NAMES
	plugin:=&p.plugins[index]
	name:=base.text_get(plugin.manifest.name[:])
	sources:=project.path(p.engine_root,"plugins",allocator=context.temp_allocator)
	add :: proc(needs:^[dynamic]string,sources,path:string,allocator:=context.allocator) {
		found:=make([dynamic]string,context.temp_allocator)
		part_packages(sources,path,&found,context.temp_allocator)
		next: for package_path in found {
			for need in needs {if need==package_path {continue next}}
			append(needs,strings.clone(package_path,allocator))
		}
	}
	if part==.Editor && .Runtime in plugin.manifest.parts {add(needs,sources,fmt.tprintf("%s/%s",name,parts[.Runtime]),allocator)}
	for &dependency in plugin.manifest.dependencies {
		wanted:=base.text_get(dependency[:])
		if wanted=="" {continue}
		for &other,at in p.plugins {
			if other.origin!=.Engine || base.text_get(other.manifest.name[:])!=wanted {continue}
			if .Runtime in other.manifest.parts {add(needs,sources,fmt.tprintf("%s/%s",wanted,parts[.Runtime]),allocator)}
			if part==.Editor && .Editor in other.manifest.parts {add(needs,sources,fmt.tprintf("%s/%s",wanted,parts[.Editor]),allocator)}
			plugin_needs(p,at,part,needs,allocator)
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

// The declarations beside the stage of a library: those of its optimization.
@(private="file")
plugin_decl_of :: proc(lib:^Plugin_Library) -> string {
	return project.path(lib.stage[:strings.last_index_byte(lib.stage,'/')],"decl",allocator=context.temp_allocator)
}

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
	append(&sources,..engine_sources(project.path(p.engine_root,"plugins",allocator=context.temp_allocator),lib.packages))
	hashed:=make([dynamic]string,context.temp_allocator)
	append(&hashed,..flags)
	// The declarations it compiles against, relative to the folder of the project that has them.
	decl:=plugin_decl_of(lib)
	needed:=engine_sources(decl,lib.needs)
	plugins_declared,_:=fingerprint(decl,"",nil,needed,masked=decl if masked else "")
	append(&hashed,fmt.tprintf("<plugin declarations %x>",plugins_declared))
	names:=make(map[string]bool,context.temp_allocator)
	declared_names_of(sources[:],nil,&names)
	declared_names_of(needed,nil,&names)
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
// it compiles against beside its sources. The errors say what keeps a source
// from being declared.
@(private)
plugin_library_prepare :: proc(p:^project.Project,lib:^Plugin_Library) -> []string {
	decl:=plugin_decl_of(lib)
	errors,_:=declare({root=project.path(p.engine_root,"plugins",allocator=context.temp_allocator),packages=lib.packages,binary="plugins",library=lib.linked,stage=lib.stage,decl=decl})
	if len(errors)>0 {return errors}
	if !decl_mirror(lib.stage,decl,lib.needs) {
		failed:=make([]string,1)
		failed[0]=fmt.aprintf("%s: the declarations it compiles against could not be copied",lib.stage)
		return failed
	}
	entry_write(lib.stage,PLUGIN_ENTRY,entry_imports("plugins",lib.packages)[:])
	if !plugin_definition_write(lib) {
		failed:=make([]string,1)
		failed[0]=fmt.aprintf("%s: its module definition could not be written",lib.stage)
		return failed
	}
	return nil
}

// The module definition that names a library on Windows by the file it is
// published as: the libraries that link it look for that name, not the one
// it is staged as. It stands in the stage, and the compiler runs there
// (plugin_work) so that the linker flag names it without a path.
@(private)
plugin_definition_write :: proc(lib:^Plugin_Library) -> bool {
	when ODIN_OS==.Windows {
		return os.write_entire_file(project.path(lib.stage,plugin_definition_file(lib),allocator=context.temp_allocator),fmt.tprintf("LIBRARY \"%s\"",project.library_file(lib.file,context.temp_allocator)))==nil
	} else {
		return true
	}
}

@(private="file")
plugin_definition_file :: proc(lib:^Plugin_Library) -> string {
	return fmt.tprintf("%s.def",lib.file)
}

// The compiler's command for a library, which writes it to staged and runs in its stage.
@(private)
plugin_command :: proc(lib:^Plugin_Library,compiler,engine_decl,staged:string,flags:[]string,allocator:=context.allocator) -> []string {
	command:=make([dynamic]string,allocator)
	append(&command,compiler,"build",project.path(lib.stage,PLUGIN_ENTRY,allocator=allocator))
	append(&command,fmt.aprintf("-collection:mirai=%s",engine_decl,allocator=allocator),fmt.aprintf("-collection:plugins=%s",lib.stage,allocator=allocator))
	append(&command,fmt.aprintf("-out:%s",staged,allocator=allocator))
	append(&command,..flags)
	append(&command,"-json-errors")
	file:=project.library_file(lib.file,context.temp_allocator)
	// The library of the project finds them in their folder, and they find each other there.
	// Odin passes no quotes in -extra-linker-flags (odin-lang/Odin#2741): a path with spaces would reach
	// the linker split in two, so on Windows the definition is named relative to the stage.
	when ODIN_OS==.Linux {linker_flags_append(&command,fmt.tprintf("-Wl,-soname,%s -Wl,-rpath,$ORIGIN %s",file,LIBRARY_OWN_RUNTIME),allocator)}
	else when ODIN_OS==.Darwin {linker_flags_append(&command,fmt.tprintf("-Wl,-install_name,@rpath/%s -Wl,-rpath,@loader_path %s",file,LIBRARY_OWN_RUNTIME),allocator)}
	else when ODIN_OS==.Windows {linker_flags_append(&command,fmt.tprintf("/DEF:%s",plugin_definition_file(lib)),allocator)}
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

// What an entry holds and where the library has it: the library and, on
// Windows, the import library its dependents and the project link against.
@(private)
plugin_cache_files :: proc(lib:^Plugin_Library) -> (files:[2][2]string) {
	files[0]={project.library_file(lib.file,context.temp_allocator),lib.library}
	when ODIN_OS==.Windows {files[1]={library_import_file(lib.file,context.temp_allocator),lib.linked}}
	return
}

// Keeps a library just built in the cache.
@(private)
plugin_cache_store :: proc(engine_root:string,lib:^Plugin_Library,hash:u64) {
	entry:=plugin_cache_entry(engine_root,lib,hash)
	staging,fresh:=cache_entry_begin(entry)
	if !fresh {return}
	for file in plugin_cache_files(lib) {
		if file[0]=="" {continue}
		if os.copy_file(project.path(staging,file[0],allocator=context.temp_allocator),file[1])!=nil {
			_=base.remove_all(staging)
			return
		}
	}
	// The job trims the cache once its libraries are stored (plugin_cache_trim).
	cache_entry_commit(entry,staging)
}

// Keeps the PLUGIN_CACHE_ENTRIES libraries of the shared cache used last.
@(private)
plugin_cache_trim :: proc(engine_root:string) {
	cache_trim(workspace.cache_folder(engine_root,"plugins",context.temp_allocator),PLUGIN_CACHE_ENTRIES)
}

// Copies the library of an entry next to staged, the way the compiler leaves
// it (staged and, on Windows, its import library beside it). False when the
// cache has none or it cannot be copied whole.
@(private)
plugin_cache_take :: proc(engine_root:string,lib:^Plugin_Library,hash:u64,staged:string) -> bool {
	entry:=plugin_cache_entry(engine_root,lib,hash)
	if !cache_entry_complete(entry) {return false}
	targets:=[2]string{staged,""}
	when ODIN_OS==.Windows {targets[1]=plugin_import_staged(staged)}
	for file,i in plugin_cache_files(lib) {
		if file[0]=="" {continue}
		if os.copy_file(targets[i],project.path(entry,file[0],allocator=context.temp_allocator))!=nil {
			for target in targets {if target!="" {_=os.remove(target)}}
			return false
		}
	}
	cache_entry_used(entry)
	return true
}

// The import library the compiler leaves next to a library on Windows.
@(private)
plugin_import_staged :: proc(staged:string) -> string {
	return strings.concatenate({staged[:len(staged)-len(project.LIBRARY_SUFFIX)],".lib"},context.temp_allocator)
}
