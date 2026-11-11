package build

import "core:os"
import "core:strings"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"

Create_Error :: enum u8 {
    None,
    Template_Missing, // the template has no project.mirai
    Folder_Not_Empty, // the destination is a file, or a folder with something in it
    Copy_Failed,
    Manifest_Failed,  // the manifest of the template does not read, or the name does not fit it
}

TEMPLATE_DEFAULT :: "empty"
TEMPLATE_COMMON :: "common"

// <engine>/templates/<name>: a project that `mirai new` copies. What all of
// them share is in TEMPLATE_COMMON beside them, which has no manifest and so
// is no template.
template_folder :: proc(engine_root:string,name:=TEMPLATE_DEFAULT,allocator:=context.allocator) -> string {
    return project.path(engine_root,"templates",name,allocator=allocator)
}

Template :: struct {name,summary:string}

// The templates of the engine, by name: the folders of <engine>/templates
// with a project.mirai. The summary is the first line of their README.md
// without the marks of a heading, or empty.
templates_list :: proc(engine_root:string,allocator:=context.allocator) -> []Template {
    found:=make([dynamic]Template,allocator)
    entries,error:=os.read_all_directory_by_path(project.path(engine_root,"templates",allocator=context.temp_allocator),context.temp_allocator)
    if error!=nil {return found[:]}
    for entry in entries {
        if entry.type!=.Directory || !os.is_file(project.path(entry.fullpath,project.PROJECT_FILE,allocator=context.temp_allocator)) {continue}
        summary:=""
        if text,read_error:=os.read_entire_file(project.path(entry.fullpath,"README.md",allocator=context.temp_allocator),context.temp_allocator);read_error==nil {
            line:=string(text)
            if cut:=strings.index_any(line,"\r\n");cut>=0 {line=line[:cut]}
            summary=strings.trim_space(strings.trim_left(line,"#"))
        }
        append(&found,Template{strings.clone(entry.name,allocator),strings.clone(summary,allocator)})
    }
    return found[:]
}

// The files all the templates share, over the project. A template outside
// <engine>/templates has none beside it.
@(private="file")
template_common_copy :: proc(template,root:string) -> bool {
    common:=project.path(template[:max(strings.last_index_byte(template,'/'),0)],TEMPLATE_COMMON,allocator=context.temp_allocator)
    if !os.is_dir(common) {return true}
    entries,error:=os.read_all_directory_by_path(common,context.temp_allocator)
    if error!=nil {return false}
    for entry in entries {
        to:=project.path(root,entry.name,allocator=context.temp_allocator)
        if (entry.type==.Directory?os.copy_directory_all(to,entry.fullpath):os.copy_file(to,entry.fullpath))!=nil {return false}
    }
    return true
}

// A new project: the tree of the template with every folder of the layout,
// the files all the templates share, the .gitattributes of the kinds of asset
// of the engine and of the plugins it uses (git_attributes), and name in its
// manifest. An empty name is the name of the folder. engine_root: where the
// plugins of the engine it names are.
project_create :: proc(template,folder,name:string,engine_root:="") -> Create_Error {
    if !os.is_file(project.path(template,project.PROJECT_FILE,allocator=context.temp_allocator)) {return .Template_Missing}
    root:=project.path_absolute(folder,context.temp_allocator)
    if os.exists(root) {
        if !os.is_dir(root) {return .Folder_Not_Empty}
        entries,error:=os.read_all_directory_by_path(root,context.temp_allocator)
        if error!=nil || len(entries)>0 {return .Folder_Not_Empty}
    }
    if os.copy_directory_all(root,template)!=nil || !template_common_copy(template,root) {return .Copy_Failed}
    // What a build of the template itself left is not part of it.
    _=base.remove_all(project.folder_path(root,.Generated,context.temp_allocator))
    for layout in ([]project.Folder{.Assets,.Game,.Editor,.Plugins,.Shaders}) {
        directory:=project.folder_path(root,layout,context.temp_allocator)
        if os.make_directory_all(directory)!=nil && !os.is_dir(directory) {return .Copy_Failed}
    }
    file:=project.path(root,project.PROJECT_FILE,allocator=context.temp_allocator)
    m,error:=project.manifest_read(file)
    if error.code!=.None {return .Manifest_Failed}
    title:=name!=""?name:root[strings.last_index_byte(root,'/')+1:]
    if !base.text_set(m.name[:],title) || project.manifest_write(file,&m).code!=.None {return .Manifest_Failed}
    attributes:=project.path(root,".gitattributes",allocator=context.temp_allocator)
    existing,_:=os.read_entire_file(attributes,context.temp_allocator)
    kinds,_:=git_plugin_kinds(engine_root,{root},context.temp_allocator)
    if text,changed:=git_attributes(kinds,false,string(existing),context.temp_allocator);changed && serial.file_write_atomic(attributes,transmute([]u8)text)!=.None {return .Copy_Failed}
    return .None
}
