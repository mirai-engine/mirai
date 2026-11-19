#+build windows
package build

import "core:os"
import win "core:sys/windows"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

@(test)
a_loaded_library_is_replaced_and_retired_until_it_is_free :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"binary-loaded")
    if folder=="" {return}
    a:=context.temp_allocator
    published:=project.path(folder,"published.dll",allocator=a)
    retired:=project.path(folder,ENGINE_RETIRED,allocator=a)
    source:="C:/Windows/System32/version.dll"
    if !testing.expect(t,copy_binary(published,source)) {return}
    old,stat_error:=binary_copy_info(published)
    if !testing.expect(t,stat_error==nil) {return}
    {
        handle:=win.LoadLibraryW(win.utf8_to_wstring(published,a))
        if !testing.expect(t,handle!=nil) {return}
        defer win.FreeLibrary(handle)
        if !testing.expect(t,copy_binary(published,source)) {return}
        current,current_error:=binary_copy_info(published)
        testing.expect(t,current_error==nil && current.inode!=old.inode)
        engine_retired_sweep(retired)
        moved,moved_error:=os.read_all_directory_by_path(retired,a)
        if !testing.expect(t,moved_error==nil && len(moved)==1) {return}
        held,held_error:=binary_copy_info(moved[0].fullpath)
        testing.expect(t,held_error==nil && held.inode==old.inode)
    }
    engine_retired_sweep(retired)
    testing.expect(t,!os.exists(retired))
}
