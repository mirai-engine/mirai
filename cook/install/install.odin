package install

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import "mirai:std/subprocess"

// The plugins of a project that come from git (project.Source): what mirai
// plugin and the Plugins of the settings run. Each is a checkout under the
// project's plugins/ at the commit its project.mirai names, which the
// repository of the project ignores. git itself fetches them, with the
// credentials of the machine, so a private repository installs for whoever
// can read it. Nothing of a plugin runs while it is installed: its code runs
// once a build compiles it and the editor or the game loads it.
//
// The catalog (project.Catalog) is a repository too: the machine keeps a
// checkout of it beside the files of the engine, and an install from it
// checks out the commit it lists, the one that was reviewed.

Result :: struct {
    ok:bool,
    name:project.Name,     // of the plugin
    commit:project.Commit, // it is at now
    message:string,        // in the allocator given: what failed, or what changed
}

// Clones url, checks it is a plugin this project can take and makes it one
// of the project, active, at ref (a commit, tag or branch; empty: the default
// branch of the repository). catalog: it comes from the catalog, at the
// commit the catalog lists, and updates only to what the catalog lists.
add :: proc(root,engine_root,url,ref:string,allocator:=context.allocator,catalog:=false) -> (result:Result) {
    url:=strings.trim_space(url)
    if url=="" {return fail(allocator,"Give the address of the repository of the plugin")}
    // A folder of this machine is written with forward slashes, as git takes it everywhere.
    if !strings.contains(url,"://") {url,_=strings.replace_all(url,"\\","/",context.temp_allocator)}
    manifest_path:=project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator)
    manifest,read_error:=project.manifest_read(manifest_path)
    if read_error.code!=.None {return fail(allocator,"%s",project.error_text(root,read_error,context.temp_allocator))}
    staging,staging_ok:=staging_folder(root)
    if !staging_ok {return fail(allocator,"%s could not be made",staging)}
    defer os.remove_all(staging)
    if _,failure:=git("","clone","--quiet",url,staging);failure!="" {return fail(allocator,"%s could not be cloned: %s",url,failure)}
    if ref:=strings.trim_space(ref);ref!="" {
        if _,failure:=git(staging,"checkout","--quiet","--detach",ref);failure!="" {return fail(allocator,"%s has no %s: %s",url,ref,failure)}
    }
    commit,failure:=git(staging,"rev-parse","HEAD")
    if failure!="" {return fail(allocator,"%s",failure)}
    // At a commit, as sync and update leave it, not on a branch that falls behind.
    git(staging,"checkout","--quiet","--detach",commit)
    plugin,problem:=plugin_check(staging,"")
    if problem!="" {return fail(allocator,"%s is not a plugin Mirai can install: %s",url,problem)}
    name:=base.text_get(plugin.name[:])
    if project.source_find(&manifest,name)!=nil {return fail(allocator,"The project already has %s; update it instead",name)}
    folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
    if os.exists(folder) {return fail(allocator,"%s already exists: the project has a plugin %s of its own",folder,name)}
    if engine_root!="" && os.is_file(project.path(engine_root,"plugins",name,project.PLUGIN_FILE,allocator=context.temp_allocator)) {
        return fail(allocator,"The engine has a plugin %s: two plugins cannot have one name",name)
    }
    slot:=-1
    for &source,i in manifest.sources {
        if base.text_len(source.name[:])==0 {slot=i;break}
    }
    if slot<0 {return fail(allocator,"A project has at most %d plugins from git",project.MAX_SOURCES)}
    before:=manifest
    source:=&manifest.sources[slot]
    source.name=plugin.name
    base.text_set(source.url[:],url)
    base.text_set(source.commit[:],commit)
    source.catalog=catalog
    if !plugin.automatic && !named_add(&manifest,plugin.name) {return fail(allocator,"A project names at most %d plugins",project.MAX_PLUGINS)}
    if error:=os.make_directory_all(project.path(root,"plugins",allocator=context.temp_allocator));error!=nil && error!=.Exist {return fail(allocator,"The plugins folder of the project could not be made")}
    if error:=os.rename(staging,folder);error!=nil {return fail(allocator,"%s could not be moved to %s: %v",staging,folder,error)}
    if message:=manifest_commit(root,engine_root,&manifest,&before);message!="" {
        os.remove_all(folder)
        return fail(allocator,"%s",message)
    }
    ignore_set(root,name,true)
    result.ok,result.name=true,plugin.name
    base.text_set(result.commit[:],commit)
    result.message=fmt.aprintf("%s %s added at %s",name,base.text_get(plugin.version[:]),commit[:12],allocator=allocator)
    return
}

// Installs the plugin the catalog lists by name, at the commit it lists, as
// the checkout of the catalog on this machine has it.
add_from_catalog :: proc(root,engine_root,name:string,allocator:=context.allocator) -> Result {
    catalog:=new(project.Catalog,context.temp_allocator)
    if message:=catalog_load(engine_root,catalog);message!="" {return fail(allocator,"%s",message)}
    entry:=project.catalog_find(catalog,name)
    if entry==nil {return fail(allocator,"The catalog has no %s; `mirai plugin catalog` lists the ones it has",name)}
    return add(root,engine_root,base.text_get(entry.url[:]),base.text_get(entry.commit[:]),allocator,catalog=true)
}

// Moves a plugin from git to ref: a commit, tag or branch. Empty: for one of
// the catalog, the commit the catalog lists, never one older than the
// checkout's and never without the catalog; for another, the default branch
// of its repository. The message has the commits it brings.
update :: proc(root,engine_root,name,ref:string,allocator:=context.allocator) -> (result:Result) {
    manifest_path:=project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator)
    manifest,read_error:=project.manifest_read(manifest_path)
    if read_error.code!=.None {return fail(allocator,"%s",project.error_text(root,read_error,context.temp_allocator))}
    source:=project.source_find(&manifest,name)
    if source==nil {return fail(allocator,"%s does not come from git: the project has no source for it",name)}
    folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
    if message:=checkout_ensure(root,source);message!="" {return fail(allocator,"%s",message)}
    if status,failure:=git(folder,"status","--porcelain");failure!="" || status!="" {
        return fail(allocator,"%s has changes of its own: commit or discard them in %s before updating",name,folder)
    }
    url:=base.text_get(source.url[:])
    target:=strings.trim_space(ref)
    reviewed:=false // the target is the commit of the catalog, not one asked for
    if target=="" && source.catalog {
        catalog:=new(project.Catalog,context.temp_allocator)
        if message:=catalog_load(engine_root,catalog);message!="" {return fail(allocator,"%s comes from the catalog, which could not be read: %s",name,message)}
        entry:=project.catalog_find(catalog,name)
        if entry==nil {return fail(allocator,"The catalog no longer lists %s",name)}
        if base.text_get(entry.url[:])!=url {return fail(allocator,"The catalog lists %s at another address now: %s",name,base.text_get(entry.url[:]))}
        target=strings.clone(base.text_get(entry.commit[:]),context.temp_allocator)
        reviewed=true
    }
    if _,failure:=git(folder,"fetch","--quiet","--tags","origin");failure!="" {return fail(allocator,"%s could not be fetched: %s",url,failure)}
    // A branch as the remote has it now, before a local one of the same name.
    if target=="" {target="HEAD"}
    commit,failure:=git(folder,"rev-parse","--verify","--quiet",strings.concatenate({"origin/",target,"^{commit}"},context.temp_allocator))
    if failure!="" || commit=="" {
        commit,failure=git(folder,"rev-parse","--verify","--quiet",strings.concatenate({target,"^{commit}"},context.temp_allocator))
        if failure!="" || commit=="" {return fail(allocator,"%s has no %s",url,target)}
    }
    old:=strings.clone(base.text_get(source.commit[:]),context.temp_allocator)
    result.name=source.name
    base.text_set(result.commit[:],commit)
    if commit==old {
        result.ok=true
        result.message=fmt.aprintf("%s is already at %s",name,commit[:12],allocator=allocator)
        return
    }
    // The catalog never takes a plugin back: one checked out past its commit, by a ref asked for, stays.
    if _,behind:=git(folder,"merge-base","--is-ancestor",commit,old);reviewed && behind=="" {
        base.text_set(result.commit[:],old)
        result.ok=true
        result.message=fmt.aprintf("%s stays at %s: the catalog lists %s, which is older",name,old[:12],commit[:12],allocator=allocator)
        return
    }
    log,_:=git(folder,"log","--oneline","--no-decorate",fmt.tprintf("%s..%s",old,commit))
    stat,_:=git(folder,"diff","--stat",old,commit)
    if _,failure=git(folder,"checkout","--quiet","--detach",commit);failure!="" {return fail(allocator,"%s",failure)}
    plugin,problem:=plugin_check(folder,name)
    if problem=="" && plugin.name!=source.name {problem=fmt.tprintf("its plugin.mirai now names it %s",base.text_get(plugin.name[:]))}
    if problem!="" {
        git(folder,"checkout","--quiet","--detach",old)
        return fail(allocator,"%s was left at %s: %s at %s %s",name,old[:12],url,commit[:12],problem)
    }
    before:=manifest
    base.text_set(source.commit[:],commit)
    if message:=manifest_commit(root,engine_root,&manifest,&before);message!="" {
        git(folder,"checkout","--quiet","--detach",old)
        return fail(allocator,"%s",message)
    }
    result.ok=true
    result.message=fmt.aprintf("%s %s..%s\n%s\n%s",name,old[:12],commit[:12],log,stat,allocator=allocator)
    return
}

// Whether the checkout of the plugin name has commit in its history: it is
// at it or past it. False too when there is no checkout.
has_commit :: proc(root,name,commit:string) -> bool {
    folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
    if !os.is_dir(folder) {return false}
    _,failure:=git(folder,"merge-base","--is-ancestor",commit,"HEAD")
    return failure==""
}

// Takes a plugin from git out of the project and deletes its checkout,
// unless that has changes of its own.
remove :: proc(root,engine_root,name:string,allocator:=context.allocator) -> (result:Result) {
    manifest_path:=project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator)
    manifest,read_error:=project.manifest_read(manifest_path)
    if read_error.code!=.None {return fail(allocator,"%s",project.error_text(root,read_error,context.temp_allocator))}
    source:=project.source_find(&manifest,name)
    if source==nil {return fail(allocator,"%s does not come from git: the project has no source for it",name)}
    folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
    if os.exists(folder) {
        if status,failure:=git(folder,"status","--porcelain");failure=="" && status!="" {
            return fail(allocator,"%s has changes of its own: commit or discard them in %s before removing it",name,folder)
        }
    }
    if dependent:=dependent_find(root,engine_root,name);dependent!="" {return fail(allocator,"%s depends on %s: deactivate it first",dependent,name)}
    result.name=source.name
    source^={}
    named_remove(&manifest,result.name)
    compact(&manifest)
    if error:=project.manifest_write(manifest_path,&manifest);error.code!=.None {return fail(allocator,"%s",project.error_text(root,error,context.temp_allocator))}
    if os.exists(folder) {
        if error:=os.remove_all(folder);error!=nil {
            result.ok=true
            result.message=fmt.aprintf("%s was taken out of the project, but %s could not be deleted: %v",name,folder,error,allocator=allocator)
            return
        }
    }
    ignore_set(root,name,false)
    result.ok=true
    result.message=fmt.aprintf("%s removed",name,allocator=allocator)
    return
}

// Makes every plugin from git a checkout at the commit the project names:
// what a fresh clone of the project, or a pull that moved a commit, needs
// before it builds. A checkout with changes of its own is left as it is.
// changed counts the ones it cloned or moved; message says what went wrong.
sync :: proc(root:string,allocator:=context.allocator) -> (changed:int,message:string) {
    manifest,read_error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if read_error.code!=.None {return}
    problems:=make([dynamic]string,context.temp_allocator)
    for &source in manifest.sources {
        name:=base.text_get(source.name[:])
        if name=="" {continue}
        folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
        commit:=base.text_get(source.commit[:])
        if os.exists(folder) {
            head,_:=git(folder,"rev-parse","HEAD")
            if head==commit {continue}
            if status,failure:=git(folder,"status","--porcelain");failure!="" || status!="" {
                append(&problems,fmt.tprintf("%s has changes of its own and is not at %s",name,commit[:12]))
                continue
            }
        }
        if failure:=checkout_ensure(root,&source);failure!="" {
            append(&problems,failure)
            continue
        }
        folder_head,_:=git(folder,"rev-parse","HEAD")
        if folder_head!=commit {
            if _,failure:=git(folder,"cat-file","-e",strings.concatenate({commit,"^{commit}"},context.temp_allocator));failure!="" {git(folder,"fetch","--quiet","--tags","origin")}
            if _,failure:=git(folder,"checkout","--quiet","--detach",commit);failure!="" {
                append(&problems,fmt.tprintf("%s could not be checked out at %s: %s",name,commit[:12],failure))
                continue
            }
        }
        ignore_set(root,name,true)
        changed+=1
    }
    if len(problems)>0 {message=strings.join(problems[:],"\n",allocator)}
    return
}

// Whether the project names a plugin from git whose checkout is missing or
// at another commit: when sync has something to do. It runs no git.
sync_needed :: proc(root:string) -> bool {
    manifest,read_error:=project.manifest_read(project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator))
    if read_error.code!=.None {return false}
    for &source in manifest.sources {
        name:=base.text_get(source.name[:])
        if name=="" {continue}
        folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
        head,known:=head_read(folder)
        if !known || head!=base.text_get(source.commit[:]) {return true}
    }
    return false
}

// Checks a folder is a plugin: its plugin.mirai, the folders of its parts, no
// links, a range of the engine that takes this one, and the same of each of
// its companions. name: the one it must have; empty: any.
plugin_check :: proc(folder,name:string) -> (plugin:project.Plugin_Manifest,problem:string) {
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    checked,failure:=plugin_check_one(folder,name)
    plugin=checked;problem=failure
    if problem!="" {return}
    if link:=link_find(folder);link!="" {return {},fmt.tprintf("%s is a link: a plugin has only files and folders",link)}
    companions:=project.path(folder,project.PLUGIN_COMPANIONS,allocator=context.temp_allocator)
    entries,_:=os.read_all_directory_by_path(companions,context.temp_allocator)
    for entry in entries {
        if entry.type!=.Directory || !os.is_file(project.path(companions,entry.name,project.PLUGIN_FILE,allocator=context.temp_allocator)) {continue}
        if _,companion:=plugin_check_one(project.path(companions,entry.name,allocator=context.temp_allocator),entry.name);companion!="" {
            return {},fmt.tprintf("its companion %s/%s: %s",project.PLUGIN_COMPANIONS,entry.name,companion)
        }
    }
    return
}

@(private)
plugin_check_one :: proc(folder,name:string) -> (plugin:project.Plugin_Manifest,problem:string) {
    // One store per value until odin-lang/Odin#7937 (see ODIN_WORKAROUNDS).
    read,error:=project.plugin_read(project.path(folder,project.PLUGIN_FILE,allocator=context.temp_allocator))
    plugin=read
    if error.code!=.None {
        if error.code==.Not_Found {return {},fmt.tprintf("it has no %s at its root",project.PLUGIN_FILE)}
        return {},fmt.tprintf("its %s: %v %s",project.PLUGIN_FILE,error.code,base.text_get(error.subject[:]))
    }
    if name!="" && base.text_get(plugin.name[:])!=name {return {},fmt.tprintf("its %s names it %s",project.PLUGIN_FILE,base.text_get(plugin.name[:]))}
    parts:=project.PART_NAMES
    for part in project.Plugin_Part {
        exists:=os.is_dir(project.path(folder,parts[part],allocator=context.temp_allocator))
        if exists && part not_in plugin.parts {return {},fmt.tprintf("it has %s/ and its %s does not declare it",parts[part],project.PLUGIN_FILE)}
        if !exists && part in plugin.parts {return {},fmt.tprintf("its %s declares %s and the folder is not there",project.PLUGIN_FILE,parts[part])}
    }
    if icon:=base.text_get(plugin.icon[:]);icon!="" {
        file:=project.path(folder,icon,allocator=context.temp_allocator)
        width,height,ok:=project.png_size(file)
        if !ok {return {},fmt.tprintf("its icon %s is not a PNG it holds",icon)}
        if width>project.PLUGIN_ICON_MAX || height>project.PLUGIN_ICON_MAX {
            return {},fmt.tprintf("its icon %s is %dx%d: scale it to %dx%d or less",icon,width,height,project.PLUGIN_ICON_MAX,project.PLUGIN_ICON_MAX)
        }
    }
    if error=project.plugin_engine_check(&plugin);error.code!=.None {
        return {},fmt.tprintf("it works with engines %s %s and this one is %s",error.code==.Engine_Old?"from":"up to",base.text_get(error.subject[:]),project.ENGINE_VERSION)
    }
    return
}

// The checkout of the catalog on this machine: beside the files of the engine.
catalog_folder :: proc(engine_root:string,allocator:=context.allocator) -> string {
    return project.path(project.machine_folder(engine_root,context.temp_allocator),"catalog",allocator=allocator)
}

// Clones the catalog, or brings its checkout to what the repository has now.
catalog_refresh :: proc(engine_root:string,allocator:=context.allocator) -> (message:string) {
    if engine_root=="" {return strings.clone("The root of the engine is unknown",allocator)}
    folder:=catalog_folder(engine_root,context.temp_allocator)
    if os.is_dir(project.path(folder,".git",allocator=context.temp_allocator)) {
        if _,failure:=git(folder,"fetch","--quiet","--depth","1","origin");failure!="" {return fmt.aprintf("The catalog could not be fetched: %s",failure,allocator=allocator)}
        if _,failure:=git(folder,"reset","--quiet","--hard","FETCH_HEAD");failure!="" {return fmt.aprintf("%s",failure,allocator=allocator)}
        return
    }
    os.remove_all(folder)
    if error:=os.make_directory_all(project.machine_folder(engine_root,context.temp_allocator));error!=nil && error!=.Exist {return fmt.aprintf("%s could not be made",folder,allocator=allocator)}
    if _,failure:=git("","clone","--quiet","--depth","1",project.CATALOG_URL,folder);failure!="" {return fmt.aprintf("The catalog could not be cloned: %s",failure,allocator=allocator)}
    return
}

// Reads the catalog as its checkout on this machine has it, without fetching.
// The message says why there is none; empty: read.
catalog_load :: proc(engine_root:string,catalog:^project.Catalog) -> string {
    catalog^={}
    if engine_root=="" {return "The root of the engine is unknown"}
    folder:=catalog_folder(engine_root,context.temp_allocator)
    if error:=project.catalog_read(folder,catalog);error.code!=.None {
        if error.code==.Not_Found {return "The catalog was not fetched yet"}
        return fmt.tprintf("%s/%s/%s.json: %v",folder,project.CATALOG_PLUGINS,base.text_get(error.subject[:]),error.code)
    }
    return ""
}

// The checkout of a source exists: cloned at its commit when it did not.
@(private)
checkout_ensure :: proc(root:string,source:^project.Source) -> string {
    name:=base.text_get(source.name[:])
    folder:=project.path(root,"plugins",name,allocator=context.temp_allocator)
    if os.exists(folder) {return ""}
    url,commit:=base.text_get(source.url[:]),base.text_get(source.commit[:])
    staging,staging_ok:=staging_folder(root)
    if !staging_ok {return fmt.tprintf("%s could not be made",staging)}
    defer os.remove_all(staging)
    if _,failure:=git("","clone","--quiet","--no-checkout",url,staging);failure!="" {return fmt.tprintf("%s could not be cloned: %s",url,failure)}
    if _,failure:=git(staging,"checkout","--quiet","--detach",commit);failure!="" {return fmt.tprintf("%s has no commit %s: %s",url,commit,failure)}
    if error:=os.make_directory_all(project.path(root,"plugins",allocator=context.temp_allocator));error!=nil && error!=.Exist {return "The plugins folder of the project could not be made"}
    if error:=os.rename(staging,folder);error!=nil {return fmt.tprintf("%s could not be moved to %s: %v",staging,folder,error)}
    return ""
}

// Writes the manifest when the project still opens with it; else leaves
// before in the file.
@(private)
manifest_commit :: proc(root,engine_root:string,manifest,before:^project.Manifest) -> string {
    file:=project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator)
    if error:=project.manifest_write(file,manifest);error.code!=.None {return project.error_text(root,error,context.temp_allocator)}
    p,error:=project.open(root,engine_root,context.temp_allocator)
    if error.code==.None {
        project.close(&p)
        return ""
    }
    project.manifest_write(file,before)
    return fmt.tprintf("The project does not open with it: %s",project.error_text(root,error,context.temp_allocator))
}

// An active plugin of the project that depends on name, besides its
// companions, which go with it; empty: none.
@(private)
dependent_find :: proc(root,engine_root,name:string) -> string {
    p,error:=project.open(root,engine_root,context.temp_allocator)
    if error.code!=.None {return ""}
    defer project.close(&p)
    companions:=strings.concatenate({project.path(p.root,"plugins",name,project.PLUGIN_COMPANIONS,allocator=context.temp_allocator),"/"},context.temp_allocator)
    for index in p.active {
        if strings.has_prefix(p.plugins[index].folder,companions) {continue}
        m:=&p.plugins[index].manifest
        for &dependency in m.dependencies {
            if base.text_get(dependency[:])==name {return strings.clone(base.text_get(m.name[:]),context.temp_allocator)}
        }
    }
    return ""
}

// A folder for a clone under the generated folder of the project, empty.
@(private)
staging_folder :: proc(root:string) -> (folder:string,ok:bool) {
    parent:=project.path(project.folder_path(root,.Generated,context.temp_allocator),"install",allocator=context.temp_allocator)
    if error:=os.make_directory_all(parent);error!=nil && error!=.Exist {return parent,false}
    made,error:=os.make_directory_temp(parent,"clone-*",context.temp_allocator)
    if error!=nil {return parent,false}
    // git clones into a folder that does not exist or is empty.
    return made,true
}

// The commit a checkout is at, read from its .git without running git.
@(private)
head_read :: proc(folder:string) -> (commit:string,ok:bool) {
    git_folder:=project.path(folder,".git",allocator=context.temp_allocator)
    data,error:=os.read_entire_file(project.path(git_folder,"HEAD",allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return}
    text:=strings.trim_space(string(data))
    if !strings.has_prefix(text,"ref: ") {return text,true}
    ref:=text[len("ref: "):]
    if named,named_error:=os.read_entire_file(project.path(git_folder,ref,allocator=context.temp_allocator),context.temp_allocator);named_error==nil {
        return strings.trim_space(string(named)),true
    }
    return "",false
}

// The first symbolic link under folder, outside .git; empty: none.
@(private)
link_find :: proc(folder:string) -> string {
    entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
    if error!=nil {return ""}
    for entry in entries {
        if entry.name==".git" {continue}
        if entry.type==.Symlink {return entry.fullpath}
        if entry.type==.Directory {
            if found:=link_find(entry.fullpath);found!="" {return found}
        }
    }
    return ""
}

// The line of the .gitignore of the project that leaves the checkout of a plugin out of its repository.
@(private)
ignore_set :: proc(root,name:string,on:bool) {
    file:=project.path(root,".gitignore",allocator=context.temp_allocator)
    line:=fmt.tprintf("/plugins/%s/",name)
    data,_:=os.read_entire_file(file,context.temp_allocator)
    text:=string(data)
    lines:=make([dynamic]string,context.temp_allocator)
    found:=false
    for entry in strings.split_lines(text,context.temp_allocator) {
        if strings.trim_space(entry)==line {
            found=true
            if !on {continue}
        }
        append(&lines,entry)
    }
    if on==found {return}
    for len(lines)>0 && lines[len(lines)-1]=="" {pop(&lines)}
    if on {append(&lines,line)}
    out:=strings.join(lines[:],"\n",context.temp_allocator)
    if len(lines)>0 {out=strings.concatenate({out,"\n"},context.temp_allocator)}
    _=serial.file_write_atomic(file,transmute([]u8)out)
}

@(private)
named_add :: proc(m:^project.Manifest,name:project.Name) -> bool {
    for &named in m.plugins {
        if named==name {return true}
    }
    for &named in m.plugins {
        if base.text_len(named[:])==0 {named=name;return true}
    }
    return false
}

@(private)
named_remove :: proc(m:^project.Manifest,name:project.Name) {
    kept:[project.MAX_PLUGINS]project.Name
    count:=0
    for &named in m.plugins {
        if base.text_len(named[:])==0 || named==name {continue}
        kept[count]=named
        count+=1
    }
    m.plugins=kept
}

// The sources without gaps, in their order.
@(private)
compact :: proc(m:^project.Manifest) {
    kept:[project.MAX_SOURCES]project.Source
    count:=0
    for &source in m.sources {
        if base.text_len(source.name[:])==0 {continue}
        kept[count]=source
        count+=1
    }
    m.sources=kept
}

// Runs git in working (empty: the current folder) and returns its standard
// output, trimmed; failure says why it did not work. It never asks for a
// password on a terminal: the credential helper of the machine answers.
@(private)
git :: proc(working:string,args:..string) -> (out:string,failure:string) {
    command:=make([dynamic]string,context.temp_allocator)
    append(&command,"git")
    append(&command,..args)
    inherited,_:=os.environ(context.temp_allocator)
    environment:=make([dynamic]string,context.temp_allocator)
    for entry in inherited {
        // core:os can hand an empty entry, which no process takes.
        if len(entry)>1 && strings.index_byte(entry[1:],'=')>=0 {append(&environment,entry)}
    }
    append(&environment,"GIT_TERMINAL_PROMPT=0","LC_ALL=C")
    state,stdout,stderr,error:=subprocess.exec({command=command[:],working_dir=working,env=environment[:]},context.temp_allocator)
    if error!=nil {return "",fmt.tprintf("git could not be started (%v): is it installed?",error)}
    if !state.exited || state.exit_code!=0 {
        text:=strings.trim_space(string(stderr))
        if text=="" {text=strings.trim_space(string(stdout))}
        if text=="" {text=fmt.tprintf("exit code %d",state.exit_code)}
        return "",text
    }
    return strings.trim_space(string(stdout)),""
}

@(private)
fail :: proc(allocator:runtime.Allocator,format:string,args:..any) -> Result {
    return {message=fmt.aprintf(format,..args,allocator=allocator)}
}
