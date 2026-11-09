package build

import "core:os"
import "core:strings"
import "mirai:asset"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/subprocess"

// Git and the assets of a repository. A kind of asset that is a document
// (asset.Kind_Info.merged for one of the engine, project.Asset_Kind.merged in
// the manifest of its plugin for another) is merged and diffed by git through
// mirai: its line of .gitattributes names the merge and the diff driver
// GIT_DRIVER, which the local configuration of each clone defines
// (git_settings). The other kinds are whole files to git.

GIT_DRIVER :: "mirai"

// A kind of asset of a plugin, as its manifest declares it.
Git_Kind :: struct {
    extension:string, // of its files, with the dot
    merged:bool,
}

// The kinds of asset of the plugins that the first of folders that is a
// checkout of the engine or a project holds or uses, as their manifests
// declare them: every plugin of the checkout, or the plugins the project
// uses, its own and those of the engine. None when no folder is either; ok
// is false when the plugins or the project do not read.
git_plugin_kinds :: proc(engine_root:string,folders:[]string,allocator:=context.allocator) -> (kinds:[]Git_Kind,ok:bool) {
    out:=make([dynamic]Git_Kind,allocator)
    add :: proc(out:^[dynamic]Git_Kind,plugin:^project.Plugin) {
        for &kind in plugin.manifest.asset_kinds {
            if extension:=base.text_get(kind.extension[:]);extension!="" {append(out,Git_Kind{strings.clone(extension,out.allocator),kind.merged})}
        }
    }
    for folder in folders {
        switch {
        case folder=="":
        case !project.engine_installed(folder) && project.engine_root_is(folder):
            found:=make([dynamic]project.Plugin,context.temp_allocator)
            if project.plugins_discover(project.path(folder,"plugins",allocator=context.temp_allocator),.Engine,&found,context.temp_allocator).code!=.None {return out[:],false}
            for &plugin in found {add(&out,&plugin)}
            return out[:],true
        case os.is_file(project.path(folder,project.PROJECT_FILE,allocator=context.temp_allocator)):
            p,error:=project.open(folder,engine_root,context.temp_allocator)
            if error.code!=.None {return out[:],false}
            for index in p.active {add(&out,&p.plugins[index])}
            return out[:],true
        }
    }
    return out[:],true
}

// The sources of imports that weigh: with LFS they stay out of the history, as
// the kinds git keeps whole do.
GIT_LFS_SOURCES :: [?]string{".png",".jpg",".jpeg",".tga",".exr",".hdr",".psd",".glb",".fbx",".wav",".ogg",".mp3"}

// The line of .gitattributes of a kind of asset. lfs: the repository keeps in
// LFS what git does not merge.
git_attributes_line :: proc(kind:Git_Kind,lfs:=false,allocator:=context.allocator) -> string {
    attributes:="merge="+GIT_DRIVER+" diff="+GIT_DRIVER+" -text"
    if !kind.merged {attributes=lfs?"filter=lfs diff=lfs merge=lfs -text":"binary"}
    return strings.concatenate({"*",kind.extension," ",attributes},allocator)
}

// The text of a .gitattributes: the lines existing has for other files, as
// they are, then one line per kind of asset of the engine and of plugins and,
// with lfs or when existing already keeps files in LFS, the kinds git keeps
// whole and the sources of imports in it. Made again from its own text it
// comes out the same: changed says whether it differs from existing in more
// than its line ends.
git_attributes :: proc(plugins:[]Git_Kind=nil,lfs:=false,existing:="",allocator:=context.allocator) -> (text:string,changed:bool) {
    kinds:=make([dynamic]Git_Kind,context.temp_allocator)
    listed :: proc(kinds:[]Git_Kind,extension:string) -> bool {
        for kind in kinds {if kind.extension==extension {return true}}
        return false
    }
    large:=lfs || strings.contains(existing,"filter=lfs")
    for info in asset.KINDS {append(&kinds,Git_Kind{info.extension,info.merged})}
    for kind in plugins {
        if kind.extension!="" && !listed(kinds[:],kind.extension) {append(&kinds,kind)}
    }
    if large {
        for extension in GIT_LFS_SOURCES {
            if !listed(kinds[:],extension) {append(&kinds,Git_Kind{extension,false})}
        }
    }
    out:=strings.builder_make(allocator)
    rest:=strings.trim_right(existing,"\r\n")
    for line in strings.split_lines_iterator(&rest) {
        pattern:=strings.trim_left_space(line)
        if cut:=strings.index_any(pattern," \t");cut>=0 {pattern=pattern[:cut]}
        if strings.has_prefix(pattern,"*") && listed(kinds[:],pattern[1:]) {continue}
        strings.write_string(&out,line)
        strings.write_byte(&out,'\n')
    }
    for kind in kinds {
        strings.write_string(&out,git_attributes_line(kind,large,context.temp_allocator))
        strings.write_byte(&out,'\n')
    }
    text=strings.to_string(out)
    same,_:=strings.replace_all(existing,"\r\n","\n",context.temp_allocator)
    return text,text!=same
}

Git_Setting :: struct {key,value:string}

GIT_SETTINGS :: 4

// What `git config --local --get-regexp` takes to list the settings of git_settings.
GIT_SETTINGS_PATTERN :: `^(merge|diff)\.`+GIT_DRIVER+`\.`

// What the local configuration of a clone holds for git to merge and diff
// assets: the merge driver, which is mirai asset merge, and the diff driver,
// which reads the text of mirai asset dump --textconv and heads each hunk
// with the name of its table. repository: the top of the work tree, which git
// runs the drivers from.
git_settings :: proc(engine_root,repository:string,allocator:=context.allocator) -> [GIT_SETTINGS]Git_Setting {
    tool:=git_tool(engine_root,repository,context.temp_allocator)
    return {
        {"merge."+GIT_DRIVER+".name","Mirai assets, row by row and field by field"},
        {"merge."+GIT_DRIVER+".driver",strings.concatenate({tool," asset merge %O %A %B"},allocator)},
        {"diff."+GIT_DRIVER+".textconv",strings.concatenate({tool," asset dump --textconv"},allocator)},
        {"diff."+GIT_DRIVER+".xfuncname",`^ +"name": "(.*)",$`},
    }
}

// How a driver names the tool. In a checkout of the engine it is the launcher
// at its top, by a relative path: the same line serves every clone and every
// worktree of it, each with its own tool. In another repository it is the
// launcher of this engine, or the tool of an installed one, by its absolute
// path: an engine that moved is set again (git_setup).
@(private="file")
git_tool :: proc(engine_root,repository:string,allocator:=context.allocator) -> string {
    if repository!="" && !project.engine_installed(repository) && project.engine_root_is(repository) && os.is_file(project.path(repository,"mirai",allocator=context.temp_allocator)) {
        return strings.clone("./mirai",allocator)
    }
    tool:=project.engine_installed(engine_root)?project.tool_file(engine_root,context.temp_allocator):project.path(engine_root,"mirai",allocator=context.temp_allocator)
    return strings.concatenate({"\"",tool,"\""},allocator)
}

// Of the settings, those a configuration listed with GIT_SETTINGS_PATTERN does
// not have (unset) and those it has with another value (other): bit i is
// settings[i].
git_settings_state :: proc(settings:[GIT_SETTINGS]Git_Setting,listed:string) -> (unset,other:u8) {
    for setting,i in settings {
        found,same:=false,false
        rest:=listed
        for line in strings.split_lines_iterator(&rest) {
            if !strings.has_prefix(line,setting.key) || len(line)>len(setting.key) && line[len(setting.key)]!=' ' {continue}
            found=true
            same||=len(line)>len(setting.key) && line[len(setting.key)+1:]==setting.value
        }
        switch {
        case !found: unset|=1<<uint(i)
        case !same:  other|=1<<uint(i)
        }
    }
    return
}

Git_Wiring :: enum u8 {
    None,    // no git, no repository, or one whose .gitattributes names no driver of mirai
    Wired,
    Unset,   // a setting is missing: git merges and diffs its assets as whole files
    Other,   // set for another copy of the engine
}

// The .gitattributes of the clone a folder is in, whose top is repository:
// the one of the folder when it has one, else the one at the top. text is
// what git_attributes makes of it with the kinds of the plugins it holds or
// uses, and changed whether that differs from the file.
@(private="file")
git_attributes_of :: proc(engine_root,folder,repository:string) -> (file,existing,text:string,changed,ok:bool) {
    holder:=folder
    file=project.path(holder,".gitattributes",allocator=context.temp_allocator)
    if !os.is_file(file) {
        holder=repository
        file=project.path(holder,".gitattributes",allocator=context.temp_allocator)
    }
    data,_:=os.read_entire_file(file,context.temp_allocator)
    existing=string(data)
    kinds:[]Git_Kind
    kinds,ok=git_plugin_kinds(engine_root,{holder,folder,repository},context.temp_allocator)
    text,changed=git_attributes(kinds,false,existing,context.temp_allocator)
    return
}

// Whether the clone folder is in has the drivers its .gitattributes names,
// and whether that file lacks the line of a kind of the engine or of the
// plugins it holds or uses (stale).
git_wiring :: proc(engine_root,folder:string,allocator:=context.allocator) -> (state:Git_Wiring,repository:string,stale:bool) {
    found:bool
    repository,found=git_top(folder,allocator)
    if !found {return .None,"",false}
    _,existing,_,changed,read:=git_attributes_of(engine_root,folder,repository)
    if !strings.contains(existing,"merge="+GIT_DRIVER) && !strings.contains(existing,"diff="+GIT_DRIVER) {return .None,repository,false}
    stale=read && changed
    unset,other:=git_settings_state(git_settings(engine_root,repository,context.temp_allocator),git_settings_listed(repository))
    switch {
    case unset!=0: state=.Unset
    case other!=0: state=.Other
    case:          state=.Wired
    }
    return
}

Git_Setup_Error :: enum u8 {
    None,
    No_Git,            // git did not run
    No_Repository,     // the folder is in no work tree
    Plugins_Failed,    // the project of the folder, or a plugin it holds, does not read
    Attributes_Failed, // .gitattributes could not be written
    Settings_Failed,   // git did not take a setting
}

Git_Setup :: struct {
    repository:string, // the top of the work tree
    attributes:string, // the .gitattributes written; "" when it already had its lines
    settings:int,      // how many settings were written
}

// Wires the clone folder is in: its .gitattributes with the lines of the
// kinds of the engine and of the plugins it holds or uses (git_attributes
// over the one of folder when it has one, else over the one at the top of the
// work tree) and the drivers in its local configuration. What already is as
// it would be written stays untouched, so it can run again at any time: after
// the engine moved, or with a new kind or plugin.
git_setup :: proc(engine_root,folder:string,allocator:=context.allocator) -> (done:Git_Setup,error:Git_Setup_Error) {
    if _,_,_,exec_error:=subprocess.exec({command={"git","--version"}},context.temp_allocator);exec_error!=nil {return {},.No_Git}
    found:bool
    done.repository,found=git_top(folder,allocator)
    if !found {return done,.No_Repository}
    file,_,text,changed,read:=git_attributes_of(engine_root,folder,done.repository)
    if !read {return done,.Plugins_Failed}
    if changed {
        if os.write_entire_file(file,text)!=nil {return done,.Attributes_Failed}
        done.attributes=strings.clone(file,allocator)
    }
    settings:=git_settings(engine_root,done.repository,context.temp_allocator)
    unset,other:=git_settings_state(settings,git_settings_listed(done.repository))
    for setting,i in settings {
        if (unset|other)&(1<<uint(i))==0 {continue}
        state,_,_,exec_error:=subprocess.exec({command={"git","-C",done.repository,"config","--local",setting.key,setting.value}},context.temp_allocator)
        if exec_error!=nil || state.exit_code!=0 {return done,.Settings_Failed}
        done.settings+=1
    }
    return done,.None
}

// The top of the work tree a folder is in, with forward slashes.
@(private="file")
git_top :: proc(folder:string,allocator:=context.allocator) -> (top:string,found:bool) {
    state,out,_,error:=subprocess.exec({command={"git","-C",folder,"rev-parse","--show-toplevel"}},context.temp_allocator)
    if error!=nil || state.exit_code!=0 {return "",false}
    return strings.clone(strings.trim_space(string(out)),allocator),true
}

@(private="file")
git_settings_listed :: proc(repository:string) -> string {
    _,out,_,_:=subprocess.exec({command={"git","-C",repository,"config","--local","--get-regexp",GIT_SETTINGS_PATTERN}},context.temp_allocator)
    return string(out)
}
