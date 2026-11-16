package main

import "core:fmt"
import "core:strings"
import "mirai:cook/install"
import "mirai:project"
import "mirai:std/base"

// mirai plugin: the plugins of a project that come from git (cook/install).
// add takes the address of a repository or the name of a plugin of the
// catalog, which installs at the commit the catalog lists.

PLUGIN_USAGE :: "plugin add <url|name> [--ref R] | plugin update [name] [--ref R] | plugin remove <name> | plugin sync | plugin list | plugin catalog [--refresh] | plugin check <folder> [--project P]"

cmd_plugin :: proc(root:string,args:[]string) -> int {
    if len(args)==0 {
        fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE)
        return 2
    }
    folder,ref,refresh:=".","",false
    rest:=make([dynamic]string,context.temp_allocator)
    for i:=1;i<len(args);i+=1 {
        switch args[i] {
        case "--project","--ref":
            option:=args[i]
            if i+1>=len(args) {fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE);return 2}
            i+=1
            if option=="--project" {folder=args[i]} else {ref=args[i]}
        case "--refresh":
            refresh=true
        case:
            if !positional(args[i]) {return argument_unknown("plugin",args[i])}
            append(&rest,args[i])
        }
    }
    folder=project.path_absolute(folder,context.temp_allocator)
    switch args[0] {
    case "add":
        if len(rest)!=1 {fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE);return 2}
        url:=rest[0]
        // A name of the catalog: no address has neither ':' nor '/'.
        if !strings.contains_any(url,":/\\") {
            if ref!="" {fmt.eprintln("mirai plugin: one of the catalog is installed at the commit it lists; --ref is for an address");return 2}
            if message:=install.catalog_refresh(root,context.temp_allocator);message!="" {fmt.eprintfln("mirai plugin: %s",message);return 1}
            return plugin_report(install.add_from_catalog(folder,root,url,context.temp_allocator))
        }
        return plugin_report(install.add(folder,root,url,ref,context.temp_allocator))
    case "update":
        if len(rest)>1 {fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE);return 2}
        manifest,error:=project.manifest_read(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator))
        if error.code!=.None {fmt.eprintfln("mirai plugin: %s",project_error_text(folder,error));return 1}
        if len(rest)==0 && ref!="" {fmt.eprintln("mirai plugin: --ref is for one plugin; name it");return 2}
        _=install.catalog_refresh(root,context.temp_allocator)
        code:=0
        for &source in manifest.sources {
            name:=base.text_get(source.name[:])
            if name=="" || len(rest)==1 && rest[0]!=name {continue}
            if plugin_report(install.update(folder,root,name,ref,context.temp_allocator))!=0 {code=1}
        }
        if len(rest)==1 && project.source_find(&manifest,rest[0])==nil {
            fmt.eprintfln("mirai plugin: %s does not come from Git",rest[0])
            return 1
        }
        return code
    case "remove":
        if len(rest)!=1 {fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE);return 2}
        return plugin_report(install.remove(folder,root,rest[0],context.temp_allocator))
    case "sync":
        changed,message:=install.sync(folder,context.temp_allocator)
        if message!="" {fmt.eprintln(message);return 1}
        fmt.printfln("%d plugins from Git moved to their commit.",changed)
        return 0
    case "list":
        manifest,error:=project.manifest_read(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator))
        if error.code!=.None {fmt.eprintfln("mirai plugin: %s",project_error_text(folder,error));return 1}
        count:=0
        for &source in manifest.sources {
            name:=base.text_get(source.name[:])
            if name=="" {continue}
            commit:=base.text_get(source.commit[:])
            fmt.printfln("%-24s %s %s",name,commit[:min(12,len(commit))],base.text_get(source.url[:]))
            count+=1
        }
        if count==0 {fmt.println("The project has no plugins from Git.")}
        return 0
    case "catalog":
        catalog:=new(project.Catalog,context.temp_allocator)
        loaded:=install.catalog_load(root,catalog)
        if refresh || loaded!="" {
            if message:=install.catalog_refresh(root,context.temp_allocator);message!="" {fmt.eprintfln("mirai plugin: %s",message);return 1}
            if message:=install.catalog_load(root,catalog);message!="" {fmt.eprintfln("mirai plugin: %s",message);return 1}
        }
        for &entry in catalog.plugins[:project.catalog_count(catalog)] {
            fmt.printfln("%-24s %s\n%24s %s",base.text_get(entry.name[:]),base.text_get(entry.description[:]),"",base.text_get(entry.url[:]))
        }
        if project.catalog_count(catalog)==0 {fmt.println("The catalog has no plugins yet.")}
        return 0
    case "check":
        if len(rest)!=1 {fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE);return 2}
        plugin,problem:=install.plugin_check(rest[0],"")
        if problem!="" {fmt.eprintfln("mirai plugin: %s",problem);return 1}
        fmt.printfln("%s %s can be installed.",base.text_get(plugin.name[:]),base.text_get(plugin.version[:]))
        return 0
    }
    fmt.eprintfln("Usage: mirai %s",PLUGIN_USAGE)
    return 2
}

@(private="file")
plugin_report :: proc(result:install.Result) -> int {
    if !result.ok {
        fmt.eprintfln("mirai plugin: %s",result.message)
        return 1
    }
    fmt.println(result.message)
    return 0
}
