package shaders

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "mirai:cook/workspace"
import "mirai:std/base"

// An official prebuilt package of a tool, pinned by its version and SHA-256,
// that installs into <deps>/<folder>.
Prebuilt :: struct {
    name,version:string,
    folder:string,  // under .deps
    asset:string,   // the file of the release
    url:string,
    sha256:string,
    top:string,     // the folder of the archive whose contents are the package; "" for its root
    required:string, // a file the package must have, relative to it
}

// Installs a prebuilt package into the deps of root. Nothing is compiled: it
// is downloaded with curl (or taken from `archive`), checked against its
// SHA-256 and unpacked with tar. The message is in `allocator`.
prebuilt_install :: proc(root:string,p:Prebuilt,archive:string="",allocator:=context.allocator) -> (message:string,ok:bool) {
    target:=prebuilt_folder(root,p,context.temp_allocator)
    if prebuilt_installed(target,p.sha256) {return fmt.aprintf("%s %s already installed in %s",p.name,p.version,target,allocator=allocator),true}
    source:=archive
    download:string
    if source=="" {
        os.make_directory_all(path_parent(target))
        folder,folder_error:=os.make_directory_temp(path_parent(target),fmt.tprintf("%s-download-*",p.folder),context.temp_allocator)
        if folder_error!=nil {return strings.clone("Could not create a temporary folder in .deps",allocator),false}
        download=path_clean(folder,context.temp_allocator)
        source=path_join(download,p.asset,allocator=context.temp_allocator)
        runner:Runner
        output,downloaded:=tool_run(&runner,{system_tool("curl"),"--location","--fail","--silent","--show-error","--output",source,p.url},context.temp_allocator)
        if !downloaded {
            base.remove_all(download)
            return fmt.aprintf("Could not download %s with curl: %s",p.url,strings.trim_space(output),allocator=allocator),false
        }
    }
    defer if download!="" {base.remove_all(download)}
    return prebuilt_install_archive(target,source,p,allocator)
}

// Where a prebuilt package is installed for root.
prebuilt_folder :: proc(root:string,p:Prebuilt,allocator:=context.allocator) -> string {
    return path_join(workspace.deps_folder(path_clean(root,context.temp_allocator),context.temp_allocator),p.folder,allocator=allocator)
}

@(private)
prebuilt_installed :: proc(target,sha256:string) -> bool {
    marker,readable:=read_json(path_join(target,"mirai-package.json",allocator=context.temp_allocator),context.temp_allocator)
    return readable && json_text(marker["sha256"])==sha256
}

// Checks, unpacks and puts a package in place of `target`. The previous
// installation is kept until the new one is whole, and comes back if moving
// the new one into place fails.
@(private)
prebuilt_install_archive :: proc(target,archive:string,p:Prebuilt,allocator:=context.allocator) -> (message:string,ok:bool) {
    data,read_error:=os.read_entire_file(archive,context.temp_allocator)
    if read_error!=nil {return fmt.aprintf("Could not read %s",archive,allocator=allocator),false}
    if actual:=sha_of(data,context.temp_allocator);actual!=p.sha256 {return fmt.aprintf("Wrong SHA-256 of %s: %s",p.asset,actual,allocator=allocator),false}
    os.make_directory_all(path_parent(target))
    folder,folder_error:=os.make_directory_temp(path_parent(target),fmt.tprintf("%s-install-*",p.folder),context.temp_allocator)
    if folder_error!=nil {return fmt.aprintf("Could not create a temporary folder next to %s",target,allocator=allocator),false}
    temporary:=path_clean(folder,context.temp_allocator)
    defer base.remove_all(temporary)
    unpacked:=path_join(temporary,"package",allocator=context.temp_allocator)
    os.make_directory(unpacked)
    runner:Runner
    tar:=system_tool("tar")
    listing,listed:=tool_run(&runner,{tar,"-tf",archive},context.temp_allocator)
    if !listed {return fmt.aprintf("tar could not read %s: %s",p.asset,strings.trim_space(listing),allocator=allocator),false}
    entries:=listing
    for entry in strings.split_lines_iterator(&entries) {
        if !archive_entry_confined(entry) {return fmt.aprintf("The package holds a path outside its destination: %s",entry,allocator=allocator),false}
    }
    if output,extracted:=tool_run(&runner,{tar,"-xf",archive,"-C",unpacked},context.temp_allocator);!extracted {
        return fmt.aprintf("tar could not extract %s: %s",p.asset,strings.trim_space(output),allocator=allocator),false
    }
    staged:=p.top!=""?path_join(unpacked,p.top,allocator=context.temp_allocator):unpacked
    if !os.is_file(path_join(staged,p.required,allocator=context.temp_allocator)) {return fmt.aprintf("The package does not contain %s",p.required,allocator=allocator),false}
    writer:=json_writer(context.temp_allocator)
    json_object_begin(&writer)
    json_key(&writer,"version");json_string(&writer,p.version)
    json_key(&writer,"asset");json_string(&writer,p.asset)
    json_key(&writer,"sha256");json_string(&writer,p.sha256)
    json_object_end(&writer)
    if !write_file(path_join(staged,"mirai-package.json",allocator=context.temp_allocator),json_finish(&writer)) {return strings.clone("Could not write mirai-package.json",allocator),false}
    previous:=path_join(temporary,"previous",allocator=context.temp_allocator)
    had_previous:=os.exists(target)
    if had_previous && !rename_patiently(target,previous) {return fmt.aprintf("Could not replace %s: it is in use; close what uses it and try again",target,allocator=allocator),false}
    if !rename_patiently(staged,target) {
        if had_previous {rename_patiently(previous,target)}
        return fmt.aprintf("Could not move the package to %s",target,allocator=allocator),false
    }
    return fmt.aprintf("%s %s installed in %s",p.name,p.version,target,allocator=allocator),true
}

// curl and tar as the system ships them. On Windows the ones of System32:
// the tar of a Unix shell earlier in PATH reads "C:" as the name of a host.
@(private)
system_tool :: proc(name:string) -> string {
    when ODIN_OS==.Windows {
        if windows,found:=os.lookup_env("SystemRoot",context.temp_allocator);found {
            candidate:=path_clean(path_join(windows,"System32",strings.concatenate({name,".exe"},context.temp_allocator),allocator=context.temp_allocator),context.temp_allocator)
            if os.is_file(candidate) {return candidate}
        }
    }
    return name
}

// Whether the name of an archive entry stays inside the folder it is unpacked in.
@(private)
archive_entry_confined :: proc(entry:string) -> bool {
    name,_:=strings.replace_all(entry,"\\","/",context.temp_allocator)
    if strings.has_prefix(name,"/") || (len(name)>1 && name[1]==':') {return false}
    rest:=name
    for part in strings.split_iterator(&rest,"/") {if part==".." {return false}}
    return true
}

// On Windows an antivirus can hold freshly unpacked binaries for a moment.
@(private)
rename_patiently :: proc(source,target:string) -> bool {
    attempts:=40 when ODIN_OS==.Windows else 1
    for attempt in 0..<attempts {
        if os.rename(source,target)==nil {return true}
        if attempt<attempts-1 {time.sleep(250*time.Millisecond)}
    }
    return false
}
