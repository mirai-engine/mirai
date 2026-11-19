package asset

import "core:fmt"
import "core:strings"
import "mirai:std/base"
import "mirai:store"

// What a root lists from the packages it uses: a project, or a plugin, which
// keeps its packages as a project does. Every program that sets a registry up
// for a root that is not shipped gives it these entries.
Root_Packages :: struct {
    listed:[]Package_Listed,     // for registry_init or registry_mount of the root
    packages:[]Resolved_Package, // whose manifest read: their names and origins
    problems:[]string,           // one line per package it cannot list whole: which one, and how to fix it
}

// packages_resolve of the list at root (PACKAGES_FILE) against the store at
// store_root, the machine's (store.default_root) when "", which takes the
// manifests it lacks from the files of the root. A root without the
// list lists nothing and opens no store. A list or a store that does not read
// is a problem, as is a package that is not here or not built here: none is an
// error, which is only that memory ran out. In allocator, an arena.
root_packages :: proc(root,store_root:string,allocator:=context.allocator) -> (resolved:Root_Packages,error:Error) {
    list,problems,listed:=packages_list(root,allocator) or_return
    if !listed {return {problems=problems[:]},.None}
    folder:=store_root!=""?store_root:store.default_root(context.temp_allocator)
    if folder=="" {
        problem_line(&problems,"this machine has no folder for the store of Mirai, so the packages of %s are not listed",root) or_return
        return {problems=problems[:]},.None
    }
    s,open_error:=store.open(folder,context.temp_allocator)
    switch open_error {
    case .None:
    case .Out_Of_Memory: return {},.Out_Of_Memory
    case .Unsupported_Layout:
        problem_line(&problems,"the store at %s was written by another version of Mirai, so the packages of %s are not listed: remove that folder and build again, which fills it",folder,root) or_return
        return {problems=problems[:]},.None
    case .Missing,.Corrupt,.Invalid_Argument,.Io,.No_Space:
        problem_line(&problems,"the store at %s does not open (%v), so the packages of %s are not listed",folder,open_error,root) or_return
        return {problems=problems[:]},.None
    }
    defer store.close(&s)
    return packages_listed(&s,root,&list,problems,allocator)
}

// root_packages against the store s, already open; a root without the list
// lists nothing. In allocator, an arena.
root_packages_in :: proc(s:^store.Store,root:string,allocator:=context.allocator) -> (resolved:Root_Packages,error:Error) {
    list,problems,listed:=packages_list(root,allocator) or_return
    if !listed {return {problems=problems[:]},.None}
    return packages_listed(s,root,&list,problems,allocator)
}

// The list at root, with a problem when it does not read; listed: it names packages.
@(private="file")
packages_list :: proc(root:string,allocator:=context.allocator) -> (list:Packages,problems:[dynamic]string,listed:bool,error:Error) {
    problems=make([dynamic]string,allocator)
    load_error:Error
    found:bool
    list,found,load_error=packages_load(root,context.temp_allocator)
    switch load_error {
    case .None:
    case .Out_Of_Memory: return {},problems,false,.Out_Of_Memory
    case .Truncated,.Not_An_Asset,.Version,.Corrupt,.Hash,.Too_Large,.Schema,.Not_Found,.IO,.Invalid,.Codec_Missing,.Not_Here:
        problem_line(&problems,"%s/%s does not read (%v), so its packages are not listed: restore it from version control",root,PACKAGES_FILE,load_error) or_return
        return
    }
    return list,problems,found && len(list.packages)>0,.None
}

@(private="file")
packages_listed :: proc(s:^store.Store,root:string,list:^Packages,problems:[dynamic]string,allocator:=context.allocator) -> (resolved:Root_Packages,error:Error) {
    problems:=problems
    folder:=s.root
    packages:=packages_resolve(s,root,list,allocator) or_return
    unreadable:=make(map[base.Asset_Id]bool,context.temp_allocator)
    for problem in packages.problems {
        named:=package_named(s,list,problem.package_id)
        switch problem.code {
        case .Manifest_Missing:
            problem_line(&problems,"%s is neither in the store at %s nor in %s: restore that file from version control, or fetch the manifest from a peer that has it",named,folder,package_file(root,problem.package_id)) or_return
        case .Manifest_Unreadable:
            problem_line(&problems,"the manifest of %s is not one this engine reads: ingest its source again",named) or_return
        case .Manifest_Mismatch:
            problem_line(&problems,"%s is not the manifest %s/%s pins for %s: restore both from version control, or ingest its source again",package_file(root,problem.package_id),root,PACKAGES_FILE,named) or_return
        case .Build_Unreadable:
            unreadable[problem.package_id]=true
            problem_line(&problems,"the build of %s on this machine does not read, so its assets are not built: refresh it on a machine with its source",named) or_return
        case .Asset_Unknown:
            buffer:[base.ASSET_ID_TEXT]u8
            problem_line(&problems,"%s has no asset %s, which %s/%s uses: remove it from the list, or ingest the package again",named,base.asset_id_format(problem.asset,buffer[:]),root,PACKAGES_FILE) or_return
        }
    }
    for &l in packages.listed {
        if l.state!=.Not_Built || unreadable[l.package_id] {continue}
        unreadable[l.package_id]=true
        problem_line(&problems,"%s has no build on this machine that this engine reads, so its assets do not load: refresh it on a machine with its source, or fetch it from a peer that built it",package_named(s,list,l.package_id)) or_return
    }
    return {listed=packages.listed[:],packages=packages.packages[:],problems=problems[:]},.None
}

// "the package <name> (<id>) of <folder>/": by its manifest when the store
// has it, else by its id. In the temp allocator.
@(private="file")
package_named :: proc(s:^store.Store,list:^Packages,id:base.Asset_Id) -> string {
    buffer:[base.ASSET_ID_TEXT]u8
    text:=base.asset_id_format(id,buffer[:])
    for &entry in list.packages {
        if entry.id!=id {continue}
        folder:=entry.folder!=""?entry.folder:"the top of the assets"
        if p,error:=package_get(s,entry.manifest,context.temp_allocator);error==.None && p.id==id {
            return fmt.tprintf("the package %s (%s) listed in %s",p.name,text,folder)
        }
        return fmt.tprintf("the package %s listed in %s",text,folder)
    }
    return fmt.tprintf("the package %s",text)
}

@(private="file")
problem_line :: proc(problems:^[dynamic]string,format:string,args:..any) -> Error {
    line,no_line:=strings.clone(fmt.tprintf(format,..args),problems.allocator)
    if no_line!=nil {return .Out_Of_Memory}
    if _,no_room:=append(problems,line);no_room!=nil {return .Out_Of_Memory}
    return .None
}
