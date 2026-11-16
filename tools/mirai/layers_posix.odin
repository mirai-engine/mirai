#+build !windows
package main

import "core:os"
import "core:strings"

// The manifests of the implicit Vulkan layers the loader would load, from
// the folders it searches.
implicit_layers :: proc(allocator:=context.allocator) -> []string {
    list:=make([dynamic]string,allocator)
    folders:=make([dynamic]string,context.temp_allocator)
    if home,found:=os.lookup_env("HOME",context.temp_allocator);found {
        append(&folders,strings.concatenate({home,"/.local/share/vulkan/implicit_layer.d"},context.temp_allocator))
    }
    append(&folders,"/etc/vulkan/implicit_layer.d","/usr/local/share/vulkan/implicit_layer.d","/usr/share/vulkan/implicit_layer.d")
    for folder in folders {
        entries,error:=os.read_all_directory_by_path(folder,context.temp_allocator)
        if error!=nil {continue}
        for entry in entries {
            if strings.has_suffix(entry.name,".json") {append(&list,strings.clone(entry.fullpath,allocator))}
        }
    }
    return list[:]
}
