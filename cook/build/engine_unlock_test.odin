#+build windows
package build

import "core:os"
import win "core:sys/windows"
import "core:testing"
import "mirai:project"
import "mirai:std/base"

// A binary something holds is moved aside and a copy takes its place, which the build can write; the
// others stay as they are, and a later build deletes what was moved once nothing holds it.
@(test)
a_binary_in_use_moves_aside_and_leaves_a_copy_to_write :: proc(t:^testing.T) {
    folder:=base.test_folder(t,"engine-unlock")
    if folder=="" {return}
    held:=project.path(folder,"mirai-engine.dll",allocator=context.temp_allocator)
    free:=project.path(folder,"mirai-editor.dll",allocator=context.temp_allocator)
    stamp:=project.path(folder,ENGINE_STAMP,allocator=context.temp_allocator)
    for path in ([?]string{free,stamp}) {testing.expect(t,os.write_entire_file(path,transmute([]u8)path)==nil)}
    // A library this process loads: Windows holds it as it holds the binaries of a running engine.
    testing.expect(t,os.copy_file(held,"C:/Windows/System32/version.dll")==nil)
    original,_:=os.read_entire_file(held,context.temp_allocator)
    retired:=project.path(folder,ENGINE_RETIRED,allocator=context.temp_allocator)
    {
        handle:=win.LoadLibraryW(win.utf8_to_wstring(held))
        testing.expect(t,handle!=nil)
        testing.expect(t,!engine_writable(held),"loaded, it cannot be written")
        file,ok:=engine_unlock(folder)
        testing.expectf(t,ok,"it moved aside: %s",file)
        testing.expect(t,engine_writable(held),"the copy in its place can be written")
        data,_:=os.read_entire_file(held,context.temp_allocator)
        testing.expect(t,string(data)==string(original),"the copy is the same library")
        moved,_:=os.read_all_directory_by_path(retired,context.temp_allocator)
        testing.expect_value(t,len(moved),1)
        engine_unlock(folder)
        testing.expect(t,os.is_dir(retired),"what is still held stays")
        win.FreeLibrary(handle)
    }
    engine_unlock(folder)
    testing.expect(t,!os.exists(retired),"once nothing holds it, it is deleted")
    for path in ([?]string{free,stamp}) {
        data,_:=os.read_entire_file(path,context.temp_allocator)
        testing.expect_value(t,string(data),path)
    }
}
